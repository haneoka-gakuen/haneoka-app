import '../catalog/visuals.dart';
import '../core/api.dart';
import '../core/i18n.dart';
import '../ui/card_artwork.dart';

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
