import 'dart:math' as math;

import 'controller.dart';
import 'editing.dart';
import 'project.dart';

void _copyRecords(ChartProject project, Map<String, String> mapping) {
  for (final source in project.extensions.values) {
    if (source is! Map || source['records'] is! Map) continue;
    final records = source['records'] as Map;
    for (final entry in mapping.entries) {
      if (records.containsKey(entry.value)) {
        records[entry.key] = cloneChartMap({
          'value': records[entry.value],
        })['value'];
      }
    }
  }
}

void _inherit(ChartProject project, Map<String, String> mapping) {
  final collections = chartCollections(project),
      members = chartMap(chartCollections(project)['members']);
  for (final entry in mapping.entries) {
    if (members[entry.value] is Map) {
      members[entry.key] = cloneChartMap(members[entry.value] as Map);
    }
  }
  collections['members'] = members;
  project.extensions['authoringCollections'] = collections;
}

List<ChartMap> _lines(ChartProject p, Set<String> ids) => p.lines
    .where(
      (line) =>
          ids.contains(line['id']) ||
          chartRows(line['points']).any((point) => ids.contains(point['id'])),
    )
    .toList();

extension ChartConnectorActions on ChartEditorController {
  void splitConnector() {
    if (selection.length != 1) return;
    final selected = project.nodes
        .where((node) => selection.contains(node.id) && node.interior)
        .firstOrNull;
    if (selected == null) return;
    final ids = <String>[];
    if (edit((draft) {
      final lines = draft.data['lines'] as List,
          line = lines.cast<Map>().firstWhere(
            (line) => line['id'] == selected.line!['id'],
          ),
          points = chartRows(line['points']),
          index = points.indexWhere((point) => point['id'] == selected.id);
      final boundary = points[index];
      boundary.addAll({
        'lane': selected.lane,
        'size': selected.size,
        'type': 'tap',
        'direction': 'none',
        'critical': line['critical'] ?? boundary['critical'],
      });
      boundary.remove('autoSize');
      final startId = chartId('node'),
          lineId = chartId('line'),
          right = cloneChartMap(line);
      right['id'] = lineId;
      right['points'] = [
        {...boundary, 'id': startId},
        ...points.skip(index + 1),
      ];
      line['points'] = points.take(index + 1).toList();
      lines.insert(lines.indexOf(line) + 1, right);
      final order = draft.data['sourceOrder'] as List?;
      if (order != null) order.insert(order.indexOf(line['id']) + 1, lineId);
      _copyRecords(draft, {lineId: '${line['id']}', startId: selected.id});
      _inherit(draft, {lineId: '${line['id']}', startId: selected.id});
      clearChartAutoGeometry(draft, {selected.id, startId});
      ids.addAll([selected.id, startId]);
    })) {
      select(ids);
    }
  }

  void joinConnectors() {
    if (selection.length != 2) return;
    final lines = _lines(project, selection);
    if (lines.length != 2 || lines[0]['kind'] != lines[1]['kind']) return;
    var first = lines[0], second = lines[1];
    bool ordered(ChartMap a, ChartMap b) {
      final ap = chartRows(a['points']), bp = chartRows(b['points']);
      return selection.contains(ap.last['id']) &&
          selection.contains(bp.first['id']) &&
          (ap.last['tick'] as int) <= (bp.first['tick'] as int);
    }

    if (!ordered(first, second)) {
      first = lines[1];
      second = lines[0];
      if (!ordered(first, second)) return;
    }
    final ids = <String>[];
    if (edit((draft) {
      final state = chartCollections(draft),
          members = chartMap(state['members']);
      Object? speed(ChartMap line) {
        final group = (members[line['id']] as Map?)?['groupId'];
        return chartRows(state['groups'])
            .where((row) => row['id'] == group)
            .firstOrNull?['forceNoteSpeed'];
      }

      if (speed(first) != speed(second)) {
        throw const FormatException('connector_speed_conflict');
      }
      final a = draft.lines.firstWhere((row) => row['id'] == first['id']),
          ap = chartRows(a['points']),
          bp = chartRows(second['points']);
      final end = resolveChartPoint(ap, ap.length - 1),
          start = resolveChartPoint(bp, 0);
      if (ap.last['tick'] == bp.first['tick'] && end == start) {
        ap.removeLast();
      } else {
        ap.last.addAll({'type': 'tap', 'direction': 'none'});
      }
      final joined = cloneChartMap({'points': bp});
      final points = chartRows(joined['points']);
      points.first.addAll({'type': 'tap', 'direction': 'none'});
      ap.addAll(points);
      a['points'] = ap;
      (draft.data['lines'] as List).removeWhere(
        (row) => (row as Map)['id'] == second['id'],
      );
      (draft.data['sourceOrder'] as List?)?.remove(second['id']);
      ids.add('${points.first['id']}');
      clearChartAutoGeometry(draft, ids.toSet());
    })) {
      select(ids);
    }
  }

  void repeatConnector() {
    final lines = _lines(project, selection);
    if (lines.length != 1) return;
    final source = lines.single,
        points = chartRows(source['points'])
            .where((point) => selection.contains(point['id']))
            .toList();
    if (points.length < 3) return;
    final firstTick = points.first['tick'] as int,
        lastTick = points.last['tick'] as int,
        end = chartRows(source['points']).last['tick'] as int,
        period = lastTick - firstTick;
    if (period <= 0 || lastTick >= end) return;
    if (((end - lastTick) / period).ceil() * (points.length - 1) > 100000) {
      return;
    }
    final all = chartRows(source['points']),
        first = resolveChartPoint(
          all,
          all.indexWhere((p) => p['id'] == points.first['id']),
        ),
        last = resolveChartPoint(
          all,
          all.indexWhere((p) => p['id'] == points.last['id']),
        );
    final ids = <String>[];
    if (edit((draft) {
      final line = draft.lines.firstWhere((line) => line['id'] == source['id']),
          existing = chartRows(line['points']),
          times = existing.map((row) => row['tick']).toSet(),
          mapping = <String, String>{};
      for (
        var iteration = 1;
        firstTick + period * iteration < end;
        iteration++
      ) {
        for (final point in points.skip(1)) {
          final tick = (point['tick'] as int) + period * iteration;
          if (tick >= end || times.contains(tick)) continue;
          final copy = cloneChartMap(point), id = chartId('node');
          copy['id'] = id;
          copy['tick'] = tick;
          if (copy['lane'] is num) {
            copy['lane'] =
                (copy['lane'] as num) + iteration * (last.$1 - first.$1);
          }
          if (point['id'] == points.last['id']) {
            copy['ease'] = cloneChartMap(points.first['ease'] as Map);
          }
          existing.add(copy);
          times.add(tick);
          ids.add(id);
          mapping[id] = '${point['id']}';
        }
      }
      if (ids.isNotEmpty) {
        existing.firstWhere(
          (point) => point['id'] == points.last['id'],
        )['ease'] = cloneChartMap(
          points.first['ease'] as Map,
        );
      }
      existing.sort((a, b) => (a['tick'] as int).compareTo(b['tick'] as int));
      line['points'] = existing;
      _copyRecords(draft, mapping);
      _inherit(draft, {for (final id in ids) id: '${line['id']}'});
      clearChartAutoGeometry(draft, ids.toSet());
    })) {
      select(ids);
    }
  }

  void connectorTraces({bool keepLines = true}) {
    final lines = _lines(project, selection);
    if (lines.isEmpty) return;
    final ids = <String>[];
    if (edit((draft) {
      for (final line in lines) {
        final points = chartRows(line['points']),
            first = points.first['tick'] as int,
            last = points.last['tick'] as int;
        final step = math.max(1, (1920 / division).round());
        if ((last - first) ~/ step > 100000) {
          throw const FormatException('too_many_generated_notes');
        }
        for (var tick = first; tick <= last; tick += step) {
          if (keepLines &&
              (tick == first && points.first['visible'] == true ||
                  tick == last && points.last['visible'] == true)) {
            continue;
          }
          final index = points.indexWhere(
            (point) => (point['tick'] as int) >= tick,
          );
          final shape = points[index]['tick'] == tick
              ? resolveChartPoint(points, index)
              : resolveChartPoint([
                  ...points.take(index),
                  {
                    ...points[index - 1],
                    'tick': tick,
                    'lane': 'auto',
                    'autoSize': true,
                  },
                  ...points.skip(index),
                ], index);
          final note = authoredChartNote(
            draft,
            tick,
            shape.$1,
            shape.$2,
            type: 'trace',
            critical:
                line['critical'] == true ||
                line['critical'] == null && points.first['critical'] == true,
          );
          (draft.data['singles'] as List).add(note);
          (draft.data['sourceOrder'] as List?)?.add(note['id']);
          ids.add('${note['id']}');
          _inherit(draft, {'${note['id']}': '${line['id']}'});
        }
      }
      if (!keepLines) {
        final removed = lines.map((line) => line['id']).toSet();
        (draft.data['lines'] as List).removeWhere(
          (line) => removed.contains((line as Map)['id']),
        );
        (draft.data['sourceOrder'] as List?)?.removeWhere(removed.contains);
      }
    })) {
      select(ids);
    }
  }
}
