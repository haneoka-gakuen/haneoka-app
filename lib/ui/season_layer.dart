/// The website's seasonal effect layer (`src/lib/seasonal.ts`): the motif of
/// a seasonal or birthday theme drifting over the app, never taking input,
/// and off when the system turns animations off.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_parsing/path_parsing.dart';

import 'themes.dart';

class SeasonLayer extends StatelessWidget {
  const SeasonLayer({super.key, required this.motif, required this.child});

  /// The shown theme's motif, or null.
  final Motif? motif;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motif = this.motif;
    if (motif == null || MediaQuery.disableAnimationsOf(context)) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(child: _Field(motif: motif)),
          ),
        ),
      ],
    );
  }
}

class _Field extends StatefulWidget {
  const _Field({required this.motif});
  final Motif motif;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _time = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(
      (elapsed) => _time.value = elapsed.inMicroseconds / 1e6,
    )..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = MediaQuery.sizeOf(context).width < 600 ? 10 : 18;
    return CustomPaint(
      painter: _Painter(
        motif: widget.motif,
        time: _time,
        count: count,
        tones: [scheme.primary, scheme.tertiary, scheme.secondary],
        moon: scheme.tertiaryContainer,
      ),
      size: Size.infinite,
    );
  }
}

/// The same bat and sky lantern the website draws.
const _bat =
    'M12 3c.6-1 1.4-1.6 1.4-1.6l.3 1.4c1.6-.4 3.3-.2 4.6.6 1.4.9 3.4.9 5.7.1-1.3 1.3-2.2 3-2.4 5-1-.8-2.4-1-3.6-.6-.6-1.3-1.9-2-3.3-1.8-.4.9-1.6 1.7-2.7 2.5-1.1-.8-2.3-1.6-2.7-2.5-1.4-.2-2.7.5-3.3 1.8-1.2-.4-2.6-.2-3.6.6C2.2 6.5 1.3 4.8 0 3.5c2.3.8 4.3.8 5.7-.1 1.3-.8 3-1 4.6-.6l.3-1.4S11.4 2 12 3Z';
const _lantern =
    'M6 0h4v2H6zM2.5 3h11C15 5 16 8 16 12s-1 7-2.5 9h-11C1 19 0 16 0 12s1-7 2.5-9ZM6 22h4v2H6z';

class _PathProxy extends PathProxy {
  final path = Path();
  @override
  void moveTo(double x, double y) => path.moveTo(x, y);
  @override
  void lineTo(double x, double y) => path.lineTo(x, y);
  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) => path.cubicTo(x1, y1, x2, y2, x3, y3);
  @override
  void close() => path.close();
}

Path _svgPath(String data) {
  final proxy = _PathProxy();
  writeSvgPathDataToPath(data, proxy);
  return proxy.path;
}

final _batPath = _svgPath(_bat), _lanternPath = _svgPath(_lantern);

double _random(int seed) {
  final value = math.sin(seed * 9301 + 49297) * 233280;
  return value - value.floorToDouble();
}

class _Painter extends CustomPainter {
  _Painter({
    required this.motif,
    required this.time,
    required this.count,
    required this.tones,
    required this.moon,
  }) : super(repaint: time);
  final Motif motif;
  final ValueNotifier<double> time;
  final int count;
  final List<Color> tones;
  final Color moon;

  void _icon(Canvas canvas, IconData icon, Color color, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(-size / 2, -size / 2));
  }

  void _shape(Canvas canvas, Path path, Size box, Color color, double width) {
    final scale = width / box.width;
    canvas
      ..save()
      ..scale(scale)
      ..translate(-box.width / 2, -box.height / 2)
      ..drawPath(path, Paint()..color = color)
      ..restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final w = size.width, h = size.height;
    if (motif == Motif.moon) {
      final centre = Offset(w * 0.94 - 36, 124);
      canvas.drawCircle(
        centre,
        36,
        Paint()
          ..color = moon.withValues(alpha: 0.7)
          ..maskFilter = const ui.MaskFilter.blur(BlurStyle.solid, 24),
      );
    }
    for (var i = 0; i < count; i++) {
      final x0 = _random(i + 1), y0 = _random(i + 41) * 0.7;
      final duration = 10 + _random(i + 13) * 10;
      final phase = ((t + _random(i + 7) * 16) / duration) % 1;
      final scale = 0.6 + _random(i + 29) * 0.8;
      final sway = (_random(i + 3) - 0.5) * 120;
      final color = tones[i % 3].withValues(alpha: 0.55);
      final wave = math.sin(phase * 2 * math.pi);
      canvas.save();
      switch (motif) {
        case Motif.hearts || Motif.lanterns:
          canvas.translate(x0 * w + sway * wave, h + 32 - phase * (h + 64));
        case Motif.bats:
          canvas.translate(-40 + phase * (w + 80), y0 * h + sway * wave / 2);
        case Motif.stars || Motif.sparkles || Motif.fireworks:
          canvas.translate(x0 * w, y0 * h);
        default:
          canvas.translate(x0 * w + sway * wave, -32 + phase * (h + 64));
      }
      canvas.scale(scale);
      switch (motif) {
        case Motif.snow:
          if (i % 3 == 0) {
            canvas.rotate(phase * math.pi);
            _icon(canvas, Symbols.ac_unit_rounded, color, 16);
          } else {
            canvas.drawCircle(Offset.zero, 3, Paint()..color = color);
          }
        case Motif.hearts:
          _icon(canvas, Symbols.favorite_rounded, color, 18);
        case Motif.sparkles || Motif.stars:
          final glow =
              0.15 + 0.55 * (0.5 + 0.5 * math.sin(phase * 6 * math.pi));
          _icon(
            canvas,
            motif == Motif.stars
                ? Symbols.star_rounded
                : Symbols.auto_awesome_rounded,
            tones[i % 3].withValues(alpha: glow),
            motif == Motif.stars ? 12 : 18,
          );
        case Motif.petals:
          canvas.rotate(phase * 4 * math.pi);
          canvas.drawPath(
            Path()
              ..moveTo(0, -7)
              ..quadraticBezierTo(7, -7, 0, 7)
              ..quadraticBezierTo(-7, 7, 0, -7),
            Paint()..color = color,
          );
        case Motif.confetti:
          canvas.rotate(phase * 4 * math.pi);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(-3, -6, 6, 12),
              const Radius.circular(2),
            ),
            Paint()..color = color,
          );
        case Motif.beans || Motif.moon:
          canvas.drawCircle(Offset.zero, 3, Paint()..color = color);
        case Motif.bats:
          canvas.scale(1, 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t * 18 + i)));
          _shape(
            canvas,
            _batPath,
            const Size(24, 12),
            tones[i % 3].withValues(alpha: 0.5),
            32,
          );
        case Motif.lanterns:
          _shape(
            canvas,
            _lanternPath,
            const Size(16, 24),
            tones[i % 3].withValues(alpha: 0.4),
            18,
          );
        case Motif.fireworks:
          final burst = (phase * 3) % 1;
          if (burst < 0.6) {
            final paint = Paint()
              ..color = tones[i % 3].withValues(
                alpha: (1 - burst / 0.6).clamp(0, 1),
              );
            for (var k = 0; k < 10; k++) {
              final angle = k * math.pi / 5;
              canvas.drawCircle(
                Offset(math.cos(angle), math.sin(angle)) * (burst / 0.6 * 48),
                2,
                paint,
              );
            }
          }
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Painter old) =>
      old.motif != motif || old.count != count || old.tones != tones;
}

/// The brand mark, in a seasonal theme cut to its shape on a tonal container
/// with the ornament on its corner (`.nav__brand` on the website).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.decoration, this.size = 32});
  final (Motif, IconData, RoundedPolygon)? decoration;
  final double size;

  @override
  Widget build(BuildContext context) {
    final logo = Image.asset(
      'assets/brand/android-chrome-512x512.png',
      width: size,
      height: size,
    );
    final value = decoration;
    if (value == null) return logo;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipPath(
            clipper: _ShapeClipper(value.$3),
            child: ColoredBox(
              color: scheme.primaryContainer,
              child: Padding(padding: const EdgeInsets.all(3), child: logo),
            ),
          ),
          Positioned(
            left: -4,
            top: -6,
            child: Transform.rotate(
              angle: -0.31,
              child: Icon(value.$2, size: 16, color: scheme.tertiary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShapeClipper extends CustomClipper<Path> {
  _ShapeClipper(this.shape);
  final RoundedPolygon shape;

  @override
  Path getClip(Size size) => shape.normalized().toPath().transform(
    Matrix4.diagonal3Values(size.width, size.height, 1).storage,
  );

  @override
  bool shouldReclip(_ShapeClipper old) => old.shape != shape;
}
