import '../core/site_date.dart';
import '../core/catalog_source.dart';

import 'package:flutter/material.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../catalog/browse.dart';
import '../catalog/source_picker.dart';
import '../catalog/visuals.dart';
import '../catalog/cross_server.dart';
import '../community/entity_comments.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../core/voice.dart';
import '../core/i18n.dart';
import '../core/image_dimensions.dart';
import '../core/provider_api.dart';
import '../core/page_data.dart';
import '../core/relative_time.dart';
import '../shell/page.dart';
import 'story_sequence.dart';
import 'story_sequence_player.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/tile.dart';
import 'story_artwork.dart';
import 'transcript.dart';
import 'transcript_view.dart';

/// The website's story sections (`StoryMode`).
const storyModes = [
  'event',
  'band',
  'link',
  'birthday',
  'home',
  'afterlive',
  'tutorial',
];

/// Which section an episode belongs to (`modeOf`): event-owned chapters,
/// then birthdays, then numbered band chapters, then by chapter key.
String? storyModeOf(
  Entry episode,
  Set<String> eventChapters, [
  Set<String> birthdayChapters = const {},
]) {
  final chapter = '${episode['chapterId'] ?? ''}';
  if (eventChapters.contains(chapter)) return 'event';
  if (episode['storyCategory'] == 'birthday' ||
      birthdayChapters.contains(chapter)) {
    return 'birthday';
  }
  if (((episode['chapterId'] as num?) ?? 0) < 900000) return 'band';
  return switch (episode['chapterKey']) {
    'asset_linkstory' => 'link',
    'asset_home' => 'home',
    'asset_afterlive' => 'afterlive',
    'asset_tutorial' => 'tutorial',
    _ => null,
  };
}

String _duration(Object? seconds) {
  if (seconds is! num || seconds <= 0) return '';
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class _StoryData {
  _StoryData(this.document, this.visuals, {this.providerMode});
  final Map document;
  final CatalogVisuals visuals;

  /// Another game's section: every episode is in it.
  final String? providerMode;

  late final Set<String> eventChapters = {
    for (final e
        in (document['storyEvents'] as List? ?? const []).whereType<Map>())
      '${e['chapterId']}',
  };
  late final List<Entry> episodes = [
    for (final MapEntry(:key, :value)
        in ((document['episodes'] as Map?) ?? const {}).entries)
      if (value is Entry) {'_key': key, ...value},
  ];

  /// The game's birthday stories: their chapters, and whose birthday each is.
  late final Map<String, int> birthdayCharacter = {
    for (final rows
        in ((document['birthdayStories'] as Map?) ?? const {}).values)
      for (final row in (rows as List? ?? const []).whereType<Map>())
        '${row['storyKey']}': (row['characterId'] as num).toInt(),
  };
  late final Set<String> birthdayChapters = {
    for (final rows
        in ((document['birthdayStories'] as Map?) ?? const {}).values)
      for (final row in (rows as List? ?? const []).whereType<Map>())
        '${row['chapterId']}',
  };

  /// Home talks by their spot (`homeSpots[].talks`).
  late final Map<String, Map> spotOfStory = {
    for (final spot in spots.values.whereType<Map>())
      for (final talk in (spot['talks'] as List? ?? const []).whereType<Map>())
        '${talk['storyKey']}': spot,
  };

  String? mode(Entry e) =>
      providerMode ?? storyModeOf(e, eventChapters, birthdayChapters);

  Map get chapters => (document['chapters'] as Map?) ?? const {};
  Map get spots => (document['homeSpots'] as Map?) ?? const {};
}

/// One story section (`story-workspace` for the release): the axis it is
/// organised by in the rail, the chosen group's heading, and its episodes in
/// the game's order, each opening its transcript.
class StoriesScreen extends StatefulWidget {
  const StoriesScreen({super.key, required this.mode, this.api, this.title});
  final String mode;

  /// GBP or Project Sekai stories (`origin`); this release's when null.
  final HaneokaApi? api;
  final String? title;
  @override
  State<StoriesScreen> createState() => _StoriesScreenState();
}

class _StoriesScreenState extends State<StoriesScreen> {
  Future<_StoryData>? _data;
  String? _rail;
  BrowseView _view = BrowseView.grid;
  int? _partner;

  /// `id`, `title`, `release` or `duration` (`defaultSort`).
  String? _sort;
  bool? _descending;
  String get _defaultSort =>
      const {'link', 'birthday', 'afterlive'}.contains(widget.mode)
      ? 'release'
      : 'id';
  bool get _defaultDescending =>
      widget.mode == 'card' || _defaultSort == 'release';
  String _query = '';
  final _queryField = GlobalKey<FormFieldState<String>>();
  final _facets = <String, Set<String>>{};
  DateTime? _releaseFrom;
  DateTime? _releaseTo;
  int get _filterCount =>
      _facets.values.fold(0, (sum, values) => sum + values.length) +
      (_releaseFrom == null ? 0 : 1) +
      (_releaseTo == null ? 0 : 1) +
      (_query.trim().isEmpty ? 0 : 1);

  List<int> _characterIds(Entry episode) => [
    for (final value
        in episode['characterIds'] as List? ?? [episode['characterId']])
      if (value is num && value > 0) value.toInt(),
  ];
  Set<int> _bandIds(Entry episode, _StoryData data) => {
    for (final value in episode['bandIds'] as List? ?? [episode['bandId']])
      if (value is num && value > 0) value.toInt(),
    for (final id in _characterIds(episode))
      if (data.visuals.characters[id]?['bandId'] case final num band
          when band > 0)
        band.toInt(),
    if ((data.chapters['${episode['chapterId']}'] as Map?)?['bandId']
        case final num band when band > 0)
      band.toInt(),
  };
  Iterable<String> _facetValues(String key, Entry e, _StoryData data) =>
      switch (key) {
        'character' => _characterIds(e).map((id) => '$id'),
        'band' => _bandIds(e, data).map((id) => '$id'),
        'kind' => [_group(e)],
        'perspective' => [
          if (e['perspectiveCharacterId'] case final num id when id > 0) '$id',
        ],
        'level' => [
          if (e['unlockCharacterFriendshipLevel'] case final num level
              when level > 0)
            '$level',
        ],
        _ => [if (e[key] != null && '${e[key]}'.isNotEmpty) '${e[key]}'],
      };
  bool _matchesEpisode(Entry episode, _StoryData data, {String? omitted}) {
    for (final facet in _facets.entries) {
      if (facet.key != omitted &&
          facet.value.isNotEmpty &&
          !_facetValues(facet.key, episode, data).any(facet.value.contains)) {
        return false;
      }
    }
    final release = _releaseValue(episode);
    if ((_releaseFrom != null || _releaseTo != null) && release <= 0) {
      return false;
    }
    if (_releaseFrom != null &&
        release < _releaseFrom!.millisecondsSinceEpoch) {
      return false;
    }
    if (_releaseTo != null &&
        release >=
            DateTime(
              _releaseTo!.year,
              _releaseTo!.month,
              _releaseTo!.day + 1,
            ).millisecondsSinceEpoch) {
      return false;
    }
    final query = _query.trim().toLowerCase();
    final t = AppScope.of(context).text;
    return '${t.text(episode['title'])} ${t.text(episode['description'])} ${t.text(episode['chapterName'])} ${episode['episodeNumber'] ?? ''}'
        .toLowerCase()
        .contains(query);
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

  Future<_StoryData> _load() async {
    if (widget.api case final api?) return _loadProvider(api);
    final apis = CatalogSourceScope.apisOf(context);
    final servers = [
      CatalogSourceScope.serverOf(context),
      ...apis.keys.where(
        (server) => server != CatalogSourceScope.serverOf(context),
      ),
    ];
    final (documents, visuals) = await (
      Future.wait([
        for (final server in servers)
          apis[server]!
              .catalog('stories')
              .then<Object?>((value) => value, onError: (_) => null),
      ]),
      CatalogVisuals.of(CatalogSourceScope.apiOf(context)),
    ).wait;
    if (documents.every((document) => document == null)) {
      throw StateError('Story catalog unavailable');
    }
    final sources = {
      for (final (index, server) in servers.indexed) server: documents[index],
    };
    final episodes = await crossServerCollection(
      resource: 'stories',
      selected: CatalogSourceScope.serverOf(context),
      apis: apis,
      rowsPath: 'episodes',
      sourceDocuments: sources,
    );
    Map mergedMap(String key) => {
      for (final document in documents.reversed.whereType<Map>())
        ...((document[key] as Map?) ?? const {}),
    };
    final events = <String, Map>{};
    final birthdays = <String, Map<String, Map>>{};
    for (final document in documents.whereType<Map>()) {
      for (final event
          in (document['storyEvents'] as List? ?? const []).whereType<Map>()) {
        events.putIfAbsent('${event['chapterId']}', () => event);
      }
      for (final group
          in (document['birthdayStories'] as Map? ?? const {}).entries) {
        final rows = birthdays.putIfAbsent('${group.key}', () => {});
        for (final row in (group.value as List? ?? const []).whereType<Map>()) {
          rows.putIfAbsent('${row['storyKey']}', () => row);
        }
      }
    }
    return _StoryData({
      'episodes': {
        for (final episode in episodes)
          '${episode['storyKey'] ?? episode['_key']}': episode,
      },
      'chapters': mergedMap('chapters'),
      'homeSpots': mergedMap('homeSpots'),
      'storyEvents': events.values.toList(),
      'birthdayStories': {
        for (final group in birthdays.entries)
          group.key: group.value.values.toList(),
      },
    }, visuals);
  }

  /// A provider's section, read as this release's document: episodes by id
  /// and their chapters with the event logo or band banner
  /// (`loadBestdori`).
  Future<_StoryData> _loadProvider(HaneokaApi api) async {
    if (widget.mode == 'card' &&
        api is ProviderApi &&
        api.provider == 'bestdori') {
      return _loadCards(api);
    }
    final (rows, visuals) = await (
      api.catalog('stories/${widget.mode}'),
      CatalogVisuals.of(api),
    ).wait;
    final records = switch (rows) {
      List() => rows.whereType<Entry>(),
      Map() => rows.values.whereType<Entry>(),
      _ => const <Entry>[],
    };
    final episodes = <String, Entry>{};
    final chapters = <String, Entry>{};
    for (final e in records) {
      final id = '${e['storyId'] ?? e['storyKey']}';
      episodes[id] = {
        ...e,
        'storyKey': e['storyKey'] ?? e['storyId'],
        'image': e['episodeImage'] ?? e['image'],
      };
      final chapter = '${e['chapterId'] ?? ''}';
      chapters.putIfAbsent(
        chapter,
        () => {
          'chapterName': e['chapterName'] ?? e['eventName'],
          'banner': e['thumbnail'] ?? e['image'],
          'chapterSort': e['chapterSort'],
        },
      );
    }
    return _StoryData(
      {'episodes': episodes, 'chapters': chapters},
      visuals,
      providerMode: widget.mode,
    );
  }

  /// GBP card stories are a card collection by character; a card opens
  /// its own episodes (`isCardSection`).
  Future<_StoryData> _loadCards(HaneokaApi api) async {
    final (rows, visuals) = await (
      api.catalog('cards'),
      CatalogVisuals.of(api),
    ).wait;
    final cards = switch (rows) {
      List() => rows.whereType<Entry>(),
      Map() => rows.values.whereType<Entry>(),
      _ => const <Entry>[],
    }.where((card) => card['hasStory'] != false);
    final episodes = <String, Entry>{};
    final chapters = <String, Entry>{};
    for (final card in cards) {
      final character = (card['characterId'] as num?)?.toInt();
      final thumbnails = card['cardThumbnails'];
      episodes['card:${card['cardId']}'] = {
        'storyKey': 'card:${card['cardId']}',
        'chapterId': character,
        'title': card['prefix'],
        'image':
            (thumbnails is Map ? thumbnails['normal'] : null) ??
            card['cardImage'],
        'storySort': card['releaseAt'],
        'cardId': card['cardId'],
        'characterIds': [?character],
        'rarity': card['rarity'],
        'attribute': card['attribute'],
        'cardThumbnails': card['cardThumbnails'],
        'cardImages': card['cardImages'],
        'releaseAt': card['releaseAt'],
      };
      chapters.putIfAbsent(
        '$character',
        () => {
          'chapterName': visuals.characters[character]?['characterName'],
          'banner': visuals.characters[character]?['faceImage'],
          'chapterSort': character,
        },
      );
    }
    return _StoryData(
      {'episodes': episodes, 'chapters': chapters},
      visuals,
      providerMode: widget.mode,
    );
  }

  String _label(SiteText t) => widget.title != null
      ? widget.title!
      : widget.mode == 'birthday'
      ? t('story.labels.birthdayStory', 'Birthday stories')
      : t('story.navigation.${widget.mode}', widget.mode);

  /// The rail key of an episode: its chapter, pair, character or band.
  String _railKey(Entry e, _StoryData data) => switch (widget.mode) {
    'link' => ([
      ...((e['characterIds'] as List?) ?? const []),
    ]..sort((a, b) => jsNumber(a).compareTo(jsNumber(b)))).join('-'),
    'afterlive' => 'all',
    'home' => '${data.spotOfStory['${e['storyKey']}']?['spotId'] ?? ''}',
    _ => '${e['chapterId']}',
  };

  bool _inRail(Entry episode, String? rail, _StoryData data) =>
      rail == null ||
      (widget.mode == 'link'
          ? _characterIds(episode).contains(int.tryParse(rail))
          : _railKey(episode, data) == rail);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final episodes = data == null
            ? const <Entry>[]
            : [
                for (final e in data.episodes)
                  if (data.mode(e) == widget.mode) e,
              ];
        final keys = widget.mode == 'link'
            ? (<String>{
                for (final episode in episodes)
                  for (final id in _characterIds(episode)) '$id',
              }.toList()..sort((a, b) => jsNumber(a).compareTo(jsNumber(b))))
            : <String>{for (final e in episodes) _railKey(e, data!)}.toList();
        if (data != null && data.providerMode != null) {
          // Another game's chapters by first release, newest events first.
          num sortOf(String key) =>
              (data.chapters[key] as Map?)?['chapterSort'] as num? ?? 0;
          keys.sort(
            (a, b) => widget.mode == 'event'
                ? sortOf(b).compareTo(sortOf(a))
                : sortOf(a).compareTo(sortOf(b)),
          );
        } else if (widget.mode == 'event') {
          // Events run newest first (`relevantChapters`).
          final starts = <String, num>{
            for (final event
                in (data?.document['storyEvents'] as List? ?? const [])
                    .whereType<Map>())
              '${event['chapterId']}': _releaseValue(event),
          };
          keys.sort(
            (a, b) => (starts[b] ?? 0).compareTo(starts[a] ?? 0) != 0
                ? (starts[b] ?? 0).compareTo(starts[a] ?? 0)
                : (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0),
          );
        } else if (widget.mode == 'band') {
          num sortOf(String key) =>
              (data?.chapters[key] as Map?)?['chapterSort'] as num? ?? 0;
          keys.sort((a, b) => sortOf(a).compareTo(sortOf(b)));
        } else if (widget.mode == 'birthday') {
          num release(String key) =>
              _releaseValue(data?.chapters[key] as Map? ?? const {});
          keys.sort(
            (a, b) => release(b) != release(a)
                ? release(b).compareTo(release(a))
                : (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0),
          );
        } else {
          keys.sort(
            (a, b) => (int.tryParse(a.split('-').first) ?? 0).compareTo(
              int.tryParse(b.split('-').first) ?? 0,
            ),
          );
        }
        final rail = keys.contains(_rail) ? _rail! : keys.firstOrNull;
        final chosen = [
          for (final e in episodes)
            if (_inRail(e, rail, data!) &&
                _matchesEpisode(e, data) &&
                (_partner == null || _characterIds(e).contains(_partner)))
              e,
        ]..sort(_compareEpisodes);
        final groups = <(String, List<Entry>)>[
          (
            widget.mode == 'band'
                ? t('story.labels.bandStory', 'Band story')
                : t('story.labels.eventStory', 'Story'),
            [
              for (final e in chosen)
                if (e['isAnotherEpisode'] != true &&
                    e['isExtraEpisode'] != true)
                  e,
            ],
          ),
          (
            t('story.labels.extraStory', 'Extra story'),
            [
              for (final e in chosen)
                if (e['isExtraEpisode'] == true) e,
            ],
          ),
          (
            t('story.labels.perspectiveStory', 'Perspective story'),
            [
              for (final e in chosen)
                if (e['isAnotherEpisode'] == true) e,
            ],
          ),
        ].where((g) => g.$2.isNotEmpty).toList();
        return ShellPage(
          title: _label(t),
          actions: [
            if (widget.api == null)
              catalogSourceAction(context, '/stories?mode=${widget.mode}'),
            if (data != null)
              BarAction(
                icon: Symbols.filter_alt_rounded,
                label: t('common.actions.filter', 'Filter'),
                badge: _filterCount,
                onPressed: () => _filters(context, data, episodes, rail),
              ),
            BarAction.choice(
              label: t('common.actions.view', 'View'),
              options: [
                for (final (view, icon, key) in [
                  (BrowseView.grid, Symbols.grid_view_rounded, 'grid'),
                  (BrowseView.list, Symbols.view_agenda_rounded, 'list'),
                  (BrowseView.table, Symbols.table_rows_rounded, 'table'),
                ])
                  BarChoice(
                    icon: icon,
                    label: t('common.layout.$key', key),
                    selected: _view == view,
                    onSelected: () => setState(() => _view = view),
                  ),
              ],
            ),
          ],
          status: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                data == null
                    ? ''
                    : chosen.length == episodes.length
                    ? '${chosen.length}'
                    : '${chosen.length} / ${episodes.length}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          body: snapshot.hasError
              ? Center(
                  child: FilledButton.tonal(
                    onPressed: () => setState(() => _data = _load()),
                    child: Text(t('common.actions.retry', 'Retry')),
                  ),
                )
              : data == null
              ? const Center(child: CircularProgressIndicator())
              : _body(context, data, keys, rail, chosen, groups),
        );
      },
    );
  }

  static num _releaseValue(Map item) {
    final value = item['releaseAt'] ?? item['publishedAt'] ?? item['startAt'];
    final first = value is List ? value.firstOrNull : value;
    return first is num ? first : num.tryParse('${first ?? ''}') ?? 0;
  }

  static num _number(Object? value) =>
      value is num ? value : num.tryParse('${value ?? ''}') ?? 0;

  static String _group(Map episode) => storyEpisodeGroup(episode);

  /// The website's episode order (`sorted` in `story-workspace.ts`).
  int _compareEpisodes(Entry a, Entry b) {
    final sort = _sort ?? _defaultSort;
    final direction = (_descending ?? _defaultDescending) ? -1 : 1;
    String id(Map e) => '${e['storyId'] ?? e['cardId'] ?? e['storyKey'] ?? ''}';
    final provider = widget.api != null;
    if (provider && widget.mode == 'event' && sort == 'id') {
      final chapter = _number(b['chapterSort'])
          .compareTo(_number(a['chapterSort']));
      if (chapter != 0) return chapter;
      final ids = _number(b['chapterId']).compareTo(_number(a['chapterId']));
      if (ids != 0) return ids;
      return direction *
          _number(a['episodeNumber']).compareTo(_number(b['episodeNumber']));
    }
    const groups = ['bandStory', 'extraStory', 'perspectiveStory'];
    final group = groups.indexOf(_group(a)) - groups.indexOf(_group(b));
    if (!provider && widget.mode == 'event') {
      var order = group;
      if (order == 0) {
        order = _number(a['episodeNumber'])
            .compareTo(_number(b['episodeNumber']));
      }
      if (order == 0) order = naturalCompare(id(a), id(b));
      return direction * order;
    }
    if (!provider && widget.mode == 'band' && group != 0) return group;
    final t = AppScope.of(context).text;
    var result = switch (sort) {
      'title' => naturalCompare(t.text(a['title']), t.text(b['title'])),
      'release' => _releaseValue(a).compareTo(_releaseValue(b)),
      'duration' => _number(a['playTime']).compareTo(_number(b['playTime'])),
      'level' => _number(
        a['unlockCharacterFriendshipLevel'],
      ).compareTo(_number(b['unlockCharacterFriendshipLevel'])),
      _ => naturalCompare(id(a), id(b)),
    };
    if (result == 0) {
      result = _number(a['storySort']).compareTo(_number(b['storySort']));
    }
    return direction * result;
  }

  /// The section's facets: characters and bands that appear in it
  /// (`FACET_KEYS`), each with its count.
  Future<void> _filters(
    BuildContext context,
    _StoryData data,
    List<Entry> episodes,
    String? rail,
  ) => showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.32),
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (sheet, _, _) => Align(
      alignment: AlignmentDirectional.centerEnd,
      child: StatefulBuilder(
        builder: (sheet, refresh) {
          final t = AppScope.of(context).text;
          final api = widget.api ?? CatalogSourceScope.apiOf(context);
          final facets = <FacetSpec>[
            for (final (key, label) in [
              ('band', t.label('band', 'Band')),
              ('character', t.label('character', 'Character')),
              if (data.providerMode == null &&
                  const {'band', 'event'}.contains(widget.mode))
                ('kind', t('catalog.fields.type', 'Type')),
              if (data.providerMode == null && widget.mode == 'band')
                (
                  'perspective',
                  t(
                    'story.labels.perspectiveCharacter',
                    'Perspective character',
                  ),
                ),
              if (widget.mode == 'card') ...[
                ('rarity', t('catalog.cards.fields.rarity', 'Rarity')),
                ('attribute', t('catalog.fields.attribute', 'Attribute')),
              ],
              ('level', t('catalog.characters.fields.friendship', 'Bond')),
            ])
              if (episodes.any((e) => _facetValues(key, e, data).isNotEmpty))
                FacetSpec(
                  key: key,
                  label: label,
                  values: (episode) => _facetValues(key, episode, data),
                  option: (value) {
                    final id = int.tryParse(value);
                    final character = data.visuals.characters[id];
                    return FacetOption(
                      switch (key) {
                        'band' => t.text(data.visuals.bands[id]?['bandName']),
                        'character' ||
                        'perspective' => t.text(character?['characterName']),
                        'kind' => t('story.labels.$value', value),
                        'level' => 'Lv.$value',
                        _ => value,
                      },
                      image: key == 'band'
                          ? data.visuals.bandIcon(id)
                          : const {'character', 'perspective'}.contains(key) &&
                                character?['faceImage'] is String
                          ? api
                                .asset(character!['faceImage'] as String)
                                .toString()
                          : null,
                    );
                  },
                ),
          ];
          Widget date(bool end) {
            final selected = end ? _releaseTo : _releaseFrom;
            final label = t(
              end ? 'common.fields.maximum' : 'common.fields.minimum',
              end ? 'To' : 'From',
            );
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(label),
              subtitle: selected == null
                  ? null
                  : Text(SiteDate.day(t.locale).format(selected)),
              leading: const Icon(Symbols.calendar_month_rounded),
              trailing: selected == null
                  ? null
                  : IconButton(
                      icon: const Icon(Symbols.close_rounded),
                      tooltip: t('common.actions.clear', 'Clear'),
                      onPressed: () {
                        setState(() {
                          if (end) {
                            _releaseTo = null;
                          } else {
                            _releaseFrom = null;
                          }
                        });
                        refresh(() {});
                      },
                    ),
              onTap: () async {
                final value = await showDatePicker(
                  context: sheet,
                  initialDate: selected ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (value != null && mounted && sheet.mounted) {
                  setState(() {
                    if (end) {
                      _releaseTo = value;
                    } else {
                      _releaseFrom = value;
                    }
                  });
                  refresh(() {});
                }
              },
            );
          }

          return BrowseFilterPanel(
            switches: const [],
            facets: facets,
            sorts: [
              for (final (key, path) in const [
                ('id', 'common.layout.order'),
                ('title', 'common.fields.title'),
                ('release', 'catalog.fields.release'),
                ('duration', 'common.fields.duration'),
              ])
                SortSpec(key, t(path, key), (_) => null),
            ],
            sort: _sort ?? _defaultSort,
            descending: _descending ?? _defaultDescending,
            selected: _facets,
            counts: (key) {
              final counts = <String, int>{
                for (final episode in episodes)
                  for (final value in _facetValues(key, episode, data))
                    value: 0,
              };
              for (final episode in episodes) {
                if (!_inRail(episode, rail, data) ||
                    !_matchesEpisode(episode, data, omitted: key)) {
                  continue;
                }
                for (final value in _facetValues(key, episode, data)) {
                  counts[value] = (counts[value] ?? 0) + 1;
                }
              }
              return counts;
            },
            onToggle: (key, value) {
              setState(() {
                final values = _facets.putIfAbsent(key, () => {});
                if (!values.remove(value)) values.add(value);
              });
              refresh(() {});
            },
            onSort: (value) {
              setState(() => _sort = value);
              refresh(() {});
            },
            onOrder: () {
              setState(
                () => _descending = !(_descending ?? _defaultDescending),
              );
              refresh(() {});
            },
            onReset: () {
              setState(() {
                _facets.clear();
                _query = '';
                _queryField.currentState?.didChange('');
                _releaseFrom = _releaseTo = null;
              });
              refresh(() {});
            },
            fields: [
              TextFormField(
                key: _queryField,
                initialValue: _query,
                decoration: InputDecoration(
                  labelText: t('common.actions.search', 'Search'),
                  prefixIcon: const Icon(Symbols.search_rounded),
                ),
                onChanged: (value) {
                  setState(() => _query = value);
                  refresh(() {});
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  t('catalog.fields.release', 'Release'),
                  style: Theme.of(sheet).textTheme.titleSmall,
                ),
              ),
              date(false),
              date(true),
            ],
          );
        },
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );

  ({String title, String? image, String? description}) _railInfo(
    _StoryData data,
    String key,
    SiteText t,
    HaneokaApi api,
  ) {
    String? asset(Object? path) =>
        path is String && path.isNotEmpty ? api.asset(path).toString() : null;
    switch (widget.mode) {
      case 'link':
        final ids = key.split('-').map(int.tryParse).whereType<int>();
        return (
          title: ids
              .map(
                (id) => t.text(data.visuals.characters[id]?['characterName']),
              )
              .join(' × '),
          image: asset(data.visuals.characters[ids.firstOrNull]?['faceImage']),
          description: null,
        );
      case 'afterlive':
        return (title: '', image: null, description: null);
      case 'home':
        final spot = data.spots[key] as Map?;
        return (
          title: t.text(spot?['name']),
          image: asset(spot?['thumbnail']),
          description: t.text(spot?['bandName']),
        );
      default:
        final chapter = data.chapters[key] as Map?;
        final event = (data.document['storyEvents'] as List? ?? const [])
            .whereType<Map>()
            .where((e) => '${e['chapterId']}' == key)
            .firstOrNull;
        return (
          title: t.text(
            chapter?['chapterName'] ?? event?['chapterName'] ?? event?['title'],
          ),
          image: asset(chapter?['banner'] ?? event?['banner']),
          description: t
              .text(chapter?['description'] ?? event?['description'])
              .trim()
              .replaceAll(
                RegExp(r'\s*\r?\n\s*'),
                t.locale.startsWith('ja') || t.locale.startsWith('zh')
                    ? ''
                    : ' ',
              ),
        );
    }
  }

  Widget _body(
    BuildContext context,
    _StoryData data,
    List<String> keys,
    String? rail,
    List<Entry> chosen,
    List<(String, List<Entry>)> groups,
  ) {
    final t = AppScope.of(context).text;
    final api = widget.api ?? CatalogSourceScope.apiOf(context);
    final padding = pagePadding(context);
    final info = rail == null ? null : _railInfo(data, rail, t, api);
    void open(BuildContext context, Entry episode) => _EpisodeTile(
      episode: episode,
      data: data,
      mode: widget.mode,
      api: widget.api,
    ).open(context);
    Widget row(BuildContext context, Entry episode) => ListTile(
      contentPadding: EdgeInsets.symmetric(
        horizontal: padding.left,
        vertical: 8,
      ),
      leading: SizedBox(
        width: 80,
        height: 48,
        child: AppImage(
          candidates: [
            for (final source in [
              episode['episodeImage'],
              episode['banner'],
              episode['image'],
            ])
              if (source is String && source.isNotEmpty)
                api.asset(source).toString(),
          ],
          fit: BoxFit.contain,
        ),
      ),
      title: Text(
        t.text(episode['title']),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        t.text(episode['chapterName']),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(_duration(episode['playTime'])),
      onTap: () => open(context, episode),
    );
    return CollectionPane(
      rail:
          keys.length > 1 ||
              keys.isNotEmpty &&
                  const {'event', 'birthday'}.contains(widget.mode)
          ? BrowseRail(
              value: rail ?? '',
              onSelect: (key) => setState(() {
                _rail = key;
                _partner = null;
              }),
              items: [
                for (final key in keys)
                  () {
                    final info = _railInfo(data, key, t, api);
                    final count = data.episodes
                        .where(
                          (e) =>
                              data.mode(e) == widget.mode &&
                              _inRail(e, key, data),
                        )
                        .length;
                    return RailItem(
                      key,
                      info.title,
                      image: info.image,
                      meta: '$count ${t('story.labels.episodes', 'episodes')}',
                    );
                  }(),
              ],
            )
          : null,
      heading: info == null || info.title.isEmpty
          ? null
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (info.image != null) ...[
                  SizedBox(
                    width: (MediaQuery.sizeOf(context).width * 0.16).clamp(
                      72.0,
                      132.0,
                    ),
                    height: 64,
                    child: AppImage(
                      candidates: [
                        api
                            .asset(
                              '${(data.chapters[rail] as Map?)?['icon'] ?? info.image!}',
                            )
                            .toString(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.title,
                        style: MediaQuery.sizeOf(context).width < 600
                            ? Theme.of(context).textTheme.titleLarge
                            : Theme.of(context).textTheme.headlineSmall,
                      ),
                      if ((info.description ?? '').isNotEmpty)
                        Text(
                          info.description!,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
      results: (context, headers) {
        final partners = <int>{
          for (final episode in data.episodes.where(
            (e) => data.mode(e) == widget.mode && _inRail(e, rail, data),
          ))
            for (final id in _characterIds(episode))
              if ('$id' != rail) id,
        }.toList()..sort();
        final contentHeaders = <Widget>[
          ...headers,
          if (widget.mode == 'link')
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padding.left, 8, padding.right, 8),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      label: Text(t('common.states.all', 'All')),
                      selected: _partner == null,
                      onSelected: (_) => setState(() => _partner = null),
                    ),
                    for (final id in partners)
                      FilterChip(
                        label: Text(
                          t.text(data.visuals.characters[id]?['characterName']),
                        ),
                        selected: _partner == id,
                        onSelected: (_) => setState(
                          () => _partner = _partner == id ? null : id,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ];
        if (_view == BrowseView.table) {
          return CustomScrollView(
            slivers: [
              ...contentHeaders,
              SliverFillRemaining(child: _table(context, data, chosen, open)),
            ],
          );
        }
        return CustomScrollView(
          slivers: [
            ...contentHeaders,
            if (_view == BrowseView.list)
              SliverList.builder(
                itemCount: chosen.length,
                itemBuilder: (context, index) => row(context, chosen[index]),
              )
            else
              for (final (title, list) in groups) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    padding.left,
                    16,
                    padding.right,
                    8,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${list.length}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: padding.left),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final compact = MediaQuery.sizeOf(context).width < 600;
                      final gap = compact ? 8.0 : 12.0;
                      final grid = collectionGrid(
                        context,
                        constraints.crossAxisExtent,
                        minWidth: 260,
                      ) as SliverGridDelegateWithFixedCrossAxisCount;
                      final columns = grid.crossAxisCount;
                      final width =
                          (constraints.crossAxisExtent - gap * (columns - 1)) /
                          columns;
                      return SliverList.builder(
                        itemCount: (list.length / columns).ceil(),
                        itemBuilder: (context, row) {
                          final entries = list
                              .skip(row * columns)
                              .take(columns)
                              .toList();
                          final height =
                              entries
                                  .map(
                                    (e) =>
                                        width /
                                        _episodeRatio(
                                          e,
                                          data,
                                          widget.mode,
                                          api is ProviderApi,
                                        ),
                                  )
                                  .reduce((a, b) => a > b ? a : b) +
                              (compact ? 16 + 40 + 4 + 18 : 32 + 48 + 8 + 20);
                          return Padding(
                            padding: EdgeInsets.only(bottom: gap),
                            child: SizedBox(
                              height: height,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (
                                    var index = 0;
                                    index < columns;
                                    index++
                                  ) ...[
                                    if (index > 0) SizedBox(width: gap),
                                    Expanded(
                                      child: index >= entries.length
                                          ? const SizedBox.shrink()
                                          : _EpisodeTile(
                                              episode: entries[index],
                                              data: data,
                                              mode: widget.mode,
                                              api: widget.api,
                                            ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            SliverToBoxAdapter(child: SizedBox(height: padding.bottom)),
          ],
        );
      },
    );
  }

  Widget _table(
    BuildContext context,
    _StoryData data,
    List<Entry> episodes,
    void Function(BuildContext, Entry) open,
  ) {
    final t = AppScope.of(context).text;
    final titles = [
      '#',
      t('common.fields.title', 'Title'),
      t('story.labels.chapter', 'Chapter'),
      t('navigation.characters', 'Characters'),
      t('common.fields.duration', 'Duration'),
      t('catalog.characters.fields.friendship', 'Bond'),
      t('catalog.fields.release', 'Release'),
    ];
    const widths = [56.0, 280.0, 180.0, 240.0, 90.0, 90.0, 140.0];
    Widget row(List<String> values, {bool header = false}) => SizedBox(
      height: header ? 48 : 64,
      child: Row(
        children: [
          for (final (index, value) in values.indexed)
            SizedBox(
              width: widths[index],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: header
                      ? Theme.of(context).textTheme.labelLarge
                      : Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
        ],
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: widths.reduce((a, b) => a + b),
        child: Column(
          children: [
            row(titles, header: true),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                primary: false,
                itemCount: episodes.length,
                itemBuilder: (context, index) {
                  final e = episodes[index];
                  final release = _releaseValue(e);
                  return InkWell(
                    onTap: () => open(context, e),
                    child: row([
                      '${e['episodeNumber'] ?? ''}',
                      t.text(e['title']),
                      t.text(e['chapterName']),
                      _characterIds(e)
                          .map(
                            (id) => t.text(
                              data.visuals.characters[id]?['characterName'],
                            ),
                          )
                          .join(
                            t(
                              'story.relationships.speakerNameSeparator',
                              ' & ',
                            ),
                          ),
                      _duration(e['playTime']),
                      e['unlockCharacterFriendshipLevel'] == null
                          ? ''
                          : 'Lv.${e['unlockCharacterFriendshipLevel']}',
                      release <= 0
                          ? ''
                          : SiteDate.day(t.locale).format(
                              DateTime.fromMillisecondsSinceEpoch(
                                release.toInt(),
                              ),
                            ),
                    ]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<String> _episodeImages(Entry episode, _StoryData data, String mode) {
  final chapter = data.chapters['${episode['chapterId']}'] as Map?;
  final spot = data.spotOfStory['${episode['storyKey']}'];
  if (mode == 'afterlive') return const [];
  return [
    for (final source
        in mode == 'home'
            ? [
                spot?['thumbnail'],
                (spot?['spine'] as Map?)?['backgroundPreview'],
                spot?['backgroundPreview'],
              ]
            : [
                episode['episodeImage'],
                episode['banner'],
                episode['image'],
                episode['thumbnail'],
                episode['cardImage'],
                (episode['cardImages'] as Map?)?['normal'],
                chapter?['banner'],
              ])
      if (source is String && source.isNotEmpty) source,
  ];
}

double _episodeRatio(
  Entry episode,
  _StoryData data,
  String mode,
  bool provider,
) => provider || mode == 'home' || mode == 'afterlive'
    ? 16 / 9
    : familyImageRatio(_episodeImages(episode, data, mode).firstOrNull ?? '') ??
          16 / 9;

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.data,
    required this.mode,
    this.api,
  });
  final Entry episode;
  final _StoryData data;
  final String mode;
  final HaneokaApi? api;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final api = this.api ?? CatalogSourceScope.apiOf(context);
    final number = episode['episodeNumber'];
    final duration = _duration(episode['playTime']);
    String subtitle;
    if (mode == 'link' || mode == 'afterlive') {
      final level =
          episode['unlockCharacterFriendshipLevel'] ??
          episode['friendshipLevel'];
      subtitle = level == null
          ? ''
          : '${t('catalog.characters.fields.friendship', '')} Lv.$level';
    } else if (mode == 'birthday') {
      subtitle = t.text(
        data.visuals.characters[data
            .birthdayCharacter['${episode['storyKey']}']]?['characterName'],
      );
    } else if (mode == 'home') {
      subtitle = [
        for (final id in (episode['characterIds'] as List? ?? const []))
          t.text(
            data.visuals.characters[(id as num).toInt()]?['characterName'],
          ),
      ].join(', ');
    } else {
      subtitle = t
          .text(episode['description'])
          .replaceAll('\r', '')
          .replaceAll('\n', ' ')
          .trim();
    }
    return Tile(
      title: t.text(episode['title']).isEmpty
          ? '#$number'
          : t.text(episode['title']),
      subtitle: subtitle,
      adornments: mode == 'birthday'
          ? [
              if (data.visuals.characters[data
                      .birthdayCharacter['${episode['storyKey']}']]?['faceImage']
                  case final String face)
                api.asset(face).toString(),
            ]
          : [
              ?episodeIdentityArtwork(
                episode,
                data.visuals,
                normalArtwork: data.visuals.bandIcon(episode['bandId']),
              ),
            ],
      images: [
        for (final path in _episodeImages(episode, data, mode))
          api.asset(path).toString(),
      ],
      media: mode == 'card'
          ? Row(
              children: [
                for (final state in const ['normal', 'trained'])
                  if (((episode['cardThumbnails'] as Map?)?[state] ??
                          (episode['cardImages'] as Map?)?[state])
                      case final String image when image.isNotEmpty)
                    Expanded(
                      child: AppImage(
                        candidates: [api.asset(image).toString()],
                        fit: BoxFit.contain,
                      ),
                    ),
              ],
            )
          : mode == 'afterlive' || mode == 'link' && episode['image'] == null
          ? StoryFaces(
              faces: [
                for (final id
                    in (episode['characterIds'] as List? ?? const []).take(2))
                  if (data.visuals.characters[(id as num).toInt()]?['faceImage']
                      case final String face)
                    api.asset(face).toString(),
              ],
            )
          : null,
      aspectRatio: _episodeRatio(episode, data, mode, api is ProviderApi),
      fit: BoxFit.contain,
      serverMark: serverMark(episode, t.call),
      placeholder: Symbols.auto_stories_rounded,
      marks: [
        if (number is num)
          TileMark.text(
            MarkAt.start,
            '#${number.toInt().toString().padLeft(2, '0')}',
          ),
        if (duration.isNotEmpty) TileMark.text(MarkAt.bottomEnd, duration),
      ],
      onTap: () => open(context),
    );
  }

  void open(BuildContext context) {
    final api = CatalogSourceScope.resolve(
      context,
      api: this.api,
      server: episode[serverKey] == null ? null : '${episode[serverKey]}',
    );
    if (episode['cardId'] != null) {
      openStoryCard(context, api, '${episode['cardId']}');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(
          name:
              '/stories/${Uri.encodeComponent('${episode['storyKey'] ?? episode['storyId'] ?? episode['_key']}')}?mode=$mode',
        ),
        builder: (_) => CatalogSourceScope(
          api: api,
          child: StoryReaderScreen(episode: episode, api: api),
        ),
      ),
    );
  }
}

/// A GBP card's episodes, each opening in the reader.
Future<void> openStoryCard(
  BuildContext context,
  HaneokaApi api,
  String cardId,
) async {
  final t = AppScope.of(context).text;
  final card = await api
      .catalog('cards', cardId)
      .then<Map?>((v) => v as Map?, onError: (_) => null);
  if (card == null || !context.mounted) return;
  final episodes = (card['episodes'] as List? ?? const []).whereType<Map>();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => ListView(
      shrinkWrap: true,
      children: [
        for (final e in episodes)
          ListTile(
            leading: const Icon(Symbols.auto_stories_rounded),
            title: Text(t.text(e['title'])),
            onTap: () {
              Navigator.pop(sheet);
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CatalogSourceScope(
                    api: api,
                    child: StoryReaderScreen(
                      api: api,
                      episode: {
                        'storyKey':
                            'card.${e['resourceSetName'] ?? card['resourceSetName']}.${e['scenarioId']}',
                        'title': e['title'],
                      },
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    ),
  );
}

/// One episode as text (`projectHaneokaTranscript`): places, speakers with
/// their faces, lines and each line's voice, in order. The 3D stage player
/// is the website's alone for now.
class StoryReaderScreen extends StatefulWidget {
  const StoryReaderScreen({super.key, required this.episode, this.api});
  final Entry episode;
  final HaneokaApi? api;
  @override
  State<StoryReaderScreen> createState() => _StoryReaderScreenState();
}

class _StoryReaderScreenState extends State<StoryReaderScreen> {
  late final _voice = VoicePlayback();
  @override
  void dispose() {
    _voice.dispose();
    super.dispose();
  }

  Future<(Map, CatalogVisuals)>? _data;

  Object? _dataKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final api = widget.api ?? CatalogSourceScope.apiOf(context);
    if (_dataKey != CatalogSourceScope.keyOf(context)) {
      _dataKey = CatalogSourceScope.keyOf(context);
      _data = _load(api);
    }
  }

  Future<(Map, CatalogVisuals)> _load(HaneokaApi api) async {
    final id = '${widget.episode['storyKey'] ?? widget.episode['_key']}';
    final locale = AppScope.of(context).text.locale;
    final (record, visuals, page) = await (
      api.catalog('stories', id),
      CatalogVisuals.of(api),
      api is ProviderApi || api.offlineRelease != null
          ? Future<Map<String, Object?>?>.value(null)
          : pageData(
              '/${api.server}/$locale/stories/${Uri.encodeComponent(id)}/',
              'story-page-$id',
            ).then<Map<String, Object?>?>(
              (value) => value,
              onError: (_) => null,
            ),
    ).wait;
    return (
      {
        ...widget.episode,
        if (record is Map) ...record,
        if ((page?['episodes'] as Map?)?[id] case final Map episode) ...episode,
        '_storyPayload': ?page,
      },
      visuals,
    );
  }

  List<GalleryImage> _artwork(Map detail, HaneokaApi api) {
    if (api is ProviderApi) return const [];
    final payload = detail['_storyPayload'] as Map?;
    final chapters = payload?['chapters'] as Map? ?? const {};
    final chapter = chapters.values
        .whereType<Map>()
        .where((c) => c['chapterId'] == detail['chapterId'])
        .firstOrNull;
    final source =
        detail['episodeImage'] ??
        detail['banner'] ??
        detail['image'] ??
        detail['thumbnail'] ??
        chapter?['banner'];
    final variants =
        (detail['imageVariants'] as Map?)?[source] ??
        (chapter?['imageVariants'] as Map?)?[source];
    if (variants is! Map || variants.length < 2) return const [];
    const names = {
      'ja': '日本語',
      'en': 'English',
      'zh-Hant': '繁體中文',
      'zh-Hans': '简体中文',
      'ko': '한국어',
    };
    return [
      for (final code in names.keys)
        if (variants[code] case final String url)
          GalleryImage(
            api.asset(url).toString(),
            names[code]!,
            localized: false,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final api = widget.api ?? CatalogSourceScope.apiOf(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final detail = data?.$1 ?? widget.episode;
        final visuals = data?.$2;
        final entries = projectTranscript(detail);
        final artwork = _artwork(detail, api);
        final voices = <VoiceClip>[
          for (final entry in entries)
            for (final voice in entry.voices)
              if ((voice['playableUrl'] ?? voice['url']) case final String path
                  when path.isNotEmpty)
                VoiceClip(
                  id: api.asset(path).toString(),
                  url: api.asset(path).toString(),
                ),
        ];
        final title = t.text(detail['title']);
        return ShellPage(
          title: title.isEmpty ? '#${detail['episodeNumber'] ?? ''}' : title,
          actions: [
            if (api is! ProviderApi && data != null)
              BarAction.choice(
                label: t('media.audio.playback', 'Playback'),
                options: [
                  BarChoice(
                    icon: Symbols.article_rounded,
                    label: t('navigation.storyText', 'Text'),
                    selected: true,
                    onSelected: () {},
                  ),
                  BarChoice(
                    icon: Symbols.play_circle_rounded,
                    label: t('navigation.player', 'Player'),
                    selected: false,
                    onSelected: () async {
                      final id = '${detail['storyKey'] ?? detail['_key']}';
                      await _voice.stop();
                      if (!context.mounted) return;
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          settings: RouteSettings(
                            name: Uri(
                              pathSegments: ['', 'stories', id],
                              queryParameters: {
                                'view': 'play',
                                'server': api.server,
                              },
                            ).toString(),
                          ),
                          builder: (_) => CatalogSourceScope(
                            api: api,
                            child: StorySequencePlayer(
                              storyId: id,
                              server: api.server,
                              api: api,
                              title: detail['title'],
                              catalog: detail['_storyPayload'] as Map?,
                              textModeBuilder: (context, currentId) =>
                                  StoryReaderScreen(
                                    episode: {'storyKey': currentId},
                                    api: api,
                                  ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            if (voices.isNotEmpty)
              BarAction(
                icon: Symbols.playlist_play_rounded,
                label: t.label('playAll', 'Play all'),
                onPressed: () => _voice.playAll(voices),
              ),
          ],
          body: snapshot.hasError
              ? Center(
                  child: Text(t('common.states.unavailable', 'Unavailable')),
                )
              : data == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: EdgeInsets.fromLTRB(
                    (MediaQuery.sizeOf(context).width * 0.03).clamp(16.0, 48.0),
                    24,
                    (MediaQuery.sizeOf(context).width * 0.03).clamp(16.0, 48.0),
                    40,
                  ),
                  children: [
                    if (artwork.isNotEmpty)
                      ImageGallery(
                        images: artwork.map((image) => image.url).toList(),
                        entries: artwork,
                        natural: true,
                        aspectRatio: 16 / 9,
                      ),
                    if (t.text(detail['description']).isNotEmpty)
                      Text(
                        t.text(detail['description']).replaceAll('\r', ''),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 16),
                    DetailFold(
                      title: t('common.actions.details', 'Details'),
                      meta: _duration(detail['playTime']),
                      child: SpecList(
                        facts: [
                          Fact(
                            t('story.labels.chapter', 'Chapter'),
                            t.text(detail['chapterName']),
                          ),
                          Fact(
                            t('common.fields.duration', 'Duration'),
                            _duration(detail['playTime']),
                          ),
                          Fact(
                            t('catalog.fields.release', 'Release'),
                            switch (RelativeTime.timestamp(
                              detail['publishedAt'] ?? detail['releaseAt'],
                            )) {
                              final num at => SiteDate.day(t.locale).format(
                                DateTime.fromMillisecondsSinceEpoch(at.toInt()),
                              ),
                              _ => '',
                            },
                          ),
                          if (detail['unlockCharacterFriendshipLevel']
                              case final num level when level > 0)
                            Fact(
                              t('catalog.characters.fields.friendship', 'Bond'),
                              'Lv.$level',
                            ),
                          Fact(
                            t('navigation.characters', 'Characters'),
                            [
                                  for (final character
                                      in detail['characterIds'] as List? ??
                                          const [])
                                    t.text(
                                      visuals?.characters[(character as num?)
                                          ?.toInt()]?['characterName'],
                                    ),
                                ]
                                .where((name) => name.isNotEmpty)
                                .join(
                                  t(
                                    'story.relationships.speakerNameSeparator',
                                    ' & ',
                                  ),
                                ),
                          ),
                          for (final condition
                              in (detail['unlockConditions'] as List? ??
                                      const [])
                                  .whereType<Map>())
                            Fact(
                              t('common.fields.required', 'Required'),
                              '${t.text((condition['reference'] as Map?)?['name'] ?? (condition['band'] as Map?)?['name'])} ${condition['rank'] ?? condition['episodeNumber'] ?? ''}',
                            ),
                        ],
                      ),
                    ),
                    StoryTranscript(
                      playback: _voice,
                      entries: entries,
                      visuals: visuals,
                      api: api,
                      provider: widget.api is ProviderApi,
                      joiner: (detail['runtime'] as Map?)?['displayNameJoiner'],
                    ),
                    if (api.server == 'jp' || api.server == 'intl')
                      if (detail['sourceTable'] == 'MasterAdv' &&
                          detail['advId'] is num)
                        EntityComments(
                          type: 'stories',
                          id: '${detail['advId']}',
                          server: api.server,
                        ),
                  ],
                ),
        );
      },
    );
  }
}

/// Two characters' faces side by side: an after-live talk's media.
class StoryFaces extends StatelessWidget {
  const StoryFaces({super.key, required this.faces});
  final List<String> faces;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final face in faces)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ClipOval(
                    child: SizedBox.square(
                      dimension: 64,
                      child: AppImage(candidates: [face], fit: BoxFit.cover),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
