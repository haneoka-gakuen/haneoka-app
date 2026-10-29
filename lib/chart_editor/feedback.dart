import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cassiopeia_runtime/native.dart';
import 'package:cassiopeia_plugin_our_notes/watch.dart';

import '../core/app_state.dart';
import '../core/net.dart';
import '../core/sound_effects.dart';
import '../rendering/native_chart_sounds.dart';
import '../rendering/native_chart_input.dart';
import '../chart/runtime_chart.dart';
import 'controller.dart';
import 'native_compile.dart';
import 'project.dart';

class EditorAudioFeedback extends ChangeNotifier {
  EditorAudioFeedback(this.controller, this.state) {
    controller.audio.position.addListener(observe);
    controller.audio.addListener(observe);
    controller.addListener(observe);
  }
  final ChartEditorController controller;
  final AppState state;
  double bgmVolume = .82, noteVolume = .7, metronomeVolume = .5;
  bool notes = false, metronome = false;
  int group = 1;
  String? error;
  bool _closed = false, _loading = false;
  int _generation = 0;
  NativeChartSounds? _sounds;
  SoundEffectBank? _click;
  OurNotesWatchPlayback? _playback;
  ChartProject? _project;
  RuntimeChart? _chart;
  String? _soundKey;
  int? _lastBeat;
  List<
    ({
      String family,
      bool complete,
      int pointCount,
      int startMicros,
      int endMicros,
    })
  >
  _holds = [];
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance(),
        raw = prefs.getString('haneoka-chart-audio-v1');
    if (raw != null) {
      try {
        final value = jsonDecode(raw) as Map;
        bgmVolume = (value['bgmVolume'] as num? ?? .82).clamp(0, 1).toDouble();
        noteVolume = (value['noteVolume'] as num? ?? .7).clamp(0, 1).toDouble();
        metronomeVolume = (value['metronomeVolume'] as num? ?? .5)
            .clamp(0, 1)
            .toDouble();
        notes = value['notes'] == true;
        metronome = value['metronome'] == true;
        group = (value['group'] as num? ?? 1).toInt().clamp(1, 4);
      } catch (_) {}
    }
    if (_closed) return;
    controller.volume = bgmVolume * 100;
    await controller.audio.configure(
      rate: controller.playbackRate,
      volume: controller.volume,
    );
    observe();
  }

  Future<void> configure({
    double? bgm,
    double? note,
    double? click,
    bool? noteSounds,
    bool? beat,
    int? soundGroup,
  }) async {
    bgmVolume = bgm ?? bgmVolume;
    noteVolume = note ?? noteVolume;
    metronomeVolume = click ?? metronomeVolume;
    notes = noteSounds ?? notes;
    metronome = beat ?? metronome;
    group = soundGroup ?? group;
    error = null;
    controller.volume = bgmVolume * 100;
    await controller.audio.configure(
      rate: controller.playbackRate,
      volume: controller.volume,
    );
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      'haneoka-chart-audio-v1',
      jsonEncode({
        'version': 1,
        'bgmVolume': bgmVolume,
        'noteVolume': noteVolume,
        'metronomeVolume': metronomeVolume,
        'notes': notes,
        'metronome': metronome,
        'group': group,
      }),
    )) {
      error = 'storage_failed';
    }
    if (_closed) return;
    observe();
    notifyListeners();
    controller.changed();
  }

  Future<void> _prepare() async {
    if (_loading || _closed) return;
    _loading = true;
    final generation = ++_generation;
    try {
      if (notes) {
        final api = state.api;
        await api.release();
        final key = '${state.server}:${api.sourceId}:$group';
        if (key != _soundKey) {
          final next = NativeChartSounds();
          try {
            await next.load(group, state.server, api.asset, (uri) async {
              final response = await netClient.get(uri);
              if (response.statusCode != 200) throw StateError('note-sound');
              return response.bodyBytes;
            });
          } catch (_) {
            await next.close();
            rethrow;
          }
          if (_closed || generation != _generation) {
            await next.close();
            return;
          }
          final old = _sounds;
          _sounds = next;
          _soundKey = key;
          await old?.close();
        }
      }
      if (metronome && _click == null) {
        final bank = SoundEffectBank();
        await bank.open({
          'beat': [EffectSoundLayer(Uri.parse('memory:beat'))],
          'bar': [EffectSoundLayer(Uri.parse('memory:bar'))],
        }, (uri) async => _wave(uri.path == 'bar' ? 1600 : 1000));
        if (_closed) {
          await bank.close();
          return;
        }
        _click = bank;
      }
    } catch (_) {
      if (!_closed) {
        error = 'feedback_failed';
        notifyListeners();
      }
    } finally {
      _loading = false;
    }
  }

  void observe() {
    if (_closed) return;
    if (notes || metronome) {
      final key = '${state.server}:${state.api.sourceId}:$group';
      if (notes && key != _soundKey || metronome && _click == null) {
        if (error == null) unawaited(_prepare());
      }
    }
    final audio = controller.audio,
        position = audio.position.value.inMicroseconds;
    if (!audio.playing) {
      unawaited(_sounds?.bank.stop() ?? Future<void>.value());
      unawaited(_click?.stop() ?? Future<void>.value());
      _lastBeat = null;
      _playback?.resetOnNextObservation();
      return;
    }
    if (notes) {
      try {
        final project = controller.project;
        if (!identical(_project, project)) {
          final chart = shiftNativeChart(
            compileNativeEditorChart(project).chart,
            project.audioOffset * 1000,
          );
          final notes = createOurNotesWatchNotes(
            enumeration: [
              for (final note in chart.enumeration)
                (
                  timeMs: note.timeMs,
                  operateType: note.operateType,
                  judgementType: note.judgementType,
                  judged: note.judged,
                ),
            ],
            bindings: [
              for (final note in chart.visualNotes)
                (sourceOrdinal: note.sourceOrdinal, id: note.id),
              for (final line in chart.visualLines)
                for (final note in [
                  ...line.comboEvents,
                  ...line.endComboEvents,
                ])
                  if (note.sourceOrdinal != null)
                    (sourceOrdinal: note.sourceOrdinal!, id: note.id),
            ],
          );
          final runtime = CassiopeiaNativeSession(
            library: openCassiopeiaNativeLibrary(),
          );
          runtime.loadNotes(
            notes,
            mode: CassiopeiaMode.watch,
            scoringComboPolicy: ourNotesScoringComboPolicy(
              CassiopeiaMode.watch,
            ),
          );
          _playback?.close();
          _playback = OurNotesWatchPlayback(
            sourceKey: 'editor:${controller.id}:${controller.history.revision}',
            runtime: runtime,
            notes: notes,
          );
          _chart = chart;
          _project = project;
          _holds = [
            for (final line in chart.visualLines)
              if (line.points.length > 1)
                (
                  family: line.family.name,
                  complete: line.completeGeometry,
                  pointCount: line.points.length,
                  startMicros: line.points.first.timeMicroseconds,
                  endMicros: line.points.last.timeMicroseconds,
                ),
          ];
        }
        final sample = _playback!.observe(
              mediaMicros: position,
              durationMs: controller.duration * 1000,
              playbackRate: controller.playbackRate,
              epoch: audio.revision,
              completed: audio.completed,
            ),
            cues = <String>{};
        if (!sample.value.historical && !sample.terminal) {
          for (final event in sample.value.events) {
            final note = _playback!.notesById[event.noteId]!;
            if (position - note.timeMicros > 100000) continue;
            final visual = _chart!.visualNotes
                .where((note) => note.id == event.noteId)
                .firstOrNull;
            final feedback = ourNotesWatchFeedback(
              noteTimeMs: note.timeMicros ~/ 1000,
              operateType: note.operateType.code,
              direction: visual?.direction ?? 0,
              judgement: event.judgement,
              differenceMicros: event.differenceMicros,
              judgedAtMicros: event.judgedAtMicros,
              mirror: false,
            );
            if (feedback.soundCue case final cue?) cues.add(cue);
          }
        }
        _sounds?.observe(
          cues,
          held: ourNotesWatchHoldActive(position, _holds),
          playing: !sample.value.historical && !sample.terminal,
          volume: noteVolume,
        );
      } catch (_) {
        unawaited(_sounds?.bank.stop() ?? Future<void>.value());
      }
    } else {
      unawaited(_sounds?.bank.stop() ?? Future<void>.value());
      _playback?.close();
      _playback = null;
      _project = null;
    }
    if (metronome) {
      final tick = controller.tempoMap.tickAt(position / 1000000),
          meters = controller.project.meters
              .where((row) => (row['tick'] as num) <= tick)
              .toList();
      final meter = meters.lastOrNull ?? controller.project.meters.first;
      final beat = 480 * 4 / (meter['denominator'] as num),
          index = ((tick - (meter['tick'] as num)) / beat).floor();
      final key = (meter['tick'] as int) * 4096 + index;
      if (_lastBeat != key && tick >= 0) {
        _lastBeat = key;
        _click?.emit(
          index % (meter['numerator'] as int) == 0 ? 'bar' : 'beat',
          metronomeVolume,
        );
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    controller.audio.position.removeListener(observe);
    controller.audio.removeListener(observe);
    controller.removeListener(observe);
    _playback?.close();
    await _sounds?.close();
    await _click?.close();
    dispose();
  }
}

Uint8List _wave(double frequency) {
  const rate = 22050, count = 882;
  final data = ByteData(44 + count * 2);
  void text(int at, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(at + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + count * 2, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, count * 2, Endian.little);
  for (var i = 0; i < count; i++) {
    data.setInt16(
      44 + i * 2,
      (math.sin(2 * math.pi * frequency * i / rate) *
              math.exp(-i / count * 7) *
              22000)
          .round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}
