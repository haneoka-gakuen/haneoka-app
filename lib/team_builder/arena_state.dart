import 'catalog.dart';
import 'engine/api.dart';
import 'engine/num.dart';
import 'settings.dart';

Doc arenaDefaults() => {
  'leagueId': 1,
  'automatic': true,
  'customized': false,
  'mode': 'shared',
  'rule': {
    'musicType': 99,
    'missions': [1, 1, 1],
  },
  'build': {'goal': 'gekiso'},
};

bool arenaReleased(Doc row, int now) {
  final value = row['publishedAt'] ?? row['releasedAt'];
  final time = value is List ? value.whereType<num>().firstOrNull : value;
  return time is! num || time <= now;
}

class ArenaState {
  ArenaState(this.catalog, this.server, this.draft, {int? now})
    : now = now ?? DateTime.now().millisecondsSinceEpoch;
  final TeamCatalog catalog;
  final String server;
  final Doc draft;
  final int now;
  Doc get data => objectRow(objectRow(catalog.data['arena'])[server]);
  int get leagueId => intOf(draft['leagueId'], 1);
  bool get automatic => draft['automatic'] != false;
  bool get shared => draft['mode'] != 'individual';
  List<Doc> get seasons => dataRows(data['seasons']);
  List<Doc> get leagues => dataRows(data['leagues']);
  List<Doc> get regulations => dataRows(data['regulations']);
  bool active(Doc row) =>
      numOf(row['startAt']) <= now && now < numOf(row['endAt']);
  Doc? get season => seasons.where(active).firstOrNull;
  Doc? get regulation {
    if (season == null) return null;
    final rows =
        regulations
            .where((row) => intOf(row['leagueId']) == leagueId && active(row))
            .toList()
          ..sort((a, b) => numOf(b['startAt']).compareTo(numOf(a['startAt'])));
    return rows.firstOrNull;
  }

  int get bandId => intOf(
    leagues.where((row) => intOf(row['id']) == leagueId).firstOrNull?['bandId'],
    leagueId,
  );
  Doc get rule {
    final source = automatic ? regulation : null;
    final rules = normalizeSongRules(
      source ?? draft['rule'] ?? arenaDefaults()['rule'],
    );
    return {'musicType': rules.musicType, 'missions': rules.missions};
  }

  Doc get goal => {
    ...rule,
    'bandId': bandId,
    'mode': shared ? 'shared' : 'individual',
    'server': server,
    'regulationId': automatic ? (regulation?['id']) : null,
  };
  List<int> get songIds => [
    for (final entry in objectRow(catalog.data['songs']).entries)
      if (int.tryParse(entry.key) case final id?)
        if (catalog.songBands(id).contains(bandId) &&
            catalog.available('songs', id) &&
            arenaReleased(objectRow(entry.value), now))
          id,
  ];
  List<SongRef> get charts => [
    for (final id in songIds)
      for (final row in catalog.difficultyRows(id))
        if (arenaReleased(row, now) && row['file'] is String)
          SongRef(id, intOf(row['difficulty'])),
  ];
  List<SongRef> get pool => [
    for (final id in songIds)
      if (charts.where((song) => song.songId == id).toList() case final rows
          when rows.isNotEmpty)
        rows.where((song) => song.difficulty == 3).firstOrNull ?? rows.last,
  ];
  BuildSettings get settings {
    final build = BuildSettings(objectRow(draft['build']));
    final allowed = charts.toSet();
    return build.copyWith({
      'goal': 'gekiso',
      'arena': goal,
      'bands': [bandId],
      'criterion': shared ? 'mean' : build.criterion,
      'gekisoPlacementMode': shared
          ? 'rank'
          : (build.opponentsMode ? 'opponents' : 'rank'),
      'songs': [
        for (final song in build.songs)
          if (allowed.contains(song)) song.toJson(),
      ],
    });
  }

  int? get nextAt {
    final times = <int>[
      for (final row in [
        ...seasons,
        ...regulations.where((row) => intOf(row['leagueId']) == leagueId),
      ]) ...[intOf(row['startAt']), intOf(row['endAt'])],
      for (final entry in objectRow(catalog.data['members']).entries)
        if (catalog.master.members[int.tryParse(entry.key)]?.bandId == bandId)
          ..._publication(objectRow(objectRow(entry.value)['catalogMetadata'])),
      for (final value in objectRow(catalog.data['snapshots']).values)
        ..._publication(objectRow(objectRow(value)['catalogMetadata'])),
      for (final value in objectRow(catalog.data['songs']).values) ...[
        ..._publication(objectRow(value)),
        for (final row in dataRows(objectRow(value)['difficulty']))
          ..._publication(row),
      ],
    ].where((time) => time > now).toList()..sort();
    return times.firstOrNull;
  }
}

List<int> _publication(Doc row) {
  final value = row['publishedAt'] ?? row['releasedAt'];
  final time = value is List ? value.whereType<num>().firstOrNull : value;
  return time is num ? [time.toInt()] : [];
}
