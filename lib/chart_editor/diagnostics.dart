import 'dart:typed_data';

import 'formats.dart';
import 'project.dart';
import 'sus_export.dart';
import 'mmws.dart';

typedef ChartExportValidation = ({
  List<ChartIssue> errors,
  List<ChartIssue> warnings,
});

List<ChartIssue> chartExportWarnings(ChartProject project, String format) {
  if (format == 'project') return [];
  final result = <ChartIssue>[];
  void warn(String code, String path) =>
      result.add(ChartIssue('$format.export.$code', path, true));
  final meta = project.meta;
  if ([
        'title',
        'artist',
        'charter',
        'difficulty',
        'level',
      ].any((key) => meta[key] != '') ||
      (meta['tags'] as List? ?? const []).isNotEmpty ||
      meta['source'] != null &&
          meta['source'] != '' &&
          meta['source'] != format ||
      chartMap(meta['extra'] ?? const {}).keys
          .any((key) => format != 'ss' || key != 'ssVersion')) {
    warn('metaUnsupported', r'$.meta');
  }
  if (project.extensions.keys.any(
    (key) => format != 'ss' || key != 'ssSource',
  )) {
    warn('extensionsUnsupported', r'$.extensions');
  }
  if (project.laneBasis != 24) warn('laneBasisNormalized', r'$.laneBasis');
  if (format == 'ss') {
    if (meta['source'] != null &&
        meta['source'] != '' &&
        !const {'ss', 'authored'}.contains(meta['source'])) {
      warn('sourceRulesChanged', r'$.meta.source');
    }
    for (final (i, note) in project.singles.indexed) {
      if (note['type'] == 'trace' && note['direction'] != 'none') {
        warn('traceDirectionUnsupported', '\$.singles[$i].direction');
      }
      if (note['visible'] == false) {
        warn('singleVisibilityIgnored', '\$.singles[$i].visible');
      }
    }
    for (final (i, line) in project.lines.indexed) {
      if (line['kind'] == 'guide') {
        warn('guideJudgementContext', '\$.lines[$i]');
      }
      final points = chartRows(line['points']);
      for (var at = 1; at < points.length - 1; at++) {
        if (line['kind'] == 'long' && points[at]['type'] == 'flick') {
          warn('midpointFlickUnsupported', '\$.lines[$i].points[$at]');
        }
      }
    }
    if (project.audioOffset != 0) {
      warn('audioOffsetUnsupported', r'$.audioOffset');
    }
    if (project.timeScales.isNotEmpty) {
      warn('timeScalesUnsupported', r'$.timeScales');
    }
    return result;
  }
  if (project.meters.length != 1 ||
      project.meters.first['tick'] != 0 ||
      project.meters.first['numerator'] != 4 ||
      project.meters.first['denominator'] != 4) {
    warn('metersUnsupported', r'$.meters');
  }
  for (final kind in ['skill', 'fever', 'call']) {
    if ((project.markers[kind] as List).isNotEmpty) {
      warn('${kind}Unsupported', '\$.markers.$kind');
    }
  }
  if ((project.data['sourceOrder'] as List? ?? const []).isNotEmpty) {
    warn('sourceOrderNotSerialized', r'$.sourceOrder');
  }
  if (project.lines.any(
    (line) => chartRows(line['points']).any((p) => p['lane'] == 'auto'),
  )) {
    warn('autoGeometryResolved', r'$.lines');
  }
  for (final (i, line) in project.lines.indexed) {
    final points = chartRows(line['points']);
    if (line['kind'] == 'guide' && points.any((p) => p['visible'] == true)) {
      warn('guideJudgementsUnsupported', '\$.lines[$i]');
    }
    if (line['kind'] == 'long') {
      for (var at = 0; at < points.length - 1; at++) {
        if (points[at]['type'] == 'flick') {
          warn('nonEndFlickUnsupported', '\$.lines[$i].points[$at]');
        }
      }
    }
  }
  return result;
}

ChartExportValidation validateChartExport(ChartProject project, String format) {
  final errors = project.validate().where((issue) => !issue.warning).toList();
  if (errors.isNotEmpty) return (errors: errors, warnings: []);
  if (format == 'sus') return susExportDiagnostics(project);
  if (format == 'mmws') return mmwsExportDiagnostics(project);
  final warnings = chartExportWarnings(project, format);
  if (format != 'ss') return (errors: errors, warnings: warnings);
  final document = projectToSs(project),
      score = chartMap(document['score']),
      events = chartMap(score['events']);
  void fail(String code, String path) =>
      errors.add(ChartIssue('ss.target.$code', path));
  for (final kind in ['bpm', 'sig', 'fever', 'call']) {
    if (events[kind] is List && (events[kind] as List).length > 4096) {
      fail('eventBudget', '\$.score.events.$kind');
    }
  }
  for (final (i, point) in (events['bpm'] as List? ?? const []).indexed) {
    final path = '\$.score.events.bpm[$i]';
    if (point is! Map) {
      fail('eventObject', path);
    } else if (point['bpm'] is! num ||
        !(point['bpm'] as num).isFinite ||
        (point['bpm'] as num) <= 0 ||
        (point['bpm'] as num) > 10000) {
      fail('bpm', '$path.bpm');
    }
  }
  for (final (i, point) in (events['sig'] as List? ?? const []).indexed) {
    if (point is! Map ||
        point['sig'] is! List ||
        (point['sig'] as List).length < 2 ||
        (point['sig'] as List)
            .take(2)
            .any((v) => v is! num || !v.isFinite || v <= 0)) {
      fail('signature', '\$.score.events.sig[$i]');
    }
  }
  for (final (i, point) in (events['call'] as List? ?? const []).indexed) {
    if (point is! Map) fail('eventObject', '\$.score.events.call[$i]');
  }
  for (final (i, range) in (events['fever'] as List? ?? const []).indexed) {
    if (range is! List || range.length < 2) {
      fail('fever', '\$.score.events.fever[$i]');
    }
  }
  final queue = <(Object?, String)>[
    for (final (i, note) in (score['notes'] as List).indexed)
      (note, '\$.score.notes[$i]'),
  ];
  final nativeFloat = Float32List(1);
  var count = 0;
  for (var i = 0; i < queue.length && count <= 25000; i++) {
    final (note, path) = queue[i];
    count++;
    if (note is! Map) {
      fail('noteObject', path);
      continue;
    }
    for (final field in ['pos', 'size']) {
      if (note[field] is num) {
        nativeFloat[0] = (note[field] as num).toDouble();
        if (!nativeFloat[0].isFinite) fail('floatGeometry', '$path.$field');
      }
    }
    for (final (field, allowed) in [
      ('type', const ['tap', 'flick', 'trace', 'long', 'guide', 'node']),
      ('dir', const ['up', 'left', 'right', 'down']),
      ('alpha', const ['none', 'in', 'out']),
    ]) {
      if (note[field] is String && !allowed.contains(note[field])) {
        fail('enum', '$path.$field');
      }
    }
    final ease = note['ease'];
    if (ease != null &&
        (ease is List
            ? ease.length != 2 ||
                  ease.any((v) => !const ['linear', 'in', 'out'].contains(v))
            : ease is String &&
                  !const ['linear', 'in', 'out'].contains(ease))) {
      fail('ease', '$path.ease');
    }
    if (note['alpha'] != null &&
        note['alpha'] != '' &&
        note['alpha'] != false &&
        note['alpha'] != 0 &&
        note['alpha'] != 'none') {
      warnings.add(ChartIssue('ss.preview.alphaReserved', '$path.alpha', true));
    }
    if (note['node'] is List) {
      for (final (at, child) in (note['node'] as List).indexed) {
        queue.add((child, '$path.node[$at]'));
      }
    }
  }
  if (count > 25000 || queue.length > 25000) {
    fail('noteBudget', r'$.score.notes');
  }
  return (errors: errors, warnings: warnings);
}
