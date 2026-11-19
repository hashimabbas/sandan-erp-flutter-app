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

/// SPEC-034 — the technician says he is on site, from the phone.
///
/// 🔴🔴 **The act carries the instant it was taken, and that is the whole
/// feature.** It is queued, because a technician's act records the PAST
/// (ADR-022) — so it drains when the signal returns, perhaps hours later. If
/// the server stamped its own clock then, it would record the man as arriving
/// however long the basement had no signal, and the arrival deadline is
/// measured in **minutes**: the figure this Spec exists to make honest would
/// have been manufactured out of a building's reception.
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

    WorkOrderRepository repository({int status = 200}) {
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
              status,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
    }

    test('✅ sends the arrival with the instant it was taken, in UTC', () async {
      final at = DateTime.utc(2026, 11, 19, 9, 12);

      await repository().arrive('job-1', at: at);

      expect(sent.single.method, 'PATCH');
      expect(sent.single.url.path, endsWith('/api/facility/work-orders/job-1/arrive'));
      expect(jsonDecode(sent.single.body)['arrived_at'], at.toIso8601String());
    });

    test('🔴 it is QUEUED — unlike the manager\'s acts', () async {
      // ADR-022's line: a technician's act records the past, so it may wait.
      // A manager's is a judgement about the present, so it may not.
      final repo = WorkOrderRepository(
        userId: userId,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((_) async => throw http.ClientException('no network')),
        ),
      );

      final result = await repo.arrive('job-1', at: DateTime.utc(2026, 11, 19, 9, 12));

      expect(result.outcome, ActOutcome.pending);
      expect(await outbox.countFor(userId), 1);
    });

    test('🔴🔴 the queued copy keeps the ORIGINAL instant, not the drain time', () async {
      // The point of the whole Spec on the client side: a drain three hours
      // later must still report 09:12.
      final at = DateTime.utc(2026, 11, 19, 9, 12);

      final offline = WorkOrderRepository(
        userId: userId,
        store: store,
        outbox: outbox,
        service: WorkOrderService(
          session: FacilitySession(),
          client: MockClient((_) async => throw http.ClientException('no network')),
        ),
      );

      await offline.arrive('job-1', at: at);

      final queued = await outbox.pending(userId);

      // ⚠️ `OutboxItem.body` is already decoded — the row holds the JSON,
      // the item holds the map.
      expect(queued.single.body!['arrived_at'], at.toIso8601String());
    });
  });

  group('the screen', () {
    late FakeWorkOrderSource source;

    setUp(() => source = FakeWorkOrderSource());

    testWidgets('✅ "I\'m on site" is a single tap, with no dialog', (tester) async {
      source.detail = ApiSuccess(Cached(
        WorkOrder.fromJson({
          ...workOrderJson(id: 'job-1'),
          'actions': [
            {'value': 'arrive', 'label': "I'm on site", 'allowed': true, 'reason': null},
          ],
        }),
        source: WorkSource.network,
        syncedAt: DateTime(2026, 11, 19, 9),
      ));

      await tester.pumpWidget(MaterialApp(
        home: WorkOrderScreen(id: 'job-1', repository: source, onSessionExpired: () {}),
      ));

      // ⚠️ Never pumpAndSettle on this screen: the gradient animates for ever.
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.widgetWithText(FilledButton, "I'm on site"));
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['arrive:job-1']);
    });

    testWidgets('🔴 the button is drawn from the SERVER\'s answer, disabled with its reason', (tester) async {
      source.detail = ApiSuccess(Cached(
        WorkOrder.fromJson({
          ...workOrderJson(id: 'job-1'),
          'actions': [
            {
              'value': 'arrive',
              'label': "I'm on site",
              'allowed': false,
              'reason': 'Arrival on this job is already recorded.',
            },
          ],
        }),
        source: WorkSource.network,
        syncedAt: DateTime(2026, 11, 19, 9),
      ));

      await tester.pumpWidget(MaterialApp(
        home: WorkOrderScreen(id: 'job-1', repository: source, onSessionExpired: () {}),
      ));

      await tester.pump(const Duration(seconds: 1));

      expect(find.textContaining('already recorded'), findsOneWidget);

      // 🔴 Never omitted, never enabled: the server decides, the app renders.
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, "I'm on site")).onPressed,
        isNull,
      );
    });
  });
}
