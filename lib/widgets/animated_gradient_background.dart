import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Deep gradient backdrop with slow-drifting glow orbs and a faint grid,
/// used behind every auth screen to give the app a premium, alive feel.
class AnimatedGradientBackground extends StatefulWidget {
  const AnimatedGradientBackground({super.key, this.child});

  final Widget? child;

  @override
  State<AnimatedGradientBackground> createState() =>
      _AnimatedGradientBackgroundState();
}

class _AnimatedGradientBackgroundState
    extends State<AnimatedGradientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value * 2 * math.pi;
              return CustomPaint(
                painter: _OrbPainter(t: t),
              );
            },
          ),
          if (widget.child != null) widget.child!,
        ],
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t});

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    _paintOrb(
      canvas,
      size,
      center: Offset(
        size.width * (0.2 + 0.08 * math.sin(t)),
        size.height * (0.18 + 0.05 * math.cos(t)),
      ),
      radius: size.width * 0.55,
      color: AppColors.accent.withValues(alpha: 0.16),
    );
    _paintOrb(
      canvas,
      size,
      center: Offset(
        size.width * (0.85 + 0.06 * math.cos(t * 0.8)),
        size.height * (0.75 + 0.06 * math.sin(t * 0.8)),
      ),
      radius: size.width * 0.6,
      color: AppColors.gold.withValues(alpha: 0.09),
    );
    _paintOrb(
      canvas,
      size,
      center: Offset(
        size.width * (0.5 + 0.1 * math.sin(t * 0.6 + 1)),
        size.height * (1.0),
      ),
      radius: size.width * 0.7,
      color: AppColors.accentDeep.withValues(alpha: 0.14),
    );
  }

  void _paintOrb(
    Canvas canvas,
    Size size, {
    required Offset center,
    required double radius,
    required Color color,
  }) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..blendMode = BlendMode.plus;
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter oldDelegate) => oldDelegate.t != t;
}
