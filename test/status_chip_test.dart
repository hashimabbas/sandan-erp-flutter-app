import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/widgets/status_chip.dart';

/// SPEC-024 Phase 1, Step 3 — the chip shows the server's word.
void main() {
  Future<void> pumpChip(WidgetTester tester, Vocab status) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StatusChip(status: status))),
      );

  testWidgets('renders the SERVER label, not one derived from the value', (tester) async {
    // 🔴 `in_progress` → "In Progress" is a transformation the app must never
    // perform. The server already did it, and its answer is the one the web
    // shows too.
    await pumpChip(tester, const Vocab(value: 'in_progress', label: 'In Progress'));

    expect(find.text('In Progress'), findsOneWidget);
    expect(find.text('in_progress'), findsNothing);
  });

  testWidgets('renders a status this build has never heard of', (tester) async {
    // 🔴 The case the old four-value enum could not survive at all: it would
    // not have compiled against an unknown value, and a `switch` with a silent
    // default would have rendered it as background.
    //
    // A status the app does not know must still reach the technician, under
    // the server's own label.
    await pumpChip(tester, const Vocab(value: 'waiting_for_parts', label: 'Waiting for Parts'));
    expect(find.text('Waiting for Parts'), findsOneWidget);

    await pumpChip(tester, const Vocab(value: 'a_status_invented_tomorrow', label: 'Invented Tomorrow'));
    expect(find.text('Invented Tomorrow'), findsOneWidget);
  });

  testWidgets('every ComplaintStatus the server has renders', (tester) async {
    // ⚠️ The eight cases of `ComplaintStatus`, measured from the enum — NOT
    // thirteen, which is `ChargeStatus`'s count and an error an earlier draft
    // of these documents made.
    const statuses = [
      'new', 'assigned', 'in_progress', 'waiting_for_parts',
      'completed', 'verified', 'closed', 'cancelled',
    ];

    for (final value in statuses) {
      await pumpChip(tester, Vocab(value: value, label: 'Label for $value'));
      expect(find.text('Label for $value'), findsOneWidget, reason: '$value did not render');
    }
  });

  testWidgets('an unknown status is not coloured like a familiar one', (tester) async {
    // 🎯 The point of the fallback: unfamiliar must LOOK unfamiliar. Returning
    // the same neutral as `closed` would make a job in an unknown state read
    // as finished.
    await pumpChip(tester, const Vocab(value: 'definitely_unknown', label: 'Unknown'));
    final unknownStyle = tester.widget<Text>(find.text('Unknown')).style;

    await pumpChip(tester, const Vocab(value: 'closed', label: 'Closed'));
    final closedStyle = tester.widget<Text>(find.text('Closed')).style;

    expect(unknownStyle!.color, isNot(closedStyle!.color));
  });
}
