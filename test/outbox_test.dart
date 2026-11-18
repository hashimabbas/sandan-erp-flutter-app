import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/local_database.dart';
import 'package:sandan_facility_app/data/outbox.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// SPEC-024 Phase 2, Step 3 — the queue's two rules, proved without a network.
///
/// 🔴 **Rule 1, refined by Phase 3 D4: in order WITHIN A JOB, and a failure
/// stops only that job's chain.** `start` then `complete` is legal and the
/// reverse is not — a fact about one job, which Phase 2 applied globally and
/// thereby let one stuck item freeze every other job's work.
/// 🔴 **Rule 2: an item is never sent under another man's token.**
void main() {
  sqfliteFfiInit();

  late LocalDatabase database;
  late Outbox outbox;

  setUp(() {
    database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    outbox = Outbox(database);
  });

  tearDown(() => database.close());

  Future<void> queueThree(int userId, {String jobId = 'job-1'}) async {
    for (final action in ['start', 'complete', 'refer']) {
      await outbox.enqueue(
        userId: userId,
        jobId: jobId,
        method: 'PATCH',
        path: '/api/facility/work-orders/$jobId/$action',
        // ⚠️ `referred_to`, measured from the controller — NOT `provider`.
        body: action == 'refer' ? {'referred_to': 'Al Sahwa Plumbing'} : null,
      );
    }
  }

  test('an item keeps its method, path, body and owner', () async {
    await outbox.enqueue(
      userId: 7,
      method: 'PATCH',
      path: '/api/facility/work-orders/job-1/complete',
      body: {'notes': 'Replaced the flexible hose.'},
      createdAt: DateTime.utc(2026, 10, 28, 9),
    );

    final item = (await outbox.pending(7)).single;

    expect(item.userId, 7);
    expect(item.method, 'PATCH');
    expect(item.path, '/api/facility/work-orders/job-1/complete');
    expect(item.body, {'notes': 'Replaced the flexible hose.'});
    expect(item.attempts, 0);
    expect(item.lastError, isNull);
    // ⚠️ Recorded, not acted on: §6 Q2 is unanswered, so no expiry is invented.
    expect(item.createdAt, DateTime.utc(2026, 10, 28, 9).toLocal());
  });

  test('the queue drains in the order it was written', () async {
    await queueThree(7);

    final seen = <String>[];

    final report = await outbox.drain(
      userId: 7,
      send: (item) async {
        seen.add(item.path.split('/').last);
        return const OutboxSendResult(OutboxDisposition.sent);
      },
    );

    expect(seen, ['start', 'complete', 'refer']);
    expect(report.sent, 3);
    expect(report.stoppedBy, isNull);
    expect(await outbox.pending(7), isEmpty);
  });

  test('🔴 a failure stops THAT JOB\'s chain — the stuck item and what follows it stay', () async {
    await queueThree(7);

    final attempted = <String>[];

    final report = await outbox.drain(
      userId: 7,
      send: (item) async {
        final action = item.path.split('/').last;
        attempted.add(action);

        if (action == 'complete') {
          return const OutboxSendResult(
            OutboxDisposition.refused,
            error: 'This work order has not been started.',
          );
        }

        return const OutboxSendResult(OutboxDisposition.sent);
      },
    );

    // 🎯 `refer` was never attempted. Sending it while `complete` is stuck
    // would ask the server for a sequence the lifecycle refuses, and the
    // failure would look random.
    expect(attempted, ['start', 'complete']);
    expect(report.sent, 1);
    expect(report.stoppedBy, OutboxDisposition.refused);
    expect(report.remaining, 2);
    expect(report.stalledJobs, {'job-1'});
    expect((await outbox.pending(7)).map((i) => i.path.split('/').last), ['complete', 'refer']);
  });

  test('🔴 but job B keeps draining while job A is stuck — the case that made the global rule WRONG', () async {
    // ⚠️ This test is why Phase 2's rule was refined rather than kept. With
    // one global queue, a technician's whole afternoon sat behind one refusal
    // he might not be able to resolve — and Phase 2 could not see it, because
    // with no writers there was never a second job to block.
    await outbox.enqueue(
      userId: 7,
      jobId: 'job-A',
      method: 'PATCH',
      path: '/api/facility/work-orders/job-A/complete',
    );
    await outbox.enqueue(
      userId: 7,
      jobId: 'job-B',
      method: 'PATCH',
      path: '/api/facility/work-orders/job-B/start',
    );
    await outbox.enqueue(
      userId: 7,
      jobId: 'job-B',
      method: 'PATCH',
      path: '/api/facility/work-orders/job-B/complete',
    );

    final report = await outbox.drain(
      userId: 7,
      send: (item) async => item.jobId == 'job-A'
          ? const OutboxSendResult(OutboxDisposition.refused, error: 'Not started.')
          : const OutboxSendResult(OutboxDisposition.sent),
    );

    expect(report.sent, 2);
    expect(report.stalledJobs, {'job-A'});

    final left = await outbox.pending(7);

    expect(left, hasLength(1));
    expect(left.single.jobId, 'job-A');
  });

  test('a stalled chain is not re-attempted later in the same drain', () async {
    await queueThree(7, jobId: 'job-A');

    var attempts = 0;

    await outbox.drain(
      userId: 7,
      send: (_) async {
        attempts++;
        return const OutboxSendResult(OutboxDisposition.unreachable, error: 'Offline.');
      },
    );

    // One attempt, not three: the first failure closes the chain for this
    // pass, and the two behind it are not even tried.
    expect(attempts, 1);
    expect(await outbox.countFor(7), 3);
  });

  test('🔴 a 422 is recorded and the item is KEPT, never read as already-done', () async {
    await outbox.enqueue(
      userId: 7,
      method: 'PATCH',
      path: '/api/facility/work-orders/job-1/referral/confirm',
      body: null,
    );

    await outbox.drain(
      userId: 7,
      send: (_) async => const OutboxSendResult(
        OutboxDisposition.refused,
        error: 'Nothing has been referred on this work order.',
      ),
    );

    final item = (await outbox.pending(7)).single;

    // Phase 0 measured the exception that makes this rule load-bearing: a
    // referral changes no status, so this 422 means the action did NOT happen.
    expect(item.attempts, 1);
    expect(item.lastError, 'Nothing has been referred on this work order.');
  });

  test('a 401 stops the drain ENTIRELY — across every job — and costs the item nothing', () async {
    await queueThree(7);
    await outbox.enqueue(
      userId: 7,
      jobId: 'job-2',
      method: 'PATCH',
      path: '/api/facility/work-orders/job-2/start',
    );

    final report = await outbox.drain(
      userId: 7,
      send: (_) async => const OutboxSendResult(OutboxDisposition.sessionExpired),
    );

    expect(report.sent, 0);
    expect(report.stoppedBy, OutboxDisposition.sessionExpired);
    // 🔴 Not a stalled chain: the token is finished, so NO job can make
    // progress. A per-job stall would have tried job-2 as well.
    expect(report.stalledJobs, isEmpty);

    final queue = await outbox.pending(7);

    expect(queue, hasLength(4));
    // ⚠️ The session ended; the work did not. No attempt is counted against
    // an item the server never judged.
    expect(queue.first.attempts, 0);
    expect(queue.first.lastError, isNull);
  });

  test('being offline keeps everything and counts the attempt', () async {
    await queueThree(7);

    final report = await outbox.drain(
      userId: 7,
      send: (_) async => const OutboxSendResult(
        OutboxDisposition.unreachable,
        error: 'Could not reach the server.',
      ),
    );

    expect(report.sent, 0);
    expect(report.stoppedBy, OutboxDisposition.unreachable);
    expect(await outbox.countFor(7), 3);
  });

  test('🔴 another user\'s queued work is NOT sent under this session', () async {
    await queueThree(7);

    var called = false;

    final report = await outbox.drain(
      userId: 8,
      send: (_) async {
        called = true;
        return const OutboxSendResult(OutboxDisposition.sent);
      },
    );

    // 🎯 Draining technician 7's completion with technician 8's token would
    // attribute 7's work to 8 in the ERP — a silent falsification, worse than
    // losing it.
    expect(called, isFalse);
    expect(report.sent, 0);
    expect(await outbox.countFor(7), 3);
  });

  test('🔴 a queued item survives closing and reopening the database', () async {
    // A real file, because an in-memory database cannot prove durability —
    // the whole point of the queue is that an interruption loses nothing.
    final directory = await Directory.systemTemp.createTemp('sandan_outbox_test');
    final path = '${directory.path}/outbox.db';

    final first = LocalDatabase(factory: databaseFactoryFfi, path: path);
    await Outbox(first).enqueue(
      userId: 7,
      jobId: 'job-1',
      method: 'PATCH',
      path: '/api/facility/work-orders/job-1/complete',
      body: {'notes': 'Done in the basement, no signal.'},
    );
    await first.close();

    final second = LocalDatabase(factory: databaseFactoryFfi, path: path);
    final survivor = (await Outbox(second).pending(7)).single;

    expect(survivor.path, '/api/facility/work-orders/job-1/complete');
    expect(survivor.body, {'notes': 'Done in the basement, no signal.'});
    expect(survivor.jobId, 'job-1');

    await second.close();
    await directory.delete(recursive: true);
  });
}
