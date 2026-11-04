import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/retry.dart';

import 'system_proxy.dart';

/// The platform's own HTTP stack, as a browser uses it: Cronet on Android and
/// NSURLSession on Apple platforms speak HTTP/2 and HTTP/3 with Brotli, so
/// the dozens of artwork requests on a page share one connection instead of
/// each opening its own.
final http.Client netClient = _client();

/// File-cached resources share proxy routing and cancellation with other requests.
Future<http.StreamedResponse> sendFileRequest(http.BaseRequest request) {
  final client = netClient;
  return client is _AndroidSystemProxyClient
      ? client.sendFile(request)
      : client.send(request);
}

http.Client _androidDirectClient({bool fileTransfer = false}) {
  try {
    final engine = CronetEngine.build(
      cacheMode: fileTransfer ? CacheMode.disabled : CacheMode.memory,
      cacheMaxSize: fileTransfer ? 0 : 8 << 20,
      enableBrotli: true,
      enableHttp2: !fileTransfer,
      enableQuic: !fileTransfer,
      userAgent: 'haneoka-app',
    );
    return CronetClient.fromCronetEngine(engine, closeEngine: true);
  } catch (error) {
    debugPrint('Cronet unavailable; using Dart HTTP: $error');
    return IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..maxConnectionsPerHost = 12
        ..idleTimeout = const Duration(seconds: 30)
        ..userAgent = 'haneoka-app',
    );
  }
}

http.Client _client() {
  if (Platform.isAndroid) {
    return _AndroidSystemProxyClient(_androidDirectClient());
  }
  if (Platform.isIOS || Platform.isMacOS) {
    final config = URLSessionConfiguration.defaultSessionConfiguration()
      ..httpMaximumConnectionsPerHost = 8
      ..waitsForConnectivity = true;
    return CupertinoClient.fromSessionConfiguration(config);
  }
  return IOClient(
    HttpClient()
      ..maxConnectionsPerHost = 12
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'haneoka-app',
  );
}

/// Keep the multiplexed native stack for DIRECT and pool proxy connections.
final class _AndroidSystemProxyClient extends http.BaseClient {
  _AndroidSystemProxyClient(this._direct);

  final http.Client _direct;
  http.Client? _fileDirect;
  final _waiting = Queue<Completer<void>>();
  int _active = 0;
  bool _closed = false;
  final http.Client _proxied = IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'haneoka-app'
      ..findProxy = (uri) => systemProxyFor(uri).directive,
  );

  late final _proxyReads = RetryClient(
    _proxied,
    retries: 2,
    when: (_) => false,
    whenError: (error, _) {
      if (error is HandshakeException) {
        return error.message == 'Connection terminated during handshake';
      }
      if (error is SocketException) {
        return switch (error.osError?.errorCode) {
          // Android/Linux: EPIPE, ECONNABORTED, ECONNRESET.
          32 || 103 || 104 => true,
          _ => false,
        };
      }
      return false;
    },
    delay: (retry) => Duration(milliseconds: 200 * (retry + 1)),
  );

  Future<void> _acquire(Uri uri) {
    if (_closed) {
      return Future.error(http.ClientException('Client is closed', uri));
    }
    if (_active < 12) {
      _active++;
      return Future.value();
    }
    final waiting = Completer<void>();
    _waiting.addLast(waiting);
    return waiting.future;
  }

  void _release() {
    if (_closed) return;
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _send(request);

  Future<http.StreamedResponse> sendFile(http.BaseRequest request) =>
      _send(request, fileTransfer: true);

  Future<http.StreamedResponse> _send(
    http.BaseRequest request, {
    bool fileTransfer = false,
  }) async {
    if (_closed) throw http.ClientException('Client is closed', request.url);
    if (systemProxyFor(request.url).isDirect) {
      final client = fileTransfer
          ? (_fileDirect ??= _androidDirectClient(fileTransfer: true))
          : _direct;
      return client.send(request);
    }
    await _acquire(request.url);
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _release();
    }

    try {
      final client = request.method == 'GET' || request.method == 'HEAD'
          ? _proxyReads
          : _proxied;
      final response = await client.send(request);
      StreamSubscription<List<int>>? subscription;
      late final StreamController<List<int>> body;
      body = StreamController<List<int>>(
        sync: true,
        onListen: () {
          subscription = response.stream.listen(
            body.add,
            onError: (Object error, StackTrace stack) {
              release();
              body.addError(error, stack);
            },
            onDone: () {
              release();
              unawaited(body.close());
            },
          );
        },
        onPause: () => subscription?.pause(),
        onResume: () => subscription?.resume(),
        onCancel: () async {
          try {
            await subscription?.cancel();
          } finally {
            release();
          }
        },
      );
      return _ProxyStreamedResponse(body.stream, response);
    } catch (_) {
      release();
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final waiting in _waiting) {
      waiting.completeError(http.ClientException('Client is closed'));
    }
    _waiting.clear();
    _active = 0;
    _direct.close();
    _fileDirect?.close();
    _proxied.close();
    super.close();
  }
}

final class _ProxyStreamedResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _ProxyStreamedResponse(Stream<List<int>> body, http.StreamedResponse source)
    : url = source is http.BaseResponseWithUrl
          ? (source as http.BaseResponseWithUrl).url
          : source.request!.url,
      super(
        body,
        source.statusCode,
        contentLength: source.contentLength,
        request: source.request,
        headers: source.headers,
        isRedirect: source.isRedirect,
        persistentConnection: source.persistentConnection,
        reasonPhrase: source.reasonPhrase,
      );

  @override
  final Uri url;
}

/// Artwork on disk for a month, fetched through [netClient].
final CacheManager artworkCache = CacheManager(
  Config(
    'haneoka-artwork',
    // Disk capacity is managed by CacheStorage. Keep the library's own
    // count/age cleanup from imposing a hidden limit on unlimited mode.
    stalePeriod: const Duration(days: 3650),
    maxNrOfCacheObjects: 1 << 30,
    fileService: _ArtworkFileService(httpClient: netClient),
  ),
);

final class _ArtworkFileService extends HttpFileService {
  _ArtworkFileService({required super.httpClient});

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final response = await super.get(url, headers: headers);
    // CacheManager skips the body on errors and 304. Drain it so shared
    // connections remain available for catalogue and playback requests.
    if (response.statusCode != 200 && response.statusCode != 202) {
      await response.content.drain<void>();
    }
    return response;
  }
}
