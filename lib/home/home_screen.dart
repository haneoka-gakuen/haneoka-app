import '../core/site_date.dart';
import '../catalog/arena_detail.dart'
    show arenaPeriods, arenaRuleAt, arenaWindowContains;
import '../team_builder/engine/num.dart' show dataRows, intOf, intListOf, Doc;
import '../core/catalog_source.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../catalog/catalog_screen.dart';
import '../catalog/hub_screen.dart';
import '../catalog/cross_server.dart';
import '../catalog/detail_screen.dart';
import '../catalog/profiles.dart';
import '../catalog/visuals.dart';
import '../catalog/song_presentation.dart';
import '../community/community_time.dart';
import '../core/api.dart';
import '../core/net.dart';
import '../core/page_data.dart';
import '../shell/links.dart';
import '../core/app_state.dart';
import '../core/i18n.dart';
import '../core/relative_time.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/theme.dart';
import '../ui/shapes.dart';
import '../ui/tile.dart';

int _numericId(Entry row) =>
    int.tryParse(
      '${row['id'] ?? row['musicId'] ?? row['cardId'] ?? row['supportCardId'] ?? row['_key']}',
    ) ??
    0;

CatalogProfile _profile(String resource) =>
    catalogProfiles.firstWhere((p) => p.resource == resource);

/// The website's home dashboard: banners the game is showing, the current
/// event, the latest songs and cards, and the next birthdays.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.onBrowse});

  /// Opens a catalogue page from a section's View all.
  final ValueChanged<String>? onBrowse;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeData {
  _HomeData(this.documents, this.visuals, this.seed);
  final Map<String, Object?> documents;
  final CatalogVisuals visuals;
  final Map<String, Object?> seed;

  List<Entry> rows(String resource, [String? key]) {
    final catalog = (seed['crossServerCatalogs'] as Map?)?[resource];
    if (catalog is Map && catalog['entries'] is List) {
      return [
        for (final entry in (catalog['entries'] as List).whereType<Map>())
          if ((entry['perServer'] as Map?)?[entry['displayServer']]
              case final Map variant)
            if (variant['row'] case final Map row)
              {
                ...displayCrossServerRow(
                  row,
                  ((entry['perServer'] as Map?)?[entry['displayServer'] == 'jp'
                              ? 'intl'
                              : 'jp']
                          as Map?)?['row']
                      as Map?,
                ),
                ...((entry['nameOverrides'] as Map?)?.cast<String, Object?>() ??
                    {}),
                '_key': '${variant['id']}',
                if (entry['displayServer'] != seed['server'])
                  serverKey: entry['displayServer'],
                serversKey: (entry['perServer'] as Map).keys.toList(),
              },
      ];
    }
    final value = documents[resource] ?? (seed['documents'] as Map?)?[resource];
    final source = key == null ? value : (value as Map?)?[key];
    return switch (source) {
      List() => source.whereType<Entry>().toList(),
      Map() => [
        for (final MapEntry(:key, :value) in source.entries)
          if (value is Entry) {'_key': key, ...value},
      ],
      _ => const [],
    };
  }
}

/// The modules a reader can order and hide (`MODULES`); banners and the
/// current events stay on top.
const _modules = [
  'birthdays',
  'arena',
  'cards',
  'songs',
  'community',
  'fanInfo',
];
const _layoutKey = 'haneoka:home-layout:v6';

class _HomeScreenState extends State<HomeScreen> {
  Future<_HomeData>? _data;
  Future<List<Map<String, Object?>>>? _community;
  Future<List<Map<String, Object?>>>? _fanInfo;
  List<String> _order = [..._modules];
  Set<String> _hidden = {};
  Timer? _clock;
  late final _cardsScroll = _railController();
  late final _songsScroll = _railController();

  ScrollController _railController() => ScrollController(
    onAttach: (_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    },
  );

  Widget _railButtons(ScrollController controller) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      void page(int direction) {
        if (!controller.hasClients) return;
        final position = controller.position;
        controller.animateTo(
          (position.pixels + direction * position.viewportDimension * .8).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
          duration: Durations.long2,
          curve: Easing.emphasizedDecelerate,
        );
      }

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: AppScope.of(context)
                .text('common.actions.previous', 'Previous'),
            onPressed: controller.hasClients && controller.offset > 0
                ? () => page(-1)
                : null,
            icon: const Icon(Symbols.chevron_left_rounded),
          ),
          IconButton(
            tooltip: AppScope.of(context).text('common.actions.next', 'Next'),
            onPressed:
                controller.hasClients &&
                    controller.offset < controller.position.maxScrollExtent
                ? () => page(1)
                : null,
            icon: const Icon(Symbols.chevron_right_rounded),
          ),
        ],
      );
    },
  );

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        setState(() {});
      }
    });
    SharedPreferences.getInstance().then((prefs) {
      try {
        final state = jsonDecode(prefs.getString(_layoutKey) ?? 'null');
        if (state is! Map || !mounted) return;
        final order = [
          for (final id in state['order'] as List? ?? const [])
            if (_modules.contains(id == 'news' ? 'arena' : id))
              id == 'news' ? 'arena' : '$id',
        ];
        setState(() {
          if (order.toSet().length == order.length) {
            _order = [...order, ..._modules.where((m) => !order.contains(m))];
          }
          _hidden = {
            for (final MapEntry(:key, :value)
                in ((state['hidden'] as Map?) ?? const {}).entries)
              if (value == true) '$key',
          };
        });
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _cardsScroll.dispose();
    _songsScroll.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _layoutKey,
      jsonEncode({
        'order': _order,
        'hidden': {for (final id in _hidden) id: true},
      }),
    );
  }

  /// The five recommended posts the website's home lists (`renderCommunity`).
  Future<List<Map<String, Object?>>> _loadCommunity() async {
    final state = AppScope.of(context);
    final uri = Uri.https('haneoka.org', '/api/v1/community/posts', {
      'limit': '5',
      'scope': 'recommended',
      'kind': 'post',
      'server': CatalogSourceScope.serverOf(context),
      'locale': state.text.locale,
    });
    final response = await netClient
        .get(uri, headers: {'accept': 'application/json'})
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200 || body is! Map) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final entries = body['entries'];
    return entries is List
        ? [
            for (final entry in entries.whereType<Map>())
              if (entry['kind'] == 'post' && entry['post'] is Map)
                (entry['post'] as Map).cast<String, Object?>(),
          ]
        : [
            for (final post
                in (body['posts'] as List? ?? const []).whereType<Map>())
              post.cast<String, Object?>(),
          ];
  }

  /// bandori.fans entries the website's home seed carries.
  Future<List<Map<String, Object?>>> _loadFanInfo() async {
    final seed = (await _data!).seed;
    return [
      for (final entry
          in ((seed['fanInfo'] as Map?)?['entries'] as List? ?? const [])
              .whereType<Map>())
        if ('${entry['title'] ?? ''}'.isNotEmpty &&
            '${entry['href'] ?? ''}'.startsWith('https://bandori.fans/'))
          entry.cast<String, Object?>(),
    ].take(8).toList();
  }

  Object? _dataKey, _communityKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = CatalogSourceScope.keyOf(context);
    if (_dataKey != key) {
      _dataKey = key;
      _data = _load();
      _fanInfo = _loadFanInfo();
    }
    final communityKey = (
      CatalogSourceScope.serverOf(context),
      AppScope.of(context).text.locale,
    );
    if (_communityKey != communityKey) {
      _communityKey = communityKey;
      _community = _loadCommunity()..ignore();
    }
  }

  Future<_HomeData> _load() async {
    final state = AppScope.of(context);
    final api = CatalogSourceScope.apiOf(context);
    final seed = await pageData(
      '/${CatalogSourceScope.serverOf(context)}/${state.text.locale}/',
      'data-home-seed',
      attribute: true,
    ).catchError((_) => <String, Object?>{});
    const keys = ['home-banners', 'events', 'songs', 'cards', 'support-cards'];
    final documents =
        (seed['documents'] as Map?)?.cast<String, Object?>() ?? {};
    final results = await Future.wait([
      for (final key in keys)
        documents[key] != null
            ? Future<Object?>.value(documents[key])
            : api.catalog(key).then<Object?>((v) => v, onError: (_) => null),
    ]);
    return _HomeData(
      {for (final (i, key) in keys.indexed) key: results[i]},
      await CatalogVisuals.of(api),
      seed,
    );
  }

  void _browse(String route) {
    final api = CatalogSourceScope.maybeApi(context);
    widget.onBrowse?.call(
      api == null
          ? route
          : Uri.parse(route)
                .replace(
                  queryParameters: {
                    ...Uri.parse(route).queryParameters,
                    'server': api.server,
                  },
                )
                .toString(),
    );
  }

  void _open(BuildContext context, String resource, Entry item) {
    final profile = _profile(resource);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          profile: profile,
          id: '${firstOf(item, profile.id) ?? item['_key']}',
          summary: item,
          api: item[serverKey] is String
              ? AppScope.of(context).apiFor(item[serverKey] as String)
              : CatalogSourceScope.apiOf(context),
        ),
      ),
    );
  }

  String _label(SiteText t, String id) => switch (id) {
    'songs' => t('home.dashboard.latestSongs', 'Latest songs'),
    'cards' => t('home.dashboard.latestCards', 'Latest cards'),
    'birthdays' => t('home.dashboard.birthdaysTitle', 'Birthday countdown'),
    'community' => t('home.dashboard.communityTitle', 'Trending community'),
    'fanInfo' => 'bandori.fans',
    _ => t('catalog.arena.title', 'Gekiso Arena'),
  };

  /// Module order and visibility (`home-layout-dialog`).
  Future<void> _customize(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, refresh) {
        final t = AppScope.of(context).text;
        void update(VoidCallback change) {
          setState(change);
          refresh(() {});
          _persist();
        }

        return AlertDialog(
          icon: const Icon(Symbols.dashboard_customize_rounded),
          title: Text(t('home.dashboard.customizeLayout', 'Customize layout')),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (index, id) in _order.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: IconButton(
                      tooltip: _hidden.contains(id)
                          ? t('home.dashboard.showModule', 'Show module')
                          : t('home.dashboard.hideModule', 'Hide module'),
                      onPressed: () => update(
                        () => _hidden.contains(id)
                            ? _hidden.remove(id)
                            : _hidden.add(id),
                      ),
                      icon: Icon(
                        _hidden.contains(id)
                            ? Symbols.visibility_off_rounded
                            : Symbols.visibility_rounded,
                      ),
                    ),
                    title: Text(
                      _label(t, id),
                      style: _hidden.contains(id)
                          ? TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            )
                          : null,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: t('home.dashboard.moveUp', 'Move up'),
                          onPressed: index == 0
                              ? null
                              : () => update(
                                  () => _order.insert(
                                    index - 1,
                                    _order.removeAt(index),
                                  ),
                                ),
                          icon: const Icon(Symbols.arrow_upward_rounded),
                        ),
                        IconButton(
                          tooltip: t('home.dashboard.moveDown', 'Move down'),
                          onPressed: index == _order.length - 1
                              ? null
                              : () => update(
                                  () => _order.insert(
                                    index + 1,
                                    _order.removeAt(index),
                                  ),
                                ),
                          icon: const Icon(Symbols.arrow_downward_rounded),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => update(() {
                _order = [..._modules];
                _hidden = {};
              }),
              child: Text(
                t('home.dashboard.resetLayout', 'Restore default layout'),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('common.actions.done', 'Done')),
            ),
          ],
        );
      },
    ),
  );

  Widget _communityModule(BuildContext context, SiteText t) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Module(
      framed: true,
      icon: Symbols.forum_rounded,
      title: t('home.dashboard.communityTitle', 'Trending community'),
      viewAll: t('home.dashboard.openCommunity', 'Open community'),
      onViewAll: () => _browse('/community/feeds'),
      child: FutureBuilder(
        future: _community,
        builder: (context, snapshot) {
          final posts = snapshot.data;
          if (posts == null || posts.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                posts == null && !snapshot.hasError
                    ? ''
                    : snapshot.hasError
                    ? t('home.dashboard.sourceUnavailable', 'Unavailable')
                    : t(
                        'home.dashboard.communityEmpty',
                        'There are no public community posts yet.',
                      ),
                textAlign: TextAlign.center,
              ),
            );
          }
          return _FitRows(
            extent: 80,
            children: [
              for (final (index, post) in posts.take(5).indexed)
                ListTile(
                  onTap: () =>
                      openLink(context, '/community/posts/${post['id']}'),
                  leading: Text(
                    '${index + 1}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                  title: Text(
                    '${post['title'] ?? post['excerpt'] ?? '—'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      '${post['authorName'] ?? ''}',
                      if (formatCommunityTime(
                            post['lastEditedAt'] ?? post['createdAt'],
                            t.locale,
                          )
                          case final time?)
                        time.text,
                    ].where((s) => s.isNotEmpty).join(' · '),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Symbols.favorite_rounded, size: 16),
                      Text(' ${post['likeCount'] ?? 0}  '),
                      const Icon(Symbols.chat_bubble_rounded, size: 16),
                      Text(' ${post['commentCount'] ?? 0}'),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// `fanSummary`: when and where, or the entry's own line.
  String _fanSummary(Map<String, Object?> entry, SiteText t) {
    final start = entry['eventStartAtMs'];
    final day = '${entry['eventDate'] ?? ''}';
    String date = '';
    if (entry['allDay'] != true && start is num) {
      date = SiteDate.day(t.locale)
          .withTime()
          .format(DateTime.fromMillisecondsSinceEpoch(start.toInt()));
    } else if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
      date = SiteDate.day(t.locale).format(DateTime.parse(day));
    }
    if (date.isNotEmpty) {
      return [
        date,
        '${entry['venue'] ?? ''}',
      ].where((s) => s.isNotEmpty).join(' · ');
    }
    return '${entry['summary'] ?? ''}'.isNotEmpty
        ? '${entry['summary']}'
        : (const {'live', 'real-live'}.contains(entry['category'])
              ? t('tools.calendar.live', 'Live')
              : '');
  }

  /// The current season: each league's rule now and at the next rotation.
  Widget _arenaModule(
    BuildContext context,
    SiteText t,
    Map<String, Object?>? seed,
  ) {
    final theme = Theme.of(context);
    final api = CatalogSourceScope.apiOf(context);
    final arena = (seed?['arena'] as Map?)?.cast<String, Object?>();
    final catalog = (arena?['catalog'] as Map?)?.cast<String, Object?>();
    final now = DateTime.now().millisecondsSinceEpoch;
    final seasons = dataRows(catalog?['entries'])
      ..sort((a, b) => intOf(a['startAt']) - intOf(b['startAt']));
    final season =
        seasons.where((s) => arenaWindowContains(s, now)).firstOrNull ??
        seasons.where((s) => intOf(s['startAt']) > now).firstOrNull ??
        seasons.lastOrNull;
    void open([int? band]) =>
        _browse(band == null ? '/catalog/arena' : '/catalog/arena?band=$band');
    if (season == null) {
      return _Module(
        icon: Symbols.emoji_events_rounded,
        title: t('catalog.arena.title', 'Gekiso Arena'),
        child: Center(child: Text(t('common.states.unavailable'))),
      );
    }
    final live = arenaWindowContains(season, now);
    final periods = arenaPeriods(season);
    final rotation = live
        ? periods.where((p) => p.start > now).firstOrNull
        : null;
    final missions = ((catalog?['images'] as Map?)?['missions'] as Map?) ?? {};
    String span(int until) {
      final minutes = ((until - now) / 60000).round().clamp(0, 1 << 31);
      final days = minutes ~/ 1440, hours = (minutes % 1440) ~/ 60;
      return days > 0
          ? t('catalog.arena.remainingDays', '{days}d {hours}h', {
              'days': days,
              'hours': hours,
            })
          : t('catalog.arena.remainingHours', '{hours}h {minutes}m', {
              'hours': hours,
              'minutes': minutes % 60,
            });
    }

    Widget mark(Object? source, double size) => SizedBox(
      width: size,
      height: size,
      child: source == null
          ? null
          : AppImage(candidates: [api.asset('$source').toString()]),
    );
    Widget rule(Doc? value, {bool next = false}) {
      final id = intListOf(value?['missions']).firstOrNull;
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          if (next) const Icon(Symbols.arrow_forward_rounded, size: 12),
          mark(missions['$id'], next ? 16 : 18),
          Text(
            ['', 'COMBO', 'LUCK', 'JUST'].elementAtOrNull(id ?? 0) ?? '',
            style: next
                ? theme.textTheme.labelSmall
                : theme.textTheme.labelMedium,
          ),
        ],
      );
    }

    final leagues = dataRows(season['leagues']);
    return _Module(
      icon: Symbols.emoji_events_rounded,
      title: t('catalog.arena.title', 'Gekiso Arena'),
      viewAll: t('home.dashboard.viewAll', 'View all'),
      onViewAll: open,
      framed: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  t.text(season['title']),
                  style: theme.textTheme.labelLarge,
                ),
                Text(
                  t(
                    live
                        ? 'catalog.arena.status.current'
                        : 'catalog.arena.status.upcoming',
                  ),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                Text(
                  live
                      ? span(intOf(season['endAt']) + 1000)
                      : span(intOf(season['startAt'])),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            for (final (index, league) in leagues.indexed)
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(Corner.small),
                  onTap: () => open(intOf(league['bandId'])),
                  child: Row(
                    spacing: 8,
                    children: [
                      mark(league['image'], 24),
                      Expanded(
                        child: Text(
                          t.text(league['name']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      rule(
                        arenaRuleAt(
                          season,
                          league,
                          live ? now : intOf(season['startAt']),
                        ),
                      ),
                      if (rotation != null)
                        rule(rotation.rules.elementAtOrNull(index), next: true),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fanInfoModule(BuildContext context, SiteText t) => _Module(
    framed: true,
    icon: Symbols.feed_rounded,
    title: 'bandori.fans',
    viewAll: 'bandori.fans',
    onViewAll: () => launchUrl(
      Uri.parse('https://bandori.fans/'),
      mode: LaunchMode.externalApplication,
    ),
    child: FutureBuilder(
      future: _fanInfo,
      builder: (context, snapshot) {
        final entries = snapshot.data;
        if (entries == null || entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              entries == null && !snapshot.hasError
                  ? ''
                  : snapshot.hasError
                  ? t('home.dashboard.sourceUnavailable', 'Unavailable')
                  : t('home.dashboard.fanInfoEmpty', 'No current updates.'),
              textAlign: TextAlign.center,
            ),
          );
        }
        return _FitRows(
          extent: 80,
          children: [
            for (final entry in entries)
              ListTile(
                onTap: () => launchUrl(
                  Uri.parse('${entry['href']}'),
                  mode: LaunchMode.externalApplication,
                ),
                leading: switch (entry['image']) {
                  final String image
                      when RegExp(r'^/images/calendar-lives/[a-f0-9]{64}\.png$')
                          .hasMatch(image) =>
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 72,
                        height: 42,
                        child: AppImage(
                          candidates: ['https://haneoka.org$image'],
                          fit: BoxFit.cover,
                          localized: false,
                        ),
                      ),
                    ),
                  _ => null,
                },
                title: Text(
                  '${entry['title']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_fanSummary(entry, t)),
                trailing: const Icon(Symbols.open_in_new_rounded, size: 18),
              ),
          ],
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    return ShellPage(
      title: t('home.dashboard.overview', 'Home'),
      actions: [
        BarAction(
          icon: Symbols.sports_esports_rounded,
          image: Image.asset(
            'assets/settings/sonolus-icon.png',
            width: 24,
            height: 24,
          ),
          label: t('navigation.sonolus', 'Sonolus'),
          onPressed: () => launchUrl(
            Uri.parse('https://open.sonolus.com/haneoka.org'),
            mode: LaunchMode.externalApplication,
          ),
        ),
        BarAction(
          icon: Symbols.description_rounded,
          label: t('navigation.help', 'Help'),
          onPressed: () => launchUrl(
            Uri.parse(
              'https://docs.haneoka.org/${t.locale.startsWith('zh') ? 'zh-cn/' : ''}',
            ),
            mode: LaunchMode.externalApplication,
          ),
        ),
        BarAction(
          icon: Symbols.code_rounded,
          image: SvgPicture.asset(
            'assets/brand/oauth/github.svg',
            width: 24,
            height: 24,
            colorFilter: ColorFilter.mode(
              Theme.of(context).colorScheme.onSurface,
              BlendMode.srcIn,
            ),
          ),
          label: 'GitHub',
          onPressed: () => launchUrl(
            Uri.parse('https://github.com/haneoka-gakuen/haneoka'),
            mode: LaunchMode.externalApplication,
          ),
        ),
        BarAction(
          icon: Symbols.dashboard_customize_rounded,
          label: t('home.dashboard.customizeLayout', 'Customize layout'),
          onPressed: () => _customize(context),
        ),
      ],
      body: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return snapshot.hasError
                ? Center(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Symbols.refresh_rounded),
                      label: Text(t('common.actions.retry', 'Retry')),
                      onPressed: () => setState(() => _data = _load()),
                    ),
                  )
                : const Center(child: CircularProgressIndicator());
          }
          final now = DateTime.now().millisecondsSinceEpoch;
          final banners =
              [
                for (final b in data.rows('home-banners', 'entries'))
                  if (b['image'] is String &&
                      ((RelativeTime.timestamp(b['endAt']) ??
                              double.infinity) >=
                          now))
                    b,
              ]..sort(
                (a, b) =>
                    (RelativeTime.timestamp(a['endAt']) ?? double.infinity)
                        .compareTo(
                          RelativeTime.timestamp(b['endAt']) ?? double.infinity,
                        ),
              );
          final events = data.rows('events', 'entries');
          final ongoing =
              events
                  .where(
                    (e) =>
                        (RelativeTime.timestamp(e['startAt']) ??
                                double.infinity) <=
                            now &&
                        (RelativeTime.timestamp(e['endAt']) ?? 0) >= now,
                  )
                  .toList()
                ..sort(
                  (a, b) => (RelativeTime.timestamp(a['endAt']) ?? 0).compareTo(
                    RelativeTime.timestamp(b['endAt']) ?? 0,
                  ),
                );
          final upcoming =
              events
                  .where(
                    (e) => (RelativeTime.timestamp(e['startAt']) ?? 0) > now,
                  )
                  .toList()
                ..sort(
                  (a, b) => (RelativeTime.timestamp(a['startAt']) ?? 0)
                      .compareTo(RelativeTime.timestamp(b['startAt']) ?? 0),
                );
          final ended =
              events
                  .where(
                    (e) =>
                        (RelativeTime.timestamp(e['endAt']) ?? 0) > 0 &&
                        (RelativeTime.timestamp(e['endAt']) ??
                                double.infinity) <
                            now,
                  )
                  .toList()
                ..sort(
                  (a, b) => (RelativeTime.timestamp(b['endAt']) ?? 0).compareTo(
                    RelativeTime.timestamp(a['endAt']) ?? 0,
                  ),
                );
          final event =
              ongoing.firstOrNull ?? upcoming.firstOrNull ?? ended.firstOrNull;
          final songPresentation = SongPresentation(
            t,
            CatalogSourceScope.apiOf(context),
            data.visuals,
          );
          final songKit = CatalogKit(
            _profile('songs'),
            t,
            CatalogSourceScope.apiOf(context),
            data.visuals,
            songTitles: state.songTitle,
          );
          final songs = data.rows('songs')
            ..sort((a, b) {
              final date = (songKit.releasedAt(b) ?? 0).compareTo(
                songKit.releasedAt(a) ?? 0,
              );
              return date != 0 ? date : _numericId(b).compareTo(_numericId(a));
            });
          final cardKit = CatalogKit(
            _profile('cards'),
            t,
            CatalogSourceScope.apiOf(context),
            data.visuals,
          );
          final snapKit = CatalogKit(
            _profile('support-cards'),
            t,
            CatalogSourceScope.apiOf(context),
            data.visuals,
          );
          final cards =
              [
                for (final c in data.rows('cards')) (c, cardKit, 'cards'),
                for (final c in data.rows('support-cards'))
                  (c, snapKit, 'support-cards'),
              ]..sort((a, b) {
                final date = (b.$2.releasedAt(b.$1) ?? 0).compareTo(
                  a.$2.releasedAt(a.$1) ?? 0,
                );
                if (date != 0) return date;
                if (a.$3 != b.$3) return a.$3 == 'support-cards' ? -1 : 1;
                return _numericId(b.$1).compareTo(_numericId(a.$1));
              });
          return LayoutBuilder(
            builder: (context, pane) {
              final inset = pane.maxWidth < 600 ? 12.0 : 24.0;
              return RefreshIndicator(
                onRefresh: () async {
                  setState(() {
                    _data = _load();
                    _community = _loadCommunity()..ignore();
                    _fanInfo = _loadFanInfo();
                  });
                  await _data;
                },
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        inset +
                            ((pane.maxWidth - 1440) / 2).clamp(
                              0,
                              double.infinity,
                            ),
                        pane.maxWidth < 600 ? 4 : 8,
                        inset +
                            ((pane.maxWidth - 1440) / 2).clamp(
                              0,
                              double.infinity,
                            ),
                        24,
                      ),
                      sliver: SliverMainAxisGroup(
                        slivers: [
                          SliverList.list(
                            children: [
                              _Spotlight(
                                children: [
                                  if (banners.isNotEmpty)
                                    _Carousel(
                                      banners: banners,
                                      t: t,
                                      api: CatalogSourceScope.apiOf(context),
                                    ),
                                  if (event != null)
                                    _EventCard(
                                      event: event,
                                      t: t,
                                      api: state.apiFor(
                                        '${event[serverKey] ?? CatalogSourceScope.serverOf(context)}',
                                      ),
                                      visuals: data.visuals,
                                      onOpen: () =>
                                          _open(context, 'events', event),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              _HomeBoard(
                                modules: [
                                  for (final id in _order)
                                    if (!_hidden.contains(id))
                                      (
                                        id,
                                        switch (id) {
                                          'birthdays' => _Birthdays(
                                            data: data,
                                            t: t,
                                            api: CatalogSourceScope.apiOf(
                                              context,
                                            ),
                                          ),
                                          'arena' => _arenaModule(
                                            context,
                                            t,
                                            snapshot.data?.seed,
                                          ),
                                          'songs' => _Module(
                                            aside: _railButtons(_songsScroll),
                                            icon: Symbols.library_music_rounded,
                                            title: t(
                                              'home.dashboard.latestSongs',
                                              'Latest songs',
                                            ),
                                            viewAll: t(
                                              'home.dashboard.viewAll',
                                              'View all',
                                            ),
                                            onViewAll: () => widget.onBrowse
                                                ?.call('/catalog/songs'),
                                            child: _Rail(
                                              width: 148,
                                              controller: _songsScroll,
                                              aspectRatio: 1,
                                              children: [
                                                for (final song in songs.take(
                                                  12,
                                                ))
                                                  Tile(
                                                    rail: true,
                                                    title: songKit.title(song),
                                                    subtitle: songPresentation
                                                        .artist(song),
                                                    adornments: songPresentation
                                                        .avatars(song),
                                                    images: songKit.images(
                                                      song,
                                                    ),
                                                    placeholder:
                                                        Symbols.album_rounded,
                                                    marks: [
                                                      ...songPresentation.marks(
                                                        song,
                                                        categoryAt: MarkAt.end,
                                                      ),
                                                      if (t.release(
                                                            song['publishedAt'],
                                                          )
                                                          case final r
                                                          when r.isNotEmpty)
                                                        TileMark.text(
                                                          MarkAt.bottomStart,
                                                          r,
                                                        ),
                                                    ],
                                                    onTap: () => _open(
                                                      context,
                                                      'songs',
                                                      song,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          'cards' => _Module(
                                            aside: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                TextButton(
                                                  onPressed: () => _browse(
                                                    '/catalog/member-cards',
                                                  ),
                                                  child: Text(
                                                    t(
                                                      'navigation.memberCards',
                                                      'Members',
                                                    ),
                                                  ),
                                                ),
                                                TextButton(
                                                  onPressed: () => _browse(
                                                    '/catalog/support-cards',
                                                  ),
                                                  child: Text(
                                                    t(
                                                      'navigation.supportCards',
                                                      'Snapshot',
                                                    ),
                                                  ),
                                                ),
                                                _railButtons(_cardsScroll),
                                              ],
                                            ),
                                            icon: Symbols.style_rounded,
                                            title: t(
                                              'home.dashboard.latestCards',
                                              'Latest cards',
                                            ),
                                            child: _Rail(
                                              width: 148,
                                              controller: _cardsScroll,
                                              aspectRatio: 1,
                                              children: [
                                                for (final (card, kit, resource)
                                                    in cards.take(12))
                                                  Tile(
                                                    rail: true,
                                                    title: kit.title(card),
                                                    subtitle: kit.subtitle(
                                                      card,
                                                    ),
                                                    adornments: kit.adornments(
                                                      card,
                                                    ),
                                                    images: kit.images(card),
                                                    aspectRatio: 1,
                                                    fit: BoxFit.contain,
                                                    marks: [
                                                      ...kit.marks(card),
                                                      if (t.release(
                                                            kit.releasedAt(
                                                              card,
                                                            ),
                                                          )
                                                          case final date
                                                          when date.isNotEmpty)
                                                        TileMark.text(
                                                          MarkAt.bottomStart,
                                                          date,
                                                        ),
                                                    ],
                                                    onTap: () => _open(
                                                      context,
                                                      resource,
                                                      card,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          'community' => _communityModule(
                                            context,
                                            t,
                                          ),
                                          'fanInfo' => _fanInfoModule(
                                            context,
                                            t,
                                          ),
                                          _ => const SizedBox.shrink(),
                                        },
                                      ),
                                ],
                              ),
                              const SizedBox(height: 24),
                            ],
                          ),
                          DestinationMosaic(
                            section: 'home',
                            navigate: (route) => _browse(route),
                            sliver: true,
                            padding: EdgeInsets.zero,
                          ),
                          SliverToBoxAdapter(
                            child: _HomeIndex(onBrowse: _browse, t: t),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// A home module: the section heading with View all, then its content.
class _Module extends StatelessWidget {
  const _Module({
    required this.icon,
    required this.title,
    required this.child,
    this.viewAll,
    this.onViewAll,
    this.framed = false,
    this.aside,
  });
  final IconData icon;
  final String title;
  final String? viewAll;
  final VoidCallback? onViewAll;
  final Widget child;
  final bool framed;
  final Widget? aside;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.zero,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Corner.extraLarge),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    ShapedIcon(
                      shape: MaterialShapes.cookie9Sided,
                      size: 36,
                      color: theme.colorScheme.secondaryContainer,
                      child: Icon(
                        icon,
                        size: 20,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onViewAll != null)
                      IconButton(
                        tooltip: viewAll,
                        onPressed: onViewAll,
                        icon: const Icon(Symbols.arrow_forward_rounded),
                      ),
                    ?aside,
                  ],
                ),
              ),
              const SizedBox(height: 4),
              if (framed) Expanded(child: ClipRect(child: child)) else child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A horizontal filmstrip of tiles.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.width,
    required this.aspectRatio,
    required this.children,
    this.controller,
  });
  final ScrollController? controller;
  final double width;
  final double aspectRatio;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < ShellMetrics.compact;
    return LayoutBuilder(
      builder: (context, box) {
        final tileWidth = (box.maxWidth * .15).clamp(132.0, 176.0);
        final height =
            tileWidth / aspectRatio +
            (compact ? 24 + 48 + 4 + 20 : 32 + 48 + 8 + 20);
        return SizedBox(
          height: height,
          child: ListView.separated(
            controller: controller,
            scrollDirection: Axis.horizontal,
            itemCount: children.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) =>
                SizedBox(width: tileWidth, child: children[index]),
          ),
        );
      },
    );
  }
}

/// The banners the game is showing now, advancing on their own.
class _Carousel extends StatefulWidget {
  const _Carousel({required this.banners, required this.t, required this.api});
  final List<Entry> banners;
  final SiteText t;
  final HaneokaApi api;
  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final _pages = PageController();
  Timer? _timer;
  int _index = 0;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!_pages.hasClients ||
          widget.banners.length < 2 ||
          _hovered ||
          MediaQuery.disableAnimationsOf(context) ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      _go(_index + 1);
    });
  }

  void _go(int index) {
    if (!_pages.hasClients || widget.banners.isEmpty) return;
    final next = index % widget.banners.length;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(next);
    } else {
      _pages.animateToPage(
        next,
        duration: Durations.long2,
        curve: Easing.emphasizedDecelerate,
      );
    }
  }

  @override
  void didUpdateWidget(_Carousel old) {
    super.didUpdateWidget(old);
    if (_index >= widget.banners.length) {
      _index = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients) _pages.jumpToPage(0);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Corner.extraLarge),
        child: AspectRatio(
          aspectRatio: 7 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                controller: _pages,
                itemCount: widget.banners.length,
                onPageChanged: (index) => setState(() => _index = index),
                itemBuilder: (context, index) {
                  final banner = widget.banners[index];
                  final window = widget.t.window(
                    banner['startAt'],
                    banner['endAt'],
                  );
                  final href = '${banner['href'] ?? ''}';
                  return Material(
                    child: InkWell(
                      onTap: href.isEmpty
                          ? null
                          : () => openLink(context, href),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          AppImage(
                            candidates: [
                              widget.api.asset('${banner['image']}').toString(),
                            ],
                            fit: BoxFit.cover,
                          ),
                          if (window.isNotEmpty)
                            Positioned(
                              left: 12,
                              bottom: 36,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(
                                    Corner.small,
                                  ),
                                ),
                                child: Text(
                                  window,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (widget.banners.length > 1) ...[
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 4,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < widget.banners.length; i++)
                        Semantics(
                          selected: i == _index,
                          child: InkWell(
                            onTap: () => _go(i),
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: AnimatedContainer(
                                duration: Durations.medium2,
                                width: i == _index ? 24 : 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: i == _index
                                      ? scheme.primary
                                      : scheme.outlineVariant,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_hovered ||
                    Theme.of(context).platform == TargetPlatform.android ||
                    Theme.of(context).platform == TargetPlatform.iOS) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton.filledTonal(
                      tooltip: widget.t('common.actions.previous', 'Previous'),
                      onPressed: () => _go(_index - 1),
                      icon: const Icon(Symbols.chevron_left_rounded),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton.filledTonal(
                      tooltip: widget.t('common.actions.next', 'Next'),
                      onPressed: () => _go(_index + 1),
                      icon: const Icon(Symbols.chevron_right_rounded),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.t,
    required this.api,
    required this.visuals,
    this.onOpen,
  });
  final Entry event;
  final SiteText t;
  final HaneokaApi api;
  final CatalogVisuals visuals;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final window = t.window(event['startAt'], event['endAt']);
    final start = RelativeTime.timestamp(event['startAt']);
    final end = RelativeTime.timestamp(event['endAt']);
    final progress = start != null && end != null && end > start
        ? ((DateTime.now().millisecondsSinceEpoch - start) / (end - start))
              .clamp(0.0, 1.0)
        : null;
    final effects = event['effects'];
    final targetRows = <Map>[
      for (final effect
          in (effects is Map
                  ? effects.values
                  : effects is List
                  ? effects
                  : const [])
              .whereType<Map>())
        ...((effect['targets'] as Map?)?.values.whereType<Map>() ??
            const <Map>[]),
    ];
    final targets = {
      for (final target in targetRows)
        '${target['homeTargetKind'] ?? target['kind']}:${target['resourceId'] ?? target['bandId'] ?? target['cardType'] ?? t.text(target['name'])}':
            target,
    }.values;
    final bands = targets
        .where((target) => target['homeTargetKind'] == 'band')
        .map((target) => target['bandId'])
        .toSet();
    final characters = visuals.characters.values.where(
      (c) => bands.contains(c['bandId']),
    );
    Widget bonusTarget(Map target) {
      final band = visuals.bands[target['bandId']];
      final image = target['homeTargetKind'] == 'band'
          ? visuals.bandIcon(target['bandId']) ?? target['icon']
          : target['image'] ?? visuals.cardTypeMark(target['cardType']);
      final name = t.text(target['name']);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (image is String && image.isNotEmpty)
            SizedBox.square(
              dimension: 20,
              child: AppImage(candidates: [api.asset(image).toString()]),
            ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              name.isNotEmpty ? name : t.text(band?['bandName']),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      );
    }

    Widget chip(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Corner.small),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: (constraints.maxWidth * 3 / 7).clamp(184.0, double.infinity),
        child: Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Corner.extraLarge),
          clipBehavior: Clip.antiAlias,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                child: InkWell(
                  onTap: onOpen,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      EventArtwork(
                        background: api
                            .asset(
                              '${event['backgroundImage'] ?? event['image'] ?? ''}',
                            )
                            .toString(),
                        logoWidth: 0.86,
                        logo: event['logo'] is String
                            ? api.asset('${event['logo']}').toString()
                            : '',
                      ),
                      Positioned(
                        left: 8,
                        top: 8,
                        child: chip(t('navigation.events', 'Events')),
                      ),
                      if (window.isNotEmpty)
                        Positioned(
                          left: 8,
                          bottom: 8,
                          right: 8,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: chip(window),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final tight = box.maxHeight < 240 || box.maxWidth < 280;
                    return Padding(
                      padding: EdgeInsets.all(tight ? 8 : 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          InkWell(
                            onTap: onOpen,
                            child: Text(
                              t.text(event['title']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tight
                                  ? theme.textTheme.titleMedium
                                  : theme.textTheme.titleLarge,
                            ),
                          ),
                          if (start != null &&
                              end != null &&
                              box.maxHeight > 125)
                            Text(
                              '${SiteDate.day(t.locale).format(DateTime.fromMillisecondsSinceEpoch(start.toInt()))} – ${SiteDate.day(t.locale).format(DateTime.fromMillisecondsSinceEpoch(end.toInt()))}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          const SizedBox(height: 8),
                          if (progress != null)
                            LinearProgressIndicator(
                              value: progress,
                              borderRadius: BorderRadius.circular(Corner.full),
                            ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        for (final target in targets.where(
                                          (target) => const {
                                            'band',
                                            'attribute',
                                          }.contains(target['homeTargetKind']),
                                        ))
                                          bonusTarget(target),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        for (final character in characters)
                                          Tooltip(
                                            message: t.text(
                                              character['characterName'],
                                            ),
                                            child: InkWell(
                                              onTap: () => openLink(
                                                context,
                                                '/${api.server}/${t.locale}/characters/${character['characterId']}/',
                                              ),
                                              child: ClipOval(
                                                child: SizedBox.square(
                                                  dimension: tight ? 24 : 32,
                                                  child: AppImage(
                                                    candidates: [
                                                      api
                                                          .asset(
                                                            '${character['faceImage']}',
                                                          )
                                                          .toString(),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              for (final (index, action)
                                  in <(IconData, String, VoidCallback)>[
                                    (
                                      Symbols.event_note_rounded,
                                      t(
                                        'home.dashboard.viewDetails',
                                        'View details',
                                      ),
                                      () => onOpen?.call(),
                                    ),
                                    (
                                      Symbols.monitoring_rounded,
                                      t(
                                        'home.dashboard.eventTracker',
                                        'Event tracker',
                                      ),
                                      () => openLink(
                                        context,
                                        '/${api.server}/${t.locale}/events/tracker/',
                                      ),
                                    ),
                                    (
                                      Symbols.auto_stories_rounded,
                                      t(
                                        'story.labels.eventStory',
                                        'Event story',
                                      ),
                                      () => openLink(
                                        context,
                                        event['homeStoryId'] is String &&
                                                '${event['homeStoryId']}'
                                                    .isNotEmpty
                                            ? '/${api.server}/${t.locale}/stories/${event['homeStoryId']}/'
                                            : '/${api.server}/${t.locale}/catalog/stories/event/',
                                      ),
                                    ),
                                  ].indexed) ...[
                                if (index > 0) const SizedBox(width: 2),
                                Expanded(
                                  child: Tooltip(
                                    message: action.$2,
                                    child: FilledButton.tonal(
                                      style: FilledButton.styleFrom(
                                        minimumSize: const Size(0, 48),
                                        backgroundColor: index == 0
                                            ? scheme.primary
                                            : null,
                                        foregroundColor: index == 0
                                            ? scheme.onPrimary
                                            : null,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 4,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.horizontal(
                                            left: Radius.circular(
                                              index == 0 ? 24 : 6,
                                            ),
                                            right: Radius.circular(
                                              index == 2 ? 24 : 6,
                                            ),
                                          ),
                                        ),
                                      ),
                                      onPressed: action.$3,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(action.$1, size: 20),
                                          Text(
                                            action.$2,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color: index == 0
                                                      ? scheme.onPrimary
                                                      : scheme
                                                            .onSecondaryContainer,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The next birthdays, nearest first.
class _Birthday {
  const _Birthday(
    this.key,
    this.name,
    this.character,
    this.at,
    this.cast,
    this.announced,
    this.pool,
    this.card,
  );
  final String key, name;
  final Entry? character, pool, card;
  final int at;
  final bool cast, announced;
}

class _Birthdays extends StatefulWidget {
  const _Birthdays({required this.data, required this.t, required this.api});
  final _HomeData data;
  final SiteText t;
  final HaneokaApi api;
  @override
  State<_Birthdays> createState() => _BirthdaysState();
}

class _BirthdaysState extends State<_Birthdays> {
  String? _selected;
  static const _day = 86400000, _offset = 9 * 3600000;
  int? _at(int year, int month, int day) {
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date.millisecondsSinceEpoch - _offset;
  }

  int? _nearest(int month, int day, int reference) {
    final year = DateTime.fromMillisecondsSinceEpoch(
      reference + _offset,
      isUtc: true,
    ).year;
    final candidates = [
      for (var y = year - 1; y <= year + 1; y++) ?_at(y, month, day),
    ]..sort((a, b) => (a - reference).abs().compareTo((b - reference).abs()));
    return candidates.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data, t = widget.t, api = widget.api;
    final now = DateTime.now().millisecondsSinceEpoch;
    final today = ((now + _offset) ~/ _day) * _day - _offset;
    final year = DateTime.fromMillisecondsSinceEpoch(
      now + _offset,
      isUtc: true,
    ).year;
    Entry? characterFor(Map profile) {
      String plain(Object? text) =>
          t.textIn(text, 'ja').replaceAll(RegExp(r'[\s・]'), '');
      return data.visuals.characters.values
          .where((c) => plain(c['characterName']) == plain(profile['name']))
          .firstOrNull;
    }

    final characters = data.visuals.characters.values;
    final cards = data
        .rows('cards')
        .where(
          (c) =>
              c['rarity'] == 20 &&
              (c[serverKey] == null || c[serverKey] == api.server),
        )
        .toList();
    final periods = <(int, int?, int, int, Entry)>[];
    for (final pool in data.rows('gacha', 'entries')) {
      final featured = pool['featured'];
      for (final prize
          in (featured is Map
                  ? featured.values
                  : featured is List
                  ? featured
                  : const [])
              .whereType<Map>()) {
        if (prize['resourceType'] != 2 || prize['pickup'] == false) continue;
        final card = cards
            .where((c) => c['cardId'] == prize['resourceId'])
            .firstOrNull;
        if ((prize['rarity'] ?? card?['rarity']) != 20) continue;
        final id = prize['characterId'] ?? card?['characterId'];
        if (id is! int) continue;
        periods.add((
          id,
          (prize['cardYear'] ?? card?['cardYear']) as int?,
          (RelativeTime.timestamp(pool['startAt']) ?? 0).toInt(),
          (RelativeTime.timestamp(pool['endAt']) ?? 0).toInt(),
          pool,
        ));
      }
    }
    _Birthday? birthday(
      String key,
      String name,
      Entry? character,
      int month,
      int day,
      bool cast,
    ) {
      int? next, previous;
      for (var y = year - 8; y <= year + 8; y++) {
        final date = _at(y, month, day);
        if (date == null) continue;
        if (date <= today) previous = date;
        if (next == null && date >= today) next = date;
      }
      if (next == null) return null;
      bool matches((int, int?, int, int, Entry) p, int at) =>
          !cast &&
          p.$1 == character?['characterId'] &&
          p.$3 > 0 &&
          (p.$3 - at).abs() <= 45 * _day &&
          _nearest(month, day, p.$3) == at &&
          (p.$2 == null ||
              p.$2 ==
                  DateTime.fromMillisecondsSinceEpoch(
                    at + _offset,
                    isUtc: true,
                  ).year) &&
          (p.$4 == 0 || p.$4 > p.$3);
      final prior = previous == null
          ? <(int, int?, int, int, Entry)>[]
          : periods.where((p) => matches(p, previous!)).toList();
      if (previous != null && prior.any((p) => p.$4 > now)) next = previous;
      if (previous == today &&
          prior.isNotEmpty &&
          prior.every((p) => p.$4 > 0 && p.$4 <= now)) {
        next = _at(year + 1, month, day);
        for (var y = year + 2; next == null && y <= year + 8; y++) {
          next = _at(y, month, day);
        }
      }
      if (next == null) return null;
      final pools = periods.where((p) => matches(p, next!)).toList();
      int state((int, int?, int, int, Entry) p) => p.$3 > now
          ? 1
          : p.$4 <= 0
          ? 3
          : p.$4 <= now
          ? 2
          : 0;
      pools.sort((a, b) {
        final rank = state(a).compareTo(state(b));
        return rank != 0
            ? rank
            : (a.$3 - next!).abs().compareTo((b.$3 - next).abs());
      });
      final artCards =
          cards
              .where(
                (c) =>
                    c['characterId'] == character?['characterId'] &&
                    ((RelativeTime.timestamp(c['releasedAt']) ?? 0) - next!)
                            .abs() <=
                        45 * _day,
              )
              .toList()
            ..sort(
              (a, b) => ((RelativeTime.timestamp(a['releasedAt']) ?? 0) - next!)
                  .abs()
                  .compareTo(
                    ((RelativeTime.timestamp(b['releasedAt']) ?? 0) - next)
                        .abs(),
                  ),
            );
      return _Birthday(
        key,
        name,
        character,
        next,
        cast,
        pools.any((p) => p.$4 > now || p.$4 <= 0 && now < next! + _day),
        pools.firstOrNull?.$5,
        artCards.firstOrNull,
      );
    }

    final profiles = (data.seed['profiles'] as Map?) ?? const {};
    final profileCharacters = (profiles['characters'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final items = <_Birthday>[];
    for (final c in characters) {
      final date = c['birthday'];
      if (date is Map && date['month'] is int && date['day'] is int) {
        final row = birthday(
          'character:${c['characterId']}',
          t.text(c['characterName']),
          c,
          date['month'],
          date['day'],
          false,
        );
        if (row != null) items.add(row);
      }
    }
    for (final person
        in (profiles['cast'] as List? ?? const []).whereType<Map>()) {
      final date = (person['birthday'] as Map?)?['value'];
      if (date is! Map || date['month'] is! int || date['day'] is! int) {
        continue;
      }
      final slugs = (person['characterSlugs'] as List? ?? const []);
      final role = profileCharacters
          .where((p) => slugs.contains(p['id']))
          .firstOrNull;
      final row = birthday(
        'cast:${person['id']}',
        t.text(person['name']),
        role == null ? null : characterFor(role),
        date['month'],
        date['day'],
        true,
      );
      if (row != null) items.add(row);
    }
    items.sort((a, b) {
      final date = a.at.compareTo(b.at);
      if (date != 0) return date;
      final kind = (a.cast ? 1 : 0).compareTo(b.cast ? 1 : 0);
      return kind != 0 ? kind : a.key.compareTo(b.key);
    });
    final members = items.where((b) => !b.cast).toList();
    if (members.isEmpty) return const SizedBox.shrink();
    final choices = members
        .where((b) => b.announced || b.at == members.first.at)
        .toList();
    final featured =
        choices.where((b) => b.key == _selected).firstOrNull ?? choices.first;
    final art =
        '${featured.pool?['image'] ?? (featured.card?['images'] as Map?)?['full'] ?? featured.character?['faceImage'] ?? ''}';
    void open(_Birthday item) {
      if (item.character?['characterId'] case final id?) {
        openLink(context, '/catalog/characters/$id');
      }
    }

    final theme = Theme.of(context);
    final face = '${featured.character?['faceImage'] ?? ''}';
    final days = ((featured.at - today) / _day).round();
    final band = data.visuals.bands[featured.character?['bandId']];
    void openArt() {
      if (featured.pool != null) {
        openLink(context, '/catalog/gacha/${featured.pool!['id']}');
      } else if (featured.card != null) {
        openLink(context, '/catalog/member-cards/${featured.card!['cardId']}');
      } else {
        open(featured);
      }
    }

    String countdown(_Birthday item, {bool short = false}) {
      final count = ((item.at - today) / _day).round();
      if (count < 0) return t('home.dashboard.ongoing', 'Ongoing');
      if (count == 0) {
        return t('home.dashboard.birthdayGreeting', 'Happy birthday');
      }
      return t(
        short
            ? 'common.time.spanDays'
            : count == 1
            ? 'home.dashboard.daysAwayOne'
            : 'home.dashboard.daysAway',
        short ? '{count}d' : '{count} days',
        {'count': NumberFormat.decimalPattern(t.locale).format(count)},
      );
    }

    final avatars = items.where((b) => b.key != featured.key).take(12).toList();
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) {
          final inset = MediaQuery.sizeOf(context).width < 720 ? 6.0 : 12.0;
          final contentWidth = box.maxWidth - inset * 2;
          final tiny = contentWidth <= 399, small = contentWidth <= 559;
          final avatarSize = tiny
              ? 24.0
              : small
              ? 32.0
              : 40.0;
          final countdownStyle = theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
          );
          var countdownHeight = 0.0;
          for (final item in avatars) {
            final painter = TextPainter(
              text: TextSpan(
                text: countdown(item, short: true),
                style: countdownStyle,
              ),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: 1,
            )..layout();
            if (painter.height > countdownHeight) {
              countdownHeight = painter.height;
            }
            painter.dispose();
          }
          final avatarHeight = (avatarSize + 3 + countdownHeight).clamp(
            48.0,
            double.infinity,
          );
          final choicesHeight = choices.length > 1 ? 32.0 : 0.0;
          final topHeight =
              box.maxHeight - inset * 2 - avatarHeight - 8 - choicesHeight;
          final faceSize = contentWidth <= 459 ? 28.0 : 40.0;
          final nameStyle =
              (contentWidth <= 459
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.headlineSmall)
                  ?.copyWith(fontWeight: FontWeight.w600);
          final dueStyle =
              (contentWidth <= 459
                      ? theme.textTheme.titleLarge
                      : theme.textTheme.displaySmall)
                  ?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  );
          final bandIcon = data.visuals.bandIcon(featured.character?['bandId']);
          final birthdayDate = DateFormat.MMMd(t.locale).format(
            DateTime.fromMillisecondsSinceEpoch(
              featured.at + _offset,
              isUtc: true,
            ),
          );
          return Padding(
            padding: EdgeInsets.all(inset),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 6,
                              child: Material(
                                color: theme.colorScheme.surfaceContainer,
                                borderRadius: BorderRadius.circular(20),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: openArt,
                                  child: AppImage(
                                    candidates: [api.asset(art).toString()],
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: tiny
                                  ? 6
                                  : small
                                  ? 8
                                  : 16,
                            ),
                            Expanded(
                              flex: 5,
                              child: LayoutBuilder(
                                builder: (context, area) => SingleChildScrollView(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minHeight: area.maxHeight,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (!small && topHeight > 140)
                                          Row(
                                            children: [
                                              Icon(
                                                Symbols.cake_rounded,
                                                size: 16,
                                                color:
                                                    theme.colorScheme.primary,
                                              ),
                                              const SizedBox(width: 5),
                                              Expanded(
                                                child: Text(
                                                  t(
                                                    'home.dashboard.birthdaysTitle',
                                                    'Birthday countdown',
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme
                                                      .labelMedium
                                                      ?.copyWith(
                                                        color: theme
                                                            .colorScheme
                                                            .primary,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        InkWell(
                                          onTap: () => open(featured),
                                          child: Row(
                                            children: [
                                              if (face.isNotEmpty)
                                                ShapedIcon(
                                                  shape: MaterialShapes.sunny,
                                                  size: topHeight < 75
                                                      ? 20
                                                      : faceSize,
                                                  color: theme
                                                      .colorScheme
                                                      .surfaceContainerHighest,
                                                  child: AppImage(
                                                    candidates: [
                                                      api
                                                          .asset(face)
                                                          .toString(),
                                                    ],
                                                    fit: BoxFit.cover,
                                                  ),
                                                ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  featured.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: nameStyle,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (topHeight >= 75 &&
                                            t
                                                .text(band?['bandName'])
                                                .isNotEmpty) ...[
                                          SizedBox(height: tiny ? 2 : 5),
                                          Row(
                                            children: [
                                              if (bandIcon != null)
                                                SizedBox.square(
                                                  dimension: tiny ? 12 : 16,
                                                  child: AppImage(
                                                    candidates: [bandIcon],
                                                  ),
                                                ),
                                              SizedBox(width: tiny ? 3 : 5),
                                              Expanded(
                                                child: Text(
                                                  t.text(band?['bandName']),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style:
                                                      theme.textTheme.bodySmall,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                        SizedBox(height: tiny ? 2 : 5),
                                        Wrap(
                                          spacing: tiny ? 4 : 8,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                countdown(
                                                  featured,
                                                  short:
                                                      choices.length > 1 &&
                                                      days > 0,
                                                ),
                                                maxLines: 1,
                                                style: dueStyle,
                                              ),
                                            ),
                                            Text(
                                              birthdayDate,
                                              style: theme.textTheme.bodySmall,
                                            ),
                                          ],
                                        ),
                                        if (!small &&
                                            featured.pool != null &&
                                            topHeight > 160)
                                          Text(
                                            t.window(
                                              featured.pool!['startAt'],
                                              featured.pool!['endAt'],
                                            ),
                                            style: theme.textTheme.bodySmall,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox.square(
                        dimension: 40,
                        child: IconButton(
                          tooltip: t('tools.calendar.title', 'Calendar'),
                          onPressed: () => openLink(context, '/calendar'),
                          icon: const Icon(Symbols.event_rounded, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
                if (choices.length > 1)
                  SizedBox(
                    height: 32,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final choice in choices)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(choice.name),
                              selected: choice.key == featured.key,
                              onSelected: (_) =>
                                  setState(() => _selected = choice.key),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  height: avatarHeight,
                  child: LayoutBuilder(
                    builder: (context, rail) {
                      final gap = tiny
                          ? 4.0
                          : small
                          ? 5.0
                          : 8.0;
                      final minimum = avatarSize.clamp(48.0, double.infinity);
                      final count = ((rail.maxWidth + gap) / (minimum + gap))
                          .floor()
                          .clamp(0, avatars.length);
                      return Row(
                        children: [
                          for (var index = 0; index < count; index++) ...[
                            if (index > 0) SizedBox(width: gap),
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  final item = avatars[index];
                                  final main = item.cast
                                      ? '/images/avatars/cast/${item.key.substring(5)}.jpg?v=official-20261002'
                                      : '${item.character?['faceImage'] ?? ''}';
                                  final role = item.cast
                                      ? '${item.character?['faceImage'] ?? ''}'
                                      : '';
                                  return Tooltip(
                                    message:
                                        '${item.name} · ${countdown(item)}',
                                    child: InkWell(
                                      onTap: () => open(item),
                                      child: Column(
                                        children: [
                                          SizedBox.square(
                                            dimension: avatarSize,
                                            child: Stack(
                                              clipBehavior: Clip.none,
                                              children: [
                                                if (index == 0)
                                                  ShapedIcon(
                                                    shape: MaterialShapes
                                                        .cookie9Sided,
                                                    size: avatarSize,
                                                    child: AppImage(
                                                      candidates: [
                                                        if (main.isNotEmpty)
                                                          api
                                                              .asset(main)
                                                              .toString(),
                                                      ],
                                                      fit: BoxFit.cover,
                                                    ),
                                                  )
                                                else
                                                  ClipOval(
                                                    child: AppImage(
                                                      candidates: [
                                                        if (main.isNotEmpty)
                                                          api
                                                              .asset(main)
                                                              .toString(),
                                                      ],
                                                      fit: BoxFit.cover,
                                                    ),
                                                  ),
                                                if (role.isNotEmpty)
                                                  Positioned(
                                                    right: -2,
                                                    bottom: -1,
                                                    child: Container(
                                                      width: tiny
                                                          ? 12
                                                          : small
                                                          ? 15
                                                          : 18,
                                                      height: tiny
                                                          ? 12
                                                          : small
                                                          ? 15
                                                          : 18,
                                                      decoration: BoxDecoration(
                                                        shape: BoxShape.circle,
                                                        border: Border.all(
                                                          color: theme
                                                              .colorScheme
                                                              .surfaceContainerLow,
                                                          width: tiny ? 1 : 2,
                                                        ),
                                                      ),
                                                      child: ClipOval(
                                                        child: AppImage(
                                                          candidates: [
                                                            api
                                                                .asset(role)
                                                                .toString(),
                                                          ],
                                                          fit: BoxFit.cover,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            countdown(item, short: true),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: countdownStyle,
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Spotlight extends StatelessWidget {
  const _Spotlight({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 720 || children.length < 2) {
      return Column(
        children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const SizedBox(height: 12),
            child,
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: children[0]),
        const SizedBox(width: 16),
        Expanded(child: children[1]),
      ],
    );
  }
}

class _HomeBoard extends StatelessWidget {
  const _HomeBoard({required this.modules});
  final List<(String, Widget)> modules;
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final rows = <Widget>[];
    for (var i = 0; i < modules.length; i++) {
      final (id, child) = modules[i];
      if (wide &&
          id != 'cards' &&
          id != 'songs' &&
          i + 1 < modules.length &&
          modules[i + 1].$1 != 'cards' &&
          modules[i + 1].$1 != 'songs') {
        final arena = id == 'arena' || modules[i + 1].$1 == 'arena';
        Widget box(Widget child) => arena
            ? SizedBox(height: 280, child: child)
            : AspectRatio(aspectRatio: 7 / 3, child: child);
        rows.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: box(child)),
              const SizedBox(width: 16),
              Expanded(child: box(modules[++i].$2)),
            ],
          ),
        );
      } else {
        rows.add(
          id == 'cards' || id == 'songs'
              ? child
              : id == 'arena'
              ? SizedBox(height: 300, child: child)
              : AspectRatio(aspectRatio: 7 / 3, child: child),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, child) in rows.indexed) ...[
          if (index > 0)
            SizedBox(height: MediaQuery.sizeOf(context).width < 600 ? 12 : 16),
          child,
        ],
      ],
    );
  }
}

class _HomeIndex extends StatelessWidget {
  const _HomeIndex({required this.onBrowse, required this.t});
  final ValueChanged<String>? onBrowse;
  final SiteText t;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 24),
      Wrap(
        spacing: 12,
        children: [
          for (final route in ['privacy', 'terms', 'about'])
            TextButton(
              onPressed: () => onBrowse?.call('/$route'),
              child: Text(t('home.dashboard.$route', route)),
            ),
        ],
      ),
    ],
  );
}

/// The website keeps only complete rows that fit an information panel.
class _FitRows extends StatelessWidget {
  const _FitRows({required this.children, required this.extent});
  final List<Widget> children;
  final double extent;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final count = (box.maxHeight / extent).floor().clamp(0, children.length);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children.take(count))
            SizedBox(height: extent, child: child),
        ],
      );
    },
  );
}
