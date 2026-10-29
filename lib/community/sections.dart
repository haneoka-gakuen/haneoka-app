import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/account_widgets.dart';
import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'community_time.dart';
import 'community_widgets.dart';
import 'feed_screen.dart';
import 'markup.dart';
import 'post_screen.dart';
import 'reactions.dart';
import 'user_screen.dart';
import 'actions.dart';

/// A paged community list: tags, notifications or the reader's comments.
abstract class _PagedState<T extends StatefulWidget> extends State<T> {
  final items = <Json>[];
  String? cursor;
  bool loading = false;
  bool done = false;
  Object? error;
  int _generation = 0;
  Object? _owner = HaneokaAccount.instance.user?['id'];
  void _accountChanged() {
    final owner = HaneokaAccount.instance.user?['id'];
    if (owner == _owner) return;
    _owner = owner;
    _generation++;
    setState(() {
      items.clear();
      cursor = null;
      loading = false;
      done = false;
      error = null;
    });
    load(reset: true);
  }

  String endpoint(String? cursor);
  String get listKey;
  bool get needsSession => false;

  @override
  void initState() {
    super.initState();
    HaneokaAccount.instance.addListener(_accountChanged);
    HaneokaAccount.instance.load().then((_) {
      if (mounted) load(reset: true);
    });
  }

  @override
  void dispose() {
    _generation++;
    HaneokaAccount.instance.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (needsSession && !HaneokaAccount.instance.signedIn) {
      setState(() => done = true);
      return;
    }
    if (loading && !reset) return;
    final generation = ++_generation;
    setState(() {
      loading = true;
      error = null;
      if (reset) {
        items.clear();
        cursor = null;
        done = false;
      }
    });
    try {
      final data = await communityRequest('GET', endpoint(cursor));
      if (!mounted || generation != _generation) return;
      setState(() {
        items.addAll(jsonList(data[listKey]));
        cursor = data['nextCursor'] as String?;
        done = cursor == null;
        loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    }
  }

  Widget list(BuildContext context, List<Widget> children, {String? empty}) {
    final theme = Theme.of(context);
    final signedOut = needsSession && !HaneokaAccount.instance.signedIn;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 600 && !done && !loading) load();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => load(reset: true),
        child: ListView(
          padding: pagePadding(context),
          children: [
            if (signedOut)
              Padding(
                padding: const EdgeInsets.all(48),
                child: Center(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await signInToHaneoka(context);
                      if (mounted) load(reset: true);
                    },
                    icon: const Icon(Symbols.login_rounded),
                    label: Text(
                      communityLabel(context, 'signInAction', 'Sign in'),
                    ),
                  ),
                ),
              )
            else if (items.isEmpty && done && empty != null)
              Padding(
                padding: const EdgeInsets.all(48),
                child: Center(
                  child: Text(
                    empty,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ...children,
            if (loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (error != null)
              Center(
                child: TextButton(
                  onPressed: load,
                  child: Text(communityLabel(context, 'retry', 'Retry')),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tags with their counts, each followed or muted (`mode === "tags"`).
class CommunityTagsScreen extends StatefulWidget {
  const CommunityTagsScreen({super.key});
  @override
  State<CommunityTagsScreen> createState() => _TagsState();
}

class _TagsState extends _PagedState<CommunityTagsScreen> {
  String _query = '';

  @override
  String get listKey => 'tags';

  @override
  String endpoint(String? cursor) => Uri(
    path: '/api/v1/community/tags',
    queryParameters: {
      if (_query.isNotEmpty) 'q': _query,
      'cursor': ?cursor,
      'limit': '20',
    },
  ).toString();

  Future<void> _prefer(Json tag, String? preference) async {
    if (!await requireSession(context)) return;
    final name = '${tag['normalizedName'] ?? ''}';
    final before = tag['preference'];
    setState(() => tag['preference'] = preference);
    try {
      final result = await communityRequest(
        'PUT',
        '/api/v1/community/tags/${Uri.encodeComponent(name)}/preference',
        body: {'preference': preference},
      );
      final updated = jsonMap(result['tag']);
      if (mounted && updated.isNotEmpty) {
        setState(() => tag.addAll(updated));
      }
    } catch (_) {
      if (mounted) setState(() => tag['preference'] = before);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = AppScope.of(context).text.locale;
    final number = NumberFormat.decimalPattern(locale);
    return ShellPage(
      title: communityLabel(context, 'tags', 'Tags'),
      search: ShellSearch(
        label: communityLabel(context, 'search', 'Search'),
        onChanged: (_) {},
        onSubmitted: (value) {
          _query = value.trim();
          load(reset: true);
        },
      ),
      body: list(context, [
        for (final (index, tag) in items.indexed) ...[
          if (index > 0) const Divider(height: 1),
          ListTile(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CommunityFeedScreen(
                  scope: 'latest',
                  tag: '${tag['normalizedName']}',
                ),
              ),
            ),
            title: Text(
              '#${tag['displayName'] ?? tag['normalizedName']}',
              style: theme.textTheme.titleMedium,
            ),
            subtitle: Text(
              '${tag['description'] ?? ''}'.isNotEmpty
                  ? '${tag['description']}'
                  : '${number.format((tag['postCount'] as num?) ?? 0)} ${communityLabel(context, 'posts', 'posts')} · ${number.format((tag['followerCount'] as num?) ?? 0)} ${communityLabel(context, 'followers', 'followers')}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: communityLabel(context, 'follow', 'Follow'),
                  isSelected: tag['preference'] == 'follow',
                  onPressed: () => _prefer(
                    tag,
                    tag['preference'] == 'follow' ? null : 'follow',
                  ),
                  icon: const Icon(Symbols.notifications_rounded),
                  selectedIcon: const Icon(
                    Symbols.notifications_rounded,
                    fill: 1,
                  ),
                ),
                IconButton(
                  tooltip: communityLabel(context, 'mute', 'Mute'),
                  isSelected: tag['preference'] == 'mute',
                  onPressed: () =>
                      _prefer(tag, tag['preference'] == 'mute' ? null : 'mute'),
                  icon: const Icon(Symbols.volume_off_rounded),
                  selectedIcon: const Icon(Symbols.volume_off_rounded, fill: 1),
                ),
              ],
            ),
          ),
        ],
      ]),
    );
  }
}

/// The reader's notifications (`mode === "notifications"`).
class CommunityNotificationsScreen extends StatefulWidget {
  const CommunityNotificationsScreen({super.key});
  @override
  State<CommunityNotificationsScreen> createState() => _NotificationsState();
}

class _NotificationsState extends _PagedState<CommunityNotificationsScreen> {
  @override
  String get listKey => 'notifications';
  @override
  bool get needsSession => true;
  @override
  String endpoint(String? cursor) => Uri(
    path: '/api/v1/community/notifications',
    queryParameters: {'cursor': ?cursor, 'limit': '20'},
  ).toString();

  String _label(Json item) {
    const keys = {
      'comment': 'notificationComment',
      'post_reaction': 'notificationReaction',
      'comment_reaction': 'notificationCommentReaction',
      'follow': 'notificationFollow',
      'mention': 'notificationMention',
      'moderation': 'notificationModeration',
      'reply': 'notificationReply',
    };
    return communityLabel(
      context,
      keys['${item['kind']}'] ?? 'notifications',
      'Notification',
    ).replaceAll(
      '{name}',
      '${item['actorName'] ?? communityLabel(context, 'member', 'Member')}',
    );
  }

  Future<void> _open(Json item) async {
    if (item['readAt'] == null) {
      communityRequest(
        'PUT',
        '/api/v1/community/notifications/${Uri.encodeComponent('${item['id']}')}/read',
      ).then((result) {
        if (mounted) {
          setState(
            () => item['readAt'] =
                result['readAt'] ?? DateTime.now().millisecondsSinceEpoch,
          );
        }
      }, onError: (_) {});
    }
    final postId = item['postId'];
    if (postId != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PostScreen(id: '$postId')),
      );
    } else if (item['actorUid'] != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CommunityUserScreen(uid: '${item['actorUid']}'),
        ),
      );
    }
  }

  Future<void> _readAll() async {
    try {
      await communityRequest('PUT', '/api/v1/community/notifications/read-all');
      final now = DateTime.now().millisecondsSinceEpoch;
      if (mounted) {
        setState(() {
          for (final item in items) {
            item['readAt'] ??= now;
          }
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = AppScope.of(context).text.locale;
    return ShellPage(
      title: communityLabel(context, 'notifications', 'Notifications'),
      actions: [
        if (items.any((item) => item['readAt'] == null))
          BarAction(
            icon: Symbols.done_all_rounded,
            label: communityLabel(context, 'markAllRead', 'Mark all read'),
            onPressed: _readAll,
          ),
      ],
      body: list(
        context,
        empty: communityLabel(
          context,
          'emptyNotifications',
          'No notifications yet',
        ),
        [
          for (final (index, item) in items.indexed) ...[
            if (index > 0) const Divider(height: 1),
            ListTile(
              onTap: () => _open(item),
              tileColor: item['readAt'] == null
                  ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.4)
                  : null,
              leading: CommunityAvatar(
                image: item['actorImage'],
                name: '${item['actorName'] ?? 'haneoka'}',
              ),
              title: Text('${item['actorName'] ?? 'haneoka'}'),
              subtitle: Text(_label(item)),
              trailing: Text(
                formatCommunityTime(item['createdAt'], locale)?.text ?? '',
                style: theme.textTheme.labelMedium,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The reader's own comments (`mode === "activity"`).
class CommunityActivityScreen extends StatefulWidget {
  const CommunityActivityScreen({super.key});
  @override
  State<CommunityActivityScreen> createState() => _ActivityState();
}

class _ActivityState extends _PagedState<CommunityActivityScreen> {
  @override
  String get listKey => 'comments';
  @override
  bool get needsSession => true;
  @override
  String endpoint(String? cursor) => Uri(
    path: '/api/v1/community/me/comments',
    queryParameters: {'cursor': ?cursor, 'limit': '20'},
  ).toString();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ShellPage(
      title: communityLabel(context, 'activity', 'My comments'),
      body: list(context, [
        for (final comment in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Material(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(Corner.large),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${comment['postTitle'] ?? communityLabel(context, 'activityPost', 'Post')}',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    CommunityContext(record: comment),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(communityExcerpt('${comment['body'] ?? ''}')),
                    ),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  PostScreen(id: '${comment['postId']}'),
                            ),
                          ),
                          child: Text(
                            communityLabel(
                              context,
                              'activityPost',
                              'Open post',
                            ),
                          ),
                        ),
                        CommunityRecordMenu(
                          kind: 'comment',
                          record: comment,
                          onChanged: (_) => load(reset: true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// A forum's artwork symbol (`forumIcon`).
IconData forumIcon(Object? name) => switch (name) {
  'chat' => Symbols.chat_rounded,
  'style' => Symbols.style_rounded,
  'emoji_emotions' => Symbols.emoji_emotions_rounded,
  'music_note' => Symbols.music_note_rounded,
  'auto_stories' => Symbols.auto_stories_rounded,
  'groups' => Symbols.groups_rounded,
  'menu_book' => Symbols.menu_book_rounded,
  'help' => Symbols.help_rounded,
  'lightbulb' => Symbols.lightbulb_rounded,
  'flag' => Symbols.flag_rounded,
  _ => Symbols.forum_rounded,
};

String _localized(Object? names, String locale, [Object? fallback]) {
  final map = jsonMap(names);
  return '${map[locale] ?? map['en'] ?? map.values.firstOrNull ?? fallback ?? ''}';
}

/// Forums by group (`renderForumDirectory`).
class CommunityForumsScreen extends StatefulWidget {
  const CommunityForumsScreen({super.key});
  @override
  State<CommunityForumsScreen> createState() => _ForumsState();
}

class _ForumsState extends State<CommunityForumsScreen> {
  Future<Json>? _directory;

  @override
  void initState() {
    super.initState();
    _directory = HaneokaAccount.instance.load().then(
      (_) => communityRequest('GET', '/api/v1/community/forums'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = AppScope.of(context).text.locale;
    final number = NumberFormat.decimalPattern(locale);
    return ShellPage(
      title: AppScope.of(context).text('navigation.community', 'Community'),
      body: FutureBuilder(
        future: _directory,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return Center(
              child: snapshot.hasError
                  ? Text(communityLabel(context, 'unavailable', 'Unavailable'))
                  : const CircularProgressIndicator(),
            );
          }
          final forums = [
            for (final forum in jsonList(data['forums']))
              if (jsonMap(forum['capabilities'])['canRead'] != false &&
                  forum['isInternal'] != true)
                forum,
          ];
          final groups = [
            ...jsonList(data['groups']),
            {
              'id': '',
              'defaultName': communityLabel(context, 'forums', 'Forums'),
            },
          ];
          return ListView(
            padding: pagePadding(context),
            children: [
              for (final group in groups)
                if (forums.any(
                  (f) => '${f['groupId'] ?? ''}' == group['id'],
                )) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 12),
                    child: Text(
                      _localized(group['names'], locale, group['defaultName']),
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = ((constraints.maxWidth + 8) / 248)
                          .floor()
                          .clamp(2, 4);
                      final width =
                          (constraints.maxWidth - 8 * (columns - 1)) / columns;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final forum in forums.where(
                            (f) => '${f['groupId'] ?? ''}' == group['id'],
                          ))
                            SizedBox(
                              width: width,
                              child: Material(
                                color: scheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(
                                  Corner.large,
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          CommunityForumScreen(forum: forum),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              width: 36,
                                              height: 36,
                                              decoration: BoxDecoration(
                                                color: scheme
                                                    .surfaceContainerHighest,
                                                borderRadius:
                                                    BorderRadius.circular(
                                                      Corner.small,
                                                    ),
                                              ),
                                              child: Icon(
                                                forumIcon(forum['icon']),
                                                size: 22,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    _localized(
                                                      forum['names'],
                                                      locale,
                                                      forum['defaultName'],
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: theme
                                                        .textTheme
                                                        .titleSmall,
                                                  ),
                                                  if (forum['postCount']
                                                      case final num count)
                                                    Text(
                                                      number.format(count),
                                                      style: theme
                                                          .textTheme
                                                          .labelSmall,
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          _localized(
                                            forum['descriptions'],
                                            locale,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                ],
            ],
          );
        },
      ),
    );
  }
}

/// One forum: its header and its topics (`renderForumHeader`,
/// `renderTopicRow`).
class CommunityForumScreen extends StatefulWidget {
  const CommunityForumScreen({super.key, required this.forum});
  final Json forum;
  @override
  State<CommunityForumScreen> createState() => _ForumState();
}

class _ForumState extends _PagedState<CommunityForumScreen> {
  @override
  String get listKey => 'posts';
  @override
  String endpoint(String? cursor) => Uri(
    path: '/api/v1/community/posts',
    queryParameters: {
      'cursor': ?cursor,
      'limit': '20',
      'scope': 'latest',
      'state': 'active',
      'forumId': '${widget.forum['id']}',
    },
  ).toString();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = AppScope.of(context).text.locale;
    final number = NumberFormat.decimalPattern(locale);
    final forum = widget.forum;
    final canPost = jsonMap(forum['capabilities'])['canPost'] == true;
    return ShellPage(
      title: _localized(forum['names'], locale, forum['defaultName']),
      body: list(context, [
        Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Corner.large),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(Corner.small),
                  ),
                  child: Icon(forumIcon(forum['icon']), size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _localized(
                          forum['names'],
                          locale,
                          forum['defaultName'],
                        ),
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(_localized(forum['descriptions'], locale)),
                      const SizedBox(height: 8),
                      if (forum['postCount'] case final num count)
                        Text(
                          communityLabel(
                            context,
                            'forumPostCount',
                            '{count} topics',
                            {'count': number.format(count)},
                          ),
                          style: theme.textTheme.bodySmall,
                        ),
                      if (!canPost)
                        Text(
                          communityLabel(
                            context,
                            'forumReadOnly',
                            'You can read this forum. Posting is restricted.',
                          ),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(Corner.large),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  communityLabel(context, 'topics', 'Topics'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              for (final (index, post) in items.indexed) ...[
                if (index > 0) const Divider(height: 1),
                _TopicRow(post: post),
              ],
            ],
          ),
        ),
      ]),
    );
  }
}

class _TopicRow extends StatelessWidget {
  const _TopicRow({required this.post});
  final Json post;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = AppScope.of(context).text.locale;
    final number = NumberFormat.decimalPattern(locale);
    final media = postMedia(post)
        .where((m) => mediaThumbnail(m).isNotEmpty)
        .firstOrNull;
    final tags = (post['tags'] as List? ?? const []).map(
      (tag) => tag is Map
          ? '${tag['displayName'] ?? tag['normalizedName']}'
          : '$tag',
    );
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PostScreen(id: '${post['id']}', initial: post),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${post['title'] ?? communityLabel(context, 'emptyTitle', 'Untitled')}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        communityExcerpt(
                          '${post['excerpt'] ?? post['body'] ?? ''}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                if (media != null) ...[
                  const SizedBox(width: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Corner.small),
                    child: SizedBox(
                      width: 64,
                      height: 48,
                      child: AppImage(
                        candidates: [absoluteUrl(mediaThumbnail(media))],
                        fit: BoxFit.cover,
                        localized: false,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (tags.isNotEmpty || post['pinnedAt'] != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (post['pinnedAt'] != null)
                    Chip(
                      avatar: const Icon(Symbols.keep_rounded, size: 14),
                      label: Text(
                        communityLabel(
                          context,
                          'pinnedTopics',
                          'Pinned topics',
                        ),
                      ),
                    ),
                  for (final tag in tags)
                    ActionChip(
                      label: Text('#$tag'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              CommunityFeedScreen(scope: 'latest', tag: tag),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${post['authorName'] ?? communityLabel(context, 'member', 'Member')}',
                        style: theme.textTheme.labelMedium,
                      ),
                      Text(
                        formatCommunityTime(post['createdAt'], locale)?.text ??
                            '',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Symbols.chat_bubble_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(number.format((post['commentCount'] as num?) ?? 0)),
                const SizedBox(width: 12),
                Icon(
                  Symbols.favorite_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(number.format((post['likeCount'] as num?) ?? 0)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A forum opened by its address (`/community/forums/{slug}`).
class CommunityForumBySlug extends StatefulWidget {
  const CommunityForumBySlug({super.key, required this.slug});
  final String slug;
  @override
  State<CommunityForumBySlug> createState() => _ForumBySlugState();
}

class _ForumBySlugState extends State<CommunityForumBySlug> {
  late final Future<Json> _forum = HaneokaAccount.instance.load().then(
    (_) => communityRequest(
      'GET',
      '/api/v1/community/forums/by-slug/${Uri.encodeComponent(widget.slug)}',
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _forum,
    builder: (context, snapshot) {
      final forum = jsonMap(snapshot.data?['forum']);
      if (forum.isNotEmpty) return CommunityForumScreen(forum: forum);
      return ShellPage(
        title: AppScope.of(context).text('navigation.community', 'Community'),
        body: Center(
          child: snapshot.hasError
              ? Text(communityLabel(context, 'unavailable', 'Unavailable'))
              : const CircularProgressIndicator(),
        ),
      );
    },
  );
}
