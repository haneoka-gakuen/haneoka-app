import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../chart/runtime_chart.dart';
import '../core/app_state.dart';
import '../core/i18n.dart';
import '../core/net.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';

/// Label-over-figure cells (`.song-data-grid`): at least [minWidth] wide.
class DataGrid extends StatelessWidget {
  const DataGrid({
    super.key,
    required this.cells,
    this.minWidth = 120,
    this.large = false,
  });
  final List<(String label, String value)> cells;
  final double minWidth;

  /// `.song-meta-strip`: title-large tabular figures.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth + 16) / (minWidth + 16))
            .floor()
            .clamp(1, cells.isEmpty ? 1 : cells.length);
        final width = (constraints.maxWidth - 16 * (columns - 1)) / columns;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            spacing: 16,
            runSpacing: 20,
            children: [
              for (final (label, value) in cells)
                SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        value,
                        style:
                            (large
                                    ? theme.textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w500,
                                      )
                                    : theme.textTheme.titleMedium)
                                ?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The figures of one chart (`renderSongSummary` metrics): level, duration,
/// score factor, efficiency, BPM, notes, density and skill coverage.
List<(String, String)> songMetrics(
  SiteText t, {
  required Map meta,
  required Map? chart,
  String? estimate,
}) {
  String percentage(Object? value) => value is num && value.isFinite
      ? '${NumberFormat('#,##0', t.locale).format(value * 100)}%'
      : '—';
  String decimal(Object? value, [int digits = 0]) =>
      value is num && value.isFinite
      ? NumberFormat(
          digits == 0 ? '#,##0' : '#,##0.${'0' * digits}',
          t.locale,
        ).format(value)
      : '—';
  String duration(Object? value) {
    final seconds = value is num ? value.round() : 0;
    return seconds <= 0
        ? '—'
        : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String plain(num value) =>
      value == value.truncate() ? '${value.truncate()}' : '$value';
  final minimum = (meta['minBpm'] ?? meta['firstBpm'] ?? 0) as num;
  final maximum = (meta['maxBpm'] ?? meta['firstBpm'] ?? 0) as num;
  final bpm = minimum == 0 && maximum == 0
      ? '—'
      : minimum == maximum
      ? plain(minimum)
      : '${plain(minimum)}–${plain(maximum)}';
  final level =
      meta['displayLevel'] ??
      chart?['displayLevel'] ??
      chart?['playLevel'] ??
      meta['r'];
  return [
    (
      t.label('metaOfficialLevel', 'Official level'),
      level is num ? plain(level) : '—',
    ),
    if (estimate != null)
      (
        t.label('difficultyEstimateBeta', 'Estimated difficulty / Beta'),
        estimate,
      ),
    (t.label('metaTime', 'Song Duration'), duration(meta['time'])),
    (t.label('metaScore', 'Factor'), percentage(meta['score'])),
    (
      t.label('metaEff', 'Score Efficiency per Minute'),
      percentage(meta['eff']),
    ),
    (t.label('metaBpm', 'Beats per Minute'), bpm),
    (t.label('metaN', 'Note Count'), decimal(meta['n'] ?? chart?['noteCount'])),
    (t.label('metaNps', 'Notes per Second'), decimal(meta['nps'], 1)),
    (t.label('metaSr', 'Skill Coverage'), percentage(meta['sr'])),
  ];
}

const _missions = {
  'Combo': ('gekisouMissionCombo', 'COMBO', 'combo'),
  'Luck': ('gekisouMissionLuck', 'LUCK', 'luck'),
  'JustCount': ('gekisouMissionJustCount', 'JUST', 'just'),
};

/// A Gekisou mission's label key, fallback and icon name (`gekisouMission`).
(String, String, String)? gekisouMission(Object? value) {
  final numeric = value is num ? value : num.tryParse('${value ?? ''}'.trim());
  final name = numeric != null && numeric == numeric.truncate()
      ? const [
          '',
          'Combo',
          'Luck',
          'JustCount',
        ].elementAtOrNull(numeric.toInt())
      : '${value ?? ''}';
  return _missions[name];
}

/// The song's Gekisou stages in order (`.song-gekisou-stages`): each stage's
/// mission with its emblem in the primary colour.
class GekisouStages extends StatelessWidget {
  const GekisouStages({super.key, required this.song, required this.metrics});
  final Map song;

  /// The chart's Gekisou metrics, which may carry their own mission pattern.
  final Map metrics;

  /// The stages' mission types, empty when the song has none.
  static List<Object?> types(Map song, Map metrics) {
    final own = (song['gekisou'] as Map?) ?? const {};
    List? list(String key) => switch (metrics[key] ?? own[key]) {
      final List value => value,
      _ => null,
    };
    final pattern = list('missionPattern') ?? const [];
    final types = list('missionTypes') ?? pattern;
    final segments = metrics['segments'] is List
        ? (metrics['segments'] as List).length
        : 0;
    final count = [
      types.length,
      pattern.length,
      segments,
    ].reduce((a, b) => a > b ? a : b);
    return [
      for (var i = 0; i < count; i++)
        types.elementAtOrNull(i) ?? pattern.elementAtOrNull(i),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icons =
        (metrics['icons'] ?? (song['gekisou'] as Map?)?['icons']) as Map? ??
        const {};
    final compact = MediaQuery.sizeOf(context).width < 600;
    final cells = [
      for (final (index, type) in types(song, metrics).indexed)
        if (gekisouMission(type) case (final key, final fallback, final icon))
          Row(
            children: [
              if (icons[icon] case final String image)
                Padding(
                  padding: EdgeInsets.only(right: compact ? 6 : 12),
                  child: Image.network(
                    state.api.asset(image).toString(),
                    width: compact ? 24 : 32,
                    height: compact ? 24 : 32,
                    color: scheme.primary,
                    errorBuilder: (_, _, _) =>
                        SizedBox.square(dimension: compact ? 24 : 32),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${t.label('gekisouSegment', 'GEKISO stage')} ${index + 1}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.label(key, fallback),
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
    ];
    if (cells.isEmpty) return const SizedBox.shrink();
    return DetailSection(
      icon: Symbols.bolt_rounded,
      title: t.label('gekisouStages', 'GEKISO stages'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, cell) in cells.indexed) ...[
            if (index > 0) SizedBox(width: compact ? 8 : 16),
            Expanded(child: cell),
          ],
        ],
      ),
    );
  }
}

/// One skill window on a [SkillTimeline].
class SkillWindow {
  const SkillWindow(this.startMs, this.endMs, this.label, {this.value});
  final int startMs;
  final int endMs;
  final String label;
  final String? value;
}

String _clock(int ms) {
  final seconds = ms < 0 ? 0 : ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// A live's skill windows on one lane over its note density and fever
/// sections (`skillTimeline`). Windows are numbered in firing order; a window
/// that overlaps the previous one drops to a second lane.
class SkillTimeline extends StatelessWidget {
  const SkillTimeline({
    super.key,
    required this.durationMs,
    required this.density,
    required this.fever,
    required this.windows,
    this.bucketMs = 500,
    this.feverLabel,
  });
  final int durationMs;
  final List<int> density;
  final int bucketMs;
  final List<(int, int)> fever;
  final List<SkillWindow> windows;
  final String Function(int index)? feverLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final duration = durationMs < 1 ? 1 : durationMs;
    final sorted = [...windows]..sort((a, b) => a.startMs - b.startMs);
    final lanes = <int>[];
    final placed = [
      for (final window in sorted)
        () {
          var lane = lanes.indexWhere((end) => end <= window.startMs);
          if (lane < 0) {
            lane = lanes.length;
            lanes.add(window.endMs);
          } else {
            lanes[lane] = window.endMs;
          }
          return (window, lane);
        }(),
    ];
    final laneCount = lanes.isEmpty ? 1 : lanes.length;
    const mark = TextStyle(
      color: Colors.white,
      fontSize: 12,
      height: 1,
      fontWeight: FontWeight.w700,
      shadows: [Shadow(color: Color(0x99000000), blurRadius: 2)],
    );
    Widget index(int value) => Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(Corner.extraSmall),
      ),
      child: Text('$value', style: mark),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            double at(int ms) => (ms / duration).clamp(0.0, 1.0) * width;
            return ClipRRect(
              borderRadius: BorderRadius.circular(Corner.medium),
              child: Container(
                height: 56 + laneCount * 26 + 4,
                color: scheme.surfaceContainerLow,
                child: Stack(
                  children: [
                    for (final (i, (start, end)) in fever.indexed)
                      Positioned(
                        left: at(start),
                        width: at(end) - at(start),
                        top: 0,
                        bottom: 0,
                        child: Container(
                          color: scheme.tertiary.withValues(alpha: 0.14),
                          padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
                          alignment: Alignment.topLeft,
                          child: Text(
                            feverLabel?.call(i) ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.tertiary,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 12,
                      height: 40,
                      child: CustomPaint(
                        painter: _Density(
                          density,
                          bucketMs / duration,
                          scheme.onSurfaceVariant.withValues(alpha: 0.26),
                        ),
                      ),
                    ),
                    for (final (i, (window, lane)) in placed.indexed)
                      Positioned(
                        left: at(window.startMs),
                        top: 56.0 + lane * 26,
                        height: 22,
                        width: (at(window.endMs) - at(window.startMs)).clamp(
                          14.0,
                          double.infinity,
                        ),
                        child: Tooltip(
                          message:
                              '${i + 1} / ${(window.startMs / 1000).toStringAsFixed(1)}s–${(window.endMs / 1000).toStringAsFixed(1)}s',
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(
                                Corner.extraSmall,
                              ),
                              border: Border.all(
                                color: scheme.surfaceContainerLow,
                              ),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: mark,
                              overflow: TextOverflow.clip,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        SizedBox(
          height: 16,
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              clipBehavior: Clip.none,
              children: [
                for (var ms = 0; ms < duration; ms += 30000)
                  Positioned(
                    left: ms / duration * constraints.maxWidth,
                    child: FractionalTranslation(
                      translation: Offset(ms == 0 ? 0 : -0.5, 0),
                      child: Text(
                        _clock(ms),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 16 / 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = ((constraints.maxWidth + 12) / 232).floor().clamp(
              1,
              8,
            );
            final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final (i, window) in sorted.indexed)
                  SizedBox(
                    width: width,
                    height: 36,
                    child: Row(
                      children: [
                        index(i + 1),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            window.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(window.startMs / 1000).toStringAsFixed(1)}s',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (window.value != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            window.value!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Density extends CustomPainter {
  _Density(this.density, this.step, this.color);
  final List<int> density;

  /// One bucket as a fraction of the width.
  final double step;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (density.isEmpty) return;
    final peak = density.fold(1, (max, value) => value > max ? value : max);
    final path = Path()..moveTo(0, size.height);
    for (final (index, count) in density.indexed) {
      path.lineTo(
        index * step * size.width,
        size.height - count / peak * size.height,
      );
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Density old) =>
      old.density != density || old.color != color || old.step != step;
}

/// Every live skill lasts five seconds before snap extensions
/// (MasterLiveSkillEffect).
const _skillMs = 5000;

final _charts = <String, Future<RuntimeChart?>>{};

/// A chart file, converted off the UI thread and kept for the session.
Future<RuntimeChart?> loadChart(String url) => _charts[url] ??= () async {
  try {
    final response = await netClient.get(Uri.parse(url));
    if (response.statusCode != 200) return null;
    final bytes = response.bodyBytes;
    return await Isolate.run(() => RuntimeChart.fromBytes(bytes));
  } catch (_) {
    _charts.remove(url);
    return null;
  }
}();

/// The selected chart's skill events and Gekisou sections, with the notes
/// each skill window covers (`song-skill-points`).
class SongSkillPoints extends StatelessWidget {
  const SongSkillPoints({super.key, required this.source});

  /// The chart file's address.
  final String source;

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final scheme = Theme.of(context).colorScheme;
    final title = t('catalog.songs.skillPoints', 'Skill points');
    return FutureBuilder(
      future: loadChart(source),
      builder: (context, snapshot) {
        final chart = snapshot.data;
        if (snapshot.connectionState == ConnectionState.done &&
            (chart == null || chart.skillTimesMs.isEmpty)) {
          return const SizedBox.shrink();
        }
        if (chart == null) {
          return DetailSection(
            icon: Symbols.bolt_rounded,
            title: title,
            child: Container(
              height: 86,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Corner.medium),
              ),
            ),
          );
        }
        final notes = [
          for (final note in chart.notes)
            if (note.judged) note.timeMs,
        ];
        final last = notes.fold(chart.durationMs, (a, b) => a > b ? a : b);
        final end = last + 1000;
        final density = List<int>.filled((end / 500).ceil(), 0);
        for (final time in notes) {
          density[time ~/ 500]++;
        }
        final covered = [
          for (final start in chart.skillTimesMs)
            notes.where((t) => t >= start && t < start + _skillMs).length,
        ];
        final ranked = [...covered]..sort((a, b) => b - a);
        final share = NumberFormat.percentPattern(t.locale)
          ..maximumFractionDigits = 1;
        final notesLabel = t('catalog.analysis.fields.n', 'Notes');
        final stage = t(
          'catalog.analysis.fields.gekisouSegment',
          'GEKISO stage',
        );
        return DetailSection(
          icon: Symbols.bolt_rounded,
          title: title,
          child: SkillTimeline(
            durationMs: end,
            density: density,
            fever: chart.feverMs,
            feverLabel: (index) => '$stage ${index + 1}',
            windows: [
              for (final (index, start) in chart.skillTimesMs.indexed)
                SkillWindow(
                  start,
                  start + _skillMs,
                  '$notesLabel ${covered[index]}',
                  value:
                      '${share.format(covered[index] / (notes.isEmpty ? 1 : notes.length))} / #${ranked.indexOf(covered[index]) + 1}',
                ),
            ],
          ),
        );
      },
    );
  }
}
