import '../core/api.dart';
import 'history_snapshot.dart';
import 'history_view.dart';
import '../catalog/visuals.dart';

import 'package:game_data_exporter/gacha_history_analysis.dart' as analysis;
import 'package:game_data_exporter/gacha_history_points.dart' as points;

import 'dart:convert';

GachaHistoryConversion historyDefaultGemConversion(
  String currencyCode, {
  Map? baseTopUp,
}) {
  final rewards = baseTopUp?['rewards'];
  final paidGems = rewards is List
      ? rewards.whereType<Map>().fold<num>(
          0,
          (sum, reward) =>
              reward['resourceType'] == 1 &&
                  reward['resourceId'] == 2 &&
                  reward['bonus'] != true &&
                  reward['count'] is num
              ? sum + (reward['count'] as num)
              : sum,
        )
      : 0;
  final payment = baseTopUp?['payment'];
  final prices = payment is Map ? payment['prices'] : null;
  final masterPrice = payment is Map ? payment['masterPrice'] : null;
  final price =
      (prices is Map ? prices[currencyCode.toLowerCase()] : null) ??
      (currencyCode == 'JPY' && masterPrice is Map
          ? masterPrice['value']
          : null);
  final referenceUnitPrice = const {'MOP': 0.07, 'CNY': 0.06}[currencyCode];
  return GachaHistoryConversion(
    currencyCode: currencyCode,
    freeUnitGemPrice: 0,
    paidUnitGemPrice:
        paidGems > 0 && price is num && price.isFinite && price >= 0
        ? price / paidGems
        : referenceUnitPrice,
  );
}

class HistoryCatalog {
  HistoryCatalog._(
    this.api,
    this.metadata,
    this.pools,
    this.cards,
    this.snapshots,
    this.items,
    this.visuals,
    this.baseTopUp,
    this.exchanges,
  );
  final HaneokaApi api;
  final Map metadata, pools, cards, snapshots, items, exchanges;
  final CatalogVisuals visuals;
  final Map? baseTopUp;

  static Future<HistoryCatalog> load(HaneokaApi api) async {
    final (pools, cards, snapshots, items, visuals, baseTopUp) = await (
      api.catalog('gacha'),
      api.catalog('cards'),
      api.catalog('support-cards'),
      api.catalog('items'),
      CatalogVisuals.of(api),
      api
          .catalog('shop', api.server == 'jp' ? '2' : '1000000101')
          .catchError((Object _) => null),
    ).wait;
    final metadata = pools is Map ? pools['history'] : null;
    if (metadata is! Map ||
        metadata['schema'] != 'haneoka-gacha-history-data-v1' ||
        pools is! Map ||
        pools['entries'] is! Map ||
        cards is! Map ||
        snapshots is! Map ||
        items is! Map ||
        items['items'] is! Map) {
      throw const FormatException('history_catalog');
    }
    final exchanges = metadata['exchanges'];
    return HistoryCatalog._(
      api,
      metadata,
      pools['entries'] as Map,
      cards,
      snapshots,
      items['items'] as Map,
      visuals,
      baseTopUp is Map ? baseTopUp : null,
      exchanges is Map && exchanges['entries'] is Map
          ? exchanges
          : const {'entries': {}},
    );
  }

  GachaHistoryConversion defaultConversion(String currencyCode) =>
      historyDefaultGemConversion(currencyCode, baseTopUp: baseTopUp);

  List<GachaHistoryPool> poolViews(
    String Function(Object?) localized,
    String Function(String) categoryLabel, {
    HistorySnapshot? snapshot,
  }) => [
    for (final MapEntry(:key, :value) in pools.entries)
      if (value is Map)
        GachaHistoryPool(
          id: '$key',
          name: localized(value['title']),
          category: categoryLabel('${value['category'] ?? 'other'}'),
          imageUrl: _poolImage(value),
          bannerUrl: value['image'] is String && '${value['image']}'.isNotEmpty
              ? api.asset(value['image'] as String).toString()
              : null,
          startAt: _time(value['startAt']),
          endAt: _time(value['endAt']),
          rates: analysis.gachaPoolRates(_rulePool('$key')),
          featured: _featured(value, localized),
          exchangeTargets: _exchangeTargets(
            _rulePool('$key'),
            localized,
            snapshot,
          ),
        ),
  ];

  static DateTime? _time(Object? value) {
    final ms = (value is List ? value : [value])
        .whereType<num>()
        .where((ms) => ms > 0)
        .firstOrNull;
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);
  }

  List<GachaHistoryFeatured> _featured(
    Map pool,
    String Function(Object?) localized,
  ) => [
    for (final entry
        in pool['featured'] is List
            ? (pool['featured'] as List).whereType<Map>()
            : const <Map>[])
      if ((entry['resourceType'] == 2 || entry['resourceType'] == 3) &&
          entry['pickup'] == true &&
          '${entry['resourceId'] ?? ''}'.isNotEmpty)
        _featuredCard(entry, localized),
  ];

  GachaHistoryFeatured _featuredCard(
    Map entry,
    String Function(Object?) localized,
  ) {
    final type = entry['resourceType'], id = '${entry['resourceId']}';
    final card = (type == 2 ? cards : snapshots)[id];
    final row = card is Map ? card : const {};
    final images = row['images'];
    final image =
        (images is Map ? images['thumbnail'] : null) ??
        row['image'] ??
        entry['image'];
    final rarity = row['rarity'] ?? entry['rarity'];
    final rarityLabel =
        const {2: 'R', 3: 'SR', 4: 'SSR', 10: 'EX', 20: 'BD'}[rarity] ?? '';
    final name = localized(
      row['prefix'] ?? row['cardName'] ?? row['name'] ?? entry['name'],
    );
    return GachaHistoryFeatured(
      key: '${type == 2 ? 'member' : 'support'}:$id',
      kind: type == 2 ? 'member' : 'support',
      name: name.isEmpty ? id : name,
      rarity: rarity is num || rarity is String ? rarity! : '',
      imageUrl: image is String && image.isNotEmpty
          ? api.asset(image).toString()
          : null,
      href: type == 2
          ? '/catalog/member-cards/$id'
          : '/catalog/support-cards/$id',
      attributeImageUrl: visuals.cardTypeMark(
        row['cardType'] ?? entry['cardType'],
      ),
      rarityImageUrl: visuals.mark('RarityIconCenter_$rarityLabel.png'),
    );
  }

  Map<String, Object?> _rulePool(String id) {
    final rawBrief = pools[id],
        rawRules = metadata['pools'],
        rawProducts = metadata['products'];
    final brief = rawBrief is Map
        ? rawBrief.cast<String, Object?>()
        : const <String, Object?>{};
    final value = rawRules is Map ? rawRules[id] : null;
    final rule = value is Map
        ? value.cast<String, Object?>()
        : const <String, Object?>{};
    final ids = rule['productIds'];
    final options = ids is List
        ? [
            for (final productId in ids)
              <String, Object?>{
                if (rawProducts is Map && rawProducts['$productId'] is Map)
                  ...(rawProducts['$productId'] as Map).cast<String, Object?>(),
                'id': '$productId',
              },
          ]
        : brief['drawOptions'];
    return {
      ...brief,
      ...rule,
      'id': rule['id'] ?? brief['id'] ?? id,
      'drawOptions': options,
    };
  }

  List<Map<String, Object?>> _exchangeTargets(
    Map pool,
    String Function(Object?) localized,
    HistorySnapshot? snapshot,
  ) {
    final options = pool['drawOptions'] is List
        ? (pool['drawOptions'] as List).whereType<Map>().toList()
        : <Map>[];
    final matching = (exchanges['entries'] as Map).values
        .whereType<Map>()
        .where((exchange) {
          final currency = exchange['currency'];
          return currency is Map &&
              currency['resourceType'] == 7 &&
              '${currency['resourceId']}' == pool['id'];
        })
        .toList();
    // Older public releases omit product identities and reset/stepped-price fields.
    if (pool['id'] == null ||
        options.isEmpty ||
        options.any((option) => option['id'] == null) ||
        matching.isEmpty ||
        matching.any(
          (exchange) =>
              exchange['products'] is! List ||
              (exchange['products'] as List).any(
                (target) =>
                    target is! Map ||
                    target['id'] == null ||
                    target['resetType'] == null ||
                    target['paymentSteps'] is! List ||
                    target['paymentStepResourceCounts'] is! List,
              ),
        )) {
      return [];
    }
    final candidates =
        options
            .where(
              (option) =>
                  option['gachaPoint'] is num &&
                  (option['gachaPoint'] as num) > 0 &&
                  option['drawCount'] is num &&
                  (option['drawCount'] as num) > 0,
            )
            .toList()
          ..sort(
            (a, b) => (a['drawCount'] as num).compareTo(b['drawCount'] as num),
          );
    if (candidates.isEmpty) return [];
    final server =
        snapshot?.server ?? (api.server == 'jp' ? 'jp' : 'global-hmt');
    if ((server == 'jp' ? 'jp' : 'intl') != api.server) return [];
    return points
        .gachaTargetProgress(
          pool.cast<String, Object?>(),
          exchanges.cast<String, Object?>(),
          snapshot?.accountState,
          server: server,
          gachaProductId: '${candidates.first['id']}',
        )
        .where((target) {
          final reward = target['reward'] as Map;
          return reward['resourceType'] == 2 || reward['resourceType'] == 3;
        })
        .map((target) {
          final reward = (target['reward'] as Map).cast<String, Object?>();
          final type = reward['resourceType'], id = '${reward['resourceId']}';
          final rawCard = (type == 2 ? cards : snapshots)[id];
          final card = rawCard is Map ? rawCard : const {};
          final images = card['images'];
          final image =
              (images is Map ? images['thumbnail'] : null) ??
              card['image'] ??
              reward['image'];
          final rarity = card['rarity'] ?? reward['rarity'];
          final rarityLabel =
              const {2: 'R', 3: 'SR', 4: 'SSR', 10: 'EX', 20: 'BD'}[rarity] ??
              '';
          final name = localized(
            card['prefix'] ??
                card['cardName'] ??
                card['name'] ??
                reward['name'],
          );
          final imageUrl = image is String && image.isNotEmpty
              ? api.asset(image).toString()
              : '';
          return <String, Object?>{
            ...target,
            'reward': <String, Object?>{
              ...reward,
              'kind': type == 2 ? 'MemberCard' : 'SupportCard',
              'name': name.isNotEmpty ? name : id,
              'image': imageUrl,
              'imageUrl': imageUrl,
              'rarity': rarity,
              'rarityLabel': rarityLabel,
              'href': type == 2
                  ? '/catalog/member-cards/$id'
                  : '/catalog/support-cards/$id',
              'attributeImageUrl': visuals.cardTypeMark(
                card['cardType'] ?? reward['cardType'],
              ),
              'rarityImageUrl': visuals.mark(
                'RarityIconCenter_$rarityLabel.png',
              ),
            },
          };
        })
        .toList();
  }

  String? _poolImage(Map pool) {
    final image = pool['logo'] is String && (pool['logo'] as String).isNotEmpty
        ? pool['logo']
        : pool['image'];
    return image is String && image.isNotEmpty
        ? api.asset(image).toString()
        : null;
  }

  List<GachaHistoryBatch> batchViews(
    HistorySnapshot snapshot,
    String accountKey,
    String Function(Object?) localized,
    String unknownLabel,
  ) {
    final prizeMap = metadata['prizes'] as Map;
    final poolMap = metadata['pools'] as Map;
    return [
      for (final (index, execution) in snapshot.executions.indexed)
        GachaHistoryBatch(
          id: '${snapshot.queriedAt.toUtc().toIso8601String()}:$index',
          accountKey: accountKey,
          poolId: execution.poolId ?? '',
          productId: execution.productId,
          pulledAt: execution.executedAt == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  execution.executedAt! * 1000,
                  isUtc: true,
                ),
          // Each history prize is one draw, including a currency item prize.
          // Ticket executions can be smaller than the product's bundle size.
          drawCount: execution.prizes.length,
          expected: _expectation(execution),
          prizes: [
            for (final prize in execution.prizes)
              _prizeView(
                prize,
                poolMap[execution.poolId],
                prizeMap,
                localized,
                unknownLabel,
              ),
          ],
          cost: GachaHistoryCost(
            freeGems: execution.freeGems,
            paidGems: execution.paidGems,
            tickets: execution.tickets,
          ),
          source: snapshot.server,
        ),
    ];
  }

  Map<String, num>? _expectation(HistoryExecution execution) {
    final pool = _rulePool(execution.poolId ?? '');
    final products = metadata['products'];
    final product = products is Map ? products[execution.productId] : null;
    final options =
        (pool['drawOptions'] is List ? pool['drawOptions'] as List : const [])
            .whereType<Map>()
            .map((value) => value.cast<String, Object?>())
            .toList();
    final exact = options
        .where(
          (option) =>
              option['id'] != null && '${option['id']}' == execution.productId,
        )
        .firstOrNull;
    if (exact != null) {
      return analysis.gachaHistoryExpectation(
        pool,
        exact,
        execution.prizes.length,
      );
    }
    if (product is! Map) return null;
    if (product['guaranteedCount'] is num) {
      return analysis.gachaHistoryExpectation(
        pool,
        product.cast<String, Object?>(),
        execution.prizes.length,
      );
    }
    final candidates = options
        .where((option) => option['drawCount'] == product['drawCount'])
        .toList();
    final rules = candidates
        .map(
          (option) => jsonEncode([
            option['guaranteedRarity'],
            option['guaranteedType'],
            option['guaranteedCount'],
            option['guaranteedNew'],
          ]),
        )
        .toSet();
    return rules.length == 1
        ? analysis.gachaHistoryExpectation(
            pool,
            candidates.first,
            execution.prizes.length,
          )
        : null;
  }

  GachaHistoryPrize _prizeView(
    HistoryPrize prize,
    Object? pool,
    Map prizeMap,
    String Function(Object?) localized,
    String unknownLabel,
  ) {
    final row = prizeMap[prize.prizeId];
    final type = row is Map ? row['resourceType'] : null;
    final id = row is Map ? '${row['resourceId']}' : '';
    final collection = type == 2
        ? cards
        : type == 3
        ? snapshots
        : type == 1
        ? items
        : const {};
    final card = collection[id];
    final images = card is Map ? card['images'] : null;
    final image = images is Map
        ? images['thumbnail']
        : card is Map
        ? card['image']
        : null;
    final rarity = card is Map ? card['rarity'] : null;
    final rarityLabel = type == 1
        ? ''
        : const {2: 'R', 3: 'SR', 4: 'SSR', 10: 'EX', 20: 'BD'}[rarity] ??
              unknownLabel;
    final groups = pool is Map ? pool['prizeGroupIds'] : null;
    final knownGroup =
        row is Map && groups is List && groups.contains(row['groupId']);
    return GachaHistoryPrize(
      id: id.isEmpty ? 'prize:${prize.prizeId}' : id,
      kind: type == 2
          ? 'member'
          : type == 3
          ? 'support'
          : type == 1
          ? 'item'
          : 'unknown',
      name: card is Map
          ? localized(card['prefix'] ?? card['cardName'] ?? card['name'])
          : '$unknownLabel · ${prize.prizeId}',
      rarity: rarity is num || rarity is String ? rarity! : '',
      rarityLabel: rarityLabel,
      converted: prize.converted,
      attributeImageUrl: card is Map && type != 1
          ? visuals.cardTypeMark(card['cardType'])
          : null,
      rarityImageUrl: type != 1
          ? visuals.mark('RarityIconCenter_$rarityLabel.png')
          : null,
      quantity: row is Map && row['count'] is int ? row['count'] as int : 1,
      imageUrl: image is String && image.isNotEmpty
          ? api.asset(image).toString()
          : null,
      href: type == 2
          ? '/catalog/member-cards/$id'
          : type == 3
          ? '/catalog/support-cards/$id'
          : null,
      pickup: knownGroup ? row['pickupType'] == 2 : null,
    );
  }
}
