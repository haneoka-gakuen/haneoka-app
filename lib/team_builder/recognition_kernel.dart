/// On-device card recognition (`team-builder/screenshot-recognition/kernel.ts`):
/// grid proposals, identity by masked colour correlation against the
/// release's reference tiles, and the native Lv glyph reader. Pure functions
/// over RGBA rasters, run in an isolate.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class Raster {
  const Raster(this.width, this.height, this.data);
  final int width, height;

  /// RGBA bytes.
  final Uint8List data;
}

class Mask {
  const Mask(this.width, this.height, this.data);
  final int width, height;
  final Float32List data;
}

class ReferenceKind {
  const ReferenceKind(
    this.tileWidth,
    this.tileHeight,
    this.cardIds,
    this.vectors,
  );
  final int tileWidth, tileHeight;
  final List<int> cardIds;
  final List<Float32List> vectors;
}

class LocalReference {
  const LocalReference(this.members, this.snapshots, this.glyphs, this.allowed);
  final ReferenceKind members, snapshots;
  final Map<String, Mask>? glyphs;

  /// Allowed levels by kind (`members`, `snapshots`).
  final Map<String, Set<int>>? allowed;
  ReferenceKind kind(String kind) => kind == 'members' ? members : snapshots;
}

class RecognizedCell {
  const RecognizedCell({
    required this.kind,
    required this.bbox,
    required this.cardId,
    required this.candidates,
    required this.level,
  });
  final String kind;
  final List<int> bbox;
  final int? cardId;
  final List<int> candidates;
  final int? level;
}

const _workingSide = 2048;
const _acceptScore = 0.6;
const _acceptMargin = 0.06;
const _maskTop = 0.12, _maskBottom = 0.89, _maskLeft = 0.09, _maskRight = 0.9;

class _Weights {
  _Weights(this.index, this.weight);
  final List<int> index;
  final List<double> weight;
}

List<_Weights> _weights(double start, double span, int count, int limit) {
  final step = span / count;
  return [
    for (var i = 0; i < count; i++)
      () {
        final from = start + i * step, to = from + step;
        final index = <int>[], weight = <double>[];
        var total = 0.0;
        for (var p = from.floor(); p < to.ceil(); p++) {
          final cover = math.min(to, p + 1.0) - math.max(from, p.toDouble());
          if (cover <= 0) continue;
          index.add(math.min(limit - 1, math.max(0, p)));
          weight.add(cover);
          total += cover;
        }
        return _Weights(index, [for (final w in weight) w / total]);
      }(),
  ];
}

/// Box-filter resample of an RGBA region into width × height RGB floats.
Float32List sampleRegion(
  Raster image,
  double x,
  double y,
  double w,
  double h,
  int width,
  int height,
) {
  final columns = _weights(x, w, width, image.width);
  final rows = _weights(y, h, height, image.height);
  final out = Float32List(width * height * 3);
  final line = Float32List(width * 3);
  for (var ty = 0; ty < height; ty++) {
    final row = rows[ty];
    for (var r = 0; r < row.index.length; r++) {
      final sy = row.index[r], wy = row.weight[r];
      for (var tx = 0; tx < width; tx++) {
        final column = columns[tx];
        var red = 0.0, green = 0.0, blue = 0.0;
        for (var c = 0; c < column.index.length; c++) {
          final offset = (sy * image.width + column.index[c]) * 4;
          final wx = column.weight[c];
          red += image.data[offset] * wx;
          green += image.data[offset + 1] * wx;
          blue += image.data[offset + 2] * wx;
        }
        line[tx * 3] = red;
        line[tx * 3 + 1] = green;
        line[tx * 3 + 2] = blue;
      }
      final base = ty * width * 3;
      for (var i = 0; i < width * 3; i++) {
        out[base + i] += line[i] * wy;
      }
    }
  }
  return out;
}

/// Zero-mean, unit-length colour vector over the identity mask.
Float32List tileVector(Float32List rgb, int width, int height) {
  final top = (height * _maskTop).round(),
      bottom = (height * _maskBottom).round();
  final left = (width * _maskLeft).round(),
      right = (width * _maskRight).round();
  final out = Float32List((bottom - top) * (right - left) * 3);
  final mean = [0.0, 0.0, 0.0];
  var n = 0;
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      for (var c = 0; c < 3; c++) {
        final value = rgb[(y * width + x) * 3 + c];
        out[n++] = value;
        mean[c] += value;
      }
    }
  }
  final pixels = n / 3;
  var norm = 0.0;
  for (var i = 0; i < n; i++) {
    out[i] = out[i] - mean[i % 3] / pixels;
    norm += out[i] * out[i];
  }
  norm = norm > 0 ? math.sqrt(norm) : 1;
  for (var i = 0; i < n; i++) {
    out[i] = out[i] / norm;
  }
  return out;
}

double _dot(Float32List a, Float32List b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

({int? cardId, List<int> candidates}) matchIdentity(
  Raster image,
  List<int> bbox,
  ReferenceKind reference,
) {
  final tw = reference.tileWidth, th = reference.tileHeight;
  final x = bbox[0].toDouble(), y = bbox[1].toDouble();
  final w = bbox[2].toDouble(), h = bbox[3].toDouble();
  final base = tileVector(sampleRegion(image, x, y, w, h, tw, th), tw, th);
  final coarse = [
    for (var i = 0; i < reference.vectors.length; i++)
      (index: i, score: _dot(base, reference.vectors[i])),
  ]..sort((a, b) => b.score.compareTo(a.score));
  final shifted = <Float32List>[];
  for (final scale in const [0.96, 1.0, 1.04]) {
    for (final dy in const [-0.03, -0.015, 0.0, 0.015, 0.03]) {
      for (final dx in const [-0.03, -0.015, 0.0, 0.015, 0.03]) {
        final sw = w * scale, sh = h * scale;
        final sx = x + (w - sw) / 2 + dx * w, sy = y + (h - sh) / 2 + dy * h;
        if (sx < 0 ||
            sy < 0 ||
            sx + sw > image.width ||
            sy + sh > image.height) {
          continue;
        }
        shifted.add(
          tileVector(sampleRegion(image, sx, sy, sw, sh, tw, th), tw, th),
        );
      }
    }
  }
  final refined = [
    for (final leader in coarse.take(6))
      (
        index: leader.index,
        score: shifted.fold(
          leader.score,
          (best, v) => math.max(best, _dot(v, reference.vectors[leader.index])),
        ),
      ),
  ]..sort((a, b) => b.score.compareTo(a.score));
  if (refined.isEmpty) return (cardId: null, candidates: const []);
  final best = refined.first;
  final accepted =
      best.score >= _acceptScore &&
      (refined.length < 2 || best.score - refined[1].score >= _acceptMargin);
  return (
    cardId: accepted ? reference.cardIds[best.index] : null,
    candidates: [for (final r in refined.take(5)) reference.cardIds[r.index]],
  );
}

/// Canny with a 3×3 Sobel, L1 magnitude and hysteresis.
Uint8List canny(Raster image, double low, double high) {
  final W = image.width, H = image.height;
  final g = Float32List(W * H);
  for (var i = 0, p = 0; i < g.length; i++, p += 4) {
    g[i] =
        0.299 * image.data[p] +
        0.587 * image.data[p + 1] +
        0.114 * image.data[p + 2];
  }
  final magnitude = Float32List(W * H);
  final direction = Uint8List(W * H);
  for (var y = 1; y < H - 1; y++) {
    for (var x = 1; x < W - 1; x++) {
      final i = y * W + x;
      final gx =
          g[i - W + 1] +
          2 * g[i + 1] +
          g[i + W + 1] -
          g[i - W - 1] -
          2 * g[i - 1] -
          g[i + W - 1];
      final gy =
          g[i + W - 1] +
          2 * g[i + W] +
          g[i + W + 1] -
          g[i - W - 1] -
          2 * g[i - W] -
          g[i - W + 1];
      final ax = gx.abs(), ay = gy.abs();
      magnitude[i] = ax + ay;
      direction[i] = ay <= ax * 0.4142
          ? 0
          : ay >= ax * 2.4142
          ? 2
          : gx * gy > 0
          ? 3
          : 1;
    }
  }
  final state = Uint8List(W * H);
  final stack = <int>[];
  for (var y = 1; y < H - 1; y++) {
    for (var x = 1; x < W - 1; x++) {
      final i = y * W + x, m = magnitude[i];
      if (m <= low) continue;
      final (a, b) = switch (direction[i]) {
        0 => (i - 1, i + 1),
        2 => (i - W, i + W),
        3 => (i - W - 1, i + W + 1),
        _ => (i - W + 1, i + W - 1),
      };
      if (m <= magnitude[a] || m < magnitude[b]) continue;
      state[i] = 1;
      if (m > high) {
        state[i] = 2;
        stack.add(i);
      }
    }
  }
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    for (final n in [
      i - W - 1,
      i - W,
      i - W + 1,
      i - 1,
      i + 1,
      i + W - 1,
      i + W,
      i + W + 1,
    ]) {
      if (state[n] == 1) {
        state[n] = 2;
        stack.add(n);
      }
    }
  }
  final edge = Uint8List(W * H);
  for (var i = 0; i < edge.length; i++) {
    edge[i] = state[i] == 2 ? 1 : 0;
  }
  return edge;
}

Uint8List _morph(Uint8List mask, int W, int H, int radius, bool dilate) {
  Uint8List pass(Uint8List input, bool horizontal) {
    final out = Uint8List(input.length);
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        var hit = dilate ? 0 : 1;
        for (var k = -radius; k <= radius; k++) {
          final xx = horizontal ? x + k : x, yy = horizontal ? y : y + k;
          final value = xx < 0 || yy < 0 || xx >= W || yy >= H
              ? (dilate ? 0 : 1)
              : input[yy * W + xx];
          if (dilate ? value != 0 : value == 0) {
            hit = dilate ? 1 : 0;
            break;
          }
        }
        out[y * W + x] = hit;
      }
    }
    return out;
  }

  return pass(pass(mask, true), false);
}

class _Component {
  _Component(this.label, this.x, this.y, this.w, this.h, this.area);
  final int label, x, y, w, h, area;
}

({Int32List labels, List<_Component> components}) _label(
  Uint8List mask,
  int W,
  int H,
  int value,
  bool eight,
) {
  final labels = Int32List(W * H);
  final components = <_Component>[];
  final queue = Int32List(W * H);
  for (var start = 0; start < mask.length; start++) {
    if (mask[start] != value || labels[start] != 0) continue;
    final id = components.length + 1;
    var head = 0, tail = 0, x0 = W, y0 = H, x1 = 0, y1 = 0;
    queue[tail++] = start;
    labels[start] = id;
    while (head < tail) {
      final i = queue[head++], x = i % W, y = i ~/ W;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if ((dx == 0 && dy == 0) || (!eight && dx != 0 && dy != 0)) continue;
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
          final n = ny * W + nx;
          if (mask[n] == value && labels[n] == 0) {
            labels[n] = id;
            queue[tail++] = n;
          }
        }
      }
    }
    components.add(_Component(id, x0, y0, x1 - x0 + 1, y1 - y0 + 1, tail));
  }
  return (labels: labels, components: components);
}

double _enclosedRatio(Int32List labels, int W, _Component c) {
  final w = c.w + 2, h = c.h + 2;
  final seen = Uint8List(w * h);
  bool inside(int x, int y) {
    final ix = c.x + x - 1, iy = c.y + y - 1;
    return ix >= c.x &&
        iy >= c.y &&
        ix < c.x + c.w &&
        iy < c.y + c.h &&
        labels[iy * W + ix] == c.label;
  }

  final queue = <int>[0];
  seen[0] = 1;
  var outside = 0;
  while (queue.isNotEmpty) {
    final i = queue.removeLast(), x = i % w, y = i ~/ w;
    if (x > 0 && y > 0 && x < w - 1 && y < h - 1) outside++;
    for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
      final nx = x + dx, ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      final n = ny * w + nx;
      if (seen[n] != 0 || inside(nx, ny)) continue;
      seen[n] = 1;
      queue.add(n);
    }
  }
  return (c.w * c.h - outside) / (c.w * c.h);
}

double _iou(List<int> a, List<int> b) {
  final x = math.max(a[0], b[0]), y = math.max(a[1], b[1]);
  final r = math.min(a[0] + a[2], b[0] + b[2]),
      d = math.min(a[1] + a[3], b[1] + b[3]);
  final v = math.max(0, r - x) * math.max(0, d - y);
  return v / (a[2] * a[3] + b[2] * b[3] - v + 1e-8);
}

double _median(Iterable<num> values) {
  final sorted = [for (final v in values) v.toDouble()]..sort();
  final mid = sorted.length >> 1;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

({double origin, double pitch}) _fit(List<int> positions, double pitch) {
  final first = positions.reduce(math.min);
  final index = [for (final p in positions) ((p - first) / pitch).round()];
  if (index.toSet().length < 2) return (origin: first.toDouble(), pitch: pitch);
  final n = positions.length;
  final mi = index.reduce((a, b) => a + b) / n;
  final mp = positions.reduce((a, b) => a + b) / n;
  var num = 0.0, den = 0.0;
  for (var k = 0; k < n; k++) {
    num += (index[k] - mi) * (positions[k] - mp);
    den += (index[k] - mi) * (index[k] - mi);
  }
  final slope = num / den;
  return (origin: mp - slope * mi, pitch: slope);
}

typedef CellProposal = ({String kind, List<int> bbox});

/// Card cell proposals from closed edge outlines, regularised into the member grid.
List<CellProposal> grid(Raster image) {
  final W = image.width, H = image.height;
  final edge = canny(image, 50, 120);
  final closed = _morph(_morph(edge, W, H, 1, true), W, H, 1, false);
  final candidates = <CellProposal>[];
  void consider(Int32List labels, _Component c) {
    if (math.min(c.w, c.h) < 32 || c.w > W * 0.4 || c.h > H * 0.7) return;
    final ratio = c.w / c.h;
    final kind = ratio > 0.68 && ratio < 0.85
        ? 'members'
        : ratio > 1.65 && ratio < 1.95
        ? 'snapshots'
        : null;
    if (kind != null && _enclosedRatio(labels, W, c) > 0.82) {
      candidates.add((kind: kind, bbox: [c.x, c.y, c.w, c.h]));
    }
  }

  final outlines = _label(closed, W, H, 1, true);
  for (final c in outlines.components) {
    consider(outlines.labels, c);
  }
  final holes = _label(closed, W, H, 0, false);
  for (final c in holes.components) {
    if (c.x > 0 && c.y > 0 && c.x + c.w < W && c.y + c.h < H) {
      consider(holes.labels, c);
    }
  }
  candidates.sort(
    (a, b) => (b.bbox[2] * b.bbox[3]).compareTo(a.bbox[2] * a.bbox[3]),
  );
  final kept = <CellProposal>[];
  for (final box in candidates) {
    if (!kept.any((other) => _iou(box.bbox, other.bbox) > 0.7)) kept.add(box);
  }
  if (kept.isEmpty) return const [];
  final groups = <List<CellProposal>>[];
  for (final box in kept) {
    final group = groups.where(
      (g) =>
          g.first.kind == box.kind &&
          (g.first.bbox[2] - box.bbox[2]).abs() < box.bbox[2] * 0.15 &&
          (g.first.bbox[3] - box.bbox[3]).abs() < box.bbox[3] * 0.15,
    );
    if (group.isNotEmpty) {
      group.first.add(box);
    } else {
      groups.add([box]);
    }
  }
  final dominant = groups.reduce((a, b) => b.length > a.length ? b : a);
  final kind = dominant.first.kind;
  var boxes = dominant;
  if (kind == 'members' && dominant.length >= 3) {
    final width = _median(dominant.map((b) => b.bbox[2])).truncate();
    final height = _median(dominant.map((b) => b.bbox[3])).truncate();
    final xs = {for (final b in dominant) b.bbox[0]}.toList()..sort();
    final ys = {for (final b in dominant) b.bbox[1]}.toList()..sort();
    final steps = [
      for (var i = 1; i < xs.length; i++)
        if (xs[i] - xs[i - 1] >= width * 0.9 && xs[i] - xs[i - 1] < width * 1.5)
          xs[i] - xs[i - 1],
    ];
    if (steps.isNotEmpty) {
      final fitX = _fit([for (final b in dominant) b.bbox[0]], _median(steps));
      final y0 = _median(ys).truncate();
      final x0 = fitX.origin.round();
      final columns = ((xs.last - fitX.origin) / fitX.pitch).round() + 1;
      final right = math.min(
        W,
        (fitX.origin + (columns - 1) * fitX.pitch).round() + width,
      );
      final profile = Float32List(H);
      for (var y = 0; y < H; y++) {
        var sum = 0;
        for (var x = math.max(0, x0); x < right; x++) {
          sum += edge[y * W + x];
        }
        profile[y] = sum.toDouble();
      }
      double smooth(int y) {
        var sum = 0.0;
        for (var k = -2; k <= 2; k++) {
          if (y + k >= 0 && y + k < H) sum += profile[y + k];
        }
        return sum / 5;
      }

      var pitchY = 0, bestScore = -1.0;
      for (
        var candidate = (height * 1.02).round();
        candidate <= (height * 1.35).round();
        candidate++
      ) {
        var score = 0.0;
        for (var y = y0 % candidate; y <= H - height; y += candidate) {
          score += smooth(math.min(H - 1, y + height - 1));
        }
        if (score > bestScore) {
          bestScore = score;
          pitchY = candidate;
        }
      }
      final fitY = _fit([
        for (final b in dominant) b.bbox[1],
      ], pitchY.toDouble());
      final rows = <int>[];
      for (var row = (-fitY.origin / fitY.pitch).floor(); ; row++) {
        final y = (fitY.origin + row * fitY.pitch).round();
        if (y + height > H) break;
        if (y >= 0) rows.add(y);
      }
      if (rows.length > 1) {
        boxes = [
          for (final y in rows)
            for (var column = 0; column < columns; column++)
              () {
                final bbox = [
                  (fitX.origin + column * fitX.pitch).round(),
                  y,
                  width,
                  height,
                ];
                final seed = dominant.where((b) => _iou(b.bbox, bbox) > 0.6);
                return (
                  kind: kind,
                  bbox: seed.isEmpty ? bbox : seed.first.bbox,
                );
              }(),
        ].where((b) => b.bbox[0] >= 0 && b.bbox[0] + b.bbox[2] <= W).toList();
      }
    }
  }
  int rowKey(CellProposal b) =>
      (b.bbox[1] / math.max(1, b.bbox[3] * 0.4)).round();
  return boxes.toList()..sort((a, b) {
    final row = rowKey(a).compareTo(rowKey(b));
    return row != 0 ? row : a.bbox[0].compareTo(b.bbox[0]);
  });
}

// Level reader: port of scripts/recognize/levels.py.

class _Blob {
  _Blob(this.x, this.y, this.w, this.h, this.mask);
  final int x, y, w, h;
  final Mask mask;
}

Float32List _resizeMask(Mask mask, int width, int height, bool linear) {
  final out = Float32List(width * height);
  final sx = mask.width / width, sy = mask.height / height;
  if (linear) {
    for (var y = 0; y < height; y++) {
      final fy = math.min(
        mask.height - 1.0,
        math.max(0.0, (y + 0.5) * sy - 0.5),
      );
      final y0 = fy.floor(), y1 = math.min(mask.height - 1, y0 + 1);
      final ty = fy - y0;
      for (var x = 0; x < width; x++) {
        final fx = math.min(
          mask.width - 1.0,
          math.max(0.0, (x + 0.5) * sx - 0.5),
        );
        final x0 = fx.floor(), x1 = math.min(mask.width - 1, x0 + 1);
        final tx = fx - x0;
        final top =
            mask.data[y0 * mask.width + x0] * (1 - tx) +
            mask.data[y0 * mask.width + x1] * tx;
        final bottom =
            mask.data[y1 * mask.width + x0] * (1 - tx) +
            mask.data[y1 * mask.width + x1] * tx;
        out[y * width + x] = top * (1 - ty) + bottom * ty;
      }
    }
    return out;
  }
  final columns = _weights(0, mask.width.toDouble(), width, mask.width);
  final rows = _weights(0, mask.height.toDouble(), height, mask.height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      final row = rows[y], column = columns[x];
      for (var r = 0; r < row.index.length; r++) {
        for (var c = 0; c < column.index.length; c++) {
          sum +=
              mask.data[row.index[r] * mask.width + column.index[c]] *
              row.weight[r] *
              column.weight[c];
        }
      }
      out[y * width + x] = sum;
    }
  }
  return out;
}

double _similarity(Mask patch, Mask reference) {
  final w = patch.width * 4, h = patch.height * 4;
  final a = _resizeMask(patch, w, h, true),
      b = _resizeMask(reference, w, h, false);
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < a.length; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= a.length;
  mb /= b.length;
  var ab = 0.0, aa = 0.0, bb = 0.0;
  for (var i = 0; i < a.length; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    ab += x * y;
    aa += x * x;
    bb += y * y;
  }
  return ab / (math.sqrt(aa) * math.sqrt(bb) + 1e-8);
}

List<_Blob> _blobs(Raster roi, int threshold) {
  final W = roi.width, H = roi.height, data = roi.data;
  final white = Uint8List(W * H), shadow = Uint8List(W * H);
  for (var i = 0, p = 0; i < W * H; i++, p += 4) {
    final r = data[p], g = data[p + 1], b = data[p + 2];
    final lo = math.min(r, math.min(g, b)), hi = math.max(r, math.max(g, b));
    white[i] = lo > threshold && hi - lo < 65 ? 1 : 0;
    shadow[i] = b > r + 15 && b > g + 15 && r < 180 && g < 180 ? 1 : 0;
  }
  final near = _morph(shadow, W, H, 3, true);
  for (var i = 0; i < white.length; i++) {
    white[i] = white[i] & near[i];
  }
  final labelled = _label(white, W, H, 1, true);
  return [
    for (final c in labelled.components)
      if (c.area >= 3)
        () {
          final mask = Float32List(c.w * c.h);
          for (var y = 0; y < c.h; y++) {
            for (var x = 0; x < c.w; x++) {
              mask[y * c.w + x] =
                  labelled.labels[(c.y + y) * W + c.x + x] == c.label ? 1 : 0;
            }
          }
          return _Blob(c.x, c.y, c.w, c.h, Mask(c.w, c.h, mask));
        }(),
  ]..sort((a, b) => a.x.compareTo(b.x));
}

Raster _crop(Raster image, int x, int y, int w, int h) {
  final data = Uint8List(w * h * 4);
  for (var row = 0; row < h; row++) {
    final from = ((y + row) * image.width + x) * 4;
    data.setRange(row * w * 4, (row + 1) * w * 4, image.data, from);
  }
  return Raster(w, h, data);
}

class _LevelRead {
  _LevelRead(this.value, {this.candidate, this.score, this.margin});
  final int? value, candidate;
  final double? score, margin;
  double get quality => (score ?? -1) + (margin ?? 0);
}

_LevelRead _readOne(
  Raster image,
  Map<String, Mask> font,
  Set<int> allowed,
  int threshold,
) {
  final W = image.width, H = image.height;
  final y0 = (H * 0.64).round();
  final roi = _crop(image, 0, y0, (W * 0.68).round(), H - y0);
  final cs = _blobs(roi, threshold);
  final anchors = <(double, _Blob, _Blob)>[];
  for (final l in cs) {
    if (l.x > W * 0.18 ||
        l.h < 5 ||
        l.h > H * 0.23 ||
        !(l.w / l.h > 0.2 && l.w / l.h < 1)) {
      continue;
    }
    final sl = _similarity(l.mask, font['L']!);
    if (sl < 0.55) continue;
    for (final v in cs) {
      if (!(v.x >= l.x + l.w &&
          v.x < l.x + l.w + l.h * 0.95 &&
          v.h / l.h > 0.42 &&
          v.h / l.h < 0.86)) {
        continue;
      }
      if ((v.y + v.h - (l.y + l.h)).abs() > 2) continue;
      final sv = _similarity(v.mask, font['v']!);
      if (sv > 0.4) anchors.add((sl + sv, l, v));
    }
  }
  if (anchors.isEmpty) return _LevelRead(null);
  final (_, l, v) = anchors.reduce((a, b) => b.$1 > a.$1 ? b : a);
  final bottom = l.y + l.h;
  final digits =
      <({String character, double score, double margin, int x, int w})>[];
  for (final c in cs) {
    if (c.x < v.x + v.w + 1 ||
        c.h < l.h * 0.8 ||
        c.h > l.h * 1.5 ||
        (c.y + c.h - bottom).abs() > 2 ||
        c.w > c.h * 1.1) {
      continue;
    }
    if (c.y == 0 || c.x + c.w >= roi.width || c.y + c.h >= roi.height) {
      return _LevelRead(null);
    }
    if (digits.isNotEmpty && c.x - digits.last.x - digits.last.w > l.h * 0.75) {
      break;
    }
    if (digits.isEmpty && c.x - (v.x + v.w) > l.h * 1.35) continue;
    final ranked = [
      for (final character in '0123456789'.split(''))
        (character, _similarity(c.mask, font[character]!)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    digits.add((
      character: ranked[0].$1,
      score: ranked[0].$2,
      margin: ranked[0].$2 - ranked[1].$2,
      x: c.x,
      w: c.w,
    ));
    if (digits.length >= 3) break;
  }
  if (digits.isEmpty) return _LevelRead(null);
  final value = int.parse(digits.map((d) => d.character).join());
  final score = digits.map((d) => d.score).reduce(math.min);
  final margin = digits.map((d) => d.margin).reduce(math.min);
  final good = score > 0.63 && margin > 0.07 && allowed.contains(value);
  return _LevelRead(
    good ? value : null,
    candidate: value,
    score: score,
    margin: margin,
  );
}

int? readLevel(Raster image, Map<String, Mask> font, Set<int> allowed) {
  final variants = [
    for (final t in const [190, 200, 210]) _readOne(image, font, allowed, t),
  ];
  final strong = variants.where((r) => r.value != null);
  final weak = variants.where(
    (r) =>
        r.candidate != null &&
        allowed.contains(r.candidate) &&
        (r.score ?? 0) > 0.45 &&
        (r.margin ?? 0) > 0.02,
  );
  final counts = <int, int>{};
  for (final r in weak) {
    counts[r.candidate!] = (counts[r.candidate!] ?? 0) + 1;
  }
  final valid = strong.where((r) => (counts[r.value!] ?? 0) >= 2).toList();
  if (valid.isEmpty || counts.length > 1) return null;
  return valid.reduce((a, b) => b.quality > a.quality ? b : a).value;
}

Raster downscale(Raster image, int width, int height) {
  final rgb = sampleRegion(
    image,
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
    width,
    height,
  );
  final data = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    data[i * 4] = rgb[i * 3].round().clamp(0, 255);
    data[i * 4 + 1] = rgb[i * 3 + 1].round().clamp(0, 255);
    data[i * 4 + 2] = rgb[i * 3 + 2].round().clamp(0, 255);
    data[i * 4 + 3] = 255;
  }
  return Raster(width, height, data);
}

/// Recognise one screenshot; boxes are in the input raster's coordinates.
List<RecognizedCell> recognize(Raster input, LocalReference reference) {
  final scale = math.min(
    1.0,
    _workingSide / math.max(input.width, input.height),
  );
  final working = scale < 1
      ? downscale(
          input,
          (input.width * scale).round(),
          (input.height * scale).round(),
        )
      : input;
  return [
    for (final proposal in grid(working).take(100))
      () {
        final bbox = proposal.bbox;
        final x = bbox[0], y = bbox[1], w = bbox[2], h = bbox[3];
        final identity = matchIdentity(
          working,
          bbox,
          reference.kind(proposal.kind),
        );
        int? level;
        final glyphs = reference.glyphs, allowed = reference.allowed;
        if (glyphs != null && allowed != null) {
          final patch = _crop(
            working,
            x,
            y,
            w,
            math.min(working.height - y, h + (h * 0.08).round()),
          );
          level = readLevel(patch, glyphs, allowed[proposal.kind]!);
        }
        final left = math.max(0, (x / scale).round()),
            top = math.max(0, (y / scale).round());
        return RecognizedCell(
          kind: proposal.kind,
          bbox: [
            left,
            top,
            math.min(input.width - left, (w / scale).round()),
            math.min(input.height - top, (h / scale).round()),
          ],
          cardId: identity.cardId,
          candidates: identity.candidates,
          level: level,
        );
      }(),
  ];
}

/// Cut a reference sheet into normalised identity vectors.
ReferenceKind referenceKind(
  Raster sheet,
  int tileWidth,
  int tileHeight,
  int columns,
  List<int> cardIds,
) => ReferenceKind(tileWidth, tileHeight, cardIds, [
  for (var i = 0; i < cardIds.length; i++)
    tileVector(
      sampleRegion(
        sheet,
        ((i % columns) * tileWidth).toDouble(),
        ((i ~/ columns) * tileHeight).toDouble(),
        tileWidth.toDouble(),
        tileHeight.toDouble(),
        tileWidth,
        tileHeight,
      ),
      tileWidth,
      tileHeight,
    ),
]);

Map<String, Mask> glyphMasks(Map<String, List<String>> glyphs) => {
  for (final MapEntry(:key, :value) in glyphs.entries)
    key: Mask(
      value.first.length,
      value.length,
      Float32List.fromList([
        for (final row in value)
          for (var x = 0; x < row.length; x++) row[x] == '1' ? 1.0 : 0.0,
      ]),
    ),
};
