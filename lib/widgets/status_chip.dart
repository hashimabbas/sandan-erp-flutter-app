import 'package:flutter/material.dart';

import '../models/work_order.dart';

/// SPEC-024 Phase 1, Step 3 — a status chip that shows the SERVER's word.
///
/// 🔴 **This used to take a `TaskStatus`** — a four-value Dart enum from
/// `mock_dashboard_data.dart`, with its labels *and* its colours written in
/// Dart. The server has **eight** `ComplaintStatus` cases and sends each as
/// `{value, label}` precisely so no client translates one. The enum was a
/// vocabulary the server had already replaced.
///
/// ⚠️ **Colour stays here, and only colour.** It is presentation, and the
/// server's own `ComplaintPriority::color()` returns Tailwind class names a
/// Flutter app cannot use. But the map is **total by construction**: a status
/// this build has never heard of renders in the fallback colour **under its
/// own server label**, never dropped and never recoloured into looking
/// ordinary.
///
/// 🎯 That matters more than it reads. A `switch` with a silent grey default
/// is how a job in a state the app does not know stops looking like anything —
/// and the states this app does not know yet include `waiting_for_parts`,
/// which is exactly the one a technician needs to notice.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final Vocab status;

  /// Keyed on the server's `value`. Adding a case here is a presentation
  /// decision; **omitting one is not a defect**, because the fallback renders.
  static const _colors = <String, Color>{
    'new': Color(0xFF8A94A6),
    'assigned': Color(0xFFE7C07B),
    'in_progress': Color(0xFF5FA8E7),
    'waiting_for_parts': Color(0xFFBE8FE0),
    'completed': Color(0xFF3DDC97),
    'verified': Color(0xFF2FC4A0),
    'closed': Color(0xFF6E7787),
    'cancelled': Color(0xFFFF6B6B),
  };

  /// Deliberately NOT grey-on-grey: an unfamiliar status should read as
  /// unfamiliar, not as background.
  static const _unknown = Color(0xFFBE8FE0);

  @override
  Widget build(BuildContext context) {
    final color = _colors[status.value] ?? _unknown;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(
        // The server's label. Never derived, never title-cased from `value`.
        status.label,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
