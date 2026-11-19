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
class WorkOrderSummary {
  const WorkOrderSummary({
    required this.open,
    required this.inProgress,
    required this.completedToday,
    required this.overdueAssignment,
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
      );

  final int open;
  final int inProgress;
  final int completedToday;
  final int overdueAssignment;
}
