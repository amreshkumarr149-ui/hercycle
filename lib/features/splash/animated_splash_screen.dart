import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Cinematic 5-second HerCycle splash (vertical, any aspect).
///
/// Timeline mapping (controller 0.0 → 1.0 over 5 seconds):
/// - 0.00–0.40  gradient wash-in, glow particles drift, cycle ring draws 0→360°
/// - 0.30–0.50  logo scales in with glow
/// - 0.40–0.70  petals orbit once around the logo
/// - 0.50–0.66  "HerCycle" wordmark fades up
/// - 0.66–1.00  settle: one gentle pulse, particles fade, clean final frame
///
/// Pure animation — no logic. The parent owns timing and routing.
class AnimatedSplashScreen extends StatefulWidget {
  const AnimatedSplashScreen({super.key});

  @override
  State<AnimatedSplashScreen> createState() => _AnimatedSplashScreenState();
}

class _SplashParticle {
  final double x; // 0..1 across width
  final double y; // 0..1 down height (start)
  final double size;
  final double speed; // upward travel in height-fractions over full timeline
  final double phase;
  const _SplashParticle(this.x, this.y, this.size, this.speed, this.phase);
}

class _AnimatedSplashScreenState extends State<AnimatedSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _wash;
  late final Animation<double> _ringDraw;
  late final Animation<double> _ringSpin;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoGlow;
  late final Animation<double> _petalOrbit;
  late final Animation<double> _petalFade;
  late final Animation<double> _wordOpacity;
  late final Animation<double> _wordRise;
  late final Animation<double> _settlePulse;
  late final Animation<double> _particleFade;

  late final List<_SplashParticle> _particles;

  Animation<double> _interval(double begin, double end, {Curve curve = Curves.easeOut}) {
    return CurvedAnimation(
      parent: _controller,
      curve: Interval(begin, end, curve: curve),
    );
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..forward();

    _wash = _interval(0.0, 0.30);
    _ringDraw = _interval(0.10, 0.50, curve: Curves.easeInOut);
    _ringSpin = _interval(0.50, 0.66, curve: Curves.easeInOut);
    _logoScale = _interval(0.30, 0.50, curve: Curves.easeOutBack);
    _logoGlow = _interval(0.30, 0.55);
    _petalOrbit = _interval(0.40, 0.70, curve: Curves.linear);
    _petalFade = _interval(0.66, 0.84);
    _wordOpacity = _interval(0.50, 0.66);
    _wordRise = _interval(0.50, 0.66, curve: Curves.easeOutCubic);
    _settlePulse = _interval(0.66, 0.84);
    _particleFade = _interval(0.70, 1.00);

    // Deterministic particles (fixed seed-style math, no per-frame Random).
    _particles = List.generate(26, (i) {
      final r1 = ((i * 37.7) % 100) / 100;
      final r2 = ((i * 91.3) % 100) / 100;
      final r3 = ((i * 53.9) % 100) / 100;
      return _SplashParticle(
        r1,
        0.55 + r2 * 0.45,
        2.0 + r3 * 3.5,
        0.25 + r1 * 0.35,
        r2 * math.pi * 2,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final pulse =
              1.0 + 0.04 * math.sin(_settlePulse.value * math.pi);
          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(
                      const Color(0xFFFFF0F2),
                      const Color(0xFFFFE3EC),
                      _wash.value)!,
                  Color.lerp(
                      const Color(0xFFFFF0F2),
                      const Color(0xFFE9D6F5),
                      _wash.value)!,
                  Color.lerp(
                      const Color(0xFFFFF0F2),
                      const Color(0xFFFFE9D9),
                      _wash.value)!,
                ],
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ParticlePainter(
                      t: _controller.value,
                      fade: 1.0 - _particleFade.value * 0.75,
                      particles: _particles,
                    ),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 260,
                        height: 260,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CustomPaint(
                              size: const Size(260, 260),
                              painter: _RingPainter(
                                drawProgress: _ringDraw.value,
                                spinProgress: _ringSpin.value,
                              ),
                            ),
                            CustomPaint(
                              size: const Size(260, 260),
                              painter: _PetalPainter(
                                orbitProgress: _petalOrbit.value,
                                fade: 1.0 - _petalFade.value * 0.65,
                              ),
                            ),
                            Transform.scale(
                              scale: _logoScale.value == 0
                                  ? 0.01
                                  : (0.8 + 0.2 * _logoScale.value) * pulse,
                              child: Container(
                                width: 150,
                                height: 150,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFF48FB1)
                                          .withValues(
                                              alpha: 0.55 *
                                                  _logoGlow.value),
                                      blurRadius: 34 * _logoGlow.value + 4,
                                      spreadRadius: 6 * _logoGlow.value,
                                    ),
                                  ],
                                ),
                                child: ClipOval(
                                  child: Image.asset(
                                    'assets/images/logo.png',
                                    fit: BoxFit.cover,
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            Container(
                                      color: const Color(0xFFFFE3EC),
                                      child: const Icon(
                                        Icons.face_retouching_natural,
                                        size: 80,
                                        color: Color(0xFFC26D81),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Opacity(
                        opacity: _wordOpacity.value,
                        child: Transform.translate(
                          offset: Offset(
                              0, 16 * (1.0 - _wordRise.value)),
                          child: const Text(
                            'HerCycle',
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                              color: Color(0xFF7B4B94),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Soft glowing particles drifting upward with twinkle.
class _ParticlePainter extends CustomPainter {
  final double t;
  final double fade;
  final List<_SplashParticle> particles;
  const _ParticlePainter(
      {required this.t, required this.fade, required this.particles});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final y = (p.y - t * p.speed) * size.height;
      if (y < -10) continue;
      final twinkle = 0.55 + 0.45 * math.sin(t * 18 + p.phase);
      final paint = Paint()
        ..color = const Color(0xFFFFFFFF).withValues(
            alpha: (0.75 * twinkle * fade).clamp(0.0, 1.0))
        ..maskFilter =
            MaskFilter.blur(BlurStyle.normal, p.size * 0.8);
      canvas.drawCircle(Offset(p.x * size.width, y), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) =>
      old.t != t || old.fade != fade;
}

/// Luminous cycle ring: draws itself, then rotates once with a bead.
class _RingPainter extends CustomPainter {
  final double drawProgress;
  final double spinProgress;
  const _RingPainter({required this.drawProgress, required this.spinProgress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 14;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Faint full track underneath.
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = const Color(0xFFF48FB1).withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round,
    );

    if (drawProgress <= 0) return;
    const startAngle = -math.pi / 2;
    final sweep = drawProgress.clamp(0.0, 1.0) * math.pi * 2;
    final rotation = spinProgress.clamp(0.0, 1.0) * math.pi * 2;

    final shaderPaint = Paint()
      ..shader = const SweepGradient(
        colors: [
          Color(0xFFF48FB1),
          Color(0xFFCE93D8),
          Color(0xFFFFB59E),
          Color(0xFFF48FB1),
        ],
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawArc(rect, startAngle, sweep, false, shaderPaint);
    // Luminous bead at the drawing tip.
    final tipAngle = startAngle + sweep;
    final tip = Offset(
      center.dx + radius * math.cos(tipAngle),
      center.dy + radius * math.sin(tipAngle),
    );
    canvas.drawCircle(
      tip,
      7,
      Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.drawProgress != drawProgress ||
      old.spinProgress != spinProgress;
}

/// Translucent petals orbiting the logo once, settling faint.
class _PetalPainter extends CustomPainter {
  final double orbitProgress;
  final double fade;
  const _PetalPainter({required this.orbitProgress, required this.fade});

  @override
  void paint(Canvas canvas, Size size) {
    if (orbitProgress <= 0 || fade <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    const radius = 104.0;
    for (var i = 0; i < 6; i++) {
      final base = (i / 6) * math.pi * 2;
      final angle = base + orbitProgress * math.pi * 2;
      final pos = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(angle + math.pi / 2);
      canvas.drawOval(
        const Rect.fromLTWH(-4, -8, 8, 16),
        Paint()
          ..color = const Color(0xFFF8BBD0)
              .withValues(alpha: 0.55 * fade)
          ..maskFilter =
              const MaskFilter.blur(BlurStyle.normal, 2),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _PetalPainter old) =>
      old.orbitProgress != orbitProgress || old.fade != fade;
}
