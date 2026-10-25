import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';

import 'audio_output.dart';
import 'playback_focus.dart';
import 'account_resource.dart';
import 'resource_file_cache.dart';
import 'media_lifecycle.dart';
import 'offline_files.dart';

class VoiceClip {
  const VoiceClip({required this.id, required this.url});
  final String id;
  final String url;
}

/// Page-owned speech playback. It never enters the music dock or song queue.
class VoicePlayback extends ChangeNotifier {
  final _player = AudioOutput();
  late final _focus = PlaybackFocus(stop);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  List<VoiceClip> _clips = const [];
  int _index = -1;
  bool _playing = false;
  bool _disposed = false;
  int _generation = 0;
  late final Future<void> _ready;
  Object? error;
  ResourceFileLease? _lease;
  Completer<void>? _download;
  Future<void>? _closing;
  final _pending = <Future<void>>{};
  bool _notifierDisposed = false;
  static final _instances = <VoicePlayback>{};
  static Future<void> stopAll() =>
      Future.wait([for (final voice in _instances) voice.stop()]);

  VoicePlayback() {
    MediaLifecycle.register(this, close);
    _instances.add(this);
    _subscriptions.add(
      AccountResources.instance.changes.listen((_) {
        if (_clips.any((clip) => isAccountResource(Uri.parse(clip.url)))) {
          unawaited(stop());
        }
      }),
    );
    _subscriptions.add(
      _player.errors.listen((exception) {
        if (_disposed) return;
        error = exception;
        _playing = false;
        notifyListeners();
      }),
    );
    _ready = _player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.speech,
          audioFocus: AndroidAudioFocus.gainTransient,
        ),
      ),
    );
    _subscriptions.add(
      _player.onPlayerStateChanged.listen((state) {
        _playing = state == PlayerState.playing;
        if (!_disposed) notifyListeners();
      }),
    );
    _subscriptions.add(
      _player.onPlayerComplete.listen((_) {
        if (_index + 1 < _clips.length) {
          _index++;
          unawaited(_play());
        } else {
          _playing = false;
          if (!_disposed) notifyListeners();
        }
      }),
    );
  }
  bool isPlaying(String id) =>
      _playing &&
      _index >= 0 &&
      _index < _clips.length &&
      _clips[_index].id == id;
  Future<void> toggle(VoiceClip clip) async {
    if (isPlaying(clip.id)) {
      await stop();
      return;
    }
    await playAll([clip]);
  }

  Future<void> playAll(List<VoiceClip> clips) async {
    if (clips.isEmpty || _disposed) return;
    _cancelDownload();
    final generation = ++_generation;
    await _focus.activate(() async {
      if (_disposed || generation != _generation) return;
      _clips = List.unmodifiable(clips);
      _index = 0;
      await _play();
    });
  }

  Future<void> _play() {
    final work = _playClip();
    _pending.add(work);
    return work.whenComplete(() => _pending.remove(work));
  }

  Future<void> _playClip() async {
    if (_disposed || _index < 0 || _index >= _clips.length) return;
    final generation = _generation;
    final url = _clips[_index].url;
    error = null;
    ResourceFileLease? lease;
    try {
      await _ready;
      if (_disposed || generation != _generation) return;
      if (isAccountResource(Uri.parse(url)) ||
          OfflineFiles.instance.contains(Uri.parse(url))) {
        final download = _download = Completer<void>();
        lease = await resourceFileCache.acquire(
          Uri.parse(url),
          kind: ResourceFileKind.media,
          cancelled: download.future,
        );
      }
      if (_disposed || generation != _generation) return;
      await _player.play(UrlSource(lease?.file.uri.toString() ?? url));
      if (_disposed || generation != _generation) return;
      final previous = _lease;
      _lease = lease;
      lease = null;
      await previous?.release();
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error = e;
        _playing = false;
      }
    } finally {
      await lease?.release();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() async {
    if (_disposed) return;
    _cancelDownload();
    _player.cancelPendingLoad();
    _generation++;
    _clips = const [];
    _index = -1;
    _playing = false;
    final lease = _lease;
    _lease = null;
    try {
      await _player.stop();
    } catch (e) {
      error = e;
    } finally {
      await lease?.release();
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }

  void _cancelDownload() {
    final download = _download;
    _download = null;
    if (download != null && !download.isCompleted) download.complete();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _disposed = true;
    _cancelDownload();
    _player.cancelPendingLoad();
    _focus.close();
    _generation++;
    _instances.remove(this);
    await Future.wait(_pending.toList());
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await _player.dispose();
    } finally {
      await _lease?.release();
      _lease = null;
      MediaLifecycle.unregister(this);
    }
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }
}
