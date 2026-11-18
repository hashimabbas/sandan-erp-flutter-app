import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/models/facility_user.dart';
import 'package:sandan_facility_app/screens/forgot_password_screen.dart';
import 'package:sandan_facility_app/screens/profile_screen.dart';

import 'support/fake_work_order_source.dart';

/// SPEC-024 Phase 4 — the account surface.
///
/// 🎯 **The screen exists for the queue.** Phase 3's D8 put a warning on
/// sign-out and promised the unsent work *a proper home*; and because SPEC-024
/// §6 Q2 (*how long may work stay on this phone?*) is still unanswered, the
/// ages shown here are the only evidence anybody will ever have for answering
/// it.
void main() {
  const technician = FacilityUser(id: 7, name: 'Fathi Al-Balushi', role: FacilityRole.technician);

  late FakeWorkOrderSource source;
  late int signOuts;

  setUp(() {
    source = FakeWorkOrderSource();
    signOuts = 0;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ProfileScreen(
        user: technician,
        source: source,
        onSignOut: () async => signOuts++,
      ),
    ));

    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('shows who is signed in, by name and role', (tester) async {
    await pump(tester);

    expect(find.text('Fathi Al-Balushi'), findsOneWidget);
    // ⚠️ From the stored session, not the server — there is no `facility/me`.
    // Acceptable because since ADR-013 the app does not act on the role at
    // all: the label is identity, not authority.
    expect(find.text('Technician'), findsOneWidget);
  });

  testWidgets('🔴 a waiting act shows what it is and HOW LONG it has waited', (tester) async {
    source.acts = [
      PendingAct(
        jobId: 'job-1',
        action: 'complete',
        createdAt: DateTime.now().subtract(const Duration(hours: 3)),
        attempts: 1,
        lastError: null,
      ),
    ];

    await pump(tester);

    expect(find.textContaining('complete'), findsOneWidget);
    // 🎯 The age is the point: Phase 2 invented no expiry precisely so this
    // question could be answered with real numbers instead of a guess.
    expect(find.textContaining('waiting 3 hours'), findsOneWidget);
  });

  testWidgets('🔴 a refused act shows the SERVER\'s reason, or it is stuck invisibly', (tester) async {
    source.acts = [
      PendingAct(
        jobId: 'job-1',
        action: 'complete',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        attempts: 2,
        lastError: 'This work order has not been started.',
      ),
    ];

    await pump(tester);

    // Without this, an item the server keeps refusing sits in the queue for
    // ever with no way for the technician to learn why.
    expect(find.text('This work order has not been started.'), findsOneWidget);
  });

  testWidgets('an empty queue says so plainly', (tester) async {
    await pump(tester);

    // ⚠️ "Nothing here" on a queue screen reads as a screen that failed.
    expect(find.text('Everything you have done has reached the server.'), findsOneWidget);
  });

  testWidgets('⚠️ offers no retry and no delete', (tester) async {
    source.acts = [
      PendingAct(
        jobId: 'job-1',
        action: 'complete',
        createdAt: DateTime.now(),
        attempts: 0,
        lastError: null,
      ),
    ];

    await pump(tester);

    // Retrying happens on every act and every refresh, so a button would
    // duplicate it — and deleting a queued act is deleting work the server has
    // never seen, which this screen must not make easy.
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('🔴 signing out here goes through the CALLER\'s sign-out', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Sign out'));
    await tester.pump(const Duration(milliseconds: 400));

    // One sign-out, not two: `HomeScreen` owns the pending-queue question, and
    // a second implementation that skipped it would be the warning's first bug.
    expect(signOuts, 1);
  });

  testWidgets('the change-password form checks only what it CAN check', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Change password'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final fields = find.byType(TextField);

    expect(fields, findsNWidgets(3));

    await tester.enterText(fields.at(0), 'old-one');
    await tester.enterText(fields.at(1), 'new-one');
    await tester.enterText(fields.at(2), 'a-different-one');
    await tester.tap(find.text('Change it'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('The two new passwords do not match.'), findsOneWidget);

    // 🔴 And nothing about length or strength: that is the server's to say, in
    // its own words. The app restating it would be a second description of one
    // rule.
    expect(find.textContaining('characters'), findsNothing);
  });

  testWidgets('it warns that a password change is NOT queued like field work', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Change password'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // ⚠️ Said before he tries: a man who expects this to behave like the acts
    // that queue would believe it had worked offline.
    expect(find.textContaining('needs a connection'), findsOneWidget);
  });

  testWidgets('shows the app version, the first thing anybody asks', (tester) async {
    await pump(tester);

    expect(find.textContaining(ProfileScreen.appVersion), findsOneWidget);
  });

  group('the forgotten-password screen', () {
    testWidgets('🔴 has NO email field and NO success state — it used to fake one', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ForgotPasswordScreen()));
      await tester.pump(const Duration(milliseconds: 400));

      // 🔴 It waited 1.2 seconds on a `Future.delayed` and then told the user a
      // reset link had been sent. Nothing was ever sent, and nothing could be:
      // `MAIL_MAILER=log`, and there is no API route to call. A dead button
      // teaches a man to ask for help; that one taught him to wait.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.textContaining('sent'), findsNothing);
    });

    testWidgets('says the thing that is true today, and what he CAN do', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ForgotPasswordScreen()));
      await tester.pump(const Duration(milliseconds: 400));

      // ⚠️ A placeholder awaiting Sandan's answer to *who resets a
      // technician's password* — named as one in the code.
      expect(find.text(ForgotPasswordScreen.placeholderGuidance), findsOneWidget);
      expect(find.textContaining('change your password yourself under Account'), findsOneWidget);
    });
  });
}
