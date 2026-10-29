import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/net.dart';
import '../shell/page.dart';
import 'puzzle_recognition.dart';

class PuzzleImportScreen extends StatefulWidget {
  const PuzzleImportScreen({
    super.key,
    required this.size,
    required this.cover,
  });
  final int size;
  final String cover;
  @override
  State<PuzzleImportScreen> createState() => _PuzzleImportScreenState();
}

class _PuzzleImportScreenState extends State<PuzzleImportScreen> {
  Uint8List? _bytes, _cover;
  ui.Image? _image;
  PuzzleCrop? _crop;
  PuzzleRecognition? _result;
  List<int> _tiles = [];
  int? _selected;
  bool _busy = false;
  String? _error;
  int _generation = 0;
  String t(String key) =>
      AppScope.of(context).text('tools.songPuzzle.$key', key);
  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (picked == null || !mounted) return;
    final file = picked;
    if ((await file.length() ?? 0) > 32 * 1024 * 1024) {
      setState(() => _error = 'imageTooLarge');
      return;
    }
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1600, allowUpscaling: false);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    final pixels = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    _image?.dispose();
    setState(() {
      _image = frame.image;
      _bytes = pixels!.buffer.asUint8List();
      _crop = null;
      _result = null;
      _tiles = [];
      _error = null;
    });
    await _recognize(true);
  }

  Future<void> _recognize(bool automatic) async {
    if (_bytes == null || _busy) return;
    final generation = ++_generation,
        bytes = _bytes!,
        size = widget.size,
        crop = automatic ? null : _crop;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_cover == null) {
        final response = await netClient.get(Uri.parse(widget.cover));
        if (response.statusCode != 200) {
          throw const FormatException('imageError');
        }
        _cover = response.bodyBytes;
      }
      final cover = _cover!;
      final result = await Isolate.run(
        () => recognizePuzzle(bytes, cover, size, crop: crop),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _result = result;
        _crop = result.crop;
        _tiles = [...result.tiles];
        _selected = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () =>
              _error = error is FormatException ? error.message : 'imageError',
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image, crop = _crop;
    final initial = (
      x: 0.0,
      y: 0.0,
      side: image == null
          ? 24.0
          : math.min(image.width, image.height).toDouble(),
    );
    Widget number(String key, double value, void Function(double) change) =>
        TextFormField(
          key: ValueKey((key, value)),
          initialValue: value.round().toString(),
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: t(key)),
          onFieldSubmitted: (text) {
            final n = double.tryParse(text);
            if (n != null && n >= 0) {
              setState(() {
                change(n);
                _result = null;
                _tiles = [];
              });
            }
          },
        );
    return ShellPage(
      title: t('imageImport'),
      showBack: true,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _choose,
            icon: const Icon(Symbols.image_rounded),
            label: Text(t('imageChoose')),
          ),
          const SizedBox(height: 16),
          if (image != null) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: AspectRatio(
                aspectRatio: image.width / image.height,
                child: CustomPaint(painter: _CropPainter(image, crop)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: number(
                    'imageX',
                    (crop ?? initial).x,
                    (n) => _crop = (
                      x: n,
                      y: (crop ?? initial).y,
                      side: (crop ?? initial).side,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: number(
                    'imageY',
                    (crop ?? initial).y,
                    (n) => _crop = (
                      x: (crop ?? initial).x,
                      y: n,
                      side: (crop ?? initial).side,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: number(
                    'imageSide',
                    (crop ?? initial).side,
                    (n) => _crop = (
                      x: (crop ?? initial).x,
                      y: (crop ?? initial).y,
                      side: n
                          .clamp(24, math.min(image.width, image.height))
                          .toDouble(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _recognize(true),
                  child: Text(t('imageLocate')),
                ),
                FilledButton(
                  onPressed: _busy ? null : () => _recognize(false),
                  child: Text(t('imageRecognize')),
                ),
              ],
            ),
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(t(_error!)),
            ),
          if (_result case final result?) ...[
            const SizedBox(height: 16),
            Text(
              t('imageReview'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _tiles.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: widget.size,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemBuilder: (context, i) => Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  side: BorderSide(
                    color: _selected == i
                        ? Theme.of(context).colorScheme.primary
                        : result.uncertain.contains(i)
                        ? Theme.of(context).colorScheme.tertiary
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: InkWell(
                  onTap: () => setState(() {
                    if (_selected == null) {
                      _selected = i;
                    } else {
                      final previous = _tiles[i];
                      _tiles[i] = _tiles[_selected!];
                      _tiles[_selected!] = previous;
                      _selected = null;
                    }
                  }),
                  child: Center(
                    child: Text(_tiles[i] == 0 ? '—' : '${_tiles[i]}'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                PuzzleRecognition(
                  result.crop,
                  _tiles,
                  result.goalBlank,
                  result.uncertain,
                  result.error,
                ),
              ),
              child: Text(t('imageApply')),
            ),
          ],
        ],
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop);
  final ui.Image image;
  final PuzzleCrop? crop;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint(),
    );
    if (crop case final c?) {
      final sx = size.width / image.width, sy = size.height / image.height;
      canvas.drawRect(
        Rect.fromLTWH(c.x * sx, c.y * sy, c.side * sx, c.side * sy),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xffffffff),
      );
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.crop != crop;
}
