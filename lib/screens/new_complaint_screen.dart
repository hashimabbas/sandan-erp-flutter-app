import 'package:flutter/material.dart';

import '../data/local_database.dart';
import '../data/outbox.dart';
import '../data/work_order_repository.dart';
import '../data/work_order_store.dart';
import '../models/complaint_lookups.dart';
import '../models/work_order.dart' show Vocab;
import '../models/assignee.dart';
import '../services/complaint_service.dart';
import '../widgets/assignee_picker.dart';
import '../theme/app_colors.dart';
import '../widgets/animated_gradient_background.dart';
import '../widgets/glass_card.dart';
import '../widgets/party_picker.dart';
import '../widgets/premium_button.dart';

/// SPEC-004: Facility Manager creates a complaint. Building/Unit/Category/
/// Tenant/Owner are all ERP master data fetched read-only from the new
/// `/api/facility/complaints/*` endpoints — nothing here is invented
/// client-side, and Tenant/Owner is always a real selected record, never
/// free text (§4.2). Photo upload is intentionally not built (§4.4,
/// deferred).
class NewComplaintScreen extends StatefulWidget {
  /// SPEC-025 Step 6 — `service` is injectable because this screen had **no
  /// widget tests at all**: it built its own `ComplaintService`, which reaches
  /// for the network and for secure storage, and neither exists under
  /// `flutter test`.
  ///
  /// 🔧 **SPEC-024 Phase 5, Step 3 — it now takes a `userId` and a
  /// repository too.** Assigning moved off `ComplaintService` and onto the
  /// one sender in `WorkOrderSource`, and that sender caches the row the
  /// server returns **per user**, so the screen that uses it must know whose
  /// phone this is. The id is threaded from `HomeScreen`, which already holds
  /// it for the queue.
  const NewComplaintScreen({
    super.key,
    required this.userId,
    this.service,
    this.repository,
  });

  final int userId;

  final ComplaintService? service;

  /// Injected by tests only.
  final WorkOrderSource? repository;

  @override
  State<NewComplaintScreen> createState() => _NewComplaintScreenState();
}

class _NewComplaintScreenState extends State<NewComplaintScreen> {
  late final ComplaintService _service = widget.service ?? ComplaintService();

  late final WorkOrderSource _repository =
      widget.repository ??
      WorkOrderRepository(
        userId: widget.userId,
        store: WorkOrderStore(LocalDatabase.instance),
        outbox: Outbox(LocalDatabase.instance),
      );
  final _descriptionController = TextEditingController();
  final _blockController = TextEditingController();

  bool _loadingLookups = true;
  bool _submitting = false;
  String? _loadError;
  Map<String, String>? _fieldErrors;
  String? _submitError;

  List<BuildingLookup> _buildings = [];
  List<ComplaintCategoryLookup> _categories = [];

  BuildingLookup? _selectedBuilding;
  UnitLookup? _selectedUnit;
  List<UnitLookup> _units = [];
  bool _loadingUnits = false;

  ComplaintCategoryLookup? _selectedCategory;
  ComplaintSubcategoryLookup? _selectedSubcategory;

  AssigneeList _assignees = const AssigneeList.empty();
  Set<int> _chosenAssignees = {};
  bool _loadingAssignees = false;

  List<PartyLookup> _tenants = [];
  List<PartyLookup> _owners = [];
  bool _loadingParties = false;
  PartyLookup? _selectedTenant;
  PartyLookup? _selectedOwner;

  /// 🔴 **SPEC-024 Phase 1, Step 2 — this was `String _priority = 'medium'`.**
  ///
  /// `'medium'` is not a value the server accepts: D3 renamed it to `'normal'`
  /// in SPEC-018, and every complaint raised from a phone has been translated
  /// since by a dated alias in `StoreFacilityComplaintRequest` written for
  /// exactly this screen. The vocabulary now comes from the server, so the
  /// default is **whatever it lists first** — mirroring the web's own create
  /// form, which uses `priorities[0]?.value`.
  ///
  /// Null until the vocabulary arrives: the app has no opinion to fall back on.
  String? _priority;
  List<Vocab> _priorities = const [];

  @override
  void initState() {
    super.initState();
    _loadLookups();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _blockController.dispose();
    super.dispose();
  }

  Future<void> _loadLookups() async {
    setState(() {
      _loadingLookups = true;
      _loadError = null;
    });
    try {
      final buildings = await _service.fetchBuildings();
      final categories = await _service.fetchCategories();
      final vocabulary = await _service.fetchVocabulary();
      if (!mounted) return;
      setState(() {
        _buildings = buildings;
        _categories = categories;
        _priorities = vocabulary.priorities;
        // 🎯 The server's order decides the default, exactly as the web's
        // create form does. Nothing here names a priority.
        _priority = vocabulary.priorities.isEmpty ? null : vocabulary.priorities.first.value;
        _loadingLookups = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load the form. Check your connection and try again.';
        _loadingLookups = false;
      });
    }
  }

  void _clearError(String field) {
    if (_fieldErrors == null || !_fieldErrors!.containsKey(field)) return;
    setState(() {
      _fieldErrors = {..._fieldErrors!}..remove(field);
      if (_fieldErrors!.isEmpty) _submitError = null;
    });
  }

  Future<void> _onBuildingChanged(BuildingLookup? building) async {
    _clearError('building_id');
    setState(() {
      _selectedBuilding = building;
      _selectedUnit = null;
      _units = [];
      _tenants = [];
      _owners = [];
      _selectedTenant = null;
      _selectedOwner = null;
    });
    if (building == null) return;
    setState(() => _loadingUnits = true);
    final units = await _service.fetchUnits(building.id);
    if (!mounted) return;
    setState(() {
      _units = units;
      _loadingUnits = false;
    });
  }

  Future<void> _onUnitChanged(UnitLookup? unit) async {
    _clearError('tenant_id');
    setState(() {
      _selectedUnit = unit;
      _tenants = [];
      _owners = [];
      _selectedTenant = null;
      _selectedOwner = null;
    });
    if (unit == null) return;
    setState(() => _loadingParties = true);
    final parties = await _service.fetchRelatedParties(unit.id);
    if (!mounted) return;
    setState(() {
      _tenants = parties.tenants;
      _owners = parties.owners;
      _loadingParties = false;
    });
  }

  /// SPEC-025 Step 6 - who can take this job.
  ///
  /// ⚠️ Failure is silent by design: the picker is OPTIONAL, and a complaint
  /// that could not be logged because a convenience lookup failed would be a
  /// worse outcome than one logged with nobody assigned. The service returns
  /// an empty list rather than throwing.
  Future<void> _loadAssignees() async {
    setState(() => _loadingAssignees = true);

    final list = await _service.fetchAssignees(categoryId: _selectedCategory?.id);

    if (!mounted) return;

    setState(() {
      _assignees = list;
      _loadingAssignees = false;
      // 🔴 Anybody who is no longer offered is dropped from the choice.
      // Keeping an id the server did not return would send an assignment
      // nobody on this screen could see.
      _chosenAssignees = _chosenAssignees
          .where((id) => list.people.any((person) => person.id == id))
          .toSet();
    });
  }

  /// Field-key -> message, matching the keys the backend's validation
  /// errors use, so the same inline error text shows either way — the only
  /// difference is this catches it before a round trip to the server.
  Map<String, String> _localValidationErrors() {
    final errors = <String, String>{};
    if (_selectedBuilding == null) errors['building_id'] = 'Select a building.';
    if (_selectedCategory == null) errors['category_id'] = 'Select a category.';
    if (_selectedCategory != null && _selectedSubcategory == null) {
      errors['subcategory_id'] = 'Select a subcategory.';
    }
    if (_descriptionController.text.trim().isEmpty) {
      errors['description'] = 'Describe the problem.';
    }
    // 🔴 SPEC-024 Phase 1, Step 2. The priority used to be a Dart constant, so
    // it could never be missing — it was merely WRONG. Now that the list comes
    // from the server, 'not loaded yet' is a real state, and it is validated
    // rather than forced with a `!`: a form that crashes because a lookup
    // failed is worse than one that says what is missing.
    if (_priority == null) {
      errors['priority'] = 'Select a priority.';
    }
    if (_selectedUnit != null && _selectedTenant == null && _selectedOwner == null) {
      errors['tenant_id'] = 'Select a tenant or owner for a unit-level complaint.';
    }
    return errors;
  }

  Future<void> _submit() async {
    final localErrors = _localValidationErrors();
    if (localErrors.isNotEmpty) {
      setState(() {
        _fieldErrors = localErrors;
        _submitError = 'Please fill in the required fields highlighted below.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _submitError = null;
      _fieldErrors = null;
    });

    final result = await _service.createComplaint(
      buildingId: _selectedBuilding!.id,
      unitId: _selectedUnit?.id,
      blockNumber: _selectedUnit == null ? _blockController.text.trim() : null,
      tenantId: _selectedTenant?.id,
      ownerId: _selectedOwner?.id,
      categoryId: _selectedCategory!.id,
      subcategoryId: _selectedSubcategory!.id,
      description: _descriptionController.text.trim(),
      priority: _priority!,
      technicianIds: _chosenAssignees.toList(),
    );

    if (!mounted) return;

    if (result.success) {
      // 🎯 SPEC-025 Step 6, option (a). The app has no complaint queue -
      // that is Phase 5 - so the only moment it can offer to assign a job it
      // just logged is now. Without this, "optional" would have meant "never,
      // from this app".
      final assignedNow = _chosenAssignees.isNotEmpty;

      if (!assignedNow && result.complaintId != null && _assignees.people.isNotEmpty) {
        await _offerToAssign(result.complaintId!);
      }

      if (!mounted) return;

      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            assignedNow ? 'Complaint logged and assigned.' : 'Complaint logged successfully.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _submitting = false;
      _submitError = result.message;
      _fieldErrors = result.fieldErrors;
    });
  }

  /// SPEC-025 Step 6 - the one chance this app has to assign a job.
  ///
  /// 🔴 **Not queued, and it says so before he tries.** An outbox item is a
  /// technician's own field act; a manager assigning work he cannot see
  /// confirmed is a promise this app cannot keep - the same rule the password
  /// change follows.
  Future<void> _offerToAssign(String complaintId) async {
    var chosen = <int>{};
    String? error;
    var sending = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Assign it now?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The complaint is logged. You can hand it to somebody now, or leave it unassigned.',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 4),
              const Text(
                'Assigning needs a connection - it is not saved on this phone.',
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
              const SizedBox(height: 14),
              AssigneePicker(
                list: _assignees,
                selected: chosen,
                onChanged: (next) => setDialogState(() => chosen = next),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: sending ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: chosen.isEmpty || sending
                  ? null
                  : () async {
                      setDialogState(() {
                        sending = true;
                        error = null;
                      });

                      // 🔧 **Step 3: the one sender.** Same endpoint, same
                      // refusal sentences — and now the cache learns the
                      // job is assigned instead of being told nothing.
                      final result = await _repository.assign(
                        complaintId,
                        chosen.toList(),
                      );

                      if (!dialogContext.mounted) return;

                      if (result.outcome == ActOutcome.applied) {
                        Navigator.of(dialogContext).pop();
                        return;
                      }

                      setDialogState(() {
                        sending = false;
                        error = result.message ?? 'Could not assign this job.';
                      });
                    },
              child: const Text('Assign'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedGradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                    ),
                    const Text(
                      'New Complaint',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loadingLookups) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accentSoft),
      );
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _loadError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              TextButton(onPressed: _loadLookups, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _FieldLabel('Location'),
            _Dropdown<BuildingLookup>(
              hint: 'Select building',
              value: _selectedBuilding,
              items: _buildings,
              labelOf: (b) => b.name,
              onChanged: _onBuildingChanged,
            ),
            _FieldError(_fieldErrors?['building_id']),
            const SizedBox(height: 10),
            if (_selectedBuilding != null) ...[
              _loadingUnits
                  ? const _InlineLoading()
                  : _Dropdown<UnitLookup>(
                      hint: 'Unit (optional — leave empty for a common area)',
                      value: _selectedUnit,
                      items: _units,
                      labelOf: (u) => u.unitNumber,
                      onChanged: _onUnitChanged,
                      nullable: true,
                    ),
              if (_selectedUnit == null) ...[
                const SizedBox(height: 10),
                _TextInput(
                  controller: _blockController,
                  hint: 'Block / common area (optional)',
                ),
              ],
            ],
            if (_selectedUnit != null) ...[
              const SizedBox(height: 18),
              const _FieldLabel('Tenant / Owner — select at least one'),
              if (_loadingParties)
                const _InlineLoading()
              else ...[
                PartyPicker(
                  type: 'tenant',
                  label: 'Tenant',
                  suggested: _tenants,
                  selected: _selectedTenant,
                  onChanged: (p) {
                    _clearError('tenant_id');
                    setState(() => _selectedTenant = p);
                  },
                ),
                const SizedBox(height: 12),
                PartyPicker(
                  type: 'owner',
                  label: 'Owner',
                  suggested: _owners,
                  selected: _selectedOwner,
                  onChanged: (p) {
                    _clearError('tenant_id');
                    setState(() => _selectedOwner = p);
                  },
                ),
              ],
            ],
            const SizedBox(height: 18),
            const _FieldLabel('Category'),
            _Dropdown<ComplaintCategoryLookup>(
              hint: 'Select category',
              value: _selectedCategory,
              items: _categories,
              labelOf: (c) => c.name,
              onChanged: (c) {
                _clearError('category_id');
                _clearError('subcategory_id');
                setState(() {
                  _selectedCategory = c;
                  _selectedSubcategory = null;
                });
                // SPEC-025 Step 6 - the category carries the job's trade, so
                // the list of people is re-asked whenever it changes. The
                // ordering is the server's; this screen only renders it.
                _loadAssignees();
              },
            ),
            _FieldError(_fieldErrors?['category_id']),
            if (_selectedCategory != null) ...[
              const SizedBox(height: 10),
              _Dropdown<ComplaintSubcategoryLookup>(
                hint: 'Select subcategory',
                value: _selectedSubcategory,
                items: _selectedCategory!.subcategories,
                labelOf: (s) => s.name,
                onChanged: (s) {
                  _clearError('subcategory_id');
                  setState(() => _selectedSubcategory = s);
                },
              ),
              _FieldError(_fieldErrors?['subcategory_id']),
            ],
            const SizedBox(height: 18),
            const _FieldLabel('Priority'),
            _PrioritySelector(
              options: _priorities,
              value: _priority,
              onChanged: (p) => setState(() => _priority = p),
            ),
            const SizedBox(height: 18),
            AssigneePicker(
              list: _assignees,
              selected: _chosenAssignees,
              loading: _loadingAssignees,
              onChanged: (next) => setState(() => _chosenAssignees = next),
            ),
            _FieldError(_fieldErrors?['technician_ids']),
            const SizedBox(height: 18),
            const _FieldLabel('Problem Description'),
            _TextInput(
              controller: _descriptionController,
              hint: 'Describe the problem…',
              maxLines: 4,
              errorText: _fieldErrors?['description'],
              onChanged: (_) {
                _clearError('description');
                setState(() {});
              },
            ),
            if (_selectedUnit != null) _FieldError(_fieldErrors?['tenant_id']),
            if (_submitError != null) ...[
              const SizedBox(height: 14),
              Text(
                _submitError!,
                style: const TextStyle(color: AppColors.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 22),
            PremiumButton(
              label: 'Submit Complaint',
              loading: _submitting,
              onPressed: _submitting ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _FieldError extends StatelessWidget {
  const _FieldError(this.message);

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        message!,
        style: const TextStyle(color: AppColors.error, fontSize: 12),
      ),
    );
  }
}

class _InlineLoading extends StatelessWidget {
  const _InlineLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentSoft),
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.hint,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
    this.nullable = false,
    super.key,
  });

  final String hint;
  final T? value;
  final List<T> items;
  final String Function(T) labelOf;
  final void Function(T?) onChanged;
  final bool nullable;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.glassFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          value: value,
          hint: Text(hint, style: const TextStyle(color: AppColors.textMuted, fontSize: 13.5)),
          dropdownColor: const Color(0xFF1B0F22),
          iconEnabledColor: AppColors.textSecondary,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 13.5),
          items: [
            if (nullable)
              const DropdownMenuItem(value: null, child: Text('— None —')),
            ...items.map(
              (item) => DropdownMenuItem(value: item, child: Text(labelOf(item))),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  const _TextInput({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.errorText,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final String? errorText;
  final void Function(String)? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.glassFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: errorText != null ? AppColors.error : AppColors.glassBorder,
          width: 1,
        ),
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        onChanged: onChanged,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 13.5),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13.5),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
    );
  }
}

/// 🔴 **SPEC-024 Phase 1, Step 2 — this held a `static const _options` of
/// THREE tuples: `low`, `medium`, `high`.**
///
/// The server has **four** priorities, and `medium` is not one of them. So the
/// list was simultaneously wrong and short: `emergency` could not be chosen
/// from a phone at all, and the one value the screen defaulted to was the one
/// the server had stopped accepting.
///
/// ⚠️ **Colour stays here, and that is deliberate.** It is presentation, and
/// the server's own `ComplaintPriority::color()` returns Tailwind class names
/// a Flutter app cannot use. But the map must be **total**: an unknown value
/// renders in a neutral colour **with the server's label**, never silently
/// dropped and never recoloured into looking ordinary.
class _PrioritySelector extends StatelessWidget {
  const _PrioritySelector({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<Vocab> options;
  final String? value;
  final void Function(String) onChanged;

  /// Keyed on the SERVER's value. A priority this build has never heard of
  /// still renders — in the fallback colour, under its own label.
  static const _colors = <String, Color>{
    'low': Color(0xFF5FA8E7),
    'normal': Color(0xFFE7C07B),
    'high': Color(0xFFFF6B6B),
    'emergency': Color(0xFFFF3B3B),
  };

  static const _unknownColor = Color(0xFF8A94A6);

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();

    return Row(
      children: [
        for (final option in options)
          Expanded(
            child: Padding(
              // ⚠️ Was `key == 'high' ? 0 : 8`, which assumed `high` was last.
              // With four priorities it no longer is.
              padding: EdgeInsets.only(right: option == options.last ? 0 : 8),
              child: GestureDetector(
                onTap: () => onChanged(option.value),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: value == option.value
                        ? _colorFor(option.value).withValues(alpha: 0.22)
                        : AppColors.glassFill,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: value == option.value ? _colorFor(option.value) : AppColors.glassBorder,
                      width: 1.4,
                    ),
                  ),
                  child: Text(
                    // The SERVER's label, never one derived in Dart.
                    option.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: value == option.value ? _colorFor(option.value) : AppColors.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Color _colorFor(String value) => _colors[value] ?? _unknownColor;
}
