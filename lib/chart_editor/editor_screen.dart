import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cassiopeia_plugin_our_notes/render_profile.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_state.dart';
import '../rendering/native_chart_document.dart';
import '../rendering/native_chart_input.dart';
import '../rendering/native_chart_player_screen.dart';
import '../shell/page.dart';
import 'canvas.dart';
import 'controller.dart';
import 'authoring_actions.dart';
import 'connectors.dart';
import 'community_source.dart';
import 'formats.dart';
import 'inspector.dart';
import 'library.dart';
import 'project.dart';
import 'editing.dart';
import 'publication.dart';
import 'usc.dart';
import 'native_compile.dart';
import 'mmws.dart';
import 'sus_export.dart';
import 'feedback.dart';
import 'diagnostics.dart';

class ChartEditorScreen extends StatefulWidget {
  const ChartEditorScreen({super.key, this.initialQuery = const {}});
  final Map<String, String> initialQuery;
  @override
  State<ChartEditorScreen> createState() => _ChartEditorScreenState();
}

class _ChartEditorScreenState extends State<ChartEditorScreen> {
  late final controller = ChartEditorController()..addListener(_changed);
  final focus = FocusNode();
  String? _shownError;
  bool _routeCurrent = true;
  ChartEditorController get c => controller;
  String t(String key) => AppScope.of(context).text('editors.chart.$key');
  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await controller.initialize(
      openLast: widget.initialQuery['communityId'] == null,
    );
    if (!mounted) return;
    if (widget.initialQuery['communityId'] != null) {
      try {
        await openCommunityEditor(c, widget.initialQuery);
      } catch (_) {
        c.error = 'loadFailed';
        c.changed();
      }
    } else if (widget.initialQuery['provider'] == 'bestdori' &&
        widget.initialQuery['songId'] != null) {
      await _library(bestdori: true, linked: widget.initialQuery);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    c.feedback ??= EditorAudioFeedback(c, AppScope.of(context))..initialize();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeCurrent && !current) unawaited(c.audio.pause());
    _routeCurrent = current;
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (c.error != null && c.error != _shownError) {
      _shownError = c.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final text = AppScope.of(context).text;
        final key = 'editors.chart.creation.${c.error}', copy = text(key);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(copy.isEmpty ? t('creation.invalid_edit') : copy),
          ),
        );
      });
    }
    if (c.error == null) _shownError = null;
  }

  Future<bool> _confirm(String title) async {
    final text = AppScope.of(context).text;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t(title)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(text('common.actions.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(text('common.actions.confirm')),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _pickAudio() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'ogg', 'flac', 'm4a', 'aac'],
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 64 * 1024 * 1024) {
      c.error = 'audio_size';
      c.changed();
      return;
    }
    final root = await getTemporaryDirectory(),
        temporary = File(
          p.join(root.path, '${chartId('audio')}${p.extension(file.name)}'),
        );
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      await c.loadAudio(temporary, name: file.name);
    } finally {
      await temporary.delete();
    }
  }

  Future<void> _pickChart({bool backup = false}) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: backup
          ? const ['zip']
          : const ['json', 'ss', 'sus', 'usc', 'mmws', 'ccmmws', 'ucmmws'],
    );
    if (file == null || !mounted) return;
    if (!backup &&
        c.project.nodes.isNotEmpty &&
        !await _confirm('importChartConfirm')) {
      return;
    }
    final bytes = await file.readAsBytes();
    if (backup) {
      await c.importBackup(bytes);
    } else {
      if (isMmws(bytes)) {
        await c.importProject(
          importMmws(bytes),
          source: {'name': file.name, 'bytes': base64Encode(bytes)},
        );
      } else {
        await c.importText(utf8.decode(bytes), name: file.name);
      }
    }
  }

  Future<void> _export(String format) => c.perform(() async {
    await c.audio.pause();
    final captured = c.history.value;
    if (format != 'backup') {
      final check = validateChartExport(captured, format);
      if (check.errors.isNotEmpty || check.warnings.isNotEmpty) {
        if (!mounted) return;
        final issues = [...check.errors, ...check.warnings];
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              '${t('creation.export_chart')} · ${format.toUpperCase()}',
            ),
            content: SizedBox(
              width: 560,
              height: math.min(360, issues.length * 96).toDouble(),
              child: ListView.builder(
                itemCount: issues.length,
                itemBuilder: (context, index) {
                  final issue = issues[index];
                  final label = t(
                    'creation.export_${issue.code.split('.').last}',
                  );
                  return ListTile(
                    leading: Icon(
                      issue.warning
                          ? Symbols.warning_rounded
                          : Symbols.error_rounded,
                    ),
                    title: Text(
                      label.isEmpty ? t('creation.invalid_edit') : label,
                    ),
                    subtitle: SelectableText(issue.path),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  if (ModalRoute.of(context)?.isCurrent == true) {
                    Navigator.pop(context, false);
                  }
                },
                child: Text(AppScope.of(context).text('common.actions.cancel')),
              ),
              if (check.errors.isEmpty)
                FilledButton(
                  onPressed: () {
                    if (ModalRoute.of(context)?.isCurrent == true) {
                      Navigator.pop(context, true);
                    }
                  },
                  child: Text(
                    AppScope.of(context).text('common.actions.export'),
                  ),
                ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
      }
    }
    final name = '${captured.meta['title']}'.trim().replaceAll(
      RegExp(r'[\\/:*?"<>|\x00-\x1f]'),
      '_',
    );
    final base = name.isEmpty ? 'chart' : name;
    if (format == 'backup') {
      await c.save();
      final bytes = await c.store.exportArchive(c.id);
      await FilePicker.saveFile(fileName: '$base.zip', bytes: bytes);
      return;
    }
    if (format == 'sus') {
      await FilePicker.saveFile(
        fileName: '$base.sus',
        bytes: Uint8List.fromList(utf8.encode(serializeSus(captured))),
      );
      return;
    }
    if (format == 'mmws') {
      await FilePicker.saveFile(
        fileName: '$base.ccmmws',
        bytes: serializeMmws(captured),
      );
      return;
    }
    final text = switch (format) {
      'ss' => serializeSsChart(captured),
      'usc' => serializeUscChart(captured, wrapped: true),
      _ => serializeChartProject(captured),
    };
    await FilePicker.saveFile(
      fileName: '$base${format == 'project' ? '.project' : '.$format'}.json',
      bytes: Uint8List.fromList(utf8.encode(text)),
    );
  });

  Future<void> _files() async {
    final text = AppScope.of(context).text;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t('file')),
        children: [
          for (final (key, label) in [
            ('new', 'newProject'),
            ('import', 'importLocalChart'),
            ('audio', 'importLocalAudio'),
            ('library', 'serverLibrary'),
            ('gbp', 'importGbp'),
            ('backup', 'creation.open_backup'),
            ('copy', 'creation.save_copy'),
            ('restore', 'creation.restore_original'),
            ('project', 'formatProject'),
            ('ss', 'formatSs'),
            ('usc', 'formatUsc'),
            ('mmws', 'formatMmws'),
            ('sus', 'formatSus'),
            ('export-backup', 'creation.open_backup'),
            ('delete', 'creation.delete_project'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  key == 'export-backup'
                      ? text('common.actions.export')
                      : t(label),
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted) return;
    switch (selected) {
      case 'new':
        if (await _confirm('newProjectConfirm')) await c.newProject();
      case 'import':
        await _pickChart();
      case 'audio':
        await _pickAudio();
      case 'library':
        await _library();
      case 'gbp':
        await _library(bestdori: true);
      case 'backup':
        await _pickChart(backup: true);
      case 'copy':
        await c.saveCopy();
      case 'restore':
        await c.restoreOriginal();
      case 'project' || 'ss' || 'usc' || 'mmws' || 'sus':
        await _export(selected!);
      case 'export-backup':
        await _export('backup');
      case 'delete':
        if (await _confirm('creation.delete_project_confirm')) {
          await c.deleteProject();
        }
    }
  }

  Future<void> _projects() async {
    await c.save();
    final docs = await c.store.list();
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('creation.projects')),
        content: SizedBox(
          width: 520,
          height: 400,
          child: ListView(
            children: [
              for (final doc in docs)
                ListTile(
                  title: Text(
                    '${doc['title']}'.isEmpty
                        ? t('newProject')
                        : '${doc['title']}',
                  ),
                  subtitle: Text('${doc['head']}'),
                  selected: doc['id'] == c.id,
                  onTap: () => Navigator.pop(context, '${doc['id']}'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppScope.of(context).text('common.actions.close')),
          ),
        ],
      ),
    );
    if (chosen != null) await c.openProject(chosen);
  }

  Future<void> _versions() async {
    final versions = await c.store.versions(c.id);
    if (!mounted) return;
    final revision = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('creation.versions')),
        content: SizedBox(
          width: 400,
          height: 360,
          child: ListView(
            children: [
              for (final row in versions)
                ListTile(
                  title: Text('${row['revision']}'),
                  subtitle: Text(
                    DateTime.fromMillisecondsSinceEpoch(row['savedAt'] as int)
                        .toLocal()
                        .toString()
                        .split('.')
                        .first,
                  ),
                  selected: row['revision'] == c.head,
                  onTap: () => Navigator.pop(context, row['revision'] as int),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppScope.of(context).text('common.actions.close')),
          ),
        ],
      ),
    );
    if (revision != null) await c.openProject(c.id, revision: revision);
  }

  Future<void> _properties() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .9,
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) => ChartEditorInspector(controller: c),
        ),
      ),
    );
  }

  Future<void> _preview() async {
    final state = AppScope.of(context);
    await c.audio.pause();
    if (!mounted) return;
    final project = c.history.value, media = c.media;
    if (media == null) return;
    final api = state.api;
    NativeChartDocument? document;
    await c.perform(() async {
      final release = await api.release(),
          file = await c.store.previewFile(c.id, serializeSsChart(project));
      final native =
          const {
            'ss',
            'authored',
          }.contains(project.meta['source'] ?? 'authored')
          ? compileNativeEditorChart(project)
          : null;
      document = NativeChartDocument(
        source: RenderSource(
          server: api.server,
          release: release,
          document: 'editor:${c.id}:${c.history.revision}',
        ),
        sourceId: api.sourceId,
        resourceBase: Uri.parse(api.origin),
        scoreUri: file.uri,
        musicUri: media.file.uri,
        bandId: 1,
        title: '${project.meta['title']}',
        difficulty: 3,
        canonicalSong: {
          'musicTitle': {'ja': project.meta['title']},
          'bandId': 1,
          'musicType': 1,
        },
        audioOffsetMs: project.audioOffset * 1000,
        chart:
            native?.chart ??
            authoredPresentationChart(project, media.ref.duration),
        visualProfiles: native?.profiles,
        timeScaleChanges: [
          for (final event in project.timeScales)
            (
              timeMs:
                  TempoMap(project.tempos).secondsAt(event['tick'] as int) *
                  1000,
              scale: (event['scale'] as num).toDouble(),
            ),
        ],
      );
    });
    if (!mounted || document == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            NativeChartPlayerScreen(document: document, difficulty: 3),
      ),
    );
  }

  Future<void> _library({
    bool bestdori = false,
    Map<String, String>? linked,
  }) async {
    await c.audio.pause();
    if (!mounted) return;
    final selected = await openChartLibrary(
      context,
      bestdori: bestdori,
      linked: linked,
    );
    if (selected != null && mounted) {
      await importChartLibrarySelection(c, selected, AppScope.of(context).text);
    }
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null) {
      return KeyEventResult.ignored;
    }
    final command = c.shortcuts.match(event);
    if (command == null) return KeyEventResult.ignored;
    _command(command);
    return KeyEventResult.handled;
  }

  void _command(String command) {
    if (command.startsWith('tool:')) {
      c.tool = command.substring(5);
      c.cancelGesture();
      return;
    }
    if (command.startsWith('grid:')) {
      c.division = int.parse(command.substring(5));
      c.changed();
      return;
    }
    switch (command) {
      case 'save':
        unawaited(c.save());
      case 'undo':
        c.undo();
      case 'redo':
        c.redo();
      case 'play':
        unawaited(c.togglePlayback());
      case 'cancel':
        c.cancelGesture();
        c.select([]);
      case 'confirm':
        c.insertControl(c.positionTick);
      case 'select_all':
        c.select(
          c.project.nodes
              .where((node) => c.scope.contains(node.id))
              .map((node) => node.id),
        );
      case 'copy':
        unawaited(c.copy());
      case 'copy_segments':
        unawaited(c.copy(segments: true));
      case 'cut':
        unawaited(c.copy(cut: true));
      case 'paste':
        unawaited(c.paste());
      case 'paste_mirrored':
        unawaited(
          Clipboard.getData(Clipboard.kTextPlain).then((data) {
            if (data?.text != null) {
              c.applyPattern(chartMap(jsonDecode(data!.text!)), mirrored: true);
            }
          }),
        );
      case 'duplicate':
        c.duplicateSelection();
      case 'duplicate_mirrored':
        c.duplicateSelection(mirrored: true);
      case 'delete':
        c.deleteSelection();
      case 'flip':
        c.flip();
      case 'join':
        c.joinConnectors();
      case 'split':
        c.splitConnector();
      case 'repeat':
        c.repeatConnector();
      case 'generate_nodes':
        c.generatePoints();
      case 'remove_nodes':
        c.deleteSelection(controlsOnly: true);
      case 'generate_traces':
        c.connectorTraces();
      case 'convert_traces':
        c.connectorTraces(keepLines: false);
      case 'compress_first':
        c.compressSelection(false);
      case 'compress_last':
        c.compressSelection(true);
      case 'nudge_up':
        c.nudge(1);
      case 'nudge_down':
        c.nudge(-1);
      case 'tick_up' || 'tick_down':
        c.edit(
          (p) => moveChartSelection(
            p,
            c.selection,
            command == 'tick_up' ? 1 : -1,
            0,
          ),
        );
      case 'width_up' || 'width_down' || 'width_up_large' || 'width_down_large':
        final node = c.renderNodesById[c.primary],
            delta = command.endsWith('large') ? 1.0 : .25;
        if (node != null) {
          c.brush({
            'size': math.max(
              0,
              node.size + (command.startsWith('width_up') ? delta : -delta),
            ),
          });
        }
      case 'zoom_in' || 'zoom_out':
        c.secondsPerScreen =
            (c.secondsPerScreen * (command == 'zoom_in' ? 0.8 : 1.25)).clamp(
              .5,
              120,
            );
        c.changed();
      case 'pan_up' || 'pan_down' || 'page_up' || 'page_down':
        c.windowStart = math.max(
          0,
          c.windowStart +
              (command.endsWith('up') ? 1 : -1) *
                  c.secondsPerScreen *
                  (command.startsWith('page') ? 0.9 : 0.1),
        );
        c.changed();
      case 'pan_left' || 'pan_right':
        c.laneStart += command == 'pan_left' ? -1 : 1;
        c.changed();
      case 'home':
        unawaited(c.seek(0));
        c.windowStart = 0;
        c.changed();
      case 'end':
        unawaited(c.seek(c.duration));
        c.windowStart = math.max(0, c.duration - c.secondsPerScreen);
        c.changed();
      case 'audio_settings':
        unawaited(_properties());
      case 'note_sounds':
        unawaited(
          c.feedback?.configure(noteSounds: !(c.feedback?.notes ?? false)) ??
              Future<void>.value(),
        );
      case 'metronome':
        unawaited(
          c.feedback?.configure(beat: !(c.feedback?.metronome ?? false)) ??
              Future<void>.value(),
        );
      case 'previous_waypoint' || 'next_waypoint':
        final points =
            chartRows(c.project.data['waypoints'] ?? [])
                .map((row) => row['tick'] as int)
                .where(
                  (tick) => command == 'next_waypoint'
                      ? tick > c.positionTick
                      : tick < c.positionTick,
                )
                .toList()
              ..sort();
        if (points.isNotEmpty) {
          unawaited(
            c.seek(
              c.tempoMap.secondsAt(
                command == 'next_waypoint' ? points.first : points.last,
              ),
            ),
          );
        }
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = AppScope.of(context).text,
        colors = Theme.of(context).colorScheme;
    return Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: _key,
      child: ShellPage(
        title: t('creation.title'),
        status: SizedBox(
          width: 48,
          child: Center(
            child: c.saving || c.busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Tooltip(
                    message: c.error != null
                        ? t('creation.invalid_edit')
                        : c.dirty
                        ? t('saveFailed')
                        : t('autosaved'),
                    child: Icon(
                      c.error != null
                          ? Symbols.error_rounded
                          : c.dirty
                          ? Symbols.edit_rounded
                          : Symbols.save_rounded,
                      size: 20,
                    ),
                  ),
          ),
        ),
        actions: [
          BarAction(
            icon: Symbols.folder_rounded,
            label: t('file'),
            onPressed: c.busy ? null : _files,
          ),
          BarAction(
            icon: Symbols.folder_open_rounded,
            label: t('creation.projects'),
            onPressed: c.busy ? null : _projects,
          ),
          BarAction(
            icon: Symbols.history_rounded,
            label: t('creation.versions'),
            onPressed: c.busy ? null : _versions,
          ),
          BarAction(
            icon: Symbols.save_rounded,
            label: t('creation.save'),
            onPressed: c.busy ? null : () => c.save(),
          ),
          BarAction(
            icon: Symbols.undo_rounded,
            label: t('undo'),
            onPressed: !c.busy && c.history.canUndo ? c.undo : null,
          ),
          BarAction(
            icon: Symbols.redo_rounded,
            label: t('redo'),
            onPressed: !c.busy && c.history.canRedo ? c.redo : null,
          ),
          BarAction(
            icon: Symbols.tune_rounded,
            label: t('inspector'),
            onPressed: _properties,
          ),
          BarAction(
            icon: Symbols.cloud_upload_rounded,
            label: AppScope.of(context)
                .text('community.charts.publishToCommunity'),
            onPressed: c.busy ? null : () => showChartPublication(context, c),
          ),
          BarAction(
            icon: Symbols.play_circle_rounded,
            label: t('preview'),
            onPressed: c.busy || c.media == null ? null : _preview,
          ),
        ],
        body: c.media == null
            ? Center(
                child: c.busy
                    ? const CircularProgressIndicator()
                    : FilledButton.tonal(
                        onPressed: _initialize,
                        child: Text(text('common.actions.retry')),
                      ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 900;
                  final canvas = Column(
                    children: [
                      Expanded(child: ChartEditorCanvas(controller: c)),
                      _transport(context),
                    ],
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: canvas),
                      if (wide) ...[
                        VerticalDivider(width: 1, color: colors.outlineVariant),
                        SizedBox(
                          width: 320,
                          child: ChartEditorInspector(controller: c),
                        ),
                      ],
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _transport(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ValueListenableBuilder<Duration>(
            valueListenable: c.audio.position,
            builder: (context, position, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: position.inMicroseconds.toDouble().clamp(
                    0,
                    c.duration * 1000000,
                  ),
                  max: math.max(1, c.duration * 1000000),
                  onChangeStart: (_) => unawaited(c.audio.pause()),
                  onChanged: (v) => c.seek(v / 1000000),
                ),
                Row(
                  children: [
                    IconButton(
                      onPressed: c.togglePlayback,
                      tooltip: AppScope.of(context).text(
                        c.audio.playing
                            ? 'common.actions.pause'
                            : 'common.actions.play',
                      ),
                      icon: Icon(
                        c.audio.playing
                            ? Symbols.pause_rounded
                            : Symbols.play_arrow_rounded,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${(position.inMilliseconds / 1000).toStringAsFixed(2)} / ${c.duration.toStringAsFixed(2)}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    PopupMenuButton<double>(
                      tooltip: t('playbackSpeed'),
                      initialValue: c.playbackRate,
                      onSelected: c.setRate,
                      itemBuilder: (context) => [
                        for (final rate in [.25, .5, .75, 1.0, 1.25, 1.5, 2.0])
                          PopupMenuItem(value: rate, child: Text('$rate×')),
                      ],
                      child: SizedBox(
                        width: 52,
                        height: 48,
                        child: Center(child: Text('${c.playbackRate}×')),
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        c.windowStart = math.max(0, c.position - 1);
                        c.changed();
                      },
                      tooltip: t('creation.follow'),
                      icon: const Icon(Symbols.my_location_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
