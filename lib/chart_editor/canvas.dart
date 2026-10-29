import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cassiopeia_plugin_our_notes/render_profile.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haneoka_render_profile_flutter/haneoka_render_profile_flutter.dart';

import 'controller.dart';
import 'authoring_actions.dart';
import 'project.dart';

class ChartCanvasSkin {
  ChartCanvasSkin(this.image, this.geometry, this.ribbonColors)
    : shader = ui.ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
      );
  final ui.Image image;
  final ChartNoteGeometry geometry;
  final List<Color> ribbonColors;
  final ui.ImageShader shader;
  final _glyphs = <String, List<(ui.Vertices, double)>>{};
  static Future<ChartCanvasSkin> load() async {
    final root = haneokaProfileAssetRoot;
    final archive = chartMap(
      jsonDecode(await loadHaneokaProfileString('${root}skin001.json')),
    );
    final bytes = await loadHaneokaProfileAsset('${root}skin001.png');
    final codec = await ui.instantiateImageCodec(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    try {
      final styles = chartMap(
        jsonDecode(await loadHaneokaProfileString('${root}hold-styles.json')),
      );
      final normal = chartMap(chartMap(styles['skin001'])['normal']);
      final colors = [
        for (final row in normal['colors'] as List)
          Color.fromRGBO(
            ((row as List)[1] as num).toDouble().clamp(0, 1).multiply255,
            (row[2] as num).toDouble().clamp(0, 1).multiply255,
            (row[3] as num).toDouble().clamp(0, 1).multiply255,
            .6,
          ),
      ];
      return ChartCanvasSkin(
        image,
        ChartNoteGeometry(archive, image.width, image.height),
        colors,
      );
    } catch (_) {
      image.dispose();
      rethrow;
    }
  }

  void note(
    Canvas canvas,
    ChartNode node,
    double x,
    double y,
    double stageWidth,
    double basis,
  ) {
    final kind = node.note['type'] == 'flick'
        ? 'flick'
        : node.note['type'] == 'trace'
        ? 'trace'
        : node.line == null
        ? 'tap'
        : node.line!['kind'] == 'guide'
        ? 'guide'
        : node.pointIndex == 0
        ? 'slide-start'
        : node.pointIndex == node.pointCount! - 1
        ? 'slide-end'
        : 'slide-node';
    final direction = switch (node.note['direction']) {
      'left' => 1,
      'right' => 2,
      _ => 0,
    };
    final width = node.size * 24 / basis, key = '$kind:$direction:$width';
    final parts = _glyphs.putIfAbsent(key, () {
      return [
        for (final part
            in geometry
                .note(
                  kind: kind,
                  direction: direction,
                  lane: node.lane * 24 / basis,
                  laneWidth: width,
                  timeSeconds: 0,
                  flat: true,
                )
                .values)
          (
            ui.Vertices(
              VertexMode.triangles,
              [
                for (var i = 0; i < part.geometry.positions.length; i += 3)
                  Offset(
                    part.geometry.positions[i],
                    part.geometry.positions[i + 1],
                  ),
              ],
              textureCoordinates: [
                for (var i = 0; i < part.geometry.uv.length; i += 2)
                  Offset(
                    part.geometry.uv[i] * image.width,
                    part.geometry.uv[i + 1] * image.height,
                  ),
              ],
              indices: part.geometry.indices.toList(),
            ),
            part.alpha,
          ),
      ];
    });
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(
      stageWidth / 15.416889634999361,
      -stageWidth / 15.416889634999361,
    );
    final paint = Paint()..shader = shader;
    for (final part in parts) {
      paint.color = Colors.white.withValues(
        alpha: part.$2 * (node.note['visible'] == false ? .4 : 1),
      );
      canvas.drawVertices(part.$1, BlendMode.modulate, paint);
    }
    canvas.restore();
    if (_glyphs.length > 256) {
      final first = _glyphs.keys.first;
      for (final part in _glyphs.remove(first)!) {
        part.$1.dispose();
      }
    }
  }

  void dispose() {
    for (final parts in _glyphs.values) {
      for (final part in parts) {
        part.$1.dispose();
      }
    }
    shader.dispose();
    image.dispose();
  }
}

extension on num {
  int get multiply255 => (this * 255).round();
}

class ChartEditorCanvas extends StatefulWidget {
  const ChartEditorCanvas({super.key, required this.controller});
  final ChartEditorController controller;
  @override
  State<ChartEditorCanvas> createState() => _ChartEditorCanvasState();
}

class _ChartEditorCanvasState extends State<ChartEditorCanvas> {
  ChartEditorController get c => widget.controller;
  ChartCanvasSkin? _skin;
  Object? _skinError;
  Size _size = Size.zero;
  Offset? _down, _last, _boxEnd;
  String? _drag;
  ChartProject? _before;
  int _tick = 0;
  double _lane = 0, _startSeconds = 0, _startLane = 0;
  (int, double)? _lineStart;
  final _pointers = <int, Offset>{};
  double? _pinchDistance;
  int _cancellation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_loadSkin());
  }

  Future<void> _loadSkin() async {
    try {
      final skin = await ChartCanvasSkin.load();
      if (!mounted) {
        skin.dispose();
        return;
      }
      setState(() {
        _skin = skin;
        _skinError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _skinError = error);
    }
  }

  double _time(double y) =>
      c.windowStart + (_size.height - y) * c.secondsPerScreen / _size.height;
  double _laneAt(double x) => c.laneStart + x * c.laneSpan / _size.width;
  double _x(double lane) => (lane - c.laneStart) / c.laneSpan * _size.width;
  double _y(int tick) =>
      _size.height -
      (c.tempoMap.secondsAt(tick) - c.windowStart) *
          _size.height /
          c.secondsPerScreen;
  ChartNode? _hit(Offset point) {
    ChartNode? hit;
    var distance = double.infinity;
    final scope = c.scope;
    for (final node in c.renderNodes) {
      if (!scope.contains(node.id)) continue;
      final y = _y(node.tick),
          left = _x(node.lane),
          right = _x(node.lane + math.max(node.size, .25));
      final dx = point.dx < left
          ? left - point.dx
          : point.dx > right
          ? point.dx - right
          : 0;
      final dy = (point.dy - y).abs();
      if (dx <= 12 && dy <= 20 && dy + dx < distance) {
        hit = node;
        distance = dy + dx;
      }
    }
    return hit;
  }

  void _pointerDown(PointerDownEvent event) {
    if (c.busy || _size.isEmpty) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length > 1) {
      _drag = 'pinch';
      c.cancelGesture();
      final points = _pointers.values.take(2).toList();
      _pinchDistance = (points[0] - points[1]).distance;
      _last = (points[0] + points[1]) / 2;
      return;
    }
    final point = event.localPosition;
    _down = _last = point;
    _before = c.project.copy();
    _tick = c.snappedTick(c.tempoMap.tickAt(_time(point.dy)));
    _lane = (_laneAt(point.dx) + .5).floorToDouble();
    c.positionTick = _tick;
    _startSeconds = c.windowStart;
    _startLane = c.laneStart;
    final hit = _hit(point), keys = HardwareKeyboard.instance;
    final additive =
        c.multiSelect || keys.isControlPressed || keys.isMetaPressed;
    if (event.buttons == kMiddleMouseButton ||
        c.tool == 'pan' ||
        keys.isAltPressed) {
      _drag = 'pan';
      return;
    }
    if (c.tool == 'erase' || event.buttons == kSecondaryMouseButton) {
      if (hit != null) {
        c.select([hit.id]);
        c.deleteSelection();
      }
      _drag = 'erase';
      return;
    }
    if (c.tool == 'select') {
      if (hit == null) {
        if (!additive) c.select([]);
        _drag = 'box';
        _boxEnd = point;
      } else {
        if (additive && c.selection.contains(hit.id)) {
          c.selection.remove(hit.id);
          c.pruneSelection();
          c.changed();
          _drag = null;
          return;
        }
        if (!c.selection.contains(hit.id)) c.select([hit.id], add: additive);
        _tick = hit.tick;
        _lane = hit.lane;
        _drag = 'move';
        final left = _x(hit.lane), right = _x(hit.lane + hit.size);
        if (keys.isShiftPressed && (point.dx - left).abs() < 12) {
          _drag = 'resize-left';
        }
        if (keys.isShiftPressed && (point.dx - right).abs() < 12) {
          _drag = 'resize-right';
        }
      }
    } else if (c.tool == 'node') {
      c.insertControl(_tick, lane: _lane - c.noteWidth / 2);
      _drag = null;
    } else if (c.tool == 'hold' || c.tool == 'guide') {
      if (_lineStart != null) {
        c.addLine(_lineStart!.$1, _lineStart!.$2, _tick, _lane);
        _lineStart = null;
        _drag = null;
      } else {
        _drag = 'line';
      }
    } else if (c.tool == 'brush') {
      if (hit != null) {
        c.select([hit.id]);
        c.brush({'type': 'tap', 'size': c.noteWidth, 'critical': c.critical});
      }
      _drag = 'brush';
    } else {
      c.place(_tick, _lane - c.noteWidth / 2);
      _drag = null;
    }
    setState(() {});
  }

  void _pointerMove(PointerMoveEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_drag == 'pinch' && _pointers.length >= 2) {
      final points = _pointers.values.take(2).toList(),
          center = (points[0] + points[1]) / 2;
      final distance = (points[0] - points[1]).distance;
      if (_pinchDistance != null && distance > 0) {
        _zoom(c.secondsPerScreen * _pinchDistance! / distance, center.dy);
        if (_last != null) {
          c.windowStart +=
              (center.dy - _last!.dy) * c.secondsPerScreen / _size.height;
        }
      }
      _pinchDistance = distance;
      _last = center;
      c.changed();
      return;
    }
    if (_down == null || _drag == null) return;
    final point = event.localPosition, delta = point - _down!;
    _last = point;
    switch (_drag) {
      case 'pan':
        c.windowStart =
            (_startSeconds + delta.dy * c.secondsPerScreen / _size.height)
                .clamp(
                  0.0,
                  math.max(
                    c.duration,
                    c.tempoMap.secondsAt(c.project.lastTick),
                  ),
                );
        c.laneStart = _startLane - delta.dx * c.laneSpan / _size.width;
        c.changed();
      case 'move':
        if (delta.distance < 3) return;
        final currentTick = _before!.tempoMap.tickAt(_time(point.dy)),
            startTick = _before!.tempoMap.tickAt(_time(_down!.dy));
        final deltaTick = c.relativeSnap
            ? snapChartTick(currentTick - startTick, c.division)
            : c.snappedTick(currentTick) - c.snappedTick(startTick);
        final laneDelta = ((point.dx - _down!.dx) * c.laneSpan / _size.width)
            .roundToDouble();
        c.previewMove(_before!, deltaTick, laneDelta);
      case 'box':
        _boxEnd = point;
        setState(() {});
      case 'line':
        setState(() {});
      case 'erase':
        final hit = _hit(point);
        if (hit != null) {
          c.select([hit.id]);
          c.deleteSelection();
        }
      case 'resize-left' || 'resize-right':
        if (delta.distance < 3) return;
        final node = _before!.nodes.where((n) => n.id == c.primary).firstOrNull;
        if (node == null) return;
        final width = math.max(
          0.0,
          node.size +
              (_drag == 'resize-left' ? -1 : 1) *
                  delta.dx *
                  c.laneSpan /
                  _size.width,
        );
        final next = _before!.copy();
        // Width previews use the same transaction path as the property field.
        c.gesture = null;
        try {
          _resize(next, width);
          next.requireValid();
          c.gesture = next;
        } catch (_) {
          c.gesture = null;
        }
        c.changed();
    }
  }

  void _resize(ChartProject project, double width) {
    // Kept with the canvas gesture so pointer motion commits one history entry.
    for (final node in project.nodes) {
      if (!c.selection.contains(node.id)) continue;
      if (_drag == 'resize-left') {
        node.note['lane'] = node.lane + node.size - width;
      } else {
        node.note['lane'] = node.lane;
      }
      node.note['size'] = width;
      node.note.remove('autoSize');
    }
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_drag == 'pinch') {
      if (_pointers.isEmpty) {
        _drag = null;
        _pinchDistance = null;
      }
      return;
    }
    if (event is PointerCancelEvent) {
      c.cancelGesture();
      _drag = null;
      _down = _boxEnd = null;
      return;
    }
    if (_drag == 'move' || _drag == 'resize-left' || _drag == 'resize-right') {
      c.commitGesture();
    }
    if (_drag == 'box' && _down != null && _boxEnd != null) {
      final a = c.tempoMap.tickAt(_time(_down!.dy)),
          b = c.tempoMap.tickAt(_time(_boxEnd!.dy));
      final l = _laneAt(_down!.dx), r = _laneAt(_boxEnd!.dx);
      final scope = c.scope;
      c.select(
        [
          for (final node in c.renderNodes)
            if (scope.contains(node.id) &&
                node.tick >= math.min(a, b) &&
                node.tick <= math.max(a, b) &&
                node.lane <= math.max(l, r) &&
                node.lane + math.max(node.size, .25) >= math.min(l, r))
              node.id,
        ],
        add:
            c.multiSelect ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed,
      );
    }
    if (_drag == 'line' && _down != null && _last != null) {
      if ((_last! - _down!).distance > 6) {
        c.addLine(
          _tick,
          _lane,
          c.snappedTick(c.tempoMap.tickAt(_time(_last!.dy))),
          _laneAt(_last!.dx).roundToDouble(),
        );
      } else {
        _lineStart = (_tick, _lane);
      }
    }
    _down = _last = _boxEnd = null;
    _drag = null;
    _before = null;
    setState(() {});
  }

  void _zoom(double seconds, double anchor) {
    final at = _time(anchor);
    c.secondsPerScreen = seconds.clamp(.25, 120.0);
    c.windowStart = math.max(
      0,
      at - (_size.height - anchor) * c.secondsPerScreen / _size.height,
    );
  }

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final keys = HardwareKeyboard.instance;
      if (keys.isControlPressed || keys.isMetaPressed) {
        _zoom(
          c.secondsPerScreen * math.exp(event.scrollDelta.dy / 600),
          event.localPosition.dy,
        );
      } else if (keys.isAltPressed) {
        final lane = _laneAt(event.localPosition.dx);
        c.zoomX = (c.zoomX * math.exp(-event.scrollDelta.dy / 600)).clamp(
          .25,
          8.0,
        );
        c.laneStart = lane - event.localPosition.dx * c.laneSpan / _size.width;
      } else if (keys.isShiftPressed) {
        c.laneStart +=
            (event.scrollDelta.dx + event.scrollDelta.dy) *
            c.laneSpan /
            _size.width;
      } else {
        c.windowStart = math.max(
          0,
          c.windowStart -
              event.scrollDelta.dy * c.secondsPerScreen / _size.height,
        );
      }
      c.changed();
    });
  }

  @override
  void dispose() {
    _skin?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cancellation != c.gestureCancellation) {
      _cancellation = c.gestureCancellation;
      _lineStart = null;
    }
    final text = Theme.of(context).textTheme.labelSmall!,
        colors = Theme.of(context).colorScheme;
    if (_skinError != null) {
      return Center(
        child: FilledButton.tonal(onPressed: _loadSkin, child: Text('↻')),
      );
    }
    if (_skin == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Listener(
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerUp,
          onPointerSignal: _signal,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([c, c.audio.position]),
              builder: (context, _) => CustomPaint(
                size: _size,
                painter: ChartEditorPainter(
                  c,
                  _skin!,
                  colors,
                  text,
                  box: _down != null && _boxEnd != null
                      ? Rect.fromPoints(_down!, _boxEnd!)
                      : null,
                  pending:
                      _lineStart ?? (_drag == 'line' ? (_tick, _lane) : null),
                  pointer: _last,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ChartEditorPainter extends CustomPainter {
  ChartEditorPainter(
    this.controller,
    this.skin,
    this.colors,
    this.textStyle, {
    this.box,
    this.pending,
    this.pointer,
  });
  final ChartEditorController controller;
  final ChartCanvasSkin skin;
  final ColorScheme colors;
  final TextStyle textStyle;
  final Rect? box;
  final (int, double)? pending;
  final Offset? pointer;
  @override
  void paint(Canvas canvas, Size size) {
    final c = controller,
        project = c.project,
        map = c.tempoMap,
        scope = c.scope,
        span = c.laneSpan;
    final nodeById = c.renderNodesById;
    double x(double lane) => (lane - c.laneStart) / span * size.width;
    double y(num tick) =>
        size.height -
        (map.secondsAt(tick) - c.windowStart) *
            size.height /
            c.secondsPerScreen;
    final stageWidth = project.laneBasis / span * size.width,
        paint = Paint()..isAntiAlias = true;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(
      Offset.zero & size,
      paint..color = colors.surfaceContainerHigh,
    );
    canvas.drawRect(
      Rect.fromLTRB(x(0), 0, x(project.laneBasis), size.height),
      paint..color = colors.scrim,
    );
    for (var i = 0; i <= 6; i++) {
      canvas.drawLine(
        Offset(x(project.laneBasis * i / 6), 0),
        Offset(x(project.laneBasis * i / 6), size.height),
        paint
          ..color = colors.outlineVariant
          ..strokeWidth = 1,
      );
    }
    final start = math.max(0, (map.tickAt(c.windowStart) / 480).floor()),
        end = map.tickAt(c.windowStart + c.secondsPerScreen) / 480;
    final step = math.max(1 / c.division, (end - start) / 256);
    for (var beat = start.toDouble(); beat <= end; beat += step) {
      final whole = (beat - beat.round()).abs() < .001;
      canvas.drawLine(
        Offset(0, y(beat * 480)),
        Offset(size.width, y(beat * 480)),
        paint
          ..color = colors.outlineVariant.withValues(alpha: whole ? .8 : .25)
          ..strokeWidth = 1,
      );
      if (whole) {
        _label(
          canvas,
          '${beat.toInt()}',
          Offset(4, y(beat * 480) - 14),
          colors.onSurfaceVariant,
        );
      }
    }
    final waveform = c.media?.waveform;
    if (waveform != null && waveform.isNotEmpty) {
      final begin = (c.windowStart / c.duration * waveform.length)
              .floor()
              .clamp(0, waveform.length),
          stop =
              ((c.windowStart + c.secondsPerScreen) /
                      c.duration *
                      waveform.length)
                  .ceil()
                  .clamp(0, waveform.length);
      final center = size.width / 2, maxWidth = stageWidth * .25;
      paint.color = colors.onSurface.withValues(alpha: .16);
      paint.strokeWidth = 1;
      for (var i = begin; i < stop; i++) {
        final yy =
            size.height -
            (i / waveform.length * c.duration - c.windowStart) *
                size.height /
                c.secondsPerScreen;
        final w = waveform[i] * maxWidth;
        canvas.drawLine(Offset(center - w, yy), Offset(center + w, yy), paint);
      }
    }
    for (final line in project.lines) {
      final points = chartRows(line['points']);
      if (!points.any((p) => scope.contains(p['id']))) continue;
      for (var i = 0; i < points.length - 1; i++) {
        final a = points[i],
            b = points[i + 1],
            sa = (nodeById[a['id']]!.lane, nodeById[a['id']]!.size),
            sb = (nodeById[b['id']]!.lane, nodeById[b['id']]!.size);
        final ya = y(a['tick'] as int), yb = y(b['tick'] as int);
        if (math.min(ya, yb) > size.height || math.max(ya, yb) < 0) continue;
        final ease = chartMap(a['ease']), path = Path();
        const count = 24;
        for (var s = 0; s <= count; s++) {
          final t = s / count,
              xx = sa.$1 + (sb.$1 - sa.$1) * chartEase(ease['left'], t),
              yy = y(
                (a['tick'] as int) +
                    ((b['tick'] as int) - (a['tick'] as int)) * t,
              );
          if (s == 0) {
            path.moveTo(x(xx), yy);
          } else {
            path.lineTo(x(xx), yy);
          }
        }
        for (var s = count; s >= 0; s--) {
          final t = s / count,
              xx =
                  sa.$1 +
                  sa.$2 +
                  (sb.$1 + sb.$2 - sa.$1 - sa.$2) * chartEase(ease['right'], t);
          path.lineTo(
            x(xx),
            y(
              (a['tick'] as int) +
                  ((b['tick'] as int) - (a['tick'] as int)) * t,
            ),
          );
        }
        path.close();
        paint
          ..shader = null
          ..style = PaintingStyle.fill
          ..color = colors.primary.withValues(
            alpha: line['kind'] == 'guide' ? .25 : .6,
          );
        if (skin.ribbonColors.length >= 2) {
          paint.shader = ui.Gradient.linear(
            Offset(x(sa.$1), ya),
            Offset(x(sa.$1 + sa.$2), ya),
            skin.ribbonColors,
            List.generate(
              skin.ribbonColors.length,
              (index) => index / (skin.ribbonColors.length - 1),
            ),
          );
        }
        canvas.drawPath(path, paint);
        paint.shader = null;
      }
    }
    for (final node in c.renderNodes) {
      if (!scope.contains(node.id)) continue;
      final yy = y(node.tick);
      if (yy < -48 || yy > size.height + 48) continue;
      final left = x(node.lane), right = x(node.lane + node.size);
      skin.note(
        canvas,
        node,
        (left + right) / 2,
        yy,
        stageWidth,
        project.laneBasis,
      );
      if (c.selection.contains(node.id) || node.note['critical'] == true) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              left - 3,
              yy - 10,
              math.max(left + 3, right) + 3,
              yy + 10,
            ),
            const Radius.circular(4),
          ),
          paint
            ..shader = null
            ..style = PaintingStyle.stroke
            ..color = c.selection.contains(node.id)
                ? colors.primary
                : colors.tertiary
            ..strokeWidth = 2,
        );
        paint.style = PaintingStyle.fill;
      }
    }
    for (final tempo in project.tempos) {
      final yy = y(tempo['tick'] as int);
      if (yy >= 0 && yy <= size.height) {
        _label(
          canvas,
          '${tempo['bpm']} BPM',
          Offset(size.width - 80, yy - 18),
          colors.tertiary,
        );
      }
    }
    final playY =
        size.height -
        (c.position - c.windowStart) * size.height / c.secondsPerScreen;
    canvas.drawLine(
      Offset(0, playY),
      Offset(size.width, playY),
      paint
        ..color = colors.primary
        ..strokeWidth = 2,
    );
    if (box != null) {
      canvas.drawRect(
        box!,
        paint..color = colors.primary.withValues(alpha: .15),
      );
      canvas.drawRect(
        box!,
        paint
          ..color = colors.primary
          ..style = PaintingStyle.stroke,
      );
      paint.style = PaintingStyle.fill;
    }
    if (pending != null) {
      final at = Offset(x(pending!.$2), y(pending!.$1));
      canvas.drawCircle(at, 6, paint..color = colors.primary);
      if (pointer != null) {
        canvas.drawLine(at, pointer!, paint..strokeWidth = 2);
      }
    }
    canvas.restore();
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: textStyle.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
    painter.dispose();
  }

  @override
  bool shouldRepaint(ChartEditorPainter old) => true;
}
