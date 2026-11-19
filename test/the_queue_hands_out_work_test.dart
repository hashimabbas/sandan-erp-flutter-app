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
import 'package:sandan_facility_app/services/complaint_service.dart';
import 'package:sandan_facility_app/services/api_result.dart';
import 'package:sandan_facility_app/services/facility_session.dart';
import 'package:sandan_facility_app/services/work_order_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_work_order_source.dart';
import 'support/work_order_payload.dart';

/// SPEC-024 Phase 5, Step 3 — **handing a job to somebody, from the one
/// sender.**
///
/// 🔧 **Three of these tests MOVED here from `assignee_picker_test.dart`.**
/// They proved `ComplaintService.assignWorkOrder()`, which shipped with
/// SPEC-025 Step 6 and was this app's only way to assign. Step 3 needed the
/// same PATCH from the work-order screen, and two senders for one endpoint is
/// the drift D3 argues against — so the weaker one was deleted. It reported
/// success **without touching the cache**, so a job assigned from the phone
/// went on being cached as unassigned until the next full refresh.
///
/// 🔴 **The fourth test is the one the old sender could not have had:** the
/// outbox is never touched. An assignment is a manager's judgement about the
/// present, exactly like his other five acts (ADR-022), and one drained four
/// hours later would land on a job that has moved.
void main() {
  sqfliteFfiInit();

  group('the wire', () {
    late LocalDatabase database;
    late WorkOrderStore store;
    late Outbox outbox;

    const userId = 3;

    setUp(() {
      database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      store = WorkOrderStore(database);
      outbox = Outbox(database);
    });

    tearDown(() => database.close());

    late List<http.Request> sent;

    WorkOrderRepository repository({int status = 200, Object? body}) {
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
              jsonEncode(body ?? {'data': workOrderJson(id: 'job-1')}),
              status,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
    }

    test('✅ assigns an existing job: the method, the path and the body', () async {
      final repo = repository();

      final result = await repo.assign('job-1', [9, 12]);

      expect(result.outcome, ActOutcome.applied);
      expect(sent.single.method, 'PATCH');
      expect(sent.single.url.path, endsWith('/api/facility/work-orders/job-1/assign'));
      expect(jsonDecode(sent.single.body), {'technician_ids': [9, 12]});
    });

    test("🔴 surfaces the server's own refusal, word for word", () async {
      // ⚠️ The sentence is the lifecycle's, and since Step 3 the endpoint
      // throws exactly what the button's `reason` carries — so a manager who
      // presses anyway reads the same words twice rather than two different
      // explanations of one rule.
      final repo = repository(status: 422, body: {
        'message': 'The given data was invalid.',
        'errors': {
          'technician_ids': [
            'This job cannot be handed to anybody else: work has started, so the only exits are completion or waiting for parts (Q5).',
          ],
        },
      });

      final result = await repo.assign('job-1', [9]);

      expect(result.outcome, ActOutcome.refused);
      expect(result.message, contains('cannot be handed to anybody else'));
    });

    test('🔴 an UNREACHABLE server is a refusal, never "recorded on this phone"', () async {
      final repo = WorkOrderRepository(
        userId: userId,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((_) async => throw http.ClientException('no network')),
        ),
      );

      final result = await repo.assign('job-1', [9]);

      expect(result.outcome, ActOutcome.refused);
      expect(result.outcome, isNot(ActOutcome.pending));
    });

    test('🔴🔴 assigning NEVER reaches the outbox — read before, after, and after a refusal', () async {
      expect(await outbox.countFor(userId), 0);

      await repository().assign('job-1', [9]);

      expect(await outbox.countFor(userId), 0);

      await repository(status: 422, body: {
        'message': 'The given data was invalid.',
        'errors': {'technician_ids': ['Work has already started on this job.']},
      }).assign('job-1', [9]);

      // 🔴 A refusal is where a queue would be tempting, and it is exactly
      // where it would be wrong: a manager told his assignment was "recorded"
      // when it will never be sent is the worst answer this app could give.
      expect(await outbox.countFor(userId), 0);
    });

    test('✅ a successful assignment upserts THAT ROW and leaves the rest of the cache alone', () async {
      // 🎯 The capability the deleted sender did not have. It returned
      // success and wrote nothing, so the phone went on showing the job as
      // unassigned until a full refresh.
      await store.replaceFor(userId, [
        WorkOrder.fromJson(workOrderJson(id: 'job-1')),
        WorkOrder.fromJson(workOrderJson(id: 'job-2')),
      ], syncedAt: DateTime.utc(2026, 11, 19, 9));

      await repository().assign('job-1', [9]);

      // Never `replaceFor()`, which opens with `DELETE … WHERE user_id = ?`
      // and would take `job-2` with it.
      expect((await store.rowsFor(userId)).map((j) => j.id).toSet(), {'job-1', 'job-2'});
    });
  });

  // ───────────────────── the screen: who takes it ─────────────────────────

  group('the screen', () {
    late FakeWorkOrderSource source;
    late List<Uri> looked;

    setUp(() {
      source = FakeWorkOrderSource();
      looked = <Uri>[];
    });

    ComplaintService lookup({List<Map<String, dynamic>>? people, String? jobTrade}) =>
        ComplaintService(
          session: FacilitySession(),
          client: MockClient((request) async {
            looked.add(request.url);

            return http.Response(
              jsonEncode({
                'data': people ??
                    [
                      {'id': 7, 'name': 'Fathi Al-Balushi', 'role': 'technician', 'trades': ['electrical'], 'matches_trade': true},
                      {'id': 9, 'name': 'Salim Al-Hinai', 'role': 'technician', 'trades': ['plumbing'], 'matches_trade': false},
                    ],
                'job_trade': jobTrade,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

    /// The job carries ONE technician already — `workOrderJson` gives it
    /// Fathi, id 7 — which is what makes the pre-selection assertable.
    Future<void> pump(WidgetTester tester, {ComplaintService? service}) async {
      source.detail = ApiSuccess(Cached(
        WorkOrder.fromJson({
          ...workOrderJson(id: 'job-1'),
          'category_id': 'cat-electrical',
          'actions': [
            {'value': 'assign', 'label': 'Hand the job to somebody', 'allowed': true, 'reason': null},
          ],
        }),
        source: WorkSource.network,
        syncedAt: DateTime(2026, 11, 19, 9),
      ));

      await tester.pumpWidget(MaterialApp(
        home: WorkOrderScreen(
          id: 'job-1',
          repository: source,
          onSessionExpired: () {},
          service: service ?? lookup(),
        ),
      ));

      // ⚠️ NEVER `pumpAndSettle()` on this screen: `AnimatedGradientBackground`
      // animates forever and it never returns — which presents as *"the sheet
      // never opens"*.
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Hand the job to somebody'));
      await tester.pump(const Duration(milliseconds: 400));

      // 🔧 **`runAsync` is required and was not obvious.** The staff lookup
      // is REAL async work — `MockClient` plus a secure-storage read that has
      // no platform channel under `flutter test` — and fake-time pumps do not
      // let it complete. Without this the sheet opens with an empty list and
      // the failure reads *"Found 0 widgets with text Salim Al-Hinai"*, which
      // looks like a picker defect and is a test-harness one.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));

      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('🔴 the sheet PRE-SELECTS the men already on the job', (tester) async {
      // 🎯 Proved by what is SENT, not by a tick mark: adding Salim sends
      // Fathi too. The server adds and never removes, so a picker that opened
      // empty would let a manager believe he had replaced somebody.
      await pump(tester);
      await openSheet(tester);

      await tester.tap(find.text('Salim Al-Hinai'));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const Key('assign-confirm')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['assign:job-1:7,9']);
    });

    testWidgets('🔴 and it says out loud what it cannot do', (tester) async {
      await pump(tester);
      await openSheet(tester);

      expect(find.byKey(const Key('assign-adds-only-notice')), findsOneWidget);
      expect(find.text('Adding somebody does not take anybody off this job.'), findsOneWidget);
    });

    testWidgets('⚠️ Assign is DISABLED while the choice would change nothing', (tester) async {
      // Re-sending exactly the men already on the job asserts nothing, and an
      // empty list is refused by the server's own `min:1`.
      await pump(tester);
      await openSheet(tester);

      expect(
        tester.widget<TextButton>(find.byKey(const Key('assign-confirm'))).onPressed,
        isNull,
      );

      await tester.tap(find.text('Salim Al-Hinai'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        tester.widget<TextButton>(find.byKey(const Key('assign-confirm'))).onPressed,
        isNotNull,
      );
    });

    testWidgets('🎯 dismissing the sheet sends nothing', (tester) async {
      await pump(tester);
      await openSheet(tester);

      await tester.tap(find.byKey(const Key('assign-dismiss')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, isEmpty);
    });

    testWidgets("✅ the job's CATEGORY is asked about, so the picker can mark the trade", (tester) async {
      // SPEC-025: the filter informs, never constrains. It could not be asked
      // at all until Step 3 put `category_id` in the payload — the name alone
      // cannot be a query.
      await pump(tester);
      await openSheet(tester);

      expect(looked.single.path, endsWith('/api/facility/complaints/lookup/assignees'));
      expect(looked.single.queryParameters['category_id'], 'cat-electrical');
    });

    testWidgets("🔴 a refusal shows the SERVER's sentence, not one written here", (tester) async {
      source.result = const ActResult(
        ActOutcome.refused,
        message: 'This job cannot be handed to anybody else: work has started, so the only exits are completion or waiting for parts (Q5).',
      );

      await pump(tester);
      await openSheet(tester);

      await tester.tap(find.text('Salim Al-Hinai'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('assign-confirm')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('cannot be handed to anybody else'), findsOneWidget);
    });
  });
}
