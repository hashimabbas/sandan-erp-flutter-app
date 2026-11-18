import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/screens/work_order_screen.dart';
import 'package:sandan_facility_app/services/api_result.dart';

import 'support/fake_work_order_source.dart';
import 'support/work_order_payload.dart';

/// SPEC-024 Phase 3, Step 5 — the buttons, and what they say when they cannot
/// be pressed.
///
/// 🔴 **Nothing here decides availability.** Every assertion below drives off
/// the server's `actions` block, which is the whole point: the transition map,
/// the referral rules and the role's permissions live on the server, and the
/// login payload does not even carry permissions.
void main() {
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
      syncedAt: DateTime(2026, 10, 28, 9),
    ));

    await tester.pumpWidget(MaterialApp(
      home: WorkOrderScreen(id: 'job-1', repository: source, onSessionExpired: () {}),
    ));

    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('an allowed act is pressable and calls it by name', (tester) async {
    await pump(tester, [act('start', 'Start work')]);

    await tester.tap(find.widgetWithText(FilledButton, 'Start work'));
    await tester.pump();

    expect(source.calls, ['start:job-1']);
  });

  testWidgets('🎯 a refused act is disabled AND shows the server\'s reason', (tester) async {
    await pump(tester, [
      act('complete', 'Mark complete',
          allowed: false, reason: 'A job in status assigned cannot be moved to completed.'),
    ]);

    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Mark complete'));

    expect(button.onPressed, isNull);
    // 🎯 The field that earns the design: a disabled button with no
    // explanation is the second-worst screen in the app.
    expect(find.text('A job in status assigned cannot be moved to completed.'), findsOneWidget);
  });

  testWidgets('🔴 an ALLOWED act this build cannot perform is DISABLED, and says why', (tester) async {
    // 🔴 SPEC-024 Phase 5, Step 0 — the runtime detector, and the defect it
    // closes. Measured on a real `in_progress` row with the seeded
    // technician, `pause` and `request_materials` came back **allowed** — and
    // the dispatcher implements neither, so the app drew two enabled buttons
    // that failed after the press. The server's answer is unchanged and
    // unquestioned; the app simply declines to offer what it has no code for.
    await pump(tester, [act('pause', 'Pause work')]);

    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Pause work'));

    expect(button.onPressed, isNull);
    // ⚠️ It describes the APP, not the job. A technician told "you cannot do
    // this" would reasonably blame his permissions.
    expect(find.textContaining('This version of the app cannot do this yet'), findsOneWidget);
    expect(source.calls, isEmpty);
  });

  testWidgets('⚠️ an act this build does not know AT ALL is still disabled, not crashed', (tester) async {
    // The case no test can reach across two repositories: an installed build
    // behind the server. It must degrade, not fail.
    await pump(tester, [act('teleport_technician', 'Teleport')]);

    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Teleport')).onPressed,
      isNull,
    );
  });

  testWidgets('a worker is told that referring is not his to do', (tester) async {
    await pump(tester, [
      act('refer', 'Waiting on a provider',
          allowed: false, reason: 'This is not something your role does.'),
    ]);

    expect(find.text('This is not something your role does.'), findsOneWidget);
    expect(source.calls, isEmpty);
  });

  testWidgets('the label comes from the SERVER, never from the act\'s name', (tester) async {
    // The server could rename this tomorrow and the app would follow — which
    // is the Phase 1 vocabulary rule, applied to acts.
    await pump(tester, [act('confirm_referral', 'The provider is done')]);

    expect(find.text('The provider is done'), findsOneWidget);
    expect(find.textContaining('confirm_referral'), findsNothing);
  });

  testWidgets('🔴 a PENDING act leaves the status alone and says what it is holding', (tester) async {
    source.result = const ActResult(ActOutcome.pending, message: 'Recorded on this phone.');

    await pump(tester, [act('complete', 'Mark complete')]);

    await tester.tap(find.widgetWithText(FilledButton, 'Mark complete'));
    await tester.pump();

    // 🔴 The status is unchanged: the server has not accepted anything. An app
    // that showed `completed` here would have to walk it back on a refusal,
    // so the technician would have seen a completion that never happened.
    expect(find.text('Assigned'), findsOneWidget);
    expect(find.textContaining('recorded on this phone'), findsOneWidget);
  });

  testWidgets('an applied act takes the SERVER\'s new state', (tester) async {
    source.result = ActResult(
      ActOutcome.applied,
      job: WorkOrder.fromJson({
        ...workOrderJson(id: 'job-1'),
        'status': {'value': 'in_progress', 'label': 'In progress'},
        'actions': [act('complete', 'Mark complete')],
      }),
    );

    await pump(tester, [act('start', 'Start work')]);

    await tester.tap(find.widgetWithText(FilledButton, 'Start work'));
    await tester.pump();

    expect(find.text('In progress'), findsOneWidget);
    // ✅ And the response already carried what may be done next, so no second
    // request was needed to find out.
    expect(find.widgetWithText(FilledButton, 'Mark complete'), findsOneWidget);
  });

  testWidgets('a refusal is reported in the server\'s words', (tester) async {
    source.result = const ActResult(
      ActOutcome.refused,
      message: 'This work order has not been started.',
    );

    await pump(tester, [act('complete', 'Mark complete')]);

    await tester.tap(find.widgetWithText(FilledButton, 'Mark complete'));
    await tester.pump();

    expect(find.text('This work order has not been started.'), findsOneWidget);
  });

  testWidgets('⚠️ a cached row with no actions says so instead of showing nothing', (tester) async {
    // A row written by the Phase 2 build has no `actions` key at all.
    await pump(tester, []);

    expect(find.textContaining('Refresh this job'), findsOneWidget);
  });

  testWidgets('referring asks for the provider first, and sends what was typed', (tester) async {
    await pump(tester, [act('refer', 'Waiting on a provider')]);

    await tester.tap(find.widgetWithText(FilledButton, 'Waiting on a provider'));
    // ⚠️ `pumpAndSettle` never returns here: the dialogue's autofocused
    // TextField has a BLINKING CURSOR, which is a repeating animation, so
    // there is no settled frame to wait for.
    await tester.pump(const Duration(milliseconds: 400));

    // ⚠️ Free text, because there is no provider master data anywhere in this
    // project — a dropdown here would be the app minting master data.
    await tester.enterText(find.byType(TextField), 'Al Sahwa Plumbing');
    await tester.tap(find.text('Record it'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(source.calls, ['refer:job-1:Al Sahwa Plumbing']);
  });

  testWidgets('cancelling the provider dialogue sends nothing', (tester) async {
    await pump(tester, [act('refer', 'Waiting on a provider')]);

    await tester.tap(find.widgetWithText(FilledButton, 'Waiting on a provider'));
    // ⚠️ `pumpAndSettle` never returns here: the dialogue's autofocused
    // TextField has a BLINKING CURSOR, which is a repeating animation, so
    // there is no settled frame to wait for.
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(source.calls, isEmpty);
  });
}
