import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'community_widgets.dart';
import 'editor.dart';
import 'feed_screen.dart';
import 'reactions.dart';
import 'actions.dart';
import 'user_screen.dart';

/// A post with its discussion (`renderPostDetail`).
class PostScreen extends StatefulWidget {
  const PostScreen({super.key, required this.id, this.initial});
  final String id;

  /// The card's record, shown while the post loads.
  final Json? initial;

  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> {
  Json? _post;
  Json _viewer = const {};
  List<Json> _comments = [];
  String? _commentsCursor;
  int _commentCount = 0;
  String _sort = 'hot';
  bool _loading = true;
  int _generation = 0;
  Object? _owner = HaneokaAccount.instance.user?['id'];
  bool _loadingComments = false;
  int _commentsGeneration = 0;
  Object? _error;
  final _expanded = <String>{};
  final _replyLoading = <String>{};

  String get _path =>
      '/api/v1/community/posts/${Uri.encodeComponent(widget.id)}';

  @override
  void initState() {
    super.initState();
    _post = widget.initial;
    HaneokaAccount.instance.addListener(_accountChanged);
    HaneokaAccount.instance.load().then((_) => _load());
  }

  void _accountChanged() {
    final owner = HaneokaAccount.instance.user?['id'];
    if (owner == _owner) return;
    _owner = owner;
    _generation++;
    setState(() {
      _post = null;
      _viewer = {};
      _comments = [];
      _commentsCursor = null;
      _loadingComments = false;
      _replyLoading.clear();
      _expanded.clear();
      _loading = true;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    HaneokaAccount.instance.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_generation;
    try {
      final data = await communityRequest(
        'GET',
        '$_path?${Uri(queryParameters: {'commentsSort': _sort}).query}',
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _post = jsonMap(data['post']);
        _viewer = jsonMap(data['viewer']);
        _comments = jsonList(data['comments']);
        _commentsCursor = data['commentsNextCursor'] as String?;
        _commentCount =
            (data['commentCount'] as num?)?.toInt() ??
            (_post!['commentCount'] as num?)?.toInt() ??
            _comments.length;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadComments({bool append = false}) async {
    if (append && _loadingComments) return;
    setState(() => _loadingComments = true);
    final generation = _generation, commentsGeneration = ++_commentsGeneration;
    try {
      final query = {
        'commentsOnly': 'true',
        'commentsSort': _sort,
        if (append && _commentsCursor != null)
          'commentsCursor': _commentsCursor!,
      };
      final data = await communityRequest(
        'GET',
        '$_path?${Uri(queryParameters: query).query}',
      );
      if (!mounted ||
          generation != _generation ||
          commentsGeneration != _commentsGeneration) {
        return;
      }
      final incoming = jsonList(data['comments']);
      setState(() {
        final known = {for (final c in _comments) '${c['id']}'};
        _comments = [
          if (append) ..._comments,
          for (final c in incoming)
            if (!append || known.add('${c['id']}')) c,
        ];
        _commentsCursor = data['commentsNextCursor'] as String?;
        if (data['commentCount'] case final num count) {
          _commentCount = count.toInt();
        }
      });
    } catch (_) {
      // The list stays as it was; scrolling tries again.
    } finally {
      if (mounted &&
          generation == _generation &&
          commentsGeneration == _commentsGeneration) {
        setState(() => _loadingComments = false);
      }
    }
  }

  Future<void> _loadReplies(String rootId) async {
    final root = _comments.where((c) => '${c['id']}' == rootId).firstOrNull;
    final cursor = root?['replyCursor'];
    if (root == null || cursor == null || _replyLoading.contains(rootId)) {
      return;
    }
    setState(() => _replyLoading.add(rootId));
    final generation = _generation;
    try {
      final data = await communityRequest(
        'GET',
        '$_path?${Uri(queryParameters: {'commentsOnly': 'true', 'commentsRoot': rootId, 'commentsCursor': '$cursor', 'commentsSort': _sort}).query}',
      );
      if (!mounted || generation != _generation) return;
      final known = {for (final c in _comments) '${c['id']}'};
      setState(() {
        _comments = [
          for (final c in _comments)
            if ('${c['id']}' == rootId)
              {...c, 'replyCursor': data['replyCursor']}
            else
              c,
          for (final c in jsonList(data['comments']))
            if (known.add('${c['id']}')) c,
        ];
        _expanded.add(rootId);
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _replyLoading.remove(rootId));
    }
  }

  void _replace(Json comment) {
    setState(() {
      _comments = [
        for (final c in _comments)
          c['id'] == comment['id']
              ? ({...comment}..remove('_refreshThread'))
              : c,
      ];
    });
    if (comment['_refreshThread'] == true) unawaited(_loadComments());
  }

  Future<void> _toggleFollow() async {
    if (!await requireSession(context) || !mounted || _post == null) return;
    final uid = '${_post?['authorUid']}';
    final following = _viewer['following'] == true;
    setState(() => _viewer = {..._viewer, 'following': !following});
    try {
      final result = await communityRequest(
        'PUT',
        '/api/v1/community/users/${Uri.encodeComponent(uid)}/follow',
        body: {'active': !following},
      );
      if (mounted) {
        setState(
          () => _viewer = {
            ..._viewer,
            'following': jsonMap(result['viewer'])['following'] == true,
          },
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _viewer = {..._viewer, 'following': following});
      }
    }
  }

  Future<void> _toggleBookmark() async {
    if (!await requireSession(context) || !mounted || _post == null) return;
    final bookmarked = _viewer['bookmarked'] == true;
    setState(() => _viewer = {..._viewer, 'bookmarked': !bookmarked});
    try {
      final result = await communityRequest(
        'PUT',
        '$_path/bookmark',
        body: {'active': !bookmarked},
      );
      if (mounted) {
        setState(
          () => _viewer = {..._viewer, 'bookmarked': result['active'] == true},
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _viewer = {..._viewer, 'bookmarked': bookmarked});
      }
    }
  }

  Future<void> _compose({Json? replyTo}) async {
    if (HaneokaAccount.instance.signedIn && _viewer['canComment'] == false) {
      return;
    }
    if (!await requireSession(context) || !mounted) return;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CommentComposer(
        postPath: _path,
        replyTo: replyTo,
        replyName: replyTo == null ? null : authorName(context, replyTo),
      ),
    );
    if (sent == true) {
      await _loadComments();
      if (replyTo != null) {
        _expanded.add('${replyTo['rootId'] ?? replyTo['id']}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final post = _post;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ShellPage(
      title: t('community.page.post', 'Post'),
      actions: [
        BarAction(
          icon: Symbols.share_rounded,
          label: t('common.actions.share', 'Share'),
          onPressed: () {
            Clipboard.setData(
              ClipboardData(
                text:
                    '$communityOrigin/${t.locale}/community/posts/${widget.id}/',
              ),
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  communityLabel(context, 'linkCopied', 'Link copied'),
                ),
              ),
            );
          },
        ),
      ],
      body: post == null
          ? Center(
              child: _error != null
                  ? Text(communityLabel(context, 'unavailable', 'Unavailable'))
                  : const CircularProgressIndicator(),
            )
          : Column(
              children: [
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 600 &&
                          _commentsCursor != null &&
                          !_loadingComments) {
                        _loadComments(append: true);
                      }
                      return false;
                    },
                    child: ListView(
                      padding: pagePadding(context),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: Material(
                              color: scheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(Corner.large),
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _PostHead(
                                      post: post,
                                      viewer: _viewer,
                                      onFollow: _toggleFollow,
                                      onChanged: (next) => setState(() {
                                        _post = next;
                                        _viewer = jsonMap(next['viewer']);
                                      }),
                                      onRemoved: () =>
                                          Navigator.of(context).pop(),
                                    ),
                                    const SizedBox(height: 16),
                                    Divider(color: scheme.outlineVariant),
                                    _commentsHeader(context),
                                    if (_loading)
                                      const Padding(
                                        padding: EdgeInsets.all(24),
                                        child: Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      )
                                    else if (_comments.isEmpty)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 24,
                                        ),
                                        child: Text(
                                          communityLabel(
                                            context,
                                            'emptyComments',
                                            'Start the conversation',
                                          ),
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      )
                                    else
                                      ...commentThreads(
                                        context,
                                        comments: _comments,
                                        authorUid: post['authorUid'],
                                        expanded: _expanded,
                                        replyLoading: _replyLoading,
                                        onExpand: (id, open) => setState(
                                          () => open
                                              ? _expanded.add(id)
                                              : _expanded.remove(id),
                                        ),
                                        onLoadReplies: _loadReplies,
                                        onChanged: _replace,
                                        onReply: (c) => _compose(replyTo: c),
                                      ),
                                    if (_loadingComments)
                                      const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _EngagementBar(
                  post: post,
                  viewer: _viewer,
                  commentCount: _commentCount,
                  onComment:
                      _viewer['canComment'] == false &&
                          HaneokaAccount.instance.signedIn
                      ? null
                      : () => _compose(),
                  onBookmark: _toggleBookmark,
                  onLike: (next) => setState(() => _post = next),
                ),
              ],
            ),
    );
  }

  Widget _commentsHeader(BuildContext context) {
    final theme = Theme.of(context);
    final locale = AppScope.of(context).text.locale;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              communityLabel(context, 'commentCount', '{count} comments', {
                'count': NumberFormat.decimalPattern(locale)
                    .format(_commentCount),
              }),
              style: theme.textTheme.bodyLarge,
            ),
          ),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: 'hot',
                label: Text(
                  communityLabel(context, 'commentSortPopular', 'Popular'),
                ),
              ),
              ButtonSegment(
                value: 'latest',
                label: Text(
                  communityLabel(context, 'commentSortLatest', 'Latest'),
                ),
              ),
            ],
            selected: {_sort},
            onSelectionChanged: (value) {
              _sort = value.single;
              _expanded.clear();
              _loadComments();
            },
          ),
        ],
      ),
    );
  }
}

/// Comments grouped under their root, replies oldest first, two shown
/// until expanded (`renderCommentThreads`).
List<Widget> commentThreads(
  BuildContext context, {
  required List<Json> comments,
  required Object? authorUid,
  required Set<String> expanded,
  required Set<String> replyLoading,
  required void Function(String id, bool open) onExpand,
  required void Function(String rootId) onLoadReplies,
  required ValueChanged<Json> onChanged,
  required void Function(Json comment) onReply,
}) {
  final byId = {for (final c in comments) '${c['id']}': c};
  final groups = <String, List<Json>>{};
  final roots = <Json>[];
  for (final comment in comments) {
    var root = byId['${comment['rootId'] ?? ''}'] ?? comment;
    final visited = {'${comment['id']}'};
    while (root['parentId'] != null &&
        byId.containsKey('${root['parentId']}') &&
        !visited.contains('${root['parentId']}')) {
      root = byId['${root['parentId']}']!;
      visited.add('${root['id']}');
    }
    final id = '${root['id']}';
    if (!groups.containsKey(id)) {
      groups[id] = [];
      roots.add(root);
    }
    if (!identical(comment, root)) groups[id]!.add(comment);
  }
  String label(
    String key,
    String fallback, [
    Map<String, Object?> v = const {},
  ]) => communityLabel(context, key, fallback, v);
  return [
    for (final root in roots)
      Builder(
        builder: (context) {
          final id = '${root['id']}';
          final replies = (groups[id] ?? [])
            ..sort((a, b) {
              final time = ((a['createdAt'] as num?) ?? 0).compareTo(
                (b['createdAt'] as num?) ?? 0,
              );
              return time != 0 ? time : '${a['id']}'.compareTo('${b['id']}');
            });
          final known = (root['replyCount'] as num?)?.toInt() ?? replies.length;
          final remaining = (known - replies.length).clamp(0, 1 << 31);
          final hasMore =
              root['replyCursor'] != null ||
              remaining > 0 ||
              replies.length > 2;
          final open = expanded.contains(id);
          final visible = open ? replies : replies.take(2).toList();
          final moreCount = remaining > 0
              ? remaining
              : (replies.length - 2).clamp(0, 1 << 31);
          final moreLabel = moreCount > 0
              ? label('expandReplies', 'Show {count} more replies', {
                  'count': moreCount,
                })
              : label('loadMoreComments', 'Load more comments');
          final loading = replyLoading.contains(id);
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CommentTile(
                  comment: root,
                  postAuthorUid: authorUid,
                  onChanged: onChanged,
                  onReply: () => onReply(root),
                ),
                if (visible.isNotEmpty)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 52),
                    child: Column(
                      children: [
                        for (final reply in visible)
                          CommentTile(
                            comment: reply,
                            reply: true,
                            postAuthorUid: authorUid,
                            replyToName: () {
                              final parent = byId['${reply['parentId']}'];
                              return parent != null &&
                                      parent['parentId'] != null
                                  ? authorName(context, parent)
                                  : null;
                            }(),
                            onChanged: onChanged,
                            onReply: () => onReply(reply),
                          ),
                      ],
                    ),
                  ),
                if (hasMore || open)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 44),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: loading
                            ? null
                            : () {
                                if (open) {
                                  onExpand(id, false);
                                } else if (root['replyCursor'] != null &&
                                    replies.length <= 2) {
                                  onLoadReplies(id);
                                } else {
                                  onExpand(id, true);
                                }
                              },
                        iconAlignment: IconAlignment.end,
                        icon: Icon(
                          open
                              ? Symbols.expand_less_rounded
                              : Symbols.expand_more_rounded,
                        ),
                        label: Text(
                          open
                              ? label('collapseReplies', 'Collapse replies')
                              : moreLabel,
                        ),
                      ),
                    ),
                  ),
                if (open && root['replyCursor'] != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 44),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: loading ? null : () => onLoadReplies(id),
                        iconAlignment: IconAlignment.end,
                        icon: const Icon(Symbols.expand_more_rounded),
                        label: Text(moreLabel),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
  ];
}

class _PostHead extends StatelessWidget {
  const _PostHead({
    required this.post,
    required this.viewer,
    required this.onFollow,
    required this.onChanged,
    required this.onRemoved,
  });
  final Json post;
  final Json viewer;
  final VoidCallback onFollow, onRemoved;
  final ValueChanged<Json> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = authorName(context, post);
    final media = postMedia(post);
    final tags = (post['tags'] as List? ?? const []).whereType<String>();
    final own = HaneokaAccount.instance.user?['uid'] == post['authorUid'];
    void openAuthor() => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CommunityUserScreen(uid: '${post['authorUid']}'),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ForumLabel(forum: jsonMap(post['forum'])),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: openAuthor,
                borderRadius: BorderRadius.circular(Corner.medium),
                child: Row(
                  children: [
                    CommunityAvatar(image: post['authorImage'], name: name),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            CommunityRecordMenu(
              kind: 'post',
              record: post,
              viewer: viewer,
              detail: true,
              onChanged: onChanged,
              onRemoved: onRemoved,
            ),
            if (!own)
              viewer['following'] == true
                  ? FilledButton.tonal(
                      onPressed: onFollow,
                      child: Text(
                        communityLabel(context, 'following', 'Following'),
                      ),
                    )
                  : OutlinedButton(
                      onPressed: onFollow,
                      child: Text(communityLabel(context, 'follow', 'Follow')),
                    ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '${post['title'] ?? ''}',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        CommunityBody(source: '${post['body'] ?? post['excerpt'] ?? ''}'),
        if (media.isNotEmpty) ...[
          const SizedBox(height: 8),
          ImageGallery(
            images: const [],
            entries: [
              for (final item in media)
                GalleryImage(
                  absoluteUrl('${item['previewUrl'] ?? item['contentUrl']}'),
                  '${item['fileName'] ?? ''}',
                  localized: false,
                ),
            ],
            aspectRatio: mediaRatio(media.first),
            natural: true,
          ),
        ],
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final tag in tags)
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          CommunityFeedScreen(scope: 'latest', tag: tag),
                    ),
                  ),
                  child: Text(
                    '#$tag',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        CommunityContext(record: post),
      ],
    );
  }
}

/// One comment (`renderCommunityComment`).
class CommentTile extends StatelessWidget {
  const CommentTile({
    super.key,
    required this.comment,
    required this.onChanged,
    this.onReply,
    this.reply = false,
    this.postAuthorUid,
    this.replyToName,
  });
  final Json comment;
  final ValueChanged<Json> onChanged;
  final VoidCallback? onReply;
  final bool reply;
  final Object? postAuthorUid;
  final String? replyToName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = authorName(context, comment);
    final floor = (comment['floor'] as num?)?.toInt() ?? 0;
    final isAuthor =
        postAuthorUid != null && '${comment['authorUid']}' == '$postAuthorUid';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    CommunityUserScreen(uid: '${comment['authorUid']}'),
              ),
            ),
            customBorder: const CircleBorder(),
            child: CommunityAvatar(
              image: comment['authorImage'],
              name: name,
              size: reply ? 28 : 40,
            ),
          ),
          SizedBox(width: reply ? 8 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          if (isAuthor) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                communityLabel(context, 'postAuthor', 'Author'),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    CommunityRecordMenu(
                      kind: 'comment',
                      record: comment,
                      onChanged: onChanged,
                    ),
                    if (floor > 0)
                      Text(
                        communityLabel(
                          context,
                          'commentFloor',
                          'Floor {floor}',
                          {'floor': floor},
                        ),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                if (replyToName != null)
                  Text(
                    '${communityLabel(context, 'replyingTo', 'Replying to')} $replyToName',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                CommunityBody(source: '${comment['body'] ?? ''}'),
                CommunityContext(record: comment),
                Row(
                  children: [
                    LikeButton(
                      kind: 'comment',
                      record: comment,
                      showLabel: true,
                      onChanged: onChanged,
                    ),
                    if (onReply != null)
                      TextButton.icon(
                        onPressed: onReply,
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.onSurfaceVariant,
                        ),
                        icon: const Icon(
                          Symbols.chat_bubble_outline_rounded,
                          size: 18,
                        ),
                        label: Text(communityLabel(context, 'reply', 'Reply')),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EngagementBar extends StatelessWidget {
  const _EngagementBar({
    required this.post,
    required this.viewer,
    required this.commentCount,
    required this.onComment,
    required this.onBookmark,
    required this.onLike,
  });
  final Json post;
  final Json viewer;
  final int commentCount;
  final VoidCallback? onComment;
  final VoidCallback onBookmark;
  final ValueChanged<Json> onLike;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final signedIn = HaneokaAccount.instance.signedIn;
    final bookmarked = viewer['bookmarked'] == true;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Material(
                      color: scheme.surfaceContainerHigh,
                      shape: const StadiumBorder(),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: onComment,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Symbols.edit_rounded,
                                size: 20,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  onComment == null
                                      ? communityLabel(
                                          context,
                                          'commentsClosed',
                                          'Comments are closed for this post',
                                        )
                                      : signedIn
                                      ? communityLabel(
                                          context,
                                          'writeComment',
                                          'Write a comment',
                                        )
                                      : communityLabel(
                                          context,
                                          'signInToComment',
                                          'Sign in to comment',
                                        ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  LikeButton(kind: 'post', record: post, onChanged: onLike),
                  IconButton(
                    onPressed: onBookmark,
                    isSelected: bookmarked,
                    icon: const Icon(Symbols.bookmark_rounded),
                    selectedIcon: const Icon(Symbols.bookmark_rounded, fill: 1),
                  ),
                  TextButton.icon(
                    onPressed: onComment,
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.onSurfaceVariant,
                    ),
                    icon: const Icon(Symbols.chat_bubble_outline_rounded),
                    label: Text('$commentCount'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Writing a comment or reply (`renderCommentComposer`).
class CommentComposer extends StatefulWidget {
  const CommentComposer({
    super.key,
    required this.postPath,
    this.replyTo,
    this.replyName,
  });
  final String postPath;
  final Json? replyTo;
  final String? replyName;
  @override
  State<CommentComposer> createState() => _ComposerState();
}

class _ComposerState extends State<CommentComposer> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty || body.length > 5000) return;
    setState(() => _sending = true);
    try {
      await communityRequest(
        'POST',
        '${widget.postPath}/comments',
        body: {
          'body': body,
          if (widget.replyTo != null) 'parentId': widget.replyTo!['id'],
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(communityLabel(context, 'unavailable', 'Unavailable')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.replyName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${communityLabel(context, 'replyingTo', 'Replying to')} · ${widget.replyName}',
                style: theme.textTheme.labelLarge,
              ),
            ),
          MarkupToolbar(controller: _controller),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            maxLength: 5000,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: communityLabel(
                context,
                'writeComment',
                'Write a comment',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: _sending || _controller.text.trim().isEmpty
                  ? null
                  : _send,
              icon: const Icon(Symbols.send_rounded),
              label: Text(
                _sending
                    ? communityLabel(context, 'publishing', 'Publishing…')
                    : communityLabel(context, 'comment', 'Comment'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
