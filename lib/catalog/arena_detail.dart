import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../records/player.dart';
import '../records/records.dart';
import '../save/game_save.dart' show regionOfProfile;
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/tile.dart' show pagePadding;
import '../ui/detail.dart';
import '../team_builder/engine/num.dart';

String arenaTime(int value, String locale) {
  final date = DateTime.fromMillisecondsSinceEpoch(value),
      offset = DateTime.fromMillisecondsSinceEpoch(value)
          .timeZoneOffset
          .inMinutes;
  return '${DateFormat.yMd(locale).add_Hm().format(date)} UTC${offset >= 0 ? '+' : '−'}${(offset.abs() ~/ 60).toString().padLeft(2, '0')}:${(offset.abs() % 60).toString().padLeft(2, '0')}';
}

bool _contains(Doc row, int now) =>
    intOf(row['startAt']) <= now && now < intOf(row['endAt']) + 1000;
Doc? _rule(Doc season, Doc league, int now) => !_contains(season, now)
    ? null
    : dataRows(league['rules']).reversed
          .where((r) => _contains(r, now))
          .firstOrNull;
List<({int start, int end, List<Doc?> rules})> arenaPeriods(Doc season) {
  final leagues = dataRows(season['leagues']);
  final times = {
    for (final league in leagues)
      for (final rule in dataRows(league['rules'])) ...[
        intOf(rule['startAt']),
        intOf(rule['endAt']) + 1000,
      ],
  }.toList()..sort();
  return [
    for (var i = 0; i + 1 < times.length; i++)
      if (leagues.any((l) => _rule(season, l, times[i]) != null))
        (
          start: times[i],
          end: times[i + 1],
          rules: [for (final l in leagues) _rule(season, l, times[i])],
        ),
  ];
}

class ArenaScreen extends StatefulWidget {
  const ArenaScreen({super.key, this.server, this.seasonId, this.anchor = ''});
  final String? server, seasonId;
  final String anchor;
  @override
  State<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends State<ArenaScreen> with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _schedule(List<Doc> seasons) {
    _timer?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch;
    final times = [
      for (final season in seasons) ...[
        intOf(season['startAt']),
        intOf(season['endAt']) + 1000,
        for (final period in arenaPeriods(season)) ...[
          period.start,
          period.end,
        ],
      ],
    ].where((v) => v > now).toList()..sort();
    if (times.isNotEmpty) {
      _timer = Timer(
        Duration(milliseconds: (times.first - now + 20).clamp(1, 2147483647)),
        () {
          if (mounted) setState(() {});
        },
      );
    }
  }

  Future<Object?>? _data;
  Object? _key;
  String? _selected;
  late String _anchor = widget.anchor;
  String? _region;
  String get _server => _region == null
      ? widget.server ?? AppScope.of(context).server
      : _region == 'jp'
      ? 'jp'
      : 'intl';
  void _load() {
    final state = AppScope.of(context);
    _data = state
        .apiFor(_server)
        .json('/api/v1/servers/$_server/arena?projection=3');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    _region ??= defaultRecordRegion(
      widget.server ?? state.server,
      state.text.locale,
    );
    final key = (state.publicDataKey, widget.server, _region);
    if (key != _key) {
      _key = key;
      _selected = null;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context), text = state.text;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final data = objectRow(snapshot.data),
            seasons = dataRows(data['entries'])
              ..sort(
                (a, b) => intOf(a['startAt']).compareTo(intOf(b['startAt'])),
              );
        _schedule(seasons);
        final now = DateTime.now().millisecondsSinceEpoch;
        final id = _selected ?? widget.seasonId ?? widget.anchor;
        final periodId = int.tryParse(
          widget.anchor.replaceFirst('arena-period-', ''),
        );
        final selected =
            seasons
                .where(
                  (s) =>
                      s['id'] == id ||
                      _selected == null &&
                          periodId != null &&
                          arenaPeriods(s).any((p) => p.start == periodId),
                )
                .firstOrNull ??
            seasons.where((s) => _contains(s, now)).firstOrNull ??
            seasons.firstOrNull;
        final index = selected == null ? -1 : seasons.indexOf(selected);
        void choose(Doc season, {String anchor = ''}) => setState(() {
          _selected = '${season['id']}';
          _anchor = anchor;
        });
        final current = seasons.where((s) => _contains(s, now)).firstOrNull;
        final period = current == null
            ? null
            : arenaPeriods(current)
                  .where((p) => p.start <= now && now < p.end)
                  .firstOrNull;
        return ShellPage(
          title: text('navigation.arena'),
          actions: [
            regionChoice(
              text,
              _region!,
              (region) => setState(() {
                _region = region;
                _key = (state.publicDataKey, widget.server, region);
                _selected = null;
                _load();
              }),
            ),
            if (current != null && period != null)
              BarAction(
                icon: Symbols.today_rounded,
                label: text('catalog.arena.currentRule'),
                onPressed: () =>
                    choose(current, anchor: 'arena-period-${period.start}'),
              ),
            BarAction(
              icon: Symbols.calendar_month_rounded,
              label: text('tools.calendar.title'),
              onPressed: () => openLink(
                context,
                Uri(
                  path:
                      '/${widget.server ?? state.server}/${text.locale}/calendar/',
                  queryParameters: {'kinds': 'arena,event', 'view': 'agenda'},
                ).toString(),
              ),
            ),
            BarAction(
              icon: Symbols.refresh_rounded,
              label: text('common.actions.refresh'),
              onPressed: () => setState(_load),
            ),
          ],
          body: selected == null
              ? Center(
                  child: snapshot.connectionState == ConnectionState.waiting
                      ? const CircularProgressIndicator()
                      : Text(text('common.states.unavailable')),
                )
              : ListView(
                  padding: pagePadding(context),
                  children: [
                    ArenaDetail(
                      key: ValueKey((selected['id'], _anchor, _region)),
                      season: selected,
                      server:
                          '${objectRow(data['identity'])['server'] ?? _server}',
                      images: objectRow(data['images']),
                      anchor: _anchor,
                      region: _region,
                      basePoints: dataRows(data['basePoints']),
                      parameters: objectRow(data['parameters']),
                      index: index,
                      seasonCount: seasons.length,
                      onSeason: (step) => choose(seasons[index + step]),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

enum _Tab { overview, ranking, schedule, songs, ranks, rules }

const _ruleKeys = [
  'matching_entry_time_limit_second',
  'matching_time_limit_second',
  'matching_phase_duration_sec',
  'disconnect_penalty_threshold',
  'penalty_rate',
];
const _boardWindow = 100;

/// One Arena season: the league chooser and six tabs, as on the website.
class ArenaDetail extends StatefulWidget {
  const ArenaDetail({
    super.key,
    required this.season,
    this.server,
    this.images = const {},
    this.anchor = '',
    this.region,
    this.basePoints = const [],
    this.parameters = const {},
    this.index = 0,
    this.seasonCount = 1,
    this.onSeason,
  });
  final Doc season, images, parameters;
  final String? server, region;
  final String anchor;
  final List<Doc> basePoints;
  final int index, seasonCount;
  final ValueChanged<int>? onSeason;
  @override
  State<ArenaDetail> createState() => _ArenaDetailState();
}

class _ArenaDetailState extends State<ArenaDetail> with WidgetsBindingObserver {
  Timer? _timer;
  _Tab _tab = _Tab.overview;
  int? _bandId;
  int _players = 5;
  bool _allPeriods = false;
  int _start = 1;
  int? _target;
  Map? _ranking;
  CardCatalog? _cards;
  Object? _population;
  String? _populationKey;
  final _rankField = TextEditingController();
  final _playerField = TextEditingController();

  int get _now => DateTime.now().millisecondsSinceEpoch;
  Doc get season => widget.season;
  List<Doc> get _leagues => dataRows(season['leagues']);
  Doc get _league =>
      _leagues.where((l) => intOf(l['bandId']) == _bandId).firstOrNull ??
      _leagues.first;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.anchor.startsWith('arena-period-')) _tab = _Tab.schedule;
    _schedule();
  }

  @override
  void didUpdateWidget(ArenaDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() {});
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final now = _now;
    final times = [
      intOf(season['startAt']),
      intOf(season['endAt']) + 1000,
      for (final league in _leagues) ...[
        for (final rule in dataRows(league['rules'])) ...[
          intOf(rule['startAt']),
          intOf(rule['endAt']) + 1000,
        ],
        for (final song in dataRows(league['songs']))
          intOf(song['arenaPublishedAt']),
      ],
    ].where((v) => v > now).toList()..sort();
    if (times.isNotEmpty) {
      _timer = Timer(
        Duration(milliseconds: (times.first - now + 20).clamp(1, 2147483647)),
        () {
          if (mounted) {
            setState(() {});
            _schedule();
          }
        },
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _rankField.dispose();
    _playerField.dispose();
    super.dispose();
  }

  String _text(String key, [Map<String, Object?> values = const {}]) =>
      AppScope.of(context).text('catalog.arena.$key', key, values);
  String get _locale => AppScope.of(context).text.locale;
  String _name(Object? value) => AppScope.of(context).text.text(value);
  String _number(num value) =>
      NumberFormat.decimalPattern(_locale).format(value);
  String _short(int at) =>
      DateFormat.Md(_locale)
          .add_Hm()
          .format(DateTime.fromMillisecondsSinceEpoch(at));
  String _range(int start, int end) => '${_short(start)} – ${_short(end)}';
  String _remaining(int until) {
    final minutes = ((until - _now) / 60000).round().clamp(0, 1 << 31);
    final days = minutes ~/ 1440, hours = (minutes % 1440) ~/ 60;
    return days > 0
        ? _text('remainingDays', {'days': days, 'hours': hours})
        : _text('remainingHours', {'hours': hours, 'minutes': minutes % 60});
  }

  Widget _art(Object? source, {double size = 24}) => SizedBox(
    width: size,
    height: size,
    child: AppImage(
      candidates: [AppScope.of(context).api.asset('$source').toString()],
    ),
  );
  String _attribute(int id) => id == 0
      ? _text('originalRule')
      : id == 99
      ? 'ALL'
      : AppScope.of(context).text(
          'catalog.songs.liveTypes.${['', 'red', 'blue', 'green', 'yellow', 'purple'].elementAtOrNull(id)}',
        );
  String _mission(int id) =>
      ['', 'COMBO', 'LUCK', 'JUST'].elementAtOrNull(id) ??
      _text('originalRule');
  String _ruleText(Doc rule) {
    final missions = intListOf(rule['missions']);
    return missions.toSet().length == 1
        ? '${_mission(missions.first)}×3'
        : missions.map(_mission).join(' / ');
  }

  Widget _missionMark(int id, {double size = 24}) =>
      switch (objectRow(widget.images['missions'])['$id']) {
        final Object source => _art(source, size: size),
        _ => const SizedBox.shrink(),
      };
  Widget _ruleMarks(Doc? rule, {double size = 24}) {
    if (rule == null) return const Text('—');
    return Tooltip(
      message: '${_attribute(intOf(rule['musicType']))} · ${_ruleText(rule)}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Text(
            _attribute(intOf(rule['musicType'])),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          for (final id in intListOf(rule['missions']).toSet())
            _missionMark(id, size: size),
        ],
      ),
    );
  }

  ({Doc? rule, List<Doc> next}) _ruleNow(Doc league) {
    final now = _now;
    final rules = dataRows(league['rules']);
    return (
      rule: _rule(season, league, now),
      next: rules.where((r) => intOf(r['startAt']) > now).take(3).toList(),
    );
  }

  String get _status => _now < intOf(season['startAt'])
      ? 'upcoming'
      : _now > intOf(season['endAt'])
      ? 'ended'
      : 'current';

  Widget _hero(ThemeData theme) {
    final now = _now, status = _status;
    final period = arenaPeriods(season)
        .where((p) => p.start <= now && now < p.end)
        .firstOrNull;
    Widget fact(IconData icon, String value) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        Flexible(child: Text(value, style: theme.textTheme.bodySmall)),
      ],
    );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: _text('previousSeason'),
                  onPressed: widget.index > 0
                      ? () => widget.onSeason?.call(-1)
                      : null,
                  icon: const Icon(Symbols.chevron_left_rounded),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        _name(season['title']),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge,
                      ),
                      Text(
                        _text('status.$status'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _text('nextSeason'),
                  onPressed: widget.index + 1 < widget.seasonCount
                      ? () => widget.onSeason?.call(1)
                      : null,
                  icon: const Icon(Symbols.chevron_right_rounded),
                ),
              ],
            ),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                fact(
                  Symbols.date_range_rounded,
                  _range(intOf(season['startAt']), intOf(season['endAt'])),
                ),
                if (season['rankingEndAt'] != null)
                  fact(
                    Symbols.flag_rounded,
                    '${_text('rankingEnds')} ${_short(intOf(season['rankingEndAt']))}',
                  ),
                if (status == 'current')
                  fact(
                    Symbols.hourglass_bottom_rounded,
                    '${_text('seasonLeft')} ${_remaining(intOf(season['endAt']))}',
                  ),
                if (status == 'current' && period != null)
                  fact(
                    Symbols.autorenew_rounded,
                    '${_text('nextRotation')} ${_remaining(period.end)}',
                  ),
                if (status == 'upcoming')
                  fact(
                    Symbols.schedule_rounded,
                    '${_text('startsIn')} ${_remaining(intOf(season['startAt']))}',
                  ),
              ],
            ),
            SizedBox(
              height: 112,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _leagues.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final league = _leagues[index];
                  final state = _ruleNow(league);
                  final shown = state.rule ?? state.next.firstOrNull;
                  final selected =
                      identical(league, _league) ||
                      league['id'] == _league['id'];
                  return SizedBox(
                    width: 168,
                    child: Material(
                      color: selected
                          ? theme.colorScheme.secondaryContainer
                          : theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => setState(() {
                          _bandId = intOf(league['bandId']);
                          _start = 1;
                          _target = null;
                          _ranking = null;
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            spacing: 4,
                            children: [
                              Row(
                                spacing: 8,
                                children: [
                                  _art(league['image'], size: 28),
                                  Expanded(
                                    child: Text(
                                      _name(league['name']),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall,
                                    ),
                                  ),
                                ],
                              ),
                              _ruleMarks(shown, size: 20),
                              if (shown != null)
                                Text(
                                  _range(
                                    intOf(shown['startAt']),
                                    intOf(shown['endAt']) + 1000,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabs() {
    const icons = {
      _Tab.overview: Symbols.insights_rounded,
      _Tab.ranking: Symbols.leaderboard_rounded,
      _Tab.schedule: Symbols.calendar_view_week_rounded,
      _Tab.songs: Symbols.music_note_rounded,
      _Tab.ranks: Symbols.military_tech_rounded,
      _Tab.rules: Symbols.gavel_rounded,
    };
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final tab in _Tab.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: Icon(icons[tab], size: 18),
                showCheckmark: false,
                label: Text(_text('tabs.${tab.name}')),
                selected: _tab == tab,
                onSelected: (_) => setState(() => _tab = tab),
              ),
            ),
        ],
      ),
    );
  }

  String _href(String kind, Object? id) =>
      '/${widget.server ?? AppScope.of(context).server}/$_locale/$kind/$id/';

  Widget _condition(ThemeData theme) {
    final league = _league, state = _ruleNow(league);
    final shown = state.rule ?? state.next.firstOrNull;
    final server = widget.server ?? AppScope.of(context).server;
    return DetailSection(
      icon: Symbols.flag_rounded,
      title: _name(league['name']),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Text(
            state.rule != null
                ? _text('currentRule')
                : shown != null
                ? _text('nextRule')
                : _text('noSchedule'),
          ),
          if (shown != null) ...[
            Row(
              spacing: 16,
              children: [
                Column(
                  children: [
                    Text(
                      _text('stageAttribute'),
                      style: theme.textTheme.labelSmall,
                    ),
                    Text(
                      _attribute(intOf(shown['musicType'])),
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                for (final (index, value) in intListOf(
                  shown['missions'],
                ).indexed)
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          _text('section', {'index': index + 1}),
                          style: theme.textTheme.labelSmall,
                        ),
                        _missionMark(value, size: 36),
                        Text(
                          _mission(value),
                          style: theme.textTheme.labelLarge,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            Text(
              '${_attribute(intOf(shown['musicType']))} · ${_ruleText(shown)}',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              [
                _range(intOf(shown['startAt']), intOf(shown['endAt'])),
                if (state.rule != null)
                  _remaining(intOf(state.rule!['endAt']) + 1000),
              ].join(' · '),
              style: theme.textTheme.bodyMedium,
            ),
          ],
          if (state.rule != null)
            for (final entry in state.next)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _range(
                        intOf(entry['startAt']),
                        intOf(entry['endAt']) + 1000,
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  _ruleMarks(entry, size: 20),
                ],
              ),
          FilledButton.icon(
            onPressed: () => openLink(
              context,
              Uri(
                path: '/team-builder',
                queryParameters: {
                  'tab': 'arena',
                  'league': '${league['id']}',
                  'server': server,
                },
              ).toString(),
            ),
            icon: const Icon(Symbols.groups_rounded),
            label: Text(_text('buildTeam')),
          ),
        ],
      ),
    );
  }

  List<(int, Doc)> _thresholds(Doc league) {
    final points = <int, Doc>{};
    for (final rank in dataRows(league['ranks'])) {
      final opens = intOf(rank['startAt']);
      if (opens == 0 || opens <= _now) {
        points.putIfAbsent(intOf(rank['points']), () => rank);
      }
    }
    return [
      for (final key in points.keys.toList()..sort()) (key, points[key]!),
    ];
  }

  void _loadPopulation() {
    if (_now < intOf(season['startAt'])) return;
    final league = _league;
    final thresholds = _thresholds(league).map((row) => row.$1).join(',');
    final key =
        '${widget.region}/${season['seasonId']}/${league['bandId']}/$thresholds';
    if (key == _populationKey || widget.region == null) return;
    _populationKey = key;
    _population = 'loading';
    final path =
        '/api/v1/game/records/${widget.region}/arena/seasons/${season['seasonId']}/leagues/${league['bandId']}/population?thresholds=$thresholds';
    final state = AppScope.of(context);
    final api = state.apiFor(widget.server ?? state.server);
    Future<void> attempt(int tries) async {
      try {
        final value = await api.live(path);
        if (mounted && key == _populationKey) {
          setState(() => _population = value);
        }
      } catch (_) {
        if (tries > 1) {
          await Future<void>.delayed(const Duration(seconds: 10));
          if (mounted && key == _populationKey) return attempt(tries - 1);
          return;
        }
        if (mounted && key == _populationKey) {
          setState(() => _population = 'error');
        }
      }
    }

    attempt(12);
  }

  Widget _populationSection(ThemeData theme) {
    _loadPopulation();
    final data = _population is Map ? objectRow(_population) : null;
    final rows = data == null ? const <Doc>[] : dataRows(data['tiers']);
    final total = data == null
        ? null
        : data['maxRank'] is num
        ? intOf(data['maxRank'])
        : rows.fold<int>(0, (sum, row) => sum + intOf(row['count']));
    int? count(int points) {
      final row = rows
          .where((row) => intOf(row['threshold']) == points)
          .firstOrNull;
      return row == null ? null : intOf(row['count']);
    }

    final tiers = <int, List<Doc>>{};
    for (final (_, rank) in _thresholds(_league)) {
      (tiers[intOf(rank['rank'])] ??= []).add(rank);
    }
    final groups = [
      for (final entry in tiers.entries.toList().reversed)
        (
          tier: entry.key,
          divisions: entry.value.reversed.toList(),
          counts: [
            for (final d in entry.value.reversed) count(intOf(d['points'])),
          ],
        ),
    ];
    int? sumOf(List<int?> counts) => counts.any((c) => c == null)
        ? null
        : counts.fold<int>(0, (sum, c) => sum + c!);
    final largest = [
      1,
      for (final group in groups) sumOf(group.counts) ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    final ranks = objectRow(widget.images['ranks']);
    return DetailSection(
      icon: Symbols.groups_rounded,
      title: total == null
          ? _text('population')
          : '${_text('population')} · ${_number(total)}',
      child: _population == 'error'
          ? Text(_text('unavailable'))
          : Column(
              spacing: 12,
              children: [
                for (final group in groups)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 4,
                    children: [
                      Row(
                        spacing: 8,
                        children: [
                          if (ranks['${group.tier}'] case final Object source)
                            _art(source, size: 32),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _tierName(group.divisions.first),
                                  style: theme.textTheme.titleSmall,
                                ),
                                Text(
                                  '${_number(intOf(group.divisions.last['points']))}+',
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                          Text(switch (sumOf(group.counts)) {
                            null => '—',
                            final sum => [
                              _number(sum),
                              if (total != null && total > 0)
                                NumberFormat.decimalPercentPattern(
                                  locale: _locale,
                                  decimalDigits: 1,
                                ).format(sum / total),
                            ].join(' · '),
                          }, style: theme.textTheme.labelLarge),
                        ],
                      ),
                      LinearProgressIndicator(
                        value: (sumOf(group.counts) ?? 0) / largest,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      if (group.divisions.length > 1)
                        Wrap(
                          spacing: 12,
                          children: [
                            for (final (index, division)
                                in group.divisions.indexed)
                              Text(
                                '${_name(division['name'])} ${group.counts[index] == null ? '—' : _number(group.counts[index]!)}',
                                style: theme.textTheme.labelSmall,
                              ),
                          ],
                        ),
                    ],
                  ),
              ],
            ),
    );
  }

  /// A division's rank name without its number.
  String _tierName(Doc rank) =>
      _name(rank['name']).replaceAll(RegExp(r'[\s　]*\d+$'), '');

  String get _boardEndpoint =>
      '/api/v1/game/records/${widget.region}/arena/seasons/${season['seasonId']}/leagues/${_league['bandId']}/ranking?start=$_start';

  Doc? _tierOf(num point, num? at) {
    Doc? best;
    final time = at ?? _now;
    for (final rank in dataRows(_league['ranks'])) {
      final opens = intOf(rank['startAt']);
      if ((opens == 0 || opens <= time) &&
          intOf(rank['points']) <= point &&
          (best == null || intOf(rank['points']) >= intOf(best['points']))) {
        best = rank;
      }
    }
    return best;
  }

  Widget _board({required int limit}) => RankingList(
    key: ValueKey('$_boardEndpoint:$limit'),
    endpoint: _boardEndpoint,
    region: widget.region!,
    points: limit > 0,
    limit: limit > 0 ? limit : _boardWindow,
    highlightRank: _target,
    onData: limit > 0
        ? null
        : (ranking, cards) {
            if (!mounted) return;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _ranking = ranking;
                  _cards = cards;
                });
              }
            });
          },
    rowDetail: (row, at) {
      final point = row['point'];
      final tier = point is num ? _tierOf(point, at) : null;
      if (tier == null) return null;
      return Row(
        spacing: 4,
        children: [
          if (objectRow(widget.images['ranks'])['${tier['rank']}']
              case final Object source)
            _art(source, size: 20),
          Flexible(
            child: Text(
              _name(tier['name']),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      );
    },
    onPlayer: (id) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerProfileScreen(
          region: regionOfProfile(id) ?? widget.region!,
          profileId: id,
        ),
      ),
    ),
  );

  void _jump(int rank) {
    final maximum = (_ranking?['maxRank'] as num?)?.toInt();
    final target = rank.clamp(1, maximum ?? rank);
    setState(() {
      _target = target;
      _start = ((target - 1) ~/ _boardWindow) * _boardWindow + 1;
    });
  }

  Future<void> _findPlayer() async {
    final id = _playerField.text.trim();
    if (!RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(id)) return;
    final messenger = ScaffoldMessenger.of(context);
    final state = AppScope.of(context);
    try {
      final result = objectRow(
        await state
            .apiFor(widget.server ?? AppScope.of(context).server)
            .live(
              '/api/v1/game/records/${widget.region}/arena/seasons/${season['seasonId']}/leagues/${_league['bandId']}/search?profileId=$id',
            ),
      );
      if (!mounted) return;
      if (result['row'] is Map) {
        _jump(intOf(objectRow(result['row'])['rank']));
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              _text('ranking.notFound', {
                'count': _number(intOf(result['searchedTo'])),
              }),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(state.text('common.states.unavailable'))),
        );
      }
    }
  }

  Widget _boardControls() {
    final maximum = (_ranking?['maxRank'] as num?)?.toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: TextField(
                controller: _rankField,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: _text('ranking.jump')),
                onSubmitted: (value) {
                  final rank = int.tryParse(value);
                  if (rank != null && rank > 0) _jump(rank);
                },
              ),
            ),
            FilledButton.tonal(
              onPressed: () {
                final rank = int.tryParse(_rankField.text);
                if (rank != null && rank > 0) _jump(rank);
              },
              child: Text(_text('ranking.go')),
            ),
          ],
        ),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: TextField(
                controller: _playerField,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: _text('ranking.playerId'),
                ),
                onSubmitted: (_) => _findPlayer(),
              ),
            ),
            FilledButton.tonal(
              onPressed: _findPlayer,
              child: Text(_text('ranking.find')),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: _text('ranking.previous'),
              onPressed: _start > 1
                  ? () => setState(() {
                      _start -= _boardWindow;
                      _target = null;
                    })
                  : null,
              icon: const Icon(Symbols.chevron_left_rounded),
            ),
            Expanded(
              child: Text(
                _text('ranking.window', {
                  'start': _number(_start),
                  'end': _number(_start + _boardWindow - 1),
                  'total': maximum == null ? '—' : _number(maximum),
                }),
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              tooltip: _text('ranking.next'),
              onPressed: maximum == null || _start + _boardWindow <= maximum
                  ? () => setState(() {
                      _start += _boardWindow;
                      _target = null;
                    })
                  : null,
              icon: const Icon(Symbols.chevron_right_rounded),
            ),
          ],
        ),
      ],
    );
  }

  Widget _usage(ThemeData theme) {
    final rows = (_ranking?['rows'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final cards = _cards;
    if (rows.isEmpty || cards == null) return const SizedBox.shrink();
    List<(int, int)> count(Iterable<Object?> Function(Map row) pick) {
      final counts = <int, int>{};
      for (final row in rows) {
        for (final id in pick(row).toSet()) {
          if (id is num && id > 0) {
            counts[id.toInt()] = (counts[id.toInt()] ?? 0) + 1;
          }
        }
      }
      final sorted = counts.entries.toList()..sort((a, b) => b.value - a.value);
      return [for (final entry in sorted.take(8)) (entry.key, entry.value)];
    }

    Iterable<Map> deck(Map row) =>
        (row['cards'] as List? ?? const []).whereType<Map>();
    final groups = <(String, List<(int, int)>, bool)>[
      (
        _text('leaders'),
        count(
          (row) => [
            deck(row).where((c) => c['slot'] == 0).firstOrNull?['memberCardId'],
          ],
        ),
        false,
      ),
      (
        _text('memberUse'),
        count((row) => deck(row).map((c) => c['memberCardId'])),
        false,
      ),
      (
        _text('supportUse'),
        count((row) => deck(row).map((c) => c['supportCardId'])),
        true,
      ),
    ];
    return DetailSection(
      icon: Symbols.style_rounded,
      title: _text('usage', {'count': rows.length}),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          for (final (label, entries, support) in groups) ...[
            Text(label, style: theme.textTheme.titleSmall),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (id, uses) in entries)
                  InkWell(
                    onTap: () => openLink(
                      context,
                      _href(support ? 'support-cards' : 'member-cards', id),
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          width: 64,
                          height: 64,
                          child: switch ((support
                                  ? cards.support
                                  : cards.member)[id]
                              ?.image) {
                            final String image => AppImage(
                              candidates: [image],
                              fit: BoxFit.cover,
                            ),
                            _ => Center(child: Text('$id')),
                          },
                        ),
                        Text(
                          NumberFormat.percentPattern(_locale)
                              .format(uses / rows.length),
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _overview(ThemeData theme) {
    final started = _now >= intOf(season['startAt']);
    final rules = dataRows(_league['rules'])
        .where((r) => intOf(r['endAt']) + 1000 > _now)
        .take(14)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _condition(theme),
        if (started) ...[
          _populationSection(theme),
          DetailSection(
            icon: Symbols.emoji_events_rounded,
            title: _text('top10'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _board(limit: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => _tab = _Tab.ranking),
                    child: Text(_text('tabs.ranking')),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (rules.isNotEmpty)
          DetailSection(
            icon: Symbols.event_upcoming_rounded,
            title: _text('upcoming'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 72,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: rules.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final rule = rules[index];
                      final current =
                          intOf(rule['startAt']) <= _now &&
                          _now < intOf(rule['endAt']) + 1000;
                      return Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: current
                              ? theme.colorScheme.secondaryContainer
                              : theme.colorScheme.surfaceContainerLow,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          spacing: 4,
                          children: [
                            Text(
                              _range(
                                intOf(rule['startAt']),
                                intOf(rule['endAt']) + 1000,
                              ),
                              style: theme.textTheme.labelSmall,
                            ),
                            _ruleMarks(rule, size: 20),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => _tab = _Tab.schedule),
                    child: Text(_text('tabs.schedule')),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _rankingTab(ThemeData theme) {
    if (_now < intOf(season['startAt'])) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(_text('notStarted'))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _boardControls(),
        _board(limit: 0),
        _populationSection(theme),
        _usage(theme),
      ],
    );
  }

  Widget _schedule_(ThemeData theme) {
    final periods = arenaPeriods(season);
    if (periods.isEmpty) return Text(_text('noSchedule'));
    final now = _now;
    final shown = _allPeriods
        ? periods
        : periods.where((p) => p.end > now).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilterChip(
            label: Text(_text('allPeriods')),
            selected: _allPeriods,
            onSelected: (value) => setState(() => _allPeriods = value),
          ),
        ),
        for (final period in shown)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: period.start <= now && now < period.end
                  ? theme.colorScheme.secondaryContainer
                  : theme.colorScheme.surfaceContainerLow,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(
                  _range(period.start, period.end),
                  style: theme.textTheme.labelMedium,
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    for (final (index, league) in _leagues.indexed)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: [
                          _art(league['image'], size: 22),
                          _ruleMarks(period.rules[index], size: 20),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _songs(ThemeData theme) {
    final league = _league, rule = _ruleNow(league).rule;
    final songs = dataRows(league['songs'])
      ..sort(
        (a, b) => intOf(b['arenaPublishedAt']) - intOf(a['arenaPublishedAt']),
      );
    return DetailSection(
      icon: Symbols.library_music_rounded,
      title: _name(league['name']),
      count: songs.length,
      child: Column(
        children: [
          for (final song in songs)
            () {
              final original = intListOf(song['arenaMissions']);
              final published = intOf(song['arenaPublishedAt']);
              final source = song['jacketThumbUrl'] ?? song['jacketUrl'];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: source == null ? null : _art(source, size: 48),
                title: Text(_name(song['musicTitle'])),
                subtitle: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _ruleMarks({
                      'musicType': song['musicType'],
                      'missions': original.isEmpty ? const [0, 0, 0] : original,
                    }, size: 18),
                    if (rule != null) ...[
                      const Icon(Symbols.arrow_forward_rounded, size: 14),
                      _ruleMarks({
                        'musicType': intOf(rule['musicType']) == 0
                            ? song['musicType']
                            : rule['musicType'],
                        'missions': [
                          for (final (i, id) in intListOf(
                            rule['missions'],
                          ).indexed)
                            id == 0 ? original.elementAtOrNull(i) ?? 0 : id,
                        ],
                      }, size: 18),
                    ],
                  ],
                ),
                trailing: Text(
                  published > _now
                      ? _short(published)
                      : DateFormat.yMd(_locale).format(
                          DateTime.fromMillisecondsSinceEpoch(published),
                        ),
                  style: theme.textTheme.labelSmall,
                ),
                onTap: () => openLink(context, _href('songs', song['musicId'])),
              );
            }(),
        ],
      ),
    );
  }

  Widget _rewards(List<Doc> rows) => Column(
    children: [
      for (final row in rows)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: row['image'] == null ? null : _art(row['image'], size: 36),
          title: Text(_name(row['name'])),
          trailing: row['count'] is num
              ? Text('×${_number(row['count'] as num)}')
              : null,
          onTap: intOf(row['resourceType']) == 1
              ? () => openLink(context, _href('items', row['resourceId']))
              : null,
        ),
    ],
  );

  Map<String, List<Doc>> _grouped(List<Doc> rows) {
    final groups = <String, List<Doc>>{};
    for (final row in rows) {
      final key = row['from'] == row['to']
          ? '${row['from']}'
          : '${row['from']}–${row['to']}';
      (groups[key] ??= []).add(row);
    }
    return groups;
  }

  Widget _ranksTab(ThemeData theme) {
    final league = _league;
    final ranks = dataRows(league['ranks']).reversed.toList();
    final promotions = dataRows(league['promotionRewards']);
    final icons = objectRow(widget.images['ranks']);
    final base = widget.basePoints
        .where((row) => intOf(row['players']) == _players)
        .toList();
    final tiers = base.map((row) => intOf(row['tier'])).toSet().toList()
      ..sort();
    final ranking = dataRows(season['rankingRewards'])
        .where(
          (r) => intOf(r['leagueId']) == 0 || r['leagueId'] == league['id'],
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSection(
          icon: Symbols.military_tech_rounded,
          title: _text('thresholds'),
          count: ranks.length,
          child: Column(
            children: [
              for (final rank in ranks)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  leading: switch (icons['${rank['rank']}']) {
                    final Object source => _art(source, size: 28),
                    _ => null,
                  },
                  title: Text(_name(rank['name'])),
                  subtitle: Text(
                    [
                      '${_number(intOf(rank['points']))} ${_text('points')}',
                      '${_text('resetPoints')} ${intOf(rank['resetPoints']) == 0 ? _text('resetKept') : '−${NumberFormat.percentPattern(_locale).format(intOf(rank['resetPoints']) / 10000)}'}',
                      if (intOf(rank['startAt']) > _now)
                        '${_text('opens')} ${_short(intOf(rank['startAt']))}',
                    ].join(' · '),
                  ),
                  children: [
                    _rewards(
                      promotions
                          .where((r) => r['rankId'] == rank['id'])
                          .toList(),
                    ),
                  ],
                ),
            ],
          ),
        ),
        if (widget.basePoints.isNotEmpty)
          DetailSection(
            icon: Symbols.query_stats_rounded,
            title: _text('basePoints'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (final count in const [2, 3, 4, 5])
                      ButtonSegment(
                        value: count,
                        label: Text(_text('playerCount', {'count': count})),
                      ),
                  ],
                  selected: {_players},
                  onSelectionChanged: (value) =>
                      setState(() => _players = value.first),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    columns: [
                      DataColumn(label: Text(_text('rank'))),
                      for (var place = 1; place <= _players; place++)
                        DataColumn(
                          numeric: true,
                          label: Text(_text('place', {'place': place})),
                        ),
                    ],
                    rows: [
                      for (final tier in tiers)
                        DataRow(
                          cells: [
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 4,
                                children: [
                                  if (icons['$tier'] case final Object source)
                                    _art(source, size: 24),
                                  Text(switch (ranks
                                      .where((r) => intOf(r['rank']) == tier)
                                      .firstOrNull) {
                                    final Doc sample => _tierName(sample),
                                    _ => '$tier',
                                  }),
                                ],
                              ),
                            ),
                            for (var place = 1; place <= _players; place++)
                              DataCell(switch (base
                                  .where(
                                    (row) =>
                                        intOf(row['tier']) == tier &&
                                        intOf(row['place']) == place,
                                  )
                                  .firstOrNull) {
                                final Doc row => Text(
                                  '${intOf(row['points']) > 0 ? '+' : ''}${_number(intOf(row['points']))}',
                                  style: intOf(row['points']) < 0
                                      ? TextStyle(
                                          color: theme.colorScheme.error,
                                        )
                                      : null,
                                ),
                                _ => const Text('—'),
                              }),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        DetailSection(
          icon: Symbols.redeem_rounded,
          title: _text('dailyRewards'),
          count: dataRows(season['dailyRewards']).length,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, reward) in dataRows(
                season['dailyRewards'],
              ).indexed) ...[
                Text(
                  _text('playNumber', {'number': index + 1}),
                  style: theme.textTheme.labelMedium,
                ),
                _rewards([reward]),
              ],
            ],
          ),
        ),
        DetailSection(
          icon: Symbols.redeem_rounded,
          title: _text('seasonRewards'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final group in _grouped(
                dataRows(season['seasonRewards']),
              ).entries) ...[
                Text(
                  '${group.key} ${_text('points')}',
                  style: theme.textTheme.labelMedium,
                ),
                _rewards(group.value),
              ],
            ],
          ),
        ),
        if (ranking.isNotEmpty)
          DetailSection(
            icon: Symbols.emoji_events_rounded,
            title: _text('rankingRewards'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final group in _grouped(ranking).entries) ...[
                  Text(group.key, style: theme.textTheme.labelMedium),
                  _rewards(group.value),
                ],
              ],
            ),
          ),
        if (dataRows(season['exchanges']).isNotEmpty ||
            dataRows(season['events']).isNotEmpty)
          DetailSection(
            icon: Symbols.link_rounded,
            title: _text('related'),
            child: Column(
              children: [
                for (final (rows, kind, icon) in [
                  (
                    dataRows(season['exchanges']),
                    'exchange',
                    Symbols.storefront_rounded,
                  ),
                  (dataRows(season['events']), 'events', Symbols.event_rounded),
                ])
                  for (final entry in rows)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: entry['image'] == null
                          ? Icon(icon)
                          : SizedBox(
                              width: 56,
                              child: _art(entry['image'], size: 28),
                            ),
                      title: Text(_name(entry['title'])),
                      trailing: const Icon(Symbols.chevron_right_rounded),
                      onTap: () => openLink(context, _href(kind, entry['id'])),
                    ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _rulesTab() {
    final league = _league;
    final songs = dataRows(league['songs'])
        .where((s) => intOf(s['arenaPublishedAt']) <= _now)
        .length;
    final parameters = widget.parameters;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSection(
          icon: Symbols.description_rounded,
          title: _text('entry'),
          child: SpecList(
            facts: [
              Fact(
                _text('members'),
                _text('membersValue', {'band': _name(league['name'])}),
              ),
              Fact(_text('supports'), _text('supportsValue')),
              Fact(_text('team'), _text('teamValue')),
              Fact(_text('songCount'), _number(songs)),
              Fact(
                _text('dailyRewards'),
                _text('plays', {
                  'count': dataRows(season['dailyRewards']).length,
                }),
              ),
              if (season['rankingEndAt'] != null)
                Fact(
                  _text('rankingEnds'),
                  arenaTime(intOf(season['rankingEndAt']), _locale),
                ),
            ],
          ),
        ),
        DetailSection(
          icon: Symbols.gavel_rounded,
          title: _text('ruleValues'),
          child: SpecList(
            facts: [
              Fact(
                _text('seasonRewardBasis'),
                _text('seasonRewardBasisValue'),
                full: true,
              ),
              Fact(_text('rankScope'), _text('rankScopeValue'), full: true),
              for (final key in _ruleKeys)
                if (parameters[key] is num)
                  Fact(
                    _text('parameters.$key'),
                    _text('parameterValues.$key', {
                      'value': _number(parameters[key] as num),
                    }),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_leagues.isEmpty) return Text(_text('noSchedule'));
    _bandId ??= intOf(_leagues.first['bandId']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        _hero(theme),
        _tabs(),
        switch (_tab) {
          _Tab.overview => _overview(theme),
          _Tab.ranking => _rankingTab(theme),
          _Tab.schedule => _schedule_(theme),
          _Tab.songs => _songs(theme),
          _Tab.ranks => _ranksTab(theme),
          _Tab.rules => _rulesTab(),
        },
      ],
    );
  }
}
