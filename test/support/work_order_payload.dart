/// The work-order payload as `WorkOrderResource` sends it — **recorded from
/// the server, not invented**. A hand-built map that happens to match what the
/// parser expects proves only that the parser agrees with itself.
///
/// 🎯 Extracted here by SPEC-024 Phase 2, Step 2, when a second test file
/// needed it. One payload, one place: a fixture copied into two files is two
/// descriptions of the server's shape, and the first to drift does so quietly.
library;

/// 🎯 The total shape a job with NO cycle carries — every key present, with
/// nulls and `false`. The server guarantees this so the app never has to guess
/// what a missing block meant.
const noCycleSla = <String, dynamic>{
  'cycle_number': null,
  'reopen_count': 0,
  'assignment_due_at': null,
  'assigned_at': null,
  'arrival_due_at': null,
  'arrived_at': null,
  'assignment_breached': false,
  'arrival_breached': false,
  'referred_minutes': 0,
  'open_referral': null,
};

const breachedSla = <String, dynamic>{
  'cycle_number': 1,
  'reopen_count': 0,
  'assignment_due_at': '2026-10-27T07:05:00+04:00',
  'assigned_at': '2026-10-27T07:06:00+04:00',
  'arrival_due_at': '2026-10-27T08:00:00+04:00',
  'arrived_at': null,
  'assignment_breached': true,
  'arrival_breached': false,
  'referred_minutes': 0,
  'open_referral': null,
};

/// Phase 0's `WorkOrderResource`, field for field.
Map<String, dynamic> workOrderJson({
  String id = '01a17c29-08de-70af-ad7d-165dcf88faf0',
  String? reference = 'MS-2026-000042',
  String description = 'Water leaking from the corridor ceiling.',
  Map<String, dynamic>? sla,
}) =>
    {
      'id': id,
      'reference': reference,
      'description': description,
      'status': {'value': 'assigned', 'label': 'Assigned'},
      'priority': {'value': 'high', 'label': 'High'},
      'unit': {'id': '01a08b6f-239e-7396-af39-f63de901b0dc', 'number': '1/E101'},
      'building': {'id': '01a08b70-0000-7000-8000-000000000001', 'name': 'Block C'},
      'block_number': null,
      'category': 'Plumbing',
      'subcategory': 'Water leak',
      'technicians': [
        {'id': 7, 'name': 'Fathi Al-Balushi'},
      ],
      'sla': sla ?? noCycleSla,
      'created_at': '2026-10-27T07:00:26+04:00',
    };
