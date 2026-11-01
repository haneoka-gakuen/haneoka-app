import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/account_resource.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../core/catalog_source.dart';
import '../core/media_lifecycle.dart';
import '../shell/page.dart';
import '../ui/detail.dart';
import 'model_view.dart';
import 'spine_runtime.dart';
import '../rendering/render_budget.dart';

class NativeSpineViewer extends StatefulWidget {
  const NativeSpineViewer({super.key, required this.id, required this.title});
  final String id, title;
  @override
  State<NativeSpineViewer> createState() => _NativeSpineViewerState();
}

class _NativeSpineViewerState extends State<NativeSpineViewer>
    with SingleTickerProviderStateMixin {
  final _captureKey = GlobalKey();
  final _transform = ModelViewTransform();
  HaneokaApi? _api;
  NativeSpineModel? _model;
  Map? _detail;
  Object? _error;
  int _epoch = 0;
  Duration? _last;
  bool _fullscreen = false, _busy = false, _closed = false;
  Color? _background;
  StreamSubscription<void>? _accountChanges;
  Future<void>? _loading;
  final _throttle = FrameThrottle();
  late final Ticker _ticker = createTicker((time) {
    if (!_throttle.admit(time)) return;
    final delta = _last == null
        ? 0.0
        : (time - _last!).inMicroseconds / 1000000;
    _last = time;
    _model?.advance(delta.clamp(0, .1));
  });

  @override
  void initState() {
    super.initState();
    MediaLifecycle.register(this, _close);
    _accountChanges = AccountResources.instance.changes.listen((_) {
      if (_api?.server case final server?
          when server != 'jp' && server != 'intl') {
        _reload();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final api = CatalogSourceScope.apiOf(context);
    if (!identical(api, _api)) {
      _api = api;
      _reload();
    }
    final ticking =
        TickerMode.valuesOf(context).enabled && (_model?.playing ?? false);
    if (ticking && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
    if (!ticking && _ticker.isActive) _ticker.stop();
  }

  void _reload() {
    final epoch = ++_epoch;
    _ticker.stop();
    _model?.dispose();
    _model = null;
    _detail = null;
    _error = null;
    _loading = () async {
      try {
        final detail = await _api!.catalog('spine', widget.id) as Map;
        if (!mounted || epoch != _epoch || _closed) return;
        final model = await NativeSpineModel.load(
          _api!,
          detail,
          current: () => mounted && epoch == _epoch && !_closed,
        );
        if (!mounted || epoch != _epoch || _closed) {
          model.dispose();
          return;
        }
        setState(() {
          _model = model;
          _detail = detail;
          _error = null;
        });
        _last = null;
        _ticker.start();
      } catch (error) {
        if (mounted && epoch == _epoch && !_closed) {
          setState(() => _error = error);
        }
      }
    }();
    if (mounted) setState(() {});
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    ++_epoch;
    _ticker.stop();
    await _accountChanges?.cancel();
    _model?.dispose();
    _model = null;
    await _loading;
    MediaLifecycle.unregister(this);
  }

  @override
  void dispose() {
    unawaited(_close());
    _ticker.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppScope.of(context)
                  .text('common.states.unavailable', 'Unavailable'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle() {
    final model = _model!;
    setState(() => model.playing = !model.playing);
    if (model.playing) {
      _last = null;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text, model = _model;
    return ShellPage(
      title: widget.title,
      status: SizedBox.square(
        dimension: 24,
        child: _busy ? const CircularProgressIndicator(strokeWidth: 2) : null,
      ),
      actions: [
        BarAction(
          icon: _fullscreen
              ? Symbols.fullscreen_exit_rounded
              : Symbols.fullscreen_rounded,
          label: t(
            _fullscreen
                ? 'common.actions.fullscreenExit'
                : 'common.actions.fullscreen',
          ),
          onPressed: () => setState(() => _fullscreen = !_fullscreen),
        ),
        BarAction(
          icon: Symbols.photo_camera_rounded,
          label: t('media.models.labels.screenshot', 'Capture image'),
          onPressed: model == null || _busy
              ? null
              : () => _action(() async {
                  final bytes = await captureModelPng(_captureKey);
                  if (mounted && identical(_model, model)) {
                    await saveModelFile('${widget.id}.png', bytes);
                  }
                }),
        ),
        BarAction(
          icon: Symbols.download_rounded,
          label: t('media.models.labels.downloadModel', 'Download model ZIP'),
          onPressed: model == null || _busy
              ? null
              : () => _action(() async {
                  final bytes = await model.package();
                  if (mounted && identical(_model, model)) {
                    await saveModelFile('${widget.id}.zip', bytes);
                  }
                }),
        ),
      ],
      body: model == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : FilledButton.tonalIcon(
                      onPressed: _reload,
                      icon: const Icon(Symbols.refresh_rounded),
                      label: Text(t('common.actions.retry', 'Retry')),
                    ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final stage = Column(
                  children: [
                    Expanded(
                      child: ModelViewport(
                        captureKey: _captureKey,
                        transform: _transform,
                        painter: NativeSpinePainter(model, _background),
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          onPressed: _toggle,
                          tooltip: t(
                            model.playing
                                ? 'common.actions.pause'
                                : 'common.actions.play',
                          ),
                          icon: Icon(
                            model.playing
                                ? Symbols.pause_rounded
                                : Symbols.play_arrow_rounded,
                          ),
                        ),
                        IconButton(
                          onPressed: () => model.seek(0),
                          tooltip: t('common.actions.reset', 'Reset'),
                          icon: const Icon(Symbols.replay_rounded),
                        ),
                        Expanded(
                          child: ValueListenableBuilder<double>(
                            valueListenable: model.position,
                            builder: (context, time, _) => Slider(
                              value: time.clamp(0, model.duration),
                              max: model.duration > 0 ? model.duration : 1,
                              onChanged: model.seek,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
                final controls = Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DetailSection(
                        title: t('navigation.settings', 'Settings'),
                        icon: Symbols.tune_rounded,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(t('common.actions.loop', 'Loop')),
                              value: model.loop,
                              onChanged: (value) => setState(() {
                                model.loop = value;
                                if (model.animation.isNotEmpty) {
                                  final time = model.position.value;
                                  model.play(model.animation);
                                  model.seek(time);
                                }
                              }),
                            ),
                            ModelBackgroundSetting(
                              color: _background,
                              onChanged: (color) =>
                                  setState(() => _background = color),
                            ),
                            Text(t('media.playback.fields.speed', 'Speed')),
                            Slider(
                              value: model.rate,
                              min: .25,
                              max: 2,
                              divisions: 35,
                              label: '${model.rate.toStringAsFixed(2)}×',
                              onChanged: (value) =>
                                  setState(() => model.rate = value),
                            ),
                          ],
                        ),
                      ),
                      if (model.animations.isNotEmpty)
                        DetailSection(
                          title: t(
                            'media.models.labels.animations',
                            'Animations',
                          ),
                          icon: Symbols.animation_rounded,
                          child: DropdownButtonFormField<String>(
                            initialValue: model.animation,
                            isExpanded: true,
                            items: [
                              for (final name in model.animations)
                                DropdownMenuItem(
                                  value: name,
                                  child: Text(
                                    name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (name) {
                              if (name != null) {
                                setState(() => model.play(name));
                              }
                            },
                          ),
                        ),
                      if (model.skins.isNotEmpty)
                        DetailSection(
                          title: t('media.spine.skins', 'Skins'),
                          icon: Symbols.layers_rounded,
                          child: DropdownButtonFormField<String>(
                            initialValue: model.skin,
                            isExpanded: true,
                            items: [
                              for (final name in model.skins)
                                DropdownMenuItem(
                                  value: name,
                                  child: Text(name),
                                ),
                            ],
                            onChanged: (name) {
                              if (name != null) {
                                setState(() => model.setSkin(name));
                              }
                            },
                          ),
                        ),
                      ModelTransformSettings(transform: _transform),
                      DetailSection(
                        title: t('common.actions.details', 'Details'),
                        icon: Symbols.info_rounded,
                        child: SpecList(
                          facts: [
                            Fact(
                              t('media.models.labels.version', 'Version'),
                              '${_detail?['spineVersion'] ?? ''}',
                            ),
                            Fact(
                              t('media.models.labels.animations', 'Animations'),
                              '${model.animations.length}',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
                if (_fullscreen) return stage;
                if (constraints.maxWidth >= 840) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: stage),
                      SizedBox(
                        width: 360,
                        child: SingleChildScrollView(child: controls),
                      ),
                    ],
                  );
                }
                return ListView(
                  children: [
                    SizedBox(
                      height: (constraints.maxHeight * .65).clamp(320, 640),
                      child: stage,
                    ),
                    controls,
                  ],
                );
              },
            ),
    );
  }
}
