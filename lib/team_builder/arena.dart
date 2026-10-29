/// Arena rules: the season timeline, one league per band and the regulation
/// that is in force in each period (`arena-tab.ts`, `arena.ts`).
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'catalog.dart';
import 'controller.dart';
import 'engine/num.dart';

class ArenaSeason {
  ArenaSeason(Doc row)
    : id = intOf(row['id']),
      startAt = numOf(row['startAt']).toInt(),
      endAt = numOf(row['endAt']).toInt();
  final int id;
  final int startAt;
  final int endAt;

  bool get active {
    final now = DateTime.now().millisecondsSinceEpoch;
    return startAt <= now && now < endAt;
  }
}

class ArenaLeague {
  ArenaLeague(Doc row)
    : id = intOf(row['id']),
      bandId = intOf(row['bandId']);
  final int id;
  final int bandId;
}

class ArenaRegulation {
  ArenaRegulation(Doc row)
    : id = intOf(row['id']),
      leagueId = intOf(row['leagueId']),
      musicType = intOf(row['musicType']),
      missions = [
        for (final value in (row['missions'] as List? ?? const []))
          if (value is num) value.toInt(),
      ],
      startAt = numOf(row['startAt']).toInt(),
      endAt = numOf(row['endAt']).toInt();
  final int id;
  final int leagueId;
  final int musicType;
  final List<int> missions;
  final int startAt;
  final int endAt;

  bool get active {
    final now = DateTime.now().millisecondsSinceEpoch;
    return startAt <= now && now < endAt;
  }
}

/// Everything the Arena panel needs, read straight from the merged document.
class ArenaRules {
  ArenaRules(Doc data)
    : seasons = [
        for (final row in dataRows(data['seasons'])) ArenaSeason(row),
      ]..sort((a, b) => a.startAt.compareTo(b.startAt)),
      leagues = [
        for (final row in dataRows(data['leagues'])) ArenaLeague(row),
      ]..sort((a, b) => a.bandId.compareTo(b.bandId)),
      regulations = [
        for (final row in dataRows(data['regulations']))
          ArenaRegulation(row),
      ]..sort((a, b) => a.startAt.compareTo(b.startAt));

  final List<ArenaSeason> seasons;
  final List<ArenaLeague> leagues;
  final List<ArenaRegulation> regulations;

  bool get isEmpty => leagues.isEmpty || regulations.isEmpty;

  ArenaSeason? get activeSeason {
    for (final season in seasons) {
      if (season.active) return season;
    }
    return seasons.isEmpty ? null : seasons.last;
  }

  List<ArenaRegulation> forLeague(int leagueId) => [
    for (final row in regulations)
      if (row.leagueId == leagueId) row,
  ];
}

class ArenaTab extends StatefulWidget {
  const ArenaTab({super.key, required this.controller, this.onSearch});
  final TeamBuilderController controller;

  /// Called after the rules and the song pool are written, so the host can
  /// switch to the Build tab.
  final VoidCallback? onSearch;

  @override
  State<ArenaTab> createState() => _ArenaTabState();
}

class _ArenaTabState extends State<ArenaTab> {
  int? _leagueId;

  TeamBuilderController get c => widget.controller;

  /// Songs of the league's band, which is what the website's Arena pool is
  /// (`arena-tab.ts` allowedSongIds).
  List<Map<String, Object?>> _pool(ArenaLeague league) => [
    for (final key in objectRow(c.catalog!.data['songs']).keys)
      if (int.tryParse(key) case final id?)
        if (c.catalog!.songBands(id).contains(league.bandId))
          {'songId': id, 'difficulty': 3},
  ];

  void _applyAndSearch(ArenaLeague league, ArenaRegulation? rule) {
    final pool = _pool(league);
    c.updateSettings({
      'goal': 'gekiso',
      'criterion': 'mean',
      'bands': [league.bandId],
      'songs': pool,
      if (rule != null)
        'songRules': {'musicType': rule.musicType, 'missions': rule.missions},
    });
    widget.onSearch?.call();
  }

  String _time(int millis) {
    final at = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }

  String _musicType(TeamCatalog catalog, int value) {
    if (value == 0) return c.tb('arena.original', 'Original song');
    if (value == 99) return c.tb('arena.any', 'Any attribute');
    return catalog.attributeName(value);
  }

  String _missions(List<int> missions) {
    const names = ['—', 'COMBO', 'LUCK', 'JUST'];
    return [
      for (final (index, value) in missions.indexed)
        '${c.tb('arena.range', 'Range {count}', {'count': index + 1})} '
            '${names[value.clamp(0, 3)]}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final catalog = c.catalog!;
    final theme = Theme.of(context);
    final arenaRow = objectRow(catalog.data['arena']);
    Object? serverRow = arenaRow[serverOf(catalog)];
    if (serverRow == null && arenaRow.isNotEmpty) {
      serverRow = arenaRow.values.first;
    }
    if (objectRow(serverRow).isEmpty) {
      return Center(
        child: Text(c.tb('arena.empty', 'No Arena schedule for this server.')),
      );
    }
    final rules = ArenaRules(objectRow(serverRow));
    final leagueId = _leagueId ?? (rules.leagues.isEmpty ? 0 : rules.leagues.first.id);
    final season = rules.activeSeason;
    final rows = rules.forLeague(leagueId);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.tb('arena.title', 'Arena'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  season == null
                      ? c.tb('arena.noSeason', 'No active season')
                      : c.tb('arena.season', 'Season {id} · {from} – {to}', {
                          'id': season.id,
                          'from': _time(season.startAt),
                          'to': _time(season.endAt),
                        }),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final league in rules.leagues)
              ChoiceChip(
                label: Text(catalog.bandName(league.bandId)),
                selected: league.id == leagueId,
                onSelected: (_) => setState(() => _leagueId = league.id),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Builder(
          builder: (context) {
            final league = rules.leagues
                .where((item) => item.id == leagueId)
                .firstOrNull;
            final current = rows.where((row) => row.active).firstOrNull ?? (rows.isEmpty ? null : rows.first);
            return Row(
              children: [
                FilledButton.icon(
                  onPressed: league == null
                      ? null
                      : () => _applyAndSearch(league, current),
                  icon: const Icon(Symbols.search_rounded),
                  label: Text(
                    c.tb('arena.search', 'Search with these rules'),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    c.tb('arena.pool', '{count} songs in this league', {
                      'count': league == null ? 0 : _pool(league).length,
                    }),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        for (final row in rows.take(40))
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              dense: true,
              leading: Icon(
                row.active
                    ? Symbols.play_circle_rounded
                    : Symbols.schedule_rounded,
                color: row.active ? theme.colorScheme.primary : null,
              ),
              title: Text(
                '${_time(row.startAt)} – ${_time(row.endAt)}'
                '${row.active ? ' · ${c.tb('arena.current', 'Now')}' : ''}',
              ),
              subtitle: Text(
                '${_musicType(catalog, row.musicType)} · ${_missions(row.missions)}',
              ),
              trailing: FilledButton.tonal(
                onPressed: () => c.updateSettings({
                  'songRules': {
                    'musicType': row.musicType,
                    'missions': row.missions,
                  },
                }),
                child: Text(c.tb('arena.apply', 'Apply')),
              ),
            ),
          ),
      ],
    );
  }
}

/// The server whose document this catalogue came from.
String serverOf(TeamCatalog catalog) => catalog.server ?? 'jp';
