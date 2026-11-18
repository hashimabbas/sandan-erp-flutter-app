import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/screens/work_order_screen.dart';
import 'package:sandan_facility_app/services/api_result.dart';

import 'support/fake_work_order_source.dart';
import 'support/work_order_payload.dart';

/// SPEC-024 Phase 1, Step 4 — the detail screen.
///
/// 🎯 **This screen is why the phase has two and not one expanding row.**
/// `GET /api/facility/work-orders/{id}` authorizes `view` **per job**, so
/// without a client that fetches one by id, the route proving per-row
/// authorization would be exercised by nothing.
void main() {
  late FakeWorkOrderSource source;

  setUp(() {
    source = FakeWorkOrderSource();
  });

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onSessionExpired,
    String id = '01a17d83-e2db-71ec-9657-605929d74713',
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: WorkOrderScreen(
        id: id,
        repository: source,
        onSessionExpired: onSessionExpired ?? () {},
      ),
    ));
  }

  testWidgets('opens on a loading state rather than an empty frame', (tester) async {
    await pump(tester);

    // The first frame is what a technician sees while the radio wakes up in a
    // basement. It must say something.
    expect(find.text('Loading…'), findsOneWidget);

    // Let the real (failing) request settle so the test ends cleanly.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a failure offers a retry instead of an empty screen', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(seconds: 2));

    // No server is running under `flutter test`, so the service returns its
    // network failure — which is the path a phone takes in a lift.
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('shows the back affordance and the screen title', (tester) async {
    await pump(tester);

    expect(find.text('Work Order'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('🎯 a CACHED job is shown with its freshness, not an error', (tester) async {
    source.detail = ApiSuccess(Cached(
      WorkOrder.fromJson(workOrderJson(id: 'cached-job')),
      source: WorkSource.cache,
      syncedAt: DateTime(2026, 10, 28, 8, 40),
      notice: 'Could not reach the server. Check your connection.',
    ));

    await pump(tester, id: 'cached-job');
    await tester.pump(const Duration(seconds: 1));

    // The job, not a retry button — this is the whole of Phase 2 on one
    // screen.
    expect(find.text('Water leaking from the corridor ceiling.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);

    // 🔴 And it says where it came from. An SLA panel read from a copy
    // saved hours ago, presented as current, is the defect that left a
    // permanent "SLA BREACHED" on a finished job.
    expect(find.textContaining('saved at 08:40'), findsOneWidget);
  });

  testWidgets('a fresh job reports when it was updated', (tester) async {
    source.detail = ApiSuccess(Cached(
      WorkOrder.fromJson(workOrderJson(id: 'fresh-job')),
      source: WorkSource.network,
      syncedAt: DateTime(2026, 10, 28, 9, 5),
    ));

    await pump(tester, id: 'fresh-job');
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Updated at 09:05.'), findsOneWidget);
    expect(find.textContaining('saved at'), findsNothing);
  });

  test('the payload this screen reads carries a TOTAL sla block', () {
    // ⚠️ Pinned here as well as in the service test, because this screen is
    // what would render a half-shape. `cycle_number: null` is a job with no
    // cycle — a real state the panel states in words — and NOT missing data.
    final sla = (jsonDecode('''
      {
        "cycle_number": null,
        "reopen_count": 0,
        "assignment_due_at": null,
        "assigned_at": null,
        "arrival_due_at": null,
        "arrived_at": null,
        "assignment_breached": false,
        "arrival_breached": false,
        "referred_minutes": 0,
        "open_referral": null
      }
    ''') as Map<String, dynamic>);

    expect(sla.keys, hasLength(10));
    expect(sla['assignment_breached'], isFalse);
  });
}
