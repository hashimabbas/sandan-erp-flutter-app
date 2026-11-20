/// SPEC-024 Phase 5, Step 1 — the Facility Manager's queue filters, as the one
/// place in this app that knows their names.
///
/// 🔴 **Every filter here is applied by the SERVER.** Nothing in this class
/// groups, counts, sorts or narrows a list: it turns a set of choices into
/// query parameters and does nothing else. Filtering a cached list in Dart
/// would be a second answer to a question the ERP already answers — and it
/// would answer it from a snapshot, which is worse than not answering.
///
/// ⚠️ **The parameter names are the server's contract**, and they are written
/// once, here. `WorkOrderQueueFilters` in the ERP validates exactly these EIGHT
/// keys; a name typed a second time somewhere else in `lib/` is how the two
/// drift apart.
///
/// 🎯 **A null field is an ABSENT parameter, never an empty one.** The server
/// normalises `?status=` to absence as well, but sending it at all would be
/// this app asserting a filter it does not have.
class QueueFilters {
  const QueueFilters({
    this.status,
    this.priority,
    this.buildingId,
    this.categoryId,
    this.subcategoryId,
    this.technicianId,
    this.breached = false,
    this.arrival,
  });

  final String? status;
  final String? priority;
  final String? buildingId;
  final String? categoryId;
  final String? subcategoryId;

  /// 🔴 **An int, not a UUID.** `users.id` in the ERP is a bigint while every
  /// other id in this module is a UUID — the server validates this key as an
  /// integer, and a UUID here is a 422.
  final int? technicianId;

  /// Whether to show only jobs the server judges late.
  ///
  /// ⚠️ **The server decides what "late" means** — it is a domain judgement
  /// over extensions, pauses and referrals, not a date comparison. This app
  /// asks the question and never answers it.
  final bool breached;

  /// SPEC-038 — which of today's arrival outcomes to show: `in_time`,
  /// `late` or `not_recorded`.
  ///
  /// 🔴 **A string, validated by the SERVER against its enum.** The three
  /// values are the ERP's, and `?arrival=nonsense` is a 422 there rather than
  /// a parameter quietly ignored — so this app never has to decide what an
  /// unknown value means.
  final String? arrival;

  bool get isEmpty =>
      status == null &&
      priority == null &&
      buildingId == null &&
      categoryId == null &&
      subcategoryId == null &&
      technicianId == null &&
      arrival == null &&
      !breached;

  /// The query parameters, with every unset filter left out entirely.
  Map<String, String> toQuery() => {
    'status': ?status,
    'priority': ?priority,
    'building_id': ?buildingId,
    'category_id': ?categoryId,
    'subcategory_id': ?subcategoryId,
    'technician_id': ?technicianId?.toString(),
    'arrival': ?arrival,
    if (breached) 'breached': '1',
  };

  QueueFilters copyWith({
    String? status,
    String? priority,
    String? buildingId,
    String? categoryId,
    String? subcategoryId,
    int? technicianId,
    bool? breached,
    String? arrival,
    Set<String> clear = const {},
  }) => QueueFilters(
    status: clear.contains('status') ? null : (status ?? this.status),
    priority: clear.contains('priority') ? null : (priority ?? this.priority),
    buildingId: clear.contains('building_id') ? null : (buildingId ?? this.buildingId),
    categoryId: clear.contains('category_id') ? null : (categoryId ?? this.categoryId),
    subcategoryId: clear.contains('subcategory_id') ? null : (subcategoryId ?? this.subcategoryId),
    technicianId: clear.contains('technician_id') ? null : (technicianId ?? this.technicianId),
    breached: clear.contains('breached') ? false : (breached ?? this.breached),
    arrival: clear.contains('arrival') ? null : (arrival ?? this.arrival),
  );

  /// 🔧 **Clearing the category clears the subcategory with it.**
  ///
  /// The server refuses `category_id=A` with a subcategory of B as a
  /// **contradiction** — a 422, not an empty list. So a screen that changed the
  /// category and left the old subcategory behind would send a contradiction
  /// the user never typed. ⚠️ This is the one piece of filter *logic* in the
  /// app, and it is here rather than in a widget because it is a property of
  /// the filter set, not of a dropdown.
  QueueFilters withCategory(String? categoryId) => copyWith(
    categoryId: categoryId,
    clear: {'subcategory_id', if (categoryId == null) 'category_id'},
  );
}
