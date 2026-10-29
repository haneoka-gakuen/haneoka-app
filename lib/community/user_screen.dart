import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../shell/page.dart';
import '../shell/links.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'community_time.dart';
import 'community_widgets.dart';
import 'feed_screen.dart';
import 'reactions.dart';
import 'actions.dart';

/// A member's public profile (`renderUserDetail`): who they are, their
/// numbers, linked game accounts, works and posts.
class CommunityUserScreen extends StatefulWidget {
  const CommunityUserScreen({super.key, required this.uid});
  final String uid;
  @override
  State<CommunityUserScreen> createState() => _CommunityUserScreenState();
}

class _CommunityUserScreenState extends State<CommunityUserScreen> {
  Json? _document;
  List<Json> _posts = [];
  String? _cursor;
  bool _loadingMore = false;
  Object? _error;
  Object? _owner = HaneokaAccount.instance.user?['id'];
  int _generation = 0;
  bool _invalidated = false;
  void _invalidate() {
    if (mounted) setState(() => _invalidated = true);
  }

  void _accountChanged() {
    final owner = HaneokaAccount.instance.user?['id'];
    if (owner == _owner) return;
    _owner = owner;
    _generation++;
    setState(() {
      _document = null;
      _posts = [];
      _cursor = null;
    });
    _load();
  }

  String get _path =>
      '/api/v1/community/users/${Uri.encodeComponent(widget.uid)}';

  @override
  void initState() {
    super.initState();
    HaneokaAccount.instance.addListener(_accountChanged);
    communityDataRevision.addListener(_invalidate);
    HaneokaAccount.instance.load().then((_) => _load());
  }

  @override
  void dispose() {
    _generation++;
    HaneokaAccount.instance.removeListener(_accountChanged);
    communityDataRevision.removeListener(_invalidate);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_generation;
    try {
      final data = await communityRequest('GET', _path);
      if (!mounted || generation != _generation) return;
      _document = data;
      setState(() {
        _posts = [
          for (final post in jsonList(data['posts'])) _withAuthor(post),
        ];
        _cursor = data['postsNextCursor'] as String?;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    }
  }

  /// A profile's posts carry no author; it is the profile (`renderUserDetail`).
  Json _withAuthor(Json post) {
    final profile = jsonMap(_document?['profile']);
    return {
      ...post,
      'authorUid': post['authorUid'] ?? profile['uid'] ?? widget.uid,
      'authorName':
          post['authorName'] ?? profile['displayName'] ?? profile['handle'],
      'authorImage': post['authorImage'] ?? profile['avatarUrl'],
    };
  }

  Future<void> _more() async {
    if (_loadingMore || _cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final data = await communityRequest(
        'GET',
        '$_path?cursor=${Uri.encodeQueryComponent(_cursor!)}',
      );
      if (!mounted) return;
      final known = {for (final p in _posts) '${p['id']}'};
      setState(() {
        _posts = [
          ..._posts,
          for (final p in jsonList(data['posts']))
            if (known.add('${p['id']}')) _withAuthor(p),
        ];
        _cursor = data['postsNextCursor'] as String?;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _follow() async {
    if (_document == null) return;
    if (!await requireSession(context)) return;
    final viewer = jsonMap(_document?['viewer']);
    final following = viewer['following'] == true;
    try {
      final result = await communityRequest(
        'PUT',
        '$_path/follow',
        body: {'active': !following},
      );
      if (!mounted) return;
      setState(() {
        final profile = jsonMap(_document!['profile']);
        final stats = jsonMap(profile['stats']);
        final now = jsonMap(result['viewer'])['following'] == true;
        _document = {
          ..._document!,
          'viewer': {...viewer, 'following': now},
          'profile': {
            ...profile,
            'stats': {
              ...stats,
              'followers':
                  ((stats['followers'] as num?) ?? 0) +
                  (now == following ? 0 : (now ? 1 : -1)),
            },
          },
        };
      });
    } catch (_) {}
  }

  Future<void> _relationship(String action) async {
    if (!await requireSession(context) || !mounted) return;
    if (action == 'report') {
      await communityStatement(
        context,
        appeal: false,
        kind: 'user',
        id: widget.uid,
      );
      return;
    }
    final viewer = jsonMap(_document?['viewer']),
        active = viewer[action == 'mute' ? 'muted' : 'blocked'] != true;
    try {
      await communityRequest('PUT', '$_path/$action', body: {'active': active});
      invalidateCommunityData();
      await _load();
    } catch (_) {
      if (mounted) communityMessage(context, 'unavailable');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_invalidated && ModalRoute.of(context)?.isCurrent == true) {
      _invalidated = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final document = _document;
    final profile = jsonMap(document?['profile']);
    final name = '${profile['displayName'] ?? ''}';
    return ShellPage(
      title: name,
      actions: [
        if (document != null && jsonMap(document['profile'])['owner'] != true)
          for (final action in ['mute', 'block', 'report'])
            BarAction(
              icon: action == 'mute'
                  ? Symbols.volume_off_rounded
                  : action == 'block'
                  ? Symbols.block_rounded
                  : Symbols.flag_rounded,
              label: communityLabel(
                context,
                action == 'report'
                    ? 'report'
                    : (jsonMap(document['viewer'])[action == 'mute'
                                  ? 'muted'
                                  : 'blocked'] ==
                              true
                          ? 'un$action'
                          : action),
                action,
              ),
              onPressed: () => _relationship(action),
            ),
      ],
      body: document == null
          ? Center(
              child: _error != null
                  ? Text(communityLabel(context, 'unavailable', 'Unavailable'))
                  : const CircularProgressIndicator(),
            )
          : LayoutBuilder(
              builder: (context, constraints) =>
                  NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 800) _more();
                      return false;
                    },
                    child: ListView(
                      padding: pagePadding(context),
                      children: [
                        _ProfileHead(document: document, onFollow: _follow),
                        const SizedBox(height: 20),
                        _Stats(stats: jsonMap(profile['stats'])),
                        const SizedBox(height: 20),

                        PostMasonry(
                          items: _posts,
                          width: constraints.maxWidth,
                          onChanged: (item, next) => setState(
                            () => item
                              ..clear()
                              ..addAll(next),
                          ),
                        ),
                        if (jsonList(document['works']).isNotEmpty)
                          DetailSection(
                            icon: Symbols.library_books_rounded,
                            title: communityLabel(
                              context,
                              'customCharts',
                              'Works',
                            ),
                            count: jsonList(document['works']).length,
                            child: Column(
                              children: [
                                for (final work in jsonList(document['works']))
                                  ListTile(
                                    title: Text('${work['title'] ?? ''}'),
                                    subtitle: Text(
                                      '${work['summary'] ?? work['kind'] ?? ''}',
                                    ),
                                    onTap: work['url'] is String
                                        ? () => openLink(
                                            context,
                                            '${work['url']}',
                                          )
                                        : null,
                                  ),
                              ],
                            ),
                          ),
                        ..._gameAccounts(context, document),
                        if (_loadingMore)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ),
                  ),
            ),
    );
  }

  /// Linked Our Notes players: server, player ID, rank and rating.
  List<Widget> _gameAccounts(BuildContext context, Json document) {
    final accounts = jsonList(document['gameAccounts']);
    if (accounts.isEmpty) return const [];
    final theme = Theme.of(context);
    final t = AppScope.of(context).text;
    final number = NumberFormat.decimalPattern(t.locale);
    return [
      Text(
        communityLabel(context, 'gameAccounts', 'Game accounts'),
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      for (final account in accounts)
        Builder(
          builder: (context) {
            final summary = jsonMap(
              jsonMap(account['latestSnapshot'])['summary'],
            );
            final facts = [
              switch (account['region']) {
                'jp' => t('settings.labels.settingsJapan', 'Japan'),
                'intl' => t('settings.labels.settingsGlobal', 'International'),
                final other => '${other ?? ''}',
              },
              if (account['displayName'] != null &&
                  account['playerUid'] != null)
                communityLabel(
                  context,
                  'gameAccountPlayerId',
                  'Player ID {id}',
                  {'id': account['playerUid']},
                ),
              if (summary['rank'] case final num rank)
                communityLabel(
                  context,
                  'gameAccountRank',
                  'Player rank {value}',
                  {'value': number.format(rank)},
                ),
              if (summary['rating'] case final num rating)
                communityLabel(
                  context,
                  'gameAccountRating',
                  'High score rating {value}',
                  {'value': number.format(rating)},
                ),
            ].where((s) => s.isNotEmpty);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.secondaryContainer,
                child: const Icon(Symbols.sports_esports_rounded, size: 20),
              ),
              title: Text(
                '${account['displayName'] ?? account['playerUid'] ?? ''}',
              ),
              subtitle: Text(facts.join(' · ')),
            );
          },
        ),
      const SizedBox(height: 20),
    ];
  }
}

class _ProfileHead extends StatelessWidget {
  const _ProfileHead({required this.document, required this.onFollow});
  final Json document;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = AppScope.of(context).text.locale;
    final profile = jsonMap(document['profile']);
    final viewer = jsonMap(document['viewer']);
    final name = '${profile['displayName'] ?? ''}';
    final joined = communityTimestamp(profile['joinedAt']);
    final owner = profile['owner'] == true;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.large),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CommunityAvatar(
                  image: profile['avatarUrl'],
                  name: name,
                  size: 56,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if ('${profile['bio'] ?? ''}'.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '${profile['bio']}',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (joined != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          '${communityLabel(context, 'joined', 'Joined')} ${mediumDateTime(DateTime.fromMillisecondsSinceEpoch(joined), locale)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (!owner) ...[
              const SizedBox(height: 16),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: viewer['following'] == true
                    ? FilledButton.tonalIcon(
                        onPressed: onFollow,
                        icon: const Icon(Symbols.how_to_reg_rounded),
                        label: Text(
                          communityLabel(context, 'following', 'Following'),
                        ),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: onFollow,
                        icon: const Icon(Symbols.person_add_rounded),
                        label: Text(
                          communityLabel(context, 'follow', 'Follow'),
                        ),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.stats});
  final Json stats;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = AppScope.of(context).text.locale;
    final number = NumberFormat.decimalPattern(locale);
    final entries = [
      ('posts', 'Posts'),
      ('works', 'Works'),
      ('followers', 'Followers'),
      ('following', 'Following'),
      ('gameAccounts', 'Game accounts'),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final (key, fallback) in entries)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                number.format((stats[key] as num?) ?? 0),
                style: theme.textTheme.headlineSmall,
              ),
              Text(
                communityLabel(context, key, fallback),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
      ],
    );
  }
}
