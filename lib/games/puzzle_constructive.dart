import 'dart:typed_data';

import 'puzzle_model.dart';

SolveResult constructPuzzle(
  int size,
  List<int> tiles,
  List<int> goal,
  int budgetMs,
) {
  final clock = Stopwatch()..start(), cells = size * size;
  final board = [...tiles], target = [...goal];
  final adjacent = [for (var i = 0; i < cells; i++) neighbors(i, size)];
  final positions = List.filled(cells, 0), locked = List.filled(cells, false);
  final bits = (cells - 1).bitLength;
  for (var i = 0; i < cells; i++) {
    positions[board[i]] = i;
  }
  final ranks = {for (var i = 0; i < cells; i++) goal[i]: i};
  var bound = 0, nodes = 0, blank = positions[0];
  for (var i = 0; i < cells; i++) {
    if (board[i] != 0) {
      bound +=
          (i ~/ size - ranks[board[i]]! ~/ size).abs() +
          (i % size - ranks[board[i]]! % size).abs();
    }
  }
  var key = BigInt.zero;
  for (var i = 0; i < cells; i++) {
    key |= BigInt.from(board[i]) << (i * bits);
  }
  final path = <int>[], states = [key], seen = {key: 0};
  SolveResult result(String status, [List<int> answer = const []]) =>
      SolveResult(status, answer, nodes, bound, clock.elapsedMilliseconds);
  void checkpoint() {
    if (clock.elapsedMilliseconds >= budgetMs) throw const _PuzzleBudget();
  }

  void move(int index) {
    final tile = board[index];
    key ^=
        (BigInt.from(tile) << (index * bits)) ^
        (BigInt.from(tile) << (blank * bits));
    board[blank] = tile;
    board[index] = 0;
    positions[tile] = blank;
    positions[0] = index;
    blank = index;
    final previous = seen[key];
    if (previous != null) {
      for (var i = previous + 1; i < states.length; i++) {
        seen.remove(states[i]);
      }
      states.length = previous + 1;
      path.length = previous;
    } else {
      path.add(tile);
      states.add(key);
      seen[key] = path.length;
    }
  }

  final restore = <int>[];
  var goalBlank = target.indexOf(0);
  while (goalBlank != cells - 1) {
    final next = goalBlank % size < size - 1 ? goalBlank + 1 : goalBlank + size;
    restore.add(target[next]);
    target[goalBlank] = target[next];
    target[next] = 0;
    goalBlank = next;
  }
  final parents = Int32List(cells * cells * cells),
      queue = Uint32List(cells * cells * cells);
  void place(List<int> destinations) {
    final first = target[destinations.first],
        second = destinations.length == 2 ? target[destinations[1]] : null;
    if (positions[first] == destinations.first &&
        (second == null || positions[second] == destinations[1])) {
      for (final cell in destinations) {
        locked[cell] = true;
      }
      return;
    }
    checkpoint();
    final pair = second != null;
    int encode(int a, int b, int z) =>
        pair ? (a * cells + b) * cells + z : a * cells + z;
    final root = encode(positions[first], pair ? positions[second] : 0, blank);
    parents.fillRange(0, pair ? parents.length : cells * cells, -1);
    parents[root] = root;
    queue[0] = root;
    var head = 0, tail = 1, found = -1;
    while (head < tail) {
      final state = queue[head++],
          z = state % cells,
          q = state ~/ cells,
          a = pair ? q ~/ cells : q,
          b = pair ? q % cells : 0;
      if ((++nodes & 4095) == 0) checkpoint();
      if (a == destinations.first && (!pair || b == destinations[1])) {
        found = state;
        break;
      }
      for (final next in adjacent[z]) {
        if (locked[next]) continue;
        final nextKey = encode(
          next == a ? z : a,
          pair && next == b ? z : b,
          next,
        );
        if (parents[nextKey] != -1) continue;
        parents[nextKey] = state;
        queue[tail++] = nextKey;
      }
    }
    if (found < 0) throw StateError('puzzle-layer-path');
    final route = <int>[];
    for (var state = found; state != root; state = parents[state]) {
      route.add(state % cells);
    }
    for (final next in route.reversed) {
      move(next);
    }
    for (final cell in destinations) {
      locked[cell] = true;
    }
  }

  try {
    for (var layer = 0; layer < size - 3; layer++) {
      for (var col = layer; col < size - 2; col++) {
        place([layer * size + col]);
      }
      place([layer * size + size - 2, layer * size + size - 1]);
      for (var row = layer + 1; row < size - 2; row++) {
        place([row * size + layer]);
      }
      place([(size - 2) * size + layer, (size - 1) * size + layer]);
    }
    final remaining = [
      for (var i = 0; i < 9; i++) (size - 3 + i ~/ 3) * size + size - 3 + i % 3,
    ];
    final goalTiles = [for (final index in remaining) target[index]];
    final codes = {
      for (var i = 0; i < 9; i++) goalTiles[i]: goalTiles[i] == 0 ? 0 : i + 1,
    };
    final powers = List.filled(9, 1);
    for (var i = 1; i < 9; i++) {
      powers[i] = powers[i - 1] * 9;
    }
    var initial = 0, end = 0;
    for (var i = 0; i < 9; i++) {
      initial += codes[board[remaining[i]]]! * powers[i];
      end += codes[goalTiles[i]]! * powers[i];
    }
    if (initial != end) {
      final forward = <int, ({int parent, int tile, int blank})>{
        initial: (parent: -1, tile: 0, blank: remaining.indexOf(blank)),
      };
      final backward = <int, ({int parent, int tile, int blank})>{
        end: (parent: -1, tile: 0, blank: 8),
      };
      var front = [initial], back = [end];
      int? meeting;
      while (front.isNotEmpty && back.isNotEmpty && meeting == null) {
        final expanding = front.length <= back.length,
            own = front.length <= back.length ? forward : backward,
            other = front.length <= back.length ? backward : forward,
            nextLayer = <int>[];
        for (final state in expanding ? front : back) {
          if ((++nodes & 4095) == 0) checkpoint();
          final z = own[state]!.blank;
          for (final next in neighbors(z, 3)) {
            final tile = state ~/ powers[next] % 9,
                nextKey = state + tile * (powers[z] - powers[next]);
            if (own.containsKey(nextKey)) continue;
            own[nextKey] = (parent: state, tile: tile, blank: next);
            nextLayer.add(nextKey);
            if (other.containsKey(nextKey)) {
              meeting = nextKey;
              break;
            }
          }
          if (meeting != null) break;
        }
        if (expanding) {
          front = nextLayer;
        } else {
          back = nextLayer;
        }
      }
      if (meeting == null) throw StateError('puzzle-final-path');
      final prefix = <int>[], suffix = <int>[];
      for (
        var state = meeting;
        forward[state]!.parent != -1;
        state = forward[state]!.parent
      ) {
        prefix.add(forward[state]!.tile);
      }
      for (
        var state = meeting;
        backward[state]!.parent != -1;
        state = backward[state]!.parent
      ) {
        suffix.add(backward[state]!.tile);
      }
      for (final tile in [...prefix.reversed, ...suffix]) {
        move(positions[goalTiles[tile - 1]]);
      }
    }
    for (final tile in restore.reversed) {
      move(positions[tile]);
    }
    checkpoint();
    return result(path.length == bound ? 'optimal' : 'found', path);
  } on _PuzzleBudget {
    return result('budget');
  }
}

class _PuzzleBudget {
  const _PuzzleBudget();
}
