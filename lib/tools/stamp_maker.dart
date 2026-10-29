import 'dart:async';
import 'dart:convert';

import '../core/local_drafts.dart';

import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../community/editor.dart';
import '../community/reactions.dart';
import '../core/app_state.dart';
import '../core/net.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'stamp_render.dart';

class _Stamp {
  const _Stamp(
    this.id,
    this.name,
    this.label,
    this.sources,
    this.characters, {
    this.variants = const {},
  });
  final String id;
  final String name;
  final String label;
  final List<String> sources;
  final List<String> characters;
  final Map<String, String> variants;

  bool supportsLanguage(String language) =>
      variants.isEmpty || variants.containsKey(language);

  _Stamp inLanguage(String language) => _Stamp(
    id,
    name,
    label,
    variants.isEmpty ? sources : [?variants[language]],
    characters,
    variants: variants,
  );
}

/// The fonts the stamp maker offers (`STAMP_FONTS`): the pinned faces,
/// the original runtime UI face, and the interface font.
const _fonts = [
  ('YurukaStd', 'YurukaStd'),
  ('SSFangTangTi', 'SSFangTangTi'),
  ('Pretendard SemiBold', 'fontPretendard'),
  ('Roboto', 'Roboto'),
  ('auto', 'fontAuto'),
];

/// Write a game sticker's text yourself (`stamp-maker`): pick a stamp, add
/// and style text layers, export a PNG or post it to the community.
class StampMakerScreen extends StatefulWidget {
  const StampMakerScreen({super.key});
  @override
  State<StampMakerScreen> createState() => _StampMakerScreenState();
}

class _StampMakerScreenState extends State<StampMakerScreen>
    with WidgetsBindingObserver {
  Future<(List<_Stamp>, List<_Stamp>, List<(String, String, Color, String?)>)>?
  _catalog;
  _Stamp? _stamp;
  ui.Image? _image;
  // Textless first, as on the website; original when none is published.
  bool _textless = true;
  String? _imageLanguage;
  final _layers = <StampLayer>[StampLayer.image(), StampLayer.text()];
  int _selected = 1;
  int _exportSize = 512;
  late final _text = TextEditingController();
  bool _busy = false;
  static bool _pretendardLoaded = false;
  Timer? _draftTimer;
  bool _restoredDraft = false;
  Future<void> _saveDraft() =>
      LocalDrafts.flush('haneoka:stamp-maker:draft:v1')
          .catchError((Object _) {});
  void _scheduleDraft() {
    if (!_restoredDraft) return;
    LocalDrafts.stage(
      'haneoka:stamp-maker:draft:v1',
      jsonEncode({
        'schema': 'haneoka-stamp-draft-v1',
        'stampId': _stamp?.id,
        'textless': _textless,
        'language': _imageLanguage,
        'selected': _selected,
        'exportSize': _exportSize,
        'layers': _layers.map(stampLayerJson).toList(),
      }),
    );
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 300), _saveDraft);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_saveDraft());
  }

  String _t(String key, String fallback) =>
      AppScope.of(context).text('tools.stampMaker.$key', fallback);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _catalog ??= _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftTimer?.cancel();
    unawaited(_saveDraft());
    _image?.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<(List<_Stamp>, List<_Stamp>, List<(String, String, Color, String?)>)>
  _load() async {
    final state = AppScope.of(context);
    final api = state.apiFor('intl');
    final language = switch (state.text.locale) {
      'zh-CN' => 'zh-Hans',
      'zh-TW' => 'zh-Hant',
      final other => other,
    };
    _imageLanguage ??= language;
    final (stamps, characters) = await (
      api.catalog('stamps'),
      api.catalog('characters'),
    ).wait;
    final originals = <_Stamp>[];
    for (final MapEntry(key: id, value: value)
        in ((stamps as Map?) ?? const {}).entries) {
      if (value is! Map) continue;
      final image = '${value['image'] ?? ''}';
      final variants =
          ((value['imageVariants'] as Map?)?[image] as Map?) ?? const {};
      final sources = {
        for (final v in [
          variants[language],
          variants['ja'],
          image,
          ...variants.values,
        ])
          if (v is String && v.startsWith('/assets/')) v,
      };
      if (sources.isEmpty) continue;
      originals.add(
        _Stamp(
          '$id',
          image.split('/').last.replaceFirst(RegExp(r'\.png$'), ''),
          state.text.text(value['name']).isEmpty
              ? image.split('/').last
              : state.text.text(value['name']),
          [for (final s in sources) api.asset(s).toString()],
          [for (final c in value['characterIds'] as List? ?? const []) '$c'],
          variants: {
            for (final MapEntry(key: language, value: path) in variants.entries)
              if (path is String && path.startsWith('/assets/'))
                '$language': api.asset(path).toString(),
          },
        ),
      );
    }
    originals.sort(
      (a, b) => (int.tryParse(a.id) ?? 0).compareTo(int.tryParse(b.id) ?? 0),
    );
    // Textless derivatives that passed review (`textlessChoices`).
    final textless = <_Stamp>[];
    try {
      final manifest =
          await api.json('/runtime/intl/stamp-maker/manifest.json') as Map;
      final entries = <String, String>{};
      for (final record
          in (manifest['records'] as List? ?? const []).whereType<Map>()) {
        if (record['publishable'] != true) continue;
        final artifacts = (record['artifacts'] as Map?) ?? const {};
        final source =
            [
                  (artifacts['sourceImage'] as Map?)?['path'],
                  (artifacts['nativeOriginal'] as Map?)?['path'],
                  (artifacts['exportCandidate'] as Map?)?['path'],
                ]
                .whereType<String>()
                .where(
                  (p) =>
                      p.startsWith('/assets/') ||
                      p.startsWith('/tools/stamp-maker/assets/'),
                )
                .firstOrNull;
        final key = '${record['stampId'] ?? record['id']}';
        if (source != null) entries.putIfAbsent(key, () => source);
      }
      for (final stamp in originals) {
        final source = entries[stamp.id] ?? entries[stamp.name];
        if (source != null) {
          textless.add(
            _Stamp(stamp.id, stamp.name, stamp.label, [
              api.asset(source).toString(),
            ], stamp.characters),
          );
        }
      }
    } catch (_) {}
    // Characters' published colours (`stampCharacterColors`).
    final colors = <(String, String, Color, String?)>[];
    for (final MapEntry(key: id, value: value)
        in ((characters as Map?) ?? const {}).entries) {
      if (value is! Map) continue;
      final code = '${value['colorCode'] ?? value['color'] ?? ''}';
      if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(code)) continue;
      final name = state.text.text(value['nickname'] ?? value['characterName']);
      if (name.isEmpty) continue;
      colors.add((
        '$id',
        name,
        Color(int.parse('FF${code.substring(1)}', radix: 16)),
        value['faceImage'] is String
            ? api.asset(value['faceImage'] as String).toString()
            : null,
      ));
    }
    colors.sort(
      (a, b) => (int.tryParse(a.$1) ?? 0).compareTo(int.tryParse(b.$1) ?? 0),
    );
    if (textless.isEmpty) _textless = false;
    _Stamp? restored;
    try {
      final raw = await LocalDrafts.read('haneoka:stamp-maker:draft:v1');
      if (!mounted) return (originals, textless, colors);
      if (raw != null) {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        if (saved['schema'] == 'haneoka-stamp-draft-v1') {
          _textless = saved['textless'] as bool;
          _imageLanguage = saved['language'] as String?;
          _exportSize = saved['exportSize'] as int;
          final layers = (saved['layers'] as List)
              .map(
                (l) => stampLayerFromJson((l as Map).cast<String, dynamic>()),
              )
              .toList();
          if (layers.isNotEmpty) {
            _layers
              ..clear()
              ..addAll(layers);
            _selected = (saved['selected'] as int).clamp(0, _layers.length - 1);
            _text.text = _layer.settings.text;
          }
          restored = (_textless ? textless : originals)
              .where((s) => s.id == saved['stampId'])
              .firstOrNull;
        }
      }
    } catch (_) {}
    if (_layers.any((layer) => layer.settings.font == 'Pretendard SemiBold')) {
      unawaited(_ensurePretendard());
    }
    _restoredDraft = true;
    final first = restored ?? (_textless ? textless : originals).firstOrNull;
    if (first != null) {
      unawaited(_choose(first, restored == null ? colors : const [], false));
    }
    return (originals, textless, colors);
  }

  Future<void> _choose(
    _Stamp stamp, [
    List<(String, String, Color, String?)> colors = const [],
    bool persist = true,
  ]) async {
    setState(() {
      _stamp = stamp;
      final character = colors
          .where((c) => stamp.characters.contains(c.$1))
          .firstOrNull;
      if (character != null) {
        for (final layer in _layers) {
          if (layer.image == null) layer.settings.fill = character.$3;
        }
      }
    });
    if (persist) _scheduleDraft();
    for (final source in stamp.sources) {
      try {
        final response = await netClient.get(Uri.parse(source));
        if (response.statusCode != 200) continue;
        final codec = await ui.instantiateImageCodec(response.bodyBytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted || _stamp != stamp) {
          frame.image.dispose();
          return;
        }
        final previous = _image;
        setState(() => _image = frame.image);
        if (previous != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            previous.dispose();
          });
        }
        return;
      } catch (_) {}
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t('loadFailed', 'Could not load the stamp.'))),
      );
    }
  }

  Future<void> _ensurePretendard() async {
    if (_pretendardLoaded) return;
    try {
      final response = await netClient.get(
        Uri.parse(
          'https://haneoka.org/stamp-maker-fonts/c89bc43027dc7cde5726e96223376f8eec09302b2fc1f8147fd5b57cfc376118.otf',
        ),
      );
      final loader = FontLoader('Pretendard SemiBold')
        ..addFont(Future.value(ByteData.sublistView(response.bodyBytes)));
      await loader.load();
      _pretendardLoaded = true;
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _t(
                'fontFailed',
                'Could not load the font. Retry or choose another font.',
              ),
            ),
          ),
        );
      }
    }
  }

  StampLayer get _layer => _layers[_selected];

  void _edit(VoidCallback change) {
    setState(change);
    _scheduleDraft();
  }

  Future<List<int>> _png(int size) =>
      stampPng(size.toDouble(), _image, _layers);

  String get _fileName => '${_stamp?.name ?? 'stamp'}-haneoka.png';

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final bytes = Uint8List.fromList(await _png(_exportSize));
      final path = await FilePicker.saveFile(
        fileName: _fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['png'],
      );
      if (path != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_t('saved', 'PNG downloaded'))));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _t('failed', 'PNG export failed. Retry after the image loads.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _post() async {
    if (!await requireSession(context) || !mounted) return;
    final bytes = Uint8List.fromList(await _png(stampCanvasSize.round()));
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PostEditorScreen(
          image: (name: _fileName, bytes: bytes),
          purpose: 'stamp',
        ),
      ),
    );
  }

  Future<void> _pick(
    List<_Stamp> originals,
    List<_Stamp> textless,
    List<(String, String, Color, String?)> colors,
  ) async {
    var language = _imageLanguage ?? 'ja';
    var textlessMode = _textless;
    final picked = await showModalBottomSheet<_Stamp>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _StampSheet(
        originals: originals,
        textless: textless,
        characters: colors,
        textlessMode: _textless,
        language: _imageLanguage ?? 'ja',
        onLanguage: (value) => language = value,
        onMode: (value) => textlessMode = value,
        labels: (key, fallback) => _t(key, fallback),
      ),
    );
    if (picked != null) {
      _imageLanguage = language;
      _textless = textlessMode;
      await _choose(picked, colors);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppScope.of(context).text;
    return ShellPage(
      title: _t('title', 'Stamp maker'),
      body: FutureBuilder(
        future: _catalog,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return Center(
              child: snapshot.hasError
                  ? FilledButton.tonal(
                      onPressed: () => setState(() => _catalog = _load()),
                      child: Text(t('common.actions.retry', 'Retry')),
                    )
                  : const CircularProgressIndicator(),
            );
          }
          final (originals, textless, colors) = data;
          final layer = _layer;
          final isImage = layer.image != null;
          if (!isImage && _text.text != layer.settings.text) {
            _text.text = layer.settings.text;
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 840;
              final canvasSide = (constraints.maxWidth - 32).clamp(0.0, 360.0);
              final preview = Column(
                children: [
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => _pick(originals, textless, colors),
                        icon: const Icon(Symbols.image_rounded),
                        label: Text(_t('choose', 'Choose stamp')),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _stamp?.label ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _Canvas(
                    side: canvasSide,
                    image: _image,
                    layers: _layers,
                    selected: _selected,
                    onDrag: (delta) => _edit(() {
                      final dx = delta.dx / canvasSide * 100,
                          dy = delta.dy / canvasSide * 100;
                      if (layer.image case final image?) {
                        image.x = (image.x + dx).clamp(0, 100);
                        image.y = (image.y + dy).clamp(0, 100);
                      } else {
                        layer.settings.x = (layer.settings.x + dx).clamp(
                          0,
                          100,
                        );
                        layer.settings.y = (layer.settings.y + dy).clamp(
                          0,
                          100,
                        );
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      DropdownMenu<int>(
                        requestFocusOnTap: false,
                        width: 140,
                        label: Text(_t('resolution', 'Export size')),
                        initialSelection: _exportSize,
                        onSelected: (v) =>
                            setState(() => _exportSize = v ?? 512),
                        dropdownMenuEntries: [
                          for (final size in const [128, 256, 384, 512])
                            DropdownMenuEntry(value: size, label: '$size px'),
                        ],
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: TextButton.icon(
                          onPressed: _image == null ? null : _post,
                          icon: const Icon(Symbols.edit_rounded),
                          label: Text(
                            _t('communityPublish', 'Post to community'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy || _image == null ? null : _export,
                      icon: const Icon(Symbols.download_rounded),
                      label: Text(
                        _busy
                            ? _t('saving', 'Saving PNG…')
                            : _t('export', 'Export PNG'),
                      ),
                    ),
                  ),
                ],
              );
              final controls = Material(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Corner.extraLarge),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownMenu<int>(
                              requestFocusOnTap: false,
                              key: ValueKey(_layers.length),
                              expandedInsets: EdgeInsets.zero,
                              label: Text(_t('layer', 'Layer')),
                              initialSelection: _selected,
                              onSelected: (v) =>
                                  setState(() => _selected = v ?? _selected),
                              dropdownMenuEntries: [
                                for (final (index, l) in _layers.indexed)
                                  DropdownMenuEntry(
                                    value: index,
                                    label:
                                        '${index + 1} · ${l.image != null ? _t('imageLayer', 'Stamp image') : (l.settings.text.trim().isEmpty ? _t('text', 'Text') : l.settings.text.split('\n').first)}',
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: _t('addLayer', 'Add text'),
                            onPressed: () => setState(() {
                              _layers.add(
                                StampLayer.text(
                                  StampText(
                                    fill: _layers.last.settings.fill,
                                    y: 82,
                                  ),
                                ),
                              );
                              _selected = _layers.length - 1;
                            }),
                            icon: const Icon(Symbols.add_rounded),
                          ),
                          PopupMenuButton<String>(
                            tooltip: _t('layerActions', 'Layer actions'),
                            onSelected: (action) => setState(() {
                              switch (action) {
                                case 'duplicate':
                                  _layers.insert(_selected + 1, layer.copy());
                                  _selected++;
                                case 'delete':
                                  if (!isImage &&
                                      _layers
                                              .where((l) => l.image == null)
                                              .length >
                                          1) {
                                    _layers.removeAt(_selected);
                                    _selected = _selected.clamp(
                                      0,
                                      _layers.length - 1,
                                    );
                                  }
                                case 'up':
                                  if (_selected < _layers.length - 1) {
                                    _layers.insert(
                                      _selected + 1,
                                      _layers.removeAt(_selected),
                                    );
                                    _selected++;
                                  }
                                case 'down':
                                  if (_selected > 0) {
                                    _layers.insert(
                                      _selected - 1,
                                      _layers.removeAt(_selected),
                                    );
                                    _selected--;
                                  }
                                case 'reset':
                                  _layers[_selected] = isImage
                                      ? StampLayer.image()
                                      : StampLayer.text();
                              }
                            }),
                            itemBuilder: (_) => [
                              if (!isImage)
                                PopupMenuItem(
                                  value: 'duplicate',
                                  child: Text(
                                    _t('duplicateLayer', 'Duplicate layer'),
                                  ),
                                ),
                              if (!isImage)
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(
                                    _t('deleteLayer', 'Delete layer'),
                                  ),
                                ),
                              PopupMenuItem(
                                value: 'up',
                                child: Text(
                                  _t('bringForward', 'Bring forward'),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'down',
                                child: Text(
                                  _t('sendBackward', 'Send backward'),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'reset',
                                child: Text(
                                  _t('reset', 'Reset selected layer'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (isImage) ...[
                        _slider(
                          _t('imageScale', 'Image scale'),
                          layer.image!.scale,
                          10,
                          300,
                          '%',
                          (v) => layer.image!.scale = v,
                        ),
                        _slider(
                          _t('rotation', 'Rotation'),
                          layer.image!.rotation,
                          -180,
                          180,
                          '°',
                          (v) => layer.image!.rotation = v,
                        ),
                        _slider(
                          _t('x', 'Horizontal position'),
                          layer.image!.x,
                          0,
                          100,
                          '%',
                          (v) => layer.image!.x = v,
                        ),
                        _slider(
                          _t('y', 'Vertical position'),
                          layer.image!.y,
                          0,
                          100,
                          '%',
                          (v) => layer.image!.y = v,
                        ),
                      ] else ...[
                        TextField(
                          controller: _text,
                          minLines: 2,
                          maxLines: 5,
                          maxLength: 500,
                          decoration: InputDecoration(
                            labelText: _t('text', 'Text'),
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (v) =>
                              _edit(() => layer.settings.text = v),
                        ),
                        DropdownMenu<String>(
                          requestFocusOnTap: false,
                          key: ValueKey('font-$_selected'),
                          expandedInsets: EdgeInsets.zero,
                          leadingIcon: const Icon(Symbols.text_fields_rounded),
                          label: Text(_t('font', 'Font')),
                          initialSelection: layer.settings.font,
                          onSelected: (v) async {
                            if (v == null) return;
                            if (v == 'Pretendard SemiBold') {
                              await _ensurePretendard();
                            }
                            _edit(() => layer.settings.font = v);
                          },
                          dropdownMenuEntries: [
                            for (final (family, key) in _fonts)
                              DropdownMenuEntry(
                                value: family,
                                label: key == family ? family : _t(key, family),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: 'horizontal',
                              label: Text(_t('horizontal', 'Horizontal')),
                            ),
                            ButtonSegment(
                              value: 'vertical-rl',
                              label: Text(_t('rightToLeft', 'Right to left')),
                            ),
                            ButtonSegment(
                              value: 'vertical-lr',
                              label: Text(_t('leftToRight', 'Left to right')),
                            ),
                          ],
                          selected: {layer.settings.writingMode},
                          onSelectionChanged: (v) => _edit(
                            () => layer.settings.writingMode = v.single,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _slider(
                          _t('size', 'Text size'),
                          layer.settings.size,
                          2,
                          30,
                          '',
                          (v) => layer.settings.size = v,
                          display:
                              '${(layer.settings.size * stampCanvasSize / 100).round()} px',
                        ),
                        _ColorRow(
                          label: _t('fill', 'Text color'),
                          value: layer.settings.fill,
                          characters: colors,
                          onChanged: (c) =>
                              _edit(() => layer.settings.fill = c),
                        ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(
                            _t('positionStyle', 'Position and outline'),
                          ),
                          children: [
                            _ColorRow(
                              label: _t('stroke', 'Outline color'),
                              value: layer.settings.stroke,
                              characters: colors,
                              onChanged: (c) =>
                                  _edit(() => layer.settings.stroke = c),
                            ),
                            _slider(
                              _t('strokeWidth', 'Outline width'),
                              layer.settings.strokeWidth,
                              0,
                              5,
                              '',
                              (v) => layer.settings.strokeWidth = v,
                              display: layer.settings.strokeWidth
                                  .toStringAsFixed(1),
                            ),
                            _slider(
                              _t('rotation', 'Rotation'),
                              layer.settings.rotation,
                              -180,
                              180,
                              '°',
                              (v) => layer.settings.rotation = v,
                            ),
                            _slider(
                              _t('x', 'Horizontal position'),
                              layer.settings.x,
                              0,
                              100,
                              '%',
                              (v) => layer.settings.x = v,
                            ),
                            _slider(
                              _t('y', 'Vertical position'),
                              layer.settings.y,
                              0,
                              100,
                              '%',
                              (v) => layer.settings.y = v,
                            ),
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton.icon(
                                onPressed: () => _edit(
                                  () => layer.settings
                                    ..x = 50
                                    ..y = 50,
                                ),
                                icon: const Icon(
                                  Symbols.center_focus_strong_rounded,
                                ),
                                label: Text(_t('center', 'Center layer')),
                              ),
                            ),
                          ],
                        ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(_t('background', 'Text background')),
                          children: [
                            _ColorRow(
                              label: _t('backgroundColor', 'Background color'),
                              value: layer.settings.background.color,
                              characters: colors,
                              onChanged: (c) => _edit(
                                () => layer.settings.background.color = c,
                              ),
                            ),
                            _slider(
                              _t('backgroundAlpha', 'Background opacity'),
                              layer.settings.background.alpha,
                              0,
                              100,
                              '%',
                              (v) => layer.settings.background.alpha = v,
                            ),
                            _slider(
                              _t('backgroundPadding', 'Background padding'),
                              layer.settings.background.padding,
                              0,
                              10,
                              '',
                              (v) => layer.settings.background.padding = v,
                              display: layer.settings.background.padding
                                  .toStringAsFixed(1),
                            ),
                            _slider(
                              _t('backgroundRadius', 'Background radius'),
                              layer.settings.background.radius,
                              0,
                              20,
                              '',
                              (v) => layer.settings.background.radius = v,
                              display: layer.settings.background.radius
                                  .toStringAsFixed(1),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              );
              return ListView(
                padding: pagePadding(context),
                children: [
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: preview),
                        const SizedBox(width: 24),
                        SizedBox(width: 420, child: controls),
                      ],
                    )
                  else ...[
                    preview,
                    const SizedBox(height: 16),
                    controls,
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    String unit,
    ValueChanged<double> onChanged, {
    String? display,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(display ?? '${value.round()}$unit'),
        ],
      ),
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: (v) => _edit(() => onChanged(v)),
      ),
    ],
  );
}

/// The stamp on a transparency checkerboard; dragging moves the selected
/// layer.
class _Canvas extends StatelessWidget {
  const _Canvas({
    required this.side,
    required this.image,
    required this.layers,
    required this.selected,
    required this.onDrag,
  });
  final double side;
  final ui.Image? image;
  final List<StampLayer> layers;
  final int selected;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onPanUpdate: (details) => onDrag(details.delta),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(Corner.large),
      child: SizedBox.square(
        dimension: side,
        child: CustomPaint(
          painter: _StampPainter(
            image,
            layers,
            selected,
            Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    ),
  );
}

class _StampPainter extends CustomPainter {
  _StampPainter(this.image, this.layers, this.selected, this.accent);
  final ui.Image? image;
  final List<StampLayer> layers;
  final int selected;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 16.0;
    final light = Paint()..color = const Color(0xFF3A3A3D);
    final dark = Paint()..color = const Color(0xFF2C2C2F);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, cell, cell),
          ((x + y) / cell).round().isEven ? light : dark,
        );
      }
    }
    drawStamp(canvas, size.width, image, layers);
    // The selected layer's anchor.
    final layer = layers[selected];
    final point = layer.image != null
        ? Offset(
            size.width * layer.image!.x / 100,
            size.width * layer.image!.y / 100,
          )
        : Offset(
            size.width * layer.settings.x / 100,
            size.width * layer.settings.y / 100,
          );
    canvas.drawCircle(
      point,
      6,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Character colours, a few basics and a hex field.
class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.label,
    required this.value,
    required this.characters,
    required this.onChanged,
  });
  final String label;
  final Color value;
  final List<(String, String, Color, String?)> characters;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    Widget swatch(Color color, String tip) => Tooltip(
      message: tip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => onChanged(color),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: value.toARGB32() == color.toARGB32()
                  ? scheme.primary
                  : scheme.outlineVariant,
              width: value.toARGB32() == color.toARGB32() ? 3 : 1,
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              SizedBox(
                width: 120,
                child: TextField(
                  key: ValueKey(hex(value)),
                  controller: TextEditingController(text: hex(value)),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')),
                  ],
                  onSubmitted: (text) {
                    final code = text.replaceFirst('#', '');
                    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(code)) {
                      onChanged(Color(int.parse('FF$code', radix: 16)));
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              swatch(const Color(0xFFFFFFFF), '#FFFFFF'),
              swatch(const Color(0xFF333333), '#333333'),
              swatch(const Color(0xFF000000), '#000000'),
              for (final (_, name, color, _) in characters) swatch(color, name),
            ],
          ),
        ],
      ),
    );
  }
}

class _StampSheet extends StatefulWidget {
  const _StampSheet({
    required this.originals,
    required this.textless,
    required this.characters,
    required this.textlessMode,
    required this.onMode,
    required this.language,
    required this.onLanguage,
    required this.labels,
  });
  final List<_Stamp> originals;
  final List<_Stamp> textless;
  final List<(String, String, Color, String?)> characters;
  final bool textlessMode;
  final ValueChanged<bool> onMode;
  final String language;
  final ValueChanged<String> onLanguage;
  final String Function(String key, String fallback) labels;
  @override
  State<_StampSheet> createState() => _StampSheetState();
}

class _StampSheetState extends State<_StampSheet> {
  late bool _textless = widget.textlessMode;
  late String _language = widget.language;
  String _character = '';
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final textless = {for (final stamp in widget.textless) stamp.id: stamp};
    final stamps = widget.originals
        .where((stamp) => stamp.supportsLanguage(_language))
        .map(
          (stamp) => _textless
              ? (textless[stamp.id] ??
                    _Stamp(
                      stamp.id,
                      stamp.name,
                      stamp.label,
                      const [],
                      stamp.characters,
                    ))
              : stamp.inLanguage(_language),
        )
        .where(
          (s) =>
              (_character.isEmpty || s.characters.contains(_character)) &&
              (_query.isEmpty ||
                  '${s.label} ${s.name}'.toLowerCase().contains(
                    _query.toLowerCase(),
                  )),
        )
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Symbols.search_rounded),
                      hintText: t('common.actions.search', 'Search'),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _language,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t('settings.labels.language', 'Language'),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (final (key, name) in const [
                        ('ja', '日本語'),
                        ('en', 'English'),
                        ('zh-Hant', '繁體中文'),
                        ('zh-Hans', '简体中文'),
                        ('ko', '한국어'),
                      ])
                        DropdownMenuItem(value: key, child: Text(name)),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _language = value);
                        widget.onLanguage(value);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(widget.labels('original', 'Original')),
                    value: !_textless,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _textless = !value);
                        widget.onMode(!value);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(t('common.states.all', 'All')),
                    selected: _character.isEmpty,
                    onSelected: (_) => setState(() => _character = ''),
                  ),
                ),
                for (final (id, name, _, face) in widget.characters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      avatar: face == null
                          ? null
                          : ClipOval(child: AppImage(candidates: [face])),
                      label: Text(name),
                      selected: _character == id,
                      onSelected: (_) => setState(
                        () => _character = _character == id ? '' : id,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: collectionGrid(
                  context,
                  constraints.maxWidth - 32,
                  minWidth: 140,
                  subtitle: false,
                  small: true,
                ),
                itemCount: stamps.length,
                itemBuilder: (context, index) {
                  final stamp = stamps[index];
                  return Tile(
                    title: stamp.label,
                    images: stamp.sources,
                    aspectRatio: 1,
                    fit: BoxFit.contain,
                    onTap: stamp.sources.isEmpty
                        ? null
                        : () => Navigator.pop(context, stamp),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
