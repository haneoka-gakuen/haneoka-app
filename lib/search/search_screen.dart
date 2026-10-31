import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/net.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';

/// The website's search scopes (`SEARCH_SCOPES`).
const _scopes = ['all', 'catalog', 'stories', 'help', 'community'];
const _scopeLabels = {
  'all': 'common.states.all',
  'catalog': 'navigation.catalog',
  'stories': 'navigation.stories',
  'help': 'navigation.help',
  'community': 'navigation.community',
};

const _browse = <(String, String, IconData)>[
  ('catalog', 'navigation.catalog', Symbols.category_rounded),
  ('songs', 'navigation.songs', Symbols.music_note_rounded),
  ('member-cards', 'navigation.memberCards', Symbols.style_rounded),
  ('support-cards', 'navigation.supportCards', Symbols.photo_library_rounded),
  ('characters', 'navigation.characters', Symbols.groups_rounded),
  ('events', 'navigation.events', Symbols.event_rounded),
  ('gacha', 'navigation.gacha', Symbols.redeem_rounded),
  ('stories', 'navigation.stories', Symbols.auto_stories_rounded),
  ('community', 'navigation.community', Symbols.forum_rounded),
];

class _CommunityResults {
  const _CommunityResults(this.posts, this.nextCursor);
  final List<Map> posts;
  final String? nextCursor;
}

/// Search (`global-search`): the catalogue and stories through the full-text
/// service, and community posts.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  Future<Map<String, Object?>>? _hits;
  String _kind = '';
  int _limit = 30;
  List<String> _recent = const [];
  static const _recentKey = 'haneoka.search.recent.v1';
  String _query = '';
  String _scope = 'all';
  Future<_CommunityResults>? _posts;
  Object? _dataKey;
  Timer? _searchTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = AppScope.of(context).publicDataKey;
    if (_dataKey != key) {
      _dataKey = key;
      _runCatalog();
      _posts = _query.isEmpty || _query.length > 100
          ? null
          : _community(_query);
    }
  }

  @override
  void initState() {
    super.initState();
    _readRecent();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }

  Future<Map<String, Object?>> _catalog(String query) async {
    final state = AppScope.of(context);
    final uri = Uri.parse(state.api.origin)
        .resolve('/api/v1/search')
        .replace(
          queryParameters: {
            'q': query,
            'server': state.server,
            'locale': state.text.locale,
            'limit': '$_limit',
            if (_scope == 'catalog' || _scope == 'stories') 'section': _scope,
            if (_kind.isNotEmpty) 'kind': _kind,
          },
        );
    final response = await netClient.get(uri);
    if (response.statusCode != 200) {
      throw HttpException('${response.statusCode}');
    }
    return (jsonDecode(utf8.decode(response.bodyBytes)) as Map)
        .cast<String, Object?>();
  }

  void _runCatalog() {
    _hits = _query.isEmpty || _query.length > 200 ? null : _catalog(_query);
  }

  Future<void> _readRecent() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final value = jsonDecode(prefs.getString(_recentKey) ?? '[]');
      if (mounted && value is List) {
        setState(() => _recent = value.whereType<String>().toList());
      }
    } catch (_) {}
  }

  Future<void> _writeRecent(List<String> values) async {
    final next = values.take(10).toList();
    setState(() => _recent = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_recentKey, jsonEncode(next));
  }

  void _remember(String query) {
    if (query.length < 2) return;
    _writeRecent([query, ..._recent.where((value) => value != query)]);
  }

  /// Search text with its `<mark>` matches highlighted.
  TextSpan _marked(String source, TextStyle? style, Color mark) {
    final spans = <TextSpan>[];
    String plain(String value) => value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&');
    var at = 0;
    for (final match in RegExp('<mark>(.*?)</mark>').allMatches(source)) {
      if (match.start > at) {
        spans.add(TextSpan(text: plain(source.substring(at, match.start))));
      }
      spans.add(
        TextSpan(
          text: plain(match[1]!),
          style: TextStyle(color: mark, fontWeight: FontWeight.w700),
        ),
      );
      at = match.end;
    }
    if (at < source.length) {
      spans.add(TextSpan(text: plain(source.substring(at))));
    }
    return TextSpan(style: style, children: spans);
  }

  Future<_CommunityResults> _community(String query, {String? cursor}) async {
    final state = AppScope.of(context);
    final uri = Uri.parse(state.api.origin)
        .resolve('/api/v1/community/posts')
        .replace(
          queryParameters: {
            'q': query,
            'scope': 'latest',
            'order': 'relevance',
            'state': 'active',
            'limit': '12',
            'cursor': ?cursor,
            'server': state.server,
            'locale': state.text.locale,
          },
        );
    final response = await netClient
        .get(uri)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final data = body as Map;
    return _CommunityResults(
      (data['posts'] as List? ?? const []).whereType<Map>().toList(),
      data['nextCursor'] as String?,
    );
  }

  Future<_CommunityResults> _moreCommunity(
    _CommunityResults current,
    String query,
  ) async {
    final next = await _community(query, cursor: current.nextCursor);
    final known = {for (final post in current.posts) '${post['id']}'};
    return _CommunityResults([
      ...current.posts,
      for (final post in next.posts)
        if (known.add('${post['id']}')) post,
    ], next.nextCursor);
  }

  void _search(String value, {bool immediate = false}) {
    _searchTimer?.cancel();
    void apply() {
      if (!mounted) return;
      final query = value.trim();
      if (_query == query) return;
      setState(() {
        _query = query;
        _kind = '';
        _limit = 30;
        _runCatalog();
        if (immediate) _remember(query);
        _posts = query.isEmpty || query.length > 100 ? null : _community(query);
      });
    }

    if (immediate || value.trim().isEmpty) {
      apply();
    } else {
      _searchTimer = Timer(const Duration(milliseconds: 150), apply);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget empty(String text) => Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Text(
          text,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    Widget row(
      Widget? leading,
      String title,
      String subtitle,
      VoidCallback onTap,
    ) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Corner.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Corner.small),
              child: Container(
                width: 56,
                height: 56,
                color: scheme.surfaceContainerHighest,
                child: leading,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return ShellPage(
      title: t('common.actions.search', 'Search'),
      search: ShellSearch(
        label: t('common.actions.search', 'Search'),
        onChanged: _search,
        onSubmitted: (value) => _search(value, immediate: true),
      ),
      body: ListView(
        padding: pagePadding(context),
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final scope in _scopes)
                    ButtonSegment(
                      value: scope,
                      label: Text(t(_scopeLabels[scope]!, scope)),
                    ),
                ],
                selected: {_scope},
                onSelectionChanged: (value) => setState(() {
                  _scope = value.single;
                  _kind = '';
                  _limit = 30;
                  _runCatalog();
                }),
              ),
            ),
          ),
          if (_query.isEmpty) ...[
            if (_recent.isNotEmpty) ...[
              Row(
                children: [
                  Expanded(child: heading(t('common.search.recent', 'Recent'))),
                  TextButton(
                    onPressed: () => _writeRecent(const []),
                    child: Text(t('common.actions.clear', 'Clear')),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final query in _recent)
                    InputChip(
                      label: Text(query),
                      onPressed: () => _search(query, immediate: true),
                      onDeleted: () => _writeRecent(
                        _recent.where((value) => value != query).toList(),
                      ),
                    ),
                ],
              ),
            ],
            heading(t('common.search.browse', 'Browse')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (path, key, icon) in _browse)
                  ActionChip(
                    avatar: Icon(icon, size: 18),
                    label: Text(t(key, key)),
                    onPressed: () => openLink(
                      context,
                      path == 'community'
                          ? '/${t.locale}/community/'
                          : '/${state.server}/${t.locale}/$path/',
                    ),
                  ),
              ],
            ),
          ],
          if (_query.isNotEmpty && _scope != 'community')
            FutureBuilder(
              future: _hits,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: TextButton.icon(
                      icon: const Icon(Symbols.refresh_rounded),
                      label: Text(t('common.actions.retry', 'Retry')),
                      onPressed: () => setState(_runCatalog),
                    ),
                  );
                }
                final data = snapshot.data;
                if (data == null) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final hits = (data['hits'] as List? ?? const [])
                    .whereType<Map>()
                    .where(
                      (hit) =>
                          _scope != 'help' || '${hit['url']}'.contains('/help'),
                    )
                    .toList();
                final kinds =
                    ((data['kinds'] as Map?) ?? const {}).entries.toList()
                      ..sort(
                        (a, b) => (b.value as num).compareTo(a.value as num),
                      );
                final total = (data['total'] as num?)?.toInt() ?? hits.length;
                if (hits.isEmpty) {
                  return _scope == 'all'
                      ? const SizedBox.shrink()
                      : empty(t('common.states.empty', 'Nothing found'));
                }
                String kindLabel(Object? kind) {
                  final key = '$kind'.replaceAllMapped(
                    RegExp('-([a-z])'),
                    (m) => m[1]!.toUpperCase(),
                  );
                  final value = t('navigation.$key', '');
                  return value.isEmpty ? '$kind' : value;
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    heading(
                      t('common.search.results', '{count} results', {
                        'count': total,
                      }),
                    ),
                    if (kinds.length > 1 || _kind.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final entry in kinds)
                            FilterChip(
                              label: Text(
                                '${kindLabel(entry.key)} ${entry.value}',
                              ),
                              selected: _kind == entry.key,
                              onSelected: (_) => setState(() {
                                _kind = _kind == entry.key
                                    ? ''
                                    : '${entry.key}';
                                _limit = 30;
                                _runCatalog();
                              }),
                            ),
                        ],
                      ),
                    for (final hit in hits)
                      InkWell(
                        onTap: () {
                          _remember(_query);
                          openLink(context, '${hit['url']}');
                        },
                        borderRadius: BorderRadius.circular(Corner.medium),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 4,
                          ),
                          child: Row(
                            spacing: 16,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  Corner.small,
                                ),
                                child: Container(
                                  width: 56,
                                  height: 56,
                                  color: scheme.surfaceContainerHighest,
                                  child: hit['image'] is String
                                      ? AppImage(
                                          candidates: [
                                            state.api
                                                .asset('${hit['image']}')
                                                .toString(),
                                          ],
                                          fit: BoxFit.cover,
                                        )
                                      : Icon(
                                          Symbols.search_rounded,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      kindLabel(hit['kind']),
                                      style: theme.textTheme.labelSmall,
                                    ),
                                    Text.rich(
                                      _marked(
                                        '${hit['title'] ?? ''}',
                                        theme.textTheme.titleSmall,
                                        scheme.primary,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if ('${hit['excerpt'] ?? ''}'.isNotEmpty)
                                      Text.rich(
                                        _marked(
                                          '${hit['excerpt']}',
                                          theme.textTheme.bodyMedium?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                          scheme.primary,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (hits.length < total && _limit < 50)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          icon: const Icon(Symbols.expand_more_rounded),
                          label: Text(
                            t('common.actions.loadMore', 'Load more'),
                          ),
                          onPressed: () => setState(() {
                            _limit = 50;
                            _runCatalog();
                          }),
                        ),
                      ),
                  ],
                );
              },
            ),
          if (_query.isNotEmpty && (_scope == 'all' || _scope == 'community'))
            FutureBuilder(
              future: _posts,
              builder: (context, snapshot) {
                final page = snapshot.data;
                final posts = page?.posts ?? const <Map>[];
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Center(
                    child: TextButton.icon(
                      icon: const Icon(Symbols.refresh_rounded),
                      label: Text(t('common.actions.retry', 'Retry')),
                      onPressed: () =>
                          setState(() => _posts = _community(_query)),
                    ),
                  );
                }
                if (posts.isEmpty) {
                  return _scope == 'community'
                      ? empty(t('common.states.empty', 'Nothing found'))
                      : const SizedBox.shrink();
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    heading(t('navigation.community', 'Community')),
                    for (final post in posts)
                      row(
                        switch ((post['attachments'] as List? ?? const [])
                            .whereType<Map>()
                            .firstOrNull?['contentUrl']) {
                          final String url => AppImage(
                            candidates: [state.api.asset(url).toString()],
                            fit: BoxFit.cover,
                            localized: false,
                          ),
                          _ => Icon(
                            Symbols.forum_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                        },
                        '${post['title'] ?? ''}',
                        [
                          '${post['excerpt'] ?? post['body'] ?? ''}'
                              .replaceAll(RegExp(r'\s+'), ' ')
                              .trim(),
                          '${post['authorName'] ?? ''}',
                        ].where((s) => s.isNotEmpty).join(' · '),
                        () => openLink(
                          context,
                          '/${t.locale}/community/posts/${post['id']}/',
                        ),
                      ),
                    if (page?.nextCursor != null)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          icon: const Icon(Symbols.expand_more_rounded),
                          label: Text(
                            t('common.actions.loadMore', 'Load more'),
                          ),
                          onPressed: () => setState(
                            () => _posts = _moreCommunity(page!, _query),
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
  }
}
