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
    this.kind,
    this.tileWidth,
    this.tileHeight,
    this.cardIds,
    this.vectors,
  );

  /// `members` or `snapshots`.
  final String kind;
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
    required this.score,
    required this.level,
  });
  final String kind;
  final List<int> bbox;
  final int? cardId;
  final List<int> candidates;

  /// The best candidate's match score.
  final double score;
  final int? level;
}

const _workingSide = 2048;
const _acceptScore = 0.6;
const _acceptMargin = 0.06;

/// Art inside a cell that no badge, mark or Lv label covers:
/// top, bottom, left, right.
const _masks = {
  'members': (0.18, 0.8, 0.1, 0.72),
  'snapshots': (0.22, 0.74, 0.1, 0.84),
};

/// Cell width ÷ height, frame included, as the card lists draw them.
const _aspects = {'members': (0.74, 0.86), 'snapshots': (1.68, 1.96)};

/// Cells narrower than this have their Lv digits read enlarged.
const _levelCellWidth = {'members': 200, 'snapshots': 280};

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
Float32List tileVector(Float32List rgb, int width, int height, String kind) {
  final (maskTop, maskBottom, maskLeft, maskRight) = _masks[kind]!;
  final top = (height * maskTop).round(),
      bottom = (height * maskBottom).round();
  final left = (width * maskLeft).round(), right = (width * maskRight).round();
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

({int? cardId, List<int> candidates, double score}) matchIdentity(
  Raster image,
  List<int> bbox,
  ReferenceKind reference,
) {
  final tw = reference.tileWidth, th = reference.tileHeight;
  final x = bbox[0].toDouble(), y = bbox[1].toDouble();
  final w = bbox[2].toDouble(), h = bbox[3].toDouble();
  final base = tileVector(
    sampleRegion(image, x, y, w, h, tw, th),
    tw,
    th,
    reference.kind,
  );
  final coarse = [
    for (var i = 0; i < reference.vectors.length; i++)
      (index: i, score: _dot(base, reference.vectors[i])),
  ]..sort((a, b) => b.score.compareTo(a.score));
  final shifted = <Float32List>[];
  for (final scale in const [0.94, 0.97, 1.0, 1.03, 1.06]) {
    for (final dy in const [-0.04, -0.02, 0.0, 0.02, 0.04]) {
      for (final dx in const [-0.04, -0.02, 0.0, 0.02, 0.04]) {
        final sw = w * scale, sh = h * scale;
        final sx = x + (w - sw) / 2 + dx * w, sy = y + (h - sh) / 2 + dy * h;
        if (sx < 0 ||
            sy < 0 ||
            sx + sw > image.width ||
            sy + sh > image.height) {
          continue;
        }
        shifted.add(
          tileVector(
            sampleRegion(image, sx, sy, sw, sh, tw, th),
            tw,
            th,
            reference.kind,
          ),
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
  if (refined.isEmpty) return (cardId: null, candidates: const [], score: 0.0);
  final best = refined.first;
  final accepted =
      best.score >= _acceptScore &&
      (refined.length < 2 || best.score - refined[1].score >= _acceptMargin);
  return (
    cardId: accepted ? reference.cardIds[best.index] : null,
    candidates: [for (final r in refined.take(5)) reference.cardIds[r.index]],
    score: best.score,
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

Float32List _gray(Raster image) {
  final g = Float32List(image.width * image.height);
  for (var i = 0, p = 0; i < g.length; i++, p += 4) {
    g[i] =
        0.299 * image.data[p] +
        0.587 * image.data[p + 1] +
        0.114 * image.data[p + 2];
  }
  return g;
}

/// Card cell proposals. Columns come from width-consistent closed outlines;
/// rows are the textured runs inside those columns, since outlines merge rows
/// wherever a badge crosses a border. The cell shape gives the card kind.
List<CellProposal> grid(Raster image) {
  final W = image.width, H = image.height;
  final g = _gray(image);
  final edge = canny(image, 50, 120);
  final closed = _morph(_morph(edge, W, H, 1, true), W, H, 1, false);
  final seeds = <List<int>>[];
  void consider(Int32List labels, _Component c) {
    if (math.min(c.w, c.h) < 32 || c.w > W * 0.4 || c.h > H * 0.9) return;
    final ratio = c.w / c.h;
    if (ratio > 0.6 && ratio < 2.2 && _enclosedRatio(labels, W, c) > 0.82) {
      seeds.add([c.x, c.y, c.w, c.h]);
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

  // Widest group of seeds sharing a width and a horizontal lattice.
  ({int width, List<int> xs, List<List<int>> boxes})? best;
  for (final seed in seeds) {
    final group = [
      for (final b in seeds)
        if ((b[2] - seed[2]).abs() <= seed[2] * 0.05) b,
    ];
    final xs = {for (final b in group) b[0]}.toList()..sort();
    final lattice = [
      for (final x in xs)
        if (xs.any((o) {
          final d = (o - x).abs();
          return o != x &&
              d >= seed[2] * 0.95 &&
              d < seed[2] * 1.5 * math.max(1, (d / (seed[2] * 1.1)).round());
        }))
          x,
    ];
    if (lattice.length < 2) continue;
    final width = _median(group.map((b) => b[2])).round();
    if (best == null ||
        lattice.length > best.xs.length ||
        (lattice.length == best.xs.length && width > best.width)) {
      best = (width: width, xs: lattice, boxes: group);
    }
  }
  if (best == null) return const [];
  final width = best.width;
  final steps = [
    for (var i = 1; i < best.xs.length; i++) best.xs[i] - best.xs[i - 1],
  ];
  final unit = steps.where((d) => d >= width * 0.95).reduce(math.min);
  final fitX = _fit(
    best.xs,
    _median(steps.map((d) => d / math.max(1, (d / unit).round()))),
  );
  final yTop = math.max(0, best.boxes.map((b) => b[1]).reduce(math.min));
  final yBottom = math.min(
    H,
    best.boxes.map((b) => b[1] + b[3]).reduce(math.max),
  );
  double vertical(int x) {
    if (x < 1 || x >= W - 1) return 0;
    var hit = 0;
    for (var y = yTop; y < yBottom; y++) {
      if ((g[y * W + x + 1] - g[y * W + x - 1]).abs() > 40) hit++;
    }
    return hit / math.max(1, yBottom - yTop);
  }

  double border(int x) =>
      math.max(vertical(x - 1), math.max(vertical(x), vertical(x + 1)));
  double columnStrength(int x) => (border(x) + border(x + width - 1)) / 2;
  int at(int k) => (fitX.origin + k * fitX.pitch).round();
  final floor =
      _median([
        for (final x in best.xs)
          columnStrength(at(((x - fitX.origin) / fitX.pitch).round())),
      ]) *
      0.5;
  var first = ((best.xs.first - fitX.origin) / fitX.pitch).round();
  var last = ((best.xs.last - fitX.origin) / fitX.pitch).round();
  while (at(first - 1) >= 0 && columnStrength(at(first - 1)) >= floor) {
    first--;
  }
  while (at(last + 1) + width <= W && columnStrength(at(last + 1)) >= floor) {
    last++;
  }
  final columns = [for (var k = first; k <= last; k++) at(k)];

  // Share of each scanline, per column and overall, that crosses a horizontal edge.
  final profile = Float32List(H);
  final perColumn = [for (final _ in columns) Float32List(H)];
  for (var y = 1; y < H - 1; y++) {
    var total = 0;
    for (var c = 0; c < columns.length; c++) {
      var hit = 0;
      for (var x = columns[c]; x < columns[c] + width; x++) {
        if ((g[(y + 1) * W + x] - g[(y - 1) * W + x]).abs() > 40) hit++;
      }
      perColumn[c][y] = hit / width;
      total += hit;
    }
    profile[y] = total / (columns.length * width);
  }
  double at0(Float32List list, int y) => y >= 0 && y < H ? list[y] : 0;
  double line(int y) => math.max(
    at0(profile, y - 1),
    math.max(at0(profile, y), at0(profile, y + 1)),
  );
  // Card art is textured; the blurred background between rows is not. A smooth
  // patch of art blanks one card, a gap between rows blanks every column.
  double texture(int y) {
    var textured = 0;
    for (final column in perColumn) {
      var sum = 0.0;
      for (var d = -3; d <= 3; d++) {
        sum += at0(column, y + d);
      }
      if (sum / 7 > 0.01) textured++;
    }
    return textured / columns.length;
  }

  final runs = <(int, int)>[];
  for (var y = 0, start = -1; y <= H; y++) {
    final inside = y < H && texture(y) >= 0.3;
    if (inside && start < 0) start = y;
    if (!inside && start >= 0) {
      runs.add((start, y - 1));
      start = -1;
    }
  }
  // A smooth patch of art also dips; a gap between rows is bounded by borders.
  double near(int y) => math.max(line(y - 2), math.max(line(y), line(y + 2)));
  // A card split by a smooth patch rejoins to about one card; two rows never fit.
  final cap = width / _aspects['members']!.$1 * 1.05;
  final tallest = math.min(
    cap,
    runs
            .map((r) => (r.$2 - r.$1).toDouble())
            .where((n) => n <= cap)
            .fold(0.0, math.max) *
        1.15,
  );
  for (var i = runs.length - 1; i > 0; i--) {
    if (near(runs[i - 1].$2) < 0.2 &&
        near(runs[i].$1) < 0.2 &&
        runs[i].$2 - runs[i - 1].$1 <= tallest) {
      runs.replaceRange(i - 1, i + 1, [(runs[i - 1].$1, runs[i].$2)]);
    }
  }
  // Nothing hangs below a card, so a run ends at the card's bottom; badges can
  // rise above the top, so the top is the strongest border near the run start.
  final cards = [
    for (final (start, end) in runs)
      if (end < H - 2 && end - start >= width * 0.4)
        () {
          var top = start;
          for (var y = start; y <= start + (end - start) * 0.2; y++) {
            if (line(y) > line(top)) top = y;
          }
          return (top: top, bottom: end + 1);
        }(),
  ];
  if (cards.isEmpty) return const [];
  final height = _median(cards.map((c) => c.bottom - c.top)).round();
  final ratio = width / height;
  final kind = const ['members', 'snapshots'].where((k) {
    final (low, high) = _aspects[k]!;
    return ratio >= low * 0.95 && ratio <= high * 1.05;
  }).firstOrNull;
  if (kind == null) return const [];
  // A run shorter than a card is a row cut by the list's edge or header.
  return [
    for (final c in cards)
      if (c.bottom - c.top >= height * 0.92 && c.bottom - height >= 0)
        if (() {
          // A whole card has its top frame one card height above its bottom.
          var frame = 0.0;
          for (var d = -4; d <= 4; d++) {
            frame = math.max(frame, line(c.bottom - height + d));
          }
          return frame >= line(c.top) * 0.6;
        }())
          for (var column = 0; column < columns.length; column++)
            if (() {
              // An empty slot at the end of the list shows only the blurred background.
              var sum = 0.0;
              for (var y = c.bottom - height; y < c.bottom; y++) {
                sum += perColumn[column][y];
              }
              return sum / height > 0.01;
            }())
              (
                kind: kind,
                bbox: [columns[column], c.bottom - height, width, height],
              ),
  ];
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
      <
        ({String character, double score, double margin, int x, int y, int w})
      >[];
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
    // Digits of one number share their top as well as their baseline.
    if (digits.isNotEmpty && (c.y - digits.last.y).abs() > 2) break;
    if (digits.isEmpty && c.x - (v.x + v.w) > l.h * 1.35) continue;
    final ranked = [
      for (final character in '0123456789'.split(''))
        (character, _similarity(c.mask, font[character]!)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    // Art next to the label can pass the shape tests; it never resembles a digit.
    if (digits.isNotEmpty && ranked[0].$2 < 0.45) break;
    digits.add((
      character: ranked[0].$1,
      score: ranked[0].$2,
      margin: ranked[0].$2 - ranked[1].$2,
      x: c.x,
      y: c.y,
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
  // Every read of an allowed level with digit-like evidence votes; one of
  // them must also be strong, and no other level may draw as many votes.
  final votes = <int, List<_LevelRead>>{};
  for (final t in const [180, 190, 200, 210, 220]) {
    final r = _readOne(image, font, allowed, t);
    if (r.candidate != null &&
        allowed.contains(r.candidate) &&
        (r.score ?? 0) > 0.45 &&
        (r.margin ?? 0) > 0.02) {
      (votes[r.candidate!] ??= []).add(r);
    }
  }
  final ranked = votes.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  if (ranked.isEmpty) return null;
  final winner = ranked.first;
  if (winner.value.length < 2 ||
      (ranked.length > 1 && ranked[1].value.length >= winner.value.length) ||
      !winner.value.any((r) => r.value != null)) {
    return null;
  }
  return winner.key;
}

/// Bilinear enlargement.
Raster _enlarge(Raster image, int width, int height) {
  final sx = width / image.width, sy = height / image.height;
  final data = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    final fy = math.min(
      image.height - 1.0,
      math.max(0.0, (y + 0.5) / sy - 0.5),
    );
    final y0 = fy.floor(), y1 = math.min(image.height - 1, y0 + 1);
    final ty = fy - y0;
    for (var x = 0; x < width; x++) {
      final fx = math.min(
        image.width - 1.0,
        math.max(0.0, (x + 0.5) / sx - 0.5),
      );
      final x0 = fx.floor(), x1 = math.min(image.width - 1, x0 + 1);
      final tx = fx - x0;
      for (var c = 0; c < 4; c++) {
        int at(int xx, int yy) => image.data[(yy * image.width + xx) * 4 + c];
        final top = at(x0, y0) * (1 - tx) + at(x1, y0) * tx;
        final bottom = at(x0, y1) * (1 - tx) + at(x1, y1) * tx;
        data[(y * width + x) * 4 + c] = (top * (1 - ty) + bottom * ty).round();
      }
    }
  }
  return Raster(width, height, data);
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
  // Thresholds are set for a list about this wide, so small screenshots are
  // enlarged too.
  final scale = _workingSide / math.max(input.width, input.height);
  final workingWidth = (input.width * scale).round();
  final workingHeight = (input.height * scale).round();
  final working = scale < 1
      ? downscale(input, workingWidth, workingHeight)
      : scale > 1
      ? _enlarge(input, workingWidth, workingHeight)
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
          var patch = _crop(
            working,
            x,
            y,
            w,
            math.min(working.height - y, h + (h * 0.08).round()),
          );
          // Small cells leave the Lv digits only a few pixels tall; read them
          // enlarged.
          final factor = (_levelCellWidth[proposal.kind]! / w).ceil();
          if (factor > 1) {
            patch = _enlarge(
              patch,
              patch.width * factor,
              patch.height * factor,
            );
          }
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
          score: identity.score,
          level: level,
        );
      }(),
  ];
}

/// Cut a reference sheet into normalised identity vectors.
ReferenceKind referenceKind(
  String kind,
  Raster sheet,
  int tileWidth,
  int tileHeight,
  int columns,
  List<int> cardIds,
) => ReferenceKind(kind, tileWidth, tileHeight, cardIds, [
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
      kind,
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
