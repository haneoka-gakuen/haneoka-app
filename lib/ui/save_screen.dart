import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/account_widgets.dart';
import '../catalog/catalog_screen.dart';
import '../catalog/profiles.dart';
import '../catalog/visuals.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../core/i18n.dart';
import '../core/relative_time.dart';
import '../l10n/app_localizations.dart';
import '../save/account_store.dart';
import '../save/export.dart';
import '../save/game_save.dart';
import '../save/save_view.dart';
import '../records/records.dart';
import '../shell/page.dart';
import '../shell/routes.dart';
import '../team_builder/team_builder_screen.dart';
import 'app_image.dart';
import 'card_artwork.dart';
import 'detail.dart';
import 'import_screen.dart';
import 'json_view.dart';
import 'shapes.dart';
import 'theme.dart';
import 'tile.dart';

typedef SaveHistoryAction = void Function(BuildContext context, GameSave save);

class SaveHistoryActionScope extends InheritedWidget {
  const SaveHistoryActionScope({
    super.key,
    required this.onReadHistory,
    required super.child,
  });
  final SaveHistoryAction onReadHistory;
  static SaveHistoryAction? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SaveHistoryActionScope>()
      ?.onReadHistory;
  @override
  bool updateShouldNotify(SaveHistoryActionScope oldWidget) =>
      oldWidget.onReadHistory != onReadHistory;
}

/// The game catalogue a save is read against: its release's cards, songs,
/// items and events.
class _Catalog {
  _Catalog(
    this.cards,
    this.supports,
    this.songs,
    this.items,
    this.events,
    this.visuals,
    this.progression,
  );
  final Map<String, Map> cards, supports, songs, items, events;
  final CatalogVisuals visuals;
  final CardCatalog progression;

  CardGrowthDisplay? growth(Map row, SiteText t, {required bool support}) {
    final id = (row['_masterId'] as num?)?.toInt();
    final art = (support ? progression.support : progression.member)[id];
    if (art == null) return null;
    final exp = row['_exp'] is num
        ? row['_exp']
        : num.tryParse('${row['_exp']}');
    return progression.growth(
      art,
      t,
      support: support,
      level: progression.cardLevel({
        'memberCardId': id,
        'memberExp': exp,
        'memberAwakeCount': row['_awakeCount'],
        'supportCardId': id,
        'supportExp': exp,
        'supportRank': row['_rank'],
      }, support: support),
      training: (row['_awakeCount'] as num?)?.toInt(),
      rank: (row['_rank'] as num?)?.toInt(),
      showSkills: !support,
      liveSkillLevel: (row['_liveSkillLevel'] as num?)?.toInt(),
      gekisoSkillLevel: (row['_performanceSkillLevel'] as num?)?.toInt(),
    );
  }

  static Map<String, Map> _rows(Object? document, [String? path]) {
    Object? rows = document;
    if (path != null) rows = rows is Map ? rows[path] : null;
    return {
      if (rows is Map)
        for (final MapEntry(:key, :value) in rows.entries)
          if (value is Map) '$key': value,
    };
  }

  static final _loaded = <HaneokaApi, Future<_Catalog>>{};
  static Future<_Catalog> of(HaneokaApi api) =>
      cachedResource(_loaded, api, () async {
        final (
          cards,
          supports,
          songs,
          items,
          events,
          visuals,
          progression,
        ) = await (
          api.catalog('cards'),
          api.catalog('support-cards'),
          api.catalog('songs'),
          api.catalog('items'),
          api.catalog('events'),
          CatalogVisuals.of(api),
          CardCatalog.of(api),
        ).wait;
        return _Catalog(
          _rows(cards),
          _rows(supports),
          _rows(songs),
          _rows(items, 'items'),
          _rows(events, 'entries'),
          visuals,
          progression,
        );
      });
}

/// One player's profile, read from their save: who they are, their
/// standing, song clears, collection and items, then exports and the raw
/// data.
class SaveScreen extends StatefulWidget {
  const SaveScreen({super.key, required this.save, this.onReadHistory});
  final GameSave save;
  final SaveHistoryAction? onReadHistory;

  @override
  State<SaveScreen> createState() => _SaveScreenState();
}

class _SaveScreenState extends State<SaveScreen> {
  SaveHistoryAction? get _historyAction =>
      widget.onReadHistory ?? SaveHistoryActionScope.maybeOf(context);
  Future<_Catalog>? _catalog;
  bool _busy = false;
  bool _newestFirst = false;

  GameSave get save =>
      AccountStore.instance.saves
          .where(
            (s) =>
                s.profileId == widget.save.profileId &&
                s.server == widget.save.server,
          )
          .firstOrNull ??
      widget.save;

  @override
  void initState() {
    super.initState();
    AccountStore.instance.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AccountStore.instance.removeListener(_changed);
    super.dispose();
  }

  Future<void> _updateSave() async {
    if (_busy) return;
    setState(() => _busy = true);
    final updated = await Navigator.of(context).push<GameSave>(
      MaterialPageRoute(
        builder: (_) =>
            ImportScreen(updateSave: save, onReadHistory: _historyAction),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (updated != null) _say(AppLocalizations.of(context).saveUpdated);
  }

  Future<void> _importTeam() async {
    if (_busy) return;
    setState(() => _busy = true);
    final selected = save;
    try {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/team-builder'),
          builder: (_) => TeamBuilderScreen(importSave: selected),
        ),
      );
    } catch (error) {
      if (mounted) _say('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    _catalog ??= _Catalog.of(
      state.apiFor(save.server ?? state.server),
    );
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _copyPackage() async {
    final t = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: exportTeamPackage(save)));
    if (mounted) _say(t.copied);
  }

  Future<void> _saveFile() async {
    final t = AppLocalizations.of(context);
    final bytes = exportSave(save);
    final name =
        'our-notes-${save.server ?? 'save'}-${save.profileId}.json';
    final path = await FilePicker.saveFile(fileName: name, bytes: bytes);
    if (path == null) return;
    if (mounted) _say(t.saved);
  }

  Future<void> _remove() async {
    final t = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.removeAccount),
        content: Text(t.removeAccountConfirm(save.name ?? save.profileId)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.remove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AccountStore.instance.remove(save);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ShellPage(
      title: save.name ?? save.profileId,
      actions: [
        BarAction(
          icon: Symbols.groups_rounded,
          label: t.importToTeamBuilder,
          onPressed: _busy ? null : _importTeam,
          tonal: true,
        ),
        BarAction(
          icon: Symbols.refresh_rounded,
          label: t.updateSave,
          onPressed: _busy ? null : _updateSave,
        ),
      ],
      body: FutureBuilder(
        future: _catalog,
        builder: (context, snapshot) => _Profile(
          save: save,
          catalog: snapshot.data,
          onCopyPackage: _copyPackage,
          onSaveFile: _saveFile,
          onRemove: _remove,
          onUpdateSave: _busy ? null : _updateSave,
          onImportTeam: _busy ? null : _importTeam,
          showReadHistory: _historyAction != null,
          onReadHistory: _busy || _historyAction == null
              ? null
              : () => _historyAction!(context, save),
          newestFirst: _newestFirst,
          onSortChanged: (value) => setState(() => _newestFirst = value),
        ),
      ),
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile({
    required this.save,
    required this.catalog,
    required this.onCopyPackage,
    required this.onSaveFile,
    required this.onRemove,
    required this.onUpdateSave,
    required this.onImportTeam,
    required this.onReadHistory,
    required this.showReadHistory,
    required this.newestFirst,
    required this.onSortChanged,
  });
  final GameSave save;
  final _Catalog? catalog;
  final VoidCallback onCopyPackage;
  final VoidCallback onSaveFile;
  final VoidCallback onRemove;
  final VoidCallback? onUpdateSave, onImportTeam, onReadHistory;
  final bool newestFirst, showReadHistory;
  final ValueChanged<bool> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final state = AppScope.of(context);
    final site = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final view = SaveView(save);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final number = NumberFormat.decimalPattern(locale);
    final api = state.apiFor(save.server ?? state.server);
    String asset(Object? path) => api.asset('$path').toString();

    final favorite = catalog?.cards['${view.favoriteMemberCardId}'];
    final favoriteArt = switch ((favorite?['images'] as Map?)) {
      final Map images => images['full'] ?? images['thumbnail'],
      _ => null,
    };
    final started = view.player['_tutorialFinishedAtUnixSeconds'];

    // ---------- Header ----------
    final header = Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (favoriteArt is String)
            Positioned.fill(
              child: ShaderMask(
                shaderCallback: (rect) => LinearGradient(
                  begin: Alignment.centerRight,
                  end: Alignment.centerLeft,
                  colors: [
                    Colors.black.withValues(alpha: 0.75),
                    Colors.transparent,
                  ],
                  stops: const [0.1, 0.75],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: AppImage(
                  candidates: [asset(favoriteArt)],
                  fit: BoxFit.cover,
                  alignment: const Alignment(0.6, -0.4),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShapedIcon(
                  shape: MaterialShapes.sunny,
                  size: 72,
                  color: scheme.primary,
                  foreground: scheme.onPrimary,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'RANK',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimary,
                          height: 1,
                          letterSpacing: 0.8,
                        ),
                      ),
                      Text(
                        '${view.playerRank ?? '—'}',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        save.name ?? save.profileId,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          SvgPicture.asset(
                            releaseEmblem(save.release),
                            width: 18,
                            height: 18,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              save.regionName ?? '',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      InkWell(
                        borderRadius: BorderRadius.circular(Corner.small),
                        onTap: () async {
                          await Clipboard.setData(
                            ClipboardData(text: save.profileId),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(t.copied)));
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${t.playerId} ${save.profileId}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                Symbols.content_copy_rounded,
                                size: 16,
                                semanticLabel: t.copyId,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (started is num && started > 0)
                        Text(
                          '${t.tutorialDone} · ${DateFormat.yMd(locale).format(DateTime.fromMillisecondsSinceEpoch(started.toInt() * 1000))}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      if (save.modifiedAt != null)
                        Text(
                          t.savedOn(
                            DateFormat.yMMMd(locale)
                                .add_Hm()
                                .format(save.modifiedAt!.toLocal()),
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // ---------- Standing ----------
    Widget stat(IconData icon, String label, String value) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Corner.large),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final stats = [
      stat(
        Symbols.trending_up_rounded,
        t.playerExp,
        view.exp == null ? '—' : number.format(view.exp),
      ),
      stat(
        Symbols.military_tech_rounded,
        t.highScoreRating,
        number.format(view.highScoreRating),
      ),
      if (view.vipRank != null)
        stat(Symbols.credit_card_rounded, t.vipRank, 'RANK ${view.vipRank}'),
      stat(
        Symbols.person_rounded,
        t.ownedMembers,
        number.format(view.rows(SaveSection.memberCards).length),
      ),
      stat(
        Symbols.photo_library_rounded,
        t.ownedSnapshots,
        number.format(view.rows(SaveSection.snapshots).length),
      ),
    ];
    Widget grid(List<Widget> children, {double min = 220}) => LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth + 8) / (min + 8)).floor().clamp(
          1,
          4,
        );
        final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );

    // ---------- Song clears ----------
    final results = view.rows(SaveSection.songs);
    final songs = catalog?.songs ?? const {};
    Widget clears() {
      const names = ['EASY', 'NORMAL', 'HARD', 'EXPERT'];
      final rows = <Widget>[];
      for (final (index, name) in names.indexed) {
        final key = name.toLowerCase();
        final total = songs.values
            .where(
              (song) => (song['difficulty'] as List? ?? const []).any(
                (d) => d is Map && d['difficulty'] == index,
              ),
            )
            .length;
        int count(int threshold) => results
            .where(
              (row) =>
                  ((row['_${key}ClearedStatus'] as num?) ?? 0) >= threshold,
            )
            .length;
        final cleared = count(10),
            fullCombo = count(20),
            allPerfect = count(30);
        final of = total == 0 ? results.length : total;
        final color = difficultyColors[index];
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 72,
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.2),
                        border: Border.all(color: color),
                        borderRadius: BorderRadius.circular(Corner.small),
                      ),
                      child: Text(
                        name,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    for (final (label, value, alpha) in [
                      (t.cleared, cleared, 0.35),
                      (t.fullCombo, fullCombo, 0.65),
                      (t.allPerfect, allPerfect, 1.0),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(left: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: alpha),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  label,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              number.format(value),
                              style: theme.textTheme.titleSmall?.copyWith(
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
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(Corner.full),
                  child: SizedBox(
                    height: 10,
                    child: LayoutBuilder(
                      builder: (context, c) => Stack(
                        children: [
                          Container(color: scheme.surfaceContainerHighest),
                          for (final (value, alpha) in [
                            (cleared, 0.35),
                            (fullCombo, 0.65),
                            (allPerfect, 1.0),
                          ])
                            Container(
                              width: of == 0
                                  ? 0
                                  : c.maxWidth * (value / of).clamp(0, 1),
                              color: color.withValues(alpha: alpha),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.ofSongs(number.format(of)),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Column(children: rows);
    }

    // ---------- Collection ----------
    Widget rail(String resource, SaveSection section, Map<String, Map> rows) {
      final owned = {
        for (final row in view.rows(section)) '${row['_masterId']}': row,
      };
      final kit = catalog == null
          ? null
          : CatalogKit(
              catalogProfiles.firstWhere((p) => p.resource == resource),
              site,
              api,
              catalog!.visuals,
            );
      final entries =
          [
            for (final MapEntry(:key, :value) in rows.entries)
              if (owned.containsKey(key)) value.cast<String, Object?>(),
          ]..sort((a, b) {
            final rarity = ((b['rarity'] as num?) ?? 0).compareTo(
              (a['rarity'] as num?) ?? 0,
            );
            if (newestFirst) {
              final released = (RelativeTime.timestamp(b['releasedAt']) ?? 0)
                  .compareTo(RelativeTime.timestamp(a['releasedAt']) ?? 0);
              if (released != 0) return released;
            }
            return !newestFirst && rarity != 0
                ? rarity
                : ((b[kit?.profile.id.first ?? 'id'] as num?) ?? 0).compareTo(
                    (a[kit?.profile.id.first ?? 'id'] as num?) ?? 0,
                  );
          });
      if (kit == null || entries.isEmpty) return const SizedBox.shrink();
      final support = resource == 'support-cards';
      final width = support ? 200.0 : 130.0;
      return SizedBox(
        // Media plus the tile's fixed text block (`collectionGrid`).
        height:
            width / kit.profile.aspectRatio +
            (MediaQuery.sizeOf(context).width < ShellMetrics.compact
                ? 16 + 40 + 4 + 18
                : 32 + 48 + 8 + 20),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: entries.length.clamp(0, 30),
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final entry = entries[index];
            final row = owned[kit.id(entry)];
            return SizedBox(
              width: width,
              child: Tile(
                title: kit.title(entry),
                subtitle: kit.subtitle(entry),
                adornments: kit.adornments(entry),
                images: kit.images(entry),
                media: kit.cardArtwork(
                  entry,
                  growth: row == null
                      ? null
                      : catalog!.growth(row, site, support: support),
                ),
                aspectRatio: kit.profile.aspectRatio,
                onTap: () => openEntity(context, kit.profile, entry),
              ),
            );
          },
        ),
      );
    }

    void viewAll(String resource, SaveSection section) {
      final profile = catalogProfiles.firstWhere((p) => p.resource == resource);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CatalogScreen(
            profile: profile,
            title: resource == 'cards' ? t.ownedMembers : t.ownedSnapshots,
            owned: {
              for (final row in view.rows(section)) '${row['_masterId']}': '',
            },
            ownedGrowth: {
              for (final row in view.rows(section))
                '${row['_masterId']}': ?catalog?.growth(
                  row,
                  site,
                  support: resource == 'support-cards',
                ),
            },
            onOpen: (context, item) => openEntity(context, profile, item),
          ),
        ),
      );
    }

    // ---------- Items ----------
    final items = [
      for (final id in const [1, 2, 3])
        if (catalog?.items['$id'] case final Map item)
          (item, view.amountOf(id)),
    ];

    // ---------- Events ----------
    final events = [
      for (final row in view.rows(SaveSection.events))
        if (((row['_eventPointCount'] as num?) ?? 0) > 0)
          (catalog?.events['${row['_masterId']}'], row),
    ];

    Widget section(
      IconData icon,
      String title,
      Widget child, {
      Widget? trailing,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ShapedIcon(
                shape: MaterialShapes.cookie9Sided,
                size: 36,
                child: Icon(icon, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );

    Widget exportCard(
      IconData icon,
      String title,
      String hint,
      VoidCallback onPressed,
    ) => Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(Corner.large),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    Text(
                      hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Symbols.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );

    void openJson(String title, Object? value) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShellPage(
          title: title,
          body: JsonView(value: value),
        ),
      ),
    );

    return ListView(
      padding: pagePadding(context),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (showReadHistory)
                      FilledButton.tonalIcon(
                        onPressed: onReadHistory,
                        icon: const Icon(Symbols.history_rounded),
                        label: Text(site('catalog.gachaHistory.readHistory')),
                      ),
                    FilledButton.icon(
                      onPressed: onImportTeam,
                      icon: const Icon(Symbols.groups_rounded),
                      label: Text(t.importToTeamBuilder),
                    ),
                    OutlinedButton.icon(
                      onPressed: onUpdateSave,
                      icon: const Icon(Symbols.refresh_rounded),
                      label: Text(t.updateSave),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  t.importToTeamHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                grid(stats, min: 150),
                const SizedBox(height: 28),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(t.cardSort, style: theme.textTheme.labelLarge),
                    ChoiceChip(
                      label: Text(t.sortRarity),
                      selected: !newestFirst,
                      onSelected: (_) => onSortChanged(false),
                    ),
                    ChoiceChip(
                      label: Text(t.sortNewest),
                      selected: newestFirst,
                      onSelected: (_) => onSortChanged(true),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                section(
                  Symbols.person_rounded,
                  '${t.ownedMembers} · ${number.format(view.rows(SaveSection.memberCards).length)}',
                  rail(
                    'cards',
                    SaveSection.memberCards,
                    catalog?.cards ?? const {},
                  ),
                  trailing: TextButton(
                    onPressed: () => viewAll('cards', SaveSection.memberCards),
                    child: Text(t.viewAll),
                  ),
                ),
                section(
                  Symbols.photo_library_rounded,
                  '${t.ownedSnapshots} · ${number.format(view.rows(SaveSection.snapshots).length)}',
                  rail(
                    'support-cards',
                    SaveSection.snapshots,
                    catalog?.supports ?? const {},
                  ),
                  trailing: TextButton(
                    onPressed: () =>
                        viewAll('support-cards', SaveSection.snapshots),
                    child: Text(t.viewAll),
                  ),
                ),
                if (results.isNotEmpty)
                  section(Symbols.music_note_rounded, t.songClears, clears()),
                if (items.isNotEmpty)
                  section(
                    Symbols.inventory_2_rounded,
                    t.currencies,
                    grid([
                      for (final (item, amount) in items)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(Corner.large),
                          ),
                          child: Row(
                            children: [
                              SizedBox.square(
                                dimension: 36,
                                child: item['image'] is String
                                    ? AppImage(
                                        candidates: [asset(item['image'])],
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  site.text(item['name']),
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              Text(
                                number.format(amount),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ], min: 200),
                  ),
                if (events.isNotEmpty)
                  section(
                    Symbols.event_rounded,
                    t.eventsPlayed,
                    Column(
                      children: [
                        for (final (event, row) in events)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox(
                              width: 96,
                              child: AspectRatio(
                                aspectRatio: 16 / 9,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    Corner.small,
                                  ),
                                  child: event?['image'] is String
                                      ? AppImage(
                                          candidates: [asset(event!['image'])],
                                          fit: BoxFit.cover,
                                        )
                                      : ColoredBox(
                                          color: scheme.surfaceContainerHighest,
                                        ),
                                ),
                              ),
                            ),
                            title: Text(
                              event == null
                                  ? '#${row['_masterId']}'
                                  : site.text(event['title']),
                            ),
                            trailing: Text(
                              t.eventPoints(
                                number.format(row['_eventPointCount']),
                              ),
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                section(
                  Symbols.public_rounded,
                  t.profileLink,
                  PlayerLink(save: save),
                ),
                DetailFold(
                  title: t.exportsTitle,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      grid([
                        exportCard(
                          Symbols.content_copy_rounded,
                          t.exportTeam,
                          t.exportTeamHint,
                          onCopyPackage,
                        ),
                        exportCard(
                          Symbols.download_rounded,
                          t.exportSave,
                          t.exportSaveHint,
                          onSaveFile,
                        ),
                      ], min: 280),
                      const SizedBox(height: 12),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: onRemove,
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.error,
                          ),
                          icon: const Icon(Symbols.delete_rounded),
                          label: Text(t.removeAccount),
                        ),
                      ),
                    ],
                  ),
                ),
                DetailFold(
                  title: t.rawData,
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(t.settings),
                        trailing: const Icon(Symbols.chevron_right_rounded),
                        onTap: () => openJson(t.settings, view.settings),
                      ),
                      if (view.persist.isNotEmpty)
                        ListTile(
                          title: Text(t.latestLive),
                          trailing: const Icon(Symbols.chevron_right_rounded),
                          onTap: () => openJson(t.latestLive, view.persist),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
