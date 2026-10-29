import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../ui/shapes.dart';
import 'community_widgets.dart';
import 'post_screen.dart';
import 'reactions.dart';

/// The thread a catalogue entry's comments live in (`detailCommentTarget`),
/// or null where the website has none.
({String type, String id})? entityCommentTarget(
  String resource,
  Map<String, Object?> item,
  String server,
) {
  if (server != 'jp' && server != 'intl') return null;
  String? decimal(Object? value) {
    final text = value is num && value == value.truncate()
        ? '${value.toInt()}'
        : value;
    return text is String && RegExp(r'^[1-9]\d{0,15}$').hasMatch(text)
        ? text
        : null;
  }

  const fields = {
    'cards': 'cardId',
    'support-cards': 'supportCardId',
    'characters': 'characterId',
    'songs': 'musicId',
    'song-meta': 'musicId',
    'band-items': 'bandItemId',
    'items': 'itemId',
    'comics': 'comicId',
    'stamps': 'stampId',
    'stickers': 'stickerId',
    'backgrounds': 'backgroundId',
  };
  var type = resource == 'song-meta' ? 'songs' : resource;
  String? id;
  if (fields[resource] case final field?) {
    id = decimal(item[field]);
  } else if (const {'passes', 'missions', 'real-lives'}.contains(resource)) {
    const variants = {
      'season-pass': ('passes-season', 'season-'),
      'monthly-pass': ('passes-monthly', 'monthly-'),
      'regular-mission': ('missions-regular', 'regular-mission-'),
      'limited-mission': ('missions-limited', 'limited-mission-'),
      'real-live': ('real-lives', 'real-live-'),
    };
    final variant = variants['${item['kind'] ?? ''}'];
    if (variant == null ||
        (resource == 'passes' && !variant.$1.startsWith('passes-')) ||
        (resource == 'missions' && !variant.$1.startsWith('missions-')) ||
        (resource == 'real-lives' && variant.$1 != 'real-lives')) {
      return null;
    }
    type = variant.$1;
    final raw = item['id'];
    id = raw is String && raw.startsWith(variant.$2)
        ? decimal(raw.substring(variant.$2.length))
        : null;
  } else if (const {
    'events',
    'gacha',
    'login-campaigns',
    'exchange',
    'circle',
    'challenge',
    'shop',
    'tgw-card',
  }.contains(resource)) {
    const kinds = {
      'events': 'game-event',
      'gacha': 'gacha',
      'login-campaigns': 'login',
      'exchange': 'exchange',
      'circle': 'circle',
      'challenge': 'challenge',
      'shop': 'shop',
    };
    if (kinds[resource] case final kind? when item['kind'] != kind) return null;
    final tables = item['sourceTables'];
    if (resource == 'events' &&
        item['sourceTable'] != 'MasterEvent' &&
        !(tables is List && tables.contains('MasterEvent'))) {
      return null;
    }
    if (resource == 'shop' && item['sourceTable'] != 'MasterShop') return null;
    if (resource == 'tgw-card' && item['sourceTable'] != 'MasterVip') {
      return null;
    }
    id = decimal(item[resource == 'tgw-card' ? 'rank' : 'id']);
  } else {
    return null;
  }
  final raw = item['raw'];
  if (id == null ||
      (raw is Map && raw['_id'] != null && decimal(raw['_id']) != id)) {
    return null;
  }
  return (type: type, id: id);
}

/// Comments on a catalogue entry (`entity-comments`).
class EntityComments extends StatefulWidget {
  const EntityComments({
    super.key,
    required this.type,
    required this.id,
    required this.server,
  });
  final String type;
  final String id;
  final String server;
  @override
  State<EntityComments> createState() => _EntityCommentsState();
}

class _EntityCommentsState extends State<EntityComments> {
  List<Json> _comments = [];
  String? _cursor;
  int _count = 0;
  String _sort = 'hot';
  bool _loading = true;
  bool _initialLoadStarted = false;
  Object? _queryKey;
  int _generation = 0;
  Object? _error;
  final _expanded = <String>{};
  final _replyLoading = <String>{};

  String get _endpoint =>
      '/api/v1/community/entity-threads/${Uri.encodeComponent(widget.type)}/${Uri.encodeComponent(widget.id)}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = (
      widget.type,
      widget.id,
      widget.server,
      AppScope.of(context).text.locale,
    );
    final changed = _queryKey != null && _queryKey != key;
    _queryKey = key;
    if (changed && _initialLoadStarted) {
      _expanded.clear();
      _replyLoading.clear();
      _comments = [];
      _cursor = null;
      _count = 0;
      _load();
    }
    if (!_initialLoadStarted) {
      _initialLoadStarted = true;
      HaneokaAccount.instance.load().then((_) => _load());
    }
  }

  Map<String, String> _query() => {
    'commentsSort': _sort,
    'locale': AppScope.of(context).text.locale,
    'server': widget.server,
  };

  Future<void> _load({bool append = false}) async {
    if (!mounted) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await communityRequest(
        'GET',
        '$_endpoint?${Uri(queryParameters: {..._query(), if (append && _cursor != null) 'commentsCursor': _cursor!}).query}',
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        final incoming = jsonList(data['comments']);
        final known = {for (final c in _comments) '${c['id']}'};
        _comments = append
            ? [
                ..._comments,
                for (final c in incoming)
                  if (known.add('${c['id']}')) c,
              ]
            : incoming;
        _cursor = (data['commentsNextCursor'] ?? data['nextCursor']) as String?;
        _count = (data['commentCount'] as num?)?.toInt() ?? _comments.length;
        _loading = false;
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

  Future<void> _loadReplies(String rootId) async {
    final root = _comments.where((c) => '${c['id']}' == rootId).firstOrNull;
    final cursor = root?['replyCursor'];
    if (cursor == null || _replyLoading.contains(rootId)) return;
    final generation = _generation;
    setState(() => _replyLoading.add(rootId));
    try {
      final data = await communityRequest(
        'GET',
        '$_endpoint?${Uri(queryParameters: {..._query(), 'commentsRoot': rootId, 'commentsCursor': '$cursor'}).query}',
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
      if (mounted && generation == _generation) {
        setState(() => _replyLoading.remove(rootId));
      }
    }
  }

  Future<void> _compose({Json? replyTo}) async {
    if (!await requireSession(context) || !mounted) return;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CommentComposer(
        postPath: _endpoint,
        replyTo: replyTo,
        replyName: replyTo == null ? null : authorName(context, replyTo),
      ),
    );
    if (sent == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = AppScope.of(context).text.locale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ShapedIcon(
              shape: MaterialShapes.cookie9Sided,
              size: 36,
              child: const Icon(Symbols.forum_rounded, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                communityLabel(context, 'commentCount', '{count} comments', {
                  'count': NumberFormat.decimalPattern(locale).format(_count),
                }),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
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
              onSelectionChanged: (v) {
                _sort = v.single;
                _expanded.clear();
                _load();
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Material(
          color: scheme.surfaceContainerHigh,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => _compose(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(
                    Symbols.edit_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    HaneokaAccount.instance.signedIn
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
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_loading && _comments.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null && _comments.isEmpty)
          Center(
            child: TextButton(
              onPressed: _load,
              child: Text(communityLabel(context, 'retry', 'Retry')),
            ),
          )
        else if (_comments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              communityLabel(
                context,
                'emptyComments',
                'Start the conversation',
              ),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          ...commentThreads(
            context,
            comments: _comments,
            authorUid: null,
            expanded: _expanded,
            replyLoading: _replyLoading,
            onExpand: (id, open) =>
                setState(() => open ? _expanded.add(id) : _expanded.remove(id)),
            onLoadReplies: _loadReplies,
            onChanged: (comment) {
              if (comment['_refreshThread'] == true) {
                _load();
                return;
              }
              setState(() {
                _comments = [
                  for (final c in _comments)
                    c['id'] == comment['id'] ? comment : c,
                ];
              });
            },
            onReply: (comment) => _compose(replyTo: comment),
          ),
          if (_cursor != null)
            Center(
              child: TextButton(
                onPressed: _loading ? null : () => _load(append: true),
                child: Text(
                  communityLabel(
                    context,
                    'loadMoreComments',
                    'Load more comments',
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
