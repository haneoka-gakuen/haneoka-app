import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'puzzle_model.dart';

typedef PuzzleCrop = ({double x, double y, double side});

class PuzzleRecognition {
  PuzzleRecognition(
    this.crop,
    this.tiles,
    this.goalBlank,
    this.uncertain,
    this.error,
  );
  final PuzzleCrop crop;
  final List<int> tiles;
  final int goalBlank;
  final List<int> uncertain;
  final double error;
}

class _Feature {
  _Feature(this.color, this.luma, this.edge);
  final List<double> color, luma, edge;
}

class _Match {
  _Match(this.crop, this.gap, this.assignment, this.costs, this.error);
  final PuzzleCrop crop;
  final double gap, error;
  final List<int> assignment;
  final List<List<double>> costs;
}

List<int> _assign(List<List<double>> cost) {
  final n = cost.length,
      u = List.filled(cost.length + 1, 0.0),
      v = List.filled(cost.length + 1, 0.0),
      p = List.filled(cost.length + 1, 0),
      way = List.filled(cost.length + 1, 0);
  for (var row = 1; row <= n; row++) {
    p[0] = row;
    final distance = List.filled(n + 1, double.infinity),
        used = List.filled(n + 1, false);
    var column = 0;
    do {
      used[column] = true;
      final current = p[column];
      var delta = double.infinity, next = 0;
      for (var j = 1; j <= n; j++) {
        if (used[j]) continue;
        final value = cost[current - 1][j - 1] - u[current] - v[j];
        if (value < distance[j]) {
          distance[j] = value;
          way[j] = column;
        }
        if (distance[j] < delta) {
          delta = distance[j];
          next = j;
        }
      }
      for (var j = 0; j <= n; j++) {
        if (used[j]) {
          u[p[j]] += delta;
          v[j] -= delta;
        } else {
          distance[j] -= delta;
        }
      }
      column = next;
    } while (p[column] != 0);
    do {
      final previous = way[column];
      p[column] = p[previous];
      column = previous;
    } while (column != 0);
  }
  final result = List.filled(n, 0);
  for (var j = 1; j <= n; j++) {
    result[p[j] - 1] = j - 1;
  }
  return result;
}

double _sample(img.Image image, double x, double y, int channel) {
  x = x.clamp(0, image.width - 1.001);
  y = y.clamp(0, image.height - 1.001);
  final left = x.floor(), top = y.floor(), dx = x - left, dy = y - top;
  return ((image.getPixel(left, top)[channel] * (1 - dx) +
                  image.getPixel(left + 1, top)[channel] * dx) *
              (1 - dy) +
          (image.getPixel(left, top + 1)[channel] * (1 - dx) +
                  image.getPixel(left + 1, top + 1)[channel] * dx) *
              dy) /
      255;
}

_Feature _feature(img.Image image, double x, double y, double side, int r) {
  final color = List.filled(r * r * 3, 0.0),
      luma = List.filled(r * r, 0.0),
      edge = List.filled(r * r * 2, 0.0);
  for (var row = 0; row < r; row++) {
    for (var col = 0; col < r; col++) {
      final px = x + side * (.05 + .9 * (col + .5) / r),
          py = y + side * (.05 + .9 * (row + .5) / r),
          i = row * r + col;
      for (var c = 0; c < 3; c++) {
        color[i * 3 + c] = _sample(image, px, py, c);
      }
      luma[i] =
          color[i * 3] * .299 +
          color[i * 3 + 1] * .587 +
          color[i * 3 + 2] * .114;
    }
  }
  for (var row = 1; row < r - 1; row++) {
    for (var col = 1; col < r - 1; col++) {
      final i = row * r + col;
      edge[i * 2] = luma[i + 1] - luma[i - 1];
      edge[i * 2 + 1] = luma[i + r] - luma[i - r];
    }
  }
  return _Feature(color, luma, edge);
}

double _difference(_Feature a, _Feature b, int r, bool small) {
  var color = 0.0, gradient = 0.0, structural = 0.0, count = 0, blocks = 0;
  final block = r ~/ 2;
  for (var by = 0; by < 2; by++) {
    for (var bx = 0; bx < 2; bx++) {
      var sa = 0.0, sb = 0.0, aa = 0.0, bb = 0.0, ab = 0.0, points = 0;
      for (var y = by * block; y < (by + 1) * block; y++) {
        for (var x = bx * block; x < (bx + 1) * block; x++) {
          if (x < r * (small ? 2 / 3 : 1 / 3) &&
              y < r * (small ? 1 / 2 : 1 / 3)) {
            continue;
          }
          final i = y * r + x, av = a.luma[i], bv = b.luma[i];
          sa += av;
          sb += bv;
          aa += av * av;
          bb += bv * bv;
          ab += av * bv;
          points++;
          for (var c = 0; c < 3; c++) {
            color += math.min(
              .3,
              (a.color[i * 3 + c] - b.color[i * 3 + c]).abs(),
            );
          }
          gradient += math.min(
            .5,
            (a.edge[i * 2] - b.edge[i * 2]).abs() +
                (a.edge[i * 2 + 1] - b.edge[i * 2 + 1]).abs(),
          );
          count++;
        }
      }
      if (points == 0) continue;
      blocks++;
      final ma = sa / points,
          mb = sb / points,
          variance =
              math.max(0, aa / points - ma * ma) +
              math.max(0, bb / points - mb * mb),
          covariance = ab / points - ma * mb;
      final similarity =
          ((2 * ma * mb + .0001) * (2 * covariance + .0009)) /
          ((ma * ma + mb * mb + .0001) * (variance + .0009));
      structural += (1 - similarity.clamp(-1, 1)) / 2;
    }
  }
  return .55 * structural / blocks +
      .3 * color / (count * .9) +
      .15 * gradient / (count * .5);
}

List<_Feature> _fragments(
  img.Image image,
  int size,
  PuzzleCrop crop,
  double gap,
  int resolution,
) {
  final pitch = crop.side / (size - gap), side = pitch * (1 - gap);
  return [
    for (var i = 0; i < size * size; i++)
      _feature(
        image,
        crop.x + i % size * pitch,
        crop.y + i ~/ size * pitch,
        side,
        resolution,
      ),
  ];
}

double _empty(_Feature feature, int r, bool small) {
  final indices = [
    for (var i = 0; i < r * r; i++)
      if (!small ||
          (!(i % r < r * 2 / 3 && i ~/ r < r / 2) &&
              (i % r < r / 4 ||
                  i % r >= r * 3 / 4 ||
                  i ~/ r < r / 4 ||
                  i ~/ r >= r * 3 / 4)))
        i,
  ];
  final channels = [
    for (var c = 0; c < 3; c++)
      [for (final i in indices) feature.color[i * 3 + c]]..sort(),
  ];
  final median = [for (final values in channels) values[values.length ~/ 2]];
  final distances = [
    for (final i in indices)
      (feature.color[i * 3] - median[0]).abs() / 3 +
          (feature.color[i * 3 + 1] - median[1]).abs() / 3 +
          (feature.color[i * 3 + 2] - median[2]).abs() / 3,
  ]..sort();
  final count = (distances.length * .85).floor();
  return math.min(
    .65,
    math.sqrt(distances.take(count).fold(0.0, (a, b) => a + b) / count) * 3,
  );
}

_Match _match(
  img.Image image,
  List<_Feature> reference,
  int size,
  PuzzleCrop crop,
  double gap,
  int r,
  int? missing,
) {
  final cells = size * size, small = crop.side / size < 80;
  final costs = [
    for (final a in _fragments(image, size, crop, gap, r))
      [
        for (final b in reference) _difference(a, b, r, small),
        _empty(a, r, small),
      ],
  ];
  costs.add([
    for (var i = 0; i < cells; i++) missing == null || i == missing ? 0 : 10000,
    10000,
  ]);
  final assignment = _assign(costs);
  var error = 0.0;
  for (var i = 0; i < assignment.length; i++) {
    error += costs[i][assignment[i]];
  }
  return _Match(crop, gap, assignment, costs, error / (cells - 1));
}

PuzzleCrop _bounded(PuzzleCrop crop, img.Image image) {
  final side = crop.side.clamp(
    24.0,
    math.min(image.width, image.height).toDouble(),
  );
  return (
    x: crop.x.clamp(0, image.width - side),
    y: crop.y.clamp(0, image.height - side),
    side: side,
  );
}

List<PuzzleCrop> _locate(img.Image image, int size) {
  final scale = math.min(1.0, 360 / math.max(image.width, image.height)),
      width = math.max(2, (image.width * scale).round()),
      height = math.max(2, (image.height * scale).round()),
      stride = width + 1;
  final vertical = Float64List((height + 1) * stride),
      horizontal = Float64List((height + 1) * stride);
  double luma(int x, int y) =>
      _sample(image, x / scale, y / scale, 0) * .299 +
      _sample(image, x / scale, y / scale, 1) * .587 +
      _sample(image, x / scale, y / scale, 2) * .114;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final value = luma(x, y), i = (y + 1) * stride + x + 1;
      vertical[i] =
          (value - luma(x + 1, y)).abs() +
          vertical[i - 1] +
          vertical[i - stride] -
          vertical[i - stride - 1];
      horizontal[i] =
          (value - luma(x, y + 1)).abs() +
          horizontal[i - 1] +
          horizontal[i - stride] -
          horizontal[i - stride - 1];
    }
  }
  double sum(Float64List integral, double x, double y, double w, double h) {
    final x1 = x.round().clamp(0, width),
        y1 = y.round().clamp(0, height),
        x2 = (x + w).round().clamp(x1, width),
        y2 = (y + h).round().clamp(y1, height);
    return integral[y2 * stride + x2] -
        integral[y1 * stride + x2] -
        integral[y2 * stride + x1] +
        integral[y1 * stride + x1];
  }

  final candidates = <({PuzzleCrop crop, double score})>[],
      limit = math.min(width, height).toDouble();
  for (
    var side = math.max(size * 7.0, limit * .32);
    side <= limit;
    side += math.max(3, side * .045)
  ) {
    final step = math.max(3, side / (size * 3));
    for (var y = 0.0; y + side <= height; y += step) {
      for (var x = 0.0; x + side <= width; x += step) {
        var seams = 0.0;
        for (var line = 1; line < size; line++) {
          seams += sum(vertical, x + line * side / size - 1, y, 2, side);
          seams += sum(horizontal, x, y + line * side / size - 1, side, 2);
        }
        final texture =
                (sum(vertical, x, y, side, side) +
                    sum(horizontal, x, y, side, side)) /
                (side * side),
            score = seams / (4 * side * (size - 1)) - texture * .7;
        if (candidates.length < 100 || score > candidates.last.score) {
          candidates.add((crop: (x: x, y: y, side: side), score: score));
          candidates.sort((a, b) => b.score.compareTo(a.score));
          if (candidates.length > 100) candidates.removeLast();
        }
      }
    }
  }
  final regions = <PuzzleCrop>[];
  for (final candidate in candidates) {
    final c = candidate.crop;
    if (regions.any(
      (r) =>
          (r.x - c.x).abs() + (r.y - c.y).abs() + (r.side - c.side).abs() <
          c.side * .12,
    )) {
      continue;
    }
    regions.add(c);
    if (regions.length >= 14) break;
  }
  for (final ratio in [1.0, .9, .8, .75, .7, .6, .5]) {
    final side = limit * ratio;
    regions.add((x: (width - side) / 2, y: (height - side) / 2, side: side));
    final step = math.max(3.0, side / (size * 2));
    for (var y = 0.0; y + side <= height; y += step) {
      regions.add((x: (width - side) / 2, y: y, side: side));
    }
  }
  return [
    for (final c in regions)
      _bounded((x: c.x / scale, y: c.y / scale, side: c.side / scale), image),
  ];
}

PuzzleRecognition recognizePuzzle(
  Uint8List screenshot,
  Uint8List jacket,
  int size, {
  PuzzleCrop? crop,
  int? missing,
}) {
  final decoder = img.findDecoderForData(screenshot),
      info = decoder?.startDecode(screenshot);
  if (screenshot.length > 32 * 1024 * 1024 ||
      info == null ||
      info.width * info.height > 32000000) {
    throw const FormatException('imageTooLarge');
  }
  final image = decoder!.decodeFrame(0), cover = img.decodeImage(jacket);
  if (image == null || cover == null || image.width < 24 || image.height < 24) {
    throw const FormatException('imageError');
  }
  final coverCrop = (
    x: 0.0,
    y: 0.0,
    side: math.min(cover.width, cover.height).toDouble(),
  );
  final coarse = _fragments(cover, size, coverCrop, 0, 6),
      fine = _fragments(cover, size, coverCrop, 0, 12);
  final candidates = [
    for (final region
        in crop == null ? _locate(image, size) : [_bounded(crop, image)])
      _match(image, coarse, size, region, .025, 6, missing),
  ]..sort((a, b) => a.error.compareTo(b.error));
  _Match? best;
  for (final candidate in candidates.take(crop == null ? 3 : 1)) {
    var current = _match(
      image,
      fine,
      size,
      candidate.crop,
      candidate.gap,
      12,
      missing,
    );
    for (var step = candidate.crop.side / size * .12; step >= .5; step /= 2) {
      for (var pass = 0; pass < 2; pass++) {
        for (final axis in [0, 1, 2]) {
          for (final direction in [-1, 1]) {
            final c = current.crop,
                region = _bounded((
                  x: c.x + (axis == 0 ? step * direction : 0),
                  y: c.y + (axis == 1 ? step * direction : 0),
                  side: c.side + (axis == 2 ? step * direction : 0),
                ), image),
                next = _match(
                  image,
                  fine,
                  size,
                  region,
                  current.gap,
                  12,
                  missing,
                );
            if (next.error < current.error) current = next;
          }
        }
      }
      for (final gap in [0.0, .02, .04, .06, .085]) {
        final next = _match(image, fine, size, current.crop, gap, 12, missing);
        if (next.error < current.error) current = next;
      }
    }
    if (best == null || current.error < best.error) best = current;
  }
  if (best == null || best.error > .36) {
    throw const FormatException('imageNoMatch');
  }
  best = _match(
    image,
    _fragments(cover, size, coverCrop, 0, 24),
    size,
    best.crop,
    best.gap,
    24,
    missing,
  );
  final total = best.error * (size * size - 1), uncertain = <int>[];
  for (var row = 0; row < size * size; row++) {
    final col = best.assignment[row], value = best.costs[row][col];
    best.costs[row][col] = 10000;
    final alternative = _assign(best.costs);
    var next = 0.0;
    for (var i = 0; i < alternative.length; i++) {
      next += best.costs[i][alternative[i]];
    }
    best.costs[row][col] = value;
    if (value > .22 || next - total < .035) uncertain.add(row);
  }
  final blank = best.assignment[size * size], goal = goalBoard(size, blank);
  return PuzzleRecognition(
    best.crop,
    [
      for (final source in best.assignment.take(size * size))
        source == size * size ? 0 : goal[source],
    ],
    blank,
    uncertain,
    best.error,
  );
}
