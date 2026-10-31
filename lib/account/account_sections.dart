import '../core/site_date.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../save/game_save.dart';
import '../shell/links.dart';
import '../ui/detail.dart';
import 'haneoka_account.dart';

String _label(BuildContext context, String key, String fallback) =>
    AppScope.of(context).text('account.page.$key', fallback);
String? _date(BuildContext context, Object? value) {
  final date = switch (value) {
    final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
    final String text => DateTime.tryParse(text)?.toLocal(),
    _ => null,
  };
  return date == null
      ? null
      : SiteDate.day(AppScope.of(context).text.locale).format(date);
}

/// The browser and system a session's agent names, as on the website.
String deviceLabel(String agent) {
  String? find(List<(String, String)> rules) {
    for (final (pattern, name) in rules) {
      if (RegExp(pattern).hasMatch(agent)) return name;
    }
    return null;
  }

  final browser = find(const [
    (r'Edg/', 'Edge'),
    (r'SamsungBrowser', 'Samsung Internet'),
    (r'Firefox/', 'Firefox'),
    (r'Chrome/', 'Chrome'),
    (r'Safari/', 'Safari'),
    (r'[Dd]art/', 'Haneoka App'),
  ]);
  final system = find(const [
    (r'Android', 'Android'),
    (r'iPhone|iPad', 'iOS'),
    (r'Windows', 'Windows'),
    (r'Mac OS', 'macOS'),
    (r'Linux', 'Linux'),
  ]);
  return [?browser, ?system].join(' · ');
}

/// Name, handle, email, role, verification, UID and join date.
class AccountSummary extends StatelessWidget {
  const AccountSummary({super.key, this.avatar});
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    final account = HaneokaAccount.instance;
    final profile = account.profile ?? const {},
        user = account.user ?? const {};
    final theme = Theme.of(context);
    final uid = profile['publicUid'];
    final role = '${profile['role'] ?? 'member'}';
    final verified = user['emailVerified'] == true;
    final name =
        '${profile['displayName'] ?? profile['accountName'] ?? user['name'] ?? user['email'] ?? '?'}';
    final joined = _date(context, profile['createdAt']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          spacing: 12,
          children: [
            ?avatar,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.titleLarge),
                  if (profile['handle'] != null)
                    Text(
                      '@${profile['handle']}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  Text(
                    '${user['email'] ?? ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            Chip(
              avatar: const Icon(Symbols.person_rounded, size: 18),
              label: Text(
                _label(
                  context,
                  'role${role[0].toUpperCase()}${role.substring(1)}',
                  role,
                ),
              ),
            ),
            Chip(
              avatar: Icon(
                verified
                    ? Symbols.check_circle_rounded
                    : Symbols.alternate_email_rounded,
                size: 18,
              ),
              label: Text(
                verified
                    ? _label(context, 'verified', 'Verified')
                    : _label(context, 'verifyEmail', 'Verify email'),
              ),
            ),
          ],
        ),
        SpecList(
          facts: [
            if (uid != null)
              Fact(
                _label(context, 'publicUid', 'UID'),
                '$uid',
                widget: TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: '$uid')),
                  child: Text('$uid'),
                ),
              ),
            if (joined != null)
              Fact(_label(context, 'joined', 'Joined'), joined),
          ],
        ),
        if (uid != null)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () => openLink(context, '/community/users/$uid'),
              icon: const Icon(Symbols.open_in_new_rounded),
              label: Text(_label(context, 'publicProfile', 'Public profile')),
            ),
          ),
      ],
    );
  }
}

/// Every linked player with its real region.
class GameAccountsSection extends StatelessWidget {
  const GameAccountsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final players = HaneokaAccount.instance.players;
    final locale = AppScope.of(context).text.locale;
    return DetailSection(
      icon: Symbols.sports_esports_rounded,
      title: _label(context, 'gameAccounts', 'Game accounts'),
      count: players.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (players.isEmpty)
            Text(_label(context, 'listEmpty', 'None'))
          else
            for (final player in players)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Symbols.sports_esports_rounded),
                title: Text(player.name ?? player.profileId),
                subtitle: Text(
                  [
                    ?gameRegionNames[regionOfProfile(player.profileId)],
                    player.profileId,
                    player.public
                        ? _label(context, 'visibilityPublic', 'Public')
                        : _label(context, 'visibilityPrivate', 'Private'),
                  ].join(' · '),
                ),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => openLink(
                  context,
                  '/$locale/player-profile/?region=${regionOfProfile(player.profileId) ?? 'tw'}&profileId=${player.profileId}',
                ),
              ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () => openLink(context, '/$locale/player-profile/'),
              icon: const Icon(Symbols.person_search_rounded),
              label: Text(_label(context, 'findPlayer', 'Find a player')),
            ),
          ),
        ],
      ),
    );
  }
}

const _apiScopes = [
  'team:read',
  'team:write',
  'gacha:read',
  'games:read',
  'profile:read',
];

/// Open platform tokens: create, copy once, revoke, and what they changed.
class ApiTokensSection extends StatefulWidget {
  const ApiTokensSection({super.key});
  @override
  State<ApiTokensSection> createState() => _ApiTokensSectionState();
}

class _ApiTokensSectionState extends State<ApiTokensSection> {
  List<Map<String, Object?>> _tokens = const [], _events = const [];
  final _name = TextEditingController();
  int _days = 90;
  final _scopes = {'team:read'};
  bool _busy = false;

  Map<String, String> get _owner => {
    'X-Haneoka-Expected-User': '${HaneokaAccount.instance.user?['id'] ?? ''}',
  };
  List<Map<String, Object?>> _rows(Object? value) => [
    for (final row in value is List ? value : const [])
      if (row is Map) row.cast<String, Object?>(),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final body = objectOf(
        await HaneokaAccount.instance.request(
          'GET',
          '/api/v1/account/api-tokens',
          headers: _owner,
        ),
      );
      if (mounted) {
        setState(() {
          _tokens = _rows(body['tokens']);
          _events = _rows(body['events']);
        });
      }
    } catch (_) {}
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _create() async {
    if (_name.text.trim().isEmpty || _scopes.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final body = objectOf(
        await HaneokaAccount.instance.request(
          'POST',
          '/api/v1/account/api-tokens',
          headers: _owner,
          body: {
            'name': _name.text.trim(),
            'days': _days,
            'scopes': _scopes.toList(),
          },
        ),
      );
      _name.clear();
      if (!mounted) return;
      setState(() => _tokens = _rows(body['tokens']));
      await _show('${body['token']}');
    } on AccountError catch (error) {
      if (mounted) _say(error.code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _show(String value) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(_label(context, 'apiTokenShown', 'Copy this token now')),
      content: SelectableText(value),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_label(context, 'close', 'Close')),
        ),
        FilledButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (mounted) {
              _say(_label(this.context, 'apiTokenCopied', 'Token copied.'));
            }
          },
          child: Text(_label(context, 'apiTokenCopy', 'Copy')),
        ),
      ],
    ),
  );

  Future<void> _revoke(Map<String, Object?> token) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _label(context, 'apiTokenRevokeTitle', 'Revoke this token?'),
        ),
        content: Text('${token['name']}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_label(context, 'close', 'Close')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_label(context, 'revoke', 'Revoke')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final body = objectOf(
        await HaneokaAccount.instance.request(
          'DELETE',
          '/api/v1/account/api-tokens/${token['id']}',
          headers: _owner,
        ),
      );
      if (!mounted) return;
      setState(() => _tokens = _rows(body['tokens']));
      _say(_label(context, 'apiTokenRevoked', 'Token revoked.'));
    } on AccountError catch (error) {
      if (mounted) _say(error.code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    String scope(String key) =>
        _label(context, 'apiScope_${key.replaceAll(':', '_')}', key);
    return DetailSection(
      icon: Symbols.key_rounded,
      title: _label(context, 'apiTokens', 'API tokens'),
      count: _tokens.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          for (final token in _tokens)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Symbols.key_rounded),
              title: Text('${token['name']}'),
              subtitle: Text(
                [
                  ((token['scopes'] as List?) ?? const [])
                      .map((value) => scope('$value'))
                      .join(' · '),
                  '${_label(context, 'apiTokenExpires', 'Expires')} ${_date(context, token['expiresAt']) ?? ''} · ${_label(context, 'apiTokenUsed', 'Last used')} ${_date(context, token['lastUsedAt']) ?? _label(context, 'apiTokenNeverUsed', 'Never')}',
                ].join('\n'),
              ),
              trailing: TextButton(
                onPressed: () => _revoke(token),
                child: Text(_label(context, 'revoke', 'Revoke')),
              ),
            ),
          for (final event in _events.take(10))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Symbols.history_rounded),
              title: Text('${event['tokenName']}'),
              subtitle: Text(
                '${_label(context, 'apiTokenEventChanged', 'Box entries changed')}: ${NumberFormat.decimalPattern(t.locale).format(event['changed'] as num? ?? 0)} · ${'${event['server']}'.toUpperCase()} · ${_date(context, event['createdAt']) ?? ''}',
              ),
            ),
          TextField(
            controller: _name,
            maxLength: 64,
            decoration: InputDecoration(
              labelText: _label(context, 'apiTokenName', 'Token name'),
            ),
          ),
          DropdownMenu<int>(
            expandedInsets: EdgeInsets.zero,
            label: Text(_label(context, 'apiTokenLifetime', 'Valid for')),
            initialSelection: _days,
            dropdownMenuEntries: [
              for (final days in const [30, 90, 365])
                DropdownMenuEntry(
                  value: days,
                  label: _label(context, 'apiTokenDays$days', '$days days'),
                ),
            ],
            onSelected: (value) => setState(() => _days = value ?? 90),
          ),
          Text(
            _label(context, 'apiTokenScopes', 'Permissions'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          for (final key in _apiScopes)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(scope(key)),
              value: _scopes.contains(key),
              onChanged: (value) => setState(
                () => value == true ? _scopes.add(key) : _scopes.remove(key),
              ),
            ),
          FilledButton(
            onPressed: _busy ? null : _create,
            child: Text(_label(context, 'apiTokenCreate', 'Create token')),
          ),
        ],
      ),
    );
  }
}

/// Blocked and muted users, each removable.
class RelationshipsSection extends StatefulWidget {
  const RelationshipsSection({super.key});
  @override
  State<RelationshipsSection> createState() => _RelationshipsSectionState();
}

class _RelationshipsSectionState extends State<RelationshipsSection> {
  List<Map> _rows = const [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final body = objectOf(
        await HaneokaAccount.instance.request(
          'GET',
          '/api/v1/community/me/relationships',
        ),
      );
      if (mounted) {
        setState(
          () => _rows = ((body['relationships'] as List?) ?? const [])
              .whereType<Map>()
              .toList(),
        );
      }
    } catch (_) {}
  }

  Future<void> _remove(Map row) async {
    try {
      await HaneokaAccount.instance.request(
        'PUT',
        '/api/v1/community/users/${row['uid']}/${row['kind']}',
        body: {'active': false},
      );
      await _load();
    } on AccountError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.code)));
      }
    }
  }

  Widget _list(String kind, IconData icon, String title, String action) {
    final rows = _rows.where((row) => row['kind'] == kind).toList();
    return DetailSection(
      icon: icon,
      title: title,
      count: rows.length,
      child: rows.isEmpty
          ? Text(_label(context, 'listEmpty', 'None'))
          : Column(
              children: [
                for (final row in rows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${row['name'] ?? row['uid']}'),
                    subtitle: row['handle'] == null
                        ? null
                        : Text('@${row['handle']}'),
                    onTap: () =>
                        openLink(context, '/community/users/${row['uid']}'),
                    trailing: TextButton(
                      onPressed: () => _remove(row),
                      child: Text(action),
                    ),
                  ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _list(
        'block',
        Symbols.block_rounded,
        _label(context, 'blockedUsers', 'Blocked users'),
        _label(context, 'unblockUser', 'Unblock'),
      ),
      _list(
        'mute',
        Symbols.volume_off_rounded,
        _label(context, 'mutedUsers', 'Muted users'),
        _label(context, 'unmute', 'Unmute'),
      ),
    ],
  );
}

/// Active restrictions on the account.
class RestrictionsSection extends StatelessWidget {
  const RestrictionsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final rows =
        ((HaneokaAccount.instance.profile?['restrictions'] as List?) ??
                const [])
            .whereType<Map>()
            .toList();
    final kinds = {
      'write': _label(context, 'restrictionWrite', 'Posting'),
      'upload': _label(context, 'restrictionUpload', 'Uploads'),
      'sign_in': _label(context, 'restrictionSignIn', 'Sign-in'),
    };
    return DetailSection(
      icon: Symbols.policy_rounded,
      title: _label(context, 'restrictions', 'Restrictions'),
      count: rows.length,
      child: rows.isEmpty
          ? Text(_label(context, 'listEmpty', 'None'))
          : SpecList(
              facts: [
                for (final row in rows)
                  Fact(
                    kinds['${row['kind']}'] ?? '${row['kind']}',
                    _date(context, row['expiresAt']) ??
                        _label(context, 'restrictionPermanent', 'Permanent'),
                  ),
              ],
            ),
    );
  }
}
