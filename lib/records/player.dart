import '../core/site_date.dart';
import '../save/game_save.dart' show regionOfProfile;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/card_artwork.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'records.dart';

/// The website's player lookup (`player-profile-workspace`): a game server
/// and a player ID in the title bar, then that player's public profile.
class PlayerProfileScreen extends StatefulWidget {
  const PlayerProfileScreen({super.key, this.region, this.profileId});
  final String? region;
  final String? profileId;
  @override
  State<PlayerProfileScreen> createState() => _PlayerProfileScreenState();
}

class _PlayerProfileScreenState extends State<PlayerProfileScreen> {
  late String? _region = widget.region;
  late String? _id = widget.profileId;
  Future<(Map, CardCatalog)>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    _region ??= defaultRecordRegion(state.server, state.text.locale);
    if (_id != null) _data ??= _load();
  }

  Future<(Map, CardCatalog)> _load() async {
    final api = AppScope.of(context).apiFor(_region == 'jp' ? 'jp' : 'intl');
    final (profile, cards) = await (
      api.live(
        '/api/v1/game/records/$_region/players/${Uri.encodeComponent(_id!)}',
      ),
      CardCatalog.of(api),
    ).wait;
    return (profile as Map, cards);
  }

  void _search(String value) {
    final id = value.trim();
    if (!RegExp(r'^\d{6,20}$').hasMatch(id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppScope.of(context).text('tools.playerProfile.invalidId', ''),
          ),
        ),
      );
      return;
    }
    setState(() {
      _id = id;
      _region = regionOfProfile(id) ?? _region;
      _data = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ShellPage(
      title: t('tools.playerProfile.title', 'Player lookup'),
      search: ShellSearch(
        label: rankingLabel(t, 'profileSearch', 'Player profile ID'),
        onChanged: (_) {},
        onSubmitted: _search,
        initial: _id,
        keyboardType: TextInputType.number,
      ),
      actions: [
        regionChoice(
          t,
          _region!,
          (region) => setState(() {
            _region = region;
            if (_id != null) _data = _load();
          }),
        ),
      ],
      body: _data == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: scheme.surfaceContainerHigh,
                    child: Icon(
                      Symbols.person_search_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t('tools.playerProfile.queryIdle', 'Enter a player ID'),
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
            )
          : FutureBuilder(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.person_off_rounded,
                          size: 32,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          rankingLabel(
                            t,
                            'profileUnavailable',
                            'Profile unavailable',
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.tonal(
                          onPressed: () => setState(() => _data = _load()),
                          child: Text(rankingLabel(t, 'retry', 'Retry')),
                        ),
                      ],
                    ),
                  );
                }
                final data = snapshot.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return PlayerProfileView(record: data.$1, cards: data.$2);
              },
            ),
    );
  }
}

/// One player's public profile; also the summary a bound account shows.
class PlayerProfileView extends StatelessWidget {
  const PlayerProfileView({
    super.key,
    required this.record,
    required this.cards,
  });
  final Map record;
  final CardCatalog cards;

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = NumberFormat.decimalPattern(t.locale);
    final profile = (record['profile'] as Map?) ?? const {};
    if (profile.isEmpty) {
      return Center(
        child: Text(rankingLabel(t, 'profilePrivate', 'No public profile.')),
      );
    }
    final name = '${profile['name'] ?? ''}'.isEmpty
        ? rankingLabel(t, 'privatePlayer', 'Unknown player')
        : '${profile['name']}';
    final favorite = (profile['favoriteMemberCard'] as Map?) ?? const {};
    final art = cards.member[favorite['cardId']];
    final level = profile['level'] ?? cards.playerLevel(profile['rankExp']);
    final namecard = (profile['profileCard'] as Map?) ?? const {};
    final pages = [
      for (final page
          in (namecard['pages'] as List? ?? const []).whereType<Map>())
        if (page['imageUrl'] is String) page['imageUrl'] as String,
    ];
    final favoriteLevel = art == null
        ? null
        : cards.cardLevel({
            'memberCardId': favorite['cardId'],
            'memberExp': favorite['exp'],
            'memberAwakeCount': favorite['awakeCount'],
          }, support: false);
    final updated = profile['lastUpdatedAtMs'] ?? record['fetchedAtMs'];
    return ListView(
      padding: pagePadding(context),
      children: [
        Row(
          children: [
            ClipOval(
              child: Container(
                width: 72,
                height: 72,
                color: scheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: art?.image == null
                    ? Text(
                        name.characters.take(2).toString(),
                        style: theme.textTheme.titleLarge,
                      )
                    : AppImage(candidates: [art!.image!], fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.headlineSmall),
                  Text(
                    '${rankingLabel(t, 'profileSearch', 'Player profile ID')} · ${record['profileId'] ?? profile['playerId']}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (level != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Chip(
                        label: Text(
                          rankingLabel(
                            t,
                            'cardLevel',
                            'Lv. {level}',
                          ).replaceAll('{level}', '$level'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (pages.isNotEmpty)
          DetailSection(
            icon: Symbols.badge_rounded,
            title:
                '${namecard['name'] ?? rankingLabel(t, 'profileCard', 'Profile card')}'
                '${namecard['slot'] != null ? ' · ${rankingLabel(t, 'profileCardSlot', 'Slot {slot}').replaceAll('{slot}', '${namecard['slot']}')}' : ''}',
            child: ImageGallery(images: pages, aspectRatio: 16 / 9),
          ),
        DetailSection(
          icon: Symbols.person_rounded,
          title: rankingLabel(t, 'profile', 'Player profile'),
          child: SpecList(
            facts: [
              if (profile['totalFavorite'] != null)
                Fact(
                  rankingLabel(t, 'favorites', 'Likes received'),
                  '${profile['totalFavoriteExact'] ?? number.format(profile['totalFavorite'])}',
                ),
              if (level != null)
                Fact(rankingLabel(t, 'level', 'Rank'), '$level'),
            ],
          ),
        ),
        if (art != null)
          DetailSection(
            icon: Symbols.style_rounded,
            title: rankingLabel(t, 'favoriteCard', 'Favourite member'),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(Corner.medium),
                  child: SizedBox(
                    width: 120,
                    height: 160,
                    child: art.image == null
                        ? null
                        : CardArtwork(
                            kind: GameCardKind.member,
                            image: art.image!,
                            attribute: art.attribute,
                            rarity: art.rarityMark,
                            growth: cards.growth(
                              art,
                              t,
                              support: false,
                              level: favoriteLevel,
                              training: (favorite['awakeCount'] as num?)
                                  ?.toInt(),
                              rank: (favorite['cardRank'] as num?)?.toInt(),
                              showSkills: true,
                              liveSkillLevel:
                                  (favorite['liveSkillLevel'] as num?)?.toInt(),
                              gekisoSkillLevel:
                                  (favorite['performanceSkillLevel'] as num?)
                                      ?.toInt(),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.text(art.name),
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (updated is num)
          Text(
            '${rankingLabel(t, 'updated', 'Updated')} · ${SiteDate.day(t.locale).withTime(seconds: true).format(DateTime.fromMillisecondsSinceEpoch(updated.toInt()))}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
