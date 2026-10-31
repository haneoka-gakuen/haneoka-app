/// The screenshot import dialog (`renderScreenshotImportDialog` in
/// `lit/shared/team-screenshot-import.ts`, the screenshot half of
/// `lit/team-builder/importers.ts`).
library;

import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'box_import.dart';
import 'controller.dart';
import 'pickers.dart';
import 'screenshot_import.dart';
import 'widgets.dart';
import 'import_source_tile.dart';
import 'screenshot_video.dart';

/// Opens the dialog; recognition runs on this device.
Future<void> openScreenshotImport(
  BuildContext context,
  TeamBuilderController c,
) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ScreenshotImportScreen(c: c),
    ),
  );
}

enum _Phase { select, preview, preparing, processing, review, failed }

class _ScreenshotImportScreen extends StatefulWidget {
  const _ScreenshotImportScreen({required this.c});
  final TeamBuilderController c;

  @override
  State<_ScreenshotImportScreen> createState() =>
      _ScreenshotImportScreenState();
}

class _ScreenshotImportScreenState extends State<_ScreenshotImportScreen> {
  TeamBuilderController get c => widget.c;
  var _phase = _Phase.select;
  String? _error;
  final _local = <LocalScreenshot>[];
  final _results = <ScreenshotResult>[];
  final _crops = <(int, int), ui.Image>{};
  final _selections = <(int, int), int?>{};
  List<ScreenshotCard> _cards = const [];
  final _choices = <String, ScreenshotChoice>{};
  var _policy = ExistingPolicy.keep;
  int _generation = 0;
  String _signature = '';

  /// (frame, total) while a recording is read.
  (int, int)? _frame;

  String _t(String key, String fallback) {
    final t = c.state.text;
    if (key.startsWith('existing')) {
      return t(
        'tools.teamBuilder.importExisting.${key.substring(8).toLowerCase()}',
        fallback,
      );
    }
    if (key == 'close' || key == 'cancel') {
      return t('common.actions.$key', fallback);
    }
    return t('tools.teamBuilder.screenshotImport.$key', fallback);
  }

  @override
  void dispose() {
    ++_generation;
    _clearLocal();
    for (final image in _crops.values) {
      image.dispose();
    }
    super.dispose();
  }

  void _clearLocal() {
    for (final local in _local) {
      local.image.dispose();
    }
    _local.clear();
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty || !mounted) return;
    final generation = ++_generation;
    setState(() {
      _clearLocal();
      _phase = _Phase.preparing;
      _error = null;
    });
    try {
      if (picked.length > 8) throw const ScreenshotError('image-budget');
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        final image = await decodeScreenshot(bytes);
        if (generation != _generation) {
          image.dispose();
          return;
        }
        _local.add(LocalScreenshot(image, const ScreenshotCrop()));
      }
      if (!mounted) return;
      setState(() => _phase = _Phase.preview);
    } on ScreenshotError catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _clearLocal();
        _phase = _Phase.failed;
        _error = error.code;
      });
    }
  }

  /// `files` of the session: each screenshot is recognized on this device.
  Future<void> _upload() async {
    final generation = ++_generation;
    setState(() {
      _phase = _Phase.preparing;
      _error = null;
      _results.clear();
      _selections.clear();
      for (final image in _crops.values) {
        image.dispose();
      }
      _crops.clear();
    });
    bool live() => mounted && generation == _generation;
    try {
      for (final local in _local) {
        final (prepared, png) = await prepareScreenshot(local);
        try {
          if (!live()) return;
          setState(() => _phase = _Phase.processing);
          final result = await recognizeScreenshot(
            prepared,
            await recognitionReference(c.server),
          );
          if (!live()) return;
          final image = _results.length;
          for (final (index, row) in result.observations.indexed) {
            _crops[(image, index)] = await observationCrop(prepared, row.bbox);
            final master = c.catalog!.master;
            _selections[(image, index)] =
                row.cardId != null &&
                    (row.members ? master.members : master.snaps).containsKey(
                      row.cardId,
                    )
                ? row.cardId
                : null;
          }
          _results.add(result);
        } finally {
          prepared.dispose();
        }
      }
      if (!live()) return;
      _clearLocal();
      _review();
    } on ScreenshotError catch (error) {
      if (!live()) return;
      setState(() {
        _phase = _Phase.failed;
        _error = error.code;
      });
    } catch (_) {
      if (!live()) return;
      setState(() {
        _phase = _Phase.failed;
        _error = 'recognition-failed';
      });
    }
  }

  /// A screen recording: frames every quarter second, each recognized here.
  /// A card counts once it shows in two frames and matches clearly in one;
  /// its level once two frames read the same value.
  Future<void> _pickVideo() async {
    final picked = await FilePicker.pickFiles(type: FileType.video);
    final path = picked.firstOrNull?.path;
    if (path == null || !mounted) return;
    final generation = ++_generation;
    setState(() {
      _clearLocal();
      _phase = _Phase.processing;
      _error = null;
      _frame = null;
      _results.clear();
      _selections.clear();
      for (final image in _crops.values) {
        image.dispose();
      }
      _crops.clear();
    });
    bool live() => mounted && generation == _generation;
    final master = c.catalog!.master;
    final seen =
        <
          String,
          ({int frames, double best, Map<int, int> levels, (int, int) at})
        >{};
    final frames = <ScreenshotResult>[];
    final crops = <(int, int), ui.Image>{};
    try {
      final reference = await recognitionReference(c.server);
      await for (final (image, index, total) in videoFrames(path)) {
        try {
          if (!live()) return;
          setState(() => _frame = (index + 1, total));
          final result = await recognizeScreenshot(image, reference);
          final fresh = <ScreenshotObservation>[];
          for (final row in result.observations) {
            final id = row.cardId;
            if (id == null ||
                !(row.members ? master.members : master.snaps).containsKey(
                  id,
                )) {
              continue;
            }
            final key = '${row.members}:$id';
            final entry = seen[key];
            final levels = {...?entry?.levels};
            if (row.level case final level?) {
              levels[level] = (levels[level] ?? 0) + 1;
            }
            final at = entry?.at ?? (frames.length, fresh.length);
            if (entry == null) {
              fresh.add(row);
              crops[at] = await observationCrop(image, row.bbox);
            }
            seen[key] = (
              frames: (entry?.frames ?? 0) + 1,
              best: row.score > (entry?.best ?? 0) ? row.score : entry!.best,
              levels: levels,
              at: at,
            );
          }
          if (fresh.isNotEmpty) {
            frames.add(
              ScreenshotResult(result.width, result.height, false, fresh),
            );
          }
        } finally {
          image.dispose();
        }
      }
      if (!live()) return;
      final keep = {
        for (final entry in seen.values)
          if (entry.frames >= 2 && entry.best >= 0.8) entry.at: entry,
      };
      for (final (image, result) in frames.indexed) {
        final rows = <ScreenshotObservation>[];
        for (final (index, row) in result.observations.indexed) {
          final entry = keep[(image, index)];
          final crop = crops.remove((image, index));
          if (entry == null) {
            crop?.dispose();
            continue;
          }
          final ranked = entry.levels.entries.toList()
            ..sort((a, b) => b.value - a.value);
          final agreed =
              ranked.isNotEmpty &&
              ranked.first.value >= 2 &&
              (ranked.length < 2 || ranked.first.value > ranked[1].value);
          final at = (_results.length, rows.length);
          if (crop != null) _crops[at] = crop;
          _selections[at] = row.cardId;
          rows.add(
            ScreenshotObservation(
              bbox: row.bbox,
              members: row.members,
              cardId: row.cardId,
              candidates: row.candidates,
              level: agreed ? ranked.first.key : null,
              score: entry.best,
            ),
          );
        }
        if (rows.isNotEmpty) {
          _results.add(
            ScreenshotResult(result.width, result.height, false, rows),
          );
        }
      }
      _frame = null;
      _review();
    } on ScreenshotError catch (error) {
      if (!live()) return;
      setState(() {
        _phase = _Phase.failed;
        _error = error.code;
      });
    } catch (_) {
      if (!live()) return;
      setState(() {
        _phase = _Phase.failed;
        _error = 'image-video';
      });
    } finally {
      for (final image in crops.values) {
        image.dispose();
      }
    }
  }

  void _review() {
    final cards = previewScreenshots(
      _results,
      _selections,
      c.view!,
      c.catalog!.master,
      c.server,
    );
    final keep = {for (final card in cards) card.key};
    _choices.removeWhere((key, _) => !keep.contains(key));
    for (final card in cards) {
      final choice = _choice(card);
      if (choice.level case ValueChoice(:final value)
          when !(choice.manual
                  ? screenshotLevels(c.catalog!.master, card)
                  : card.observedLevels)
              .contains(value)) {
        choice.level = null;
      }
    }
    setState(() {
      _cards = cards;
      _signature = boxSignature(c.view!);
      _phase = _Phase.review;
    });
  }

  ScreenshotChoice _choice(ScreenshotCard card) =>
      _choices[card.key] ??= ScreenshotChoice()
        ..include = card.observedLevels.length <= 1;

  bool get _canConfirm {
    if (!_choices.values.any((choice) => choice.include)) return false;
    try {
      applyScreenshots(_cards, _choices, _policy, c.catalog!.master);
      return true;
    } on ScreenshotError {
      return false;
    }
  }

  void _confirm() {
    final view = c.view;
    if (view == null || boxSignature(view) != _signature) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            c.state.text(
              'tools.teamBuilder.boxImport.changed',
              'Your account, data or inventory changed. Open the import again.',
            ),
          ),
        ),
      );
      return;
    }
    final changes = [
      for (final change in applyScreenshots(
        _cards,
        _choices,
        _policy,
        c.catalog!.master,
      ))
        if (c.store!.value(change.$1) != change.$2) change,
    ];
    c.write(changes);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          c.tb('imported', 'Imported {count} changes', {
            'count': changes.length,
          }),
        ),
      ),
    );
  }

  Future<void> _correct(int image, int index) async {
    final observation = _results[image].observations[index];
    final catalog = c.catalog!;
    final picked = await pickCard(
      context,
      catalog,
      members: observation.members,
      ids: [
        ...(observation.members
            ? catalog.master.members.keys
            : catalog.master.snaps.keys),
      ],
      current: _selections[(image, index)],
    );
    if (picked == null || picked < 0 || !mounted) return;
    _selections[(image, index)] = picked;
    _review();
  }

  String _errorText(String code) {
    if (code.startsWith('image-')) {
      return _t(code, _t('failedMessage', 'Screenshot recognition failed'));
    }
    if (code == 'unavailable' || code == 'recognition-reference-unavailable') {
      return _t(
        'unavailable',
        'Screenshot recognition is unavailable for the loaded card data.',
      );
    }
    return _t('failedMessage', 'Screenshot recognition failed');
  }

  Widget _cropEditor(int index, LocalScreenshot local) {
    final theme = Theme.of(context);
    final image = local.image;
    final crop = local.crop;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: AspectRatio(
                aspectRatio: image.width / image.height,
                child: LayoutBuilder(
                  builder: (context, box) => Stack(
                    fit: StackFit.expand,
                    children: [
                      RawImage(image: image, fit: BoxFit.fill),
                      Positioned(
                        left: box.maxWidth * crop.left / 100,
                        right: box.maxWidth * crop.right / 100,
                        top: box.maxHeight * crop.top / 100,
                        bottom: box.maxHeight * crop.bottom / 100,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.primary,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            for (final (side, label) in [
              ('top', 'Top'),
              ('bottom', 'Bottom'),
              ('left', 'Left'),
              ('right', 'Right'),
            ])
              Row(
                children: [
                  SizedBox(width: 64, child: Text(_t(side, label))),
                  Expanded(
                    child: Slider(
                      value: crop.of(side),
                      max: 45,
                      divisions: 45,
                      label: '${crop.of(side).round()}',
                      onChanged: (value) => setState(
                        () => local.crop = crop.copyWith(side, value),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _source(int image, int index, int? selected) {
    final observation = _results[image].observations[index];
    final catalog = c.catalog!;
    final ids = {...observation.candidates, ?selected}.toList();
    final crop = _crops[(image, index)];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (crop != null)
            SizedBox(
              height: 96,
              child: AspectRatio(
                aspectRatio: observation.bbox[2] / observation.bbox[3],
                child: RawImage(image: crop, fit: BoxFit.contain),
              ),
            ),
          if (ids.isNotEmpty)
            DropdownMenu<int>(
              key: ValueKey('$image:$index:$selected'),
              width: 240,
              label: Text(_t('candidate', 'Card')),
              initialSelection: selected,
              hintText: _t('chooseCard', 'Choose card'),
              onSelected: (id) {
                if (id == null) return;
                _selections[(image, index)] = id;
                _review();
              },
              dropdownMenuEntries: [
                for (final id in ids)
                  DropdownMenuEntry(
                    value: id,
                    label: catalog.has(observation.members, id)
                        ? catalog.cardName(observation.members, id)
                        : '#$id',
                  ),
              ],
            ),
          OutlinedButton(
            onPressed: () => _correct(image, index),
            child: Text(_t('chooseCard', 'Choose card')),
          ),
        ],
      ),
    );
  }

  Widget _cardEntry(ScreenshotCard card) {
    final theme = Theme.of(context);
    final catalog = c.catalog!;
    final choice = _choice(card);
    final (defaultLevel, source) = screenshotLevelDefault(card, _policy);
    final conflict = source == LevelSource.conflict;
    final defaultLabel = switch (source) {
      LevelSource.saved => _t('keepLevel', 'Keep saved level'),
      LevelSource.conflict => _t('chooseLevel', 'Choose level'),
      LevelSource.observed => _t('observedLevel', 'Screenshot level'),
      LevelSource.unknown => _t('unknown', 'Unknown'),
    };
    final defaultText = defaultLevel == null
        ? defaultLabel
        : '$defaultLabel: $defaultLevel';
    final levels = screenshotLevels(catalog.master, card);
    final selectedLevel = switch (choice.level) {
      KeepChoice() => card.existingLevel,
      ValueChoice(:final value) => value,
      null => defaultLevel,
    };
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: card.members ? 72 : 112,
                  child: InkWell(
                    onTap: () => _correct(
                      card.observations.first.$1,
                      card.observations.first.$2,
                    ),
                    child: CardArt(
                      catalog: catalog,
                      members: card.members,
                      id: card.cardId,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        catalog.cardName(card.members, card.cardId),
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        value: choice.include,
                        onChanged: (value) =>
                            setState(() => choice.include = value ?? false),
                        title: Text(_t('include', 'Include card')),
                      ),
                      Text(defaultText, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      if (levels.isNotEmpty)
                        DropdownMenu<int>(
                          key: ValueKey('${card.key}:$selectedLevel'),
                          width: 200,
                          label: Text(_t('level', 'Level')),
                          initialSelection:
                              selectedLevel != null &&
                                  levels.contains(selectedLevel)
                              ? selectedLevel
                              : null,
                          hintText: _t('chooseLevel', 'Choose level'),
                          errorText:
                              conflict && choice.include && choice.level == null
                              ? ''
                              : null,
                          onSelected: (level) => setState(() {
                            if (level == null) return;
                            choice
                              ..level = ValueChoice(level)
                              ..manual = !card.observedLevels.contains(level);
                          }),
                          dropdownMenuEntries: [
                            for (final level in levels)
                              DropdownMenuEntry(value: level, label: '$level'),
                          ],
                        ),
                      Wrap(
                        spacing: 4,
                        children: [
                          if (card.owned != null && choice.level is! KeepChoice)
                            TextButton(
                              onPressed: () => setState(
                                () => choice.level = const KeepChoice(),
                              ),
                              child: Text(
                                '${_t('keepLevel', 'Keep saved level')}: ${card.existingLevel ?? _t('levelUnknown', 'Level not recognized')}',
                              ),
                            ),
                          if (choice.level != null)
                            TextButton(
                              onPressed: () =>
                                  setState(() => choice.level = null),
                              child: Text(defaultText),
                            ),
                        ],
                      ),
                      if (card.observedLevels.isEmpty)
                        Text(
                          _t('levelUnknown', 'Level not recognized'),
                          style: theme.textTheme.labelSmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(_t('sourceImages', 'Screenshots')),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (image, index) in card.observations)
                  _source(image, index, card.cardId),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = const {_Phase.preparing, _Phase.processing}.contains(_phase);
    final noGrid =
        _results.isNotEmpty && _results.every((result) => result.noGrid);
    final unmatched = [
      for (final (image, result) in _results.indexed)
        for (final (index, _) in result.observations.indexed)
          if (!_cards.any((card) => card.observations.contains((image, index))))
            (image, index),
    ];
    final children = <Widget>[
      if (_phase == _Phase.select ||
          _phase == _Phase.failed ||
          (_phase == _Phase.review && noGrid))
        ImportSourceTile(
          icon: Symbols.image_rounded,
          title: _t('chooseImages', 'Choose screenshots'),
          hint: _t('imagesHint', 'Up to 8 images of the card list'),
          onTap: _pick,
        ),
      if (_phase == _Phase.select ||
          _phase == _Phase.failed ||
          (_phase == _Phase.review && noGrid))
        ImportSourceTile(
          icon: Symbols.videocam_rounded,
          title: _t('chooseVideo', 'Choose screen recording'),
          hint: _t('videoHint', 'Scroll through the whole list once'),
          onTap: _pickVideo,
        ),
      if (busy) ...[
        LinearProgressIndicator(
          value: _frame == null ? null : _frame!.$1 / _frame!.$2,
        ),
        Text(
          _frame == null
              ? _t(_phase.name, 'Recognizing screenshots')
              : '${_t(_phase.name, 'Recognizing screenshots')} · ${_frame!.$1} / ${_frame!.$2}',
          style: theme.textTheme.bodyMedium,
        ),
      ],
      if (_error != null)
        Text(
          _errorText(_error!),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      if (_phase == _Phase.preview)
        for (final (index, local) in _local.indexed) _cropEditor(index, local),
      if (_phase == _Phase.review && _cards.isNotEmpty) ...[
        Text(
          _t('existingPolicy', 'Existing cards'),
          style: theme.textTheme.labelLarge,
        ),
        Segmented<ExistingPolicy>(
          grow: false,
          value: _policy,
          options: [
            Choice(
              ExistingPolicy.keep,
              _t('existingKeep', 'Keep all existing values'),
            ),
            Choice(
              ExistingPolicy.updates,
              _t('existingUpdates', 'Only increases'),
            ),
            Choice(
              ExistingPolicy.overwrite,
              _t('existingOverwrite', 'Overwrite all existing values'),
            ),
          ],
          onSelected: (value) => setState(() {
            _policy = value;
            for (final card in _cards) {
              if (card.owned != null) {
                _choices[card.key]
                  ?..level = null
                  ..manual = false;
              }
            }
          }),
        ),
        for (final card in _cards) _cardEntry(card),
      ],
      if (_phase == _Phase.review) ...[
        if (noGrid) Text(_t('noGrid', 'No reliable card grid found')),
        for (final (image, index) in unmatched)
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _results[image].observations[index].cardId == null
                        ? _t('unrecognized', 'Unrecognized card')
                        : _t('reviewCard', 'Review card'),
                    style: theme.textTheme.titleSmall,
                  ),
                  _source(image, index, null),
                ],
              ),
            ),
          ),
      ],
    ];
    final footer = switch (_phase) {
      _Phase.preview => FilledButton(
        onPressed: _upload,
        child: Text(_t('upload', 'Recognize')),
      ),
      _ when busy => OutlinedButton(
        onPressed: () {
          ++_generation;
          setState(() {
            _clearLocal();
            _phase = _Phase.select;
          });
        },
        child: Text(_t('cancel', 'Cancel')),
      ),
      _Phase.review => FilledButton(
        onPressed: _canConfirm ? _confirm : null,
        child: Text(_t('confirm', 'Confirm import')),
      ),
      _ => null,
    };
    return Scaffold(
      appBar: AppBar(title: Text(_t('title', 'Import screenshots'))),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => children[index],
      ),
      bottomNavigationBar: footer == null
          ? null
          : Material(
              color: theme.colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    heightFactor: 1,
                    child: footer,
                  ),
                ),
              ),
            ),
    );
  }
}
