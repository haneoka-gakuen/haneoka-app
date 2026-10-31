import 'comments_panel.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/browse.dart';
import '../chart_editor/project.dart';
import '../community/reactions.dart';
import '../community/charts_screen.dart';
import '../playlists/playlists_screen.dart';
import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/detail.dart';
import '../ui/tile.dart';
import '../ui/account_dialog.dart';
import 'controller.dart';
import 'forms.dart';
import 'statistics.dart';
import 'user_dialog.dart';
import 'analytics.dart';
import 'resources.dart';
import 'post_review.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({
    super.key,
    this.section = 'overview',
    this.query = const {},
  });
  final String section;
  final Map<String, String> query;
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  String _commentQuery = '';
  late final c = AdminController(
    adminSections.contains(widget.section) ? widget.section : 'overview',
    initialQuery: widget.query,
  )..addListener(_changed);
  Timer? _search;
  String? _shownError;
  String t(String key) => AppScope.of(context).text('admin.page.$key');
  @override
  void initState() {
    super.initState();
    unawaited(c.load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    c.onNavigate = ShellScope.of(context)?.navigate;
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (c.error != null && c.error != _shownError) {
      _shownError = c.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(c.staff.isEmpty ? 'forbidden' : 'actions.failed'),
              ),
            ),
          );
        }
      });
    }
    if (c.error == null) _shownError = null;
  }

  void _query(String value) {
    _search?.cancel();
    _search = Timer(const Duration(milliseconds: 300), () {
      if (value.trim().isEmpty) {
        c.query.remove('q');
      } else {
        c.query['q'] = value.trim();
      }
      unawaited(c.load());
    });
  }

  @override
  void dispose() {
    _search?.cancel();
    c.removeListener(_changed);
    c.dispose();
    super.dispose();
  }

  List<BarAction> get _actions => [
    if (c.section == 'posts')
      BarAction.choice(
        label: t('creations.content'),
        options: [
          for (final kind in ['posts', 'charts', 'playlists'])
            BarChoice(
              icon: kind == 'charts'
                  ? Symbols.piano_rounded
                  : kind == 'playlists'
                  ? Symbols.queue_music_rounded
                  : Symbols.article_rounded,
              label: t('creations.$kind'),
              selected: c.contentKind == kind,
              onSelected: () => c.selectContent(kind),
            ),
        ],
      ),
    BarAction.choice(
      label: t('title'),
      options: [
        for (final section in adminSections)
          if (c.staff['role'] == 'admin' || section == 'appeals')
            BarChoice(
              icon: _icon(section),
              label: t('sections.$section'),
              selected: c.section == section,
              onSelected: () => c.select(section),
            ),
      ],
    ),
    BarAction(
      icon: Symbols.refresh_rounded,
      label: t('refresh'),
      onPressed: c.loading ? null : () => c.load(),
    ),
    if (c.cursor != null)
      BarAction(
        icon: Symbols.more_horiz_rounded,
        label: t('loadMore'),
        onPressed: c.loading ? null : () => c.load(append: true),
      ),
    if (const {'users', 'posts'}.contains(c.section))
      BarAction(
        icon: Symbols.filter_alt_rounded,
        label: AppScope.of(context).text('common.actions.filter'),
        onPressed: _filters,
      ),
  ];
  IconData _icon(String section) => switch (section) {
    'users' => Symbols.group_rounded,
    'posts' => Symbols.article_rounded,
    'forums' => Symbols.forum_rounded,
    'reports' => Symbols.flag_rounded,
    'appeals' => Symbols.balance_rounded,
    'comments' => Symbols.forum_rounded,
    'operations' => Symbols.settings_rounded,
    _ => Symbols.dashboard_rounded,
  };
  String _title(ChartMap row) =>
      '${row['publicDisplayName'] ?? row['displayName'] ?? row['accountName'] ?? row['name'] ?? row['title'] ?? row['id'] ?? ''}';
  String _value(Object? value) {
    if (value == null) return '—';
    if (value is bool) {
      return AppScope.of(context)
          .text(value ? 'common.states.yes' : 'common.states.no');
    }
    final key = '$value', localized = t('values.$key');
    final role = t('roles.$key');
    return localized.isNotEmpty
        ? localized
        : role.isNotEmpty
        ? role
        : key;
  }

  String _date(Object? value) {
    if (value == null) return '—';
    final n = value is num ? value.toInt() : int.tryParse('$value');
    final parsed = n == null
        ? DateTime.tryParse('$value')
        : DateTime.fromMillisecondsSinceEpoch(n);
    return parsed?.toLocal().toString().split('.').first ?? '—';
  }

  Future<void> _filters() async {
    final roles = {
      '': t('userDetails.allRoles'),
      for (final role in adminRoles) role: t('roles.$role'),
    };
    await editAdminFields(
      context,
      title: AppScope.of(context).text('common.actions.filter'),
      initial: {...c.query},
      fields: [
        if (c.section == 'users')
          AdminField('role', t('columns.role'), options: roles),
        AdminField(
          'status',
          t('columns.status'),
          options: {
            '': t('userDetails.allStatuses'),
            for (final s
                in c.section == 'users'
                    ? ['active', 'suspended', 'deleted']
                    : c.contentKind != 'posts'
                    ? ['draft', 'published', 'deleted']
                    : ['published', 'draft', 'hidden'])
              s: _value(s),
          },
        ),
        if (c.section == 'posts' && c.contentKind == 'posts')
          AdminField(
            'moderationStatus',
            t('columns.moderation'),
            options: {
              '': t('userDetails.allStatuses'),
              for (final status in ['pending', 'review', 'block', 'allow'])
                status: _value(status),
            },
          ),
      ],
      save: (value) async {
        for (final key in ['role', 'status', 'moderationStatus']) {
          if (value[key] == null || value[key] == '') {
            c.query.remove(key);
          } else {
            c.query[key] = '${value[key]}';
          }
        }
        await c.load();
        return c.error == null;
      },
    );
  }

  String _filterLabel(String key) {
    if (key.startsWith('geo') || key.startsWith('visited')) {
      return t('analytics.filters.$key');
    }
    return key == 'forumId'
        ? t('sections.forums')
        : t(
            'columns.${switch (key) {
              'moderationStatus' => 'moderation',
              'authorId' => 'author',
              _ => key,
            }}',
          );
  }

  Widget? _filterMarks() {
    final filters = c.query.entries
        .where(
          (entry) => const {
            'role',
            'status',
            'moderationStatus',
            'authorId',
            'forumId',
            'geoCountry',
            'geoRegion',
            'geoCity',
            'geoCountryUnknown',
            'geoRegionUnknown',
            'geoCityUnknown',
            'geoLat',
            'geoLng',
            'geoCoordinates',
            'visitedFrom',
            'visitedTo',
          }.contains(entry.key),
        )
        .toList();
    if (filters.isEmpty) return null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in filters)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: _filterLabel(entry.key),
                child: InputChip(
                  label: Text(
                    entry.key.startsWith('visited')
                        ? _date(entry.value)
                        : _value(entry.value),
                  ),
                  onDeleted: () {
                    final next = {...c.query}..remove(entry.key);
                    if (entry.key == 'geoLat' || entry.key == 'geoLng') {
                      next.remove('geoLat');
                      next.remove('geoLng');
                    }
                    unawaited(c.select(c.section, filters: next));
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AccountDialog(
          child: AlertDialog(
            title: Text(title),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppScope.of(context).text('common.actions.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(
                  AppScope.of(context).text('common.actions.confirm'),
                ),
              ),
            ],
          ),
        ),
      ) ??
      false;
  Future<void> _record(ChartMap row) async {
    if (c.section == 'users') {
      await _user(row);
      return;
    }
    if (c.section == 'posts') {
      if (c.contentKind == 'posts') {
        await _post(row);
      } else {
        await _creation(row);
      }
      return;
    }
    if (c.section == 'reports' || c.section == 'appeals') {
      final section = c.section;
      await showDialog<void>(
        context: context,
        builder: (context) => AccountDialog(
          child: AlertDialog(
            title: Text(_title(row)),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(child: _facts(row)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppScope.of(context).text('common.actions.close')),
              ),
              for (final action
                  in section == 'reports'
                      ? ['reviewing', 'resolved', 'dismissed']
                      : ['accepted', 'rejected'])
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () async {
                          if (section == 'reports') {
                            await c.report(row, action);
                          } else {
                            await c.appeal(row, action);
                          }
                          if (context.mounted && c.error == null) {
                            Navigator.pop(context);
                          }
                        },
                  child: Text(_value(action)),
                ),
            ],
          ),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AccountDialog(
        child: AlertDialog(
          title: Text(_title(row)),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(child: _facts(row)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppScope.of(context).text('common.actions.close')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _facts(ChartMap row, {String prefix = 'columns'}) {
    final facts = <Fact>[];
    for (final entry in row.entries) {
      if (entry.value is Map || entry.value is List) continue;
      final specific = t('$prefix.${entry.key}');
      final mapped = const {
        'version': 'history.revision',
        'updatedAt': 'workspace.updated',
        'reasonCode': 'history.reason',
        'body': 'workspace.postContent',
        'publishedAt': 'values.published',
        'revokedAt': 'userDetails.revokedAt',
        'expiresAt': 'userDetails.expires',
        'accountName': 'accountName',
        'displayName': 'publicDisplayName',
        'title': 'columns.post',
        'authorName': 'columns.author',
        'authorAccountName': 'accountName',
        'email': 'userDetails.email',
        'userAgent': 'history.userAgent',
        'ip': 'ip.address',
        'ipAddress': 'history.ipAddress',
        'ipCountryCode': 'ip.country',
        'ipRegionCode': 'userDetails.regionCode',
        'ipRegionName': 'ip.region',
        'browserFamily': 'userDetails.browser',
        'osFamily': 'userDetails.platform',
        'countryCode': 'userDetails.countryCode',
        'regionCode': 'userDetails.regionCode',
      }[entry.key];
      final label = specific.isNotEmpty
          ? specific
          : mapped == null
          ? ''
          : t(mapped);
      if (label.isEmpty &&
          const {
                'id',
                'version',
                'createdAt',
                'updatedAt',
                'status',
                'role',
                'reasonCode',
                'detail',
                'body',
                'title',
                'slug',
                'email',
                'uid',
                'accountName',
                'displayName',
                'publishedAt',
                'revokedAt',
                'expiresAt',
                'userAgent',
                'ip',
                'countryCode',
                'regionCode',
              }.contains(entry.key) ==
              false) {
        continue;
      }
      final fallback = entry.key == 'uid'
          ? 'UID'
          : AppScope.of(context).text(
              'common.fields.${switch (entry.key) {
                'detail' => 'content',
                'slug' => 'id',
                _ => entry.key,
              }}',
            );
      facts.add(
        Fact(
          label.isNotEmpty
              ? label
              : fallback.isNotEmpty
              ? fallback
              : entry.key,
          entry.key.endsWith('At') ? _date(entry.value) : _value(entry.value),
        ),
      );
    }
    return SpecList(facts: facts);
  }

  Future<void> _user(ChartMap row) async {
    try {
      final response = await c.request('/api/v1/admin/users/${row['id']}');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AccountDialog(
          child: AdminUserDialog(
            controller: c,
            document: response,
            restrict: _restriction,
          ),
        ),
      );
    } catch (_) {
      if (mounted && c.staff.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t('actions.failed'))));
      }
    }
  }

  Future<void> _restriction(ChartMap user, String kind) async {
    await editAdminFields(
      context,
      title: t('actions.restrictions'),
      initial: {'duration': '604800000'},
      fields: [
        AdminField(
          'duration',
          t('userDetails.expires'),
          options: {
            '86400000': t('durations.day'),
            '604800000': t('durations.week'),
            '0': t('durations.permanent'),
          },
        ),
      ],
      save: (value) async {
        await c.restrict(user, kind, int.parse('${value['duration']}'));
        return c.error == null;
      },
    );
  }

  Future<void> _creation(ChartMap row) async {
    final kind = c.contentKind;
    try {
      final response = await c.request('/api/v1/admin/$kind/${row['id']}');
      if (!mounted || kind != c.contentKind) return;
      final record = chartMap(response['creation']);
      final details = chartRows(record['details']);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AccountDialog(
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => AlertDialog(
              title: Text(_title(record)),
              content: SizedBox(
                width: 700,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SpecList(
                        facts: [
                          Fact(t('columns.status'), _value(record['status'])),
                          Fact(
                            AppScope.of(context)
                                .text('community.page.visibility'),
                            _value(record['visibility']),
                          ),
                          Fact(
                            t('columns.author'),
                            '${record['authorName'] ?? record['authorAccountName'] ?? record['authorId']}',
                          ),
                          Fact(
                            t('columns.createdAt'),
                            _date(record['createdAt']),
                          ),
                          Fact(
                            t('workspace.updated'),
                            _date(record['updatedAt']),
                          ),
                        ],
                      ),
                      if (record['body'] != null && record['body'] != '') ...[
                        const SizedBox(height: 16),
                        SelectableText('${record['body']}'),
                      ],
                      if (kind == 'charts')
                        for (final revision in details)
                          DetailSection(
                            icon: Symbols.piano_rounded,
                            title:
                                '${t('history.revision')} ${revision['revision']}',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    if (revision['isHead'] == 1)
                                      Chip(label: Text(t('creations.latest'))),
                                    if (revision['isPublished'] == 1)
                                      Chip(label: Text(_value('published'))),
                                  ],
                                ),
                                Text('${revision['title']}'),
                                SpecList(
                                  facts: [
                                    Fact(
                                      t('creations.artist'),
                                      '${revision['artist'] ?? '—'}',
                                    ),
                                    Fact(
                                      t('creations.charter'),
                                      '${revision['charter'] ?? '—'}',
                                    ),
                                    Fact(
                                      t('creations.difficulty'),
                                      '${revision['difficulty']} ${revision['level']}',
                                    ),
                                    Fact(
                                      t('columns.createdAt'),
                                      _date(revision['createdAt']),
                                    ),
                                    if (revision['publishedAt'] != null)
                                      Fact(
                                        _value('published'),
                                        _date(revision['publishedAt']),
                                      ),
                                  ],
                                ),
                                if (revision['summary'] != null &&
                                    revision['summary'] != '')
                                  SelectableText('${revision['summary']}'),
                              ],
                            ),
                          ),
                      if (kind == 'playlists')
                        DetailSection(
                          icon: Symbols.queue_music_rounded,
                          title: t('creations.tracks'),
                          count: details.length,
                          child: Column(
                            children: [
                              for (final track in details)
                                ListTile(
                                  leading: Text(
                                    '${(track['position'] as num).toInt() + 1}',
                                  ),
                                  title: Text('${track['musicId']}'),
                                  subtitle: Text(
                                    '${track['provider']} · ${track['server']}',
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                if (record['status'] == 'published' &&
                    record['visibility'] == 'public')
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      Navigator.of(this.context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => kind == 'charts'
                              ? CommunityChartScreen(id: '${record['id']}')
                              : PlaylistsScreen(open: '${record['id']}'),
                        ),
                      );
                    },
                    child: Text(t('creations.open')),
                  ),
                if (record['deletedAt'] == null)
                  TextButton(
                    onPressed: c.busy
                        ? null
                        : () async {
                            if (!await _confirm(t('creations.confirmRemove'))) {
                              return;
                            }
                            await c.removeCreation(kind, record);
                            if (dialogContext.mounted && c.error == null) {
                              Navigator.pop(dialogContext);
                            }
                          },
                    child: Text(
                      t('creations.remove'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () {
                          Navigator.pop(dialogContext);
                          unawaited(_creation(row));
                        },
                  child: Text(t('refresh')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(
                    AppScope.of(context).text('common.actions.close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted && c.staff.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t('actions.failed'))));
      }
    }
  }

  Future<void> _post(ChartMap row) => showDialog<void>(
    context: context,
    builder: (_) => AccountDialog(
      child: AdminPostReview(
        controller: c,
        id: '${row['id']}',
        facts: _facts,
        move: _move,
      ),
    ),
  );

  Future<void> _move(ChartMap post) async {
    await c.loadForums();
    if (!mounted) return;
    await editAdminFields(
      context,
      title: t('forum.movePost'),
      initial: {'forumId': '${post['forumId'] ?? ''}', 'reason': ''},
      fields: [
        AdminField(
          'forumId',
          t('forum.destination'),
          options: {
            for (final forum in c.forums)
              '${forum['id']}': AppScope.of(context).text.text(forum['names']),
          },
        ),
        AdminField('reason', t('forum.moveReason'), required: true),
      ],
      save: (value) async {
        await c.movePost(post, '${value['forumId']}', '${value['reason']}');
        return c.error == null;
      },
    );
  }

  Future<void> _forum({ChartMap? row, bool group = false}) async {
    final text = AppScope.of(context).text;
    final initial =
        row ??
        <String, Object?>{
          'slug': '',
          'names': {},
          'descriptions': {},
          'groupId': '',
          'icon': 'forum',
          'sortOrder': 0,
          'enabled': true,
          'permissions': {
            'read': 'public',
            'post': 'verified',
            'reply': 'verified',
            'manage': 'admin',
          },
          'defaultPurpose': '',
        };
    final fields = [
      AdminField('slug', t('forum.slug'), required: true),
      for (final locale in ['ja', 'en', 'zh-TW', 'zh-CN', 'ko'])
        AdminField('names.$locale', '${t('forum.name')} · $locale'),
      if (!group) ...[
        for (final locale in ['ja', 'en', 'zh-TW', 'zh-CN', 'ko'])
          AdminField(
            'descriptions.$locale',
            '${t('forum.description')} · $locale',
            multiline: true,
          ),
        AdminField(
          'groupId',
          t('forum.group'),
          options: {
            '': t('forum.ungrouped'),
            for (final g in c.groups) '${g['id']}': text.text(g['names']),
          },
        ),
        AdminField(
          'icon',
          t('forum.icon'),
          options: {
            for (final icon in [
              'forum',
              'chat',
              'style',
              'emoji_emotions',
              'music_note',
              'auto_stories',
              'groups',
              'menu_book',
              'help',
              'lightbulb',
              'flag',
            ])
              icon: t('forum.symbol.$icon'),
          },
        ),
        for (final key in ['read', 'post', 'reply', 'manage'])
          AdminField(
            'permissions.$key',
            t('forum.permission.$key'),
            options: {
              for (final value in [
                'public',
                'member',
                'verified',
                'moderator',
                'admin',
                'none',
              ])
                value: t('forum.audience.$value'),
            },
          ),
        AdminField('enabled', t('forum.availability'), toggle: true),
        AdminField(
          'defaultPurpose',
          t('forum.purpose'),
          options: {
            '': t('forum.noPurpose'),
            'general': t('forum.generalPurpose'),
            'stamp': t('forum.stampPurpose'),
          },
        ),
      ],
      AdminField('sortOrder', t('forum.order'), number: true),
    ];
    var previous = row;
    await editAdminFields(
      context,
      title: t(
        group
            ? (row == null ? 'forum.createGroup' : 'forum.editGroup')
            : (row == null ? 'forum.create' : 'forum.edit'),
      ),
      initial: initial,
      fields: fields,
      save: (value) async {
        if (!(value['names'] as Map).values.any(
          (v) => '$v'.trim().isNotEmpty,
        )) {
          return false;
        }
        final body = group
            ? <String, Object?>{
                for (final key in ['slug', 'names', 'sortOrder'])
                  key: value[key],
              }
            : <String, Object?>{
                for (final key in [
                  'slug',
                  'names',
                  'descriptions',
                  'icon',
                  'sortOrder',
                  'enabled',
                  'permissions',
                ])
                  key: value[key],
                'groupId': value['groupId'] == '' ? null : value['groupId'],
                'defaultPurpose': value['defaultPurpose'] == ''
                    ? null
                    : value['defaultPurpose'],
              };
        await c.saveForum(body, previous: previous, group: group);
        return c.error == null;
      },
      reload: row == null
          ? null
          : () async {
              await c.loadForums();
              previous = (group ? c.groups : c.forums)
                  .where((v) => v['id'] == row['id'])
                  .firstOrNull;
              return previous;
            },
    );
  }

  void _metric(String key) {
    final target = switch (key) {
      'totalUsers' || 'activeUsers' => ('users', <String, String>{}),
      'suspendedUsers' => ('users', {'status': 'suspended'}),
      'publishedPosts' => ('posts', {'status': 'published'}),
      'blockedPosts' => ('posts', {'moderationStatus': 'block'}),
      'pendingReports' => ('reports', {'status': 'pending'}),
      'pendingAppeals' => ('appeals', {'status': 'pending'}),
      _ => ('operations', <String, String>{}),
    };
    unawaited(c.select(target.$1, filters: target.$2));
  }

  Widget _overview() {
    final document = c.document;
    final settings = document['siteSettings'];
    return ListView(
      padding: pagePadding(context),
      children: [
        AdminStatistics(document: document, onMetric: _metric),
        if (c.staff['role'] == 'admin')
          AdminAnalytics(
            key: ValueKey((
              c.ownerGeneration,
              document['statisticsGeneratedAt'],
            )),
            controller: c,
          ),
        if (settings is Map)
          DetailSection(
            icon: Symbols.visibility_rounded,
            title: t('showRestrictedContent'),
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('showRestrictedContent')),
                  value: settings['showRestrictedContent'] == true,
                  onChanged: c.busy
                      ? null
                      : (value) => c.siteSettings({
                          'showRestrictedContent': value,
                          'contentAccessRoles': settings['contentAccessRoles'],
                          'expectedVersion': settings['version'],
                        }),
                ),
                for (final role in adminRoles)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('roles.$role')),
                    value: (settings['contentAccessRoles'] as List).contains(
                      role,
                    ),
                    onChanged: c.busy
                        ? null
                        : (value) {
                            final roles =
                                (settings['contentAccessRoles'] as List)
                                    .toSet();
                            if (value == true) {
                              roles.add(role);
                            } else {
                              roles.remove(role);
                            }
                            unawaited(
                              c.siteSettings({
                                'showRestrictedContent':
                                    settings['showRestrictedContent'],
                                'contentAccessRoles': adminRoles
                                    .where(roles.contains)
                                    .toList(),
                                'expectedVersion': settings['version'],
                              }),
                            );
                          },
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _forums() => ListView(
    padding: pagePadding(context),
    children: [
      Wrap(
        spacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => _forum(),
            icon: const Icon(Symbols.add_rounded),
            label: Text(t('forum.create')),
          ),
          OutlinedButton(
            onPressed: () => _forum(group: true),
            child: Text(t('forum.createGroup')),
          ),
        ],
      ),
      const SizedBox(height: 16),
      for (final row in c.forums)
        ListTile(
          title: Text(AppScope.of(context).text.text(row['names'])),
          subtitle: Text('${row['slug']}'),
          onTap: () => _forum(row: row),
        ),
      const Divider(),
      for (final group in c.groups)
        ListTile(
          title: Text(AppScope.of(context).text.text(group['names'])),
          subtitle: Text('${group['slug']}'),
          onTap: () => _forum(row: group, group: true),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    if (c.staff.isEmpty) {
      return ShellPage(
        title: t('title'),
        actions: _actions,
        body: Center(
          child: c.loading
              ? const CircularProgressIndicator()
              : FilledButton.tonal(
                  onPressed: () async {
                    if (await requireSession(context)) await c.load();
                  },
                  child: Text(t(c.error == null ? 'retry' : 'forbidden')),
                ),
        ),
      );
    }
    if (c.section == 'comments') {
      return ShellPage(
        title: t('sections.comments'),
        actions: _actions,
        search: ShellSearch(
          label: AppScope.of(context)
              .text('admin.comments.search', 'Search comments'),
          onChanged: (value) => setState(() => _commentQuery = value.trim()),
        ),
        body: ListView(
          padding: pagePadding(context),
          children: [
            AdminCommentsPanel(
              key: ValueKey(c.ownerGeneration),
              controller: c,
              query: _commentQuery,
            ),
          ],
        ),
      );
    }
    if (c.section == 'overview' || c.section == 'forums') {
      return ShellPage(
        title: t('sections.${c.section}'),
        actions: _actions,
        status: c.loading || c.busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        body: c.section == 'overview' ? _overview() : _forums(),
      );
    }
    return BrowseScreen(
      title: t('sections.${c.section}'),
      marks: _filterMarks(),
      heading: c.section == 'operations'
          ? AdminResources(key: ValueKey(c.ownerGeneration), controller: c)
          : null,
      items: c.loading && c.records.isEmpty ? null : c.records,
      error: c.error,
      onRetry: () => c.load(),
      itemId: (r) => '${r['id']}',
      search: const {'users', 'posts'}.contains(c.section)
          ? ShellSearch(
              label: t(
                c.section == 'users' ? 'columns.user' : 'workspace.searchPosts',
              ),
              onChanged: _query,
              initial: c.query['q'],
            )
          : null,
      searchText: (r) => '${_title(r)} ${r['body'] ?? ''} ${r['status'] ?? ''}',
      grid: const GridSpec(minWidth: 280, aspectRatio: 2),
      onOpen: (context, row) => _record(row),
      tile: (context, row) => Card(
        child: ListTile(
          title: Text(_title(row)),
          subtitle: Text(_value(row['status'] ?? row['role'])),
          onTap: () => _record(row),
        ),
      ),
      listRow: (context, row) => ListTile(
        title: Text(_title(row)),
        subtitle: Text(_value(row['status'] ?? row['role'])),
        trailing: const Icon(Symbols.chevron_right_rounded),
        onTap: () => _record(row),
      ),
      columns: [
        TableColumn(
          t(
            'columns.${c.section == 'users'
                ? 'user'
                : c.section == 'posts'
                ? 'post'
                : 'target'}',
          ),
          _title,
        ),
        TableColumn(
          t('columns.status'),
          (r) => _value(r['status'] ?? r['role']),
        ),
        TableColumn(t('columns.createdAt'), (r) => _date(r['createdAt'])),
      ],
      actions: (_) => _actions,
      sorts: [
        SortSpec('createdAt', t('columns.createdAt'), (r) => r['createdAt']),
      ],
    );
  }
}
