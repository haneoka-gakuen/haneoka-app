import 'spatial_rendering.dart';

import 'package:haneoka_render_profile_flutter/haneoka_render_profile_flutter.dart'
    show
        HaneokaProfileAssets,
        haneokaProfileAssetRoot,
        haneokaShaderBundle,
        loadHaneokaProfileAsset,
        loadHaneokaProfileTexture,
        loadHaneokaProfileString;

import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io';
import 'dart:isolate';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:cassiopeia_plugin_our_notes/render_profile.dart';
import 'package:cassiopeia_plugin_our_notes/watch.dart';
import 'package:cassiopeia_runtime/native.dart';
import 'package:cassiopeia_renderer_flutter/cassiopeia_renderer_flutter.dart';
import 'package:image/image.dart' as img;

import '../chart/runtime_chart.dart';
import '../core/page_audio.dart';
import '../core/haptics.dart';
import 'native_chart_haptics.dart';
import 'native_chart_sounds.dart';
import 'native_chart_intro_sounds.dart';
import 'native_chart_intro_resources.dart';
import 'chart_native_snapshot.dart';
import 'native_chart_document.dart';
import 'native_chart_input.dart';
import 'visual_time.dart';
import 'native_chart_preferences.dart';
import 'native_chart_effect_source.dart';
import 'native_chart_effects.dart';
import 'native_numeric_texture.dart';

Future<NativeTextureData> _composeChartBackground(
  NativeChartBackground compositor,
  Map<String, Uint8List> encoded,
) => Isolate.run(() {
  final inputs = <String, NativeBackgroundPixels>{};
  for (final entry in encoded.entries) {
    final pixels = img.decodeImage(entry.value);
    if (pixels == null) {
      throw FormatException('chart_background_decode:${entry.key}');
    }
    inputs[entry.key] = NativeBackgroundPixels(
      pixels.width,
      pixels.height,
      pixels.getBytes(order: img.ChannelOrder.rgba),
    );
  }
  return compositor.build(inputs);
});

/// The music backend owns song time; the authored intro owns pre-music time.
/// Flutter Ticker schedules requests without advancing either clock itself.
final class NativeChartPlayback extends ChangeNotifier {
  NativeChartPlayback(this._locale, {required this.fetch}) {
    // The chart samples the real decoder once for each rendered frame.
    audio = PageAudio(onFocusInterrupted: pause, pollPosition: false);
    audio.addListener(_audioStateChanged);
  }
  void _audioStateChanged() {
    if (_disposed || audio.playing) return;
    unawaited(_sounds?.bank.stop() ?? Future<void>.value());
    unawaited(_deviceHaptics.stop());
  }

  late final PageAudio audio;
  double _spatialFactor = 1, _spatialSharpness = .8705505632961241;
  void setRenderQuality({required double factor, required double sharpness}) {
    if (factor == _spatialFactor && sharpness == _spatialSharpness) return;
    _spatialFactor = factor;
    _spatialSharpness = sharpness;
    if (session != null) unawaited(requestFrame(force: true));
  }

  final _presentationClock = Stopwatch()..start();
  String _locale;
  String? _introPreparedLocale;
  OurNotesIntroPlayback? _intro;
  OurNotesIntroProjector? _introProjector;
  late final _introResources = NativeChartIntroResources(fetch, resourceUri);
  Map<String, String> _introTexturePaths = const {};
  Map<String, NativeTextureData> _introDataTextures = const {};
  bool _introBypassed = false;
  NativeChartIntroSounds? _introSounds;
  String? _introSourceKey;
  double? _lastPresentedIntroSeconds;
  bool _introWantsPlayback = false,
      _introHandoffPending = false,
      _introMusicHandoffComplete = false;
  ({double left, double top, double width, double height})? pauseHitBounds(
    double width,
    double height,
  ) => _header?.pauseHitBounds(width: width, height: height);

  bool get presentationPlaying =>
      _intro?.phase == OurNotesIntroPlaybackPhase.playing ||
      (_introHandoffPending && _introWantsPlayback) ||
      (controlsThisAudio && audio.playing);
  bool get _introPresenting => _intro != null && !_introMusicHandoffComplete;

  /// Allows one hardware tick to remain pending during a steady music frame.
  /// requestFrame retains ownership of serialization and GPU completion.
  bool get canCoalesceFrameRequests =>
      !_disposed &&
      !loading &&
      error == null &&
      !_commandPending &&
      !_exportBusy &&
      !_forcedFramePending &&
      _pendingPreferences == null &&
      session != null &&
      !_introPresenting &&
      !_introHandoffPending &&
      controlsThisAudio &&
      audio.playing &&
      !audio.completed;

  void _resetIntroTransport() {
    _intro?.pause(_presentationClock.elapsedMicroseconds);
    _introSounds?.setPaused(true);
    _intro = null;
    _lastPresentedIntroSeconds = null;
    _introWantsPlayback = false;
    _introHandoffPending = false;
    _introMusicHandoffComplete = false;
    _introBypassed = false;
  }

  Future<void> setLocale(String locale) async {
    if (_disposed || (_locale == locale && _introPreparedLocale == locale)) {
      return;
    }
    _locale = locale;
    if (loading) return;
    await _frameCompletion?.future;
    if (_disposed || _locale != locale) return;
    final selected = document, owner = session, generation = _generation;
    if (_introProjector == null) {
      _introPreparedLocale = locale;
      return;
    }
    if (selected != null && _introProjector != null && _introPresenting) {
      await _prepareIntroTextures(
        selected,
        () => !_disposed && generation == _generation && session == owner,
        owner: owner,
      );
    }
    if (_disposed || _locale != locale || generation != _generation) return;
    await requestFrame(force: true);
  }

  Future<void> _prepareIntroTextures(
    NativeChartDocument selected,
    bool Function() current, {
    CassiopeiaRenderSession? owner,
  }) async {
    final projector = _introProjector;
    if (projector == null) return;
    while (current()) {
      final locale = _locale;
      final batch = await _introResources.textures(
        projector,
        selected,
        locale,
        current,
      );
      if (!current()) return;
      if (_locale != locale) continue;
      if (owner != null) {
        await owner.ensureTextures({
          for (final entry in batch.paths.entries)
            if (!batch.data.containsKey(entry.key))
              entry.key: resourceUri(entry.value, selected),
        });
        await owner.ensureDataTextures(batch.data);
        if (!current()) return;
      }
      if (_locale != locale) continue;
      _introTexturePaths = batch.paths;
      _introDataTextures = batch.data;
      _introPreparedLocale = locale;
      return;
    }
  }

  Future<void> _installIntro(
    String sourceKey,
    double durationSeconds,
    NativeChartDocument selected,
    bool Function() current,
  ) async {
    if (_introSourceKey == sourceKey) return;
    _intro?.pause(_presentationClock.elapsedMicroseconds);
    final oldSounds = _introSounds;
    _introSounds = null;
    await oldSounds?.close();
    if (!current()) return;
    _intro = OurNotesIntroPlayback(durationSeconds)
      ..setRate(
        preferences.playbackRate,
        _presentationClock.elapsedMicroseconds,
      );
    _lastPresentedIntroSeconds = null;
    _introWantsPlayback = false;
    _introHandoffPending = false;
    _introMusicHandoffComplete = false;
    _introBypassed = false;
    final options = jsonDecode(
      utf8.decode(
        await fetch(
          resourceUri(
            '/api/v1/servers/${selected.source.server}/options',
            selected,
          ),
        ),
      ),
    ) as Map;
    if (!current()) return;
    final sounds = NativeChartIntroSounds(
      OurNotesIntroAudio(options.cast<String, Object?>()),
    );
    try {
      await sounds.open((path) => resourceUri(path, selected), fetch);
      if (!current()) {
        await sounds.close();
        return;
      }
      _introSounds = sounds;
      _introSourceKey = sourceKey;
    } catch (_) {
      await sounds.close();
      rethrow;
    }
  }

  Future<void> _retireIntroTextures(
    CassiopeiaRenderSession owner,
    RenderScene resources,
  ) async {
    if (_introPresenting || _introTexturePaths.isEmpty) return;
    final paths = _introTexturePaths;
    final bound = {
      for (final material in resources.materials.values)
        ...material.textures.values,
    };
    final retired = _introTexturePaths.keys
        .where((key) => !bound.contains(key))
        .toSet();
    if (retired.isEmpty) return;
    await owner.releaseTextures(retired);
    if (_disposed ||
        !identical(owner, session) ||
        !identical(paths, _introTexturePaths)) {
      return;
    }
    _introTexturePaths = {
      for (final entry in _introTexturePaths.entries)
        if (!retired.contains(entry.key)) entry.key: entry.value,
    };
    _introDataTextures = {
      for (final entry in _introDataTextures.entries)
        if (!retired.contains(entry.key)) entry.key: entry.value,
    };
    _introResources.releaseDecodedPixels();
  }

  void _queueIntroHandoff(int generation) {
    if (!_introWantsPlayback ||
        _commandPending ||
        _introHandoffPending ||
        _introMusicHandoffComplete ||
        _intro?.phase != OurNotesIntroPlaybackPhase.complete) {
      return;
    }
    _introHandoffPending = true;
    final intro = _intro;
    unawaited(
      _command((_, active) async {
            if (!active() ||
                generation != _generation ||
                !identical(intro, _intro) ||
                !_introWantsPlayback) {
              return;
            }
            await _resumeMusic(active);
          })
          .catchError((Object exception) {
            if (!_disposed && generation == _generation) {
              error = exception;
              _intro?.pause(_presentationClock.elapsedMicroseconds);
              _introWantsPlayback = false;
              notifyListeners();
            }
          })
          .whenComplete(() {
            if (identical(intro, _intro)) _introHandoffPending = false;
          }),
    );
  }

  Future<void> _resumeMusic(bool Function() active) async {
    if (_introPresenting) {
      await audio.seek(Duration.zero);
      if (!active()) return;
    }
    await audio.resume();
    if (active()) _introMusicHandoffComplete = true;
  }

  final ResourceFetch fetch;
  NativeChartDocument? document;
  CassiopeiaRenderSession? session;
  RuntimeChart? _chart;
  ChartVisualTimeMap? _visualTime;
  Map<String, Object?>? _archive;
  NativeHoldMaterialStyle? _holdStyle;
  NativeChartHud? _hud;
  NativeChartHeader? _header;
  OurNotesGekisouOverlayProjector? _gekisouOverlay;
  OurNotesGekisouStage? _gekisouStage;
  Map<String, NativeTextureData> _gekisouStageTextures = const {};
  String? _gekisouStageTextureKey;

  Map<String, NativeTextureData> _headerDataTextures = const {};
  OurNotesWatchPlayback? _watchPlayback;
  Map<int, RuntimeVisualNote> _visualNotes = const {};
  List<
    ({
      String family,
      bool complete,
      int pointCount,
      int startMicros,
      int endMicros,
    })
  >
  _holdSpans = const [];
  NativeChartEffects? _effects;
  OurNotesGekisouPlan? _gekisouPlan;
  String _liveMode = 'normal';
  String get liveMode => _liveMode;
  bool get gekisouAvailable =>
      _chart != null &&
      document != null &&
      document!.gekisouMissionTypes.isNotEmpty &&
      document!.gekisouMissionTypes.length == _chart!.feverMs.length &&
      _effects?.source.laneFeedback.supports(ChartLaneFeedbackKind.gekisou) ==
          true &&
      (_hud?.source['judgement'] as Map?)?['just'] is Map;

  OurNotesGekisouPlan _makeGekisouPlan() {
    if (!gekisouAvailable) throw StateError('chart_gekisou_unavailable');
    return OurNotesGekisouPlan([
      for (var index = 0; index < _chart!.feverMs.length; index++)
        OurNotesGekisouRange(
          startTimeMs: _chart!.feverMs[index].$1,
          endTimeMs: _chart!.feverMs[index].$2,
          mission: OurNotesGekisouMission
              .values[document!.gekisouMissionTypes[index]],
        ),
    ]);
  }

  Future<void> setLiveMode(String mode) {
    if (mode != 'normal' && mode != 'gekisou') {
      throw ArgumentError.value(mode, 'liveMode');
    }
    final update = _preferenceUpdates.then((_) async {
      await _frameCompletion?.future;
      if (_disposed || mode == _liveMode) return;
      final plan = mode == 'gekisou' ? _makeGekisouPlan() : null;
      if (plan != null && _gekisouOverlay != null && session != null) {
        final generation = _generation, owner = session!;
        final selected = document!;
        await owner.ensureTextures({
          for (final entry
              in _gekisouOverlay!.texturePaths(selected.source.server).entries)
            entry.key: resourceUri(entry.value, selected),
        });
        final stage = _gekisouStage;
        if (stage != null) {
          final prepared = await _prepareStageTextures(stage, selected);
          if (_disposed || generation != _generation || session != owner) {
            return;
          }
          _gekisouStageTextures = prepared.textures;
          _gekisouStageTextureKey = prepared.key;
          await owner.ensureDataTextures(_gekisouStageTextures);
        }
        await _frameCompletion?.future;
        if (_disposed || generation != _generation || session != owner) return;
      }
      _liveMode = mode;
      _gekisouPlan = plan;
      _watchPlayback?.setGekisouPlan(plan);
      _effects?.setGekisouPlan(plan);
      await requestFrame(force: true);
      if (!_disposed) notifyListeners();
    });
    _preferenceUpdates = update.catchError((Object _) {});
    return update;
  }

  String _stageTextureKey(
    OurNotesGekisouStage stage,
    NativeChartDocument selected,
  ) => jsonEncode([
    stage.sourceSha256,
    for (final entry in stage.texturePaths(selected.source.server).entries)
      [entry.key, resourceUri(entry.value, selected).toString()],
  ]);

  Future<({String key, Map<String, NativeTextureData> textures})>
  _prepareStageTextures(
    OurNotesGekisouStage stage,
    NativeChartDocument selected,
  ) async {
    final key = _stageTextureKey(stage, selected);
    if (key == _gekisouStageTextureKey && _gekisouStageTextures.isNotEmpty) {
      return (key: key, textures: _gekisouStageTextures);
    }
    final paths = stage.texturePaths(selected.source.server);
    final keys = paths.keys.toList();
    final values = await Future.wait([
      for (final name in keys)
        () async {
          final bytes = await fetch(resourceUri(paths[name]!, selected));
          if (sha256.convert(bytes).toString() !=
              stage.textureManifest[name]!['sha256']) {
            throw StateError('gekisou_stage_texture_hash:$name');
          }
          return decodeNativeNumericTexture(bytes);
        }(),
    ]);
    return (key: key, textures: Map.fromIterables(keys, values));
  }

  final _deviceHaptics = DeviceHaptics();
  NativeChartHaptics? _haptics;
  NativeChartSounds? _sounds;
  bool get supportsVibration => _deviceHaptics.supported;
  (int, int)? _atlasSize, _backgroundSize;
  NativeTextureData? _backgroundImage;
  String? _backgroundKey;
  int _generation = 0, _intent = 0, _frames = 0;
  int mediaUs = 0;
  NativeChartPreferences preferences = const NativeChartPreferences();
  bool get continuation => preferences.continuation;
  bool _disposed = false,
      _frameBusy = false,
      _commandPending = false,
      _exportBusy = false;
  Completer<void>? _frameCompletion;
  Future<void> _commands = Future.value();
  Future<void> _preferenceUpdates = Future.value();
  Future<void>? _preferenceDrain;
  Future<void> _preferenceSaves = Future.value();
  Timer? _preferenceSaveTimer;
  NativeChartPreferences? _pendingPreferences,
      _unsavedPreferences,
      _resourcePreferences,
      _appliedPreferences;
  bool loading = false;
  Object? error;
  double logicalWidth = 0, logicalHeight = 0;
  int pixelWidth = 0, pixelHeight = 0;
  double _pixelRatio = 1;
  double get pixelRatio => _pixelRatio;
  Future<void> _viewportUpdates = Future.value();
  (double, double, double)? _requestedViewport;
  List<Map<String, Object?>> unsupported = const [];
  Map<String, int> get resources =>
      session?.renderer.resourceCounts ?? const {};
  int get renderedFrames => _frames;
  double get durationSeconds => (audio.duration.value.inMicroseconds / 1000000)
      .clamp((_chart?.durationMs ?? 0) / 1000, double.infinity);
  Map<String, Object?> _fxFrame = const {};
  Map<String, Object?> _hudFrame = const {};
  bool _completionPresented = false;
  bool _forcedFramePending = false;
  bool get needsCompletionFrame =>
      controlsThisAudio && audio.completed && !_completionPresented;
  Map<String, Object?> get watchObservation => {
    ..._hudFrame,
    'audioCompleted': controlsThisAudio && audio.completed,
    'completionFramePresented': _completionPresented,
    'actualAudioFrameUs': mediaUs,
    'introPhase': _intro?.phase.name,
    'introSeconds': _intro?.elapsedSeconds,
    'introMusicHandoffComplete': _introMusicHandoffComplete,
    'intro': _introProjector?.diagnostic,
    'liveMode': liveMode,
    'gekisouAvailable': gekisouAvailable,
    'missionTypes': document?.gekisouMissionTypes,
    'gekisouEffects': _effects?.diagnostic['gekisouActivations'],
    'masterNoteCount': document?.masterNoteCount,
    'masterCountMatches': document?.masterNoteCount == null
        ? null
        : _hudFrame['totalJudgements'] == document!.masterNoteCount,
    'runtimeObservations': _watchPlayback?.observationCount ?? 0,
    'runtimeResets': _watchPlayback?.resetCount ?? 0,
    'ignoredBackwardObservations':
        _watchPlayback?.ignoredBackwardObservationCount ?? 0,
    'runtimeTimeUs': _watchPlayback?.lastMediaMicros,
    'runtimeSourceKey': _watchPlayback?.sourceKey,
    'runtimeBackend': 'cassiopeia-native-abi1',
    'watchProjectionSupported': _watchPlayback?.supportsWatchProjection,
    'scoringComboPolicy': ourNotesScoringComboPolicy(CassiopeiaMode.watch)
        .wireName,
  };
  bool get hasVisibleEffects =>
      (_fxFrame['actualDraws'] as int? ?? 0) > 0 &&
      (_fxFrame['aliveParticles'] as int? ?? 0) > 0;
  bool get controlsThisAudio =>
      audio.active && document?.track.id == audio.current?.id;

  /// Atlas pages carry a content hash in their name that changes with the
  /// game, so the page comes from the release's own atlas record.
  Future<String> _currentAtlasPage(
    String path,
    NativeChartDocument selected,
  ) async {
    final page = RegExp(
      r'^/runtime/([^/]+)/(unity/(Assets/.+\.spriteatlasv2)/sactx-\d+-\d+x\d+-.+-)[0-9a-f]{8}(--Texture2D--\d+\.png)$',
    ).firstMatch(path);
    if (page == null) return path;
    final source = page[3]!.split('/').map(Uri.encodeComponent).join('/');
    final atlas = jsonDecode(
      utf8.decode(
        await fetch(
          resourceUri('/api/v1/servers/${page[1]}/sources/$source', selected),
        ),
      ),
    ) as Map;
    for (final output in (atlas['outputs'] as List? ?? const []).cast<Map>()) {
      final found = '${output['path']}';
      if (found.startsWith('runtime/${page[2]}') && found.endsWith(page[4]!)) {
        return '/runtime/${page[1]}/${found.substring('runtime/'.length)}';
      }
    }
    return path;
  }

  Uri resourceUri(String path, [NativeChartDocument? selected]) {
    if (path.startsWith('asset:')) {
      return Uri.parse('haneoka-asset:${path.substring(6)}');
    }
    final doc = selected ?? document!;
    final uri = (doc.resourceBase ?? doc.scoreUri).resolve(path);
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'release': doc.source.release},
    );
  }

  Future<(int, int)> _size(Uri uri) async {
    final codec = await ui.instantiateImageCodec(await fetch(uri));
    try {
      final frame = await codec.getNextFrame();
      try {
        return (frame.image.width, frame.image.height);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<void> open(
    NativeChartDocument selected, {
    required double width,
    required double height,
    required double pixelRatio,
  }) async {
    if (_disposed) return;
    final selectedPreferences = preferences;
    selected = selected.withNoteSkin(selectedPreferences.noteSkin);
    final sourceChanged = document?.key != selected.key,
        ownedPreviousAudio = controlsThisAudio;
    if (sourceChanged) {
      _liveMode = 'normal';
      _resetIntroTransport();
    }
    _gekisouPlan = null;
    final generation = ++_generation;
    await _deviceHaptics.stop();
    if (_disposed || generation != _generation) return;
    _haptics = null;
    final oldSounds = _sounds;
    _sounds = null;
    await oldSounds?.close();
    if (_disposed || generation != _generation) return;
    _completionPresented = false;
    _forcedFramePending = false;
    ++_intent;
    _frameBusy = false;
    _commandPending = false;
    final oldSession = session;
    session = null;
    document = selected;
    loading = true;
    error = null;
    logicalWidth = width;
    logicalHeight = height;
    _pixelRatio = pixelRatio;
    pixelWidth = (width * pixelRatio).round();
    pixelHeight = (height * pixelRatio).round();
    notifyListeners();
    await oldSession?.dispose();
    CassiopeiaRenderSession? pendingSession;
    try {
      if (sourceChanged && ownedPreviousAudio) {
        await audio.pause();
        if (_disposed || generation != _generation) return;
        await audio.loadPaused(selected.track);
        if (_disposed || generation != _generation) return;
      }
      final bytes = selected.chart == null
          ? await fetch(selected.scoreUri)
          : Uint8List(0);
      final archive = Map<String, Object?>.from(
        jsonDecode(
          await loadHaneokaProfileString(
            '$haneokaProfileAssetRoot${selected.noteSkin}.json',
          ),
        ) as Map,
      );
      final chart = shiftNativeChart(
        selected.chart ??
            RuntimeChart.fromBytes(bytes, includeVisualSource: true),
        selected.audioOffsetMs,
      );
      final visualTime = selected.timeScaleChanges.isEmpty
          ? null
          : ChartVisualTimeMap([
              for (final e in selected.timeScaleChanges)
                (timeMs: e.timeMs + selected.audioOffsetMs, scale: e.scale),
            ]);
      final convertedCount = chart.notes.where((note) => note.judged).length;
      if (selected.masterNoteCount != null &&
          selected.masterNoteCount != convertedCount) {
        throw FormatException(
          'native_chart_master_count_mismatch:'
          '${selected.masterNoteCount}:$convertedCount',
        );
      }
      final styles = jsonDecode(
        await loadHaneokaProfileString(
          '${haneokaProfileAssetRoot}hold-styles.json',
        ),
      ) as Map;
      final holdStyle = NativeHoldMaterialStyle(
        styles[selected.noteSkin] as Map,
      );
      final hud = NativeChartHud(
        jsonDecode(
          await loadHaneokaProfileString(
            '${haneokaProfileAssetRoot}hud-combo.json',
          ),
        ) as Map,
      );
      final header = NativeChartHeader(
        jsonDecode(
          await loadHaneokaProfileString(
            '${haneokaProfileAssetRoot}hud-header.json',
          ),
        ) as Map,
      );
      if (_introSourceKey != selected.key) {
        _introProjector = await _introResources.create(
          selected,
          () => !_disposed && generation == _generation,
        );
        if (_disposed || generation != _generation) return;
        if (_introProjector case final projector?) {
          await _installIntro(
            selected.key,
            projector.durationSeconds,
            selected,
            () => !_disposed && generation == _generation,
          );
        } else {
          await _introSounds?.close();
          _introSounds = null;
          _resetIntroTransport();
          _introSourceKey = selected.key;
          _introTexturePaths = const {};
          _introDataTextures = const {};
        }
      }
      if (_disposed || generation != _generation) return;
      final gekisouOverlay = OurNotesGekisouOverlayProjector(
        (jsonDecode(
          await loadHaneokaProfileString(
            '${haneokaProfileAssetRoot}gekisou-lane-hud-profile.json',
          ),
        ) as Map).cast<String, Object?>(),
      );
      final stageJson = await loadHaneokaProfileString(
        '${haneokaProfileAssetRoot}gekisou-effect-profile.json',
      );
      final stagePacket = (jsonDecode(stageJson) as Map)
          .cast<String, Object?>();
      final gekisouStage = OurNotesGekisouStage(
        stagePacket,
        sourceSha256: sha256.convert(utf8.encode(stageJson)).toString(),
        random: NativeChartEffectSource.sharedParticleRandom,
      );
      final stageTextureKey = _stageTextureKey(gekisouStage, selected);
      var stageTextures = stageTextureKey == _gekisouStageTextureKey
          ? _gekisouStageTextures
          : const <String, NativeTextureData>{};
      if (_liveMode == 'gekisou' && stageTextures.isEmpty) {
        stageTextures = (await _prepareStageTextures(
          gekisouStage,
          selected,
        )).textures;
        if (_disposed || generation != _generation) return;
      }
      final independentPaths = header.independentTexturePaths(
        selected.source.server,
      );
      final independentBytes = await Future.wait([
        for (final path in independentPaths.values)
          fetch(resourceUri(path, selected)),
      ]);
      if (_disposed || generation != _generation) return;
      final headerDataTextures = await decodeNativeNumericTextures(
        Map.fromIterables(independentPaths.keys, independentBytes),
        alpha: NativeTextureAlpha.independent,
      );
      final atlasSize = await _size(
        resourceUri(
          'asset:$haneokaProfileAssetRoot${selected.noteSkin}.png',
          selected,
        ),
      );
      final backgroundBand = selectedPreferences.backgroundBand(
        selected.bandId,
      );
      NativeTextureData? backgroundImage;
      final backgroundKey =
          '${selected.source.server}:${selected.source.release}:$backgroundBand:${selected.jacketUri}';
      if (backgroundBand != null) {
        if (backgroundKey == _backgroundKey) {
          backgroundImage = _backgroundImage;
        } else {
          final compositor = NativeChartBackground(
            jsonDecode(
              await loadHaneokaProfileString(
                '${haneokaProfileAssetRoot}chart-background.json',
              ),
            ) as Map,
          );
          final pixels = await Future.wait([
            fetch(
              resourceUri(
                '/assets/${selected.source.server}/Assets/AddressableResources/Band/$backgroundBand/live_stage/lightweight_background.png',
                selected,
              ),
            ),
            fetch(
              resourceUri(
                await _currentAtlasPage(
                  compositor.baseWhitePath(selected.source.server),
                  selected,
                ),
                selected,
              ),
            ),
            if (selected.jacketUri != null) fetch(selected.jacketUri!),
          ]);
          final inputs = <String, Uint8List>{
            'stage': pixels[0],
            'baseWhite': pixels[1],
            if (selected.jacketUri != null) 'jacket': pixels[2],
          };
          backgroundImage = await _composeChartBackground(compositor, inputs);
        }
      }
      final backgroundSize = backgroundImage == null
          ? (1, 1)
          : (backgroundImage.width, backgroundImage.height);
      if (_disposed || generation != _generation) return;
      await _deviceHaptics.initialize(OurNotesHapticFeedbackProfile.recipes);
      if (_disposed || generation != _generation) return;
      _haptics = NativeChartHaptics(_deviceHaptics);
      final sounds = NativeChartSounds();
      await sounds.load(
        selectedPreferences.noteSeGroup,
        selected.source.server,
        (path) => resourceUri(path, selected),
        fetch,
      );
      if (_disposed || generation != _generation) {
        await sounds.close();
        return;
      }
      _sounds = sounds;
      _chart = chart;
      _visualTime = visualTime;
      _archive = archive;
      _holdStyle = holdStyle;
      _hud = hud;
      _header = header;
      _gekisouOverlay = gekisouOverlay;
      _gekisouStage = gekisouStage;
      _gekisouStageTextures = stageTextures;
      _gekisouStageTextureKey = stageTextureKey;
      _headerDataTextures = headerDataTextures;
      _atlasSize = atlasSize;
      _backgroundSize = backgroundSize;
      _backgroundKey = backgroundKey;
      _backgroundImage = backgroundImage;
      if (controlsThisAudio && !_introPresenting) {
        final position = await audio.samplePosition();
        if (_disposed || generation != _generation) return;
        if (position != null) mediaUs = position.inMicroseconds;
      } else {
        mediaUs = 0;
      }
      _effects = null;
      final visualProfile = await HaneokaProfileAssets.open();
      visualProfile.requireCapability('our-notes-chart-v1');
      {
        final effects = await NativeChartEffectSource.load(
          server: visualProfile.packetSource['server'] as String,
          sourceId: visualProfile.packetSource['sourceId'] as String,
        );
        if (_disposed || generation != _generation) return;
        _effects = NativeChartEffects(
          effects,
          chart,
          tier: selectedPreferences.effectTier,
          initialMediaUs: mediaUs,
        )..resetOnNextObservation();
      }
      if (_liveMode == 'gekisou') {
        _gekisouPlan = _makeGekisouPlan();
        _effects?.setGekisouPlan(_gekisouPlan);
      }
      _installRuntime(chart, selected);
      final observation = await _prepareObservation(
        mediaUs,
        () => !_disposed && generation == _generation,
      );
      if (_disposed || generation != _generation) return;
      await _prepareIntroTextures(
        selected,
        () => !_disposed && generation == _generation,
      );
      if (_disposed || generation != _generation) return;
      final snapshot = _build(mediaUs, generation, 0);
      final gpuSnapshot = _spatial(snapshot);
      final current = CassiopeiaRenderSession(
        renderer: GpuFrameRenderer(
          gpu.gpuContext,
          programs: {...haneokaShaderPrograms, ...SpatialUpscaler.programs},
          additionalShaderBundles: [await SpatialUpscaler.loadShaders()],
        ),
        fetch: fetch,
        textureDataFetch: loadHaneokaProfileTexture,
      );
      pendingSession = current;
      await current.open(
        handwrittenShaderBundle: await loadHaneokaProfileAsset(
          haneokaShaderBundle,
        ),
        scene: gpuSnapshot.scene,
        textures: {
          for (final entry in snapshot.texturePaths.entries)
            entry.key: resourceUri(entry.value, selected),
        },
        initialFrame: gpuSnapshot.frame,
        dataTextures: snapshot.dataTextures,
      );
      if (_disposed || generation != _generation) {
        await current.dispose();
        return;
      }
      session = current;
      _resourcePreferences = selectedPreferences;
      _appliedPreferences ??= selectedPreferences;
      pendingSession = null;
      unsupported = snapshot.unsupported;
      _hudFrame =
          snapshot.roles.where((r) => r['role'] == 'hud').firstOrNull ??
          const {};
      _fxFrame =
          snapshot.roles
              .where((r) => r['role'] == 'judgement-fx')
              .firstOrNull ??
          const {};
      _frames = 1;
      loading = false;
      if (_introPreparedLocale != _locale) await setLocale(_locale);
      if (_disposed || generation != _generation) return;
      _deliverFeedback(
        observation.value,
        mediaUs,
        terminal: observation.terminal,
      );
      notifyListeners();
      _queueIntroHandoff(generation);
    } catch (exception) {
      debugPrint('HANEOKA_NATIVE_OPEN_ERROR $exception');
      await pendingSession?.dispose();
      if (_disposed || generation != _generation) return;
      error = exception;
      loading = false;
      notifyListeners();
    }
  }

  void _installRuntime(RuntimeChart chart, NativeChartDocument selected) {
    final key = '${selected.key}:${selected.sourceId}:${selected.scoreUri}';
    if (_watchPlayback?.sourceKey == key) return;
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
          for (final note in [...line.comboEvents, ...line.endComboEvents])
            if (note.sourceOrdinal != null)
              (sourceOrdinal: note.sourceOrdinal!, id: note.id),
      ],
    );
    final next = CassiopeiaNativeSession(
      library: openCassiopeiaNativeLibrary(),
    );
    final OurNotesWatchPlayback nextPlayback;
    try {
      next.loadNotes(
        notes,
        mode: CassiopeiaMode.watch,
        scoringComboPolicy: ourNotesScoringComboPolicy(CassiopeiaMode.watch),
      );
      nextPlayback = OurNotesWatchPlayback(
        sourceKey: key,
        runtime: next,
        notes: notes,
        plan: _gekisouPlan,
      );
    } catch (_) {
      next.close();
      rethrow;
    }
    _watchPlayback?.close();
    _watchPlayback = nextPlayback;
    _visualNotes = {for (final note in chart.visualNotes) note.id: note};
    _holdSpans = [
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

  Future<OurNotesWatchObservation> _prepareObservation(
    int positionUs,
    bool Function() current,
  ) async {
    final playback = _watchPlayback!;
    final sample = playback.observe(
      mediaMicros: positionUs,
      durationMs: durationSeconds * 1000,
      playbackRate: preferences.playbackRate,
      epoch: controlsThisAudio ? audio.revision : null,
      completed: controlsThisAudio && audio.completed,
    );
    final observation = sample.value, terminal = sample.terminal;
    final effects = _effects;
    final presentationUs = sample.presentationMicros;
    final effectPositionUs =
        !observation.historical &&
            effects != null &&
            presentationUs < effects.observedMediaUs
        ? effects.observedMediaUs
        : presentationUs;
    final effectPlaying =
        controlsThisAudio && audio.playing && preferences.effects;
    if (effects != null && preferences.effects) {
      await effects.observe(
        effectPositionUs,
        observation: observation,
        history:
            terminal ||
                observation.historical ||
                effects.needsRestore ||
                (!effectPlaying &&
                    (observation.events.isNotEmpty ||
                        effects.observedMediaUs != effectPositionUs))
            ? playback.visualHistory
            : const [],
        mirror: preferences.mirror,
        playing: effectPlaying,
        playbackRate: preferences.playbackRate,
        current: current,
        forceRestore: terminal,
      );
    }
    _gekisouStage?.observe(
      plan: _gekisouPlan,
      mediaUs:
          playback.presentation.sampledVisualTimeMicros ??
          sample.presentationMicros,
      mode: preferences.effects
          ? _gekisouStage!.defaultMode
          : OurNotesGekisouEffectMode.off,
      reset: observation.historical,
    );
    return sample;
  }

  void _deliverFeedback(
    CassiopeiaObservation observation,
    int positionUs, {
    bool terminal = false,
  }) {
    final cues = <String>{}, recipes = <int>{};
    final playing = controlsThisAudio && audio.playing;
    if (playing && !observation.historical && !terminal) {
      for (final event in observation.events) {
        final note = _watchPlayback!.notesById[event.noteId]!;
        // Device feedback does not replay stale sounds after a blocked frame.
        if (positionUs - note.timeMicros > 100000) continue;
        final feedback = ourNotesWatchFeedback(
          noteTimeMs: note.timeMicros ~/ 1000,
          operateType: note.operateType.code,
          direction: _visualNotes[event.noteId]?.direction ?? 0,
          judgement: event.judgement,
          differenceMicros: event.differenceMicros,
          judgedAtMicros: event.judgedAtMicros,
          mirror: preferences.mirror,
          plan: _gekisouPlan,
        );
        if (feedback.soundCue case final cue?) cues.add(cue);
        if (feedback.hapticRecipe case final recipe?) recipes.add(recipe);
      }
    }
    _haptics?.observe(
      recipes,
      playing: playing,
      enabled: preferences.vibration,
      held: ourNotesWatchHoldActive(positionUs, _holdSpans),
      historical: observation.historical || terminal,
    );
    _sounds?.observe(
      cues,
      held: ourNotesWatchHoldActive(positionUs, _holdSpans),
      playing: playing && !observation.historical && !terminal,
      volume: preferences.musicVolume / 100 * .875,
    );
  }

  ({RenderScene scene, RenderFrame frame}) _spatial(ChartGpuSnapshot snapshot) {
    final scene = toRenderScene(snapshot.scene);
    if (!scene.targets.containsKey('chart-world-input')) {
      return (scene: scene, frame: snapshot.frame);
    }
    final target = scene.targets[snapshot.frame.outputTarget]!;
    return SpatialUpscaler(sharpness: _spatialSharpness).append(
      scene: scene,
      frame: snapshot.frame,
      inputTarget: 'chart-world-input',
      outputTarget: 'chart-main',
      width: target.width,
      height: target.height,
    );
  }

  ChartGpuSnapshot _build(int positionUs, int epoch, int outputBuffer) {
    final projection = NativeChartProjection(
      pixelWidth,
      pixelHeight,
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      noteSpeed: preferences.noteSpeed,
    );
    final geometry = _effects?.source.recipe['geometry'] as Map?;
    final intro = _introProjector?.sample(
      _intro!.elapsedSeconds,
      OurNotesIntroViewport(
        width: logicalWidth,
        height: logicalHeight,
        pixelRatio: _pixelRatio,
        worldToClip: projection.worldClip,
        fieldOfViewRadians: projection.fieldOfViewRadians,
        cameraPosition: (geometry!['cameraPosition'] as List)
            .cast<num>()
            .map((v) => v.toDouble())
            .toList(),
        cameraXDegrees: (geometry['cameraXDegrees'] as num).toDouble(),
      ),
      canonicalSong: document!.canonicalSong,
      difficulty: document!.difficulty,
      locale: _introPreparedLocale ?? _locale,
      liveMode: liveMode,
      bypass: _introBypassed,
    );
    return buildChartSnapshot(
      _chart!,
      _archive!,
      textureWidth: _atlasSize!.$1,
      textureHeight: _atlasSize!.$2,
      backgroundSize: _backgroundSize!,
      backgroundData: _backgroundImage,
      width: pixelWidth,
      height: pixelHeight,
      worldViewport: spatialWorldViewport(
        pixelWidth,
        pixelHeight,
        _spatialFactor,
      ),
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      mediaUs: positionUs,
      stageProjection: projection,
      visualTime: _visualTime,
      visualProfiles: document!.visualProfiles,
      intro: intro,
      introTexturePaths: _introTexturePaths,
      introDataTextures: _introDataTextures,
      source: document!.source,
      bandId: preferences.backgroundBand(document!.bandId) ?? document!.bandId,
      showBackground: preferences.stageBackground != 'none',
      noteSkin: document!.noteSkin,
      holdStyle: _holdStyle,
      hud: _hud,
      header: _header,
      headerDataTextures: _headerDataTextures,
      rankScores: document!.scoreRankScores,
      watch: _watchPlayback!.presentation,
      effects: _effects,
      gekisouPlan: _gekisouPlan,
      gekisouOverlay: _gekisouOverlay,
      gekisouStage: _gekisouStage,
      gekisouStageTextures: _gekisouStageTextures,
      effectQuality: preferences.effectQuality,
      continuation: continuation,
      showCombo: preferences.showCombo,
      effectsEnabled: preferences.effects,
      noteSize: preferences.noteSize,
      longAlpha: preferences.longAlpha,
      guideAlpha: preferences.guideAlpha,
      backgroundBrightness: preferences.backgroundBrightness,
      laneOpacity: preferences.laneOpacity,
      guidelineCount: preferences.guidelineCount,
      guidelineOpacity: preferences.guidelineOpacity,
      showSimultaneousLine: preferences.showSimultaneousLine,
      showJudgementLine: preferences.showJudgementLine,
      noteSpeed: preferences.noteSpeed,
      mirror: preferences.mirror,
      epoch: epoch,
      outputBuffer: outputBuffer,
    );
  }

  Future<void> requestFrame({bool force = false}) async {
    if (_disposed ||
        loading ||
        error != null ||
        _commandPending ||
        _exportBusy ||
        session == null ||
        (!controlsThisAudio && !force)) {
      return;
    }
    if (_frameBusy) {
      if (force) _forcedFramePending = true;
      return;
    }
    _frameBusy = true;
    final completion = Completer<void>();
    _frameCompletion = completion;
    final generation = _generation, intent = _intent, current = session!;
    final hadAudio = controlsThisAudio;
    bool sameAudio() => controlsThisAudio == hadAudio;
    final trace = kProfileMode
        ? (developer.TimelineTask()..start('chart.frame'))
        : null;
    try {
      final audioTrace = kProfileMode
          ? (developer.TimelineTask(parent: trace)..start('chart.audio'))
          : null;
      Duration? actual;
      try {
        // A paused decoder can expose a primed PTS before music starts.
        // The pre-music timeline keeps music at its actual start boundary.
        actual = _introPresenting
            ? Duration.zero
            : hadAudio
            ? await audio.samplePosition()
            : Duration(microseconds: mediaUs);
      } finally {
        audioTrace?.finish(
          arguments: {
            'positionUs': actual?.inMicroseconds,
            'previousMediaUs': mediaUs,
          },
        );
      }
      if (actual == null ||
          _disposed ||
          generation != _generation ||
          intent != _intent ||
          !sameAudio()) {
        return;
      }
      final position = actual.inMicroseconds;
      final introSeconds = _intro?.sample(
        _presentationClock.elapsedMicroseconds,
      );
      if (position == mediaUs &&
          introSeconds == _lastPresentedIntroSeconds &&
          !force) {
        if (kProfileMode) {
          developer.Timeline.instantSync(
            'chart.audio.unchanged',
            arguments: {'positionUs': position},
          );
        }
        return;
      }
      final buildTrace = kProfileMode
          ? (developer.TimelineTask(parent: trace)..start('chart.build'))
          : null;
      final ChartGpuSnapshot snapshot;
      final RenderScene resources;
      final RenderFrame renderFrame;
      final OurNotesWatchObservation? observation;
      try {
        observation = _introPresenting
            ? null
            : await _prepareObservation(
                position,
                () =>
                    !_disposed &&
                    generation == _generation &&
                    intent == _intent &&
                    sameAudio(),
              );
        if (_disposed ||
            generation != _generation ||
            intent != _intent ||
            !sameAudio()) {
          return;
        }
        snapshot = _build(position, generation, _frames % 2);
        final gpuSnapshot = _spatial(snapshot);
        resources = gpuSnapshot.scene;
        renderFrame = gpuSnapshot.frame;
      } finally {
        buildTrace?.finish();
      }
      await current.present(
        renderFrame,
        resources: resources,
        stillCurrent: () =>
            !_disposed &&
            generation == _generation &&
            intent == _intent &&
            sameAudio(),
      );
      if (_disposed || generation != _generation || intent != _intent) return;
      await _retireIntroTextures(current, resources);
      if (_disposed || generation != _generation || intent != _intent) return;
      if (observation != null) {
        _deliverFeedback(
          observation.value,
          position,
          terminal: observation.terminal,
        );
      }
      if (_intro case final intro?) {
        _introSounds?.observe(intro, preferences.musicVolume / 100);
      }
      mediaUs = position;
      _lastPresentedIntroSeconds = introSeconds;
      unsupported = snapshot.unsupported;
      _hudFrame =
          snapshot.roles.where((r) => r['role'] == 'hud').firstOrNull ??
          const {};
      _completionPresented =
          controlsThisAudio && audio.completed && _watchPlayback!.finished;
      _fxFrame =
          snapshot.roles
              .where((r) => r['role'] == 'judgement-fx')
              .firstOrNull ??
          const {};
      _frames++;
      if (_completionPresented) {
        if (const bool.fromEnvironment('HANEOKA_NATIVE_TRACE')) {
          debugPrint(
            'HANEOKA_NATIVE_PLAYER_COMPLETE $watchObservation sounds=${_sounds?.observation}',
          );
        }
        notifyListeners();
      }
      if (const bool.fromEnvironment('HANEOKA_NATIVE_TRACE') &&
          _frames % 60 == 0) {
        debugPrint(
          'HANEOKA_NATIVE_FRAME source=${document!.key} audioUs=$mediaUs frames=$_frames resources=${this.resources} fx=${_effects?.diagnostic}',
        );
      }
    } catch (exception, stack) {
      debugPrint('HANEOKA_NATIVE_FRAME_ERROR $exception\n$stack');
      if (!_disposed &&
          generation == _generation &&
          intent == _intent &&
          controlsThisAudio) {
        error = exception;
        _intro?.pause(_presentationClock.elapsedMicroseconds);
        _introWantsPlayback = false;
        notifyListeners();
        await audio.pause();
      }
    } finally {
      trace?.finish();
      if (generation == _generation) _frameBusy = false;
      completion.complete();
      if (identical(_frameCompletion, completion)) _frameCompletion = null;
      if (!_disposed && generation == _generation) {
        _queueIntroHandoff(generation);
        if (_forcedFramePending) {
          _forcedFramePending = false;
          unawaited(requestFrame(force: true));
        }
      }
    }
  }

  Future<void> setContinuation(bool enabled) async {
    await setPreferences(preferences.copyWith(continuation: enabled));
  }

  Future<void> setPreferences(NativeChartPreferences selected) {
    if (_disposed) return Future.value();
    selected.validate();
    final previous = preferences;
    preferences = selected;
    if (previous.effects != selected.effects) {
      _effects?.resetOnNextObservation();
    }
    _pendingPreferences = selected;
    _unsavedPreferences = selected;
    _preferenceSaveTimer?.cancel();
    _preferenceSaveTimer = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(_flushPreferenceSave()),
    );
    notifyListeners();
    final running = _preferenceDrain;
    if (running != null) return running;
    final update = _preferenceUpdates.then((_) async {
      try {
        while (!_disposed && _pendingPreferences != null) {
          final next = _pendingPreferences!;
          _pendingPreferences = null;
          try {
            await _applyPreferences(next);
          } catch (_) {
            if (_pendingPreferences == null) rethrow;
          }
        }
      } finally {
        _preferenceDrain = null;
      }
    });
    _preferenceDrain = update;
    _preferenceUpdates = update.catchError((Object _) {});
    return update;
  }

  Future<void> _flushPreferenceSave() {
    _preferenceSaveTimer?.cancel();
    _preferenceSaveTimer = null;
    final selected = _unsavedPreferences;
    _unsavedPreferences = null;
    if (selected != null) {
      _preferenceSaves = _preferenceSaves
          .then((_) => selected.save())
          .catchError((Object exception) {
            debugPrint('HANEOKA_CHART_PREFERENCE_SAVE_ERROR $exception');
            if (!_disposed) {
              error = exception;
              notifyListeners();
            }
          });
    }
    return _preferenceSaves;
  }

  Future<void> _applyPreferences(NativeChartPreferences selected) async {
    await _frameCompletion?.future;
    if (_disposed || !identical(selected, preferences)) return;
    final installed = _resourcePreferences ?? selected;
    final applied = _appliedPreferences ?? selected;
    if (applied.playbackRate != selected.playbackRate) {
      _intro?.setRate(
        selected.playbackRate,
        _presentationClock.elapsedMicroseconds,
      );
    }
    final changeSkin = installed.noteSkin != selected.noteSkin;
    final changeSounds = installed.noteSeGroup != selected.noteSeGroup;
    final changeEffectTier = installed.effectTier != selected.effectTier;
    final changeBackground =
        installed.stageBackground != selected.stageBackground;
    if (applied.vibration && !selected.vibration) {
      await _deviceHaptics.stop();
    }
    if (_disposed || !identical(selected, preferences)) return;
    if (controlsThisAudio &&
        (applied.playbackRate != selected.playbackRate ||
            applied.musicVolume != selected.musicVolume)) {
      await _command((doc, active) async {
        if (active() && controlsThisAudio) {
          await audio.configure(
            rate: selected.playbackRate,
            volume: selected.musicVolume,
          );
        }
      });
      if (_disposed) return;
    }
    _appliedPreferences = selected;
    if (!identical(selected, preferences)) return;
    final doc = document;
    if ((changeSkin || changeEffectTier || changeSounds || changeBackground) &&
        doc != null) {
      await open(
        doc,
        width: logicalWidth,
        height: logicalHeight,
        pixelRatio: _pixelRatio,
      );
    } else {
      await requestFrame(force: true);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _command(
    Future<void> Function(NativeChartDocument, bool Function()) action,
  ) {
    final intent = ++_intent, generation = _generation, selected = document;
    if (_disposed || selected == null) return Future.value();
    _commandPending = true;
    final operation = _commands
        .then((_) async {
          if (_disposed || intent != _intent || generation != _generation) {
            return;
          }
          await action(
            selected,
            () => !_disposed && intent == _intent && generation == _generation,
          );
        })
        .whenComplete(() {
          if (intent == _intent) _commandPending = false;
        });
    _commands = operation.catchError((Object _) {});
    return operation.then((_) => requestFrame(force: true));
  }

  void setLoop(bool enabled) {
    audio.loop = enabled;
    notifyListeners();
  }

  Future<void> resize(double width, double height, double pixelRatio) {
    _requestedViewport = (width, height, pixelRatio);
    final generation = _generation;
    final update = _viewportUpdates.then((_) async {
      await _frameCompletion?.future;
      if (_disposed || generation != _generation) return;
      final viewport = _requestedViewport!;
      logicalWidth = viewport.$1;
      logicalHeight = viewport.$2;
      _pixelRatio = viewport.$3;
      pixelWidth = (logicalWidth * _pixelRatio).round();
      pixelHeight = (logicalHeight * _pixelRatio).round();
      if (const bool.fromEnvironment('HANEOKA_NATIVE_TRACE')) {
        debugPrint(
          'HANEOKA_NATIVE_VIEWPORT_APPLIED logical=$viewport pixels=($pixelWidth, $pixelHeight)',
        );
      }
      await requestFrame(force: true);
    });
    _viewportUpdates = update.catchError((Object _) {});
    return update;
  }

  Future<void> play() => _command((doc, active) async {
    if (controlsThisAudio && audio.completed) {
      _completionPresented = false;
      _effects?.resetOnNextObservation();
      await audio.loadPaused(doc.track);
    }
    if (!controlsThisAudio) {
      await audio.loadPaused(doc.track);
    }
    if (active() && controlsThisAudio) {
      await audio.configure(
        rate: preferences.playbackRate,
        volume: preferences.musicVolume,
      );
    }
    if (!active()) return;
    if (_introPresenting &&
        _intro!.phase != OurNotesIntroPlaybackPhase.complete) {
      await audio.activate(() async {
        if (!active()) return;
        _intro!.setRate(
          preferences.playbackRate,
          _presentationClock.elapsedMicroseconds,
        );
        _intro!.start(_presentationClock.elapsedMicroseconds);
        _introSounds?.setPaused(false);
        _introWantsPlayback = true;
        notifyListeners();
      });
    } else {
      _introWantsPlayback = true;
      _introSounds?.setPaused(false);
      await _resumeMusic(active);
    }
  });
  Future<void> pause() => _command((_, active) async {
    _intro?.pause(_presentationClock.elapsedMicroseconds);
    _introWantsPlayback = false;
    _introSounds?.setPaused(true);
    notifyListeners();
    await _deviceHaptics.stop();
    await _sounds?.bank.stop();
    if (active() && controlsThisAudio) await audio.pause();
  });
  Future<void> seek(Duration position) => _command((doc, active) async {
    _intro?.bypass();
    _introBypassed = true;
    _introMusicHandoffComplete = true;
    _introWantsPlayback = false;
    await _introSounds?.stop();
    await _deviceHaptics.stop();
    await _sounds?.bank.stop();
    if (!controlsThisAudio) {
      await audio.loadPaused(doc.track);
    }
    if (active() && controlsThisAudio) {
      await audio.configure(
        rate: preferences.playbackRate,
        volume: preferences.musicVolume,
      );
    }
    if (active()) {
      _completionPresented = false;
      _watchPlayback?.resetOnNextObservation();
      _effects?.resetOnNextObservation();
      await audio.seek(position);
    }
  });

  /// Captures the actual current GPU frame after the normal Flutter paint
  /// boundary. Rendering is held during capture; native audio keeps its clock.
  Future<Map<String, Object?>> exportCurrentFrame(String path) async {
    if (_exportBusy || _disposed || session == null) {
      throw StateError('native_export_not_ready');
    }
    _exportBusy = true;
    final generation = _generation;
    try {
      await _frameCompletion?.future;
      await SchedulerBinding.instance.endOfFrame;
      if (_disposed || generation != _generation) {
        throw StateError('native_export_source_replaced');
      }
      final selected = document!, current = session!;
      final frameUs = mediaUs, count = _frames, stats = resources;
      final image = current.image.value?.clone();
      if (image == null) throw StateError('native_export_frame_missing');
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('native_export_png_failed');
        if (_disposed || generation != _generation) {
          throw StateError('native_export_source_replaced');
        }
        await File(path).writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        final receipt = <String, Object?>{
          'source': selected.key,
          'sourceId': selected.sourceId,
          'fx': _effects == null
              ? null
              : {
                  ..._fxFrame,
                  'activeInstances': _effects!.activeInstances,
                  'liveParticles': _effects!.liveParticles,
                  'sourceHashes': _effects!.source.sourceHashes,
                },
          'noteSkin': selected.noteSkin,
          'noteSounds': _sounds?.observation,
          'selectedSettings': {
            'noteSpeed': preferences.noteSpeed,
            'mirror': preferences.mirror,
            'continuation': preferences.continuation,
            'playbackRate': preferences.playbackRate,
            'musicVolume': preferences.musicVolume,
            'effectQuality': preferences.effectQuality,
            'showCombo': preferences.showCombo,
            'vibration': preferences.vibration,
            'hapticDeviceSupported': supportsVibration,
            'hapticPulses': _haptics?.pulses ?? 0,
          },
          'watch': watchObservation,
          'actualAudioFrameUs': frameUs,
          'renderedFrames': count,
          'resources': stats,
          'textureResources': current.renderer.textureResources,
          'targetResources': current.renderer.targetResources,
          'viewport': [image.width, image.height],
          'unsupported': unsupported,
          'boundaryReadbacks': false,
          'timeSource': audio.clockBackend,
          'completePlayer': false,
        };
        await File('$path.json').writeAsString(jsonEncode(receipt));
        return receipt;
      } finally {
        image.dispose();
      }
    } finally {
      _exportBusy = false;
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _intro?.pause(_presentationClock.elapsedMicroseconds);
    _introWantsPlayback = false;
    _presentationClock.stop();
    await _deviceHaptics.stop();
    ++_generation;
    ++_intent;
    _pendingPreferences = null;
    await _preferenceUpdates;
    await _flushPreferenceSave();
    final current = session;
    session = null;
    if (controlsThisAudio) {
      await audio.pause();
    }
    await current?.dispose();
    _watchPlayback?.close();
    _watchPlayback = null;
    _headerDataTextures = const {};
    _gekisouOverlay = null;
    _gekisouStage = null;
    _gekisouStageTextures = const {};
    _gekisouStageTextureKey = null;
    _introProjector = null;
    _introDataTextures = const {};
    _introTexturePaths = const {};
    _introResources.dispose();
    await _introSounds?.close();
    _introSounds = null;
    await _sounds?.close();
    audio.removeListener(_audioStateChanged);
    await audio.close();
    super.dispose();
  }
}
