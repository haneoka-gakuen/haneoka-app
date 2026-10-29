import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';

class ChartShortcutCommand {
  const ChartShortcutCommand(this.id, this.label, this.defaults);
  final String id, label;
  final List<String> defaults;
}

final chartShortcutCommands = <ChartShortcutCommand>[
  ChartShortcutCommand('save', 'creation.save', ['Mod+KeyS']),
  ChartShortcutCommand('undo', 'undo', ['Mod+KeyZ']),
  ChartShortcutCommand('redo', 'redo', ['Mod+Shift+KeyZ', 'Mod+KeyY']),
  ChartShortcutCommand('play', 'shortcuts.play', ['Space']),
  ChartShortcutCommand('cancel', 'shortcuts.cancel', ['Escape']),
  ChartShortcutCommand('confirm', 'patterns.place', ['Enter']),
  ChartShortcutCommand('select_all', 'shortcuts.select_all', ['Mod+KeyA']),
  ChartShortcutCommand('cut', 'creation.cut', ['Mod+KeyX']),
  ChartShortcutCommand('copy', 'creation.copy', ['Mod+KeyC']),
  ChartShortcutCommand('copy_segments', 'creation.copy_segments', []),
  ChartShortcutCommand('paste', 'creation.paste', ['Mod+KeyV']),
  ChartShortcutCommand('paste_mirrored', 'creation.paste_mirrored', [
    'Mod+Shift+KeyV',
  ]),
  ChartShortcutCommand('duplicate', 'creation.duplicate', ['Mod+KeyD']),
  ChartShortcutCommand('duplicate_mirrored', 'creation.duplicate_mirrored', [
    'Mod+Shift+KeyD',
  ]),
  ChartShortcutCommand('delete', 'deleteSelection', ['Delete', 'Backspace']),
  ChartShortcutCommand('flip', 'creation.flip', ['Mod+KeyF']),
  ChartShortcutCommand('join', 'creation.join_lines', []),
  ChartShortcutCommand('split', 'creation.split_line', []),
  ChartShortcutCommand('repeat', 'creation.repeat_nodes', []),
  ChartShortcutCommand('generate_nodes', 'creation.generate_nodes', []),
  ChartShortcutCommand('remove_nodes', 'creation.remove_nodes', []),
  ChartShortcutCommand('generate_traces', 'creation.generate_traces', []),
  ChartShortcutCommand('convert_traces', 'creation.convert_traces', []),
  ChartShortcutCommand('compress_first', 'patterns.compress_first', []),
  ChartShortcutCommand('compress_last', 'patterns.compress_last', []),
  ChartShortcutCommand('nudge_up', 'shortcuts.nudge_up', ['Alt+ArrowUp']),
  ChartShortcutCommand('nudge_down', 'shortcuts.nudge_down', ['Alt+ArrowDown']),
  ChartShortcutCommand('tick_up', 'shortcuts.tick_up', []),
  ChartShortcutCommand('tick_down', 'shortcuts.tick_down', []),
  ChartShortcutCommand('width_up', 'shortcuts.width_up', ['BracketRight']),
  ChartShortcutCommand('width_down', 'shortcuts.width_down', ['BracketLeft']),
  ChartShortcutCommand('width_up_large', 'shortcuts.width_up_large', [
    'Shift+BracketRight',
  ]),
  ChartShortcutCommand('width_down_large', 'shortcuts.width_down_large', [
    'Shift+BracketLeft',
  ]),
  ChartShortcutCommand('zoom_in', 'shortcuts.zoom_in', [
    'Equal',
    'Shift+Equal',
    'NumpadAdd',
  ]),
  ChartShortcutCommand('zoom_out', 'shortcuts.zoom_out', [
    'Minus',
    'NumpadSubtract',
  ]),
  ChartShortcutCommand('pan_up', 'shortcuts.pan_up', ['ArrowUp']),
  ChartShortcutCommand('pan_down', 'shortcuts.pan_down', ['ArrowDown']),
  ChartShortcutCommand('pan_left', 'shortcuts.pan_left', ['ArrowLeft']),
  ChartShortcutCommand('pan_right', 'shortcuts.pan_right', ['ArrowRight']),
  ChartShortcutCommand('page_up', 'shortcuts.page_up', ['PageUp']),
  ChartShortcutCommand('page_down', 'shortcuts.page_down', ['PageDown']),
  ChartShortcutCommand('home', 'shortcuts.home', ['Home']),
  ChartShortcutCommand('end', 'shortcuts.end', ['End']),
  ChartShortcutCommand('previous_waypoint', 'creation.previous_waypoint', []),
  ChartShortcutCommand('next_waypoint', 'creation.next_waypoint', []),
  ChartShortcutCommand('audio_settings', 'audio.title', []),
  ChartShortcutCommand('note_sounds', 'labels.noteSound', []),
  ChartShortcutCommand('metronome', 'audio.metronome', []),

  for (final (i, tool) in [
    'select',
    'tap',
    'flick',
    'trace',
    'hold',
    'guide',
    'erase',
    'pan',
    'brush',
    'node',
  ].indexed)
    ChartShortcutCommand(
      'tool:$tool',
      tool == 'brush' ? 'creation.brush' : tool,
      ['Digit${(i + 1) % 10}'],
    ),
  for (final (i, division) in [4, 8, 12, 16, 24, 32, 48, 64].indexed)
    ChartShortcutCommand('grid:$division', '1/$division', [
      'Shift+Digit${i + 1}',
    ]),
];
String? chartBinding(KeyEvent event) {
  final keys = HardwareKeyboard.instance;
  final code = event.physicalKey.debugName?.replaceAll(' ', '');
  if (code == null ||
      code.contains('Control') ||
      code.contains('Shift') ||
      code.contains('Alt') ||
      code.contains('Meta')) {
    return null;
  }
  return '${keys.isControlPressed || keys.isMetaPressed ? 'Mod+' : ''}${keys.isAltPressed ? 'Alt+' : ''}${keys.isShiftPressed ? 'Shift+' : ''}$code';
}

class ChartShortcuts extends ChangeNotifier {
  Map<String, List<String>> overrides = {};
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('haneoka-chart-shortcuts-v1');
    if (raw != null) {
      try {
        final doc = jsonDecode(raw) as Map;
        final bindings = doc['bindings'] as Map;
        overrides = {
          for (final command in chartShortcutCommands)
            if (bindings[command.id] is List)
              command.id: (bindings[command.id] as List)
                  .whereType<String>()
                  .take(4)
                  .toList(),
        };
      } catch (_) {
        overrides = {};
      }
    }
  }

  List<String> bindings(String id) =>
      overrides[id] ??
      chartShortcutCommands.firstWhere((command) => command.id == id).defaults;
  String? match(KeyEvent event) {
    final binding = chartBinding(event);
    return chartShortcutCommands
        .where((command) => bindings(command.id).contains(binding))
        .firstOrNull
        ?.id;
  }

  Future<void> save(String id, List<String> bindings) async {
    overrides = {...overrides, id: bindings};
    await _persist();
    notifyListeners();
  }

  Future<void> reset() async {
    overrides = {};
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      'haneoka-chart-shortcuts-v1',
      jsonEncode({'version': 1, 'bindings': overrides}),
    )) {
      throw const FormatException('shortcut_storage');
    }
  }
}

class ChartShortcutSettings extends StatefulWidget {
  const ChartShortcutSettings({super.key, required this.shortcuts});
  final ChartShortcuts shortcuts;
  @override
  State<ChartShortcutSettings> createState() => _ChartShortcutSettingsState();
}

class _ChartShortcutSettingsState extends State<ChartShortcutSettings> {
  String t(String key) => AppScope.of(context).text('editors.chart.$key', key);
  Future<void> record(String id) async {
    String? binding;
    bool conflict = false;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(t('shortcuts.recording')),
          content: Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.handled;
              final next = chartBinding(event);
              if (next != null) {
                set(() {
                  binding = next;
                  conflict = chartShortcutCommands.any(
                    (command) =>
                        command.id != id &&
                        widget.shortcuts.bindings(command.id).contains(next),
                  );
                });
              }
              return KeyEventResult.handled;
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(binding ?? '—'),
                if (conflict) Text(t('shortcuts.conflict')),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppScope.of(context).text('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: binding == null || conflict
                  ? null
                  : () => Navigator.pop(context, binding),
              child: Text(AppScope.of(context).text('common.actions.save')),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await widget.shortcuts.save(
        id,
        {...widget.shortcuts.bindings(id), result}.take(4).toList(),
      );
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(t('shortcuts.title')),
    children: [
      TextButton(
        onPressed: () async {
          await widget.shortcuts.reset();
          if (mounted) setState(() {});
        },
        child: Text(t('shortcuts.reset')),
      ),
      for (final command in chartShortcutCommands)
        ListTile(
          title: Text(
            command.label.startsWith('1/') ? command.label : t(command.label),
          ),
          subtitle: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final binding in widget.shortcuts.bindings(command.id))
                InputChip(
                  label: Text(
                    binding
                        .replaceAll('Mod+', 'Ctrl/⌘+')
                        .replaceAll('Key', '')
                        .replaceAll('Digit', ''),
                  ),
                  onDeleted: () async {
                    await widget.shortcuts.save(
                      command.id,
                      widget.shortcuts
                          .bindings(command.id)
                          .where((value) => value != binding)
                          .toList(),
                    );
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
          trailing: IconButton(
            tooltip: t('shortcuts.add'),
            icon: const Icon(Icons.add),
            onPressed: () => record(command.id),
          ),
        ),
    ],
  );
}
