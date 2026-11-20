import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/data/local_database.dart';
import 'package:sandan_facility_app/data/outbox.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/data/work_order_store.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/screens/work_order_screen.dart';
import 'package:sandan_facility_app/services/api_result.dart';
import 'package:sandan_facility_app/services/facility_session.dart';
import 'package:sandan_facility_app/services/work_order_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_work_order_source.dart';
import 'support/work_order_payload.dart';

/// SPEC-037 Phase 1 — the three acts of the man standing in the room.
///
/// 🎯 **They are QUEUED, and that is the opposite call to the manager's
/// five.** A manager's judgement drained hours later lands on a job that has
/// moved, so his acts are sent once or refused. An interruption drained hours
/// later is a **record of what happened** — which is what the queue is for.
/// The two groups look alike, and the reason they differ is the direction of
/// time: one decides the present, the other reports the past (ADR-022).
///
/// ⚠️ **The server requires a stated cause for both forms**: `reason` for a
/// pause, and `minutes` AND `reason` for a request for time. The Impact
/// Analysis described half of the second one, and the Plan corrected it before
/// a one-field sheet could meet a 422 the app could have answered itself.
void main() {
  sqfliteFfiInit();

  group('the wire', () {
    late LocalDatabase database;
    late WorkOrderStore store;
    late Outbox outbox;

    const userId = 7;

    setUp(() {
      database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      store = WorkOrderStore(database);
      outbox = Outbox(database);
    });

    tearDown(() => database.close());

    late List<http.Request> sent;

    WorkOrderRepository repository() {
      sent = <http.Request>[];

      return WorkOrderRepository(
        userId: userId,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((request) async {
            sent.add(request);

            return http.Response(
              jsonEncode({'data': workOrderJson(id: 'job-1')}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
    }

    test('✅ sends each of the three to its own endpoint, with the fields the server requires', () async {
      final repo = repository();

      await repo.pause('job-1', 'Pulled onto a lift entrapment.');
      await repo.resume('job-1');
      await repo.requestExtension('job-1', minutes: 45, reason: 'The riser valve is seized.');

      expect(sent.map((r) => r.method).toList(), ['PATCH', 'PATCH', 'PATCH']);

      expect(sent[0].url.path, endsWith('/api/facility/work-orders/job-1/pause'));
      expect(jsonDecode(sent[0].body)['reason'], 'Pulled onto a lift entrapment.');

      expect(sent[1].url.path, endsWith('/api/facility/work-orders/job-1/resume'));

      // 🔴 **The suffix is `extension`, not the act's name
      // `request_extension`.** The route and the act disagree on purpose
      // (`routes/api.php:128`), and a mirrored name here would 404 — which is
      // exactly the mistake a reader of the `actions` payload would make.
      expect(sent[2].url.path, endsWith('/api/facility/work-orders/job-1/extension'));

      final extension = jsonDecode(sent[2].body) as Map<String, dynamic>;
      expect(extension['minutes'], 45);
      expect(extension['reason'], 'The riser valve is seized.');
    });

    test('🔴 holds all three on the phone when there is no signal — they are QUEUED, not sent once', () async {
      final repo = WorkOrderRepository(
        userId: userId,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((_) async => throw http.ClientException('offline')),
        ),
      );

      final outcomes = [
        await repo.pause('job-1', 'No signal in the basement.'),
        await repo.resume('job-1'),
        await repo.requestExtension('job-1', minutes: 30, reason: 'Still here.'),
      ].map((r) => r.outcome);

      // 🎯 **`pending` is the proof of the design decision.** The manager's
      // five answer `refused` when unreachable, because telling him his
      // cancellation is "recorded" when nothing will send it is the worst
      // answer the app could give. These three are the other case: the
      // interruption HAPPENED, and the phone is holding the record of it.
      expect(outcomes, everyElement(ActOutcome.pending));
      expect(await repo.pendingCount(), 3);
    });
  });

  // ───────────────────── the screen: what it asks before it sends ─────────

  group('the screen', () {
    late FakeWorkOrderSource source;

    setUp(() => source = FakeWorkOrderSource());

    Map<String, dynamic> act(String value, String label, {bool allowed = true, String? reason}) => {
          'value': value,
          'label': label,
          'allowed': allowed,
          'reason': reason,
        };

    Future<void> pump(WidgetTester tester, List<Map<String, dynamic>> actions) async {
      source.detail = ApiSuccess(Cached(
        WorkOrder.fromJson({...workOrderJson(id: 'job-1'), 'actions': actions}),
        source: WorkSource.network,
        syncedAt: DateTime(2026, 11, 20, 9),
      ));

      await tester.pumpWidget(MaterialApp(
        home: WorkOrderScreen(id: 'job-1', repository: source, onSessionExpired: () {}),
      ));

      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('🔴 pause ASKS why and sends nothing when nothing is typed, while resume is ONE TAP', (tester) async {
      await pump(tester, [act('pause', 'Pause work'), act('resume', 'Back to work')]);

      // 1️⃣ Stopping needs a stated cause — the server validates `reason` as
      // `required`, and a dismissed sheet must not send an empty one.
      await tester.tap(find.widgetWithText(FilledButton, 'Pause work'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('act-reason-dismiss')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, isEmpty);

      // 2️⃣ Typed, it goes with its words.
      await tester.tap(find.widgetWithText(FilledButton, 'Pause work'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byKey(const Key('act-reason-field')), 'Pulled onto a lift entrapment.');
      await tester.tap(find.byKey(const Key('act-reason-confirm')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['pause:job-1:Pulled onto a lift entrapment.']);

      // 3️⃣ 🎯 **Coming back is a single tap, like `arrive`.** There is
      // nothing to type to resume work, and a dialog asking him to explain
      // returning would be a form standing between a man and his job.
      await tester.tap(find.widgetWithText(FilledButton, 'Back to work'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls.last, 'resume:job-1');
    });

    testWidgets('🔴 the request for TIME needs both fields, and ASK stays disabled until both are there', (tester) async {
      await pump(tester, [act('request_extension', 'Ask for more time')]);

      await tester.tap(find.widgetWithText(FilledButton, 'Ask for more time'));
      await tester.pump(const Duration(milliseconds: 400));

      TextButton ask() => tester.widget<TextButton>(find.byKey(const Key('more-time-confirm')));

      // 1️⃣ Nothing typed: disabled.
      expect(ask().onPressed, isNull);

      // 2️⃣ Minutes alone: still disabled. 🔴 The server requires `reason`
      // too (`:329-331`), and the Impact Analysis described half this form.
      await tester.enterText(find.byKey(const Key('more-time-minutes-field')), '45');
      await tester.pump(const Duration(milliseconds: 400));
      expect(ask().onPressed, isNull);

      // 3️⃣ ⚠️ A figure outside the server's own sanity bound is refused
      // HERE, so the technician is never handed a 422 for a number this
      // screen could read. 1440 is a bound, not a business maximum.
      await tester.enterText(find.byKey(const Key('more-time-minutes-field')), '1441');
      await tester.enterText(find.byKey(const Key('more-time-reason-field')), 'The riser valve is seized.');
      await tester.pump(const Duration(milliseconds: 400));
      expect(ask().onPressed, isNull);

      // 4️⃣ Both answerable: it sends, with both fields.
      await tester.enterText(find.byKey(const Key('more-time-minutes-field')), '45');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('more-time-confirm')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['extension:job-1:45:The riser valve is seized.']);
    });
  });

  // ───────── the act that waited too long (SPEC-037 Plan Step 8) ──────────

  group('a STALE act', () {
    late LocalDatabase database;
    late WorkOrderStore store;
    late Outbox outbox;

    const userId = 7;

    setUp(() {
      database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      store = WorkOrderStore(database);
      outbox = Outbox(database);
    });

    tearDown(() => database.close());

    test('🔴 is reported as a REFUSAL in the server\'s own words, and moves NOTHING in the cache', () async {
      // 🔴🔴 **Hashim's second named test, 2026-11-20** — *"وألا نسمح لطلب
      // قديم بأن يعيد الحالة إلى وضع غير صحيح."* A pause typed in a basement
      // on Tuesday, drained on Thursday onto a job that has since been
      // completed. The server refuses it by STATUS (`refusalForPause`), and
      // the only question left is what the PHONE does with that answer.
      //
      // ⚠️ `pause` and deliberately not `resume`: a replayed resume finds the
      // job already `in_progress` and is answered 200 unchanged
      // (`FacilityWorkOrderWorkflowController:239`), so it would prove
      // nothing about staleness.
      final cached = WorkOrder.fromJson({
        ...workOrderJson(id: 'job-1'),
        'status': {'value': 'completed', 'label': 'Completed'},
      });

      await store.upsert(userId, cached);

      final repo = WorkOrderRepository(
        userId: userId,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((_) async => http.Response(
                jsonEncode({
                  'message': 'The given data was invalid.',
                  'errors': {
                    'status': ['Work has already been completed on this job.'],
                  },
                }),
                422,
                headers: {'content-type': 'application/json'},
              )),
        ),
      );

      final result = await repo.pause('job-1', 'Pulled onto a lift entrapment.');

      // 1️⃣ A refusal, never `pending`. `pending` means *this phone is
      // holding it for you*, and nothing is going to make this one succeed.
      expect(result.outcome, ActOutcome.refused);

      // 2️⃣ 🎯 **In the SERVER's words, not the app's.** The technician is
      // told what actually happened to the job — the sentence is the whole
      // reason a 422 is distinguishable from everything else.
      expect(result.message, 'Work has already been completed on this job.');

      // 3️⃣ 🔴 **And the cached row did not move.** An app that advanced its
      // own copy on a hopeful press would show a paused job the server calls
      // completed — the stale act's real damage, and the thing Hashim's
      // sentence asks about.
      expect((await store.rowFor(userId, 'job-1'))!.status.value, 'completed');

      // 4️⃣ ⚠️ **A pre-existing behaviour this phase does NOT change**, and a
      // finding records it: the refused item STAYS queued with its error, and
      // `Outbox.drain` adds its job to `stalled` — so this job's chain is
      // blocked until something removes the item. That is the offline
      // contract's rule for every act, not SPEC-037's doing, and changing a
      // disposition rule needs its own gate.
      expect(await repo.pendingCount(), 1);
    });
  });
}
