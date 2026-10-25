import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/app_state.dart';
import '../core/net.dart';
import '../core/account_resource.dart';
import 'account_image.dart';
import '../core/storage.dart';
import '../core/offline_files.dart';

const _localeImageTags = {
  'en': ['en'],
  'zh-TW': ['zh-Hant', 'zh-Hans'],
  'zh-CN': ['zh-Hans', 'zh-Hant'],
  'ko': ['ko'],
};
final _gameAsset = RegExp(r'/assets/[^/]+/(?:Assets|Packages)/');
final _tagged = RegExp(r'\((?:en|ko|zh-Hans|zh-Hant)\)(?=\.[^./]+$)');

/// Locale-tagged artwork candidates (`localeTaggedCandidates`): the reading
/// locale's variants, then the untagged original.
List<String> localeImageCandidates(String source, String locale) {
  final tags = _localeImageTags[locale];
  if (source.isEmpty ||
      tags == null ||
      !_gameAsset.hasMatch(source) ||
      _tagged.hasMatch(Uri.parse(source).path)) {
    return [source];
  }
  final uri = Uri.parse(source);
  final path = uri.path;
  final slash = path.lastIndexOf('/'), dot = path.lastIndexOf('.');
  return [
    for (final tag in tags)
      dot > slash
          ? uri
                .replace(
                  path: '${path.substring(0, dot)}($tag)${path.substring(dot)}',
                )
                .toString()
          : uri.replace(path: '$path($tag)').toString(),
    source,
  ];
}

/// Addresses that failed this session, so a missing variant is asked for once.
final _missing = <String>{};
final _retryAfter = <String, DateTime>{};

/// Network artwork decoded at the size it is shown, trying each candidate in
/// turn (original first, thumbnail last), as the website's `nextImageCandidate`.
class AppImage extends StatefulWidget {
  const AppImage({
    super.key,
    required this.candidates,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.alignment = Alignment.center,
    this.localized = true,
    this.naturalHeight = false,
  });
  final List<String> candidates;

  /// Whether each candidate is first tried in the reading locale's own
  /// artwork (`banner(zh-Hans).png` beside `banner.png`).
  final bool localized;
  final bool naturalHeight;
  final BoxFit fit;
  final Alignment alignment;

  /// Shown when no candidate loads.
  final Widget? placeholder;

  @override
  State<AppImage> createState() => _AppImageState();
}

class _AppImageState extends State<AppImage> {
  int _index = 0;
  Timer? _retry;
  String? _vectorUrl;
  Future<File>? _vectorFile;
  AccountResourceLease? _vectorLease;
  StreamSubscription<void>? _accountChanges;
  int _vectorGeneration = 0;
  String? _chosenUrl;
  String? _offlineUrl;
  Future<OfflineFileLease?>? _offlineFile;
  OfflineFileLease? _offlineLease;

  Future<OfflineFileLease?> _loadOffline(String url) async {
    final lease = await OfflineFiles.instance.acquire(Uri.parse(url));
    if (!mounted || _offlineUrl != url) {
      await lease?.release();
      return null;
    }
    await _offlineLease?.release();
    _offlineLease = lease;
    return lease;
  }

  @override
  void initState() {
    super.initState();
    _watchAccount();
  }

  void _watchAccount() {
    final private = widget.candidates.any(
      (v) => isAccountResource(Uri.parse(v)),
    );
    if (private && _accountChanges == null) {
      _accountChanges = AccountResources.instance.changes.listen((_) {
        _vectorGeneration++;
        unawaited(_vectorLease?.release());
        _vectorLease = null;
        if (mounted) {
          setState(() {
            _index = 0;
            _vectorUrl = null;
            _chosenUrl = null;
          });
        }
      });
    } else if (!private && _accountChanges != null) {
      unawaited(_accountChanges!.cancel());
      _accountChanges = null;
    }
  }

  Future<File> _privateVector(String url) async {
    final generation = ++_vectorGeneration,
        lease = await AccountResources.instance.acquire(Uri.parse(url));
    if (!mounted || generation != _vectorGeneration) {
      await lease.release();
      throw StateError('image_changed');
    }
    await _vectorLease?.release();
    _vectorLease = lease;
    return lease.file;
  }

  Widget _empty() => widget.naturalHeight
      ? const AspectRatio(aspectRatio: 1)
      : const SizedBox.expand();

  @override
  void dispose() {
    _offlineUrl = null;
    unawaited(_offlineLease?.release());
    _retry?.cancel();
    _vectorGeneration++;
    unawaited(_vectorLease?.release());
    unawaited(_accountChanges?.cancel());
    super.dispose();
  }

  @override
  void didUpdateWidget(AppImage old) {
    super.didUpdateWidget(old);
    _watchAccount();
    if (!listEquals(old.candidates, widget.candidates)) {
      _index = 0;
      _vectorGeneration++;
      _vectorUrl = null;
      unawaited(_vectorLease?.release());
      _vectorLease = null;
    }
  }

  Widget _failed(String url, Object error, {int? epoch}) {
    if (isAccountResource(Uri.parse(url))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _chosenUrl == url &&
            epoch == AccountResources.instance.epoch) {
          _chosenUrl = null;
          setState(() => _index++);
        }
      });
      return widget.placeholder ?? _empty();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (error is HttpExceptionWithStatus &&
          const {404, 410}.contains(error.statusCode)) {
        _missing.add(url);
      } else {
        _retryAfter[url] = DateTime.now().add(const Duration(seconds: 30));
        if (mounted) {
          _retry ??= Timer(const Duration(seconds: 31), () {
            _retry = null;
            _vectorUrl = null;
            if (mounted) setState(() => _index = 0);
          });
        }
      }
      if (mounted) setState(() {});
    });
    return _empty();
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.localized
        ? AppScope.maybeOf(context)?.text.locale
        : null;
    final candidates = [
      for (final source in widget.candidates)
        for (final url
            in locale == null
                ? [source]
                : localeImageCandidates(source, locale))
          if (!_missing.contains(url) &&
              !(_retryAfter[url]?.isAfter(DateTime.now()) ?? false))
            url,
    ];
    if (_index >= candidates.length) {
      return widget.placeholder ?? _empty();
    }
    final local = candidates
        .where((url) => OfflineFiles.instance.contains(Uri.parse(url)))
        .firstOrNull;
    final url = local ?? candidates[_index];
    _chosenUrl = url;
    final private = isAccountResource(Uri.parse(url)),
        epoch = private ? AccountResources.instance.epoch : 0;
    if (local != null) {
      if (_offlineUrl != url) {
        _offlineUrl = url;
        _offlineFile = _loadOffline(url);
      }
      return FutureBuilder<OfflineFileLease?>(
        future: _offlineFile,
        builder: (context, snapshot) {
          final file = snapshot.data?.file;
          if (file == null) return widget.placeholder ?? _empty();
          if (Uri.parse(url).path.toLowerCase().endsWith('.svg')) {
            return SvgPicture.file(
              file,
              fit: widget.fit,
              alignment: widget.alignment,
              width: double.infinity,
              height: widget.naturalHeight ? null : double.infinity,
            );
          }
          return LayoutBuilder(
            builder: (context, constraints) => Image.file(
              file,
              cacheWidth: constraints.hasBoundedWidth
                  ? (constraints.maxWidth *
                            MediaQuery.devicePixelRatioOf(context))
                        .round()
                        .clamp(1, 8192)
                  : null,
              fit: widget.fit,
              alignment: widget.alignment,
              width: double.infinity,
              height: widget.naturalHeight ? null : double.infinity,
            ),
          );
        },
      );
    }
    if (Uri.tryParse(url)?.path.toLowerCase().endsWith('.svg') == true) {
      if (_vectorUrl != url) {
        _vectorUrl = url;
        _vectorFile = private
            ? _privateVector(url)
            : artworkCache.getSingleFile(url);
      }
      return FutureBuilder<File>(
        key: ValueKey((url, epoch)),
        future: _vectorFile,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _failed(url, snapshot.error!, epoch: epoch);
          }
          final file = snapshot.data;
          if (file == null) return _empty();
          CacheStorage.instance.scheduleTrim();
          return SvgPicture.file(
            file,
            key: ValueKey(url),
            fit: widget.fit,
            alignment: widget.alignment,
            width: double.infinity,
            height: widget.naturalHeight ? null : double.infinity,
            placeholderBuilder: (_) => _empty(),
            errorBuilder: (_, error, _) => _failed(url, error, epoch: epoch),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        // Collapsing layouts can otherwise request a 1-pixel-wide decode,
        // whose aspect-ratio-derived height can round down to zero.
        if (constraints.hasBoundedWidth && constraints.maxWidth * ratio < 2) {
          return _empty();
        }
        final width = constraints.hasBoundedWidth
            ? (constraints.maxWidth * ratio).round().clamp(1, 8192)
            : null;
        if (private) {
          return Image(
            image: ResizeImage.resizeIfNeeded(
              width,
              null,
              AccountImageProvider(Uri.parse(url), epoch),
            ),
            fit: widget.fit,
            alignment: widget.alignment,
            width: double.infinity,
            height: widget.naturalHeight ? null : double.infinity,
            frameBuilder: (context, child, frame, sync) =>
                frame == null ? _empty() : child,
            errorBuilder: (_, error, _) => _failed(url, error, epoch: epoch),
          );
        }
        return CachedNetworkImage(
          key: ValueKey(url),
          imageUrl: url,
          imageBuilder: (context, provider) {
            CacheStorage.instance.scheduleTrim();
            return Image(
              image: ResizeImage.resizeIfNeeded(width, null, provider),
              fit: widget.fit,
              alignment: widget.alignment,
              width: double.infinity,
              height: widget.naturalHeight ? null : double.infinity,
            );
          },
          cacheManager: artworkCache,
          fit: widget.fit,
          alignment: widget.alignment,
          width: double.infinity,
          height: widget.naturalHeight ? null : double.infinity,
          memCacheWidth: width,
          fadeInDuration: const Duration(milliseconds: 120),
          fadeOutDuration: Duration.zero,
          placeholder: (_, _) => _empty(),
          errorWidget: (_, _, error) => _failed(url, error, epoch: epoch),
        );
      },
    );
  }
}
