import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/services/api_result.dart';
import 'package:sandan_facility_app/services/facility_session.dart';
import 'package:sandan_facility_app/services/work_order_service.dart';

import 'support/work_order_payload.dart';

/// SPEC-024 Phase 1, Step 1 — the app's first service tests.
///
/// 🔴 Until now this app had **2 tests and neither touched a service**, while
/// every field of every payload is decoded by hand — so a field that changed
/// name would have surfaced as a runtime null inside a widget's build method
/// rather than as a failing test.
///
/// ⚠️ **The payload below is recorded from `WorkOrderResource`, not invented.**
/// A hand-built map that happens to match what the parser expects proves only
/// that the parser agrees with itself.
void main() {
  // ⚠️ The payload, `noCycleSla` and `breachedSla` now live in
  // `test/support/work_order_payload.dart` — Phase 2's store tests need the
  // same shape, and one fixture in two files is two descriptions of it.

  WorkOrderService serviceReturning(
    Object body, {
    int status = 200,
  }) =>
      WorkOrderService(
        session: FacilitySession(),
        client: MockClient((_) async => http.Response(
              jsonEncode(body),
              status,
              headers: {'content-type': 'application/json'},
            )),
      );

  group('fetchMyWork', () {
    test('decodes a list, with ids as STRINGS', () async {
      final result = await serviceReturning({
        'data': [workOrderJson()],
        'meta': {'current_page': 1, 'last_page': 1, 'per_page': 20, 'total': 1},
      }).fetchMyWork();

      expect(result, isA<ApiSuccess<List<WorkOrder>>>());

      final jobs = (result as ApiSuccess<List<WorkOrder>>).data;

      expect(jobs, hasLength(1));
      // 🔴 `complaints.id` is a char(36) UUID. `FacilityUser.id` is an int
      // because `users.id` is a bigint — copying that `as int` here would have
      // been a runtime cast failure on every single work order.
      expect(jobs.single.id, isA<String>());
      expect(jobs.single.id, '01a17c29-08de-70af-ad7d-165dcf88faf0');
    });

    test('keeps the server vocabulary and never derives a label', () async {
      final result = await serviceReturning({
        'data': [workOrderJson()],
      }).fetchMyWork();

      final job = (result as ApiSuccess<List<WorkOrder>>).data.single;

      expect(job.status.value, 'assigned');
      expect(job.status.label, 'Assigned');
      expect(job.priority.value, 'high');
      expect(job.priority.label, 'High');
    });

    test('an empty list is a success, not a failure', () async {
      // ⚠️ A technician with nothing assigned is an ordinary morning. If this
      // were an error the screen would tell him something is broken.
      final result = await serviceReturning({'data': <dynamic>[]}).fetchMyWork();

      expect(result, isA<ApiSuccess<List<WorkOrder>>>());
      expect((result as ApiSuccess<List<WorkOrder>>).data, isEmpty);
    });
  });

  group('the SLA block', () {
    test('decodes a job with NO cycle without guessing', () async {
      final result = await serviceReturning({
        'data': [workOrderJson(sla: noCycleSla)],
      }).fetchMyWork();

      final sla = (result as ApiSuccess<List<WorkOrder>>).data.single.sla;

      expect(sla.cycleNumber, isNull);
      expect(sla.assignmentBreached, isFalse);
      expect(sla.arrivalBreached, isFalse);
      expect(sla.hasBreached, isFalse);
      expect(sla.hasOpenReferral, isFalse);
    });

    test('reports a breach the SERVER decided, never one it computed', () async {
      // 🔴 The booleans arrive decided. D4a's referred-time subtraction is part
      // of what a breach means and lives in the ERP; date arithmetic here would
      // be a second definition, and the two would disagree.
      final result = await serviceReturning({
        'data': [workOrderJson(sla: breachedSla)],
      }).fetchMyWork();

      final sla = (result as ApiSuccess<List<WorkOrder>>).data.single.sla;

      expect(sla.cycleNumber, 1);
      expect(sla.assignmentBreached, isTrue);
      expect(sla.hasBreached, isTrue);
      expect(sla.assignedAt, isNotNull);
    });
  });

  group('401 is not 403', () {
    test('401 is a session that ended', () async {
      final result = await serviceReturning(
        {'message': 'Unauthenticated.'},
        status: 401,
      ).fetchMyWork();

      expect(result, isA<ApiFailure<List<WorkOrder>>>());
      expect((result as ApiFailure<List<WorkOrder>>).kind, ApiErrorKind.sessionExpired);
    });

    test('403 is a job that is not yours, and must NOT end the session', () async {
      // 🔴 Phase 0 returns 403 deliberately for a work order assigned to
      // another technician. Treating it as a 401 would sign a man out for
      // tapping the wrong row.
      final result = await serviceReturning(
        {'message': 'This action is unauthorized.'},
        status: 403,
      ).fetchOne('01a17c29-08de-70af-ad7d-165dcf88faf0');

      expect(result, isA<ApiFailure<WorkOrder>>());
      expect((result as ApiFailure<WorkOrder>).kind, ApiErrorKind.forbidden);
      expect(result.kind, isNot(ApiErrorKind.sessionExpired));
    });
  });

  group('failures the user can act on', () {
    test('an unreachable server is a network failure, not a crash', () async {
      final service = WorkOrderService(
        session: FacilitySession(),
        client: MockClient((_) async => throw const _Unreachable()),
      );

      final result = await service.fetchMyWork();

      expect((result as ApiFailure<List<WorkOrder>>).kind, ApiErrorKind.network);
      expect(result.message, contains('connection'));
    });

    test('a payload this version cannot read fails loudly, not inside a widget', () async {
      // ⚠️ Every field is decoded by hand. A renamed key must surface here.
      final result = await serviceReturning({
        'data': [
          {'id': 'x', 'status': 'assigned'}, // status is a String, not {value,label}
        ],
      }).fetchMyWork();

      expect((result as ApiFailure<List<WorkOrder>>).kind, ApiErrorKind.server);
    });
  });
}

class _Unreachable implements Exception {
  const _Unreachable();
}
