import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../community/community_time.dart';
import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'haneoka_account.dart';
import 'security_widgets.dart';
import 'account_sections.dart';
import 'appeals.dart';

/// The reader's haneoka profile and sign-in sessions (`account-workspace`):
/// display name, handle and bio; every signed-in device, revocable.
class AccountProfileScreen extends StatefulWidget {
  const AccountProfileScreen({super.key});
  @override
  State<AccountProfileScreen> createState() => _AccountProfileScreenState();
}

class _AccountProfileScreenState extends State<AccountProfileScreen> {
  final _name = TextEditingController();
  final _handle = TextEditingController();
  final _bio = TextEditingController();
  Future<List<Map<String, Object?>>>? _sessions;
  bool _saving = false;
  String _section = 'profile';
  Object? _owner = HaneokaAccount.instance.user?['id'];
  void _accountChanged() {
    final owner = HaneokaAccount.instance.user?['id'];
    if (owner == _owner) return;
    _owner = owner;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final profile = HaneokaAccount.instance.profile ?? const {};
    HaneokaAccount.instance.addListener(_accountChanged);
    _name.text = '${profile['displayName'] ?? ''}';
    _handle.text = '${profile['handle'] ?? ''}';
    _bio.text = '${profile['bio'] ?? ''}';
    _sessions = _loadSessions();
  }

  @override
  void dispose() {
    HaneokaAccount.instance.removeListener(_accountChanged);
    _name.dispose();
    _handle.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<List<Map<String, Object?>>> _loadSessions() async {
    final body = await HaneokaAccount.instance.request(
      'GET',
      '/api/auth/list-sessions',
    );
    return [
      for (final row in (body as List? ?? const []).whereType<Map>())
        row.cast<String, Object?>(),
    ];
  }

  String _label(String key, String fallback) =>
      AppScope.of(context).text('account.page.$key', fallback);

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await HaneokaAccount.instance.updateProfile(
        displayName: _name.text,
        handle: _handle.text,
        bio: _bio.text,
      );
      if (mounted) _say(_label('profileUpdated', 'Profile updated.'));
    } catch (_) {
      if (mounted) _say(_label('profileLoadFailed', 'Unavailable'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _revoke(String token) async {
    try {
      await HaneokaAccount.instance.request(
        'POST',
        '/api/auth/revoke-session',
        body: {'token': token},
      );
      if (!mounted) return;
      _say(_label('sessionRevoked', 'Session revoked.'));
      setState(() => _sessions = _loadSessions());
    } catch (_) {
      if (mounted) {
        _say(
          _label('sessionRevokeFailed', 'The session could not be revoked.'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = AppScope.of(context).text.locale;
    Widget surface(Widget child) => Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      child: Padding(padding: const EdgeInsets.all(20), child: child),
    );
    return ShellPage(
      title: _label('profile', 'Profile'),
      body: ListView(
        padding: pagePadding(context),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  surface(const AccountSummary()),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final (key, icon, label) in [
                          (
                            'profile',
                            Symbols.person_rounded,
                            _label('profile', 'Profile'),
                          ),
                          (
                            'games',
                            Symbols.sports_esports_rounded,
                            _label('gameAccounts', 'Game accounts'),
                          ),
                          (
                            'security',
                            Symbols.verified_user_rounded,
                            _label('security', 'Sign-in & security'),
                          ),
                          (
                            'sessions',
                            Symbols.devices_rounded,
                            _label('sessions', 'Sessions'),
                          ),
                          (
                            'relationships',
                            Symbols.block_rounded,
                            _label('relationships', 'Blocks & mutes'),
                          ),
                          (
                            'moderation',
                            Symbols.policy_rounded,
                            _label('moderation', 'Restrictions & appeals'),
                          ),
                          (
                            'management',
                            Symbols.settings_rounded,
                            _label('accountManagement', 'Account management'),
                          ),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              avatar: Icon(icon, size: 18),
                              showCheckmark: false,
                              label: Text(label),
                              selected: _section == key,
                              onSelected: (_) => setState(() => _section = key),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_section == 'profile') ...[
                    surface(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _name,
                            maxLength: 80,
                            decoration: InputDecoration(
                              labelText: _label('displayName', 'Display name'),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _handle,
                            maxLength: 32,
                            decoration: InputDecoration(
                              labelText: _label('handle', 'Handle'),
                              prefixText: '@',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _bio,
                            minLines: 3,
                            maxLines: 6,
                            maxLength: 500,
                            decoration: InputDecoration(
                              labelText: _label('bio', 'Bio'),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: _saving ? null : _save,
                            child: Text(_label('saveProfile', 'Save profile')),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    surface(const AccountAvatar()),
                  ],
                  if (_section == 'games') surface(const GameAccountsSection()),
                  if (_section == 'security') ...[
                    surface(const AccountSecurity()),
                    const SizedBox(height: 16),
                    surface(const ApiTokensSection()),
                  ],
                  if (_section == 'relationships')
                    surface(const RelationshipsSection()),
                  if (_section == 'sessions')
                    surface(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _label('sessions', 'Sessions'),
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          FutureBuilder(
                            future: _sessions,
                            builder: (context, snapshot) {
                              final sessions = snapshot.data;
                              if (snapshot.hasError) {
                                return FilledButton.tonalIcon(
                                  onPressed: () => setState(
                                    () => _sessions = _loadSessions(),
                                  ),
                                  icon: const Icon(Symbols.refresh_rounded),
                                  label: Text(
                                    AppScope.of(context)
                                        .text('common.actions.retry', 'Retry'),
                                  ),
                                );
                              }
                              if (sessions == null) {
                                return const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return Column(
                                children: [
                                  for (final session in sessions)
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: const Icon(
                                        Symbols.devices_rounded,
                                      ),
                                      title: Text(
                                        deviceLabel(
                                              '${session['userAgent'] ?? ''}',
                                            ).isEmpty
                                            ? _label(
                                                'sessionUnknown',
                                                'Unknown device',
                                              )
                                            : deviceLabel(
                                                '${session['userAgent']}',
                                              ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        formatCommunityTime(
                                              session['updatedAt'] ??
                                                  session['createdAt'],
                                              locale,
                                            )?.text ??
                                            '',
                                      ),
                                      trailing: TextButton(
                                        onPressed: () =>
                                            _revoke('${session['token']}'),
                                        child: Text(_label('revoke', 'Revoke')),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  if (_section == 'moderation') ...[
                    surface(const RestrictionsSection()),
                    const SizedBox(height: 16),
                    surface(const AccountAppeals()),
                  ],
                  if (_section == 'management') surface(const DeleteAccount()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
