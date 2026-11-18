import 'package:flutter/material.dart';

import '../models/work_order.dart';
import '../theme/app_colors.dart';
import 'status_chip.dart';

/// A single row for an activity/work-order entry: leading icon (maintenance
/// vs cleaning), title/location, trailing status chip + time.
class TaskRowTile extends StatelessWidget {
  const TaskRowTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.time,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// 🔴 SPEC-024 Phase 1, Step 3 — was a `TaskStatus`, a four-value Dart enum
  /// against the server's eight. It is now the server's own `{value, label}`.
  final Vocab status;

  /// Free text, so a row may say "3h ago" or "Due 14:20" without this widget
  /// deciding which. ⚠️ It must never carry a BREACH judgement: that is
  /// computed by the ERP (D4a subtracts referred time) and arrives as a
  /// boolean on the work order.
  final String time;

  /// Optional: a row in a manager's read-only list may have nowhere to go,
  /// while a field user's row opens the job.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppColors.accentSoft, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusChip(status: status),
              const SizedBox(height: 4),
              Text(
                time,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return row;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: row,
    );
  }
}
