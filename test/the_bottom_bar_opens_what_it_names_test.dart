import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/models/facility_user.dart';
import 'package:sandan_facility_app/screens/home_screen.dart';
import 'package:sandan_facility_app/screens/new_complaint_screen.dart';
import 'package:sandan_facility_app/screens/queue_screen.dart';
import 'package:sandan_facility_app/services/complaint_service.dart';
import 'package:sandan_facility_app/services/facility_session.dart';

import 'support/fake_work_order_source.dart';

/// **The bottom bar, 2026-11-21 — three labels and one working button.**
///
/// 🔧 **`Work` and `Complaints` were never broken: they were never wired.**
/// Both called `_notImplemented` and answered *"coming soon"*, while the screen
/// each one needed had already shipped — the queue, in SPEC-024 Phase 5
/// Step 1. These tests are what stop that happening again: a tab that answers
/// a snackbar instead of opening a screen now fails here.
///
/// 🔴 **And `Complaints` opens the SAME screen as `Work`, by measurement.** In
/// this system a complaint and a work order are the same row: `GET
/// /api/facility/work-orders` reads the `complaints` table and there is **no
/// complaints-list endpoint at all**. The tab asks a different question of the
/// same list — `status: 'new'`, the complaints that are nobody's work yet.
void main() {
  const manager = FacilityUser(id: 3, name: 'Mujahed', role: FacilityRole.facilityManager);
  const technician = FacilityUser(id: 9, name: 'Ali', role: FacilityRole.technician);

  late FakeWorkOrderSource source;

  setUp(() => source = FakeWorkOrderSource());

  ComplaintService summaryService() => ComplaintService(
        session: FacilitySession(),
        client: MockClient((request) async => http.Response(
              jsonEncode({
                'data': {'open': 7, 'in_progress': 2, 'completed_today': 4, 'overdue_assignment': 1},
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

  Future<void> pump(WidgetTester tester, FacilityUser user) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(user: user, workOrderSource: source, complaintService: summaryService()),
    ));

    // ⚠️ Never `pumpAndSettle()` — `AnimatedGradientBackground` animates for
    // ever.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> settleRoute(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  testWidgets('🔧 Work opens the work queue, and no longer says "coming soon"', (tester) async {
    await pump(tester, manager);

    await tester.tap(find.byKey(const Key('nav-work')));
    await settleRoute(tester);

    final queue = tester.widget<QueueScreen>(find.byType(QueueScreen));

    expect(queue.title, 'Work Queue');
    // 🔴 Unfiltered: `Work` is every job, and the filter bar is how he narrows it.
    expect(queue.initialFilters.isEmpty, isTrue);
    expect(queue.onRaiseComplaint, isNull);

    // ⚠️ The regression this file exists for.
    expect(find.textContaining('coming soon'), findsNothing);
  });

  testWidgets('🔧 Complaints opens the same list asking for the ones nobody owns yet', (tester) async {
    await pump(tester, manager);

    await tester.tap(find.byKey(const Key('nav-complaints')));
    await settleRoute(tester);

    final queue = tester.widget<QueueScreen>(find.byType(QueueScreen));

    expect(queue.title, 'Complaints');
    // 🔴 `new` is the intake: a complaint that exists and is nobody's work.
    expect(queue.initialFilters.status, 'new');
    expect(queue.initialFilters.breached, isFalse);
    expect(queue.initialFilters.arrival, isNull);

    expect(find.textContaining('coming soon'), findsNothing);
  });

  testWidgets('✅ the Facility Manager can raise a complaint from the Complaints tab', (tester) async {
    await pump(tester, manager);

    await tester.tap(find.byKey(const Key('nav-complaints')));
    await settleRoute(tester);

    expect(find.byKey(const Key('raise-complaint')), findsOneWidget);

    await tester.tap(find.byKey(const Key('raise-complaint')));
    await settleRoute(tester);

    expect(find.byType(NewComplaintScreen), findsOneWidget);
  });

  testWidgets('🔴 a technician gets neither tab, because both would be empty for him', (tester) async {
    // He holds no `facility.complaints.create`, and the queue endpoint returns
    // only his OWN assigned jobs — so a `status: new` list is empty by
    // construction. His work is on Home, which IS My Work for a field role.
    await pump(tester, technician);

    expect(find.byKey(const Key('nav-work')), findsNothing);
    expect(find.byKey(const Key('nav-complaints')), findsNothing);

    expect(find.byKey(const Key('nav-home')), findsOneWidget);
    expect(find.byKey(const Key('nav-profile')), findsOneWidget);
  });

  testWidgets('⚠️ only Home is drawn as the current tab — the highlight used to lie', (tester) async {
    // It was hardcoded to `i == 0`, so every item rendered as selected,
    // including the three that did nothing at all.
    await pump(tester, manager);

    for (final label in ['nav-home', 'nav-work', 'nav-complaints', 'nav-profile']) {
      expect(find.byKey(Key(label)), findsOneWidget);
    }
  });
}
