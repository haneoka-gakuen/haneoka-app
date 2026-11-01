import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../core/net.dart';

import '../core/account_resource.dart';

final _accountImageKeys = <AccountImageKey>{};
bool _watchingAccountImages = false;
void _watchAccountImages() {
  if (_watchingAccountImages) return;
  _watchingAccountImages = true;
  AccountResources.instance.changes.listen((_) {
    final previous = _accountImageKeys.toList();
    _accountImageKeys.clear();
    for (final key in previous) {
      PaintingBinding.instance.imageCache.evict(key);
    }
  });
}

@immutable
class AccountImageKey {
  const AccountImageKey(this.uri, this.epoch);
  final Uri uri;
  final int epoch;
  @override
  bool operator ==(Object other) =>
      other is AccountImageKey && other.uri == uri && other.epoch == epoch;
  @override
  int get hashCode => Object.hash(uri, epoch);
}

class AccountImageProvider extends ImageProvider<AccountImageKey> {
  const AccountImageProvider(this.uri, this.epoch);
  final Uri uri;
  final int epoch;
  @override
  Future<AccountImageKey> obtainKey(ImageConfiguration configuration) {
    _watchAccountImages();
    final key = AccountImageKey(uri, epoch);
    _accountImageKeys.add(key);
    return SynchronousFuture(key);
  }

  @override
  ImageStreamCompleter loadImage(
    AccountImageKey key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);
  Future<ui.Codec> _load(
    AccountImageKey key,
    ImageDecoderCallback decode,
  ) async {
    if (key.epoch != AccountResources.instance.epoch) {
      throw const AccountResourceCancelled();
    }
    final lease = await AccountResources.instance.acquire(key.uri);
    try {
      final codec = await decode(
        await ui.ImmutableBuffer.fromFilePath(lease.file.path),
      );
      if (key.epoch != AccountResources.instance.epoch) {
        codec.dispose();
        throw const AccountResourceCancelled();
      }
      return codec;
    } finally {
      await lease.release();
    }
  }
}

ImageProvider nativeNetworkImage(String url) =>
    isAccountResource(Uri.parse(url))
    ? AccountImageProvider(Uri.parse(url), AccountResources.instance.epoch)
    : CachedNetworkImageProvider(url, cacheManager: artworkCache);
