import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/relative_time.dart';
import '../shell/links.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import '../ui/upgrade.dart';

List<Map> _rows(Object? value) =>
    (value as List? ?? const []).whereType<Map>().toList();

num _num(Object? value) =>
    value is num ? value : num.tryParse('${value ?? ''}') ?? 0;

String _href(AppState state, Object? resource, Object? id) =>
    '/${state.server}/${state.text.locale}/${resource == 'cards' ? 'member-cards' : resource}/$id/';

/// A band item's effect at each level and the materials for that step
/// (`.band-item-level-detail`).
class BandItemLevels extends StatefulWidget {
  const BandItemLevels({super.key, required this.item, required this.page});
  final Map<String, Object?> item;
  final Map? page;

  @override
  State<BandItemLevels> createState() => _BandItemLevelsState();
}

class _BandItemLevelsState extends State<BandItemLevels> {
  int? _level;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final item = widget.item;
    final effects = _rows(item['effects']);
    final levels = {
      for (final row in [..._rows(item['levels']), ...effects])
        if (_num(row['level']) > 0) _num(row['level']).toInt(),
    }.toList()..sort();
    if (levels.isEmpty) return const SizedBox.shrink();
    final level = levels.contains(_level) ? _level! : levels.last;
    final value = _num(
      effects
          .where((row) => _num(row['level']) == level)
          .firstOrNull?['effectValue'],
    );
    final figure = NumberFormat('#,##0.##', t.locale).format(value / 100);
    final description = t
        .text(item['description'])
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\{0(?::[^}]*)?\}'), figure)
        .trim();
    final aux = (widget.page?['aux'] as Map?) ?? const {};
    final upgrades = [
      for (final row in _rows((aux['associations'] as Map?)?['upgrades']))
        if (row['kind'] == 'level') row,
    ];
    final label = t.label('required', 'Required');
    return DetailSection(
      icon: Symbols.bolt_rounded,
      title: t.label('effectsByLevel', 'Effects by level'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownMenu<int>(
            expandedInsets: EdgeInsets.zero,
            label: Text(t.label('level', 'Level')),
            initialSelection: level,
            onSelected: (value) => setState(() => _level = value ?? level),
            dropdownMenuEntries: [
              for (final value in levels)
                DropdownMenuEntry(
                  value: value,
                  label: 'Lv.${value - 1} → Lv.$value',
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(description, style: theme.textTheme.bodyLarge),
          ),
          if (upgrades.isNotEmpty)
            DetailFold(
              title: label,
              child: UpgradeCost(
                label: label,
                to: level,
                initial: 0,
                framed: false,
                steps: [
                  for (final row in upgrades)
                    CostStep(
                      _num(row['from']).toInt(),
                      _num(row['to']).toInt(),
                      [
                        for (final cost in _rows(row['costs']))
                          if (cost['reference'] case final Map reference)
                            CostItem(
                              '${reference['resource']}:${reference['id']}',
                              t.text(reference['name']).isEmpty
                                  ? label
                                  : t.text(reference['name']),
                              _num(cost['count']).toInt(),
                              image: switch (reference['image']) {
                                final String path =>
                                  state.api.asset(path).toString(),
                                _ => null,
                              },
                              onTap: () => openLink(
                                context,
                                _href(
                                  state,
                                  reference['resource'],
                                  reference['id'],
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
    );
  }
}

/// A sticker's unlock conditions and the card its artwork comes from
/// (`renderExtendedDetail` for stickers).
class StickerExtras extends StatelessWidget {
  const StickerExtras({super.key, required this.page});
  final Map? page;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final associations =
        ((page?['aux'] as Map?)?['associations'] as Map?) ?? const {};
    final unlocks = _rows(associations['unlocks']);
    final card = associations['artworkCard'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (unlocks.isNotEmpty)
          DetailSection(
            icon: Symbols.info_rounded,
            title: t.label('unlockConditions', 'Unlock conditions'),
            child: Column(
              children: [
                for (final unlock in unlocks)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Symbols.lock_open_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    title: Text(t.text((unlock['character'] as Map?)?['name'])),
                    subtitle: Text(
                      '${unlock['kind'] == 'friendshipRank' ? t.label('friendship', 'Friendship') : t.label('characterRank', 'Character rank')} ${unlock['rank'] ?? ''}',
                    ),
                    onTap: switch ((unlock['character'] as Map?)?['id']) {
                      final Object id => () => openLink(
                        context,
                        _href(state, 'characters', id),
                      ),
                      _ => null,
                    },
                  ),
              ],
            ),
          ),
        if (card is Map && card['id'] != null)
          DetailSection(
            icon: Symbols.person_rounded,
            title: t.label('artworkCard', 'Artwork card'),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: SizedBox(
                width: 180,
                child: Tile(
                  title: t.text(card['name']),
                  subtitle: null,
                  images: [
                    if (card['image'] case final String image)
                      state.api.asset(image).toString(),
                  ],
                  aspectRatio: 3 / 4,
                  onTap: () => openLink(
                    context,
                    _href(state, 'member-cards', card['id']),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

const _sourceLabels = {
  'missions': 'navigation.missions',
  'events': 'navigation.events',
  'login-campaigns': 'navigation.loginCampaigns',
  'passes': 'navigation.systemNavPasses',
  'shop': 'navigation.shop',
  'exchange': 'navigation.exchange',
  'circle': 'navigation.circle',
  'songs': 'navigation.songs',
  'cards': 'navigation.memberCards',
  'support-cards': 'navigation.supportCards',
  'band-items': 'navigation.bandItems',
};
const _purposeLabels = {
  'training': 'catalog.cards.fields.training',
  'awakening': 'catalog.cards.fields.rankUp',
  'live': 'catalog.cards.fields.liveSkill',
  'gekisou': 'catalog.cards.fields.gekisouSkill',
  'level': 'navigation.bandItems',
  'exchange': 'navigation.exchange',
};
const _ruleLabels = {
  'MasterLiveFreeReward': 'catalog.items.ruleSolo',
  'MasterBattleLiveReward': 'catalog.items.ruleMulti',
  'MasterGekisouLiveRankReward': 'catalog.items.ruleGekisou',
  'MasterLiveStamp': 'catalog.items.ruleStamp',
  'MasterInvitationReward': 'catalog.items.ruleInvite',
};
const _sourceIcons = {
  'missions': Symbols.fact_check_rounded,
  'events': Symbols.event_rounded,
  'login-campaigns': Symbols.event_available_rounded,
  'passes': Symbols.workspace_premium_rounded,
  'shop': Symbols.storefront_rounded,
  'exchange': Symbols.swap_horiz_rounded,
  'circle': Symbols.groups_rounded,
  'songs': Symbols.music_note_rounded,
};
const _scoreRanks = ['', 'E', 'D', 'C', 'B', 'A', 'S', 'SS'];
const _difficulties = ['EASY', 'NORMAL', 'HARD', 'EXPERT'];

/// An item's place in the economy (`renderItemRelations`): where it comes
/// from, grouped by kind of source, and what consumes it. Upgrade costs are
/// tables shared by many cards; each distinct table is shown once, followed
/// by the cards that use it.
class ItemRelations extends StatelessWidget {
  const ItemRelations({super.key, required this.data});
  final Map data;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    String number(num value) =>
        NumberFormat.decimalPattern(t.locale).format(value);
    String sourceLabel(String resource) =>
        t(_sourceLabels[resource] ?? resource, resource);
    String quantity(Object? count) => count is num
        ? '×${number(count)}'
        : t('common.states.unavailable', 'Unavailable');
    String instant(Object? value) {
      return gameDateTime(t.locale, RelativeTime.timestamp(value));
    }

    /// The conditions that distinguish one occurrence, as phrases.
    List<String> conditions(Map row, [Map? only]) {
      final value = only ?? (row['conditions'] as Map?) ?? const {};
      String item(String key, String fallback, Object? a, [Object? b]) => t(
        'catalog.items.$key',
        fallback,
        {'0': '$a', if (b != null) '1': '$b'},
      );
      final points = value['points'] ?? value['point'];
      final end = instant(value['endAt']);
      final start = instant(value['startAt']);
      return [
        if (end.isNotEmpty)
          start.isNotEmpty
              ? '$start – $end'
              : '${t('catalog.systems.common.ends', 'Ends')} $end',
        if (value['day'] != null) item('day', 'Day {0}', value['day']),
        if (value['level'] != null) item('level', 'Level {0}', value['level']),
        if (value['rank'] != null && value['minRank'] == null)
          item('level', 'Level {0}', value['rank']),
        if (value['minRank'] != null || value['maxRank'] != null)
          item(
            'rankRange',
            'Rank {0}–{1}',
            value['minRank'] ?? value['rank'] ?? '',
            value['maxRank'] ?? value['minRank'] ?? '',
          ),
        if (points != null)
          t('catalog.systems.common.points', '{points} points', {
            'points': number(_num(points)),
          }),
        if (value['premium'] == true) t('catalog.items.premium', 'Premium'),
        if (value['difficulty'] case final Object difficulty)
          difficulty is num
              ? _difficulties.elementAtOrNull(difficulty.toInt()) ??
                    '$difficulty'
              : '$difficulty'.toUpperCase(),
        if (value['scoreRank'] != null)
          item(
            'scoreRank',
            'Score rank {0}',
            _scoreRanks.elementAtOrNull(_num(value['scoreRank']).toInt()) ??
                value['scoreRank'],
          ),
        if (value['probabilityBp'] != null)
          item(
            'chance',
            'Chance {0}%',
            NumberFormat(
              '#,##0.##',
              t.locale,
            ).format(_num(value['probabilityBp']) / 100),
          ),
        if (value['comboRateType'] != null)
          'Combo ${const [25, 50, 75, 100].elementAtOrNull(_num(value['comboRateType']).toInt()) ?? value['comboRateType']}%',
        if (value['currency'] != null && value['cost'] != null)
          '${t.text(value['currency'])} ×${number(_num(value['cost']))}',
        if (t.text(value['reward']).isNotEmpty) t.text(value['reward']),
        if (value['limit'] case final num limit when limit > 0)
          item('limit', 'Limit {0}', number(limit)),
      ];
    }

    String entityTitle(Map entry) {
      final entity = (entry['entity'] as Map?) ?? const {};
      final name = t.text(entity['name']);
      return name.isEmpty
          ? '${sourceLabel('${entity['resource']}')} ${entity['id']}'
          : name;
    }

    VoidCallback? open(Map entry) {
      final entity = (entry['entity'] as Map?) ?? const {};
      return entity['id'] == null
          ? null
          : () => openLink(
              context,
              _href(state, entity['resource'], entity['id']),
            );
    }

    Widget strong(String value) => Text(
      value,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    TextStyle? copy = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    /// One source: a reward row, or one row per alternative.
    Widget sourceRow(Map entry) {
      final entity = (entry['entity'] as Map?) ?? const {};
      final occurrences = _rows(entry['occurrences']);
      final single = occurrences.length == 1 ? occurrences.first : null;
      final supporting = single == null ? '' : conditions(single).join(' / ');
      final image = entity['image'];
      return InkWell(
        onTap: open(entry),
        borderRadius: BorderRadius.circular(Corner.medium),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 36,
                child: image is String && image.isNotEmpty
                    ? AppImage(candidates: [state.api.asset(image).toString()])
                    : Icon(
                        _sourceIcons[entity['resource']] ??
                            Symbols.redeem_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(entityTitle(entry), style: theme.textTheme.titleSmall),
                    if (supporting.isNotEmpty) Text(supporting, style: copy),
                    if (single == null)
                      for (final row in occurrences)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  conditions(row).isEmpty
                                      ? '—'
                                      : conditions(row).join(' / '),
                                  style: copy,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                quantity(row['count']),
                                style: theme.textTheme.titleSmall,
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
              if (single != null) ...[
                const SizedBox(width: 12),
                strong(quantity(single['count'])),
              ],
            ],
          ),
        ),
      );
    }

    /// Upgrade costs: each distinct step table once, then its users.
    Widget costTables(List<Map> entries) {
      final tables = <String, (List<Map>, List<Map>)>{};
      for (final entry in entries) {
        final steps = _rows(entry['occurrences'])
          ..sort(
            (a, b) =>
                _num((a['conditions'] as Map?)?['to'])
                    .compareTo(_num((b['conditions'] as Map?)?['to'])),
          );
        final key = jsonEncode([
          for (final step in steps)
            [
              step['count'],
              (step['conditions'] as Map?)?['from'],
              (step['conditions'] as Map?)?['to'],
            ],
        ]);
        (tables[key] ??= (steps, <Map>[])).$2.add(entry);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (steps, users) in tables.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      for (final step in steps)
                        Text.rich(
                          TextSpan(
                            text:
                                '${(step['conditions'] as Map?)?['from']} → ${(step['conditions'] as Map?)?['to']}  ',
                            style: copy,
                            children: [
                              TextSpan(
                                text: quantity(step['count']),
                                style: theme.textTheme.titleSmall,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  if (steps.length > 1 &&
                      steps.every((step) => step['count'] is num))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text.rich(
                        TextSpan(
                          text: '${t('common.fields.total', 'Total')}  ',
                          style: copy,
                          children: [
                            TextSpan(
                              text:
                                  '×${number(steps.fold<num>(0, (sum, step) => sum + (step['count'] as num)))}',
                              style: theme.textTheme.titleSmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in users)
                        ActionChip(
                          avatar: switch ((entry['entity'] as Map?)?['image']) {
                            final String image when image.isNotEmpty =>
                              ClipOval(
                                child: AppImage(
                                  candidates: [
                                    state.api.asset(image).toString(),
                                  ],
                                  fit: BoxFit.cover,
                                ),
                              ),
                            _ => null,
                          },
                          label: Text(entityTitle(entry)),
                          onPressed: open(entry) ?? () {},
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      );
    }

    List<MapEntry<String, List<Map>>> grouped(
      List<Map> rows,
      String Function(Map) key,
      List<String> order,
    ) {
      final groups = <String, List<Map>>{};
      for (final row in rows) {
        (groups[key(row)] ??= []).add(row);
      }
      int rank(String value) =>
          order.contains(value) ? order.indexOf(value) : order.length;
      return groups.entries.toList()
        ..sort((a, b) => rank(a.key).compareTo(rank(b.key)));
    }

    final acquisitions = _rows(data['acquisitions']);
    final uses = _rows(data['uses']);
    final rules = _rows(data['rules']);
    final acquisitionGroups = grouped(
      acquisitions,
      (entry) => '${(entry['entity'] as Map?)?['resource']}',
      _sourceLabels.keys.toList(),
    );
    final useGroups = grouped(
      uses,
      (entry) => '${entry['purpose']}',
      _purposeLabels.keys.toList(),
    );
    // Short pages open every group; long ones keep the outline readable.
    final openAll =
        acquisitionGroups.length + useGroups.length + rules.length <= 3;
    final unavailable = [
      for (final source in _rows(data['coverage']))
        if (source['available'] != true) sourceLabel('${source['resource']}'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (acquisitions.isNotEmpty || rules.isNotEmpty)
          DetailSection(
            icon: Symbols.redeem_rounded,
            title: t('catalog.items.acquisition', 'Acquisition'),
            count: acquisitions.length,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, MapEntry(:key, :value))
                    in acquisitionGroups.indexed)
                  DetailFold(
                    title: sourceLabel(key),
                    meta: number(value.length),
                    open: openAll || index == 0 || value.length <= 5,
                    child: Column(children: value.map(sourceRow).toList()),
                  ),
                for (final rule in rules)
                  DetailFold(
                    title: t(
                      _ruleLabels[rule['source']] ?? '${rule['source']}',
                      '${rule['source']}',
                    ),
                    meta: number(_rows(rule['occurrences']).length),
                    open: openAll,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          t(
                            'catalog.items.baseRewardsHint',
                            'Base quantities; performance multipliers and game bonuses determine the final reward.',
                          ),
                          style: copy,
                        ),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            dataRowMinHeight: 40,
                            dataRowMaxHeight: 40,
                            headingRowHeight: 40,
                            columns: [
                              DataColumn(
                                label: Text(
                                  t(
                                    'catalog.items.conditionRewardGroup',
                                    'Reward group',
                                  ),
                                ),
                              ),
                              DataColumn(
                                label: Text(
                                  t('catalog.fields.conditions', 'Conditions'),
                                ),
                              ),
                              DataColumn(
                                numeric: true,
                                label: Text(t('common.fields.value', 'Value')),
                              ),
                            ],
                            rows: [
                              for (final row in _rows(rule['occurrences']))
                                DataRow(
                                  cells: [
                                    DataCell(
                                      Text(
                                        '${(row['conditions'] as Map?)?['group'] ?? '—'}',
                                      ),
                                    ),
                                    DataCell(
                                      Text(switch (conditions(
                                        row,
                                        {...?(row['conditions'] as Map?)}
                                          ..remove('group'),
                                      )) {
                                        final List<String> phrases
                                            when phrases.isNotEmpty =>
                                          phrases.join(' / '),
                                        _ => '—',
                                      }),
                                    ),
                                    DataCell(Text(quantity(row['count']))),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (uses.isNotEmpty)
          DetailSection(
            icon: Symbols.bolt_rounded,
            title: t('catalog.items.usage', 'Uses'),
            count: uses.length,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, MapEntry(:key, :value)) in useGroups.indexed)
                  DetailFold(
                    title: t(_purposeLabels[key] ?? key, key),
                    meta: number(value.length),
                    open: openAll || index == 0 || value.length <= 5,
                    child: key == 'exchange'
                        ? Column(children: value.map(sourceRow).toList())
                        : costTables(value),
                  ),
              ],
            ),
          ),
        if (unavailable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Text(
              '${t('common.states.unavailable', 'Unavailable')}: ${unavailable.join(', ')}',
              style: copy,
            ),
          ),
      ],
    );
  }
}
