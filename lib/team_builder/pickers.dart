/// Choosers on the shared selection pane: songs for a search and cards for
/// a formation slot (`song-picker.ts`, the Teams tab's slot picker), and the
/// card filters the box and the pickers share (`card-filters.ts`).
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/catalog_screen.dart' show cardRarityName;
import '../catalog/catalog_query.dart';
import '../ui/tile.dart';
import 'catalog.dart';
import 'engine/api.dart';
import 'engine/num.dart';
import 'widgets.dart';

/// Card filters: bands, characters, attributes, rarities, artwork presence
/// and a total-stat range (`card-filters.ts`).
class CardFilters {
  const CardFilters({
    this.query = '',
    this.bands = const {},
    this.characters = const {},
    this.attributes = const {},
    this.rarities = const {},
    this.totalMin,
    this.totalMax,
    this.artOnly = false,
    this.noArt = false,
    this.releaseFrom,
    this.releaseTo,
    this.skill = '',
    this.skills = const {},
  });
  final String query;
  final Set<int> bands;
  final Set<int> characters;
  final Set<int> attributes;
  final Set<int> rarities;

  /// Bounds on performance + technique + visual at maximum growth.
  final int? totalMin;
  final int? totalMax;

  /// Only cards that actually ship a card image.
  final bool artOnly;
  final bool noArt;

  /// Release window, in epoch milliseconds (`catalogMetadata.releasedAt`).
  final int? releaseFrom;
  final int? releaseTo;

  /// Substring matched against the resolved live / gekiso / leader skill names.
  final String skill;

  /// Skill type names selected per role (`leader`, `live`, `gekiso`,
  /// `support`, `gekisouSupport`), the website's `CARD_SKILL_FACETS`.
  final Map<String, Set<String>> skills;

  int get active =>
      bands.length +
      characters.length +
      attributes.length +
      rarities.length +
      (totalMin != null || totalMax != null ? 1 : 0) +
      (artOnly || noArt ? 1 : 0) +
      (releaseFrom != null || releaseTo != null ? 1 : 0) +
      (skill.trim().isEmpty ? 0 : 1) +
      skills.values.fold<int>(0, (sum, set) => sum + set.length);

  CardFilters copyWith({
    String? query,
    Set<int>? bands,
    Set<int>? characters,
    Set<int>? attributes,
    Set<int>? rarities,
    int? totalMin,
    int? totalMax,
    bool resetTotal = false,
    bool clearTotalMin = false,
    bool clearTotalMax = false,
    bool? artOnly,
    bool? noArt,
    int? releaseFrom,
    int? releaseTo,
    bool resetRelease = false,
    bool clearReleaseFrom = false,
    bool clearReleaseTo = false,
    String? skill,
    Map<String, Set<String>>? skills,
  }) => CardFilters(
    query: query ?? this.query,
    bands: bands ?? this.bands,
    characters: characters ?? this.characters,
    attributes: attributes ?? this.attributes,
    rarities: rarities ?? this.rarities,
    totalMin: resetTotal || clearTotalMin ? null : (totalMin ?? this.totalMin),
    totalMax: resetTotal || clearTotalMax ? null : (totalMax ?? this.totalMax),
    artOnly: artOnly ?? this.artOnly,
    noArt: noArt ?? this.noArt,
    releaseFrom: resetRelease || clearReleaseFrom
        ? null
        : (releaseFrom ?? this.releaseFrom),
    releaseTo: resetRelease || clearReleaseTo
        ? null
        : (releaseTo ?? this.releaseTo),
    skill: skill ?? this.skill,
    skills: skills ?? this.skills,
  );

  bool matches(TeamCatalog catalog, bool members, int id) {
    final characters = catalog.characterIds(members, id);
    if (bands.isNotEmpty &&
        !characters.any((c) => bands.contains(catalog.characterBand(c)))) {
      return false;
    }
    if (this.characters.isNotEmpty &&
        !characters.any(this.characters.contains)) {
      return false;
    }
    if (attributes.isNotEmpty &&
        !attributes.contains(catalog.attribute(members, id))) {
      return false;
    }
    if (rarities.isNotEmpty &&
        !rarities.contains(catalog.rarity(members, id))) {
      return false;
    }
    if (artOnly && catalog.cardImage(members, id).isEmpty) return false;
    if (noArt && catalog.cardImage(members, id).isNotEmpty) return false;
    if (totalMin != null || totalMax != null) {
      final stat = objectRow(catalog.card(members, id)['statMax']);
      final total =
          intOf(stat['performance']) +
          intOf(stat['technique']) +
          intOf(stat['visual']);
      if (totalMin != null && total < totalMin!) return false;
      if (totalMax != null && total > totalMax!) return false;
    }
    final meta = objectRow(catalog.card(members, id)['catalogMetadata']);
    if (releaseFrom != null || releaseTo != null) {
      final raw = meta['releasedAt'];
      num? stamp;
      if (raw is List) {
        for (final value in raw) {
          if (value is num) {
            stamp = value;
            break;
          }
        }
      } else if (raw is num) {
        stamp = raw;
      }
      if (stamp == null) return false;
      final millis = stamp.toInt();
      if (releaseFrom != null && millis < releaseFrom!) return false;
      if (releaseTo != null && millis > releaseTo!) return false;
    }
    final skillQuery = skill.trim().toLowerCase();
    if (skillQuery.isNotEmpty) {
      final resolved = objectRow(meta['resolvedSkills']);
      final names = <String>[];
      for (final role in resolved.values) {
        for (final row in role is List ? role : [role]) {
          final values = objectRow(row)['skillName'];
          if (values is List) names.addAll(values.whereType<String>());
        }
      }
      if (!names.any((name) => name.toLowerCase().contains(skillQuery))) {
        return false;
      }
    }
    for (final entry in skills.entries) {
      if (entry.value.isEmpty) continue;
      final carried = catalog.skillTypes(members, id, entry.key);
      if (!carried.any(entry.value.contains)) return false;
    }
    final plan = catalog.cardQueryEngine.parse(query);
    if (!catalog.cardQueryEngine.matches({
      ...catalog.card(members, id),
      'characterIds': characters,
      'cardType': catalog.attribute(members, id),
      'rarity': catalog.rarity(members, id),
    }, plan)) {
      return false;
    }
    final q = plan.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return '${catalog.cardName(members, id)} ${catalog.cardSubtitle(members, id)} $id'
        .toLowerCase()
        .contains(q);
  }
}

Set<int> _toggle(Set<int> set, int value) =>
    set.contains(value) ? ({...set}..remove(value)) : {...set, value};

/// The filter facets for cards, as chips.
class CardFilterPanel extends StatelessWidget {
  const CardFilterPanel({
    super.key,
    required this.catalog,
    required this.filters,
    required this.onChanged,
    this.members = true,
  });
  final TeamCatalog catalog;
  final CardFilters filters;
  final ValueChanged<CardFilters> onChanged;

  /// Which card kind the skill facets apply to (member or snapshot).
  final bool members;

  @override
  Widget build(BuildContext context) {
    final t = catalog.t;
    final characters = [
      for (final id in catalog.master.characters.keys)
        if (catalog.characterName(id).isNotEmpty &&
            (filters.bands.isEmpty ||
                filters.bands.contains(catalog.characterBand(id))))
          id,
    ];
    Widget chips(List<Widget> children) =>
        Wrap(spacing: 8, runSpacing: 8, children: children);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToolField(
          label: t('catalog.fields.band', 'Band'),
          child: chips([
            for (final id in catalog.bandIds)
              FilterChip(
                avatar: _emblem(catalog.bandIcon(id)),
                label: Text(catalog.bandName(id)),
                selected: filters.bands.contains(id),
                onSelected: (_) => onChanged(
                  filters.copyWith(bands: _toggle(filters.bands, id)),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        ToolField(
          label: t('catalog.fields.character', 'Character'),
          child: chips([
            for (final id in characters)
              FilterChip(
                avatar: _emblem(catalog.characterFace(id), round: true),
                label: Text(catalog.characterName(id)),
                selected: filters.characters.contains(id),
                onSelected: (_) => onChanged(
                  filters.copyWith(characters: _toggle(filters.characters, id)),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        ToolField(
          label: t('catalog.fields.attribute', 'Attribute'),
          child: chips([
            for (final id in [1, 2, 3, 4, 5])
              FilterChip(
                avatar: _emblem(catalog.attributeIcon(id) ?? ''),
                label: Text(catalog.attributeName(id)),
                selected: filters.attributes.contains(id),
                onSelected: (_) => onChanged(
                  filters.copyWith(attributes: _toggle(filters.attributes, id)),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        ToolField(
          label: t.label('rarity'),
          child: chips([
            for (final id in [1, 2, 3, 4])
              FilterChip(
                avatar: _emblem(catalog.rarityIcon(id) ?? ''),
                label: Text(cardRarityName(id)),
                selected: filters.rarities.contains(id),
                onSelected: (_) => onChanged(
                  filters.copyWith(rarities: _toggle(filters.rarities, id)),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        ToolField(
          label: t.label('total'),
          child: Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey((members, 'total-min', filters.active == 0)),
                  initialValue: filters.totalMin?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t.label('minimum')),
                  onChanged: (value) => onChanged(
                    filters.copyWith(
                      totalMin: int.tryParse(value),
                      clearTotalMin: value.isEmpty,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  key: ValueKey((members, 'total-max', filters.active == 0)),
                  initialValue: filters.totalMax?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t.label('maximum')),
                  onChanged: (value) => onChanged(
                    filters.copyWith(
                      totalMax: int.tryParse(value),
                      clearTotalMax: value.isEmpty,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ToolField(
          label: t.label('availableImage'),
          child: chips([
            FilterChip(
              label: Text(t.label('yes')),
              selected: filters.artOnly,
              onSelected: (value) =>
                  onChanged(filters.copyWith(artOnly: value, noArt: false)),
            ),
            FilterChip(
              label: Text(t.label('no')),
              selected: filters.noArt,
              onSelected: (value) =>
                  onChanged(filters.copyWith(noArt: value, artOnly: false)),
            ),
          ]),
        ),
        for (final (role, label)
            in (members
                ? const [
                    ('leader', 'Leader skill'),
                    ('live', 'Live skill'),
                    ('gekiso', 'Gekiso skill'),
                  ]
                : const [
                    ('support', 'Support skill'),
                    ('gekisouSupport', 'Gekiso support skill'),
                  ])) ...[
          const SizedBox(height: 12),
          ToolField(
            label: t.label(
              role == 'gekiso'
                  ? 'gekisouSkill'
                  : role == 'gekisouSupport'
                  ? 'gekisouSupportSkill'
                  : '${role}Skill',
              label,
            ),
            child: chips([
              for (final name in catalog.skillTypeOptions(members, role))
                FilterChip(
                  label: Text(name),
                  selected: filters.skills[role]?.contains(name) ?? false,
                  onSelected: (_) {
                    final current = {...?filters.skills[role]};
                    if (!current.remove(name)) current.add(name);
                    onChanged(
                      filters.copyWith(
                        skills: {...filters.skills, role: current},
                      ),
                    );
                  },
                ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        ToolField(
          label: t.label('release'),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final lower in [true, false])
                InputChip(
                  label: Text(
                    '${t.label(lower ? 'minimum' : 'maximum')}: ${(lower ? filters.releaseFrom : filters.releaseTo) == null ? t('common.states.all', 'All') : DateFormat.yMd(t.locale).format(DateTime.fromMillisecondsSinceEpoch((lower ? filters.releaseFrom : filters.releaseTo)!))}',
                  ),
                  onPressed: () async {
                    final value = lower
                        ? filters.releaseFrom
                        : filters.releaseTo;
                    final date = await showDatePicker(
                      context: context,
                      initialDate: value == null
                          ? DateTime.now()
                          : DateTime.fromMillisecondsSinceEpoch(value),
                      firstDate: DateTime(2010),
                      lastDate: DateTime(2100),
                    );
                    if (date != null) {
                      onChanged(
                        lower
                            ? filters.copyWith(
                                releaseFrom: date.millisecondsSinceEpoch,
                              )
                            : filters.copyWith(
                                releaseTo:
                                    DateTime(
                                      date.year,
                                      date.month,
                                      date.day + 1,
                                    ).millisecondsSinceEpoch -
                                    1,
                              ),
                      );
                    }
                  },
                  onDeleted: () => onChanged(
                    lower
                        ? filters.copyWith(clearReleaseFrom: true)
                        : filters.copyWith(clearReleaseTo: true),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ToolField(
          label: t('catalog.fields.skill', 'Skill'),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              hintText: t('catalog.fields.skillHint', 'Skill name'),
            ),
            onChanged: (value) => onChanged(filters.copyWith(skill: value)),
          ),
        ),
      ],
    );
  }
}

Widget? _emblem(String url, {bool round = false}) {
  if (url.isEmpty) return null;
  final image = Image.network(url, width: 18, height: 18, fit: BoxFit.contain);
  return round ? ClipOval(child: image) : image;
}

/// A full-screen chooser: search and filters in its bar, a grid, and a
/// footer of actions (`selectionPane`).
class SelectionPane extends StatefulWidget {
  const SelectionPane({
    super.key,
    required this.title,
    required this.searchLabel,
    required this.filterLabel,
    required this.query,
    required this.onQuery,
    required this.filters,
    required this.activeFilters,
    required this.count,
    required this.empty,
    required this.itemCount,
    required this.item,
    required this.minTileWidth,
    required this.aspectRatio,
    this.footer,
  });
  final String title;
  final String searchLabel;
  final String filterLabel;
  final String query;
  final ValueChanged<String> onQuery;
  final Widget filters;
  final int activeFilters;
  final String count;
  final String empty;
  final int itemCount;
  final Widget Function(BuildContext context, int index) item;
  final double minTileWidth;
  final double aspectRatio;
  final Widget? footer;

  @override
  State<SelectionPane> createState() => _SelectionPaneState();
}

class _SelectionPaneState extends State<SelectionPane> {
  bool _filters = false;
  late final _search = TextEditingController(text: widget.query);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: widget.filterLabel,
            isSelected: _filters,
            onPressed: () => setState(() => _filters = !_filters),
            icon: Badge(
              isLabelVisible: widget.activeFilters > 0,
              label: Text('${widget.activeFilters}'),
              child: const Icon(Symbols.filter_list_rounded),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SearchBar(
              controller: _search,
              hintText: widget.searchLabel,
              leading: const Icon(Symbols.search_rounded),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: widget.onQuery,
            ),
          ),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          if (_filters)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              sliver: SliverToBoxAdapter(child: widget.filters),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Text(
                widget.count,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (widget.itemCount == 0)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(widget.empty)),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) => SliverGrid(
                  gridDelegate: collectionGrid(
                    context,
                    constraints.crossAxisExtent,
                    minWidth: widget.minTileWidth,
                    aspectRatio: widget.aspectRatio,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    widget.item,
                    childCount: widget.itemCount,
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: widget.footer == null
          ? null
          : Material(
              color: theme.colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: widget.footer,
                ),
              ),
            ),
    );
  }
}

/// Multi- or single-song chooser; returns the chosen songs.
Future<List<SongRef>?> pickSongs(
  BuildContext context,
  TeamCatalog catalog,
  List<SongRef> songs, {
  bool single = false,
  List<int>? allowed,
  List<SongRef>? allowedCharts,
}) => Navigator.of(context).push<List<SongRef>>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _SongPicker(
      catalog: catalog,
      initial: songs,
      single: single,
      allowed: allowed,
      allowedCharts: allowedCharts,
    ),
  ),
);

class _SongPicker extends StatefulWidget {
  const _SongPicker({
    required this.catalog,
    required this.initial,
    required this.single,
    this.allowed,
    this.allowedCharts,
  });
  final TeamCatalog catalog;
  final List<SongRef> initial;
  final bool single;
  final List<int>? allowed;
  final List<SongRef>? allowedCharts;

  @override
  State<_SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends State<_SongPicker> {
  late List<SongRef> _songs = [...widget.initial];
  String _query = '';
  int _difficulty = 3;
  final _bands = <int>{};
  final _attributes = <int>{};
  final _missions = <String>{};
  bool _containsMissions = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.catalog,
    builder: (context, _) => _content(context),
  );

  Widget _content(BuildContext context) {
    final catalog = widget.catalog;
    final t = catalog.t;
    String tb(
      String key,
      String fallback, [
      Map<String, Object?> v = const {},
    ]) => t('tools.teamBuilder.$key', fallback, v);
    final plan = catalog.songQueryEngine
        .parse(_query)
        .withMissionMode(_containsMissions ? 'contains' : 'only');
    final query = plan.text.trim().toLowerCase();
    final missionPlan = CatalogQuery('', {
      'gekisouType': _missions.toList(),
      'gekisouMatch': plan.facets['gekisouMatch']!,
    });
    final ids = [
      for (final key in objectRow(catalog.data['songs']).keys)
        if (int.tryParse(key) case final id?)
          if ((widget.allowed == null || widget.allowed!.contains(id)) &&
              catalog.difficultyRow(id, _difficulty) != null &&
              (widget.allowedCharts == null ||
                  widget.allowedCharts!.contains(SongRef(id, _difficulty))) &&
              (_bands.isEmpty || catalog.songBands(id).any(_bands.contains)) &&
              (_attributes.isEmpty ||
                  _attributes.contains(intOf(catalog.song(id)['musicType']))) &&
              catalog.songQueryEngine.matches(catalog.song(id), missionPlan) &&
              catalog.songQueryEngine.matches({
                ...catalog.song(id),
                'difficulty': [catalog.difficultyRow(id, _difficulty)],
              }, plan) &&
              (query.isEmpty ||
                  '${catalog.songTitle(id)} ${catalog.songPresentation.artist(catalog.displaySong(id))} ${catalog.songBands(id).map(catalog.bandName).join(' ')}'
                      .toLowerCase()
                      .contains(query)))
            id,
    ]..sort((a, b) => b - a);
    final selected = {
      for (final song in _songs)
        if (song.difficulty == _difficulty) song.songId,
    };
    void toggle(int id) {
      final ref = SongRef(id, _difficulty);
      if (widget.single) {
        Navigator.of(context).pop([ref]);
        return;
      }
      setState(() {
        _songs = _songs.contains(ref)
            ? [..._songs.where((s) => s != ref)]
            : [..._songs, ref];
      });
    }

    Widget facet(
      String label,
      List<(String, String, String?)> options,
      Set<String> chosen,
      void Function(String value) toggle,
    ) => ToolField(
      label: label,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (value, name, icon) in options)
            FilterChip(
              avatar: icon == null ? null : _emblem(icon),
              label: Text(name),
              selected: chosen.contains(value),
              onSelected: (_) => setState(() => toggle(value)),
            ),
        ],
      ),
    );
    final bandValues = {for (final b in _bands) '$b'};
    final attributeValues = {for (final a in _attributes) '$a'};
    return SelectionPane(
      title: widget.single
          ? tb('chooseSong', 'Choose a song')
          : tb('chooseSongs', 'Choose songs'),
      searchLabel: t('common.actions.search', 'Search'),
      filterLabel: tb('filters', 'Filters'),
      query: _query,
      onQuery: (value) => setState(() => _query = value),
      activeFilters: _bands.length + _attributes.length + _missions.length,
      filters: Builder(
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            facet(
              t('catalog.analysis.fields.gekisouType', 'Gekiso type'),
              [
                (
                  'Combo',
                  t('catalog.songs.gekisou.gekisouMissionCombo', 'COMBO'),
                  null,
                ),
                (
                  'Luck',
                  t('catalog.songs.gekisou.gekisouMissionLuck', 'LUCK'),
                  null,
                ),
                (
                  'JustCount',
                  t('catalog.songs.gekisou.gekisouMissionJustCount', 'JUST'),
                  null,
                ),
                ('Mix', t('catalog.songs.gekisou.mixed', 'Mixed'), null),
              ],
              _missions,
              (v) => _missions.contains(v)
                  ? _missions.remove(v)
                  : _missions.add(v),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(
                    t('catalog.songs.gekisou.only', 'Only selected types'),
                  ),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(
                    t(
                      'catalog.songs.gekisou.contains',
                      'Contains a selected type',
                    ),
                  ),
                ),
              ],
              selected: {_containsMissions},
              onSelectionChanged: (value) =>
                  setState(() => _containsMissions = value.first),
            ),
            const SizedBox(height: 12),
            facet(
              t('catalog.fields.band', 'Band'),
              [
                for (final id in catalog.bandIds)
                  ('$id', catalog.bandName(id), catalog.bandIcon(id)),
              ],
              bandValues,
              (v) => _bands.contains(int.parse(v))
                  ? _bands.remove(int.parse(v))
                  : _bands.add(int.parse(v)),
            ),
            const SizedBox(height: 12),
            facet(
              t('catalog.fields.attribute', 'Attribute'),
              [
                for (final id in [1, 2, 3, 4, 5])
                  ('$id', catalog.attributeName(id), catalog.attributeIcon(id)),
              ],
              attributeValues,
              (v) => _attributes.contains(int.parse(v))
                  ? _attributes.remove(int.parse(v))
                  : _attributes.add(int.parse(v)),
            ),
          ],
        ),
      ),
      count: tb('songCount', '{count} songs', {'count': ids.length}),
      empty: tb('noSongs', 'No songs match'),
      itemCount: ids.length,
      minTileWidth: 150,
      aspectRatio: 1,
      item: (context, index) {
        final id = ids[index];
        final song = catalog.displaySong(id);
        final presentation = catalog.songPresentation;
        return Tile(
          title: catalog.songTitle(id),
          subtitle: presentation.artist(song),
          adornments: presentation.avatars(song),
          marks: presentation.marks(
            song,
            difficulty: catalog.difficultyLabel(id, _difficulty),
          ),
          images: [catalog.songJacket(id)],
          fit: BoxFit.cover,
          selected: selected.contains(id),
          serverMark: catalog.mark('songs', id),
          onTap: () => toggle(id),
        );
      },
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Segmented<int>(
            value: _difficulty,
            grow: false,
            options: [
              for (final (index, name) in difficultyNames.indexed)
                Choice(index, name.toUpperCase()),
            ],
            onSelected: (value) => setState(() => _difficulty = value),
          ),
          if (!widget.single) ...[
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  tb('selectedSongs', '{count} selected', {
                    'count': _songs.length,
                  }),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _songs = [
                      ..._songs.where(
                        (s) =>
                            s.difficulty != _difficulty ||
                            !ids.contains(s.songId),
                      ),
                      for (final id in ids) SongRef(id, _difficulty),
                    ];
                  }),
                  child: Text(
                    tb('selectMatchingSongs', 'Select all shown songs'),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _songs = {
                      ..._songs,
                      for (final id in ids)
                        for (final row in catalog.difficultyRows(id))
                          if (widget.allowedCharts == null ||
                              widget.allowedCharts!.contains(
                                SongRef(id, intOf(row['difficulty'])),
                              ))
                            SongRef(id, intOf(row['difficulty'])),
                    }.toList();
                  }),
                  child: Text(tb('selectAllCharts', 'Select all difficulties')),
                ),
                TextButton(
                  onPressed: () => setState(
                    () =>
                        _songs.removeWhere((song) => ids.contains(song.songId)),
                  ),
                  child: Text(
                    tb('deselectAllCharts', 'Deselect all difficulties'),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _songs = []),
                  child: Text(t('common.actions.clear', 'Clear')),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_songs),
                  child: Text(tb('useSongs', 'Use these songs')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Chooses one card (a formation slot); returns its id, or -1 for "no snap".
Future<int?> pickCard(
  BuildContext context,
  TeamCatalog catalog, {
  required bool members,
  required List<int> ids,
  int? current,
  String? caption,
}) => Navigator.of(context).push<int>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _CardPicker(
      catalog: catalog,
      members: members,
      ids: ids,
      current: current,
    ),
  ),
);

class _CardPicker extends StatefulWidget {
  const _CardPicker({
    required this.catalog,
    required this.members,
    required this.ids,
    this.current,
  });
  final TeamCatalog catalog;
  final bool members;
  final List<int> ids;
  final int? current;

  @override
  State<_CardPicker> createState() => _CardPickerState();
}

class _CardPickerState extends State<_CardPicker> {
  CardFilters _filters = const CardFilters();

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final t = catalog.t;
    String tb(
      String key,
      String fallback, [
      Map<String, Object?> v = const {},
    ]) => t('tools.teamBuilder.$key', fallback, v);
    final ids = [
      for (final id in widget.ids)
        if (_filters.matches(catalog, widget.members, id)) id,
    ]..sort((a, b) => b - a);
    return SelectionPane(
      title: widget.members
          ? tb('pickMember', 'Choose a member')
          : tb('pickSnap', 'Choose a snap'),
      searchLabel: t('common.actions.search', 'Search'),
      filterLabel: tb('filters', 'Filters'),
      query: _filters.query,
      onQuery: (value) =>
          setState(() => _filters = _filters.copyWith(query: value)),
      activeFilters: _filters.active,
      filters: CardFilterPanel(
        catalog: catalog,
        filters: _filters,
        members: widget.members,
        onChanged: (value) => setState(() => _filters = value),
      ),
      count: tb('cardCount', '{count} cards', {'count': ids.length}),
      empty: tb('noMatches', 'No cards match'),
      itemCount: ids.length,
      minTileWidth: widget.members ? 140 : 200,
      aspectRatio: widget.members ? 3 / 4 : 16 / 9,
      item: (context, index) {
        final id = ids[index];
        return Tile(
          title: catalog.cardName(widget.members, id),
          subtitle: catalog.cardSubtitle(widget.members, id),
          adornments: [
            for (final c in catalog.characterIds(widget.members, id))
              catalog.characterFace(c),
          ],
          images: [catalog.cardImage(widget.members, id)],
          fit: BoxFit.cover,
          aspectRatio: widget.members ? 3 / 4 : 16 / 9,
          media: CardArt(catalog: catalog, members: widget.members, id: id),
          serverMark: catalog.mark(
            widget.members ? 'members' : 'snapshots',
            id,
          ),
          selected: id == widget.current,
          onTap: () => Navigator.of(context).pop(id),
        );
      },
      footer: widget.members
          ? null
          : Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).pop(-1),
                icon: const Icon(Symbols.hide_image_rounded),
                label: Text(tb('noSnap', 'No snap')),
              ),
            ),
    );
  }
}
