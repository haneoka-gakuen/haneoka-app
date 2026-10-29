import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;

import '../core/document_cache.dart';
import '../core/page_data.dart' show pageDocumentKey;

Future<List<Map<String, Object?>>> hubData(String origin, String path) {
  final uri = Uri.parse(origin).resolve(path);
  return publicDocumentCache.read<List<Map<String, Object?>>>(
    key: pageDocumentKey(uri),
    decodeVariant: 'destination-hub.v1',
    decode: _decodeHub,
  );
}

Future<List<Map<String, Object?>>> _decodeHub(
  Uint8List bytes,
) => Isolate.run(() {
  final document = html.parse(utf8.decode(bytes));
  final tiles = document.querySelectorAll('.destination-hub__tile');
  if (tiles.isEmpty) throw const FormatException('destination-hub');
  return [
    for (final tile in tiles)
      {
        'visual': tile.classes
            .firstWhere((value) => value.startsWith('destination-hub__tile--'))
            .replaceFirst('destination-hub__tile--', ''),
        'columns': int.parse(
          tile.classes
              .firstWhere((v) => RegExp(r'--c\d+$').hasMatch(v))
              .split('--c')
              .last,
        ),
        'rows': int.parse(
          tile.classes
              .firstWhere((v) => RegExp(r'--r\d+$').hasMatch(v))
              .split('--r')
              .last,
        ),
        'links': [
          for (final link
              in tile.attributes.containsKey('data-hub-route')
                  ? [tile]
                  : tile.querySelectorAll('[data-hub-route]'))
            {
              'route': link.attributes['data-hub-route'],
              'label': link
                  .querySelector(
                    link == tile
                        ? '.destination-hub__tile-label [data-i18n]'
                        : '[data-i18n]',
                  )
                  ?.attributes['data-i18n'],
            },
        ],
        'images': [
          for (final image in tile.querySelectorAll(
            '.destination-hub__picture img, .destination-hub__score-media > img:first-child, .destination-hub__puzzle > img, .destination-hub__guess > img',
          ))
            image.attributes['src'],
        ],
        'team': [
          for (final slot in tile.querySelectorAll('.destination-hub__slot'))
            {
              'leader': slot.classes.contains('destination-hub__slot--leader'),
              'member': [
                for (final image in slot.querySelectorAll(
                  '.destination-hub__member > img',
                ))
                  image.attributes['src'],
              ],
              'snap': [
                for (final image in slot.querySelectorAll(
                  '.destination-hub__snap > img',
                ))
                  image.attributes['src'],
              ],
            },
        ],
        'friendship': {
          for (final name in ['board', 'lead', 'logo', 'arrow'])
            name: tile
                .querySelector('.destination-hub__bond-$name')
                ?.attributes['src'],
          'portraits': [
            for (final image in tile.querySelectorAll(
              '.destination-hub__bond-avatar',
            ))
              image.attributes['src'],
          ],
          'slots': [
            for (final slot in tile.querySelectorAll(
              '.destination-hub__bond-partner',
            ))
              slot.attributes['style'],
          ],
        },
      },
  ];
});
