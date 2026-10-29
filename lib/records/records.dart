import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/visuals.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../core/i18n.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/card_artwork.dart';
import '../ui/theme.dart';
import 'player.dart';

/// The game servers whose records the website reads (`GAME_RECORDS_REGIONS`).
const recordRegions = [
  ('jp', 'regionJp', 'assets/settings/flag-jp.svg'),
  ('tw', 'regionTw', 'assets/settings/flag-hk.svg'),
  ('en', 'regionEn', 'assets/settings/flag-en.svg'),
  ('kr', 'regionKr', 'assets/settings/flag-kr.svg'),
];

String defaultRecordRegion(String server, String locale) => server == 'jp'
    ? 'jp'
    : locale == 'en'
    ? 'en'
    : locale == 'ko'
    ? 'kr'
    : 'tw';

String rankingLabel(SiteText t, String key, [String fallback = '']) =>
    t('catalog.rankings.songs.$key', fallback);

/// The region choice for a title bar (`gameRecordsRegionPicker`).
BarAction regionChoice(
  SiteText t,
  String region,
  ValueChanged<String> onSelect,
) => BarAction.choice(
  label: rankingLabel(t, 'region', 'Ranking region'),
  options: [
    for (final (value, key, flag) in recordRegions)
      BarChoice(
        icon: Symbols.public_rounded,
        image: SvgPicture.asset(flag, width: 24, height: 24),
        label: rankingLabel(t, key, value),
        selected: region == value,
        onSelected: () => onSelect(value),
      ),
  ],
);

/// One card's art, marks and progression group (`RankingCardArtwork`).
class CardArt {
  CardArt(
    this.name,
    this.image,
    this.rarity,
    this.attribute,
    this.rarityMark,
    this.rankGroup,
    this.levelGroup,
    this.liveSkillIcon,
    this.gekisoSkillIcon,
  );
  final Object? name;
  final String? image;
  final int rarity;
  final String? attribute;
  final String? rarityMark;
  final int rankGroup;
  final int levelGroup;
  final String? liveSkillIcon, gekisoSkillIcon;
}

typedef LevelTable = List<(int level, num exp)>;

/// Card art and the native progression tables the rankings read
/// (`rankingCardCatalog`), built from the API for one release server.
class CardCatalog {
  CardCatalog._(
    this.member,
    this.support,
    this.memberLevels,
    this.supportLevels,
    this.playerLevels,
    this.memberLimits,
    this.supportLimits,
    this.visuals,
  );
  final Map<int, CardArt> member, support;
  final Map<int, LevelTable> memberLevels, supportLevels;
  final LevelTable playerLevels;
  final Map<String, int> memberLimits, supportLimits;
  final CatalogVisuals visuals;

  static final _loaded = <HaneokaApi, Future<CardCatalog>>{};
  static Future<CardCatalog> of(HaneokaApi api) =>
      cachedResource(_loaded, api, () => _load(api));

  static Future<CardCatalog> _load(HaneokaApi api) async {
    final s = api.server;
    final (
      cards,
      supports,
      progression,
      memberLevels,
      supportLevels,
      visuals,
    ) = await (
      api.catalog('cards'),
      api.catalog('support-cards'),
      api.json('/api/v1/servers/$s/progression'),
      api.json('/api/v1/servers/$s/progression/views/member-card-levels'),
      api.json('/api/v1/servers/$s/progression/views/support-card-levels'),
      CatalogVisuals.of(api),
    ).wait;
    const rarities = {2: 'R', 3: 'SR', 4: 'SSR', 10: 'EX'};
    Map<int, CardArt> arts(Object? source, bool support) => {
      for (final MapEntry(:key, :value)
          in ((source as Map?) ?? const {}).entries)
        if (value is Map && int.tryParse('$key') != null)
          int.parse('$key'): CardArt(
            value['prefix'] ?? value['cardName'],
            switch ((value['images'] as Map?)?['thumbnail']) {
              final String path => api.asset(path).toString(),
              _ => null,
            },
            (value['rarity'] as num?)?.toInt() ?? 0,
            visuals.cardTypeMark(value['cardType']),
            visuals.mark(
              'RarityIconCenter_${rarities[value['rarity']] ?? ''}.png',
            ),
            (value['supportCardRankGroup'] as num?)?.toInt() ?? 0,
            ((support
                            ? value['supportCardLevelGroup']
                            : value['memberCardLevelGroup'])
                        as num?)
                    ?.toInt() ??
                0,
            _skillIcon(value, 'live', api),
            _skillIcon(value, 'gekisou', api),
          ),
    };
    Map<int, LevelTable> levels(Object? rows) {
      final groups = <int, LevelTable>{};
      for (final row in (rows as List? ?? const []).whereType<Map>()) {
        (groups[(row['group'] as num).toInt()] ??= []).add((
          (row['level'] as num).toInt(),
          row['exp'] as num,
        ));
      }
      for (final list in groups.values) {
        list.sort((a, b) => a.$1.compareTo(b.$1));
      }
      return groups;
    }

    final p = (progression as Map?) ?? const {};
    Map<String, Object?> raw(Object? row) =>
        ((row as Map?)?['raw'] as Map?)?.cast<String, Object?>() ?? const {};
    return CardCatalog._(
      arts(cards, false),
      arts(supports, true),
      levels(memberLevels),
      levels(supportLevels),
      [
        for (final row
            in (p['playerRanks'] as List? ?? const []).whereType<Map>())
          ((row['rank'] as num).toInt(), row['exp'] as num),
      ]..sort((a, b) => a.$1.compareTo(b.$1)),
      {
        for (final row in (p['memberCardLevelLimits'] as List? ?? const []))
          '${raw(row)['_rarity']}:${raw(row)['_awakeCount']}':
              (raw(row)['_limitLevel'] as num?)?.toInt() ?? 0,
      },
      {
        for (final row in (p['supportCardRanks'] as List? ?? const []))
          '${raw(row)['_group']}:${raw(row)['_rank']}':
              (raw(row)['_limitLevel'] as num?)?.toInt() ?? 0,
      },
      visuals,
    );
  }

  static String? _skillIcon(Map card, String family, HaneokaApi api) {
    final icon = ((card['resolvedSkills'] as Map?)?[family] as Map?)?['icon'];
    return icon is String && icon.isNotEmpty
        ? api.asset(icon).toString()
        : null;
  }

  CardGrowthDisplay? cardGrowth(Map card, SiteText t, {required bool support}) {
    final art = (support
        ? this.support
        : member)[card[support ? 'supportCardId' : 'memberCardId']];
    return art == null
        ? null
        : growth(
            art,
            t,
            support: support,
            level: cardLevel(card, support: support),
            training: (card['memberAwakeCount'] as num?)?.toInt(),
            rank: (card[support ? 'supportRank' : 'memberRank'] as num?)
                ?.toInt(),
          );
  }

  /// Native awakeCount is training; card rank selects the awakening emblem.
  CardGrowthDisplay growth(
    CardArt art,
    SiteText t, {
    required bool support,
    int? level,
    int? training,
    int? rank,
    bool showSkills = false,
    int? liveSkillLevel,
    int? gekisoSkillLevel,
  }) => CardGrowthDisplay(
    level: level,
    training: support ? null : training,
    trainingIcon: visuals.mark('SpecialTraining.png'),
    trainingLabel: t('catalog.cards.fields.training', 'Training'),
    rank: rank,
    rankIcon: visuals.mark(
      support ? 'snaplimit_${rank ?? 0}.png' : 'CardRank${rank ?? 0}.png',
    ),
    rankLabel: t('catalog.cards.fields.awakening', 'Awakening'),
    liveSkill: !support && showSkills && art.liveSkillIcon != null
        ? CardSkillMark(
            art.liveSkillIcon!,
            liveSkillLevel,
            t('catalog.cards.fields.liveSkill', 'LIVE Skill'),
          )
        : null,
    gekisoSkill: !support && showSkills && art.gekisoSkillIcon != null
        ? CardSkillMark(
            art.gekisoSkillIcon!,
            gekisoSkillLevel,
            t('catalog.cards.fields.gekisouSkill', 'GEKISO Skill'),
          )
        : null,
  );

  /// The highest level whose experience is reached (`levelFromExp`).
  static int? levelFromExp(LevelTable? rows, Object? exp) {
    if (exp is! num || rows == null || rows.isEmpty) return null;
    var level = 1;
    for (final (l, e) in rows) {
      if (e > exp) break;
      level = l;
    }
    return level;
  }

  int? playerLevel(Object? exp) => levelFromExp(playerLevels, exp);

  /// A card's level from its experience, capped by its awakening or rank.
  int? cardLevel(Map card, {required bool support}) {
    final art = (support
        ? this.support
        : member)[card[support ? 'supportCardId' : 'memberCardId']];
    if (art == null) return null;
    final level = levelFromExp(
      (support ? supportLevels : memberLevels)[art.levelGroup],
      card[support ? 'supportExp' : 'memberExp'],
    );
    final cap = support
        ? supportLimits['${art.rankGroup}:${card['supportRank'] ?? 1}']
        : memberLimits['${art.rarity}:${card['memberAwakeCount'] ?? 1}'];
    return level == null
        ? null
        : (cap != null && cap > 0 ? (level < cap ? level : cap) : level);
  }
}

/// A ranking (`song-ranking`): rank, the player's profile card and favourite
/// member, name, rank and power, score, and the deck's ten cards.
class RankingList extends StatefulWidget {
  const RankingList({
    super.key,
    required this.endpoint,
    required this.region,
    this.points = false,
    this.summary = false,
    this.onPlayer,
  });

  /// `/api/v1/game/records/{region}/…/ranking`.
  final String endpoint;
  final String region;
  final bool points, summary;
  final void Function(String profileId)? onPlayer;

  @override
  State<RankingList> createState() => RankingListState();
}

class RankingListState extends State<RankingList> {
  Future<(Map, CardCatalog)>? _data;
  (Map, CardCatalog)? _last;
  int _limit = 20;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _load();
  }

  @override
  void didUpdateWidget(RankingList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endpoint != widget.endpoint) {
      _last = null;
      _limit = 20;
      _data = _load();
    }
  }

  void refresh() => setState(() => _data = _load(fresh: true));

  Future<(Map, CardCatalog)> _load({bool fresh = false}) async {
    final endpoint = widget.endpoint;
    final api = AppScope.of(context)
        .apiFor(widget.region == 'jp' ? 'jp' : 'intl');
    final response = await api.live(endpoint) as Map;
    final previous = _last?.$1;
    final ranking =
        response['snapshotId'] != null &&
            response['snapshotId'] == previous?['snapshotId']
        ? {...response, 'rows': previous!['rows']}
        : response;
    final result = (ranking, await CardCatalog.of(api));
    if (mounted && endpoint == widget.endpoint) _last = result;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    return FutureBuilder(
      key: ValueKey(widget.endpoint),
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError && _last == null) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(rankingLabel(t, 'error', 'Ranking unavailable')),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: refresh,
                  child: Text(rankingLabel(t, 'retry', 'Retry')),
                ),
              ],
            ),
          );
        }
        final data = snapshot.data ?? _last;
        if (data == null) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final (ranking, cards) = data;
        final rows = (ranking['rows'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        if (rows.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(rankingLabel(t, 'empty', 'No scores yet')),
            ),
          );
        }
        final fetched = ranking['observedAtMs'] ?? ranking['fetchedAtMs'];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (fetched is num)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '${rankingLabel(t, ranking['provider'] == 'official' ? 'observed' : 'updated')} · ${DateFormat.yMd(t.locale).add_Hms().format(DateTime.fromMillisecondsSinceEpoch(fetched.toInt()))}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final (index, row) in rows.take(_limit).indexed) ...[
              if (index > 0) const Divider(height: 1),
              _Row(
                row: row,
                cards: cards,
                points: widget.points || widget.summary,
                onPlayer: widget.onPlayer,
              ),
            ],
            if (ranking['provider'] == 'official')
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(rankingLabel(t, 'officialSource')),
              ),
            if (rows.length > _limit)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: FilledButton.tonal(
                    onPressed: () => setState(() => _limit = 100),
                    child: Text(rankingLabel(t, 'showMore', 'Show top 100')),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.cards,
    required this.points,
    this.onPlayer,
  });
  final Map row;
  final CardCatalog cards;
  final bool points;
  final void Function(String profileId)? onPlayer;

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = NumberFormat.decimalPattern(t.locale);
    final name = '${row['name'] ?? ''}'.isEmpty
        ? rankingLabel(t, 'privatePlayer', 'Unknown player')
        : '${row['name']}';
    final namecard =
        ((row['profileCard'] as Map?)?['thumbnailUrls'] as List?)?.firstOrNull;
    final favorite = cards.member[row['favoriteMemberCardId']];
    final level = cards.playerLevel(row['rankExp']);
    final profileId = row['profileId'];
    final deck = (row['cards'] as List? ?? const []).whereType<Map>().toList();
    Widget media(
      String? url,
      double w,
      double h, {
      bool circle = false,
      Widget? fallback,
    }) => ClipRRect(
      borderRadius: BorderRadius.circular(circle ? w : Corner.small),
      child: Container(
        width: w,
        height: h,
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: url == null
            ? fallback
            : AppImage(candidates: [url], fit: BoxFit.cover),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '${row['rank']}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 8),
              media(
                namecard is String ? namecard : null,
                64,
                36,
                fallback: Icon(
                  Symbols.badge_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              media(
                favorite?.image,
                32,
                32,
                circle: true,
                fallback: Text(
                  name.characters.take(2).toString(),
                  style: theme.textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: profileId is String && onPlayer != null
                      ? () => onPlayer!(profileId)
                      : null,
                  borderRadius: BorderRadius.circular(Corner.small),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        [
                          if (level != null)
                            rankingLabel(
                              t,
                              'cardLevel',
                              'Lv. {level}',
                            ).replaceAll('{level}', '$level'),
                          if (row['totalPower'] is num)
                            '${rankingLabel(t, 'power', 'Power')} ${number.format(row['totalPower'])}',
                        ].join('   '),
                        maxLines: 2,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    row['scoreExact'] is String
                        ? (row['scoreExact'] as String).replaceAllMapped(
                            RegExp(r'\B(?=(\d{3})+(?!\d))'),
                            (_) => number.symbols.GROUP_SEP,
                          )
                        : row['score'] is num
                        ? number.format(row['score'])
                        : '—',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (row['tied'] == true)
                    Text(
                      rankingLabel(t, 'tied', 'Tied rank'),
                      style: theme.textTheme.labelSmall,
                    ),
                ],
              ),
            ],
          ),
          if (!points && deck.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 8),
              child: Row(
                children: [
                  for (final card in deck.take(5))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          children: [
                            _Card(
                              art: cards.member[card['memberCardId']],
                              growth: cards.cardGrowth(card, t, support: false),
                              support: false,
                            ),
                            const SizedBox(height: 4),
                            _Card(
                              art: cards.support[card['supportCardId']],
                              growth: cards.cardGrowth(card, t, support: true),
                              support: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.art, required this.growth, required this.support});
  final CardArt? art;
  final CardGrowthDisplay? growth;
  final bool support;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: support ? 16 / 9 : 1,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(Corner.small),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: art == null
            ? null
            : CardArtwork(
                kind: support ? GameCardKind.support : GameCardKind.member,
                image: art!.image ?? '',
                attribute: art!.attribute,
                rarity: art!.rarityMark,
                growth: growth,
              ),
      ),
    ),
  );
}

/// One song's score ranking (`song-ranking`): the region in the bar, the
/// ranking below.
class SongRankingScreen extends StatefulWidget {
  const SongRankingScreen({
    super.key,
    required this.songId,
    required this.title,
    this.server,
  });
  final String songId;
  final String title;
  final String? server;

  @override
  State<SongRankingScreen> createState() => _SongRankingScreenState();
}

class _SongRankingScreenState extends State<SongRankingScreen> {
  final _list = GlobalKey<RankingListState>();
  String? _region;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final region =
        _region ?? defaultRecordRegion(widget.server ?? state.server, t.locale);
    return ShellPage(
      title: widget.title,
      actions: [
        regionChoice(t, region, (value) => setState(() => _region = value)),
        BarAction(
          icon: Symbols.refresh_rounded,
          label: rankingLabel(t, 'refresh', 'Refresh ranking'),
          onPressed: () => _list.currentState?.refresh(),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          RankingList(
            key: _list,
            region: region,
            endpoint:
                '/api/v1/game/records/$region/songs/${Uri.encodeComponent(widget.songId)}/ranking',
            onPlayer: (id) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    PlayerProfileScreen(region: region, profileId: id),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
