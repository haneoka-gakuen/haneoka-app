/// The website's seasonal background (`src/lib/seasonal.ts`) for a seasonal
/// or birthday theme, behind the app; still when the system turns animations
/// off.
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
    if (motif == null) return child;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: _Backdrop(
                motif: motif,
                still: MediaQuery.disableAnimationsOf(context),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// The website's seasonal background (MoeSekai's brand background): a wash
/// in the theme's colours, three facets, and the motif over three depths with
/// blur, drifting slowly. It sits behind the app, which turns its frame
/// transparent and its page pane translucent while it shows.
class _Backdrop extends StatefulWidget {
  const _Backdrop({required this.motif, required this.still});
  final Motif motif;
  final bool still;

  @override
  State<_Backdrop> createState() => _BackdropState();
}

class _BackdropState extends State<_Backdrop>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _time = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    // The drift is slow: about fifteen frames a second is smooth enough.
    _ticker = createTicker((elapsed) {
      final t = elapsed.inMilliseconds / 1000;
      if (t - _time.value >= 1 / 15) _time.value = t;
    });
    if (!widget.still) _ticker.start();
  }

  @override
  void didUpdateWidget(_Backdrop old) {
    super.didUpdateWidget(old);
    if (widget.still && _ticker.isActive) _ticker.stop();
    if (!widget.still && !_ticker.isActive) _ticker.start();
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
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return CustomPaint(
      painter: _Painter(
        motif: widget.motif,
        time: _time,
        narrow: narrow,
        scheme: scheme,
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

/// Depths from far to near: glyph count, size range, blur and opacity.
const _depths = [
  (count: 5, size: (56.0, 88.0), blur: 6.0, opacity: 0.3),
  (count: 8, size: (22.0, 32.0), blur: 1.5, opacity: 0.55),
  (count: 14, size: (14.0, 22.0), blur: 0.0, opacity: 0.75),
];

class _Painter extends CustomPainter {
  _Painter({
    required this.motif,
    required this.time,
    required this.narrow,
    required this.scheme,
  }) : super(repaint: time);
  final Motif motif;
  final ValueNotifier<double> time;
  final bool narrow;
  final ColorScheme scheme;

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

  void _glyph(Canvas canvas, int index, Color color, double size) {
    final paint = Paint()..color = color;
    switch (motif) {
      case Motif.snow when index % 3 == 0:
        _icon(canvas, Symbols.ac_unit_rounded, color, size);
      case Motif.hearts:
        _icon(canvas, Symbols.favorite_rounded, color, size);
      case Motif.sparkles || Motif.fireworks when index % 3 != 0:
        _icon(canvas, Symbols.auto_awesome_rounded, color, size);
      case Motif.stars when index % 3 != 0:
        _icon(canvas, Symbols.star_rounded, color, size);
      case Motif.bats:
        _shape(canvas, _batPath, const Size(24, 12), color, size);
      case Motif.lanterns:
        _shape(canvas, _lanternPath, const Size(16, 24), color, size * 0.7);
      case Motif.petals:
        final r = size / 2;
        canvas.drawPath(
          Path()
            ..moveTo(0, -r)
            ..quadraticBezierTo(r * 0.8, -r, 0, r)
            ..quadraticBezierTo(-r * 0.8, r, 0, -r),
          paint,
        );
      case Motif.confetti:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: size * 0.36,
              height: size * 0.72,
            ),
            const Radius.circular(2),
          ),
          paint,
        );
      default:
        canvas.drawCircle(Offset.zero, size * 0.2, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final w = size.width, h = size.height;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = scheme.surfaceContainer,
    );
    void wash(Offset centre, double rx, double ry, Color color, double alpha) {
      canvas
        ..save()
        ..translate(centre.dx, centre.dy)
        ..scale(1, ry / rx)
        ..drawCircle(
          Offset.zero,
          rx,
          Paint()
            ..shader = RadialGradient(
              colors: [
                color.withValues(alpha: alpha),
                color.withValues(alpha: 0),
              ],
              stops: const [0, 0.72],
            ).createShader(Rect.fromCircle(center: Offset.zero, radius: rx)),
        )
        ..restore();
    }

    wash(Offset.zero, 1024, 832, scheme.primaryContainer, 0.7);
    wash(Offset(w * 0.62, -h * 0.1), 1152, 704, scheme.tertiaryContainer, 0.6);
    wash(Offset(w, h), 1088, 832, scheme.primaryContainer, 0.55);
    wash(Offset(w * 0.06, h), 896, 704, scheme.tertiaryContainer, 0.5);
    final facet = Paint()
      ..color = scheme.surfaceBright.withValues(alpha: 0.45 * 0.9);
    Path poly(List<double> points) {
      final path = Path()..moveTo(points[0] / 1600 * w, points[1] / 900 * h);
      for (var i = 2; i < points.length; i += 2) {
        path.lineTo(points[i] / 1600 * w, points[i + 1] / 900 * h);
      }
      return path..close();
    }

    canvas
      ..drawPath(poly([0, 0, 380, 0, 0, 820]), facet)
      ..drawPath(
        poly([250, 0, 1600, 0, 1600, 380, 1040, 250]),
        Paint()..color = scheme.surfaceBright.withValues(alpha: 0.45 * 0.55),
      )
      ..drawPath(
        poly([120, 900, 1040, 250, 1600, 380, 1600, 900]),
        Paint()..color = scheme.surfaceBright.withValues(alpha: 0.45 * 0.75),
      );
    if (motif == Motif.moon) {
      canvas.drawCircle(
        Offset(w * 0.92 - 60, h * 0.12 + 60),
        60,
        Paint()
          ..color = scheme.tertiaryContainer.withValues(alpha: 0.8)
          ..maskFilter = const ui.MaskFilter.blur(BlurStyle.solid, 40),
      );
    }
    final tones = [scheme.primary, scheme.tertiary];
    for (final (layer, depth) in _depths.indexed) {
      final count = narrow ? (depth.count / 2).ceil() : depth.count;
      if (depth.blur > 0) {
        canvas.saveLayer(
          null,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: depth.blur,
              sigmaY: depth.blur,
            ),
        );
      }
      for (var i = 0; i < count; i++) {
        final seed = layer * 97 + i + 1;
        final glyph =
            depth.size.$1 + _random(seed + 3) * (depth.size.$2 - depth.size.$1);
        final duration = 14 + _random(seed + 13) * 14;
        // An eased back-and-forth like the website's alternate drift.
        final phase =
            0.5 -
            0.5 * math.cos((t / duration + _random(seed + 7)) * 2 * math.pi);
        final dx = (_random(seed + 5) - 0.5) * 32 * phase;
        final dy = (_random(seed + 9) - 0.5) * 40 * phase;
        final turn = (_random(seed + 11) - 0.5) * 24 * phase;
        var alpha = depth.opacity;
        if ((motif == Motif.stars ||
                motif == Motif.sparkles ||
                motif == Motif.fireworks) &&
            depth.blur == 0) {
          alpha *= 0.72 + 0.28 * math.sin((t / duration * 3 + i) * 2 * math.pi);
        }
        canvas
          ..save()
          ..translate(
            _random(seed) * w + dx,
            (_random(seed + 41) * 1.2 - 0.1) * h + dy,
          )
          ..rotate(((_random(seed + 17) - 0.5) * 60 + turn) * math.pi / 180);
        _glyph(canvas, i, tones[i % 2].withValues(alpha: alpha), glyph);
        canvas.restore();
      }
      if (depth.blur > 0) canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Painter old) =>
      old.motif != motif || old.narrow != narrow || old.scheme != scheme;
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
