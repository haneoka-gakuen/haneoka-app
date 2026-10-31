import 'spatial_rendering.dart';

import 'package:haneoka_render_profile_flutter/haneoka_render_profile_flutter.dart'
    show
        haneokaProfileAssetRoot,
        haneokaShaderBundle,
        loadHaneokaProfileAsset,
        loadHaneokaProfileTexture,
        loadHaneokaProfileString;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vega_plugin_haneoka/render_profile.dart';
import 'package:vega_plugin_cubism/vega_plugin_cubism.dart'
    show CubismCoreUnavailable;
import 'package:vega_protocol/seek.dart';
import 'package:vega_protocol/save.dart';
import 'package:vega_renderer_flutter/vega_renderer_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../core/catalog_source.dart';
import '../core/render_preferences.dart';
import '../core/resource_file_cache.dart';
import '../core/voice.dart';
import '../shell/page.dart';
import '../ui/adv_text.dart';
import '../ui/playback_pane.dart';
import '../ui/player_orientation.dart';
import '../ui/story_player_menu.dart';
import '../ui/player_preparation_indicator.dart';
import '../ui/player_settings_sheet.dart';
import '../ui/render_quality_settings.dart';
import 'native_story_document.dart';
import 'native_story_world.dart';
import 'native_story_colour_host.dart';
import 'native_story_colour_scene.dart';
import 'native_story_frame_data.dart';
import 'native_story_frame_host.dart';
import 'native_story_frame_projection.dart';
import 'native_story_playback.dart';
import 'native_story_still_host.dart';
import 'native_story_still_source.dart';
import 'native_story_ui_frame.dart';
import 'native_story_ui_source.dart';
import 'native_story_chat_source.dart';
import 'native_story_chat_text.dart';
import 'native_story_talk_ui_runtime.dart';
import 'native_story_front_ui_runtime.dart';
import 'native_story_video_ui.dart';
import 'native_story_video_texture.dart';
import 'native_story_media.dart';
import 'native_story_transition_source.dart';
import 'native_story_preferences.dart';
import 'story_seek_host.dart';
import 'story_save_store.dart';
import 'story_render_profile.dart';
import '../stories/story_sequence.dart';

/// The ordinary selected-episode host. Media, source command history and the
/// measured game UI run together; model availability is reported independently.
class NativeStoryPlayerScreen extends StatefulWidget {
  const NativeStoryPlayerScreen({
    super.key,
    required this.storyId,
    this.server,
    this.api,
    this.title,
    this.textModeBuilder,
    this.sequence,
    this.startAutomatically = false,
    this.initialAutoAdvance = false,
    this.replaceTextMode = false,
  });
  final String storyId;
  final String? server;
  final HaneokaApi? api;
  final Object? title;
  final WidgetBuilder? textModeBuilder;
  final StorySequenceHost? sequence;
  final bool startAutomatically, initialAutoAdvance, replaceTextMode;
  @override
  State<NativeStoryPlayerScreen> createState() =>
      _NativeStoryPlayerScreenState();
}

class _NativeStoryPlayerScreenState extends State<NativeStoryPlayerScreen>
    with SingleTickerProviderStateMixin {
  NativeStoryDocument? _document;
  NativeStoryUiSource? _ui;
  NativeStoryChatSource? _chatSource;
  StoryChatRuntime? _chat;
  NativeStoryChatText? _chatText;
  int _lastChatRevision = -1;
  NativeStoryPlayback? _player;
  NativeStorySeekFacade<_StoryScreenSeekSnapshot>? _seek;
  Future<void>? _seekReady;
  VegaSaveEnvelope? _storedSave;
  StorySaveStore? _saveStore;
  RenderPreferences? _rendering;
  double get _spatialFactor => _rendering?.factor ?? 1;
  void _renderQualityChanged() {
    _sceneRevision++;
    _pausedColourKey = null;
    if (_started && !_ticker.isActive) _ticker.start();
  }

  bool _seekBusy = false;
  bool _scrubResume = false;
  int? _restoredTextIndex;
  VegaRenderSession? _uiSession;
  NativeStoryStillHost? _stillHost;
  NativeStoryFrameHost? _frameHost;
  NativeStoryColourHost? _colourHost;
  NativeStoryTalkUiRuntime? _talkUi;
  NativeStoryFrontUiRuntime? _frontUi;
  NativeStoryVideoUi? _videoUi;
  NativeStoryVideoTexture? _videoCapture;
  NativeStoryPreferences? _preferences;
  Future<void>? _preferenceMediaApply;
  bool _preferenceMediaPending = false;
  StoryPlayerControls? _controls;
  final _menuKey = GlobalKey<PopupMenuButtonState<String>>();
  bool _uiHidden = false;
  VoicePlayback? _logVoice;
  Completer<void>? _shakeTap;
  final _backlog = <({int commandIndex, String speaker, String text})>[];
  final _videoBoundary = GlobalKey();
  GpuFrameRenderer? _videoRenderer;
  int _videoSessionGeneration = -1;
  double _pixelRatio = 1, _movieCurtainAlpha = 0;

  StoryBackgroundImage? _backgroundImage;
  bool _sharedColourActive = false;
  StoryTextPresentationController? _textController;
  StoryTextPresentation? _text;
  NativeStoryUiSnapshot? _uiFrame;
  final _capture = GlobalKey();
  final _bytes = <String, Future<Uint8List>>{};
  final _visualResourceWork = <Future<Object?>, int>{};
  final _unsupportedVisual = <int, String>{};
  NativeStoryWorld? _world;
  String _mode = 'Default', _line = '', _speaker = '', _locale = '';
  String? _pendingLocale;
  int _epoch = 0, _update = 0, _uiFrames = 0, _textIndex = -1;
  int _lastFrontRevision = -1;
  int _uiIntent = 0;
  int _lastTickerUs = 0, _lastMotionTickerUs = 0;
  final _motionClock = Stopwatch()..start();
  int? _lastPresentedVisible;
  int? _lastPresentedUiRevision;
  int? _lastStillCaptureUs;
  int _stillCaptures = 0;
  Object? _lastUiState;
  bool _completionPresented = false;
  String? _sequenceStartedId;
  int _sequenceCompletionRevision = 0;
  bool _started = false,
      _preparing = true,
      _preparingIndex = false,
      _starting = false,
      _busy = false,
      _mutatingUi = false,
      _nextVisible = false,
      _windowVisible = false,
      _exported = false;
  int _preparedModels = 0, _preparationModels = 0;
  int _preparedIndexCommands = 0, _preparationIndexCommands = 0;
  int? _seekTargetPosition;
  Object? _error;
  Uint8List? _background;
  (int, int)? _viewport;
  int _sceneRevision = 0;
  Object? _pausedColourKey;
  double _movieAlpha = 0;
  final _tweens = <_StoryUiTween>[];
  final _transitionSources = <String, Future<NativeStoryTransitionSource>>{};
  Completer<void> _uiReady = Completer<void>();
  late final Ticker _ticker = createTicker(_tick);

  @override
  void initState() {
    super.initState();
    widget.sequence?.addListener(_sequenceChanged);
    unawaited(_uiReady.future.catchError((Object _) {}));
  }

  void _sequenceChanged() {
    if (mounted) setState(() {});
  }

  Future<T> _visualResource<T>(Future<T> Function() load) {
    final epoch = _epoch;
    late final Future<T> work;
    work = load().whenComplete(() => _visualResourceWork.remove(work));
    _visualResourceWork[work] = epoch;
    return work;
  }

  Future<Uint8List> _fetch(Uri uri) => _visualResource(
    () => _bytes
        .putIfAbsent(uri.toString(), () async {
          if (uri.scheme == 'haneoka-asset') {
            final data = await loadHaneokaProfileAsset(uri.path);
            return data.buffer.asUint8List(
              data.offsetInBytes,
              data.lengthInBytes,
            );
          }
          return resourceFileCache.readBytes(
            uri,
            kind: _document?.assets.isMediaUri(uri) == true
                ? ResourceFileKind.media
                : ResourceFileKind.renderResource,
          );
        })
        .catchError((Object error) {
          _bytes.remove(uri.toString());
          throw error;
        }),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rendering = AppScope.of(context).rendering;
    if (!identical(_rendering, rendering)) {
      _rendering?.removeListener(_renderQualityChanged);
      _rendering = rendering..addListener(_renderQualityChanged);
    }
    if (_document == null && _epoch == 0) {
      unawaited(_load());
    } else if (_document != null) {
      final locale = AppScope.of(context).text.locale;
      _pendingLocale = locale == _locale ? null : locale;
    }
  }

  @override
  void didUpdateWidget(covariant NativeStoryPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sequence, widget.sequence)) {
      oldWidget.sequence?.removeListener(_sequenceChanged);
      widget.sequence?.addListener(_sequenceChanged);
    }
    if (oldWidget.storyId != widget.storyId ||
        oldWidget.server != widget.server ||
        !identical(oldWidget.api, widget.api)) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final epoch = ++_epoch;
    setState(() {
      _preparing = true;
      _preparingIndex = false;
      _starting = false;
      _started = false;
      _preparedModels = _preparationModels = 0;
      _preparedIndexCommands = _preparationIndexCommands = 0;
    });
    unawaited(_player?.pause());
    _seek?.dispose();
    _seek = null;
    _seekReady = null;
    _storedSave = null;
    _saveStore = null;
    _seekBusy = false;
    _scrubResume = false;
    await _logVoice?.stop();
    if (!mounted || epoch != _epoch) return;
    ++_uiIntent;
    if (!_uiReady.isCompleted) {
      _uiReady.completeError(StateError('story_source_replaced'));
    }
    _uiReady = Completer<void>();
    unawaited(_uiReady.future.catchError((Object _) {}));
    _ticker.stop();
    _world?.close();
    _world = null;
    _talkUi?.close();
    _talkUi = null;
    _frontUi?.close();
    _frontUi = null;
    _videoCapture?.close();
    _videoCapture = null;
    _videoRenderer = null;
    _videoUi = null;
    _textController?.close();
    for (final tween in _tweens) {
      if (!tween.done.isCompleted) {
        tween.done.completeError(StateError('story_source_replaced'));
      }
    }
    _tweens.clear();
    _transitionSources.clear();
    final old = _player,
        oldUi = _uiSession,
        oldStill = _stillHost,
        oldFrame = _frameHost,
        oldColour = _colourHost;
    old?.removeListener(_changed);
    old?.media.removeListener(_changed);
    _player = null;
    _uiSession = null;
    _stillHost = null;
    _frameHost = null;
    _chat?.close();
    _chat = null;
    _chatSource = null;
    _chatText = null;
    _lastChatRevision = -1;
    _colourHost = null;
    _backgroundImage = null;
    _sharedColourActive = false;
    await old?.close();
    await oldUi?.dispose();
    await oldStill?.dispose();
    await oldFrame?.dispose();
    await oldColour?.dispose();
    if (!mounted || epoch != _epoch) return;
    setState(() {
      _error = null;
      _document = null;
      _ui = null;
      _viewport = null;
      _pausedColourKey = null;
      _sceneRevision++;
      _started = false;
      _preparing = true;
      _preparingIndex = false;
      _starting = false;
      _preparedModels = _preparationModels = 0;
      _preparedIndexCommands = _preparationIndexCommands = 0;
      _uiHidden = false;
      _busy = false;
      _mutatingUi = false;
      _text = null;
      _mode = 'Default';
      _movieAlpha = 0;
      _movieCurtainAlpha = 0;
      _nextVisible = false;
      _line = '';
      _speaker = '';
      _windowVisible = false;
      _exported = false;
      _textIndex = -1;
      _uiFrames = 0;
      _update = 0;
      _lastFrontRevision = -1;
      _background = null;
      _unsupportedVisual.clear();
      _backlog.clear();
      _lastPresentedVisible = null;
      _lastPresentedUiRevision = null;
      _lastStillCaptureUs = null;
      _stillCaptures = 0;
      _completionPresented = false;
      _lastUiState = null;
    });
    try {
      final state = AppScope.of(context);
      final preferences = _preferences ??= await NativeStoryPreferences.load();
      _controls ??= StoryPlayerControls.fromJson(
        jsonDecode(
          await loadHaneokaProfileString(
            '${haneokaProfileAssetRoot}player-controls.json',
          ),
        ) as Map,
      );
      if (!mounted || epoch != _epoch) return;
      final api = CatalogSourceScope.resolve(
        context,
        api: widget.api,
        server: widget.server,
      );
      final document = await NativeStoryDocument.load(api, widget.storyId);
      final renderProfile = await bindStoryRenderProfile(
        document.chapter.sourceIdentity,
      );
      final sourceUi = await NativeStoryUiSource.load(
        renderProfile.packetSource,
      );
      if (!mounted || epoch != _epoch) return;
      final stillSource = await NativeStoryStillSource.load(
        renderProfile.packetSource,
      );
      if (!mounted || epoch != _epoch) return;
      final stillHost = NativeStoryStillHost(
        document: document,
        epoch: epoch,
        fetch: _fetch,
        source: stillSource,
        actualStoryUs: 0,
        speed: 1,
        shakeOffset: () => _world?.stillShakeOffset ?? const [0, 0, 0],
      );
      try {
        await stillHost.prepare(() => mounted && epoch == _epoch);
      } catch (_) {
        await stillHost.dispose();
        rethrow;
      }
      if (!mounted || epoch != _epoch) {
        await stillHost.dispose();
        return;
      }
      _stillHost = stillHost;
      _document = document;
      if (document.chapter.commands.any(
        (c) => const {36, 37, 38, 39, 65}.contains(c.opcode),
      )) {
        final chatSource = await NativeStoryChatSource.load(
          document,
          renderProfile: renderProfile,
        );
        await chatSource.prepare(_fetch);
        if (!mounted || epoch != _epoch) return;
        _chatSource = chatSource;
      }
      final saveStore = StorySaveStore(
        document.chapter.sourceIdentity,
        runtimeHash: document.runtimeHash,
        hostCodec: NativeStorySeekFacade.portableCodec,
      );
      _saveStore = saveStore;
      final storedSave = await saveStore.readQuick();
      if (!mounted || epoch != _epoch) return;
      if (storedSave != null) {
        try {
          final savedUi = storedSave.hostData['ui'] as Map;
          if (savedUi['version'] != 2) {
            throw const FormatException('story_ui_save_version');
          }
          sourceUi.validateSavedResources(savedUi['resourceHashes']);
          _storedSave = storedSave;
        } catch (error) {
          saveStore.lastReadError = error;
        }
      }
      if (saveStore.lastReadError != null) {
        debugPrint(
          'HANEOKA_STORY_QUICKSAVE_IGNORED ${saveStore.lastReadError}',
        );
      }
      _world = NativeStoryWorld(
        api: api,
        document: document,
        epoch: epoch,
        current: () => mounted && epoch == _epoch,
        currentStamp: () => _player!.actualUpdateStamp,
        motionClockUs: () => _motionClock.elapsedMicroseconds,
        timing: () => _player!.visualTiming,
        fetch: _fetch,
      );
      _ui = sourceUi;
      _locale = state.text.locale;
      _pendingLocale = null;
      _textController = StoryTextPresentationController(
        sourceIdentity: document.chapter.sourceIdentity,
        sourceEpoch: epoch,
      );
      _player = NativeStoryPlayback(
        document: document,
        sourceEpoch: epoch,
        handlers: NativeStoryHandlers(
          visual: _visual,
          framePrepare: _prepareFrame,
          text: _presentText,
          videoUi: (command, context) {
            if (context.isCurrent()) {
              _talkUi?.hideTalk();
              _windowVisible = false;
              _nextVisible = false;
              _frontUi?.clearCaption(_epoch);
              _lastPresentedVisible = null;
            }
          },
          subtitleNext: (visible, context) {
            if (context.isCurrent()) _frontUi?.setNext(visible, _epoch);
          },
          onTalkBegin: (command, context) {
            if (!context.isCurrent()) throw StateError('story_source_replaced');
            _nextVisible = false;
            return _talkUi!.beginTalk(command);
          },
          choice: _choice,
          goto: _goto,
          movieFade: _movieFade,
          onActualUpdate: (stamp) {
            if (_seekBusy || _seek?.seeking == true) {
              _world?.clearVoiceBindings();
            }
            _world?.update(stamp);
            _frameHost?.actualUpdate(stamp);
            _stillHost?.actualUpdate(stamp);
          },
          frameDispatch: _dispatchFrame,
          cancelFrameDelay: () => _frameHost?.cancelDelay(),
        ),
      )..addListener(_changed);
      _talkUi = NativeStoryTalkUiRuntime(
        ui: sourceUi,
        renderProfile: renderProfile,
        sourceIdentity: document.chapter.sourceIdentity,
        initialStamp: _player!.actualUpdateStamp,
      );
      _frontUi = NativeStoryFrontUiRuntime(
        source: sourceUi.front,
        sourceEpoch: epoch,
      );
      _frontUi!.setCaptionsEnabled(preferences.subtitlesEnabled, epoch);
      _player!.autoDelaySeconds = preferences.autoDelay;
      await _player!.setSpeed(preferences.speed);
      await _player!.setUserAudio(
        master: preferences.masterVolume,
        bgm: preferences.bgmVolume,
        enabled: preferences.bgmEnabled,
      );
      if (!mounted || epoch != _epoch) return;
      _videoUi = await NativeStoryVideoUi.load(renderProfile.packetSource);
      final frameData = await NativeStoryFrameData.load(
        renderProfile.packetSource,
      );
      if (!mounted || epoch != _epoch) return;
      final frameHost = NativeStoryFrameHost(
        document: document,
        renderProfile: renderProfile,
        data: frameData,
        epoch: epoch,
        fetch: _fetch,
        initialStamp: _player!.actualUpdateStamp,
        actualFadeEase: stillSource.fadeEase,
        resolvePlanarClip: (metrics) =>
            nativeStoryFramePlaneClip(frameData, metrics),
      );
      try {
        await frameHost.prepare(() => mounted && epoch == _epoch);
      } catch (_) {
        await frameHost.dispose();
        rethrow;
      }
      if (!mounted || epoch != _epoch) {
        await frameHost.dispose();
        return;
      }
      _frameHost = frameHost;
      _colourHost = NativeStoryColourHost(epoch: epoch, fetch: _fetch);
      _seek = NativeStorySeekFacade(
        player: _player!,
        world: _world!,
        callbacks: NativeStorySeekCallbacks<_StoryScreenSeekSnapshot>(
          captureUi: _captureSeekUi,
          captureUiData: _encodeSeekUi,
          restoreUiData: _restoreSeekUiData,
          restoreUi: _restoreSeekUi,
          quiesceUi: _quiesceSeekUi,
          settleUi: _settleSeekUi,
          present: _presentSeekUi,
          replayText: _replaySeekText,
          preparationBarrier: _seekPreparationBarrier,
          resumeText: _presentText,
          resumeCommand: _resumeSeekCommand,
          advanceUi: (stamp, context) {
            context.checkCurrent();
            _advanceUi(stamp);
          },
          uiDeadline: (stamp) {
            int? end =
                _frameHost!.playback.hasPendingTimeline ||
                    _stillHost!.playback.hasPendingTimeline ||
                    _chat?.hasPendingTimeline == true
                ? stamp.storyUs + 16667
                : null;
            for (final tween in _tweens) {
              if (tween.current()) {
                final next = tween.atUs + tween.durationUs;
                if (end == null || next < end) end = next;
              }
            }
            return end;
          },
        ),
      );
      _seekReady = _uiReady.future.then((_) async {
        if (!mounted || epoch != _epoch) return;
        await _world!.prewarmInitialModels((completed, total) {
          if (!mounted || epoch != _epoch) return;
          setState(() {
            _preparedModels = completed;
            _preparationModels = total;
          });
        });
        if (!mounted || epoch != _epoch) return;
        await _seek!.seed();
        if (!mounted || epoch != _epoch) return;
        await _player!.prepareInitialMedia();
        if (!mounted || epoch != _epoch) return;
        await _player!.setSpeed(_preferences!.speed);
        if (mounted && epoch == _epoch) {
          setState(() {
            _preparing = false;
            _preparingIndex = false;
          });
          if (widget.startAutomatically &&
              _sequenceStartedId != widget.storyId) {
            _sequenceStartedId = widget.storyId;
            _player!.setAutoPlayback(widget.initialAutoAdvance);
            _start();
          } else if (const bool.fromEnvironment(
            'HANEOKA_NATIVE_STORY_AUTOPLAY',
          )) {
            _player!.setAutoPlayback(true);
            _start();
          }
        }
      });
      unawaited(
        _seekReady!.catchError((Object error, StackTrace stack) {
          if (mounted && epoch == _epoch) _fail(error, stack, epoch);
        }),
      );
      _player!.media.addListener(_changed);
      _lastTickerUs = 0;
      _lastMotionTickerUs = 0;
      _ticker.start();
      setState(() {});
    } catch (error, stack) {
      _fail(error, stack, epoch);
    }
  }

  int get _languageMode => storyUiLanguageMode(_locale);
  String _localized(Object? value) {
    if (value is! List || value.length != 5 || value.any((v) => v is! String)) {
      throw const FormatException('native_story_actual_localized_text');
    }
    return value[_languageMode] as String;
  }

  String _speakerName(StoryDecodedCommand command) {
    if (command.payload['targetStatus'] == 2) return '';
    final names = command.payload['targetTextNames'];
    if (names is! List) return '';
    final colors = command.payload['targetTextColors'] as List? ?? const [];
    final values = <String>[];
    for (var i = 0; i < names.length; i++) {
      final name = _localized(names[i]);
      final color = i < colors.length ? colors[i] : null;
      values.add(
        color is String && RegExp(r'^#[a-fA-F0-9]{6,8}$').hasMatch(color)
            ? '<color=$color>$name</color>'
            : name,
      );
    }
    return values.join(
      AppScope.of(context).text('story.relationships.speakerNameSeparator', ''),
    );
  }

  NativeStoryUiSnapshot _snapshot({int? visible, bool layoutOnly = false}) {
    final base = buildNativeStoryUiFrame(
      ui: _ui!,
      source: RenderSource(
        server: _document!.chapter.sourceIdentity.server,
        release: _document!.chapter.sourceIdentity.release,
        document: _document!.chapter.sourceIdentity.document,
      ),
      epoch: _epoch,
      storyUs: _player!.actualUpdateStamp.storyUs,
      width: _viewport!.$1,
      height: _viewport!.$2,
      locale: _locale,
      mode: _mode,
      text: _line,
      speaker: _speaker,
      visibleCharacters: visible ?? _text?.visibleLength ?? 0,
      auto: _player!.autoPlayback,
      nextVisible: _nextVisible,
      windowVisible: _windowVisible,
      revealAll: _text != null && !_text!.typing,
      controlFrame: _talkUi!.frame,
      frontRuntime: _frontUi,
      textSize: _preferences?.textSize ?? 1,
      talkOffset: _world?.talkShakeOffset ?? const [0, 0, 0],
      layoutOnly: layoutOnly,
    );
    final chat = _chat;
    if (chat?.active != true) return base;
    final compiled = compileStoryChat(
      runtime: chat!,
      source: base.scene.source,
      epoch: _epoch,
      storyUs: _player!.actualUpdateStamp.storyUs,
      updateIndex: _player!.actualUpdateStamp.updateIndex,
      width: _viewport!.$1,
      height: _viewport!.$2,
      measureText: _chatTypography.measure,
      emitText: _chatTypography.emit,
      resolveOutput: _chatSource!.resolveOutput,
      externalImages: _chatSource!.externalImages,
      layoutOnly: layoutOnly,
    );
    final output = compiled.frame.outputTarget;
    final main = compiled.frame.passes.singleWhere(
      (pass) => pass.target == output,
    );
    final scene = NativeSceneResources(
      epoch: base.scene.epoch,
      source: base.scene.source,
      meshes: {...base.scene.meshes, ...compiled.scene.meshes},
      materials: {...base.scene.materials, ...compiled.scene.materials},
      targets: {
        ...base.scene.targets,
        for (final entry in compiled.scene.targets.entries)
          if (entry.key != output) entry.key: entry.value,
      },
    );
    final frame = NativeFrame(
      epoch: base.frame.epoch,
      mediaMicroseconds: base.frame.mediaMicroseconds,
      outputTarget: base.frame.outputTarget,
      passes: [
        for (final pass in compiled.frame.passes)
          if (pass.target != output) pass,
        for (final pass in base.frame.passes)
          if (pass.target == base.frame.outputTarget)
            NativePass(
              target: pass.target,
              draws: [...pass.draws, ...main.draws],
              clear: pass.clear,
              clearColor: pass.clearColor,
            )
          else
            pass,
      ],
    );
    return NativeStoryUiSnapshot(
      scene,
      frame,
      {...base.textures, ...compiled.textures},
      base.talk,
      base.layout,
      base.unsupported,
      base.textMeasurements,
      base.front,
    );
  }

  Future<void> _openUi(int width, int height, {bool force = false}) async {
    if (_mutatingUi ||
        _document == null ||
        _frameHost == null ||
        (!force && _viewport == (width, height))) {
      return;
    }
    _mutatingUi = true;
    final epoch = _epoch;
    final intent = ++_uiIntent;
    if (_uiReady.isCompleted) {
      _uiReady = Completer<void>();
      unawaited(_uiReady.future.catchError((Object _) {}));
    }
    try {
      _viewport = (width, height);
      if (_chat?.hasWindowSource == true) {
        _chat!.configurePixelViewport(width, height);
      }
      if (_sharedColourActive) {
        _stillHost!.configureColourViewport(width, height);
        _frameHost!.configureColourViewport(width, height);
        if (!_uiReady.isCompleted) _uiReady.complete();
        setState(() {});
        return;
      }
      final previous = _uiSession;
      _uiSession = null;
      await previous?.dispose();
      if (!mounted || epoch != _epoch || intent != _uiIntent) return;
      final frame = _snapshot();
      final session = VegaRenderSession(
        renderer: GpuFrameRenderer(
          gpu.gpuContext,
          programs: haneokaShaderPrograms,
        ),
        fetch: _fetch,
        textureDataFetch: loadHaneokaProfileTexture,
      );
      await session.open(
        handwrittenShaderBundle: await loadHaneokaProfileAsset(
          haneokaShaderBundle,
        ),
        scene: toRenderScene(frame.scene),
        textures: frame.textures,
        initialFrame: frame.frame,
      );
      if (!mounted || epoch != _epoch || intent != _uiIntent) {
        await session.dispose();
        return;
      }
      _uiSession = session;
      await _stillHost!.open(
        width,
        height,
        () => mounted && epoch == _epoch && intent == _uiIntent,
      );
      if (!mounted || epoch != _epoch || intent != _uiIntent) return;
      await _frameHost!.open(
        width,
        height,
        () => mounted && epoch == _epoch && intent == _uiIntent,
      );
      if (!mounted || epoch != _epoch || intent != _uiIntent) return;
      if (!_uiReady.isCompleted) _uiReady.complete();
      _uiFrame = frame;
      _uiFrames++;
      if (!_started &&
          const bool.fromEnvironment('HANEOKA_NATIVE_STORY_AUTOPLAY')) {
        _player!.setAutoPlayback(true);
        _start();
      }
      setState(() {});
    } catch (error, stack) {
      _fail(error, stack, epoch);
    } finally {
      if (epoch == _epoch && intent == _uiIntent) _mutatingUi = false;
    }
  }

  StoryChatUpdateStamp _chatStamp(NativeStoryUpdateStamp stamp) =>
      StoryChatUpdateStamp(
        sourceEpoch: stamp.sourceEpoch,
        updateIndex: stamp.updateIndex,
        storyUs: stamp.storyUs,
        speed: stamp.speed,
        paused: stamp.paused,
      );

  Future<StoryChatRuntime> _ensureChat(
    String id, {
    bool selectSource = false,
  }) async {
    final epoch = _epoch;
    _chat ??= StoryChatRuntime(
      identity: _document!.chapter.sourceIdentity,
      sourceEpoch: epoch,
    );
    if (selectSource) {
      final source = await _chatSource!.window(id);
      if (!mounted || epoch != _epoch) throw const VegaSeekCancelled();
      _chat!.bindSource(source);
    }
    final viewport = _viewport;
    if (_chat!.hasWindowSource && viewport != null) {
      _chat!.configurePixelViewport(viewport.$1, viewport.$2);
    }
    return _chat!;
  }

  Future<void> _restoreChat(Object? data, VegaSeekContext context) async {
    _chat?.close();
    _chat = null;
    _chatText = null;
    _lastChatRevision = -1;
    if (data is! Map) return;
    final id = data['windowId'] as String?;
    final runtime = await _ensureChat(id ?? '', selectSource: id != null);
    context.checkCurrent();
    runtime.restoreData(data, _chatStamp(_player!.actualUpdateStamp));
    final viewport = _viewport;
    if (runtime.hasWindowSource && viewport != null) {
      runtime.configurePixelViewport(viewport.$1, viewport.$2);
    }
  }

  void _chatLogs(Iterable<StoryChatEntry> entries) {
    for (final entry in entries) {
      if (entry.logged || !entry.shouldAddLog) continue;
      _backlog.add((
        commandIndex: entry.commandIndex,
        speaker: entry.name,
        text: entry.text,
      ));
      _chat!.memory.markLogAdded(_epoch, entry);
    }
  }

  Future<void> _playChatWindow(
    StoryDecodedCommand command,
    StoryDispatchContext context,
  ) async {
    final chat = await _ensureChat(
      '${command.payload['targetChatID']}',
      selectSource: true,
    );
    if (!context.isCurrent()) throw const VegaSeekCancelled();
    _locale = _pendingLocale ?? _locale;
    _pendingLocale = null;
    final change = chat.selectWindow(command, _speakerName(command));
    _chatLogs(change.pendingLogs);
    _talkUi!.hideTalk();
    _windowVisible = false;
    _nextVisible = false;
    _lastPresentedVisible = null;
    if (change.action != StoryChatWindowAction.configure) {
      final sound = chat.soundFor(command, window: true);
      if (sound > 0) await _player!.playChatSound('$sound', command, context);
      if (!context.isCurrent()) throw const VegaSeekCancelled();
      await chat.transition(
        change.action == StoryChatWindowAction.show,
        _chatStamp(_player!.actualUpdateStamp),
        shortcut: _player!.voiceShortcut,
        executionId: context.executionId,
      );
    }
  }

  NativeStoryChatText get _chatTypography {
    final existing = _chatText;
    final size = _preferences?.textSize ?? 1;
    final uiLocale = AppScope.of(context).text.locale;
    final uiLanguageMode = storyUiLanguageMode(uiLocale);
    if (existing != null &&
        identical(existing.ui, _ui) &&
        existing.locale == uiLocale &&
        existing.uiLanguageMode == uiLanguageMode &&
        existing.textScale == size) {
      return existing;
    }
    return _chatText = NativeStoryChatText(
      _ui!,
      uiLocale,
      size,
      uiLanguageMode: uiLanguageMode,
    );
  }

  Future<NativeStoryTextSession> _presentChat(
    StoryDecodedCommand command,
    StoryDispatchContext context, {
    bool immediate = false,
  }) async {
    await _uiReady.future;
    if (!context.isCurrent()) throw const VegaSeekCancelled();
    final chat = await _ensureChat('${command.payload['targetChatID']}');
    if (!context.isCurrent()) throw const VegaSeekCancelled();
    var presentation = context.resuming
        ? chat.presentationForExecution(context.executionId)
        : null;
    var skip = false;
    if (!context.resuming && const {37, 38, 65}.contains(command.opcode)) {
      _locale = _pendingLocale ?? _locale;
      _pendingLocale = null;
    }
    final text = _localized(command.payload['text']);
    if (presentation == null) {
      if (command.opcode == 36) {
        final pending = chat.pendingCompletionForExecution(context.executionId);
        if (pending != null) await pending;
        skip = chat.skipWindowAdvance;
      } else if (command.opcode == 37 || command.opcode == 38) {
        final mutation = chat.append(
          command,
          text: text,
          name: _speakerName(command),
          stampAsset: command.payload['targetAssetName'] as String? ?? '',
        );
        skip = !mutation.visible;
        _chatLogs(mutation.pendingLogs);
        if (mutation.visible) {
          final sound = chat.soundFor(command, window: false);
          if (sound > 0) {
            await _player!.playChatSound('$sound', command, context);
          }
        }
      } else if (command.opcode == 39) {
        chat.applyRead(command);
        skip = !chat.active;
      } else if (command.opcode == 65) {
        skip = !chat.active;
      }
      if (!context.isCurrent()) throw const VegaSeekCancelled();
      if (skip) {
        return NativeStoryTextSession(
          fullyRevealed: Future.value(),
          firstTap: Future.value(),
          waitForNextStep: () => Future.value(),
          renderedLength: 0,
          skipAdvance: true,
        );
      }
      final template = chat.source.bubbleTemplate(
        '${command.payload['targetChatID']}' != chat.memory.currentChatId,
      );
      final component = command.opcode == 65
          ? chat.source.textComponent(
              chat.source.pointer(
                chat.source.windowController['_typingContentText'],
              ),
            )
          : chat.source.textComponent(
              chat.source.pointer(template['_talkText']),
            );
      final glyphs = _chatTypography.measure(
        StoryChatTextRequest(
          key: 'read:${context.executionId}',
          text: text,
          component: component,
          sourceHash: chat.source.windowDomain['sourceHash'] as String,
          width: 0,
          height: 0,
        ),
      );
      presentation = command.opcode == 65
          ? chat.beginTyping(
              command: command,
              text: text,
              renderedLength: glyphs.renderedGlyphCount,
              executionId: context.executionId,
              stamp: _chatStamp(_player!.actualUpdateStamp),
              instant: immediate,
              languageMode: _languageMode,
            )
          : chat.presentRead(
              command: command,
              text: text,
              executionId: context.executionId,
              renderedLength: glyphs.renderedGlyphCount,
              stamp: _chatStamp(_player!.actualUpdateStamp),
            );
    }
    _textIndex = command.index;
    _windowVisible = false;
    _talkUi!.hideTalk();
    _lastPresentedVisible = null;
    if (mounted) setState(() {});
    return NativeStoryTextSession(
      fullyRevealed: presentation.fullyRevealed,
      firstTap: presentation.firstTap,
      waitForNextStep: presentation.waitForNextStep,
      renderedLength: presentation.renderedLength,
      skipAdvance: immediate || _player!.voiceShortcut,
    );
  }

  Future<NativeStoryTextSession> _presentText(
    StoryDecodedCommand command,
    StoryDispatchContext context, {
    bool immediate = false,
  }) async {
    if (const {36, 37, 38, 39, 65}.contains(command.opcode)) {
      return _presentChat(command, context, immediate: immediate);
    }
    if (!immediate && _restoredTextIndex == command.index && _text != null) {
      _restoredTextIndex = null;
      final restored = _text!;
      return NativeStoryTextSession(
        fullyRevealed: restored.fullyRevealed,
        firstTap: restored.firstTap,
        renderedLength: restored.renderedLength,
        waitForNextStep: restored.waitForNextStep,
      );
    }
    if (command.opcode == 28) return _presentSubtitles(command, context);
    final epoch = _epoch;
    await _uiReady.future;
    if (!mounted || epoch != _epoch) throw StateError('story_source_replaced');
    if (!context.isCurrent()) throw StateError('story_source_replaced');
    if (command.opcode != 29) {
      // Locale changes take effect at the next genuine text command boundary.
      // Current typing/voice/Next futures retain their original source input.
      _locale = _pendingLocale ?? _locale;
      _pendingLocale = null;
      _line = _localized(command.payload['text']);
      _speaker = command.opcode == 2 ? _speakerName(command) : '';
    }
    _textIndex = command.index;
    if (command.opcode == 2) {
      _talkUi!.showTalk();
      _windowVisible = true;
    }
    _nextVisible = false;
    _talkUi!.hideNext();
    final frame = _snapshot(visible: 0);
    _mutatingUi = true;
    try {
      final fullTextures = _snapshot(visible: frame.talk.meshCharacterCount)
          .textures;
      if (_sharedColourActive) {
        await _colourHost!.ensureTextures({
          for (final entry in fullTextures.entries)
            'colour:304:${entry.key}': entry.value,
        });
      } else {
        await _uiSession!.ensureTextures(fullTextures);
      }
      if (!context.isCurrent()) throw StateError('story_source_replaced');
      final proof = (_ui!.typing['rows'] as List).cast<Map>().singleWhere(
        (row) => (row['sourceUiPath'] as String).endsWith(
          _mode == 'Default'
              ? 'UIDefaultTalkWindow.prefab'
              : 'UICenterTalkWindow.prefab',
        ),
      );
      final presentation = _textController!.present(
        StoryTextInput(
          sourceIdentity: _document!.chapter.sourceIdentity,
          sourceEpoch: _epoch,
          commandIndex: command.index,
          text: _line,
          letterTestText: frame.talk.letterTestText,
          renderedLength: frame.talk.renderedGlyphCount,
          kind:
              immediate ||
                  command.opcode == 29 ||
                  _preferences?.instantText == true
              ? StoryTextKind.instant
              : StoryTextKind.talk,
          typingDelaySeconds: _ui!.typingDelay(_mode),
          uiLanguageMode: _languageMode,
          playbackSpeed: _player!.speed,
          sourceUiPath: proof['sourceUiPath'] as String,
          sourceUiHash: proof['sourceUiHash'] as String,
        ),
        _update,
      );
      _text = presentation;
      if (command.opcode == 2 && _line.isNotEmpty) {
        _backlog.add((
          commandIndex: command.index,
          speaker: _speaker,
          text: _line,
        ));
        if (_backlog.length > 2000) {
          _backlog.removeRange(0, _backlog.length - 2000);
        }
      }
      _lastPresentedVisible = null;
      setState(() {});
      return NativeStoryTextSession(
        fullyRevealed: presentation.fullyRevealed,
        firstTap: presentation.firstTap,
        renderedLength: frame.talk.renderedGlyphCount,
        waitForNextStep: () {
          _nextVisible = true;
          _talkUi!.requestNext();
          _lastPresentedVisible = null;
          return presentation.waitForNextStep();
        },
      );
    } finally {
      if (epoch == _epoch) _mutatingUi = false;
    }
  }

  Future<NativeStoryTextSession> _presentSubtitles(
    StoryDecodedCommand command,
    StoryDispatchContext context,
  ) async {
    final epoch = _epoch;
    await _uiReady.future;
    if (!mounted || epoch != _epoch || !context.isCurrent()) {
      throw StateError('story_source_replaced');
    }
    final id = command.payload['advTextId'];
    if (id is! String || id.isEmpty || id == '0') {
      _frontUi!.clearCaption(epoch);
      _lastPresentedVisible = null;
      return NativeStoryTextSession(
        fullyRevealed: Future.value(),
        firstTap: Future.value(),
        waitForNextStep: () => Future.value(),
        renderedLength: 0,
      );
    }
    _locale = _pendingLocale ?? _locale;
    _pendingLocale = null;
    _frontUi!.showCaption(_localized(command.payload['text']), epoch);
    final frame = _snapshot();
    final ruby = _ui!.front.subtitlesRubyId;
    final tmp = _ui!.front.textComponent(ruby)['data'] as Map;
    final go = (tmp['m_GameObject'] as Map)['m_PathID'];
    final path = _ui!.frontLayout.pathToId.entries
        .singleWhere((e) => e.value == _ui!.frontLayout.gameObjectToId[go])
        .key;
    final glyphs = frame.front!.glyphs[path]!;
    if (_sharedColourActive) {
      await _colourHost!.ensureTextures({
        for (final e in frame.textures.entries) 'colour:304:${e.key}': e.value,
      });
    } else {
      await _uiSession!.ensureTextures(frame.textures);
    }
    if (!context.isCurrent() || epoch != _epoch) {
      throw StateError('story_source_replaced');
    }
    final presentation = _textController!.present(
      StoryTextInput(
        sourceIdentity: _document!.chapter.sourceIdentity,
        sourceEpoch: epoch,
        commandIndex: command.index,
        text: _frontUi!.caption,
        letterTestText: glyphs.letterTestText,
        renderedLength: glyphs.renderedGlyphCount,
        kind: StoryTextKind.instant,
        typingDelaySeconds: 0,
        uiLanguageMode: _languageMode,
        playbackSpeed: _player!.speed,
        sourceUiPath:
            'Assets/AddressableResources/UI/Prefab/UIAdvWidget.prefab',
        sourceUiHash:
            '4876cec383e7aab291fcb8a2ebf40a0b5a288a38ad8ee731f488db910fbf3acc',
      ),
      _update,
    );
    _text = presentation;
    _textIndex = command.index;
    _lastPresentedVisible = null;
    if (mounted) setState(() {});
    return NativeStoryTextSession(
      fullyRevealed: presentation.fullyRevealed,
      firstTap: presentation.firstTap,
      waitForNextStep: () {
        _frontUi!.setNext(true, epoch);
        return presentation.waitForNextStep();
      },
      renderedLength: glyphs.renderedGlyphCount,
    );
  }

  StoryDispatchOperation _dispatchFrame(
    StoryDecodedCommand command,
    StoryDispatchContext context,
    NativeStoryUpdateStamp stamp,
  ) {
    final ids =
        command.payload['targetTextIds'] ??
        command.payload['_targetTextIDs'] ??
        const [];
    if (ids is! List) {
      throw const FormatException('native_frame_actual_text_ids');
    }
    final names = command.payload['targetTextNames'];
    if (ids.isNotEmpty && (names is! List || names.length != ids.length)) {
      throw UnsupportedError('native_frame_actual_text_names');
    }
    final texts = <String>[
      if (ids.isNotEmpty)
        for (final name in names as List) _localized(name),
    ];
    return _frameHost!.dispatch(command, context, stamp, texts);
  }

  Future<void> _prepareFrame(
    StoryDecodedCommand command,
    StoryDispatchContext context,
  ) async {
    final reference = command.resourceRefs['frameRef'];
    if (!_document!.assets.frames.containsKey(reference)) {
      throw StateError('native_story_frame_source:$reference');
    }
  }

  Future<void> _visual(
    StoryDecodedCommand command,
    StoryDispatchContext context,
  ) async {
    if (!context.isCurrent()) return;
    if (command.opcode == 4) {
      final generation = _world!.shake(command);
      final layers = command.payload['canvasLayers'] as List? ?? const [];
      final waiting = _player!.waitVisualDuration(
        command.durationUs / 1000000,
        context,
        stillWaiting: layers.isEmpty
            ? null
            : () => _world!.shakeGeneration == generation,
      );
      if (command.noWait) {
        await waiting;
      } else {
        final tap = Completer<void>();
        _shakeTap = tap;
        try {
          await Future.any([waiting, tap.future]);
        } finally {
          if (identical(_shakeTap, tap)) _shakeTap = null;
        }
      }
    } else if (command.opcode == 36) {
      await _playChatWindow(command, context);
    } else if (command.opcode == 51) {
      await _world!.cameraShake(command, executionId: context.executionId);
    } else if (command.opcode == 20) {
      final text = _localized(command.payload['text']);
      final generation = _frontUi!.showLocation(text);
      if (text.isNotEmpty) {
        _backlog.add((commandIndex: command.index, speaker: '', text: text));
        await _player!.waitLocation(_frontUi!.source.locationDuration, context);
        if (context.isCurrent()) _frontUi!.finishLocation(generation);
      }
    } else if (command.opcode == 5 ||
        command.opcode == 6 ||
        command.opcode == 11) {
      await _transition(command, context);
    } else if (command.opcode == 12) {
      await _world!.brightness(
        command,
        () => _player!.waitCommonCommandDelay(command, context),
        context.isCurrent,
        executionId: context.executionId,
      );
    } else if (command.opcode == 23) {
      await _world!.load(command);
    } else if (command.opcode == 24) {
      _world!.costume(command);
    } else if (command.opcode == 0 || command.opcode == 1) {
      _world!.show(command, command.opcode == 0);
    } else if (const {9, 10}.contains(command.opcode)) {
      _world!.reorder(command);
    } else if (command.opcode == 21 || command.opcode == 17) {
      _world!.motion(command);
    } else if (command.opcode == 68) {
      _world!.parameterLoop(command, shortcut: _player!.voiceShortcut);
    } else if (const {18, 19, 69}.contains(command.opcode)) {
      _world!.characterControl(command, shortcut: _player!.voiceShortcut);
    } else if (command.opcode == 32) {
      await _world!.angle(
        command,
        () => _player!.waitCommonCommandDelay(command, context),
        context.isCurrent,
        executionId: context.executionId,
      );
    } else if (command.opcode == 49) {
      await _world!.depthOfField(
        command,
        () => _player!.waitCommonCommandDelay(command, context),
        context.isCurrent,
        executionId: context.executionId,
      );
    } else if (command.opcode == 43) {
      _world!.postEffect(command, executionId: context.executionId);
    } else if (command.opcode == 57) {
      final remaining = _world!.stageEnvironment(command);
      if (remaining.isNotEmpty) {
        _unsupportedVisual[command.index] =
            'stage_environment:${remaining.join(',')}';
      }
    } else if (const {7, 33, 34, 47, 48, 50, 53, 67}.contains(command.opcode)) {
      await _world!.camera(command, executionId: context.executionId);
    } else if (command.opcode == 46 || command.opcode == 66) {
      await _world!.look(
        command,
        () => _player!.waitCommonCommandDelay(command, context),
        context.isCurrent,
        executionId: context.executionId,
      );
    } else if (const {13, 14, 60, 61, 62, 63, 64}.contains(command.opcode)) {
      await _world!.moveToDirection(command, executionId: context.executionId);
    } else if (command.opcode == 30) {
      await _stillHost!.dispatch(
        command,
        context,
        _player!.actualUpdateStamp.storyUs,
        _player!.actualUpdateStamp.speed,
      );
    } else if (command.opcode == 25) {
      final record =
          _document!.assets.backgrounds[command.resourceRefs['backgroundRef']];
      if (record == null || record['url'] is! String) {
        throw StateError('native_story_stage_resource:${command.resourceRefs}');
      }
      final uri =
          widget.api?.asset(record['url'] as String) ??
          _document!.assets.assetUri(record['url'] as String);
      final pinned = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'release': _document!.chapter.sourceIdentity.release,
        },
      );
      final prepared = await _visualResource(() async {
        final data = await _fetch(pinned);
        if (!context.isCurrent() || !mounted) return null;
        final identity = _document!.chapter.sourceIdentity;
        final lower = await StoryBackgroundImage.fromActualEncodedImage(
          source: RenderSource(
            server: identity.server,
            release: identity.release,
            document: identity.document,
          ),
          epoch: _epoch,
          uri: pinned,
          bytes: data,
        );
        return (data: data, lower: lower);
      });
      if (prepared == null || !context.isCurrent() || !mounted) return;
      _background = prepared.data;
      _backgroundImage = prepared.lower;
      await _world!.stage(command.resourceRefs['backgroundRef']!);
    } else if (command.opcode == 35) {
      final name = (command.payload['targetAssetName'] as String)
          .split('/')
          .last;
      _mode = switch (name) {
        'UIDefaultTalkWindow' => 'Default',
        'UICenterTalkWindow' => 'Center',
        _ => throw UnsupportedError('native_story_talk_window:$name'),
      };
      _talkUi!.attachWindow(_mode);
      _lastPresentedVisible = null;
    } else if (command.opcode == 40) {
      // ChoiceSet retains its actual source catalog; ChoiceShow owns display.
      StoryChoiceCatalog.fromChapter(_document!.chapter);
    } else if (command.opcode == 44) {
      _unsupportedVisual[command.index] =
          'frame_authored_animator_and_geometry_pending';
    } else {
      _unsupportedVisual[command.index] =
          const {
            0,
            1,
            4,
            7,
            9,
            10,
            13,
            14,
            17,
            18,
            19,
            21,
            23,
            24,
            32,
            33,
            34,
            46,
            47,
            48,
            49,
            50,
            51,
            53,
            58,
            60,
            61,
            62,
            63,
            64,
            66,
            67,
            68,
            69,
          }.contains(command.opcode)
          ? 'native_model_core_and_3d_handler_pending:${command.opcodeName}'
          : 'native_visual_handler_pending:${command.opcodeName}';
    }
    _sceneRevision++;
    if (mounted) setState(() {});
  }

  Future<int?> _choice(
    StoryDecodedCommand command,
    StoryDispatchContext context,
  ) async {
    final epoch = _epoch;
    await _uiReady.future;
    if (!mounted || epoch != _epoch || !context.isCurrent()) {
      throw StateError('story_source_replaced');
    }
    final group = int.tryParse((command.parameter(0) ?? '').trim()) ?? 0;
    final presentation = StoryChoiceCatalog.fromChapter(_document!.chapter)
        .open(group, epoch);
    final labels = <String>[];
    for (final choice in presentation.choices) {
      final row = _document!.chapter.commands.singleWhere(
        (r) => r.index == choice.commandIndex,
      );
      labels.add(
        choice.textId.isEmpty || choice.textId == '0'
            ? ''
            : _localized(row.payload['text']),
      );
    }
    _frontUi!.showChoices(presentation, labels, epoch);
    _lastPresentedVisible = null;
    final selected = await presentation.selected;
    _seek?.recordChoice(command.index, selected.targetCommandIndex);
    if (!context.isCurrent() || epoch != _epoch) {
      throw StateError('story_source_replaced');
    }
    await presentation.finished;
    if (!context.isCurrent() || epoch != _epoch) {
      throw StateError('story_source_replaced');
    }
    _player!.acknowledge(command.index);
    return selected.targetCommandIndex;
  }

  void _tapFront([Offset? point, Size? surface]) {
    if (_seekBusy) return;
    if (!_started) {
      _start();
      return;
    }
    if (_uiHidden) {
      _toggleUi();
      return;
    }
    final shakeTap = _shakeTap;
    if (shakeTap != null && !shakeTap.isCompleted) {
      shakeTap.complete();
      return;
    }
    final front = _frontUi;
    if (front?.nextLocked == true) {
      final hit = _uiFrame?.front?.hitRects;
      if (point != null &&
          surface != null &&
          hit != null &&
          _viewport != null) {
        final scaler = _ui!.graphics.frontScaler;
        final ref = scaler['m_ReferenceResolution'] as Map;
        final scale = math.min(
          _viewport!.$1 / (ref['x'] as num),
          _viewport!.$2 / (ref['y'] as num),
        );
        final x = point.dx / surface.width * (_viewport!.$1 / scale),
            y = point.dy / surface.height * (_viewport!.$2 / scale);
        for (final entry in hit.entries) {
          final r = entry.value;
          if (x >= r.x &&
              x <= r.x + r.width &&
              y >= r.y &&
              y <= r.y + r.height) {
            front!.select(entry.key, _epoch);
            _lastPresentedVisible = null;
            break;
          }
        }
      }
      return;
    }
    if (_chat?.active == true) {
      _chat!.tap();
      _lastPresentedVisible = null;
      return;
    }
    _textController?.tap();
  }

  int? _goto(StoryDecodedCommand command) {
    final key = command.parameter(0) ?? '';
    final actual = StoryChoiceCatalog.fromChapter(_document!.chapter).keys[key];
    return actual;
  }

  List<double> _transitionColor(String? value, List<double> fallback) {
    final named = {
      'black': '000000',
      'white': 'ffffff',
      'red': 'ff0000',
      'green': '008000',
      'blue': '0000ff',
      'yellow': 'ffff00',
      'cyan': '00ffff',
      'magenta': 'ff00ff',
      'clear': '00000000',
    };
    var hex = value?.trim().toLowerCase() ?? '';
    hex = named[hex] ?? hex.replaceFirst('#', '');
    if (hex.length == 3) hex = hex.split('').map((s) => '$s$s').join();
    if (hex.length != 6 && hex.length != 8) return fallback;
    final number = int.tryParse(hex, radix: 16);
    if (number == null) return fallback;
    final rgba = hex.length == 8 ? number : (number << 8) | 255;
    return [
      for (final shift in [24, 16, 8, 0]) ((rgba >> shift) & 255) / 255,
    ];
  }

  Future<void> _uiValue(
    String channel,
    double from,
    double to,
    double seconds,
    StoryDispatchContext context,
    void Function(double) write, {
    required int commandIndex,
    required bool waitForCompletion,
    double Function(double)? curve,
    String? curveSource,
  }) {
    for (final old in _tweens.where((t) => t.channel == channel).toList()) {
      _tweens.remove(old);
      if (!old.done.isCompleted) old.done.complete();
    }
    write(from);
    if (seconds <= 0) {
      write(to);
      return Future.value();
    }
    final tween = _StoryUiTween(
      _player!.storyUs,
      seconds,
      from,
      to,
      context.isCurrent,
      write,
      channel: channel,
      curve: curve,
      curveSource: curveSource,
      executionId: context.executionId,
      commandIndex: commandIndex,
      waitForCompletion: waitForCompletion,
    );
    _tweens.add(tween);
    return tween.done.future;
  }

  Future<void> _transition(
    StoryDecodedCommand command,
    StoryDispatchContext context,
  ) async {
    if (command.opcode == 11) {
      await _player!.waitCommonCommandDelay(command, context);
      final seconds = command.durationUs > 0
          ? command.durationUs / 1000000
          : .3;
      return _uiValue(
        'flash',
        1,
        0,
        seconds / _player!.speed,
        context,
        _frontUi!.setFlash,
        commandIndex: command.index,
        waitForCompletion: !command.noWait,
      );
    }
    final definition =
        (command.payload['ruleTransition'] ??
                _document!.runtime['defaultRuleTransition'])
            as Map;
    final name = definition['name'] as String;
    final source = await _loadTransitionSource(
      name,
      definition,
      context.isCurrent,
    );
    await _player!.waitCommonCommandDelay(command, context);
    if (!context.isCurrent() || !mounted) return;
    final fadeOut = command.opcode == 5;
    final front = _frontUi!;
    front.ruleTexture = source.texture;
    front.ruleGradient = source.gradient;
    front.ruleColor = _transitionColor(
      command.parameter(0),
      fadeOut ? const [0, 0, 0, 1] : front.ruleColor,
    );
    front.ruleVisible = true;
    final seconds = command.durationUs / 1000000 / _player!.speed;
    await _uiValue(
      'rule',
      fadeOut ? 1 : -1,
      fadeOut ? -1 : 1,
      seconds,
      context,
      front.setRuleValue,
      curve: source.curve.sample,
      curveSource: name,
      commandIndex: command.index,
      waitForCompletion: !command.noWait,
    );
    if (!fadeOut && context.isCurrent()) {
      front.ruleVisible = false;
      front.revision++;
    }
  }

  Future<void> _movieFade(
    double alpha,
    double seconds,
    StoryDispatchContext context,
  ) {
    if (!context.isCurrent()) {
      return Future.error(StateError('story_source_replaced'));
    }
    if (seconds <= 0) {
      _movieAlpha = alpha;
      _movieCurtainAlpha = alpha > 0 ? 1 : 0;
      return Future.value();
    }
    final tween = _StoryUiTween(
      _player!.storyUs,
      seconds,
      _movieAlpha,
      alpha,
      context.isCurrent,
      (value) => _movieAlpha = value,
      channel: 'movieAlpha',
      executionId: context.executionId,
    );
    final curtain = _StoryUiTween(
      _player!.storyUs,
      seconds,
      _movieCurtainAlpha,
      alpha > 0 ? 1 : 0,
      context.isCurrent,
      (v) => _movieCurtainAlpha = v,
      channel: 'movieCurtainAlpha',
      executionId: context.executionId,
    );
    _tweens.addAll([tween, curtain]);
    return Future.wait([tween.done.future, curtain.done.future]);
  }

  Future<void> _replay() async {
    final epoch = _epoch + 1;
    await _load();
    if (_error != null || !mounted || epoch != _epoch) return;
    await _seekReady;
    if (mounted && epoch == _epoch) _start();
  }

  Future<void> _waitUiIdle(VegaSeekContext? context) async {
    while (_busy || _mutatingUi) {
      context?.checkCurrent();
      if (!mounted) throw const VegaSeekCancelled();
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<_StoryScreenSeekSnapshot> _captureSeekUi() async {
    await _waitUiIdle(null);
    return _StoryScreenSeekSnapshot(
      epoch: _epoch,
      runtimeHash: _document!.runtimeHash,
      mode: _mode,
      line: _line,
      speaker: _speaker,
      locale: _locale,
      pendingLocale: _pendingLocale,
      textIndex: _textIndex,
      update: _update,
      windowVisible: _windowVisible,
      nextVisible: _nextVisible,
      movieAlpha: _movieAlpha,
      curtainAlpha: _movieCurtainAlpha,
      background: _background,
      lower: _backgroundImage,
      text: _text?.cancelled == false ? _text!.snapshot() : null,
      talk: _talkUi!.snapshot(),
      front: _frontUi!.snapshot(),
      still: _stillHost!.snapshot(),
      frame: _frameHost!.snapshot(),
      chat: _chat?.snapshotData(),
      retainedUi: captureNativeStoryUiRetainedLayout(_ui!),
      backlog: List.unmodifiable(_backlog),
      tweens: List.unmodifiable([
        for (final tween in _tweens)
          _StoryUiTweenSnapshot(
            tween.atUs,
            tween.durationUs,
            tween.from,
            tween.to,
            tween.apply,
            tween.channel,
            tween.curve,
            tween.curveSource,
            executionId: tween.executionId,
            commandIndex: tween.commandIndex,
            waitForCompletion: tween.waitForCompletion,
          ),
      ]),
    );
  }

  Future<void> _quiesceSeekUi(VegaSeekContext context) async {
    await _waitUiIdle(context);
    context.checkCurrent();
    ++_uiIntent;
    _textController!.cancelActive('story_seek');
    _text = null;
    final tap = _shakeTap;
    _shakeTap = null;
    if (tap != null && !tap.isCompleted) tap.complete();
    for (final tween in _tweens) {
      if (!tween.done.isCompleted) {
        tween.done.completeError(
          const StoryPresentationCancelled('story_seek'),
        );
      }
    }
    _tweens.clear();
    _frontUi!.quiesce();
    _chat?.quiesce();
    await _stillHost!.quiesce();
    await _frameHost!.quiesce();
    _videoCapture?.close();
    _videoCapture = null;
  }

  Map _transitionDefinition(String name) {
    final definitions = [
      _document!.runtime['defaultRuleTransition'] as Map,
      ...(_document!.runtime['ruleTransitions'] as List? ?? const [])
          .cast<Map>(),
      for (final command in _document!.chapter.commands)
        if (command.payload['ruleTransition'] case final Map definition)
          definition,
    ];
    final matches = definitions.where((row) => row['name'] == name).toList();
    if (matches.isEmpty) {
      throw FormatException('story_ui_save_transition:$name');
    }
    Map normalized(Map row) => {
      'name': row['name'],
      'maskTexture': row['maskTexture'],
      'sourcePath':
          row['sourcePath'] ??
          'Assets/AddressableResources/Adv/Transition/$name/$name.asset',
    };
    String semantics(Map row) => jsonEncode(normalized(row));
    if (matches.any((row) => semantics(row) != semantics(matches.first))) {
      throw FormatException('story_ui_save_transition_ambiguous:$name');
    }
    return normalized(matches.first);
  }

  Future<NativeStoryTransitionSource> _loadTransitionSource(
    String name,
    Map definition,
    bool Function() current,
  ) => _transitionSources.putIfAbsent(name, () {
    late final Future<NativeStoryTransitionSource> pending;
    pending =
        NativeStoryTransitionSource.load(
          api: CatalogSourceScope.resolve(
            context,
            api: widget.api,
            server: widget.server,
          ),
          identity: _document!.chapter.sourceIdentity,
          definition: definition,
          current: current,
        ).catchError((Object error, StackTrace stack) {
          if (identical(_transitionSources[name], pending)) {
            _transitionSources.remove(name);
          }
          Error.throwWithStackTrace(error, stack);
        });
    return pending;
  });

  Future<Map<String, Object?>> _encodeSeekUi(
    _StoryScreenSeekSnapshot state,
  ) async {
    if (state.epoch != _epoch || state.runtimeHash != _document!.runtimeHash) {
      throw const FormatException('story_ui_save_source');
    }
    final transitions = <String, Object?>{};
    for (final tween in state.tweens) {
      final name = tween.curveSource;
      if (name == null || transitions.containsKey(name)) continue;
      final pending = _transitionSources[name];
      if (pending == null) {
        throw FormatException('story_ui_save_transition_missing:$name');
      }
      final source = await pending;
      if (!mounted || state.epoch != _epoch) throw const VegaSeekCancelled();
      transitions[name] = {
        'definition': _transitionDefinition(name),
        // NativeCubismFadeCurve accepts these exact source wrap modes.
        'curve': {
          'm_PreInfinity': 2,
          'm_PostInfinity': 2,
          'm_Curve': source.curve.keys,
        },
      };
    }
    return {
      'version': 2,
      'source': _document!.chapter.sourceIdentity.toJson(),
      'runtimeHash': state.runtimeHash,
      'resourceHashes': _ui!.sourceHashes,
      'transitions': transitions,
      'chat': state.chat,
      'mode': state.mode,
      'line': state.line,
      'speaker': state.speaker,
      'locale': state.locale,
      'pendingLocale': state.pendingLocale,
      'textIndex': state.textIndex,
      'update': state.update,
      'windowVisible': state.windowVisible,
      'nextVisible': state.nextVisible,
      'movieAlpha': state.movieAlpha,
      'curtainAlpha': state.curtainAlpha,
      'lower': state.lower == null
          ? null
          : {
              'uri': state.lower!.uri.toString(),
              'sha256': state.lower!.encodedSHA256,
              'width': state.lower!.width,
              'height': state.lower!.height,
            },
      'text': state.text?.toData(),
      'talk': state.talk.toData(),
      'front': state.front.toData(),
      'still': state.still.toData(),
      'frame': state.frame.toData(),
      'retained': state.retainedUi.toData(
        ui: _ui!,
        identity: _document!.chapter.sourceIdentity,
      ),
      'backlog': [
        for (final entry in state.backlog)
          {
            'commandIndex': entry.commandIndex,
            'speaker': entry.speaker,
            'text': entry.text,
          },
      ],
      'tweens': [
        for (final tween in state.tweens)
          {
            'atUs': tween.atUs,
            'durationUs': tween.durationUs,
            'from': tween.from,
            'to': tween.to,
            'channel': tween.channel,
            'curveSource': tween.curveSource,
            'executionId': tween.executionId,
            'commandIndex': tween.commandIndex,
            'waitForCompletion': tween.waitForCompletion,
          },
      ],
    };
  }

  Uri _resolveSavedUiResource(String saved) {
    final uri = Uri.parse(saved), identity = _document!.chapter.sourceIdentity;
    if (uri.scheme == 'haneoka-asset') {
      if (!uri.path.startsWith(NativeStoryUiSource.base)) {
        throw const FormatException('story_ui_save_package_resource');
      }
      return uri;
    }
    if (uri.queryParameters['release'] != identity.release) {
      throw const FormatException('story_ui_save_resource_release');
    }
    final api = CatalogSourceScope.resolve(
      context,
      api: widget.api,
      server: widget.server,
    );
    return api.asset(uri.path).replace(queryParameters: uri.queryParameters);
  }

  Future<void> _restoreSeekUiData(Map data, VegaSeekContext context) async {
    context.checkCurrent();
    final identity = _document!.chapter.sourceIdentity, epoch = _epoch;
    if (data['version'] != 2 ||
        StorySourceIdentity.fromJson(data['source'] as Map) != identity ||
        data['runtimeHash'] != _document!.runtimeHash) {
      throw const FormatException('story_ui_save_source');
    }
    _ui!.validateSavedResources(data['resourceHashes']);
    final stamp = _player!.actualUpdateStamp;
    await _restoreChat(data['chat'], context);
    _mode = data['mode'] as String;
    _line = data['line'] as String;
    _speaker = data['speaker'] as String;
    _locale = data['locale'] as String;
    _pendingLocale = data['pendingLocale'] as String?;
    _textIndex = data['textIndex'] as int;
    _update = data['update'] as int;
    _windowVisible = data['windowVisible'] as bool;
    _nextVisible = data['nextVisible'] as bool;
    _movieAlpha = (data['movieAlpha'] as num).toDouble();
    _movieCurtainAlpha = (data['curtainAlpha'] as num).toDouble();
    _talkUi!.restoreData(data['talk'] as Map, stamp: stamp);
    _frontUi!.restoreData(
      data['front'] as Map,
      stamp: stamp,
      resolveResource: _resolveSavedUiResource,
    );
    await _stillHost!.restoreData(data['still'] as Map, stamp: stamp);
    await _frameHost!.restoreData(data['frame'] as Map, stamp: stamp);
    context.checkCurrent();
    _text = data['text'] == null
        ? null
        : _textController!.restoreData(
            data['text'] as Map,
            actualUpdateIndex: _update,
            validateUiSource: (path, hash) =>
                (_ui!.typing['rows'] as List).cast<Map>().any(
                  (row) =>
                      row['sourceUiPath'] == path &&
                      row['sourceUiHash'] == hash,
                ),
          );
    _restoredTextIndex = _text == null ? null : _textIndex;
    restoreNativeStoryUiRetainedData(
      _ui!,
      data['retained'] as Map,
      identity: identity,
      epoch: epoch,
      storyUs: stamp.storyUs,
      updateIndex: stamp.updateIndex,
    );
    _background = null;
    _backgroundImage = null;
    if (data['lower'] case final Map lower) {
      final uri = _resolveSavedUiResource(lower['uri'] as String);
      final bytes = await _fetch(uri);
      context.checkCurrent();
      final proof = await StoryBackgroundImage.fromActualEncodedImage(
        source: RenderSource(
          server: identity.server,
          release: identity.release,
          document: identity.document,
        ),
        epoch: epoch,
        uri: uri,
        bytes: bytes,
      );
      if (proof.encodedSHA256 != lower['sha256'] ||
          proof.width != lower['width'] ||
          proof.height != lower['height']) {
        throw const FormatException('story_ui_save_background_hash');
      }
      _background = bytes;
      _backgroundImage = proof;
    }
    _sharedColourActive = _backgroundImage != null;
    _backlog
      ..clear()
      ..addAll([
        for (final entry in (data['backlog'] as List).cast<Map>())
          (
            commandIndex: entry['commandIndex'] as int,
            speaker: entry['speaker'] as String,
            text: entry['text'] as String,
          ),
      ]);
    _tweens.clear();
    for (final tween in (data['tweens'] as List).cast<Map>()) {
      final channel = tween['channel'] as String;
      final void Function(double) write = switch (channel) {
        'flash' => _frontUi!.setFlash,
        'rule' => _frontUi!.setRuleValue,
        'movieAlpha' => (value) => _movieAlpha = value,
        'movieCurtainAlpha' => (value) => _movieCurtainAlpha = value,
        _ => throw FormatException('story_ui_save_tween:$channel'),
      };
      double Function(double)? curve;
      if (tween['curveSource'] case final String name) {
        final definition = _transitionDefinition(name);
        final saved = (data['transitions'] as Map)[name] as Map;
        final savedDefinition = saved['definition'] as Map;
        for (final key in ['name', 'maskTexture', 'sourcePath']) {
          if (definition[key] != savedDefinition[key]) {
            throw const FormatException('story_ui_save_transition_source');
          }
        }
        final source = await _loadTransitionSource(
          name,
          definition,
          context.isCurrent,
        );
        context.checkCurrent();
        if (jsonEncode((saved['curve'] as Map)['m_Curve']) !=
            jsonEncode(source.curve.keys)) {
          throw const FormatException('story_ui_save_transition_curve');
        }
        if ((saved['curve'] as Map)['m_PreInfinity'] != 2 ||
            (saved['curve'] as Map)['m_PostInfinity'] != 2) {
          throw const FormatException('story_ui_save_transition_curve');
        }
        curve = source.curve.sample;
      }
      _tweens.add(
        _StoryUiTween(
          tween['atUs'] as int,
          (tween['durationUs'] as num) / 1000000,
          (tween['from'] as num).toDouble(),
          (tween['to'] as num).toDouble(),
          () => mounted && epoch == _epoch,
          write,
          channel: channel,
          curve: curve,
          curveSource: tween['curveSource'] as String?,
          executionId: tween['executionId'] as int?,
          commandIndex: tween['commandIndex'] as int?,
          waitForCompletion: tween['waitForCompletion'] as bool?,
        ),
      );
    }
    context.checkCurrent();
    _error = null;
    _completionPresented = false;
    _lastTickerUs = 0;
    _lastMotionTickerUs = 0;
    _lastPresentedVisible = null;
    _lastPresentedUiRevision = null;
    _lastFrontRevision = -1;
    _pausedColourKey = null;
    _sceneRevision++;
    if (_backgroundImage == null && _uiSession == null && _viewport != null) {
      await _openUi(_viewport!.$1, _viewport!.$2, force: true);
    }
    context.checkCurrent();
    setState(() {});
  }

  Future<void> _restoreSeekUi(
    _StoryScreenSeekSnapshot state,
    VegaSeekContext context,
  ) async {
    context.checkCurrent();
    if (!mounted ||
        state.epoch != _epoch ||
        state.runtimeHash != _document!.runtimeHash) {
      throw const FormatException('story_seek_ui_source');
    }
    await _restoreChat(state.chat, context);
    _mode = state.mode;
    _line = state.line;
    _speaker = state.speaker;
    _locale = state.locale;
    _pendingLocale = state.pendingLocale;
    _textIndex = state.textIndex;
    _update = state.update;
    _windowVisible = state.windowVisible;
    _nextVisible = state.nextVisible;
    _movieAlpha = state.movieAlpha;
    _movieCurtainAlpha = state.curtainAlpha;
    _background = state.background;
    _backgroundImage = state.lower;
    _sharedColourActive = state.lower != null;
    _talkUi!.restore(state.talk);
    _frontUi!.restore(state.front, stamp: _player!.actualUpdateStamp);
    restoreNativeStoryUiRetainedLayout(_ui!, state.retainedUi);
    await _stillHost!.restore(state.still, stamp: _player!.actualUpdateStamp);
    await _frameHost!.restore(state.frame, stamp: _player!.actualUpdateStamp);
    _text = state.text == null
        ? null
        : _textController!.restore(state.text!, _update);
    _restoredTextIndex = _text == null ? null : _textIndex;
    _backlog
      ..clear()
      ..addAll(state.backlog);
    _tweens.clear();
    for (final tween in state.tweens) {
      _tweens.add(
        _StoryUiTween(
          tween.atUs,
          tween.durationUs / 1000000,
          tween.from,
          tween.to,
          () => mounted && state.epoch == _epoch,
          tween.apply,
          channel: tween.channel,
          curve: tween.curve,
          curveSource: tween.curveSource,
          executionId: tween.executionId,
          commandIndex: tween.commandIndex,
          waitForCompletion: tween.waitForCompletion,
        ),
      );
    }
    _error = null;
    _completionPresented = false;
    _lastTickerUs = 0;
    _lastMotionTickerUs = 0;
    _lastPresentedVisible = null;
    _lastPresentedUiRevision = null;
    _lastFrontRevision = -1;
    _pausedColourKey = null;
    _sceneRevision++;
    if (state.lower == null && _uiSession == null && _viewport != null) {
      await _openUi(_viewport!.$1, _viewport!.$2, force: true);
      context.checkCurrent();
    }
    setState(() {});
  }

  Future<void> _settleSeekUi(VegaSeekContext context) async {
    context.checkCurrent();
    await _uiReady.future;
    final epoch = _epoch;
    while (true) {
      context.checkCurrent();
      if (!mounted || epoch != _epoch) throw const VegaSeekCancelled();
      final pending = [
        for (final work in _visualResourceWork.entries)
          if (work.value == epoch) work.key,
      ];
      if (pending.isEmpty) break;
      await Future.wait(pending);
    }
    await _stillHost!.settleResources();
    await _frameHost!.settleResources();
    _advanceUi(_player!.actualUpdateStamp);
    _snapshot(layoutOnly: true);
    context.checkCurrent();
  }

  Future<void> _presentSeekUi(
    NativeStoryUpdateStamp stamp,
    VegaSeekContext context,
  ) async {
    context.checkCurrent();
    if (_backgroundImage != null) {
      final before = _uiFrames;
      await _presentSharedColour(_epoch, stamp);
      context.checkCurrent();
      if (_uiFrames <= before || !_colourHost!.hasCurrentImage) {
        throw StateError('story_seek_frame_not_presented');
      }
    } else {
      await _stillHost!.update(
        stamp.storyUs,
        stamp.speed,
        stamp.paused,
        context.isCurrent,
      );
      await _frameHost!.present(context.isCurrent);
      final frame = _snapshot();
      await _uiSession!.ensureTextures(frame.textures);
      context.checkCurrent();
      await _uiSession!.present(
        frame.frame,
        resources: toRenderScene(frame.scene),
        stillCurrent: context.isCurrent,
      );
      context.checkCurrent();
      _uiFrame = frame;
      ++_uiFrames;
    }
    setState(() {});
  }

  Future<void> _replaySeekText(
    StoryDecodedCommand command,
    StoryDispatchContext context,
  ) async {
    if (_talkUi!.frame.visibility.currentMode == null) {
      _talkUi!.attachWindow('Default');
    }
    if (command.opcode == 2) _talkUi!.beginTalk(command);
    await _presentText(command, context, immediate: true);
    _nextVisible = true;
    if (command.opcode == 2) _talkUi!.requestNext();
    _lastPresentedVisible = null;
  }

  Future<StoryDispatchCompletion> _resumeSeekCommand(
    StoryDecodedCommand command,
    StoryDispatchContext context,
  ) async {
    if (const {36, 37, 38, 39, 65}.contains(command.opcode)) {
      final pending = _chat?.pendingCompletionForExecution(context.executionId);
      if (pending != null) await pending;
      if (!context.isCurrent()) throw const VegaSeekCancelled();
      return const StoryDispatchCompletion();
    }
    if (command.opcode == 41 && _frontUi!.choices != null) {
      final choices = _frontUi!.choices!;
      final selected = await choices.selected;
      if (!context.isCurrent()) {
        throw const StoryPresentationCancelled('story_seek');
      }
      _seek!.recordChoice(command.index, selected.targetCommandIndex);
      await choices.finished;
      _player!.acknowledge(command.index);
      return StoryDispatchCompletion(
        nextCommandIndex: selected.targetCommandIndex,
      );
    }
    if (command.opcode == 44 || command.opcode == 30) {
      final pending = command.opcode == 44
          ? _frameHost!.pendingCompletionForExecution(
              context.executionId,
              legacyCommandIndex: command.index,
            )
          : _stillHost!.pendingCompletionForExecution(
              context.executionId,
              legacyCommandIndex: command.index,
            );
      return pending ?? const StoryDispatchCompletion();
    }
    if (const {
      7,
      12,
      13,
      14,
      32,
      33,
      34,
      46,
      47,
      48,
      49,
      50,
      51,
      53,
      60,
      61,
      62,
      63,
      64,
      66,
      67,
    }.contains(command.opcode)) {
      await _world!.waitPendingVisualsForExecution(
        context.executionId,
        commandIndex: command.index,
        blocking: !command.noWait,
      );
    } else if (const {5, 6, 11, 26, 27}.contains(command.opcode)) {
      var owned = _tweens
          .where((tween) => tween.executionId == context.executionId)
          .toList();
      if (owned.isEmpty && !command.noWait) {
        owned = _tweens
            .where(
              (tween) =>
                  tween.executionId == null &&
                  tween.commandIndex == command.index &&
                  tween.waitForCompletion == true,
            )
            .toList();
        for (final tween in owned) {
          tween.executionId = context.executionId;
        }
        if (owned.isEmpty &&
            _tweens.any((tween) => tween.executionId == null)) {
          throw FormatException(
            'story_ui_legacy_execution_owner:${command.index}',
          );
        }
      }
      await Future.wait([for (final tween in owned) tween.done.future]);
      if (command.opcode == 6 && context.isCurrent()) {
        _frontUi!.ruleVisible = false;
        _frontUi!.revision++;
      }
    }
    if (!context.isCurrent()) {
      throw const StoryPresentationCancelled('story_seek');
    }
    return const StoryDispatchCompletion();
  }

  int _seekBoundary(int position) {
    final commands = _document!.chapter.commands;
    final bounded = position.clamp(0, commands.length);
    if (bounded == 0 || bounded == commands.length) return bounded;
    for (var i = bounded - 1; i >= 0; i--) {
      if (const {
        2,
        28,
        29,
        36,
        37,
        38,
        39,
        52,
        65,
      }.contains(commands[i].opcode)) {
        return i + 1;
      }
    }
    return 0;
  }

  String? _seekPreparationBarrier(StoryDecodedCommand command) {
    if (command.opcode < 0 ||
        command.opcode > 69 ||
        const {8, 22, 45, 54, 55, 58}.contains(command.opcode)) {
      return 'backend-opcode:${command.opcodeName}';
    }
    if (command.opcode == 26 || command.opcode == 27) {
      return 'video-clock-projection';
    }
    if (command.opcode == 35) {
      final name = (command.payload['targetAssetName'] as String)
          .split('/')
          .last;
      if (name != 'UIDefaultTalkWindow' && name != 'UICenterTalkWindow') {
        return 'talk-window:$name';
      }
    }
    if (command.opcode == 44) {
      final frame = _frameHost!.data.frames[command.resourceRefs['frameRef']];
      if (frame == null) return 'frame-source-missing';
      if (frame.unsupported.isNotEmpty) return 'frame-source-unsupported';
      final ids =
          command.payload['targetTextIds'] ??
          command.payload['_targetTextIDs'] ??
          const [];
      if (ids is! List) {
        throw const FormatException('native_frame_actual_text_ids');
      }
      if (ids.isNotEmpty) return 'frame-text-receiver';
    }
    return null;
  }

  Future<void> _seekTo(int position, {bool resume = false}) async {
    if (_seekBusy) return;
    ++_sequenceCompletionRevision;
    final epoch = _epoch;
    await _seekReady;
    if (!mounted || epoch != _epoch || _seek == null) return;
    setState(() {
      _seekBusy = true;
      _seekTargetPosition = _seekBoundary(position);
    });
    try {
      await _seek!.seek(_seekBoundary(position), resume: false);
      if (!mounted || epoch != _epoch) return;
      await _player!.setSpeed(_preferences!.speed);
      if (!mounted || epoch != _epoch) return;
      if (resume && !_player!.completed) await _player!.resume();
      if (!mounted || epoch != _epoch) return;
      _changed();
      if (!_ticker.isActive) _ticker.start();
    } catch (error, stack) {
      debugPrint('HANEOKA_STORY_SEEK_ERROR $error\n$stack');
      if (mounted && epoch == _epoch) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() {
          _seekBusy = false;
          _seekTargetPosition = null;
        });
      }
    }
  }

  Future<void> _savePosition() async {
    final seek = _seek, store = _saveStore, player = _player;
    if (_seekBusy || seek == null || store == null || player == null) return;
    final epoch = _epoch, resume = !player.paused && !player.completed;
    bool current() => mounted && epoch == _epoch && identical(_seek, seek);
    VegaNarrativeCheckpoint<NativeStorySeekSnapshot<_StoryScreenSeekSnapshot>>?
    previous;
    Object? failure;
    var saved = false;
    setState(() => _seekBusy = true);
    try {
      await _seekReady;
      if (!current()) return;
      previous = await seek.save();
      if (!current()) return;
      final envelope = await seek.encodeEnvelope(previous, fetch: _fetch);
      if (!current()) return;
      await store.writeQuick(envelope);
      if (!current()) return;
      _storedSave = envelope;
      saved = true;
    } catch (error, stack) {
      failure = error;
      debugPrint('HANEOKA_STORY_SAVE_ERROR $error\n$stack');
    } finally {
      if (current()) {
        try {
          if (previous != null) {
            await seek.load(previous, resume: resume);
          } else if (resume && player.paused) {
            await player.resume();
          }
        } catch (error, stack) {
          failure = error;
          debugPrint('HANEOKA_STORY_SAVE_RECOVERY_ERROR $error\n$stack');
        }
        if (current()) setState(() => _seekBusy = false);
      }
    }
    if (!mounted || !current()) return;
    final labels = _controls!.forLocale(
      AppScope.of(context).locale.toLanguageTag(),
    );
    if (failure != null || saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure?.toString() ?? labels['saved']!)),
      );
    }
  }

  Future<void> _loadPosition() async {
    ++_sequenceCompletionRevision;
    final envelope = _storedSave, seek = _seek, player = _player;
    if (_seekBusy || envelope == null || seek == null || player == null) return;
    final epoch = _epoch, resume = !player.paused && !player.completed;
    final wasStarted = _started, wasTicking = _ticker.isActive;
    bool current() => mounted && epoch == _epoch && identical(_seek, seek);
    VegaNarrativeCheckpoint<NativeStorySeekSnapshot<_StoryScreenSeekSnapshot>>?
    previous;
    Object? failure;
    var loaded = false;
    setState(() => _seekBusy = true);
    try {
      await _seekReady;
      if (!current()) return;
      previous = await seek.save();
      if (!current()) return;
      await seek.loadEnvelope(envelope, fetch: _fetch, resume: false);
      if (!current()) return;
      await player.setSpeed(_preferences!.speed);
      if (!current()) return;
      loaded = true;
      _started = true;
      if (resume && !player.completed) await player.resume();
      if (!current()) return;
      _changed();
      if (!_ticker.isActive) _ticker.start();
    } catch (error, stack) {
      failure = error;
      debugPrint('HANEOKA_STORY_LOAD_ERROR $error\n$stack');
    } finally {
      if (current()) {
        if (!loaded) {
          try {
            if (previous != null) {
              await seek.load(previous, resume: false);
              await player.setSpeed(_preferences!.speed);
              if (resume && !player.completed) await player.resume();
            } else if (resume && player.paused) {
              await player.resume();
            }
            if (current()) {
              _started = wasStarted;
              if (wasTicking && !_ticker.isActive) _ticker.start();
              if (!wasTicking) _ticker.stop();
            }
          } catch (error, stack) {
            failure = error;
            debugPrint('HANEOKA_STORY_LOAD_RECOVERY_ERROR $error\n$stack');
          }
        }
        if (current()) setState(() => _seekBusy = false);
      }
    }
    if (mounted && current() && failure != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.toString())));
    }
  }

  void _start() {
    if (_started ||
        _preparing ||
        _seekBusy ||
        _player == null ||
        (_uiSession == null && !_sharedColourActive)) {
      return;
    }
    setState(() {
      _started = true;
      _starting = true;
    });
    _lastTickerUs = 0;
    _lastMotionTickerUs = 0;
    if (!_ticker.isActive) _ticker.start();
    final epoch = _epoch;
    unawaited(
      (() async {
        await _seekReady;
        if (!mounted || epoch != _epoch) return;
        if (_talkUi!.frame.visibility.currentMode == null) {
          _talkUi!.attachWindow('Default');
        }
        _talkUi!.setAutoMode(_player!.autoPlayback);
        await _player!.play();
      })().catchError((Object error, StackTrace stack) {
        _fail(error, stack, epoch);
      }),
    );
  }

  void _changed() {
    final player = _player;
    if (player != null && player.error != null && _error == null) {
      _fail(
        player.error!,
        player.errorStackTrace ?? StackTrace.current,
        _epoch,
      );
      return;
    }
    if (player != null) {
      _talkUi?.setAutoMode(player.autoPlayback);
      if (_seekBusy || _seek?.seeking == true) {
        _world?.clearVoiceBindings();
      } else {
        _world?.syncVoiceCues(
          player.media.cues,
          paused: player.paused,
          storySpeed: player.speed,
          shortcut: player.voiceShortcut,
        );
      }
    }
    final movie = player?.media.cues
        .where((cue) => cue.kind == StoryMediaKind.movie)
        .firstOrNull;
    final state = (
      player,
      player?.paused,
      player?.completed,
      player?.autoPlayback,
      player?.speed,
      player?.controller.cursor,
      player?.canSkipClip,
      movie,
      movie?.player.state.width,
      movie?.player.state.height,
      _started,
      _chat?.revision,
    );
    if (state == _lastUiState) return;
    _lastUiState = state;
    if (mounted) setState(() {});
  }

  void _fail(Object error, StackTrace stack, int epoch) {
    debugPrint('HANEOKA_NATIVE_STORY_ERROR epoch=$epoch $error\n$stack');
    if (!mounted || epoch != _epoch) return;
    if (!_uiReady.isCompleted) _uiReady.completeError(error);
    _ticker.stop();
    _error = error;
    _preparing = _starting = false;
    unawaited(_player?.pause());
    setState(() {});
  }

  Future<void> _presentSharedColour(
    int epoch,
    NativeStoryUpdateStamp stamp,
  ) async {
    final intent = _uiIntent;
    bool current() => mounted && epoch == _epoch && intent == _uiIntent;
    final still = _stillHost!.snapshotForColour(stamp);
    final frame = _frameHost!.snapshotForColour(stamp);
    final front = _snapshot();
    final lower = _backgroundImage!;
    final owner = _colourHost!;
    final forcePostLutRebuild = !owner.hasWorldPostLut(
      _viewport!.$1,
      _viewport!.$2,
    );
    final snapshot = composeStoryColour(
      lower: lower,
      backgroundClearColor: _world!.cameraClearColor,
      worldViewport: spatialWorldViewport(
        _viewport!.$1,
        _viewport!.$2,
        _spatialFactor,
      ),
      actualStamp: stamp,
      world: _world?.active == true
          ? _world!.snapshot(
              stamp,
              (spatialWorldViewport(
                        _viewport!.$1,
                        _viewport!.$2,
                        _spatialFactor,
                      ) ??
                      _viewport!)
                  .$1,
              (spatialWorldViewport(
                        _viewport!.$1,
                        _viewport!.$2,
                        _spatialFactor,
                      ) ??
                      _viewport!)
                  .$2,
              forcePostLutRebuild: forcePostLutRebuild,
            )
          : null,
      width: _viewport!.$1,
      height: _viewport!.$2,
      layers: [
        NativeStoryColourLayer(
          sortingOrder: 302,
          contentTarget: 'story-still-main',
          scene: still.scene,
          frame: still.frame,
          textures: still.textures,
        ),
        NativeStoryColourLayer(
          sortingOrder: 303,
          contentTarget: 'frame:main',
          scene: frame.scene,
          frame: frame.frame,
          textures: frame.textures,
          dataTextures: _frameHost!.dataTextures,
        ),
        if (!_uiHidden)
          NativeStoryColourLayer(
            sortingOrder: 304,
            contentTarget: 'story-ui',
            scene: front.scene,
            frame: front.frame,
            textures: front.textures,
          ),
      ],
    );
    final movie = _player!.media.cues
        .where((c) => c.kind == StoryMediaKind.movie && c.video != null)
        .firstOrNull;
    try {
      await owner.present(
        lower: lower,
        snapshot: snapshot,
        spatialSharpness: _rendering?.sharpness ?? .8705505632961241,
        current: current,
        prepareDecodedVideo: movie == null
            ? null
            : (renderer, generation, active) async {
                if (!current() || !active() || _videoUi == null) return null;
                final params = movie.player.state.videoParams;
                final sw = params.dw ?? movie.player.state.width,
                    sh = params.dh ?? movie.player.state.height;
                if (sw == null || sh == null || sw <= 0 || sh <= 0) return null;
                final key = 'video:decoded:$_epoch:${movie.id}:$generation';
                if (_videoCapture?.cue != movie ||
                    !identical(_videoRenderer, renderer) ||
                    _videoSessionGeneration != generation) {
                  _videoCapture?.close();
                  _videoRenderer = renderer;
                  _videoSessionGeneration = generation;
                  _videoCapture = NativeStoryVideoTexture(
                    cue: movie,
                    renderer: renderer,
                    textureKey: 'colour:301:$key',
                    boundaryKey: _videoBoundary,
                    pixelRatio: _pixelRatio,
                    isCurrent: () =>
                        current() &&
                        active() &&
                        identical(_videoRenderer, renderer) &&
                        _videoSessionGeneration == generation &&
                        _player!.media.cues.contains(movie),
                  );
                }
                if (!await _videoCapture!.capturePaintedFrame()) return null;
                if (!current() || !active()) return null;
                final video = _videoUi!.layer(
                  source: lower.source,
                  stamp: stamp,
                  width: _viewport!.$1,
                  height: _viewport!.$2,
                  sourceWidth: sw,
                  sourceHeight: sh,
                  decodedTextureKey: key,
                  videoAlpha: _movieAlpha.clamp(0, 1),
                  curtainAlpha: _movieCurtainAlpha.clamp(0, 1),
                );
                return composeStoryColour(
                  lower: lower,
                  backgroundClearColor: _world!.cameraClearColor,
                  worldViewport: spatialWorldViewport(
                    _viewport!.$1,
                    _viewport!.$2,
                    _spatialFactor,
                  ),
                  actualStamp: stamp,
                  world: _world?.active == true
                      ? _world!.snapshot(
                          stamp,
                          (spatialWorldViewport(
                                    _viewport!.$1,
                                    _viewport!.$2,
                                    _spatialFactor,
                                  ) ??
                                  _viewport!)
                              .$1,
                          (spatialWorldViewport(
                                    _viewport!.$1,
                                    _viewport!.$2,
                                    _spatialFactor,
                                  ) ??
                                  _viewport!)
                              .$2,
                          forcePostLutRebuild: forcePostLutRebuild,
                        )
                      : null,
                  width: _viewport!.$1,
                  height: _viewport!.$2,
                  layers: [
                    video,
                    NativeStoryColourLayer(
                      sortingOrder: 302,
                      contentTarget: 'story-still-main',
                      scene: still.scene,
                      frame: still.frame,
                      textures: still.textures,
                    ),
                    NativeStoryColourLayer(
                      sortingOrder: 303,
                      contentTarget: 'frame:main',
                      scene: frame.scene,
                      frame: frame.frame,
                      textures: frame.textures,
                    ),
                    if (!_uiHidden)
                      NativeStoryColourLayer(
                        sortingOrder: 304,
                        contentTarget: 'story-ui',
                        scene: front.scene,
                        frame: front.frame,
                        textures: front.textures,
                      ),
                  ],
                );
              },
      );
    } catch (_) {
      if (!current()) return;
      rethrow;
    }
    if (!current() ||
        !owner.hasCurrentImage ||
        (!_uiHidden &&
            !owner.containsSubmittedLayer(304, front.scene, front.frame))) {
      return;
    }
    _stillHost!.recordColourPresentation(still, owner);
    _frameHost!.recordColourPresentation(frame, owner);
    _uiFrame = front;
    _uiFrames++;
    _lastPresentedVisible = _text?.visibleLength;
    _lastPresentedUiRevision = _talkUi!.frame.visualRevision;
    _lastFrontRevision = _frontUi!.revision;
    _lastChatRevision = _chat?.revision ?? -1;
    final changed = !_sharedColourActive;
    _sharedColourActive = true;
    final ui = _uiSession;
    _uiSession = null;
    final retireStill = _stillHost!.image != null;
    final retireFrame = _frameHost!.image != null;
    if (changed || ui != null || retireStill || retireFrame) {
      await ui?.dispose();
      if (retireStill) await _stillHost!.retireSurfaceForColour();
      if (retireFrame) await _frameHost!.retireSurfaceForColour();
      if (current()) setState(() {});
    }
  }

  void _advanceUi(NativeStoryUpdateStamp stamp) {
    for (final tween in _tweens.toList()) {
      if (!tween.current()) {
        _tweens.remove(tween);
        tween.done.completeError(StateError('story_fade_cancelled'));
      } else {
        final progress = ((stamp.storyUs - tween.atUs) / tween.durationUs)
            .clamp(0.0, 1.0);
        final eased = tween.curve?.call(progress) ?? progress;
        tween.apply(tween.from + (tween.to - tween.from) * eased);
        if (progress == 1) {
          _tweens.remove(tween);
          tween.done.complete();
        }
      }
    }
    if (!_mutatingUi) {
      final pair = stamp;
      final uiStamp = NativeStoryUpdateStamp(
        sourceEpoch: pair.sourceEpoch,
        updateIndex: pair.updateIndex,
        storyUs: pair.storyUs,
        speed: stamp.speed,
        paused: stamp.paused,
      );
      _talkUi!.actualUiPhase(uiStamp);
      _frontUi!.actualUiPhase(uiStamp);
      _chat?.actualUiPhase(_chatStamp(uiStamp));
    }
  }

  void _tick(Duration elapsed) async {
    final player = _player, now = elapsed.inMicroseconds;
    final motionNow = _motionClock.elapsedMicroseconds;
    final motionDelta = _lastMotionTickerUs == 0
        ? 0.0
        : (motionNow - _lastMotionTickerUs) / 1000000;
    _lastMotionTickerUs = motionNow;
    if (player == null ||
        _error != null ||
        _seek?.seeking == true ||
        _seekBusy) {
      _lastMotionTickerUs = 0;
      return;
    }
    try {
      _world?.advanceMotionFrame(
        deltaSeconds: motionDelta,
        atUs: motionNow,
        speed: player.speed,
        transportPaused: player.paused,
      );
    } catch (error, stack) {
      _fail(error, stack, _epoch);
      return;
    }
    if (_busy) return;
    _busy = true;
    final epoch = _epoch;
    final delta = _lastTickerUs == 0 ? 0.0 : (now - _lastTickerUs) / 1000000;
    _lastTickerUs = now;
    try {
      if (player.completed && !_completionPresented) _world?.resetShakes();
      await player.actualUpdate();
      if (!mounted || epoch != _epoch || _seekBusy || _seek?.seeking == true) {
        return;
      }
      final stamp = player.actualUpdateStamp;
      _world?.syncVoiceCues(
        player.media.cues,
        paused: player.paused,
        storySpeed: player.speed,
        shortcut: player.voiceShortcut,
        observations: player.mediaObservations,
      );
      if (_backgroundImage == null) {
        await _stillHost!.update(
          stamp.storyUs,
          stamp.speed,
          stamp.paused,
          () => mounted && epoch == _epoch,
        );
        if (!mounted || epoch != _epoch) return;
        await _frameHost!.present(() => mounted && epoch == _epoch);
        if (!mounted || epoch != _epoch) return;
      }
      _textController!.update(
        StoryTextFrame(
          sourceEpoch: epoch,
          updateIndex: ++_update,
          deltaSeconds: delta,
          paused: player.paused,
        ),
      );
      if (player.autoPlayback && _nextVisible) _text?.automaticNext(epoch);
      _advanceUi(stamp);
      if (_backgroundImage != null && !_mutatingUi && _viewport != null) {
        final key = (
          epoch,
          _uiIntent,
          _viewport,
          player.actualUpdateStamp.storyUs,
          player.controller.cursor,
          _sceneRevision,
          _uiHidden,
          _text?.visibleLength,
          _talkUi!.frame.visualRevision,
          _frontUi!.revision,
          _chat?.revision,
          _movieAlpha,
          _movieCurtainAlpha,
        );
        if (!player.paused ||
            _pausedColourKey != key ||
            _colourHost?.hasCurrentImage != true) {
          final before = _uiFrames;
          await _presentSharedColour(epoch, player.actualUpdateStamp);
          if (!mounted || epoch != _epoch) return;
          if (_uiFrames > before) _pausedColourKey = key;
        }
      }
      final session = _uiSession;
      if (!_mutatingUi &&
          session != null &&
          _viewport != null &&
          (_lastPresentedVisible != _text?.visibleLength ||
              _lastPresentedUiRevision != _talkUi!.frame.visualRevision ||
              _lastFrontRevision != _frontUi!.revision ||
              _lastChatRevision != (_chat?.revision ?? -1) ||
              _uiFrames == 1)) {
        final frame = _snapshot();
        final intent = _uiIntent;
        bool currentUi() =>
            mounted &&
            epoch == _epoch &&
            intent == _uiIntent &&
            identical(session, _uiSession);
        try {
          await session.ensureTextures(frame.textures);
          if (!currentUi()) return;
          await session.present(
            frame.frame,
            resources: toRenderScene(frame.scene),
            stillCurrent: currentUi,
          );
        } catch (_) {
          if (!currentUi()) return;
          rethrow;
        }
        if (!currentUi()) return;
        _uiFrame = frame;
        _uiFrames++;
        _lastPresentedVisible = _text?.visibleLength;
        _lastPresentedUiRevision = _talkUi!.frame.visualRevision;
        _lastFrontRevision = _frontUi!.revision;
        _lastChatRevision = _chat?.revision ?? -1;
      }
      if (const bool.fromEnvironment('HANEOKA_NATIVE_TRACE') &&
          _update % 60 == 0) {
        debugPrint(
          'HANEOKA_NATIVE_STORY_FRAME source=${_document!.chapter.sourceIdentity.document} '
          'storyUs=${player.storyUs} update=$_update textIndex=$_textIndex '
          'visible=${_text?.visibleLength} glyphs=${_uiFrame?.talk.renderedGlyphCount} '
          'resources=${_colourHost?.observation['resources'] ?? _uiSession?.renderer.resourceCounts} '
          'media=${await player.media.sample()} unsupported=$_unsupportedVisual',
        );
      }
      const path = String.fromEnvironment('HANEOKA_NATIVE_STORY_EXPORT');
      final stillVisible = _stillHost!.hasRenderedStill;
      final stillUs = _stillHost!.renderedStoryUs;
      if (!_exported &&
          path.isNotEmpty &&
          (stillVisible || (_text != null && !_text!.typing)) &&
          _uiFrames > 1) {
        _exported = true;
        final captured = await _export(path, epoch);
        if (captured && stillVisible && mounted && epoch == _epoch) {
          _lastStillCaptureUs = stillUs;
          _stillCaptures++;
        }
      } else if (path.isNotEmpty &&
          stillVisible &&
          stillUs != null &&
          _lastStillCaptureUs != null &&
          _stillCaptures < 4 &&
          stillUs - _lastStillCaptureUs! >=
              (_stillCaptures == 2 ? 500000 : 1000000)) {
        final captured = await _export('$path.still-$stillUs.png', epoch);
        if (captured && mounted && epoch == _epoch) {
          _lastStillCaptureUs = stillUs;
          _stillCaptures++;
        }
      }
      if (player.completed) {
        final firstCompletion = !_completionPresented;
        _completionPresented = true;
        _ticker.stop();
        final sequence = widget.sequence;
        if (firstCompletion && _started && sequence != null) {
          final id = widget.storyId;
          final completionRevision = _sequenceCompletionRevision;
          unawaited(
            sequence.complete(
              storyId: id,
              epoch: epoch,
              completionRevision: completionRevision,
              automatic: player.autoPlayback,
              isCurrent: () =>
                  mounted &&
                  epoch == _epoch &&
                  completionRevision == _sequenceCompletionRevision &&
                  !_seekBusy &&
                  _seek?.seeking != true &&
                  widget.storyId == id &&
                  identical(sequence, widget.sequence) &&
                  identical(player, _player) &&
                  _completionPresented &&
                  player.completed,
            ),
          );
        }
      } else if (!_started && _uiFrames > 1) {
        _ticker.stop();
      }
      if (_starting &&
          (player.completed ||
              (_world?.active == true &&
                  _colourHost?.hasCurrentImage == true) ||
              ((_videoCapture?.captures ?? 0) > 0 &&
                  _colourHost?.hasCurrentImage == true) ||
              player.media.cues.any((cue) => cue.videoFrameRendered) ||
              _frameHost!.hasRenderedFrame ||
              _stillHost!.hasRenderedStill ||
              (_uiFrames > 2 &&
                  (_text != null ||
                      (_chat?.active == true &&
                          _lastChatRevision == _chat!.revision) ||
                      _frontUi!.locationVisible ||
                      _frontUi!.captionVisible ||
                      _frontUi!.ruleVisible ||
                      _frontUi!.flashAlpha > 0 ||
                      _frontUi!.choices != null)))) {
        setState(() => _starting = false);
      }
    } catch (error, stack) {
      _fail(error, stack, epoch);
    } finally {
      if (epoch == _epoch) _busy = false;
    }
  }

  Future<bool> _export(String path, int epoch) async {
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted || epoch != _epoch) return false;
    final document = _document!,
        player = _player!,
        sourceUi = _ui!,
        frame = _uiFrame!,
        presentation = _text;
    final storyUs = player.storyUs,
        textIndex = _textIndex,
        frameCount = _uiFrames,
        locale = _locale;
    final unsupported = Map<int, String>.of(_unsupportedVisual);
    final observedStamp = player.actualUpdateStamp;
    final exportPath =
        '$path.epoch-$epoch.update-${observedStamp.updateIndex}.png';
    final boundary = _capture.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      _exported = false;
      return false;
    }
    final image = await boundary.toImage(
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted || epoch != _epoch || bytes == null) return false;
      await File(exportPath).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      if (!mounted || epoch != _epoch) return false;
      final media = await player.media.sample();
      if (!mounted || epoch != _epoch) return false;
      final receipt = {
        'source': document.chapter.sourceIdentity.document,
        'sourceId': document.chapter.sourceIdentity.sourceId,
        'release': document.chapter.sourceIdentity.release,
        'chapterHash': document.chapter.sourceIdentity.sourceHash,
        'runtimeHash': document.runtimeHash,
        'sourceEpoch': epoch,
        'exportObservedUpdateIndex': observedStamp.updateIndex,
        'exportObservedUpdateUs': observedStamp.storyUs,
        'uiSourceHashes': sourceUi.sourceHashes,
        'actualStoryUs': storyUs,
        'uiFrameStoryUs': frame.frame.mediaMicroseconds,
        'mediaObservedStoryUs': player.storyUs,
        'textIndex': textIndex,
        'glyphs': frame.talk.renderedGlyphCount,
        'visible': presentation?.visibleLength ?? 0,
        'typing': presentation?.typing ?? false,
        'uiFrames': frameCount,
        'locale': locale,
        'media': [
          for (final cue in media)
            {
              'id': cue.cueId,
              'kind': cue.kind.name,
              'positionUs': cue.positionUs,
              'durationUs': cue.durationUs,
              'playing': cue.playing,
              'completed': cue.completed,
              'error': cue.error,
            },
        ],
        'videoCapture': _videoCapture?.observation,
        'world': _world?.observation,
        'unsupportedVisual': unsupported.map((k, v) => MapEntry('$k', v)),
        'unsupportedUi': frame.unsupported,
        'textMeasurements': frame.textMeasurements,
        'still': _stillHost?.observation,
        'frame': _frameHost?.observation,
        'chat': _chat?.snapshotData(),
        'colourScene': _colourHost?.observation,
        'uiTextureResources': _uiSession?.renderer.textureResources,
        'uiTargetResources': _uiSession?.renderer.targetResources,
        'commandObservations': player.commandObservations,
        'completePlayer': false,
        'physicalTapEvidence': false,
      };
      await File('$exportPath.json').writeAsString(
        jsonEncode(
          receipt,
          toEncodable: (value) => value is Map
              ? value.map((key, entry) => MapEntry(key.toString(), entry))
              : throw UnsupportedError(
                  'story_export_value:${value.runtimeType}',
                ),
        ),
      );
      debugPrint('HANEOKA_NATIVE_STORY_EXPORT $receipt');
      return true;
    } finally {
      image.dispose();
    }
  }

  @override
  void dispose() {
    widget.sequence?.removeListener(_sequenceChanged);
    _rendering?.removeListener(_renderQualityChanged);
    _seek?.dispose();
    _logVoice?.dispose();
    ++_epoch;
    if (!_uiReady.isCompleted) {
      _uiReady.completeError(StateError('story_closed'));
    }
    _ticker.dispose();
    _world?.close();
    _talkUi?.close();
    _frontUi?.close();
    _videoCapture?.close();
    _textController?.close();
    for (final tween in _tweens) {
      if (!tween.done.isCompleted) {
        tween.done.completeError(StateError('story_closed'));
      }
    }
    _player?.removeListener(_changed);
    _player?.media.removeListener(_changed);
    unawaited(_player?.close());
    unawaited(_uiSession?.dispose());
    unawaited(_stillHost?.dispose());
    _chat?.close();
    unawaited(_frameHost?.dispose());
    unawaited(_colourHost?.dispose());
    super.dispose();
  }

  Widget _paintedVideo(
    NativeStoryMediaCue movie,
    int width,
    int height,
    double ratio,
  ) {
    final params = movie.player.state.videoParams;
    final sw = params.dw ?? movie.player.state.width,
        sh = params.dh ?? movie.player.state.height;
    if (sw == null || sh == null || sw <= 0 || sh <= 0) {
      return RepaintBoundary(
        key: _videoBoundary,
        child: Video(
          controller: movie.video!,
          controls: NoVideoControls,
          fit: BoxFit.contain,
        ),
      );
    }
    final r = _videoUi!.containedPixels(width, height, sw, sh);
    return Positioned(
      left: r.x / ratio,
      top: r.y / ratio,
      width: r.width / ratio,
      height: r.height / ratio,
      child: RepaintBoundary(
        key: _videoBoundary,
        child: Video(
          controller: movie.video!,
          controls: NoVideoControls,
          fit: BoxFit.fill,
        ),
      ),
    );
  }

  Future<void> _showBacklog() async {
    if (_seekBusy) return;
    final player = _player, epoch = _epoch;
    final wasPlaying = _started && player?.paused == false;
    if (wasPlaying) await player!.pause();
    if (!mounted || epoch != _epoch) return;
    final entries = List.of(_backlog), document = _document!;
    final voice = _logVoice ??= VoicePlayback();
    await voice.stop();
    if (!mounted || epoch != _epoch) return;
    final destination = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: voice,
          builder: (context, _) => ListView.builder(
            reverse: true,
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[entries.length - index - 1];
              final command = document.chapter.commands.firstWhere(
                (command) => command.index == entry.commandIndex,
              );
              final clips = [
                for (final id in command.voiceIds)
                  VoiceClip(
                    id: id,
                    url: document.assets
                        .resolve(
                          document.assets.referenceFor(
                            StoryMediaKind.voice,
                            id,
                          ),
                          StoryMediaKind.voice,
                        )
                        .toString(),
                  ),
              ];
              final speaking = clips.any((clip) => voice.isPlaying(clip.id));
              return ListTile(
                key: ValueKey((epoch, entries.length - index - 1)),
                title: entry.speaker.isEmpty ? null : Text(entry.speaker),
                subtitle: AdvText(entry.text),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (clips.isNotEmpty)
                      IconButton(
                        tooltip: AppScope.of(context).text(
                          speaking ? 'media.voice.stop' : 'media.audio.play',
                          speaking ? 'Stop' : 'Play',
                        ),
                        icon: Icon(
                          speaking
                              ? Symbols.stop_rounded
                              : Symbols.volume_up_rounded,
                        ),
                        onPressed: () => unawaited(
                          speaking ? voice.stop() : voice.playAll(clips),
                        ),
                      ),
                    IconButton(
                      tooltip: AppScope.of(context)
                          .text('common.actions.seek', 'Seek'),
                      icon: const Icon(Symbols.replay_rounded),
                      onPressed: () =>
                          Navigator.of(context).pop(entry.commandIndex + 1),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await voice.stop();
    if (mounted && epoch == _epoch && destination != null) {
      await _seekTo(destination, resume: wasPlaying);
      return;
    }
    if (mounted &&
        epoch == _epoch &&
        identical(player, _player) &&
        wasPlaying) {
      await player!.resume();
    }
  }

  Future<void> _updatePreferences(Future<void> Function() write) {
    // SharedPreferences updates its in-memory value before the disk future.
    final instantBefore = _preferences?.instantText;
    final captionsBefore = _preferences?.subtitlesEnabled;
    final textSizeBefore = _preferences?.textSize;
    final saved = write();
    if (!mounted) return saved;
    final preferences = _preferences!, player = _player;
    if (preferences.instantText && instantBefore != preferences.instantText) {
      _text?.requestReveal(_epoch);
    }
    if (player != null) player.autoDelaySeconds = preferences.autoDelay;
    if (captionsBefore != preferences.subtitlesEnabled) {
      _frontUi?.setCaptionsEnabled(preferences.subtitlesEnabled, _epoch);
    }
    if (instantBefore != preferences.instantText ||
        captionsBefore != preferences.subtitlesEnabled ||
        textSizeBefore != preferences.textSize) {
      _sceneRevision++;
      _pausedColourKey = null;
      _lastPresentedVisible = null;
      if (_started && !_ticker.isActive) _ticker.start();
    }
    setState(() {});
    return Future.wait([saved, _schedulePreferenceMedia()]).then((_) {});
  }

  Future<void> _schedulePreferenceMedia() {
    _preferenceMediaPending = true;
    final running = _preferenceMediaApply;
    if (running != null) return running;
    late final Future<void> operation;
    operation = _drainPreferenceMedia().whenComplete(() {
      if (identical(_preferenceMediaApply, operation)) {
        _preferenceMediaApply = null;
      }
    });
    _preferenceMediaApply = operation;
    return operation;
  }

  Future<void> _drainPreferenceMedia() async {
    while (mounted && _preferenceMediaPending) {
      _preferenceMediaPending = false;
      final epoch = _epoch, player = _player, preferences = _preferences;
      if (player == null || preferences == null) continue;
      if (player.speed != preferences.speed) {
        await player.setSpeed(preferences.speed);
      }
      if (!mounted) return;
      if (epoch != _epoch || !identical(player, _player)) {
        _preferenceMediaPending = true;
        continue;
      }
      if (player.userVolume != preferences.masterVolume ||
          player.userBgmVolume != preferences.bgmVolume ||
          player.bgmEnabled != preferences.bgmEnabled) {
        await player.setUserAudio(
          master: preferences.masterVolume,
          bgm: preferences.bgmVolume,
          enabled: preferences.bgmEnabled,
        );
      }
    }
  }

  Future<void> _settings() async {
    if (_seekBusy) return;
    final player = _player, epoch = _epoch;
    final wasPlaying = _started && player?.paused == false;
    if (wasPlaying) await player!.pause();
    if (!mounted || epoch != _epoch) return;
    final preferences = _preferences!, t = AppScope.of(context).text;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) {
          Future<void> change(Future<void> Function() write) async {
            final updated = _updatePreferences(write);
            if (sheetContext.mounted) refresh(() {});
            await updated;
          }

          Widget range(
            String label,
            double value,
            double max,
            Future<void> Function(double) write, {
            double min = 0,
          }) => ListTile(
            title: Text(label),
            subtitle: Slider(
              value: value,
              min: min,
              max: max,
              label: value.toStringAsFixed(1),
              onChanged: (value) => unawaited(change(() => write(value))),
            ),
          );

          return PlayerSettingsSheet(
            title:
                _controls?.forLocale(t.locale)['settings'] ??
                t('navigation.settings', 'Settings'),
            closeLabel: t('common.actions.close', 'Close'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: Text(t('story.labels.instantText', 'Instant')),
                  value: preferences.instantText,
                  onChanged: (value) => unawaited(
                    change(() => preferences.setInstantText(value)),
                  ),
                ),
                SwitchListTile(
                  title: Text(t('story.labels.subtitles', 'Subtitles')),
                  value: preferences.subtitlesEnabled,
                  onChanged: (value) => unawaited(
                    change(() => preferences.setSubtitlesEnabled(value)),
                  ),
                ),
                SwitchListTile(
                  title: Text(t('story.labels.bgm', 'BGM')),
                  value: preferences.bgmEnabled,
                  onChanged: (value) =>
                      unawaited(change(() => preferences.setBgmEnabled(value))),
                ),
                range(
                  t('media.playback.fields.speed', 'Speed'),
                  preferences.speed,
                  4,
                  preferences.setSpeed,
                  min: .25,
                ),
                range(
                  t('media.audio.volume', 'Volume'),
                  preferences.masterVolume,
                  1,
                  preferences.setMasterVolume,
                ),
                range(
                  t('story.labels.bgm', 'BGM'),
                  preferences.bgmVolume,
                  1,
                  preferences.setBgmVolume,
                ),
                range(
                  t('story.labels.autoDelay', 'Auto delay'),
                  preferences.autoDelay,
                  30,
                  preferences.setAutoDelay,
                ),
                RenderQualitySettings(
                  preferences: AppScope.of(context).rendering,
                  text: t,
                ),
                range(
                  t('story.labels.textSize', 'Text size'),
                  preferences.textSize,
                  2,
                  preferences.setTextSize,
                  min: .5,
                ),
              ],
            ),
          );
        },
      ),
    );
    await _preferenceMediaApply;
    if (mounted &&
        epoch == _epoch &&
        identical(player, _player) &&
        wasPlaying) {
      await player!.resume();
    }
  }

  void _toggleAuto() {
    if (_seekBusy) return;
    final player = _player;
    if (player == null) return;
    if (player.completed) {
      unawaited(_replay());
    } else if (!_started) {
      _start();
    } else {
      if (player.paused) unawaited(player.resume());
      player.setAutoPlayback(!player.autoPlayback);
      _talkUi!.setAutoMode(player.autoPlayback);
      _lastPresentedVisible = null;
    }
  }

  Future<void> _sequenceAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  void _toggleUi() {
    if (_seekBusy) return;
    setState(() {
      _uiHidden = !_uiHidden;
      _sceneRevision++;
      _pausedColourKey = null;
      _lastPresentedVisible = null;
    });
    if (_started && !_ticker.isActive) _ticker.start();
  }

  Future<void> _skip() async {
    if (_seekBusy) return;
    final player = _player;
    if (player == null) return;
    if (player.canSkipClip) {
      player.skipClip();
      return;
    }
    await player.skipToEnd();
    if (!mounted || !identical(player, _player)) return;
    _textController?.cancelActive('story_skipped');
    _nextVisible = false;
    _talkUi?.hideNext();
    _lastPresentedVisible = null;
    if (!_ticker.isActive) _ticker.start();
    setState(() {});
  }

  Widget _preparationOverlay() {
    final t = AppScope.of(context).text;
    final detail = _seekBusy
        ? '${t('story.playback.sceneIndex', 'Scene index')} / ${_seekTargetPosition ?? _player!.controller.cursor}'
        : _preparingIndex
        ? '${t('story.playback.sceneIndex', 'Scene index')} / $_preparedIndexCommands / $_preparationIndexCommands'
        : _preparing && _preparationModels > 0
        ? '${t('story.playback.resources', 'Story resources')} / $_preparedModels / $_preparationModels'
        : t('story.playback.resources', 'Story resources');
    return ColoredBox(
      color: const Color(0xff111317),
      child: PlayerPreparationIndicator(
        foregroundColor: const Color(0xffc4c6d0),
        label: t('story.playback.preparing', 'Preparing playback'),
        detail: detail,
        progress: _preparingIndex && _preparationIndexCommands > 0
            ? _preparedIndexCommands / _preparationIndexCommands
            : _preparing && !_preparingIndex && _preparationModels > 0
            ? _preparedModels / _preparationModels
            : null,
      ),
    );
  }

  Future<void> _openText() async {
    ++_sequenceCompletionRevision;
    final navigator = Navigator.of(context);
    if (!widget.replaceTextMode && await navigator.maybePop()) return;
    if (!mounted) return;
    final builder = widget.textModeBuilder;
    if (builder == null) return;
    await navigator.pushReplacement<void, void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(
          name: Uri(
            pathSegments: ['', 'stories', widget.storyId],
            queryParameters: widget.server == null
                ? null
                : {'server': widget.server!},
          ).toString(),
        ),
        builder: builder,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DisplayFrameRateScope(
    targetHz: 60,
    child: PlayerOrientationScope(
      landscape: true,
      child: _buildPlayer(context),
    ),
  );

  Widget _buildPlayer(BuildContext context) {
    final state = AppScope.of(context), t = state.text;
    final player = _player;
    final title = t.text(_document?.chapter.document['title'] ?? widget.title);
    return ShellPage(
      title: title.isEmpty ? t('navigation.story', 'Story') : title,
      actions: [
        BarAction.choice(
          label: t('media.audio.playback', 'Playback'),
          options: [
            BarChoice(
              icon: Symbols.article_rounded,
              label: t('navigation.storyText', 'Text'),
              selected: false,
              onSelected: () => unawaited(_openText()),
            ),
            BarChoice(
              icon: Symbols.play_circle_rounded,
              label: t('navigation.player', 'Player'),
              selected: true,
              onSelected: () {},
            ),
          ],
        ),
      ],
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error is CubismCoreUnavailable
                          ? t(
                              'story.playback.live2dUnavailable',
                              'Live2D playback is unavailable on this device.',
                            )
                          : t(
                              'story.playback.loadFailed',
                              'Story playback could not be loaded.',
                            ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonal(
                          onPressed: _load,
                          child: Text(t('common.actions.retry', 'Retry')),
                        ),
                        TextButton.icon(
                          onPressed: _openText,
                          icon: const Icon(Symbols.article_rounded),
                          label: Text(t('navigation.storyText', 'Text')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : player == null || _ui == null
          ? ColoredBox(
              color: const Color(0xff111317),
              child: PlayerPreparationIndicator(
                foregroundColor: const Color(0xffc4c6d0),
                label: t('story.playback.preparing', 'Preparing playback'),
                detail: t('story.playback.resources', 'Story resources'),
              ),
            )
          : PlaybackPane(
              playing: _started && !player.paused,
              position: player.controller.cursor.toDouble(),
              maximum: _document!.chapter.commands.length.toDouble(),
              positionLabel: '${player.controller.cursor}',
              maximumLabel: '${_document!.chapter.commands.length}',
              leadLabel: player.completed
                  ? t('common.actions.replay', 'Replay')
                  : _started
                  ? t('story.playback.auto', 'Auto')
                  : t('common.actions.play', 'Play'),
              leadActive: _started && !player.completed
                  ? player.autoPlayback
                  : null,
              leadReplay: player.completed,
              controlsVisible: !_uiHidden,
              busy: _seekBusy || _preparing || _starting,
              onToggle: _toggleAuto,
              onScrubStart: () {
                if (_seekBusy) return;
                ++_sequenceCompletionRevision;
                _scrubResume = _started && !player.paused;
                unawaited(player.pause());
              },
              onSeek: (value) =>
                  unawaited(_seekTo(value.round(), resume: _scrubResume)),
              onStageActivate: () => _tapFront(),
              collapsed: !(_preferences?.expanded ?? false),
              onCollapsed: (collapsed) {
                unawaited(_preferences!.setExpanded(!collapsed));
                setState(() {});
              },
              stage: (context) => LayoutBuilder(
                builder: (context, outer) {
                  final displayPortrait =
                      MediaQuery.sizeOf(context).height >
                      MediaQuery.sizeOf(context).width;
                  final baseAspect =
                      (_document!.runtime['layout']
                              as Map)['designViewportAspect']
                          as num;
                  final stageHeight = storyViewportHeight(
                    width: outer.maxWidth,
                    height: outer.maxHeight,
                    pixelRatio: MediaQuery.devicePixelRatioOf(context),
                    displayPortrait: displayPortrait,
                    baseAspect: baseAspect.toDouble(),
                  );
                  return ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: SizedBox(
                        width: outer.maxWidth,
                        height: stageHeight,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final ratio = MediaQuery.devicePixelRatioOf(
                              context,
                            );
                            _pixelRatio = ratio;
                            final w = (constraints.maxWidth * ratio).round(),
                                h = (constraints.maxHeight * ratio).round();
                            if (_viewport != (w, h) &&
                                !_mutatingUi &&
                                w > 0 &&
                                h > 0) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) unawaited(_openUi(w, h));
                              });
                            }
                            final movie = player.media.cues
                                .where(
                                  (c) =>
                                      c.kind == StoryMediaKind.movie &&
                                      c.video != null,
                                )
                                .firstOrNull;
                            return FocusableActionDetector(
                              autofocus: true,
                              shortcuts: const {
                                SingleActivator(LogicalKeyboardKey.space):
                                    ActivateIntent(),
                                SingleActivator(LogicalKeyboardKey.enter):
                                    ActivateIntent(),
                                SingleActivator(LogicalKeyboardKey.keyH):
                                    _HideStoryUiIntent(),
                                SingleActivator(LogicalKeyboardKey.keyA):
                                    _AutoStoryIntent(),
                                SingleActivator(LogicalKeyboardKey.keyL):
                                    _StoryLogIntent(),
                              },
                              actions: {
                                ActivateIntent: CallbackAction<ActivateIntent>(
                                  onInvoke: (_) {
                                    _tapFront();
                                    return null;
                                  },
                                ),
                                _HideStoryUiIntent:
                                    CallbackAction<_HideStoryUiIntent>(
                                      onInvoke: (_) {
                                        _toggleUi();
                                        return null;
                                      },
                                    ),
                                _AutoStoryIntent:
                                    CallbackAction<_AutoStoryIntent>(
                                      onInvoke: (_) {
                                        _toggleAuto();
                                        return null;
                                      },
                                    ),
                                _StoryLogIntent:
                                    CallbackAction<_StoryLogIntent>(
                                      onInvoke: (_) {
                                        unawaited(_showBacklog());
                                        return null;
                                      },
                                    ),
                              },
                              child: Semantics(
                                label: _uiFrame?.talk.letterTestText ?? _line,
                                button: true,
                                onTap: () => _tapFront(),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: (details) => _tapFront(
                                    details.localPosition,
                                    Size(
                                      constraints.maxWidth,
                                      constraints.maxHeight,
                                    ),
                                  ),
                                  onSecondaryTapUp: (_) => _toggleUi(),
                                  child: RepaintBoundary(
                                    key: _capture,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        const ColoredBox(color: Colors.black),
                                        if (_background != null)
                                          Image.memory(
                                            _background!,
                                            fit: BoxFit.cover,
                                          ),
                                        if (movie != null && _videoUi != null)
                                          _paintedVideo(movie, w, h, ratio),
                                        // Original Canvas sorting: Video301, Still302,
                                        // Frame303, Front304, all on sorting layer zero.
                                        if (_sharedColourActive &&
                                            _colourHost?.image != null)
                                          ValueListenableBuilder<ui.Image?>(
                                            valueListenable:
                                                _colourHost!.image!,
                                            builder: (_, frame, _) => RawImage(
                                              image: frame,
                                              fit: BoxFit.fill,
                                            ),
                                          )
                                        else ...[
                                          if (_stillHost?.image
                                              case final image?)
                                            ValueListenableBuilder<ui.Image?>(
                                              valueListenable: image,
                                              builder: (_, frame, _) =>
                                                  RawImage(
                                                    image: frame,
                                                    fit: BoxFit.fill,
                                                  ),
                                            ),
                                          if (_frameHost?.image
                                              case final image?)
                                            ValueListenableBuilder<ui.Image?>(
                                              valueListenable: image,
                                              builder: (_, frame, _) =>
                                                  RawImage(
                                                    image: frame,
                                                    fit: BoxFit.fill,
                                                  ),
                                            ),
                                          if (_uiSession != null && !_uiHidden)
                                            ValueListenableBuilder<ui.Image?>(
                                              valueListenable:
                                                  _uiSession!.image,
                                              builder: (_, image, _) =>
                                                  RawImage(
                                                    image: image,
                                                    fit: BoxFit.fill,
                                                  ),
                                            ),
                                        ],
                                        if (!_started && !_preparing)
                                          Center(
                                            child: FilledButton.tonalIcon(
                                              onPressed: _seekBusy
                                                  ? null
                                                  : _start,
                                              icon: const Icon(
                                                Symbols.play_arrow_rounded,
                                              ),
                                              label: Text(
                                                t(
                                                  'common.actions.play',
                                                  'Play',
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (!_uiHidden && _controls != null)
                                          StoryPlayerMenu(
                                            menuKey: _menuKey,
                                            controls: _controls!,
                                            busy:
                                                _seekBusy ||
                                                _preparing ||
                                                _starting,
                                            enabled: {
                                              'load': _storedSave != null,
                                              'continuous':
                                                  widget.sequence?.available ??
                                                  false,
                                            },
                                            locale: state.locale
                                                .toLanguageTag(),
                                            height: constraints.maxHeight,
                                            actions: {
                                              'auto': _toggleAuto,
                                              'fast': () => unawaited(
                                                player.toggleFastForward(),
                                              ),
                                              'skip': () => unawaited(_skip()),
                                              'log': () =>
                                                  unawaited(_showBacklog()),
                                              'save': () =>
                                                  unawaited(_savePosition()),
                                              'load': () =>
                                                  unawaited(_loadPosition()),
                                              'subtitles': () => unawaited(
                                                _updatePreferences(
                                                  () => _preferences!
                                                      .setSubtitlesEnabled(
                                                        !_preferences!
                                                            .subtitlesEnabled,
                                                      ),
                                                ),
                                              ),
                                              'hide': _toggleUi,
                                              'fullscreen':
                                                  PlaybackStageScope.maybeOf(
                                                    context,
                                                  )!.toggleFullscreen!,
                                              'progress': () =>
                                                  PlaybackStageScope.maybeOf(
                                                    context,
                                                  )!.setControlsExpanded!(
                                                    !(_preferences?.expanded ??
                                                        true),
                                                  ),
                                              'settings': () =>
                                                  unawaited(_settings()),
                                              'replay': () =>
                                                  unawaited(_replay()),
                                              if (widget.sequence
                                                  case final sequence?) ...{
                                                'continuous': () => unawaited(
                                                  _sequenceAction(
                                                    sequence.toggleContinuous,
                                                  ),
                                                ),
                                                'interrupt': () => unawaited(
                                                  _sequenceAction(
                                                    sequence.interrupt,
                                                  ),
                                                ),
                                              },
                                            },
                                            selected: {
                                              'auto': player.autoPlayback,
                                              'fast': player.fastForward,
                                              'subtitles': _preferences!
                                                  .subtitlesEnabled,
                                              'fullscreen':
                                                  PlaybackStageScope.maybeOf(
                                                    context,
                                                  )!.fullscreen,
                                              'progress':
                                                  _preferences!.expanded,
                                              'continuous':
                                                  widget.sequence?.continuous ??
                                                  false,
                                            },
                                          ),
                                        if (_preparing ||
                                            _starting ||
                                            _seekBusy)
                                          _preparationOverlay(),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

final class _StoryScreenSeekSnapshot {
  const _StoryScreenSeekSnapshot({
    required this.epoch,
    required this.runtimeHash,
    required this.mode,
    required this.line,
    required this.speaker,
    required this.locale,
    required this.pendingLocale,
    required this.textIndex,
    required this.update,
    required this.windowVisible,
    required this.nextVisible,
    required this.movieAlpha,
    required this.curtainAlpha,
    required this.background,
    required this.lower,
    required this.text,
    required this.talk,
    required this.front,
    required this.still,
    required this.frame,
    required this.chat,
    required this.retainedUi,
    required this.backlog,
    required this.tweens,
  });
  final int epoch, textIndex, update;
  final String runtimeHash, mode, line, speaker, locale;
  final String? pendingLocale;
  final bool windowVisible, nextVisible;
  final double movieAlpha, curtainAlpha;
  final Uint8List? background;
  final StoryBackgroundImage? lower;
  final StoryTextPresentationSnapshot? text;
  final NativeStoryTalkUiSnapshot talk;
  final NativeStoryFrontUiStateSnapshot front;
  final NativeStoryStillHostSnapshot still;
  final NativeStoryFrameHostSnapshot frame;
  final Map<String, Object?>? chat;
  final NativeStoryUiRetainedCheckpoint retainedUi;
  final List<({int commandIndex, String speaker, String text})> backlog;
  final List<_StoryUiTweenSnapshot> tweens;
}

final class _StoryUiTweenSnapshot {
  const _StoryUiTweenSnapshot(
    this.atUs,
    this.durationUs,
    this.from,
    this.to,
    this.apply,
    this.channel,
    this.curve,
    this.curveSource, {
    this.executionId,
    this.commandIndex,
    this.waitForCompletion,
  });
  final int atUs, durationUs;
  final double from, to;
  final void Function(double) apply;
  final String? channel;
  final double Function(double)? curve;
  final String? curveSource;
  final int? executionId, commandIndex;
  final bool? waitForCompletion;
}

final class _HideStoryUiIntent extends Intent {
  const _HideStoryUiIntent();
}

final class _AutoStoryIntent extends Intent {
  const _AutoStoryIntent();
}

final class _StoryLogIntent extends Intent {
  const _StoryLogIntent();
}

final class _StoryUiTween {
  _StoryUiTween(
    this.atUs,
    double seconds,
    this.from,
    this.to,
    this.current,
    this.apply, {
    this.channel,
    this.curve,
    this.curveSource,
    this.executionId,
    this.commandIndex,
    this.waitForCompletion,
  }) : durationUs = (seconds * 1000000).round() {
    unawaited(done.future.catchError((Object _) {}));
  }
  final int atUs, durationUs;
  final double from, to;
  final bool Function() current;
  final void Function(double) apply;
  final String? channel;
  final double Function(double)? curve;
  final String? curveSource;
  int? executionId;
  final int? commandIndex;
  final bool? waitForCompletion;
  final done = Completer<void>();
}
