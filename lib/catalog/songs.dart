import '../core/site_date.dart';
import '../core/catalog_source.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';


import '../core/api.dart';
import '../core/app_state.dart';
import '../core/audio.dart';
import '../core/i18n.dart';
import '../core/provider_api.dart';
import '../playlists/song_performer.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/tile.dart';
import 'browse.dart';
import 'catalog_query.dart';
import 'cross_server.dart';
import 'visuals.dart';
import 'song_presentation.dart';

/// The song catalogue (`catalog-screen` with the song presentation): jacket
/// tiles with the live attribute and genre on the artwork, band emblems
/// before the artist, a play button, and Play all in the bar.
class SongsScreen extends StatefulWidget {
  const SongsScreen({
    super.key,
    this.onOpen,
    this.api,
    this.title,
    this.extraActions = const [],
  });

  /// Opens a song's page.
  final void Function(BuildContext context, Entry song)? onOpen;

  /// Another game's songs (`origin: "bestdori"` / `"sekai"`); this
  /// release's and the other's merged when null.
  final HaneokaApi? api;
  final String? title;
  final List<BarAction> extraActions;

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  Future<(List<Entry>, CatalogVisuals, PerformerRegistry?)>? _data;

  /// Each server's `song-meta`, for the chart metric sorts.
  final _meta = <String, Map>{};
  List<Entry>? _sorted;
  List<Entry>? _source;
  int _metaSeen = 0;
  Object? _dataKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = CatalogSourceScope.keyOf(context);
    if (_dataKey != key) {
      _dataKey = key;
      _data = _load();
      _loadMeta();
    }
  }

  Future<void> _loadMeta() async {
    final apis = widget.api == null
        ? CatalogSourceScope.apisOf(context)
        : {widget.api!.server: widget.api!};
    await Future.wait([
      for (final MapEntry(key: server, value: api) in apis.entries)
        api.catalog('song-meta').then((value) {
          if (value is Map && mounted) setState(() => _meta[server] = value);
        }, onError: (_) {}),
    ]);
  }

  /// `songMetaValue`: a chart metric of the song's Expert chart.
  double _metric(Entry song, String key, String server) {
    final rows = song['difficulty'] as List? ?? const [];
    const names = ['easy', 'normal', 'hard', 'expert', 'special'];
    final index = rows.indexed
        .where(
          (row) =>
              row.$2 is Map &&
              ((row.$2 as Map)['difficulty'] == 3 ||
                  (row.$2 as Map)['difficulty'] == names[3]),
        )
        .firstOrNull
        ?.$1;
    final meta = _meta[song[serverKey] ?? server]?['${song['musicId']}'];
    final difficulty = meta is Map && index != null ? meta['$index'] : null;
    final chart = difficulty is Map ? difficulty['chart'] : null;
    if (chart is! Map) return double.nan;
    final value = switch (key) {
      'bpm' => chart['firstBpm'] ?? chart['minBpm'] ?? chart['maxBpm'],
      'n' => chart['n'] ?? chart['noteCount'] ?? chart['canonicalNoteCount'],
      _ => chart[key],
    };
    return value is num ? value.toDouble() : double.nan;
  }

  Future<(List<Entry>, CatalogVisuals, PerformerRegistry?)> _load() async {
    final scopedApi = CatalogSourceScope.apiOf(context),
        scopedApis = CatalogSourceScope.apisOf(context),
        selected = CatalogSourceScope.serverOf(context);
    await CatalogQueryEngine.loadAliases();
    if (widget.api case final api?) {
      final (document, visuals, formal) = await (
        api.catalog('songs'),
        CatalogVisuals.of(api),
        api is ProviderApi && api.provider == 'bestdori'
            ? CatalogVisuals.of(scopedApi).then<CatalogVisuals?>(
                (value) => value,
                onError: (Object _) => null,
              )
            : Future<CatalogVisuals?>.value(null),
      ).wait;
      final rows = document is Map && document['items'] is Map
          ? document['items'] as Map
          : document;
      return (
        switch (rows) {
          Map() => [
            for (final MapEntry(:key, :value) in rows.entries)
              if (value is Entry) {'_key': '$key', ...value},
          ],
          List() => rows.whereType<Entry>().toList(),
          _ => <Entry>[],
        },
        visuals,
        formal == null ? null : visuals.withPortraitSource(formal),
      );
    }
    final (songs, visuals) = await (
      crossServerCollection(
        resource: 'songs',
        selected: selected,
        apis: scopedApis,
        rowsPath: null,
      ),
      CatalogVisuals.of(scopedApi),
    ).wait;
    return (songs, visuals, null);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final songs = data?.$1;
        final visuals = data?.$2;
        final api = widget.api ?? CatalogSourceScope.apiOf(context);
        final song = _SongText(t, visuals, api, state.songTitle, data?.$3);
        // A new list once the metrics arrive, so a metric sort reorders.
        if (!identical(songs, _source) || _metaSeen != _meta.length) {
          _source = songs;
          _metaSeen = _meta.length;
          _sorted = songs == null ? null : [...songs];
        }
        final items = _sorted;
        String server(Entry song) => '${song[serverKey] ?? api.server}';
        String text(Object? value) => t.text(value);
        return BrowseScreen(
          sourcePath: widget.api == null ? '/catalog/songs' : null,
          title: widget.title ?? t('navigation.songs', 'Songs'),
          items: items,
          onOpen: widget.onOpen,
          queryEngine: visuals == null
              ? null
              : CatalogQueryEngine(
                  visuals: visuals,
                  game: catalogGame(api),
                  kind: 'song',
                ),
          itemId: (item) => '${item['musicId'] ?? item['_key'] ?? ''}',
          error: snapshot.error,
          onRetry: () => setState(() => _data = _load()),
          searchText: (item) => [
            ...switch (item['musicTitle']) {
              final List titles => titles.whereType<String>(),
              final String title => [title],
              _ => const <String>[],
            },
            song.artist(item),
            '${item['musicId']}',
          ].join(' '),
          grid: const GridSpec(minWidth: 160),
          tile: (context, item) => _SongTile(
            song: item,
            text: song,
            onOpen: () => widget.onOpen?.call(context, item),
          ),
          listRow: (context, item) => _SongRow(
            song: item,
            text: song,
            onOpen: () => widget.onOpen?.call(context, item),
          ),
          columns: [
            TableColumn(
              t.label('title'),
              (item) => state.songTitle(item['musicTitle']),
            ),
            TableColumn(t.label('band'), song.artist),
            TableColumn(t.label('musicType'), song.attribute),
            TableColumn(t.label('category'), song.category),
            TableColumn(
              'EXPERT',
              (item) => '${song.level(item, 3) ?? '—'}',
              numeric: true,
            ),
            TableColumn(t.label('release'), song.release),
          ],
          facets: visuals == null
              ? const []
              : [
                  FacetSpec(
                    key: 'band',
                    label: t.label('band'),
                    values: (item) => [
                      for (final id in (item['bandIds'] as List? ?? const []))
                        '$id',
                    ],
                    option: (value) => FacetOption(
                      t.text(visuals.bands[int.parse(value)]?['bandName']),
                      image: visuals.bandIcon(int.parse(value)),
                    ),
                  ),
                  FacetSpec(
                    key: 'character',
                    label: t.label('character'),
                    values: (item) => [
                      for (final id
                          in (item['vocalCharacterIds'] as List? ?? const []))
                        '$id',
                    ],
                    option: (value) {
                      final character = visuals.characters[int.parse(value)];
                      final face = character?['faceImage'];
                      return FacetOption(
                        t.text(character?['characterName']),
                        image: face is String
                            ? api.asset(face).toString()
                            : null,
                      );
                    },
                  ),
                  FacetSpec(
                    key: 'type',
                    label: t.label('attribute'),
                    values: (item) => [
                      if (item['musicType'] != null) '${item['musicType']}',
                    ],
                    option: (value) => FacetOption(
                      song.attribute({'musicType': int.parse(value)}),
                      image: visuals.musicTypeMark(int.parse(value)),
                    ),
                  ),
                  FacetSpec(
                    key: 'category',
                    label: t.label('category'),
                    values: (item) => [
                      for (final id
                          in (item['musicCategories'] as List? ?? const []))
                        '$id',
                    ],
                    option: (value) => FacetOption(
                      song.category({
                        'musicCategories': [int.parse(value)],
                      }),
                    ),
                  ),
                ],
          // The website's song sort options (`sortOptions`, `sortValue`).
          sorts: [
            SortSpec(
              'order',
              t.label('order'),
              (item) =>
                  item['displayOrder'] ??
                  item['order'] ??
                  item['sortOrder'] ??
                  item['musicId'],
            ),
            SortSpec('id', t.label('id'), (item) => item['musicId']),
            SortSpec(
              'title',
              t.label('title'),
              (item) => state.songTitle(item['musicTitle']),
            ),
            SortSpec(
              'musicType',
              t.label('musicType'),
              (item) => item['musicType'] ?? 0,
            ),
            SortSpec('band', t.label('band'), song.artist),
            SortSpec('level', t.label('level'), (item) {
              final rows = item['difficulty'] as List? ?? const [];
              final row = rows.length > 3 && rows[3] is Map
                  ? rows[3] as Map
                  : const {};
              return row['sortLevel'] ??
                  row['displayLevel'] ??
                  row['playLevel'] ??
                  -1;
            }),
            for (final (key, label) in const [
              ('time', 'time'),
              ('score', 'metaScoreFactor'),
              ('eff', 'eff'),
              ('bpm', 'bpm'),
              ('n', 'n'),
              ('nps', 'nps'),
              ('sr', 'sr'),
            ])
              SortSpec(
                key,
                t.label(label),
                (item) => _metric(item, key, server(item)),
                missingLast: true,
              ),
            SortSpec('category', t.label('category'), (item) {
              final categories = item['musicCategories'];
              final first = categories is List && categories.isNotEmpty
                  ? categories.first
                  : 99;
              return first is num && first != 0 ? first : 99;
            }),
            SortSpec(
              'composer',
              t.label('composer'),
              (item) => text(item['composer']),
            ),
            SortSpec(
              'lyrics',
              t.label('lyrics'),
              (item) => text(item['lyricist']),
            ),
            SortSpec(
              'arrangement',
              t.label('arrangement'),
              (item) => text(item['arranger']),
            ),
            SortSpec('release', t.label('release'), (item) {
              final value =
                  item['releasedAt'] ??
                  item['publishedAt'] ??
                  item['publicStartAt'] ??
                  item['startAt'];
              return value is List
                  ? value.whereType<num>().where((v) => v > 0).firstOrNull ?? 0
                  : value ?? 0;
            }),
          ],
          defaultSort: 'release',
          actions: (visible) => [
            ...widget.extraActions,
            BarAction(
              icon: Symbols.playlist_play_rounded,
              label: t.label('playAll'),
              onPressed: visible.any((s) => s['musicUrl'] is String)
                  ? () => state.audio.playQueue([
                      for (final s in visible) ?song.track(s),
                    ])
                  : null,
            ),
          ],
        );
      },
    );
  }
}

/// How a song reads: title, artist line, attribute, genre, level, release.
class _SongText {
  _SongText(this.t, this.visuals, this.api, this.title, this.registry);
  final SiteText t;
  final CatalogVisuals? visuals;
  final PerformerRegistry? registry;
  final HaneokaApi api;

  /// The reader's song-title choice.
  final String Function(Object?) title;

  late final presentation = SongPresentation(
    t,
    api,
    visuals,
    registry: registry,
  );
  List<int> bandIds(Entry song) => presentation.bandIds(song);
  SongPerformer? performer(Entry song) => presentation.performer(song);
  String artist(Entry song) => presentation.artist(song);
  List<String> emblems(Entry song) => presentation.avatars(song);
  String attribute(Entry song) => presentation.attribute(song);
  String category(Entry song) => presentation.category(song);

  num? level(Entry song, int difficulty) {
    const names = ['easy', 'normal', 'hard', 'expert', 'special'];
    for (final row in (song['difficulty'] as List? ?? const [])) {
      if (row is Entry &&
          (row['difficulty'] == difficulty ||
              row['difficulty'] == names[difficulty])) {
        return (row['displayLevel'] ?? row['playLevel']) as num?;
      }
    }
    return null;
  }

  num? releasedAt(Entry song) {
    final value = song['publishedAt'];
    if (value is num) return value;
    if (value is List) return value.whereType<num>().firstOrNull;
    return null;
  }

  String release(Entry song) {
    final ms = releasedAt(song);
    return ms == null
        ? '—'
        : SiteDate.day(t.locale)
              .format(DateTime.fromMillisecondsSinceEpoch(ms.toInt()));
  }

  List<String> jackets(Entry song) => [
    for (final key in ['jacketUrl', 'jacketThumbUrl'])
      if (song[key] case final String path when path.isNotEmpty)
        api.asset(path).toString(),
  ];

  Track? track(Entry song) {
    final url = song['musicUrl'];
    if (url is! String) return null;
    return Track(
      id: '${song['musicId']}',
      songKey:
          '${presentation.game}:${song[serverKey] ?? api.server}:${song['musicId']}',
      url: api.asset(url).toString(),
      title: title(song['musicTitle']),
      subtitle: artist(song),
      artwork: jackets(song).firstOrNull,
    );
  }
}

class _SongTile extends StatelessWidget {
  const _SongTile({required this.song, required this.text, this.onOpen});
  final Entry song;
  final _SongText text;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final audio = AppScope.of(context).audio;
    final track = text.track(song);
    return Tile(
      title: AppScope.of(context).songTitle(song['musicTitle']),
      subtitle: text.artist(song),
      adornments: text.emblems(song),
      images: text.jackets(song),
      placeholder: Symbols.album_rounded,
      serverMark: serverMark(song, text.t.call),
      marks: text.presentation.marks(song),
      onTap: onOpen,
      action: track == null
          ? null
          : ListenableBuilder(
              listenable: audio,
              builder: (context, _) {
                final playing = audio.isPlaying(track.id, track.url);
                return Material(
                  type: MaterialType.transparency,
                  elevation: 1,
                  shape: const CircleBorder(),
                  child: IconButton.filledTonal(
                    tooltip:
                        '${text.t(playing ? 'common.actions.pause' : 'common.actions.play')}: ${track.title}',
                    onPressed: () => audio.enqueueTrack(track),
                    icon: Icon(
                      playing
                          ? Symbols.pause_rounded
                          : Symbols.play_arrow_rounded,
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({required this.song, required this.text, this.onOpen});
  final Entry song;
  final _SongText text;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onOpen,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: 48,
          child: ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: AppImage(candidates: text.jackets(song)),
          ),
        ),
      ),
      title: Text(
        AppScope.of(context).songTitle(song['musicTitle']),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          text.artist(song),
          text.category(song),
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text('${text.level(song, 3) ?? ''}'),
    );
  }
}
