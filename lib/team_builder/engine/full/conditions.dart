/// Skill condition checkers and the factory that builds them from the
/// condition tables (`engine/full/conditions.ts`). A checker answers
/// `(hit, hit count)` and may carry an override time (the chart time of the
/// note that completed a count). Condition groups are an OR over their
/// sets, each set an AND over its conditions.
library;

import 'dart:math' as math;

import '../master.dart';
import '../num.dart';
import 'core.dart';
import 'gekisou.dart';

class GkView {
  GkView(this.ctrl, this.prevLots, this.prevLotMs);
  final GekisouController ctrl;
  final List<int> prevLots;
  final int prevLotMs;
}

class CheckCtx {
  CheckCtx({
    required this.prevConfirmedRank,
    required this.life,
    required this.random,
    required this.frameTime,
    required this.currentCombo,
    required this.judged,
    required this.events,
    required this.gk,
    this.record = false,
  });
  int? prevConfirmedRank;
  LifeController life;
  LiveRandom random;
  int frameTime;
  int currentCombo;

  /// The frame's judged notes: note id, converted judgement, chart time.
  List<(int, int, int)> judged;

  /// The frame's fired skill events: event index, event time.
  List<(int, int)> events;
  GkView? gk;

  /// Luck recording: probabilities pass and no rush is ever playing.
  bool record;
}

GekisouController _ctrl(CheckCtx ctx, int type) =>
    ctx.gk?.ctrl ??
    (throw StateError(
      'condition type $type reads the Gekisou state of a live without Gekisou',
    ));

abstract class Checker {
  (bool, int) check(CheckCtx ctx);
  int? overrideTime() => null;
  void reset(CheckCtx ctx) {}
  bool countResettable() => false;
  void resetCount(CheckCtx ctx) {}

  /// For the idle plan: -1 for the pure `Fixed(false)`, the performer index
  /// of a pure same-member live skill check, else null.
  int? idleMember() => null;
}

class _Fixed extends Checker {
  _Fixed(this.ok);
  final bool ok;
  @override
  (bool, int) check(CheckCtx ctx) => (ok, ok ? 1 : 0);
  @override
  int? idleMember() => ok ? null : -1;
}

class AndChecker extends Checker {
  AndChecker(this.items)
    : _resettable = [for (final item in items) item.countResettable()];
  final List<Checker> items;
  final List<bool> _resettable;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    var hit = 0;
    for (var i = 0; i < items.length; i++) {
      final (ok, h) = items[i].check(ctx);
      hit = math.max(hit, h);
      if (!ok) {
        _override = null;
        if (!_resettable[i]) {
          for (var k = 0; k < items.length; k++) {
            if (_resettable[k]) items[k].resetCount(ctx);
          }
        }
        return (false, 0);
      }
      final time = items[i].overrideTime();
      if (time != null) {
        final current = _override;
        _override = current == null ? time : math.max(current, time);
      }
    }
    return (true, hit);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) {
    _override = null;
    for (final item in items) {
      item.reset(ctx);
    }
  }
}

class OrChecker extends Checker {
  OrChecker(this.items);
  final List<Checker> items;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    var hit = 0;
    for (final c in items) {
      final (ok, h) = c.check(ctx);
      hit = math.max(hit, h);
      if (ok) {
        _override = c.overrideTime();
        return (true, hit);
      }
    }
    return (false, 0);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) {
    _override = null;
    for (final item in items) {
      item.reset(ctx);
    }
  }
}

class NotChecker extends Checker {
  NotChecker(this.inner);
  final Checker inner;
  @override
  (bool, int) check(CheckCtx ctx) {
    final (ok, h) = inner.check(ctx);
    return (!ok, h);
  }

  @override
  int? overrideTime() => inner.overrideTime();
  @override
  void reset(CheckCtx ctx) => inner.reset(ctx);
  @override
  bool countResettable() => true;
  @override
  void resetCount(CheckCtx ctx) {
    if (inner.countResettable()) inner.resetCount(ctx);
  }
}

class _Life extends Checker {
  _Life(this.type, this.value);
  final int type;
  final double? value;
  @override
  (bool, int) check(CheckCtx ctx) {
    final v = value ?? (throw StateError('skill condition without a value'));
    final life = ctx.life.lifeAt(ctx.frameTime);
    final ok = type == 2000
        ? v < life
        : type == 2001
        ? v <= life
        : type == 2002
        ? life < v
        : life <= v;
    return (ok, ok ? 1 : 0);
  }
}

class _LifeChanged extends Checker {
  _LifeChanged(this._previous);
  int _previous;
  @override
  (bool, int) check(CheckCtx ctx) {
    final life = ctx.life.lifeAt(ctx.frameTime);
    final ok = _previous != life;
    _previous = life;
    return (ok, 0);
  }
}

class _LifePercent extends Checker {
  _LifePercent(this.threshold);
  final int threshold;
  int _previous = 0;
  @override
  (bool, int) check(CheckCtx ctx) {
    final life = ctx.life.lifeAt(ctx.frameTime);
    final ok = _previous > threshold && life <= threshold;
    _previous = life;
    return (ok, ok ? 1 : 0);
  }
}

class _LifeDelta extends Checker {
  _LifeDelta(this.threshold, this.increase, this._previous);
  final int threshold;
  final bool increase;
  int _previous;
  int _count = 0;
  @override
  (bool, int) check(CheckCtx ctx) {
    final life = ctx.life.lifeAt(ctx.frameTime);
    final change = increase ? i32(life - _previous) : i32(_previous - life);
    _previous = life;
    if (change > 0) _count = i32(_count + change);
    if (threshold <= 0) throw StateError('nonpositive life change threshold');
    final hits = _count >= threshold ? _count ~/ threshold : 0;
    if (hits > 0) _count = _count.remainder(threshold);
    return (hits > 0, hits);
  }

  @override
  void reset(CheckCtx ctx) {
    _count = 0;
    _previous = ctx.life.lifeAt(ctx.frameTime);
  }

  @override
  bool countResettable() => true;
  @override
  void resetCount(CheckCtx ctx) => reset(ctx);
}

class _LiveComboMultiple extends Checker {
  _LiveComboMultiple(this.threshold);
  final int threshold;
  int _previous = 0;
  @override
  (bool, int) check(CheckCtx ctx) {
    final combo = ctx.currentCombo;
    if (combo < 1 || threshold < 1) {
      _previous = 0;
      return (false, 0);
    }
    if (combo <= _previous) {
      _previous = combo;
      return (false, 0);
    }
    final hit = combo ~/ threshold - _previous ~/ threshold;
    _previous = combo;
    return (hit > 0, hit);
  }

  @override
  void reset(CheckCtx ctx) => _previous = 0;
}

class _LiveComboAtLeast extends Checker {
  _LiveComboAtLeast(this.threshold);
  final int threshold;
  @override
  (bool, int) check(CheckCtx ctx) {
    final hit = threshold > 0 && ctx.currentCombo >= threshold;
    return (hit, hit ? 1 : 0);
  }
}

class _ElapsedTime extends Checker {
  _ElapsedTime(this.period, this._previous);
  final int period;
  int _previous;
  int _elapsed = 0;
  @override
  (bool, int) check(CheckCtx ctx) {
    _elapsed = i32(_elapsed + ctx.frameTime - _previous);
    _previous = ctx.frameTime;
    final hit = _elapsed >= period;
    if (hit) _elapsed = i32(_elapsed - period);
    return (hit, hit ? 1 : 0);
  }

  @override
  void reset(CheckCtx ctx) {
    _elapsed = 0;
    _previous = ctx.frameTime;
  }

  @override
  bool countResettable() => true;
  @override
  void resetCount(CheckCtx ctx) => reset(ctx);
}

class _SnapGekisouStart extends Checker {
  int _previous = -1;
  @override
  (bool, int) check(CheckCtx ctx) {
    final gk = ctx.gk;
    if (gk != null) {
      for (final index in gk.ctrl.stateUpdates) {
        if (gk.ctrl.states[index].state == sStart && index != _previous) {
          _previous = index;
          return (true, 1);
        }
      }
    }
    return (false, 0);
  }

  @override
  void reset(CheckCtx ctx) => _previous = -1;
}

class _SameMemberLiveSkill extends Checker {
  _SameMemberLiveSkill(this.member);
  final int member;
  @override
  (bool, int) check(CheckCtx ctx) {
    final ok = ctx.events.any((e) => e.$1 == member);
    return (ok, ok ? 1 : 0);
  }

  @override
  int? idleMember() => member;
}

class ProbabilityChecker extends Checker {
  ProbabilityChecker(this.rate);
  final double rate;
  @override
  (bool, int) check(CheckCtx ctx) {
    if (ctx.record) return (true, 0);
    return (ctx.random.value(streamSkill) < rate, 0);
  }
}

class _NoteJudgementMatch extends Checker {
  _NoteJudgementMatch(this.kind, this.targets);
  final int kind;
  final List<int> targets;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    var hit = 0;
    for (final (nid, j, tn) in ctx.judged) {
      if (kind == 1020 && (j == -1 || j == 7)) continue;
      for (final target in targets) {
        bool matches;
        if (kind == 1000) {
          matches = target == j;
        } else {
          if (target < 1 || target > 6 || j < 1 || j > 6) {
            throw StateError('unknown judgement comparison rank');
          }
          matches = kind == 1010 ? j >= target : j <= target;
        }
        if (matches) {
          hit++;
          _override = nid >= 0 ? tn : null;
          break;
        }
      }
    }
    return (hit > 0, hit);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) => _override = null;
}

class _NoteJudgementCount extends Checker {
  _NoteJudgementCount(this.n, this.consecutive, this.targets);
  final double n;
  final bool consecutive;
  final List<int> targets;
  int _count = 0;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    var trig = -1, trigMs = 0, hit = 0;
    var ok = false;
    for (final (nid, j, tn) in ctx.judged) {
      for (final tj in targets) {
        if (tj == j) {
          _count = i32(_count + 1);
          if (_count >= n) {
            ok = true;
            hit++;
            _count = 0;
            trig = nid;
            trigMs = tn;
          }
        } else if (consecutive) {
          _count = 0;
        }
      }
    }
    if (ok && trig >= 0) _override = trigMs;
    return (ok, hit);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) => _count = 0;
  @override
  bool countResettable() => true;
  @override
  void resetCount(CheckCtx ctx) => reset(ctx);
}

class _LuckLotResult extends Checker {
  _LuckLotResult(this.target);
  final double target;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    final lots = ctx.gk?.prevLots ?? const <int>[];
    final hit = lots.where((r) => r == target).length;
    if (hit > 0) {
      _override = ctx.gk?.prevLotMs ?? 0;
      return (true, hit);
    }
    return (false, 0);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) => _override = null;
}

class _ComboAtLeast extends Checker {
  _ComboAtLeast(this.threshold);
  final double threshold;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    final c = _ctrl(ctx, 7005);
    final idx = c.currentPlayingIndex;
    if (idx < 0 || threshold <= 0) return (false, 0);
    final rs = c.states[idx];
    if (rs.combo < threshold) return (false, 0);
    if (rs.lastComboMs >= 0) _override = rs.lastComboMs;
    return (true, 1);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) => _override = null;
}

RangeState? _playingState(CheckCtx ctx) {
  final gk = ctx.gk;
  final idx = gk != null ? gk.ctrl.currentPlayingIndex : -1;
  return gk != null && idx >= 0 ? gk.ctrl.states[idx] : null;
}

class _GkInterval extends Checker {
  _GkInterval(this.kind, this.n);
  final int kind;
  final int n;
  int _previous = 0;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    final rs = _playingState(ctx);
    var hits = 0;
    if (n > 0 && rs != null) {
      final current = kind == 7001
          ? rs.combo
          : kind == 7002
          ? rs.just
          : rs.rawJust;
      if (current <= 0) {
        _previous = 0;
      } else {
        final old = _previous;
        _previous = current;
        if (current > old) hits = math.max(0, current ~/ n - old ~/ n);
      }
    }
    if (hits > 0 && rs != null) {
      final t = kind == 7001 ? rs.lastComboMs : rs.lastJustMs;
      _override = t >= 0 ? t : null;
    }
    return (hits > 0, hits);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) {
    _previous = 0;
    _override = null;
  }
}

class _JustAtLeast extends Checker {
  _JustAtLeast(this.threshold);
  final int threshold;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    final rs = _playingState(ctx);
    final hit = threshold > 0 && rs != null && rs.just >= threshold;
    if (hit && rs.lastJustMs >= 0) _override = rs.lastJustMs;
    return (hit, hit ? 1 : 0);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) => _override = null;
}

class _GkJustEdge extends Checker {
  _GkJustEdge(this.raw, this.threshold);
  final bool raw;
  final int threshold;
  int _previous = 0;
  int _lastRange = -1;
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    final gk = ctx.gk;
    final idx = gk != null ? gk.ctrl.currentPlayingIndex : -1;
    final rs = gk != null && idx >= 0 ? gk.ctrl.states[idx] : null;
    if (threshold <= 0) return (false, 0);
    if (rs == null) {
      _previous = 0;
      _lastRange = -1;
      return (false, 0);
    }
    if (idx != _lastRange) {
      _previous = 0;
      _lastRange = idx;
    }
    final count = raw ? rs.rawJust : rs.just;
    final hit = _previous < threshold && count >= threshold;
    _previous = count;
    if (hit && rs.lastJustMs >= 0) _override = rs.lastJustMs;
    return (hit, hit ? 1 : 0);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) {
    _previous = 0;
    _lastRange = -1;
    _override = null;
  }
}

class _GkOnce extends Checker {
  _GkOnce(this.eligible);
  final bool Function(CheckCtx ctx) eligible;
  bool _triggered = false;
  @override
  (bool, int) check(CheckCtx ctx) {
    final hit = !_triggered && eligible(ctx);
    if (hit) _triggered = true;
    return (hit, hit ? 1 : 0);
  }

  @override
  void reset(CheckCtx ctx) => _triggered = false;
}

bool _missionOk(List<int> missions, int mission) =>
    missions.isEmpty ||
    missions.contains(missionAll) ||
    missions.contains(mission);

class _RangeStart extends Checker {
  _RangeStart(this.missions);
  final List<int> missions;
  var _triggered = <int>[];
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    final c = _ctrl(ctx, 7010);
    for (final idx in c.stateUpdates) {
      final s = c.states[idx].state;
      if (s == sFinish) {
        _triggered = [
          for (final x in _triggered)
            if (x != idx) x,
        ];
      } else if (s == sStart) {
        if (!_missionOk(missions, c.ranges[idx].mission)) continue;
        if (!_triggered.contains(idx)) {
          _triggered.add(idx);
          _override = c.ranges[idx].startMs;
          return (true, 1);
        }
      }
    }
    return (false, 0);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) {
    _triggered = [];
    _override = null;
  }
}

class _RangeComplete extends Checker {
  @override
  (bool, int) check(CheckCtx ctx) {
    final c = _ctrl(ctx, 7013);
    final ok = c.stateUpdates.any((i) => c.states[i].state == sComplete);
    return (ok, ok ? 1 : 0);
  }
}

class _RangePlaying extends Checker {
  _RangePlaying(this.missions);
  final List<int> missions;
  var _active = <(int, int)>[];
  int? _override;
  @override
  (bool, int) check(CheckCtx ctx) {
    _override = null;
    final c = _ctrl(ctx, 7020);
    var first = -1;
    for (final idx in c.stateUpdates) {
      final s = c.states[idx].state;
      if (s == sStart || s == sPlaying) {
        if (!_active.any((a) => a.$1 == idx)) {
          _active.add((idx, c.ranges[idx].mission));
          if (first < 0) first = c.ranges[idx].startMs;
        }
      } else if (s == sComplete || s == sFinish) {
        _active = [
          for (final a in _active)
            if (a.$1 != idx) a,
        ];
      }
    }
    if (_active.isEmpty) return (false, 0);
    if (missions.isNotEmpty &&
        !missions.contains(missionAll) &&
        !_active.any((a) => missions.contains(a.$2))) {
      return (false, 0);
    }
    if (first >= 0) _override = first;
    return (true, 1);
  }

  @override
  int? overrideTime() => _override;
  @override
  void reset(CheckCtx ctx) {
    _active = [];
    _override = null;
  }
}

class _LuckRushPlaying extends Checker {
  bool _rush = false;
  @override
  (bool, int) check(CheckCtx ctx) {
    if (ctx.record) return (false, 0);
    final c = _ctrl(ctx, 7021);
    final idx = c.currentPlayingIndex;
    if (idx >= 0 && c.ranges[idx].mission == missionLuck) {
      _rush = c.states[idx].luck.rushCombo != 0;
    }
    for (final i in c.stateUpdates) {
      final s = c.states[i].state;
      if (c.ranges[i].mission == missionLuck &&
          (s == sComplete || s == sFinish)) {
        _rush = false;
      }
    }
    return (_rush, _rush ? 1 : 0);
  }

  @override
  void reset(CheckCtx ctx) => _rush = false;
}

/// Probability that a pure condition holds: probabilities multiply through
/// AND, OR and NOT; every other checker is asked once.
double chanceOf(Checker? checker, CheckCtx ctx) {
  if (checker == null) return 1;
  if (checker is ProbabilityChecker) return checker.rate;
  if (checker is AndChecker) {
    return checker.items.fold(1.0, (p, item) => p * chanceOf(item, ctx));
  }
  if (checker is OrChecker) {
    return 1 -
        checker.items.fold(1.0, (p, item) => p * (1 - chanceOf(item, ctx)));
  }
  if (checker is NotChecker) return 1 - chanceOf(checker.inner, ctx);
  return checker.check(ctx).$1 ? 1 : 0;
}

/// The count an effect state carries while it runs.
abstract class Cumulative {
  int initCount() => 0;
  int unit() => 0;
  int max() => 0;
  int updateCount(CheckCtx ctx);
  void reset() {}
}

class _CumulativeFixed extends Cumulative {
  _CumulativeFixed(this.value);
  final int value;
  @override
  int initCount() => value;
  @override
  int updateCount(CheckCtx ctx) => value;
}

class _ComboPerN extends Cumulative {
  _ComboPerN(this.n, this.valuesEmpty, this.maximum, this.just);
  final int n;
  final bool valuesEmpty;
  final int maximum;
  final bool just;
  @override
  int unit() => n;
  @override
  int max() => maximum;
  @override
  int updateCount(CheckCtx ctx) {
    final gk = ctx.gk;
    if (gk == null) return 0;
    final idx = gk.ctrl.currentPlayingIndex;
    var v = 0;
    if (idx >= 0) {
      if (valuesEmpty) throw StateError('skill condition without a value');
      final st = gk.ctrl.states[idx];
      v = floorToI32(f(f(just ? st.just : st.combo) / f(n)));
    }
    return v >= maximum ? maximum : v;
  }
}

class _LifePerN extends Cumulative {
  _LifePerN(this.init, this.n, this.valuesEmpty, this.maximum, this.limit);
  final int init;
  final int n;
  final bool valuesEmpty;
  final int maximum;
  final bool limit;
  @override
  int initCount() => init;
  @override
  int updateCount(CheckCtx ctx) {
    if (valuesEmpty) throw StateError('skill condition without a value');
    final life = limit ? ctx.life.maximum : ctx.life.lifeAt(ctx.frameTime);
    return math.min(floorToI32(f(f(life) / f(n))), maximum);
  }
}

class _JudgementPerN extends Cumulative {
  _JudgementPerN(
    this.n,
    this.valuesEmpty,
    this.targets,
    this.maximum,
    this.kind,
  );
  final int n;
  final bool valuesEmpty;
  final List<int> targets;
  final int maximum;
  final int kind;
  int _count = 0;
  @override
  int unit() => n;
  @override
  int max() => maximum;
  @override
  int updateCount(CheckCtx ctx) {
    for (final (_, j, _) in ctx.judged) {
      if (targets.any(
        (t) => kind == 1001
            ? j >= t
            : kind == 1002
            ? j <= t
            : j == t,
      )) {
        _count = i32(_count + 1);
      }
    }
    if (valuesEmpty) throw StateError('skill condition without a value');
    return math.min(floorToI32(f(f(_count) / f(n))), maximum);
  }

  @override
  void reset() => _count = 0;
}

class _ElapsedCount extends Cumulative {
  _ElapsedCount(this.period, this._previous, this.maximum);
  final int period;
  int _previous;
  final int maximum;
  int _elapsed = 0;
  int _count = 0;
  @override
  int updateCount(CheckCtx ctx) {
    _elapsed = i32(_elapsed + ctx.frameTime - _previous);
    _previous = ctx.frameTime;
    if (_elapsed >= period) {
      _elapsed = i32(_elapsed - period);
      _count = i32(_count + 1);
    }
    return math.min(_count, maximum);
  }

  @override
  void reset() {
    _elapsed = 0;
    _count = 0;
  }
}

/// A performer's skill-target view.
class Performer {
  Performer({
    required this.liveSkill,
    required this.supportSkills,
    required this.bandId,
    required this.characterId,
    required this.cardType,
    required this.tagIds,
    required this.liveSkillCategories,
    required this.gekisouSkillCategories,
    required this.gekisouMissionType,
    required this.gekisouSkill,
    required this.gekisouSupportSkills,
    this.missionOnly,
  });
  final (int, int)? liveSkill;
  final List<(int, int)> supportSkills;
  final int bandId;
  final int characterId;
  final int cardType;
  final List<int> tagIds;
  final List<int> liveSkillCategories;
  final List<int> gekisouSkillCategories;
  final int gekisouMissionType;
  final (int, int)? gekisouSkill;
  final List<(int, int)> gekisouSupportSkills;

  /// Analysis only: a Gekisou mission without Gekisou skill rows.
  final int? missionOnly;

  /// A performer with nothing but the given parts (`{...EMPTY, …}`).
  Performer.empty({
    this.bandId = 0,
    this.missionOnly,
    this.gekisouSupportSkills = const [],
    this.gekisouSkill,
    this.gekisouMissionType = 0,
  }) : liveSkill = null,
       supportSkills = const [],
       characterId = 0,
       cardType = 0,
       tagIds = const [],
       liveSkillCategories = const [],
       gekisouSkillCategories = const [];

  Performer withMissionOnly(int? value) => Performer(
    liveSkill: liveSkill,
    supportSkills: supportSkills,
    bandId: bandId,
    characterId: characterId,
    cardType: cardType,
    tagIds: tagIds,
    liveSkillCategories: liveSkillCategories,
    gekisouSkillCategories: gekisouSkillCategories,
    gekisouMissionType: gekisouMissionType,
    gekisouSkill: gekisouSkill,
    gekisouSupportSkills: gekisouSupportSkills,
    missionOnly: value,
  );

  /// This performer with another band and Gekisou support skills.
  Performer withSupport(int bandId, List<(int, int)> supports) => Performer(
    liveSkill: liveSkill,
    supportSkills: supportSkills,
    bandId: bandId,
    characterId: characterId,
    cardType: cardType,
    tagIds: tagIds,
    liveSkillCategories: liveSkillCategories,
    gekisouSkillCategories: gekisouSkillCategories,
    gekisouMissionType: gekisouMissionType,
    gekisouSkill: gekisouSkill,
    gekisouSupportSkills: supports,
    missionOnly: missionOnly,
  );

  /// The Gekisou parts without the member's own Gekisou skill
  /// (`{...gekisoPerformer(p), gekisouSkill: null, missionOnly: 1}`).
  Performer get supportOnly => Performer(
    liveSkill: null,
    supportSkills: const [],
    bandId: bandId,
    characterId: characterId,
    cardType: cardType,
    tagIds: tagIds,
    liveSkillCategories: liveSkillCategories,
    gekisouSkillCategories: gekisouSkillCategories,
    gekisouMissionType: gekisouMissionType,
    gekisouSkill: null,
    gekisouSupportSkills: gekisouSupportSkills,
    missionOnly: 1,
  );

  /// A skill-target attribute by its name (`p[field]`).
  Object field(String name) => switch (name) {
    'bandId' => bandId,
    'cardType' => cardType,
    'characterId' => characterId,
    'tagIds' => tagIds,
    'liveSkillCategories' => liveSkillCategories,
    'gekisouSkillCategories' => gekisouSkillCategories,
    'gekisouMissionType' => gekisouMissionType,
    _ => 0,
  };

  /// The Gekisou parts alone: what every member order shares.
  Performer get gekisoOnly => Performer(
    liveSkill: null,
    supportSkills: const [],
    bandId: bandId,
    characterId: characterId,
    cardType: cardType,
    tagIds: tagIds,
    liveSkillCategories: liveSkillCategories,
    gekisouSkillCategories: gekisouSkillCategories,
    gekisouMissionType: gekisouMissionType,
    gekisouSkill: gekisouSkill,
    gekisouSupportSkills: gekisouSupportSkills,
    missionOnly: missionOnly,
  );
}

/// The live member-target predicate (it ignores the target's discriminator).
bool performerMatches(Performer p, TargetRow t) {
  bool categories(List<int> targets, List<int> member) =>
      targets.any((c) => c != 0 && member.contains(c));
  return (t.bandId > 0 && t.bandId == p.bandId) ||
      (t.cardType != 0 && t.cardType == p.cardType) ||
      (t.characterId > 0 && t.characterId == p.characterId) ||
      (t.tagId > 0 && p.tagIds.contains(t.tagId)) ||
      categories(t.liveSkillCategories, p.liveSkillCategories) ||
      categories(t.gekisouSkillCategories, p.gekisouSkillCategories) ||
      (t.gekisouMissionType != 0 &&
          t.gekisouMissionType == p.gekisouMissionType);
}

const _targetMission = 5;
const _noJudgement = -1;

/// Builds checkers for the performer at index `k` of [deck].
class ConditionFactory {
  ConditionFactory(
    this.master,
    this.deck,
    this.initialLife,
    this.skillTargetMusicType, [
    this.initialTimeMs = 0,
  ]);
  final EngineMaster master;
  final List<Performer> deck;
  final int initialLife;
  final int skillTargetMusicType;
  final int initialTimeMs;

  TargetRow _target(int id) =>
      master.targets[id] ?? (throw StateError('unknown skill target $id'));

  Checker? _one(int cid, int k) {
    final c =
        master.conditions[cid] ??
        (throw StateError('unknown skill condition $cid'));
    final v0 = c.values.firstOrNull;
    double need() =>
        v0 ?? (throw StateError('skill condition without a value'));
    List<TargetRow> targets() => [for (final id in c.targetIds) _target(id)];
    List<int> missions() => [
      for (final t in targets())
        if (t.skillTargetType == _targetMission && t.gekisouMissionType != 0)
          t.gekisouMissionType,
    ];
    Checker ch;
    switch (c.type) {
      case 0:
        return null;
      case 2000 || 2001 || 2002 || 2003:
        ch = _Life(c.type, v0);
      case 2004:
        ch = _LifeChanged(initialLife);
      case 4007:
        ch = _LifePercent(ceilToI32(f(f(f(need()) / 10) * f(initialLife))));
      case 4008 || 4009:
        ch = _LifeDelta(i32(need()), c.type == 4008, initialLife);
      case 3000 || 3001:
        final ts = targets();
        final count = deck
            .where((member) => ts.any((t) => performerMatches(member, t)))
            .length;
        ch = _Fixed(c.type == 3000 ? count > 0 : count == deck.length);
      case 4001:
        ch = _LiveComboMultiple(i32(need()));
      case 4002:
        ch = _LiveComboAtLeast(i32(need()));
      case 4000:
        ch = _ElapsedTime(imul(i32(need()), 1000), initialTimeMs);
      case 4010 || 5020:
        ch = _SameMemberLiveSkill(k);
      case 5021:
        ch = _SnapGekisouStart();
      case 4012:
        ch = _Fixed(
          targets().any((t) => t.liveMusicType == skillTargetMusicType),
        );
      case 4011:
        ch = ProbabilityChecker(f(f(need()) / 100));
      case 5000:
        final p = k < deck.length ? deck[k] : null;
        ch = _Fixed(p != null && targets().any((t) => performerMatches(p, t)));
      case 8000:
        ch = _Fixed(false);
      case 1000 || 1010 || 1020 || 1030 || 1040:
        final judgements = [
          for (final t in targets())
            if (t.judgement != _noJudgement) t.judgement,
        ];
        ch = c.type == 1030 || c.type == 1040
            ? _NoteJudgementCount(need(), c.type == 1040, judgements)
            : _NoteJudgementMatch(c.type, judgements);
      case 7000:
        ch = _LuckLotResult(need());
      case 7001 || 7002 || 7004:
        ch = _GkInterval(c.type, i32(need()));
      case 7003:
        ch = _JustAtLeast(i32(need()));
      case 7006 || 7007:
        ch = _GkJustEdge(c.type == 7007, i32(need()));
      case 7011:
        ch = _GkOnce((ctx) => ctx.gk != null);
      case 7012:
        final threshold = v0 ?? 1;
        ch = _GkOnce(
          (ctx) =>
              ctx.prevConfirmedRank != null &&
              ctx.prevConfirmedRank! > 0 &&
              ctx.prevConfirmedRank! <= threshold,
        );
      case 7005:
        ch = _ComboAtLeast(need());
      case 7010:
        ch = _RangeStart(missions());
      case 7013:
        ch = _RangeComplete();
      case 7020:
        ch = _RangePlaying(missions());
      case 7021:
        ch = _LuckRushPlaying();
      default:
        throw StateError('unsupported skill condition type ${c.type}');
    }
    return c.positive ? ch : NotChecker(ch);
  }

  /// The checker of a condition group (null for group 0 or a group without
  /// a non-empty set).
  Checker? group(int gid, int k) {
    if (gid == 0) return null;
    final ors = <Checker>[];
    for (final set in master.conditionSets[gid] ?? const <List<int>>[]) {
      final items = [for (final cid in set) ?_one(cid, k)];
      if (items.length == 1) {
        ors.add(items.first);
      } else if (items.length > 1) {
        ors.add(AndChecker(items));
      }
    }
    return ors.isEmpty
        ? null
        : ors.length == 1
        ? ors.first
        : OrChecker(ors);
  }

  /// The cumulative condition of an effect (id 0: none).
  Cumulative? cumulative(int cid, int k) {
    if (cid == 0) return null;
    final c =
        master.cumulative[cid] ??
        (throw StateError('unknown cumulative condition $cid'));
    final max = c.cap < 1 ? 2147483647 : c.cap;
    final n = (c.values.firstOrNull ?? 0).toInt();
    final empty = c.values.isEmpty;
    switch (c.type) {
      case 7000 || 7001:
        return _ComboPerN(n, empty, max, c.type == 7000);
      case 2000 || 2001:
        if (c.type == 2000 && empty) {
          throw StateError('skill condition without a value');
        }
        final init = c.type == 2000 ? floorToI32(f(f(initialLife) / f(n))) : 0;
        return _LifePerN(init, n, empty, max, c.type == 2001);
      case 1000 || 1001 || 1002:
        final targets = [
          for (final id in c.targetIds)
            if (_target(id).judgement != _noJudgement) _target(id).judgement,
        ];
        return _JudgementPerN(n, empty, targets, max, c.type);
      case 3000 || 3001 || 3002 || 3003 || 3004 || 3005:
        int count;
        if (c.type <= 3001) {
          final ts = [for (final id in c.targetIds) _target(id)];
          count = [
            for (final (index, member) in deck.indexed)
              if ((c.type != 3001 || index != k) &&
                  ts.any((t) => performerMatches(member, t)))
                member,
          ].length;
        } else if (c.type <= 3003) {
          if (k >= deck.length) {
            throw RangeError('cumulative self member index out of range');
          }
          final band = deck[k].bandId;
          count = c.type == 3002
              ? deck.where((p) => p.bandId == band).length
              : {
                  for (final p in deck)
                    if (p.bandId != band) p.bandId,
                }.length;
        } else {
          count = {for (final p in deck) c.type == 3004 ? p.bandId : p.cardType}
              .length;
        }
        return _CumulativeFixed(math.min(count, max));
      case 6000:
        if (empty) throw StateError('skill condition without a value');
        return _ElapsedCount(imul(n, 1000), initialTimeMs, max);
      default:
        throw StateError(
          'ArgumentOutOfRangeException: cumulative condition type ${c.type}',
        );
    }
  }
}
