/// The website's chart analysis (`src/lit/song-chart-analysis.ts`): note
/// composition, Gekisou sections and a score scenario with section
/// placements, Just and Great share, skills, slot weights and rank
/// thresholds, all from the loaded chart and the release's chart rates.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../chart/runtime_chart.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import 'chart_rates.dart';
import 'song_summary.dart';

const _rankNames = ['', 'E', 'D', 'C', 'B', 'A', 'S', 'SS'];
const _missionKeys = {
  1: 'gekisouMissionCombo',
  2: 'gekisouMissionLuck',
  3: 'gekisouMissionJustCount',
  4: 'gekisouMissionAll',
};
// The time between lives that per-minute values count.
const _extraSeconds = 30;

enum _Kind { tap, flick, long, trace, node }

/// Operate types by the game's note families; 120 is a long note's combo node.
_Kind _kindOf(int op) => op >= 120
    ? _Kind.node
    : op >= 60 && op < 80
    ? _Kind.trace
    : op >= 40 && op < 60
    ? _Kind.flick
    : op >= 20 && op < 40
    ? _Kind.long
    : _Kind.tap;

/// Loads the chart and its rates, then shows the analysis.
class SongChartAnalysisSection extends StatefulWidget {
  const SongChartAnalysisSection({
    super.key,
    required this.api,
    required this.source,
    required this.musicId,
    required this.difficulty,
  });
  final HaneokaApi api;
  final String source;
  final int musicId, difficulty;

  @override
  State<SongChartAnalysisSection> createState() =>
      _SongChartAnalysisSectionState();
}

class _SongChartAnalysisSectionState extends State<SongChartAnalysisSection> {
  Future<ChartRateTable?>? _table;

  @override
  Widget build(BuildContext context) {
    _table ??= ChartRateTable.load(widget.api)
        .then<ChartRateTable?>((v) => v, onError: (_) => null);
    return FutureBuilder(
      future: Future.wait<Object?>([loadChart(widget.source), _table!]),
      builder: (context, snapshot) {
        final chart = snapshot.data?[0] as RuntimeChart?;
        final table = snapshot.data?[1] as ChartRateTable?;
        if (chart == null) return const SizedBox.shrink();
        return SongChartAnalysis(
          chart: chart,
          rates: table?.charts['${widget.musicId}:${widget.difficulty}'],
          greatFactor: table?.greatFactor ?? .8,
          api: widget.api,
        );
      },
    );
  }
}

class SongChartAnalysis extends StatefulWidget {
  const SongChartAnalysis({
    super.key,
    required this.chart,
    required this.rates,
    required this.greatFactor,
    required this.api,
  });
  final RuntimeChart chart;
  final ChartRates? rates;
  final double greatFactor;
  final HaneokaApi api;

  @override
  State<SongChartAnalysis> createState() => _SongChartAnalysisState();
}

class _SongChartAnalysisState extends State<SongChartAnalysis> {
  var _gekisou = true;
  var _ranks = [1, 1, 1];
  var _just = 1.0, _great = 0.0;
  var _skills = [100.0, 100.0, 100.0, 100.0, 100.0];
  var _room = 5;
  var _power = 300000;

  String _text(String key, String fallback) =>
      AppScope.of(context).text('catalog.songs.analysis.$key', fallback);

  @override
  Widget build(BuildContext context) {
    final notes = [
      for (final note in widget.chart.notes)
        if (note.judged) note,
    ];
    if (notes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _composition(notes),
        if (widget.chart.feverMs.isNotEmpty) _sections(notes),
        if (widget.rates case final rates?) _scenario(rates),
      ],
    );
  }

  Widget _composition(List<ChartNote> notes) {
    final scheme = Theme.of(context).colorScheme;
    final colours = {
      _Kind.tap: scheme.primary,
      _Kind.flick: scheme.tertiary,
      _Kind.long: scheme.secondary,
      _Kind.trace: scheme.error,
      _Kind.node: scheme.outlineVariant,
    };
    final counts = <_Kind, int>{};
    for (final note in notes) {
      counts.update(_kindOf(note.operateType), (v) => v + 1, ifAbsent: () => 1);
    }
    final number = NumberFormat.decimalPattern(
      AppScope.of(context).text.locale,
    );
    return DetailSection(
      icon: Symbols.info_rounded,
      title: _text('composition', 'Note composition'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: Row(
                children: [
                  for (final kind in _Kind.values)
                    if ((counts[kind] ?? 0) > 0)
                      Expanded(
                        flex: counts[kind]!,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: ColoredBox(color: colours[kind]!),
                        ),
                      ),
                ],
              ),
            ),
          ),
          DataGrid(
            cells: [
              for (final kind in _Kind.values)
                if ((counts[kind] ?? 0) > 0)
                  (
                    _text(kind.name, kind.name),
                    '${number.format(counts[kind])} · ${(counts[kind]! / notes.length * 100).round()}%',
                  ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sections(List<ChartNote> notes) {
    final t = AppScope.of(context).text;
    final number = NumberFormat.decimalPattern(t.locale);
    final gekisou = widget.rates?.gekisou;
    return DetailSection(
      icon: Symbols.trending_up_rounded,
      title: _text('sections', 'Gekisou sections'),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 24,
          horizontalMargin: 12,
          columns: [
            DataColumn(label: Text(_text('section', 'Section'))),
            DataColumn(label: Text(_text('metric', 'Ranked by'))),
            DataColumn(
              label: Text(_text('sectionNotes', 'Notes')),
              numeric: true,
            ),
            if (gekisou != null)
              const DataColumn(label: Text('Just'), numeric: true),
            DataColumn(
              label: Text(_text('startCombo', 'Starting combo')),
              numeric: true,
            ),
            DataColumn(label: Text(_text('seconds', 'Length')), numeric: true),
          ],
          rows: [
            for (final (index, (start, end)) in widget.chart.feverMs.indexed)
              DataRow(
                cells: [
                  DataCell(Text('${index + 1}')),
                  DataCell(
                    Text(
                      gekisou == null || index >= gekisou.missions.length
                          ? '—'
                          : t(
                              'catalog.songs.gekisou.${_missionKeys[gekisou.missions[index]] ?? 'gekisouMissionNone'}',
                            ),
                    ),
                  ),
                  DataCell(
                    Text(
                      number.format(
                        gekisou != null && index < gekisou.notes.length
                            ? gekisou.notes[index]
                            : notes
                                  .where(
                                    (n) => n.timeMs >= start && n.timeMs < end,
                                  )
                                  .length,
                      ),
                    ),
                  ),
                  if (gekisou != null)
                    DataCell(
                      Text(
                        number.format(
                          index < gekisou.just.length ? gekisou.just[index] : 0,
                        ),
                      ),
                    ),
                  DataCell(
                    Text(
                      number.format(
                        notes.where((n) => n.timeMs < start).length,
                      ),
                    ),
                  ),
                  DataCell(
                    Text('${((end - start) / 1000).toStringAsFixed(1)}s'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _segmented(
    List<int> values,
    int current,
    ValueChanged<int> pick, {
    String Function(int)? label,
  }) => SegmentedButton<int>(
    showSelectedIcon: false,
    segments: [
      for (final value in values)
        ButtonSegment(
          value: value,
          label: Text(label?.call(value) ?? '$value'),
        ),
    ],
    selected: {current},
    onSelectionChanged: (selection) => pick(selection.first),
  );

  Widget _slider(String label, double value, ValueChanged<double> pick) => Row(
    children: [
      SizedBox(width: 96, child: Text(label)),
      Expanded(
        child: Slider(
          value: value,
          divisions: 100,
          onChanged: (v) => setState(() => pick(v)),
        ),
      ),
      SizedBox(
        width: 48,
        child: Text('${(value * 100).round()}%', textAlign: TextAlign.end),
      ),
    ],
  );

  Widget _scenario(ChartRates rates) {
    final theme = Theme.of(context);
    final t = AppScope.of(context).text;
    final number = NumberFormat.decimalPattern(t.locale);
    String fixed(double v) => NumberFormat('#,##0.000', t.locale).format(v);
    final general = 1 - _great * (1 - widget.greatFactor);
    final gekisou = _gekisou ? rates.gekisou : null;
    final windows = rates.windows.isEmpty ? <double>[] : rates.windows[0];
    var free = rates.base * general;
    for (final (index, value) in windows.indexed) {
      free += value * general * (_skills[index] / 100);
    }
    final perPower = gekisou?.rate(_ranks, _just, general, _skills) ?? free;
    final base =
        gekisou?.rate(_ranks, _just, general, const [0, 0, 0, 0, 0]) ??
        rates.base * general;
    final weights = gekisou != null
        ? [
            for (var event = 0; event < 5; event++)
              gekisou.rate(_ranks, _just, general, [
                    for (var i = 0; i < 5; i++) i == event ? 100 : 0,
                  ]) -
                  base,
          ]
        : [for (final value in windows) value * general];
    final total = weights.fold(0.0, (a, b) => a + b);
    final minutes = (widget.chart.durationMs / 1000 + _extraSeconds) / 60;
    final thresholds = [
      for (final row in rates.ranks.reversed)
        if (row.rank >= 3 && row.rank <= 7)
          (
            rank: row.rank,
            score: gekisou != null
                ? (roomRequiredScore(row.battleRequired, _room) / _room).ceil()
                : row.required,
          ),
    ];
    return DetailSection(
      icon: Symbols.emoji_events_rounded,
      title: _text('scenario', 'Score scenario'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rates.gekisou != null)
            Align(
              alignment: Alignment.centerLeft,
              child: _segmented(
                [1, 0],
                _gekisou ? 1 : 0,
                (v) => setState(() => _gekisou = v == 1),
                label: (v) => v == 1
                    ? _text('gekisouLive', 'Gekisou Live')
                    : _text('freeLive', 'Free Live'),
              ),
            ),
          if (gekisou != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                for (var i = 0; i < 3; i++)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_text('section', 'Section')} ${i + 1} · ${_text('placement', 'Place')}',
                        style: theme.textTheme.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      _segmented(
                        [1, 2, 3, 4, 5],
                        _ranks[i],
                        (v) => setState(() => _ranks = [..._ranks]..[i] = v),
                      ),
                    ],
                  ),
              ],
            ),
            _slider(_text('justShare', 'Just share'), _just, (v) => _just = v),
          ],
          _slider(
            _text('greatShare', 'Great share'),
            _great,
            (v) => _great = v,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < 5; i++)
                SizedBox(
                  width: 96,
                  child: TextFormField(
                    initialValue: '${_skills[i].round()}',
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '${_text('skill', 'Skill')} ${i + 1}',
                      suffixText: '%',
                    ),
                    onChanged: (raw) => setState(
                      () =>
                          _skills = [..._skills]
                            ..[i] = (double.tryParse(raw) ?? 0).clamp(0, 400),
                    ),
                  ),
                ),
            ],
          ),
          DataGrid(
            large: true,
            cells: [
              (_text('perPower', 'Score / power'), fixed(perPower)),
              if (gekisou != null)
                (_text('recordPerPower', 'Song record / power'), fixed(free)),
              (
                _text('perMinute', 'Score / power / minute'),
                fixed(perPower / minutes),
              ),
              (_text('base', 'No skills'), fixed(base)),
              (_text('skip', 'Skip'), fixed(rates.skip)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(
              _text('slotWeights', 'Skill slot weights'),
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final (index, value) in weights.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(width: 32, child: Text('#${index + 1}')),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: total <= 0 ? 0 : (value / total).clamp(0, 1),
                        minHeight: 8,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(fixed(value), textAlign: TextAlign.end),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${total <= 0 ? 0 : (value / total * 100).round()}%',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(
              _text('thresholds', 'Rank thresholds'),
              style: theme.textTheme.titleSmall,
            ),
          ),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              if (gekisou != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _text('roomSize', 'Room size'),
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    _segmented(
                      [1, 2, 3, 4, 5],
                      _room,
                      (v) => setState(() => _room = v),
                    ),
                  ],
                ),
              SizedBox(
                width: 200,
                child: TextFormField(
                  initialValue: '$_power',
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _text('power', 'Power'),
                  ),
                  onChanged: (raw) =>
                      setState(() => _power = int.tryParse(raw) ?? 0),
                ),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
              horizontalMargin: 12,
              columns: [
                DataColumn(label: Text(_text('rank', 'Rank'))),
                DataColumn(
                  label: Text(
                    gekisou != null
                        ? _text('scorePerPlayer', 'Score per player')
                        : _text('score', 'Score'),
                  ),
                  numeric: true,
                ),
                DataColumn(
                  label: Text(_text('powerNeeded', 'Power needed')),
                  numeric: true,
                ),
                DataColumn(
                  label: Text(_text('reached', 'Reached')),
                  numeric: true,
                ),
              ],
              rows: [
                for (final row in thresholds)
                  DataRow(
                    cells: [
                      DataCell(
                        Semantics(
                          label: _rankNames[row.rank],
                          image: true,
                          child: SizedBox.square(
                            dimension: 28,
                            child: AppImage(
                              candidates: [
                                widget.api
                                    .asset(
                                      '/assets/${widget.api.server}/Assets/AddressableResources/UI/Texture/BandRank/ImgScorerank_${_rankNames[row.rank]}.png',
                                    )
                                    .toString(),
                              ],
                              localized: false,
                            ),
                          ),
                        ),
                      ),
                      DataCell(Text(number.format(row.score))),
                      DataCell(
                        Text(
                          number.format(
                            ((row.score + rates.notes) / perPower).ceil(),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          '${((_power * perPower - rates.notes) / (row.score < 1 ? 1 : row.score) * 100).floor().clamp(0, 100)}%',
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
