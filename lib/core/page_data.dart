import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'document_cache.dart';

const _pageOrigin = String.fromEnvironment(
  'HANEOKA_API_ORIGIN',
  defaultValue: 'https://haneoka.org',
);
final _pageKeys = <PublicDocumentKey>{};

Stream<PublicDocumentChange> get publicPageDataChanges => publicDocumentCache
    .changes
    .where((change) => _pageKeys.contains(change.key));

PublicDocumentKey pageDocumentKey(Uri uri) {
  final key = PublicDocumentKey(
    uri: uri,
    server: uri.pathSegments.firstOrNull ?? '',
  );
  _pageKeys.remove(key);
  _pageKeys.add(key);
  while (_pageKeys.length > 128) {
    _pageKeys.remove(_pageKeys.first);
  }
  return key;
}

Future<Map<String, Object?>> _decodePage(
  Uint8List bytes,
  String scriptId,
  bool attribute,
) => Isolate.run(() {
  final html = utf8.decode(bytes);
  final selector = attribute
      ? '\\s${RegExp.escape(scriptId)}(?=[\\s=>])'
      : '\\sid=["\x27]${RegExp.escape(scriptId)}["\x27]';
  final match = RegExp(
    '<script[^>]*$selector[^>]*>([\\s\\S]*?)</script>',
    caseSensitive: false,
  ).firstMatch(html);
  if (match == null) throw const FormatException('page data');
  return (jsonDecode(match[1]!) as Map).cast<String, Object?>();
});

/// Generated pages and their decoded payloads share the public document cache.
Future<Map<String, Object?>> pageData(
  String path,
  String scriptId, {
  bool attribute = false,
}) {
  final uri = Uri.parse(_pageOrigin).resolve(path);
  return publicDocumentCache.read<Map<String, Object?>>(
    key: pageDocumentKey(uri),
    decodeVariant: 'page.v1.$attribute.$scriptId',
    decode: (bytes) => _decodePage(bytes, scriptId, attribute),
  );
}

Future<Map<String, Object?>?> entityPage(
  String server,
  String locale,
  String resource,
  String id,
) {
  final kind = resource == 'cards' ? 'member-cards' : resource;
  final path = '/$server/$locale/$kind/${Uri.encodeComponent(id)}/';
  return pageData(
    path,
    'catalog-page-$resource-$id',
  ).then<Map<String, Object?>?>((value) => value, onError: (_) => null);
}
