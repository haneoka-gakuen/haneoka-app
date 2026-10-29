import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter/painting.dart';

/// The stamp maker's layers and drawing, a port of the website's
/// `lib/stamp-maker/render.ts`, `layers.ts` and `text-layout.ts` (the
/// layout without fixed frames). Positions and sizes are percentages of
/// the canvas width, so the preview and every export size agree.

const stampCanvasSize = 512.0;

class StampBackground {
  StampBackground({
    this.color = const Color(0xFFFFFFFF),
    this.alpha = 0,
    this.padding = 2,
    this.radius = 2,
  });
  Color color;
  double alpha;
  double padding;
  double radius;
  StampBackground copy() => StampBackground(
    color: color,
    alpha: alpha,
    padding: padding,
    radius: radius,
  );
}

class StampText {
  StampText({
    this.text = '',
    this.x = 50,
    this.y = 18,
    this.size = 9,
    this.rotation = 0,
    this.font = 'YurukaStd',
    this.fill = const Color(0xFF333333),
    this.stroke = const Color(0xFFFFFFFF),
    this.strokeWidth = 1.2,
    this.writingMode = 'horizontal',
    StampBackground? background,
  }) : background = background ?? StampBackground();
  String text;
  double x;
  double y;
  double size;
  double rotation;
  String font;
  Color fill;
  Color stroke;
  double strokeWidth;

  /// `horizontal`, `vertical-rl` or `vertical-lr`.
  String writingMode;
  StampBackground background;

  StampText copy() => StampText(
    text: text,
    x: x,
    y: y,
    size: size,
    rotation: rotation,
    font: font,
    fill: fill,
    stroke: stroke,
    strokeWidth: strokeWidth,
    writingMode: writingMode,
    background: background.copy(),
  );
}

class StampImageTransform {
  StampImageTransform({
    this.x = 50,
    this.y = 50,
    this.scale = 100,
    this.rotation = 0,
  });
  double x;
  double y;
  double scale;
  double rotation;
}

/// The stamp image (one layer) or a text layer.
class StampLayer {
  StampLayer.text([StampText? text])
    : settings = text ?? StampText(),
      image = null;
  StampLayer.image()
    : settings = StampText(text: ''),
      image = StampImageTransform();
  StampLayer._(this.settings, this.image);
  final StampText settings;
  final StampImageTransform? image;
  StampLayer copy() => StampLayer._(
    settings.copy(),
    image == null
        ? null
        : StampImageTransform(
            x: image!.x,
            y: image!.y,
            scale: image!.scale,
            rotation: image!.rotation,
          ),
  );
}

class _Cell {
  _Cell(this.text, this.x, this.y, this.rotation, this.scale);
  final String text;
  final double x;
  final double y;
  final double rotation;
  final double scale;
}

// Rotate the original punctuation outlines in vertical text.
final _verticalRotated = '（）｛｝〔〕【】《》〈〉「」『』…—ー：；'.characters.toSet();
final _verticalCorner = '、。，．'.characters.toSet();
final _letter = RegExp(r'^(?:[A-Za-zÀ-ɏ]|[0-9])$');
final _runPunctuation = RegExp(r'''^[.,:;!?'"\-]$''');

TextStyle stampTextStyle(StampText text, double width) => TextStyle(
  fontFamily: text.font == 'auto' ? null : text.font,
  fontWeight: text.font == 'YurukaStd' ? FontWeight.w900 : FontWeight.w600,
  fontSize: width * text.size / 100,
  height: 1,
);

double _measure(String text, TextStyle style) => (TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: TextDirection.ltr,
)..layout()).width;

/// `legacyStampTextLayout`: lines stacked horizontally, or columns of
/// characters (Latin runs and punctuation rotated) for vertical text.
List<_Cell> _layout(StampText text, double width) {
  final style = stampTextStyle(text, width);
  final size = width * text.size / 100;
  final gap = size * 1.15;
  if (text.writingMode == 'horizontal') {
    final lines = text.text.split('\n');
    return [
      for (final (index, line) in lines.indexed)
        _Cell(line, 0, (index - (lines.length - 1) / 2) * gap, 0, 1),
    ];
  }
  final limit = width * 0.8;
  final columns =
      <
        List<
          ({
            String text,
            bool rotated,
            double advance,
            double scale,
            Offset offset,
          })
        >
      >[];
  for (final line in text.text.split('\n')) {
    final characters = line.characters.toList();
    final tokens =
        <
          ({
            String text,
            bool rotated,
            double advance,
            double scale,
            Offset offset,
          })
        >[];
    for (var i = 0; i < characters.length;) {
      if (_letter.hasMatch(characters[i])) {
        var run = characters[i++];
        while (i < characters.length &&
            (_letter.hasMatch(characters[i]) ||
                _runPunctuation.hasMatch(characters[i]))) {
          final next = run + characters[i];
          if (_measure(next, style) > limit && run.isNotEmpty) break;
          run = next;
          i++;
        }
        // One or two digits stay upright (tate-chu-yoko).
        final upright = RegExp(r'^\d{1,2}$').hasMatch(run);
        final w = _measure(run, style);
        final scale = upright
            ? min(1.0, size * 0.9 / max(1, w))
            : min(1.0, limit / max(1, w));
        tokens.add((
          text: run,
          rotated: !upright,
          advance: upright ? size * 1.15 : w * scale + size * 0.12,
          scale: scale,
          offset: Offset.zero,
        ));
      } else {
        final c = characters[i++];
        tokens.add((
          text: c,
          rotated: _verticalRotated.contains(c),
          advance: size * 1.15,
          scale: 1,
          offset: _verticalCorner.contains(c)
              ? Offset(size * 0.25, -size * 0.25)
              : Offset.zero,
        ));
      }
    }
    var column =
        <
          ({
            String text,
            bool rotated,
            double advance,
            double scale,
            Offset offset,
          })
        >[];
    var used = 0.0;
    for (final token in tokens) {
      if (column.isNotEmpty && used + token.advance > limit) {
        columns.add(column);
        column = [];
        used = 0;
      }
      column.add(token);
      used += token.advance;
    }
    columns.add(column);
  }
  final height = [
    size,
    for (final column in columns)
      column.fold(0.0, (t, token) => t + token.advance),
  ].reduce(max);
  final cells = <_Cell>[];
  for (final (index, column) in columns.indexed) {
    final x =
        (index - (columns.length - 1) / 2) *
        gap *
        (text.writingMode == 'vertical-rl' ? -1 : 1);
    var y = -height / 2;
    for (final token in column) {
      cells.add(
        _Cell(
          token.text,
          x + token.offset.dx,
          y + token.advance / 2 + token.offset.dy,
          token.rotated ? pi / 2 : 0,
          token.scale,
        ),
      );
      y += token.advance;
    }
  }
  return cells;
}

Rect _cellBounds(List<_Cell> cells, TextStyle style, double stroke) {
  var bounds = Rect.zero;
  var first = true;
  for (final cell in cells) {
    if (cell.text.trim().isEmpty) continue;
    final painter = TextPainter(
      text: TextSpan(text: cell.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final half = Size(painter.width / 2 + stroke, painter.height / 2 + stroke);
    final c = cos(cell.rotation), s = sin(cell.rotation);
    for (final p in [
      Offset(-half.width, -half.height),
      Offset(half.width, -half.height),
      Offset(half.width, half.height),
      Offset(-half.width, half.height),
    ]) {
      final point = Offset(
        cell.x + (p.dx * c - p.dy * s) * cell.scale,
        cell.y + (p.dx * s + p.dy * c) * cell.scale,
      );
      bounds = first
          ? Rect.fromPoints(point, point)
          : bounds.expandToInclude(Rect.fromPoints(point, point));
      first = false;
    }
  }
  return bounds;
}

void _drawText(Canvas canvas, StampText text, double width) {
  final background = text.background;
  if (text.text.trim().isEmpty && background.alpha <= 0) return;
  final style = stampTextStyle(text, width);
  final cells = _layout(text, width);
  final stroke = width * text.strokeWidth / 100;
  canvas.save();
  canvas.translate(width * text.x / 100, width * text.y / 100);
  canvas.rotate(text.rotation * pi / 180);
  if (background.alpha > 0) {
    final ink = _cellBounds(
      cells,
      style,
      stroke,
    ).inflate(width * background.padding / 100);
    final radius = min(
      width * background.radius / 100,
      min(ink.width, ink.height) / 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(ink, Radius.circular(max(0, radius))),
      Paint()
        ..color = background.color.withValues(
          alpha: (background.alpha / 100).clamp(0, 1),
        ),
    );
  }
  for (final cell in cells) {
    canvas.save();
    canvas.translate(cell.x, cell.y);
    canvas.rotate(cell.rotation);
    canvas.scale(cell.scale, cell.scale);
    TextPainter painter(Paint? foreground) => TextPainter(
      text: TextSpan(
        text: cell.text,
        style: foreground == null
            ? style.copyWith(color: text.fill)
            : style.copyWith(foreground: foreground),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (text.strokeWidth > 0) {
      final outline = painter(
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 2
          ..strokeJoin = StrokeJoin.round
          ..color = text.stroke,
      );
      outline.paint(canvas, Offset(-outline.width / 2, -outline.height / 2));
    }
    final fill = painter(null);
    fill.paint(canvas, Offset(-fill.width / 2, -fill.height / 2));
    canvas.restore();
  }
  canvas.restore();
}

/// The image's drawn size: fitted inside the 512 canvas, then scaled
/// (`imageSize`).
Size stampImageSize(
  ui.Image image,
  StampImageTransform transform,
  double width,
) {
  final w = image.width.toDouble(), h = image.height.toDouble();
  final fit =
      min(1.0, min(stampCanvasSize / w, stampCanvasSize / h)) *
      width /
      stampCanvasSize *
      transform.scale /
      100;
  return Size(w * fit, h * fit);
}

/// Draws every layer in order (`drawStamp`).
void drawStamp(
  Canvas canvas,
  double width,
  ui.Image? image,
  List<StampLayer> layers,
) {
  for (final layer in layers) {
    final transform = layer.image;
    if (transform != null) {
      if (image == null) continue;
      final size = stampImageSize(image, transform, width);
      canvas.save();
      canvas.translate(width * transform.x / 100, width * transform.y / 100);
      canvas.rotate(transform.rotation * pi / 180);
      paintImage(
        canvas: canvas,
        rect: Rect.fromCenter(
          center: Offset.zero,
          width: size.width,
          height: size.height,
        ),
        image: image,
        filterQuality: FilterQuality.high,
      );
      canvas.restore();
    } else {
      _drawText(canvas, layer.settings, width);
    }
  }
}

/// A PNG of the composition at [width] pixels square.
Future<List<int>> stampPng(
  double width,
  ui.Image? image,
  List<StampLayer> layers,
) async {
  final recorder = ui.PictureRecorder();
  drawStamp(Canvas(recorder), width, image, layers);
  final picture = recorder.endRecording();
  final rendered = await picture.toImage(width.round(), width.round());
  final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Map<String, Object?> stampLayerJson(StampLayer layer) {
  final text = layer.settings, bg = text.background, image = layer.image;
  return {
    'kind': image == null ? 'text' : 'image',
    'text': text.text,
    'x': text.x,
    'y': text.y,
    'size': text.size,
    'rotation': text.rotation,
    'font': text.font,
    'fill': text.fill.toARGB32(),
    'stroke': text.stroke.toARGB32(),
    'strokeWidth': text.strokeWidth,
    'writingMode': text.writingMode,
    'background': {
      'color': bg.color.toARGB32(),
      'alpha': bg.alpha,
      'padding': bg.padding,
      'radius': bg.radius,
    },
    if (image != null)
      'image': {
        'x': image.x,
        'y': image.y,
        'scale': image.scale,
        'rotation': image.rotation,
      },
  };
}

StampLayer stampLayerFromJson(Map<String, dynamic> value) {
  final bg = (value['background'] as Map).cast<String, dynamic>();
  final text = StampText(
    text: value['text'] as String,
    x: (value['x'] as num).toDouble(),
    y: (value['y'] as num).toDouble(),
    size: (value['size'] as num).toDouble(),
    rotation: (value['rotation'] as num).toDouble(),
    font: value['font'] as String,
    fill: Color(value['fill'] as int),
    stroke: Color(value['stroke'] as int),
    strokeWidth: (value['strokeWidth'] as num).toDouble(),
    writingMode: value['writingMode'] as String,
    background: StampBackground(
      color: Color(bg['color'] as int),
      alpha: (bg['alpha'] as num).toDouble(),
      padding: (bg['padding'] as num).toDouble(),
      radius: (bg['radius'] as num).toDouble(),
    ),
  );
  final image = value['image'] as Map?;
  return StampLayer._(
    text,
    image == null
        ? null
        : StampImageTransform(
            x: (image['x'] as num).toDouble(),
            y: (image['y'] as num).toDouble(),
            scale: (image['scale'] as num).toDouble(),
            rotation: (image['rotation'] as num).toDouble(),
          ),
  );
}
