import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/account_resource.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../core/catalog_source.dart';
import '../core/media_lifecycle.dart';
import '../shell/page.dart';
import '../ui/detail.dart';
import 'live2d_runtime.dart';
import 'model_view.dart';
import '../rendering/render_budget.dart';

class NativeLive2DViewer extends StatefulWidget {
  const NativeLive2DViewer({super.key, required this.id, required this.title});
  final String id, title;
  @override
  State<NativeLive2DViewer> createState() => _NativeLive2DViewerState();
}

class _NativeLive2DViewerState extends State<NativeLive2DViewer>
    with SingleTickerProviderStateMixin {
  final _captureKey = GlobalKey();
  final _transform = ModelViewTransform();
  final _poses = <String, Map<String, Object?>>{};
  String _pose = '', _parameterMode = 'none', _parameterQuery = '';
  bool _parametersExpanded = false, _partsExpanded = false;
  bool _posePreview = false;
  HaneokaApi? _api;
  NativeLive2DModel? _model;
  Object? _error;
  int _epoch = 0;
  Duration? _last;
  bool _fullscreen = false,
      _busy = false,
      _closed = false,
      _drag = true,
      _sway = false;
  double _lookX = 0, _lookY = 0;
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
    final model = _model;
    if (_posePreview &&
        model != null &&
        (model.duration <= 0 || model.position.value >= model.duration)) {
      _posePreview = false;
      model.applyPose(model.pose());
      _syncTicker();
      setState(() => _parameterMode = 'pose');
    }
  });
  String get _poseKey => 'live2d.poses.${_api!.server}.${widget.id}';
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
    _syncTicker();
  }

  void _syncTicker() {
    final active =
        !_closed &&
        TickerMode.valuesOf(context).enabled &&
        (_model?.playing ?? false) &&
        !(_model?.manual ?? true);
    if (active && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
    if (!active && _ticker.isActive) _ticker.stop();
  }

  void _reload() {
    final epoch = ++_epoch;
    _posePreview = false;
    _parameterMode = 'none';
    _ticker.stop();
    final previous = _model;
    _model = null;
    _error = null;
    _poses.clear();
    _pose = '';
    _loading = () async {
      await previous?.close();
      try {
        final model = await NativeLive2DModel.load(
          _api!,
          widget.id,
          () => mounted && epoch == _epoch && !_closed,
        );
        if (!mounted || epoch != _epoch || _closed) {
          await model.close();
          return;
        }
        final preferences = await SharedPreferences.getInstance();
        try {
          final poses =
              jsonDecode(preferences.getString(_poseKey) ?? '{}') as Map;
          for (final entry in poses.entries) {
            _poses['${entry.key}'] = (entry.value as Map)
                .cast<String, Object?>();
          }
        } catch (_) {
          _poses.clear();
        }
        if (!mounted || epoch != _epoch || _closed) {
          await model.close();
          return;
        }
        setState(() {
          _model = model;
          _error = null;
        });
        _syncTicker();
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
    await _model?.close();
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

  Future<void> _action(
    Future<void> Function() action, {
    String? errorKey,
  }) async {
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
                  .text(errorKey ?? 'common.states.unavailable'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle() {
    setState(() => _model!.playing = !_model!.playing);
    _syncTicker();
  }

  void _mode(String mode) {
    final model = _model!;
    setState(() {
      _posePreview = false;
      _parameterMode = mode;
      if (mode == 'pose') {
        _ticker.stop();
        model.loop = false;
        model.applyPose(model.pose());
      } else {
        model.manual = false;
        model.locked.clear();
      }
    });
    _syncTicker();
  }

  Future<void> _writePoses() async {
    final preferences = await SharedPreferences.getInstance();
    if (_poses.isEmpty) {
      await preferences.remove(_poseKey);
    } else {
      await preferences.setString(_poseKey, jsonEncode(_poses));
    }
  }

  Future<void> _savePose() async {
    final t = AppScope.of(context).text;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final pose = _model!.pose()
      ..['name'] = '${t('media.models.labels.pose')} ${_poses.length + 1}';
    setState(() {
      _pose = id;
      _poses[id] = pose;
    });
    await _writePoses();
  }

  void _applyPose(String id) {
    _ticker.stop();
    setState(() {
      _pose = id;
      _parameterMode = 'pose';
      if (id.isEmpty) {
        final model = _model!;
        model.applyPose({
          'parameters': {
            for (final entry in model.host.model.parameters.entries)
              entry.key: model.host.parameters.defaults[entry.value],
          },
          'parts': model.initialParts,
        });
      } else {
        _model!.applyPose(_poses[id]!);
      }
    });
  }

  Future<void> _renamePose() async {
    final t = AppScope.of(context).text, pose = _poses[_pose]!;
    final controller = TextEditingController(text: '${pose['name']}');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('common.actions.rename', 'Rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          decoration: InputDecoration(
            labelText: t('media.models.labels.pose', 'Name'),
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('common.actions.cancel', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(t('community.page.save', 'Save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.isEmpty || _poses[_pose] != pose) {
      return;
    }
    setState(() => pose['name'] = name);
    await _writePoses();
  }

  Future<void> _importPose() async {
    final model = _model!;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null || !mounted || !identical(model, _model)) return;
    if ((await file.length() ?? 0) > 1024 * 1024) {
      throw const FormatException('invalidParameterPose');
    }
    final bytes = await file.readAsBytes();
    final document = jsonDecode(utf8.decode(bytes)) as Map;
    if (!mounted || !identical(model, _model)) return;
    model.applyPose(document);
    _ticker.stop();
    setState(() {
      _parameterMode = 'pose';
      _pose = '';
    });
  }

  Future<void> _capture() async {
    final model = _model!, viewport = _transform.viewport;
    final resume = _ticker.isActive,
        ratio = MediaQuery.devicePixelRatioOf(context);
    _ticker.stop();
    try {
      model.configure(viewport, modelCaptureRatio(viewport));
      await model.render();
      if (!mounted || !identical(_model, model)) return;
      final bytes = await captureModelPng(_captureKey);
      if (mounted && identical(_model, model)) {
        await saveModelFile('${widget.id}.png', bytes);
      }
    } finally {
      if (mounted && identical(_model, model)) {
        model.configure(viewport, ratio);
        await model.render();
        if (mounted && resume) _syncTicker();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text, model = _model;
    String label(String key) => t('media.models.labels.$key');
    return ShellPage(
      title: [
        model?.detail['title'],
        model?.detail['live2dName'],
        model?.detail['characterName'],
        widget.title,
      ].map(t.text).where((value) => value.isNotEmpty).first,
      search: _parametersExpanded
          ? ShellSearch(
              label: t('common.actions.search'),
              initial: _parameterQuery,
              onChanged: (value) =>
                  setState(() => _parameterQuery = value.toLowerCase()),
            )
          : null,
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
          label: label('screenshot'),
          onPressed: model == null || _busy ? null : () => _action(_capture),
        ),
        BarAction(
          icon: Symbols.download_rounded,
          label: label('downloadModel'),
          onPressed: model == null || _busy
              ? null
              : () => _action(() async {
                  final bytes = await model.package();
                  if (mounted && identical(model, _model)) {
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
                      label: Text(t('common.actions.retry')),
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
                        drag: _drag,
                        painter: NativeLive2DPainter(model, _background),
                        onViewport: (size) =>
                            model.configure(size, renderPixelRatio(context)),
                        onLook: _sway
                            ? (point) => model.look(point, sway: true)
                            : null,
                        onLookEnd: () => model.look(Offset(_lookX, _lookY)),
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
                          tooltip: t('common.actions.reset'),
                          icon: const Icon(Symbols.replay_rounded),
                        ),
                        Expanded(
                          child: ValueListenableBuilder<double>(
                            valueListenable: model.position,
                            builder: (context, value, _) => Slider(
                              value: value.clamp(0, model.duration),
                              max: model.duration > 0 ? model.duration : 1,
                              onChanged: model.seek,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
                Widget toggle(
                  String key,
                  bool value,
                  ValueChanged<bool> update,
                ) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    key == 'loop' ? t('common.actions.loop') : label(key),
                  ),
                  value: value,
                  onChanged: (value) => setState(() => update(value)),
                );
                Widget select(
                  String title,
                  String selected,
                  List<String> values,
                  ValueChanged<String> update,
                ) => DetailSection(
                  title: title,
                  icon: Symbols.animation_rounded,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey((title, selected)),
                    isExpanded: true,
                    initialValue: values.contains(selected) ? selected : null,
                    items: [
                      for (final value in values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => update(value));
                    },
                  ),
                );
                final controls = Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DetailSection(
                        title: t('navigation.settings'),
                        icon: Symbols.tune_rounded,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            toggle('loop', model.loop, (value) {
                              model.loop = value;
                              model.playMotion(model.motion);
                            }),
                            toggle('breath', model.breath, model.setBreath),
                            toggle('blink', model.blink, model.setBlink),
                            toggle('sway', _sway, (value) {
                              _sway = value;
                              if (!value) model.look(Offset(_lookX, _lookY));
                            }),
                            toggle('drag', _drag, (value) => _drag = value),
                            ModelBackgroundSetting(
                              color: _background,
                              onChanged: (color) =>
                                  setState(() => _background = color),
                            ),
                            Text(t('media.playback.fields.speed')),
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
                      if (model.motions.isNotEmpty)
                        select(label('motion'), model.motion, model.motions, (
                          name,
                        ) {
                          _posePreview = _parameterMode == 'pose';
                          model.playing = true;
                          model.playMotion(name, oneShot: _posePreview);
                          _syncTicker();
                        }),
                      if (model.expressions.isNotEmpty)
                        select(
                          label('expression'),
                          model.expression,
                          model.expressions,
                          model.playExpression,
                        ),
                      DetailSection(
                        title: label('pose'),
                        icon: Symbols.face_rounded,
                        child: Column(
                          children: [
                            Text(label('lookX')),
                            Slider(
                              value: _lookX,
                              min: -1,
                              max: 1,
                              onChanged: (value) => setState(() {
                                _lookX = value;
                                model.look(Offset(_lookX, _lookY));
                              }),
                            ),
                            Text(label('lookY')),
                            Slider(
                              value: _lookY,
                              min: -1,
                              max: 1,
                              onChanged: (value) => setState(() {
                                _lookY = value;
                                model.look(Offset(_lookX, _lookY));
                              }),
                            ),
                          ],
                        ),
                      ),
                      ModelTransformSettings(transform: _transform),
                      DetailFold(
                        title: label('parameters'),
                        open: _parametersExpanded,
                        onExpansionChanged: (value) =>
                            setState(() => _parametersExpanded = value),
                        meta: '${model.host.model.parameters.length}',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SegmentedButton<String>(
                              segments: [
                                ButtonSegment(
                                  value: 'none',
                                  label: Text(t('common.states.none')),
                                ),
                                ButtonSegment(
                                  value: 'capture',
                                  label: Text(t('common.actions.capture')),
                                ),
                                ButtonSegment(
                                  value: 'pose',
                                  label: Text(label('pose')),
                                ),
                              ],
                              selected: {_parameterMode},
                              onSelectionChanged: (value) =>
                                  _mode(value.single),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _action(
                                          _importPose,
                                          errorKey: 'media.models.labels.invalidParameterPose',
                                        ),
                                  child: Text(label('importPose')),
                                ),
                                OutlinedButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _action(
                                          () async => saveModelFile(
                                            '${widget.id}.pose.json',
                                            utf8.encode(
                                              jsonEncode({
                                                ...model.pose(),
                                                'mode': 'pose',
                                              }),
                                            ),
                                          ),
                                        ),
                                  child: Text(label('exportPose')),
                                ),
                                TextButton(
                                  onPressed: () => setState(() {
                                    model.resetPose();
                                    _parameterMode = 'none';
                                    _pose = '';
                                  }),
                                  child: Text(t('common.actions.reset')),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                              key: ValueKey(('pose', _pose, _poses.length)),
                              initialValue: _pose,
                              decoration: InputDecoration(
                                labelText: label('customPoses'),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: '',
                                  child: Text(label('defaultPose')),
                                ),
                                for (final entry in _poses.entries)
                                  DropdownMenuItem(
                                    value: entry.key,
                                    child: Text('${entry.value['name']}'),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value != null) _applyPose(value);
                              },
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _action(_savePose),
                                  child: Text(t('common.actions.savePose')),
                                ),
                                TextButton(
                                  onPressed: _pose.isEmpty || _busy
                                      ? null
                                      : () => _action(_renamePose),
                                  child: Text(t('common.actions.rename')),
                                ),
                                TextButton(
                                  onPressed: _pose.isEmpty || _busy
                                      ? null
                                      : () => _action(() async {
                                          setState(() {
                                            _poses.remove(_pose);
                                            _pose = '';
                                          });
                                          await _writePoses();
                                        }),
                                  child: Text(t('community.page.delete')),
                                ),
                              ],
                            ),
                            if (_parametersExpanded)
                              ValueListenableBuilder<Map<String, double>>(
                                valueListenable: model.parameters,
                                builder: (context, values, _) => Column(
                                  children: [
                                    for (final entry
                                        in model.host.model.parameters.entries)
                                      if (entry.key.toLowerCase().contains(
                                        _parameterQuery,
                                      ))
                                        _parameter(
                                          model,
                                          entry.key,
                                          entry.value,
                                          values,
                                        ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      DetailFold(
                        title: label('partsVisibility'),
                        open: _partsExpanded,
                        onExpansionChanged: (value) =>
                            setState(() => _partsExpanded = value),
                        meta: '${model.host.model.parts.length}',
                        child: Column(
                          children: [
                            if (_partsExpanded)
                              for (final entry
                                  in model.host.model.parts.entries)
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(entry.key),
                                  value:
                                      (model.parts[entry.key] ??
                                          model.host.parameters.parts[entry
                                              .value]) >
                                      .5,
                                  onChanged: (value) => setState(
                                    () =>
                                        model.setPart(entry.key, value ? 1 : 0),
                                  ),
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
                    children: [
                      Expanded(child: stage),
                      SizedBox(
                        width: 380,
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

  Widget _parameter(
    NativeLive2DModel model,
    String id,
    int index,
    Map<String, double> values,
  ) {
    final t = AppScope.of(context).text;
    final minimum = model.host.parameters.minimum[index],
        maximum = model.host.parameters.maximum[index];
    final value =
        model.locked[id] ?? values[id] ?? model.host.parameters.values[index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(id, overflow: TextOverflow.ellipsis)),
            Text(value.toStringAsFixed(2)),
            IconButton(
              tooltip: t('common.actions.reset'),
              icon: const Icon(Symbols.restart_alt_rounded),
              onPressed: _parameterMode != 'pose'
                  ? null
                  : () => setState(() {
                      model.setParameter(
                        id,
                        model.host.parameters.defaults[index],
                      );
                    }),
            ),
          ],
        ),
        Slider(
          value: value.clamp(minimum, maximum),
          min: minimum,
          max: maximum,
          onChanged: minimum == maximum || _parameterMode != 'pose'
              ? null
              : (value) => setState(() => model.setParameter(id, value)),
        ),
      ],
    );
  }
}
