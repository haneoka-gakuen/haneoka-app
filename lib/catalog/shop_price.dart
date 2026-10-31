import 'package:intl/intl.dart';

/// Currency groups each locale reads first, tried in order (`CURRENCY_CHAINS`).
const _chains = {
  'ja': [
    ['jpy'],
    ['usd'],
  ],
  'en': [
    ['usd'],
    ['jpy'],
  ],
  'zh-TW': [
    ['twd', 'hkd'],
    ['jpy'],
    ['usd'],
  ],
  'zh-CN': [
    ['cny'],
    ['twd', 'hkd'],
    ['jpy'],
    ['usd'],
  ],
  'ko': [
    ['krw'],
    ['jpy'],
    ['usd'],
  ],
};
const _symbols = {
  'usd': r'US$',
  'twd': r'NT$',
  'hkd': r'HK$',
  'krw': '₩',
  'jpy': 'JP¥',
  'cny': 'CN¥',
};

Map<String, num> shopPrices(Map payment, String server) {
  final table = {
    for (final MapEntry(:key, :value)
        in ((payment['prices'] as Map?) ?? const {}).entries)
      if (value is num && value > 0) '$key'.toLowerCase(): value,
  };
  // JP MasterShop lists whole-yen reference amounts (`jpShopReferencePrice`).
  final master = payment['masterPrice'];
  if (table.isEmpty &&
      server == 'jp' &&
      payment['storePurchase'] == true &&
      payment['advertisement'] != true &&
      payment['price'] == null &&
      master is Map &&
      master['value'] is int &&
      (master['value'] as int) > 0) {
    table['jpy'] = master['value'] as int;
  }
  return table;
}

/// Storefront-style money (`formatMoney`): whole amounts shed their cents.
String formatMoney(num amount, String currency, String locale) {
  final whole = amount == amount.truncate();
  final figure = NumberFormat(
    whole ? '#,##0' : '#,##0.00',
    locale,
  ).format(amount);
  final symbol = _symbols[currency.toLowerCase()];
  return symbol == null
      ? '$figure ${currency.toUpperCase()}'
      : '$symbol$figure';
}

/// "NT$30 · HK$8": the locale's own storefront prices (`shopPriceLine`).
String shopPriceLine(String locale, Map<String, num> prices) {
  for (final group in _chains[locale] ?? _chains['en']!) {
    final available = [
      for (final code in group)
        if ((prices[code] ?? 0) > 0) code,
    ];
    if (available.isNotEmpty) {
      return available
          .map((code) => formatMoney(prices[code]!, code, locale))
          .join(' / ');
    }
  }
  return '';
}
