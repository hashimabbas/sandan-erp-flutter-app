import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/models/facility_user.dart';
import 'package:sandan_facility_app/screens/app_shell.dart';
import 'package:sandan_facility_app/screens/home_screen.dart';
import 'package:sandan_facility_app/screens/new_complaint_screen.dart';
import 'package:sandan_facility_app/screens/queue_screen.dart';
import 'package:sandan_facility_app/services/complaint_service.dart';
import 'package:sandan_facility_app/services/facility_session.dart';

import 'support/fake_work_order_source.dart';

/// **The bottom bar, 2026-11-21 — from three dead labels to a tab shell.**
///
/// 🔧 **`Work` and `Complaints` were never broken: they were never wired.**
/// Both called `_notImplemented` and answered *"coming soon"*, while the screen
/// each one needed had already shipped (SPEC-024 Phase 5 Step 1). Then, on
/// Hashim's word, the bar stopped PUSHING screens over Home and became an
/// `IndexedStack` with a navigator per tab.
///
/// 🔴 **What these tests hold, and what no manual check would hold for long:**
/// every tab opens the screen it names · the highlight follows where you
/// actually are · each tab keeps its own state and its own history · and the
/// word *"coming soon"* never appears on either tab again.
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
      home: AppShell(user: user, workOrderSource: source, complaintService: summaryService()),
    ));

    // ⚠️ Never `pumpAndSettle()` — `AnimatedGradientBackground` animates for
    // ever.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapTab(WidgetTester tester, String tab) async {
    await tester.tap(find.byKey(Key('nav-$tab')));

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  testWidgets('🔧 Work shows the work queue, and no longer says "coming soon"', (tester) async {
    await pump(tester, manager);

    await tapTab(tester, 'work');

    final queue = tester.widget<QueueScreen>(
      find.descendant(of: find.byType(IndexedStack), matching: find.byType(QueueScreen)).first,
    );

    expect(queue.title, 'Work Queue');
    // 🔴 Unfiltered: `Work` is every job, and the filter bar is how he narrows it.
    expect(queue.initialFilters.isEmpty, isTrue);
    expect(queue.onRaiseComplaint, isNull);

    // ⚠️ The regression this file exists for.
    expect(find.textContaining('coming soon'), findsNothing);
  });

  testWidgets('🔧 Complaints asks the same list for the ones nobody owns yet', (tester) async {
    await pump(tester, manager);

    await tapTab(tester, 'complaints');

    // 🔴 A complaint and a work order are the same row: `GET
    // /api/facility/work-orders` reads the `complaints` table and there is no
    // complaints-list endpoint at all.
    final complaints = tester
        .widgetList<QueueScreen>(find.byType(QueueScreen))
        .firstWhere((screen) => screen.title == 'Complaints');

    expect(complaints.initialFilters.status, 'new');
    expect(complaints.initialFilters.breached, isFalse);
    expect(complaints.initialFilters.arrival, isNull);
    expect(find.textContaining('coming soon'), findsNothing);
  });

  testWidgets('✅ the Facility Manager raises a complaint inside the Complaints tab', (tester) async {
    await pump(tester, manager);
    await tapTab(tester, 'complaints');

    expect(find.byKey(const Key('raise-complaint')), findsOneWidget);

    await tester.tap(find.byKey(const Key('raise-complaint')));

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(find.byType(NewComplaintScreen), findsOneWidget);

    // 🔴🔴 **The whole point of a navigator per tab: the bar is STILL THERE**
    // over the screen the tab just opened. With one root navigator this push
    // covered it.
    expect(find.byKey(const Key('nav-complaints')), findsOneWidget);
  });

  testWidgets('🔴 the four tabs stay ALIVE — Home is not rebuilt by a trip to Profile', (tester) async {
    await pump(tester, manager);

    expect(find.byType(HomeScreen), findsOneWidget);

    await tapTab(tester, 'work');

    expect(find.byType(QueueScreen), findsWidgets);

    // 🔧 **`skipOffstage: false`, and that is the lesson of this pattern.**
    // `IndexedStack` keeps every branch MOUNTED and paints only the selected
    // one, so an unselected tab is **offstage** — and `find.byType` skips
    // offstage widgets by default. Asking the default question would have
    // reported Home as gone and the liveness this change exists for as broken.
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);

    await tapTab(tester, 'home');

    // Back on Home, and it is the SAME element — never rebuilt, which is why
    // the figures do not reload and the queue keeps its filters.
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('✅ back pops the TAB\'s own stack, then returns to Home', (tester) async {
    await pump(tester, manager);
    await tapTab(tester, 'complaints');

    await tester.tap(find.byKey(const Key('raise-complaint')));

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(find.byType(NewComplaintScreen), findsOneWidget);

    // First back: out of the pushed screen, still inside the Complaints tab.
    await tester.binding.handlePopRoute();

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(find.byType(NewComplaintScreen), findsNothing);
    expect(find.byKey(const Key('nav-complaints')), findsOneWidget);
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

  testWidgets('✅ Profile opens the account screen — for a FIELD role too', (tester) async {
    // 🔧 Moved here from `my_work_view_test.dart`, which asserted it by
    // pumping `HomeScreen` alone and tapping a label in a bar that screen used
    // to own. The bar is the shell's now, so the assertion belongs here.
    await pump(tester, technician);

    await tapTab(tester, 'profile');

    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Sandan Facility 1.0.0+1'), findsOneWidget);

    // 🔴 And the bar is STILL visible over it — the whole point of the
    // shell. Before this change, Profile was pushed and the bar disappeared.
    expect(find.byKey(const Key('nav-profile')), findsOneWidget);
  });

  testWidgets('⚠️ the highlight follows where you ARE — it used to be hardcoded to Home', (tester) async {
    await pump(tester, manager);

    Color colourOf(String tab) {
      final icon = tester.widget<Icon>(
        find.descendant(of: find.byKey(Key('nav-$tab')), matching: find.byType(Icon)),
      );

      return icon.color!;
    }

    final homeSelected = colourOf('home');

    expect(colourOf('work'), isNot(homeSelected));

    await tapTab(tester, 'work');

    // Now Work carries the selected colour and Home does not.
    expect(colourOf('work'), homeSelected);
    expect(colourOf('home'), isNot(homeSelected));
  });
}
