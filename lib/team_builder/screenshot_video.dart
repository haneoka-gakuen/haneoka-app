/// Frames of a Box screen recording for on-device recognition, as the
/// website takes them (`src/lib/team-builder/screenshot-video.ts`): one every
/// quarter second, decoded by the app's own player. The video never leaves
/// the device.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:media_kit/media_kit.dart';

import 'screenshot_import.dart';

/// A Box row stays on screen longer than this while scrolling.
const _step = Duration(milliseconds: 250);
const _maxFrames = 600;

/// The frame count a recording of [duration] yields.
int videoFrameCount(Duration duration) =>
    (duration.inMilliseconds ~/ _step.inMilliseconds + 1).clamp(1, _maxFrames);

/// Each frame as an image the caller disposes, with its index and the total.
Stream<(ui.Image, int, int)> videoFrames(String path) async* {
  // No texture: mpv's image output draws each frame in software, so a
  // screenshot has it; the files it writes go to a folder removed after.
  final folder = await Directory.systemTemp.createTemp('haneoka-frames-');
  final player = Player(
    configuration: const PlayerConfiguration(vo: 'image', muted: true),
  );
  try {
    await player.open(Media(path), play: false);
    final native = player.platform;
    if (native is NativePlayer) {
      // Without a video view the player leaves video off; frames are needed
      // here. Exact seeks: a keyframe seek would repeat frames.
      await native.setProperty('vo-image-outdir', folder.path);
      await native.setProperty('vo-image-format', 'jpg');
      await native.setProperty('hwdec', 'no');
      await native.setProperty('vid', 'auto');
      await native.setProperty('hr-seek', 'yes');
    }
    final ready = await player.stream.width
        .firstWhere((width) => width != null && width > 0)
        .then((_) => true)
        .timeout(const Duration(seconds: 20), onTimeout: () => false);
    var duration = player.state.duration;
    for (var i = 0; i < 40 && duration == Duration.zero; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      duration = player.state.duration;
    }
    if (!ready || duration == Duration.zero) {
      throw const ScreenshotError('image-video');
    }
    final total = videoFrameCount(duration);
    for (var index = 0; index < total; index++) {
      final at = _step * index > duration ? duration : _step * index;
      await player.seek(at);
      await player.stream.position
          .firstWhere((p) => (p - at).abs() < const Duration(milliseconds: 60))
          .timeout(const Duration(seconds: 2), onTimeout: () => at);
      // The texture follows the position by a frame.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final bgra = await player.screenshot(format: null);
      final width = player.state.width, height = player.state.height;
      if (bgra == null || width == null || height == null) continue;
      if (bgra.length < width * height * 4) continue;
      yield (await _image(bgra, width, height), index, total);
    }
  } finally {
    await player.dispose();
    await folder.delete(recursive: true).catchError((Object _) => folder);
  }
}

Future<ui.Image> _image(Uint8List bgra, int width, int height) {
  // mpv's raw frames are bgr0: the fourth byte is padding, not alpha.
  for (var i = 3; i < bgra.length; i += 4) {
    bgra[i] = 255;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bgra,
    width,
    height,
    ui.PixelFormat.bgra8888,
    done.complete,
    // Rows are padded to the decoder's alignment.
    rowBytes: bgra.length ~/ height,
  );
  return done.future;
}
