import 'dart:convert';

import 'engine/master.dart';
import 'engine/num.dart';

Doc emptyManualEvent() => {
  'templateId': null,
  'attributes': null,
  'targetKind': 'band',
  'targets': [],
  'members': [],
  'snaps': [],
};

Doc _effect(EventEffectRow row) => {
  'resourceType': row.resourceType,
  'characterId': row.characterId,
  'bandId': row.bandId,
  'cardType': row.cardType,
  'tagId': row.tagId,
  'memberCardId': row.memberCardId,
  'supportCardId': row.supportCardId,
  'bonusType': row.bonusType,
  'perRank': [...row.perRank],
};
Doc _clear(Doc row) => {
  ...row,
  'characterId': 0,
  'bandId': 0,
  'cardType': 0,
  'tagId': 0,
  'memberCardId': 0,
  'supportCardId': 0,
};

class BonusTier {
  BonusTier(List<Doc> rows)
    : effects =
          {
            ...{for (final row in rows) jsonEncode(row): row},
          }.values.toList()..sort(
            (a, b) => intOf(a['resourceType']) - intOf(b['resourceType']) == 0
                ? intOf(a['bonusType']) - intOf(b['bonusType'])
                : intOf(a['resourceType']) - intOf(b['resourceType']),
          );
  final List<Doc> effects;
  String get key => jsonEncode([
    for (final row in effects) [row['bonusType'], row['perRank']],
  ]);
  String get label {
    final row =
        effects.where((row) => row['bonusType'] != 2).firstOrNull ??
        effects.first;
    final values = intListOf(row['perRank'])..sort();
    String percent(int value) =>
        (value / 100).toString().replaceFirst(RegExp(r'\.0$'), '');
    return '+${percent(values.first)}${values.first == values.last ? '' : '–${percent(values.last)}'}%';
  }
}

class ManualEventTemplate {
  ManualEventTemplate(
    this.event,
    this.attribute,
    this.target,
    this.members,
    this.snaps,
  );
  final GameEvent event;
  final List<Doc> attribute, target;
  final List<BonusTier> members, snaps;

  static ManualEventTemplate? read(GameEvent event, EngineMaster master) {
    if (event.livePoints.isEmpty ||
        event.liveRewards.isEmpty ||
        event.itemId == 0 ||
        event.effects.isEmpty) {
      return null;
    }
    final ranks = {
      master.params.skipRank,
      for (final rows in master.scoreRanks.values)
        for (final row in rows) row.rank,
    };
    if (ranks.any(
      (rank) =>
          !event.livePoints.containsKey(rank) ||
          !event.liveRewards.any(
            (row) => row.scoreRank == rank && row.resourceId == event.itemId,
          ),
    )) {
      return null;
    }
    if (event.livePoints.values.any((value) => value < 0) ||
        event.liveRewards.any(
          (row) =>
              row.count < 0 || row.probability < 0 || row.probability > 10000,
        )) {
      return null;
    }
    final groups = <String, Map<int, List<Doc>>>{
      for (final name in ['attribute', 'target', 'members', 'snaps']) name: {},
    };
    for (final row in event.effects) {
      if (![2, 3].contains(row.resourceType) ||
          ![0, 1, 2].contains(row.bonusType) ||
          row.tagId != 0 ||
          row.perRank.length != 5 ||
          row.perRank.any((value) => value < 0)) {
        return null;
      }
      if ([
                row.cardType,
                row.bandId,
                row.characterId,
                row.memberCardId,
                row.supportCardId,
              ].where((id) => id != 0).length !=
              1 ||
          row.memberCardId != 0 && row.resourceType != 2 ||
          row.supportCardId != 0 && row.resourceType != 3) {
        return null;
      }
      final category = row.memberCardId != 0
          ? 'members'
          : row.supportCardId != 0
          ? 'snaps'
          : row.cardType != 0
          ? 'attribute'
          : 'target';
      final id = row.memberCardId != 0
          ? row.memberCardId
          : row.supportCardId != 0
          ? row.supportCardId
          : row.cardType != 0
          ? row.cardType
          : row.bandId != 0
          ? row.bandId
          : -row.characterId;
      (groups[category]![id] ??= []).add(_clear(_effect(row)));
    }
    List<BonusTier> profiles(String category) => {
      for (final rows in groups[category]!.values)
        jsonEncode(BonusTier(rows).effects): BonusTier(rows),
    }.values.toList();
    final attributes = profiles('attribute'), targets = profiles('target');
    if (attributes.length != 1 || targets.length != 1) return null;
    return ManualEventTemplate(
      event,
      attributes.single.effects,
      targets.single.effects,
      profiles('members'),
      profiles('snaps'),
    );
  }
}

({List<Doc>? effects, String? issue}) resolveManualEvent(
  EngineMaster master,
  Doc draft,
) {
  final event = master.events[intOf(draft['templateId'])];
  final template = event == null
      ? null
      : ManualEventTemplate.read(event, master);
  if (template == null) return (effects: null, issue: 'rules');
  final attributes = draft['attributes'] is List
      ? intListOf(draft['attributes'])
      : null;
  if (attributes == null ||
      attributes.any((id) => ![1, 2, 3, 4, 5].contains(id))) {
    return (effects: null, issue: 'attribute');
  }
  final kind = draft['targetKind'], targets = intListOf(draft['targets']);
  if (!['none', 'band', 'character'].contains(kind) ||
      kind != 'none' &&
          (targets.isEmpty ||
              targets.any(
                (id) => kind == 'character'
                    ? !master.characters.containsKey(id)
                    : !master.members.values.any((row) => row.bandId == id),
              ))) {
    return (effects: null, issue: 'targets');
  }
  final effects = <Doc>[
    for (final id in attributes.toSet())
      for (final row in template.attribute) {...row, 'cardType': id},
    if (kind != 'none')
      for (final id in targets.toSet())
        for (final row in template.target)
          {...row, kind == 'band' ? 'bandId' : 'characterId': id},
  ];
  for (final key in ['members', 'snaps']) {
    final seen = <int>{};
    for (final row in dataRows(draft[key])) {
      final id = intOf(row['cardId']);
      final profile = (key == 'members' ? template.members : template.snaps)
          .where((tier) => tier.key == row['tier'])
          .firstOrNull;
      if (profile == null ||
          !(key == 'members'
              ? master.members.containsKey(id)
              : master.snaps.containsKey(id)) ||
          !seen.add(id)) {
        return (effects: null, issue: 'cards');
      }
      effects.addAll([
        for (final effect in profile.effects)
          {...effect, key == 'members' ? 'memberCardId' : 'supportCardId': id},
      ]);
    }
  }
  return (effects: effects, issue: null);
}
