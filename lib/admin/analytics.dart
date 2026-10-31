import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:material_symbols_icons/symbols.dart';

import '../chart_editor/project.dart';
import '../core/app_state.dart';
import '../ui/detail.dart';
import 'controller.dart';

class AdminAnalytics extends StatefulWidget {
  const AdminAnalytics({super.key, required this.controller});
  final AdminController controller;
  @override
  State<AdminAnalytics> createState() => _AdminAnalyticsState();
}

class _AdminAnalyticsState extends State<AdminAnalytics> {
  int _days = 30;
  bool _visitWindow = false;
  String _metric = 'registrations';
  Future<ChartMap>? _series, _geo, _world;
  String t(String key) => AppScope.of(context).text('admin.page.$key');
  String count(Object? value) =>
      NumberFormat.decimalPattern(AppScope.of(context).text.locale)
          .format(value ?? 0);
  String state(String key) {
    final value = t('values.$key');
    return value.isEmpty ? t('roles.$key') : value;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_series == null) {
      _load();
      _world = AppScope.of(context).api
          .json('/admin/world-110m.geo.json')
          .then(chartMap);
    }
  }

  void _load() {
    final now = DateTime.now().toUtc();
    final end = DateTime.utc(now.year, now.month, now.day + 1);
    final start = end.subtract(Duration(days: _days));
    _series = widget.controller.request(
      Uri(
        path: '/api/v1/admin/statistics/series',
        queryParameters: {
          'from': start.toIso8601String().substring(0, 10),
          'to': end.toIso8601String().substring(0, 10),
          'bucket': 'day',
        },
      ).toString(),
    );
    _geo = widget.controller.request(
      Uri(
        path: '/api/v1/admin/statistics/geo',
        queryParameters: _visitWindow
            ? {
                'visitedFrom': '${start.millisecondsSinceEpoch}',
                'visitedTo': '${end.millisecondsSinceEpoch}',
              }
            : null,
      ).toString(),
    );
  }

  void _users(String url) => widget.controller.select(
    'users',
    filters: Uri.parse(url).queryParameters,
  );
  void _partition(String kind, String value) {
    if (kind == 'users') {
      if (const {'active', 'suspended', 'deleted'}.contains(value)) {
        widget.controller.select('users', filters: {'status': value});
      }
    } else {
      widget.controller.select('posts', filters: {kind: value});
    }
  }

  Widget _pending(AsyncSnapshot<ChartMap> snapshot) => SizedBox(
    height: 220,
    child: Center(
      child: snapshot.hasError
          ? TextButton.icon(
              icon: const Icon(Symbols.refresh_rounded),
              label: Text(t('loadFailed')),
              onPressed: () => setState(_load),
            )
          : const CircularProgressIndicator(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final statistics = chartMap(
      widget.controller.document['statistics'] ?? const {},
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSection(
          icon: Symbols.monitoring_rounded,
          title: t('analytics.title'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final days in [7, 30, 90, 365])
                    ChoiceChip(
                      label: Text(
                        t('analytics.days').replaceAll('{count}', count(days)),
                      ),
                      selected: _days == days,
                      onSelected: (_) => setState(() {
                        _days = days;
                        _load();
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _metric,
                isExpanded: true,
                decoration: InputDecoration(labelText: t('analytics.metric')),
                items: [
                  for (final metric in [
                    'registrations',
                    'posts',
                    'comments',
                    'attachments',
                    'moderationJobsCreated',
                    'moderationDecisions',
                    'moderationCasesLatestCompleted',
                  ])
                    DropdownMenuItem(
                      value: metric,
                      child: Text(
                        t('analytics.$metric'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _metric = value!),
              ),
              FutureBuilder<ChartMap>(
                future: _series,
                builder: (context, snapshot) {
                  if (!snapshot.hasData || snapshot.hasError) {
                    return _pending(snapshot);
                  }
                  final series = chartRows(snapshot.data!['series'])
                      .where((row) => row['metric'] == _metric)
                      .firstOrNull;
                  final points = chartRows(series?['points'] ?? const []);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Trend(points: points, label: t('analytics.$_metric')),
                      DetailFold(
                        title: t('analytics.trendData'),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: SingleChildScrollView(
                            child: DataTable(
                              columns: [
                                DataColumn(label: Text(t('analytics.date'))),
                                DataColumn(
                                  label: Text(t('analytics.count')),
                                  numeric: true,
                                ),
                              ],
                              rows: [
                                for (final point in points)
                                  DataRow(
                                    cells: [
                                      DataCell(Text('${point['bucket']}')),
                                      DataCell(Text(count(point['count']))),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        for (final (field, label, kind) in [
          ('profiles', 'usersPartition', 'users'),
          ('postStatus', 'contentPartition', 'status'),
          ('postModeration', 'moderationPartition', 'moderationStatus'),
        ])
          DetailFold(
            title: t('analytics.$label'),
            child: _Partition(
              values: chartMap(statistics[field] ?? const {}),
              label: state,
              count: count,
              onSelected: (value) => _partition(kind, value),
            ),
          ),
        const SizedBox(height: 24),
        DetailSection(
          icon: Symbols.public_rounded,
          title: t('analytics.map'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(t('analytics.limitVisits')),
                value: _visitWindow,
                onChanged: (value) => setState(() {
                  _visitWindow = value;
                  _load();
                }),
              ),
              FutureBuilder<ChartMap>(
                future: _geo,
                builder: (context, snapshot) {
                  if (!snapshot.hasData || snapshot.hasError) {
                    return _pending(snapshot);
                  }
                  final geo = snapshot.data!, totals = chartMap(geo['totals']);
                  final countries = chartRows(geo['countries']);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SpecList(
                        facts: [
                          Fact(
                            t('analytics.usersCount'),
                            count(totals['total']),
                          ),
                          Fact(
                            t('analytics.unknownCountry'),
                            count(totals['unknownCountry']),
                          ),
                          Fact(
                            t('analytics.unknownCoordinates'),
                            count(totals['unknownCoordinates']),
                          ),
                          Fact(
                            t('analytics.noVisit'),
                            count(totals['noVisit']),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      FutureBuilder<ChartMap>(
                        future: _world,
                        builder: (context, world) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (world.hasData)
                              _WorldMap(
                                geometry: world.data!,
                                geo: geo,
                                onUsers: _users,
                              )
                            else
                              AspectRatio(
                                aspectRatio: 2,
                                child: Center(
                                  child: world.hasError
                                      ? TextButton(
                                          onPressed: () => setState(
                                            () => _world = AppScope.of(context)
                                                .api
                                                .json(
                                                  '/admin/world-110m.geo.json',
                                                )
                                                .then(chartMap),
                                          ),
                                          child: Text(
                                            t('analytics.mapUnavailable'),
                                          ),
                                        )
                                      : const CircularProgressIndicator(),
                                ),
                              ),
                            DetailFold(
                              title: t('analytics.countryData'),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 400,
                                ),
                                child: SingleChildScrollView(
                                  child: Column(
                                    children: [
                                      for (final country in countries)
                                        ListTile(
                                          title: Text(
                                            country['countryCode'] == null
                                                ? t('analytics.unknownCountry')
                                                : _country(
                                                    world.data,
                                                    '${country['countryCode']}',
                                                  ),
                                          ),
                                          trailing: Text(
                                            count(country['count']),
                                          ),
                                          onTap: () =>
                                              _users('${country['usersUrl']}'),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _country(ChartMap? world, String code) {
    if (world == null) return code;
    final feature = chartRows(world['features'])
        .where((row) => chartMap(row['properties'])['iso2'] == code)
        .firstOrNull;
    return feature == null
        ? code
        : '${chartMap(feature['properties'])['label']}';
  }
}

class _Trend extends StatefulWidget {
  const _Trend({required this.points, required this.label});
  final List<ChartMap> points;
  final String label;
  @override
  State<_Trend> createState() => _TrendState();
}

class _TrendState extends State<_Trend> {
  RangeValues _window = const RangeValues(0, 1);
  int? _selected;
  @override
  void didUpdateWidget(_Trend oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label ||
        oldWidget.points.length != widget.points.length) {
      _window = const RangeValues(0, 1);
      _selected = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.points;
    final start = (_window.start * math.max(0, all.length - 1)).floor();
    final end = (_window.end * math.max(0, all.length - 1)).ceil();
    final points = all.isEmpty ? <ChartMap>[] : all.sublist(start, end + 1);
    final selected = _selected == null || points.isEmpty
        ? null
        : points[_selected!.clamp(0, points.length - 1)];
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: Center(
            child: Text(
              selected == null
                  ? widget.label
                  : '${selected['bucket']} / ${NumberFormat.decimalPattern(AppScope.of(context).text.locale).format(selected['count'])}',
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, area) => GestureDetector(
            onTapDown: (event) => setState(
              () => _selected =
                  (((event.localPosition.dx - 44) /
                              math.max(1, area.maxWidth - 56)) *
                          math.max(0, points.length - 1))
                      .round()
                      .clamp(0, math.max(0, points.length - 1)),
            ),
            child: Semantics(
              label: widget.label,
              child: SizedBox(
                height: 200,
                width: double.infinity,
                child: CustomPaint(
                  painter: _TrendPainter(
                    points,
                    Theme.of(context).colorScheme,
                    AppScope.of(context).text.locale,
                    _selected,
                  ),
                ),
              ),
            ),
          ),
        ),
        RangeSlider(
          values: _window,
          onChanged: all.length < 2
              ? null
              : (value) {
                  if (value.end - value.start < 1 / all.length) return;
                  setState(() {
                    _window = value;
                    _selected = null;
                  });
                },
        ),
      ],
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.points, this.colors, this.locale, this.selected);
  final List<ChartMap> points;
  final ColorScheme colors;
  final String locale;
  final int? selected;
  void label(Canvas canvas, String value, Offset position) {
    final text = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, position);
    text.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTRB(44, 8, size.width - 12, size.height - 26);
    final highest = points.fold<double>(
      1,
      (v, p) => math.max(v, (p['count'] as num).toDouble()),
    );
    for (var i = 0; i <= 4; i++) {
      final y = box.bottom - box.height * i / 4;
      canvas.drawLine(
        Offset(box.left, y),
        Offset(box.right, y),
        Paint()
          ..color = colors.outlineVariant
          ..strokeWidth = .5,
      );
      label(
        canvas,
        NumberFormat.compact(locale: locale).format(highest * i / 4),
        Offset(0, y - 6),
      );
    }
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = Offset(
        box.left +
            box.width * (points.length == 1 ? .5 : i / (points.length - 1)),
        box.bottom - box.height * (points[i]['count'] as num) / highest,
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      if (selected == i) {
        canvas.drawCircle(p, 4, Paint()..color = colors.tertiary);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.primary
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    if (points.isNotEmpty) {
      label(
        canvas,
        '${points.first['bucket']}',
        Offset(box.left, box.bottom + 8),
      );
      label(
        canvas,
        '${points.last['bucket']}',
        Offset(math.max(box.left, box.right - 70), box.bottom + 8),
      );
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.points != points || old.colors != colors || old.selected != selected;
}

class _Partition extends StatelessWidget {
  const _Partition({
    required this.values,
    required this.label,
    required this.count,
    required this.onSelected,
  });
  final ChartMap values;
  final String Function(String) label;
  final String Function(Object?) count;
  final ValueChanged<String> onSelected;
  @override
  Widget build(BuildContext context) {
    final rows = values.entries.where((row) => row.value is num).toList();
    final scheme = Theme.of(context).colorScheme;
    final colors = [
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      scheme.error,
      scheme.primaryContainer,
      scheme.tertiaryContainer,
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox.square(
          dimension: 180,
          child: GestureDetector(
            onTapUp: (event) {
              final p = event.localPosition - const Offset(90, 90);
              if (p.distance < 38 || p.distance > 76) return;
              var angle =
                  (math.atan2(p.dy, p.dx) + math.pi / 2) % (2 * math.pi);
              final sum = rows.fold<double>(
                0,
                (sum, r) => sum + (r.value as num),
              );
              if (sum == 0) return;
              for (final row in rows) {
                angle -= 2 * math.pi * (row.value as num) / sum;
                if (angle <= 0) {
                  onSelected(row.key);
                  break;
                }
              }
            },
            child: CustomPaint(
              painter: _PartitionPainter(
                rows.map((r) => (r.value as num).toDouble()).toList(),
                colors,
                scheme.surface,
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rows.length; i++)
              TextButton.icon(
                onPressed: () => onSelected(rows[i].key),
                icon: Icon(
                  Symbols.circle_rounded,
                  color: colors[i % colors.length],
                  size: 14,
                ),
                label: Text('${label(rows[i].key)} / ${count(rows[i].value)}'),
              ),
          ],
        ),
      ],
    );
  }
}

class _PartitionPainter extends CustomPainter {
  _PartitionPainter(this.values, this.colors, this.surface);
  final List<double> values;
  final List<Color> colors;
  final Color surface;
  @override
  void paint(Canvas canvas, Size size) {
    final sum = values.fold<double>(0, (a, b) => a + b);
    var at = -math.pi / 2;
    for (var i = 0; i < values.length && sum > 0; i++) {
      final sweep = math.pi * 2 * values[i] / sum;
      canvas.drawArc(
        Rect.fromCircle(center: size.center(Offset.zero), radius: 57),
        at,
        math.max(0, sweep - .02),
        false,
        Paint()
          ..color = colors[i % colors.length]
          ..strokeWidth = 34
          ..style = PaintingStyle.stroke,
      );
      at += sweep;
    }
  }

  @override
  bool shouldRepaint(_PartitionPainter old) =>
      old.values != values || old.colors != colors;
}

class _WorldMap extends StatefulWidget {
  const _WorldMap({
    required this.geometry,
    required this.geo,
    required this.onUsers,
  });
  final ChartMap geometry, geo;
  final ValueChanged<String> onUsers;
  @override
  State<_WorldMap> createState() => _WorldMapState();
}

class _WorldMapState extends State<_WorldMap> {
  final _transform = TransformationController();
  late final _countries = [
    for (final feature in chartRows(widget.geometry['features']))
      _MapCountry(feature),
  ];
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = AppScope.of(context).text;
    final points = chartRows(widget.geo['points']);
    final countries = chartRows(widget.geo['countries']);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (final (icon, key, scale) in [
              (Symbols.zoom_in_rounded, 'zoomIn', 1.5),
              (Symbols.zoom_out_rounded, 'zoomOut', 1 / 1.5),
            ])
              IconButton(
                icon: Icon(icon),
                tooltip: text('admin.page.analytics.$key'),
                onPressed: () {
                  final current = _transform.value.getMaxScaleOnAxis(),
                      next = (current * scale).clamp(1.0, 12.0);
                  _transform.value = _transform.value.clone()
                    ..scaleByDouble(next / current, next / current, 1, 1);
                },
              ),
            IconButton(
              icon: const Icon(Symbols.restart_alt_rounded),
              tooltip: text('admin.page.analytics.resetMap'),
              onPressed: () => _transform.value = Matrix4.identity(),
            ),
          ],
        ),
        AspectRatio(
          aspectRatio: 2,
          child: LayoutBuilder(
            builder: (context, area) => InteractiveViewer(
              transformationController: _transform,
              minScale: 1,
              maxScale: 12,
              child: GestureDetector(
                onTapUp: (event) {
                  final tap = event.localPosition;
                  for (final point in points.reversed) {
                    final p = _MapCountry.project(
                      (point['longitude'] as num).toDouble(),
                      (point['latitude'] as num).toDouble(),
                    );
                    if ((Offset(p.dx * area.maxWidth, p.dy * area.maxHeight) -
                                tap)
                            .distance <
                        16) {
                      widget.onUsers('${point['usersUrl']}');
                      return;
                    }
                  }
                  final local = Offset(
                    tap.dx / area.maxWidth,
                    tap.dy / area.maxHeight,
                  );
                  final country = _countries
                      .where((c) => c.path.contains(local))
                      .firstOrNull;
                  if (country == null) return;
                  final row = countries
                      .where((c) => c['countryCode'] == country.iso)
                      .firstOrNull;
                  if (row != null) widget.onUsers('${row['usersUrl']}');
                },
                child: CustomPaint(
                  size: Size(area.maxWidth, area.maxHeight),
                  painter: _WorldPainter(
                    _countries,
                    widget.geo,
                    Theme.of(context).colorScheme,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MapCountry {
  _MapCountry(ChartMap feature)
    : iso = chartMap(feature['properties'])['iso2'] as String? {
    final geometry = chartMap(feature['geometry']);
    final coordinates = geometry['coordinates'] as List;
    final polygons = geometry['type'] == 'Polygon'
        ? [coordinates]
        : coordinates;
    for (final polygon in polygons) {
      for (final ring in polygon as List) {
        var first = true;
        for (final coordinate in ring as List) {
          final pair = coordinate as List;
          final p = project(
            (pair[0] as num).toDouble(),
            (pair[1] as num).toDouble(),
          );
          if (first) {
            path.moveTo(p.dx, p.dy);
            first = false;
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        path.close();
      }
    }
  }
  final String? iso;
  final path = Path()..fillType = PathFillType.evenOdd;
  static Offset project(double longitude, double latitude) =>
      Offset((longitude + 180) / 360, (90 - latitude) / 180);
}

class _WorldPainter extends CustomPainter {
  _WorldPainter(this.countries, this.geo, this.colors);
  final List<_MapCountry> countries;
  final ChartMap geo;
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    final counts = {
      for (final c in chartRows(geo['countries']))
        c['countryCode']: (c['count'] as num).toDouble(),
    };
    final maximum = counts.values.fold<double>(1, math.max);
    canvas.save();
    canvas.scale(size.width, size.height);
    for (final country in countries) {
      final value = counts[country.iso] ?? 0;
      canvas.drawPath(
        country.path,
        Paint()
          ..color = Color.lerp(
            colors.surfaceContainerHighest,
            colors.primary,
            math.sqrt(value / maximum),
          )!,
      );
      canvas.drawPath(
        country.path,
        Paint()
          ..color = colors.outlineVariant
          ..style = PaintingStyle.stroke
          ..strokeWidth = .0008,
      );
    }
    canvas.restore();
    for (final point in chartRows(geo['points'])) {
      final p = _MapCountry.project(
        (point['longitude'] as num).toDouble(),
        (point['latitude'] as num).toDouble(),
      );
      canvas.drawCircle(
        Offset(p.dx * size.width, p.dy * size.height),
        3 + 7 * math.sqrt((point['count'] as num) / maximum),
        Paint()..color = colors.tertiary.withValues(alpha: .8),
      );
    }
  }

  @override
  bool shouldRepaint(_WorldPainter old) =>
      old.geo != geo || old.colors != colors;
}
