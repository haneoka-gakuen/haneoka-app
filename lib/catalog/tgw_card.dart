import '../core/catalog_source.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'missions.dart';

const _tierKeys = {
  'normal': ('tierNormal', 'Normal'),
  'gold': ('tierGold', 'Gold'),
  'platinum': ('tierPlatinum', 'Platinum'),
  'black': ('tierBlack', 'Black'),
};

/// Card tier from the rank art's file name: `tgwcard_gold_7.png` → gold.
String _cardTier(Map tier) {
  final match = RegExp(r'tgwcard_(normal|gold|platinum|black)_\d+\.')
      .firstMatch('${tier['image'] ?? ''}');
  if (match != null) return match[1]!;
  final rank = (tier['rank'] as num?) ?? 0;
  return rank >= 16
      ? 'black'
      : rank >= 11
      ? 'platinum'
      : rank >= 6
      ? 'gold'
      : 'normal';
}

/// Sibling art in the rank image's folder: the tier's card face (`''`), rank
/// plate (`_rank`) and badge (`_small`).
String _cardArt(Map tier, String suffix) {
  final source = '${tier['image'] ?? ''}';
  final slash = source.lastIndexOf('/');
  return slash < 0
      ? ''
      : '${source.substring(0, slash + 1)}tgwcard_${_cardTier(tier)}$suffix.png';
}

/// T.G.W CARD (`tgw-card-workspace`): the membership benefits ladder. A rank
/// picker grouped by card tier selects one rank; the page shows its composed
/// card art with its points threshold, its benefits and its grants.
class TgwCardScreen extends StatefulWidget {
  const TgwCardScreen({super.key});
  @override
  State<TgwCardScreen> createState() => _TgwCardScreenState();
}

class _TgwCardScreenState extends State<TgwCardScreen> {
  Future<(List<Map>, Object?)>? _data;
  int? _rank;

  Object? _dataKey;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = CatalogSourceScope.keyOf(context);
    if (_dataKey != key) {
      _dataKey = key;
      _data = _load();
    }
  }

  Future<(List<Map>, Object?)> _load() async {
    final api = CatalogSourceScope.apiOf(context);
    final base = '/api/v1/servers/${api.server}/tgw-card';
    final document = (await api.json(base)) as Map;
    final entries = document['entries'];
    final summaries = switch (entries) {
      Map() => entries.values.whereType<Map>().toList(),
      List() => entries.whereType<Map>().toList(),
      _ => <Map>[],
    }..sort((a, b) => (a['rank'] as num).compareTo(b['rank'] as num));
    final tiers = <Map>[];
    for (var offset = 0; offset < summaries.length; offset += 80) {
      final chunk = summaries.skip(offset).take(80).toList();
      final query = [
        for (final tier in chunk)
          'id=${Uri.encodeQueryComponent('${tier['id']}')}',
      ].join('&');
      final details = (await api.json('$base?$query')) as Map;
      final items = (details['items'] as Map?) ?? const {};
      for (final summary in chunk) {
        final detail = items['${summary['id']}'];
        tiers.add({...summary, if (detail is Map) ...detail});
      }
    }
    return (tiers, document['pointName']);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    return ShellPage(
      title: 'T.G.W CARD',
      body: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton.tonal(
                onPressed: () => setState(() => _data = _load()),
                child: Text(t('common.actions.retry', 'Retry')),
              ),
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final (tiers, pointName) = data;
          if (tiers.isEmpty) {
            return Center(
              child: Text(
                t('catalog.tgwCard.empty', 'No rank data in this release'),
              ),
            );
          }
          final selected = tiers.firstWhere(
            (tier) => tier['rank'] == _rank,
            orElse: () => tiers.first,
          );
          return ListView(
            padding: pagePadding(context),
            children: [
              if (tiers.length > 1) _picker(tiers, selected),
              const SizedBox(height: 16),
              _TierView(
                tier: selected,
                next: tiers.elementAtOrNull(tiers.indexOf(selected) + 1),
                pointName: t.text(pointName),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _picker(List<Map> tiers, Map selected) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = <String, List<Map>>{};
    for (final tier in tiers) {
      (groups[_cardTier(tier)] ??= []).add(tier);
    }
    String pad(Object? rank) => '$rank'.padLeft(2, '0');
    final compact = MediaQuery.sizeOf(context).width < 600;
    Widget ranks(List<Map> group) => Row(
      children: [
        for (final (index, tier) in group.indexed) ...[
          if (index > 0) const SizedBox(width: 2),
          Expanded(
            child: () {
              final current = identical(tier, selected);
              final radius = BorderRadius.horizontal(
                left: Radius.circular(
                  current || index == 0 ? Corner.full : Corner.small,
                ),
                right: Radius.circular(
                  current || index == group.length - 1
                      ? Corner.full
                      : Corner.small,
                ),
              );
              return Semantics(
                selected: current,
                label: t.text(tier['title']),
                child: Material(
                  color: current
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  borderRadius: radius,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () =>
                        setState(() => _rank = (tier['rank'] as num).toInt()),
                    child: SizedBox(
                      height: 48,
                      child: Center(
                        child: Text(
                          pad(tier['rank']),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: current
                                ? scheme.onPrimary
                                : scheme.onSurface,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }(),
          ),
        ],
      ],
    );
    Widget badge(Map first) => SizedBox(
      width: 60,
      height: 28,
      child: AppImage(
        candidates: [
          CatalogSourceScope.apiOf(context)
              .asset(_cardArt(first, '_small'))
              .toString(),
        ],
      ),
    );
    Widget label(String kind) => Text(
      t('catalog.tgwCard.${_tierKeys[kind]!.$1}', _tierKeys[kind]!.$2),
      style: compact ? theme.textTheme.labelMedium : theme.textTheme.titleSmall,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = compact
            ? 1
            : ((constraints.maxWidth + 12) / 260).floor().clamp(1, 4);
        final gap = compact ? 8.0 : 12.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final MapEntry(key: kind, value: group) in groups.entries)
              Container(
                width: width,
                padding: EdgeInsets.all(compact ? 8 : 12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: compact
                    ? Row(
                        children: [
                          SizedBox(
                            width: 64,
                            child: Column(
                              children: [
                                badge(group.first),
                                const SizedBox(height: 2),
                                label(kind),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: ranks(group)),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              badge(group.first),
                              const SizedBox(width: 8),
                              Expanded(child: label(kind)),
                              Text(
                                '${pad(group.first['rank'])}–${pad(group.last['rank'])}',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ranks(group),
                        ],
                      ),
              ),
          ],
        );
      },
    );
  }
}

class _TierView extends StatelessWidget {
  const _TierView({
    required this.tier,
    required this.next,
    required this.pointName,
  });
  final Map tier;
  final Map? next;
  final String pointName;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    String text(
      String key,
      String fallback, [
      Map<String, Object?> values = const {},
    ]) => t('catalog.tgwCard.$key', fallback, values);
    String number(num value) =>
        NumberFormat.decimalPattern(t.locale).format(value);
    final points = (tier['pointsRequired'] as num?) ?? 0;
    final kind = _cardTier(tier);
    final compact = MediaQuery.sizeOf(context).width < 600;

    String duration(int seconds) {
      final hours = seconds ~/ 3600, minutes = seconds % 3600 ~/ 60;
      final rest = seconds % 60;
      return [
        if (hours > 0)
          t('common.time.spanHours', '{count} h', {'count': number(hours)}),
        if (minutes > 0)
          t('common.time.spanMinutes', '{count} m', {'count': number(minutes)}),
        if (rest > 0 || (hours == 0 && minutes == 0))
          text('durationSeconds', '{count} s', {'count': number(rest)}),
      ].join(' ');
    }

    /// A benefit in words (`benefitDisplay`): its count, time or percentage.
    String benefit(Map row) {
      final label = t.text(row['name']);
      final type = row['vipBonusType'], value = row['value'];
      if (type is! int || value is! int || value < 0) return label;
      final decimal = NumberFormat('#,##0.##', t.locale);
      return switch (type) {
        9 =>
          value == 0
              ? text('boostConsumptionUnlocked', label)
              : text('boostConsumptionLimit', label, {'count': number(value)}),
        1 => text('bandFormationBonus', label, {
          'count': decimal.format(value),
        }),
        3 => text('boostAutoRecoveryLimitBonus', label, {
          'count': decimal.format(value),
        }),
        8 => text('eventGachaFreeCountBonus', label, {
          'count': decimal.format(value),
        }),
        6 => text('studioTimeExtension', label, {'duration': duration(value)}),
        2 => text('boostRecoveryTimeReduction', label, {
          'percent': decimal.format(value / 100),
        }),
        5 => text('studioRewardBonus', label, {
          'percent': decimal.format(value / 100),
        }),
        7 => text('allParametersBoost', label, {
          'percent': decimal.format(value / 100),
        }),
        _ => label,
      };
    }

    final benefits = [
      for (final row
          in (tier['benefits'] as List? ?? const []).whereType<Map>())
        if (benefit(row).isNotEmpty) benefit(row),
    ];
    final daily = (tier['dailyRewards'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final rankRewards = (tier['rankRewards'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    String asset(String path) =>
        CatalogSourceScope.apiOf(context).asset(path).toString();

    // The game's card: face, rank plate and rank numeral layered as in-game.
    final art = SizedBox(
      width: compact ? 280 : 320,
      child: AspectRatio(
        aspectRatio: 980 / 630,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final h = constraints.maxHeight;
            return Stack(
              children: [
                Positioned.fill(
                  child: AppImage(candidates: [asset(_cardArt(tier, ''))]),
                ),
                Positioned(
                  top: h * 0.32,
                  height: h * 0.06,
                  left: 0,
                  right: 0,
                  child: AppImage(candidates: [asset(_cardArt(tier, '_rank'))]),
                ),
                Positioned(
                  top: h * 0.42,
                  height: h * 0.144,
                  left: 0,
                  right: 0,
                  child: AppImage(candidates: [asset('${tier['image']}')]),
                ),
              ],
            );
          },
        ),
      ),
    );
    final align = compact
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final copy = Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          t.text(tier['title']),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          t('catalog.tgwCard.${_tierKeys[kind]!.$1}', _tierKeys[kind]!.$2),
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          text('requiredPoints', 'Total points required'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Text.rich(
          TextSpan(
            text: number(points),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            children: [
              TextSpan(text: ' $pointName', style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          next == null
              ? text('maxRank', 'Highest rank')
              : text('toNextRank', '{points} to the next rank', {
                  'points':
                      '${number(((next!['pointsRequired'] as num?) ?? 0) - points)} $pointName',
                }),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    Widget panel(String title, Widget child) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Corner.extraLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
    Widget empty(String value) => Text(
      value,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
    Widget grant(String label, List<Map> rewards) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final reward in rewards) RewardChip(reward)],
          ),
        ],
      ),
    );
    final panels = [
      panel(
        text('benefits', 'Rank benefits'),
        benefits.isEmpty
            ? empty(text('noBenefits', 'No benefits at this rank'))
            : Column(
                children: [
                  for (final label in benefits)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Symbols.check_circle_rounded,
                            size: 20,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              label,
                              style: theme.textTheme.bodyLarge,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      panel(
        text('rewards', 'Rewards'),
        daily.isEmpty && rankRewards.isEmpty
            ? empty(text('noRewards', 'No rewards at this rank'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (daily.isNotEmpty)
                    grant(text('dailyRewards', 'Daily rewards'), [
                      for (final slot in daily)
                        (slot['reward'] as Map?) ?? const {},
                    ]),
                  if (rankRewards.isNotEmpty)
                    grant(text('rankRewards', 'Rank-up rewards'), rankRewards),
                ],
              ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Corner.extraLarge),
          ),
          child: compact
              ? Column(children: [art, const SizedBox(height: 20), copy])
              : Row(
                  children: [
                    art,
                    const SizedBox(width: 40),
                    Expanded(child: copy),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < 736
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [panels[0], const SizedBox(height: 16), panels[1]],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: panels[0]),
                    const SizedBox(width: 16),
                    Expanded(child: panels[1]),
                  ],
                ),
        ),
      ],
    );
  }
}
