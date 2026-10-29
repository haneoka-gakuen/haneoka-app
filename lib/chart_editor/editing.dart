import 'dart:math' as math;

import 'project.dart';

Set<String> chartEntityIds(ChartProject project) => {
  for (final node in project.nodes) node.id,
  for (final line in project.lines) '${line['id']}',
  for (final key in ['tempos', 'meters', 'timeScales'])
    for (final row in chartRows(project.data[key])) '${row['id']}',
};

ChartMap chartCollections(ChartProject project) {
  final raw = project.extensions['authoringCollections'];
  final value = raw == null
      ? <String, Object?>{
          'schema': 'haneoka.authoring.collections',
          'version': 1,
          'groups': <Object?>[],
          'layers': <Object?>[],
          'members': <String, Object?>{},
          'sourceContexts': <String, Object?>{},
        }
      : cloneChartMap(raw as Map);
  if (value['schema'] != 'haneoka.authoring.collections' ||
      value['version'] != 1 ||
      value['groups'] is! List ||
      value['layers'] is! List ||
      value['members'] is! Map ||
      value['sourceContexts'] is! Map) {
    throw const FormatException('invalid_authoring_collections');
  }
  final ids = <String>{};
  for (final item in [
    ...chartRows(value['groups']),
    ...chartRows(value['layers']),
  ]) {
    final id = item['id'], name = item['name'];
    if (id is! String ||
        id.isEmpty ||
        !ids.add(id) ||
        name is! String ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch('$id$name')) {
      throw const FormatException('invalid_authoring_collection');
    }
  }
  for (final group in chartRows(value['groups'])) {
    final speed = group['forceNoteSpeed'];
    if (speed != null && (speed is! num || !speed.isFinite || speed <= 0)) {
      throw const FormatException('invalid_group_speed');
    }
  }
  for (final layer in chartRows(value['layers'])) {
    if (layer['visible'] is! bool) {
      throw const FormatException('invalid_layer_visibility');
    }
  }
  final entities = chartEntityIds(project);
  final groups = chartRows(value['groups']).map((v) => v['id']).toSet();
  final layers = chartRows(value['layers']).map((v) => v['id']).toSet();
  for (final entry in chartMap(value['members']).entries) {
    final member = entry.value;
    if (!entities.contains(entry.key) ||
        member is! Map ||
        member['groupId'] != null && !groups.contains(member['groupId']) ||
        member['layerId'] != null && !layers.contains(member['layerId'])) {
      throw const FormatException('invalid_authoring_membership');
    }
    final source = member['source'];
    if (source != null &&
        (source is! Map ||
            source['contextId'] is! String ||
            source['entityId'] is! String ||
            !(value['sourceContexts'] as Map).containsKey(
              source['contextId'],
            ))) {
      throw const FormatException('invalid_authoring_source');
    }
  }
  return value;
}

Set<String> expandChartSelection(ChartProject project, Set<String> selection) {
  final entities = chartEntityIds(project),
      result = selection.intersection(entities);
  for (final entry in chartMap(chartCollections(project)['members']).entries) {
    final member = chartMap(entry.value);
    if (selection.contains(member['groupId']) ||
        selection.contains(member['layerId'])) {
      result.add(entry.key);
    }
  }
  for (final line in project.lines) {
    final points = chartRows(line['points']);
    if (result.contains(line['id']) ||
        points.any((point) => result.contains(point['id']))) {
      result.add('${line['id']}');
      result.addAll(points.map((point) => '${point['id']}'));
    }
  }
  return result;
}

Set<String> chartScope(
  ChartProject project, {
  String? group,
  String? layer,
  bool hidden = false,
}) {
  final collections = chartCollections(project),
      members = chartMap(collections['members']);
  final invisible = chartRows(collections['layers'])
      .where((v) => v['visible'] == false)
      .map((v) => v['id'])
      .toSet();
  return chartEntityIds(project).where((id) {
    final member = members[id] is Map
        ? chartMap(members[id])
        : const <String, Object?>{};
    return (group == null || member['groupId'] == group) &&
        (layer == null || member['layerId'] == layer) &&
        (hidden || !invisible.contains(member['layerId']));
  }).toSet();
}

void reconcileChartCollections(ChartProject project) {
  final value = project.extensions['authoringCollections'];
  if (value is! Map) return;
  final ids = chartEntityIds(project), members = chartMap(value['members']);
  members.removeWhere((key, _) => !ids.contains(key));
  chartCollections(project);
}

void assignChartSelection(
  ChartProject project,
  Set<String> selection,
  ChartMap assignment,
) {
  final value = chartCollections(project), members = chartMap(value['members']);
  for (final id in expandChartSelection(project, selection)) {
    final member = members[id] is Map
        ? chartMap(members[id])
        : <String, Object?>{};
    for (final entry in assignment.entries) {
      if (entry.value == null) {
        member.remove(entry.key);
      } else {
        member[entry.key] = entry.value;
      }
    }
    if (member.isEmpty) {
      members.remove(id);
    } else {
      members[id] = member;
    }
  }
  project.extensions['authoringCollections'] = value;
  chartCollections(project);
}

bool chartSpanInBounds(double lane, double size, double basis, bool interior) =>
    interior
    ? size == 0
          ? lane >= 0 && lane <= basis
          : lane < basis && lane + size > 0
    : lane >= 0 && lane + size <= basis;

void requireEditedChartSpans(ChartProject before, ChartProject after) {
  final previous = {for (final node in before.nodes) node.id: node};
  for (final node in after.nodes) {
    final old = previous[node.id];
    final changed =
        old == null ||
        old.lane != node.lane ||
        old.size != node.size ||
        old.interior != node.interior ||
        old.note['type'] != node.note['type'] ||
        old.note['visible'] != node.note['visible'] ||
        old.line?['kind'] != node.line?['kind'] ||
        before.laneBasis != after.laneBasis;
    if (changed &&
        !chartSpanInBounds(
          node.lane,
          node.size,
          after.laneBasis,
          node.interior,
        )) {
      throw const FormatException('authored_span_outside_stage');
    }
  }
}

ChartMap authoredChartNote(
  ChartProject project,
  int tick,
  double lane,
  double size, {
  String type = 'tap',
  String direction = 'up',
  bool critical = false,
  bool visible = true,
  bool interior = false,
}) {
  if (size < 0 ||
      !size.isFinite ||
      tick < 0 ||
      !lane.isFinite ||
      !interior && size > project.laneBasis) {
    throw const FormatException('invalid_note_position');
  }
  final position = interior ? lane : lane.clamp(0.0, project.laneBasis - size);
  if (!chartSpanInBounds(position, size, project.laneBasis, interior)) {
    throw const FormatException('authored_span_outside_stage');
  }
  return {
    'id': chartId('note'),
    'tick': tick,
    'lane': position,
    'size': size,
    'type': type,
    'direction': type == 'flick' ? direction : 'none',
    'critical': critical,
    'visible': visible,
  };
}

void clearChartAutoGeometry(ChartProject project, Set<String> selection) {
  for (final line in project.lines) {
    final points = chartRows(line['points']);
    if (!points.any((p) => selection.contains(p['id']))) continue;
    for (final point in points) {
      if (point['lane'] == 'auto') {
        point.remove('resolvedLane');
        point.remove('resolvedSize');
      }
    }
  }
}

void moveChartSelection(
  ChartProject project,
  Set<String> selection,
  int tickDelta,
  double laneDelta, {
  double laneStep = 1,
}) {
  final before = project.copy();
  final selected = project.nodes
      .where((n) => selection.contains(n.id))
      .toList();
  if (selected.isEmpty || tickDelta == 0 && laneDelta == 0) return;
  var minimumTick = -selected.map((n) => n.tick).reduce(math.min);
  var maximumTick =
      9007199254740991 - selected.map((n) => n.tick).reduce(math.max);
  for (final line in project.lines) {
    final points = chartRows(line['points']);
    for (final (i, point) in points.indexed) {
      if (!selection.contains(point['id'])) continue;
      if (i > 0 && !selection.contains(points[i - 1]['id'])) {
        minimumTick = math.max(
          minimumTick,
          (points[i - 1]['tick'] as int) - (point['tick'] as int),
        );
      }
      if (i + 1 < points.length && !selection.contains(points[i + 1]['id'])) {
        maximumTick = math.min(
          maximumTick,
          (points[i + 1]['tick'] as int) - (point['tick'] as int),
        );
      }
    }
  }
  final dt = tickDelta.clamp(minimumTick, maximumTick);
  var dl = laneDelta;
  final concrete = selected.where((n) => n.note['lane'] is num).toList();
  if (dl != 0 && concrete.isNotEmpty) {
    if (concrete.any(
      (n) => !chartSpanInBounds(n.lane, n.size, project.laneBasis, n.interior),
    )) {
      if (concrete.any(
        (n) => !chartSpanInBounds(
          n.lane + dl,
          n.size,
          project.laneBasis,
          n.interior,
        ),
      )) {
        throw const FormatException('authored_span_outside_stage');
      }
    } else {
      var low = -double.infinity, high = double.infinity;
      var lowInclusive = true, highInclusive = true;
      for (final node in concrete) {
        final a = (node.interior ? -node.size : 0) - node.lane;
        final b =
            (node.interior
                ? project.laneBasis
                : project.laneBasis - node.size) -
            node.lane;
        final inclusive = !node.interior || node.size == 0;
        if (a > low) {
          low = a;
          lowInclusive = inclusive;
        } else if (a == low) {
          lowInclusive &= inclusive;
        }
        if (b < high) {
          high = b;
          highInclusive = inclusive;
        } else if (b == high) {
          highInclusive &= inclusive;
        }
      }
      if (dl < low || dl == low && !lowInclusive) {
        dl =
            (low / laneStep).floor() * laneStep +
            (lowInclusive && low % laneStep == 0 ? 0 : laneStep);
      }
      if (dl > high || dl == high && !highInclusive) {
        dl =
            (high / laneStep).ceil() * laneStep -
            (highInclusive && high % laneStep == 0 ? 0 : laneStep);
      }
      if (dl < low ||
          dl > high ||
          dl == low && !lowInclusive ||
          dl == high && !highInclusive) {
        throw const FormatException('no_overlapping_lane_grid_point');
      }
    }
  }
  for (final node in selected) {
    node.note['tick'] = node.tick + dt;
    if (node.note['lane'] is num) {
      node.note['lane'] = (node.note['lane'] as num) + dl;
    }
  }
  clearChartAutoGeometry(project, selection);
  requireEditedChartSpans(before, project);
}

void brushChartSelection(
  ChartProject project,
  Set<String> ids,
  ChartMap patch, {
  String anchor = 'left',
}) {
  final before = project.copy();
  final original = {for (final node in project.nodes) node.id: node};
  for (final node in project.nodes.toList()) {
    if (!ids.contains(node.id)) continue;
    final note = node.note;
    if (patch['size'] case final num width) {
      final shape = original[node.id]!;
      final lane =
          shape.lane +
          (anchor == 'center'
              ? (shape.size - width) / 2
              : anchor == 'right'
              ? shape.size - width
              : 0);
      note['lane'] = lane;
      note['size'] = width;
      note.remove('autoSize');
      note.remove('resolvedLane');
      note.remove('resolvedSize');
    }
    for (final key in ['type', 'critical', 'visible']) {
      if (patch.containsKey(key)) note[key] = patch[key];
    }
    note['direction'] = note['type'] == 'flick'
        ? patch['direction'] ??
              (note['direction'] == 'none' ? 'up' : note['direction'])
        : 'none';
    if (node.line != null) {
      if (patch['ease'] is Map) {
        note['ease'] = {...chartMap(note['ease']), ...chartMap(patch['ease'])};
      }
      if (patch.containsKey('lineKind')) node.line!['kind'] = patch['lineKind'];
      if (patch.containsKey('lineCritical')) {
        node.line!['critical'] = patch['lineCritical'];
      }
    }
  }
  clearChartAutoGeometry(project, ids);
  requireEditedChartSpans(before, project);
}

void flipChartSelection(ChartProject project, Set<String> ids) {
  final before = project.copy();
  for (final node in project.nodes) {
    if (!ids.contains(node.id)) continue;
    final note = node.note;
    if (note['lane'] is num) {
      note['lane'] =
          project.laneBasis - (note['lane'] as num) - (note['size'] as num);
    }
    if (note['direction'] == 'left') {
      note['direction'] = 'right';
    } else if (note['direction'] == 'right') {
      note['direction'] = 'left';
    }
    if (note['ease'] is Map) {
      final ease = chartMap(note['ease']);
      note['ease'] = {'left': ease['right'], 'right': ease['left']};
    }
  }
  clearChartAutoGeometry(project, ids);
  requireEditedChartSpans(before, project);
}

void deleteChartSelection(
  ChartProject project,
  Set<String> ids, {
  bool controlsOnly = false,
}) {
  if (controlsOnly) {
    final before = project.copy();
    for (final line in project.lines) {
      final points = chartRows(line['points']);
      line['points'] = [
        for (final (i, point) in points.indexed)
          if (i == 0 || i == points.length - 1 || !ids.contains(point['id']))
            point,
      ];
    }
    clearChartAutoGeometry(project, ids);
    reconcileChartCollections(project);
    requireEditedChartSpans(before, project);
    return;
  }
  final expanded = expandChartSelection(project, ids);
  if (project.tempos.any(
        (row) => row['tick'] == 0 && expanded.contains(row['id']),
      ) ||
      project.meters.every((row) => expanded.contains(row['id']))) {
    throw const FormatException('protected_timing_origin');
  }
  for (final key in ['singles', 'lines', 'tempos', 'meters', 'timeScales']) {
    project.data[key] = chartRows(project.data[key])
        .where((row) => !expanded.contains(row['id']))
        .toList();
  }
  if (project.data['sourceOrder'] is List) {
    project.data['sourceOrder'] = (project.data['sourceOrder'] as List)
        .where((id) => !expanded.contains(id))
        .toList();
  }
  reconcileChartCollections(project);
}

List<String> generateChartPoints(
  ChartProject project,
  Set<String> ids,
  int division,
) {
  final created = <String>[];
  for (final line in project.lines) {
    final points = chartRows(line['points']);
    if (!ids.contains(line['id']) &&
        !points.any((p) => ids.contains(p['id']))) {
      continue;
    }
    final existing = points.map((p) => p['tick']).toSet(),
        start = points.first['tick'] as int,
        end = points.last['tick'] as int;
    for (
      var unit = (start * division / 480).floor() + 1;
      unit < end * division / 480;
      unit++
    ) {
      final tick = (unit * 480 / division + .5).floor();
      if (!existing.add(tick)) continue;
      final parent = points.reversed.firstWhere(
        (p) => (p['tick'] as int) < tick,
        orElse: () => points.first,
      );
      final id = chartId('node'),
          node = cloneChartMap(parent)
            ..remove('resolvedLane')
            ..remove('resolvedSize');
      node.addAll({
        'id': id,
        'tick': tick,
        'lane': 'auto',
        'size': 0,
        'autoSize': true,
        'ease': {'left': 'linear', 'right': 'linear'},
      });
      points.add(node);
      created.add(id);
    }
    line['points'] = stableChartSort(
      points,
      (a, b) => (a['tick'] as int).compareTo(b['tick'] as int),
    );
  }
  return created;
}

ChartMap copyChartSelection(ChartProject project, Set<String> ids) {
  final expanded = expandChartSelection(project, ids),
      collections = chartCollections(project);
  final members = chartMap(collections['members'])
    ..removeWhere((key, _) => !expanded.contains(key));
  collections['members'] = members;
  collections['groups'] = chartRows(collections['groups'])
      .where((g) => members.values.any((m) => (m as Map)['groupId'] == g['id']))
      .toList();
  collections['layers'] = chartRows(collections['layers'])
      .where((g) => members.values.any((m) => (m as Map)['layerId'] == g['id']))
      .toList();
  final sources = <String, Object?>{};
  for (final entry in project.extensions.entries) {
    final value = entry.value;
    if (value is Map && value['records'] is Map) {
      sources[entry.key] = {
        if (value['schema'] != null) 'schema': value['schema'],
        'records': {...chartMap(value['records'])}
          ..removeWhere((key, _) => !expanded.contains(key)),
      };
    }
  }
  return cloneChartMap({
    'schema': 'haneoka.authoring.clipboard',
    'version': 1,
    'laneBasis': project.laneBasis,
    'resolution': 480,
    'sourceFormat': project.meta['source'],
    'entities': {
      for (final key in ['singles', 'lines', 'tempos', 'meters', 'timeScales'])
        key: chartRows(project.data[key])
            .where((row) => expanded.contains(row['id']))
            .toList(),
    },
    'sourceOrder': [
      for (final id in project.data['sourceOrder'] as List? ?? const [])
        if (expanded.contains(id)) id,
    ],
    'collections': collections,
    'sourceExtensions': sources,
  });
}

ChartMap copyChartSegments(ChartProject project, Set<String> selection) {
  final clipboard = copyChartSelection(project, selection),
      entities = chartMap(copyChartSelection(project, selection)['entities']);
  final lines = <ChartMap>[];
  for (final line in chartRows(entities['lines'])) {
    if (selection.contains(line['id'])) {
      lines.add(line);
      continue;
    }
    final points = chartRows(line['points'])
        .where((point) => selection.contains(point['id']))
        .toList();
    if (points.length < 2) continue;
    final source = chartRows(
      project.lines.firstWhere((row) => row['id'] == line['id'])['points'],
    );
    for (final point in [points.first, points.last]) {
      if (point['lane'] != 'auto') continue;
      final shape = resolveChartPoint(
        source,
        source.indexWhere((row) => row['id'] == point['id']),
      );
      point.addAll({'lane': shape.$1, 'size': shape.$2});
      point.remove('autoSize');
      point.remove('resolvedLane');
      point.remove('resolvedSize');
    }
    lines.add({...line, 'points': points});
  }
  entities['lines'] = lines;
  clipboard['entities'] = entities;
  final ids = <String>{
    for (final key in ['singles', 'tempos', 'meters', 'timeScales'])
      for (final row in chartRows(entities[key])) '${row['id']}',
    for (final line in lines) ...[
      '${line['id']}',
      for (final point in chartRows(line['points'])) '${point['id']}',
    ],
  };
  (clipboard['sourceOrder'] as List).removeWhere((id) => !ids.contains(id));
  chartMap(chartMap(clipboard['collections'])['members'])
      .removeWhere((id, _) => !ids.contains(id));
  return clipboard;
}

Set<String> pasteChartSelection(
  ChartProject project,
  ChartMap clipboard,
  int tick,
) {
  if (clipboard['schema'] != 'haneoka.authoring.clipboard' ||
      clipboard['version'] != 1 ||
      clipboard['resolution'] != 480) {
    throw const FormatException('invalid_clipboard');
  }
  final entities = chartMap(clipboard['entities']),
      mapping = <String, String>{};
  final all = <ChartMap>[];
  for (final key in ['singles', 'lines', 'tempos', 'meters', 'timeScales']) {
    for (final row in chartRows(entities[key])) {
      all.add(row);
      if (key == 'lines') all.addAll(chartRows(row['points']));
    }
  }
  final timed = all.where((row) => row['tick'] is int).toList();
  if (timed.isEmpty) return {};
  final start = timed.map((row) => row['tick'] as int).reduce(math.min);
  final copied = cloneChartMap(clipboard), body = chartMap(copied['entities']);
  final ratio = project.laneBasis / (clipboard['laneBasis'] as num);
  final selected = <String>{};
  void change(ChartMap row, {bool line = false}) {
    final old = '${row['id']}', id = chartId(line ? 'line' : 'note');
    mapping[old] = id;
    row['id'] = id;
    if (!line) {
      row['tick'] = (row['tick'] as int) + tick - start;
      selected.add(id);
      if (row['lane'] is num) row['lane'] = (row['lane'] as num) * ratio;
      if (row['size'] is num) row['size'] = (row['size'] as num) * ratio;
      row.remove('resolvedLane');
      row.remove('resolvedSize');
    }
  }

  for (final key in ['singles', 'lines', 'tempos', 'meters', 'timeScales']) {
    for (final row in chartRows(body[key])) {
      if (key == 'lines') {
        change(row, line: true);
        for (final point in chartRows(row['points'])) {
          change(point);
        }
      } else {
        change(row);
      }
      if (const {'tempos', 'meters', 'timeScales'}.contains(key) &&
          chartRows(project.data[key]).any((r) => r['tick'] == row['tick'])) {
        throw const FormatException('timing_collision');
      }
      (project.data[key] as List).add(row);
    }
  }
  final collections = chartCollections(project),
      incoming = chartMap(copied['collections']);
  for (final key in ['groups', 'layers']) {
    for (final row in chartRows(incoming[key])) {
      final old = '${row['id']}',
          id = chartId(key == 'groups' ? 'group' : 'layer');
      mapping[old] = id;
      row['id'] = id;
      (collections[key] as List).add(row);
    }
  }
  final contexts = chartMap(collections['sourceContexts']);
  for (final entry in chartMap(incoming['sourceContexts']).entries) {
    final id = chartId('source');
    mapping[entry.key] = id;
    contexts[id] = entry.value;
  }
  final members = chartMap(collections['members']);
  for (final entry in chartMap(incoming['members']).entries) {
    final id = mapping[entry.key];
    if (id == null) continue;
    final member = chartMap(entry.value);
    for (final key in ['groupId', 'layerId']) {
      if (member[key] != null) member[key] = mapping[member[key]];
    }
    if (member['source'] is Map) {
      final source = chartMap(member['source']);
      source['contextId'] = mapping[source['contextId']];
    }
    members[id] = member;
  }
  project.extensions['authoringCollections'] = collections;
  for (final entry in chartMap(copied['sourceExtensions']).entries) {
    final source = chartMap(entry.value),
        target = project.extensions[entry.key] is Map
            ? chartMap(project.extensions[entry.key])
            : <String, Object?>{};
    if (target['schema'] != null &&
        source['schema'] != null &&
        target['schema'] != source['schema']) {
      throw const FormatException('clipboard_source_schema_mismatch');
    }
    target['schema'] ??= source['schema'];
    final records = target['records'] is Map
        ? chartMap(target['records'])
        : <String, Object?>{};
    for (final record in chartMap(source['records']).entries) {
      if (mapping[record.key] case final String id) records[id] = record.value;
    }
    target['records'] = records;
    project.extensions[entry.key] = target;
  }
  if (project.data['sourceOrder'] is List) {
    (project.data['sourceOrder'] as List).addAll([
      for (final id in copied['sourceOrder'] as List)
        if (mapping[id] != null) mapping[id],
    ]);
  }
  project.sort();
  chartCollections(project);
  return selected;
}
