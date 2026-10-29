/// Input qualification for the AP solo/challenge reward recommendation
/// (`engine/pt-eligibility.ts`). No inferred practice values: every card
/// growth, rank and bonus the result reads must be entered.
library;

import 'dart:math' as math;

import '../../chart/runtime_chart.dart' show RuntimeChart;
import 'api.dart';
import 'box.dart';
import 'full/gekisou.dart' show missionPattern;
import 'master.dart';
import 'num.dart';
import 'full/core.dart' show satI32;
import 'objectives.dart';
import 'power.dart';
import 'skills.dart';

class PtIssue {
  const PtIssue(this.code, this.target);

  /// `mode`, `inventory`, `practice`, `player`, `constraint`, `event`,
  /// `chart`, `skill` or `rules`.
  final String code;
  final String target;
  String get key => '$code:$target';
}

bool _integer(Object? n, [int min = 0]) =>
    n is int && n >= min && n <= 2147483647;
bool _wholeDouble(double n, [int min = 0]) =>
    n.isFinite && n == n.roundToDouble() && n >= min && n <= 2147483647;

List<PtIssue> validatePtRequest(EngineMaster master, EngineRequest request) {
  final rules = request.songRules;
  if (rules != null) {
    final missions = intListOf(rules['missions']),
        type = intOf(rules['musicType']);
    master = master.withSongs({
      for (final entry in master.songs.entries)
        entry.key: Song(
          entry.value.id,
          type == 0 ? entry.value.musicType : type,
          entry.value.bestTags,
          entry.value.bandIds,
          entry.value.rankGroup,
          entry.value.difficulties,
          [
            for (final (i, mission) in entry.value.gekisoMissions.indexed)
              (missions.elementAtOrNull(i) ?? 0) == 0 ? mission : missions[i],
          ],
        ),
    });
  }
  final issues = <PtIssue>[];
  void add(String code, String target) => issues.add(PtIssue(code, target));
  void checkGekisoEffects(Iterable<SkillEffectRow> effects, String target) {
    for (final effect in effects) {
      if (!(effect.triggerType == 1 || effect.triggerType == 2) ||
          !effect.seconds.isFinite ||
          effect.targetIds.any((id) => !master.targets.containsKey(id))) {
        add('skill', target);
      }
      for (final group in [
        effect.triggerGroup,
        effect.conditionGroup,
        effect.releaseGroup,
        effect.resetGroup,
      ]) {
        if (group == 0) continue;
        final sets = master.conditionSets[group];
        if (sets == null ||
            sets.isEmpty ||
            sets.expand((set) => set).any((id) {
              final condition = master.conditions[id];
              return condition == null ||
                  condition.targetIds.any(
                    (t) => !master.targets.containsKey(t),
                  );
            })) {
          add('skill', '$target:condition:$group');
        }
      }
      if (effect.cumulativeId != 0) {
        final row = master.cumulative[effect.cumulativeId];
        if (row == null ||
            row.targetIds.any((id) => !master.targets.containsKey(id))) {
          add('skill', '$target:cumulative');
        }
      }
    }
  }

  final goal = request.goal;
  if (goal is! EventGoal ||
      goal.route == RouteKind.skip ||
      !(goal.measure == 'points' || goal.measure == 'items') ||
      !goal.ptOnly ||
      !goal.play.isAllPerfect ||
      request.k != 1) {
    return const [PtIssue('mode', 'solo-ap-rewards')];
  }
  final gekiso = goal.gekiso;
  if (gekiso != null &&
      (goal.route != RouteKind.live ||
          !gekiso.just.isFinite ||
          gekiso.just < 0 ||
          gekiso.just > 1 ||
          gekiso.luckSamples < 1)) {
    add('mode', 'gekiso-input');
  }
  final cp = goal.cpExchange;
  if (cp != null &&
      (goal.route != RouteKind.live ||
          cp.numerator < 0 ||
          cp.denominator < 1)) {
    add('rules', 'cp-value');
  }
  final challenge = goal.route == RouteKind.challenge;
  if (goal.songs.isEmpty) {
    add('chart', challenge ? 'challenge-selection' : 'selection');
  }
  if ({for (final r in request.members) r.key}.length !=
          request.members.length ||
      {for (final r in request.members) r.cardId}.length !=
          request.members.length) {
    add('inventory', 'member');
  }
  if ({for (final r in request.snaps) r.key}.length != request.snaps.length ||
      {for (final r in request.snaps) r.cardId}.length !=
          request.snaps.length) {
    add('inventory', 'snap');
  }
  for (final row in request.members) {
    final card = master.members[row.cardId];
    if (card == null) {
      add('inventory', row.key);
      continue;
    }
    final resolved = memberGrowth(master, card, row, UnknownPolicy.min);
    for (final (field, entered, value) in [
      ('level', row.level, resolved.level),
      ('awake', row.awake, resolved.awake),
      ('rank', row.rank, resolved.rank),
      ('liveSkillLevel', row.liveSkillLevel, resolved.liveSkillLevel),
    ]) {
      if (!_integer(entered, 1) || entered != value) {
        add('practice', '${row.key}.$field');
      }
    }
    if (gekiso != null &&
        card.gekisoSkillId != 0 &&
        (!_integer(row.gekisoSkillLevel, 1) ||
            row.gekisoSkillLevel != resolved.gekisoSkillLevel)) {
      add('practice', '${row.key}.gekisoSkillLevel');
    }
  }
  for (final row in request.snaps) {
    final card = master.snaps[row.cardId];
    if (card == null) {
      add('inventory', row.key);
      continue;
    }
    final resolved = snapGrowth(master, card, row, UnknownPolicy.min);
    for (final (field, entered, value) in [
      ('level', row.level, resolved.level),
      ('rank', row.rank, resolved.rank),
    ]) {
      if (!_integer(entered, 1) || entered != value) {
        add('practice', '${row.key}.$field');
      }
    }
  }
  final box = resolveBox(
    master,
    request.members,
    request.snaps,
    UnknownPolicy.min,
  );
  for (final key in box.unknown) {
    add('inventory', key);
  }
  final members = {for (final row in box.members) row.key: row};
  final snaps = {for (final row in box.snaps) row.key: row};
  final c = request.constraints;
  final usable = [
    for (final row in box.members)
      if (!c.excludedMembers.contains(row.key)) row,
  ];
  if ({for (final row in usable) row.card.characterId}.length < 5) {
    add('inventory', 'five-characters');
  }
  final required = {
    ...c.requiredMembers,
    for (final (key, _) in c.bindings) key,
    ?c.leader,
  };
  for (final key in [...required, ...c.excludedMembers]) {
    if (!members.containsKey(key) ||
        (required.contains(key) && c.excludedMembers.contains(key))) {
      add('constraint', key);
    }
  }
  if (required.length > 5 ||
      {for (final key in required) members[key]?.card.characterId}.length !=
          required.length) {
    add('constraint', 'required-members');
  }
  final bound = [for (final (_, key) in c.bindings) ?key];
  final requiredPhotos = {...c.requiredSnaps, ...bound};
  if (requiredPhotos.length > 5 ||
      bound.toSet().length != bound.length ||
      {for (final (key, _) in c.bindings) key}.length != c.bindings.length) {
    add('constraint', 'photo-bindings');
  }
  for (final key in [...requiredPhotos, ...c.excludedSnaps]) {
    if (!snaps.containsKey(key) ||
        (requiredPhotos.contains(key) &&
            (c.noSnaps || c.excludedSnaps.contains(key)))) {
      add('constraint', key);
    }
  }
  if (c.minBonusPercent != null &&
      (!c.minBonusPercent!.isFinite || c.minBonusPercent! < 0)) {
    add('constraint', 'minBonus');
  }

  final player = request.player;
  for (final id in {for (final row in usable) row.card.characterId}) {
    final rank = player.characterRanks['$id'];
    if (!_integer(rank, 1) || rank! > master.maxCharacterRank) {
      add('player', 'cr.$id');
    }
    if (!_integer(player.characterMemory['$id'])) add('player', 'cm.$id');
  }
  // The public bonus table is sparse: the base rank (1) has no bonus row.
  if (!_integer(player.vipRank, 1) ||
      master.vipBonus.isEmpty ||
      (player.vipRank != 1 && !master.vipBonus.containsKey(player.vipRank))) {
    add('player', 'p.vip');
  }
  for (final MapEntry(key: id, value: item) in master.bandItems.entries) {
    final level = player.bandItems['$id'];
    if (!_integer(level) || (level != 0 && !item.levels.containsKey(level))) {
      add('player', 'bi.$id');
    }
  }

  final event = master.events[goal.eventId];
  final points = challenge ? event?.challengePoints : event?.livePoints;
  final rewards = [
    for (final row
        in (challenge ? event?.challengeRewards : event?.liveRewards) ??
            const <RewardRow>[])
      if (row.resourceId == event?.itemId) row,
  ];
  final items = goal.measure == 'items';
  final BoostRow? boost = challenge
      ? master.challengeBoosts
            .where((row) => row.consumed == goal.consumption)
            .firstOrNull
      : !liveBoostCosts.contains(goal.consumption)
      ? null
      : goal.consumption == 0
      ? BoostRow(0, 1, 1)
      : master.boosts
            .where((row) => row.consumed == goal.consumption)
            .firstOrNull;
  if (goal.consumption < (challenge ? 1 : 0) ||
      boost == null ||
      !_wholeDouble(boost.eventPointRate, 1) ||
      (items && !_wholeDouble(boost.rewardRate, 1))) {
    add('event', challenge ? 'challenge-consumption' : 'consumption');
  }
  if (!items && (points == null || points.isEmpty)) add('event', 'tables');
  if (items &&
      (!_integer(event?.itemId, 1) ||
          rewards.isEmpty ||
          {for (final row in rewards) row.resourceType}.length != 1 ||
          rewards.any((row) => row.probability != 10000 || row.count < 0))) {
    add('event', 'guaranteed-medal-rewards');
  }
  List<int> countsAt(int rank) => [
    for (final row in rewards)
      if (row.scoreRank == rank) row.count,
  ]..sort();
  final seen = <String>{};
  for (final ref in goal.songs) {
    final key = ref.key;
    final chartTarget = challenge ? 'challenge:$key' : key;
    if (!seen.add(key)) add('chart', chartTarget);
    final song = master.songs[ref.songId];
    final diff = song?.difficulties
        .where((row) => row.difficulty == ref.difficulty)
        .firstOrNull;
    if (song == null ||
        diff == null ||
        diff.file.isEmpty ||
        diff.noteCount < 1 ||
        !_wholeDouble(diff.playLevel, 1)) {
      add('chart', chartTarget);
    }
    if (challenge &&
        !master.challengeMusics.any(
          (row) => row.eventId == goal.eventId && row.liveMusicId == ref.songId,
        )) {
      add('chart', 'challenge:$key');
    }
    final ranks = song == null ? null : master.scoreRanks[song.rankGroup];
    if (gekiso != null && song != null) {
      final missions = song.gekisoMissions;
      if (missions.length != 3 || missions.any((m) => m < 1 || m > 3)) {
        add('chart', 'gekiso:$key');
      } else {
        final pattern = missionPattern(missions[0], missions[1], missions[2]);
        if ([1, 2, 3].any(
          (count) => !master.live.gekiso.rankingBonuses.any(
            (row) =>
                row.pattern == pattern &&
                row.count == count &&
                row.rank == 1 &&
                row.percent >= 0,
          ),
        )) {
          add('rules', 'gekiso-rank-bonus');
        }
      }
      if (ranks == null ||
          !ranks.any((r) => r.battleRequired > 0) ||
          ranks.any((r) => r.battleRequired < 0)) {
        add('chart', 'gekiso-ranks:$key');
      }
      if (missions.contains(3) &&
          (master.live.justTypes.isEmpty ||
              !master.live.judgePercent.containsKey(1))) {
        add('rules', 'gekiso-just');
      }
    }
    if (ranks == null ||
        ranks.isEmpty ||
        ranks.any((row) => row.required < 0)) {
      add('chart', chartTarget);
    }
    for (final rank in {
      2,
      for (final row in ranks ?? const <ScoreRankRow>[]) row.rank,
    }) {
      if (items ? countsAt(rank).isEmpty : !_integer(points?[rank])) {
        add('event', '${goal.eventId}:$rank');
      }
      if (cp != null && !_integer(master.liveChallengePoints[rank])) {
        add('event', 'cp:$rank');
      }
    }
    final ordered = stableSorted([
      (rank: 2, required: 0),
      for (final r in ranks ?? const <ScoreRankRow>[])
        if (r.rank != 2) (rank: r.rank, required: r.required),
    ], (a, b) => a.rank - b.rank);
    var monotone = true;
    for (var i = 1; i < ordered.length && monotone; i++) {
      final row = ordered[i], previous = ordered[i - 1];
      final now = countsAt(row.rank), before = countsAt(previous.rank);
      if (row.required < previous.required ||
          (!items &&
              (points?[row.rank] ?? 0) < (points?[previous.rank] ?? 0)) ||
          (items &&
              (now.length != before.length ||
                  [for (var j = 0; j < now.length; j++) now[j] < before[j]]
                      .contains(true))) ||
          (cp != null &&
              (master.liveChallengePoints[row.rank] ?? 0) <
                  (master.liveChallengePoints[previous.rank] ?? 0))) {
        monotone = false;
      }
    }
    if (!monotone) add('rules', 'rank-monotonicity');
    if (!_integer(player.musicMemory['${ref.songId}'])) {
      add('player', 'mm.${ref.songId}');
    }
  }
  // Bound inversion and native integer settlement require a non-negative,
  // non-overflowing domain.
  if (event != null && boost != null) {
    if (event.effects.any((row) => row.perRank.any((v) => !_integer(v)))) {
      add('rules', 'event-bonus');
    }
    double top(Iterable<int> values) => (values.toList()..sort((a, b) => b - a))
        .take(5)
        .fold(0.0, (a, b) => a + b);
    final bonus =
        top([
          for (final m in box.members)
            memberEventPercent(event.effects, m, items ? 1 : 0),
        ]) +
        top([
          for (final s in box.snaps)
            snapEventPercent(event.effects, s, items ? 1 : 0),
        ]);
    final maxBase = items
        ? rewards.fold(0, (m, row) => math.max(m, row.count))
        : (points?.values ?? const <int>[]).fold(0, math.max);
    final rate = items ? boost.rewardRate : boost.eventPointRate;
    if (bonus > 1000000 ||
        (bonus.isFinite &&
            (BigInt.from(bonus.truncate()) + BigInt.from(10000)) *
                    BigInt.from(satI32(rate)) *
                    BigInt.from(maxBase) >
                BigInt.parse('7fffffffffffffff', radix: 16))) {
      add('rules', 'settlement-range');
    }
    if (cp != null) {
      final cpValue =
          master.liveChallengePoints.values.fold(0, math.max) *
          boost.eventPointRate;
      final payout =
          (maxBase * rate * 101).ceilToDouble() * (items ? rewards.length : 1);
      final sum =
          120.0 *
          (gekiso?.luckSamples ?? 1) *
          (payout * cp.denominator + cpValue * cp.numerator);
      // Leave one precision bit so dividing the integer order sum by 120
      // cannot merge adjacent sums.
      if (!_wholeDouble(cpValue) ||
          !sum.isFinite ||
          sum > 9007199254740991 / 2) {
        add('rules', 'cp-settlement-range');
      }
    }
  }
  for (final member in usable) {
    final gekisoEffects =
        master.gekisoSkills[member.card.gekisoSkillId]?.effects ??
        const <SkillEffectRow>[];
    if (gekiso != null) {
      if (member.card.gekisoSkillId != 0 &&
          !gekisoEffects.any(
            (r) => r.level == member.growth.gekisoSkillLevel,
          )) {
        add('skill', '${member.key}.gekiso');
      }
      checkGekisoEffects(
        gekisoEffects.where((r) => r.level == member.growth.gekisoSkillLevel),
        '${member.key}.gekiso',
      );
    }
    final effects = master.liveSkills[member.card.liveSkillId];
    if (member.card.liveSkillId != 0 &&
        !(effects?.any((row) => row.level == member.growth.liveSkillLevel) ??
            false)) {
      add('skill', member.key);
    }
    final leaders = master.leaderSkills[member.card.leaderSkillId];
    if (member.card.leaderSkillId != 0 &&
        !(leaders?.any((row) => row.level == member.leaderSkillLevel) ??
            false)) {
      add('skill', '${member.key}.leader');
    }
    for (final effect in (leaders ?? const <SkillEffectRow>[]).where(
      (row) => row.level == member.leaderSkillLevel,
    )) {
      if (!const {
            1000, 1001, 1002, 1003, 1500, 1501, 1502, 1503, //
          }.contains(effect.type) ||
          effect.value < 0 ||
          effect.targetIds.any((id) => !master.targets.containsKey(id))) {
        add('skill', '${member.key}.leader');
      }
      if (effect.conditionGroup > 0) {
        final sets = master.conditionSets[effect.conditionGroup];
        if (sets == null ||
            sets.isEmpty ||
            sets.expand((set) => set).any((id) {
              final row = master.conditions[id];
              return row == null ||
                  !const {0, 3000, 3001, 4012}.contains(row.type) ||
                  row.targetIds.any((t) => !master.targets.containsKey(t));
            })) {
          add('skill', '${member.key}.leader-condition');
        }
      }
      if (effect.cumulativeId > 0) {
        final row = master.cumulative[effect.cumulativeId];
        if (row == null ||
            row.type < 3000 ||
            row.type > 3005 ||
            row.targetIds.any((id) => !master.targets.containsKey(id))) {
          add('skill', '${member.key}.leader-cumulative');
        }
      }
    }
    for (final photo in <SnapState?>[
      null,
      if (!c.noSnaps)
        for (final s in box.snaps)
          if (!c.excludedSnaps.contains(s.key)) s,
    ]) {
      final unsupported = <String>[];
      final slotSkill = resolveSlotSkill(master, member, photo, unsupported);
      // The fast order scorer applies live Perfect conversion after the
      // Gekisou simulation: never report an unchanged JUST rate.
      if (gekiso != null &&
          (slotSkill.convert?.judgements.contains(6) ?? false)) {
        add('skill', '${member.key}:just-to-perfect');
      }
      for (final why in unsupported) {
        add(
          'skill',
          '${member.key}${photo != null ? '/${photo.key}' : ''}:$why',
        );
      }
      if (photo == null) continue;
      for (final (slot, id) in photo.card.supportSkillIds.indexed) {
        if (id != 0 &&
            !(master.supportSkills[id]?.any(
                  (row) => row.level == photo.skillLevels[slot],
                ) ??
                false)) {
          add('skill', '${photo.key}:$id');
        }
      }
      if (gekiso != null) {
        for (final (slot, id) in photo.card.gekisoSupportSkillIds.indexed) {
          final rows = [
            for (final row
                in master.gekisoSupportSkills[id]?.effects ??
                    const <SkillEffectRow>[])
              if (row.level == photo.gekisoSkillLevels[slot]) row,
          ];
          if (id != 0 && rows.isEmpty) add('skill', '${photo.key}.gekiso:$id');
          checkGekisoEffects(rows, '${photo.key}.gekiso:$id');
        }
      }
    }
  }
  for (final MapEntry(key: id, value: item) in master.bandItems.entries) {
    final level = player.bandItems['$id'];
    if (level == null || level == 0) continue;
    for (final effect in item.levels[level] ?? const <SkillEffectRow>[]) {
      if (effect.type < 1000 ||
          effect.type > 1003 ||
          effect.conditionGroup > 0 ||
          effect.cumulativeId > 0 ||
          effect.value < 0 ||
          effect.targetIds.any((t) => !master.targets.containsKey(t))) {
        add('skill', 'bi.$id');
      }
    }
  }
  return {for (final issue in issues) issue.key: issue}.values.toList();
}

void validatePtChart(EngineMaster master, SongRef ref, RuntimeChart source) {
  final judged = [
    for (final n in source.notes)
      if (n.judged) n,
  ];
  var ordered = true;
  for (var i = 0; i < judged.length; i++) {
    final n = judged[i];
    if (n.timeMs < 0 ||
        (i > 0 && n.timeMs < judged[i - 1].timeMs) ||
        !master.live.notePercent.containsKey(n.operateType) ||
        !master.live.timingTypes.contains(n.judgementType)) {
      ordered = false;
      break;
    }
  }
  if (source.durationMs <= 0 ||
      judged.isEmpty ||
      source.skillTimesMs.length != 5 ||
      source.skillTimesMs.any((t) => t < 0) ||
      !ordered ||
      !master.live.adjustment.isFinite ||
      master.live.adjustment <= 0 ||
      !master.live.judgePercent.containsKey(2)) {
    throw StateError('pt-chart-unsupported:${ref.key}');
  }
}
