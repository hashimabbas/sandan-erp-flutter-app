import 'package:flutter/material.dart';

/// Premium palette for Sandan Facility — deep navy/indigo base with a
/// cyan-teal accent. Shared by the auth flow now, and by the rest of the
/// app once role-based home screens are wired up.
class AppColors {
  AppColors._();

  static const Color bgTop = Color(0xFF0D0710);
  static const Color bgMid = Color(0xFF170B1D);
  static const Color bgBottom = Color(0xFF0A0610);

  // Sampled from assets/images/logo-transparent.png so the UI stays on-brand.
  static const Color accent = Color(0xFF9A3FA0); // logo purple
  static const Color accentSoft = Color(0xFFC97FCE);
  static const Color accentDeep = Color(0xFF5A1360);

  static const Color gold = Color(0xFFE7C07B); // premium highlight

  static const Color glassFill = Color(0x14FFFFFF);
  static const Color glassBorder = Color(0x33FFFFFF);

  // Opaque premium surfaces — used where a component should read as solid
  // dark UI chrome rather than glass (operational cards, list containers).
  static const Color surface = Color(0xFF1B0F22);
  static const Color surfaceElevated = Color(0xFF241430);
  static const Color divider = Color(0x1FFFFFFF);

  static const Color textPrimary = Color(0xFFF5F7FA);
  static const Color textSecondary = Color(0xFFAEB9CC);
  static const Color textMuted = Color(0xFF7C879C);

  static const Color error = Color(0xFFFF6B6B);
  static const Color success = Color(0xFF3DDC97);
  static const Color warning = Color(0xFFE7C07B);
  static const Color info = Color(0xFF5FA8E7);

  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [bgTop, bgMid, bgBottom],
    stops: [0.0, 0.55, 1.0],
  );

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [accentDeep, accent, accentSoft],
  );
}
