import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/screens/queue_screen.dart';
import 'package:sandan_facility_app/services/api_result.dart';
import 'package:sandan_facility_app/services/complaint_service.dart';
import 'package:sandan_facility_app/services/facility_session.dart';

import 'support/fake_work_order_source.dart';
import 'support/work_order_payload.dart';

/// SPEC-024 Phase 5, Step 1 — the manager's queue, as a screen.
///
/// 🔴 **What these tests are really protecting.** The screen must ask the
/// SERVER for a filtered list and must never narrow one itself — Hashim's
/// constraint, *"لا منطق تجميعي للفلاتر في Flutter"*. The way to prove that is
/// not to inspect the widget tree: it is to assert **what the repository was
/// asked**, which is why [FakeWorkOrderSource.queueCalls] exists.
void main() {
  /// A lookup server. [assignees] empty means the technician picker is not
  /// served — which is what a caller without `facility.work_orders.assign`
  /// sees, because `fetchAssignees()` returns an empty list rather than
  /// throwing.
  ComplaintService lookups({List<Map<String, dynamic>> assignees = const []}) => ComplaintService(
    session: FacilitySession(),
    client: MockClient((request) async {
      final path = request.url.path;

      final body = switch (true) {
        _ when path.endsWith('lookup/vocabulary') => {
          'priorities': [
            {'value': 'normal', 'label': 'Normal'},
            {'value': 'high', 'label': 'High'},
          ],
          'statuses': [
            {'value': 'new', 'label': 'New'},
            {'value': 'assigned', 'label': 'Assigned'},
          ],
          'acts': <Map<String, String>>[],
        },
        // ⚠️ A BARE list, not a `data` envelope — which is what this
        // endpoint actually returns, and getting it wrong here is how the
        // screen's one-failure-kills-all-seven defect was found.
        _ when path.endsWith('lookup/buildings') => [
          {'id': 'b-1', 'name': 'Building 1'},
        ],
        _ when path.endsWith('lookup/categories') => [
          {
            'id': 'c-1',
            'name': 'Plumbing',
            'subcategories': [
              {'id': 's-1', 'name': 'Leak'},
            ],
          },
        ],
        _ when path.endsWith('lookup/assignees') => {'data': assignees, 'job_trade': null},
        _ => <String, dynamic>{},
      };

      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }),
  );

  Future<FakeWorkOrderSource> pumpQueue(
    WidgetTester tester, {
    ApiResult<List<WorkOrder>>? result,
    List<Map<String, dynamic>> assignees = const [],
  }) async {
    final source = FakeWorkOrderSource()
      ..queueResult = result ?? ApiSuccess([WorkOrder.fromJson(workOrderJson(id: 'job-1'))]);

    // 🔴🔴 **`runAsync` is required, and discovering why cost an hour.**
    // `MockClient` resolves its response through `http`'s byte-stream
    // plumbing, which does not complete under the fake clock `testWidgets`
    // installs: without this the four lookups never finish, every dropdown
    // renders with only its *"Any…"* entry, and the screen looks as though
    // it had no option data. ⚠️ It is a property of the test binding, not of
    // the screen — but it is exactly the shape of bug that gets "fixed" by
    // weakening an assertion, so it is written down here.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: QueueScreen(
            userId: 7,
            onSessionExpired: () {},
            repository: source,
            service: lookups(assignees: assignees),
          ),
        ),
      );

      // Real time, so the HTTP futures above can actually complete.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    await tester.pumpAndSettle();

    return source;
  }

  /// ⚠️ The filter bar scrolls horizontally, and the 800×600 test viewport
  /// puts the later controls off-screen — a tap on an off-screen widget is a
  /// miss, not a failure of the screen. Every control is brought into view
  /// first, exactly as a thumb would.
  Future<void> tapFilter(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));

    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// ⚠️ An OPTION inside an open dropdown is in an overlay that is already
  /// positioned for it — calling `ensureVisible` on it scrolls the filter bar
  /// underneath instead, and the tap then lands outside the render tree. The
  /// warning that produced said *"would not hit test"* while the test still
  /// passed, which is the most dangerous shape a test can have.
  /// 🔧 **Two of these taps still log *"would not hit test"*, and the
  /// warning is a FALSE ALARM — proven, not assumed.** The last two controls
  /// sit beyond the 800px test viewport, so the overlay menu anchored to them
  /// reports an offset outside the root render tree, while the tap still
  /// dispatches through the overlay. Verified by mutation: changing the
  /// expected technician id from 42 to 99 fails with `Actual: <42>`, so the
  /// selection genuinely reached [QueueFilters]. ⚠️ Left visible rather than
  /// silenced with `warnIfMissed: false`, because the next person to see it
  /// should find this paragraph instead of a suppressed warning.
  Future<void> tapOption(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)), warnIfMissed: true);
    await tester.pumpAndSettle();
  }

  group('the queue asks the server', () {
    testWidgets('🔴 it opens by asking for an UNFILTERED queue', (tester) async {
      final source = await pumpQueue(tester);

      expect(source.queueCalls, hasLength(1));
      expect(source.queueCalls.single.isEmpty, isTrue);
      // ❌ And never the cached sync, which is the path that writes.
      expect(source.listCalls, 0);
    });

    testWidgets('✅ choosing a status re-asks the SERVER rather than narrowing the list here', (
      tester,
    ) async {
      final source = await pumpQueue(tester);

      await tapFilter(tester, 'filter-status');
      await tapOption(tester, 'Status-option-Assigned');

      expect(source.queueCalls, hasLength(2));
      expect(source.queueCalls.last.status, 'assigned');
      expect(source.queueCalls.last.toQuery(), containsPair('status', 'assigned'));
    });

    testWidgets('✅ the Late chip sends breached', (tester) async {
      final source = await pumpQueue(tester);

      await tapFilter(tester, 'filter-breached');

      expect(source.queueCalls.last.breached, isTrue);
    });

    testWidgets('✅ Clear returns to an empty filter set, in one request', (tester) async {
      final source = await pumpQueue(tester);

      await tapFilter(tester, 'filter-breached');

      await tapFilter(tester, 'filter-clear');

      expect(source.queueCalls.last.isEmpty, isTrue);
    });
  });

  group('the technician control', () {
    testWidgets('🔴 is ABSENT when the assignee lookup serves nothing', (tester) async {
      // ⚠️ `lookup/assignees` is guarded by `facility.work_orders.assign`. A
      // holder of `work_orders.view` alone would see one fewer control, never
      // a 403 to interpret.
      await pumpQueue(tester);

      expect(find.byKey(const Key('filter-technician')), findsNothing);
    });

    testWidgets('✅ is present, and sends an INTEGER id, when it is served', (tester) async {
      final source = await pumpQueue(
        tester,
        assignees: [
          {'id': 42, 'name': 'Plumber', 'role': 'technician', 'trades': <String>[]},
        ],
      );

      expect(find.byKey(const Key('filter-technician')), findsOneWidget);

      await tapFilter(tester, 'filter-technician');
      await tapOption(tester, 'Technician-option-Plumber');

      // 🔴 `users.id` is a bigint while every other id here is a UUID; the
      // server validates this key as an integer.
      expect(source.queueCalls.last.technicianId, 42);
      expect(source.queueCalls.last.toQuery(), containsPair('technician_id', '42'));
    });
  });

  group('the subcategory control', () {
    testWidgets('✅ appears only once a category is chosen, and the pair is sent together', (
      tester,
    ) async {
      final source = await pumpQueue(tester);

      expect(find.byKey(const Key('filter-subcategory')), findsNothing);

      await tapFilter(tester, 'filter-category');
      await tapOption(tester, 'Category-option-Plumbing');

      expect(find.byKey(const Key('filter-subcategory')), findsOneWidget);

      await tapFilter(tester, 'filter-subcategory');
      await tapOption(tester, 'Subcategory-option-Leak');

      expect(source.queueCalls.last.categoryId, 'c-1');
      expect(source.queueCalls.last.subcategoryId, 's-1');
    });
  });

  group('what the screen says when there is nothing', () {
    testWidgets('🔴 an empty FILTERED result says the filters matched nothing, not "no work"', (
      tester,
    ) async {
      final source = await pumpQueue(tester, result: const ApiSuccess(<WorkOrder>[]));

      // Unfiltered: the claim about the system is allowed.
      expect(find.text('There is no work in the system right now.'), findsOneWidget);

      await tapFilter(tester, 'filter-breached');

      // 🎯 Filtered, that claim would be FALSE and much worse than unhelpful.
      expect(find.text('No work matches these filters.'), findsOneWidget);
      expect(source.queueCalls.last.breached, isTrue);
    });

    testWidgets('❌ a failure shows the server\'s own sentence and a retry — never an empty list', (
      tester,
    ) async {
      await pumpQueue(
        tester,
        result: const ApiFailure(ApiErrorKind.server, 'The server could not answer right now.'),
      );

      expect(find.text('The server could not answer right now.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('There is no work in the system right now.'), findsNothing);
    });
  });
}
