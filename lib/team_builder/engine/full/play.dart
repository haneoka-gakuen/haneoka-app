/// Charts and judgement streams of the whole-live simulation: the
/// theoretical best play at 60 fps (Just inside Gekisou Just-count ranges)
/// and stated accuracies spread evenly over it (`engine/full/play.ts`,
/// `deck.ts`).
library;

import 'dart:math' as math;

import '../../../chart/runtime_chart.dart' show RuntimeChart;
import '../master.dart';
import '../num.dart';
import '../power.dart';
import 'conditions.dart';
import 'core.dart';
import 'model.dart';

const fps = 60;
const tailMs = 2000;
final dt = f(1 / 60);
const _maxFevers = 3;
const _notJudged = {0, 80, 82, 100, 103, 121, 122, 123};
bool isJudgementNote(int op) => !_notJudged.contains(op);

class FullChart {
  FullChart({
    required this.notes,
    required this.events,
    required this.fevers,
    required this.convertedCount,
    required this.lastTimingMs,
    required this.level,
  });

  /// Every runtime note in enumeration order; ids are 1-based positions.
  final List<LiveNote> notes;

  /// Skill events: performer index, time.
  final List<(int, int)> events;
  final List<(int, int)> fevers;
  final int convertedCount;
  final int lastTimingMs;
  final num level;
}

FullChart fullChart(EngineMaster master, RuntimeChart source, num level) {
  final enumeration = source.enumeration;
  if (enumeration.isEmpty) {
    throw StateError('chart without runtime enumeration');
  }
  final notes = [
    for (final (i, n) in enumeration.indexed)
      LiveNote(i + 1, n.timeMs, n.operateType, n.judgementType),
  ];
  var sum = 0;
  for (final n in notes) {
    final p = master.live.notePercent[n.op];
    if (p != null) sum = i32(sum + p);
  }
  return FullChart(
    notes: notes,
    events: [for (final (i, t) in source.skillTimesMs.indexed) (i, t)],
    fevers: [...source.feverMs],
    convertedCount: ceilToI32(f(f(sum) / 100)),
    lastTimingMs: notes.fold(0, (m, n) => math.max(m, n.timeMs)),
    level: level,
  );
}

List<int> _frames(int end) {
  final out = <int>[];
  for (var k = 0; ; k++) {
    final t = (k * 1000 / fps).floor();
    if (t > end) return out;
    out.add(t);
  }
}

int _partition(List<int> xs, int t) {
  var lo = 0, hi = xs.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (xs[mid] < t) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

void _chooseEvenly(int n, int count, void Function(int i) select) {
  var remainder = 0;
  for (var i = 0; i < n; i++) {
    remainder += count;
    if (remainder >= n) {
      remainder -= n;
      select(i);
    }
  }
}

class Accuracy {
  const Accuracy({this.great = 0, this.just = 1, this.missEvery = 0});
  final double great;
  final double just;

  /// Pattern play: after Great/Just, every Nth judged note is a Miss.
  final int missEvery;
}

class LivePlay {
  LivePlay(this.frames, this.dt, this.justEligibleIds);
  final List<PlayFrame> frames;
  final List<double> dt;

  /// Notes on which the player's baseline JUST rate is defined.
  final List<int> justEligibleIds;
}

/// The play of a stated accuracy built from the theoretical best play.
LivePlay judgementStream(
  EngineMaster master,
  FullChart chart,
  GekisouSetup? gekisou, [
  Accuracy accuracy = const Accuracy(),
]) {
  final judged = [
    for (final n in chart.notes)
      if (isJudgementNote(n.op)) n,
  ]..sort((a, b) => a.timeMs != b.timeMs ? a.timeMs - b.timeMs : a.id - b.id);
  var last = 0;
  for (final n in chart.notes) {
    last = math.max(last, n.timeMs);
  }
  for (final (_, t) in chart.events) {
    last = math.max(last, t);
  }
  if (gekisou != null) {
    if (gekisou.fevers.length > _maxFevers) {
      throw StateError('more than three fevers');
    }
    for (final (_, e) in gekisou.fevers) {
      last = math.max(last, e);
    }
  }
  final times = _frames(last + tailMs);
  final windows = <(int, int)>[];
  if (gekisou != null) {
    for (final (i, (start, end)) in gekisou.fevers.indexed) {
      if (i >= gekisou.missions.length) {
        throw StateError('fewer missions than fevers');
      }
      if (gekisou.missions[i] != 3) continue;
      final first = times.indexWhere((t) => t >= start);
      if (first < 0) continue;
      final rel = times.indexWhere((t) => t >= end, first + 1);
      windows.add((first, rel < 0 ? times.length : rel));
    }
  }
  bool inWindow(int frame) => windows.any((w) => w.$1 <= frame && frame < w.$2);
  final rows = [
    for (final n in judged)
      () {
        final frame = _partition(times, n.timeMs);
        final just =
            gekisou != null &&
            master.live.justTypes.contains(n.judgementType) &&
            inWindow(frame);
        return (frame: frame, note: n, best: just ? 6 : 5);
      }(),
  ];
  final total = rows.length;
  final grade = List.filled(total, 5);
  _chooseEvenly(total, jsRound(total * accuracy.great), (i) => grade[i] = 4);
  final eligible = [
    for (var i = 0; i < total; i++)
      if (grade[i] != 4 && rows[i].best == 6) i,
  ];
  _chooseEvenly(
    eligible.length,
    jsRound(eligible.length * accuracy.just),
    (k) => grade[eligible[k]] = 6,
  );
  final every = accuracy.missEvery;
  if (every > 0) {
    for (var i = every - 1; i < total; i += every) {
      grade[i] = 1;
    }
  }
  final frames = [for (final r in rows) r.frame];
  if (gekisou != null) {
    for (final (range, (start, end)) in gekisou.fevers.indexed) {
      if (gekisou.missions[range] != 1) continue;
      final first = rows.indexWhere(
        (r) => r.note.timeMs >= start && r.note.timeMs <= end,
      );
      if (first < 0) continue;
      final opening = rows[first];
      var after = first + 1;
      while (after < rows.length &&
          rows[after].frame == opening.frame &&
          rows[after].note.timeMs <= end) {
        after++;
      }
      final nextFrame = opening.frame + 1;
      final next = nextFrame < times.length ? times[nextFrame] : null;
      if (after - first < 2 || next == null || next >= end) continue;
      final legal = rows.sublist(first, after).every((r) {
        final note = r.note;
        return note.timeMs == opening.note.timeMs &&
            (note.op == 1 || note.op == 40) &&
            next - note.timeMs <=
                (master.live.perfectAfterMs[note.judgementType] ?? -1);
      });
      if (!legal) continue;
      for (var i = first + 1; i < after; i++) {
        frames[i]++;
      }
    }
  }
  final out = [for (final timeMs in times) PlayFrame(timeMs, [])];
  for (final (i, r) in rows.indexed) {
    out[frames[i]].judged.add(JudgedNote(r.note.id, grade[i], r.note.timeMs));
  }
  return LivePlay(out, List.filled(times.length, dt), [
    for (final i in eligible) rows[i].note.id,
  ]);
}

/// The performer of a member card paired with a snap.
Performer performer(EngineMaster master, MemberState m, SnapState? s) {
  final card = m.card;
  List<(int, int)> pairs(List<int> ids, List<int> levels) =>
      ids.every((id) => id == 0)
      ? const []
      : [
          for (final (i, id) in ids.indexed)
            if (id != 0) (id, i < levels.length ? levels[i] : 0),
        ];
  return Performer(
    liveSkill: (card.liveSkillId, m.growth.liveSkillLevel),
    supportSkills: s != null
        ? pairs(s.card.supportSkillIds, s.skillLevels)
        : const [],
    bandId: card.bandId,
    characterId: card.characterId,
    cardType: card.cardType,
    tagIds: card.bestTags,
    liveSkillCategories: m.liveSkillCategories,
    gekisouSkillCategories: m.gekisoSkillCategories,
    gekisouMissionType: m.gekisoMissionType,
    gekisouSkill:
        card.gekisoSkillId != 0 &&
            master.gekisoSkills.containsKey(card.gekisoSkillId)
        ? (card.gekisoSkillId, m.growth.gekisoSkillLevel)
        : null,
    gekisouSupportSkills: s != null
        ? pairs(s.card.gekisoSupportSkillIds, s.gekisoSkillLevels)
        : const [],
  );
}
