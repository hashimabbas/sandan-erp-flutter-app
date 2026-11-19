import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/models/facility_user.dart';
import 'package:sandan_facility_app/screens/home_screen.dart';
import 'package:sandan_facility_app/screens/queue_screen.dart';
import 'package:sandan_facility_app/services/complaint_service.dart';
import 'package:sandan_facility_app/services/facility_session.dart';

import 'support/fake_work_order_source.dart';

/// SPEC-024 Phase 5, Step 4 — the manager's four figures on his home screen.
///
/// 🎯 **This screen once showed four invented counts** from
/// `MockDashboardData`, and the notice that replaced them promised they would
/// return *"built on the field data the app is now collecting"*. These tests
/// are what make the figures the discharge of that promise rather than a
/// repeat of the defect: ✅ the numbers come from the server, and 🔴 **a
/// failure shows no number at all**, because a zero and a failure must never
/// look alike here.
void main() {
  const manager = FacilityUser(id: 3, name: 'Mujahed', role: FacilityRole.facilityManager);

  late FakeWorkOrderSource source;
  late List<Uri> asked;

  setUp(() {
    source = FakeWorkOrderSource();
    asked = <Uri>[];
  });

  ComplaintService serving({int status = 200, Object? body}) => ComplaintService(
        session: FacilitySession(),
        client: MockClient((request) async {
          asked.add(request.url);

          return http.Response(
            jsonEncode(body ?? {
              'data': {
                'open': 7,
                'in_progress': 2,
                'completed_today': 4,
                'overdue_assignment': 1,
              },
            }),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

  Future<void> pump(WidgetTester tester, ComplaintService service) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(user: manager, workOrderSource: source, complaintService: service),
    ));

    // ⚠️ Never `pumpAndSettle()` — `AnimatedGradientBackground` animates for
    // ever. And the fetch is real async work, so it needs `runAsync` before
    // the frame that shows its result (the Step 3 harness trap, reused).
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('✅ renders the four numbers the server counted', (tester) async {
    await pump(tester, serving());

    expect(asked.single.path, endsWith('/api/facility/work-orders/summary'));

    expect(find.text('7'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Done today'), findsOneWidget);
  });

  testWidgets('🔴 names the breach tile "Late to assign", never "Late"', (tester) async {
    // The tile counts ASSIGNMENT breaches; the queue's `breached` filter is
    // the wider set (assignment OR arrival), so this tile opens a list that
    // may be longer than its own number. Two names, because two sets — and
    // the arrival half is the figure Hashim forbade until SPEC-034.
    await pump(tester, serving());

    expect(find.text('Late to assign'), findsOneWidget);
    expect(find.text('Late'), findsNothing);
  });

  testWidgets('🔴🔴 shows NO figure when the fetch fails, and says why', (tester) async {
    await pump(tester, serving(status: 500));

    expect(find.byKey(const Key('figures-unavailable')), findsOneWidget);
    expect(find.textContaining('No number is shown rather than a wrong one'), findsOneWidget);

    // 🎯 Not a zero anywhere: the standard this screen set when the invented
    // counts were deleted.
    expect(find.byKey(const Key('figure-open')), findsNothing);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('🔴 treats a MALFORMED payload as unavailable, not as zeros', (tester) async {
    // A missing key is a broken contract, never a count of none.
    await pump(tester, serving(body: {'data': {'open': 7}}));

    expect(find.byKey(const Key('figures-unavailable')), findsOneWidget);
    expect(find.text('7'), findsNothing);
  });

  testWidgets('✅ a tile opens the queue, already filtered', (tester) async {
    await pump(tester, serving());

    await tester.tap(find.byKey(const Key('figure-in-progress')));

    // ⚠️ The route transition needs its own frames, and `QueueScreen` then
    // fails its own first load — it builds a real repository here, and there
    // is no database under `flutter test`. That failure is its business; what
    // this test asserts is the QUESTION it was opened with.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    final queue = tester.widget<QueueScreen>(find.byType(QueueScreen));

    expect(queue.initialFilters.status, 'in_progress');
    expect(queue.initialFilters.breached, isFalse);
  });

  testWidgets('✅ and the breach tile opens it on the server\'s own judgement', (tester) async {
    await pump(tester, serving());

    await tester.tap(find.byKey(const Key('figure-overdue')));

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    final queue = tester.widget<QueueScreen>(find.byType(QueueScreen));

    expect(queue.initialFilters.breached, isTrue);
    expect(queue.initialFilters.status, isNull);
  });
}
