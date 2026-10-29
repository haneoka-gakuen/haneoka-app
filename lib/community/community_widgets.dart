import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../shell/links.dart';
import '../ui/app_image.dart';
import '../ui/theme.dart';
import 'community_time.dart';
import 'markup.dart';

const communityOrigin = 'https://haneoka.org';
final communityDataRevision = ValueNotifier<int>(0);
void invalidateCommunityData() => communityDataRevision.value++;

typedef Json = Map<String, Object?>;

Json jsonMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const <String, Object?>{};
List<Json> jsonList(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map) item.cast<String, Object?>(),
];

/// A community API read or write as the signed-in reader, when there is one.
Future<Json> communityRequest(
  String method,
  String path, {
  Object? body,
  Map<String, String> headers = const {},
}) async => jsonMap(
  await HaneokaAccount.instance.request(
    method,
    path,
    body: body,
    headers: headers,
  ),
);

String absoluteUrl(String path) =>
    path.startsWith('/') ? '$communityOrigin$path' : path;

/// `community.page.*` labels, as the website words them.
String communityLabel(
  BuildContext context,
  String key,
  String fallback, [
  Map<String, Object?> values = const {},
]) => AppScope.of(context).text('community.page.$key', fallback, values);

/// An image or video attachment's media, or a profile post's cover
/// (`communityPostMedia`).
List<Json> postMedia(Json post) {
  if (post['attachments'] is List) {
    return [
      for (final item in jsonList(post['attachments']))
        if (RegExp(r'^(image|video)/').hasMatch('${item['mediaType']}')) item,
    ];
  }
  return switch (post['coverUrl']) {
    final String url when url.isNotEmpty => [
      {
        'contentUrl': url,
        'width': post['coverWidth'],
        'height': post['coverHeight'],
      },
    ],
    _ => const [],
  };
}

/// The smallest rendition of an attachment (`communityMediaThumbnail`).
String mediaThumbnail(Json media) =>
    [
      media['thumbnailUrl'],
      media['posterUrl'],
      media['previewUrl'],
      media['contentUrl'],
    ].whereType<String>().where((v) => v.trim().isNotEmpty).firstOrNull ??
    '';

/// Width over height, kept between 0.6 and 1.8 (`communityImageRatio`).
double mediaRatio(Json media, [double fallback = 4 / 5]) {
  final width = ((media['displayWidth'] ?? media['width']) as num?) ?? 0;
  final height = ((media['displayHeight'] ?? media['height']) as num?) ?? 0;
  return width > 0 && height > 0
      ? (width / height).clamp(0.6, 1.8).toDouble()
      : fallback;
}

String authorName(BuildContext context, Json record) {
  final display = jsonMap(record['author'])['displayName'];
  return switch ((display, record['authorName'])) {
    (final String name, _) when name.isNotEmpty => name,
    (_, final String name) when name.isNotEmpty => name,
    _ => communityLabel(context, 'member', 'Member'),
  };
}

/// A member's avatar: their image, or the first letter of their name.
class CommunityAvatar extends StatelessWidget {
  const CommunityAvatar({
    super.key,
    required this.image,
    required this.name,
    this.size = 40,
  });
  final Object? image;
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = image is String && (image as String).isNotEmpty
        ? absoluteUrl(image as String)
        : null;
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        color: scheme.secondaryContainer,
        child: url != null
            ? AppImage(candidates: [url], fit: BoxFit.cover, localized: false)
            : Text(
                name.isEmpty ? '?' : name.characters.first,
                style: TextStyle(
                  fontSize: size * 0.42,
                  color: scheme.onSecondaryContainer,
                ),
              ),
      ),
    );
  }
}

/// A forum's name in the reader's language, with the forum icon.
class ForumLabel extends StatelessWidget {
  const ForumLabel({super.key, required this.forum});
  final Json forum;
  @override
  Widget build(BuildContext context) {
    final locale = AppScope.of(context).text.locale;
    final names = jsonMap(forum['names']);
    final name =
        '${names[locale] ?? names['en'] ?? names.values.firstOrNull ?? forum['slug'] ?? ''}';
    if (name.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Symbols.forum_rounded, size: 18, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// A game sticker from a `server:id:language` token (`community-sticker`).
class CommunitySticker extends StatefulWidget {
  const CommunitySticker({
    super.key,
    required this.token,
    required this.label,
    this.size = 48,
  });
  final String token;
  final String label;
  final double size;
  @override
  State<CommunitySticker> createState() => _CommunityStickerState();
}

class _CommunityStickerState extends State<CommunitySticker> {
  Future<List<String>>? _sources;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sources ??= _resolve();
  }

  /// `stampSources`: the reader's language, then Japanese, then any.
  Future<List<String>> _resolve() async {
    final state = AppScope.of(context);
    final parts = widget.token.split(':');
    final language = parts.length > 2 ? parts[2] : state.text.locale;
    final key = switch (language) {
      'zh-CN' => 'zh-Hans',
      'zh-TW' => 'zh-Hant',
      _ => language,
    };
    for (final server in {parts.first, state.server, 'intl', 'jp'}) {
      if (server != 'jp' && server != 'intl') continue;
      try {
        final catalog = jsonMap(await state.apiFor(server).catalog('stamps'));
        final stamp = jsonMap(catalog[parts[1]]);
        if (stamp.isEmpty) continue;
        final source = '${stamp['image'] ?? ''}';
        final variants = jsonMap(jsonMap(stamp['imageVariants'])[source]);
        final sources = <String>{
          for (final value in [
            variants[key],
            variants['ja'],
            source,
            ...variants.values,
          ])
            if (value is String && value.startsWith('/assets/')) value,
        };
        if (sources.isNotEmpty) {
          return [for (final s in sources) absoluteUrl(s)];
        }
      } catch (_) {}
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: FutureBuilder(
      future: _sources,
      builder: (context, snapshot) {
        final sources = snapshot.data ?? const <String>[];
        if (sources.isEmpty) {
          return snapshot.connectionState == ConnectionState.done
              ? Text(widget.label, style: Theme.of(context).textTheme.bodySmall)
              : const SizedBox.shrink();
        }
        return Tooltip(
          message: widget.label,
          child: AppImage(
            candidates: sources,
            fit: BoxFit.contain,
            localized: false,
          ),
        );
      },
    ),
  );
}

/// A post or comment body: the website's markup rendered as HTML, with game
/// stickers, spoilers and links that stay in the app.
class CommunityBody extends StatelessWidget {
  const CommunityBody({
    super.key,
    required this.source,
    this.style,
    this.allowStickers = true,
  });
  final String source;
  final TextStyle? style;
  final bool allowStickers;

  @override
  Widget build(BuildContext context) {
    final locale = AppScope.of(context).text.locale;
    final html = communityMarkup(
      source,
      spoiler: communityLabel(context, 'spoiler', 'Spoiler'),
      locale: locale,
      allowStickers: allowStickers,
    );
    return _Html(
      html: html,
      style: style ?? Theme.of(context).textTheme.bodyLarge,
    );
  }
}

class _Html extends StatelessWidget {
  const _Html({required this.html, required this.style});
  final String html;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String hex(Color color) =>
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return HtmlWidget(
      html,
      textStyle: style,
      onTapUrl: (url) => openLink(context, url),
      customStylesBuilder: (element) => switch (element.localName) {
        'p' => {'margin': '0 0 0.6em 0'},
        'blockquote' => {
          'margin': '0 0 0.6em 0',
          'padding': '0 0 0 12px',
          'border-left': '3px solid ${hex(scheme.outlineVariant)}',
          'color': hex(scheme.onSurfaceVariant),
        },
        'pre' => {
          'background-color': hex(scheme.surfaceContainerHighest),
          'padding': '8px 12px',
          'border-radius': '8px',
        },
        'mark' => {
          'background-color': hex(scheme.tertiaryContainer),
          'color': hex(scheme.onTertiaryContainer),
        },
        'a' => {
          'color': hex(scheme.primary),
          'text-decoration': 'underline',
          'text-decoration-thickness': '1.5px',
        },
        _ => null,
      },
      customWidgetBuilder: (element) {
        if (element.localName == 'community-sticker') {
          return InlineCustomWidget(
            alignment: PlaceholderAlignment.middle,
            child: CommunitySticker(
              token: element.attributes['token'] ?? '',
              label: element.attributes['label'] ?? '',
            ),
          );
        }
        if (element.localName == 'details') {
          final summary = element.children
              .where((e) => e.localName == 'summary')
              .firstOrNull;
          final inner = element.children
              .where((e) => e.localName == 'div')
              .firstOrNull;
          return _Spoiler(
            label: summary?.text ?? '',
            child: _Html(html: inner?.innerHtml ?? '', style: style),
          );
        }
        return null;
      },
    );
  }
}

class _Spoiler extends StatefulWidget {
  const _Spoiler({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  State<_Spoiler> createState() => _SpoilerState();
}

class _SpoilerState extends State<_Spoiler> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Corner.small),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _open
                        ? Symbols.visibility_off_rounded
                        : Symbols.visibility_rounded,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(widget.label),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

/// The time, edit mark and country under a post or comment.
class CommunityContext extends StatelessWidget {
  const CommunityContext({super.key, required this.record});
  final Json record;
  @override
  Widget build(BuildContext context) {
    final locale = AppScope.of(context).text.locale;
    final theme = Theme.of(context);
    final time = formatCommunityTime(record['createdAt'], locale);
    final edited = isEdited(record['createdAt'], record['lastEditedAt'])
        ? formatCommunityTime(record['lastEditedAt'], locale)
        : null;
    final place = communityLocation(record['ipLocation'], locale);
    final status = record['moderationStatus'];
    final parts = [
      if (time != null) time.text,
      if (edited != null)
        '${communityLabel(context, 'lastEdited', 'Last edited')} ${edited.text}',
      if (place.isNotEmpty)
        '${communityLabel(context, 'ipLocation', 'IP location')}: $place',
      if (status != null && status != 'allow')
        communityLabel(
          context,
          status == 'block' ? 'moderationBlocked' : 'moderationPending',
          'Reviewing',
        ),
    ];
    return Tooltip(
      message: time?.title ?? '',
      child: Wrap(
        spacing: 12,
        children: [
          for (final part in parts)
            Text(
              part,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
