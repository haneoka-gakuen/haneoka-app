import 'dart:math' as math;

import 'controller.dart';
import 'editing.dart';
import 'project.dart';

extension ChartAuthoringActions on ChartEditorController {
  void applyPattern(
    ChartMap clipboard, {
    bool mirrored = false,
    bool duplicate = false,
  }) {
    final ids = <String>{};
    final tick = duplicate && selection.isNotEmpty
        ? project.nodes
                  .where((node) => selection.contains(node.id))
                  .map((node) => node.tick)
                  .fold<int>(positionTick, (a, b) => math.max(a, b)) +
              math.max(1, (480 / division).round())
        : positionTick;
    if (edit((draft) {
      ids.addAll(pasteChartSelection(draft, clipboard, tick.toInt()));
      if (mirrored) flipChartSelection(draft, ids);
    })) {
      select(ids);
    }
  }

  void duplicateSelection({bool mirrored = false}) => applyPattern(
    copyChartSelection(project, selection),
    mirrored: mirrored,
    duplicate: true,
  );
  void compressSelection(bool last) => edit((draft) {
    final ticks =
        draft.nodes
            .where((node) => selection.contains(node.id))
            .map((node) => node.tick)
            .toSet()
            .toList()
          ..sort();
    if (ticks.length < 2) return;
    final start = last ? ticks.last - ticks.length + 1 : ticks.first;
    final mapping = {
      for (var i = 0; i < ticks.length; i++) ticks[i]: start + i,
    };
    if (start < 0) throw const FormatException('invalid_edit');
    for (final node in draft.nodes) {
      if (selection.contains(node.id)) node.note['tick'] = mapping[node.tick];
    }
    for (final line in draft.lines) {
      final points = chartRows(line['points']);
      for (var i = 1; i < points.length; i++) {
        if ((points[i]['tick'] as int) < (points[i - 1]['tick'] as int)) {
          throw const FormatException('line_time_order');
        }
      }
    }
    clearChartAutoGeometry(draft, selection);
  });
  void shortFlick() {
    final ids = <String>[];
    if (edit((draft) {
      final lineId = chartId('line');
      final first = authoredChartNote(
        draft,
        positionTick,
        laneStart.clamp(0, draft.laneBasis - noteWidth),
        noteWidth,
        type: 'tap',
        critical: critical,
      );
      final last = authoredChartNote(
        draft,
        positionTick + 1,
        laneStart.clamp(0, draft.laneBasis - noteWidth),
        noteWidth,
        type: 'flick',
        direction: direction,
        critical: true,
      );
      for (final row in [first, last]) {
        row['ease'] = {'left': 'linear', 'right': 'linear'};
        ids.add('${row['id']}');
      }
      (draft.data['lines'] as List).add({
        'id': lineId,
        'kind': 'long',
        'points': [first, last],
      });
      if (group != null || layer != null) {
        assignChartSelection(draft, ids.toSet(), {
          'groupId': group,
          'layerId': layer,
        });
      }
    })) {
      select(ids);
    }
  }

  void insertControl(int tick, {double? lane}) {
    final selectedLine = project.nodes
        .where((node) => selection.contains(node.id) && node.line != null)
        .firstOrNull
        ?.line;
    if (selectedLine == null) return;
    final id = chartId('node');
    if (edit((draft) {
      final line = draft.lines.firstWhere(
        (line) => line['id'] == selectedLine['id'],
      );
      final points = chartRows(line['points']);
      if (tick <= (points.first['tick'] as int) ||
          tick >= (points.last['tick'] as int) ||
          points.any((point) => point['tick'] == tick)) {
        throw const FormatException('invalid_edit');
      }
      final previous = points.lastWhere(
        (point) => (point['tick'] as int) < tick,
      );
      final point = {
        ...previous,
        'id': id,
        'tick': tick,
        'lane': lane ?? 'auto',
        'size': lane == null ? 0 : noteWidth,
        if (lane == null) 'autoSize': true,
        'visible': true,
      };
      points.add(point);
      points.sort((a, b) => (a['tick'] as int).compareTo(b['tick'] as int));
      line['points'] = points;
      clearChartAutoGeometry(draft, {id});
    })) {
      select([id]);
    }
  }
}
