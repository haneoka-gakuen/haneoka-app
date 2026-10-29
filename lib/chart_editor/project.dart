import 'dart:convert';
import 'dart:math' as math;

typedef ChartMap = Map<String, Object?>;

ChartMap chartMap(Object? value) => (value as Map).cast<String, Object?>();
List<ChartMap> chartRows(Object? value) =>
    (value as List).map(chartMap).toList();
ChartMap cloneChartMap(Map value) => chartMap(jsonDecode(jsonEncode(value)));
num chartNumber(Object? value, [num fallback = 0]) =>
    value is num && value.isFinite ? value : fallback;
bool chartEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((i) => chartEqual(a[i], b[i]));
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && chartEqual(a[key], b[key]));
  }
  return a == b;
}

final _random = math.Random.secure();
String chartId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_random.nextInt(1 << 32).toRadixString(36)}';

String chartUuid() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final text = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${text.substring(0, 8)}-${text.substring(8, 12)}-${text.substring(12, 16)}-${text.substring(16, 20)}-${text.substring(20)}';
}

/// JSON contract shared with packages/chart-editor/src/model.ts in Haneoka Web.
/// Source records and authored automatic lanes survive native edits and saves.
class ChartProject {
  ChartProject(Map value) : data = cloneChartMap(value);
  factory ChartProject.empty([ChartMap meta = const {}]) => ChartProject({
    'version': 1,
    'resolution': 480,
    'laneBasis': 24,
    'meta': {
      'title': '',
      'artist': '',
      'charter': '',
      'difficulty': '',
      'level': '',
      ...meta,
    },
    'audioOffset': 0,
    'tempos': [
      {'id': 'tempo-0', 'tick': 0, 'bpm': 120},
    ],
    'meters': [
      {'id': 'meter-0', 'tick': 0, 'numerator': 4, 'denominator': 4},
    ],
    'timeScales': <Object?>[],
    'singles': <Object?>[],
    'lines': <Object?>[],
    'markers': {
      'skill': <Object?>[],
      'fever': <Object?>[],
      'call': <Object?>[],
    },
    'extensions': <String, Object?>{},
  });
  final ChartMap data;
  ChartMap get meta => chartMap(data['meta']);
  ChartMap get extensions => chartMap(data['extensions']);
  ChartMap get markers => chartMap(data['markers']);
  double get laneBasis => (data['laneBasis'] as num).toDouble();
  double get audioOffset => (data['audioOffset'] as num).toDouble();
  List<ChartMap> get singles => chartRows(data['singles']);
  List<ChartMap> get lines => chartRows(data['lines']);
  List<ChartMap> get tempos => chartRows(data['tempos']);
  List<ChartMap> get meters => chartRows(data['meters']);
  List<ChartMap> get timeScales => chartRows(data['timeScales']);
  ChartProject copy() => ChartProject(data);
  TempoMap get tempoMap => TempoMap(tempos, audioOffset: audioOffset);
  int get lastTick => [
    0,
    for (final name in ['tempos', 'meters', 'timeScales', 'singles'])
      ...chartRows(data[name]).map((row) => row['tick'] as int),
    for (final line in lines)
      ...chartRows(line['points']).map((row) => row['tick'] as int),
    ...chartRows(data['waypoints'] ?? []).map((row) => row['tick'] as int),
    ...(markers['skill'] as List).cast<int>(),
    for (final pair in markers['fever'] as List) ...(pair as List).cast<int>(),
    ...chartRows(markers['call']).map((row) => row['tick'] as int),
  ].reduce(math.max);

  void sort() {
    int byTick(ChartMap a, ChartMap b) {
      final order = (a['tick'] as int).compareTo(b['tick'] as int);
      return order != 0 ? order : '${a['id']}'.compareTo('${b['id']}');
    }

    for (final key in ['tempos', 'meters', 'timeScales', 'singles']) {
      data[key] = chartRows(data[key])..sort(byTick);
    }
    for (final line in lines) {
      line['points'] = stableChartSort(
        chartRows(line['points']),
        (a, b) => (a['tick'] as int).compareTo(b['tick'] as int),
      );
    }
    data['lines'] = lines
      ..sort((a, b) {
        final order = (chartRows(a['points']).first['tick'] as int).compareTo(
          chartRows(b['points']).first['tick'] as int,
        );
        return order != 0 ? order : '${a['id']}'.compareTo('${b['id']}');
      });
  }

  List<ChartIssue> validate() {
    final issues = <ChartIssue>[];
    void issue(String code, String path, [bool warning = false]) =>
        issues.add(ChartIssue(code, path, warning));
    bool finite(Object? value) => value is num && value.isFinite;
    bool tick(Object? value) =>
        value is int && value >= 0 && value <= 9007199254740991;
    if (data['version'] != 1) issue('project.version', r'$.version');
    if (data['resolution'] != 480) issue('project.resolution', r'$.resolution');
    if (!finite(data['laneBasis']) || chartNumber(data['laneBasis']) <= 0) {
      issue('project.laneBasis', r'$.laneBasis');
    }
    if (!finite(data['audioOffset'])) {
      issue('project.audioOffset', r'$.audioOffset');
    }
    final rawMeta = data['meta'];
    if (rawMeta is! Map) {
      issue('meta.type', r'$.meta');
    } else {
      for (final key in ['title', 'artist', 'charter', 'difficulty', 'level']) {
        if (rawMeta[key] is! String) issue('meta.field', '\$.meta.$key');
      }
      if (rawMeta.containsKey('source') && rawMeta['source'] is! String) {
        issue('meta.source', r'$.meta.source');
      }
      final tags = rawMeta['tags'];
      if (tags != null && (tags is! List || tags.any((v) => v is! String))) {
        issue('meta.tags', r'$.meta.tags');
      }
      if (rawMeta['extra'] != null && rawMeta['extra'] is! Map) {
        issue('meta.extra', r'$.meta.extra');
      }
    }
    final ids = <String>{};
    void identity(Map row, String path) {
      final id = row['id'];
      if (id is! String || id.trim().isEmpty) {
        issue('id.invalid', '$path.id');
      } else if (!ids.add(id)) {
        issue('id.duplicate', '$path.id');
      }
      if (!tick(row['tick'])) issue('tick.invalid', '$path.tick');
    }

    for (final key in ['tempos', 'meters', 'timeScales']) {
      final rows = data[key];
      if (rows is! List || (key != 'timeScales' && rows.isEmpty)) {
        issue('$key.type', '\$.$key');
        continue;
      }
      final ticks = <int>{};
      var previous = -1;
      for (final (index, row) in rows.indexed) {
        final path = '\$.$key[$index]';
        if (row is! Map) {
          issue('$key.type', path);
          continue;
        }
        identity(row, path);
        if (row['tick'] case final int t) {
          if (!ticks.add(t)) issue('$key.duplicate', '$path.tick');
          if (t < previous) issue('$key.unsorted', path, true);
          previous = t;
        }
        if (key == 'tempos' || key == 'timeScales') {
          final field = key == 'tempos' ? 'bpm' : 'scale';
          if (!finite(row[field]) || chartNumber(row[field]) <= 0) {
            issue('$key.$field', '$path.$field');
          }
        } else {
          final n = row['numerator'], d = row['denominator'];
          if (n is! int || n <= 0) issue('meter.numerator', '$path.numerator');
          if (d is! int || d <= 0 || (d & (d - 1)) != 0) {
            issue('meter.denominator', '$path.denominator');
          }
        }
      }
      if (key != 'timeScales' && !ticks.contains(0)) {
        issue('$key.origin', '\$.$key', key == 'meters');
      }
    }
    void note(Object? value, String path, bool auto) {
      if (value is! Map) {
        issue('note.type', path);
        return;
      }
      identity(value, path);
      final lane = value['lane'], size = value['size'];
      if (!(auto && lane == 'auto') && !finite(lane)) {
        issue('lane.invalid', '$path.lane');
      }
      if (!finite(size) || chartNumber(size) < 0) {
        issue('size.invalid', '$path.size');
      }
      if (lane is num &&
          size is num &&
          (lane < 0 || lane + size > chartNumber(data['laneBasis'], 24))) {
        issue('lane.authoredOutsideStage', path, true);
      }
      if (!const {'tap', 'flick', 'trace'}.contains(value['type'])) {
        issue('note.noteType', '$path.type');
      }
      if (value['critical'] is! bool) issue('note.critical', '$path.critical');
      if (value['visible'] is! bool) issue('note.visible', '$path.visible');
      if (!const {'none', 'left', 'up', 'right'}.contains(value['direction'])) {
        issue('note.direction', '$path.direction');
      } else if (value['type'] == 'tap' && value['direction'] != 'none') {
        issue('note.tapDirection', '$path.direction');
      }
    }

    final rawSingles = data['singles'];
    if (rawSingles is! List) {
      issue('singles.type', r'$.singles');
    } else {
      for (final (i, value) in rawSingles.indexed) {
        note(value, '\$.singles[$i]', false);
      }
    }
    final rawLines = data['lines'];
    if (rawLines is! List) {
      issue('lines.type', r'$.lines');
    } else {
      for (final (i, line) in rawLines.indexed) {
        final path = '\$.lines[$i]';
        if (line is! Map) {
          issue('line.type', path);
          continue;
        }
        // Connector IDs share the note/event namespace but have no own tick.
        final id = line['id'];
        if (id is! String || id.trim().isEmpty) {
          issue('id.invalid', '$path.id');
        } else if (!ids.add(id)) {
          issue('id.duplicate', '$path.id');
        }
        if (!const {'long', 'guide'}.contains(line['kind'])) {
          issue('line.kind', '$path.kind');
        }
        if (line['critical'] != null && line['critical'] is! bool) {
          issue('line.critical', '$path.critical');
        }
        final points = line['points'];
        if (points is! List || points.length < 2) {
          issue('line.broken', '$path.points');
          continue;
        }
        var previous = -1;
        for (final (at, point) in points.indexed) {
          final p = '$path.points[$at]';
          note(point, p, true);
          if (point is! Map) continue;
          final ease = point['ease'];
          if (ease is! Map ||
              !const {'linear', 'in', 'out'}.contains(ease['left']) ||
              !const {'linear', 'in', 'out'}.contains(ease['right'])) {
            issue('line.ease', '$p.ease');
          }
          if (point.containsKey('autoSize') &&
              (point['autoSize'] is! bool || point['lane'] != 'auto')) {
            issue('line.autoSize', '$p.autoSize');
          }
          if (point.containsKey('resolvedLane') &&
              !finite(point['resolvedLane'])) {
            issue('line.resolvedLane', '$p.resolvedLane');
          }
          if (point.containsKey('resolvedSize') &&
              (!finite(point['resolvedSize']) ||
                  chartNumber(point['resolvedSize']) < 0)) {
            issue('line.resolvedSize', '$p.resolvedSize');
          }
          if (point['tick'] case final int t) {
            if (t < previous) issue('line.order', '$p.tick');
            if (t == previous) issue('line.zeroDuration', '$p.tick', true);
            previous = t;
          }
        }
      }
    }
    final marker = data['markers'];
    if (marker is! Map) {
      issue('markers.type', r'$.markers');
    } else {
      final skill = marker['skill'],
          fever = marker['fever'],
          call = marker['call'];
      if (skill is! List || skill.any((v) => !tick(v))) {
        issue('markers.skill', r'$.markers.skill');
      }
      if (fever is! List ||
          fever.any(
            (v) => v is! List || v.length != 2 || v.any((t) => !tick(t)),
          )) {
        issue('markers.fever', r'$.markers.fever');
      }
      if (call is! List ||
          call.any(
            (v) =>
                v is! Map ||
                !tick(v['tick']) ||
                v['timing'] is! List ||
                (v['timing'] as List).any((t) => !finite(t)),
          )) {
        issue('markers.call', r'$.markers.call');
      }
    }
    if (data['extensions'] is! Map) issue('extensions.type', r'$.extensions');
    final order = data['sourceOrder'];
    if (order != null && (order is! List || order.any((v) => v is! String))) {
      issue('sourceOrder.type', r'$.sourceOrder');
    }
    try {
      jsonEncode(data);
    } on JsonUnsupportedObjectError {
      issue('extensions.json', r'$');
    }
    return issues;
  }

  void requireValid() {
    final errors = validate().where((issue) => !issue.warning).toList();
    if (errors.isNotEmpty) throw ChartProjectError(errors);
  }

  Iterable<ChartNode> get nodes sync* {
    for (final note in singles) {
      yield ChartNode(
        note,
        lane: (note['lane'] as num).toDouble(),
        size: (note['size'] as num).toDouble(),
      );
    }
    for (final line in lines) {
      final points = chartRows(line['points']);
      final shapes = resolveChartPoints(points);
      for (final (index, point) in points.indexed) {
        final shape = shapes[index];
        yield ChartNode(
          point,
          lane: shape.$1,
          size: shape.$2,
          line: line,
          pointIndex: index,
          pointCount: points.length,
          interior: index > 0 && index < points.length - 1,
        );
      }
    }
  }
}

class ChartIssue {
  const ChartIssue(this.code, this.path, [this.warning = false]);
  final String code, path;
  final bool warning;
  ChartMap toJson() => {
    'code': code,
    'path': path,
    'severity': warning ? 'warning' : 'error',
  };
}

class ChartProjectError implements Exception {
  ChartProjectError(this.issues);
  final List<ChartIssue> issues;
  @override
  String toString() => issues.map((e) => '${e.path}: ${e.code}').join('; ');
}

class ChartNode {
  const ChartNode(
    this.note, {
    required this.lane,
    required this.size,
    this.line,
    this.interior = false,
    this.pointIndex,
    this.pointCount,
  });
  final ChartMap note;
  final ChartMap? line;
  final double lane, size;
  final bool interior;
  final int? pointIndex, pointCount;
  String get id => note['id'] as String;
  int get tick => note['tick'] as int;
}

List<T> stableChartSort<T>(List<T> values, int Function(T, T) compare) {
  final indexed = values.indexed.toList()
    ..sort((a, b) {
      final order = compare(a.$2, b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  return indexed.map((v) => v.$2).toList();
}

double chartEase(Object? ease, double t) => switch (ease) {
  'in' => t * t,
  'out' => (2 - t) * t,
  _ => t,
};
(double, double) resolveChartPoint(List<ChartMap> points, int index) {
  final point = points[index];
  if (point['lane'] is num) {
    return (
      (point['lane'] as num).toDouble(),
      (point['size'] as num).toDouble(),
    );
  }
  var l = index - 1, r = index + 1;
  while (l >= 0 && points[l]['lane'] is! num) {
    l--;
  }
  while (r < points.length && points[r]['lane'] is! num) {
    r++;
  }
  return _resolveChartPoint(points, index, l, r);
}

List<(double, double)> resolveChartPoints(List<ChartMap> points) {
  final left = List<int>.filled(points.length, -1),
      right = List<int>.filled(points.length, points.length);
  var previous = -1, next = points.length;
  for (var i = 0; i < points.length; i++) {
    left[i] = previous;
    if (points[i]['lane'] is num) previous = i;
  }
  for (var i = points.length - 1; i >= 0; i--) {
    right[i] = next;
    if (points[i]['lane'] is num) next = i;
  }
  return [
    for (var i = 0; i < points.length; i++)
      points[i]['lane'] is num
          ? (
              (points[i]['lane'] as num).toDouble(),
              (points[i]['size'] as num).toDouble(),
            )
          : _resolveChartPoint(points, i, left[i], right[i]),
  ];
}

(double, double) _resolveChartPoint(
  List<ChartMap> points,
  int index,
  int l,
  int r,
) {
  final point = points[index];
  if (l < 0 && r >= points.length) {
    return (
      chartNumber(point['resolvedLane']).toDouble(),
      chartNumber(point['resolvedSize'], chartNumber(point['size'])).toDouble(),
    );
  }
  if (l < 0 || r >= points.length) {
    final neighbour = points[l < 0 ? r : l];
    return (
      (neighbour['lane'] as num).toDouble(),
      (point['autoSize'] == true
              ? neighbour['size'] as num
              : point['size'] as num)
          .toDouble(),
    );
  }
  final a = points[l], b = points[r];
  final duration = (b['tick'] as int) - (a['tick'] as int);
  final t = duration == 0
      ? 0.0
      : (((point['tick'] as int) - (a['tick'] as int)) / duration).clamp(
          0.0,
          1.0,
        );
  final ease = chartMap(a['ease']);
  final left = (a['lane'] as num).toDouble(),
      right = (b['lane'] as num).toDouble();
  final lane = left + (right - left) * chartEase(ease['left'], t);
  final edge =
      left +
      (a['size'] as num) +
      (right + (b['size'] as num) - left - (a['size'] as num)) *
          chartEase(ease['right'], t);
  return (lane, edge - lane);
}

class TempoMap {
  TempoMap(List<ChartMap> tempos, {this.audioOffset = 0}) {
    final sorted = [...tempos]
      ..sort((a, b) => (a['tick'] as int).compareTo(b['tick'] as int));
    var seconds = audioOffset;
    for (final (i, tempo) in sorted.indexed) {
      final tick = tempo['tick'] as int, bpm = (tempo['bpm'] as num).toDouble();
      if (i == 0 && tick != 0 ||
          bpm <= 0 ||
          !bpm.isFinite ||
          i > 0 && tick <= _segments.last.$1) {
        throw const FormatException('tempo');
      }
      if (i > 0) {
        seconds += (tick - _segments.last.$1) / 480 * 60 / _segments.last.$3;
      }
      _segments.add((tick, seconds, bpm));
    }
    if (_segments.isEmpty) throw const FormatException('tempo');
  }
  final double audioOffset;
  final _segments = <(int, double, double)>[];
  (int, double, double) _at(num value, bool seconds) {
    var low = 0, high = _segments.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if ((seconds ? _segments[mid].$2 : _segments[mid].$1) <= value) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return _segments[math.max(0, low - 1)];
  }

  double secondsAt(num tick) {
    final s = _at(tick, false);
    return s.$2 + (tick - s.$1) / 480 * 60 / s.$3;
  }

  double tickAt(num seconds) {
    final s = _at(seconds, true);
    return s.$1 + (seconds - s.$2) * s.$3 * 480 / 60;
  }

  double bpmAt(num tick) => _at(tick, false).$3;
}

int snapChartTick(num tick, int division, {String mode = 'nearest'}) {
  final units = tick * division / 480;
  final snapped = switch (mode) {
    'floor' => units.floor(),
    'ceil' => units.ceil(),
    _ => (units + .5).floor(),
  };
  return (snapped * 480 / division + .5).floor();
}

/// Gesture updates share one undo entry; revisions remain monotonic through undo.
class ChartHistory {
  ChartHistory(ChartProject initial, {this.capacity = 50})
    : _present = initial.copy();
  final int capacity;
  ChartProject _present;
  final _undo = <ChartProject>[], _redo = <ChartProject>[];
  String? _merge;
  int revision = 0;
  ChartProject get value => _present.copy();
  ChartProject get snapshot => _present;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool update(void Function(ChartProject) edit, {String? mergeKey}) {
    final next = value;
    edit(next);
    next.requireValid();
    if (chartEqual(next.data, _present.data)) return false;
    if (mergeKey == null || mergeKey != _merge || _redo.isNotEmpty) {
      _undo.add(_present);
      if (_undo.length > capacity) _undo.removeAt(0);
    }
    _present = next;
    _redo.clear();
    _merge = mergeKey;
    revision++;
    return true;
  }

  void endMerge() => _merge = null;
  void undo() {
    if (!canUndo) return;
    _redo.add(_present);
    _present = _undo.removeLast();
    _merge = null;
    revision++;
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_present);
    _present = _redo.removeLast();
    _merge = null;
    revision++;
  }

  void reset(ChartProject value) {
    value.requireValid();
    _present = value.copy();
    _undo.clear();
    _redo.clear();
    _merge = null;
    revision++;
  }
}
