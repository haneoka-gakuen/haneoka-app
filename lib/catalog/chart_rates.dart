import 'dart:math' as math;

import '../core/api.dart';

typedef ScoreRank = ({int rank, int required, int battleRequired});
typedef PowerNeeded = ({int mean, int every, int best});

class DeckSlot {
  const DeckSlot({this.score = 100, this.perfect = 0, this.extensionMs = 0});
  final double score, perfect;
  final int extensionMs;
  DeckSlot copyWith({double? score, double? perfect, int? extensionMs}) =>
      DeckSlot(
        score: score ?? this.score,
        perfect: perfect ?? this.perfect,
        extensionMs: extensionMs ?? this.extensionMs,
      );
  String get encoded => '$score:$perfect:$extensionMs';
}

class ChartRates {
  ChartRates.fromJson(Map value)
    : base = (value['base'] as num).toDouble(),
      windows = [
        for (final row in value['windows'] as List)
          [for (final v in row as List) (v as num).toDouble()],
      ],
      skip = (value['skip'] as num).toDouble(),
      notes = (value['notes'] as num).toInt(),
      ranks = [
        for (final row in value['ranks'] as List)
          (
            rank: (row[0] as num).toInt(),
            required: (row[1] as num).toInt(),
            battleRequired: (row[2] as num).toInt(),
          ),
      ],
      gekisou = value['gekisou'] is Map
          ? GekisouRates.fromJson(value['gekisou'] as Map)
          : null;
  final double base, skip;
  final int notes;
  final List<List<double>> windows;
  final List<ScoreRank> ranks;

  /// Gekisou Live, on songs with three missions.
  final GekisouRates? gekisou;
}

/// A Gekisou Live's per-power score without rank bonuses, as parts [outside
/// the ranges, range 1, 2, 3]: at no Just and at every Just the play allows.
class GekisouRates {
  GekisouRates.fromJson(Map value)
    : missions = _ints(value['missions']),
      percents = [for (final row in value['percents'] as List) _ints(row)],
      base = [for (final row in value['base'] as List) _doubles(row)],
      events = [
        for (final run in value['events'] as List)
          [for (final row in run as List) _doubles(row)],
      ],
      notes = _ints(value['notes']),
      just = _ints(value['just']);

  /// Mission type of each range: 1 COMBO, 2 LUCK, 3 JUST, 4 All.
  final List<int> missions;

  /// Rank bonus percent as [range][rank - 1].
  final List<List<int>> percents;

  /// [no Just, all Just] → parts without skills.
  final List<List<double>> base;

  /// [no Just, all Just] → [skill event] → parts a +100 % five-second score
  /// skill adds.
  final List<List<List<double>>> events;
  final List<int> notes, just;

  static List<int> _ints(Object? row) => [
    for (final v in row as List) (v as num).toInt(),
  ];
  static List<double> _doubles(Object? row) => [
    for (final v in row as List) (v as num).toDouble(),
  ];

  /// Per-power score at a placement in each range, a Just share, a general
  /// score factor (Great share) and the five skills in percent.
  double rate(
    List<int> ranks,
    double just,
    double general,
    List<double> skills,
  ) {
    double lerp(double low, double high) => low + (high - low) * just;
    var total = 0.0;
    for (var part = 0; part < 4; part++) {
      var value = lerp(base[0][part], base[1][part]);
      for (var event = 0; event < 5; event++) {
        value +=
            (event < skills.length ? skills[event] : 0) /
            100 *
            lerp(events[0][event][part], events[1][event][part]);
      }
      final bonus = part == 0
          ? 0
          : percents[part - 1][(ranks[part - 1] - 1).clamp(0, 4)];
      total += value * (1 + bonus / 100);
    }
    return total * general;
  }
}

class RateEvent {
  RateEvent.fromJson(Map value)
    : id = (value['id'] as num).toInt(),
      title = value['title'],
      startAt = (value['startAt'] as num?)?.toInt(),
      endAt = (value['endAt'] as num?)?.toInt(),
      points = [
        for (final row in value['points'] as List)
          [for (final v in row as List) (v as num).toInt()],
      ],
      items = [
        for (final row in value['items'] as List)
          [for (final v in row as List) (v as num).toInt()],
      ];
  final int id;
  final Object? title;
  final int? startAt, endAt;
  final List<List<int>> points, items;
}

class ChartRateTable {
  ChartRateTable.fromJson(Map value)
    : releaseId = '${value['releaseId']}',
      greatFactor = (value['greatFactor'] as num).toDouble(),
      boosts = [
        for (final row in value['boosts'] as List)
          [for (final v in row as List) (v as num).toInt()],
      ],
      events = [
        for (final row in value['events'] as List)
          RateEvent.fromJson(row as Map),
      ],
      charts = {
        for (final e in (value['charts'] as Map).entries)
          '${e.key}': ChartRates.fromJson(e.value as Map),
      };
  final String releaseId;
  final double greatFactor;
  final List<List<int>> boosts;
  final List<RateEvent> events;
  final Map<String, ChartRates> charts;
  static Future<ChartRateTable> load(HaneokaApi api) async =>
      ChartRateTable.fromJson(
        await api.json('/data/chart-rates/${api.server}.json') as Map,
      );
}

final skillOrders = (() {
  final result = <List<int>>[];
  void walk(List<int> prefix) {
    if (prefix.length == 5) {
      result.add(prefix);
      return;
    }
    for (var i = 0; i < 5; i++) {
      if (!prefix.contains(i)) walk([...prefix, i]);
    }
  }

  walk([]);
  return result;
})();

int roomRequiredScore(int battleRequired, int players) {
  if (players < 1) return 2147483647;
  final value = (math.sqrt(5 / players) * battleRequired * players).truncate();
  return value > 2147483647 ? -2147483648 : value;
}

({int rank, ({int rank, int required})? next}) roomRank(
  List<ScoreRank> ranks,
  int total,
  int players,
) {
  var rank = 2;
  for (final row in ranks) {
    final required = roomRequiredScore(row.battleRequired, players);
    if (required > total) {
      return (rank: rank, next: (rank: row.rank, required: required));
    }
    rank = row.rank;
  }
  return (rank: math.max(2, rank), next: null);
}

List<double> slotOrderRates(
  ChartRates rates,
  List<DeckSlot> slots, {
  double great = 0,
  double greatFactor = .8,
}) {
  final general = 1 - great * (1 - greatFactor);
  return [
    for (final order in skillOrders)
      () {
        var score = rates.base * general;
        for (var event = 0; event < rates.windows.first.length; event++) {
          final slot = slots[order[event]];
          final w = (slot.extensionMs / 250).round().clamp(
            0,
            rates.windows.length - 1,
          );
          score +=
              slot.score / 100 * (rates.windows[w][event] * general) +
              slot.perfect / 100 * (rates.windows[w][event] * (1 - great));
        }
        return score;
      }(),
  ];
}

double certainScore(num power, double rate, int notes) =>
    power * rate * (1 - 2e-6) - notes;

PowerNeeded slotPowerNeeded(num target, List<double> orderRates, int notes) {
  if (target <= 0) return (mean: 0, every: 0, best: 0);
  int power(double rate) => ((target + notes) / (rate * (1 - 2e-6))).ceil();
  return (
    mean: power(orderRates.reduce((a, b) => a + b) / orderRates.length),
    every: power(orderRates.reduce(math.min)),
    best: power(orderRates.reduce(math.max)),
  );
}

double slotReach(num target, num power, List<double> orderRates, int notes) =>
    orderRates
        .where((rate) => certainScore(power, rate, notes) >= target)
        .length /
    orderRates.length;

PowerNeeded teamPowerNeeded(
  num target,
  List<double> scores,
  num power,
  int notes,
) =>
    slotPowerNeeded(target, [for (final score in scores) score / power], notes);

int soloRank(List<ScoreRank> ranks, num score) {
  var rank = 2;
  for (final row in ranks) {
    if (row.required <= score) rank = math.max(rank, row.rank);
  }
  return rank;
}

int _imul(int a, int b) => (a * b).toSigned(32);
int eventLivePoints(int points, num bonusPercent, int rate) =>
    (_imul(_imul((bonusPercent * 100).round() + 10000, rate), points) / 10000)
        .truncate();
double eventLiveItems(
  List<List<int>> items,
  int rank,
  num bonusPercent,
  int rate,
) {
  var total = 0.0;
  for (final row in items) {
    if (row[0] == rank) {
      total +=
          (_imul(_imul(row[1], (bonusPercent * 100).round() + 10000), rate) /
                  10000)
              .truncate() *
          row[2] /
          10000;
    }
  }
  return total;
}
