/// SPEC-025 Step 6 — a person this job can be given to, as the server
/// describes him.
///
/// 🎯 **Nothing here is derived.** The server decides who may be offered, in
/// what order, and whether each one's trade matches the job — the same
/// division ADR-013 set for *which acts are available*. The app renders an
/// answer; it does not compute one.
class Assignee {
  const Assignee({
    required this.id,
    required this.name,
    required this.role,
    required this.trades,
    required this.matchesTrade,
  });

  factory Assignee.fromJson(Map<String, dynamic> json) => Assignee(
        id: json['id'] as int,
        name: json['name'] as String,
        role: json['role'] as String? ?? '',
        trades: ((json['trades'] as List?) ?? const []).map((t) => t as String).toList(),
        matchesTrade: json['matches_trade'] as bool?,
      );

  final int id;
  final String name;

  /// `technician` or `worker` — maintenance or cleaning. **Not** his trade.
  final String role;

  /// `electrical`, `plumbing`, `cleaning`, `other` — any number of them.
  final List<String> trades;

  /// 🔴 **Three states, and the third is the common one.**
  ///
  /// - `true` — he holds this job's trade;
  /// - `false` — he holds trades, none of them this one;
  /// - `null` — **nobody has recorded his trades**, or the job has no trade.
  ///
  /// ⚠️ `null` must never be rendered as `false`: *"we do not know what he
  /// does"* is a gap in Sandan's data, not a fact about the man. Every real
  /// field account is in this state until the account-provisioning screens
  /// exist.
  final bool? matchesTrade;

  /// What to show beside his name: his trades if any are recorded, else his
  /// role, which is the coarser fact and always present.
  String get label => trades.isNotEmpty ? trades.join(', ') : role;
}

/// The answer to *who can take this job*, with the question it was asked.
class AssigneeList {
  const AssigneeList({required this.people, required this.jobTrade});

  const AssigneeList.empty() : people = const [], jobTrade = null;

  factory AssigneeList.fromJson(Map<String, dynamic> json) => AssigneeList(
        people: ((json['data'] as List?) ?? const [])
            .map((row) => Assignee.fromJson(row as Map<String, dynamic>))
            .toList(),
        jobTrade: json['job_trade'] as String?,
      );

  final List<Assignee> people;

  /// The trade of the job the list was asked about, or `null` when the
  /// category carries none. 🎯 Kept so the screen can say *why* the order is
  /// what it is, instead of presenting an unexplained sort.
  final String? jobTrade;
}
