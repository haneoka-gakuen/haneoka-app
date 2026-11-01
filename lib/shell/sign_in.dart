import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:url_launcher/url_launcher.dart';

/// Provider sign-in in the system browser, where providers allow it: the
/// provider's page hands a one-time code back to the app (PKCE), and the page
/// exchanges code and verifier for its session cookie. Null when the reader
/// backs out.
Future<({String code, String verifier})?> signInWithProvider(
  Uri origin,
  String provider,
) async {
  final random = Random.secure();
  String token(int bytes) => base64Url
      .encode(List.generate(bytes, (_) => random.nextInt(256)))
      .replaceAll('=', '');
  final verifier = token(48), state = token(16);
  final challenge = base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
  final query = {'challenge': challenge, 'state': state, 'provider': provider};
  final returned = Completer<Uri>();
  HttpServer? loopback;
  StreamSubscription<Uri>? links;
  if (Platform.isAndroid || Platform.isIOS) {
    links = AppLinks().uriLinkStream.listen((uri) {
      if (uri.scheme == 'haneoka' &&
          uri.host == 'auth' &&
          !returned.isCompleted) {
        returned.complete(uri);
      }
    });
  } else {
    // Desktop builds receive the code on a loopback listener (RFC 8252).
    loopback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    query['redirect'] = 'http://127.0.0.1:${loopback.port}/auth';
    loopback.listen((request) async {
      if (request.uri.path != '/auth') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><meta charset="utf-8"><title>Haneoka</title>'
        '<body style="font:16px system-ui;text-align:center;padding:48px">'
        '&#10003;</body>',
      );
      await request.response.close();
      if (!returned.isCompleted) returned.complete(request.uri);
    });
  }
  try {
    final opened = await launchUrl(
      origin.replace(path: '/api/v1/account/app/oauth', queryParameters: query),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) return null;
    final result = await returned.future.timeout(const Duration(minutes: 10));
    final code = result.queryParameters['code'];
    if (result.queryParameters['state'] != state || code == null) return null;
    return (code: code, verifier: verifier);
  } on TimeoutException {
    return null;
  } finally {
    await links?.cancel();
    await loopback?.close(force: true);
  }
}
