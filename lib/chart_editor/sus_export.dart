import 'project.dart';

class _MeasureMap {
  _MeasureMap(ChartProject project) {
    var measure = 0, previousTick = 0, length = 1920;
    for (final meter in project.meters) {
      final tick = meter['tick'] as int,
          advance = (tick - previousTick) / length;
      if (advance != advance.roundToDouble()) {
        throw const FormatException('measureBoundary');
      }
      measure += advance.round();
      final next =
          1920 * (meter['numerator'] as num) / (meter['denominator'] as num);
      if (next != next.roundToDouble()) {
        throw const FormatException('measureBoundary');
      }
      length = next.round();
      previousTick = tick;
      segments.add((tick: tick, measure: measure, length: length));
    }
  }
  final segments = <({int tick, int measure, int length})>[];
  ({int measure, int offset, int length}) position(int tick) {
    var segment = segments.first;
    for (final next in segments) {
      if (next.tick > tick) break;
      segment = next;
    }
    final advance = (tick - segment.tick) ~/ segment.length;
    return (
      measure: segment.measure + advance,
      offset: tick - segment.tick - advance * segment.length,
      length: segment.length,
    );
  }
}

({List<ChartIssue> errors, List<ChartIssue> warnings}) susExportDiagnostics(
  ChartProject p,
) {
  final errors = <ChartIssue>[], warnings = <ChartIssue>[];
  void error(String code, String path) =>
      errors.add(ChartIssue('sus.export.$code', path));
  void warn(String code, String path) =>
      warnings.add(ChartIssue('sus.export.$code', path, true));
  try {
    _MeasureMap(p);
  } catch (_) {
    error('measureBoundary', r'$.meters');
  }
  if (p.tempos.map((event) => event['bpm']).toSet().length > 1295) {
    error('bpmLimit', r'$.tempos');
  }
  for (final kind in ['long', 'guide']) {
    final ends = <int>[];
    final lines = p.lines.where((line) => line['kind'] == kind).toList()
      ..sort(
        (a, b) => (chartRows(a['points']).first['tick'] as int).compareTo(
          chartRows(b['points']).first['tick'] as int,
        ),
      );
    for (final line in lines) {
      final points = chartRows(line['points']),
          start = points.first['tick'] as int,
          end = points.last['tick'] as int,
          index = ends.indexWhere((end) => end < start);
      if (index < 0) {
        ends.add(end);
      } else {
        ends[index] = end;
      }
    }
    if (ends.length > 36) error('channelLimit', r'$.lines');
  }
  for (final node in p.nodes) {
    final lane = node.lane * 12 / p.laneBasis + 2,
        width = node.size * 12 / p.laneBasis;
    if (lane != lane.roundToDouble() ||
        width != width.roundToDouble() ||
        lane < 2 ||
        lane >= 14 ||
        width < 0 ||
        width > 35) {
      error('integerLanes', r'$.lines');
      break;
    }
  }
  if (p.lines.any(
    (line) => chartRows(line['points'])
        .take(chartRows(line['points']).length - 1)
        .any(
          (point) =>
              chartMap(point['ease'])['left'] !=
              chartMap(point['ease'])['right'],
        ),
  )) {
    error('edgeEase', r'$.lines');
  }
  if (p.meters.any((meter) => meter['denominator'] != 4)) {
    warn('meterRatioNormalized', r'$.meters');
  }
  final keys = p.singles
      .map((note) => '${note['tick']}:${note['lane']}')
      .toList();
  if (keys.toSet().length < keys.length ||
      p.lines.any(
        (line) =>
            line['kind'] == 'long' &&
            chartRows(line['points']).any(
              (point) => keys.contains('${point['tick']}:${point['lane']}'),
            ),
      )) {
    warn('coincidentNotesMerged', r'$.singles');
  }
  if ((p.data['waypoints'] as List? ?? []).isNotEmpty) {
    warn('waypointsUnsupported', r'$.waypoints');
  }
  if ((p.markers['call'] as List).isNotEmpty) {
    warn('callUnsupported', r'$.markers.call');
  }
  if (p.extensions.isNotEmpty) warn('extensionsUnsupported', r'$.extensions');
  if (p.lines.any(
    (line) => chartRows(line['points']).any((point) => point['lane'] == 'auto'),
  )) {
    warn('autoGeometryResolved', r'$.lines');
  }
  if (p.lines.any(
    (line) =>
        line['kind'] == 'guide' &&
        chartRows(
          line['points'],
        ).any((point) => point['visible'] == true || point['lane'] == 'auto'),
  )) {
    warn('guideJudgementsUnsupported', r'$.lines');
  }
  if (p.lines.any(
    (line) =>
        line['kind'] == 'long' &&
        chartRows(line['points'])
            .take(chartRows(line['points']).length - 1)
            .any((point) => point['type'] == 'flick'),
  )) {
    warn('nonEndFlickUnsupported', r'$.lines');
  }
  if (p.lines.any(
    (line) =>
        (line['critical'] == true ||
            chartRows(line['points']).first['critical'] == true) &&
        chartRows(line['points']).any((point) => point['critical'] != true),
  )) {
    warn('criticalNormalized', r'$.lines');
  }
  if (p.singles.any((note) => note['visible'] != true)) {
    warn('singleVisibilityIgnored', r'$.singles');
  }
  return (errors: errors, warnings: warnings);
}

String _b36(int value) => value.toRadixString(36).toUpperCase();
String _decimal(num value) {
  final text = '$value',
      match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?e([+-]?\d+)$').firstMatch(text);
  if (match == null) return text;
  final digits = match[2]! + (match[3] ?? ''),
      point = match[2]!.length + int.parse(match[4]!);
  return match[1]! +
      (point <= 0
          ? '0.${'0' * (-point)}$digits'
          : point >= digits.length
          ? '$digits${'0' * (point - digits.length)}'
          : '${digits.substring(0, point)}.${digits.substring(point)}');
}

String serializeSus(ChartProject p) {
  p.requireValid();
  final check = susExportDiagnostics(p);
  if (check.errors.isNotEmpty) throw ChartProjectError(check.errors);
  final map = _MeasureMap(p);
  String quote(Object? value) =>
      '"${'$value'.replaceAll(RegExp(r'[\r\n]'), ' ')}"';
  final output = [
    '#REQUEST "ticks_per_beat 480"',
    '#REQUEST "side_lane true"',
    '#LANECOUNT ${p.laneBasis}',
    '#TITLE ${quote(p.meta['title'])}',
    '#ARTIST ${quote(p.meta['artist'])}',
    '#DESIGNER ${quote(p.meta['charter'])}',
    '#DIFFICULTY ${quote(p.meta['difficulty'])}',
    '#PLAYLEVEL ${quote(p.meta['level'])}',
    '#WAVEOFFSET ${_decimal(-p.audioOffset)}',
  ];
  var measureBase = 0;
  String header(int measure, String channel) {
    final base = measure ~/ 1000 * 1000;
    if (base != measureBase) {
      output.add('#MEASUREBS $base');
      measureBase = base;
    }
    return '#${(measure - base).toString().padLeft(3, '0')}$channel';
  }

  for (final meter in map.segments) {
    output.add(
      '${header(meter.measure, '02')}: ${_decimal(meter.length / 480)}',
    );
  }
  final bpms = p.tempos.map((event) => event['bpm'] as num).toSet().toList();
  for (final (i, bpm) in bpms.indexed) {
    output.add('#BPM${_b36(i + 1).padLeft(2, '0')}: ${_decimal(bpm)}');
  }
  final rows =
      <
        String,
        ({
          int measure,
          int length,
          String channel,
          List<Map<int, String>> values,
        })
      >{};
  void add(int tick, String channel, String value) {
    final pos = map.position(tick), key = '${pos.measure}:$channel';
    final row = rows.putIfAbsent(
      key,
      () => (
        measure: pos.measure,
        length: pos.length,
        channel: channel,
        values: [],
      ),
    );
    var values = row.values
        .where((values) => !values.containsKey(pos.offset))
        .firstOrNull;
    if (values == null) {
      values = {};
      row.values.add(values);
    }
    values[pos.offset] = value;
  }

  for (final event in p.tempos) {
    add(
      event['tick'] as int,
      '08',
      _b36(bpms.indexOf(event['bpm'] as num) + 1).padLeft(2, '0'),
    );
  }
  void modifier(
    int tick,
    int lane,
    int width,
    int type, [
    String channel = '1',
  ]) => add(tick, '$channel${_b36(lane)}', '${_b36(type)}${_b36(width)}');
  void direction(int tick, int lane, int width, Object? value) => modifier(
    tick,
    lane,
    width,
    value == 'left'
        ? 3
        : value == 'right'
        ? 4
        : 1,
    '5',
  );
  for (final note in p.singles) {
    final lane = ((note['lane'] as num) * 12 / p.laneBasis + 2).round(),
        width = ((note['size'] as num) * 12 / p.laneBasis).round();
    modifier(
      note['tick'] as int,
      lane,
      width,
      note['type'] == 'trace'
          ? note['critical'] == true
                ? 6
                : 5
          : note['critical'] == true
          ? 2
          : 1,
    );
    if (note['type'] == 'flick') {
      direction(note['tick'] as int, lane, width, note['direction']);
    }
  }
  final channels = {'long': List.filled(36, -1), 'guide': List.filled(36, -1)},
      lines = p.lines
        ..sort(
          (a, b) => (chartRows(a['points']).first['tick'] as int).compareTo(
            chartRows(b['points']).first['tick'] as int,
          ),
        );
  for (final line in lines) {
    final points = chartRows(line['points']),
        pool = channels[line['kind']]!,
        channel = pool.indexWhere((end) => end < (points.first['tick'] as int));
    if (channel < 0) throw const FormatException('channelLimit');
    pool[channel] = points.last['tick'] as int;
    for (final (index, point) in points.indexed) {
      final shape = resolveChartPoint(points, index),
          lane = (shape.$1 * 12 / p.laneBasis + 2).round(),
          width = (shape.$2 * 12 / p.laneBasis).round(),
          endpoint = index == 0 || index == points.length - 1,
          tick = point['tick'] as int;
      add(
        tick,
        '${line['kind'] == 'long' ? '3' : '9'}${_b36(lane)}${_b36(channel)}',
        '${index == 0
            ? '1'
            : index == points.length - 1
            ? '2'
            : point['visible'] == true
            ? '3'
            : '5'}${_b36(width)}',
      );
      if (endpoint && (point['visible'] != true || line['kind'] == 'guide')) {
        modifier(
          tick,
          lane,
          width,
          point['critical'] == true || line['critical'] == true ? 8 : 7,
        );
      } else if (line['kind'] == 'long' &&
          (point['critical'] == true || point['type'] == 'trace')) {
        modifier(
          tick,
          lane,
          width,
          point['type'] == 'trace'
              ? point['critical'] == true
                    ? 6
                    : 5
              : 2,
        );
      }
      if (line['kind'] == 'long' &&
          index == points.length - 1 &&
          point['type'] == 'flick') {
        direction(tick, lane, width, point['direction']);
      }
      if (index < points.length - 1 &&
          chartMap(point['ease'])['left'] != 'linear') {
        modifier(
          tick,
          lane,
          width,
          chartMap(point['ease'])['left'] == 'in' ? 2 : 5,
          '5',
        );
      }
    }
  }
  for (final tick in p.markers['skill'] as List) {
    modifier(tick as int, 0, 1, 4);
  }
  for (final pair in p.markers['fever'] as List) {
    modifier((pair as List)[0] as int, 15, 1, 1);
    modifier(pair[1] as int, 15, 1, 2);
  }
  var outputSize = output.fold(0, (sum, line) => sum + line.length + 1);
  final ordered = rows.values.toList()
    ..sort((a, b) => a.measure.compareTo(b.measure));
  for (final row in ordered) {
    for (final values in row.values) {
      final unit = values.keys.fold<int>(row.length, (a, b) => a.gcd(b)),
          cells = row.length ~/ unit;
      outputSize += cells * 2 + 24;
      if (outputSize > 2 * 1024 * 1024) throw const FormatException('sus_size');
      final tokens = List.filled(cells, '00');
      for (final entry in values.entries) {
        tokens[entry.key ~/ unit] = entry.value;
      }
      output.add('${header(row.measure, row.channel)}: ${tokens.join()}');
    }
  }
  if (p.timeScales.isNotEmpty) {
    output.add(
      '#TIL00: "${p.timeScales.map((event) {
        final pos = map.position(event['tick'] as int);
        return "${pos.measure}'${pos.offset}:${_decimal(event['scale'] as num)}";
      }).join(',')}"',
    );
    output.add('#HISPEED 00');
  }
  return '${output.join('\n')}\n';
}
