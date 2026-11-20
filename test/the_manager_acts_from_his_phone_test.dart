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

/// SPEC-024 Phase 5, Step 2 — the Facility Manager performs his five from the
/// phone.
///
/// 🔴 **The gap:** the web carried fourteen work-order acts and the API nine,
/// and the five missing were all his. He could read every job in Sandan on
/// this phone and resolve none of them.
///
/// 🔴🔴 **And none of the five is queued offline — asserted, not merely
/// stated.** D3's one-path rule is right for a technician in a basement: the
/// act records what HE just did and a minute's delay changes nothing. A
/// manager's act is a judgement about a job's STATE, and a judgement drained
/// four hours later lands on a job that has moved — verifying work that was
/// reopened since, or cancelling one a tenant has already had done.
void main() {
  sqfliteFfiInit();

  // ───────────────────── the wire: what is sent, and whether ─────────────

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

    test('✅ each of the five sends the right method, path and body', () async {
      final repo = repository();

      await repo.verify('job-1');
      await repo.close('job-1');
      await repo.cancel('job-1', 'Reported twice.');
      await repo.reject('job-1', 'Needs the electrical team.');
      await repo.decideExtension('job-1', approved: true, note: 'Access delay is real.');

      expect(sent.map((r) => '${r.method} ${r.url.path}').toList(), [
        'PATCH /api/facility/work-orders/job-1/verify',
        'PATCH /api/facility/work-orders/job-1/close',
        'PATCH /api/facility/work-orders/job-1/cancel',
        'PATCH /api/facility/work-orders/job-1/reject',
        'PATCH /api/facility/work-orders/job-1/extension/decide',
      ]);

      expect(jsonDecode(sent[2].body), {'reason': 'Reported twice.'});
      expect(jsonDecode(sent[3].body), {'reason': 'Needs the electrical team.'});
      expect(jsonDecode(sent[4].body), {'approved': true, 'note': 'Access delay is real.'});
    });

    test('⚠️ a grant with no note omits the key entirely rather than sending an empty one', () async {
      // The server validates `note` as nullable, so an empty string would
      // pass — and would record that the manager wrote nothing, which is not
      // the same as his having written nothing.
      final repo = repository();

      await repo.decideExtension('job-1', approved: true);
      await repo.decideExtension('job-1', approved: false, note: '   ');

      expect(jsonDecode(sent[0].body), {'approved': true});
      expect(jsonDecode(sent[1].body), {'approved': false});
    });

    test('🔴🔴 a manager act NEVER reaches the outbox — read before and after', () async {
      final repo = repository();

      expect(await outbox.countFor(userId), 0);

      await repo.verify('job-1');
      await repo.cancel('job-1', 'Duplicate.');
      await repo.decideExtension('job-1', approved: false, note: 'Not reasonable.');

      expect(await outbox.countFor(userId), 0);
    });

    test('🔴 and it stays empty when the SERVER REFUSES, which is where a queue would be tempting', () async {
      final repo = repository(status: 422, body: {
        'message': 'Work has already started on this job.',
        'errors': {
          'reason': ['Work has already started on this job; it can be completed or left open, but not cancelled.'],
        },
      });

      final result = await repo.cancel('job-1', 'Changed our minds.');

      expect(result.outcome, ActOutcome.refused);
      // 🔴 The SERVER's sentence, carried through unchanged.
      expect(result.message, contains('Work has already started'));
      expect(await outbox.countFor(userId), 0);
    });

    test('🔴 an UNREACHABLE server is a refusal, never "recorded on this phone"', () async {
      // ⚠️ `pending` means *this phone is holding it for you*. Nothing is
      // holding anything here, and telling a manager his cancellation was
      // recorded when it will never be sent is the worst answer the app
      // could give.
      final repo = WorkOrderRepository(
        userId: userId,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((_) async => throw const SocketLikeFailure()),
        ),
      );

      final result = await repo.verify('job-1');

      expect(result.outcome, ActOutcome.refused);
      expect(result.outcome, isNot(ActOutcome.pending));
      expect(await outbox.countFor(userId), 0);
    });

    test('✅ a successful act upserts THAT ROW and leaves the rest of the cache alone', () async {
      await store.replaceFor(userId, [
        WorkOrder.fromJson(workOrderJson(id: 'job-1')),
        WorkOrder.fromJson(workOrderJson(id: 'job-2')),
      ], syncedAt: DateTime.utc(2026, 11, 19, 9));

      await repository().verify('job-1');

      // 🔴 An upsert of one row, never `replaceFor()` — which opens with
      // `DELETE … WHERE user_id = ?` and would take `job-2` with it.
      expect((await store.rowsFor(userId)).map((j) => j.id).toSet(), {'job-1', 'job-2'});
    });
  });

  // ───────────────────── the screen: the dialogs ruling 4 asked for ───────

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
        syncedAt: DateTime(2026, 11, 19, 9),
      ));

      await tester.pumpWidget(MaterialApp(
        home: WorkOrderScreen(id: 'job-1', repository: source, onSessionExpired: () {}),
      ));

      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('✅ verify and close are a single tap, with no dialog', (tester) async {
      await pump(tester, [act('verify', 'Verify the work')]);

      await tester.tap(find.widgetWithText(FilledButton, 'Verify the work'));
      await tester.pump();

      expect(source.calls, ['verify:job-1']);
    });

    testWidgets('🔴 cancel ASKS for a reason, and sends nothing when none is given', (tester) async {
      await pump(tester, [act('cancel', 'Cancel the work order')]);

      await tester.tap(find.widgetWithText(FilledButton, 'Cancel the work order'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('act-reason-field')), findsOneWidget);

      await tester.tap(find.byKey(const Key('act-reason-dismiss')));
      await tester.pump(const Duration(milliseconds: 400));

      // 🎯 Dismissed is not cancelled. Nothing was sent.
      expect(source.calls, isEmpty);
    });

    testWidgets('✅ cancel sends the typed reason', (tester) async {
      await pump(tester, [act('cancel', 'Cancel the work order')]);

      await tester.tap(find.widgetWithText(FilledButton, 'Cancel the work order'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.enterText(find.byKey(const Key('act-reason-field')), 'Reported twice.');
      await tester.tap(find.byKey(const Key('act-reason-confirm')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['cancel:job-1:Reported twice.']);
    });

    testWidgets('✅ reject asks the same way and sends through its own method', (tester) async {
      await pump(tester, [act('reject', 'Hand the job back')]);

      await tester.tap(find.widgetWithText(FilledButton, 'Hand the job back'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.enterText(find.byKey(const Key('act-reason-field')), 'Wrong trade.');
      await tester.tap(find.byKey(const Key('act-reason-confirm')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['reject:job-1:Wrong trade.']);
    });

    testWidgets('🔴 decide_extension opens a TWO-FIELD dialog on the detail screen (ruling 4)', (tester) async {
      await pump(tester, [act('decide_extension', 'Decide the request for more time')]);

      await tester.tap(find.widgetWithText(FilledButton, 'Decide the request for more time'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('extension-note-field')), findsOneWidget);
      expect(find.byKey(const Key('extension-grant')), findsOneWidget);
      expect(find.byKey(const Key('extension-refuse')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('extension-note-field')), 'The access delay is real.');
      await tester.tap(find.byKey(const Key('extension-grant')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['decide:job-1:true:The access delay is real.']);
    });

    testWidgets('🔴 REFUSE is disabled until a note is typed, because the DOMAIN refuses a blank one', (tester) async {
      await pump(tester, [act('decide_extension', 'Decide the request for more time')]);

      await tester.tap(find.widgetWithText(FilledButton, 'Decide the request for more time'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester.widget<TextButton>(find.byKey(const Key('extension-refuse'))).onPressed,
        isNull,
      );

      // ✅ A GRANT needs no note, and is pressable from the start.
      expect(
        tester.widget<TextButton>(find.byKey(const Key('extension-grant'))).onPressed,
        isNotNull,
      );

      await tester.enterText(find.byKey(const Key('extension-note-field')), 'Not reasonable.');
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester.widget<TextButton>(find.byKey(const Key('extension-refuse'))).onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(const Key('extension-refuse')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['decide:job-1:false:Not reasonable.']);
    });

    testWidgets('🎯 a refused manager act is still DRAWN, disabled, with the server\'s sentence', (tester) async {
      // 🔴 Ruling 3's deliverable on the client: the act is never omitted.
      // A button that disappears tells the manager nothing; a greyed one
      // with a reason tells him what to do instead.
      await pump(tester, [
        act('cancel', 'Cancel the work order',
            allowed: false,
            reason: 'Work has already started on this job; it can be completed or left open, but not cancelled.'),
      ]);

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Cancel the work order'),
      );

      expect(button.onPressed, isNull);
      expect(find.textContaining('it can be completed or left open'), findsOneWidget);
    });

    testWidgets('⚠️ a MIXED set still disables what this build cannot do', (tester) async {
      // The manager's five are implemented and the technician's four are
      // not, so `implementedActs` is now a mixed list — which is correct,
      // because these sets describe the BUILD and never a role. This
      // exercises Step 0's detector against that mixture.
      // 🔧 **2026-11-20, SPEC-037: the mixture is now the other way round.**
      // When this was written the manager's five were built and the
      // technician's four were not. Phase 1 built three of those four, so the
      // example moved to `request_materials` — the one act left. The point of
      // the test is unchanged: `implementedActs` describes the BUILD and never
      // a role, so a payload mixing a built act with an unbuilt one must
      // enable exactly one button.
      await pump(tester, [
        act('verify', 'Verify the work'),
        act('request_materials', 'Ask for parts'),
      ]);

      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Verify the work')).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Ask for parts')).onPressed,
        isNull,
      );
    });
  });
}

/// A failure that is not an HTTP response — the shape an unreachable server
/// takes inside `MockClient`.
class SocketLikeFailure implements Exception {
  const SocketLikeFailure();
}
