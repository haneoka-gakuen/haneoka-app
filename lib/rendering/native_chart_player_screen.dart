import 'package:haneoka_render_profile_flutter/haneoka_render_profile_flutter.dart'
    show
        haneokaProfileAssetRoot,
        loadHaneokaProfileAsset,
        loadHaneokaProfileString;

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:cassiopeia_plugin_our_notes/chart_ui_profile.dart';
import 'package:cassiopeia_renderer_flutter/overview.dart';
import 'package:render_kernel_flutter/render_kernel_flutter.dart'
    show DisplayFrameRateScope;

import '../core/api.dart';
import '../core/catalog_source.dart';
import '../core/app_state.dart';
import '../core/render_preferences.dart';
import '../core/resource_file_cache.dart';
import '../shell/page.dart';
import '../ui/playback_pane.dart';
import '../ui/player_orientation.dart';
import '../ui/player_settings_sheet.dart';
import '../ui/player_preparation_indicator.dart';
import '../ui/render_quality_settings.dart';
import 'native_chart_document.dart';
import 'native_chart_playback.dart';
import 'native_chart_preferences.dart';
import 'chart_overview_source.dart';
import 'render_budget.dart';

/// Normal selected-catalog chart path. The diagnostic native-renderer route is
/// separate and retains its immutable visual comparison receipts.
class NativeChartPlayerScreen extends StatefulWidget {
  const NativeChartPlayerScreen({
    super.key,
    this.song,
    this.api,
    required this.difficulty,
    this.songId,
    this.server,
    this.document,
  });
  final Map? song;
  final HaneokaApi? api;
  final int difficulty;
  final String? songId, server;
  final NativeChartDocument? document;
  @override
  State<NativeChartPlayerScreen> createState() =>
      _NativeChartPlayerScreenState();
}

class _NativeChartPlayerScreenState extends State<NativeChartPlayerScreen>
    with SingleTickerProviderStateMixin {
  RenderPreferences? _rendering;
  void _renderQualityChanged() {
    _clearFrameDebt();
    final value = _rendering!;
    _player?.setRenderQuality(factor: value.factor, sharpness: value.sharpness);
  }

  NativeChartPlayback? _player;
  NativeChartDocument? _document;
  Future<ChartOverviewSource>? _overviewFuture;
  ChartOverviewSource? _overviewSource;
  bool _watchMode = false;
  Object? _error;
  bool _autoplayUsed = false, _captured = false, _resumeAfterScrub = false;
  bool _drainingFrames = false, _pendingHardwareTick = false;
  int _frameDebtEpoch = 0, _frameActionDepth = 0;

  void _clearFrameDebt() {
    _pendingHardwareTick = false;
    ++_frameDebtEpoch;
  }

  bool _canContinueFrameDrain(NativeChartPlayback player, int epoch) =>
      mounted &&
      epoch == _frameDebtEpoch &&
      identical(player, _player) &&
      _watchMode &&
      _ticker.isTicking &&
      _frameActionDepth == 0 &&
      _error == null &&
      _viewport ==
          (player.logicalWidth, player.logicalHeight, player.pixelRatio) &&
      player.document?.key == _document?.key &&
      player.canCoalesceFrameRequests;

  final _throttle = FrameThrottle();
  late final Ticker _ticker = createTicker((elapsed) async {
    final player = _player;
    if (player == null || !_throttle.admit(elapsed)) return;
    if (_drainingFrames) {
      _pendingHardwareTick = _canContinueFrameDrain(player, _frameDebtEpoch);
      return;
    }
    _drainingFrames = true;
    final epoch = _frameDebtEpoch;
    try {
      do {
        _pendingHardwareTick = false;
        await player.requestFrame();
        const path = String.fromEnvironment('HANEOKA_NATIVE_PLAYER_EXPORT');
        const captureUs = int.fromEnvironment(
          'HANEOKA_NATIVE_CAPTURE_AT_US',
          defaultValue: 5000000,
        );
        const requireFx = bool.fromEnvironment(
          'HANEOKA_NATIVE_EXPORT_REQUIRE_FX',
        );
        if (!_captured &&
            path.isNotEmpty &&
            player.mediaUs >= captureUs &&
            (!requireFx || player.hasVisibleEffects)) {
          _captured = true;
          try {
            final receipt = await player.exportCurrentFrame(path);
            debugPrint('HANEOKA_NATIVE_PLAYER_EXPORT $receipt');
          } catch (error) {
            debugPrint('HANEOKA_NATIVE_PLAYER_EXPORT_ERROR $error');
          }
        }

        if (!_pendingHardwareTick || !_canContinueFrameDrain(player, epoch)) {
          break;
        }
        // Let queued commands and Flutter's frame callbacks run before
        // consuming the single hardware tick that arrived during rendering.
        await Future<void>.delayed(Duration.zero);
      } while (_pendingHardwareTick && _canContinueFrameDrain(player, epoch));
    } finally {
      _pendingHardwareTick = false;
      _drainingFrames = false;
    }
  });
  final _bytes = <String, Future<Uint8List>>{};
  final _paneKey = GlobalKey();
  (double, double, double)? _viewport;
  int _viewportRequest = 0;
  int _load = 0;

  Future<Uint8List> _fetch(Uri uri) => _bytes
      .putIfAbsent(uri.toString(), () async {
        if (uri.scheme == 'haneoka-asset') {
          final value = await loadHaneokaProfileAsset(uri.path);
          return value.buffer.asUint8List(
            value.offsetInBytes,
            value.lengthInBytes,
          );
        }
        if (uri.scheme == 'file') return File.fromUri(uri).readAsBytes();
        return resourceFileCache.readBytes(
          uri,
          kind: ResourceFileKind.renderResource,
        );
      })
      .catchError((Object error) {
        _bytes.remove(uri.toString());
        throw error;
      });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rendering = AppScope.of(context).rendering;
    if (!identical(_rendering, rendering)) {
      _rendering?.removeListener(_renderQualityChanged);
      _rendering = rendering..addListener(_renderQualityChanged);
    }
    final locale = AppScope.of(context).text.locale;
    if (_player != null) {
      unawaited(_action(() => _player!.setLocale(locale)));
      return;
    }
    _player = NativeChartPlayback(locale, fetch: _fetch)..addListener(_changed);
    _renderQualityChanged();
    _player!.audio.addListener(_changed);
    NativeChartPreferences.load()
        .then((preferences) {
          if (!mounted) return;
          _player!.preferences = preferences;
          _loadDocument();
        })
        .catchError((Object error) {
          if (mounted) setState(() => _error = error);
        });
  }

  Future<void> _loadDocument() async {
    _clearFrameDebt();
    final load = ++_load, state = AppScope.of(context);
    try {
      final NativeChartDocument doc;
      if (widget.document case final document?) {
        doc = document;
      } else {
        final api = CatalogSourceScope.resolve(
          context,
          api: widget.api,
          server: widget.server,
        );
        final song =
            widget.song ?? await api.catalog('songs', widget.songId) as Map;
        doc = await NativeChartDocument.fromSong(
          song,
          widget.difficulty,
          api,
          state.songTitle(song['musicTitle']),
        );
      }
      if (!mounted || load != _load) return;
      setState(() {
        _document = doc;
        _error = null;
        _viewport = null;
        _loadOverview(doc);
      });
    } catch (error) {
      debugPrint('HANEOKA_NATIVE_DOCUMENT_ERROR $error');
      if (mounted && load == _load) setState(() => _error = error);
    }
  }

  void _loadOverview(NativeChartDocument document) {
    final old = _overviewSource;
    _overviewSource = null;
    final task = loadChartOverviewSource(
      document.withNoteSkin(_player!.preferences.noteSkin),
      _fetch,
    );
    _overviewFuture = task;
    if (old != null) {
      SchedulerBinding.instance.endOfFrame.then((_) => old.dispose());
    }
    task.then((source) {
      if (!mounted || !identical(task, _overviewFuture)) {
        source.dispose();
        return;
      }
      _overviewSource = source;
    }, onError: (Object _) {});
  }

  void _setMode(bool watch) {
    if (_watchMode == watch) return;
    _clearFrameDebt();
    if (!watch) {
      _ticker.stop();
      unawaited(_player!.pause());
    }
    setState(() {
      _watchMode = watch;
      _viewport = null;
      ++_viewportRequest;
    });
  }

  /// What failed to load, next to the action that loads it again.
  Widget _failed(VoidCallback retry) {
    final t = AppScope.of(context).text;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Text(t('common.loading.failed', 'Loading failed')),
          FilledButton.tonal(
            onPressed: retry,
            child: Text(t('common.actions.retry', 'Retry')),
          ),
        ],
      ),
    );
  }

  Widget _overview() => FutureBuilder<ChartOverviewSource>(
    future: _overviewFuture,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return _failed(() => setState(() => _loadOverview(_document!)));
      }
      final source = snapshot.data;
      if (source == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return ChartOverviewView(data: source.data, atlas: source.atlas);
    },
  );

  Future<void> _retry() async {
    final player = _player!, document = _document;
    if (player.error != null &&
        document != null &&
        player.logicalWidth > 0 &&
        player.logicalHeight > 0) {
      setState(() => _error = null);
      await _action(
        () => player.open(
          document,
          width: player.logicalWidth,
          height: player.logicalHeight,
          pixelRatio: player.pixelRatio,
        ),
      );
    } else {
      await _loadDocument();
    }
  }

  void _changed() {
    if (!mounted) return;
    final player = _player!;
    if (_watchMode &&
        player.session != null &&
        !player.loading &&
        player.error == null &&
        player.presentationPlaying) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      _clearFrameDebt();
      if (_ticker.isActive) _ticker.stop();
    }
    if (player.needsCompletionFrame) {
      player.requestFrame(force: true);
    }
    if (!_autoplayUsed &&
        const bool.fromEnvironment('HANEOKA_NATIVE_AUTOPLAY') &&
        player.session != null &&
        !player.loading &&
        _document != null) {
      _autoplayUsed = true;
      _action(player.play);
    }
    setState(() {});
  }

  Future<void> _settings() async {
    final player = _player!;
    final t = AppScope.of(context).text;
    var preferences = player.preferences;
    var revision = 0;
    final soundPacket = jsonDecode(
      await loadHaneokaProfileString(
        '${haneokaProfileAssetRoot}note-sounds.json',
      ),
    ) as Map;
    final soundNames = soundPacket['names'] as Map;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refresh(VoidCallback change) {
            final previous = preferences;
            setSheetState(change);
            if (identical(previous, preferences)) return;
            final selected = preferences;
            final currentRevision = ++revision;
            unawaited(
              _action(() async {
                await player.setPreferences(selected);
                if (!mounted ||
                    currentRevision != revision ||
                    !identical(_player, player)) {
                  return;
                }
                if (previous.noteSkin != selected.noteSkin &&
                    _document != null) {
                  setState(() => _loadOverview(_document!));
                }
              }),
            );
          }

          return PlayerSettingsSheet(
            title: t('media.chartPlayer.settings', 'Live settings'),
            closeLabel: t('common.actions.close', 'Close'),
            actions: [
              IconButton(
                tooltip: t('media.chartPlayer.reset', 'Reset'),
                onPressed: () {
                  unawaited(AppScope.of(context).rendering.reset());
                  refresh(() => preferences = const NativeChartPreferences());
                },
                icon: const Icon(Symbols.restart_alt_rounded),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                if (player.gekisouAvailable) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey('live-mode:${player.liveMode}'),
                    initialValue: player.liveMode,
                    decoration: InputDecoration(
                      labelText: t('media.chartPlayer.liveMode', 'Live mode'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'normal',
                        child: Text(
                          t('media.chartPlayer.normalLive', 'Normal Live'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'gekisou',
                        child: Text(
                          t('media.chartPlayer.gekisouLive', 'GEKISO Live'),
                        ),
                      ),
                    ],
                    onChanged: (mode) async {
                      if (mode == null) return;
                      await _action(() => player.setLiveMode(mode));
                      if (context.mounted) refresh(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                DropdownButtonFormField<String>(
                  key: ValueKey('note-skin:${preferences.noteSkin}'),
                  initialValue: preferences.noteSkin,
                  decoration: InputDecoration(
                    labelText: t('media.chartPlayer.noteSkin', 'Note design'),
                  ),
                  items: [
                    for (final skin in NativeChartPreferences.noteSkins)
                      DropdownMenuItem(
                        value: skin,
                        child: Text(
                          NativeChartPreferences.noteSkinNames[skin]![t
                              .locale]!,
                        ),
                      ),
                  ],
                  onChanged: (skin) {
                    if (skin != null) {
                      refresh(
                        () =>
                            preferences = preferences.copyWith(noteSkin: skin),
                      );
                    }
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('effect-skin:${preferences.noteEffectSkin}'),
                  initialValue: preferences.noteEffectSkin,
                  decoration: InputDecoration(
                    labelText: t(
                      'media.chartPlayer.noteEffectSkin',
                      'Judgement effect',
                    ),
                  ),
                  items: [
                    for (final skin in NativeChartPreferences.noteEffectSkins)
                      DropdownMenuItem(
                        value: skin,
                        child: Text(
                          NativeChartPreferences.noteEffectSkinNames[skin]![t
                              .locale]!,
                        ),
                      ),
                  ],
                  onChanged: (skin) {
                    if (skin != null) {
                      refresh(
                        () => preferences = preferences.copyWith(
                          noteEffectSkin: skin,
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  key: ValueKey('note-se:${preferences.noteSeGroup}'),
                  initialValue: preferences.noteSeGroup,
                  decoration: InputDecoration(
                    labelText: t('media.chartPlayer.noteSe', 'Note sounds'),
                  ),
                  items: [
                    for (var group = 1; group <= 4; group++)
                      DropdownMenuItem(
                        value: group,
                        child: Text(
                          (soundNames['$group'] as Map)[t.locale] as String,
                        ),
                      ),
                  ],
                  onChanged: (group) {
                    if (group != null) {
                      refresh(
                        () => preferences = preferences.copyWith(
                          noteSeGroup: group,
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  key: ValueKey('quality:${preferences.effectQuality}'),
                  initialValue: preferences.effectQuality,
                  decoration: InputDecoration(
                    labelText: t(
                      'media.chartPlayer.liveQuality',
                      'Live quality',
                    ),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 0,
                      child: Text(
                        t('media.chartPlayer.qualityOptions.high', 'High'),
                      ),
                    ),
                    DropdownMenuItem(
                      value: 1,
                      child: Text(
                        t('media.chartPlayer.qualityOptions.middle', 'Middle'),
                      ),
                    ),
                    DropdownMenuItem(
                      value: 2,
                      child: Text(
                        t('media.chartPlayer.qualityOptions.low', 'Low'),
                      ),
                    ),
                  ],
                  onChanged: (quality) {
                    if (quality != null) {
                      refresh(
                        () => preferences = preferences.copyWith(
                          effectQuality: quality,
                        ),
                      );
                    }
                  },
                ),
                Text(
                  '${t('media.chartPlayer.noteSpeed', 'Note speed')} ${preferences.noteSpeed.toStringAsFixed(1)}',
                ),
                Slider(
                  value: preferences.noteSpeed,
                  min: 1,
                  max: 12,
                  divisions: 110,
                  onChanged: (speed) => refresh(
                    () => preferences = preferences.copyWith(noteSpeed: speed),
                  ),
                ),
                _settingSlider(
                  t('media.chartPlayer.noteSize', 'Note width'),
                  preferences.noteSize,
                  .5,
                  1.5,
                  (value) => refresh(
                    () => preferences = preferences.copyWith(noteSize: value),
                  ),
                ),
                _settingSlider(
                  t('media.chartPlayer.longOpacity', 'Long-note opacity'),
                  preferences.longAlpha,
                  .1,
                  1,
                  (value) => refresh(
                    () => preferences = preferences.copyWith(longAlpha: value),
                  ),
                ),
                _settingSlider(
                  t('media.chartPlayer.guideOpacity', 'Guide-note opacity'),
                  preferences.guideAlpha,
                  .1,
                  1,
                  (value) => refresh(
                    () => preferences = preferences.copyWith(guideAlpha: value),
                  ),
                ),
                SwitchListTile(
                  title: Text(t('media.chartPlayer.effects', 'Effects')),
                  value: preferences.effects,
                  onChanged: (value) => refresh(
                    () => preferences = preferences.copyWith(effects: value),
                  ),
                ),
                SwitchListTile(
                  title: Text(
                    t(
                      'media.chartPlayer.simultaneousLine',
                      'Simultaneous line',
                    ),
                  ),
                  value: preferences.showSimultaneousLine,
                  onChanged: (value) => refresh(
                    () => preferences = preferences.copyWith(
                      showSimultaneousLine: value,
                    ),
                  ),
                ),
                SwitchListTile(
                  title: Text(
                    t('media.chartPlayer.judgementLine', 'Judgement line'),
                  ),
                  value: preferences.showJudgementLine,
                  onChanged: (value) => refresh(
                    () => preferences = preferences.copyWith(
                      showJudgementLine: value,
                    ),
                  ),
                ),
                _settingSlider(
                  t(
                    'media.chartPlayer.backgroundBrightness',
                    'Background brightness',
                  ),
                  preferences.backgroundBrightness,
                  0,
                  1,
                  (value) => refresh(
                    () => preferences = preferences.copyWith(
                      backgroundBrightness: value,
                    ),
                  ),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('stage:${preferences.stageBackground}'),
                  initialValue: preferences.stageBackground,
                  decoration: InputDecoration(
                    labelText: t(
                      'media.chartPlayer.stageBackground',
                      'Stage background',
                    ),
                  ),
                  items: [
                    for (final stage in NativeChartPreferences.stageBackgrounds)
                      DropdownMenuItem(
                        value: stage,
                        child: Text(
                          stage == 'auto'
                              ? t('media.chartPlayer.songBand', 'Song band')
                              : stage == 'none'
                              ? t(
                                  'media.chartPlayer.noBackground',
                                  'No background',
                                )
                              : NativeChartPreferences.stageNames[stage]![t
                                    .locale]!,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      refresh(
                        () => preferences = preferences.copyWith(
                          stageBackground: value,
                        ),
                      );
                    }
                  },
                ),
                _settingSlider(
                  t('media.chartPlayer.laneOpacity', 'Lane opacity'),
                  preferences.laneOpacity,
                  0,
                  1,
                  (value) => refresh(
                    () =>
                        preferences = preferences.copyWith(laneOpacity: value),
                  ),
                ),
                _settingSlider(
                  t('media.chartPlayer.guidelineOpacity', 'Guideline opacity'),
                  preferences.guidelineOpacity,
                  0,
                  1,
                  (value) => refresh(
                    () => preferences = preferences.copyWith(
                      guidelineOpacity: value,
                    ),
                  ),
                ),
                DropdownButtonFormField<int>(
                  key: ValueKey('guidelines:${preferences.guidelineCount}'),
                  initialValue: preferences.guidelineCount,
                  decoration: InputDecoration(
                    labelText: t(
                      'media.chartPlayer.guidelineCount',
                      'Guideline count',
                    ),
                  ),
                  items: [
                    for (final count in OurNotesChartUiProfile.guidelineCounts)
                      DropdownMenuItem(value: count, child: Text('$count')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      refresh(
                        () => preferences = preferences.copyWith(
                          guidelineCount: value,
                        ),
                      );
                    }
                  },
                ),
                SwitchListTile(
                  title: Text(t('media.chartPlayer.vibration', 'Vibration')),
                  subtitle: player.supportsVibration
                      ? null
                      : Text(
                          t(
                            'media.chartPlayer.vibrationUnavailable',
                            'Unavailable on this device',
                          ),
                        ),
                  value: preferences.vibration,
                  onChanged: player.supportsVibration
                      ? (enabled) => refresh(
                          () => preferences = preferences.copyWith(
                            vibration: enabled,
                          ),
                        )
                      : null,
                ),
                SwitchListTile(
                  title: Text(t('media.chartPlayer.mirror', 'Mirror')),
                  value: preferences.mirror,
                  onChanged: (mirror) => refresh(
                    () => preferences = preferences.copyWith(mirror: mirror),
                  ),
                ),
                Text(
                  '${t('media.chartPlayer.playbackSpeed', 'Playback speed')} ${preferences.playbackRate.toStringAsFixed(2)}×',
                ),
                Slider(
                  value: preferences.playbackRate,
                  min: .5,
                  max: 2,
                  divisions: 30,
                  onChanged: (rate) => refresh(
                    () =>
                        preferences = preferences.copyWith(playbackRate: rate),
                  ),
                ),
                Text(
                  '${t('media.chartPlayer.volume', 'Volume')} ${preferences.musicVolume.round()}%',
                ),
                Slider(
                  value: preferences.musicVolume,
                  min: 0,
                  max: 100,
                  divisions: 100,
                  onChanged: (volume) => refresh(
                    () =>
                        preferences = preferences.copyWith(musicVolume: volume),
                  ),
                ),
                RenderQualitySettings(
                  preferences: AppScope.of(context).rendering,
                  text: AppScope.of(context).text,
                ),
                SwitchListTile(
                  title: Text(
                    t('media.chartPlayer.continuationEffects', 'Combo effects'),
                  ),
                  value: preferences.continuation,
                  onChanged: (enabled) => refresh(
                    () => preferences = preferences.copyWith(
                      continuation: enabled,
                    ),
                  ),
                ),
                SwitchListTile(
                  title: Text(
                    t('media.chartPlayer.comboDisplay', 'Show combo count'),
                  ),
                  value: preferences.showCombo,
                  onChanged: (show) => refresh(
                    () => preferences = preferences.copyWith(showCombo: show),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _settingSlider(
    String label,
    double value,
    double minimum,
    double maximum,
    ValueChanged<double> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('$label ${(value * 100).round()}%'),
      Slider(
        value: value,
        min: minimum,
        max: maximum,
        divisions: ((maximum - minimum) / .05).round(),
        onChanged: onChanged,
      ),
    ],
  );

  Future<void> _action(Future<void> Function() action) async {
    _clearFrameDebt();
    ++_frameActionDepth;
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      --_frameActionDepth;
    }
  }

  void _queueViewport(
    NativeChartPlayback player,
    NativeChartDocument document,
    (double, double, double) viewport,
    PlaybackStageScope? presentation,
  ) {
    if (presentation?.isCurrent() == false ||
        viewport.$1 <= 0 ||
        viewport.$2 <= 0) {
      return;
    }
    final applied = (
      player.logicalWidth,
      player.logicalHeight,
      player.pixelRatio,
    );
    if (_viewport == viewport &&
        applied == viewport &&
        player.document?.key == document.key) {
      return;
    }
    _clearFrameDebt();
    _viewport = viewport;
    final request = ++_viewportRequest;
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          request != _viewportRequest ||
          presentation?.isCurrent() == false) {
        return;
      }
      await _action(() async {
        if (const bool.fromEnvironment('HANEOKA_NATIVE_TRACE')) {
          debugPrint(
            'HANEOKA_NATIVE_VIEWPORT request=$request fullscreen=${presentation?.fullscreen} '
            'epoch=${presentation?.epoch} measured=$viewport applied=$applied',
          );
        }
        if (player.document?.key == document.key &&
            (player.session != null || player.loading)) {
          await player.resize(viewport.$1, viewport.$2, viewport.$3);
        } else {
          await player.open(
            document,
            width: viewport.$1,
            height: viewport.$2,
            pixelRatio: viewport.$3,
          );
        }
      });
      if (mounted &&
          request == _viewportRequest &&
          presentation?.isCurrent() != false &&
          (player.logicalWidth != viewport.$1 ||
              player.logicalHeight != viewport.$2 ||
              player.pixelWidth != (viewport.$1 * viewport.$3).round() ||
              player.pixelHeight != (viewport.$2 * viewport.$3).round())) {
        setState(() => _viewport = null);
      }
    });
  }

  @override
  void dispose() {
    _clearFrameDebt();
    _rendering?.removeListener(_renderQualityChanged);
    ++_load;
    ++_viewportRequest;
    _ticker.dispose();
    _overviewFuture = null;
    _overviewSource?.dispose();
    _player?.audio.removeListener(_changed);
    _player?.removeListener(_changed);
    _player?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DisplayFrameRateScope(
    targetHz: _watchMode ? 60 : null,
    child: PlayerOrientationScope(
      landscape: _watchMode,
      child: _buildPlayer(context),
    ),
  );

  Widget _watchStage(NativeChartPlayback player, {required bool ready}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final t = AppScope.of(context).text;
          final doc = _document, error = _error ?? player.error;
          if (error != null) return _failed(_retry);
          if (doc == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final viewport = (
            constraints.maxWidth,
            constraints.maxHeight,
            renderPixelRatio(context),
          );
          _queueViewport(
            player,
            doc,
            viewport,
            PlaybackStageScope.maybeOf(context),
          );
          final session = player.session;
          if (session == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final pauseHit = player.pauseHitBounds(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          return Stack(
            children: [
              Positioned.fill(
                child: ValueListenableBuilder<ui.Image?>(
                  valueListenable: session.image,
                  builder: (_, image, _) =>
                      RawImage(image: image, fit: BoxFit.contain),
                ),
              ),
              if (pauseHit != null)
                Positioned(
                  left: pauseHit.left,
                  top: pauseHit.top,
                  width: pauseHit.width,
                  height: pauseHit.height,
                  child: Tooltip(
                    message: t('common.actions.pause', 'Pause'),
                    child: Semantics(
                      button: true,
                      label: t('common.actions.pause', 'Pause'),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: !ready
                            ? null
                            : () {
                                _action(player.pause);
                                PlaybackStageScope.maybeOf(context)
                                    ?.setControlsExpanded
                                    ?.call(true);
                              },
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              if (player.audio.sourcePreparing)
                Positioned.fill(
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: PlayerPreparationIndicator(
                      label: t('common.states.loading', 'Loading'),
                    ),
                  ),
                ),
            ],
          );
        },
      );

  Widget _buildPlayer(BuildContext context) {
    final state = AppScope.of(context), t = state.text, player = _player;
    final title =
        _document?.title ??
        (widget.song == null
            ? ''
            : state.songTitle(widget.song!['musicTitle']));
    final playingThisChart = player?.presentationPlaying == true;
    final ready =
        _document != null &&
        player?.session != null &&
        player?.loading == false &&
        player?.audio.sourcePreparing == false;
    return ShellPage(
      title: title.isEmpty ? t('navigation.chart', 'Chart') : title,
      actions: [
        BarAction.choice(
          label: t('common.actions.view', 'View'),
          options: [
            BarChoice(
              icon: Symbols.view_week_rounded,
              label: t('common.layout.simple', 'Simple'),
              selected: !_watchMode,
              onSelected: () => _setMode(false),
            ),
            BarChoice(
              icon: Symbols.play_circle_rounded,
              label: t('common.actions.watch', 'Watch'),
              selected: _watchMode,
              onSelected: () => _setMode(true),
            ),
          ],
        ),
      ],
      body: player == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _failed(_retry)
          : !_watchMode
          ? _overview()
          : ListenableBuilder(
              listenable: player.audio.duration,
              builder: (context, stage) => PlaybackPane(
                key: _paneKey,
                playing: playingThisChart,
                busy: player.audio.sourcePreparing,
                position: player.audio.position.value.inMicroseconds / 1000000,
                mediaPosition: player.audio.position,
                maximum: player.durationSeconds,
                onToggle: !ready
                    ? null
                    : () => _action(
                        playingThisChart ? player.pause : player.play,
                      ),
                onPause: !ready ? null : () => _action(player.pause),
                onScrubStart: () {
                  _resumeAfterScrub = playingThisChart;
                  _action(player.pause);
                },
                onPreviewSeek: (value) => _action(
                  () => player.seek(
                    Duration(microseconds: (value * 1000000).round()),
                  ),
                ),
                onSeek: (value) => _action(() async {
                  await player.seek(
                    Duration(microseconds: (value * 1000000).round()),
                  );
                  if (_resumeAfterScrub) {
                    _resumeAfterScrub = false;
                    await player.play();
                  }
                }),
                onSettings: _settings,
                onLoop: () => player.setLoop(!player.audio.loop),
                loop: player.audio.loop,
                stage: (_) => stage!,
              ),
              child: _watchStage(player, ready: ready),
            ),
    );
  }
}
