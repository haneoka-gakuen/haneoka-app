import 'package:game_data_exporter/gacha_history_analysis.dart' as analysis;

class GachaHistoryAccount {
  const GachaHistoryAccount({
    required this.key,
    required this.server,
    required this.serverLabel,
    required this.label,
    this.offsetMinutes = 480,
  });
  final String key, server, serverLabel, label;
  final int offsetMinutes;
}

class GachaHistoryPool {
  const GachaHistoryPool({
    required this.id,
    required this.name,
    required this.category,
    this.imageUrl,
    this.bannerUrl,
    this.startAt,
    this.endAt,
    this.rates,
    this.featured = const [],
    this.exchangeTargets = const [],
  });
  final String id, name, category;
  final String? imageUrl, bannerUrl;
  final DateTime? startAt, endAt;

  /// Official single-draw probabilities (`gachaPoolRates`).
  final Map<String, Object?>? rates;
  final List<GachaHistoryFeatured> featured;
  final List<Map<String, Object?>> exchangeTargets;
}

/// A pool's pickup card, as the banner features it.
class GachaHistoryFeatured {
  const GachaHistoryFeatured({
    required this.key,
    required this.kind,
    required this.name,
    required this.rarity,
    this.imageUrl,
    this.href,
    this.attributeImageUrl,
    this.rarityImageUrl,
  });
  final String key, kind, name;
  final Object rarity;
  final String? imageUrl, href, attributeImageUrl, rarityImageUrl;
}

class GachaHistoryPrize {
  const GachaHistoryPrize({
    required this.id,
    required this.kind,
    required this.name,
    required this.rarity,
    required this.rarityLabel,
    required this.quantity,
    this.imageUrl,
    this.href,
    this.pickup,
    this.converted = false,
    this.attributeImageUrl,
    this.rarityImageUrl,
  });
  final String id, kind, name, rarityLabel;
  final Object rarity;
  final int quantity;
  final String? imageUrl, href;
  final bool? pickup;
  final bool converted;
  final String? attributeImageUrl, rarityImageUrl;
}

class GachaHistoryBatch {
  const GachaHistoryBatch({
    required this.id,
    required this.accountKey,
    required this.poolId,
    required this.pulledAt,
    required this.drawCount,
    required this.prizes,
    this.source,
    this.productId,
    this.expected,
    this.cost,
  });
  final String id, accountKey, poolId;
  final DateTime? pulledAt;
  final int? drawCount;
  final List<GachaHistoryPrize> prizes;
  final String? source;
  final String? productId;
  final GachaHistoryCost? cost;
  final Map<String, num>? expected;
}

Map<String, Object?> historyAnalysis(
  List<GachaHistoryBatch> batches, [
  int offsetMinutes = 480,
]) => analysis.analyzeGachaHistory(_historyInput(batches), offsetMinutes);

Map<String, Object?> historyProgress(List<GachaHistoryBatch> batches) =>
    analysis.gachaHistoryProgress(_historyInput(batches));

/// Hits per pool (`high` or `pickup`); each hit's `prize` is the view prize.
List<Map<String, Object?>> historyHits(
  List<GachaHistoryBatch> batches,
  String target,
) => [
  for (final pool in analysis.gachaHistoryHits(_historyInput(batches), target))
    {
      ...pool,
      'hits': [
        for (final hit in pool['hits'] as List)
          {
            ...hit as Map<String, Object?>,
            'prize': (hit['prize'] as Map)['_view'],
          },
      ],
    },
];

Map<String, Object?>? historyLuck(
  List<GachaHistoryBatch> batches,
  String target,
) => analysis.gachaHistoryLuck(_historyInput(batches), target);

List<Map<String, Object?>> historyMonths(
  List<GachaHistoryBatch> batches, [
  int offsetMinutes = 480,
]) => analysis.gachaHistoryMonths(_historyInput(batches), offsetMinutes);

List<Map<String, Object?>> _historyInput(List<GachaHistoryBatch> batches) => [
  for (final batch in batches)
    <String, Object?>{
      'id': batch.id,
      'poolId': batch.poolId,
      'pulledAt': batch.pulledAt?.toUtc().toIso8601String(),
      'expected': batch.expected,
      'cost': <String, Object?>{
        'freeGems': batch.cost?.freeGems,
        'paidGems': batch.cost?.paidGems,
        'tickets': batch.cost?.tickets,
      },
      'prizes': [
        for (final prize in batch.prizes)
          <String, Object?>{
            'id': prize.id,
            'kind': prize.kind,
            'rarity': prize.rarity,
            'quantity': prize.quantity,
            'pickup': prize.pickup,
            'converted': prize.converted,
            '_view': prize,
          },
      ],
    },
];

class GachaHistoryExport {
  const GachaHistoryExport({
    required this.accountKey,
    required this.batches,
    this.historyKind,
  });
  final String accountKey;
  final String? historyKind;
  final List<GachaHistoryBatch> batches;
}

class GachaHistoryCost {
  const GachaHistoryCost({this.freeGems, this.paidGems, this.tickets});
  final num? freeGems, paidGems, tickets;
}

class GachaHistoryConversion {
  const GachaHistoryConversion({
    required this.currencyCode,
    this.freeUnitGemPrice = 0,
    this.paidUnitGemPrice,
  });
  final String currencyCode;
  final double? freeUnitGemPrice, paidUnitGemPrice;
}
