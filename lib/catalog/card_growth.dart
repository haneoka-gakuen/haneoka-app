import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../core/i18n.dart';
import '../shell/links.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/upgrade.dart';
import 'skill_text.dart';
import 'visuals.dart';

/// The progression tables a card page reads (`detailAux` for cards).
class CardGrowthData {
  CardGrowthData._(
    this.progression,
    this.levels,
    this.awakeResources,
    this.skillResources,
    this.items, [
    this.associations = const {},
  ]);
  final Map progression;
  final List<Map> levels;
  final List<Map> awakeResources;
  final List<Map> skillResources;
  final Map items;

  /// The page's resolved upgrades and skill texts (`entity-associations`).
  final Map associations;

  /// The tables the website built into the entity page.
  static CardGrowthData? fromPage(Map? page, {required bool support}) {
    final aux = page?['aux'];
    if (aux is! Map) return null;
    List<Map> rows(Object? value) =>
        (value as List? ?? const []).whereType<Map>().toList();
    return CardGrowthData._(
      (aux['progression'] as Map?) ?? const {},
      rows(aux[support ? 'support-card-levels' : 'member-card-levels']),
      rows(aux['member-card-awake-resources']),
      rows(aux['skill-level-resources']),
      {for (final item in rows(page?['gameItems'])) '${item['itemId']}': item},
      (aux['associations'] as Map?) ?? const {},
    );
  }

  List<Map> upgrades(String kind) => [
    for (final row
        in (associations['upgrades'] as List? ?? const []).whereType<Map>())
      if (row['kind'] == kind) row,
  ];

  /// The page's text for one skill at [level], already resolved.
  Object? skillText(String group, int slot, int level) {
    for (final display
        in (associations['skills'] as List? ?? const []).whereType<Map>()) {
      if (display['group'] != group || _int(display['slot']) != slot) continue;
      for (final row
          in (display['levels'] as List? ?? const []).whereType<Map>()) {
        if (_int(row['level']) == level) return row['description'];
      }
    }
    return null;
  }

  static final _loaded = <(HaneokaApi, bool), Future<CardGrowthData>>{};
  static Future<CardGrowthData> of(HaneokaApi api, {required bool support}) =>
      cachedResource(_loaded, (api, support), () => _load(api, support));

  static Future<CardGrowthData> _load(HaneokaApi api, bool support) async {
    final base = '/api/v1/servers/${api.server}/progression';
    List<Map> rows(Object? value) =>
        (value as List? ?? const []).whereType<Map>().toList();
    final (progression, levels, awake, skill, items) = await (
      api.json(base),
      api.json(
        '$base/views/${support ? 'support-card-levels' : 'member-card-levels'}',
      ),
      support
          ? Future<Object?>.value(const [])
          : api.json('$base/views/member-card-awake-resources'),
      api.json('$base/views/skill-level-resources'),
      api.catalog('items'),
    ).wait;
    return CardGrowthData._(
      (progression as Map?) ?? const {},
      rows(levels),
      rows(awake),
      rows(skill),
      ((items as Map?)?['items'] as Map?) ?? const {},
    );
  }

  /// A progression table's game rows (`progressionRows`).
  List<Map> table(String key) => [
    for (final row in (progression[key] as List? ?? const []).whereType<Map>())
      (row['raw'] as Map?) ?? row,
  ];
}

const _skillOrder = ['leader', 'live', 'gekisou', 'support', 'gekisouSupport'];

int _int(Object? value) => (value as num?)?.toInt() ?? 0;

List<int> _unique(Iterable<Object?> values) => {
  for (final v in values)
    if (v is num && v > 0) v.toInt(),
}.toList()..sort();

/// The value a slider shows: the stored one when allowed, else the nearest.
int _select(List<int> values, int? current) {
  if (values.isEmpty) return current != null && current > 0 ? current : 1;
  if (current == null) return values.last;
  if (current <= values.first) return values.first;
  if (current >= values.last) return values.last;
  return values.contains(current)
      ? current
      : values.reduce(
          (a, b) => (b - current).abs() < (a - current).abs() ? b : a,
        );
}

/// A member card's or snapshot's characters, stats and skills
/// (`renderCardRelations`, `renderCardStats`, the skill rows): every
/// progression step on a slider, stats and skill effects at the chosen step,
/// and the materials to reach it.
class CardGrowthView extends StatefulWidget {
  const CardGrowthView({
    super.key,
    required this.record,
    required this.visuals,
    required this.characterIds,
    required this.characterName,
    required this.support,
    this.page,
    this.ready = true,
  });
  final Map<String, Object?> record;

  /// The website's payload for the page; its tables replace the API's.
  final Map? page;

  /// False while the page is still loading, so the API is not asked too.
  final bool ready;
  final CatalogVisuals? visuals;
  final List<int> characterIds;
  final String Function(int id) characterName;
  final bool support;

  @override
  State<CardGrowthView> createState() => _CardGrowthViewState();
}

class _CardGrowthViewState extends State<CardGrowthView> {
  Future<CardGrowthData>? _data;
  Map? _page;
  CardGrowthData? _fromPage;
  int? _level, _training, _awakening, _rank, _live, _gekisou;

  @override
  Widget build(BuildContext context) {
    if (!identical(_page, widget.page)) {
      _page = widget.page;
      _fromPage = CardGrowthData.fromPage(_page, support: widget.support);
    }
    if (_fromPage case final data?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [?_relations(context), ..._growth(context, data)],
      );
    }
    if (widget.ready) {
      _data ??= CardGrowthData.of(
        AppScope.of(context).api,
        support: widget.support,
      );
    }
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final data = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?_relations(context),
            if (data != null) ..._growth(context, data),
          ],
        );
      },
    );
  }

  Widget? _relations(BuildContext context) {
    final state = AppScope.of(context);
    final ids = widget.characterIds;
    if (ids.isEmpty) return null;
    final scheme = Theme.of(context).colorScheme;
    return DetailSection(
      icon: Symbols.group_rounded,
      title: state.text.label('characters', 'Characters'),
      count: ids.length,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final id in ids)
            Material(
              color: scheme.surfaceContainer,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => openLink(
                  context,
                  '/${state.server}/${state.text.locale}/characters/$id/',
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipOval(
                        child: SizedBox.square(
                          dimension: 32,
                          child: switch (widget
                              .visuals
                              ?.characters[id]?['faceImage']) {
                            final String face => AppImage(
                              candidates: [state.api.asset(face).toString()],
                            ),
                            _ => null,
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.characterName(id),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Symbols.north_east_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _growth(BuildContext context, CardGrowthData data) {
    final state = AppScope.of(context);
    final t = state.text;
    final item = widget.record;
    final support = widget.support;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final levelGroup = _int(
      support ? item['supportCardLevelGroup'] : item['memberCardLevelGroup'],
    );
    final levelRows =
        data.levels.where((r) => _int(r['group']) == levelGroup).toList()
          ..sort((a, b) => _int(a['level']).compareTo(_int(b['level'])));
    int group(String key, [String? fallback]) {
      final value = _int(item[key]);
      if (value > 0) return value;
      return fallback == null ? 1 : _int(item[fallback]);
    }

    List<Map> sorted(String table, int group, String by) =>
        data.table(table).where((r) => _int(r['_group']) == group).toList()
          ..sort((a, b) => _int(a[by]).compareTo(_int(b[by])));
    final awakeRows = sorted(
      'memberCardAwake',
      group('memberCardAwakeGroup'),
      '_awakeCount',
    );
    final rankRows = sorted(
      'memberCardRanks',
      group('memberCardRankGroup'),
      '_rank',
    );
    final supportRankRows = sorted(
      'supportCardRanks',
      group('supportCardRankGroup', 'supportCardLevelGroup'),
      '_rank',
    );
    final skills = (item['resolvedSkills'] as Map?) ?? const {};
    List<int> skillLevels(String name) => _unique([
      for (final e
          in ((skills[name] as Map?)?['effects'] as List? ?? const [])
              .whereType<Map>())
        e['level'] ?? (e['raw'] as Map?)?['_level'],
    ]);
    final trainings = _unique(awakeRows.map((r) => r['_awakeCount']));
    final awakenings = _unique(rankRows.map((r) => r['_rank']));
    final ranks = _unique(supportRankRows.map((r) => r['_rank']));
    final lives = skillLevels('live');
    final gekisous = skillLevels('gekisou');
    final training = _select(trainings, _training);
    final awakening = _select(awakenings, _awakening);
    final rank = _select(ranks, _rank);
    final live = _select(lives, _live);
    final gekisou = _select(gekisous, _gekisou);
    final cap = support
        ? _int(
            supportRankRows
                .where((r) => _int(r['_rank']) == rank)
                .firstOrNull?['_limitLevel'],
          )
        : _int(
            data
                .table('memberCardLevelLimits')
                .where(
                  (r) =>
                      _int(r['_rarity']) == _int(item['rarity']) &&
                      _int(r['_awakeCount']) == training,
                )
                .firstOrNull?['_limitLevel'],
          );
    final levels = _unique(levelRows.map((r) => r['level']))
        .where((l) => cap == 0 || l <= cap)
        .toList();
    final level = _select(levels, _level);

    final selected =
        levelRows.where((r) => _int(r['level']) == level).firstOrNull ??
        levelRows.lastOrNull ??
        const {};
    final trainingRow = support
        ? const {}
        : awakeRows
                  .where((r) => _int(r['_awakeCount']) == training)
                  .firstOrNull ??
              const {};
    final awakeningRow = support
        ? const {}
        : rankRows.where((r) => _int(r['_rank']) == awakening).firstOrNull ??
              const {};
    int value(String key) {
      final name = key == 'technique' ? 'technic' : key;
      final rate =
          ((selected['${name}Rate'] as num?) ?? 10000) +
          ((trainingRow['_${name}Rate'] as num?) ?? 0) +
          ((awakeningRow['_${name}Rate'] as num?) ?? 0);
      final base = ((item['stat'] as Map?)?[key] as num?) ?? 0;
      return (base * rate / 10000).floor();
    }

    final stats = [value('performance'), value('technique'), value('visual')];
    final number = NumberFormat.decimalPattern(t.locale);
    final figures = [
      ('performance', stats[0]),
      ('technique', stats[1]),
      ('visual', stats[2]),
      if (!support) ('total', stats.reduce((a, b) => a + b)),
      ('exp', _int(selected['exp'])),
    ];

    Widget pair(List<Widget> children) => LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 528) {
          return Column(children: children);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, child) in children.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: child),
            ],
          ],
        );
      },
    );

    final controls = [
      LevelSwitch(
        label: t.label('level', 'Level'),
        levels: levels,
        value: level,
        onChanged: (v) => setState(() => _level = v),
      ),
      if (support)
        LevelSwitch(
          label: t.label('rank', 'Rank'),
          levels: ranks,
          value: rank,
          onChanged: (v) => setState(() => _rank = v),
        )
      else ...[
        pair([
          LevelSwitch(
            label: t.label('training', 'Training'),
            levels: trainings,
            value: training,
            onChanged: (v) => setState(() => _training = v),
          ),
          LevelSwitch(
            label: t.label('awakening', 'Awakening'),
            levels: awakenings,
            value: awakening,
            onChanged: (v) => setState(() => _awakening = v),
          ),
        ]),
        pair([
          LevelSwitch(
            label: t.label('liveSkill', 'LIVE Skill'),
            levels: lives,
            value: live,
            onChanged: (v) => setState(() => _live = v),
          ),
          LevelSwitch(
            label: t.label('gekisouSkill', 'GEKISO Skill'),
            levels: gekisous,
            value: gekisou,
            onChanged: (v) => setState(() => _gekisou = v),
          ),
        ]),
      ],
    ];

    String href(String resource, Object? id) =>
        '/${state.server}/${t.locale}/$resource/$id/';
    Map? gameItem(Object? id) => data.items['$id'] as Map?;
    CostItem cost(Map? source, Object? resourceId, int count, String resource) {
      return CostItem(
        '$resource:$resourceId',
        t.text(source?['name']).isEmpty
            ? t.label('required', 'Required')
            : t.text(source?['name']),
        count,
        image: switch (source?['image']) {
          final String path => state.api.asset(path).toString(),
          _ => null,
        },
        onTap: resourceId == null
            ? null
            : () => openLink(context, href(resource, resourceId)),
      );
    }

    /// `renderCostList` with growth: one step per level above [initial].
    Widget? costFold(
      String label,
      List<(int level, int count, Map? item, Object? id, String resource)> rows,
      int to, {
      int initial = 1,
    }) {
      final steps = <int, List<CostItem>>{};
      for (final (level, count, source, id, resource) in rows) {
        if (level <= initial) continue;
        final list = steps.putIfAbsent(level, () => []);
        if (count != 0) list.add(cost(source, id, count, resource));
      }
      if (steps.isEmpty) return null;
      return DetailFold(
        title: label,
        child: UpgradeCost(
          key: ValueKey(label),
          label: label,
          to: to,
          initial: initial,
          framed: false,
          steps: [
            for (final MapEntry(:key, :value) in steps.entries)
              CostStep(key - 1, key, value),
          ],
        ),
      );
    }

    /// `renderAssociatedCost`: the page's own steps for [kind].
    (bool, Widget?) associated(String kind, String label, int to) {
      final rows = data.upgrades(kind);
      if (rows.isEmpty) return (false, null);
      final initial = kind == 'level' ? 0 : 1;
      return (
        true,
        DetailFold(
          title: label,
          child: UpgradeCost(
            key: ValueKey('$kind$label'),
            label: label,
            to: to,
            initial: initial,
            framed: false,
            steps: [
              for (final row in rows)
                CostStep(_int(row['from']), _int(row['to']), [
                  for (final c
                      in (row['costs'] as List? ?? const []).whereType<Map>())
                    if (c['reference'] case final Map r)
                      cost(r, r['id'], _int(c['count']), '${r['resource']}')
                    else
                      cost(
                        gameItem(c['itemId']),
                        c['itemId'],
                        _int(c['count']),
                        'items',
                      ),
                ]),
            ],
          ),
        ),
      );
    }

    Widget? either(String kind, String label, int to, Widget? Function() own) {
      final (found, widget) = associated(kind, label, to);
      return found ? widget : own();
    }

    final costs = support
        ? [
            either(
              'rank',
              t.label('rank', 'Rank'),
              rank,
              () => costFold(t.label('rank', 'Rank'), [
                for (final r in supportRankRows)
                  (
                    _int(r['_rank']),
                    _int(r['_requiredRankUpItemCount']),
                    {
                      'name': item['prefix'] ?? item['cardName'],
                      'image': (item['images'] as Map?)?['thumbnail'],
                    },
                    item['supportCardId'],
                    'support-cards',
                  ),
              ], rank),
            ),
          ]
        : [
            either(
              'training',
              t.label('training', 'Training'),
              training,
              () => costFold(t.label('training', 'Training'), [
                for (final r in data.awakeResources)
                  if (_int(r['group']) ==
                      _int(item['memberCardAwakeResourceGroup']))
                    (
                      _int(r['awakeCount']),
                      _int(r['count']),
                      r['item'] as Map?,
                      r['itemId'],
                      'items',
                    ),
              ], training),
            ),
            either(
              'awakening',
              t.label('awakening', 'Awakening'),
              awakening,
              () => costFold(t.label('awakening', 'Awakening'), [
                for (final r in rankRows)
                  (
                    _int(r['_rank']),
                    _int(r['_requiredRankUpItemCount']),
                    gameItem(item['rankUpItemId']),
                    item['rankUpItemId'],
                    'items',
                  ),
              ], awakening),
            ),
          ];

    int skillLevel(String group, int slot) {
      if (group == 'live') return live;
      if (group == 'gekisou') return gekisou;
      if (group == 'leader') {
        final row = rankRows
            .where((r) => _int(r['_rank']) == awakening)
            .firstOrNull;
        final value = _int(row?['_leaderSkillLevel']);
        return value > 0 ? value : 1;
      }
      final row =
          supportRankRows.where((r) => _int(r['_rank']) == rank).firstOrNull ??
          const {};
      final slotKey = (slot + 1).toString().padLeft(2, '0');
      final prefix = group == 'gekisouSupport'
          ? '_gekisouSupportSkill'
          : '_supportSkill';
      final value = _int(row['$prefix${slotKey}Level']);
      if (value > 0) return value;
      final shared = _int(row['${prefix}Level']);
      return shared > 0 ? shared : rank;
    }

    Widget? ownSkillCost(String group, int to) {
      final resourceGroup = _int(
        group == 'live'
            ? item['liveSkillLevelResourceGroup']
            : group == 'gekisou'
            ? item['gekisouSkillLevelResourceGroup']
            : 0,
      );
      if (resourceGroup == 0) return null;
      return costFold(t.label('required', 'Required'), [
        for (final r in data.skillResources)
          if (_int(r['group']) == resourceGroup)
            (
              _int(r['level']),
              _int(r['count']),
              r['item'] as Map?,
              r['itemId'],
              'items',
            ),
      ], to);
    }

    Widget? skillCost(String group, int to) => either(
      group,
      t.label('required', 'Required'),
      to,
      () => ownSkillCost(group, to),
    );

    final skillRows = <Widget>[
      for (final MapEntry(:key, :value)
          in skills.entries.toList()..sort(
            (a, b) => _skillOrder
                .indexOf('${a.key}')
                .compareTo(_skillOrder.indexOf('${b.key}')),
          ))
        for (final (slot, skill)
            in (value is List ? value : [value]).whereType<Map>().indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SkillRow(
              group: t.label('${key}Skill', '$key'),
              skill: skill,
              level: skillLevel('$key', slot),
              text: data.skillText('$key', slot, skillLevel('$key', slot)),
              cost: skillCost('$key', skillLevel('$key', slot)),
              t: t,
              api: state.api,
            ),
          ),
    ];

    return [
      DetailSection(
        icon: Symbols.monitoring_rounded,
        title: t.label('stats', 'Stats'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...controls,
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = ((constraints.maxWidth + 16) / 96)
                    .floor()
                    .clamp(1, figures.length);
                final width =
                    (constraints.maxWidth - 16 * (columns - 1)) / columns;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      for (final (key, figure) in figures)
                        SizedBox(
                          width: width,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.label(key, key),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                support && key != 'exp'
                                    ? '${(figure / 100).toStringAsFixed(2)}%'
                                    : number.format(figure),
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            for (final fold in costs) ?fold,
          ],
        ),
      ),
      if (skillRows.isNotEmpty)
        DetailSection(
          icon: Symbols.bolt_rounded,
          title: t.label('skills', 'Skills'),
          child: Column(children: skillRows),
        ),
    ];
  }
}

/// A skill as the website's `.skill-row`: icon, group, name, the template
/// filled at the chosen level, and the materials to reach that level.
class _SkillRow extends StatelessWidget {
  const _SkillRow({
    required this.group,
    required this.skill,
    required this.level,
    required this.text,
    required this.cost,
    required this.t,
    required this.api,
  });
  final String group;
  final Map skill;
  final int level;

  /// The page's resolved text at [level], used before the template.
  final Object? text;
  final Widget? cost;
  final SiteText t;
  final HaneokaApi api;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = skill['icon'];
    final template = t.text(skill['description']);
    final effects = [
      for (final e in (skill['effects'] as List? ?? const []))
        if (e is Map) e.cast<String, Object?>(),
    ];
    final resolved = t.text(text).replaceAll('\r', '');
    final description = resolved.isNotEmpty
        ? resolved
        : template.isEmpty
        ? ''
        : skillDescription(
            template,
            skillLevelEffects(effects, level).effects,
            t.text,
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Corner.large),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon is String)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox.square(
                  dimension: 40,
                  child: AppImage(candidates: [api.asset(icon).toString()]),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    group,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    t.text(skill['skillName']),
                    style: theme.textTheme.titleSmall,
                  ),
                  if (description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        description,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ?cost,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
