import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_state.dart';

class PlaybackStageScope extends InheritedWidget {
  const PlaybackStageScope({
    super.key,
    required this.fullscreen,
    required this.epoch,
    required this.isCurrent,
    this.toggleFullscreen,
    this.setControlsExpanded,
    required super.child,
  });
  final bool fullscreen;
  final int epoch;
  final bool Function() isCurrent;
  final VoidCallback? toggleFullscreen;
  final ValueChanged<bool>? setControlsExpanded;
  static PlaybackStageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlaybackStageScope>();
  @override
  bool updateShouldNotify(PlaybackStageScope old) =>
      old.fullscreen != fullscreen || old.epoch != epoch;
}

/// Shared page transport. Its caller owns rendering and audio; fullscreen
/// moves the same presentation into an overlay without creating a new player.
class PlaybackPane extends StatefulWidget {
  const PlaybackPane({
    super.key,
    required this.stage,
    required this.playing,
    required this.position,
    this.mediaPosition,
    required this.maximum,
    required this.onToggle,
    this.onSeek,
    this.onPreviewSeek,
    this.onScrubStart,
    this.onSettings,
    this.onLoop,
    this.loop = false,
    this.collapsed = false,
    this.onCollapsed,
    this.positionLabel,
    this.maximumLabel,
    this.onStageActivate,
    this.onPause,
    this.leadLabel,
    this.leadActive,
    this.leadReplay = false,
    this.controlsVisible = true,
    this.busy = false,
  });
  final WidgetBuilder stage;
  final bool playing, loop, collapsed;
  final bool? leadActive;
  final bool leadReplay, controlsVisible;
  final bool busy;
  final String? leadLabel;
  final double position, maximum;

  /// Optional media clock for the progress controls. Ordinal-based players
  /// continue to supply [position] without rebuilding the presentation per PTS.
  final ValueListenable<Duration>? mediaPosition;
  final String? positionLabel, maximumLabel;
  final VoidCallback? onToggle,
      onScrubStart,
      onSettings,
      onLoop,
      onStageActivate,
      onPause;
  final ValueChanged<double>? onSeek, onPreviewSeek;
  final ValueChanged<bool>? onCollapsed;
  @override
  State<PlaybackPane> createState() => _PlaybackPaneState();
}

/// Back (the Android button or gesture) leaves fullscreen instead of the page.
class _FullscreenPopEntry extends PopEntry<Object?> {
  _FullscreenPopEntry(this.exit);
  final VoidCallback exit;
  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(false);
  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) exit();
  }
}

class _PlaybackPaneState extends State<PlaybackPane> {
  OverlayEntry? _overlay;
  _FullscreenPopEntry? _popEntry;
  ModalRoute<Object?>? _popRoute;
  bool _collapsed = false, _hidden = false, _busy = false;
  double? _scrub;
  Timer? _hide;
  bool _previousFullscreen = false;
  bool _disposing = false;
  int _presentationEpoch = 0;
  bool _overlayBuildScheduled = false;
  bool _pointerInsideControls = false,
      _controlsHaveFocus = false,
      _keyboardFocusWithin = false,
      _pointerActivation = false;
  bool get _uiAlive => mounted && !_disposing;
  bool get _desktop =>
      !kIsWeb &&
      const {
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);
  bool get _mobile =>
      !kIsWeb &&
      const {
        TargetPlatform.android,
        TargetPlatform.iOS,
      }.contains(defaultTargetPlatform);
  @override
  void initState() {
    super.initState();
    _collapsed = widget.collapsed;
    FocusManager.instance.addEarlyKeyEventHandler(_controlsKeyEvent);
  }

  @override
  void didUpdateWidget(PlaybackPane old) {
    super.didUpdateWidget(old);
    if (old.collapsed != widget.collapsed) {
      _collapsed = widget.collapsed;
      if (_collapsed) _clearControlsInteraction();
    }
    _queueOverlayBuild();
    if (old.playing != widget.playing ||
        old.collapsed != widget.collapsed ||
        old.controlsVisible != widget.controlsVisible ||
        old.busy != widget.busy) {
      _scheduleHide();
    }
  }

  void _changed() {
    if (!_uiAlive) return;
    setState(() {});
    _queueOverlayBuild();
  }

  void _queueOverlayBuild() {
    if (!_uiAlive || _overlay == null || _overlayBuildScheduled) return;
    _overlayBuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayBuildScheduled = false;
      if (_uiAlive) _overlay?.markNeedsBuild();
    });
  }

  void _showControls() {
    if (!_uiAlive) return;
    _hidden = false;
    _scheduleHide();
    _changed();
  }

  void _scheduleHide() {
    _hide?.cancel();
    if (_canAutoHide) {
      _hide = Timer(const Duration(seconds: 4), () {
        if (_uiAlive && _canAutoHide) {
          _hidden = true;
          _clearControlsInteraction();
          _changed();
        }
      });
    } else {
      _hidden = false;
    }
  }

  bool get _canAutoHide =>
      _overlay != null &&
      widget.playing &&
      widget.controlsVisible &&
      !widget.busy &&
      _scrub == null &&
      !_pointerInsideControls &&
      !_keyboardFocusWithin &&
      !_pointerActivation;

  void _clearControlsInteraction() {
    _pointerInsideControls = false;
    _controlsHaveFocus = false;
    _keyboardFocusWithin = false;
    _pointerActivation = false;
  }

  KeyEventResult _controlsKeyEvent(KeyEvent event) {
    if (_uiAlive &&
        _controlsHaveFocus &&
        widget.controlsVisible &&
        !_collapsed &&
        !_hidden) {
      _keyboardFocusWithin = true;
      _showControls();
    }
    return KeyEventResult.ignored;
  }

  Widget _controlsInteraction({
    required bool fullscreen,
    required Widget child,
  }) {
    final epoch = _presentationEpoch;
    bool current() =>
        _uiAlive &&
        epoch == _presentationEpoch &&
        fullscreen == (_overlay != null);
    void releasePointer() {
      Future<void>.delayed(Duration.zero, () {
        if (!current()) return;
        _pointerActivation = false;
        _scheduleHide();
      });
    }

    return MouseRegion(
      onEnter: (event) {
        if (!current() || event.kind == PointerDeviceKind.touch) return;
        _pointerInsideControls = true;
        if (!_collapsed && !_hidden) _showControls();
      },
      onExit: (event) {
        if (!current() || event.kind == PointerDeviceKind.touch) return;
        _pointerInsideControls = false;
        _scheduleHide();
      },
      child: Listener(
        onPointerDown: (_) {
          if (!current()) return;
          _pointerActivation = true;
          _keyboardFocusWithin = false;
          _showControls();
        },
        onPointerUp: (_) => releasePointer(),
        onPointerCancel: (_) => releasePointer(),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (focused) {
            if (!current()) return;
            _controlsHaveFocus = focused;
            _keyboardFocusWithin = focused && !_pointerActivation;
            if (focused) {
              _showControls();
            } else {
              _scheduleHide();
            }
          },
          child: child,
        ),
      ),
    );
  }

  Future<void> _fullscreen() async {
    if (_busy || !_uiAlive) return;
    _busy = true;
    try {
      if (_overlay != null) {
        await _exitFullscreen();
        return;
      }
      if (_desktop) {
        await windowManager.ensureInitialized();
        if (!_uiAlive) return;
        _previousFullscreen = await windowManager.isFullScreen();
        if (!_uiAlive) return;
        await windowManager.setFullScreen(true);
      } else if (_mobile) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
      if (!mounted || _disposing) {
        await _exitFullscreen();
        return;
      }
      _clearControlsInteraction();
      ++_presentationEpoch;
      _overlay = OverlayEntry(
        builder: (context) => Material(
          color: Colors.black,
          child: _presentation(context, fullscreen: true),
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(_overlay!);
      _popRoute = ModalRoute.of(context);
      _popRoute?.registerPopEntry(
        _popEntry = _FullscreenPopEntry(() {
          if (_overlay != null) unawaited(_exitFullscreen());
        }),
      );
      _showControls();
    } finally {
      _busy = false;
    }
  }

  Future<void> _exitFullscreen() async {
    _hide?.cancel();
    final overlay = _overlay;
    _overlay = null;
    if (_popEntry case final entry?) {
      _popRoute?.unregisterPopEntry(entry);
      entry.canPopNotifier.dispose();
    }
    _popEntry = null;
    _popRoute = null;
    _clearControlsInteraction();
    ++_presentationEpoch;
    overlay?.remove();
    overlay?.dispose();
    _hidden = false;
    if (_uiAlive) setState(() {});
    if (_desktop) {
      await windowManager.setFullScreen(_previousFullscreen);
    } else if (_mobile) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    FocusManager.instance.removeEarlyKeyEventHandler(_controlsKeyEvent);
    _hide?.cancel();
    if (_overlay != null) unawaited(_exitFullscreen());
    super.dispose();
  }

  String _clock(double seconds) {
    final value = seconds.isFinite ? seconds.round().clamp(0, 8640000) : 0;
    return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
  }

  Widget _button(
    IconData icon,
    String label,
    VoidCallback? callback, {
    bool? selected,
  }) => IconButton(
    tooltip: label,
    isSelected: selected,
    onPressed: widget.busy ? null : callback,
    icon: Icon(icon, size: 20),
  );

  Widget _progress(BuildContext context, double position) {
    final value = (_scrub ?? position).clamp(
      0.0,
      widget.maximum > 0 ? widget.maximum : 1.0,
    );
    return Row(
      children: [
        Text(
          widget.positionLabel ?? _clock(value),
          style: Theme.of(context).textTheme.labelSmall,
        ),
        Expanded(
          child: Slider(
            value: value,
            max: widget.maximum > 0 ? widget.maximum : 1,
            semanticFormatterCallback: (v) =>
                widget.positionLabel == null ? _clock(v) : '${v.round()}',
            onChangeStart: widget.busy || widget.onSeek == null
                ? null
                : (v) {
                    _hide?.cancel();
                    _scrub = v;
                    widget.onScrubStart?.call();
                    _changed();
                  },
            onChanged: widget.busy || widget.onSeek == null
                ? null
                : (v) {
                    _scrub = v;
                    widget.onPreviewSeek?.call(v);
                    _changed();
                  },
            onChangeEnd: widget.busy || widget.onSeek == null
                ? null
                : (v) {
                    _scrub = null;
                    widget.onSeek?.call(v);
                    _showControls();
                  },
          ),
        ),
        Text(
          widget.maximumLabel ?? _clock(widget.maximum),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }

  Widget _controls(BuildContext context, bool fullscreen) {
    final t = AppScope.of(context).text;
    // Fullscreen keeps its controls (and the way out) whatever the pane's
    // collapsed preference; they only hide while playing and return on a tap.
    if ((_collapsed && !fullscreen) || _hidden) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return _controlsInteraction(
      fullscreen: fullscreen,
      child: Material(
        color: fullscreen
            ? scheme.surfaceContainer.withValues(alpha: .94)
            : scheme.surfaceContainer,
        child: SafeArea(
          top: false,
          left: false,
          right: false,
          minimum: EdgeInsets.only(
            bottom: MediaQuery.systemGestureInsetsOf(context).bottom,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 500;
                final extras = <Widget>[
                  if (widget.onSettings != null)
                    _button(
                      Symbols.tune_rounded,
                      t('media.chartPlayer.settings', 'Settings'),
                      widget.onSettings,
                    ),
                  if (widget.onLoop != null)
                    _button(
                      Symbols.refresh_rounded,
                      t('media.chartPlayer.loop', 'Loop'),
                      widget.onLoop,
                      selected: widget.loop,
                    ),
                  _button(
                    fullscreen
                        ? Symbols.fullscreen_exit_rounded
                        : Symbols.fullscreen_rounded,
                    t(
                      fullscreen
                          ? 'common.actions.fullscreenExit'
                          : 'common.actions.fullscreen',
                      'Fullscreen',
                    ),
                    () => unawaited(_fullscreen()),
                    selected: fullscreen,
                  ),
                  if (!fullscreen)
                    _button(
                      Symbols.expand_more_rounded,
                      t('common.actions.collapse', 'Collapse'),
                      () {
                        _collapsed = true;
                        _clearControlsInteraction();
                        _hide?.cancel();
                        _hidden = false;
                        widget.onCollapsed?.call(true);
                        _changed();
                      },
                    ),
                ];
                return AbsorbPointer(
                  absorbing: widget.busy,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          _button(
                            widget.leadReplay
                                ? Symbols.replay_rounded
                                : (widget.leadActive ?? widget.playing)
                                ? Symbols.pause_rounded
                                : Symbols.play_arrow_rounded,
                            widget.leadLabel ??
                                t(
                                  widget.playing
                                      ? 'common.actions.pause'
                                      : 'common.actions.play',
                                  'Play',
                                ),
                            widget.onToggle,
                            selected: widget.leadActive,
                          ),
                          Expanded(
                            child:
                                widget.mediaPosition != null &&
                                    widget.controlsVisible
                                ? ValueListenableBuilder<Duration>(
                                    valueListenable: widget.mediaPosition!,
                                    builder: (context, position, _) =>
                                        _progress(
                                          context,
                                          position.inMicroseconds / 1000000,
                                        ),
                                  )
                                : _progress(context, widget.position),
                          ),
                          if (!compact) ...extras,
                        ],
                      ),
                      if (compact)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: extras,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _presentation(BuildContext context, {required bool fullscreen}) {
    final epoch = _presentationEpoch;
    final stage = PlaybackStageScope(
      fullscreen: fullscreen,
      epoch: epoch,
      isCurrent: () =>
          _uiAlive &&
          epoch == _presentationEpoch &&
          fullscreen == (_overlay != null),
      toggleFullscreen: () => unawaited(_fullscreen()),
      setControlsExpanded: (expanded) {
        _collapsed = !expanded;
        widget.onCollapsed?.call(!expanded);
        _showControls();
      },
      child: Builder(
        builder: (context) => FocusableActionDetector(
          autofocus: true,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                if (widget.busy) return null;
                if (widget.onStageActivate != null) {
                  widget.onStageActivate!();
                } else if (widget.playing && widget.onPause != null) {
                  widget.onPause!();
                  _collapsed = false;
                  widget.onCollapsed?.call(false);
                  _showControls();
                } else {
                  widget.onToggle?.call();
                }
                return null;
              },
            ),
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                if (_overlay != null) unawaited(_exitFullscreen());
                return null;
              },
            ),
          },
          child: widget.stage(context),
        ),
      ),
    );
    final presentation = fullscreen
        ? Listener(
            onPointerDown: (_) {
              if (_hidden) _showControls();
            },
            child: Stack(
              children: [
                Positioned.fill(child: stage),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Visibility(
                    visible: widget.controlsVisible,
                    maintainSize: true,
                    maintainState: true,
                    maintainAnimation: true,
                    child: _controls(context, true),
                  ),
                ),
              ],
            ),
          )
        : Column(
            children: [
              Expanded(child: stage),
              Visibility(
                visible: widget.controlsVisible,
                maintainSize: true,
                maintainState: true,
                maintainAnimation: true,
                child: _controls(context, false),
              ),
            ],
          );
    return presentation;
  }

  @override
  Widget build(BuildContext context) => _overlay == null
      ? _presentation(context, fullscreen: false)
      : const SizedBox.expand();
}
