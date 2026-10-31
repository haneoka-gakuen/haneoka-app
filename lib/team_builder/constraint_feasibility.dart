/// Pre-submit check that a minimum event bonus can be reached at all.
library;

import 'engine/api.dart';
import 'engine/box.dart';
import 'engine/master.dart';
import 'engine/power.dart';

/// False means the floor may be reachable, or this request cannot be checked.
bool minimumEventBonusUnreachable(EngineMaster master, EngineRequest request) {
  final goal = request.goal;
  final constraints = request.constraints;
  final minimum = constraints.minBonusPercent;
  if (goal is! EventGoal ||
      minimum == null ||
      !minimum.isFinite ||
      minimum <= 0) {
    return false;
  }
  final plan = goal.rewardPlan;
  if (plan == null && goal.measure == 'challenge-points') return false;
  var metric = goal.measure;
  if (plan != null) {
    metric = 'points';
    final levels = plan['levels'];
    if (levels is List) {
      search:
      for (final level in levels) {
        if (level is! List) continue;
        for (final term in level) {
          final value = term is Map ? term['metric'] : null;
          if (value is String && value != 'challenge-points') {
            metric = value;
            break search;
          }
        }
      }
    }
  }
  final effects = goal.eventEffects == null
      ? master.events[goal.eventId]?.effects
      : [for (final row in goal.eventEffects!) EventEffectRow(row)];
  if (effects == null) return false;
  final box = resolveBox(
    master,
    request.members,
    request.snaps,
    request.unknownPolicy,
  );
  if (box.unknown.isNotEmpty) return false;
  final excludedMembers = constraints.excludedMembers.toSet();
  final excludedSnaps = constraints.excludedSnaps.toSet();
  final availableMembers = [
    for (final member in box.members)
      if (!excludedMembers.contains(member.key)) member,
  ];
  final availableSnaps = [
    for (final snap in box.snaps)
      if (!excludedSnaps.contains(snap.key)) snap,
  ];
  final memberByKey = {
    for (final member in availableMembers) member.key: member,
  };
  final snapByKey = {for (final snap in availableSnaps) snap.key: snap};
  if (memberByKey.length != availableMembers.length ||
      snapByKey.length != availableSnaps.length) {
    return false;
  }

  final boundMembers = [for (final binding in constraints.bindings) binding.$1];
  if (boundMembers.toSet().length != boundMembers.length) return false;
  final requiredMembers = {
    ...constraints.requiredMembers,
    ...boundMembers,
    ?constraints.leader,
  };
  if (requiredMembers.length > 5 ||
      requiredMembers.any((key) => !memberByKey.containsKey(key))) {
    return false;
  }
  final fixedMembers = [for (final key in requiredMembers) memberByKey[key]!];
  final fixedCharacters = {
    for (final member in fixedMembers) member.card.characterId,
  };
  if (fixedCharacters.length != fixedMembers.length) return false;
  final bonusType = metric == 'items' ? 1 : 0;
  int memberBonus(MemberState member) {
    final value = memberEventPercent(effects, member, bonusType);
    return value > 0 ? value : 0;
  }

  final bestByCharacter = <int, int>{};
  for (final member in availableMembers) {
    final character = member.card.characterId;
    if (fixedCharacters.contains(character)) continue;
    final bonus = memberBonus(member);
    final best = bestByCharacter[character] ?? 0;
    bestByCharacter[character] = bonus > best ? bonus : best;
  }
  final remaining = 5 - fixedMembers.length;
  if (bestByCharacter.length < remaining) return false;
  final others = bestByCharacter.values.toList()..sort((a, b) => b - a);
  final memberUpper =
      fixedMembers.fold<int>(0, (sum, member) => sum + memberBonus(member)) +
      others.take(remaining).fold<int>(0, (sum, bonus) => sum + bonus);

  final boundSnaps = [
    for (final binding in constraints.bindings)
      if (binding.$2 != null) binding.$2!,
  ];
  if (boundSnaps.toSet().length != boundSnaps.length) return false;
  final requiredSnaps = {...constraints.requiredSnaps, ...boundSnaps};
  final emptySlots = constraints.bindings.length - boundSnaps.length;
  if ((constraints.noSnaps && requiredSnaps.isNotEmpty) ||
      requiredSnaps.length > 5 - emptySlots ||
      requiredSnaps.any((key) => !snapByKey.containsKey(key))) {
    return false;
  }
  var snapUpper = 0;
  if (!constraints.noSnaps) {
    int snapBonus(SnapState snap) {
      final value = snapEventPercent(effects, snap, bonusType);
      return value > 0 ? value : 0;
    }

    final rest = [
      for (final snap in availableSnaps)
        if (!requiredSnaps.contains(snap.key)) snapBonus(snap),
    ]..sort((a, b) => b - a);
    snapUpper =
        requiredSnaps.fold<int>(
          0,
          (sum, key) => sum + snapBonus(snapByKey[key]!),
        ) +
        rest
            .take(5 - emptySlots - requiredSnaps.length)
            .fold<int>(0, (sum, bonus) => sum + bonus);
  }
  return memberUpper + snapUpper < (minimum * 100 + 0.5).floor();
}
