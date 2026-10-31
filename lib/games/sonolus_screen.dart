import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/net.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/shapes.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';

const _serverLink = 'https://open.sonolus.com/haneoka.org';
const _host = 'haneoka.org';
const _sonolusLocale = {
  'zh-CN': 'zhs',
  'zh-TW': 'zht',
  'ja': 'ja',
  'en': 'en',
  'ko': 'ko',
};

/// The server's resources are site-relative (`/sonolus/repository/…`).
String _absolute(String url) =>
    url.startsWith('/') ? 'https://haneoka.org$url' : url;

class _Item {
  const _Item(this.name, this.title, this.subtitle, this.image, this.rating);
  final String name;
  final String title;
  final String subtitle;
  final String image;
  final num? rating;
}

typedef _Section = ({String title, List<_Item> items});

/// The site's Sonolus server: what it serves, opened in the Sonolus app
/// (`sonolus-hub`).
class SonolusScreen extends StatefulWidget {
  const SonolusScreen({super.key});
  @override
  State<SonolusScreen> createState() => _SonolusScreenState();
}

class _SonolusScreenState extends State<SonolusScreen> {
  Future<(String, List<_Section>, List<_Section>)>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _load();
  }

  String _localize(Object? value, String locale) {
    final text = '${value ?? ''}';
    if (!text.startsWith('##LOCALIZE:')) return text;
    try {
      final table = (jsonDecode(text.substring('##LOCALIZE:'.length)) as Map)
          .cast<String, Object?>();
      return '${table[_sonolusLocale[locale] ?? 'en'] ?? table['en'] ?? table.values.firstOrNull ?? ''}';
    } catch (_) {
      return text;
    }
  }

  Future<(String, List<_Section>, List<_Section>)> _load() async {
    final locale = AppScope.of(context).text.locale;
    Future<Map> read(String path) async {
      final response = await netClient.get(
        Uri.parse('https://haneoka.org$path'),
        headers: {'accept': 'application/json'},
      );
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    }

    List<_Section> sections(Map document, String image) => [
      for (final section
          in (document['sections'] as List? ?? const []).whereType<Map>())
        (
          title: '${section['title'] ?? ''}',
          items: [
            for (final item
                in (section['items'] as List? ?? const []).whereType<Map>())
              _Item(
                '${item['name'] ?? ''}',
                _localize(item['title'], locale),
                _localize(item['artists'] ?? item['subtitle'], locale),
                _absolute('${(item[image] as Map?)?['url'] ?? ''}'),
                item['rating'] as num?,
              ),
          ],
        ),
    ];
    final [info, levels, playlists] = await Future.wait([
      read('/sonolus/info'),
      read('/sonolus/levels/info'),
      read('/sonolus/playlists/info'),
    ]);
    return (
      _absolute('${(info['banner'] as Map?)?['url'] ?? ''}'),
      sections(levels, 'cover'),
      sections(playlists, 'thumbnail'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    String text(String key, String fallback) =>
        t('catalog.sonolus.$key', fallback);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    String label(String title) => switch (title) {
      '#RANDOM' => text('random', 'Random'),
      '#NEWEST' => text('newest', 'Newest'),
      _ => _localize(title, t.locale),
    };
    Widget grid(String type, _Section section) => Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ShapedIcon(
                shape: MaterialShapes.cookie9Sided,
                size: 36,
                child: Icon(
                  type == 'levels'
                      ? Symbols.music_note_rounded
                      : Symbols.queue_music_rounded,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${type == 'levels' ? text('levels', 'Charts') : text('playlists', 'Playlists')} / ${label(section.title)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = ((constraints.maxWidth + 8) / 168).floor().clamp(
                2,
                6,
              );
              final width =
                  (constraints.maxWidth - 8 * (columns - 1)) / columns;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in section.items)
                    SizedBox(
                      width: width,
                      child: Tile(
                        title: item.title,
                        subtitle: item.subtitle,
                        images: [if (item.image.isNotEmpty) item.image],
                        aspectRatio: 1,
                        placeholder: Symbols.album_rounded,
                        marks: [
                          if (item.rating != null)
                            TileMark.text(
                              MarkAt.bottomStart,
                              'Lv.${item.rating}',
                            ),
                        ],
                        onTap: () => launchUrl(
                          Uri.parse(
                            '$_serverLink/$type/${Uri.encodeComponent(item.name)}',
                          ),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
    return ShellPage(
      title: text('title', 'Sonolus'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          final data = snapshot.data;
          return ListView(
            padding: pagePadding(context),
            children: [
              Material(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Corner.extraLarge),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // `height="320"` on the site's image wins over its
                    // 3:1 ratio: a 320-high band, cropped to cover.
                    SizedBox(
                      height: 320,
                      child: data == null || data.$1.isEmpty
                          ? ColoredBox(color: scheme.surfaceContainerHighest)
                          : AppImage(
                              candidates: [data.$1],
                              fit: BoxFit.cover,
                              localized: false,
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.asset(
                              'assets/settings/sonolus-icon.png',
                              width: 40,
                              height: 40,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(Corner.small),
                            ),
                            child: Text(
                              _host,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: text('copy', 'Copy server address'),
                            onPressed: () {
                              Clipboard.setData(
                                const ClipboardData(text: _host),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(text('copied', 'Copied')),
                                ),
                              );
                            },
                            icon: const Icon(Symbols.content_copy_rounded),
                          ),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () => launchUrl(
                                Uri.parse(_serverLink),
                                mode: LaunchMode.externalApplication,
                              ),
                              icon: const Icon(
                                Symbols.open_in_new_rounded,
                                size: 18,
                              ),
                              label: Text(text('open', 'Open in Sonolus')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (data == null)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: snapshot.hasError
                        ? FilledButton.tonal(
                            onPressed: () => setState(() => _data = _load()),
                            child: Text(t('common.actions.retry', 'Retry')),
                          )
                        : const CircularProgressIndicator(),
                  ),
                )
              else ...[
                for (final section in data.$2) grid('levels', section),
                for (final section in data.$3) grid('playlists', section),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: FilledButton.tonalIcon(
                      onPressed: () => setState(() => _data = _load()),
                      icon: const Icon(Symbols.shuffle_rounded, size: 18),
                      label: Text(text('shuffle', 'Shuffle')),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
