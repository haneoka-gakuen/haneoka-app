import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import 'controller.dart';
import 'authoring_tools.dart';
import 'shortcuts.dart';
import 'editing.dart';
import 'project.dart';

class ChartEditorInspector extends StatelessWidget {
  const ChartEditorInspector({super.key, required this.controller});
  final ChartEditorController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, t = AppScope.of(context).text;
    String label(String key) => t('editors.chart.$key');
    final project = c.project,
        selected = c.renderNodes.where((n) => n.id == c.primary).firstOrNull;
    Widget field(
      String key,
      Object? value,
      bool Function(String) commit, {
      bool numeric = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ChartEditorField(
        key: ValueKey('${c.id}:$key'),
        label: label(key),
        value: '$value',
        numeric: numeric,
        enabled: !c.busy,
        onCommit: commit,
      ),
    );
    Widget choose(
      String key,
      String value,
      List<(String, String)> options,
      ValueChanged<String> change,
    ) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$key:$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label(key)),
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option.$1,
              child: Text(option.$2, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: c.busy
            ? null
            : (value) {
                if (value != null) change(value);
              },
      ),
    );
    Widget section(
      String key,
      List<Widget> children, {
      bool expanded = false,
    }) => ExpansionTile(
      key: PageStorageKey('chart-inspector-$key'),
      title: Text(label(key)),
      initiallyExpanded: expanded,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: children,
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        section('currentTool', [
          choose(
            'currentTool',
            c.tool,
            [
              for (final key in [
                'select',
                'pan',
                'tap',
                'flick',
                'trace',
                'hold',
                'guide',
                'erase',
                'creation.brush',
                'node',
              ])
                (key == 'creation.brush' ? 'brush' : key, label(key)),
            ],
            (value) {
              c.tool = value;
              c.cancelGesture();
            },
          ),
          field('creation.default_width', c.noteWidth, (value) {
            final width = double.tryParse(value);
            if (width == null || width < 0 || width > project.laneBasis) {
              return false;
            }
            c.noteWidth = width;
            c.changed();
            return true;
          }, numeric: true),
          field('snap', c.division, (value) {
            final n = int.tryParse(value);
            if (n == null || n < 1 || n > 480) return false;
            c.division = n;
            c.changed();
            return true;
          }, numeric: true),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(label('defaultCritical')),
            value: c.critical,
            onChanged: (v) {
              c.critical = v;
              c.changed();
            },
          ),
          choose(
            'defaultDirection',
            c.direction,
            [
              ('left', label('directionLeft')),
              ('up', label('directionUp')),
              ('right', label('directionRight')),
            ],
            (v) {
              c.direction = v;
              c.changed();
            },
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(label('creation.multi_select')),
            value: c.multiSelect,
            onChanged: (v) {
              c.multiSelect = v;
              c.changed();
            },
          ),
          choose(
            'snap',
            c.relativeSnap ? 'relative' : 'absolute',
            [
              ('absolute', label('creation.snap_absolute')),
              ('relative', label('creation.snap_relative')),
            ],
            (v) {
              c.relativeSnap = v == 'relative';
              c.changed();
            },
          ),
          field('creation.zoom', c.secondsPerScreen, (value) {
            final n = double.tryParse(value);
            if (n == null || n <= 0 || n > 120) return false;
            c.secondsPerScreen = n;
            c.changed();
            return true;
          }, numeric: true),
          field('creation.zoom_x', c.zoomX, (value) {
            final n = double.tryParse(value);
            if (n == null || n < .25 || n > 8) return false;
            c.zoomX = n;
            c.changed();
            return true;
          }, numeric: true),
          OutlinedButton.icon(
            onPressed: c.resetView,
            icon: const Icon(Symbols.restart_alt_rounded),
            label: Text(label('resetView')),
          ),
        ]),
        section('inspector', [
          for (final key in [
            'title',
            'artist',
            'charter',
            'difficulty',
            'level',
          ])
            field(
              key,
              project.meta[key],
              (value) => c.edit((p) => p.meta[key] = value),
            ),
          field(
            'creation.bpm',
            project.tempos.first['bpm'],
            (value) =>
                c.edit((p) => p.tempos.first['bpm'] = double.parse(value)),
            numeric: true,
          ),
          field(
            'audioOffset',
            project.audioOffset,
            (value) =>
                c.edit((p) => p.data['audioOffset'] = double.parse(value)),
            numeric: true,
          ),
          field(
            'laneBasis',
            project.laneBasis,
            (value) => c.edit((p) => p.data['laneBasis'] = double.parse(value)),
            numeric: true,
          ),
          if (c.media != null)
            for (final candidate in c.media!.candidates)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${label('creation.candidate')} ${candidate.$1}'),
                trailing: const Icon(Symbols.add_rounded),
                onTap: () =>
                    c.edit((p) => p.tempos.first['bpm'] = candidate.$1),
              ),
        ], expanded: true),
        if (selected != null)
          section('selection', [
            field(
              'tick',
              selected.tick,
              (value) => c.edit(
                (p) => moveChartSelection(
                  p,
                  c.selection,
                  int.parse(value) - selected.tick,
                  0,
                ),
              ),
              numeric: true,
            ),
            field(
              'beat',
              selected.tick / 480,
              (value) => c.edit(
                (p) => moveChartSelection(
                  p,
                  c.selection,
                  (double.parse(value) * 480).round() - selected.tick,
                  0,
                ),
              ),
              numeric: true,
            ),
            field(
              'lane',
              selected.note['lane'],
              (value) => c.edit((p) {
                final target = double.parse(value),
                    node = p.nodes.firstWhere((n) => n.id == selected.id);
                if (node.note['lane'] == 'auto') {
                  node.note['lane'] = node.lane;
                  node.note['size'] = node.size;
                  node.note.remove('autoSize');
                }
                moveChartSelection(p, c.selection, 0, target - node.lane);
              }),
              numeric: true,
            ),
            field(
              'width',
              selected.size,
              (value) => c.edit(
                (p) => brushChartSelection(p, c.selection, {
                  'size': double.parse(value),
                }),
              ),
              numeric: true,
            ),
            choose('noteType', '${selected.note['type']}', [
              for (final key in ['tap', 'flick', 'trace']) (key, label(key)),
            ], (v) => c.brush({'type': v})),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(label('critical')),
              value: selected.note['critical'] == true,
              onChanged: (v) => c.brush({'critical': v}),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(label('visible')),
              value: selected.note['visible'] == true,
              onChanged: (v) => c.brush({'visible': v}),
            ),
            if (selected.note['type'] == 'flick')
              choose('direction', '${selected.note['direction']}', [
                ('left', label('directionLeft')),
                ('up', label('directionUp')),
                ('right', label('directionRight')),
              ], (v) => c.brush({'direction': v})),
            if (selected.line != null) ...[
              choose('lineType', '${selected.line!['kind']}', [
                ('long', label('longLine')),
                ('guide', label('guideLine')),
              ], (v) => c.brush({'lineKind': v})),
              choose(
                'creation.line_critical',
                '${selected.line!['critical'] ?? 'inherit'}',
                [
                  ('inherit', label('creation.line_critical_inherit')),
                  ('false', label('creation.line_critical_normal')),
                  ('true', label('critical')),
                ],
                (v) => c.edit((p) {
                  for (final line in p.lines) {
                    if (chartRows(line['points'])
                        .any((n) => c.selection.contains(n['id']))) {
                      if (v == 'inherit') {
                        line.remove('critical');
                      } else {
                        line['critical'] = v == 'true';
                      }
                    }
                  }
                }),
              ),
              for (final side in ['left', 'right'])
                choose(
                  side == 'left' ? 'leftEase' : 'rightEase',
                  '${chartMap(selected.note['ease'])[side]}',
                  [
                    ('linear', label('easeLinear')),
                    ('in', label('easeIn')),
                    ('out', label('easeOut')),
                  ],
                  (v) => c.brush({
                    'ease': {side: v},
                  }),
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(label('autoLane')),
                value: selected.note['lane'] == 'auto',
                onChanged: (value) => c.edit((p) {
                  for (final node in p.nodes.toList()) {
                    if (!c.selection.contains(node.id) || node.line == null) {
                      continue;
                    }
                    if (value) {
                      node.note['lane'] = 'auto';
                    } else {
                      node.note['lane'] = node.lane;
                      node.note['size'] = node.size;
                      node.note.remove('autoSize');
                    }
                    node.note.remove('resolvedLane');
                    node.note.remove('resolvedSize');
                  }
                }),
              ),
              OutlinedButton(
                onPressed: c.generatePoints,
                child: Text(label('creation.generate_nodes')),
              ),
              OutlinedButton(
                onPressed: () => c.deleteSelection(controlsOnly: true),
                child: Text(label('creation.remove_nodes')),
              ),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                IconButton(
                  onPressed: c.flip,
                  tooltip: label('creation.flip'),
                  icon: const Icon(Symbols.flip_rounded),
                ),
                IconButton(
                  onPressed: () => c.copy(),
                  tooltip: label('creation.copy'),
                  icon: const Icon(Symbols.content_copy_rounded),
                ),
                IconButton(
                  onPressed: () => c.copy(cut: true),
                  tooltip: label('creation.cut'),
                  icon: const Icon(Symbols.content_cut_rounded),
                ),
                IconButton(
                  onPressed: c.deleteSelection,
                  tooltip: label('deleteSelection'),
                  icon: const Icon(Symbols.delete_rounded),
                ),
              ],
            ),
          ], expanded: true),
        section('timing', [
          for (final key in ['tempos', 'meters', 'timeScales']) ...[
            for (final row in chartRows(project.data[key]))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  key == 'tempos'
                      ? '${row['bpm']} BPM'
                      : key == 'meters'
                      ? '${row['numerator']}/${row['denominator']}'
                      : '${row['scale']}×',
                ),
                subtitle: Text('${label('tick')} ${row['tick']}'),
                onTap: () => _timing(context, c, key, row),
                trailing: IconButton(
                  tooltip: t('common.actions.remove'),
                  icon: const Icon(Symbols.delete_rounded),
                  onPressed: key != 'timeScales' && row['tick'] == 0
                      ? null
                      : () => c.edit(
                          (p) => (p.data[key] as List).removeWhere(
                            (v) => (v as Map)['id'] == row['id'],
                          ),
                        ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () => _timing(context, c, key),
              icon: const Icon(Symbols.add_rounded),
              label: Text(
                label(
                  key == 'tempos'
                      ? 'addBpm'
                      : key == 'meters'
                      ? 'addMeter'
                      : 'addTimeScale',
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ]),
        ChartCollectionsPanel(controller: c),
        if (c.feedback case final feedback?)
          section('audio.title', [
            SwitchListTile(
              title: Text(label('labels.noteSound')),
              value: feedback.notes,
              onChanged: (value) => feedback.configure(noteSounds: value),
            ),
            SwitchListTile(
              title: Text(label('audio.metronome')),
              value: feedback.metronome,
              onChanged: (value) => feedback.configure(beat: value),
            ),
            for (final (name, value) in [
              ('bgm_volume', feedback.bgmVolume),
              ('note_volume', feedback.noteVolume),
              ('metronome_volume', feedback.metronomeVolume),
            ])
              Column(
                children: [
                  Text(label('audio.$name')),
                  Slider(
                    value: value,
                    onChanged: (v) => feedback.configure(
                      bgm: name == 'bgm_volume' ? v : null,
                      note: name == 'note_volume' ? v : null,
                      click: name == 'metronome_volume' ? v : null,
                    ),
                  ),
                ],
              ),
            choose('audio.sound_group', '${feedback.group}', [
              for (final id in [1, 2, 3, 4]) ('$id', '$id'),
            ], (value) => feedback.configure(soundGroup: int.parse(value))),
          ]),
        ChartAuthoringTools(controller: c),
        ChartShortcutSettings(shortcuts: c.shortcuts),
      ],
    );
  }
}

Future<void> _timing(
  BuildContext context,
  ChartEditorController c,
  String key, [
  ChartMap? old,
]) async {
  final t = AppScope.of(context).text;
  final row = old == null
      ? <String, Object?>{
          'id': chartId(key),
          'tick': c.positionTick,
          if (key == 'tempos') 'bpm': c.project.tempoMap.bpmAt(c.positionTick),
          if (key == 'meters') ...{'numerator': 4, 'denominator': 4},
          if (key == 'timeScales') 'scale': 1,
        }
      : cloneChartMap(old);
  final fields = [
    'tick',
    if (key == 'tempos') 'bpm',
    if (key == 'meters') ...'numerator denominator'.split(' '),
    if (key == 'timeScales') 'scale',
  ];
  final controllers = {
    for (final field in fields)
      field: TextEditingController(text: '${row[field]}'),
  };
  bool invalid = false;
  final value = await showDialog<ChartMap>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          t(
            'editors.chart.${key == 'tempos'
                ? 'creation.bpm'
                : key == 'meters'
                ? 'meter'
                : 'timeScale'}',
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final field in fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: TextField(
                    controller: controllers[field],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: field == 'tick'
                          ? t('editors.chart.tick')
                          : field == 'bpm'
                          ? 'BPM'
                          : field == 'scale'
                          ? t('editors.chart.timeScale')
                          : field == 'numerator'
                          ? '×'
                          : '/',
                      error: invalid ? const SizedBox.shrink() : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('common.actions.cancel')),
          ),
          FilledButton(
            onPressed: () {
              try {
                final next = cloneChartMap(row);
                for (final field in fields) {
                  next[field] =
                      field == 'tick' ||
                          field == 'numerator' ||
                          field == 'denominator'
                      ? int.parse(controllers[field]!.text)
                      : double.parse(controllers[field]!.text);
                }
                final p = c.project.copy();
                final list = chartRows(p.data[key])
                  ..removeWhere((v) => v['id'] == row['id']);
                list.add(next);
                p.data[key] = list;
                p.sort();
                p.requireValid();
                Navigator.pop(context, next);
              } catch (_) {
                setState(() => invalid = true);
              }
            },
            child: Text(t('common.actions.confirm')),
          ),
        ],
      ),
    ),
  );
  for (final controller in controllers.values) {
    controller.dispose();
  }
  if (value != null) {
    c.edit((p) {
      final rows = chartRows(p.data[key])
        ..removeWhere((r) => r['id'] == row['id']);
      rows.add(value);
      p.data[key] = rows;
    });
  }
}

class ChartCollectionsPanel extends StatelessWidget {
  const ChartCollectionsPanel({super.key, required this.controller});
  final ChartEditorController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller,
        t = AppScope.of(context).text,
        collections = chartCollections(c.project);
    String label(String key) => t('editors.chart.collections.$key');
    Future<void> rename(String key, [ChartMap? item]) async {
      final field = TextEditingController(text: '${item?['name'] ?? ''}');
      final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(label(key == 'groups' ? 'group_name' : 'layer_name')),
          content: TextField(
            controller: field,
            autofocus: true,
            maxLength: 120,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, field.text),
              child: Text(t('common.actions.confirm')),
            ),
          ],
        ),
      );
      field.dispose();
      if (value == null) return;
      c.edit((p) {
        final state = chartCollections(p), rows = chartRows(state[key]);
        if (item == null) {
          rows.add({
            'id': chartId(key == 'groups' ? 'group' : 'layer'),
            'name': value,
            if (key == 'layers') 'visible': true,
          });
        } else {
          rows.firstWhere((r) => r['id'] == item['id'])['name'] = value;
        }
        state[key] = rows;
        p.extensions['authoringCollections'] = state;
      });
    }

    Future<void> remove(String key, ChartMap item) async {
      final delete = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(label(key == 'groups' ? 'delete_group' : 'delete_layer')),
          content: Text(label('delete_choice')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('common.actions.cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(label('keep_notes')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(label('delete_notes')),
            ),
          ],
        ),
      );
      if (delete == null) return;
      c.edit((p) {
        final state = chartCollections(p),
            members = chartMap(state['members']),
            memberKey = key == 'groups' ? 'groupId' : 'layerId';
        final ids = {
          for (final entry in members.entries)
            if ((entry.value as Map)[memberKey] == item['id']) entry.key,
        };
        if (delete) deleteChartSelection(p, ids);
        for (final member in members.values) {
          if ((member as Map)[memberKey] == item['id']) {
            member.remove(memberKey);
          }
        }
        members.removeWhere(
          (id, value) =>
              !chartEntityIds(p).contains(id) || (value as Map).isEmpty,
        );
        state[key] = chartRows(state[key])
            .where((v) => v['id'] != item['id'])
            .toList();
        p.extensions['authoringCollections'] = state;
      });
      if (c.group == item['id']) c.group = null;
      if (c.layer == item['id']) c.layer = null;
      c.changed();
    }

    return ExpansionTile(
      key: const PageStorageKey('chart-collections'),
      title: Text(label('title')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        for (final key in ['groups', 'layers']) ...[
          Text(label(key), style: Theme.of(context).textTheme.titleSmall),
          DropdownButtonFormField<String>(
            key: ValueKey('$key:${c.group}:${c.layer}'),
            initialValue: key == 'groups' ? c.group ?? '' : c.layer ?? '',
            isExpanded: true,
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  label(key == 'groups' ? 'all_groups' : 'all_layers'),
                ),
              ),
              for (final row in chartRows(collections[key]))
                DropdownMenuItem(
                  value: '${row['id']}',
                  child: Text('${row['name']}'),
                ),
            ],
            onChanged: (value) {
              if (key == 'groups') {
                c.group = value?.isEmpty == true ? null : value;
              } else {
                c.layer = value?.isEmpty == true ? null : value;
              }
              c.cancelGesture();
              c.selection.retainAll(c.scope);
              c.changed();
            },
          ),
          for (final (index, item) in chartRows(collections[key]).indexed)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${item['name']}'),
                  onTap: () => rename(key, item),
                  leading: key == 'layers'
                      ? IconButton(
                          tooltip: label(
                            item['visible'] == true
                                ? 'hide_layer'
                                : 'show_layer',
                          ),
                          icon: Icon(
                            item['visible'] == true
                                ? Symbols.visibility_rounded
                                : Symbols.visibility_off_rounded,
                          ),
                          onPressed: () => c.edit((p) {
                            final state = chartCollections(p);
                            chartRows(state[key]).firstWhere(
                              (r) => r['id'] == item['id'],
                            )['visible'] = item['visible'] != true;
                            p.extensions['authoringCollections'] = state;
                          }),
                        )
                      : null,
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      switch (action) {
                        case 'select':
                          c.select(
                            chartScope(
                              c.project,
                              group: key == 'groups' ? '${item['id']}' : null,
                              layer: key == 'layers' ? '${item['id']}' : null,
                              hidden: true,
                            ),
                          );
                        case 'assign':
                          c.edit(
                            (p) => assignChartSelection(p, c.selection, {
                              key == 'groups' ? 'groupId' : 'layerId':
                                  item['id'],
                            }),
                          );
                        case 'up' || 'down':
                          c.edit((p) {
                            final state = chartCollections(p),
                                rows = chartRows(state[key]);
                            final at = rows.indexWhere(
                              (v) => v['id'] == item['id'],
                            );
                            final target = at + (action == 'up' ? -1 : 1);
                            if (target >= 0 && target < rows.length) {
                              final value = rows.removeAt(at);
                              rows.insert(target, value);
                              state[key] = rows;
                              p.extensions['authoringCollections'] = state;
                            }
                          });
                        case 'delete':
                          unawaited(remove(key, item));
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'select',
                        child: Text(label('select_members')),
                      ),
                      PopupMenuItem(
                        value: 'assign',
                        enabled: c.selection.isNotEmpty,
                        child: Text(
                          label(
                            key == 'groups' ? 'assign_group' : 'assign_layer',
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'up',
                        enabled: index > 0,
                        child: Text(label('move_up')),
                      ),
                      PopupMenuItem(
                        value: 'down',
                        enabled: index + 1 < chartRows(collections[key]).length,
                        child: Text(label('move_down')),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(t('common.actions.remove')),
                      ),
                    ],
                  ),
                ),
                if (key == 'groups')
                  ChartEditorField(
                    key: ValueKey('speed:${item['id']}'),
                    label: label('force_speed'),
                    enabled:
                        !c.busy &&
                        const {
                          'ss',
                          'authored',
                        }.contains(c.project.meta['source'] ?? 'authored'),
                    value: '${item['forceNoteSpeed'] ?? ''}',
                    numeric: true,
                    onCommit: (value) => c.edit((p) {
                      final state = chartCollections(p),
                          row = chartRows(state['groups'])
                              .firstWhere((v) => v['id'] == item['id']);
                      if (value.trim().isEmpty) {
                        row.remove('forceNoteSpeed');
                      } else {
                        final speed = double.parse(value);
                        if (speed < 1 || speed > 14) {
                          throw const FormatException('invalid_group_speed');
                        }
                        row['forceNoteSpeed'] = speed;
                      }
                      p.extensions['authoringCollections'] = state;
                    }),
                  ),
              ],
            ),
          OutlinedButton.icon(
            onPressed: () => rename(key),
            icon: const Icon(Symbols.add_rounded),
            label: Text(label(key == 'groups' ? 'add_group' : 'add_layer')),
          ),
          const SizedBox(height: 16),
        ],
        if (c.selection.isNotEmpty)
          OutlinedButton(
            onPressed: () => c.edit(
              (p) => assignChartSelection(p, c.selection, {
                'groupId': null,
                'layerId': null,
              }),
            ),
            child: Text(label('unassigned')),
          ),
      ],
    );
  }
}

class ChartEditorField extends StatefulWidget {
  const ChartEditorField({
    super.key,
    required this.label,
    required this.value,
    required this.onCommit,
    this.numeric = false,
    this.enabled = true,
  });
  final String label, value;
  final bool numeric, enabled;
  final bool Function(String) onCommit;
  @override
  State<ChartEditorField> createState() => _ChartEditorFieldState();
}

class _ChartEditorFieldState extends State<ChartEditorField> {
  late final _text = TextEditingController(text: widget.value);
  late final _focus = FocusNode()..addListener(_blur);
  bool _invalid = false;
  void _blur() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    if (_text.text == widget.value) return;
    bool ok;
    try {
      ok = widget.onCommit(_text.text);
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _invalid = !ok);
  }

  @override
  void didUpdateWidget(ChartEditorField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != old.value) {
      _text.text = widget.value;
      _invalid = false;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_blur);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    enabled: widget.enabled,
    keyboardType: widget.numeric
        ? const TextInputType.numberWithOptions(decimal: true, signed: true)
        : null,
    decoration: InputDecoration(
      labelText: widget.label,
      error: _invalid ? const SizedBox.shrink() : null,
    ),
    onSubmitted: (_) => _commit(),
  );
}
