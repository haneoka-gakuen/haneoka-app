import '../core/site_date.dart';
import '../core/catalog_source.dart';
import '../core/api.dart';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/i18n.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/tile.dart';

typedef Announcement = Map<String, Object?>;

String _date(SiteText t, Object? seconds, {bool full = false}) {
  if (seconds is! num) return '';
  final at = DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
  final format = SiteDate.day(t.locale);
  return (full ? format.withTime() : format).format(at);
}

String _category(SiteText t, Object? category) => t(
  'home.announcements.categories.$category',
  t('home.announcements.title', 'Announcements'),
);

/// The game's announcements for the release server, newest first
/// (`fetchAnnouncements`, `sortAnnouncements`).
Future<List<Announcement>> fetchAnnouncements(
  AppState state, {
  HaneokaApi? api,
}) async {
  api ??= state.api;
  final value = await api.json(
    '/api/v1/announcements?server=${api.server}&locale=${state.text.locale}',
  );
  final list = [
    for (final entry
        in ((value as Map?)?['announcements'] as List? ?? const []))
      if (entry is Announcement) entry,
  ];
  list.sort((a, b) {
    final pinned =
        (b['pinned'] == true ? 1 : 0) - (a['pinned'] == true ? 1 : 0);
    if (pinned != 0) return pinned;
    final date = ((b['startAt'] as num?) ?? 0).compareTo(
      (a['startAt'] as num?) ?? 0,
    );
    return date != 0
        ? date
        : ((b['id'] as num?) ?? 0).compareTo((a['id'] as num?) ?? 0);
  });
  return list;
}

/// One announcement in a list (`announcementRow`): banner, date and
/// category, then the title over three lines.
class AnnouncementRow extends StatelessWidget {
  const AnnouncementRow({super.key, required this.entry, this.compact = false});
  final Announcement entry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final banner = entry['banner'];
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AnnouncementScreen(
            entry: entry,
            server: CatalogSourceScope.serverOf(context),
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 4 : 16,
          vertical: compact ? 6 : 12,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: compact ? 56 : 112,
                height: compact ? 32 : 64,
                color: scheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: banner is String
                    ? AppImage(
                        candidates: [
                          AppScope.of(context).api.asset(banner).toString(),
                        ],
                        localized: false,
                        fit: BoxFit.cover,
                        placeholder: Icon(
                          Symbols.campaign_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    : Icon(
                        Symbols.campaign_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        _date(t, entry['startAt']),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        _category(t, entry['category']),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (entry['pinned'] == true)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Symbols.push_pin_rounded,
                              size: 16,
                              color: scheme.primary,
                            ),
                            Text(
                              t('home.announcements.pinned', 'Pinned'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.primary,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${entry['title'] ?? ''}',
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: compact
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The announcements page (`announcement-feed`): every announcement for the
/// release server in a divided list.
class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});
  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  Future<List<Announcement>>? _entries;
  Object? _dataKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_dataKey != CatalogSourceScope.keyOf(context)) {
      _dataKey = CatalogSourceScope.keyOf(context);
      _entries = fetchAnnouncements(
        state,
        api: CatalogSourceScope.apiOf(context),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    return ShellPage(
      title: t('home.announcements.title', 'Announcements'),
      body: FutureBuilder(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton.tonalIcon(
                icon: const Icon(Symbols.refresh_rounded),
                label: Text(t('home.announcements.retry', 'Retry')),
                onPressed: () => setState(
                  () => _entries = fetchAnnouncements(
                    AppScope.of(context),
                    api: CatalogSourceScope.apiOf(context),
                  ),
                ),
              ),
            );
          }
          final entries = snapshot.data;
          if (entries == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (entries.isEmpty) {
            return Center(
              child: Text(
                t('home.announcements.empty', 'No announcements yet.'),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              final state = AppScope.of(context);
              final api = CatalogSourceScope.apiOf(context);
              await api.revalidate();
              if (!mounted) return;
              if (!context.mounted) return;
              final next = fetchAnnouncements(state, api: api);
              setState(() => _entries = next);
              await next;
            },
            child: ListView.separated(
              padding: pagePadding(context).copyWith(left: 0, right: 0),
              itemCount: entries.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (context, index) =>
                  AnnouncementRow(entry: entries[index]),
            ),
          );
        },
      ),
    );
  }
}

final _drop = [
  RegExp(r'<head[\s\S]*?</head>', caseSensitive: false),
  RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
  RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
];
final _presentation = RegExp(
  r'''\s(?:style|color|bgcolor)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)''',
  caseSensitive: false,
);

/// The announcement body without the game's own stylesheet, so its text
/// takes the app's colours (`announcementBodyFragment`).
String _body(String html) {
  var body = html;
  for (final pattern in _drop) {
    body = body.replaceAll(pattern, '');
  }
  return body.replaceAll(_presentation, '');
}

/// One announcement (`announcement-detail`): category and date, then the
/// game's own body.
class AnnouncementScreen extends StatefulWidget {
  const AnnouncementScreen({super.key, required this.entry, this.server});
  final Announcement entry;
  final String? server;
  @override
  State<AnnouncementScreen> createState() => _AnnouncementScreenState();
}

class _AnnouncementScreenState extends State<AnnouncementScreen> {
  Future<Announcement>? _detail;
  Object? _dataKey;

  Future<Announcement> _load(AppState state) async {
    final server = widget.server ?? CatalogSourceScope.serverOf(context);
    final document = await state
        .apiFor(server)
        .json(
          '/api/v1/announcements/${widget.entry['id']}?server=$server&locale=${state.text.locale}',
        );
    final value = document is Map ? document['announcement'] ?? document : null;
    if (value is! Map || value['id'] != widget.entry['id']) {
      throw const FormatException('Announcement detail identity');
    }
    return value.cast<String, Object?>();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_dataKey != CatalogSourceScope.keyOf(context)) {
      _dataKey = CatalogSourceScope.keyOf(context);
      _detail = _load(state);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FutureBuilder(
      future: _detail,
      builder: (context, snapshot) {
        final entry = {...widget.entry, ...?snapshot.data};
        final html = entry['html'];
        final image =
            entry['bodyImage'] is String &&
                (entry['bodyImage'] as String).isNotEmpty
            ? entry['bodyImage'] as String
            : null;
        final body = html is String ? _body(html) : '';
        return ShellPage(
          title:
              '${entry['title'] ?? t('home.announcements.title', 'Announcements')}',
          showBack: true,
          body: ListView(
            padding: pagePadding(context),
            children: [
              DetailSection(
                icon: Symbols.info_rounded,
                title: t(
                  'home.announcements.information',
                  'Announcement information',
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        Chip(label: Text(_category(t, entry['category']))),
                        if (entry['pinned'] == true)
                          Chip(
                            label: Text(
                              t('home.announcements.pinned', 'Pinned'),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SpecList(
                      facts: [
                        Fact(
                          t('home.announcements.published', 'Published'),
                          _date(t, entry['startAt'], full: true),
                        ),
                        if (entry['updatedAt'] is num &&
                            entry['updatedAt'] != entry['startAt'])
                          Fact(
                            t('home.announcements.updated', 'Updated'),
                            _date(t, entry['updatedAt'], full: true),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (image is String && !body.contains(image))
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AppImage(
                      candidates: [
                        AppScope.of(context).api.asset(image).toString(),
                      ],
                      localized: false,
                      naturalHeight: true,
                      placeholder: Text(
                        t(
                          'home.announcements.imageError',
                          'The announcement image could not be loaded.',
                        ),
                      ),
                    ),
                  ),
                ),
              if (snapshot.hasError)
                Center(
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Symbols.refresh_rounded),
                    label: Text(t('home.announcements.retry', 'Retry')),
                    onPressed: () =>
                        setState(() => _detail = _load(AppScope.of(context))),
                  ),
                )
              else if (snapshot.connectionState != ConnectionState.done &&
                  body.trim().isEmpty &&
                  image is! String)
                const Center(child: CircularProgressIndicator())
              else if (body.trim().isEmpty && image is! String)
                Text(
                  t(
                    'home.announcements.bodyUnavailable',
                    'The announcement content is unavailable.',
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else if (body.trim().isNotEmpty)
                HtmlWidget(
                  body,
                  baseUrl: Uri.parse(AppScope.of(context).api.origin),
                  textStyle: theme.textTheme.bodyLarge,
                  customStylesBuilder: (element) => element.localName == 'a'
                      ? {
                          'color':
                              '#${(scheme.primary.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}',
                          'text-decoration': 'underline',
                        }
                      : null,
                  // haneoka.org addresses open their native page.
                  onTapUrl: (url) => openLink(context, url),
                ),
            ],
          ),
        );
      },
    );
  }
}
