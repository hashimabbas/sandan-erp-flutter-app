import 'package:flutter/material.dart';

import '../data/local_database.dart';
import '../data/outbox.dart';
import '../data/queue_filters.dart';
import '../data/work_order_repository.dart';
import '../data/work_order_store.dart';
import '../models/assignee.dart';
import '../models/complaint_lookups.dart';
import '../models/work_order.dart';
import '../services/api_result.dart';
import '../services/complaint_service.dart';
import '../theme/app_colors.dart';
import '../widgets/task_row_tile.dart';
import 'work_order_screen.dart';

/// SPEC-024 Phase 5, Step 1 — **the Facility Manager's queue.**
///
/// 🎯 **The screen this phase was asked for.** Until now a manager opening this
/// app saw a *"Quick Action"* card and a notice that the figures live in the
/// browser. His own work — seeing what is open, late, or sitting with one man —
/// was not here at all.
///
/// 🔴 **Every filter is applied by the SERVER**, and that is Hashim's
/// constraint, not a preference: *"الفلاتر تنفذ في Backend. لا منطق تجميعي
/// للفلاتر في Flutter."* This screen holds a [QueueFilters] and asks for a
/// list; it never narrows, groups, counts or sorts one.
///
/// 🔴🔴 **And it reads through — it does not touch the cache.**
/// `WorkOrderRepository.queue()` writes nothing to sqflite, because
/// `WorkOrderStore.replaceFor()` deletes every row for the user before
/// inserting, and a filtered list is a subset by definition. Handing one to the
/// cache would delete the rest — Step 0's defect wearing a filter's hat.
/// ⚠️ So this screen has **no offline story on purpose**: a stale answer to a
/// filter set one second ago is worse than an honest refusal, because the
/// manager would act on it.
class QueueScreen extends StatefulWidget {
  const QueueScreen({
    super.key,
    required this.userId,
    required this.onSessionExpired,
    this.repository,
    this.service,
  });

  final int userId;
  final VoidCallback onSessionExpired;

  /// Injected by tests only.
  final WorkOrderSource? repository;
  final ComplaintService? service;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  late final WorkOrderSource _repository =
      widget.repository ??
      WorkOrderRepository(
        userId: widget.userId,
        store: WorkOrderStore(LocalDatabase.instance),
        outbox: Outbox(LocalDatabase.instance),
      );

  late final ComplaintService _service = widget.service ?? ComplaintService();

  QueueFilters _filters = const QueueFilters();

  bool _loading = true;
  String? _error;
  List<WorkOrder> _jobs = const [];

  // The option lists, every one of them from a lookup the server ALREADY
  // serves. ❌ Step 1 adds no endpoint.
  List<Vocab> _statuses = const [];
  List<Vocab> _priorities = const [];
  List<BuildingLookup> _buildings = const [];
  List<ComplaintCategoryLookup> _categories = const [];
  List<Assignee> _technicians = const [];

  /// 🔴 **The technician control is ABSENT, not empty, when its options are not
  /// served.** `lookup/assignees` is guarded by `facility.work_orders.assign`,
  /// which the manager and the supervisor hold and a read-only holder of
  /// `work_orders.view` would not.
  ///
  /// ⚠️ **A known imprecision, recorded rather than papered over:**
  /// `ComplaintService.fetchAssignees()` returns an **empty list** when the
  /// lookup fails, by an earlier deliberate decision — so *"you may not see
  /// the staff list"* and *"the staff list is empty"* arrive here as the same
  /// value. Hiding the control on empty is therefore right for the permission
  /// case and also hides it in a system with no technicians at all. ❌ Not
  /// fixed by minting a permission; it is one fewer control, never a 403 for
  /// the user to interpret.
  bool get _canFilterByTechnician => _technicians.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadOptions();
    _load();
  }

  /// 🔴 **Each option list is loaded INDEPENDENTLY, and that is a defect
  /// fixed rather than a style.**
  ///
  /// This method first awaited all four lookups and then called `setState`
  /// once. The four do not share a failure: `fetchBuildings()` and
  /// `fetchCategories()` throw on an unexpected payload, and
  /// `fetchVocabulary()` throws on any non-200. So **one failing lookup
  /// removed all seven filter controls**, silently, leaving a bar of empty
  /// *"Any…"* dropdowns and no reason given. ⚠️ A manager would read that
  /// as *the system has no buildings*.
  ///
  /// 🎯 Now a lookup that fails costs **its own control and nothing else**,
  /// which is the same principle the technician control already followed and
  /// the same one `fetchAssignees()` chose years earlier when it decided to
  /// return an empty list rather than throw.
  Future<void> _loadOptions() async {
    await Future.wait([
      _option(() async {
        final vocabulary = await _service.fetchVocabulary();

        if (mounted) {
          setState(() {
            _statuses = vocabulary.statuses;
            _priorities = vocabulary.priorities;
          });
        }
      }),
      _option(() async {
        final buildings = await _service.fetchBuildings();

        if (mounted) setState(() => _buildings = buildings);
      }),
      _option(() async {
        final categories = await _service.fetchCategories();

        if (mounted) setState(() => _categories = categories);
      }),
      _option(() async {
        final assignees = await _service.fetchAssignees();

        if (mounted) setState(() => _technicians = assignees.people);
      }),
    ]);
  }

  /// ⚠️ **Swallowing is correct HERE and nowhere else on this screen.** An
  /// option list is a convenience: without it the user loses one control. The
  /// QUEUE itself never swallows anything — a failed `queue()` shows the
  /// server's own sentence and a retry, because an empty list presented as an
  /// answer is the lie this whole Step exists to stop telling.
  Future<void> _option(Future<void> Function() load) async {
    try {
      await load();
    } catch (_) {
      // The control simply does not appear. Nothing is claimed about the data.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await _repository.queue(_filters);

    if (!mounted) return;

    switch (result) {
      case ApiSuccess(:final data):
        setState(() {
          _jobs = data;
          _loading = false;
        });

      case ApiFailure(:final kind, :final message):
        if (kind == ApiErrorKind.sessionExpired) {
          widget.onSessionExpired();

          return;
        }

        setState(() {
          _error = message;
          _loading = false;
        });
    }
  }

  void _apply(QueueFilters next) {
    setState(() => _filters = next);

    _load();
  }

  List<ComplaintSubcategoryLookup> get _subcategoriesInScope {
    if (_filters.categoryId == null) return const [];

    return _categories
            .where((category) => category.id == _filters.categoryId)
            .firstOrNull
            ?.subcategories ??
        const [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Work Queue'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(
            filters: _filters,
            statuses: _statuses,
            priorities: _priorities,
            buildings: _buildings,
            categories: _categories,
            subcategories: _subcategoriesInScope,
            technicians: _technicians,
            showTechnician: _canFilterByTechnician,
            onChanged: _apply,
          ),
          const Divider(height: 1, color: AppColors.divider),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 14),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }

    if (_jobs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _filters.isEmpty
                ? 'There is no work in the system right now.'
                // ⚠️ The empty state says WHY it is empty. "Nothing here"
                // after a filter is set reads as *there is no work*, which is
                // a different and much worse claim.
                : 'No work matches these filters.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _jobs.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.divider),
      itemBuilder: (context, index) {
        final job = _jobs[index];

        return TaskRowTile(
          icon: Icons.assignment_outlined,
          title: job.reference ?? job.description,
          subtitle: _subtitle(job),
          status: job.status,
          // ⚠️ Never a breach judgement: that boolean is computed by the ERP.
          time: job.sla.assignmentBreached || job.sla.arrivalBreached ? 'Late' : job.priority.label,
          // 🔧 **SPEC-024 Phase 5, Step 3 — the list reloads when he comes
          // back** (Hashim, 2026-11-19). A job he has just handed to somebody
          // may no longer match the filter he is standing in — *unassigned*
          // being the obvious one — and the row **disappearing** is the
          // correct outcome: this screen is read-through with no offline
          // story by design, and a stale row is one a manager would act on.
          //
          // ⚠️ It reloads on EVERY return, not only after an act. This
          // screen cannot know what happened inside, and one request on a
          // back-press is cheaper than a rule that guesses.
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => WorkOrderScreen(
                  id: job.id,
                  repository: _repository,
                  onSessionExpired: widget.onSessionExpired,
                ),
              ),
            );

            if (mounted) await _load();
          },
        );
      },
    );
  }

  String _subtitle(WorkOrder job) {
    final who = job.technicians.isEmpty
        ? 'Unassigned'
        : job.technicians.map((person) => person.name).join(', ');

    return '${job.location} · $who';
  }
}

/// The seven controls, in the order Hashim set on 2026-11-18.
///
/// ⚠️ `breached` is last because it is a different **kind** of control — a
/// boolean, not a value picker — not because it matters least. It is the
/// filter a dispatcher reaches for first.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filters,
    required this.statuses,
    required this.priorities,
    required this.buildings,
    required this.categories,
    required this.subcategories,
    required this.technicians,
    required this.showTechnician,
    required this.onChanged,
  });

  final QueueFilters filters;
  final List<Vocab> statuses;
  final List<Vocab> priorities;
  final List<BuildingLookup> buildings;
  final List<ComplaintCategoryLookup> categories;
  final List<ComplaintSubcategoryLookup> subcategories;
  final List<Assignee> technicians;
  final bool showTechnician;
  final ValueChanged<QueueFilters> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _Picker<Vocab>(
            key: const Key('filter-status'),
            label: 'Status',
            value: statuses.where((s) => s.value == filters.status).firstOrNull,
            options: statuses,
            labelOf: (status) => status.label,
            onChanged: (status) => onChanged(
              status == null
                  ? filters.copyWith(clear: const {'status'})
                  : filters.copyWith(status: status.value),
            ),
          ),
          _Picker<Vocab>(
            key: const Key('filter-priority'),
            label: 'Priority',
            value: priorities.where((p) => p.value == filters.priority).firstOrNull,
            options: priorities,
            labelOf: (priority) => priority.label,
            onChanged: (priority) => onChanged(
              priority == null
                  ? filters.copyWith(clear: const {'priority'})
                  : filters.copyWith(priority: priority.value),
            ),
          ),
          _Picker<BuildingLookup>(
            key: const Key('filter-building'),
            label: 'Building',
            value: buildings.where((b) => b.id == filters.buildingId).firstOrNull,
            options: buildings,
            labelOf: (building) => building.name,
            onChanged: (building) => onChanged(
              building == null
                  ? filters.copyWith(clear: const {'building_id'})
                  : filters.copyWith(buildingId: building.id),
            ),
          ),
          _Picker<ComplaintCategoryLookup>(
            key: const Key('filter-category'),
            label: 'Category',
            value: categories.where((c) => c.id == filters.categoryId).firstOrNull,
            options: categories,
            labelOf: (category) => category.name,
            // 🔧 Changing the category CLEARS the subcategory. The server
            // refuses a subcategory from another category as a CONTRADICTION
            // (422), so leaving the old one behind would send a contradiction
            // the user never typed.
            onChanged: (category) => onChanged(filters.withCategory(category?.id)),
          ),
          // The subcategory control appears only once a category is chosen:
          // the server's own rule is that the two must agree.
          if (filters.categoryId != null)
            _Picker<ComplaintSubcategoryLookup>(
              key: const Key('filter-subcategory'),
              label: 'Subcategory',
              value: subcategories.where((s) => s.id == filters.subcategoryId).firstOrNull,
              options: subcategories,
              labelOf: (subcategory) => subcategory.name,
              onChanged: (subcategory) => onChanged(
                subcategory == null
                    ? filters.copyWith(clear: const {'subcategory_id'})
                    : filters.copyWith(subcategoryId: subcategory.id),
              ),
            ),
          if (showTechnician)
            _Picker<Assignee>(
              key: const Key('filter-technician'),
              label: 'Technician',
              value: technicians.where((t) => t.id == filters.technicianId).firstOrNull,
              options: technicians,
              labelOf: (person) => person.name,
              onChanged: (person) => onChanged(
                person == null
                    ? filters.copyWith(clear: const {'technician_id'})
                    : filters.copyWith(technicianId: person.id),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: FilterChip(
              key: const Key('filter-breached'),
              label: const Text('Late'),
              selected: filters.breached,
              onSelected: (on) => onChanged(filters.copyWith(breached: on)),
            ),
          ),
          if (!filters.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: TextButton(
                key: const Key('filter-clear'),
                onPressed: () => onChanged(const QueueFilters()),
                child: const Text('Clear'),
              ),
            ),
        ],
      ),
    );
  }
}

class _Picker<T> extends StatelessWidget {
  const _Picker({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final T? value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DropdownButton<T?>(
        value: value,
        hint: Text(label, style: const TextStyle(fontSize: 12.5)),
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(14),
        dropdownColor: AppColors.surfaceElevated,
        items: [
          DropdownMenuItem<T?>(key: Key('$label-any'), value: null, child: Text('Any $label')),
          for (final option in options)
            DropdownMenuItem<T?>(
              // ⚠️ Keyed per control AND per option. A widget test cannot
              // select by visible text here: a status label such as *Assigned*
              // is also printed by every row in the list behind the menu, so
              // `find.text` is ambiguous by construction rather than by
              // accident.
              key: Key('$label-option-${labelOf(option)}'),
              value: option,
              child: Text(labelOf(option)),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}
