import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/audio_track.dart';
import '../account/haneoka_account.dart' show AccountError;
import '../core/media_lifecycle.dart';
import '../core/page_audio.dart';
import 'audio.dart';
import 'chart_input.dart';
import 'editing.dart';
import 'formats.dart';
import 'project.dart';
import 'storage.dart';
import 'shortcuts.dart';
import 'feedback.dart';

typedef ChartEditorImport = ({
  ChartImport? chart,
  NativeChartAudio? audio,
  ChartMap? source,
});

class ChartEditorController extends ChangeNotifier {
  ChartEditorController() {
    MediaLifecycle.register(this, close);
    audio.addListener(changed);
  }
  final store = ChartCreationStore();
  final shortcuts = ChartShortcuts();
  EditorAudioFeedback? feedback;
  final history = ChartHistory(ChartProject.empty());
  final audio = PageAudio();
  NativeChartAudio? media;
  ChartProject original = ChartProject.empty();
  ChartAudioRef? originalAudio;
  ChartMap? source;
  String id = chartId('project');
  int head = 0,
      _savedRevision = -1,
      _mediaRevision = 0,
      _savedMediaRevision = -1;
  bool busy = false, saving = false, _closed = false;
  String? error;
  List<ChartIssue> warnings = [];
  List<ChartMap> documents = [], revisions = [];
  final selection = <String>{};
  String? primary, group, layer;
  String tool = 'select', direction = 'up';
  bool critical = false,
      multiSelect = false,
      relativeSnap = false,
      follow = true;
  int division = 4, positionTick = 0;
  double noteWidth = 4,
      windowStart = 0,
      secondsPerScreen = 8,
      zoomX = 1,
      laneStart = -2;
  double playbackRate = 1, volume = 82;
  ChartProject? gesture;
  int gestureCancellation = 0;
  Timer? _autosave;
  Future<void> _writes = Future.value(), _operation = Future.value();
  bool _disposed = false;
  Future<void>? _closing;
  ChartProject get project => gesture ?? history.snapshot;
  ChartProject? _tempoProject;
  TempoMap? _tempoMap;
  TempoMap get tempoMap {
    final current = project;
    if (!identical(_tempoProject, current)) {
      _tempoProject = current;
      _tempoMap = current.tempoMap;
    }
    return _tempoMap!;
  }

  bool get dirty =>
      history.revision != _savedRevision ||
      _mediaRevision != _savedMediaRevision;
  double get position => audio.position.value.inMicroseconds / 1000000;
  double get duration => media?.ref.duration ?? 16;
  double get laneSpan => (project.laneBasis + project.laneBasis / 6) / zoomX;
  ChartProject? _nodeProject, _scopeProject;
  List<ChartNode> _nodes = [];
  Map<String, ChartNode> _nodesById = {};
  (String?, String?)? _scopeKey;
  Set<String> _scopeIds = {};
  List<ChartNode> get renderNodes {
    final current = project;
    if (!identical(_nodeProject, current)) {
      _nodeProject = current;
      _nodes = current.nodes.toList();
      _nodesById = {for (final node in _nodes) node.id: node};
    }
    return _nodes;
  }

  Map<String, ChartNode> get renderNodesById {
    renderNodes;
    return _nodesById;
  }

  Set<String> get scope {
    final current = project, key = (group, layer);
    if (!identical(_scopeProject, current) || _scopeKey != key) {
      _scopeProject = current;
      _scopeKey = key;
      _scopeIds = chartScope(current, group: group, layer: layer);
    }
    return _scopeIds;
  }

  void changed() {
    if (!_closed && !_disposed) notifyListeners();
  }

  Future<void> initialize({bool openLast = true}) => perform(() async {
    await store.open();
    await shortcuts.load();
    documents = await store.list();
    if (!openLast) return;
    if (documents.isNotEmpty) {
      await _open('${documents.first['id']}');
    } else {
      await _new();
    }
  });
  Future<void> perform(Future<void> Function() action) {
    final result = _operation.then((_) async {
      if (_closed || _closing != null) return;
      busy = true;
      error = null;
      changed();
      try {
        await action();
      } catch (e) {
        error = e is FormatException
            ? e.message
            : e is AccountError
            ? e.code
            : 'loadFailed';
      } finally {
        busy = false;
        changed();
      }
    });
    _operation = result.catchError((Object _) {});
    return result;
  }

  Future<void> _installAudio(NativeChartAudio value) async {
    final previous = media;
    media = value;
    _mediaRevision++;
    await audio.loadPaused(
      Track(
        id: 'chart:$id:${value.ref.sha}',
        title: '${project.meta['title']}',
        url: value.file.uri.toString(),
      ),
    );
    await audio.configure(rate: playbackRate, volume: volume);
    if (previous != null && !identical(previous, value)) await previous.close();
  }

  Future<void> newProject() => perform(() async {
    await flush();
    await _new();
  });
  Future<void> _new() async {
    _autosave?.cancel();
    await audio.pause();
    id = chartId('project');
    head = 0;
    source = null;
    group = layer = primary = null;
    selection.clear();
    gesture = null;
    final empty = ChartProject.empty({'source': 'authored'});
    history.reset(empty);
    original = empty.copy();
    final decoded = await decodeChartAudio(
      store,
      await chartExampleAudio(),
      name: 'example.wav',
    );
    await _installAudio(decoded);
    originalAudio = decoded.ref;
    resetView();
    await save();
  }

  Future<void> openProject(String id, {int? revision}) => perform(() async {
    await flush();
    await _open(id, revision: revision);
  });
  Future<void> _open(String value, {int? revision}) async {
    _autosave?.cancel();
    await audio.pause();
    final opened = await store.read(value, revision: revision);
    id = value;
    head = opened.head;
    original = opened.original;
    originalAudio = ChartAudioRef.fromJson(opened.document['originalAudio']);
    source = opened.document['source'] is Map
        ? chartMap(opened.document['source'])
        : null;
    history.reset(opened.project);
    _savedRevision = history.revision;
    group = layer = primary = null;
    selection.clear();
    gesture = null;
    final decoded = await decodeChartAudio(
      store,
      opened.audioFile,
      name: opened.audio.name,
      type: opened.audio.type,
    );
    await _installAudio(decoded);
    _savedMediaRevision = _mediaRevision;
    revisions = await store.versions(id);
    resetView();
    if (revision != null && revision != head) {
      _savedRevision = -1;
      scheduleSave();
    }
  }

  void resetView() {
    windowStart = 0;
    secondsPerScreen = 8;
    zoomX = 1;
    laneStart = -project.laneBasis / 12;
    positionTick = 0;
    changed();
  }

  void scheduleSave() {
    _autosave?.cancel();
    _autosave = Timer(
      const Duration(milliseconds: 900),
      () => unawaited(save()),
    );
  }

  Future<void> save() {
    _autosave?.cancel();
    final result = _writes.then((_) async {
      final media = this.media;
      if (_closed || media == null || !dirty) return;
      final capturedId = id,
          revision = history.revision,
          mediaRevision = _mediaRevision;
      final captured = history.value;
      saving = true;
      changed();
      try {
        final document = await store.save(
          capturedId,
          head,
          captured,
          media.ref,
          original,
          source: source,
          originalAudio: originalAudio,
        );
        if (_closed || id != capturedId) return;
        head = document['head'] as int;
        _savedRevision = revision;
        _savedMediaRevision = mediaRevision;
        documents = await store.list();
        revisions = await store.versions(capturedId);
        error = null;
      } catch (e) {
        error = e is FormatException ? e.message : 'save_failed';
      } finally {
        saving = false;
        changed();
      }
    });
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<void> flush() async {
    if (media == null && head == 0) return;
    await save();
    if (dirty) throw FormatException(error ?? 'save_failed');
  }

  Future<void> saveCopy() => perform(() async {
    await flush();
    final chart = history.value;
    id = chartId('project');
    head = 0;
    _savedRevision = -1;
    original = chart.copy();
    originalAudio = media?.ref;
    await save();
  });
  Future<void> restoreOriginal() => perform(() async {
    final ref = originalAudio;
    if (ref == null) return;
    history.reset(original);
    selection.clear();
    primary = null;
    await _installAudio(
      await decodeChartAudio(
        store,
        store.audioFile(ref),
        name: ref.name,
        type: ref.type,
      ),
    );
    scheduleSave();
  });
  Future<void> deleteProject() => perform(() async {
    _autosave?.cancel();
    await _writes;
    await store.delete(id);
    documents = await store.list();
    if (documents.isNotEmpty) {
      await _open('${documents.first['id']}');
    } else {
      await _new();
    }
  });
  Future<void> loadAudio(File file, {String? name}) => perform(() async {
    await audio.pause();
    await _installAudio(await decodeChartAudio(store, file, name: name));
    scheduleSave();
  });
  Future<void> importResource(Future<ChartEditorImport> Function() load) =>
      perform(() async {
        final value = await load();
        if (value.chart != null) {
          await _importProject(
            value.chart!,
            source: value.source,
            audio: value.audio,
          );
        } else if (value.audio != null) {
          await _installAudio(value.audio!);
          scheduleSave();
        }
      });
  Future<void> importText(String text, {String name = 'chart.json'}) =>
      perform(() async {
        await _importProject(
          importChartInput(text),
          source: {'name': name, 'text': text},
        );
      });
  Future<void> importProject(
    ChartImport result, {
    ChartMap? source,
    NativeChartAudio? audio,
  }) => perform(() => _importProject(result, source: source, audio: audio));
  Future<void> _importProject(
    ChartImport result, {
    ChartMap? source,
    NativeChartAudio? audio,
  }) async {
    chartCollections(result.project);
    await flush();
    await this.audio.pause();
    id = chartId('project');
    head = 0;
    original = result.project.copy();
    history.reset(result.project);
    warnings = result.warnings;
    this.source = source;
    if (audio != null) await _installAudio(audio);
    originalAudio = media?.ref;
    group = layer = primary = null;
    selection.clear();
    gesture = null;
    _savedRevision = -1;
    resetView();
    await save();
  }

  Future<void> importBackup(Uint8List bytes) => perform(() async {
    await flush();
    await _open(await store.importArchive(bytes));
  });
  bool edit(void Function(ChartProject) change, {String? mergeKey}) {
    if (busy || _closed) return false;
    try {
      final changed = history.update((draft) {
        final before = draft.copy();
        change(draft);
        draft.sort();
        reconcileChartCollections(draft);
        requireEditedChartSpans(before, draft);
      }, mergeKey: mergeKey);
      if (changed) {
        error = null;
        pruneSelection();
        scheduleSave();
        this.changed();
      }
      return changed;
    } catch (_) {
      error = 'invalid_edit';
      changed();
      return false;
    }
  }

  void pruneSelection() {
    selection.retainAll(chartEntityIds(project));
    if (!selection.contains(primary)) primary = selection.firstOrNull;
  }

  void undo() {
    if (busy) return;
    history.undo();
    gesture = null;
    pruneSelection();
    scheduleSave();
    changed();
  }

  void redo() {
    if (busy) return;
    history.redo();
    gesture = null;
    pruneSelection();
    scheduleSave();
    changed();
  }

  void select(Iterable<String> ids, {bool add = false}) {
    if (!add) selection.clear();
    selection.addAll(ids);
    primary = ids.firstOrNull ?? selection.firstOrNull;
    changed();
  }

  void place(int tick, double lane) {
    final idList = <String>[];
    if (edit((project) {
      final note = authoredChartNote(
        project,
        tick,
        lane,
        noteWidth,
        type: tool,
        direction: direction,
        critical: critical,
      );
      idList.add('${note['id']}');
      (project.data['singles'] as List).add(note);
      if (group != null || layer != null) {
        assignChartSelection(project, idList.toSet(), {
          'groupId': group,
          'layerId': layer,
        });
      }
    })) {
      select(idList);
    }
  }

  void addLine(int fromTick, double fromLane, int toTick, double toLane) {
    if (toTick < fromTick) {
      error = 'line_order';
      changed();
      return;
    }
    final ids = <String>[];
    if (edit((project) {
      final first = authoredChartNote(
        project,
        fromTick,
        fromLane - noteWidth / 2,
        noteWidth,
        critical: critical,
      );
      final last = authoredChartNote(
        project,
        toTick,
        toLane - noteWidth / 2,
        noteWidth,
        critical: critical,
      );
      for (final note in [first, last]) {
        note['ease'] = {'left': 'linear', 'right': 'linear'};
        ids.add('${note['id']}');
      }
      final line = {
        'id': chartId('line'),
        'kind': tool == 'guide' ? 'guide' : 'long',
        'points': [first, last],
      };
      (project.data['lines'] as List).add(line);
      if (group != null || layer != null) {
        assignChartSelection(project, ids.toSet(), {
          'groupId': group,
          'layerId': layer,
        });
      }
    })) {
      select(ids);
    }
  }

  void brush(ChartMap patch, {String anchor = 'left'}) => edit(
    (project) => brushChartSelection(project, selection, patch, anchor: anchor),
  );
  void flip() => edit((project) => flipChartSelection(project, selection));
  void deleteSelection({bool controlsOnly = false}) => edit(
    (project) =>
        deleteChartSelection(project, selection, controlsOnly: controlsOnly),
  );
  void generatePoints() {
    final created = <String>[];
    if (edit(
      (project) =>
          created.addAll(generateChartPoints(project, selection, division)),
    )) {
      select(created);
    }
  }

  void nudge(int direction, {bool horizontal = false}) {
    final anchor = project.nodes.where((n) => n.id == primary).firstOrNull;
    if (anchor == null) return;
    final target = snapChartTick(
      anchor.tick,
      division,
      mode: direction > 0 ? 'ceil' : 'floor',
    );
    final tick = target == anchor.tick
        ? snapChartTick(
            anchor.tick + direction,
            division,
            mode: direction > 0 ? 'ceil' : 'floor',
          )
        : target;
    edit(
      (project) => moveChartSelection(
        project,
        selection,
        horizontal ? 0 : tick - anchor.tick,
        horizontal ? direction.toDouble() : 0,
      ),
    );
  }

  Future<void> copy({bool cut = false, bool segments = false}) async {
    if (selection.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(
        text: jsonEncode(
          segments
              ? copyChartSegments(project, selection)
              : copyChartSelection(project, selection),
        ),
      ),
    );
    if (cut) deleteSelection();
  }

  Future<void> paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null) return;
    try {
      final clipboard = chartMap(jsonDecode(text)), ids = <String>{};
      if (edit(
        (project) =>
            ids.addAll(pasteChartSelection(project, clipboard, positionTick)),
      )) {
        select(ids);
      }
    } catch (_) {
      error = 'invalid_edit';
      changed();
    }
  }

  void cancelGesture() {
    gestureCancellation++;
    gesture = null;
    changed();
  }

  void previewMove(ChartProject before, int dt, double dl) {
    try {
      final next = before.copy();
      moveChartSelection(next, selection, dt, dl);
      next.requireValid();
      gesture = next;
      error = null;
    } catch (_) {
      gesture = null;
      error = 'invalid_edit';
    }
    changed();
  }

  void commitGesture() {
    final candidate = gesture;
    gesture = null;
    if (candidate != null) {
      edit((project) {
        project.data.clear();
        project.data.addAll(candidate.data);
      });
    }
    changed();
  }

  int snappedTick(double value, {int? relativeTo}) =>
      relativeSnap && relativeTo != null
      ? math.max(0, relativeTo + snapChartTick(value - relativeTo, division))
      : math.max(0, snapChartTick(value, division));
  Future<void> seek(double seconds) async {
    await audio.seek(
      Duration(microseconds: (seconds.clamp(0.0, duration) * 1000000).round()),
    );
    positionTick = math.max(0, project.tempoMap.tickAt(seconds).round());
    changed();
  }

  Future<void> togglePlayback() async {
    if (audio.playing) {
      await audio.pause();
    } else {
      await audio.resume();
    }
    changed();
  }

  Future<void> setRate(double value) async {
    playbackRate = value;
    await audio.configure(rate: value, volume: volume);
    changed();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    shortcuts.dispose();
    _autosave?.cancel();
    await _operation;
    await save();
    await _writes;
    _closed = true;
    audio.removeListener(changed);
    await feedback?.close();
    await audio.close();
    await media?.close();
    await store.close();
    MediaLifecycle.unregister(this);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
