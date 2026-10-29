import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import 'authoring_actions.dart';
import 'connectors.dart';
import 'controller.dart';
import 'editing.dart';
import 'project.dart';

class ChartAuthoringTools extends StatefulWidget {
  const ChartAuthoringTools({super.key, required this.controller});
  final ChartEditorController controller;
  @override
  State<ChartAuthoringTools> createState() => _ChartAuthoringToolsState();
}

class _ChartAuthoringToolsState extends State<ChartAuthoringTools> {
  List<ChartMap> _patterns = [];
  ChartEditorController get c => widget.controller;
  String t(String key) => AppScope.of(context).text('editors.chart.$key', key);
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final patterns = await c.store.patterns();
      if (mounted) setState(() => _patterns = patterns);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('patterns.storage_failed'))));
      }
    }
  }

  Future<String?> _name([String initial = '']) async {
    final input = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('patterns.name')),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 80,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppScope.of(context).text('common.actions.cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(context, input.text.trim());
              }
            },
            child: Text(AppScope.of(context).text('common.actions.save')),
          ),
        ],
      ),
    );
    input.dispose();
    return result;
  }

  Future<void> _save() async {
    final name = await _name();
    if (name == null) return;
    await c.store.savePattern({
      'id': chartUuid(),
      'name': name,
      'clipboard': copyChartSelection(c.project, c.selection),
    });
    await _refresh();
  }

  Future<void> _import() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null) return;
    try {
      final value = chartMap(jsonDecode(utf8.decode(await file.readAsBytes())));
      if (value['schema'] != 'haneoka.chart-pattern' ||
          value['version'] != 1 ||
          value['name'] is! String ||
          '${value['name']}'.trim().isEmpty) {
        throw const FormatException('invalid_pattern');
      }
      final clipboard = chartMap(value['clipboard']);
      pasteChartSelection(ChartProject.empty(), clipboard, 0);
      await c.store.savePattern({
        'id': chartUuid(),
        'name': value['name'],
        'clipboard': clipboard,
      });
      await _refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('patterns.invalid_pattern'))));
      }
    }
  }

  Future<void> _marker(String kind, [int? index]) async {
    final rows = c.project.markers[kind] as List;
    final row = index == null ? null : rows[index];
    final start = TextEditingController(
      text:
          '${row is num
              ? row / 480
              : row is List
              ? (row.first as num) / 480
              : row is Map
              ? (row['tick'] as num) / 480
              : c.positionTick / 480}',
    );
    final end = TextEditingController(
      text:
          '${row is List ? (row.last as num) / 480 : c.positionTick / 480 + 4}',
    );
    final rhythm = TextEditingController(
      text: row is Map ? (row['rhythm'] as List).join(' ') : '1 0 1 0',
    );
    var invalid = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(t('markers.$kind')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: start,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t('markers.start'),
                  error: invalid ? const SizedBox.shrink() : null,
                ),
              ),
              if (kind == 'fever')
                TextField(
                  controller: end,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('markers.end')),
                ),
              if (kind == 'call')
                TextField(
                  controller: rhythm,
                  decoration: InputDecoration(labelText: t('markers.rhythm')),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppScope.of(context).text('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final a = double.tryParse(start.text),
                    b = double.tryParse(end.text),
                    r = rhythm.text.trim().split(RegExp(r'[\s,]+'));
                if (a == null ||
                    a < 0 ||
                    kind == 'fever' && (b == null || b < a) ||
                    kind == 'call' &&
                        (r.isEmpty ||
                            r.any((value) => value != '0' && value != '1'))) {
                  set(() => invalid = true);
                  return;
                }
                Navigator.pop(context, true);
              },
              child: Text(AppScope.of(context).text('common.actions.save')),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      c.edit((p) {
        final values = p.markers[kind] as List;
        final tick = (double.parse(start.text) * 480).round();
        final Object value = kind == 'skill'
            ? tick
            : kind == 'fever'
            ? [tick, (double.parse(end.text) * 480).round()]
            : {
                'tick': tick,
                'rhythm': rhythm.text
                    .trim()
                    .split(RegExp(r'[\s,]+'))
                    .map(int.parse)
                    .toList(),
              };
        if (index == null) {
          values.add(value);
        } else {
          values[index] = value;
        }
      });
    }
    start.dispose();
    end.dispose();
    rhythm.dispose();
  }

  Future<void> _waypoint([int? index]) async {
    final rows = chartRows(c.project.data['waypoints'] ?? []),
        old = index == null ? null : rows[index];
    final name = TextEditingController(text: '${old?['name'] ?? ''}');
    final beat = TextEditingController(
      text: '${(old?['tick'] as num? ?? c.positionTick) / 480}',
    );
    var invalid = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(t('creation.waypoint')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(
                  labelText: t('creation.waypoint_name'),
                ),
              ),
              TextField(
                controller: beat,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t('beat'),
                  error: invalid ? const SizedBox.shrink() : null,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppScope.of(context).text('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final tick = double.tryParse(beat.text);
                if (tick == null || !tick.isFinite || tick < 0) {
                  set(() => invalid = true);
                  return;
                }
                Navigator.pop(context, true);
              },
              child: Text(AppScope.of(context).text('common.actions.save')),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      c.edit((p) {
        final values =
            p.data.putIfAbsent('waypoints', () => <ChartMap>[]) as List;
        final row = {
          'id': old?['id'] ?? chartId('waypoint'),
          'name': name.text.trim(),
          'tick': (double.parse(beat.text) * 480).round(),
        };
        if (index == null) {
          values.add(row);
        } else {
          values[index] = row;
        }
        values.sort(
          (a, b) =>
              ((a as Map)['tick'] as int).compareTo((b as Map)['tick'] as int),
        );
      });
    }
    name.dispose();
    beat.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ExpansionTile(
        title: Text(t('patterns.title')),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: c.selection.isEmpty ? null : _save,
                child: Text(t('patterns.save_selection')),
              ),
              OutlinedButton(
                onPressed: _import,
                child: Text(t('patterns.import')),
              ),
              OutlinedButton(
                onPressed: c.shortFlick,
                child: Text(t('patterns.short_flick')),
              ),
              OutlinedButton(
                onPressed: c.selection.isEmpty
                    ? null
                    : () => c.compressSelection(false),
                child: Text(t('patterns.compress_first')),
              ),
              OutlinedButton(
                onPressed: c.selection.isEmpty
                    ? null
                    : () => c.compressSelection(true),
                child: Text(t('patterns.compress_last')),
              ),
            ],
          ),
          for (final pattern in _patterns)
            ListTile(
              title: Text('${pattern['name']}'),
              onTap: () => c.applyPattern(chartMap(pattern['clipboard'])),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'delete') {
                    await c.store.deletePattern('${pattern['id']}');
                  }
                  if (action == 'rename') {
                    final name = await _name('${pattern['name']}');
                    if (name != null) {
                      await c.store.savePattern({...pattern, 'name': name});
                    }
                  }
                  if (action == 'export') {
                    await FilePicker.saveFile(
                      fileName: 'pattern.json',
                      bytes: Uint8List.fromList(
                        utf8.encode(
                          const JsonEncoder.withIndent('  ').convert({
                            'schema': 'haneoka.chart-pattern',
                            'version': 1,
                            'name': pattern['name'],
                            'clipboard': pattern['clipboard'],
                          }),
                        ),
                      ),
                    );
                  }
                  await _refresh();
                },
                itemBuilder: (context) => [
                  for (final action in ['rename', 'export', 'delete'])
                    PopupMenuItem(
                      value: action,
                      child: Text(
                        action == 'export'
                            ? AppScope.of(context).text('common.actions.export')
                            : t('patterns.$action'),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
      ExpansionTile(
        title: Text(t('selection')),
        children: [
          for (final entry in <(String, VoidCallback)>[
            ('creation.join_lines', c.joinConnectors),
            ('creation.split_line', c.splitConnector),
            ('creation.repeat_nodes', c.repeatConnector),
            ('creation.generate_traces', () => c.connectorTraces()),
            (
              'creation.convert_traces',
              () => c.connectorTraces(keepLines: false),
            ),
            ('creation.duplicate', c.duplicateSelection),
            (
              'creation.duplicate_mirrored',
              () => c.duplicateSelection(mirrored: true),
            ),
          ])
            TextButton(
              onPressed: c.selection.isEmpty ? null : entry.$2,
              child: Text(t(entry.$1)),
            ),
        ],
      ),
      ExpansionTile(
        title: Text(t('markers.title')),
        children: [
          for (final kind in ['skill', 'fever', 'call']) ...[
            for (final (index, row)
                in (c.project.markers[kind] as List).indexed)
              ListTile(
                title: Text(t('markers.$kind')),
                subtitle: Text('$row'),
                onTap: () => _marker(kind, index),
                trailing: IconButton(
                  tooltip: t('markers.delete_$kind'),
                  icon: const Icon(Symbols.delete_rounded),
                  onPressed: () =>
                      c.edit((p) => (p.markers[kind] as List).removeAt(index)),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () => _marker(kind),
              icon: const Icon(Symbols.add_rounded),
              label: Text(t('markers.add_$kind')),
            ),
          ],
        ],
      ),
      ExpansionTile(
        title: Text(t('creation.waypoints')),
        children: [
          for (final (index, row) in chartRows(
            c.project.data['waypoints'] ?? [],
          ).indexed)
            ListTile(
              title: Text('${row['name']}'),
              subtitle: Text('${t('beat')}: ${(row['tick'] as num) / 480}'),
              onTap: () => _waypoint(index),
              leading: IconButton(
                tooltip: t('creation.jump_waypoint'),
                onPressed: () =>
                    c.seek(c.tempoMap.secondsAt(row['tick'] as num)),
                icon: const Icon(Symbols.my_location_rounded),
              ),
              trailing: IconButton(
                tooltip: t('creation.delete_waypoint'),
                onPressed: () => c.edit(
                  (p) => (p.data['waypoints'] as List).removeAt(index),
                ),
                icon: const Icon(Symbols.delete_rounded),
              ),
            ),
          TextButton(
            onPressed: () => _waypoint(),
            child: Text(t('creation.add_waypoint')),
          ),
        ],
      ),
      ExpansionTile(
        title: Text(t('statistics.title')),
        children: [
          ListTile(
            title: Text(t('statistics.authored')),
            trailing: Text('${c.project.nodes.length}'),
          ),
          ListTile(
            title: Text(t('statistics.duration')),
            trailing: Text('${c.duration.toStringAsFixed(2)} s'),
          ),
        ],
      ),
    ],
  );
}
