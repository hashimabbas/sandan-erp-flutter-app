/// SPEC-024 Phase 1, Step 1 — a work order as the ERP sends it.
///
/// 🔴 **Status and priority are NOT enums here, and that is the point.** The
/// server has eight `ComplaintStatus` cases and four priorities, and it
/// returns each as `{value, label}` precisely so the app never translates one.
/// `mock_dashboard_data.dart` held a four-value `TaskStatus` with its labels
/// hardwired in Dart — a vocabulary the server had already replaced — and
/// repeating that mistake in a new file would be worse than leaving the old
/// one alone.
///
/// ⚠️ **Ids are `String`.** `complaints.id` is a `char(36)` UUID. The existing
/// `FacilityUser.id` is an `int` because `users.id` is a bigint; copying that
/// `as int` here would be a **runtime** cast failure on every work order, which
/// no compiler would have caught.
library;

/// A `{value, label}` pair exactly as the server sends it.
class Vocab {
  const Vocab({required this.value, required this.label});

  factory Vocab.fromJson(Map<String, dynamic> json) => Vocab(
        value: json['value'] as String,
        label: json['label'] as String,
      );

  /// What the server calls it — the only thing the app may compare or send.
  final String value;

  /// What a person reads. Never derived from [value] in Dart.
  final String label;
}

/// A named party on a work order — a unit, a building, a technician.
class NamedRef {
  const NamedRef({required this.id, required this.name});

  final String id;
  final String name;
}

/// The SLA state, straight from `WorkOrderSlaPresenter`.
///
/// ⚠️ **The breaches arrive as booleans and the deadlines as raw timestamps,
/// and that split is deliberate on the server's side**: a screen may format a
/// date however it likes, but it may **not** conclude from two timestamps
/// whether a job has breached. D4a's referred-time subtraction is part of what
/// a breach means, and it lives in one place — the ERP.
///
/// ✅ The shape is **total**: a job with no SLA cycle still carries every key,
/// with nulls and `false`, so this never has to guess what a missing block
/// meant.
class SlaState {
  const SlaState({
    required this.cycleNumber,
    required this.reopenCount,
    required this.assignmentDueAt,
    required this.assignedAt,
    required this.arrivalDueAt,
    required this.arrivedAt,
    required this.assignmentBreached,
    required this.arrivalBreached,
    required this.referredMinutes,
    required this.hasOpenReferral,
  });

  factory SlaState.fromJson(Map<String, dynamic> json) => SlaState(
        cycleNumber: json['cycle_number'] as int?,
        reopenCount: json['reopen_count'] as int? ?? 0,
        assignmentDueAt: _date(json['assignment_due_at']),
        assignedAt: _date(json['assigned_at']),
        arrivalDueAt: _date(json['arrival_due_at']),
        arrivedAt: _date(json['arrived_at']),
        assignmentBreached: json['assignment_breached'] as bool? ?? false,
        arrivalBreached: json['arrival_breached'] as bool? ?? false,
        referredMinutes: json['referred_minutes'] as int? ?? 0,
        hasOpenReferral: json['open_referral'] != null,
      );

  final int? cycleNumber;
  final int reopenCount;
  final DateTime? assignmentDueAt;
  final DateTime? assignedAt;
  final DateTime? arrivalDueAt;
  final DateTime? arrivedAt;
  final bool assignmentBreached;
  final bool arrivalBreached;
  final int referredMinutes;
  final bool hasOpenReferral;

  bool get hasBreached => assignmentBreached || arrivalBreached;
}


/// SPEC-024 Phase 3 — one act the server says this user may or may not
/// perform on this job.
///
/// 🔴 **The app does not work this out, and could not have.** The transition
/// map, `REFERABLE_FROM`, the rule that a referral moves no status and the
/// role's permissions all live on the server — and the login payload carries
/// **no permissions at all**, so a Dart table claiming *a technician may
/// start* would have been a guess with nothing to correct it. On 2026-10-22
/// all twelve work-order permission rows were missing from the database
/// entirely; that guess would have been confidently wrong.
class WorkOrderAction {
  const WorkOrderAction({
    required this.value,
    required this.label,
    required this.allowed,
    required this.reason,
  });

  factory WorkOrderAction.fromJson(Map<String, dynamic> json) => WorkOrderAction(
        value: json['value'] as String,
        label: json['label'] as String,
        allowed: json['allowed'] as bool? ?? false,
        reason: json['reason'] as String?,
      );

  /// What the app sends — the only thing it may compare.
  final String value;

  /// What a person reads. Never built in Dart.
  final String label;

  final bool allowed;

  /// 🎯 Why not, in the server's own words. A disabled button with no
  /// explanation is the second-worst screen in the app; the worst is an
  /// enabled button that fails.
  final String? reason;
}

class WorkOrder {
  const WorkOrder({
    required this.source,
    required this.id,
    required this.reference,
    required this.description,
    required this.status,
    required this.priority,
    required this.unit,
    required this.building,
    required this.blockNumber,
    required this.category,
    required this.subcategory,
    required this.technicians,
    required this.sla,
    required this.actions,
    required this.createdAt,
  });

  factory WorkOrder.fromJson(Map<String, dynamic> json) => WorkOrder(
        // 🔴 SPEC-024 Phase 2: the payload is KEPT, so the offline cache can
        // store what the server said rather than what Dart made of it.
        // Writing a `toJson()` instead would create a second description of
        // this shape, and the first of the two to drift would do so silently —
        // the mistake `MockDashboardData`'s four-value `TaskStatus` already
        // made against the server's eight.
        source: json,
        id: json['id'] as String,
        // ⚠️ Nullable: `complaint_number` is generated by
        // `CreateComplaintAction`, so a row written any other way has none.
        reference: json['reference'] as String?,
        description: json['description'] as String? ?? '',
        status: Vocab.fromJson(json['status'] as Map<String, dynamic>),
        priority: Vocab.fromJson(json['priority'] as Map<String, dynamic>),
        unit: _ref(json['unit'], 'number'),
        building: _ref(json['building'], 'name'),
        blockNumber: json['block_number'] as String?,
        category: json['category'] as String?,
        subcategory: json['subcategory'] as String?,
        technicians: ((json['technicians'] as List<dynamic>?) ?? const [])
            .map((t) => NamedRef(
                  id: (t as Map<String, dynamic>)['id'].toString(),
                  name: t['name'] as String,
                ))
            .toList(growable: false),
        sla: SlaState.fromJson(json['sla'] as Map<String, dynamic>),
        // ⚠️ Defaults to empty rather than throwing: a cached row written by
        // the Phase 2 build has no `actions` key, and a technician opening the
        // app after an update must see his work rather than a crash. An empty
        // list means *no acts offered*, which is the safe reading.
        actions: ((json['actions'] as List<dynamic>?) ?? const [])
            .map((act) => WorkOrderAction.fromJson(act as Map<String, dynamic>))
            .toList(growable: false),
        createdAt: _date(json['created_at']),
      );

  /// The server's own JSON for this row, untouched. Persisted by
  /// `WorkOrderStore` and decoded back through [WorkOrder.fromJson], so there
  /// is exactly **one** description of the payload in this app.
  final Map<String, dynamic> source;

  final String id;
  final String? reference;
  final String description;
  final Vocab status;
  final Vocab priority;
  final NamedRef? unit;
  final NamedRef? building;
  final String? blockNumber;
  final String? category;
  final String? subcategory;
  final List<NamedRef> technicians;
  final SlaState sla;
  final List<WorkOrderAction> actions;
  final DateTime? createdAt;

  /// The act with this name, or null when the server did not offer it at all.
  WorkOrderAction? action(String value) =>
      actions.where((act) => act.value == value).firstOrNull;

  /// Where the job is, in the words the operator would use: a unit number when
  /// there is one, otherwise the block, otherwise the building. A common-area
  /// job legitimately has no unit — `unit_id` is nullable and `building_id` is
  /// not.
  String get location {
    if (unit != null) return 'Unit ${unit!.name}';
    if (blockNumber != null && blockNumber!.isNotEmpty) return blockNumber!;
    return building?.name ?? 'Location not recorded';
  }
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

NamedRef? _ref(Object? value, String nameKey) {
  if (value is! Map<String, dynamic>) return null;

  return NamedRef(
    id: value['id'].toString(),
    name: value[nameKey]?.toString() ?? '',
  );
}
