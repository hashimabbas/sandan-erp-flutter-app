/// SPEC-024 Phase 5, Step 4 — the four figures the manager asked for.
///
/// 🔴 **The server counts them; this class only carries them.** Every number
/// here is an integer the ERP computed over a query `scopeVisibleTo()` had
/// already narrowed — so a technician who reaches the same endpoint gets his
/// own four, and this app never adds, filters or derives one of them.
///
/// 🎯 **There is no `fromJson` fallback to zero, and that is the point.** This
/// screen once showed four counts that were not real, and the notice that
/// replaced them read *"They have been removed rather than left to be
/// quoted."* A missing key is a malformed payload, not a zero — so parsing
/// throws, the caller catches, and the screen shows **no figure at all**.
/// SPEC-038 — today's arrival promise, in the three states this system can
/// tell apart.
///
/// 🔴🔴 **This block is OPTIONAL while the four figures are required, and the
/// difference is deliberate.** The four have always been there, so a missing
/// key among them is a malformed payload. This one is new, and **the two
/// repositories deploy independently**: parsing it as required would mean a
/// newer app against a server without SPEC-038 throws and the manager loses
/// **all four** figures he has today. Absent block ⇒ no card.
///
/// ⚠️ **The three are three answers, never a partition.** A job reopened and
/// re-promised in one day can appear in two of them, because both promises
/// were made and both outcomes are true — so nothing here sums them.
class ArrivalToday {
  const ArrivalToday({
    required this.inTime,
    required this.late,
    required this.notRecorded,
  });

  factory ArrivalToday.fromJson(Map<String, dynamic> json) => ArrivalToday(
        inTime: json['in_time'] as int,
        late: json['late'] as int,
        notRecorded: json['not_recorded'] as int,
      );

  final int inTime;

  /// 🔴 **Proved late — an arrival that was RECORDED and was after the
  /// deadline.** The server never counts a job nobody arrived at here: that
  /// job is [notRecorded], and conflating the two is what SPEC-038 exists to
  /// prevent.
  final int late;

  final int notRecorded;
}

class WorkOrderSummary {
  const WorkOrderSummary({
    required this.open,
    required this.inProgress,
    required this.completedToday,
    required this.overdueAssignment,
    this.arrivalToday,
  });

  factory WorkOrderSummary.fromJson(Map<String, dynamic> json) => WorkOrderSummary(
        open: json['open'] as int,
        inProgress: json['in_progress'] as int,
        completedToday: json['completed_today'] as int,

        /// ⚠️ **Assignment breaches alone**, and the screen must name it so.
        /// The queue's `breached` filter is a wider set — assignment OR
        /// arrival — so a tile labelled *Late* would open a longer list than
        /// its own number promised.
        overdueAssignment: json['overdue_assignment'] as int,

        /// 🔴 **Optional, unlike the four above.** `?[...]` would be wrong
        /// here too: the key's absence means an older server, and its
        /// presence with a missing inner key means a broken payload — so the
        /// block is parsed strictly once it exists at all.
        arrivalToday: json['arrival_today'] == null
            ? null
            : ArrivalToday.fromJson(json['arrival_today'] as Map<String, dynamic>),
      );

  final int open;
  final int inProgress;
  final int completedToday;
  final int overdueAssignment;

  /// Null when the server has not shipped SPEC-038 — **never a zeroed
  /// block**, which would be this app asserting three figures nobody counted.
  final ArrivalToday? arrivalToday;
}
