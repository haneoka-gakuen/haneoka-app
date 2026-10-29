import 'dart:math';

import 'puzzle_constructive.dart';

/// A port of the website's `lib/song-puzzle/model.ts` and `solver.ts`: a
/// sliding puzzle whose blank is tile 0, and an IDA* solver with Manhattan
/// distance and linear conflicts.

List<int> goalBoard(int size, [int? blank]) {
  final position = blank ?? size * size - 1;
  var tile = 1;
  return [for (var i = 0; i < size * size; i++) i == position ? 0 : tile++];
}

bool solved(List<int> tiles, List<int> goal) {
  if (tiles.length != goal.length) return false;
  for (var i = 0; i < tiles.length; i++) {
    if (tiles[i] != goal[i]) return false;
  }
  return true;
}

bool validPosition(int size, List<int> tiles, List<int> goal) {
  bool valid(List<int> board) =>
      board.length == size * size &&
      board.toSet().length == board.length &&
      board.every((t) => t >= 0 && t < size * size);
  return size >= 3 && size <= 8 && valid(tiles) && valid(goal);
}

bool solvable(int size, List<int> tiles, List<int> goal) {
  if (!validPosition(size, tiles, goal)) return false;
  final ranks = <int, int>{};
  var rank = 0;
  for (final tile in goal) {
    if (tile != 0) ranks[tile] = rank++;
  }
  final sequence = [
    for (final tile in tiles)
      if (tile != 0) ranks[tile]!,
  ];
  var inversions = 0;
  for (var i = 0; i < sequence.length; i++) {
    for (var j = i + 1; j < sequence.length; j++) {
      if (sequence[i] > sequence[j]) inversions++;
    }
  }
  if (size.isOdd) return inversions.isEven;
  final row = size - tiles.indexOf(0) ~/ size;
  final goalRow = size - goal.indexOf(0) ~/ size;
  return (inversions + row) % 2 == goalRow % 2;
}

List<int> neighbors(int blank, int size) => [
  if (blank >= size) blank - size,
  if (blank < size * (size - 1)) blank + size,
  if (blank % size > 0) blank - 1,
  if (blank % size < size - 1) blank + 1,
];

/// The board after [tile] slides into the blank, or null.
List<int>? slide(int size, List<int> tiles, int tile) {
  final index = tiles.indexOf(tile);
  final blank = tiles.indexOf(0);
  if (!neighbors(blank, size).contains(index)) return null;
  final next = [...tiles];
  next[index] = 0;
  next[blank] = tile;
  return next;
}

/// The way [tile] moves: `up`, `down`, `left` or `right`.
String tileDirection(List<int> tiles, int tile, int size) {
  final delta = tiles.indexOf(0) - tiles.indexOf(tile);
  return delta == -size
      ? 'up'
      : delta == size
      ? 'down'
      : delta == -1
      ? 'left'
      : 'right';
}

/// [count] random slides from [goal], never undoing the last.
List<int> shuffleBoard(int size, List<int> goal, int count, [Random? random]) {
  final rng = random ?? Random();
  final next = [...goal];
  var blank = next.indexOf(0), previous = -1;
  for (var i = 0; i < count; i++) {
    final choices = neighbors(blank, size).where((i) => i != previous).toList();
    final index = choices[rng.nextInt(choices.length)];
    next[blank] = next[index];
    next[index] = 0;
    previous = blank;
    blank = index;
  }
  return next;
}

class SolveResult {
  const SolveResult(
    this.status,
    this.path,
    this.nodes,
    this.bound,
    this.elapsedMs,
  );

  /// `optimal`, `budget`, `unsolvable` or `invalid`.
  final String status;
  final List<int> path;
  final int nodes;
  final int bound;
  final int elapsedMs;
}

/// Unit-cost IDA*: Manhattan plus minimum-removal linear conflict, with
/// path-cycle pruning (`solvePuzzle`). Runs to the budget; call it in an
/// isolate.
SolveResult solvePuzzle(
  int size,
  List<int> tiles,
  List<int> goal,
  int budgetMs,
) {
  final clock = Stopwatch()..start();
  var nodes = 0, bound = 0;
  SolveResult result(String status, [List<int> path = const []]) =>
      SolveResult(status, path, nodes, bound, clock.elapsedMilliseconds);
  if (!validPosition(size, tiles, goal)) return result('invalid');
  if (!solvable(size, tiles, goal)) return result('unsolvable');
  if (size >= 5) {
    return constructPuzzle(size, tiles, goal, budgetMs.clamp(100, 120000));
  }
  final board = [...tiles];
  final cells = board.length;
  final cellRows = [for (var i = 0; i < cells; i++) i ~/ size];
  final cellColumns = [for (var i = 0; i < cells; i++) i % size];
  final goalRows = List.filled(cells, 0);
  final goalColumns = List.filled(cells, 0);
  final distances = List.filled(cells * cells, 0);
  final adjacent = [for (var i = 0; i < cells; i++) neighbors(i, size)];
  for (var index = 0; index < cells; index++) {
    final tile = goal[index];
    goalRows[tile] = cellRows[index];
    goalColumns[tile] = cellColumns[index];
    if (tile == 0) continue;
    for (var cell = 0; cell < cells; cell++) {
      distances[tile * cells + cell] =
          (cellRows[cell] - goalRows[tile]).abs() +
          (cellColumns[cell] - goalColumns[tile]).abs();
    }
  }
  int distance(int tile, int index) => distances[tile * cells + index];
  final tails = List.filled(size, 0);
  int lineConflict(int line, bool row) {
    var count = 0, length = 0;
    for (var offset = 0; offset < size; offset++) {
      final tile = board[row ? line * size + offset : offset * size + line];
      if (tile == 0 || (row ? goalRows[tile] : goalColumns[tile]) != line) {
        continue;
      }
      final rank = row ? goalColumns[tile] : goalRows[tile];
      count++;
      var low = 0, high = length;
      while (low < high) {
        final middle = (low + high) >> 1;
        if (tails[middle] < rank) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      tails[low] = rank;
      if (low == length) length++;
    }
    return 2 * (count - length);
  }

  int affectedConflict(int first, int second) {
    final r1 = cellRows[first], r2 = cellRows[second];
    final c1 = cellColumns[first], c2 = cellColumns[second];
    return lineConflict(r1, true) +
        (r2 == r1 ? 0 : lineConflict(r2, true)) +
        lineConflict(c1, false) +
        (c2 == c1 ? 0 : lineConflict(c2, false));
  }

  var heuristic = 0;
  for (var i = 0; i < cells; i++) {
    heuristic += distance(board[i], i);
  }
  for (var line = 0; line < size; line++) {
    heuristic += lineConflict(line, true) + lineConflict(line, false);
  }
  // Positions are keyed by 64-bit Zobrist codes of tile and cell.
  final random = Random(cells);
  int code() => (random.nextInt(1 << 32) << 32) ^ random.nextInt(1 << 32);
  final zobrist = List.generate(cells * cells, (_) => code());
  var rootKey = 0;
  for (var i = 0; i < cells; i++) {
    rootKey ^= zobrist[board[i] * cells + i];
  }
  bound = heuristic;
  final deadline = budgetMs.clamp(100, 120000);
  final path = <int>[];
  final onPath = <int>{rootKey};
  List<int>? answer;
  String? stopped;
  var exceeded = 1 << 30;

  // Recursive descent, depth bounded by the IDA* threshold.
  bool search(int blank, int previous, int g, int h, int key) {
    final f = g + h;
    if (f > bound) {
      if (f < exceeded) exceeded = f;
      return false;
    }
    nodes++;
    if ((nodes & 2047) == 0 &&
        (clock.elapsedMilliseconds >= deadline || nodes >= 5000000)) {
      stopped = 'budget';
      return false;
    }
    if (h == 0) {
      answer = [...path];
      return true;
    }
    final choices = adjacent[blank].where((i) => i != previous).toList()
      ..sort(
        (a, b) =>
            distance(board[a], blank) -
            distance(board[a], a) -
            distance(board[b], blank) +
            distance(board[b], b),
      );
    for (final index in choices) {
      final tile = board[index];
      final childKey =
          key ^
          zobrist[tile * cells + index] ^
          zobrist[tile * cells + blank] ^
          zobrist[index] ^
          zobrist[blank];
      if (onPath.contains(childKey)) continue;
      final before = affectedConflict(blank, index);
      board[blank] = tile;
      board[index] = 0;
      final childH =
          h -
          distance(tile, index) +
          distance(tile, blank) +
          affectedConflict(blank, index) -
          before;
      onPath.add(childKey);
      path.add(tile);
      final found = search(index, blank, g + 1, childH, childKey);
      path.removeLast();
      onPath.remove(childKey);
      board[index] = tile;
      board[blank] = 0;
      if (found) return true;
      if (stopped != null) return false;
    }
    return false;
  }

  while (true) {
    exceeded = 1 << 30;
    if (search(board.indexOf(0), -1, 0, heuristic, rootKey)) {
      return result('optimal', answer!);
    }
    if (stopped != null) return result(stopped!);
    if (exceeded == 1 << 30) return result('budget');
    bound = exceeded;
  }
}
