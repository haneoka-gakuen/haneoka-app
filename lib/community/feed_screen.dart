import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/account_widgets.dart';
import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/account_dialog.dart';
import '../catalog/browse.dart' show BrowseFilterPanel;
import '../team_builder/widgets.dart' show Segmented, Choice;
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'community_widgets.dart';
import 'editor.dart';
import 'markup.dart';
import 'post_screen.dart';
import 'reactions.dart';
import 'actions.dart';
import 'user_screen.dart';

/// The website's community feeds (`/community/feeds`, `latest`, `following`,
/// `mine`, `bookmarks`): posts as cards in balanced columns.
class CommunityFeedScreen extends StatefulWidget {
  const CommunityFeedScreen({
    super.key,
    required this.scope,
    this.tag,
    this.forum,
  });

  /// `recommended`, `latest`, `following`, `mine` or `bookmarked`.
  final String scope;
  final String? tag;
  final Json? forum;

  @override
  State<CommunityFeedScreen> createState() => _CommunityFeedScreenState();
}

class _CommunityFeedScreenState extends State<CommunityFeedScreen> {
  final _items = <Json>[];
  String? _cursor;
  Object? _seed;
  bool _loading = false;
  bool _done = false;
  Object? _error;
  String _query = '';
  late String? _tagFilter = widget.tag;
  final _selectedTags = <String>{};
  String _tagMode = 'all', _postState = 'active';
  bool _invalidated = false;
  ModalRoute<void>? _filterRoute;
  void _changeFilters(VoidCallback change) {
    setState(change);
    _load(reset: true);
  }

  void _dataChanged() {
    if (mounted) setState(() => _invalidated = true);
  }

  int _generation = 0;
  Object? _queryKey;
  bool _sessionReady = false;

  bool get _needsSession =>
      const {'following', 'mine', 'bookmarked'}.contains(widget.scope);

  @override
  void initState() {
    super.initState();
    HaneokaAccount.instance.load().then((_) {
      _sessionReady = true;
      if (mounted) _load(reset: true);
    });
    HaneokaAccount.instance.addListener(_onAccount);
    communityDataRevision.addListener(_dataChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final key = (state.server, state.text.locale);
    final changed = _queryKey != null && _queryKey != key;
    _queryKey = key;
    if (changed && _sessionReady) _load(reset: true);
  }

  @override
  void dispose() {
    HaneokaAccount.instance.removeListener(_onAccount);
    communityDataRevision.removeListener(_dataChanged);
    final route = _filterRoute;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    super.dispose();
  }

  Object? _owner = HaneokaAccount.instance.user?['id'];
  void _onAccount() {
    final owner = HaneokaAccount.instance.user?['id'];
    if (owner == _owner) return;
    _owner = owner;
    _generation++;
    setState(() {
      _items.clear();
      _cursor = null;
      _seed = null;
      _loading = false;
      _done = false;
      _error = null;
    });
    _load(reset: true);
  }

  String _endpoint(bool append) {
    final state = AppScope.of(context);
    final query = <String, String>{
      if (_query.isNotEmpty) 'q': _query,
      if (append && _cursor != null) 'cursor': _cursor!,
      'limit': '20',
      'scope': widget.scope,
      if (widget.scope == 'recommended') ...{
        'server': state.server,
        'locale': state.text.locale,
        if (append && _seed != null) 'seed': '$_seed',
      },
      'state': widget.scope == 'mine' ? _postState : 'active',
      'tag': ?_tagFilter,
      if (_selectedTags.isNotEmpty) ...{
        'tags': _selectedTags.join(','),
        'tagMatch': _tagMode,
      },
      if (widget.forum?['id'] case final String id) 'forumId': id,
    };
    return Uri(
      path: '/api/v1/community/posts',
      queryParameters: query,
    ).toString();
  }

  Future<void> _load({bool reset = false}) async {
    if (_needsSession && !HaneokaAccount.instance.signedIn) {
      setState(() {
        _items.clear();
        _done = true;
        _loading = false;
      });
      return;
    }
    if (_loading && !reset) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _cursor = null;
        _seed = null;
        _done = false;
      }
    });
    try {
      final data = await communityRequest('GET', _endpoint(!reset));
      if (!mounted || generation != _generation) return;
      final entries = data['entries'];
      final next = entries is List
          ? [
              for (final entry in jsonList(entries))
                if (entry['kind'] == 'post')
                  jsonMap(entry['post'])
                else if (entry['kind'] == 'entity-comment')
                  entry,
            ]
          : jsonList(data['posts']);
      final known = {for (final item in _items) '${item['id']}'};
      setState(() {
        _items.addAll(next.where((item) => known.add('${item['id']}')));
        _cursor = data['nextCursor'] as String?;
        _seed ??= data['seed'];
        _done = _cursor == null || next.isEmpty;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  String get _title {
    String label(String key, String fallback) =>
        communityLabel(context, key, fallback);
    if (_tagFilter != null) return '#$_tagFilter';
    if (widget.forum != null) {
      final names = jsonMap(widget.forum!['names']);
      final locale = AppScope.of(context).text.locale;
      return '${names[locale] ?? names['en'] ?? ''}';
    }
    return switch (widget.scope) {
      'latest' => label('feedLatest', 'Latest'),
      'following' => label('feedFollowing', 'Following'),
      'mine' => label('mine', 'Mine'),
      'bookmarked' => label('bookmarks', 'Bookmarks'),
      _ => label('feedRecommended', 'For you'),
    };
  }

  Future<void> _openFilters() async {
    try {
      await showGeneralDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
        barrierColor: Theme.of(context).colorScheme.scrim
            .withValues(alpha: .32),
        pageBuilder: (context, _, _) {
          _filterRoute = ModalRoute.of(context);
          return Align(
            alignment: AlignmentDirectional.centerEnd,
            child: AccountDialog(child: _FeedFilters(feed: this)),
          );
        },
      );
    } finally {
      _filterRoute = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_invalidated && ModalRoute.of(context)?.isCurrent == true) {
      _invalidated = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(reset: true);
      });
    }
    final theme = Theme.of(context);
    final signedOut = _needsSession && !HaneokaAccount.instance.signedIn;
    return ShellPage(
      title: _title,
      marks: _selectedTags.isEmpty && _tagFilter == null
          ? null
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final tag in {?_tagFilter, ..._selectedTags})
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: InputChip(
                        label: Text('#$tag'),
                        onDeleted: () {
                          setState(() {
                            if (_tagFilter == tag) _tagFilter = null;
                            _selectedTags.remove(tag);
                          });
                          _load(reset: true);
                        },
                      ),
                    ),
                ],
              ),
            ),
      marksExtent: _selectedTags.isEmpty && _tagFilter == null ? 0 : 240,
      search: ShellSearch(
        label: communityLabel(context, 'search', 'Search'),
        onChanged: (_) {},
        onSubmitted: (value) {
          _query = value.trim();
          _load(reset: true);
        },
      ),
      actions: [
        BarAction(
          icon: Symbols.filter_alt_rounded,
          label: AppScope.of(context).text('common.actions.filter'),
          badge: _selectedTags.length + (_postState == 'archived' ? 1 : 0),
          onPressed: signedOut ? null : _openFilters,
        ),
        if (HaneokaAccount.instance.signedIn && widget.scope == 'recommended')
          BarAction(
            icon: Symbols.restore_rounded,
            label: communityLabel(
              context,
              'resetFeedback',
              'Reset recommendations',
            ),
            onPressed: () async {
              try {
                await communityRequest(
                  'DELETE',
                  '/api/v1/community/me/post-feedback',
                );
                if (mounted) _load(reset: true);
              } catch (_) {
                if (context.mounted) communityMessage(context, 'unavailable');
              }
            },
          ),
        BarAction(
          icon: Symbols.edit_rounded,
          label: communityLabel(context, 'newPost', 'New post'),
          tonal: true,
          onPressed: () async {
            if (!await requireSession(context) || !context.mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PostEditorScreen(forum: widget.forum),
              ),
            );
            if (mounted) _load(reset: true);
          },
        ),
        BarAction(
          icon: Symbols.refresh_rounded,
          label: AppScope.of(context).text('common.actions.refresh', 'Refresh'),
          onPressed: () => _load(reset: true),
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.extentAfter < 800 &&
                  !_loading &&
                  !_done &&
                  _error == null) {
                _load();
              }
              return false;
            },
            child: RefreshIndicator(
              onRefresh: () => _load(reset: true),
              child: ListView(
                padding: pagePadding(context),
                children: [
                  if (signedOut)
                    _SignInPrompt(onSignIn: () => signInToHaneoka(context))
                  else if (_items.isEmpty && _done && !_loading)
                    Padding(
                      padding: const EdgeInsets.all(48),
                      child: Center(
                        child: Text(
                          communityLabel(context, 'emptyTitle', 'No posts yet'),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    PostMasonry(
                      items: _items,
                      allowFeedback: widget.scope == 'recommended',
                      width: width,
                      onChanged: (item, next) {
                        if (!mounted) return;
                        setState(() {
                          if (next['_removeFromFeed'] == true) {
                            _items.remove(item);
                          } else if (next['_restoreToFeed'] == true) {
                            _items.insert(
                              0,
                              {...next}..remove('_restoreToFeed'),
                            );
                          } else {
                            item
                              ..clear()
                              ..addAll(next);
                          }
                        });
                      },
                    ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (_error != null)
                    Center(
                      child: TextButton.icon(
                        onPressed: () => _load(),
                        icon: const Icon(Symbols.refresh_rounded),
                        label: Text(communityLabel(context, 'retry', 'Retry')),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Posts in balanced columns (`renderPins`): each card goes under the
/// shortest column by an estimate of its height, and stays there.
class PostMasonry extends StatefulWidget {
  const PostMasonry({
    super.key,
    required this.items,
    required this.width,
    required this.onChanged,
    this.allowFeedback = false,
  });
  final bool allowFeedback;
  final List<Json> items;
  final double width;
  final void Function(Json item, Json next) onChanged;
  @override
  State<PostMasonry> createState() => _PostMasonryState();
}

class _PostMasonryState extends State<PostMasonry> {
  final _placements = <String, int>{};
  int _placementColumns = 0;

  List<List<Json>> _columns(int count) {
    if (_placementColumns != count) {
      _placements.clear();
      _placementColumns = count;
    }
    final columns = List.generate(count, (_) => <Json>[]);
    final heights = List.filled(count, 0.0);
    final ids = {for (final post in widget.items) '${post['id']}'};
    _placements.removeWhere((id, _) => !ids.contains(id));
    for (final post in widget.items) {
      final column = _placements.putIfAbsent('${post['id']}', () {
        var best = 0;
        for (var i = 1; i < count; i++) {
          if (heights[i] < heights[best]) best = i;
        }
        return best;
      });
      columns[column].add(post);
      final first = jsonList(post['attachments'])
          .where(
            (item) =>
                '${item['mediaType']}'.startsWith('image/') &&
                mediaThumbnail(item).isNotEmpty,
          )
          .firstOrNull;
      heights[column] += first != null
          ? 160 + 240 / mediaRatio(first)
          : 140 +
                (('${post['excerpt'] ?? post['body'] ?? ''}').length / 18)
                        .ceil()
                        .clamp(0, 9) *
                    22;
    }
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    // `columnsFor` on the website, for the pane's width.
    final count = width < 300
        ? 1
        : width < 670
        ? 2
        : width < 1050
        ? 3
        : width < 1400
        ? 4
        : 5;
    final gap = width < 600 ? 12.0 : 16.0;
    final columns = _columns(count);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: count * 312 + (count - 1) * gap),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (index, column) in columns.indexed) ...[
              if (index > 0) SizedBox(width: gap),
              Expanded(
                child: Column(
                  children: [
                    for (final item in column)
                      Padding(
                        key: ValueKey(item['id']),
                        padding: EdgeInsets.only(bottom: gap),
                        child: item['kind'] == 'entity-comment'
                            ? EntityCommentCard(entry: item)
                            : PostCard(
                                post: item,
                                onFeedback: widget.allowFeedback
                                    ? () => widget.onChanged(item, {
                                        ...item,
                                        '_removeFromFeed': true,
                                      })
                                    : null,
                                compact: width < 600,
                                onChanged: (next) =>
                                    widget.onChanged(item, next),
                              ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt({required this.onSignIn});
  final VoidCallback onSignIn;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(48),
    child: Center(
      child: FilledButton.icon(
        onPressed: onSignIn,
        icon: const Icon(Symbols.login_rounded),
        label: Text(
          AppScope.of(context).text('account.page.signIn', 'Sign in'),
        ),
      ),
    ),
  );
}

/// A post as a card (`renderPin`): its first image, or the excerpt; the
/// forum, title, author and likes.
class PostCard extends StatelessWidget {
  const PostCard({
    super.key,
    required this.post,
    required this.onChanged,
    this.compact = false,
    this.onFeedback,
  });
  final Json post;
  final ValueChanged<Json> onChanged;
  final bool compact;
  final VoidCallback? onFeedback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = postMedia(post);
    final first = media.firstOrNull;
    final excerpt = communityExcerpt(
      '${post['excerpt'] ?? post['body'] ?? ''}',
    );
    final title = '${post['title'] ?? ''}'.trim();
    final name = authorName(context, post);
    void open() => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PostScreen(id: '${post['id']}', initial: post),
      ),
    );
    final titleStyle =
        (first == null
                ? theme.textTheme.titleMedium?.copyWith(
                    fontSize: compact ? 15 : 17,
                    height: compact ? 22 / 15 : 24 / 17,
                  )
                : theme.textTheme.titleMedium?.copyWith(
                    fontSize: compact ? 14 : null,
                    height: compact ? 20 / 14 : null,
                  ))
            ?.copyWith(fontWeight: FontWeight.w600);
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.large),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (first != null)
              AspectRatio(
                aspectRatio: mediaRatio(first),
                child: Container(
                  color: scheme.surfaceContainer,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AppImage(
                        candidates: [absoluteUrl(mediaThumbnail(first))],
                        fit: BoxFit.contain,
                        localized: false,
                      ),
                      if ('${first['mediaType']}'.startsWith('video/') ||
                          first['playbackUrl'] != null)
                        const Center(
                          child: Icon(Symbols.play_arrow_rounded, size: 40),
                        ),
                      if (media.length > 1)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Symbols.image_rounded,
                                  size: 14,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  '${media.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 10 : 14,
                first == null ? (compact ? 12 : 16) : (compact ? 10 : 12),
                compact ? 10 : 14,
                compact ? 2 : 4,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ForumLabel(forum: jsonMap(post['forum'])),
                      ),
                      CommunityRecordMenu(
                        kind: 'post',
                        record: post,
                        onChanged: onChanged,
                        onFeedback: onFeedback,
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 5 : 6),
                  if (post['adminOnlyContext'] == true &&
                      post['visibility'] == 'private') ...[
                    Text(
                      communityLabel(
                        context,
                        'visibilityPrivate',
                        'Only visible to you',
                      ),
                      style: theme.textTheme.labelSmall,
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    title.isEmpty
                        ? communityLabel(context, 'emptyTitle', 'Untitled')
                        : title,
                    style: titleStyle,
                  ),
                  if (first == null) ...[
                    const SizedBox(height: 8),
                    Text(
                      excerpt.isEmpty
                          ? communityLabel(
                              context,
                              'postBody',
                              'What would you like to share?',
                            )
                          : excerpt,
                      maxLines: 7,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 10 : 14, 4, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Corner.small),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              CommunityUserScreen(uid: '${post['authorUid']}'),
                        ),
                      ),
                      child: Row(
                        children: [
                          CommunityAvatar(
                            image: post['authorImage'],
                            name: name,
                            size: compact ? 20 : 22,
                          ),
                          SizedBox(width: compact ? 4 : 6),
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: compact ? 11 : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  LikeButton(
                    kind: 'post',
                    record: post,
                    compact: true,
                    onChanged: onChanged,
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

/// A comment on a catalogue page, recommended in the feed
/// (`renderEntityCommentActivity`).
class EntityCommentCard extends StatelessWidget {
  const EntityCommentCard({super.key, required this.entry});
  final Json entry;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final locale = state.text.locale;
    final ref = jsonMap(entry['entityRef']);
    final titles = jsonMap(ref['titles']);
    final title =
        '${titles[locale] ?? titles.values.whereType<String>().where((t) => t.isNotEmpty).firstOrNull ?? ref['originalId'] ?? ''}';
    final paths = jsonMap(ref['detailPaths']);
    final path = (paths[state.server] ?? paths.values.firstOrNull) as String?;
    final comment = jsonMap(entry['comment']);
    final name = authorName(context, comment);
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.large),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: path == null ? null : () => openLink(context, path),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Symbols.chat_bubble_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    communityLabel(context, 'comments', 'Comments'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  CommunityAvatar(
                    image: comment['authorImage'],
                    name: name,
                    size: 22,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              CommunityBody(
                source: '${comment['body'] ?? ''}',
                style: theme.textTheme.bodyMedium,
              ),
              CommunityContext(record: comment),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeedFilters extends StatefulWidget {
  const _FeedFilters({required this.feed});
  final _CommunityFeedScreenState feed;
  @override
  State<_FeedFilters> createState() => _FeedFiltersState();
}

class _FeedFiltersState extends State<_FeedFilters> {
  final _search = TextEditingController();
  late Future<Json> _data = _fetch();
  Future<Json> _fetch([String? cursor]) {
    final query = {...Uri.parse(widget.feed._endpoint(false)).queryParameters}
      ..remove('tags')
      ..remove('tagMatch')
      ..remove('q')
      ..remove('seed')
      ..remove('server')
      ..remove('locale');
    return communityRequest(
      'GET',
      Uri(
        path: '/api/v1/community/tag-facets',
        queryParameters: {
          ...query,
          'limit': '100',
          if (widget.feed._query.isNotEmpty) 'postQ': widget.feed._query,
          if (_search.text.trim().isNotEmpty) 'q': _search.text.trim(),
          'cursor': ?cursor,
        },
      ).toString(),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _change(VoidCallback change) {
    widget.feed._changeFilters(change);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    String t(String key) => communityLabel(context, key, key);
    return BrowseFilterPanel(
      switches: const [],
      facets: const [],
      sorts: const [],
      sort: null,
      descending: true,
      selected: const {},
      counts: (_) => const {},
      onToggle: (_, _) {},
      onSort: (_) {},
      onOrder: () {},
      onReset: () {},
      fields: [
        if (feed.widget.scope == 'mine')
          Segmented<String>(
            value: feed._postState,
            options: [
              Choice('active', t('stateActive')),
              Choice('archived', t('stateArchived')),
            ],
            onSelected: (v) {
              _change(() => feed._postState = v);
              setState(() => _data = _fetch());
            },
          ),
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          maxLength: 64,
          decoration: InputDecoration(
            labelText: t('tagSearch'),
            suffixIcon: IconButton(
              tooltip: AppScope.of(context).text('common.actions.search'),
              icon: const Icon(Symbols.search_rounded),
              onPressed: () => setState(() => _data = _fetch()),
            ),
          ),
          onSubmitted: (_) => setState(() => _data = _fetch()),
        ),
        const SizedBox(height: 16),
        Segmented<String>(
          value: feed._tagMode,
          options: [
            Choice('all', t('tagMatchAll')),
            Choice('any', t('tagMatchAny')),
          ],
          onSelected: (v) => _change(() => feed._tagMode = v),
        ),
        const SizedBox(height: 16),
        FutureBuilder(
          future: _data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return TextButton(
                onPressed: () => setState(() => _data = _fetch()),
                child: Text(AppScope.of(context).text('common.actions.retry')),
              );
            }
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 64,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final tags = jsonList(snapshot.data?['tags']),
                groups = [
                  ...jsonList(snapshot.data?['groups']),
                  {'id': '', 'defaultName': t('tags')},
                ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final group in groups)
                  if (tags.any((tag) => (tag['groupId'] ?? '') == group['id']))
                    ExpansionTile(
                      title: Text(
                        AppScope.of(context).text
                                .text(group['names'])
                                .isNotEmpty
                            ? AppScope.of(context).text.text(group['names'])
                            : '${group['defaultName'] ?? ''}',
                      ),
                      initiallyExpanded: true,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final tag in tags.where(
                              (tag) => (tag['groupId'] ?? '') == group['id'],
                            ))
                              FilterChip(
                                showCheckmark: false,
                                label: Text(
                                  '#${tag['displayName']} · ${tag['postCount']}',
                                ),
                                selected: feed._selectedTags.contains(
                                  tag['normalizedName'],
                                ),
                                onSelected: (_) => _change(() {
                                  if (!feed._selectedTags.remove(
                                    '${tag['normalizedName']}',
                                  )) {
                                    feed._selectedTags.add(
                                      '${tag['normalizedName']}',
                                    );
                                  }
                                }),
                              ),
                          ],
                        ),
                      ],
                    ),
                if (snapshot.data?['nextCursor'] case final String cursor
                    when cursor.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      final next = await _fetch(cursor);
                      if (mounted) {
                        setState(
                          () => _data = Future.value({
                            ...next,
                            'tags': [...tags, ...jsonList(next['tags'])],
                          }),
                        );
                      }
                    },
                    child: Text(
                      AppScope.of(context).text('common.actions.loadMore'),
                    ),
                  ),
              ],
            );
          },
        ),
        TextButton(
          onPressed: () {
            _change(() {
              feed._tagFilter = null;
              feed._selectedTags.clear();
              feed._tagMode = 'all';
              feed._postState = 'active';
            });
            setState(() => _data = _fetch());
          },
          child: Text(AppScope.of(context).text('common.actions.clear')),
        ),
      ],
    );
  }
}
