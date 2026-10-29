import 'package:flutter/material.dart';

import '../catalog/browse.dart';
import '../catalog/catalog_screen.dart';
import '../catalog/profiles.dart';
import '../catalog/sort_control.dart';
import 'catalog.dart';
import 'engine/api.dart';
import 'engine/num.dart';

enum TeamResource { members, snaps, songs }

class TeamResourceSort {
  const TeamResourceSort({this.field = 'release', this.descending = true});
  final String field;
  final bool descending;
}

const songSortFields = <(String, String)>[
  ('order', 'common.layout.order'),
  ('id', 'common.fields.id'),
  ('title', 'common.fields.title'),
  ('musicType', 'catalog.songs.fields.musicType'),
  ('band', 'catalog.fields.band'),
  ('level', 'common.fields.level'),
  ('time', 'common.fields.time'),
  ('score', 'catalog.analysis.fields.metaScoreFactor'),
  ('eff', 'catalog.analysis.fields.eff'),
  ('bpm', 'catalog.analysis.fields.bpm'),
  ('n', 'catalog.analysis.fields.n'),
  ('nps', 'catalog.analysis.fields.nps'),
  ('sr', 'catalog.analysis.fields.sr'),
  ('category', 'common.fields.category'),
  ('composer', 'catalog.songs.fields.composer'),
  ('lyrics', 'catalog.songs.fields.lyrics'),
  ('arrangement', 'catalog.songs.fields.arrangement'),
  ('release', 'catalog.fields.release'),
];
const chartMetricSortFields = {'time', 'score', 'eff', 'bpm', 'n', 'nps', 'sr'};

extension TeamCatalogSorting on TeamCatalog {
  CatalogKit cardSortKit(bool members) => CatalogKit(
    catalogProfiles.firstWhere(
      (profile) => profile.resource == (members ? 'cards' : 'support-cards'),
    ),
    t,
    state.apiFor(server ?? state.server),
    visuals,
  );
  Doc sortableCard(bool members, int id) {
    final row = card(members, id),
        meta = objectRow(card(members, id)['catalogMetadata']);
    return {
      ...row,
      'cardId': id,
      'supportCardId': id,
      'prefix': row['name'],
      'characterIds': characterIds(members, id),
      'cardType': attribute(members, id),
      'stat': row['statMax'],
      'resolvedSkills': meta['resolvedSkills'],
      'releasedAt': meta['releasedAt'],
    };
  }

  List<int> sortedCards(bool members, Iterable<int> ids) {
    final preference =
        resourceSort[members ? TeamResource.members : TeamResource.snaps] ??
        const TeamResourceSort();
    final sort = cardSortKit(members).sorts
        .firstWhere((sort) => sort.key == preference.field);
    final rows = {for (final id in ids) id: sortableCard(members, id)},
        values = {
          for (final id in ids) id: sort.value(sortableCard(members, id)),
        };
    return ids.toList()..sort(
      (a, b) => compareEntries(
        rows[a]!,
        rows[b]!,
        sort,
        values[a],
        values[b],
        (row) => '${row['id']}',
        preference.descending,
      ),
    );
  }

  List<SongRef> sortedCharts(
    Iterable<SongRef> refs, {
    Doc Function(int)? view,
  }) {
    final preference =
        resourceSort[TeamResource.songs] ?? const TeamResourceSort();
    Object? value(SongRef ref) {
      final row = view?.call(ref.songId) ?? displaySong(ref.songId),
          meta = chartMetadata(ref);
      return switch (preference.field) {
        'id' => '${ref.songId}',
        'title' => songTitle(ref.songId),
        'band' => songPresentation.artist(row),
        'release' => _release(row),
        'order' =>
          row['displayOrder'] ?? row['order'] ?? row['sortOrder'] ?? ref.songId,
        'musicType' => row['musicType'],
        'category' => (row['musicCategories'] as List?)?.firstOrNull ?? 99,
        'composer' => text(row['composer']),
        'lyrics' => text(row['lyricist']),
        'arrangement' => text(row['arranger']),
        'level' =>
          difficultyRow(ref.songId, ref.difficulty)?['sortLevel'] ??
              difficultyRow(ref.songId, ref.difficulty)?['displayLevel'] ??
              difficultyRow(ref.songId, ref.difficulty)?['playLevel'] ??
              double.nan,
        'bpm' =>
          meta?['firstBpm'] ?? meta?['minBpm'] ?? meta?['maxBpm'] ?? double.nan,
        'n' =>
          meta?['n'] ??
              meta?['noteCount'] ??
              meta?['canonicalNoteCount'] ??
              double.nan,
        final key => meta?[key] ?? double.nan,
      };
    }

    final sort = SortSpec(
      preference.field,
      '',
      (_) => null,
      missingLast:
          preference.field == 'level' ||
          chartMetricSortFields.contains(preference.field),
    );
    final values = {for (final ref in refs) ref: value(ref)};
    return refs.toList()..sort(
      (a, b) => compareEntries(
        {'id': a.key},
        {'id': b.key},
        sort,
        values[a],
        values[b],
        (row) => '${row['id']}',
        preference.descending,
      ),
    );
  }
}

num _release(Doc row) {
  final value =
      row['releasedAt'] ??
      row['publishedAt'] ??
      row['publicStartAt'] ??
      row['startAt'];
  return value is List
      ? value.whereType<num>().where((v) => v > 0).firstOrNull ?? 0
      : value is num
      ? value
      : 0;
}

class TeamResourceSortControl extends StatelessWidget {
  const TeamResourceSortControl({
    super.key,
    required this.catalog,
    required this.resource,
    this.onChanged,
  });
  final TeamCatalog catalog;
  final TeamResource resource;
  final VoidCallback? onChanged;
  @override
  Widget build(BuildContext context) {
    final current = catalog.resourceSort[resource] ?? const TeamResourceSort();
    final options = resource == TeamResource.songs
        ? [for (final (key, label) in songSortFields) (key, catalog.t(label))]
        : [
            for (final sort
                in catalog.cardSortKit(resource == TeamResource.members).sorts)
              (sort.key, sort.label),
          ];
    void change(TeamResourceSort value) {
      catalog.resourceSort[resource] = value;
      catalog.sortChanged();
      onChanged?.call();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(catalog.t('common.actions.sort')),
          const SizedBox(height: 8),
          CatalogSortControl(
            options: options,
            value: current.field,
            descending: current.descending,
            onSort: (field) => change(
              TeamResourceSort(field: field, descending: current.descending),
            ),
            onOrder: () => change(
              TeamResourceSort(
                field: current.field,
                descending: !current.descending,
              ),
            ),
          ),
          if (resource == TeamResource.songs &&
              chartMetricSortFields.contains(current.field))
            SizedBox(
              height: 48,
              child: catalog.metricsError != null
                  ? Row(
                      children: [
                        Expanded(
                          child: Text(catalog.t('common.states.unavailable')),
                        ),
                        IconButton(
                          tooltip: catalog.t('common.actions.retry'),
                          onPressed: catalog.loadChartMetadata,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    )
                  : !catalog.metricsLoaded
                  ? const Center(child: LinearProgressIndicator())
                  : const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }
}
