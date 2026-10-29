import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../community/actions.dart';
import '../community/community_widgets.dart';
import '../community/community_time.dart';
import 'haneoka_account.dart';

class AccountAppeals extends StatefulWidget {
  const AccountAppeals({super.key});
  @override
  State<AccountAppeals> createState() => _AccountAppealsState();
}

class _AccountAppealsState extends State<AccountAppeals> {
  late Future<Json> _data = communityRequest(
    'GET',
    '/api/v1/community/appeals',
  );
  Object? _owner = HaneokaAccount.instance.user?['id'];
  @override
  void initState() {
    super.initState();
    HaneokaAccount.instance.addListener(_changed);
  }

  void _changed() {
    final owner = HaneokaAccount.instance.user?['id'];
    if (owner != _owner) {
      _owner = owner;
      setState(
        () => _data = communityRequest('GET', '/api/v1/community/appeals'),
      );
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    HaneokaAccount.instance.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context),
        profile = HaneokaAccount.instance.profile ?? const {},
        avatar = jsonMap(HaneokaAccount.instance.profile?['avatarReview']);
    String t(String key) => state.text('community.page.$key');
    Future<void> appeal(String kind, String id, {Object? revision}) async {
      final done = await communityStatement(
        context,
        appeal: true,
        kind: kind,
        id: id,
        revision: revision,
      );
      if (done && context.mounted) {
        setState(
          () => _data = communityRequest('GET', '/api/v1/community/appeals'),
        );
        communityMessage(context, 'appealSubmitted');
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t('appealsTitle'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: state.text('common.actions.refresh'),
              onPressed: () => setState(
                () => _data = communityRequest(
                  'GET',
                  '/api/v1/community/appeals',
                ),
              ),
              icon: const Icon(Symbols.refresh_rounded),
            ),
          ],
        ),
        if (profile['displayNameStatus'] == 'block')
          OutlinedButton.icon(
            onPressed: () => appeal(
              'profile-name',
              '$_owner',
              revision: profile['displayNameRevision'],
            ),
            icon: const Icon(Symbols.gavel_rounded),
            label: Text(
              '${state.text('account.page.displayName')} · ${t('appeal')}',
            ),
          ),
        if (avatar['moderationStatus'] == 'block')
          OutlinedButton.icon(
            onPressed: () => appeal('attachment', '${avatar['id']}'),
            icon: const Icon(Symbols.gavel_rounded),
            label: Text(
              '${state.text('account.page.avatar')} · ${t('appeal')}',
            ),
          ),
        FutureBuilder(
          future: _data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return TextButton(
                onPressed: () => setState(
                  () => _data = communityRequest(
                    'GET',
                    '/api/v1/community/appeals',
                  ),
                ),
                child: Text(state.text('common.actions.retry')),
              );
            }
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 48,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              children: [
                for (final appeal in jsonList(snapshot.data?['appeals']))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Symbols.gavel_rounded),
                    title: Text(
                      appeal['entityKind'] == 'profile-name'
                          ? state.text('account.page.displayName')
                          : appeal['entityKind'] == 'attachment'
                          ? state.text('account.page.avatar')
                          : t('appeal'),
                    ),
                    subtitle: Text(
                      '${t('appealStatus.${appeal['status']}')} · ${formatCommunityTime(appeal['updatedAt'], state.text.locale)?.text ?? ''}',
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
