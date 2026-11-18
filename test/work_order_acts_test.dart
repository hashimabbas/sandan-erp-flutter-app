import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/data/local_database.dart';
import 'package:sandan_facility_app/data/outbox.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/data/work_order_store.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/services/facility_session.dart';
import 'package:sandan_facility_app/services/work_order_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/work_order_payload.dart';

/// SPEC-024 Phase 3, Step 4 — the acts, end to end through the queue.
///
/// 🔴 **Every act is queued first and sent immediately after (D3).** There is
/// no "send directly when online" path: two paths mean two behaviours and the
/// rare one rots unexercised — which matters *more* now that the aeroplane-mode
/// device run is deferred and having no signal is said to be rare. With one
/// path, the queue is exercised by every act every technician performs.
void main() {
  sqfliteFfiInit();

  late LocalDatabase database;
  late WorkOrderStore store;
  late Outbox outbox;

  setUp(() {
    database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    store = WorkOrderStore(database);
    outbox = Outbox(database);
  });

  tearDown(() => database.close());

  /// Records what the app actually sent, because half of what Phase 3 can get
  /// wrong is the shape of the request.
  final sent = <http.BaseRequest>[];

  WorkOrderRepository repository(
    Future<http.Response> Function(http.Request request) respond,
  ) =>
      WorkOrderRepository(
        userId: 7,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((request) async {
            sent.add(request);

            return respond(request);
          }),
        ),
        clock: () => DateTime.utc(2026, 10, 28, 9),
      );

  http.Response ok(Map<String, dynamic> data, {int status = 200}) => http.Response(
        jsonEncode({'data': data}),
        status,
        headers: {'content-type': 'application/json'},
      );

  http.Response refusal(String field, String message) => http.Response(
        jsonEncode({
          'message': message,
          'errors': {
            field: [message],
          },
        }),
        422,
        headers: {'content-type': 'application/json'},
      );

  WorkOrderRepository unreachable() => WorkOrderRepository(
        userId: 7,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((_) async => throw http.ClientException('offline')),
        ),
      );

  setUp(sent.clear);

  group('a transition', () {
    test('✅ applies, and the CACHE takes the server\'s fresh row', () async {
      await store.replaceFor(
        7,
        [WorkOrder.fromJson(workOrderJson(id: 'job-1'))],
        syncedAt: DateTime.utc(2026, 10, 28, 8),
      );

      final result = await repository(
        (_) async => ok(workOrderJson(id: 'job-1', description: 'Started.')),
      ).start('job-1');

      expect(result.outcome, ActOutcome.applied);
      expect(result.job?.description, 'Started.');

      // 🎯 The status changed because the SERVER said so. Every transition
      // answers with the fresh work order, so this costs no extra request.
      expect((await store.rowFor(7, 'job-1'))?.description, 'Started.');

      // Nothing left behind in the queue.
      expect(await outbox.countFor(7), 0);
    });

    test('sends the right method and path', () async {
      await repository((_) async => ok(workOrderJson())).complete('job-9');

      expect(sent.single.method, 'PATCH');
      expect(sent.single.url.path, '/api/facility/work-orders/job-9/complete');
    });

    test('🔴 refer sends `referred_to`, the field the server actually has', () async {
      await repository((_) async => ok(workOrderJson())).refer('job-1', 'Al Sahwa Plumbing');

      final body = jsonDecode((sent.single as http.Request).body) as Map<String, dynamic>;

      // ⚠️ A Phase 2 fixture used `provider`, which the server has never had:
      // it would have answered 422 on a field that does not exist.
      expect(body, {'referred_to': 'Al Sahwa Plumbing'});
      expect(sent.single.url.path, endsWith('/refer'));
    });

    test('confirmReferral posts to the referral path', () async {
      await repository((_) async => ok(workOrderJson())).confirmReferral('job-1');

      expect(sent.single.url.path, endsWith('/referral/confirm'));
    });
  });

  group('when the act cannot go through', () {
    test('🎯 offline, the act is PENDING — recorded here, not sent', () async {
      final result = await unreachable().complete('job-1');

      expect(result.outcome, ActOutcome.pending);
      expect(result.message, contains('not yet sent'));

      // 🔴 The work exists nowhere else, so it stays in the queue — with its
      // job, so the per-job ordering rule can hold.
      final queued = (await outbox.pending(7)).single;

      expect(queued.jobId, 'job-1');
      expect(queued.path, endsWith('/complete'));
    });

    test('🔴 a 422 is shown in the SERVER\'s words and the item is kept', () async {
      final result = await repository(
        (_) async => refusal('status', 'This work order has not been started.'),
      ).complete('job-1');

      expect(result.outcome, ActOutcome.refused);
      expect(result.message, 'This work order has not been started.');

      // Phase 2's rule, unchanged: a 422 never means *already done*. What
      // changes is that the technician is told why.
      final kept = (await outbox.pending(7)).single;

      expect(kept.attempts, 1);
      expect(kept.lastError, 'This work order has not been started.');
    });

    test('🔴 a 403 evicts the cached row — the same rule the read path follows', () async {
      await store.replaceFor(
        7,
        [WorkOrder.fromJson(workOrderJson(id: 'job-1'))],
        syncedAt: DateTime.utc(2026, 10, 28, 8),
      );

      final result = await repository(
        (_) async => http.Response('{"message":"Forbidden."}', 403),
      ).start('job-1');

      expect(result.outcome, ActOutcome.refused);
      // The server has just said the job is not his.
      expect(await store.rowFor(7, 'job-1'), isNull);
    });

    test('a replayed act on an already-started job is ACCEPTED, not refused', () async {
      // Phase 0 settled this: a transition replayed to its target state
      // answers 200 with the current state, so a lost reply costs nothing.
      final result = await repository((_) async => ok(workOrderJson(id: 'job-1'))).start('job-1');

      expect(result.outcome, ActOutcome.applied);
      expect(await outbox.countFor(7), 0);
    });
  });

  group('the queue a technician is carrying', () {
    test('counts what is waiting, and names the jobs', () async {
      await unreachable().complete('job-1');
      await unreachable().start('job-2');

      final repo = unreachable();

      expect(await repo.pendingCount(), 2);
      expect(await repo.pendingJobIds(), {'job-1', 'job-2'});
    });

    test('🔴 one stuck job does not hold up another — the whole of D4', () async {
      // job-1's completion will be refused for ever; job-2's start is fine.
      await unreachable().complete('job-1');

      final result = await repository((request) async =>
              request.url.path.contains('job-1')
                  ? refusal('status', 'Not started.')
                  : ok(workOrderJson(id: 'job-2')))
          .start('job-2');

      // 🎯 job-2 went through even though job-1 was stuck in front of it. With
      // Phase 2's global rule a technician's whole afternoon sat behind one
      // refusal he might not be able to resolve.
      expect(result.outcome, ActOutcome.applied);
      expect(
        (await outbox.pending(7)).map((item) => item.jobId).toSet(),
        {'job-1'},
      );
    });
  });

  group('the photograph', () {
    test('is sent as MULTIPART with its stage and the capture time', () async {
      final result = await repository((_) async => ok({'id': 'ev-1'}, status: 201)).uploadEvidence(
        'job-1',
        filePath: await _tempPhoto(),
        stage: 'after',
        capturedAt: DateTime.utc(2026, 10, 28, 8, 15),
      );

      expect(result.outcome, ActOutcome.applied);

      final request = sent.single as http.Request;

      expect(request.method, 'POST');
      expect(request.url.path, endsWith('/evidence'));

      // ⚠️ `MockClient` hands the handler a FLATTENED request, so the type is
      // `Request` even for a multipart send — the proof is the content type
      // and the encoded parts, not the Dart class.
      expect(request.headers['content-type'], startsWith('multipart/form-data'));

      final body = request.body;

      expect(body, contains('name="photo"'));
      expect(body, contains('name="stage"'));
      expect(body, contains('after'));
      // 🎯 The gap between capture and arrival is real once there is a queue,
      // and the server keeps the two timestamps apart on purpose.
      expect(body, contains('name="device_captured_at"'));
      expect(body, contains('2026-10-28T08:15:00.000Z'));
      // ⚠️ Deliberately absent: the server stores it as a claim it never
      // trusts, so inventing one would add a dependency and no truth.
      expect(body, isNot(contains('device_identifier')));
    });

    test('🔴 once the server has it, the FILE is deleted with the queue row', () async {
      final path = await _tempPhoto();

      await repository((_) async => ok({'id': 'ev-1'}, status: 201))
          .uploadEvidence('job-1', filePath: path, stage: 'after');

      // 🔴 No outbox row is removed without its file — otherwise the phone
      // fills up with photographs of jobs that closed weeks ago.
      expect(await File(path).exists(), isFalse);
      expect(await outbox.countFor(7), 0);
    });

    test('offline, it waits with its FILE PATH, not its bytes', () async {
      final path = await _tempPhoto();

      final result = await unreachable().uploadEvidence('job-1', filePath: path, stage: 'before');

      expect(result.outcome, ActOutcome.pending);

      final queued = (await outbox.pending(7)).single;

      // 🔴 On disk, with the item holding the path — a 5 MB image has no
      // business in a JSON column.
      expect(queued.filePath, path);
      expect(queued.fileField, 'photo');
      expect(queued.body, {'stage': 'before'});
    });
  });
}

/// A real file on disk, because a queued photograph is a path and a path that
/// points at nothing is a photograph silently lost.
Future<String> _tempPhoto() async {
  final directory = await Directory.systemTemp.createTemp('sandan_photo_test');
  final file = File('${directory.path}/work.jpg');

  await file.writeAsBytes(List<int>.filled(64, 0));

  return file.path;
}
