import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/i18n.dart';
import '../core/net.dart';
import '../core/relative_time.dart';
import '../shell/links.dart';
import '../stories/stories.dart';
import '../stories/story_artwork.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import '../ui/upgrade.dart';
import 'catalog_screen.dart';
import 'gacha_simulator.dart';
import 'profiles.dart';
import 'visuals.dart';

const _scoreRanks = ['', 'E', 'D', 'C', 'B', 'A', 'S', 'SS'];

List<Map> _rows(Object? value) =>
    (value as List? ?? const []).whereType<Map>().toList();

Map _raw(Map row) => (row['raw'] as Map?) ?? const {};

num _num(Object? value) =>
    value is num ? value : num.tryParse('${value ?? ''}') ?? 0;

/// A reward's own record: nested under `reward`, or the row itself.
Map _rewardOf(Map row) => (row['reward'] as Map?) ?? row;

/// `member` / `support` for a card reward, else empty (`cardTileKind`).
String cardKindOf(Map item) =>
    item['kind'] == 'SupportCard' || item['resourceType'] == 3
    ? 'support'
    : item['kind'] == 'MemberCard' || item['resourceType'] == 2
    ? 'member'
    : '';

/// The sections of a rotating game system's page (`renderGameSystemDetail`):
/// events, recruitment, login campaigns, shop, exchange, passes, real lives.
class SystemDetail extends StatefulWidget {
  const SystemDetail({
    super.key,
    required this.resource,
    required this.item,
    required this.visuals,
  });
  final String resource;
  final Map<String, Object?> item;
  final CatalogVisuals? visuals;

  @override
  State<SystemDetail> createState() => _SystemDetailState();
}

class _SystemDetailState extends State<SystemDetail> {
  int _bonusRank = 5;
  int _pointBonus = 0, _itemBonus = 0;
  final _boost = <String, int>{};
  bool _finiteOnly = false;
  Future<Map<String, num>?>? _fx;

  AppState get state => AppScope.of(context);
  SiteText get t => state.text;
  Map<String, Object?> get item => widget.item;
  ThemeData get theme => Theme.of(context);
  ColorScheme get scheme => theme.colorScheme;

  String number(Object? value) =>
      NumberFormat.decimalPattern(t.locale).format(_num(value));

  /// `eventText`: the authored message with its values filled.
  String text(
    String key,
    String fallback, [
    Map<String, Object?> values = const {},
  ]) {
    final filled = {
      for (final MapEntry(:key, :value) in values.entries)
        key: value is num ? number(value) : value,
    };
    return t.system(key, fallback, filled);
  }

  CatalogKit _kit(String resource) => CatalogKit(
    catalogProfiles.firstWhere((p) => p.resource == resource),
    t,
    state.api,
    widget.visuals,
    songTitles: state.songTitle,
  );

  String _asset(Object? path) => state.api.asset('$path').toString();

  void _open(Object? href) {
    if (href is String && href.isNotEmpty) openLink(context, href);
  }

  @override
  Widget build(BuildContext context) {
    final rewards = _rows(item['rewards']);
    final sections = switch (widget.resource) {
      'events' => [
        _overview(),
        _recruitments(),
        _pickups(),
        _effects(),
        _song(),
        _story(),
        _rankings(),
        _eventRewards(),
        _missions(),
      ],
      'gacha' => [
        _overview(),
        GachaSimulator(
          key: ValueKey(item['id']),
          item: item,
          visuals: widget.visuals,
        ),
        _featured(),
        _rates(),
      ],
      'login-campaigns' => [_loginDays(rewards)],
      'shop' => [
        _shopFacts(),
        _rewardSection(rewards, t.label('contents', 'Contents')),
      ],
      'exchange' => [_exchange()],
      'circle' => [
        _rewardSection(rewards, t.label('rankRewards', 'Rank rewards')),
      ],
      'challenge' => [
        if (item['songHref'] case final String href)
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                onPressed: () => _open(href),
                icon: const Icon(Symbols.library_music_rounded, size: 18),
                label: Text(t.label('viewSong', 'View song')),
              ),
            ),
          ),
      ],
      'passes' =>
        item['kind'] == 'monthly-pass'
            ? [_loginDays(rewards)]
            : [_passLevels(), _passMissions()],
      'real-lives' => [_bands()],
      _ => const <Widget?>[],
    };
    final shown = sections.nonNulls.toList();
    if (widget.resource == 'events' && shown.length <= 1) {
      shown.add(
        _copy(
          text(
            'eventDetailsUnavailable',
            'No linked event details are available in this release.',
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: shown,
    );
  }

  // ---------- Shared pieces ----------

  Widget _copy(String value) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      value,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
  );

  String _plain(Object? value) => t
      .text(value)
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('\r', '')
      .trim();

  Widget _subheading(String label) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 8),
    child: Text(
      label,
      style: theme.textTheme.titleSmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _badge(String label) => Container(
    margin: const EdgeInsets.only(top: 2),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    height: 22,
    decoration: BoxDecoration(
      border: Border.all(color: scheme.outlineVariant),
      borderRadius: BorderRadius.circular(Corner.small),
    ),
    child: Text(label, style: theme.textTheme.labelMedium),
  );

  /// One reward row (`rewardRow`, `.detail-object`): emblem, linked name,
  /// secondary credit, trailing number.
  Widget? _reward(
    Map reward, {
    Widget? trailing,
    String? badge,
    bool quantity = true,
  }) {
    final name = t.text(reward['name']);
    if (name.isEmpty) return null;
    final secondary = t.text(reward['secondary']);
    final count = _num(reward['count']);
    final badgeLabel =
        badge ??
        (reward['pickup'] == true
            ? t.label('pickup', 'Pickup')
            : reward['bonus'] == true
            ? t.label('bonus', 'Bonus')
            : null);
    final href = reward['href'];
    final linked = href is String && href.isNotEmpty;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: badgeLabel == null ? 48 : 40),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 36,
            child: reward['image'] is String && '${reward['image']}'.isNotEmpty
                ? AppImage(candidates: [_asset(reward['image'])])
                : Icon(Symbols.redeem_rounded, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, style: theme.textTheme.titleSmall),
                if (secondary.isNotEmpty && secondary != name)
                  Text(
                    secondary,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 176),
              child: trailing,
            ),
          ] else if (quantity && count > 1) ...[
            const SizedBox(width: 12),
            _strong('×${number(count)}'),
          ],
        ],
      ),
    );
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: badgeLabel == null
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row,
                Padding(
                  padding: const EdgeInsets.only(left: 48),
                  child: _badge(badgeLabel),
                ),
              ],
            ),
    );
    return linked
        ? InkWell(
            onTap: () => _open(href),
            borderRadius: BorderRadius.circular(Corner.medium),
            child: body,
          )
        : body;
  }

  Widget _strong(String value, {bool end = false}) => Text(
    value,
    textAlign: end ? TextAlign.end : null,
    style: theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );

  Widget _list(Iterable<Widget?> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: rows.nonNulls.toList(),
  );

  Widget? _rewardSection(List<Map> rewards, String title) {
    if (rewards.isEmpty) return null;
    return DetailSection(
      icon: Symbols.redeem_rounded,
      title: title,
      count: rewards.length,
      child: _list(rewards.map(_reward)),
    );
  }

  /// A labelled group of a spec list whose value is a list of rows.
  Widget _spec(String label, Widget value) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        value,
      ],
    ),
  );

  /// `.spec-list--split`: label-over-value cells at least 150 dp wide.
  Widget _split(List<(String, Widget)> cells) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = ((constraints.maxWidth + 24) / 174).floor().clamp(1, 6);
      final width = (constraints.maxWidth - 24 * (columns - 1)) / columns;
      return Wrap(
        spacing: 24,
        runSpacing: 4,
        children: [
          for (final (label, value) in cells)
            SizedBox(width: width, child: _spec(label, value)),
        ],
      );
    },
  );

  /// `.detail-columns`: side by side when each can be [min] wide.
  Widget _columns(List<Widget> children, {double min = 300}) => LayoutBuilder(
    builder: (context, constraints) {
      if (children.length < 2 ||
          constraints.maxWidth < min * children.length + 16) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: child),
          ],
        ],
      );
    },
  );

  /// A card reward as the catalogue's own record (`rewardCardOptions`).
  Map<String, Object?> _cardRecord(Map reward, String kind) {
    final id = kind == 'support' ? 'supportCardId' : 'cardId';
    return {
      ...reward.cast<String, Object?>(),
      id: reward[id] ?? reward['resourceId'],
      'prefix': reward['prefix'] ?? reward['name'],
      'cardName': reward['cardName'] ?? reward['secondary'],
      'images': reward['images'] ?? {'thumbnail': reward['image']},
    };
  }

  /// A reward as its resource's catalogue tile (`gachaRewardTile`).
  Widget _rewardTile(Map reward, {List<TileMark> marks = const []}) {
    final kind = cardKindOf(reward);
    final href = reward['href'];
    final tap = href is String && href.isNotEmpty ? () => _open(href) : null;
    if (kind.isNotEmpty) {
      final kit = _kit(kind == 'support' ? 'support-cards' : 'cards');
      final record = _cardRecord(reward, kind);
      return Tile(
        title: kit.title(record),
        subtitle: kit.subtitle(record),
        adornments: kit.adornments(record),
        images: kit.images(record),
        aspectRatio: kit.profile.aspectRatio,
        fit: kit.profile.fit,
        marks: [...kit.marks(record), ...marks],
        onTap: tap,
      );
    }
    final title = t.text(reward['name']);
    return Tile(
      title: title.isEmpty ? t.label('reward', 'Reward') : title,
      subtitle: t.text(reward['secondary']),
      images: [if (reward['image'] is String) _asset(reward['image'])],
      marks: marks,
      onTap: tap,
    );
  }

  Widget _grid(
    List<Widget> tiles, {
    required double minWidth,
    double aspectRatio = 1,
    bool small = false,
  }) => LayoutBuilder(
    builder: (context, constraints) => GridView(
      shrinkWrap: true,
      primary: false,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: collectionGrid(
        context,
        constraints.maxWidth,
        minWidth: minWidth,
        aspectRatio: aspectRatio,
        small: small,
      ),
      children: tiles,
    ),
  );

  /// Rewards grouped by resource, each in its catalogue grid
  /// (`renderRewardGrid`).
  Widget _rewardGrid(
    List<Map> rewards, [
    List<TileMark> Function(Map reward)? marks,
  ]) {
    final groups = <Widget>[];
    for (final kind in ['member', 'support', 'item']) {
      final entries = rewards
          .where(
            (r) => (cardKindOf(r).isEmpty ? 'item' : cardKindOf(r)) == kind,
          )
          .toList();
      if (entries.isEmpty) continue;
      final profile = kind == 'item'
          ? null
          : catalogProfiles.firstWhere(
              (p) =>
                  p.resource == (kind == 'support' ? 'support-cards' : 'cards'),
            );
      groups.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                t.label(
                  kind == 'member'
                      ? 'memberCards'
                      : kind == 'support'
                      ? 'supportCards'
                      : 'items',
                  kind,
                ),
                style: theme.textTheme.titleSmall,
              ),
            ),
            _grid(
              [
                for (final reward in entries)
                  _rewardTile(reward, marks: marks?.call(reward) ?? const []),
              ],
              minWidth: profile?.minWidth ?? 132,
              aspectRatio: profile?.aspectRatio ?? 1,
              small: profile?.small ?? true,
            ),
            const SizedBox(height: 16),
          ],
        ),
      );
    }
    return _columns(groups, min: 360);
  }

  String _rate(Object? value) => _num(value) > 0
      ? '${NumberFormat('#,##0.###', t.locale).format(_num(value) * 100)}%'
      : '';

  // ---------- Overview ----------

  Widget _overview() {
    final start = RelativeTime.timestamp(item['startAt']) ?? 0;
    final end = RelativeTime.timestamp(item['endAt']) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final phase = start > now
        ? 'upcoming'
        : end > 0 && end < now
        ? 'ended'
        : 'ongoing';
    String instant(num value) => gameDateTime(t.locale, value);
    const rankingFields = [
      ('rankingDisabled', 'eventScoreRanking', 'Score ranking'),
      ('musicRankingDisabled', 'eventSongRanking', 'Song ranking'),
      (
        'totalMusicRankingDisabled',
        'eventTotalSongRanking',
        'Total song ranking',
      ),
    ];
    final active = [
      for (final (field, key, fallback) in rankingFields)
        if (item[field] == false) text(key, fallback),
    ];
    final eventItem = item['eventItem'];
    final description = _plain(item['description']);
    Widget value(String s) => Text(s, style: theme.textTheme.titleSmall);
    return DetailSection(
      icon: Symbols.info_rounded,
      title: t.label('details', 'Details'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (start > 0 || end > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Chip(label: Text(t.label(phase, phase))),
              ),
            ),
          _split([
            if (item['category'] case final String category)
              (
                t.label('category', 'Category'),
                value(t.label(category, category)),
              ),
            if (start > 0) (t.label('starts', 'Starts'), value(instant(start))),
            if (end > 0) (t.label('ends', 'Ends'), value(instant(end))),
          ]),
          if (rankingFields.any((f) => item[f.$1] is bool))
            _spec(
              text('eventAvailableRankings', 'Rankings'),
              value(
                active.isEmpty
                    ? text('eventRankingOff', 'No rankings')
                    : active.join(' / '),
              ),
            ),
          if (eventItem is Map)
            _spec(
              text('eventItem', 'Event item'),
              _eventReward(eventItem, quantity: false) ?? const SizedBox(),
            ),
          if (description.isNotEmpty) _copy(description),
        ],
      ),
    );
  }

  // ---------- Recruitment ----------

  Widget? _featured() {
    final featured = _rows(item['featured']);
    if (featured.isEmpty) return null;
    return DetailSection(
      icon: Symbols.style_rounded,
      title: t.label('featured', 'Featured'),
      count: featured.length,
      child: _rewardGrid(
        featured,
        (reward) => [
          if (_num(reward['rate']) > 0)
            TileMark.text(
              MarkAt.bottomStart,
              _rate(reward['rate']),
              label: t.label('rates', 'Rates'),
            ),
        ],
      ),
    );
  }

  Widget? _rates() {
    final rates = _rows(item['rates']);
    if (rates.isEmpty) return null;
    final warning = _plain(item['warning']);
    return DetailSection(
      icon: Symbols.percent_rounded,
      title: t.label('rates', 'Rates'),
      count: rates.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in rates)
            if (_rows(row['prizes']).isNotEmpty)
              DetailFold(
                title: [
                  t.label('${row['resourceType'] ?? ''}'),
                  cardRarityName(row['rarity']),
                ].where((label) => label.isNotEmpty).join(' '),
                meta: _rate(row['rate']),
                child: _list([
                  for (final prize in _rows(row['prizes']))
                    _reward(prize, trailing: _strong(_rate(prize['rate']))),
                ]),
              ),
          if (warning.isNotEmpty) _copy(warning),
        ],
      ),
    );
  }

  // ---------- Login campaigns, passes, real lives ----------

  Widget? _loginDays(List<Map> rewards) {
    if (rewards.isEmpty) return null;
    final days = <int, List<Map>>{};
    for (final slot in rewards) {
      (days[_num(slot['day']).toInt()] ??= []).add(
        (slot['reward'] as Map?) ?? const {},
      );
    }
    final keys = days.keys.toList()..sort();
    return DetailSection(
      icon: Symbols.redeem_rounded,
      title: t.label('dailyRewards', 'Daily rewards'),
      count: days.length,
      child: _split([
        for (final day in keys)
          (
            t.label('dayN', 'Day {day}').replaceAll('{day}', number(day)),
            _list(days[day]!.map(_reward)),
          ),
      ]),
    );
  }

  Widget? _passLevels() {
    final levels = _rows(item['levels']);
    if (levels.isEmpty) return null;
    final grouped = <int, List<Map>>{};
    for (final level in levels) {
      (grouped[_num(level['level']).toInt()] ??= []).add(level);
    }
    final keys = grouped.keys.toList()..sort();
    return DetailSection(
      icon: Symbols.redeem_rounded,
      title: t.label('levelRewards', 'Level rewards'),
      count: grouped.length,
      child: _split([
        for (final level in keys)
          (
            'Lv.${number(level)}',
            _list([
              for (final track in grouped[level]!)
                for (final reward in _rows(track['rewards']))
                  _reward(
                    reward,
                    badge: track['premium'] == true
                        ? t.label('premium', 'Premium')
                        : t.label('free', 'Free'),
                  ),
            ]),
          ),
      ]),
    );
  }

  Widget? _passMissions() {
    final tasks = _rows(item['tasks']);
    if (tasks.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: DetailFold(
        title: t.label('passMissions', 'Pass missions'),
        child: _list([
          for (final task in tasks)
            _reward(
              {'name': task['title']},
              trailing: _strong(
                '${number(task['points'])} ${t.label('points', 'pt')}',
              ),
            ),
        ]),
      ),
    );
  }

  Widget? _bands() {
    final bands = _rows(item['bands']);
    if (bands.isEmpty) return null;
    return DetailSection(
      icon: Symbols.info_rounded,
      title: t.label('bands', 'Bands'),
      count: bands.length,
      child: _list([
        for (final band in bands)
          _reward({
            'name': band['name'],
            'image': band['logo'] ?? band['icon'],
          }),
      ]),
    );
  }

  // ---------- Exchange ----------

  Widget _cost(String amount, Object? image, {bool end = false}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (image is String && image.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: SizedBox.square(
            dimension: 18,
            child: AppImage(candidates: [_asset(image)]),
          ),
        ),
      Flexible(child: _strong(amount, end: end)),
    ],
  );

  Widget? _exchange() {
    final products = _rows(item['products']);
    if (products.isEmpty) return null;
    final currency = (item['currency'] as Map?) ?? const {};
    final currencyName = t.text(currency['name']);
    bool finite(Map p) => p['limit'] is int && (p['limit'] as int) > 0;
    var total = 0, finiteCount = 0, unknown = 0;
    for (final product in products) {
      final limit = product['limit'], cost = product['cost'];
      if (limit is! int) {
        unknown++;
        continue;
      }
      if (limit <= 0) continue;
      finiteCount++;
      if (cost is! int || cost < 0) {
        unknown++;
        continue;
      }
      total += cost * limit;
    }
    final shown = _finiteOnly ? products.where(finite).toList() : products;
    return DetailSection(
      icon: Symbols.notes_rounded,
      title: t.label('exchangeGoods', 'Exchange goods'),
      count: shown.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _spec(
            t.label('exchangeFiniteTotal', 'Full finite stock cost'),
            unknown > 0
                ? Text(
                    t.label(
                      'exchangeUnknownCost',
                      'Some product costs or limits are unavailable',
                    ),
                    style: theme.textTheme.titleSmall,
                  )
                : _cost('${number(total)} $currencyName', currency['image']),
          ),
          _copy(
            t.label(
              'exchangeFullStockHint',
              'All listed finite stock; prior purchases are not deducted. Unlimited goods are excluded.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilterChip(
                label: Text(
                  '${t.label('exchangeFiniteOnly', 'Finite stock only')} $finiteCount',
                ),
                selected: _finiteOnly,
                onSelected: (value) => setState(() => _finiteOnly = value),
              ),
            ),
          ),
          for (final product in shown)
            ?_reward(
              (product['reward'] as Map?) ?? const {},
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _cost(
                    '${product['cost'] is int && (product['cost'] as int) >= 0 ? number(product['cost']) : t.label('unknown', 'Unknown')} $currencyName',
                    currency['image'],
                    end: true,
                  ),
                  Text(
                    '${t.label('exchangePurchaseLimit', 'Purchase limit')}: ${product['limit'] is int ? ((product['limit'] as int) > 0 ? '${product['limit']}' : t.label('unlimited', 'Unlimited')) : t.label('unknown', 'Unknown')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------- Shop ----------

  static const _currencyOrder = ['usd', 'jpy', 'cny', 'twd', 'hkd', 'krw'];
  static const _symbols = {
    'usd': r'US$',
    'twd': r'NT$',
    'hkd': r'HK$',
    'krw': '₩',
    'jpy': 'JP¥',
    'cny': 'CN¥',
  };
  static const _currencyNames = {
    'usd': ['米ドル', 'US Dollar', '美元', '美元', '미국 달러'],
    'jpy': ['日本円', 'Japanese Yen', '日圓', '日元', '일본 엔화'],
    'cny': ['中国人民元', 'Chinese Yuan', '人民幣', '人民币', '중국 위안화'],
    'twd': ['新台湾ドル', 'New Taiwan Dollar', '新台幣', '新台币', '신 타이완 달러'],
    'hkd': ['香港ドル', 'Hong Kong Dollar', '港幣', '港元', '홍콩 달러'],
    'krw': ['韓国ウォン', 'South Korean Won', '韓元', '韩元', '대한민국 원'],
  };
  static const _localeCurrency = {
    'ja': 'jpy',
    'en': 'usd',
    'zh-TW': 'twd',
    'zh-CN': 'cny',
    'ko': 'krw',
  };

  /// Storefront-style money (`formatMoney`): whole amounts shed their cents.
  String _money(num amount, String currency) {
    final whole = amount == amount.truncate();
    final figure = NumberFormat(
      whole ? '#,##0' : '#,##0.00',
      t.locale,
    ).format(amount);
    final symbol = _symbols[currency];
    return symbol == null
        ? '$figure ${currency.toUpperCase()}'
        : '$symbol$figure';
  }

  static Future<Map<String, num>?>? _rates$;

  /// Daily reference rates against the US dollar (`fetchShopFxRates`).
  static Future<Map<String, num>?> _loadRates() => _rates$ ??= () async {
    Map<String, num>? clean(Object? value) {
      final rates = {
        for (final MapEntry(:key, :value)
            in ((value as Map?) ?? const {}).entries)
          if (value is num && value > 0) '$key'.toLowerCase(): value,
      };
      return rates.containsKey('usd') ? rates : null;
    }

    for (final (url, field) in const [
      (
        'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json',
        'usd',
      ),
      ('https://open.er-api.com/v6/latest/USD', 'rates'),
    ]) {
      try {
        final response = await netClient.get(Uri.parse(url));
        if (response.statusCode != 200) continue;
        final rates = clean((jsonDecode(response.body) as Map)[field]);
        if (rates != null) return rates;
      } catch (_) {}
    }
    _rates$ = null;
    return null;
  }();

  Widget? _shopFacts() {
    final payment = (item['payment'] as Map?) ?? const {};
    final prices = {
      for (final MapEntry(:key, :value)
          in ((payment['prices'] as Map?) ?? const {}).entries)
        if (value is num && value > 0) '$key'.toLowerCase(): value,
    };
    final master = payment['masterPrice'];
    if (prices.isEmpty &&
        state.server == 'jp' &&
        payment['storePurchase'] == true &&
        payment['price'] == null &&
        master is Map &&
        master['value'] is int) {
      prices['jpy'] = master['value'] as int;
    }
    final codes = prices.keys.toList()
      ..sort((a, b) {
        int rank(String c) =>
            _currencyOrder.contains(c) ? _currencyOrder.indexOf(c) : 99;
        return rank(a).compareTo(rank(b));
      });
    final target = _localeCurrency[t.locale] ?? 'usd';
    Widget value(String s) => Text(s, style: theme.textTheme.titleSmall);
    final cells = <(String, Widget)>[];
    if (payment['advertisement'] == true) {
      cells.add((
        t.label('price', 'Price'),
        value(t.label('watchAd', 'Watch an ad')),
      ));
    } else {
      if (codes.any((c) => c != target)) _fx ??= _loadRates();
      for (final code in codes) {
        final amount = prices[code]!;
        final index = SiteText.tupleOrder.indexOf(t.locale);
        cells.add((
          _currencyNames[code]?[index < 0 ? 1 : index] ?? code.toUpperCase(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              value(_money(amount, code)),
              if (code != target)
                FutureBuilder(
                  future: _fx,
                  builder: (context, snapshot) {
                    final rates = snapshot.data;
                    final from = rates?[code], to = rates?[target];
                    final settled =
                        snapshot.connectionState == ConnectionState.done;
                    return Text(
                      from != null && to != null
                          ? '≈ ${_money(amount * to / from, target)}'
                          : settled
                          ? ''
                          : '≈',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    );
                  },
                ),
            ],
          ),
        ));
      }
      if (codes.isEmpty) {
        final price = _num(payment['price']);
        if (payment['storePurchase'] == true && price == 0) {
          cells.add((
            t.label('price', 'Price'),
            value(t.label('inAppPurchase', 'In-app purchase')),
          ));
        } else if (price != 0) {
          cells.add((
            t.label('price', 'Price'),
            _cost(
              '${number(price)} ${t.text(payment['currency'])}',
              payment['currencyImage'],
            ),
          ));
        }
      }
    }
    if (_num(item['limit']) != 0) {
      cells.add((t.label('limit', 'Limit'), value(number(item['limit']))));
    }
    if (_num(item['vipRank']) != 0) {
      cells.add((
        t.label('tgwCard', 'T.G.W CARD'),
        value(
          t
              .label('requiresRank', 'Rank {rank}')
              .replaceAll('{rank}', '${item['vipRank']}'),
        ),
      ));
    }
    if (cells.isEmpty) return null;
    return DetailSection(
      icon: Symbols.info_rounded,
      title: t.label('details', 'Details'),
      child: _split(cells),
    );
  }

  // ---------- Events ----------

  String _points(Object? value) =>
      text('eventPoints', '{points} pt', {'points': _num(value)});

  String _condition(Map row) {
    final raw = _raw(row);
    if (row['sourceTable'] == 'MasterEventAchievementLoopReward') {
      return text('eventLoopCondition', 'Every {every} pt after {from} pt', {
        'every': _num(raw['_loopEventPoint']),
        'from': _num(raw['_loopStartEventPoint']),
      });
    }
    final point = raw['_eventPoint'] ?? raw['_point'] ?? raw['_requiredPoint'];
    final rank = raw['_rank'] ?? raw['_ranking'];
    return [
      if (point != null) _points(point),
      if (rank != null) text('eventRankN', 'Rank {rank}', {'rank': _num(rank)}),
      if (raw['_scoreRank'] != null)
        _scoreRanks.elementAtOrNull(_num(raw['_scoreRank']).toInt()) ?? '—',
      for (final (field, key, fallback) in const [
        ('_achievementCount', 'eventGoalN', 'Goal {count}'),
        ('_limitCount', 'eventLimitN', 'Limit {count}'),
        ('_boxNumber', 'eventBoxN', 'Box {count}'),
      ])
        if (_num(raw[field]) > 0)
          text(key, fallback, {'count': _num(raw[field])}),
    ].join(' / ');
  }

  /// One resource with its quantity and authored chance (`eventRewardRow`).
  Widget? _eventReward(Map row, {bool quantity = true, bool compact = false}) {
    final reward = _rewardOf(row);
    final kind = cardKindOf(reward);
    if (compact && kind.isNotEmpty) return _cardIdentity(reward, kind);
    final probability = _raw(row)['_probability'];
    final name = t.text(reward['name']);
    return _reward(
      {
        ...reward,
        'name': name.isEmpty
            ? t.label('rewardUnavailable', 'Reward unavailable')
            : reward['name'],
        if (probability is num && probability < 10000)
          'secondary': [
            t.text(reward['secondary']),
            text('eventProbability', '{rate}% chance', {
              'rate': probability / 100,
            }),
          ].where((s) => s.isNotEmpty && s != name).join(' / '),
        'count': null,
      },
      quantity: false,
      trailing: quantity
          ? _strong('×${number(reward['count'] ?? row['resourceCount'] ?? 1)}')
          : null,
    );
  }

  /// A card as artwork beside its title and credit (`compactIdentity`).
  Widget _cardIdentity(Map reward, String kind) {
    final kit = _kit(kind == 'support' ? 'support-cards' : 'cards');
    final record = _cardRecord(reward, kind);
    final href = reward['href'];
    final adornments = kit.adornments(record);
    return InkWell(
      onTap: href is String && href.isNotEmpty ? () => _open(href) : null,
      borderRadius: BorderRadius.circular(Corner.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: kind == 'member' ? 54 : 72,
              child: AspectRatio(
                aspectRatio: kit.profile.aspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Corner.small),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AppImage(
                        candidates: kit.images(record),
                        fit: BoxFit.cover,
                      ),
                      for (final mark in kit.marks(record))
                        if (mark.image != null)
                          Positioned(
                            top: 4,
                            left: mark.at == MarkAt.start ? 4 : null,
                            right: mark.at == MarkAt.end ? 4 : null,
                            width: 16,
                            height: 16,
                            child: AppImage(candidates: [mark.image!]),
                          ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    kit.title(record),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      for (final image in adornments)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: SizedBox.square(
                            dimension: 16,
                            child: AppImage(candidates: [image]),
                          ),
                        ),
                      Flexible(
                        child: Text(
                          kit.subtitle(record),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _recruitments() {
    final recruitments = _rows(item['recruitments']);
    if (recruitments.isEmpty) return null;
    final kit = _kit('gacha');
    return DetailSection(
      icon: Symbols.notes_rounded,
      title: text('eventRecruitments', 'Related recruitments'),
      count: recruitments.length,
      child: _grid(
        [
          for (final gacha in recruitments)
            Tile(
              title: t.text(gacha['title']),
              subtitle: kit.subtitle(gacha.cast<String, Object?>()),
              images: [if (gacha['image'] is String) _asset(gacha['image'])],
              aspectRatio: 16 / 9,
              onTap: () => _open(gacha['href']),
            ),
        ],
        minWidth: kit.profile.minWidth,
        aspectRatio: 16 / 9,
      ),
    );
  }

  Widget? _pickups() {
    final cards = [
      for (final row in _rows(item['pickupCards']))
        if (row['card'] case final Map card)
          {..._rewardOf(card), 'resourceType': row['resourceType']},
    ];
    if (cards.isEmpty) return null;
    return DetailSection(
      icon: Symbols.style_rounded,
      title: text('eventRewardCards', 'Event reward cards'),
      count: cards.length,
      child: _rewardGrid(
        cards,
        (card) => [
          if (_num(card['rate']) > 0)
            TileMark.text(
              MarkAt.bottomStart,
              text('eventUpRate', 'UP {rate}%', {
                'rate': _num(card['rate']) * 100,
              }),
            ),
        ],
      ),
    );
  }

  Widget? _song() {
    final song = item['song'];
    if (song is! Map) return null;
    final kit = _kit('songs');
    final record = song.cast<String, Object?>();
    return DetailSection(
      icon: Symbols.library_music_rounded,
      title: text('eventSong', 'Event song'),
      child: _grid([
        Tile(
          title: kit.title(record),
          subtitle: kit.subtitle(record),
          adornments: kit.adornments(record),
          images: kit.images(record),
          marks: kit.marks(record),
          onTap: () => _open(song['href']),
        ),
      ], minWidth: kit.profile.minWidth),
    );
  }

  Widget? _story() {
    final story = item['story'];
    if (story is! Map) return null;
    final episodes = _rows(story['episodes']);
    final groups = [
      (
        'eventMainEpisodes',
        'Main',
        episodes.where(
          (e) => e['isExtraEpisode'] != true && e['isAnotherEpisode'] != true,
        ),
      ),
      (
        'eventExtraStory',
        'Extra',
        episodes.where(
          (e) => e['isExtraEpisode'] == true && e['isAnotherEpisode'] != true,
        ),
      ),
      (
        'eventAnotherStory',
        'Another',
        episodes.where((e) => e['isAnotherEpisode'] == true),
      ),
    ];
    final banner = story['banner'] ?? story['image'];
    final description = _plain(story['description']);
    final bandIcon = (story['bandDetails'] as Map?)?['icon'];
    String duration(Object? value) {
      final seconds = _num(value).round();
      return seconds == 0
          ? ''
          : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    }

    return DetailSection(
      icon: Symbols.auto_stories_rounded,
      title: text('eventStory', 'Event story'),
      count: episodes.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (banner is String && banner.isNotEmpty)
            _grid(
              [
                Tile(
                  title: t.text(story['chapterName']).isEmpty
                      ? t.text(item['title'])
                      : t.text(story['chapterName']),
                  subtitle: null,
                  images: [_asset(banner)],
                  aspectRatio: 16 / 9,
                  onTap: () => _open(
                    '/catalog/stories/event?chapter=${story['chapterId']}',
                  ),
                ),
              ],
              minWidth: 220,
              aspectRatio: 16 / 9,
            ),
          if (description.isNotEmpty &&
              description != _plain(item['description']))
            _copy(description),
          for (final (key, fallback, entries) in groups)
            if (entries.isNotEmpty) ...[
              _subheading(text(key, fallback)),
              _grid(
                [
                  for (final episode in entries)
                    Tile(
                      title: switch (t.text(
                        episode['titleText'] ??
                            episode['title'] ??
                            episode['prefix'],
                      )) {
                        '' => t.label('storyEpisode', 'Story episode'),
                        final title => title,
                      },
                      subtitle: t.text(
                        [
                          episode['description'],
                          episode['caption'],
                          story['chapterName'],
                        ].firstWhere(
                          (v) => t.text(v).isNotEmpty,
                          orElse: () => null,
                        ),
                      ),
                      adornments: [
                        ?episodeIdentityArtwork(
                          episode,
                          widget.visuals,
                          normalArtwork: bandIcon is String
                              ? _asset(bandIcon)
                              : null,
                        ),
                      ],
                      images: [
                        for (final key in ['image', 'banner'])
                          if (episode[key] case final String path
                              when path.isNotEmpty)
                            _asset(path),
                        if (story['banner'] case final String path)
                          _asset(path),
                      ],
                      aspectRatio: 16 / 9,
                      fit: BoxFit.cover,
                      marks: [
                        if (_num(episode['eventPoint']) > 0)
                          TileMark.text(
                            MarkAt.bottomStart,
                            text('eventStoryUnlock', 'Unlock at {points} pt', {
                              'points': _num(episode['eventPoint']),
                            }),
                          ),
                        if (duration(episode['playTime']).isNotEmpty)
                          TileMark.text(
                            MarkAt.bottomEnd,
                            duration(episode['playTime']),
                          ),
                      ],
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => StoryReaderScreen(
                            episode: episode.cast<String, Object?>(),
                          ),
                        ),
                      ),
                    ),
                ],
                minWidth: 220,
                aspectRatio: 16 / 9,
              ),
            ],
        ],
      ),
    );
  }

  Widget? _eventRewards() {
    String identity(Map row) =>
        '${row['sourceTable']}:${row['sourceId']}:${row['rewardId'] ?? row['resourceId']}';
    final mapped = {
      for (final rank in _rows(item['rankings']))
        for (final row in _rows(rank['rewards'])) identity(row),
    };
    final rewards = _rows(item['rewards'])
        .where((row) => !mapped.contains(identity(row)))
        .toList();
    if (rewards.isEmpty) return null;
    const labels = {
      'MasterEventAchievementReward': (
        'achievementRewards',
        'Achievement rewards',
      ),
      'MasterEventAchievementLoopReward': ('loopRewards', 'Loop rewards'),
      'MasterEventBoxGachaReward': ('boxGachaRewards', 'Box rewards'),
      'MasterEventRankingReward': ('rankingRewards', 'Ranking rewards'),
      'MasterLiveEventReward': ('liveEventRewards', 'Live rewards'),
      'MasterChallengeLiveEventReward': (
        'challengeRewards',
        'Challenge rewards',
      ),
    };
    final tables = <String, List<Map>>{};
    for (final row in rewards) {
      (tables['${row['sourceTable'] ?? ''}'] ??= []).add(row);
    }
    return DetailSection(
      icon: Symbols.redeem_rounded,
      title: text('eventRewards', 'Event rewards'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final MapEntry(key: table, value: rows) in tables.entries)
            () {
              final tiers = <String, List<Map>>{};
              for (final row in rows) {
                (tiers['${row['sourceId']}'] ??= []).add(row);
              }
              final (key, fallback) = labels[table] ?? ('rewards', 'Rewards');
              final content = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final tier in tiers.values)
                    _spec(
                      _condition(tier.first).isEmpty
                          ? t.label('rewards', 'Rewards')
                          : _condition(tier.first),
                      _list(tier.map(_eventReward)),
                    ),
                ],
              );
              return tiers.length > 12
                  ? DetailFold(
                      title: text(key, fallback),
                      meta: number(tiers.length),
                      child: content,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [_subheading(text(key, fallback)), content],
                    );
            }(),
        ],
      ),
    );
  }

  Widget _bonusField(String label, int value, ValueChanged<int> onChanged) =>
      TextFormField(
        initialValue: value == 0 ? '' : '${value / 100}',
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          suffixText: '%',
          border: const OutlineInputBorder(),
        ),
        onChanged: (text) {
          final parsed = double.tryParse(text) ?? 0;
          onChanged(parsed > 0 ? (parsed * 100).round() : 0);
        },
      );

  Widget? _rankings() {
    final rows = _rows(item['rankings']);
    if (rows.isEmpty) return null;
    final boosts = (item['boosts'] as Map?) ?? const {};
    final itemId = _num((item['eventItem'] as Map?)?['resourceId']);
    final columns = <Widget>[];
    for (final kind in ['live', 'challenge']) {
      final entries = rows.where((r) => r['kind'] == kind).toList();
      if (entries.isEmpty) continue;
      final table = _rows(boosts[kind]);
      final levels = [
        if (kind == 'live') 0,
        for (final row in table) _num(row['consumed']).toInt(),
      ];
      final chosen = levels.contains(_boost[kind])
          ? _boost[kind]!
          : (levels.firstOrNull ?? 0);
      final boost = table
          .where((r) => _num(r['consumed']) == chosen)
          .firstOrNull;
      final pointRate = _num(boost?['pointRate'] ?? 1).toInt();
      final rewardRate = _num(boost?['rewardRate'] ?? 1).toInt();
      columns.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _subheading(
              t.label(
                kind == 'live' ? 'liveRanking' : 'challengeRanking',
                kind == 'live' ? 'Live' : 'Challenge live',
              ),
            ),
            if (levels.length > 1)
              LevelSwitch(
                label: kind == 'live'
                    ? text('eventLiveBoost', 'LIVE BOOST')
                    : text('eventChallengePoints', 'Challenge points'),
                levels: levels,
                value: chosen,
                format: number,
                onChanged: (value) => setState(() => _boost[kind] = value),
              ),
            for (final row in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 28,
                      child: AppImage(
                        candidates: [
                          _asset(
                            '/assets/${state.server}/Assets/AddressableResources/UI/Texture/BandRank/ImgScorerank_${_scoreRanks.elementAtOrNull(_num(row['scoreRank']).toInt()) ?? ''}.png',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 104,
                      child: Text(
                        _points(
                          table.isEmpty
                              ? row['pointValue']
                              : (_num(row['pointValue']).toInt() *
                                        pointRate *
                                        (_pointBonus + 10000)) ~/
                                    10000,
                        ),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final entry in _rows(row['rewards']))
                            () {
                              final reward = _rewardOf(entry);
                              final count =
                                  table.isNotEmpty &&
                                      _num(entry['resourceId']) == itemId
                                  ? (_num(entry['resourceCount'] ?? 1).toInt() *
                                            (_itemBonus + 10000) *
                                            rewardRate) ~/
                                        10000
                                  : reward['count'] ??
                                        entry['resourceCount'] ??
                                        1;
                              return InkWell(
                                onTap: reward['href'] is String
                                    ? () => _open(reward['href'])
                                    : null,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (reward['image'] is String)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                          ),
                                          child: SizedBox.square(
                                            dimension: 26,
                                            child: AppImage(
                                              candidates: [
                                                _asset(reward['image']),
                                              ],
                                            ),
                                          ),
                                        ),
                                      Flexible(
                                        child: Text(
                                          t.text(reward['name']),
                                          style: theme.textTheme.bodyMedium,
                                        ),
                                      ),
                                      Text(
                                        ' ×${number(count)}',
                                        style: theme.textTheme.titleSmall,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }
    return DetailSection(
      icon: Symbols.redeem_rounded,
      title: text('eventLiveRewards', 'Live rewards'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_rows(boosts['live']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _bonusField(
                      text('eventPointBonus', 'Point bonus'),
                      _pointBonus,
                      (v) => setState(() => _pointBonus = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _bonusField(
                      text('eventItemBonusInput', 'Item bonus'),
                      _itemBonus,
                      (v) => setState(() => _itemBonus = v),
                    ),
                  ),
                ],
              ),
            ),
          _columns(columns),
        ],
      ),
    );
  }

  Widget? _effects() {
    final effects = _rows(item['effects']);
    if (effects.isEmpty) return null;
    final levels = {
      for (final effect in effects)
        for (final value in _rows(effect['perRank']))
          if (_num(value['rank']) >= 1 && _num(value['rank']) <= 5)
            _num(value['rank']).toInt(),
    }.toList()..sort();
    final rank = levels.contains(_bonusRank)
        ? _bonusRank
        : (levels.lastOrNull ?? 5);
    Object? constraint(Map row) =>
        row['resourceTypeConstraint'] ?? _raw(row)['_resourceTypeConstraint'];
    String target(Map row) {
      final raw = _raw(row);
      return [
        constraint(row),
        raw['_memberCardId'],
        raw['_supportCardId'],
        raw['_characterId'],
        raw['_bandId'],
        raw['_cardType'],
        raw['_tagId'],
      ].join(':');
    }

    final groups = <String, List<Map>>{};
    for (final effect in effects) {
      (groups[target(effect)] ??= []).add(effect);
    }
    num bonusType(Map row) =>
        _num(row['bonusType'] ?? _raw(row)['_eventBonusType']);
    String percent(Map? row) {
      final value = _rows(row?['perRank'])
          .where((v) => _num(v['rank']) == rank)
          .firstOrNull;
      return value == null ? '—' : '+${number(value['percent'])}%';
    }

    Widget figure(String label, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.titleSmall),
      ],
    );
    const attributes = ['', 'red', 'blue', 'green', 'yellow', 'purple'];
    final columns = <Widget>[];
    for (final type in [2, 3]) {
      final entries = groups.values
          .where((g) => _num(constraint(g.first)) == type)
          .toList();
      if (entries.isEmpty) continue;
      columns.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _subheading(
              t.label(type == 2 ? 'memberCards' : 'supportCards', ''),
            ),
            for (final group in entries)
              () {
                final first = group.first;
                final cardType = _num(
                  first['cardType'] ?? _raw(first)['_cardType'],
                ).toInt();
                final mark = widget.visuals?.cardTypeMark(cardType);
                final targets = [
                  for (final MapEntry(:key, :value)
                      in ((first['targets'] as Map?) ?? const {}).entries)
                    if (value is Map)
                      key == 'attribute' ? {...value, 'image': mark} : value,
                ];
                final fallback = cardType > 0
                    ? {
                        'image': mark,
                        'name': t.label(
                          attributes.elementAtOrNull(cardType) ?? 'attribute',
                          'Attribute',
                        ),
                      }
                    : {'name': text('eventAnyCard', 'All cards')};
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: _list([
                          for (final target
                              in targets.isEmpty ? [fallback] : targets)
                            _eventReward(
                              target,
                              quantity: false,
                              compact: true,
                            ),
                        ]),
                      ),
                      const SizedBox(width: 12),
                      figure(
                        text('eventParameterBonus', 'Parameters'),
                        percent(
                          group
                              .where((r) => bonusType(r) == type - 2)
                              .firstOrNull,
                        ),
                      ),
                      const SizedBox(width: 12),
                      figure(
                        text('eventItemBonus', 'Event items'),
                        percent(
                          group.where((r) => bonusType(r) == 2).firstOrNull,
                        ),
                      ),
                    ],
                  ),
                );
              }(),
          ],
        ),
      );
    }
    final note = _plain(item['bonusNote']);
    return DetailSection(
      icon: Symbols.bolt_rounded,
      title: text('eventEffects', 'Event bonuses'),
      count: groups.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LevelSwitch(
            label: text('eventBonusRank', 'Card rank'),
            levels: levels,
            value: rank,
            format: (value) =>
                text('eventRankN', 'Rank {rank}', {'rank': value}),
            onChanged: (value) => setState(() => _bonusRank = value),
          ),
          _columns(columns),
          if (note.isNotEmpty) _copy(note),
        ],
      ),
    );
  }

  Widget? _missions() {
    final missions = _rows(item['missions']);
    if (missions.isEmpty) return null;
    return DetailSection(
      icon: Symbols.task_alt_rounded,
      title: t.label('missions', 'Missions'),
      count: missions.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final mission in missions)
            _spec(
              _plain(mission['description']).isEmpty
                  ? text('eventMission', 'Event mission')
                  : _plain(mission['description']),
              _list(_rows(mission['rewards']).map(_eventReward)),
            ),
        ],
      ),
    );
  }
}
