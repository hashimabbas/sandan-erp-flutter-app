import 'package:flutter/material.dart';

import '../models/assignee.dart';
import '../theme/app_colors.dart';

/// SPEC-025 Step 6 — choose who does the work, or choose nobody.
///
/// 🔴 **Optional is the decision, not a convenience** (D1). Logging a
/// complaint in ten seconds and handing it over a minute later must stay
/// possible, so this widget never blocks a submit and starts with nothing
/// selected.
///
/// 🎯 **It states why the order is what it is.** The server sends the job's
/// trade beside the people; without printing it, a sorted list would be an
/// unexplained order — and an unexplained order is a surface asking to be
/// mistrusted.
class AssigneePicker extends StatelessWidget {
  const AssigneePicker({
    super.key,
    required this.list,
    required this.selected,
    required this.onChanged,
    this.loading = false,
  });

  static const nobodyYet = 'No technicians or workers exist yet.';
  static const skippable = 'Optional — you can assign this later.';

  final AssigneeList list;
  final Set<int> selected;
  final void Function(Set<int>) onChanged;
  final bool loading;

  void _toggle(int id) {
    final next = Set<int>.from(selected);
    if (!next.remove(id)) next.add(id);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: Text(
                'Assign to',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ),
            if (list.jobTrade != null)
              Text(
                '${list.jobTrade} — shown first',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
          ],
        ),
        const SizedBox(height: 2),
        const Text(skippable, style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
        const SizedBox(height: 8),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentSoft),
            ),
          )
        else if (list.people.isEmpty)
          const Text(nobodyYet, style: TextStyle(color: AppColors.textMuted, fontSize: 12.5))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final person in list.people)
                _AssigneeChip(
                  person: person,
                  jobTrade: list.jobTrade,
                  chosen: selected.contains(person.id),
                  onTap: () => _toggle(person.id),
                ),
            ],
          ),
      ],
    );
  }
}

class _AssigneeChip extends StatelessWidget {
  const _AssigneeChip({
    required this.person,
    required this.jobTrade,
    required this.chosen,
    required this.onTap,
  });

  static const unknownTrade = 'trade not recorded';
  static const otherTrade = 'other trade';

  final Assignee person;
  final String? jobTrade;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 🔴 D5/D7 — everybody is here and everybody is tappable. The trade is
    // said, never enforced: with two technicians in the whole business, a
    // hidden man means a water leak nobody can be given.
    //
    // ⚠️ And "trade not recorded" is deliberately NOT drawn as "other trade".
    // One is a gap in our data; the other is a fact about him.
    final note = jobTrade == null
        ? null
        : switch (person.matchesTrade) {
            true => null,
            null => _AssigneeChip.unknownTrade,
            false => _AssigneeChip.otherTrade,
          };

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: chosen ? AppColors.accentSoft.withValues(alpha: 0.18) : AppColors.glassFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: chosen ? AppColors.accentSoft : AppColors.glassBorder,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (chosen) ...[
              const Icon(Icons.check, size: 14, color: AppColors.accentSoft),
              const SizedBox(width: 6),
            ],
            Text(
              person.name,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            ),
            const SizedBox(width: 6),
            Text(
              person.label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 10.5),
            ),
            if (note != null) ...[
              const SizedBox(width: 6),
              Text(
                note,
                style: TextStyle(
                  color: note == _AssigneeChip.unknownTrade ? Colors.amber.shade700 : AppColors.textMuted,
                  fontSize: 10.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
