import '../core/catalog_source.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/i18n.dart';
import '../core/page_data.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/tile.dart';
import '../ui/upgrade.dart';
import 'browse.dart';
import 'visuals.dart';

const _families = {
  'leader': 'catalog.cards.fields.leaderSkill',
  'live': 'catalog.cards.fields.liveSkill',
  'gekisou': 'catalog.cards.fields.gekisouSkill',
  'support': 'catalog.cards.fields.supportSkill',
  'gekisouSupport': 'catalog.cards.fields.gekisouSupportSkill',
};

String _skillPageId(Entry skill) => '${skill['family']}-${skill['id']}';

String _family(SiteText t, Object? family) =>
    t(_families['$family'] ?? '', '$family');

String _effects(SiteText t, Entry skill) => [
  for (final effect in (skill['effects'] as List? ?? const []).whereType<Map>())
    t.text(effect['name']).isEmpty ? '${effect['id']}' : t.text(effect['name']),
].join(' · ');

String _levels(Entry skill) {
  final levels = [
    for (final l in (skill['levels'] as List? ?? const []).whereType<Map>())
      (l['level'] as num).toInt(),
  ];
  if (levels.isEmpty) return '—';
  levels.sort();
  return levels.first == levels.last
      ? 'Lv.${levels.first}'
      : 'Lv.${levels.first}–${levels.last}';
}

/// The website's skill catalogue (`skills-workspace`): every skill a card
/// carries, by type and effect, each with its own page.
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key, this.id});
  final String? id;
  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  Future<Map<String, Object?>>? _data;
  bool _unlinked = false;
  Object? _entrySource, _dataKey;
  List<Entry>? _all;
  List<Entry>? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_dataKey != CatalogSourceScope.keyOf(context)) {
      _dataKey = CatalogSourceScope.keyOf(context);
      _data = pageData(
        '/${CatalogSourceScope.serverOf(context)}/${state.text.locale}/skills/',
        'skill-catalog-data',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final api = CatalogSourceScope.apiOf(context);
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final source = snapshot.data?['entries'];
        final entries = identical(source, _entrySource)
            ? _all
            : (source as List?)?.whereType<Entry>().toList();
        _entrySource = source;
        if (entries != null && !identical(entries, _all)) {
          _all = entries;
          _shown = null;
        }
        _shown ??= entries
            ?.where(
              (e) => _unlinked || (e['cards'] as List? ?? const []).isNotEmpty,
            )
            .toList();
        if (widget.id != null) {
          final skill = entries
              ?.where(
                (e) =>
                    _skillPageId(e) == widget.id || '${e['key']}' == widget.id,
              )
              .firstOrNull;
          if (skill != null) return SkillDetailScreen(skill: skill);
          return ShellPage(
            title: t('catalog.cards.fields.skills'),
            body: Center(
              child: snapshot.connectionState == ConnectionState.waiting
                  ? const CircularProgressIndicator()
                  : Text(t('common.states.unavailable')),
            ),
          );
        }
        final effects = <String, Object?>{
          for (final e in entries ?? const <Entry>[])
            for (final effect
                in (e['effects'] as List? ?? const []).whereType<Map>())
              '${effect['id']}': effect['name'],
        };
        void open(BuildContext context, Entry skill) {
          final api = CatalogSourceScope.apiOf(context);
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: RouteSettings(
                name: Uri(
                  path: '/catalog/skills/${_skillPageId(skill)}',
                  queryParameters: {'server': api.server},
                ).toString(),
              ),
              builder: (_) => CatalogSourceScope(
                api: api,
                child: SkillDetailScreen(skill: skill),
              ),
            ),
          );
        }

        return BrowseScreen(
          onOpen: open,
          title: t('catalog.cards.fields.skills', 'Skills'),
          items: _shown,
          error: snapshot.error,
          onRetry: () => setState(() {
            final state = AppScope.of(context);
            _data = pageData(
              '/${CatalogSourceScope.serverOf(context)}/${state.text.locale}/skills/',
              'skill-catalog-data',
            );
          }),
          searchText: (skill) => [
            skill['id'],
            t.text(skill['name']),
            _effects(t, skill),
            for (final l
                in (skill['levels'] as List? ?? const []).whereType<Map>())
              t.text(l['description']),
          ].join(' '),
          grid: const GridSpec(minWidth: 132, small: true),
          tile: (context, skill) => Tile(
            title: t.text(skill['name']).isEmpty
                ? '${skill['key']}'
                : t.text(skill['name']),
            subtitle: _family(t, skill['family']),
            images: [
              if (skill['image'] case final String path)
                api.asset(path).toString(),
            ],
            placeholder: Symbols.bolt_rounded,
            onTap: () => open(context, skill),
          ),
          listRow: (context, skill) => ListTile(
            onTap: () => open(context, skill),
            leading: SizedBox.square(
              dimension: 48,
              child: skill['image'] is String
                  ? AppImage(
                      candidates: [
                        api.asset(skill['image'] as String).toString(),
                      ],
                    )
                  : null,
            ),
            title: Text(
              t.text(skill['name']),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                _family(t, skill['family']),
                _effects(t, skill),
              ].where((s) => s.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: (skill['cards'] as List? ?? const []).isEmpty
                ? null
                : Text(
                    t('catalog.skills.cardCount', '{count}', {
                      'count': (skill['cards'] as List).length,
                    }),
                  ),
          ),
          columns: [
            TableColumn(
              t('common.fields.title', 'Title'),
              (s) => t.text(s['name']),
            ),
            TableColumn(
              t('catalog.fields.type', 'Type'),
              (s) => _family(t, s['family']),
            ),
            TableColumn(
              t('catalog.fields.effects', 'Effects'),
              (s) => _effects(t, s),
            ),
            TableColumn(t('common.fields.level', 'Level'), _levels),
            TableColumn(
              t('navigation.cards', 'Cards'),
              (s) => '${(s['cards'] as List? ?? const []).length}',
              numeric: true,
            ),
            TableColumn('ID', (s) => '${s['id']}', numeric: true),
          ],
          facets: [
            FacetSpec(
              key: 'family',
              label: t('catalog.fields.type', 'Type'),
              values: (s) => ['${s['family']}'],
              option: (value) => FacetOption(_family(t, value)),
            ),
            FacetSpec(
              key: 'effect',
              label: t('catalog.fields.effects', 'Effects'),
              values: (s) => [
                for (final effect
                    in (s['effects'] as List? ?? const []).whereType<Map>())
                  '${effect['id']}',
              ],
              option: (value) => FacetOption(
                t.text(effects[value]).isEmpty ? value : t.text(effects[value]),
              ),
            ),
          ],
          switches: [
            BrowseSwitch(
              t(
                'catalog.skills.includeUnlinked',
                'Include skills without cards',
              ),
              _unlinked,
              (value) => setState(() {
                _unlinked = value;
                _shown = null;
              }),
            ),
          ],
        );
      },
    );
  }
}

/// One skill (`renderDetail`): what it is, its effect at every level, the
/// materials to raise it, and the cards that carry it.
class SkillDetailScreen extends StatelessWidget {
  const SkillDetailScreen({super.key, required this.skill});
  final Entry skill;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final api = CatalogSourceScope.apiOf(context);
    final title = t.text(skill['name']).isEmpty
        ? '${skill['key']}'
        : t.text(skill['name']);
    final cards = (skill['cards'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final members = cards.where((c) => c['kind'] == 'member-cards').toList();
    final supports = cards.where((c) => c['kind'] == 'support-cards').toList();
    final costs = [
      for (final cost in (skill['costs'] as List? ?? const []).whereType<Map>())
        if ((cost['steps'] as List? ?? const []).isNotEmpty) cost,
    ];
    String href(Map card) =>
        '/${CatalogSourceScope.serverOf(context)}/${t.locale}/${card['kind']}/${card['id']}/';
    Widget grid(List<Map> list, double ratio) => LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 500 ? 2 : 4;
        final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final card in list)
              SizedBox(
                width: width,
                child: Tile(
                  title: t.text(card['name']),
                  subtitle: null,
                  aspectRatio: ratio,
                  images: [
                    if (card['image'] case final String path)
                      api.asset(path).toString(),
                  ],
                  onTap: () => openLink(context, href(card)),
                ),
              ),
          ],
        );
      },
    );
    return ShellPage(
      title: title,
      body: DetailLayout(
        media: skill['image'] is String
            ? ImageGallery(
                images: [api.asset(skill['image'] as String).toString()],
              )
            : null,
        sections: [
          DetailSection(
            icon: Symbols.info_rounded,
            title: t('common.actions.details', 'Details'),
            child: SpecList(
              facts: [
                Fact(
                  t('catalog.fields.type', 'Type'),
                  _family(t, skill['family']),
                ),
                Fact(
                  t('catalog.fields.effects', 'Effects'),
                  _effects(t, skill).isEmpty ? '—' : _effects(t, skill),
                ),
                Fact(t('common.fields.level', 'Level'), _levels(skill)),
                Fact('ID', '${skill['id']}'),
              ],
            ),
          ),
          if ((skill['levels'] as List? ?? const []).isNotEmpty)
            DetailSection(
              icon: Symbols.trending_up_rounded,
              title: t(
                'catalog.cards.fields.effectsByLevel',
                'Effects by level',
              ),
              count: (skill['levels'] as List).length,
              child: SpecList(
                facts: [
                  for (final level
                      in (skill['levels'] as List).whereType<Map>())
                    Fact(
                      'Lv.${level['level']}',
                      t.text(level['description']).replaceAll('\r', ''),
                      full: true,
                    ),
                ],
              ),
            ),
          if (costs.isNotEmpty)
            DetailSection(
              icon: Symbols.inventory_2_rounded,
              title: t('catalog.skills.upgradeCosts', 'Upgrade materials'),
              child: Column(
                children: [
                  for (final cost in costs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _Cost(cost: cost, skill: skill),
                    ),
                ],
              ),
            ),
          if (members.isNotEmpty)
            DetailSection(
              icon: Symbols.person_rounded,
              title: t('navigation.memberCards', 'Members'),
              count: members.length,
              child: grid(members, 3 / 4),
            ),
          if (supports.isNotEmpty)
            DetailSection(
              icon: Symbols.photo_library_rounded,
              title: t('navigation.supportCards', 'Snapshots'),
              count: supports.length,
              child: grid(supports, 16 / 9),
            ),
        ],
      ),
    );
  }
}

class _Cost extends StatefulWidget {
  const _Cost({required this.cost, required this.skill});
  final Map cost;
  final Entry skill;
  @override
  State<_Cost> createState() => _CostState();
}

class _CostState extends State<_Cost> {
  int? _to;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final cost = widget.cost;
    final kind = '${cost['kind']}';
    final label = t(
      kind == 'awakening'
          ? 'catalog.cards.fields.rankUp'
          : kind == 'rank'
          ? 'catalog.cards.fields.rank'
          : 'common.fields.level',
      kind,
    );
    final steps = [
      for (final step in (cost['steps'] as List).whereType<Map>())
        CostStep((step['from'] as num).toInt(), (step['to'] as num).toInt(), [
          for (final item
              in (step['costs'] as List? ?? const []).whereType<Map>())
            CostItem(
              switch (item['reference']) {
                final Map r => '${r['resource']}:${r['id']}',
                _ => 'items:${item['itemId']}',
              },
              t.text((item['reference'] as Map?)?['name']).isEmpty
                  ? t('common.fields.required', 'Required')
                  : t.text((item['reference'] as Map?)?['name']),
              (item['count'] as num).toInt(),
              image: switch ((item['reference'] as Map?)?['image']) {
                final String path => CatalogSourceScope.apiOf(
                  context,
                ).asset(path).toString(),
                _ => null,
              },
              onTap: switch (item['reference']) {
                final Map r
                    when r['resource'] == 'items' ||
                        r['resource'] == 'support-cards' =>
                  () => openLink(
                    context,
                    '/${CatalogSourceScope.serverOf(context)}/${t.locale}/${r['resource']}/${r['id']}/',
                  ),
                _ => null,
              },
            ),
        ]),
    ];
    final stages = {1, for (final s in steps) s.to}.toList()..sort();
    final to = _to ?? stages.last;
    final users = (widget.skill['cards'] as List? ?? const [])
        .whereType<Map>()
        .where((c) => c['costKey'] == cost['key'])
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (users.length < (widget.skill['cards'] as List).length)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final card in users)
                  ActionChip(
                    avatar: card['image'] is String
                        ? AppImage(
                            candidates: [
                              CatalogSourceScope.apiOf(context)
                                  .asset(card['image'] as String)
                                  .toString(),
                            ],
                          )
                        : null,
                    label: Text(t.text(card['name'])),
                    onPressed: () => openLink(
                      context,
                      '/${CatalogSourceScope.serverOf(context)}/${t.locale}/${card['kind']}/${card['id']}/',
                    ),
                  ),
              ],
            ),
          ),
        LevelSwitch(
          label: label,
          levels: stages,
          value: to,
          onChanged: (value) => setState(() => _to = value),
        ),
        UpgradeCost(label: label, steps: steps, to: to),
      ],
    );
  }
}
