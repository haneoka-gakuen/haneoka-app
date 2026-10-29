/// The team builder's release document: every official server's
/// `/api/v1/team-builder/{server}` merged into one, as the website's
/// `team-builder/data/cross-server.ts` does, so a reader on one server can
/// plan with cards the other server already has.
library;

import 'dart:convert';

import '../core/api.dart';
import 'engine/num.dart';

const _collections = [
  'members',
  'snapshots',
  'characters',
  'bands',
  'bandItems',
  'songs',
  'events',
];
const _growth = [
  'memberCardLevels',
  'memberCardAwake',
  'memberCardRanks',
  'supportCardLevels',
  'supportCardRanks',
];
const officialServers = ['jp', 'intl'];

Object? _clone(Object? value) => switch (value) {
  final Map<String, Object?> map => {
    for (final entry in map.entries) entry.key: _clone(entry.value),
  },
  final Map map => {
    for (final entry in map.entries) '${entry.key}': _clone(entry.value),
  },
  final List list => [for (final item in list) _clone(item)],
  _ => value,
};

/// Reads every official server's document and merges them, the reader's
/// server first. A missing peer only drops its cards.
Future<Doc> loadTeamData(String server) async {
  final servers = [server, ...officialServers.where((peer) => peer != server)];
  final results = await Future.wait([
    for (final peer in servers)
      _fetch(peer).then<Doc?>((v) => v, onError: (Object _) => null),
  ]);
  final primary = results.first;
  if (primary == null) {
    // The reader's own server failed: surface its error.
    await _fetch(server);
  }
  return mergeTeamData(
    [...results.whereType<Doc>()],
    [
      for (final (index, peer) in servers.indexed)
        if (results[index] == null) peer,
    ],
  );
}

final _apis = <String, HaneokaApi>{};

Future<Doc> _fetch(String server) async {
  final api = _apis[server] ??= HaneokaApi(server: server);
  final release = await api.release();
  final data = objectRow(
    await api.json(
      '/api/v1/team-builder/${Uri.encodeComponent(server)}?projection=4'
      '${release == 'offline' ? '' : '&release=${Uri.encodeComponent(release)}'}',
    ),
  );
  if (data['schema'] != 'haneoka-team-builder-data-v1' ||
      objectRow(data['identity'])['server'] != server) {
    throw const FormatException('team-data-identity');
  }
  return data;
}

/// Selects content by original ID, keeping every foreign auxiliary
/// reference in its own namespace (`mergeTeamBuilderData`).
Doc mergeTeamData(List<Doc> sources, [List<String> unavailable = const []]) {
  final result = _clone(sources.first) as Doc;
  final identities = <String, Object?>{};
  result['arena'] = {
    for (final source in sources) ...objectRow(source['arena']),
  };
  final owners = <String, Map<String, String>>{};
  final availability = <String, Map<String, List<String>>>{};
  final challengeMusics = <Doc>[];
  result['crossServer'] = {
    'identities': identities,
    'owners': owners,
    'availability': availability,
    'unavailableServers': unavailable,
    'challengeMusics': challengeMusics,
  };
  for (final collection in _collections) {
    owners[collection] = {};
    availability[collection] = {};
    result[collection] = <String, Object?>{};
  }

  // Stay inside int32: native skill readers validate their reference IDs.
  final used = <int>{};
  void remember(Object? value) {
    if (value is num && value == value.roundToDouble()) {
      if (value > 0 && value <= 0x7fffffff) used.add(value.toInt());
    } else if (value is Map) {
      for (final entry in value.entries) {
        remember(num.tryParse('${entry.key}'));
        remember(entry.value);
      }
    } else if (value is List) {
      value.forEach(remember);
    }
  }

  sources.forEach(remember);
  var next = 1;
  int allocate() {
    while (used.contains(next)) {
      next++;
    }
    if (next > 0x7fffffff) throw RangeError('team-data-namespace');
    used.add(next);
    return next++;
  }

  final challengeIds = <int>{};
  for (var index = 0; index < sources.length; index++) {
    final source = _clone(sources[index]) as Doc;
    final identity = objectRow(source['identity']);
    final server = '${identity['server']}';
    identities[server] = identity;
    Object? pinAssets(Object? value) {
      if (value is String && value.startsWith('/assets/$server/')) {
        final uri = Uri.parse(value);
        return uri
            .replace(
              queryParameters: {
                ...uri.queryParameters,
                'release': '${identity['releaseId']}',
              },
            )
            .toString();
      }
      if (value is List) return [for (final item in value) pinAssets(item)];
      if (value is Map) {
        return {
          for (final entry in value.entries)
            '${entry.key}': pinAssets(entry.value),
        };
      }
      return value;
    }

    final references = <String, int>{};
    Object? reference(String namespace, Object? value) {
      final id = num.tryParse('$value');
      if (id == null || id != id.roundToDouble() || id <= 0 || index == 0) {
        return value;
      }
      return references['$namespace:${id.toInt()}'] ??= allocate();
    }

    Doc rewrite(
      Object? value,
      Map<String, String> fields, [
      Map<String, String> arrays = const {},
    ]) {
      final row = nativeRow(value);
      for (final entry in fields.entries) {
        if (row[entry.key] != null) {
          row[entry.key] = reference(entry.value, row[entry.key]);
        }
      }
      for (final entry in arrays.entries) {
        if (row[entry.key] case final List list) {
          row[entry.key] = [for (final id in list) reference(entry.value, id)];
        }
      }
      return row;
    }

    List<Doc> effects(Object? value, String family) => [
      for (final row in dataRows(value))
        rewrite(
          row,
          {
            'id': 'effect:$family',
            'effectId': 'effect:$family',
            'liveSkillID': 'skill:live',
            'liveSkillId': 'skill:live',
            'leaderSkillID': 'skill:leader',
            'leaderSkillId': 'skill:leader',
            'supportSkillID': 'skill:support',
            'supportSkillId': 'skill:support',
            'gekisouSkillID': 'skill:gekiso',
            'gekisouSkillId': 'skill:gekiso',
            'gekisouSupportSkillID': 'skill:gekisoSupport',
            'gekisouSupportSkillId': 'skill:gekisoSupport',
            'skillConditionGroup': 'condition-group',
            'conditionGroup': 'condition-group',
            'skillTriggerConditionGroup': 'condition-group',
            'triggerConditionGroup': 'condition-group',
            'skillReleaseConditionGroup': 'condition-group',
            'releaseConditionGroup': 'condition-group',
            'effectExecuteLimitResetConditionGroup': 'condition-group',
            'executeLimitResetConditionGroup': 'condition-group',
            'skillCumulativeConditionID': 'cumulative',
            'cumulativeConditionId': 'cumulative',
          },
          {'skillTargetIDs': 'target', 'targetIds': 'target'},
        ),
    ];

    final progression = objectRow(source['progression']);
    final limits = dataRows(progression['memberCardLevelLimits']);
    for (final card in objectRow(source['members']).values) {
      if (card is! Map) continue;
      card['levelLimits'] = {
        for (final row in limits)
          if (numOf(row['rarity']) == numOf(card['rarity']))
            '${intOf(row['awakeCount'])}': intOf(row['limitLevel']),
      };
      card['levelGroup'] = reference('memberCardLevels', card['levelGroup']);
      card['trainingGroup'] = reference(
        'memberCardAwake',
        card['trainingGroup'],
      );
      card['awakeningGroup'] = reference(
        'memberCardRanks',
        card['awakeningGroup'],
      );
      card['leaderSkillId'] = reference('skill:leader', card['leaderSkillId']);
      card['liveSkillId'] = reference('skill:live', card['liveSkillId']);
      card['gekisoSkillId'] = reference('skill:gekiso', card['gekisoSkillId']);
    }
    for (final card in objectRow(source['snapshots']).values) {
      if (card is! Map) continue;
      card['levelGroup'] = reference('supportCardLevels', card['levelGroup']);
      card['awakeningGroup'] = reference(
        'supportCardRanks',
        card['awakeningGroup'],
      );
      card['supportSkillIds'] = [
        for (final id in card['supportSkillIds'] as List? ?? const [])
          reference('skill:support', id),
      ];
      card['gekisoSupportSkillIds'] = [
        for (final id in card['gekisoSupportSkillIds'] as List? ?? const [])
          reference('skill:gekisoSupport', id),
      ];
    }
    final resultProgression = result['progression'] = objectRow(
      result['progression'],
    );
    for (final table in _growth) {
      final rows = [
        for (final row in dataRows(progression[table]))
          rewrite(row, {'group': table}),
      ];
      resultProgression[table] = index == 0
          ? rows
          : [...dataRows(resultProgression[table]), ...rows];
    }
    final resultSkills = result['skills'] = objectRow(result['skills']);
    for (final family in objectRow(source['skills']).entries) {
      final mapped = <String, Object?>{
        for (final entry in objectRow(family.value).entries)
          '${reference('skill:${family.key}', entry.key)}': pinAssets({
            ...objectRow(entry.value),
            'id': reference(
              'skill:${family.key}',
              objectRow(entry.value)['id'] ?? entry.key,
            ),
            'effects': effects(objectRow(entry.value)['effects'], family.key),
          }),
      };
      resultSkills[family.key] = index == 0
          ? mapped
          : {...objectRow(resultSkills[family.key]), ...mapped};
    }
    const referenceTables = {
      'targets': ({'id': 'target'}, <String, String>{}),
      'conditions': ({'id': 'condition'}, {'conditionTargetIDs': 'target'}),
      'conditionSets': (
        {'id': 'condition-set', 'group': 'condition-group'},
        {'conditionIds': 'condition'},
      ),
      'cumulativeConditions': (
        {'id': 'cumulative'},
        {'conditionTargetIDs': 'target'},
      ),
    };
    final sourceReference = objectRow(source['skillReference']);
    final resultReference = result['skillReference'] = objectRow(
      result['skillReference'],
    );
    for (final entry in referenceTables.entries) {
      final rows = [
        for (final row in dataRows(sourceReference[entry.key]))
          rewrite(row, entry.value.$1, entry.value.$2),
      ];
      resultReference[entry.key] = index == 0
          ? rows
          : [...dataRows(resultReference[entry.key]), ...rows];
    }
    for (final item in objectRow(source['bandItems']).values) {
      if (item is Map) item['effects'] = effects(item['effects'], 'band-item');
    }
    for (final song in objectRow(source['songs']).values) {
      if (song is Map) {
        song['liveScoreRankGroup'] = reference(
          'score-rank',
          song['liveScoreRankGroup'],
        );
      }
    }
    final scoreRanks = [
      for (final row in dataRows(objectRow(source['liveTools'])['scoreRanks']))
        rewrite(row, {'group': 'score-rank'}),
    ];
    final resultLiveTools = result['liveTools'] = objectRow(
      result['liveTools'],
    );
    resultLiveTools['scoreRanks'] = index == 0
        ? scoreRanks
        : [...dataRows(resultLiveTools['scoreRanks']), ...scoreRanks];

    final eventRules = objectRow(source['eventRules']);
    for (final event in objectRow(source['events']).values) {
      if (event is! Map) continue;
      final tables = {...objectRow(event['tables'])};
      for (final rule in eventRules.entries) {
        if (rule.value is List && !tables.containsKey(rule.key)) {
          tables[rule.key] = [
            for (final row in (rule.value as List).map(nativeRow))
              if (row['eventId'] == null ||
                  row['eventId'] == 0 ||
                  numOf(row['eventId']) == numOf(event['id']))
                row,
          ];
        }
      }
      event['tables'] = tables;
    }
    // URLs are pinned to the selected row's source, including icons and chart files.
    for (final collection in _collections) {
      final target = result[collection] as Map<String, Object?>;
      for (final entry in objectRow(source[collection]).entries) {
        (availability[collection]![entry.key] ??= []).add(server);
        if (target.containsKey(entry.key)) continue;
        target[entry.key] = pinAssets(entry.value);
        owners[collection]![entry.key] = server;
      }
    }
    for (final row in dataRows(
      objectRow(source['challengeMusicTable'])['rows'],
    )) {
      final id = intOf(row['id']);
      if (owners['events']!['${intOf(row['eventId'])}'] != server ||
          !challengeIds.add(id)) {
        continue;
      }
      challengeMusics.add(row);
    }
  }
  return result;
}

/// A deep copy safe to send to another isolate as JSON text.
String encodeTeamData(Doc data) => jsonEncode(data);

/// Display metadata from each core document's exact release. The calculation
/// input remains the original slim data; the shared document cache serves
/// these same collection URLs to catalog pages and the chooser.
Future<Map<int, Doc>> loadTeamSongVisuals(
  Doc data,
  HaneokaApi Function(String) apiFor,
) async {
  final cross = objectRow(data['crossServer']);
  final primary = objectRow(data['identity']);
  final identities = objectRow(cross['identities']);
  final sourceIdentities = identities.isEmpty
      ? <String, Object?>{'${primary['server']}': primary}
      : identities;
  final documents = await Future.wait([
    for (final entry in sourceIdentities.entries)
      () async {
        final release = '${objectRow(entry.value)['releaseId'] ?? ''}';
        if (release.isEmpty) return (entry.key, <String, Object?>{});
        try {
          final value = await apiFor(entry.key).json(
            '/api/v1/servers/${Uri.encodeComponent(entry.key)}/songs?release=${Uri.encodeQueryComponent(release)}',
          );
          final document = objectRow(value);
          return (entry.key, objectRow(document['items'] ?? document));
        } catch (_) {
          return (entry.key, <String, Object?>{});
        }
      }(),
  ]);
  final byServer = {for (final (server, songs) in documents) server: songs};
  final owners = objectRow(objectRow(cross['owners'])['songs']);
  return {
    for (final key in objectRow(data['songs']).keys)
      if (int.tryParse(key) case final id?)
        if (objectRow(byServer['${owners[key] ?? primary['server']}'])[key]
            case final Map song)
          id: song.cast<String, Object?>(),
  };
}
