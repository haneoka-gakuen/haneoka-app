import '../core/site_date.dart';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:material_symbols_icons/symbols.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import '../core/app_state.dart';
import '../core/audio.dart';
import '../core/relative_time.dart';
import '../shell/page.dart';
import '../shell/routes.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'profiles.dart';
import 'cross_server.dart';
import 'chart_rates.dart';
import 'deck_state.dart';
import 'song_analysis.dart';
import 'visuals.dart';

const _difficultyNames = ['EASY', 'NORMAL', 'HARD', 'EXPERT', 'SPECIAL'];
const _categories = ['', 'original', 'virtual', 'jpop', 'anime', 'game'];
const _attributes = ['', 'red', 'blue', 'green', 'yellow', 'purple'];
const _missions = [
  null,
  ('gekisouMissionCombo', 'COMBO', 'combo'),
  ('gekisouMissionLuck', 'LUCK', 'luck'),
  ('gekisouMissionJustCount', 'JUST', 'just'),
];

/// One chart: a song at one difficulty, with its metrics.
class _Chart {
  _Chart(this.song, this.index, this.row, this.chart, this.gekisou);
  final Entry song;
  final int index;
  final Entry row;
  final Entry chart;
  final Entry gekisou;
}

/// The website's song analysis (`song-meta`): every chart's live or gekisou
/// metrics in one sortable table, against the theoretical, current or a
/// band's reference deck.
class SongMetaScreen extends StatefulWidget {
  const SongMetaScreen({
    super.key,
    this.initialQuery = const {},
    this.initialQueryAll = const {},
    this.server,
  });
  final String? server;
  final Map<String, String> initialQuery;
  final Map<String, List<String>> initialQueryAll;
  @override
  State<SongMetaScreen> createState() => _SongMetaScreenState();
}

class _SongMetaScreenState extends State<SongMetaScreen> {
  Future<(List<_Chart>, CatalogVisuals, Map<String, String>)>? _data;
  bool _gekisou = false;
  String _tier = 'theory';
  String _sort = 'score';
  bool _scatter = false;
  bool _descending = true;
  String _query = '';
  final Set<int> _difficulties = {};
  final Set<int> _bands = {};
  final _deckController = AnalysisDeckController.instance;
  final Map<String, ChartRateTable> _rates = {};
  final Map<_Chart, SongAnalysis?> _analysisCache = {};
  AnalysisDeck get _deck => _deckController.value;
  bool _frontier = false;
  String _xMetric = 'level';
  Object? _dataKey;
  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery;
    _gekisou = q['metaMode'] == 'gekisou';
    final tier = q['metaTier'] ?? 'theory';
    final band = int.tryParse(q['metaBand'] ?? '');
    _tier = _gekisou
        ? 'theory'
        : tier == 'band' && band != null && band > 0
        ? 'band:$band'
        : tier == 'current' || RegExp(r'^band:[1-9]\d*$').hasMatch(tier)
        ? tier
        : 'theory';
    _sort = q['sort'] ?? 'score';
    _descending = q.containsKey('order') ? q['order'] == 'desc' : true;
    _query = (q['q'] ?? '').trim();
    for (final value in widget.initialQueryAll['band'] ?? [q['band'] ?? '']) {
      final id = int.tryParse(value);
      if (id != null && id > 0) _bands.add(id);
    }
    for (final value
        in widget.initialQueryAll['difficulty'] ?? [q['difficulty'] ?? '']) {
      final index = _difficultyNames.indexOf(value.toUpperCase());
      final id = index >= 0 ? index : int.tryParse(value);
      if (id != null && id >= 0 && id < _difficultyNames.length) {
        _difficulties.add(id);
      }
    }
    _scatter = const {'chart', 'scatter'}.contains(q['view']);
    _frontier = q['frontier'] == '1';
    _xMetric = q['metaX'] ?? 'level';
    _deckController.addListener(_deckChanged);
    _deckController.load(q);
  }

  void _deckChanged() {
    _analysisCache.clear();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _deckController.removeListener(_deckChanged);
    super.dispose();
  }

  String _metricLabel(String key) {
    final t = AppScope.of(context).text;
    if (liveAnalysisMetrics[key] case final name?) {
      return t('catalog.analysis.fields.$name', key);
    }
    if (rankAnalysisMetrics[key] case final rank?) {
      return t(
        'catalog.analysis.fields.metaRankScore',
        '{rank} score',
      ).replaceAll(
        '{rank}',
        const ['', '', '', 'C', 'B', 'A', 'S', 'SS'][rank],
      );
    }
    return t.label(key, key);
  }

  SongAnalysis? _analysis(_Chart c) => _analysisCache.putIfAbsent(c, () {
    final table =
            _rates[(c.song[serverKey] ??
                    widget.server ??
                    AppScope.of(context).server)
                .toString()],
        rates =
            table?.charts['${c.song['musicId'] ?? c.song['_key']}:${c.index}'];
    return table == null || rates == null
        ? null
        : SongAnalysis(
            table: table,
            rates: rates,
            deck: _deck,
            seconds: (_value(c, 'time') ?? 0).toDouble(),
          );
  });
  num? _deckValue(_Chart c, String key) =>
      _analysis(c)?.value(key, gekisou: _gekisou);
  List<_Chart> _notOutclassed(List<_Chart> rows) {
    final sorted =
        [
          for (final row in rows)
            if (_deckValue(row, 'deckScore') != null &&
                _deckValue(row, 'deckPerMinute') != null)
              row,
        ]..sort((a, b) {
          final first = _deckValue(
            b,
            'deckScore',
          )!.compareTo(_deckValue(a, 'deckScore')!);
          return first != 0
              ? first
              : _deckValue(
                  b,
                  'deckPerMinute',
                )!.compareTo(_deckValue(a, 'deckPerMinute')!);
        });
    final kept = <_Chart>{};
    var best = double.negativeInfinity;
    for (final row in sorted) {
      final value = _deckValue(row, 'deckPerMinute')!.toDouble();
      if (value > best) kept.add(row);
      best = max(best, value);
    }
    return rows.where(kept.contains).toList();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = AppScope.of(context).publicDataKey;
    if (_dataKey != key) {
      _dataKey = key;
      _data = _load();
    }
  }

  Future<(List<_Chart>, CatalogVisuals, Map<String, String>)> _load() async {
    final state = AppScope.of(context);
    final api = state.apiFor(widget.server ?? state.server);
    final (songs, metaDocuments, visuals, atlas, rateTables) = await (
      crossServerCollection(
        resource: 'songs',
        selected: widget.server ?? state.server,
        apis: state.catalogApis,
        rowsPath: null,
      ),
      Future.wait([
        for (final entry in state.catalogApis.entries)
          entry.value
              .catalog('song-meta')
              .then(
                (value) => (entry.key, value),
                onError: (Object error) {
                  if (entry.key == state.server) throw error;
                  return (entry.key, null);
                },
              ),
      ]),
      CatalogVisuals.of(api),
      api
          .json(
            '/api/v1/servers/${api.server}/sources/Assets/AddressableResources/Live/Images/Atlas/LiveAtlas.spriteatlasv2',
          )
          .then<Object?>((v) => v, onError: (_) => null),
      Future.wait([
        for (final entry in state.catalogApis.entries)
          ChartRateTable.load(entry.value).then<(String, ChartRateTable?)>(
            (value) => (entry.key, value),
            onError: (_) => (entry.key, null),
          ),
      ]),
    ).wait;
    _rates.clear();
    for (final (server, table) in rateTables) {
      if (table != null) _rates[server] = table;
    }
    _analysisCache.clear();
    final pattern = RegExp(r'Icon_gekisou_(combo|luck|just)--');
    final icons = <String, String>{};
    for (final output in ((atlas as Map?)?['outputs'] as List? ?? const [])) {
      final path = output is Map ? '${output['path']}' : '';
      final match = pattern.firstMatch(path);
      if (match != null) {
        icons[match[1]!] = api
            .asset('/runtime/${api.server}/${path.substring(8)}')
            .toString();
      }
    }
    final charts = <_Chart>[];
    final meta = {
      for (final (server, document) in metaDocuments) server: document,
    };
    for (final song in songs) {
      final source = '${song[serverKey] ?? state.server}';
      final value =
          (meta[source] as Map?)?['${song['musicId'] ?? song['_key']}'];
      if (value is! Map) continue;
      final rows = (song['difficulty'] as List? ?? const [])
          .whereType<Entry>()
          .toList();
      for (final MapEntry(key: index, value: difficulty) in value.entries) {
        final i = int.tryParse('$index');
        if (i == null || difficulty is! Map || difficulty['chart'] is! Entry) {
          continue;
        }
        charts.add(
          _Chart(
            song,
            i,
            rows.where((r) => r['difficulty'] == i).firstOrNull ??
                (i >= 0 && i < rows.length ? rows[i] : const {}),
            difficulty['chart'] as Entry,
            (difficulty['gekisou'] as Entry?) ?? const {},
          ),
        );
      }
    }
    return (charts, visuals, icons);
  }

  num? _value(_Chart c, String key) {
    if (liveAnalysisMetrics.containsKey(key) ||
        rankAnalysisMetrics.containsKey(key)) {
      return _deckValue(c, key);
    }
    num? read(Object? v) => v is num ? v : null;
    if (key == 'bpm') {
      return read(
        c.chart['firstBpm'] ?? c.chart['minBpm'] ?? c.chart['maxBpm'],
      );
    }
    if (key == 'n') return read(c.chart['n'] ?? c.chart['canonicalNoteCount']);
    if (key == 'level') {
      return read(
        c.row['displayLevel'] ?? c.row['playLevel'] ?? c.chart['displayLevel'],
      );
    }
    if (key == 'release') return RelativeTime.timestamp(c.song['publishedAt']);
    if (_gekisou) {
      switch (key) {
        case 'score':
          return read(c.gekisou['score']);
        case 'eff':
          return read(c.gekisou['eff']);
        case 'justable':
          return read(c.gekisou['justableTotal']);
        case 'justableRate':
          return read(c.gekisou['justableRate']);
        case 'luck':
          final total = (c.gekisou['segments'] as List? ?? const [])
              .whereType<Map>()
              .fold<num>(
                0,
                (sum, s) => sum + ((s['luckExpected'] as num?) ?? 0),
              );
          return total == 0 ? null : total;
      }
    }
    if (_tier != 'theory' && const {'score', 'eff', 'sr'}.contains(key)) {
      final profile = (c.chart['profiles'] as Map?)?[_tier];
      return profile is Map ? read(profile[key]) : null;
    }
    return read(c.chart[key]);
  }

  String _format(_Chart c, String key, String unavailable) {
    final value = _value(c, key);
    final locale = AppScope.of(context).text.locale;
    if (value == null) {
      return _tier != 'theory' && const {'score', 'eff', 'sr'}.contains(key)
          ? unavailable
          : '—';
    }
    if (key == 'deckReach') {
      return '${NumberFormat('0.#', locale).format(value * 100)}%';
    }
    if (key == 'eventPoints') {
      return NumberFormat('#,##0.#', locale).format(value);
    }
    if (key == 'time') {
      final s = value.round();
      return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    }
    if (const {'score', 'eff', 'sr', 'justableRate'}.contains(key)) {
      return '${NumberFormat.decimalPattern(locale).format((value * 100).round())}%';
    }
    if (key == 'nps') return value.toStringAsFixed(2);
    return NumberFormat.decimalPattern(locale).format(value.round());
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    String label(String key, [String? fallback]) => t.label(key, fallback);
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final visuals = data?.$2;
        var rows = data?.$1 ?? const <_Chart>[];
        final query = _query.toLowerCase();
        rows = [
          for (final c in rows)
            if ((_difficulties.isEmpty || _difficulties.contains(c.index)) &&
                (_bands.isEmpty || _bands.contains(c.song['bandId'])) &&
                (_tier.startsWith('band:')
                    ? '${c.song['bandId']}' == _tier.substring(5)
                    : true) &&
                (query.isEmpty ||
                    [
                      ...?(c.song['musicTitle'] as List?)?.whereType<String>(),
                      '${c.song['musicId']}',
                    ].join(' ').toLowerCase().contains(query)))
              c,
        ];
        if (_frontier && !_gekisou && _rates.isNotEmpty) {
          rows = _notOutclassed(rows);
        }
        rows.sort((a, b) {
          if (_sort == 'title') {
            final x = state.songTitle(a.song['musicTitle']),
                y = state.songTitle(b.song['musicTitle']);
            return _descending ? y.compareTo(x) : x.compareTo(y);
          }
          if (_sort == 'musicType' || _sort == 'band') {
            final key = _sort == 'band' ? 'bandId' : 'musicType';
            final x = (a.song[key] as num?) ?? 0,
                y = (b.song[key] as num?) ?? 0;
            return _descending ? y.compareTo(x) : x.compareTo(y);
          }
          final x = _value(a, _sort), y = _value(b, _sort);
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return _descending ? y.compareTo(x) : x.compareTo(y);
        });
        return ShellPage(
          title: t('catalog.songs.fields.songMeta', 'Song analysis'),
          search: ShellSearch(
            label: t('common.actions.search', 'Search'),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
          status: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                data == null
                    ? ''
                    : NumberFormat.decimalPattern(t.locale).format(rows.length),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          actions: [
            BarAction(
              icon: Symbols.playlist_play_rounded,
              label: label('playAll', 'Play all'),
              onPressed: rows.isEmpty
                  ? null
                  : () => state.audio.playQueue([
                      for (final c in {
                        for (final c in rows) c.song['musicId']: c,
                      }.values)
                        if (c.song['musicUrl'] case final String url)
                          Track(
                            id: '${c.song['musicId']}',
                            songKey:
                                'our-notes:${state.api.server}:${c.song['musicId']}',
                            url: state.api.asset(url).toString(),
                            title: state.songTitle(c.song['musicTitle']),
                            subtitle: t.text(
                              visuals?.bands[c.song['bandId']]?['bandName'],
                            ),
                            artwork: c.song['jacketUrl'] is String
                                ? state.api
                                      .asset(c.song['jacketUrl'] as String)
                                      .toString()
                                : null,
                          ),
                    ]),
            ),
            BarAction(
              icon: Symbols.filter_alt_rounded,
              label: t('common.actions.filter', 'Filter'),
              badge: _difficulties.length + _bands.length,
              onPressed: visuals == null
                  ? null
                  : () => _filters(context, visuals),
            ),
            BarAction.choice(
              label: t('catalog.analysis.fields.scatter', 'Scatter'),
              options: [
                BarChoice(
                  icon: Symbols.table_rows_rounded,
                  label: label('table', 'Table'),
                  selected: !_scatter,
                  onSelected: () => setState(() => _scatter = false),
                ),
                BarChoice(
                  icon: Symbols.monitoring_rounded,
                  label: t('catalog.analysis.fields.scatter', 'Scatter'),
                  selected: _scatter,
                  onSelected: () => setState(() => _scatter = true),
                ),
              ],
            ),
            BarAction.choice(
              label: label('metaMode', 'Mode'),
              options: [
                BarChoice(
                  icon: Symbols.music_note_rounded,
                  label: label('metaModeLive', 'Live'),
                  selected: !_gekisou,
                  onSelected: () => setState(() => _gekisou = false),
                ),
                BarChoice(
                  icon: Symbols.bolt_rounded,
                  label: label('metaModeGekisou', 'Gekisou'),
                  selected: _gekisou,
                  onSelected: () => setState(() {
                    _gekisou = true;
                    _tier = 'theory';
                  }),
                ),
              ],
            ),
          ],
          body: snapshot.hasError
              ? Center(
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Symbols.refresh_rounded),
                    label: Text(t('common.actions.retry', 'Retry')),
                    onPressed: () => setState(() => _data = _load()),
                  ),
                )
              : data == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (!_gekisou) _tiers(context, data.$2, data.$1),
                    Expanded(
                      child: _scatter
                          ? _scatterChart(context, rows)
                          : _table(context, rows, data.$2, data.$3, label),
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// Charts as points: level across, the sorted metric up, coloured by
  /// difficulty (`metaScatter`).
  Widget _scatterChart(BuildContext context, List<_Chart> rows) {
    const numeric = {
      'score',
      'eff',
      'time',
      'bpm',
      'n',
      'nps',
      'sr',
      'justable',
      'justableRate',
      'luck',
    };
    final metrics = {
      ...numeric,
      ...liveAnalysisMetrics.keys,
      ...rankAnalysisMetrics.keys,
    };
    final metric = metrics.contains(_sort) ? _sort : 'score';
    final percent = const {
      'score',
      'eff',
      'sr',
      'justableRate',
      'deckReach',
    }.contains(metric);
    final t = AppScope.of(context).text;
    final number = NumberFormat.decimalPattern(t.locale)
      ..maximumFractionDigits = percent ? 0 : 1;
    String format(num value) =>
        percent ? '${number.format(value * 100)}%' : number.format(value);
    final points = [
      for (final c in rows)
        if ((_xMetric == 'level'
                ? (c.row['sortLevel'] ??
                      c.row['displayLevel'] ??
                      c.row['playLevel'])
                : _value(c, _xMetric))
            case final num level)
          if (_value(c, metric) case final num value)
            (level.toDouble(), value.toDouble(), c),
    ];
    final padding = pagePadding(context);
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(
            constraints.maxWidth,
            (constraints.maxWidth / 2).clamp(240, constraints.maxHeight),
          );
          final painter = _ScatterPainter(
            points: [
              for (final (x, y, c) in points)
                (x, y, difficultyColors[c.index.clamp(0, 4)]),
            ],
            format: format,
            scheme: Theme.of(context).colorScheme,
            textStyle: Theme.of(context).textTheme.labelSmall!,
            xFormat: _xMetric == 'level'
                ? null
                : (value) =>
                      const {
                        'score',
                        'eff',
                        'sr',
                        'justableRate',
                        'deckReach',
                      }.contains(_xMetric)
                      ? '${NumberFormat('0.#', t.locale).format(value * 100)}%'
                      : NumberFormat('#,##0.#', t.locale).format(value),
            xLabel: _metricLabel(_xMetric),
            yLabel: _metricLabel(metric),
          );
          return Align(
            alignment: Alignment.topCenter,
            child: GestureDetector(
              onTapUp: (details) {
                final hit = painter.hit(details.localPosition, size);
                if (hit != null) {
                  openEntity(
                    context,
                    catalogProfiles.firstWhere((p) => p.resource == 'songs'),
                    points[hit].$3.song,
                    api: AppScope.of(context).apiFor(
                      '${points[hit].$3.song[serverKey] ?? AppScope.of(context).server}',
                    ),
                  );
                }
              },
              child: CustomPaint(size: size, painter: painter),
            ),
          );
        },
      ),
    );
  }

  /// The reference tiers (`character-pair__bands`): All, Current, each band's logo.
  Widget _tiers(
    BuildContext context,
    CatalogVisuals visuals,
    List<_Chart> all,
  ) {
    final t = AppScope.of(context).text;
    final scheme = Theme.of(context).colorScheme;
    final bands = {
      for (final c in all) (c.song['bandId'] as num?)?.toInt(),
    }.whereType<int>().where(visuals.bands.containsKey).toList()..sort();
    final options = [
      ('theory', t.label('all', 'All'), null as String?),
      ('current', t.label('current', 'Current'), null),
      for (final id in bands)
        (
          'band:$id',
          t.text(visuals.bands[id]?['bandName']),
          visuals.bandLogo(id),
        ),
    ];
    final padding = pagePadding(context);
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(padding.left, 12, padding.right, 4),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (key, label, image) = options[index];
          final selected = key == _tier;
          return Tooltip(
            message: label,
            child: Material(
              color: selected
                  ? scheme.secondaryContainer
                  : scheme.surfaceContainer,
              shape: RoundedRectangleBorder(
                side: BorderSide(
                  color: selected ? scheme.primary : Colors.transparent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: InkWell(
                customBorder: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                onTap: () => setState(() => _tier = key),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 64,
                    minHeight: 48,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Center(
                      child: image == null
                          ? Text(
                              label,
                              style: Theme.of(context).textTheme.labelLarge,
                            )
                          : SizedBox(
                              width: 96,
                              height: 32,
                              child: AppImage(candidates: [image]),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _table(
    BuildContext context,
    List<_Chart> rows,
    CatalogVisuals visuals,
    Map<String, String> icons,
    String Function(String, [String?]) label,
  ) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final columns = <(String, String, double, bool)>[
      ('title', label('title'), compact ? 132 : 280, false),
      ('musicType', label('attribute'), 72, false),
      ('band', label('band'), 168, false),
      ('level', label('level'), 96, true),
      ('time', label('metaTime', 'Song Duration'), 96, true),
      ('score', label('metaScoreFactor', 'Factor'), 96, true),
      ('eff', label('metaEff', 'Efficiency'), 104, true),
      if (_rates.isNotEmpty) ...[
        if (!_gekisou)
          for (final key in liveAnalysisMetrics.keys)
            (key, _metricLabel(key), 152, true),
        for (final key in rankAnalysisMetrics.keys)
          (key, _metricLabel(key), 128, true),
      ],
      if (_gekisou) ...[
        ('justableRate', label('justableRate'), 104, true),
        ('justable', label('justable'), 104, true),
        ('luck', label('luck'), 104, true),
      ],
      ('bpm', label('metaBpm', 'BPM'), 96, true),
      ('n', label('metaN', 'Notes'), 96, true),
      ('nps', label('metaNps', 'NPS'), 104, true),
      if (!_gekisou) ('sr', label('metaSr', 'Skill Coverage Rate'), 112, true),
      ('phase1', '${label('gekisouPhase', 'Phase')} 1', 120, false),
      ('phase2', '${label('gekisouPhase', 'Phase')} 2', 120, false),
      ('phase3', '${label('gekisouPhase', 'Phase')} 3', 120, false),
      ('category', label('category'), 120, false),
      ('release', label('release'), 128, true),
      ('play', '', 56, false),
    ];
    final unavailable = label('unavailable', 'Unavailable');
    final sortable = {
      'title',
      'musicType',
      'band',
      'level',
      'time',
      'score',
      'eff',
      'bpm',
      'n',
      'nps',
      'sr',
      'justableRate',
      'justable',
      'luck',
      'release',
      ...liveAnalysisMetrics.keys,
      ...rankAnalysisMetrics.keys,
    };

    Widget header(int column) {
      final (key, text, _, numeric) = columns[column];
      final active = key == _sort;
      return InkWell(
        onTap: sortable.contains(key)
            ? () => setState(() {
                if (active) {
                  _descending = !_descending;
                } else {
                  _sort = key;
                  _descending = numeric;
                }
              })
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: numeric
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              Flexible(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (sortable.contains(key))
                Icon(
                  active && !_descending
                      ? Symbols.arrow_upward_rounded
                      : Symbols.arrow_downward_rounded,
                  size: 16,
                  color: active ? scheme.primary : scheme.outline,
                ),
            ],
          ),
        ),
      );
    }

    Widget cell(_Chart c, int column) {
      final (key, _, _, numeric) = columns[column];
      Widget text(String value) => Align(
        alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
      final band = (c.song['bandId'] as num?)?.toInt();
      switch (key) {
        case 'title':
          final jacket = c.song['jacketUrl'] ?? c.song['jacketThumbUrl'];
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 12,
              vertical: 6,
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox.square(
                    dimension: compact ? 36 : 44,
                    child: jacket is String
                        ? AppImage(
                            candidates: [state.api.asset(jacket).toString()],
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                ),
                SizedBox(width: compact ? 8 : 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.songTitle(c.song['musicTitle']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: compact
                            ? theme.textTheme.labelLarge
                            : theme.textTheme.titleSmall,
                      ),
                      Text(
                        t.text(visuals.bands[band]?['bandName']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        case 'musicType':
          final mark = visuals.musicTypeMark(c.song['musicType']);
          final id = (c.song['musicType'] as num?)?.toInt() ?? 0;
          return Center(
            child: mark == null
                ? Text(
                    id > 0 && id < _attributes.length
                        ? t.label(_attributes[id])
                        : '—',
                  )
                : SizedBox.square(
                    dimension: 24,
                    child: AppImage(candidates: [mark]),
                  ),
          );
        case 'band':
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (visuals.bandLogo(band) case final logo?)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 48,
                      height: 24,
                      child: AppImage(candidates: [logo]),
                    ),
                  ),
                Expanded(
                  child: Text(
                    t.text(visuals.bands[band]?['bandName']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        case 'level':
          final level = '${c.row['displayLevel'] ?? c.row['playLevel'] ?? '—'}'
              .replaceAll(RegExp(r'\.0$'), '');
          return Center(
            child: DifficultyChips(
              levels: [(c.index, _difficultyNames[c.index.clamp(0, 4)], level)],
              captions: {
                if (state.difficultyEstimates)
                  if ((c.row['difficultyEstimate']
                          as Map?)?['estimatedConstant']
                      case final num v)
                    c.index: v.toStringAsFixed(1),
              },
            ),
          );
        case 'phase1' || 'phase2' || 'phase3':
          final types =
              ((c.song['gekisou'] as Map?)?['missionTypes'] as List?) ??
              const [];
          final phase = int.parse(key.substring(5)) - 1;
          final type = phase < types.length
              ? (types[phase] as num?)?.toInt() ?? 0
              : 0;
          final mission = type > 0 && type < _missions.length
              ? _missions[type]
              : null;
          if (mission == null) return text('—');
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (icons[mission.$3] case final icon?)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: SizedBox.square(
                      dimension: 24,
                      child: AppImage(candidates: [icon]),
                    ),
                  ),
                Flexible(
                  child: Text(
                    t.label(mission.$1, mission.$2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        case 'category':
          return text(
            [
              for (final id in (c.song['musicCategories'] as List? ?? const []))
                if (id is num && id > 0 && id < _categories.length)
                  t.label(_categories[id.toInt()]),
            ].join(', ').ifEmpty('—'),
          );
        case 'release':
          final at = RelativeTime.timestamp(c.song['publishedAt']);
          return text(
            at == null
                ? '—'
                : SiteDate.day(t.locale)
                      .format(DateTime.fromMillisecondsSinceEpoch(at.toInt())),
          );
        case 'play':
          final url = c.song['musicUrl'];
          if (url is! String) return const SizedBox.shrink();
          final track = Track(
            id: '${c.song['musicId']}',
            songKey: 'our-notes:${state.api.server}:${c.song['musicId']}',
            url: state.api.asset(url).toString(),
            title: state.songTitle(c.song['musicTitle']),
            artwork: c.song['jacketUrl'] is String
                ? state.api.asset(c.song['jacketUrl'] as String).toString()
                : null,
          );
          return ListenableBuilder(
            listenable: state.audio,
            builder: (context, _) => IconButton(
              tooltip: t('common.actions.play', 'Play'),
              onPressed: () => state.audio.enqueueTrack(track),
              icon: Icon(
                state.audio.isPlaying(track.id, track.url)
                    ? Symbols.pause_rounded
                    : Symbols.play_arrow_rounded,
              ),
            ),
          );
        default:
          return text(_format(c, key, unavailable));
      }
    }

    final songsProfile = catalogProfiles.firstWhere(
      (p) => p.resource == 'songs',
    );
    final padding = pagePadding(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(padding.left, 8, padding.right, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Corner.large),
          ),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Corner.large),
          ),
          child: TableView.builder(
            pinnedRowCount: 1,
            pinnedColumnCount: 1,
            columnCount: columns.length,
            rowCount: rows.length + 1,
            columnBuilder: (index) => TableSpan(
              extent: FixedTableSpanExtent(columns[index].$3),
              foregroundDecoration: index == 0
                  ? TableSpanDecoration(
                      border: TableSpanBorder(
                        trailing: BorderSide(color: scheme.outlineVariant),
                      ),
                    )
                  : null,
            ),
            rowBuilder: (index) => TableSpan(
              extent: FixedTableSpanExtent(index == 0 ? 56 : 72),
              backgroundDecoration: TableSpanDecoration(
                color: index == 0 ? scheme.surfaceContainer : scheme.surface,
                border: TableSpanBorder(
                  trailing: BorderSide(
                    color: scheme.outlineVariant,
                    width: 0.5,
                  ),
                ),
              ),
              recognizerFactories: index == 0
                  ? const {}
                  : {
                      TapGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                            TapGestureRecognizer
                          >(
                            () => TapGestureRecognizer(),
                            (recognizer) => recognizer.onTap = () => openEntity(
                              context,
                              songsProfile,
                              rows[index - 1].song,
                              api: AppScope.of(context).apiFor(
                                '${rows[index - 1].song[serverKey] ?? AppScope.of(context).server}',
                              ),
                            ),
                          ),
                    },
            ),
            cellBuilder: (context, vicinity) => TableViewCell(
              child: vicinity.row == 0
                  ? header(vicinity.column)
                  : cell(rows[vicinity.row - 1], vicinity.column),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _deckFilters(BuildContext context, StateSetter setSheet) {
    final text = AppScope.of(context).text;
    String t(String key, String fallback) =>
        text('catalog.analysis.fields.$key', fallback);
    void apply(AnalysisDeck deck) {
      _deckController.set(deck);
      setSheet(() {});
    }

    Widget title(String value) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(value, style: Theme.of(context).textTheme.titleSmall),
    );
    Widget number(
      String id,
      String label,
      num value,
      num maximum,
      ValueChanged<double> change,
    ) => TextFormField(
      key: ValueKey(id),
      initialValue: value == value.truncate()
          ? value.truncate().toString()
          : value.toString(),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
      onChanged: (raw) {
        final value = double.tryParse(raw);
        if (value != null && value.isFinite && value >= 0 && value <= maximum) {
          change(value);
        }
      },
    );
    Widget row(List<Widget> fields) => Row(
      children: [
        for (var i = 0; i < fields.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: fields[i]),
        ],
      ],
    );
    final result = <Widget>[];
    if (_gekisou) {
      result.addAll([
        title(t('deckRoom', 'Players in room')),
        SegmentedButton<int>(
          segments: [
            for (var i = 1; i <= 5; i++)
              ButtonSegment(value: i, label: Text(i.toString())),
          ],
          selected: {_deck.room},
          onSelectionChanged: (v) => apply(_deck.copyWith(room: v.first)),
        ),
      ]);
    } else {
      result.addAll([
        title(t('deck', 'Deck')),
        number('deckPower', t('deckPower', 'Power'), _deck.power, 99999999, (
          value,
        ) {
          if (value >= 1) apply(_deck.copyWith(power: value.round()));
        }),
        title(t('deckSkills', 'Score skills (%)')),
        row([
          for (var i = 0; i < 5; i++)
            number(
              'slotScore$i',
              (i + 1).toString(),
              _deck.slots[i].score + _deck.slots[i].perfect,
              1000,
              (value) => apply(
                _deck.copyWith(
                  slots: [
                    for (var n = 0; n < 5; n++)
                      if (n != i)
                        _deck.slots[n]
                      else
                        _deck.slots[n].perfect > 0 && _deck.slots[n].score == 0
                            ? _deck.slots[n].copyWith(perfect: value)
                            : _deck.slots[n].copyWith(score: value, perfect: 0),
                  ],
                ),
              ),
            ),
        ]),
        title(t('deckExtension', 'Snap skill extension (s)')),
        row([
          for (var i = 0; i < 5; i++)
            number(
              'slotExtension$i',
              (i + 1).toString(),
              _deck.slots[i].extensionMs / 1000,
              6,
              (value) => apply(
                _deck.copyWith(
                  slots: [
                    for (var n = 0; n < 5; n++)
                      if (n != i)
                        _deck.slots[n]
                      else
                        _deck.slots[n].copyWith(
                          extensionMs: (value * 4).round() * 250,
                        ),
                  ],
                ),
              ),
            ),
        ]),
        title(t('deckPlay', 'Play')),
        row([
          number(
            'deckGreat',
            t('deckGreat', 'Great (%)'),
            _deck.great,
            100,
            (v) => apply(_deck.copyWith(great: v.round())),
          ),
          number(
            'deckOverhead',
            t('deckOverhead', 'Time between plays (s)'),
            _deck.overhead,
            600,
            (v) => apply(_deck.copyWith(overhead: v.round())),
          ),
        ]),
      ]);
      final table = _rates[widget.server ?? AppScope.of(context).server];
      if (table != null && table.events.isNotEmpty) {
        final selected = _deck.event == 0
            ? (table.events.toList()..sort(
                    (a, b) => (b.startAt ?? 0).compareTo(a.startAt ?? 0),
                  ))
                  .where(
                    (e) =>
                        e.startAt != null &&
                        e.startAt! <= DateTime.now().millisecondsSinceEpoch,
                  )
                  .firstOrNull
                  ?.id
            : _deck.event;
        result.addAll([
          title(t('deckEvent', 'Event')),
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: table.events.any((e) => e.id == selected)
                ? selected
                : table.events.first.id,
            decoration: InputDecoration(labelText: t('deckEvent', 'Event')),
            items: [
              for (final event in table.events)
                DropdownMenuItem(
                  value: event.id,
                  child: Text(
                    text.text(event.title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) apply(_deck.copyWith(event: v));
            },
          ),
          const SizedBox(height: 12),
          number(
            'deckBoosts',
            t('deckBoosts', 'Boosts per live'),
            _deck.boosts,
            10,
            (v) => apply(_deck.copyWith(boosts: v.round())),
          ),
          const SizedBox(height: 12),
          row([
            number(
              'deckPointBonus',
              t('deckPointBonus', 'Event point bonus (%)'),
              _deck.pointBonus,
              100000,
              (v) => apply(_deck.copyWith(pointBonus: v.round())),
            ),
            number(
              'deckItemBonus',
              t('deckItemBonus', 'Event item bonus (%)'),
              _deck.itemBonus,
              100000,
              (v) => apply(_deck.copyWith(itemBonus: v.round())),
            ),
          ]),
        ]);
      }
      result.addAll([
        title(t('frontier', 'Charts')),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: false, label: Text(text.label('all', 'All'))),
            ButtonSegment(
              value: true,
              label: Text(t('frontierOnly', 'Not outclassed')),
            ),
          ],
          selected: {_frontier},
          onSelectionChanged: (v) {
            setState(() => _frontier = v.first);
            setSheet(() {});
          },
        ),
        title(t('deckRank', 'Target rank')),
        SegmentedButton<int>(
          segments: [
            for (final e in rankAnalysisMetrics.entries)
              ButtonSegment(
                value: e.value,
                label: Text(
                  const ['', '', '', 'C', 'B', 'A', 'S', 'SS'][e.value],
                ),
              ),
          ],
          selected: {_deck.rank},
          onSelectionChanged: (v) => apply(_deck.copyWith(rank: v.first)),
        ),
      ]);
    }
    if (_scatter) {
      final metrics = [
        'level',
        'score',
        'eff',
        'time',
        'bpm',
        'n',
        'nps',
        'sr',
        'justable',
        'justableRate',
        'luck',
        if (!_gekisou) ...liveAnalysisMetrics.keys,
        ...rankAnalysisMetrics.keys,
      ];
      result.addAll([
        title(t('scatterX', 'Horizontal axis')),
        DropdownButtonFormField<String>(
          initialValue: metrics.contains(_xMetric) ? _xMetric : 'level',
          isExpanded: true,
          items: [
            for (final key in metrics)
              DropdownMenuItem(value: key, child: Text(_metricLabel(key))),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() => _xMetric = value);
              setSheet(() {});
            }
          },
        ),
        title(text.label('sort', 'Sort')),
        DropdownButtonFormField<String>(
          initialValue: metrics.contains(_sort) ? _sort : 'score',
          isExpanded: true,
          items: [
            for (final key in metrics)
              DropdownMenuItem(value: key, child: Text(_metricLabel(key))),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() => _sort = value);
              setSheet(() {});
            }
          },
        ),
      ]);
    }
    return result;
  }

  void _filters(BuildContext context, CatalogVisuals visuals) {
    final t = AppScope.of(context).text;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void toggle(Set<int> set, int value) {
            setState(
              () => set.contains(value) ? set.remove(value) : set.add(value),
            );
            setSheet(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                16 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t('common.actions.filter', 'Filter'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _difficulties.clear();
                            _bands.clear();
                          });
                          setSheet(() {});
                        },
                        child: Text(t('common.actions.reset', 'Reset')),
                      ),
                    ],
                  ),
                  if (_rates.isNotEmpty) ..._deckFilters(context, setSheet),
                  const SizedBox(height: 8),
                  Text(
                    t.label('difficulty', 'Difficulty'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  DifficultyChips(
                    levels: [
                      for (var i = 0; i < 5; i++) (i, _difficultyNames[i], ''),
                    ],
                    selected: _difficulties.length == 1
                        ? _difficulties.first
                        : null,
                    onSelected: (i) => toggle(_difficulties, i),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t.label('band'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final MapEntry(:key, :value)
                          in visuals.bands.entries)
                        FilterChip(
                          avatar: visuals.bandIcon(key) == null
                              ? null
                              : AppImage(candidates: [visuals.bandIcon(key)!]),
                          label: Text(t.text(value['bandName'])),
                          selected: _bands.contains(key),
                          onSelected: (_) => toggle(_bands, key),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _ScatterPainter extends CustomPainter {
  _ScatterPainter({
    required this.points,
    required this.format,
    required this.scheme,
    required this.textStyle,
    required this.xLabel,
    required this.yLabel,
    this.xFormat,
  });
  final List<(double, double, Color)> points;
  final String Function(num) format;
  final ColorScheme scheme;
  final TextStyle textStyle;
  final String xLabel;
  final String yLabel;
  final String Function(num)? xFormat;
  static const _pad = (left: 64.0, right: 16.0, top: 20.0, bottom: 40.0);

  ({double xMin, double xMax, double yMin, double yMax})? _range() {
    if (points.isEmpty) return null;
    final xs = points.map((p) => p.$1), ys = points.map((p) => p.$2);
    final yLow = ys.reduce((a, b) => a < b ? a : b),
        yHigh = ys.reduce((a, b) => a > b ? a : b);
    final yPad = (yHigh - yLow) * 0.05 == 0 ? 1.0 : (yHigh - yLow) * 0.05;
    final xLow = xs.reduce(min),
        xHigh = xs.reduce(max),
        xPad = (xHigh - xLow) * .05 == 0 ? 1.0 : (xHigh - xLow) * .05;
    return (
      xMin: xFormat == null ? xLow.floorToDouble() : xLow - xPad,
      xMax: xFormat == null ? xHigh.ceilToDouble() : xHigh + xPad,
      yMin: yLow - yPad,
      yMax: yHigh + yPad,
    );
  }

  Offset _at(
    double x,
    double y,
    Size size,
    ({double xMin, double xMax, double yMin, double yMax}) r,
  ) => Offset(
    _pad.left +
        (x - r.xMin) /
            (r.xMax - r.xMin).clamp(
              xFormat == null ? 1 : 1e-9,
              double.infinity,
            ) *
            (size.width - _pad.left - _pad.right),
    size.height -
        _pad.bottom -
        (y - r.yMin) /
            (r.yMax - r.yMin) *
            (size.height - _pad.top - _pad.bottom),
  );

  int? hit(Offset position, Size size) {
    final r = _range();
    if (r == null) return null;
    for (var i = points.length - 1; i >= 0; i--) {
      if ((_at(points[i].$1, points[i].$2, size, r) - position).distance <=
          10) {
        return i;
      }
    }
    return null;
  }

  /// `ticks`: round steps of 1, 2, 2.5, 5 or 10.
  static List<double> _ticks(double min, double max, int count) {
    final raw = ((max - min).abs() < 1e-9 ? 1e-9 : max - min) / count;
    final power = pow10((log10(raw)).floor());
    final step = [
      1,
      2,
      2.5,
      5,
      10,
    ].map((f) => f * power).firstWhere((v) => v >= raw, orElse: () => raw);
    return [
      for (
        var v = (min / step).ceil() * step;
        v <= max + step * 1e-6;
        v += step
      )
        v,
    ];
  }

  static double log10(double v) => log(v) / ln10;
  static double pow10(int e) => pow(10, e).toDouble();

  TextPainter _label(String text) => TextPainter(
    text: TextSpan(
      text: text,
      style: textStyle.copyWith(color: scheme.onSurfaceVariant),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    TextAlign align = TextAlign.left,
  }) {
    final painter = _label(text);
    final dx = switch (align) {
      TextAlign.right => -painter.width,
      TextAlign.center => -painter.width / 2,
      _ => 0.0,
    };
    painter.paint(canvas, at + Offset(dx, -painter.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = _range();
    if (r == null) return;
    final grid = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = 1;
    for (final value in _ticks(r.yMin, r.yMax, 6)) {
      final y = _at(r.xMin, value, size, r).dy;
      canvas.drawLine(
        Offset(_pad.left, y),
        Offset(size.width - _pad.right, y),
        grid,
      );
      _text(
        canvas,
        format(value),
        Offset(_pad.left - 8, y),
        align: TextAlign.right,
      );
    }
    String xText(num value) => xFormat?.call(value) ?? '${value.round()}';
    final labelWidth = _ticks(
      r.xMin,
      r.xMax,
      12,
    ).fold(0.0, (width, value) => max(width, _label(xText(value)).width));
    final tickCount =
        ((size.width - _pad.left - _pad.right) / (labelWidth + 12))
            .floor()
            .clamp(1, 12);
    for (final value in _ticks(
      r.xMin,
      r.xMax,
      tickCount,
    ).where((v) => xFormat != null || v == v.roundToDouble())) {
      final x = _at(value, r.yMin, size, r).dx;
      final label = xText(value);
      final halfWidth = _label(label).width / 2;
      canvas.drawLine(
        Offset(x, _pad.top),
        Offset(x, size.height - _pad.bottom),
        grid,
      );
      _text(
        canvas,
        label,
        Offset(
          x.clamp(halfWidth, size.width - halfWidth),
          size.height - _pad.bottom + 14,
        ),
        align: TextAlign.center,
      );
    }
    _text(
      canvas,
      xLabel,
      Offset(size.width - _pad.right, size.height - 8),
      align: TextAlign.right,
    );
    _text(canvas, yLabel, Offset(_pad.left, _pad.top - 10));
    for (final (x, y, color) in points) {
      final at = _at(x, y, size, r);
      canvas.drawCircle(at, 6, Paint()..color = color.withValues(alpha: 0.75));
      canvas.drawCircle(
        at,
        6,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ScatterPainter old) => old.points != points;
}
