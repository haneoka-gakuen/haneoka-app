import '../core/catalog_source.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:intl/intl.dart';

import '../community/entity_comments.dart';
import '../core/api.dart';
import '../core/provider_api.dart';
import '../core/app_state.dart';
import '../core/audio.dart';
import '../core/i18n.dart';
import '../core/page_data.dart';
import '../core/relative_time.dart';
import '../shell/page.dart';
import '../shell/links.dart';
import '../rendering/native_chart_player_screen.dart';
import '../records/records.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import 'card_growth.dart';
import 'arena_detail.dart';
import 'character_detail.dart';
import 'cross_server.dart';
import 'source_picker.dart';
import 'detail_media.dart';
import 'entity_extras.dart';
import 'catalog_screen.dart';
import 'format.dart';
import 'labels.g.dart';
import 'profiles.dart';
import 'song_summary.dart';
import 'song_score_targets.dart';
import 'song_video.dart';
import 'system_detail.dart';
import 'visuals.dart';

const _difficultyNames = ['EASY', 'NORMAL', 'HARD', 'EXPERT', 'SPECIAL'];
const _rankNames = ['', 'E', 'D', 'C', 'B', 'A', 'S', 'SS'];

/// One entity as the website's entity page: artwork in the gallery beside
/// the presentation's own sections, every remaining field folded under All
/// fields.
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.profile,
    required this.id,
    required this.summary,
    this.siblings,
    this.api,
  });

  /// Another game's data (`origin`); the release's when null.
  final HaneokaApi? api;
  final CatalogProfile profile;
  final String id;
  final Entry summary;

  /// The collection this was opened from, for previous and next.
  final List<Entry>? siblings;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Future<(Entry, CatalogVisuals, Entry?, Entry)>? _data;
  int? _difficulty;

  void refresh(VoidCallback change) {
    if (mounted) setState(change);
  }

  Object? _dataKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = CatalogSourceScope.keyOf(context);
    if (_dataKey != key) {
      _dataKey = key;
      _data = _load();
    }
  }

  Future<(Entry, CatalogVisuals, Entry?, Entry)> _load() async {
    final state = AppScope.of(context);
    // An entity only the other release has opens there (`displayServer`).
    final server = '${widget.summary[serverKey] ?? state.server}';
    final api =
        widget.api ??
        CatalogSourceScope.maybeApi(context) ??
        state.apiFor(server);
    final resource = widget.profile.resource;
    final (record, visuals, page) = await (
      api
          .catalog(resource, widget.id)
          .then<Entry>(
            (value) => value is Entry ? value : widget.summary,
            onError: (_) => widget.summary,
          ),
      CatalogVisuals.of(api),
      // A provider has no built page; its songs join its own song-meta.
      api is ProviderApi
          ? (resource == 'songs'
                ? api
                      .catalog('song-meta')
                      .then<Map<String, Object?>?>(
                        (meta) => {'songMeta': meta},
                        onError: (_) => null,
                      )
                : Future<Map<String, Object?>?>.value())
          : entityPage(api.server, state.text.locale, resource, widget.id),
    ).wait;
    final canonicalRecord = _providerRecord(record);
    final displayRecord = {...widget.summary, ...record};
    final item = page?['item'];
    return (
      item is Map
          ? {...displayRecord, ...item.cast<String, Object?>()}
          : _providerRecord(displayRecord),
      visuals,
      page,
      canonicalRecord,
    );
  }

  /// GBP names its difficulties; the song page reads them by index, the
  /// name kept for labels (`easy` … `special`).
  Entry _providerRecord(Entry record) {
    if (widget.api is! ProviderApi) return record;
    const names = ['easy', 'normal', 'hard', 'expert', 'special'];
    return {
      ...record,
      'difficulty': [
        for (final row in (record['difficulty'] as List? ?? const []))
          if (row is Map)
            {
              ...row.cast<String, Object?>(),
              if (row['difficulty'] is String) ...{
                'difficulty': names.indexOf(row['difficulty'] as String),
                'difficultyName': row['difficulty'],
              },
            },
      ],
    };
  }

  /// Previous and next in the collection (`data-entity-navigation`):
  /// they replace this page, so Back still returns to the collection.
  List<BarAction> _neighbours(CatalogKit kit) {
    final list = widget.siblings;
    if (list == null) return const [];
    final index = list.indexWhere((e) => kit.id(e) == widget.id);
    if (index < 0) return const [];
    BarAction step(int offset, IconData icon, String key, String fallback) {
      final entry = list[index + offset];
      return BarAction(
        icon: icon,
        label: '${kit.t(key, fallback)}: ${kit.title(entry)}',
        overflowFirst: true,
        onPressed: () => Navigator.of(context).pushReplacement(
          PageRouteBuilder<void>(
            settings: RouteSettings(
              name:
                  '/catalog/${widget.profile.resource == 'cards' ? 'member-cards' : widget.profile.resource}/${Uri.encodeComponent(kit.id(entry))}',
            ),
            pageBuilder: (_, _, _) => DetailScreen(
              profile: widget.profile,
              id: kit.id(entry),
              summary: entry,
              siblings: list,
              api: widget.api is ProviderApi ? widget.api : null,
            ),
            transitionDuration: Duration.zero,
          ),
        ),
      );
    }

    return [
      if (index > 0)
        step(
          -1,
          Symbols.chevron_left_rounded,
          'common.actions.previous',
          'Previous',
        ),
      if (index + 1 < list.length)
        step(1, Symbols.chevron_right_rounded, 'common.actions.next', 'Next'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final record = snapshot.data?.$1 ?? widget.summary;
        final visuals = snapshot.data?.$2;
        final page = snapshot.data?.$3;
        final canonicalRecord = snapshot.data?.$4 ?? widget.summary;
        final kit = CatalogKit(
          widget.profile,
          t,
          widget.api ??
              CatalogSourceScope.maybeApi(context) ??
              state.apiFor('${widget.summary[serverKey] ?? state.server}'),
          visuals,
          songTitles: state.songTitle,
        );
        final view = _Page(
          kit,
          record,
          this,
          page,
          canonicalRecord: canonicalRecord,
          ready: snapshot.hasData,
        );
        return ShellPage(
          title: kit.title(record),
          marks: view.marks(),
          marksExtent: view.marksExtent(),
          actions: [
            ..._neighbours(kit),
            ...view.actions(),
            if (widget.api is! ProviderApi)
              catalogSourceAction(
                context,
                '/catalog/${widget.profile.resource == 'cards' ? 'member-cards' : widget.profile.resource}/${widget.id}',
              ),
          ],
          body: widget.profile.presentation == Presentation.character
              ? CharacterDetail(record: record, page: page, visuals: visuals)
              : DetailLayout(media: view.media(), sections: view.sections()),
        );
      },
    );
  }
}

/// The sections of one entity, by presentation.
class _Page {
  _Page(
    this.kit,
    this.record,
    this.host,
    this.page, {
    required this.canonicalRecord,
    this.ready = true,
  });
  final bool ready;
  final CatalogKit kit;
  final Entry record;
  final Entry canonicalRecord;
  final _DetailScreenState host;

  /// The website's payload for this page, when it was published.
  final Entry? page;

  SiteText get t => kit.t;
  BuildContext get context => host.context;
  Presentation get kind => kit.kind;
  AudioService get audio => AppScope.of(context).audio;

  Widget _emblem(String? url, {double size = 24}) => url == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(right: 6),
          child: SizedBox(
            height: size,
            width: size,
            child: AppImage(candidates: [url]),
          ),
        );

  Widget? marks() {
    final visuals = kit.visuals;
    if (visuals == null) return null;
    final children = <Widget>[
      if (kind == Presentation.character && record['faceImage'] is String)
        _emblem(
          kit.api.asset(record['faceImage'] as String).toString(),
          size: 34,
        ),
      if (kind == Presentation.song) ...[
        for (final id in (record['bandIds'] as List? ?? [?record['bandId']]))
          if (visuals.bandLogo(id) case final logo?)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: SizedBox(
                height: 24,
                width: 40,
                child: AppImage(candidates: [logo]),
              ),
            ),
        _emblem(visuals.musicTypeMark(record['musicType'])),
      ],
      if (kind == Presentation.member || kind == Presentation.support) ...[
        for (final id in kit.characterIds(record).take(3))
          if (visuals.characters[id]?['faceImage'] case final String face)
            _emblem(kit.api.asset(face).toString()),
        // Rarity, then attribute (`renderDetailLeading`).
        for (final mark in kit.marks(record).reversed) _emblem(mark.image),
      ],
    ];
    return children.isEmpty
        ? null
        : Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  double marksExtent() {
    final visuals = kit.visuals;
    if (visuals == null) return 0;
    if (kind == Presentation.character && record['faceImage'] is String) {
      return 40;
    }
    if (kind == Presentation.song) {
      return 46.0 * (record['bandIds'] as List? ?? [?record['bandId']]).length +
          30;
    }
    if (kind == Presentation.member || kind == Presentation.support) {
      return 30.0 *
          (kit.characterIds(record).take(3).length + kit.marks(record).length);
    }
    return 0;
  }

  /// The song's own actions (`renderDetailActions`): ranking, play,
  /// Sonolus.
  List<BarAction> actions() {
    if (kind != Presentation.song || !ready) return const [];
    // Rankings and Sonolus are this game's; another game's song only plays.
    final native = kit.api is! ProviderApi;
    final actions = <BarAction>[
      if (native)
        BarAction(
          icon: Symbols.bar_chart_rounded,
          label: t('catalog.rankings.songs.title', 'Song ranking'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SongRankingScreen(
                songId:
                    '${canonicalRecord['musicId'] ?? kit.id(canonicalRecord)}',
                title: kit.title(record),
                server: kit.api.server,
              ),
            ),
          ),
        ),
    ];
    if (canonicalRecord['musicUrl'] is String) {
      final track = Track(
        id: kit.id(canonicalRecord),
        songKey:
            '${kit.api is ProviderApi ? "gbp" : "our-notes"}:${canonicalRecord[serverKey] ?? kit.api.server}:${canonicalRecord["musicId"] ?? kit.id(canonicalRecord)}',
        url: kit.api.asset(canonicalRecord['musicUrl'] as String).toString(),
        title: kit.title(record),
        artwork: kit.images(canonicalRecord).firstOrNull,
      );
      final playing = audio.isPlaying(track.id, track.url);
      actions.add(
        BarAction(
          icon: playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
          label: t(playing ? 'common.actions.pause' : 'common.actions.play'),
          onPressed: () async {
            if (playing) {
              await audio.pause();
            } else {
              await audio.enqueueTrack(track);
            }
            host.refresh(() {});
          },
        ),
      );
    }
    final charts = _canonicalCharts;
    final chosen =
        host._difficulty ??
        (charts.any((c) => c['difficulty'] == 3)
            ? 3
            : charts.lastOrNull?['difficulty'] as int?);
    final chart = charts.where((c) => c['difficulty'] == chosen).firstOrNull;
    final musicId = '${canonicalRecord['musicId'] ?? ''}'.trim();
    if (!native && chart?['file'] != null) {
      final provider = kit.api as ProviderApi;
      final collection = provider.provider == 'sekai' ? 'sekai' : 'gbp';
      final difficulty =
          '${chart?['difficultyName'] ?? ['easy', 'normal', 'hard', 'expert', 'special'].elementAtOrNull(chosen ?? 3) ?? 'expert'}';
      actions.add(
        BarAction(
          icon: Symbols.sports_esports_rounded,
          label: t('navigation.chart', 'Chart'),
          onPressed: () => openLink(
            context,
            Uri(
              path: '/community/$collection/songs/$musicId',
              queryParameters: {'chart': '1', 'difficulty': '$chosen'},
            ).toString(),
          ),
        ),
      );
      if (provider.provider == 'bestdori') {
        actions.add(
          BarAction(
            icon: Symbols.edit_rounded,
            label: t('editors.chart.importGbp', 'Import GBP chart'),
            onPressed: () => openLink(
              context,
              Uri(
                path: '/chart-editor/create',
                queryParameters: {
                  'provider': 'bestdori',
                  'region': provider.region,
                  'songId': musicId,
                  'difficulty': difficulty,
                },
              ).toString(),
            ),
          ),
        );
        actions.add(
          BarAction(
            icon: Symbols.sports_esports_rounded,
            image: Image.asset(
              'assets/settings/sonolus-icon.png',
              width: 24,
              height: 24,
            ),
            label: 'Sonolus',
            onPressed: () => openLink(
              context,
              'https://open.sonolus.com/haneoka.org/levels/haneoka-gbp-$musicId-$difficulty',
            ),
          ),
        );
      }
    }
    if (native &&
        chart?['file'] != null &&
        RegExp(r'^\d{1,16}$').hasMatch(musicId)) {
      actions.add(
        BarAction(
          icon: Symbols.sports_esports_rounded,
          label: t('navigation.chart', 'Chart'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: RouteSettings(
                name: Uri(
                  path: '/chart-simulator',
                  queryParameters: {
                    'id': musicId,
                    'server': kit.api.server,
                    'difficulty': '$chosen',
                  },
                ).toString(),
              ),
              builder: (_) => CatalogSourceScope(
                api: kit.api,
                child: NativeChartPlayerScreen(
                  song: canonicalRecord,
                  api: kit.api,
                  difficulty: chosen!,
                ),
              ),
            ),
          ),
        ),
      );
      const names = ['easy', 'normal', 'hard', 'expert', 'master'];
      final raw = '${chart!['difficultyName'] ?? ''}'.toLowerCase();
      final difficulty =
          names.contains(raw) || raw == 'special' || raw == 'append'
          ? raw
          : names.elementAtOrNull(
                  (chart['difficulty'] as num?)?.toInt() ?? 4,
                ) ??
                'master';
      actions.add(
        BarAction(
          icon: Symbols.sports_esports_rounded,
          image: Image.asset(
            'assets/settings/sonolus-icon.png',
            width: 24,
            height: 24,
          ),
          label: 'Sonolus',
          onPressed: () => openLink(
            context,
            'https://open.sonolus.com/haneoka.org/levels/haneoka-${kit.api.server}-$musicId-$difficulty',
          ),
        ),
      );
    }
    return actions;
  }

  Widget? media() {
    final (entries, initial) = detailMedia(
      t: t,
      resource: kit.profile.resource,
      kind: kind,
      item: record,
      asset: (path) => kit.api.asset(path).toString(),
      tileImage: kit.images(record).firstOrNull,
    );
    if (entries.isEmpty) return null;
    return ImageGallery(
      key: ValueKey(entries.map((e) => e.url).join()),
      images: const [],
      entries: entries,
      initial: initial,
      natural:
          kit.profile.resource == 'events' || kit.profile.resource == 'gacha',
      aspectRatio:
          kind == Presentation.support ||
              kind == Presentation.system ||
              kind == Presentation.background
          ? 16 / 9
          : 1,
    );
  }

  String _date(Object? value) {
    return gameDateTime(t.locale, RelativeTime.timestamp(value));
  }

  List<Widget> sections() {
    // The site's discussion under every catalogue entry (`entity-comments`).
    final target = kit.api is ProviderApi
        ? null
        : entityCommentTarget(
            host.widget.profile.resource,
            canonicalRecord,
            '${host.widget.summary[serverKey] ?? kit.api.server}',
          );
    return [
      ...switch (kind) {
        Presentation.song => _song(),
        Presentation.member || Presentation.support => _card(),
        _ => _generic(),
      },
      if (target != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: EntityComments(
            key: ValueKey('${target.type}/${target.id}'),
            type: target.type,
            id: target.id,
            server: '${host.widget.summary[serverKey] ?? kit.api.server}',
          ),
        ),
    ];
  }

  // ---------- Songs ----------

  List<Entry> get _canonicalCharts => [
    for (final row in (canonicalRecord['difficulty'] as List? ?? const []))
      if (row is Entry) row,
  ];

  List<Entry> get _charts => [
    for (final row in (record['difficulty'] as List? ?? const []))
      if (row is Entry) row,
  ];

  List<Widget> _song() {
    final charts = _charts;
    final chosen =
        host._difficulty ??
        (charts.any((c) => c['difficulty'] == 3)
            ? 3
            : charts.lastOrNull?['difficulty'] as int?);
    final chart = charts.where((c) => c['difficulty'] == chosen).firstOrNull;
    final canonicalChart = _canonicalCharts
        .where((c) => c['difficulty'] == chosen)
        .firstOrNull;
    String list(Object? value) => switch (value) {
      List() =>
        value.whereType<String>().where((s) => s.isNotEmpty).take(1).join(),
      _ => t.text(value),
    };
    final estimates = AppScope.of(context).difficultyEstimates;
    String? estimate(Entry? row) {
      final value = readPath(
        row ?? const {},
        'difficultyEstimate.estimatedConstant',
      );
      final status = readPath(
        row ?? const {},
        'difficultyEstimate.quality.status',
      );
      return estimates &&
              value is num &&
              value > 0 &&
              readPath(row!, 'difficultyEstimate.target') ==
                  'fc-operation-load' &&
              (status == 'estimated' || status == 'low-confidence')
          ? value.toStringAsFixed(1)
          : null;
    }

    final entry =
        ((page?['songMeta'] as Map?)?['${record['musicId']}']
                as Map?)?['$chosen']
            as Map?;
    final meta = (entry?['chart'] as Map?) ?? const {};
    final gekisou = (entry?['gekisou'] as Map?) ?? const {};
    final published = RelativeTime.timestamp(record['publishedAt']);
    final facts = [
      for (final key in ['composer', 'lyricist', 'arranger'])
        if (list(record[key]).isNotEmpty)
          (
            t.label(
              key == 'lyricist'
                  ? 'lyrics'
                  : key == 'arranger'
                  ? 'arrangement'
                  : key,
            ),
            list(record[key]),
          ),
      if (published != null && published > 0)
        (
          t.label('release'),
          DateFormat.yMd(t.locale)
              .format(DateTime.fromMillisecondsSinceEpoch(published.toInt())),
        ),
    ];
    return [
      DetailSection(
        icon: Symbols.info_rounded,
        title: t('common.actions.details', 'Details'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DifficultyChips(
              captions: {
                for (final c in charts)
                  (c['difficulty'] as num).toInt(): ?estimate(c),
              },
              selected: chosen,
              onSelected: (index) =>
                  host.refresh(() => host._difficulty = index),
              levels: [
                for (final c in charts)
                  (
                    (c['difficulty'] as num).toInt(),
                    _difficultyNames[(c['difficulty'] as num).toInt().clamp(
                      0,
                      4,
                    )],
                    '${c['displayLevel'] ?? c['playLevel'] ?? ''}'.replaceAll(
                      RegExp(r'\.0$'),
                      '',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            DataGrid(
              large: true,
              cells: songMetrics(
                t,
                meta: meta,
                chart: chart,
                estimate: estimate(chart),
              ),
            ),
            DataGrid(cells: facts, minWidth: 180),
          ],
        ),
      ),
      if (ready)
        if (canonicalChart?['file'] case final String file when file.isNotEmpty)
          SongSkillPoints(
            key: ValueKey(file),
            source: kit.api.asset(file).toString(),
          ),
      GekisouStages(song: record, metrics: gekisou),
      if (kit.api is! ProviderApi &&
          const ['jp', 'intl'].contains(kit.api.server) &&
          chosen != null)
        SongChartTargets(
          api: kit.api,
          musicId:
              (record['musicId'] as num?)?.toInt() ??
              int.tryParse('${record['_key']}') ??
              0,
          difficulty: chosen,
          inlineRates: (page?['aux'] as Map?)?['chartRates'] as Map?,
        ),
      ?_rewards(chart),
      if (kit.api is! ProviderApi &&
          (record['scoreRanks'] as List? ?? const []).whereType<Map>().any(
            (r) =>
                ((r['scoreRank'] as num?) ?? 0) >= 3 &&
                ((r['battleLiveRequiredScore'] as num?) ?? 0) > 0,
          ))
        SongRoomScores(
          key: ValueKey('room:${kit.api.server}:${record['musicId']}'),
          api: kit.api,
          ranks: [
            for (final r
                in (record['scoreRanks'] as List? ?? const []).whereType<Map>())
              if (((r['scoreRank'] as num?) ?? 0) >= 3 &&
                  ((r['battleLiveRequiredScore'] as num?) ?? 0) > 0)
                (
                  rank: (r['scoreRank'] as num).toInt(),
                  required: ((r['requiredScore'] as num?) ?? 0).toInt(),
                  battleRequired: (r['battleLiveRequiredScore'] as num).toInt(),
                ),
          ],
        ),
      if (ready)
        SongVideos(
          key: ValueKey('mv:${canonicalRecord['musicId']}'),
          song: canonicalRecord,
        ),
    ];
  }

  Widget? _rewards(Entry? chart) {
    final ranks = [
      for (final r in (record['scoreRanks'] as List? ?? const []))
        if (r is Entry && ((r['scoreRank'] as num?) ?? 0) >= 3) r,
    ];
    final scoreRewards = [
      for (final r in (record['scoreRewards'] as List? ?? const []))
        if (r is Entry) r,
    ];
    final name = '${chart?['difficultyName'] ?? ''}'.toLowerCase();
    final combo = [
      for (final r
          in ((record['comboRewards'] as Map?)?[name] as List? ?? const []))
        if (r is Entry) r,
    ];
    if (ranks.isEmpty && scoreRewards.isEmpty && combo.isEmpty) return null;
    final theme = Theme.of(context);
    final number = NumberFormat.decimalPattern(t.locale);
    final server = kit.api.server;
    Widget reward(Entry r) {
      final resolved = (r['resolved'] as Map?) ?? const {};
      final image = resolved['image'];
      return Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 26,
              child: image is String
                  ? AppImage(candidates: [kit.api.asset(image).toString()])
                  : const Icon(Symbols.redeem_rounded, size: 18),
            ),
            const SizedBox(width: 6),
            Text(t.text(resolved['name']), style: theme.textTheme.bodyMedium),
            Text(
              ' ×${number.format(r['resourceCount'] ?? 0)}',
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
      );
    }

    Widget row(
      Widget? leading,
      String value,
      String caption,
      List<Entry> rewards,
    ) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 12)],
          SizedBox(
            width: 104,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: theme.textTheme.titleSmall),
                Text(
                  caption,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Wrap(
              runSpacing: 4,
              children: [for (final r in rewards) reward(r)],
            ),
          ),
        ],
      ),
    );
    final rankIds = {
      for (final r in ranks) (r['scoreRank'] as num).toInt(),
      for (final r in scoreRewards) (r['liveScoreRank'] as num).toInt(),
    }.toList()..sort();
    final notes = (chart?['noteCount'] as num?) ?? 0;
    const percentages = [25, 50, 75, 100];
    return DetailSection(
      icon: Symbols.emoji_events_rounded,
      title: t.label('rewards', 'Rewards'),
      count: ranks.length + scoreRewards.length + combo.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.label('score', 'Score'), style: theme.textTheme.titleSmall),
          for (final id in rankIds)
            row(
              SizedBox.square(
                dimension: 28,
                child: AppImage(
                  candidates: [
                    kit.api
                        .asset(
                          '/assets/$server/Assets/AddressableResources/UI/Texture/BandRank/ImgScorerank_${_rankNames[id.clamp(0, 7)]}.png',
                        )
                        .toString(),
                  ],
                ),
              ),
              number.format(
                ranks
                        .where((r) => r['scoreRank'] == id)
                        .firstOrNull?['requiredScore'] ??
                    0,
              ),
              t.label('score', 'Score'),
              [
                for (final r in scoreRewards)
                  if (r['liveScoreRank'] == id) r,
              ],
            ),
          if (combo.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(t.label('combo', 'Combo'), style: theme.textTheme.titleSmall),
            for (final r in combo)
              Builder(
                builder: (context) {
                  final percent =
                      percentages[((r['comboRateType'] as num?) ?? 0)
                          .toInt()
                          .clamp(0, 3)];
                  return row(
                    null,
                    percent == 100 ? 'FULL COMBO' : '$percent%',
                    '${number.format((notes * percent / 100).ceil())} ${t.label('notes', 'notes')}',
                    [r],
                  );
                },
              ),
          ],
        ],
      ),
    );
  }

  // ---------- Member cards and snapshots ----------

  List<Widget> _card() {
    final visuals = kit.visuals;
    final marks = kit.marks(record);
    final ids = kit.characterIds(record);
    return [
      DetailSection(
        icon: Symbols.info_rounded,
        title: t('common.actions.details', 'Details'),
        child: SpecList(
          facts: [
            for (final mark in marks.reversed)
              Fact(
                mark.at.name == 'end'
                    ? t.label('rarity')
                    : t.label('attribute'),
                mark.label ?? '',
                widget: SizedBox(
                  height: 28,
                  width: 28,
                  child: AppImage(candidates: [mark.image!]),
                ),
              ),
            if (_date(record['releasedAt']).isNotEmpty)
              Fact(t.label('release'), _date(record['releasedAt'])),
          ],
        ),
      ),
      CardGrowthView(
        record: record,
        visuals: visuals,
        characterIds: ids,
        characterName: kit.characterName,
        support: kind == Presentation.support,
        page: page,
        ready: ready,
      ),
    ];
  }

  // ---------- Everything else ----------

  List<Widget> _generic() {
    final format = ValueFormat(t);

    /// A field as the website prints it (`fieldValue`).
    String value(String key) {
      final raw = readPath(record, key);
      String names(Iterable<Object?> ids) => [
        for (final id in ids)
          if (id is num && kit.characterName(id.toInt()).isNotEmpty)
            kit.characterName(id.toInt()),
      ].join(', ');
      return switch (key) {
        'kind' => switch ('${raw ?? ''}') {
          '' => '',
          final kind => t.label(kind, kind),
        },
        'characterId' => names([raw]),
        'characterIds' => names(kit.characterIds(record)),
        'bandId' => kit.bandName(raw),
        'type' || 'category' => switch (format.format(key, raw)) {
          '' => '',
          final text => t.label(text, text),
        },
        'description' => '',
        _ when key.endsWith('At') => _date(raw),
        _ => switch (format.format(key, raw)) {
          final text when text.startsWith('/assets/') => '',
          final text => text,
        },
      };
    }

    /// A field's label (`detailLabel`).
    String label(String key) {
      const aliases = {
        'characterId': 'character',
        'characterIds': 'characters',
        'subTitle': 'subtitle',
        'bandId': 'band',
        'cardType': 'attribute',
        'releasedAt': 'release',
        'publishedAt': 'release',
        'publicStartAt': 'release',
        'startAt': 'starts',
        'endAt': 'ends',
        'itemTypeName': 'type',
        'max': 'size',
        'maximum': 'size',
      };
      final alias = aliases[key] ?? key;
      return _named(alias) ?? t.label(alias, alias);
    }

    final facts = [
      for (final key in kit.profile.detail)
        if (value(key) case final text when text.isNotEmpty)
          Fact(label(key), text),
    ];
    final description = kit.plain(record['description']);
    final resource = kit.profile.resource;
    final rotating = resource == 'events' || resource == 'gacha';
    final titled = kind == Presentation.item || kind == Presentation.bandItem;
    final details = facts.isEmpty || rotating
        ? null
        : DetailSection(
            icon: Symbols.info_rounded,
            title: t('common.actions.details', 'Details'),
            child: SpecList(facts: facts),
          );
    return [
      if (description.isNotEmpty && !titled && !rotating)
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: SelectableText(
            description,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ?details,
      if (description.isNotEmpty && kind == Presentation.item)
        DetailSection(
          icon: Symbols.notes_rounded,
          title: t.label('content', 'Content'),
          child: SelectableText(
            description,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      if (kind == Presentation.bandItem)
        BandItemLevels(
          key: ValueKey('levels:${kit.id(record)}'),
          item: record,
          page: page,
        ),
      if (resource == 'stickers') StickerExtras(page: page),
      if (kind == Presentation.item)
        if ((page?['document'] as Map?)?['itemRelations'] case final Map data)
          ItemRelations(data: data),
      if (resource == 'arena') ArenaDetail(season: record),
      if (kind == Presentation.system && resource != 'arena')
        SystemDetail(
          key: ValueKey('$resource:${kit.id(record)}'),
          resource: resource,
          item: record,
          visuals: kit.visuals,
        ),
    ];
  }

  /// The website's label for a field, or null when it does not name it.
  String? _named(String key) {
    for (final path in [
      ?catalogLabelPaths[key],
      'catalog.fields.$key',
      'catalog.songs.fields.$key',
      'catalog.cards.fields.$key',
      'catalog.characters.fields.$key',
      'common.fields.$key',
    ]) {
      final label = t(path);
      if (label.isNotEmpty) return label;
    }
    return null;
  }
}
