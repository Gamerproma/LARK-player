// ===========================================================================
// EFECTOS VISUALES DE LOS COSMÉTICOS
// Widgets y pinceles que dibujan botones, vinilos, marcos, ecualizadores,
// partículas y transiciones. No dependen del resto de la app.
// ===========================================================================
import 'dart:math';

import 'package:flutter/material.dart';

import 'cosmetics_catalog.dart';

Path polygonPath(Size s, int sides,
    {double rotation = -pi / 2, double inner = 1.0}) {
  final c = Offset(s.width / 2, s.height / 2);
  final r = min(s.width, s.height) / 2;
  final path = Path();
  final n = inner < 1.0 ? sides * 2 : sides;
  for (var i = 0; i < n; i++) {
    final rad = (inner < 1.0 && i.isOdd) ? r * inner : r;
    final ang = rotation + 2 * pi * i / n;
    final p = Offset(c.dx + rad * cos(ang), c.dy + rad * sin(ang));
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  path.close();
  return path;
}

double _fr(double x) => x - x.floorToDouble();
double _rnd(int i, int k) => _fr(sin(i * 12.9898 + k * 78.233) * 43758.5453);

// ---------------------------------------------------------------------------
// BOTÓN DE REPRODUCCIÓN
// ---------------------------------------------------------------------------
class StyledPlayButton extends StatelessWidget {
  final Cosmetic style;
  final bool playing;
  final double size;
  final VoidCallback? onTap;
  const StyledPlayButton({
    super.key,
    required this.style,
    required this.playing,
    required this.size,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final w = style.a == 6 ? size * 1.5 : size;
    final outline = style.b == 2;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: w,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(size: Size(w, size), painter: _BtnPainter(style)),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(playing),
                size: size * 0.55,
                color: outline ? Color(style.c1) : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BtnPainter extends CustomPainter {
  final Cosmetic s;
  _BtnPainter(this.s);

  Path _shape(Rect r) {
    switch (s.a) {
      case 1:
        return Path()
          ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.height * 0.32)));
      case 2:
        return polygonPath(r.size, 6, rotation: 0).shift(r.topLeft);
      case 3:
        return polygonPath(r.size, 4).shift(r.topLeft);
      case 4:
        return polygonPath(r.size, 5, inner: 0.52).shift(r.topLeft);
      case 5:
        return polygonPath(r.size, 8, rotation: pi / 8).shift(r.topLeft);
      case 6:
        return Path()
          ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)));
      default:
        return Path()..addOval(r);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.height * 0.06;
    final rect = Rect.fromLTWH(
        inset, inset, size.width - 2 * inset, size.height - 2 * inset);
    final path = _shape(rect);
    final c1 = Color(s.c1);
    final c2 = Color(s.c2 == 0xFFFFFFFF ? s.c1 : s.c2);
    final grad = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [c1, c2],
    ).createShader(rect);
    void glow() {
      canvas.drawPath(
        path,
        Paint()
          ..color = c1.withAlpha(150)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    switch (s.b) {
      case 1:
        canvas.drawPath(path, Paint()..shader = grad);
        break;
      case 2:
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = size.height * 0.07
            ..color = c1,
        );
        break;
      case 3:
        glow();
        canvas.drawPath(path, Paint()..color = c1);
        break;
      case 4:
        canvas.drawPath(path, Paint()..color = Colors.white.withAlpha(45));
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = Colors.white.withAlpha(150),
        );
        break;
      case 5:
        glow();
        canvas.drawPath(path, Paint()..shader = grad);
        break;
      default:
        canvas.drawPath(path, Paint()..color = c1);
    }
  }

  @override
  bool shouldRepaint(covariant _BtnPainter old) => old.s.id != s.id;
}

// ---------------------------------------------------------------------------
// VINILOS
// ---------------------------------------------------------------------------
class VinylSkin {
  final int pattern;
  final Color c1;
  final Color c2;
  final Color label;
  const VinylSkin(this.pattern, this.c1, this.c2, this.label);

  static const classic =
      VinylSkin(2, Color(0xFF2B2B2B), Color(0xFF0A0A0A), Color(0xFF3B3B4A));

  factory VinylSkin.fromCosmetic(Cosmetic? c) {
    if (c == null) return classic;
    return VinylSkin(c.a, Color(c.c1), Color(c.c2), Color(c.c3));
  }
}

class _VinylPainter extends CustomPainter {
  final VinylSkin skin;
  _VinylPainter(this.skin);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final rect = Offset.zero & size;
    final paint = Paint();
    switch (skin.pattern) {
      case 0:
        paint.color = skin.c1;
        break;
      case 1:
        paint.shader = SweepGradient(
                colors: [skin.c1, skin.c2, skin.c1, skin.c2, skin.c1])
            .createShader(rect);
        break;
      case 2:
        paint.shader =
            RadialGradient(colors: [skin.c1, skin.c2]).createShader(rect);
        break;
      case 4:
        paint.shader = const SweepGradient(colors: [
          Color(0xFFF3F4F6),
          Color(0xFF9CA3AF),
          Color(0xFFF9FAFB),
          Color(0xFF6B7280),
          Color(0xFFF3F4F6),
        ]).createShader(rect);
        break;
      default:
        paint.shader = const SweepGradient(colors: [
          Color(0xFFEF4444),
          Color(0xFFF59E0B),
          Color(0xFFFDE047),
          Color(0xFF22C55E),
          Color(0xFF06B6D4),
          Color(0xFF3B82F6),
          Color(0xFFA855F7),
          Color(0xFFEF4444),
        ]).createShader(rect);
    }
    canvas.drawCircle(c, r, paint);
    final dark = skin.c1.computeLuminance() < 0.35;
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = skin.pattern == 0
          ? skin.c2.withAlpha(150)
          : (dark ? Colors.white.withAlpha(28) : Colors.black.withAlpha(45));
    for (double k = 0.5; k < 0.98; k += 0.05) {
      canvas.drawCircle(c, r * k, groove);
    }
    canvas.drawCircle(c, r * 0.27, Paint()..color = skin.label);
  }

  @override
  bool shouldRepaint(covariant _VinylPainter old) => old.skin != skin;
}

class VinylDisc extends StatelessWidget {
  final double d;
  final VinylSkin skin;
  final Widget center;
  const VinylDisc({
    super.key,
    required this.d,
    required this.skin,
    required this.center,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: d,
      height: d,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black54)],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(size: Size(d, d), painter: _VinylPainter(skin)),
          center,
          Container(
            width: d * 0.05,
            height: d * 0.05,
            decoration: const BoxDecoration(
              color: Colors.black,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MARCOS DE CARÁTULA
// ---------------------------------------------------------------------------
class _CornersPainter extends CustomPainter {
  final Color color;
  _CornersPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color;
    const l = 24.0;
    const i = 2.0;
    final w = size.width;
    final h = size.height;
    canvas.drawPath(
        Path()
          ..moveTo(i, i + l)
          ..lineTo(i, i)
          ..lineTo(i + l, i),
        p);
    canvas.drawPath(
        Path()
          ..moveTo(w - i - l, i)
          ..lineTo(w - i, i)
          ..lineTo(w - i, i + l),
        p);
    canvas.drawPath(
        Path()
          ..moveTo(i, h - i - l)
          ..lineTo(i, h - i)
          ..lineTo(i + l, h - i),
        p);
    canvas.drawPath(
        Path()
          ..moveTo(w - i - l, h - i)
          ..lineTo(w - i, h - i)
          ..lineTo(w - i, h - i - l),
        p);
  }

  @override
  bool shouldRepaint(covariant _CornersPainter old) => old.color != color;
}

class CoverFrame extends StatelessWidget {
  final Cosmetic? style;
  final double radius;
  final Widget child;
  const CoverFrame({
    super.key,
    required this.style,
    required this.radius,
    required this.child,
  });

  /// Espacio que el marco agrega en ancho y alto (para ajustar el tamaño).
  static double extra(Cosmetic? s) {
    if (s == null) return 0;
    const m = {0: 12.0, 1: 24.0, 2: 12.0, 3: 10.0, 4: 46.0, 5: 16.0, 6: 20.0, 7: 10.0};
    return m[s.a] ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final s = style;
    if (s == null) return child;
    final c1 = Color(s.c1);
    final c2 = Color(s.c2);
    switch (s.a) {
      case 0:
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 6),
            border: Border.all(color: c1, width: 2),
          ),
          child: child,
        );
      case 1:
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 12),
            border: Border.all(color: c1, width: 3),
          ),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius + 5),
              border: Border.all(color: c2, width: 2),
            ),
            child: child,
          ),
        );
      case 2:
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 6),
            border: Border.all(color: c1, width: 2),
            boxShadow: [
              BoxShadow(color: c1.withAlpha(170), blurRadius: 18, spreadRadius: 1),
            ],
          ),
          child: child,
        );
      case 3:
        return Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 5),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [c1, c2],
            ),
          ),
          child: child,
        );
      case 4:
        return Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 36),
          decoration: BoxDecoration(
            color: c1,
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(blurRadius: 14, color: Colors.black38)],
          ),
          child: child,
        );
      case 5:
        return Stack(
          children: [
            Padding(padding: const EdgeInsets.all(8), child: child),
            Positioned.fill(
              child: CustomPaint(painter: _CornersPainter(c1)),
            ),
          ],
        );
      case 6:
        return Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 12),
            color: c1.withAlpha(60),
            border: Border.all(color: Colors.white.withAlpha(110), width: 1.5),
          ),
          child: child,
        );
      default:
        return Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 5),
            gradient: LinearGradient(colors: [c1, c2]),
            boxShadow: [
              BoxShadow(color: c1.withAlpha(150), blurRadius: 26, offset: const Offset(-6, 0)),
              BoxShadow(color: c2.withAlpha(150), blurRadius: 26, offset: const Offset(6, 0)),
            ],
          ),
          child: child,
        );
    }
  }
}

// ---------------------------------------------------------------------------
// ECUALIZADOR VISUAL (animación)
// ---------------------------------------------------------------------------
class VizPainter extends CustomPainter {
  final int style;
  final double t;
  final bool playing;
  final Color c1;
  final Color c2;
  VizPainter({
    required this.style,
    required this.t,
    required this.playing,
    required this.c1,
    required this.c2,
  });

  double _amp(int i) =>
      playing ? 0.5 + 0.5 * sin(t * 2 * pi * (1 + i % 3) + i * 0.7) : 0.06;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 24;
    final w = size.width;
    final h = size.height;
    final p = Paint()..color = c1;
    switch (style) {
      case 1:
        p.strokeWidth = 2.5;
        p.strokeCap = StrokeCap.round;
        for (var i = 0; i < n; i++) {
          final x = (i + 0.5) * w / n;
          final bh = h * 0.06 + h * 0.85 * _amp(i);
          canvas.drawLine(Offset(x, h), Offset(x, h - bh), p);
        }
        break;
      case 2:
        const levels = 8;
        for (var i = 0; i < n; i++) {
          final x = (i + 0.5) * w / n;
          final lit = max(1, (_amp(i) * levels).ceil());
          for (var j = 0; j < lit; j++) {
            canvas.drawCircle(
                Offset(x, h - (j + 0.5) * h / levels), w / n * 0.26, p);
          }
        }
        break;
      case 3:
        final bw = w / n * 0.55;
        for (var i = 0; i < n; i++) {
          final x = (i + 0.5) * w / n;
          final bh = h * 0.06 + h * 0.85 * _amp(i);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromCenter(center: Offset(x, h / 2), width: bw, height: bh),
                Radius.circular(bw / 2)),
            p,
          );
        }
        break;
      case 4:
        final path = Path();
        final k = playing ? 1.0 : 0.12;
        for (var x = 0.0; x <= w; x += 4) {
          final y = h / 2 +
              sin(x / w * 2 * pi * 2 + t * 2 * pi * 2) * h * 0.25 * k +
              sin(x / w * 2 * pi * 3 - t * 2 * pi * 3) * h * 0.12 * k;
          if (x == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        final fill = Path.from(path)
          ..lineTo(w, h)
          ..lineTo(0, h)
          ..close();
        canvas.drawPath(fill, Paint()..color = c1.withAlpha(60));
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = c1,
        );
        break;
      case 5:
        final c = Offset(w / 2, h / 2);
        final r = min(w, h) / 2;
        const m = 48;
        p.strokeWidth = 3;
        p.strokeCap = StrokeCap.round;
        for (var i = 0; i < m; i++) {
          final a = 2 * pi * i / m;
          final len = r * 0.12 + r * 0.55 * _amp(i % n);
          final from = Offset(c.dx + cos(a) * r * 0.32, c.dy + sin(a) * r * 0.32);
          final to = Offset(c.dx + cos(a) * (r * 0.32 + len), c.dy + sin(a) * (r * 0.32 + len));
          canvas.drawLine(from, to, p);
        }
        break;
      case 6:
        final bw = w / n * 0.55;
        p.shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [c2, c1],
        ).createShader(Offset.zero & size);
        for (var i = 0; i < n; i++) {
          final x = (i + 0.5) * w / n;
          final bh = h * 0.06 + h * 0.85 * _amp(i);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x - bw / 2, h - bh, bw, bh), Radius.circular(bw / 2)),
            p,
          );
        }
        break;
      case 7:
        final c = Offset(w / 2, h / 2);
        final r = min(w, h) / 2;
        for (var k = 0; k < 4; k++) {
          final q = playing ? _fr(t * 2 + k / 4) : 0.2 + k * 0.15;
          canvas.drawCircle(
            c,
            q * r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = c1.withAlpha(((1 - q) * 220).round().clamp(0, 255)),
          );
        }
        break;
      default:
        final bw = w / n * 0.55;
        for (var i = 0; i < n; i++) {
          final x = (i + 0.5) * w / n;
          final bh = h * 0.06 + h * 0.85 * _amp(i);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x - bw / 2, h - bh, bw, bh), Radius.circular(bw / 2)),
            p,
          );
        }
    }
  }

  @override
  bool shouldRepaint(covariant VizPainter old) => true;
}

// ---------------------------------------------------------------------------
// PARTÍCULAS
// ---------------------------------------------------------------------------
class ParticlePainter extends CustomPainter {
  final int kind;
  final Color color;
  final double t;
  final int count;
  ParticlePainter({
    required this.kind,
    required this.color,
    required this.t,
    this.count = 26,
  });

  void _note(Canvas c, Offset o, double s, Paint p) {
    c.drawOval(Rect.fromCenter(center: o, width: s * 0.9, height: s * 0.65), p);
    c.drawPath(
        Path()
          ..moveTo(o.dx + s * 0.4, o.dy)
          ..lineTo(o.dx + s * 0.4, o.dy - s * 1.6)
          ..lineTo(o.dx + s * 0.55, o.dy - s * 1.6)
          ..lineTo(o.dx + s * 0.55, o.dy)
          ..close(),
        p);
    c.drawPath(
        Path()
          ..moveTo(o.dx + s * 0.55, o.dy - s * 1.6)
          ..quadraticBezierTo(
              o.dx + s * 1.2, o.dy - s * 1.2, o.dx + s * 0.9, o.dy - s * 0.7)
          ..quadraticBezierTo(
              o.dx + s * 1.0, o.dy - s * 1.2, o.dx + s * 0.55, o.dy - s * 1.25)
          ..close(),
        p);
  }

  Path _heart(Offset c, double s) {
    return Path()
      ..moveTo(c.dx, c.dy + s * 0.35)
      ..cubicTo(c.dx - s, c.dy - s * 0.2, c.dx - s * 0.5, c.dy - s * 0.95,
          c.dx, c.dy - s * 0.4)
      ..cubicTo(c.dx + s * 0.5, c.dy - s * 0.95, c.dx + s, c.dy - s * 0.2,
          c.dx, c.dy + s * 0.35)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const rising = {0, 2, 6, 7};
    for (var i = 0; i < count; i++) {
      final r1 = _rnd(i, 1);
      final r2 = _rnd(i, 2);
      final r3 = _rnd(i, 3);
      final loops = 1 + (_rnd(i, 4) * 3).floor();
      final p = _fr(t * loops + r2);
      final alpha = sin(p * pi).clamp(0.0, 1.0).toDouble();
      final a8 = (alpha * 210).round().clamp(0, 255);
      var x = r1 * w + sin(p * 2 * pi * 2 + r2 * 6) * w * 0.03;
      var y = rising.contains(kind)
          ? h * (1.1 - p * 1.2)
          : h * (-0.1 + p * 1.2);
      final paint = Paint()..color = color.withAlpha(a8);
      switch (kind) {
        case 0:
          _note(canvas, Offset(x, y), 6 + r3 * 7, paint);
          break;
        case 1:
          final sz = 8 + r3 * 12;
          canvas.drawPath(
              polygonPath(Size(sz, sz), 5, inner: 0.45)
                  .shift(Offset(x - sz / 2, y - sz / 2)),
              paint);
          break;
        case 2:
          canvas.drawCircle(
            Offset(x, y),
            4 + r3 * 10,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = color.withAlpha(a8),
          );
          break;
        case 3:
          canvas.drawCircle(Offset(x, y), 1.5 + r3 * 3, paint);
          break;
        case 4:
          x = r1 * w + sin(t * 2 * pi * loops + r2 * 6) * w * 0.08;
          y = _rnd(i, 5) * h + cos(t * 2 * pi * loops + r2 * 6) * h * 0.05;
          final pulse = 0.5 + 0.5 * sin(t * 2 * pi * 3 * loops + r2 * 6);
          canvas.drawCircle(Offset(x, y), 6 + r3 * 4,
              Paint()..color = color.withAlpha((pulse * 50).round()));
          canvas.drawCircle(Offset(x, y), 2 + r3 * 1.5,
              Paint()..color = color.withAlpha((120 + pulse * 130).round()));
          break;
        case 5:
          canvas.save();
          canvas.translate(x, y);
          canvas.rotate(p * 2 * pi * 2 + r2 * 6);
          canvas.drawRect(
            const Rect.fromLTWH(-4, -2, 8, 4),
            Paint()
              ..color = HSLColor.fromAHSL(a8 / 255, r2 * 360, 0.8, 0.62).toColor(),
          );
          canvas.restore();
          break;
        case 6:
          canvas.drawPath(_heart(Offset(x, y), 6 + r3 * 8), paint);
          break;
        case 7:
          canvas.drawCircle(Offset(x, y), 1.5 + r3 * 2.5, paint);
          break;
        case 8:
          canvas.drawLine(
            Offset(x, y),
            Offset(x - 4, y + 14 + r3 * 10),
            Paint()
              ..strokeWidth = 1.2
              ..strokeCap = StrokeCap.round
              ..color = color.withAlpha((a8 * 0.8).round()),
          );
          break;
        default:
          x = r1 * w;
          y = _rnd(i, 5) * h;
          final tw = 0.5 + 0.5 * sin(t * 2 * pi * loops + r2 * 6);
          final s = 4 + r3 * 8;
          final sp = Paint()
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round
            ..color = color.withAlpha((tw * 230).round());
          canvas.drawLine(Offset(x - s, y), Offset(x + s, y), sp);
          canvas.drawLine(Offset(x, y - s), Offset(x, y + s), sp);
          canvas.drawCircle(Offset(x, y), 1.6, Paint()..color = sp.color);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ParticlePainter old) => old.t != t || old.kind != kind;
}

class ParticleField extends StatefulWidget {
  final Cosmetic style;
  const ParticleField({super.key, required this.style});
  @override
  State<ParticleField> createState() => _ParticleFieldState();
}

class _ParticleFieldState extends State<ParticleField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 24))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: ParticlePainter(
              kind: widget.style.a,
              color: Color(widget.style.c1),
              t: _c.value,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TRANSICIÓN DEL CARRUSEL
// ---------------------------------------------------------------------------
Widget cosTransition(Cosmetic? s, double signed, Widget child) {
  final sg = signed.clamp(-1.0, 1.0).toDouble();
  final d = sg.abs();
  if (s == null) {
    return Transform.scale(
      scale: 1 - 0.16 * d,
      child: Opacity(opacity: 1 - 0.5 * d, child: child),
    );
  }
  switch (s.a) {
    case 0:
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(-sg * 0.7),
        child: Transform.scale(
          scale: 1 - 0.1 * d,
          child: Opacity(opacity: 1 - 0.45 * d, child: child),
        ),
      );
    case 1:
      return Transform.scale(
        scale: 1 - 0.32 * d,
        child: Opacity(opacity: 1 - 0.75 * d, child: child),
      );
    case 2:
      return Transform.rotate(
        angle: sg * 0.38,
        child: Transform.scale(
          scale: 1 - 0.18 * d,
          child: Opacity(opacity: 1 - 0.5 * d, child: child),
        ),
      );
    default:
      return Transform.translate(
        offset: Offset(0, d * 40),
        child: Transform.scale(
          scale: 1 - 0.24 * d,
          child: Opacity(opacity: 1 - 0.6 * d, child: child),
        ),
      );
  }
}

// ---------------------------------------------------------------------------
// VISTA PREVIA PARA LA TIENDA
// ---------------------------------------------------------------------------
Widget cosPreview(Cosmetic c, String name) {
  switch (c.cat) {
    case CosCat.button:
      return StyledPlayButton(style: c, playing: false, size: 56);
    case CosCat.vinyl:
      return VinylDisc(
        d: 72,
        skin: VinylSkin.fromCosmetic(c),
        center: Container(
          width: 29,
          height: 29,
          decoration: const BoxDecoration(
              shape: BoxShape.circle, color: Colors.black26),
        ),
      );
    case CosCat.frame:
      return CoverFrame(
        style: c,
        radius: 8,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: const LinearGradient(
              colors: [Color(0xFF7C3AED), Color(0xFFEC4899)],
            ),
          ),
          child: const Icon(Icons.music_note, color: Colors.white),
        ),
      );
    case CosCat.viz:
      return SizedBox(
        width: 100,
        height: 58,
        child: CustomPaint(
          painter: VizPainter(
            style: c.a,
            t: 0.35,
            playing: true,
            c1: Color(c.c1),
            c2: Color(c.c2),
          ),
        ),
      );
    case CosCat.particles:
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 100,
          height: 64,
          color: const Color(0xFF1B1530),
          child: CustomPaint(
            painter: ParticlePainter(
                kind: c.a, color: Color(c.c1), t: 0.37, count: 14),
          ),
        ),
      );
    case CosCat.theme:
      final base = Color(c.c1);
      final scheme = ColorScheme.fromSeed(seedColor: base, brightness: Brightness.dark);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final col in [base, scheme.primaryContainer, scheme.secondary])
            Container(
              width: 26,
              height: 26,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(color: col, shape: BoxShape.circle),
            ),
        ],
      );
    case CosCat.transition:
      const icons = [
        Icons.threed_rotation,
        Icons.zoom_in_map,
        Icons.rotate_right,
        Icons.view_carousel,
      ];
      return Icon(icons[c.a.clamp(0, 3)], size: 44);
    case CosCat.title:
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Color(c.c1).withAlpha(40),
          border: Border.all(color: Color(c.c1)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Color(c.c1), fontWeight: FontWeight.bold, fontSize: 12),
        ),
      );
  }
}
