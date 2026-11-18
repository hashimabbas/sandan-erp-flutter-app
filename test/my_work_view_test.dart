import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/models/facility_user.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/screens/home_screen.dart';
import 'package:sandan_facility_app/services/api_result.dart';

import 'support/fake_work_order_source.dart';
import 'support/work_order_payload.dart';

/// SPEC-024 Phase 2, Step 5 — what *My Work* says about where its list came
/// from.
///
/// 🔴 **The vocabulary change this phase forces.** A network failure used to
/// be the end of the screen. With rows on the disk it is a **note**: a retry
/// button is the wrong thing to show a technician who is holding a perfectly
/// usable list, because it teaches him the app is broken when it is working
/// exactly as designed.
void main() {
  const technician = FacilityUser(id: 7, name: 'Fathi Al-Balushi', role: FacilityRole.technician);

  late FakeWorkOrderSource source;

  setUp(() => source = FakeWorkOrderSource());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(user: technician, workOrderSource: source),
    ));

    await tester.pump(const Duration(seconds: 1));
  }

  List<WorkOrder> oneJob() => [WorkOrder.fromJson(workOrderJson(id: 'a'))];

  testWidgets('a fresh list says when it was updated', (tester) async {
    source.list = ApiSuccess(Cached(
      oneJob(),
      source: WorkSource.network,
      syncedAt: DateTime(2026, 10, 28, 9, 5),
    ));

    await pump(tester);

    expect(find.text('Updated at 09:05.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('🎯 a cached list is shown as a NOTE, with the time it was saved', (tester) async {
    source.list = ApiSuccess(Cached(
      oneJob(),
      source: WorkSource.cache,
      syncedAt: DateTime(2026, 10, 28, 8, 40),
      notice: 'Could not reach the server. Check your connection.',
    ));

    await pump(tester);

    expect(find.textContaining('Showing the work saved at 08:40'), findsOneWidget);
    // 🔴 Not an error state: the list is there and it is his.
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('a failure with NOTHING cached is still an error with a retry', (tester) async {
    // The fake's default is a network failure, which is what the repository
    // propagates when the cache is empty.
    await pump(tester);

    // ⚠️ Unchanged from Phase 1, deliberately. Saying "no work orders are
    // assigned to you right now" because the server was unreachable would be
    // the most reassuring possible lie.
    expect(find.text('Could not reach the server. Check your connection.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('an empty list is an ordinary morning, not a fault', (tester) async {
    source.list = ApiSuccess(Cached(
      const <WorkOrder>[],
      source: WorkSource.network,
      syncedAt: DateTime(2026, 10, 28, 9, 5),
    ));

    await pump(tester);

    expect(find.text('No work orders are assigned to you right now.'), findsOneWidget);
  });

  testWidgets('🔴 a row carrying unsent work says so, above the breach and the priority', (tester) async {
    source.list = ApiSuccess(Cached(
      oneJob(),
      source: WorkSource.network,
      syncedAt: DateTime(2026, 10, 28, 9, 5),
    ));
    source.pending = {'a'};

    await pump(tester);

    // ⚠️ It outranks the priority because it is the one thing the
    // technician can act on; the other two are facts about the job.
    expect(find.text('Not yet sent'), findsOneWidget);
    expect(find.text('High'), findsNothing);
  });

  testWidgets('🔴 signing out with unsent work ASKS, and staying signed in keeps it', (tester) async {
    source.list = ApiSuccess(Cached(
      oneJob(),
      source: WorkSource.network,
      syncedAt: DateTime(2026, 10, 28, 9, 5),
    ));
    source.pending = {'a', 'b'};

    await pump(tester);

    // Sign-out lives in the account menu, so the menu opens first.
    await tester.tap(find.byType(PopupMenuButton<String>));
    // 🔴 TWO pumps, and the first is not a formality: it only SCHEDULES the
    // menu route's animation, and while that animation runs the route holds
    // an `AbsorbPointer` — so a tap on a perfectly visible menu item lands on
    // the barrier instead, closing the menu and selecting nothing. ⚠️ And
    // `pumpAndSettle` is not available on this screen at all: the animated
    // background drifts for ever, so there is no settled frame to wait for.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('2 actions have not been sent yet'), findsOneWidget);

    // 🎯 It asks; it never refuses. A man may need to hand the phone over,
    // and blocking a sign-out would make the app worse than the paper it
    // replaces.
    expect(find.text('Stay signed in'), findsOneWidget);
    expect(find.text('Sign out anyway'), findsOneWidget);

    await tester.tap(find.text('Stay signed in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Still signed in, still holding the work: the dialogue is gone and the
    // home screen was never replaced by the login screen.
    expect(find.text('Stay signed in'), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('with an empty queue it signs out without asking', (tester) async {
    source.list = ApiSuccess(Cached(
      oneJob(),
      source: WorkSource.network,
      syncedAt: DateTime(2026, 10, 28, 9, 5),
    ));

    await pump(tester);

    await tester.tap(find.byType(PopupMenuButton<String>));
    // 🔴 TWO pumps, and the first is not a formality: it only SCHEDULES the
    // menu route's animation, and while that animation runs the route holds
    // an `AbsorbPointer` — so a tap on a perfectly visible menu item lands on
    // the barrier instead, closing the menu and selecting nothing. ⚠️ And
    // `pumpAndSettle` is not available on this screen at all: the animated
    // background drifts for ever, so there is no settled frame to wait for.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('have not been sent'), findsNothing);
  });

  testWidgets('✅ the Profile tab opens the account screen instead of saying "coming soon"', (tester) async {
    source.list = ApiSuccess(Cached(
      oneJob(),
      source: WorkSource.network,
      syncedAt: DateTime(2026, 10, 28, 9, 5),
    ));

    await pump(tester);

    await tester.tap(find.text('Profile'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Account'), findsOneWidget);
    // ⚠️ And `Complaints` still says it, on purpose: that is the Facility
    // Manager's surface (Phase 5), deferred rather than forgotten.
    expect(find.text('Sandan Facility 1.0.0+1'), findsOneWidget);
  });
}
