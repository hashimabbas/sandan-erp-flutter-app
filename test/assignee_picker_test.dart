import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/models/assignee.dart';
import 'package:sandan_facility_app/models/complaint_lookups.dart';
import 'package:sandan_facility_app/services/complaint_service.dart';
import 'package:sandan_facility_app/services/facility_session.dart';
import 'package:sandan_facility_app/widgets/assignee_picker.dart';
import 'package:sandan_facility_app/widgets/party_picker.dart';

/// SPEC-025 Steps 6 and 7 — choosing who does the work, and saying when a unit
/// has nobody on record.
///
/// 🔴 **`ComplaintService` could not be tested at all until this step**: it
/// called the `http` package's top-level functions, so there was no seam. The
/// screen it serves still has no widget tests for the same reason, which is
/// why the picker is a separate widget that takes its data as an argument.
void main() {
  AssigneeList listOf(List<Map<String, dynamic>> people, {String? jobTrade}) =>
      AssigneeList.fromJson({'data': people, 'job_trade': jobTrade});

  Map<String, dynamic> person(
    int id,
    String name, {
    String role = 'technician',
    List<String> trades = const [],
    bool? matches,
  }) =>
      {'id': id, 'name': name, 'role': role, 'trades': trades, 'matches_trade': matches};

  Future<void> pumpPicker(
    WidgetTester tester, {
    required AssigneeList list,
    Set<int> selected = const {},
    void Function(Set<int>)? onChanged,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AssigneePicker(
          list: list,
          selected: selected,
          onChanged: onChanged ?? (_) {},
        ),
      ),
    ));
  }

  group('the picker', () {
    testWidgets('says it is optional, and starts with nobody chosen', (tester) async {
      await pumpPicker(tester, list: listOf([person(1, 'Fathi')]));

      expect(find.text(AssigneePicker.skippable), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('names the job trade, so the order is explained', (tester) async {
      await pumpPicker(
        tester,
        list: listOf([person(1, 'Fathi', trades: ['plumbing'], matches: true)], jobTrade: 'plumbing'),
      );

      expect(find.textContaining('plumbing'), findsWidgets);
      expect(find.textContaining('shown first'), findsOneWidget);
    });

    testWidgets('🔴 shows everybody, matching or not (D7)', (tester) async {
      await pumpPicker(
        tester,
        list: listOf([
          person(1, 'Plumber', trades: ['plumbing'], matches: true),
          person(2, 'Electrician', trades: ['electrical'], matches: false),
          person(3, 'Unrecorded'),
        ], jobTrade: 'plumbing'),
      );

      expect(find.text('Plumber'), findsOneWidget);
      expect(find.text('Electrician'), findsOneWidget);
      expect(find.text('Unrecorded'), findsOneWidget);
    });

    testWidgets('⚠️ distinguishes "trade not recorded" from "other trade"', (tester) async {
      await pumpPicker(
        tester,
        list: listOf([
          person(2, 'Electrician', trades: ['electrical'], matches: false),
          person(3, 'Unrecorded'),
        ], jobTrade: 'plumbing'),
      );

      // One is a gap in Sandan's data; the other is a fact about the man.
      expect(find.text('trade not recorded'), findsOneWidget);
      expect(find.text('other trade'), findsOneWidget);
    });

    testWidgets('says nothing about trades when the job has none', (tester) async {
      await pumpPicker(tester, list: listOf([person(3, 'Unrecorded')]));

      expect(find.text('trade not recorded'), findsNothing);
      expect(find.text('other trade'), findsNothing);
    });

    testWidgets('toggles a choice on and off', (tester) async {
      var chosen = <int>{};

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AssigneePicker(
              list: listOf([person(7, 'Fathi')]),
              selected: chosen,
              onChanged: (next) => setState(() => chosen = next),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Fathi'));
      await tester.pump();
      expect(chosen, {7});

      await tester.tap(find.text('Fathi'));
      await tester.pump();
      expect(chosen, isEmpty);
    });

    testWidgets('says so plainly when no field accounts exist', (tester) async {
      await pumpPicker(tester, list: const AssigneeList.empty());

      expect(find.text(AssigneePicker.nobodyYet), findsOneWidget);
    });
  });

  group('the service', () {
    ComplaintService serviceReturning(Object body, {int status = 200}) => ComplaintService(
          session: FacilitySession(),
          client: MockClient((_) async => http.Response(
                jsonEncode(body),
                status,
                headers: {'content-type': 'application/json'},
              )),
        );

    test('decodes the three states and the job trade', () async {
      final list = await serviceReturning({
        'job_trade': 'plumbing',
        'data': [
          person(1, 'Plumber', trades: ['plumbing'], matches: true),
          person(2, 'Electrician', trades: ['electrical'], matches: false),
          person(3, 'Unrecorded'),
        ],
      }).fetchAssignees(categoryId: 'abc');

      expect(list.jobTrade, 'plumbing');
      expect(list.people.map((p) => p.matchesTrade), [true, false, null]);
      expect(list.people[0].label, 'plumbing');
      // No trades recorded: the label falls back to the coarser fact.
      expect(list.people[2].label, 'technician');
    });

    test('⚠️ returns an empty list rather than throwing — the picker is optional', () async {
      final list = await serviceReturning({'message': 'nope'}, status: 403).fetchAssignees();

      expect(list.people, isEmpty);
      expect(list.jobTrade, isNull);
    });

    test('sends the chosen people with a new complaint, and reads back its id', () async {
      http.Request? sent;

      final service = ComplaintService(
        session: FacilitySession(),
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({'id': 'the-new-id'}),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await service.createComplaint(
        buildingId: 'b1',
        categoryId: 'c1',
        subcategoryId: 's1',
        description: 'Leak',
        priority: 'high',
        technicianIds: [4, 5],
      );

      expect(result.success, isTrue);
      expect(result.complaintId, 'the-new-id');
      expect(jsonDecode(sent!.body)['technician_ids'], [4, 5]);
    });

    test('✅ omits the field entirely when nobody was chosen (D1)', () async {
      http.Request? sent;

      final service = ComplaintService(
        session: FacilitySession(),
        client: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode({'id': 'x'}), 201, headers: {'content-type': 'application/json'});
        }),
      );

      await service.createComplaint(
        buildingId: 'b1',
        categoryId: 'c1',
        subcategoryId: 's1',
        description: 'Leak',
        priority: 'high',
      );

      // Byte-for-byte the request this app has always sent: that is what makes
      // "optional" real rather than a label.
      expect((jsonDecode(sent!.body) as Map<String, dynamic>).containsKey('technician_ids'), isFalse);
    });

    test('assigns an existing job', () async {
      http.Request? sent;

      final service = ComplaintService(
        session: FacilitySession(),
        client: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode({'data': {}}), 200, headers: {'content-type': 'application/json'});
        }),
      );

      final result = await service.assignWorkOrder(complaintId: 'job-1', technicianIds: [9]);

      expect(result.success, isTrue);
      expect(sent!.method, 'PATCH');
      expect(sent!.url.path, endsWith('/api/facility/work-orders/job-1/assign'));
      expect(jsonDecode(sent!.body)['technician_ids'], [9]);
    });

    test('surfaces the server\'s own refusal', () async {
      final result = await serviceReturning({
        'message': 'The given data was invalid.',
        'errors': {
          'technician_ids': ['Cannot assign a job in status in_progress: work has started.'],
        },
      }, status: 422).assignWorkOrder(complaintId: 'job-1', technicianIds: [9]);

      expect(result.success, isFalse);
      expect(result.message, contains('work has started'));
    });

    test('🔴 offline is a plain failure that names the reason — never a queue', () async {
      final service = ComplaintService(
        session: FacilitySession(),
        client: MockClient((_) async => throw http.ClientException('no network')),
      );

      final result = await service.assignWorkOrder(complaintId: 'job-1', technicianIds: [9]);

      expect(result.success, isFalse);
      expect(result.message, contains('needs a connection'));
    });
  });

  group('the party picker', () {
    testWidgets('🔴 says a unit has nobody on record instead of showing a bare search box', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PartyPicker(
            type: 'owner',
            label: 'Owner',
            suggested: const [],
            selected: null,
            onChanged: (_) {},
          ),
        ),
      ));

      expect(find.text(PartyPicker.nobodyOnRecord), findsOneWidget);
    });

    testWidgets('and says nothing of the kind when somebody IS on record', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PartyPicker(
            type: 'owner',
            label: 'Owner',
            suggested: const [PartyLookup(id: 'o1', name: 'AMAN REIT', subtitle: '90647005')],
            selected: null,
            onChanged: (_) {},
          ),
        ),
      ));

      expect(find.text(PartyPicker.nobodyOnRecord), findsNothing);
      expect(find.text('AMAN REIT'), findsOneWidget);
    });
  });
}
