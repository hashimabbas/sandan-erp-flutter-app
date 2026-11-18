import 'dart:async';

import 'package:flutter/material.dart';

import '../models/complaint_lookups.dart';
import '../services/complaint_service.dart';
import '../theme/app_colors.dart';

/// Tenant/Owner picker for the New Complaint form: shows "suggested"
/// records tied to the selected unit (if any), plus a manual search field
/// that queries the same ERP records — mirroring the web Reception form's
/// ReceptionEntitySelector, which always offers manual search regardless of
/// whether a suggestion exists. Selection is always a real ERP record;
/// there is no free-text fallback (SPEC-004 §4.2).
class PartyPicker extends StatefulWidget {
  /// SPEC-025 Step 7 — what the app says when a unit has nobody on record.
  ///
  /// 🔴 **Until today it said nothing**: with no suggestions it rendered a
  /// bare search box, so the screen read as *"this system cannot do that"*
  /// when the truth was *"this unit has nobody on record yet"*. The web has
  /// always said the second. Hashim reported the symptom — having to type the
  /// name — and this is the half of it that was a real defect.
  ///
  /// ⚠️ **A named constant and a placeholder.** Measured 2026-10-29: of
  /// 2,557 units, 2,081 have nobody on record, because **1,155 of 1,156
  /// owners are not loaded** — questions 1 and 3 to Sandan. 🎯 And per
  /// Hashim the same day, *every* unit has an owner (Sandan's own, when
  /// nobody else's), so this sentence describes a **gap in our data, never a
  /// state of the business**, and it should become unreachable once the owners
  /// are imported.
  static const nobodyOnRecord = 'No tenant/owner found on record for this unit.';

  const PartyPicker({
    super.key,
    required this.type,
    required this.label,
    required this.suggested,
    required this.selected,
    required this.onChanged,
  });

  final String type; // 'tenant' or 'owner'
  final String label;
  final List<PartyLookup> suggested;
  final PartyLookup? selected;
  final void Function(PartyLookup?) onChanged;

  @override
  State<PartyPicker> createState() => _PartyPickerState();
}

class _PartyPickerState extends State<PartyPicker> {
  final _service = ComplaintService();
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<PartyLookup> _results = [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      setState(() => _searching = true);
      final results = await _service.searchParties(type: widget.type, search: value.trim());
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selected != null) {
      return _SelectedChip(
        party: widget.selected!,
        onClear: () => widget.onChanged(null),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        if (widget.suggested.isEmpty) ...[
          const Text(
            PartyPicker.nobodyOnRecord,
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 6),
        ],
        if (widget.suggested.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final party in widget.suggested)
                _SuggestionChip(party: party, onTap: () => widget.onChanged(party)),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Container(
          decoration: BoxDecoration(
            color: AppColors.glassFill,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.glassBorder, width: 1),
          ),
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13.5),
            decoration: InputDecoration(
              hintText: 'Search ${widget.type}…',
              hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13.5),
              prefixIcon: const Icon(Icons.search, color: AppColors.textMuted, size: 19),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentSoft),
                      ),
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            ),
          ),
        ),
        if (_results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: AppColors.glassFill,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.glassBorder, width: 1),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _results.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.glassBorder),
              itemBuilder: (context, index) {
                final party = _results[index];
                return ListTile(
                  dense: true,
                  title: Text(party.name, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13)),
                  subtitle: party.subtitle != null
                      ? Text(party.subtitle!, style: const TextStyle(color: AppColors.textMuted, fontSize: 11))
                      : null,
                  onTap: () {
                    widget.onChanged(party);
                    setState(() => _results = []);
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.party, required this.onTap});

  final PartyLookup party;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.accentSoft.withValues(alpha: 0.4), width: 1),
        ),
        child: Text(
          party.name,
          style: const TextStyle(color: AppColors.accentSoft, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _SelectedChip extends StatelessWidget {
  const _SelectedChip({required this.party, required this.onClear});

  final PartyLookup party;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: AppColors.success, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              party.name,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: AppColors.textMuted, size: 18),
            onPressed: onClear,
            splashRadius: 18,
          ),
        ],
      ),
    );
  }
}
