import 'dart:convert';
import 'dart:typed_data';

import 'editing.dart';
import 'formats.dart';
import 'project.dart';

class _Reader {
  _Reader(this.bytes) : view = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData view;
  int position = 0;
  void ensure(int length) {
    if (position + length > bytes.length) {
      throw const FormatException('mmws_invalid');
    }
  }

  int u16() {
    ensure(2);
    final value = view.getUint16(position, Endian.little);
    position += 2;
    return value;
  }

  int u32() {
    ensure(4);
    final value = view.getUint32(position, Endian.little);
    position += 4;
    return value;
  }

  double f32() {
    ensure(4);
    final value = view.getFloat32(position, Endian.little);
    position += 4;
    if (!value.isFinite) throw const FormatException('mmws_invalid');
    return value;
  }

  String text() {
    final end = bytes.indexOf(0, position);
    if (end < 0) throw const FormatException('mmws_invalid');
    final value = utf8.decode(bytes.sublist(position, end));
    position = end + 1;
    return value;
  }

  void seek(int offset) {
    if (offset < 0 || offset >= bytes.length) {
      throw const FormatException('mmws_invalid');
    }
    position = offset;
  }

  int count() {
    final value = u32();
    if (value > bytes.length - position) {
      throw const FormatException('mmws_invalid');
    }
    return value;
  }
}

bool isMmws(Uint8List bytes) =>
    RegExp(r'^(?:MMWS|CCMMWS|UCMMWS)\x00')
        .hasMatch(latin1.decode(bytes.take(8).toList()));
const _ease = ['linear', 'in', 'out'],
    _directions = ['none', 'up', 'left', 'right'];
ChartImport importMmws(Uint8List bytes) {
  final r = _Reader(bytes);
  final signature = r.text();
  var base = 4, cc = 0, uc = 0;
  if (signature == 'MMWS') {
    base = r.u32();
  } else if (signature == 'CCMMWS') {
    base = r.u16();
    cc = r.u16();
    if (cc == 0) cc = 1;
  } else if (signature == 'UCMMWS') {
    uc = r.u32();
    cc = 6;
  } else {
    throw const FormatException('mmws_invalid');
  }
  if (base < 1 || base > 4 || cc > 6 || uc > 4) {
    throw const FormatException('mmws_version');
  }
  final extended = uc >= 3,
      addresses = base >= 3,
      offsets = base >= 3
          ? [
              for (
                var i = 0;
                i <
                    (cc >= 5
                        ? 7
                        : cc >= 4
                        ? 6
                        : cc >= 1
                        ? 5
                        : 4);
                i++
              )
                r.u32(),
            ]
          : <int>[];
  if (addresses) r.seek(offsets[0]);
  final title = r.text(),
      charter = r.text(),
      artist = r.text(),
      musicFile = r.text(),
      musicOffset = r.f32(),
      jacketFile = base >= 2 ? r.text() : '',
      laneExtension = cc >= 1 ? r.u32() : 0;
  if (extended) {
    r.u32();
    r.u32();
  }
  final p = ChartProject.empty({
    'title': title,
    'charter': charter,
    'artist': artist,
    'source': 'mmws',
  });
  p.data['audioOffset'] = -musicOffset / 1000;
  p.extensions['mmws'] = {
    'signature': signature,
    'base': base,
    'cc': cc,
    'uc': uc,
    'musicFile': musicFile,
    'jacketFile': jacketFile,
    'laneExtension': laneExtension,
  };
  final collections = chartCollections(p),
      layers = collections['layers'] as List,
      groups = collections['groups'] as List,
      members = chartMap(collections['members']),
      forced = <double>[];
  if (cc >= 4) {
    r.seek(offsets[5]);
    final count = r.count();
    for (var i = 0; i < count; i++) {
      final name = r.text(), speed = uc >= 4 ? r.f32() : 0.0;
      layers.add({'id': 'mmws-layer-$i', 'name': name, 'visible': true});
      forced.add(speed);
      if (speed > 0) {
        groups.add({
          'id': 'mmws-speed-group-$i',
          'name': name,
          'forceNoteSpeed': speed,
        });
      }
    }
  } else {
    layers.add({'id': 'mmws-layer-0', 'name': '', 'visible': true});
  }
  void assign(String id, int layer) {
    if (layer < 0 || layer >= layers.length) {
      throw const FormatException('mmws_invalid');
    }
    members[id] = {
      'layerId': (layers[layer] as Map)['id'],
      if (forced.elementAtOrNull(layer) != null && forced[layer] > 0)
        'groupId': 'mmws-speed-group-$layer',
    };
  }

  if (addresses) r.seek(offsets[1]);
  final signatures = [
    for (var i = 0, n = r.count(); i < n; i++)
      {'measure': r.u32(), 'numerator': r.u32(), 'denominator': r.u32()},
  ]..sort((a, b) => a['measure']!.compareTo(b['measure']!));
  var measure = 0, tick = 0.0, length = 1920.0;
  p.data['meters'] = [
    for (final (i, meter) in signatures.indexed)
      (() {
        tick += (meter['measure']! - measure) * length;
        measure = meter['measure']!;
        length = 1920 * meter['numerator']! / meter['denominator']!;
        return {
          'id': 'mmws-meter-$i',
          'tick': tick.round(),
          'numerator': meter['numerator'],
          'denominator': meter['denominator'],
        };
      })(),
  ];
  p.data['tempos'] = [
    for (var i = 0, n = r.count(); i < n; i++)
      {'id': 'mmws-tempo-$i', 'tick': r.u32(), 'bpm': r.f32()},
  ];
  if (base >= 3) {
    final timelines = <int, Map<int, double>>{};
    for (var i = 0, n = r.count(); i < n; i++) {
      final tick = r.u32(),
          scale = r.f32(),
          layer = cc >= 4 ? r.u32() : 0,
          skip = uc >= 2 ? r.f32() : 0,
          ease = uc >= 2 ? r.u16() : 0,
          hidden = uc >= 2 ? r.u16() : 0;
      if (scale <= 0 || skip != 0 || ease != 0 || hidden != 0) {
        throw const FormatException('mmws_unsupported');
      }
      (timelines[layer] ??= {})[tick] = scale;
    }
    final speeds = timelines[0] ?? {0: 1.0};
    String normalized(Map<int, double> timeline) {
      final rows = {0: 1.0, ...timeline}.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return jsonEncode([
        for (var i = 0; i < rows.length; i++)
          if (i == 0 || rows[i].value != rows[i - 1].value)
            [rows[i].key, rows[i].value],
      ]);
    }

    if (timelines.values.any(
      (timeline) => normalized(timeline) != normalized(speeds),
    )) {
      throw const FormatException('mmws_unsupported');
    }
    p.data['timeScales'] = [
      for (final (i, entry) in speeds.entries.indexed)
        {'id': 'mmws-speed-$i', 'tick': entry.key, 'scale': entry.value},
    ];
  }
  if (base >= 2) {
    final skills = p.markers['skill'] as List;
    for (var i = 0, n = r.count(); i < n; i++) {
      skills.add(r.u32());
      if (extended) {
        final effect = r.u32();
        r.u32();
        if (effect != 0) throw const FormatException('mmws_unsupported');
      }
    }
    final start = r.u32(), end = r.u32();
    if (start != 0xffffffff && end != 0xffffffff) {
      (p.markers['fever'] as List).add([start, end]);
    }
  }
  var noteIndex = 0;
  ChartMap note(String role) {
    final tick = r.u32(),
        lane = cc >= 6 ? r.f32() : r.u32().toSigned(32).toDouble(),
        width = cc >= 6 ? r.f32() : r.u32().toDouble(),
        sound = extended ? r.u32() : 0,
        layer = cc >= 4 ? r.u32() : 0;
    var flick = 0, flags = 0, type = 0, ease = 0;
    if (extended) {
      type = r.u32();
      flags = r.u32();
      flick = r.u32();
      ease = r.u32();
      if (r.f32() != 1) throw const FormatException('mmws_unsupported');
    } else {
      if (role == 'single' || role == 'tail') flick = r.u32();
      flags = r.u32();
    }
    if (sound != 0 || type > 1 || flags & 4 != 0 || flick > 3 || ease > 2) {
      throw const FormatException('mmws_unsupported');
    }
    return {
      'id': 'mmws-note-${noteIndex++}',
      'tick': tick,
      'lane': lane * 2,
      'size': width * 2,
      'type': flags & 2 != 0
          ? 'trace'
          : flick != 0
          ? 'flick'
          : 'tap',
      'direction': _directions[flick],
      'critical': flags & 1 != 0,
      'visible': flags & 16 == 0,
      'layer': layer,
      'flags': flags,
      'easeValue': ease,
    };
  }

  ChartMap clean(ChartMap raw) => {...raw}
    ..remove('layer')
    ..remove('flags')
    ..remove('easeValue');
  ChartMap point(ChartMap raw, int ease) {
    if (ease > 2) throw const FormatException('mmws_unsupported');
    return {
      ...clean(raw),
      'ease': {'left': _ease[ease], 'right': _ease[ease]},
    };
  }

  if (addresses) r.seek(offsets[2]);
  for (var i = 0, n = r.count(); i < n; i++) {
    final raw = note('single');
    (p.data['singles'] as List).add(clean(raw));
    assign('${raw['id']}', raw['layer'] as int);
  }
  if (addresses) r.seek(offsets[3]);
  for (var i = 0, n = r.count(); i < n; i++) {
    final flags = base >= 4 ? r.u32() : 0;
    if (flags & (extended ? 2 : 8) != 0) {
      throw const FormatException('mmws_unsupported');
    }
    final head = note('head'),
        startEase = extended ? head['easeValue'] as int : r.u32(),
        fade = cc >= 2 ? r.u32() : 0,
        color = cc >= 3
            ? r.u32()
            : head['critical'] == true
            ? 4
            : 2,
        holdLayer = extended ? r.u32() : 0;
    if (![0, 4].contains(fade) || ![2, 4].contains(color) || holdLayer > 1) {
      throw const FormatException('mmws_unsupported');
    }
    final kind = flags & 4 != 0 ? 'guide' : 'long',
        line = <String, Object?>{
          'id': 'mmws-line-$i',
          'kind': kind,
          'critical': extended ? flags & 1 != 0 : head['critical'],
          'points': <ChartMap>[],
        };
    final points = line['points'] as List<ChartMap>,
        first = point(head, startEase);
    if (!extended) first['visible'] = flags & 1 == 0 && kind != 'guide';
    points.add(first);
    assign('${line['id']}', head['layer'] as int);
    assign('${first['id']}', head['layer'] as int);
    for (var j = 0, count = r.count(); j < count; j++) {
      final raw = note('mid'),
          mode = extended
              ? (raw['flags'] as int) & 8 != 0
                    ? 2
                    : (raw['flags'] as int) & 16 != 0
                    ? 1
                    : 0
              : r.u32(),
          ease = extended ? raw['easeValue'] as int : r.u32(),
          mid = point(raw, ease);
      mid['visible'] = mode == 0;
      if (mode == 2) mid.addAll({'lane': 'auto', 'autoSize': true, 'size': 0});
      points.add(mid);
      assign('${mid['id']}', raw['layer'] as int);
    }
    final tail = note('tail'), last = point(tail, tail['easeValue'] as int);
    if (!extended) last['visible'] = flags & 2 == 0 && kind != 'guide';
    points.add(last);
    assign('${last['id']}', tail['layer'] as int);
    if (extended && r.count() != 0) {
      throw const FormatException('mmws_unsupported');
    }
    (p.data['lines'] as List).add(line);
  }
  if (cc >= 1) {
    r.seek(offsets[4]);
    if (r.count() != 0) throw const FormatException('mmws_unsupported');
  }
  if (cc >= 5) {
    r.seek(offsets[6]);
    p.data['waypoints'] = [
      for (var i = 0, n = r.count(); i < n; i++)
        {'id': 'mmws-waypoint-$i', 'name': r.text(), 'tick': r.u32()},
    ];
  }
  collections['members'] = members;
  p.extensions['authoringCollections'] = collections;
  return finishChartImport('mmws', p, []);
}

class _Writer {
  final bytes = BytesBuilder(copy: false);
  int get position => bytes.length;
  void u16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    bytes.add(data.buffer.asUint8List());
  }

  void u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    bytes.add(data.buffer.asUint8List());
  }

  void f32(num value) {
    final data = ByteData(4)..setFloat32(0, value.toDouble(), Endian.little);
    bytes.add(data.buffer.asUint8List());
  }

  void text(String value) {
    if (value.contains('\x00')) throw const FormatException('mmws_invalid');
    bytes.add(utf8.encode(value));
    bytes.add([0]);
  }
}

Uint8List serializeMmws(ChartProject p) {
  p.requireValid();
  if ((p.markers['fever'] as List).length > 1) {
    throw const FormatException('singleFever');
  }
  final w = _Writer(),
      collections = chartCollections(p),
      layers = chartRows(collections['layers']),
      members = chartMap(collections['members']);
  final ids = [
    for (final note in p.singles) note['id'],
    for (final line in p.lines)
      for (final point in chartRows(line['points'])) point['id'],
  ];
  if (layers.isEmpty ||
      ids.any((id) => (members[id] as Map?)?['layerId'] == null)) {
    layers.insert(0, {'id': '', 'name': '', 'visible': true});
  }
  int layerFor(String id) {
    final index = layers.indexWhere(
      (layer) => layer['id'] == (members[id] as Map?)?['layerId'],
    );
    return index < 0 ? 0 : index;
  }

  w.text('CCMMWS');
  w.u16(4);
  w.u16(6);
  final at = w.position;
  for (var i = 0; i < 7; i++) {
    w.u32(0);
  }
  final offsets = [w.position];
  final metadata = chartMap(p.extensions['mmws'] ?? {});
  w.text('${p.meta['title']}');
  w.text('${p.meta['charter']}');
  w.text('${p.meta['artist']}');
  w.text('${metadata['musicFile'] ?? ''}');
  w.f32(-p.audioOffset * 1000);
  w.text('${metadata['jacketFile'] ?? ''}');
  w.u32(0);
  offsets.add(w.position);
  final meters = p.meters;
  w.u32(meters.length);
  var previousTick = 0, measure = 0, previousLength = 1920.0;
  for (final meter in meters) {
    final tick = meter['tick'] as int,
        delta = (tick - previousTick) / previousLength;
    if (delta != delta.roundToDouble()) {
      throw const FormatException('mmwMeasureBoundary');
    }
    measure += delta.round();
    w.u32(measure);
    w.u32(meter['numerator'] as int);
    w.u32(meter['denominator'] as int);
    previousTick = tick;
    previousLength =
        1920 * (meter['numerator'] as num) / (meter['denominator'] as num);
  }
  w.u32(p.tempos.length);
  for (final event in p.tempos) {
    w.u32(event['tick'] as int);
    w.f32(event['bpm'] as num);
  }
  w.u32(p.timeScales.length * layers.length);
  for (var i = 0; i < layers.length; i++) {
    for (final event in p.timeScales) {
      w.u32(event['tick'] as int);
      w.f32(event['scale'] as num);
      w.u32(i);
    }
  }
  w.u32((p.markers['skill'] as List).length);
  for (final tick in p.markers['skill'] as List) {
    w.u32(tick as int);
  }
  final fever = (p.markers['fever'] as List).firstOrNull as List?;
  w.u32(fever?[0] as int? ?? 0xffffffff);
  w.u32(fever?[1] as int? ?? 0xffffffff);
  void note(ChartMap value, String role, double lane, double size) {
    w.u32(value['tick'] as int);
    w.f32(lane * 12 / p.laneBasis);
    w.f32(size * 12 / p.laneBasis);
    w.u32(layerFor('${value['id']}'));
    if (role == 'single' || role == 'tail') {
      w.u32(
        _directions.indexOf(
          value['type'] == 'flick'
              ? value['direction'] == 'none'
                    ? 'up'
                    : '${value['direction']}'
              : 'none',
        ),
      );
    }
    w.u32(
      (value['critical'] == true ? 1 : 0) | (value['type'] == 'trace' ? 2 : 0),
    );
  }

  offsets.add(w.position);
  w.u32(p.singles.length);
  for (final value in p.singles) {
    note(
      value,
      'single',
      (value['lane'] as num).toDouble(),
      (value['size'] as num).toDouble(),
    );
  }
  offsets.add(w.position);
  w.u32(p.lines.length);
  for (final line in p.lines) {
    final points = chartRows(line['points']),
        first = points.first,
        last = points.last;
    if (points
        .take(points.length - 1)
        .any(
          (point) =>
              chartMap(point['ease'])['left'] !=
              chartMap(point['ease'])['right'],
        )) {
      throw const FormatException('mmwEdgeEase');
    }
    w.u32(
      (first['visible'] == false ? 1 : 0) |
          (last['visible'] == false ? 2 : 0) |
          (line['kind'] == 'guide' ? 4 : 0),
    );
    void write(int index, String role) {
      final shape = resolveChartPoint(points, index);
      note(points[index], role, shape.$1, shape.$2);
    }

    write(0, 'head');
    w.u32(_ease.indexOf('${chartMap(first['ease'])['left']}'));
    w.u32(0);
    w.u32(first['critical'] == true ? 4 : 2);
    w.u32(points.length - 2);
    for (var i = 1; i < points.length - 1; i++) {
      write(i, 'mid');
      w.u32(
        points[i]['lane'] == 'auto'
            ? 2
            : points[i]['visible'] == true
            ? 0
            : 1,
      );
      w.u32(_ease.indexOf('${chartMap(points[i]['ease'])['left']}'));
    }
    write(points.length - 1, 'tail');
  }
  offsets.add(w.position);
  w.u32(0);
  offsets.add(w.position);
  w.u32(layers.length);
  for (final layer in layers) {
    w.text('${layer['name']}');
  }
  offsets.add(w.position);
  final waypoints = chartRows(p.data['waypoints'] ?? []);
  w.u32(waypoints.length);
  for (final point in waypoints) {
    w.text('${point['name']}');
    w.u32(point['tick'] as int);
  }
  final output = w.bytes.toBytes(), view = ByteData.sublistView(output);
  for (var i = 0; i < offsets.length; i++) {
    view.setUint32(at + i * 4, offsets[i], Endian.little);
  }
  return output;
}

({List<ChartIssue> errors, List<ChartIssue> warnings}) mmwsExportDiagnostics(
  ChartProject p,
) {
  final errors = <ChartIssue>[], warnings = <ChartIssue>[];
  void fail(String code, String path) =>
      errors.add(ChartIssue('mmws.export.$code', path));
  void warn(String code, String path) =>
      warnings.add(ChartIssue('mmws.export.$code', path, true));
  var previous = 0, length = 1920.0;
  for (final meter in p.meters) {
    final tick = meter['tick'] as int;
    if ((tick - previous) / length !=
        ((tick - previous) / length).roundToDouble()) {
      fail('mmwMeasureBoundary', r'$.meters');
    }
    previous = tick;
    length = 1920 * (meter['numerator'] as num) / (meter['denominator'] as num);
  }
  if ((p.markers['fever'] as List).length > 1) {
    fail('singleFever', r'$.markers.fever');
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
    fail('mmwEdgeEase', r'$.lines');
  }
  final ticks = [
    for (final node in p.nodes) node.tick,
    for (final key in ['tempos', 'timeScales', 'waypoints'])
      for (final row in chartRows(p.data[key] ?? [])) row['tick'] as int,
    ...(p.markers['skill'] as List).cast<int>(),
    for (final pair in p.markers['fever'] as List)
      ...(pair as List).cast<int>(),
  ];
  if (ticks.any((tick) => tick > 0x7fffffff)) fail('tickLimit', r'$');
  final floats = [
    p.audioOffset * 1000,
    for (final event in p.tempos) (event['bpm'] as num).toDouble(),
    for (final event in p.timeScales) (event['scale'] as num).toDouble(),
    for (final node in p.nodes) ...[
      node.lane * 12 / p.laneBasis,
      node.size * 12 / p.laneBasis,
    ],
  ];
  if (floats.any((value) => !(Float32List.fromList([value])[0]).isFinite)) {
    fail('floatRange', r'$');
  }
  if ((p.markers['call'] as List).isNotEmpty) {
    warn('callUnsupported', r'$.markers.call');
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
        chartRows(line['points'])
            .take(chartRows(line['points']).length - 1)
            .any((point) => point['type'] == 'flick'),
  )) {
    warn('nonEndFlickUnsupported', r'$.lines');
  }
  if (p.lines.any(
    (line) =>
        line['critical'] != null &&
        line['critical'] != chartRows(line['points']).first['critical'],
  )) {
    warn('mmwCritical', r'$.lines');
  }
  if (['difficulty', 'level'].any((key) => '${p.meta[key] ?? ''}'.isNotEmpty) ||
      (p.meta['tags'] as List? ?? []).isNotEmpty) {
    warn('metadataPartial', r'$.meta');
  }
  if (p.lines.any(
    (line) => chartRows(line['points'])
        .any((point) => point['lane'] == 'auto' && point['visible'] == true),
  )) {
    warn('autoVisibilityUnsupported', r'$.lines');
  }
  final collections = chartCollections(p);
  if ((collections['groups'] as List).isNotEmpty) {
    warn('groupsUnsupported', r'$.extensions');
  }
  if (chartRows(collections['layers'])
      .any((layer) => layer['visible'] == false)) {
    warn('layerVisibilityUnsupported', r'$.extensions');
  }
  if (p.singles.any((note) => note['visible'] == false)) {
    warn('singleVisibilityIgnored', r'$.singles');
  }
  if (p.extensions.keys.any(
    (key) => key != 'mmws' && key != 'authoringCollections',
  )) {
    warn('extensionsUnsupported', r'$.extensions');
  }
  warn('floatPrecision', r'$');
  return (errors: errors, warnings: warnings);
}
