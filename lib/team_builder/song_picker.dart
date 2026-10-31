import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../catalog/catalog_query.dart';
import '../ui/tile.dart';
import 'catalog.dart';
import 'catalog_sort.dart';
import 'engine/api.dart';
import 'settings.dart' show normalizeSongRules;
import 'engine/num.dart';
import 'pickers.dart' show SelectionPane;
import 'widgets.dart';

Future<List<SongRef>?> pickSongs(
  BuildContext context,
  TeamCatalog catalog,
  List<SongRef> songs, {
  bool single = false,
  List<int>? allowed,
  List<SongRef>? allowedCharts,
  Doc? songRules,
  String selectionContext = 'build',
}) => Navigator.of(context).push<List<SongRef>>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => SongPicker(
      catalog: catalog,
      initial: songs,
      single: single,
      allowed: allowed,
      allowedCharts: allowedCharts,
      songRules: songRules,
      selectionContext: selectionContext,
    ),
  ),
);

class SongPicker extends StatefulWidget {
  const SongPicker({
    super.key,
    required this.catalog,
    required this.initial,
    required this.single,
    required this.selectionContext,
    this.allowed,
    this.allowedCharts,
    this.songRules,
  });
  final TeamCatalog catalog;
  final List<SongRef> initial;
  final bool single;
  final String selectionContext;
  final List<int>? allowed;
  final List<SongRef>? allowedCharts;
  final Doc? songRules;
  @override
  State<SongPicker> createState() => SongPickerState();
}

class SongPickerState extends State<SongPicker> {
  late List<SongRef> _songs = [...widget.initial];
  List<SongRef>? _undo;
  late final String _preferenceKey =
      '${widget.selectionContext}:${widget.single}';
  String _query = '', _view = 'all';
  Set<int> _difficulties = {3};
  final _bands = <String>{},
      _categories = <String>{},
      _attributes = <String>{},
      _missions = <String>{};
  bool _containsMissions = false;
  double? _minLevel, _maxLevel, _maxSeconds;
  TeamCatalog get catalog => widget.catalog;
  late final _queryEngine = CatalogQueryEngine(
    visuals: catalog.visuals,
    game: 'our-notes',
    kind: 'song',
    characters: catalog.cardQueryEngine.characters,
    bands: catalog.cardQueryEngine.bands,
    aliases: [
      for (final key in objectRow(catalog.data['songs']).keys)
        if (int.tryParse(key) case final id?)
          if (_bandValues(id).any((v) => v.startsWith('credit:')))
            for (final name in _artistNames(id))
              (name, 'collectionBand', _bandValues(id).first),
    ],
  );
  @override
  void initState() {
    super.initState();
    final saved = catalog.songPickerPreferences[_preferenceKey];
    if (saved != null) {
      _query = '${saved['query'] ?? ''}';
      final difficulties = intListOf(saved['difficulties']).toSet();
      if (difficulties.isNotEmpty) _difficulties = difficulties;
      for (final (key, target) in [
        ('bands', _bands),
        ('categories', _categories),
        ('attributes', _attributes),
        ('missions', _missions),
      ]) {
        target.addAll((saved[key] as List? ?? []).cast<String>());
      }
      _containsMissions = saved['contains'] == true;
      _minLevel = saved['minLevel'] as double?;
      _maxLevel = saved['maxLevel'] as double?;
      _maxSeconds = saved['maxSeconds'] as double?;
    }
  }

  void _update(VoidCallback change) {
    setState(change);
    catalog.songPickerPreferences[_preferenceKey] = {
      'query': _query,
      'difficulties': _difficulties.toList(),
      'bands': _bands.toList(),
      'categories': _categories.toList(),
      'attributes': _attributes.toList(),
      'missions': _missions.toList(),
      'contains': _containsMissions,
      'minLevel': _minLevel,
      'maxLevel': _maxLevel,
      'maxSeconds': _maxSeconds,
    };
  }

  List<String> _artistNames(int id) {
    final row = catalog.song(id), source = row['artistName'] ?? row['bandName'];
    return source is List
        ? source.whereType<String>().where((v) => v.trim().isNotEmpty).toList()
        : source is String
        ? [source]
        : [];
  }

  List<String> _bandValues(int id) {
    final ids = catalog.songBands(id);
    if (ids.isNotEmpty) return ids.map((v) => '$v').toList();
    final artist = catalog.song(id)['artistId'];
    final credit = unorm.nfkc(
      '${artist == null || artist == 0 || artist == '' ? _artistNames(id).firstOrNull ?? '' : artist}',
    );
    return credit.isEmpty ? [] : ['credit:$credit'];
  }

  Doc _song(int id) {
    final row = catalog.displaySong(id),
        rules = widget.songRules,
        original = catalog.master.songs[id]?.gekisoMissions ?? [0, 0, 0];
    if (rules == null) return {...row, 'collectionBand': _bandValues(id)};
    final override = normalizeSongRules(rules);
    final missions = [
      for (var i = 0; i < 3; i++)
        override.missions[i] == 0
            ? original.elementAtOrNull(i) ?? 0
            : override.missions[i],
    ];
    return {
      ...row,
      'musicType': override.musicType == 0
          ? row['musicType']
          : override.musicType,
      'collectionBand': _bandValues(id),
      'gekisou': {...objectRow(row['gekisou']), 'missionTypes': missions},
    };
  }

  bool _legal(SongRef ref) =>
      (widget.allowed == null || widget.allowed!.contains(ref.songId)) &&
      (widget.allowedCharts == null || widget.allowedCharts!.contains(ref)) &&
      catalog.difficultyRow(ref.songId, ref.difficulty) != null;
  void _replace(List<SongRef> values) {
    setState(() {
      _undo = [..._songs];
      _songs = values.toSet().toList();
    });
  }

  void _clear() {
    _update(() {
      _query = _queryEngine.removeFacets(
        _query,
        _queryEngine.parse(_query).facets.keys.toSet(),
      );
      _difficulties = {3};
      _bands.clear();
      _categories.clear();
      _attributes.clear();
      _missions.clear();
      _containsMissions = false;
      _minLevel = _maxLevel = _maxSeconds = null;
    });
  }

  void _clearQuery(Set<String> keys) =>
      _query = _queryEngine.removeFacets(_query, keys);
  @override
  Widget build(BuildContext context) => PopScope<List<SongRef>>(
    canPop: _songs.length == widget.initial.length &&
        _songs.toSet().containsAll(widget.initial),
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      Navigator.of(context).pop(_songs.where(_legal).toSet().toList());
    },
    child: ListenableBuilder(
      listenable: catalog,
      builder: (context, _) => _content(context),
    ),
  );
  Widget _content(BuildContext context) {
    final t = catalog.t;
    String tb(String key, [Map<String, Object?> values = const {}]) =>
        t('tools.teamBuilder.$key', key, values);
    final plan = _queryEngine
        .parse(_query)
        .withMissionMode(_containsMissions ? 'contains' : 'only');
    bool selected(Set<String> wanted, Iterable<String> values) =>
        wanted.isEmpty || values.any(wanted.contains);
    final minFacet = plan.facets['minLevel']
            ?.map(double.parse)
            .reduce((a, b) => a > b ? a : b),
        maxFacet = plan.facets['maxLevel']
            ?.map(double.parse)
            .reduce((a, b) => a < b ? a : b);
    final minLevel = _minLevel == null
            ? minFacet
            : minFacet == null
            ? _minLevel
            : (_minLevel! > minFacet ? _minLevel : minFacet),
        maxLevel = _maxLevel == null
            ? maxFacet
            : maxFacet == null
            ? _maxLevel
            : (_maxLevel! < maxFacet ? _maxLevel : maxFacet);
    final all = [
      for (final key in objectRow(catalog.data['songs']).keys)
        if (int.tryParse(key) case final id?)
          for (final row in catalog.difficultyRows(id))
            SongRef(id, intOf(row['difficulty'])),
    ].where(_legal).toList();
    final sort =
        catalog.resourceSort[TeamResource.songs] ?? const TeamResourceSort();
    final needsMetrics =
        _maxSeconds != null || chartMetricSortFields.contains(sort.field);
    if (needsMetrics &&
        !catalog.metricsLoaded &&
        catalog.metricsError == null) {
      catalog.loadChartMetadata();
    }
    final incomplete = _maxSeconds != null && !catalog.metricsLoaded;
    final query = CatalogQueryEngine.normalize(plan.text);
    final visible = all.where((ref) {
      final row = _song(ref.songId),
          difficulty = catalog.difficultyRow(ref.songId, ref.difficulty)!;
      if (!_difficulties.contains(ref.difficulty) ||
          !selected(_bands, _bandValues(ref.songId)) ||
          !selected(
            _categories,
            intListOf(row['musicCategories']).map((v) => '$v'),
          ) ||
          !selected(_attributes, ['${row['musicType']}'])) {
        return false;
      }
      final level = numOf(
        difficulty['displayLevel'] ??
            difficulty['playLevel'] ??
            difficulty['sortLevel'],
        double.nan,
      );
      if ((minLevel != null || maxLevel != null) && !level.isFinite ||
          minLevel != null && level < minLevel ||
          maxLevel != null && level > maxLevel) {
        return false;
      }
      final time = catalog.chartMetadata(ref)?['time'];
      if (_maxSeconds != null &&
          (time is! num || !time.isFinite || time > _maxSeconds!)) {
        return false;
      }
      if (!_queryEngine.matches({
            ...row,
            'difficulty': [difficulty],
          }, plan) ||
          !_queryEngine.matches(
            row,
            CatalogQuery('', {
              'gekisouType': _missions.toList(),
              'gekisouMatch': plan.facets['gekisouMatch']!,
            }),
          )) {
        return false;
      }
      return query.isEmpty ||
          CatalogQueryEngine.normalize(
            '${catalog.songTitle(ref.songId)} ${catalog.songPresentation.artist(row)}',
          ).contains(query);
    }).toList();
    final valid = _songs.where(_legal).toList(),
        unavailable = _songs.where((s) => !_legal(s)).toList(),
        outside = valid.where((s) => !visible.contains(s)).toList();
    final shown = catalog.sortedCharts(
      _view == 'outside'
          ? outside
          : _view == 'unavailable'
          ? unavailable
          : visible,
      view: _song,
    );
    final shownLegal = shown.where(_legal).toList();
    final bandOptions = <String, String>{
      for (final id in catalog.bandIds) '$id': catalog.bandName(id),
    };
    for (final ref in all) {
      for (final value in _bandValues(ref.songId)) {
        bandOptions.putIfAbsent(
          value,
          () => catalog.songPresentation.artist(_song(ref.songId)),
        );
      }
    }
    final categories = {
      for (final ref in all)
        ...intListOf(_song(ref.songId)['musicCategories']).map((id) => '$id'),
    }.toList()..sort();
    String category(String value) {
      final key = [
        '',
        'original',
        'virtual',
        'jpop',
        'anime',
        'game',
      ].elementAtOrNull(int.parse(value));
      return key == null ? value : t('catalog.songs.types.$key');
    }

    final applied = <(String, VoidCallback)>[];
    if (minLevel != null || maxLevel != null) {
      applied.add((
        'Lv. ${minLevel ?? '—'}–${maxLevel ?? '—'}',
        () => _update(() {
          _minLevel = _maxLevel = null;
          _clearQuery({'minLevel', 'maxLevel'});
        }),
      ));
    }
    if (_maxSeconds != null) {
      applied.add((
        '≤ ${_maxSeconds}s',
        () => _update(() => _maxSeconds = null),
      ));
    }
    for (final (key, values, chosen, label)
        in <(String, Set<String>, Set<String>, String Function(String))>[
          (
            'collectionBand',
            {..._bands, ...?plan.facets['collectionBand']},
            _bands,
            (v) => bandOptions[v] ?? v,
          ),
          (
            'category',
            {..._categories, ...?plan.facets['category']},
            _categories,
            category,
          ),
          (
            'type',
            {..._attributes, ...?plan.facets['type']},
            _attributes,
            (v) => catalog.attributeName(int.parse(v)),
          ),
          (
            'character',
            {...?plan.facets['character']},
            <String>{},
            (v) => catalog.characterName(int.parse(v)),
          ),
          (
            'gekisouType',
            {..._missions, ...?plan.facets['gekisouType']},
            _missions,
            (v) =>
                {
                  'Combo': 'COMBO',
                  'Luck': 'LUCK',
                  'JustCount': 'JUST',
                  'Mix': t('catalog.songs.gekisou.mixed'),
                }[v] ??
                v,
          ),
        ]) {
      for (final value in values) {
        applied.add((
          label(value),
          () => _update(() {
            chosen.remove(value);
            _clearQuery({key});
          }),
        ));
      }
    }
    Widget facet(
      String label,
      Map<String, String> options,
      Set<String> chosen,
    ) => ToolField(
      label: label,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in options.entries)
            FilterChip(
              label: Text(entry.value),
              selected: chosen.contains(entry.key),
              onSelected: (_) => _update(() {
                if (!chosen.remove(entry.key)) chosen.add(entry.key);
              }),
            ),
        ],
      ),
    );
    Widget number(
      String key,
      String label,
      double? value,
      ValueChanged<double?> change,
    ) => _PickerNumberField(
      key: ValueKey(key),
      label: label,
      value: value,
      onChanged: (value) => _update(() => change(value)),
    );
    return SelectionPane(
      title: tb(widget.single ? 'chooseSong' : 'chooseSongs'),
      searchLabel: t('common.actions.search'),
      filterLabel: tb('filters'),
      query: _query,
      onQuery: (value) => _update(() => _query = value),
      activeFilters: applied.length,
      count: tb('chartCount', {'count': shown.length}),
      empty: incomplete ? '' : tb('noSongs'),
      itemCount: shown.length,
      minTileWidth: 150,
      aspectRatio: 1,
      quickFilters: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (i, name) in difficultyNames.indexed)
                FilterChip(
                  label: Text(name.toUpperCase()),
                  showCheckmark: false,
                  selected: _difficulties.contains(i),
                  onSelected: (_) => _update(() {
                    if (!_difficulties.contains(i)) {
                      _difficulties.add(i);
                    } else if (_difficulties.length > 1) {
                      _difficulties.remove(i);
                    }
                  }),
                ),
            ],
          ),
          SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (label, clear) in applied)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(label: Text(label), onDeleted: clear),
                    ),
                  if (applied.isNotEmpty)
                    TextButton(
                      onPressed: _clear,
                      child: Text(tb('clearFilters')),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      filters: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          facet(t('catalog.songs.fields.genre'), {
            for (final value in categories) value: category(value),
          }, _categories),
          const SizedBox(height: 16),
          facet(t('catalog.fields.band'), bandOptions, _bands),
          const SizedBox(height: 16),
          facet(t('catalog.fields.attribute'), {
            for (final id in [1, 2, 3, 4, 5, if (widget.songRules != null) 99])
              '$id': catalog.attributeName(id),
          }, _attributes),
          const SizedBox(height: 16),
          facet(t('catalog.analysis.fields.gekisouType'), {
            'Combo': 'COMBO',
            'Luck': 'LUCK',
            'JustCount': 'JUST',
            'Mix': t('catalog.songs.gekisou.mixed'),
          }, _missions),
          const SizedBox(height: 8),
          Segmented<bool>(
            value: _containsMissions,
            options: [
              Choice(false, t('catalog.songs.gekisou.only')),
              Choice(true, t('catalog.songs.gekisou.contains')),
            ],
            onSelected: (v) => _update(() => _containsMissions = v),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: number(
                  'min',
                  tb('sc.minLevel'),
                  _minLevel,
                  (v) => _minLevel = v,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: number(
                  'max',
                  tb('sc.maxLevel'),
                  _maxLevel,
                  (v) => _maxLevel = v,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          number(
            'time',
            tb('maxDuration'),
            _maxSeconds,
            (v) => _maxSeconds = v,
          ),
          TeamResourceSortControl(
            catalog: catalog,
            resource: TeamResource.songs,
          ),
          TextButton(onPressed: _clear, child: Text(tb('clearFilters'))),
        ],
      ),
      status: needsMetrics && !catalog.metricsLoaded
          ? SizedBox(
              height: 48,
              child: catalog.metricsError == null
                  ? const Center(child: LinearProgressIndicator())
                  : Row(
                      children: [
                        Expanded(child: Text(t('common.loading.failed'))),
                        IconButton(
                          tooltip: t('common.actions.retry'),
                          onPressed: catalog.loadChartMetadata,
                          icon: const Icon(Symbols.refresh_rounded),
                        ),
                      ],
                    ),
            )
          : null,
      item: (context, index) {
        final ref = shown[index], row = _song(ref.songId);
        return Tile(
          title: catalog.songTitle(ref.songId),
          subtitle: catalog.songPresentation.artist(row),
          adornments: catalog.songPresentation.avatars(row),
          marks: catalog.songPresentation.marks(
            row,
            difficulty: catalog.difficultyLabel(ref.songId, ref.difficulty),
            categoryAt: MarkAt.bottomEnd,
          ),
          images: [catalog.songJacket(ref.songId)],
          fit: BoxFit.cover,
          selected: _songs.contains(ref),
          action: Material(
            color: Theme.of(context).colorScheme.surfaceContainer
                .withValues(alpha: .85),
            borderRadius: BorderRadius.circular(12),
            child: Checkbox(
              value: _songs.contains(ref),
              onChanged: (_) => _replace(
                _songs.contains(ref)
                    ? _songs.where((s) => s != ref).toList()
                    : widget.single
                    ? [ref]
                    : [..._songs, ref],
              ),
            ),
          ),
          serverMark: catalog.mark('songs', ref.songId),
          onTap: () => _replace(
            _songs.contains(ref)
                ? _songs.where((s) => s != ref).toList()
                : widget.single
                ? [ref]
                : [..._songs, ref],
          ),
        );
      },
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Text(tb('selectedCharts', {'count': valid.length})),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: outside.isEmpty && _view != 'outside'
                        ? null
                        : () => setState(
                            () =>
                                _view = _view == 'outside' ? 'all' : 'outside',
                          ),
                    child: Text(tb('outsideCharts', {'count': outside.length})),
                  ),
                  TextButton(
                    onPressed: unavailable.isEmpty && _view != 'unavailable'
                        ? null
                        : () => setState(
                            () => _view = _view == 'unavailable'
                                ? 'all'
                                : 'unavailable',
                          ),
                    child: Text(
                      tb('unavailableCharts', {'count': unavailable.length}),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (!widget.single)
                    TextButton(
                      onPressed:
                          incomplete ||
                              shownLegal.isEmpty ||
                              shownLegal.every(_songs.contains)
                          ? null
                          : () => _replace([..._songs, ...shownLegal]),
                      child: Text(tb('selectAllCharts')),
                    ),
                  TextButton(
                    onPressed: _songs.any(shown.contains)
                        ? () => _replace(
                            _songs.where((s) => !shown.contains(s)).toList(),
                          )
                        : null,
                    child: Text(tb('deselectAllCharts')),
                  ),
                  if (!widget.single)
                    PopupMenuButton<String>(
                      tooltip: tb('selectionActions'),
                      icon: const Icon(Symbols.more_horiz_rounded),
                      onSelected: (v) =>
                          _replace(v == 'replace' ? visible : []),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'replace',
                          enabled: !incomplete,
                          child: Text(tb('replaceSelection')),
                        ),
                        PopupMenuItem(
                          value: 'clear',
                          enabled: _songs.isNotEmpty,
                          child: Text(tb('clearAllCharts')),
                        ),
                      ],
                    ),
                  TextButton(
                    onPressed: _undo == null
                        ? null
                        : () => setState(() {
                            _songs = _undo!;
                            _undo = null;
                          }),
                    child: Text(tb('undoSelection')),
                  ),
                ],
              ),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(valid.toSet().toList()),
            child: Text(tb('applyCharts', {'count': valid.length})),
          ),
        ],
      ),
    );
  }
}

class _PickerNumberField extends StatefulWidget {
  const _PickerNumberField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final double? value;
  final ValueChanged<double?> onChanged;
  @override
  State<_PickerNumberField> createState() => _PickerNumberFieldState();
}

class _PickerNumberFieldState extends State<_PickerNumberField> {
  late final _controller = TextEditingController(
    text: widget.value?.toString() ?? '',
  );
  final _focus = FocusNode();
  void _sync() {
    final value = widget.value?.toString() ?? '';
    if (!_focus.hasFocus && _controller.text != value) _controller.text = value;
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_sync);
  }

  @override
  void didUpdateWidget(_PickerNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    focusNode: _focus,
    decoration: InputDecoration(labelText: widget.label),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    onChanged: (raw) => widget.onChanged(double.tryParse(raw)),
  );
}
