/// Screenshot recognition import (`team-builder/recognition-client.ts`,
/// `screenshot-import.ts`, `screenshot-import-session.ts`,
/// `screenshot-image.ts`): screenshots are cropped and encoded on the
/// device, recognized by the website's private job endpoint for the signed-in
/// account, and each recognized card is reviewed before the box changes.
/// Screenshots only show cards and levels; other fields stay as they are.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import '../account/haneoka_account.dart';
import 'box.dart';
import 'box_import.dart';
import 'engine/master.dart';
import 'engine/num.dart';

/// Percent cut from each side, as the website's crop sliders.
class ScreenshotCrop {
  const ScreenshotCrop({
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    this.left = 0,
  });
  final double top, right, bottom, left;
  ScreenshotCrop copyWith(String side, double value) => ScreenshotCrop(
    top: side == 'top' ? value : top,
    right: side == 'right' ? value : right,
    bottom: side == 'bottom' ? value : bottom,
    left: side == 'left' ? value : left,
  );
  double of(String side) => switch (side) {
    'top' => top,
    'right' => right,
    'bottom' => bottom,
    _ => left,
  };
}

class ScreenshotError implements Exception {
  const ScreenshotError(this.code);

  /// `image-format`, `image-budget`, `image-heic`, `image-crop`,
  /// `image-timeout`, or a recognition failure code.
  final String code;
  @override
  String toString() => code;
}

const _imageBytes = 8 * 1024 * 1024;
const _imagePixels = 16000000;

/// `screenshotHeader`: only PNG, JPEG and WebP within the pixel budget.
void checkScreenshotHeader(Uint8List bytes) {
  String ascii(int from, int length) => bytes.length < from + length
      ? ''
      : String.fromCharCodes(bytes.sublist(from, from + length));
  final view = ByteData.sublistView(bytes);
  var width = 0, height = 0;
  if (bytes.length >= 24 &&
      bytes[0] == 137 &&
      ascii(1, 3) == 'PNG' &&
      ascii(12, 4) == 'IHDR') {
    width = view.getUint32(16);
    height = view.getUint32(20);
  } else if (bytes.length >= 12 && ascii(4, 4) == 'ftyp') {
    throw const ScreenshotError('image-heic');
  } else if (bytes.length > 2 && bytes[0] == 255 && bytes[1] == 216) {
    for (var offset = 2; offset + 8 < bytes.length;) {
      if (bytes[offset] != 255) break;
      final marker = bytes[offset + 1];
      if (marker == 255) {
        offset++;
        continue;
      }
      if (marker == 0xda || marker == 0xd9) break;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
        offset += 2;
        continue;
      }
      final length = view.getUint16(offset + 2);
      if (length < 2 || offset + length + 2 > bytes.length) break;
      if (marker == 0xc0 || marker == 0xc1 || marker == 0xc2) {
        height = view.getUint16(offset + 5);
        width = view.getUint16(offset + 7);
        break;
      }
      offset += length + 2;
    }
  } else if (bytes.length >= 30 &&
      ascii(0, 4) == 'RIFF' &&
      ascii(8, 4) == 'WEBP') {
    final chunk = ascii(12, 4);
    if (chunk == 'VP8X') {
      width = 1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16);
      height = 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16);
    } else if (chunk == 'VP8 ' &&
        bytes[23] == 0x9d &&
        bytes[24] == 1 &&
        bytes[25] == 0x2a) {
      width = view.getUint16(26, Endian.little) & 0x3fff;
      height = view.getUint16(28, Endian.little) & 0x3fff;
    } else if (chunk == 'VP8L' && bytes[20] == 0x2f) {
      final bits = view.getUint32(21, Endian.little);
      width = (bits & 0x3fff) + 1;
      height = ((bits >> 14) & 0x3fff) + 1;
    }
  }
  if (width == 0 || height == 0) throw const ScreenshotError('image-format');
  if (width > 8192 || height > 8192 || width * height > _imagePixels) {
    throw const ScreenshotError('image-budget');
  }
}

/// `cropPixels`.
ui.Rect cropRect(int width, int height, ScreenshotCrop crop) {
  if ([
        crop.top,
        crop.right,
        crop.bottom,
        crop.left,
      ].any((v) => !v.isFinite || v < 0 || v > 95) ||
      crop.left + crop.right >= 100 ||
      crop.top + crop.bottom >= 100) {
    throw const ScreenshotError('image-crop');
  }
  final x = (width * crop.left / 100).floor();
  final y = (height * crop.top / 100).floor();
  final w = width - x - (width * crop.right / 100).floor();
  final h = height - y - (height * crop.bottom / 100).floor();
  if (w < 128 || h < 128) throw const ScreenshotError('image-crop');
  return ui.Rect.fromLTWH(
    x.toDouble(),
    y.toDouble(),
    w.toDouble(),
    h.toDouble(),
  );
}

/// A screenshot decoded once (with its orientation applied).
class LocalScreenshot {
  LocalScreenshot(this.image, this.crop);
  final ui.Image image;
  ScreenshotCrop crop;
}

Future<ui.Image> decodeScreenshot(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > _imageBytes) {
    throw const ScreenshotError('image-budget');
  }
  checkScreenshotHeader(bytes);
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    if (image.width * image.height > _imagePixels) {
      image.dispose();
      throw const ScreenshotError('image-budget');
    }
    return image;
  } on ScreenshotError {
    rethrow;
  } catch (_) {
    throw const ScreenshotError('image-format');
  }
}

/// `prepareScreenshot`: the cropped screenshot as PNG, within the
/// recognizer's 4096-pixel side and eight-million-pixel area.
Future<(ui.Image, Uint8List)> prepareScreenshot(LocalScreenshot local) async {
  final source = local.image;
  final rect = cropRect(source.width, source.height, local.crop);
  var scale = math
      .min(
        1.0,
        math.min(
          4096 / math.max(rect.width, rect.height),
          math.sqrt(8000000 / (rect.width * rect.height)),
        ),
      )
      .toDouble();
  while (true) {
    final width = (rect.width * scale).floor();
    final height = (rect.height * scale).floor();
    if (width < 128 || height < 128) throw const ScreenshotError('image-crop');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      rect,
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final image = await recorder.endRecording().toImage(width, height);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = png!.buffer.asUint8List();
    if (bytes.length <= _imageBytes) return (image, bytes);
    image.dispose();
    // The website falls back to JPEG here; a smaller PNG keeps the same pixels'
    // proportions within the upload limit.
    scale *= 0.85;
  }
}

/// A card crop for the review, at most 320 pixels on its long side.
Future<ui.Image> observationCrop(ui.Image image, List<int> bbox) async {
  final scale = math.min(1.0, 320 / math.max(bbox[2], bbox[3]));
  final width = math.max(1, (bbox[2] * scale).round());
  final height = math.max(1, (bbox[3] * scale).round());
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(
      bbox[0].toDouble(),
      bbox[1].toDouble(),
      bbox[2].toDouble(),
      bbox[3].toDouble(),
    ),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  return recorder.endRecording().toImage(width, height);
}

class ScreenshotObservation {
  ScreenshotObservation({
    required this.bbox,
    required this.members,
    required this.cardId,
    required this.candidates,
    required this.level,
  });
  final List<int> bbox;
  final bool members;
  final int? cardId;

  /// Candidate card ids, best first.
  final List<int> candidates;

  /// The visible level, when the recognizer read it.
  final int? level;
}

class ScreenshotResult {
  ScreenshotResult(this.width, this.height, this.noGrid, this.observations);
  final int width;
  final int height;
  final bool noGrid;
  final List<ScreenshotObservation> observations;
}

final _uuid = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
  caseSensitive: false,
);
final _hash = RegExp(r'^[a-f0-9]{64}$');

String uuid4() {
  final random = math.Random.secure();
  final bytes = [for (var i = 0; i < 16; i++) random.nextInt(256)];
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')]
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The recognition identity: the loaded release the website's recognizer
/// holds references for.
typedef RecognitionContext = ({
  String owner,
  String server,
  String releaseId,
  String sourceId,
});

/// `createRecognitionClient` over the signed-in account's bearer session.
class RecognitionClient {
  RecognitionClient(this.context, [HaneokaAccount? account])
    : _account = account ?? HaneokaAccount.instance;
  final RecognitionContext context;
  final HaneokaAccount _account;

  String _path([String? id]) {
    final query = Uri(
      queryParameters: {
        'server': context.server,
        'releaseId': context.releaseId,
        'sourceId': context.sourceId,
      },
    ).query;
    return '/api/v1/team-builder/recognition/jobs${id == null ? '' : '/$id'}?$query';
  }

  Map<String, String> get _headers => {
    'X-Haneoka-Expected-User': context.owner,
  };

  Doc _job(Object? body, String id) {
    if (!_uuid.hasMatch(id)) throw const ScreenshotError('recognition-job-id');
    final job = objectRow(objectRow(body)['job']);
    final jobContext = objectRow(job['context']);
    if (job['id'] != id ||
        !const {
          'queued',
          'processing',
          'ready',
          'failed',
        }.contains(job['state']) ||
        jobContext['server'] != context.server ||
        jobContext['releaseId'] != context.releaseId ||
        jobContext['sourceId'] != context.sourceId ||
        !_hash.hasMatch('${jobContext['referenceId']}')) {
      throw const ScreenshotError('recognition-job-context-mismatch');
    }
    return job;
  }

  Future<Doc> submit(Uint8List png, String id) async => _job(
    await _account.request(
      'POST',
      _path(),
      bytes: png,
      headers: {
        ..._headers,
        'Content-Type': 'image/png',
        'Idempotency-Key': id,
        'X-Image-Sha256': sha256.convert(png).toString(),
      },
    ),
    id,
  );

  Future<Doc> poll(String id) async =>
      _job(await _account.request('GET', _path(id), headers: _headers), id);

  Future<void> cancel(String id) async {
    try {
      await _account.request('DELETE', _path(id), headers: _headers);
    } on AccountError catch (error) {
      if (error.code != 'http_404') rethrow;
    }
  }
}

/// `normalizeRecognitionResult` for a one-image job.
ScreenshotResult normalizeRecognition(Doc job) {
  final result = objectRow(job['result']);
  final context = objectRow(job['context']);
  final identity = objectRow(result['identity']);
  final images = result['images'];
  final observations = result['observations'];
  if (job['state'] != 'ready' ||
      result['schema'] != 'haneoka-card-recognition-result-v1' ||
      ![
        'server',
        'releaseId',
        'sourceId',
      ].every((key) => identity[key] == context[key]) ||
      (result['referenceId'] != null &&
          result['referenceId'] != context['referenceId']) ||
      images is! List ||
      images.length != 1 ||
      observations is! List ||
      observations.length > 100) {
    throw const ScreenshotError('recognition-result-context');
  }
  final image = objectRow(images.single);
  final size = image['size'];
  if (image['coordinateSpace'] != 'exif_normalized_original' ||
      !_hash.hasMatch('${image['sha256']}') ||
      size is! List ||
      size.length != 2 ||
      size.any((v) => v is! int || v < 128 || v > 4096) ||
      (size[0] as int) * (size[1] as int) > 8000000) {
    throw const ScreenshotError('recognition-result-image');
  }
  final width = size[0] as int, height = size[1] as int;
  final rows = <ScreenshotObservation>[];
  for (final raw in observations) {
    final row = objectRow(raw);
    final bbox = row['bbox'];
    final kind = row['kind'];
    final fields = objectRow(row['fields']);
    final level = objectRow(fields['level']);
    final candidates = row['candidates'];
    if (row['imageId'] != image['id'] ||
        (kind != 'members' && kind != 'snapshots') ||
        bbox is! List ||
        bbox.length != 4 ||
        bbox.any((v) => v is! int || v < 0) ||
        (bbox[2] as int) < 1 ||
        (bbox[3] as int) < 1 ||
        (bbox[0] as int) + (bbox[2] as int) > width ||
        (bbox[1] as int) + (bbox[3] as int) > height ||
        candidates is! List ||
        candidates.length > 5) {
      throw const ScreenshotError('recognition-result-observation');
    }
    final value = level['status'] == 'recognized' ? level['value'] : null;
    rows.add(
      ScreenshotObservation(
        bbox: [for (final v in bbox) v as int],
        members: kind == 'members',
        cardId: row['cardId'] is int ? row['cardId'] as int : null,
        candidates: [
          for (final candidate in candidates)
            if (objectRow(candidate)['cardId'] is int &&
                (objectRow(candidate)['cardId'] as int) > 0)
              objectRow(candidate)['cardId'] as int,
        ],
        level: value is int && value >= 1 ? value : null,
      ),
    );
  }
  return ScreenshotResult(width, height, image['status'] == 'needs_crop', rows);
}

class ScreenshotCard {
  ScreenshotCard(this.key, this.members, this.cardId, this.owned);
  final String key;
  final bool members;
  final int cardId;
  final Object? owned;

  /// (image, observation index) of every crop showing this card.
  final List<(int, int)> observations = [];
  final List<int> observedLevels = [];
  int? get existingLevel => ownedValue(owned, 'level');
}

enum LevelSource { saved, conflict, observed, unknown }

/// `screenshotLevelDefault`.
(int?, LevelSource) screenshotLevelDefault(
  ScreenshotCard card,
  ExistingPolicy policy,
) {
  if (card.owned != null &&
      (policy == ExistingPolicy.keep || card.observedLevels.isEmpty)) {
    return (card.existingLevel, LevelSource.saved);
  }
  if (card.observedLevels.length > 1) return (null, LevelSource.conflict);
  if (policy == ExistingPolicy.updates &&
      card.existingLevel != null &&
      card.observedLevels.length == 1 &&
      card.observedLevels.first <= card.existingLevel!) {
    return (card.existingLevel, LevelSource.saved);
  }
  if (card.observedLevels.length == 1) {
    return (card.observedLevels.first, LevelSource.observed);
  }
  return (null, LevelSource.unknown);
}

/// `previewScreenshotImportBatch`: crops showing the same card converge on
/// one entry. [selections] maps (image, observation) to the chosen card.
List<ScreenshotCard> previewScreenshots(
  List<ScreenshotResult> results,
  Map<(int, int), int?> selections,
  BoxView view,
  EngineMaster master,
  String server,
) {
  final cards = <String, ScreenshotCard>{};
  for (final (image, result) in results.indexed) {
    for (final (index, observation) in result.observations.indexed) {
      final chosen = selections[(image, index)];
      if (chosen == null) continue;
      final known = observation.members
          ? master.members.containsKey(chosen)
          : master.snaps.containsKey(chosen);
      if (!known) throw const ScreenshotError('screenshot-card-not-in-catalog');
      final kind = observation.members ? 'members' : 'snapshots';
      final key = '$server:$kind:$chosen';
      final card = cards[key] ??= ScreenshotCard(
        key,
        observation.members,
        chosen,
        observation.members ? view.members[chosen] : view.snaps[chosen],
      );
      card.observations.add((image, index));
      final level = observation.level;
      if (level != null && !card.observedLevels.contains(level)) {
        card.observedLevels.add(level);
      }
    }
  }
  return cards.values.toList();
}

class ScreenshotChoice {
  bool include = false;

  /// Null follows the default; `KeepChoice` keeps the saved level.
  FieldChoice? level;
  bool manual = false;
}

/// Levels a card may be set to, given its saved training or awakening.
List<int> screenshotLevels(EngineMaster master, ScreenshotCard card) =>
    practiceRanges(
      master,
      card.members,
      card.cardId,
      training: ownedValue(card.owned, 'training'),
      awakening: ownedValue(card.owned, 'awakening'),
    )['level'] ??
    const [];

/// `applyConfirmedScreenshotImport` as box writes.
List<(String, Object?)> applyScreenshots(
  List<ScreenshotCard> cards,
  Map<String, ScreenshotChoice> choices,
  ExistingPolicy policy,
  EngineMaster master,
) {
  final out = <(String, Object?)>[];
  for (final card in cards) {
    final choice = choices[card.key];
    if (choice == null || !choice.include) continue;
    if (screenshotLevelDefault(card, policy).$2 == LevelSource.conflict &&
        choice.level == null) {
      throw const ScreenshotError('screenshot-level-conflict');
    }
    final p = card.members ? 'm' : 's';
    if (card.owned == null) {
      out
        ..add(('$p.${card.cardId}.own', true))
        ..add(('$p.${card.cardId}.use', true));
    }
    final level = switch (choice.level) {
      KeepChoice() =>
        card.owned == null
            ? throw const ScreenshotError('screenshot-level-evidence-required')
            : null,
      ValueChoice(:final value) =>
        choice.manual || card.observedLevels.contains(value)
            ? value
            : throw const ScreenshotError('screenshot-level-evidence-required'),
      null =>
        card.observedLevels.length == 1 &&
                (card.owned == null ||
                    policy == ExistingPolicy.overwrite ||
                    (policy == ExistingPolicy.updates &&
                        (card.existingLevel == null ||
                            card.observedLevels.first > card.existingLevel!)))
            ? card.observedLevels.first
            : null,
    };
    if (level != null) {
      if (!screenshotLevels(master, card).contains(level)) {
        throw const ScreenshotError('screenshot-practice-review');
      }
      out.add(('$p.${card.cardId}.lvl', level));
    }
  }
  return out;
}
