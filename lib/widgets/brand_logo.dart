import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// The Sandan logo (assets/images/logo-transparent.png) on a soft light
/// card, since its dark wordmark needs a light surface to stay legible
/// against the app's dark gradient background.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.14),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFFBF7FC),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.38),
            blurRadius: size * 0.28,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Image.asset(
        'assets/images/logo-transparent.png',
        fit: BoxFit.contain,
      ),
    );
  }
}
