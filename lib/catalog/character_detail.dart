import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/voice.dart';
import '../core/i18n.dart';
import '../shell/links.dart';
import '../shell/routes.dart';
import '../stories/stories.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/dialogue_row.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import '../ui/upgrade.dart';
import 'catalog_screen.dart';
import 'character_art.g.dart';
import 'format.dart';
import 'profiles.dart';
import 'visuals.dart';
import 'song_presentation.dart';
import 'voice_catalog.dart';
import 'cross_server.dart';

List<Map> _values(Object? value, [String? key]) {
  final source = key != null && value is Map ? value[key] : value;
  return switch (source) {
    List() => source.whereType<Map>().toList(),
    Map() => source.values.whereType<Map>().toList(),
    _ => <Map>[],
  };
}

num _num(Object? value) =>
    value is num ? value : num.tryParse('${value ?? ''}') ?? 0;

int Function(Map, Map) _by(String key) =>
    (a, b) => _num(a[key]).compareTo(_num(b[key]));

const _storyCategories = ['band', 'link', 'home', 'afterlive', 'tutorial'];

String _storyCategory(Map entry) {
  final key = '${entry['chapterKey'] ?? ''}'.toLowerCase();
  if (key.contains('linkstory')) return 'link';
  if (key.contains('asset_home')) return 'home';
  if (key.contains('afterlive')) return 'afterlive';
  if (key.contains('tutorial')) return 'tutorial';
  return 'band';
}

/// The measured portrait and ribbon positions of the game's friendship board
/// (`FRIENDSHIP_SELF_SLOTS`, `FRIENDSHIP_OTHER_SLOTS`): x, y, arrow x, arrow
/// y in percent, arrow rotation in degrees.
const _selfSlots = [
  (18.82622, 43.36100, 90.85714, 68.57143, -11.853991),
  (27.59146, 77.80083, 93.28571, 33.08571, -44.430576),
  (74.16159, 67.20954, 3.51429, 40.37143, 29.744215),
  (73.93293, 25.82988, 7.42857, 80.62857, -29.195091),
];
const _otherSlots = [
  (19.28354, 30.18672, 90.60000, 75.37143, 29.658096),
  (20.88415, 69.91701, 96.00000, 44.85714, -36.740987),
  (68.90244, 80.18672, 10.71429, 13.57143, 52.050356),
  (79.64939, 49.48133, -0.28571, 50.00000, 3.755137),
  (71.95122, 20.12448, 9.34286, 86.82857, -43.944990),
];

/// A character's page (`character-detail-archive`): profile, cards, stamps,
/// voices, stories, bonds, missions, Live2D models and songs, one per tab.
class CharacterDetail extends StatefulWidget {
  const CharacterDetail({
    super.key,
    required this.record,
    required this.page,
    required this.visuals,
  });
  final Map<String, Object?> record;

  /// The website's payload for the page: its `aux` holds every tab's rows.
  final Map? page;
  final CatalogVisuals? visuals;

  @override
  State<CharacterDetail> createState() => _CharacterDetailState();
}

class _CharacterDetailState extends State<CharacterDetail> {
  late final _voice = VoicePlayback();

  @override
  void dispose() {
    _voice.dispose();
    super.dispose();
  }

  String _section = 'profile';
  int? _partner;
  int _missionType = 0;
  int _rank = 1;
  int? _band;
  final _deferred = <String, Future<Object?>>{};

  AppState get state => AppScope.of(context);
  SiteText get t => state.text;
  ThemeData get theme => Theme.of(context);
  ColorScheme get scheme => theme.colorScheme;
  Map<String, Object?> get item => widget.record;
  Map get aux => (widget.page?['aux'] as Map?) ?? const {};
  int get id => _num(item['characterId']).toInt();

  String number(Object? value) =>
      NumberFormat.decimalPattern(t.locale).format(_num(value));
  String _asset(Object? path) => state.api.asset('$path').toString();

  CatalogKit _kit(String resource) => CatalogKit(
    catalogProfiles.firstWhere((p) => p.resource == resource),
    t,
    state.api,
    widget.visuals,
    songTitles: state.songTitle,
  );

  List<int> _ids(Map entry) => [
    for (final value in [
      ...(entry['characterIds'] as List? ?? const []),
      if (entry['characterIds'] == null) entry['characterId'],
    ])
      if (value is num && value > 0) value.toInt(),
  ];

  Map? _character(int id) => widget.visuals?.characters[id];
  String _name(int id) => t.text(_character(id)?['characterName']);
  String? _face(int id) => switch (_character(id)?['faceImage']) {
    final String face => _asset(face),
    _ => null,
  };

  /// Read the complete page payload, or the older deferred endpoint.
  Future<Object?>? _load(String key) {
    final inline = aux[key];
    if (inline != null) {
      return _deferred[key] ??= Future<Object?>.value(
        key == 'voices' ? (inline as Map)['entries'] : inline,
      );
    }
    final source = (widget.page?['deferred'] as Map?)?[key];
    if (source is! Map || source['url'] is! String) return null;
    return _deferred[key] ??= state.api.json(
      (source['url'] as String).split('?').first,
    );
  }

  int? _deferredCount(String key) => aux[key] != null
      ? _values(aux[key], key == 'voices' ? 'entries' : 'missions').length
      : ((widget.page?['deferred'] as Map?)?[key] as Map?)?['count'] as int?;

  @override
  Widget build(BuildContext context) {
    final cards = _values(
      aux['cards'],
    ).where((e) => _num(e['characterId']) == id).toList()..sort(_by('cardId'));
    final supports = _values(
      aux['support-cards'],
    ).where((e) => _ids(e).contains(id)).toList()..sort(_by('supportCardId'));
    final stamps = _values(
      aux['stamps'],
    ).where((e) => _ids(e).contains(id)).toList()..sort(_by('stampId'));
    final stories =
        _values(
          aux['stories'],
          'episodes',
        ).where((e) => _ids(e).contains(id)).toList()..sort((a, b) {
          for (final compare in [
            _storyCategories
                .indexOf(_storyCategory(a))
                .compareTo(_storyCategories.indexOf(_storyCategory(b))),
            _num(a['chapterId']).compareTo(_num(b['chapterId'])),
            _num(a['storySort']).compareTo(_num(b['storySort'])),
          ]) {
            if (compare != 0) return compare;
          }
          return '${a['storyId']}'.compareTo('${b['storyId']}');
        });
    final models =
        (_values(aux['live2d'], 'models').isNotEmpty
                ? _values(aux['live2d'], 'models')
                : _values(aux['live2d']))
            .where((e) => _num(e['characterId']) == id)
            .toList()
          ..sort((a, b) => '${a['live2dKey']}'.compareTo('${b['live2dKey']}'));
    final songPresentation = SongPresentation(t, state.api, widget.visuals);
    final songs = _values(aux['songs']).where((song) {
      final performer = songPresentation.performer(
        song.cast<String, Object?>(),
      );
      // The entity graph already selected this character's songs. Use the
      // same participants when a registry is present; retain that selection
      // when optional presentation resources are unavailable.
      return performer == null ||
          performer.participantCharacterIds.contains(id);
    }).toList()..sort(_by('musicId'));
    final friendships = _values(
      aux['friendships'],
      'friendships',
    ).where((e) => _ids(e).contains(id)).toList()..sort(_by('friendshipId'));

    final tabs = [
      (
        'profile',
        Symbols.contact_page_rounded,
        t.label('profile', 'Profile'),
        0,
      ),
      (
        'cards',
        Symbols.photo_library_rounded,
        t.label('cards', 'Cards'),
        cards.length + supports.length,
      ),
      (
        'stamps',
        Symbols.sticky_note_2_rounded,
        t.label('stamps', 'Stamps'),
        stamps.length,
      ),
      (
        'voices',
        Symbols.mic_rounded,
        t.label('voices', 'Voices'),
        _deferredCount('voices') ?? 0,
      ),
      (
        'story',
        Symbols.chat_rounded,
        t.label('story', 'Story'),
        stories.length,
      ),
      (
        'friendships',
        Symbols.handshake_rounded,
        t.label('characterBonds', 'Character Bonds'),
        friendships.length,
      ),
      (
        'missions',
        Symbols.checklist_rounded,
        t.label('missions', 'Missions'),
        _deferredCount('character-missions') ?? 0,
      ),
      ('live2d', Symbols.accessibility_new_rounded, 'Live2D', models.length),
      (
        'songs',
        Symbols.music_note_rounded,
        t.label('songs', 'Songs'),
        songs.length,
      ),
    ];
    final panel = switch (_section) {
      'cards' => _section$(
        Symbols.style_rounded,
        t.label('cards', 'Cards'),
        cards.length + supports.length,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _cardGrid(t.label('memberCards', 'Member cards'), 'cards', cards),
            _cardGrid(
              t.label('supportCards', 'Support cards'),
              'support-cards',
              supports,
            ),
          ],
        ),
      ),
      'stamps' => _section$(
        Symbols.sticky_note_2_rounded,
        t.label('stamps', 'Stamps'),
        stamps.length,
        _grid(
          [
            for (final stamp in stamps)
              Tile(
                title: t.text(stamp['name']),
                subtitle: _ids(stamp).map(_name).join(', '),
                adornments: [
                  for (final other in _ids(stamp).take(3)) ?_face(other),
                ],
                images: [if (stamp['image'] is String) _asset(stamp['image'])],
                onTap: () => openEntity(
                  context,
                  catalogProfiles.firstWhere((p) => p.resource == 'stamps'),
                  stamp.cast<String, Object?>(),
                ),
              ),
          ],
          minWidth: 132,
          small: true,
        ),
      ),
      'voices' => _voices(),
      'story' => _section$(
        Symbols.auto_stories_rounded,
        t.label('story', 'Story'),
        stories.length,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final category in _storyCategories)
              if (stories.where((e) => _storyCategory(e) == category).toList()
                  case final entries when entries.isNotEmpty)
                _storyGrid(t.label('${category}Stories', category), entries),
          ],
        ),
      ),
      'friendships' => _bonds(friendships, stories),
      'missions' => _missions(),
      'live2d' => _section$(
        Symbols.accessibility_new_rounded,
        'Live2D',
        models.length,
        _grid(
          [
            for (final model in models)
              Tile(
                title: '${model['live2dName'] ?? model['title'] ?? ''}',
                subtitle: _name(id),
                adornments: [?_face(id)],
                images: [
                  for (final key in ['image', 'runtime'])
                    if ((model['preview'] as Map?)?[key] case final String path
                        when path.isNotEmpty)
                      _asset(path),
                  for (final key in ['thumbnailImage', 'faceImage'])
                    if (model[key] case final String path) _asset(path),
                ],
                aspectRatio: 3 / 4,
                onTap: () => openLink(
                  context,
                  '/${state.server}/${t.locale}/live2d/${model['live2dKey']}/',
                ),
              ),
          ],
          minWidth: 148,
          aspectRatio: 3 / 4,
        ),
      ),
      'songs' => _section$(
        Symbols.music_note_rounded,
        t.label('songs', 'Songs'),
        songs.length,
        _songGrid(songs),
      ),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_profile(), ?_rankRewards()],
      ),
    };
    final gutter = (MediaQuery.sizeOf(context).width * 0.022).clamp(12.0, 24.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 24, gutter + 10, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ColoredBox(
              color: scheme.surfaceContainerLow,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    for (final (section, icon, label, count) in tabs)
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            foregroundColor: _section == section
                                ? scheme.onSecondaryContainer
                                : scheme.onSurfaceVariant,
                            backgroundColor: _section == section
                                ? scheme.secondaryContainer
                                : Colors.transparent,
                            shape: const StadiumBorder(),
                          ),
                          onPressed: () => setState(() => _section = section),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                icon,
                                size: 18,
                                fill: _section == section ? 1 : 0,
                              ),
                              const SizedBox(width: 8),
                              Text(label),
                              if (count > 0) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.08,
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    '$count',
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            key: PageStorageKey(_section),
            padding: EdgeInsets.fromLTRB(gutter + 2, 17, gutter + 12, 32),
            children: [panel],
          ),
        ),
      ],
    );
  }

  // ---------- Shared pieces ----------

  Widget _section$(IconData icon, String title, int? count, Widget child) =>
      DetailSection(icon: icon, title: title, count: count, child: child);

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Center(
      child: Text(
        t.label('empty', 'No results'),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    ),
  );

  Widget _grid(
    List<Widget> tiles, {
    required double minWidth,
    double aspectRatio = 1,
    bool small = false,
  }) => tiles.isEmpty
      ? _empty()
      : LayoutBuilder(
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

  Widget _group(String title, int count, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '$title  $count',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        child,
      ],
    ),
  );

  Widget _cardGrid(String title, String resource, List<Map> entries) {
    final kit = _kit(resource);
    return _group(
      title,
      entries.length,
      _grid(
        [
          for (final entry in entries.map((e) => e.cast<String, Object?>()))
            Tile(
              title: kit.title(entry),
              subtitle: kit.subtitle(entry),
              adornments: kit.adornments(entry),
              images: kit.images(entry),
              media: kit.cardArtwork(entry),
              aspectRatio: kit.profile.aspectRatio,
              fit: kit.profile.fit,
              onTap: () => openEntity(context, kit.profile, entry),
            ),
        ],
        minWidth: kit.profile.minWidth,
        aspectRatio: kit.profile.aspectRatio,
      ),
    );
  }

  Widget _songGrid(List<Map> songs) {
    final kit = _kit('songs');
    final presentation = SongPresentation(t, state.api, widget.visuals);
    return _grid([
      for (final song in songs.map((e) => e.cast<String, Object?>()))
        Tile(
          title: kit.title(song),
          subtitle: presentation.artist(song),
          adornments: presentation.avatars(song),
          images: kit.images(song),
          marks: presentation.marks(song),
          onTap: () => openEntity(context, kit.profile, song),
        ),
    ], minWidth: kit.profile.minWidth);
  }

  Map? _storyChapter(Map entry) => _values(
    aux['stories'],
    'chapters',
  ).where((c) => _num(c['chapterId']) == _num(entry['chapterId'])).firstOrNull;

  Map? _homeSpot(Map entry) => _values(aux['stories'], 'homeSpots')
      .where(
        (spot) => _values(spot['talks']).any(
          (talk) =>
              '${talk['storyKey']}' ==
              '${entry['storyId'] ?? entry['storyKey']}',
        ),
      )
      .firstOrNull;

  Widget _storyGrid(String title, List<Map> entries) => _group(
    title,
    entries.length,
    _grid(
      [
        for (final entry in entries)
          () {
            final category = _storyCategory(entry);
            final chapter = _storyChapter(entry) ?? const {};
            final Object? image;
            if (category == 'home') {
              final spine = _homeSpot(entry)?['spine'];
              image = spine is Map ? spine['backgroundPreview'] : null;
            } else if (category == 'afterlive') {
              image = null;
            } else {
              image =
                  entry['banner'] ??
                  entry['image'] ??
                  chapter['banner'] ??
                  chapter['image'];
            }
            final cast = category == 'afterlive' || category == 'home';
            return Tile(
              title: switch (t.text(entry['title'])) {
                '' => t.text(entry['chapterName']),
                final title => title,
              },
              subtitle: category == 'band' || category == 'tutorial'
                  ? switch (t.text(entry['chapterName'])) {
                      '' => t.text(chapter['chapterName']),
                      final name => name,
                    }
                  : category == 'afterlive'
                  ? '${t.label('friendship', 'Friendship')} ${entry['unlockCharacterFriendshipLevel'] == null ? '—' : 'Lv.${entry['unlockCharacterFriendshipLevel']}'}'
                  : '',
              images: [if (image is String && image.isNotEmpty) _asset(image)],
              aspectRatio: 16 / 9,
              fit: BoxFit.cover,
              media: cast
                  ? StoryFaces(
                      faces: [for (final other in _ids(entry)) ?_face(other)],
                    )
                  : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => StoryReaderScreen(
                    episode: {
                      ...entry.cast<String, Object?>(),
                      'storyKey': entry['storyKey'] ?? entry['storyId'],
                    },
                  ),
                ),
              ),
            );
          }(),
      ],
      minWidth: 220,
      aspectRatio: 16 / 9,
    ),
  );

  Widget _rewardRow(Map row, {String? caption}) {
    final reward = (row['reward'] as Map?) ?? row;
    final reference = reward['reference'] as Map?;
    final resolved = (reward['resolved'] as Map?) ?? const {};
    final name = switch (t.text(reference?['name'] ?? resolved['name'])) {
      '' => '${reward['resourceTypeName'] ?? t.label('rewards', 'Rewards')}',
      final name => name,
    };
    final image = reference?['image'] ?? resolved['image'];
    final linked = reference != null && reference['id'] != null;
    return InkWell(
      onTap: linked
          ? () => openLink(
              context,
              '/${state.server}/${t.locale}/${reference['resource'] == 'cards' ? 'member-cards' : reference['resource']}/${reference['id']}/',
            )
          : null,
      borderRadius: BorderRadius.circular(Corner.medium),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 36,
              child: image is String && image.isNotEmpty
                  ? AppImage(candidates: [_asset(image)])
                  : Icon(
                      Symbols.redeem_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, style: theme.textTheme.titleSmall),
                  if (caption != null)
                    Text(
                      caption,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              '×${number(reward['resourceCount'])}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Profile ----------

  Widget _profile() {
    final name = t.text(item['characterName']);
    final alternate = t.text(item['englishName']);
    final voice = t
        .text(item['voiceActor'])
        .replaceFirst(RegExp(r'^CV\s*[.．:：]\s*', caseSensitive: false), '');
    final catchCopy = t.text(item['catchCopy']);
    final description = t.text(item['description']).replaceAll('\r', '');
    final part = '${item['bandPart'] ?? ''}';
    final logo = widget.visuals?.bandLogo(item['bandId']);
    final format = ValueFormat(t);
    final profile = catalogProfiles.firstWhere(
      (p) => p.resource == 'characters',
    );
    final fields = [
      if (t.text(
            item['bandName'] ??
                widget.visuals?.bands[item['bandId']]?['bandName'],
          )
          case final band when band.isNotEmpty)
        (t.label('band', 'Band'), band),
      for (final key in profile.detail)
        if (!const {'voiceActor', 'bandPart', 'englishName'}.contains(key))
          if (item[key] case final value?)
            if (format.format(key, value).trim() case final text
                when text.isNotEmpty)
              (t.label(key, key), text),
    ];
    final accent = switch ('${item['colorCode'] ?? ''}'.replaceFirst('#', '')) {
      final String hex when hex.length == 6 => Color(
        0xFF000000 | (int.tryParse(hex, radix: 16) ?? 0),
      ),
      _ => scheme.primaryContainer,
    };
    final portraits = characterPortraits[id] ?? const <CharacterPortrait>[];
    final entries = [
      for (final (index, portrait) in portraits.indexed)
        GalleryImage(
          _asset(portrait.source),
          '${t('media.images.fields.portrait', 'Portrait')} ${(index + 1).toString().padLeft(2, '0')}',
          localized: false,
          sourceSize: Size(portrait.width, portrait.height),
          bounds: Rect.fromLTWH(
            portrait.bounds[0],
            portrait.bounds[1],
            portrait.bounds[2],
            portrait.bounds[3],
          ),
        ),
    ];
    final images = [for (final entry in entries) entry.url];
    final viewport = MediaQuery.sizeOf(context).width;
    final wide = viewport >= 840;
    final visual = CustomPaint(
      painter: _Stripes(accent, scheme.surface.withValues(alpha: 0.24)),
      child: Padding(
        padding: wide
            ? const EdgeInsets.fromLTRB(12, 24, 12, 16)
            : const EdgeInsets.all(16),
        child: images.isEmpty
            ? const SizedBox(height: 240)
            : ImageGallery(
                images: images,
                entries: entries,
                stageHeight: wide
                    ? (viewport * 0.68).clamp(720.0, 940.0)
                    : (MediaQuery.sizeOf(context).height * 0.65).clamp(
                        0.0,
                        640.0,
                      ),
                aspectRatio: 3 / 4,
                framed: false,
              ),
      ),
    );
    final body = Padding(
      padding: EdgeInsets.all((viewport * 0.04).clamp(24.0, 64.0)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (logo != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Padding(
                padding: EdgeInsets.only(bottom: wide ? 24 : 20),
                child: SizedBox(
                  width: wide ? 128 : 112,
                  height: wide ? 64 : 56,
                  child: AppImage(
                    candidates: [logo],
                    alignment: Alignment.centerRight,
                  ),
                ),
              ),
            ),
          if (part.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                part,
                style: const TextStyle(
                  fontSize: 28,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.68,
                ),
              ),
            ),
          Text(
            name,
            style: TextStyle(
              fontSize: wide
                  ? (viewport * 0.032).clamp(28.0, 48.0)
                  : (viewport * 0.07).clamp(26.0, 36.0),
              height: 1.25,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
          if (alternate.isNotEmpty && alternate != name)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                alternate,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.84,
                ),
              ),
            ),
          if (voice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text: 'CV. ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    TextSpan(text: voice),
                  ],
                ),
                style: const TextStyle(
                  fontSize: 24,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.96,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Divider(height: 1, color: scheme.outlineVariant),
          ),
          if (catchCopy.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                '\n$catchCopy',
                style: TextStyle(
                  fontSize: 18,
                  height: 1.7,
                  fontWeight: FontWeight.w500,
                  color: scheme.primary,
                ),
              ),
            ),
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 28),
              child: Text(
                '\n$description',
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.9,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          for (final (label, value) in fields)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.65,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 10,
                    child: Text(
                      value,
                      style: const TextStyle(fontSize: 14, height: 1.65),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Material(
        color: scheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(
            wide ? Corner.extraLarge : Corner.large,
          ),
        ),
        child: wide
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 85, child: visual),
                    Expanded(flex: 115, child: body),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [visual, body],
              ),
      ),
    );
  }

  Widget? _rankRewards() {
    final associations = (aux['associations'] as Map?) ?? const {};
    final ranks = _values(associations['ranks'])..sort(_by('rank'));
    if (ranks.isEmpty) return null;
    final selected = ranks.firstWhere(
      (r) => _num(r['rank']) == _rank,
      orElse: () => ranks.first,
    );
    final rank = _num(selected['rank']).toInt();
    final rewards = _values(associations['rewards'])
        .where((r) => _num(r['rank']) == rank)
        .toList();
    return DetailSection(
      icon: Symbols.redeem_rounded,
      title: t.label('characterRankRewards', 'Character rank rewards'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LevelSwitch(
            label: t.label('rank', 'Rank'),
            levels: [for (final r in ranks) _num(r['rank']).toInt()],
            value: rank,
            onChanged: (value) => setState(() => _rank = value),
          ),
          SpecList(
            facts: [
              Fact(t.label('exp', 'EXP'), number(selected['exp'])),
              Fact(t.label('bonus', 'Bonus'), number(selected['bonus'])),
            ],
          ),
          const SizedBox(height: 8),
          for (final row in rewards) _rewardRow(row),
        ],
      ),
    );
  }

  // ---------- Voices ----------

  Widget _voices() {
    final future = _load('voices');
    return FutureBuilder(
      future: future,
      builder: (context, snapshot) {
        if (future != null && !snapshot.hasData && !snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final entries =
            _values(snapshot.data)
                .map(preferredVoiceRecording)
                .where((e) => _ids(e).contains(id))
                .toList()
              ..sort((a, b) => compareVoices(a, b, id));
        if (entries.isEmpty) return _empty();
        String v(String key, [Object? value]) =>
            t('media.voice.$key', key, {'0': value});
        String title(Map entry) {
          final birthdayId = _num(entry['birthdayCharacterId']).toInt();
          if (birthdayId > 0) return v('birthdayOf', _name(birthdayId));
          final rank = _num(entry['scoreRank']).toInt();
          final type = entry['masterType'];
          return [
            switch (t.text(entry['title'])) {
              '' => v(voiceKind(entry)),
              final title => title,
            },
            if (type == 1 && entry['characterVoiceType'] == 7 && rank > 0)
              const ['', 'E', 'D', 'C', 'B', 'A', 'S', 'SS'][rank.clamp(0, 7)],
            if (type == 5 || type == 6)
              if (entry['dialogueCallType'] == 1)
                v('call')
              else if (entry['dialogueCallType'] == 2)
                v('response'),
            if (type == 6 || voiceKind(entry) == 'resultPair')
              _ids(entry).map(_name).join(' → '),
          ].where((s) => s.isNotEmpty).join(' / ');
        }

        String condition(Map entry) {
          final year = _num(entry['year']).toInt();
          final start = _voiceDate(entry['seasonStartAt'], year);
          final end = _voiceDate(entry['seasonEndAt'], year);
          final season = start.isNotEmpty && end.isNotEmpty && start != end
              ? '$start – $end'
              : start.isNotEmpty
              ? start
              : end;
          final birthday = _character(
            _num(entry['birthdayCharacterId']).toInt(),
          )?['birthday'];
          final date = birthday is Map
              ? _voiceDate('${birthday['month']}/${birthday['day']}', year)
              : '';
          final unlock = _num(entry['unlockCharacterRank']) > 1
              ? v('unlockRank', entry['unlockCharacterRank'])
              : _num(entry['unlockFriendshipRank']) > 0
              ? v('unlockBond', entry['unlockFriendshipRank'])
              : '';
          return [
            season.isNotEmpty ? season : date,
            if (entry['startAt'] is num && (entry['startAt'] as num) > 0)
              DateFormat.yMMMMd(t.locale).format(
                DateTime.fromMillisecondsSinceEpoch(
                  (entry['startAt'] as num).toInt(),
                  isUtc: true,
                ).add(const Duration(hours: 9)),
              ),
            unlock,
          ].where((value) => value.isNotEmpty).join(' / ');
        }

        final audio = _voice;
        return ListenableBuilder(
          listenable: audio,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final group in voiceTabs)
                if (entries.where((e) => voiceTab(e) == group).toList()
                    case final items when items.isNotEmpty)
                  DetailFold(
                    key: ValueKey('voice-group-$group'),
                    title: v('groups.$group'),
                    meta: '${items.length}',
                    open: group == 'comment',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final kind in voiceKinds)
                          if (items.where((e) => voiceKind(e) == kind).toList()
                              case final subset when subset.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Text(
                                v(kind),
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            for (final (position, entry) in subset.indexed) ...[
                              if (position > 0)
                                const SizedBox(height: DialogueRow.spacing),
                              _voiceEntry(
                                entry,
                                title(entry),
                                condition(entry),
                                entry['lines'] is List &&
                                        (entry['lines'] as List).length > 1 ||
                                    position == 0 ||
                                    title(entry) !=
                                        title(subset[position - 1]) ||
                                    condition(entry) !=
                                        condition(subset[position - 1]) ||
                                    entry['cardId'] !=
                                        subset[position - 1]['cardId'],
                                audio,
                                v,
                              ),
                            ],
                          ],
                      ],
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }

  String _voiceDate(Object? value, int year) {
    if (value is! String) return '';
    final match = RegExp(r'^(\d{1,2})/(\d{1,2})$').firstMatch(value);
    if (match == null) return '';
    final month = int.parse(match[1]!);
    final day = int.parse(match[2]!);
    final date = DateTime.utc(year > 0 ? year : 2000, month, day);
    if (date.month != month || date.day != day) return '';
    final locale = t.locale.replaceAll('-', '_');
    return (year > 0 ? DateFormat.yMMMMd(locale) : DateFormat.MMMMd(locale))
        .format(date);
  }

  String _voiceKey(Map entry, int index) =>
      'voice:${entry['voiceKey'] ?? '${entry['masterType']}:${entry['masterId']}'}:$index';

  VoiceClip? _voiceClip(Map entry, int index, Map line) {
    final sound = (line['sound'] as Map?) ?? const {};
    final url = sound['playableUrl'] ?? line['playableUrl'];
    return url is String && url.isNotEmpty
        ? VoiceClip(id: _voiceKey(entry, index), url: _asset(url))
        : null;
  }

  Widget _voiceEntry(
    Map entry,
    String title,
    String condition,
    bool showHeading,
    VoicePlayback audio,
    String Function(String, [Object?]) v,
  ) {
    final lines = entry['lines'] is List ? _values(entry['lines']) : [entry];
    final sequence = lines.length > 1;
    final clips = [
      for (final (index, line) in lines.indexed)
        ?_voiceClip(entry, index, line),
    ];
    final groupActive = clips.any((clip) => audio.isPlaying(clip.id));
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: entry['cardId'] == null && entry['storyId'] == null
              ? null
              : () => openLink(
                  context,
                  '/${entry['sourceServer'] ?? state.server}/${t.locale}/${entry['cardId'] != null ? 'member-cards' : 'stories'}/${entry['cardId'] ?? entry['storyId']}/',
                ),
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: entry['cardId'] == null
                  ? scheme.onSurfaceVariant
                  : scheme.primary,
            ),
          ),
        ),
        if (condition.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            condition,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    return Container(
      padding: sequence ? const EdgeInsets.all(8) : EdgeInsets.zero,
      decoration: sequence
          ? BoxDecoration(
              color: scheme.surfaceContainerLow,
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(Corner.medium),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeading) ...[
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: MediaQuery.sizeOf(context).width < 600 ? 0 : 8,
              ),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  heading,
                  if (sequence)
                    FilledButton.tonalIcon(
                      onPressed: clips.isEmpty
                          ? null
                          : () => groupActive
                                ? audio.stop()
                                : audio.playAll(clips),
                      icon: Icon(
                        groupActive
                            ? Symbols.stop_rounded
                            : Symbols.play_arrow_rounded,
                      ),
                      label: Text(v(groupActive ? 'stop' : 'playGroup')),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (final (index, line) in lines.indexed) ...[
            if (index > 0) const SizedBox(height: DialogueRow.spacing),
            _voiceLine(entry, index, line, audio, v),
          ],
        ],
      ),
    );
  }

  Widget _voiceLine(
    Map entry,
    int index,
    Map line,
    VoicePlayback audio,
    String Function(String, [Object?]) v,
  ) {
    final clip = _voiceClip(entry, index, line);
    final speaker = _num(line['characterId']) > 0
        ? _num(line['characterId']).toInt()
        : (_ids(entry).firstOrNull ?? id);
    final playing = audio.isPlaying(_voiceKey(entry, index));
    final text = t.text(line['text']);
    final face = _num(line['characterId']) > 0 || _ids(entry).length == 1
        ? _face(speaker)
        : null;
    final mark = entry['sourcesComplete'] == true
        ? serverMark({'_servers': entry['sourceServers']}, t.call)
        : null;
    return DialogueRow(
      name: _num(line['characterId']) > 0
          ? _name(speaker)
          : _ids(entry).map(_name).join(' / '),
      marks: mark == null
          ? null
          : Tooltip(
              message: mark.$2,
              child: SvgPicture.asset(mark.$1, width: 20, height: 20),
            ),
      faces: [?face],
      playing: playing,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text.isEmpty
                ? voiceGroup(entry) == 'title'
                      ? v(voiceKind(entry))
                      : v('noText')
                : text.replaceAll('\r', ''),
          ),
          if (clip == null)
            Text(
              v('unavailable'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      action: IconButton(
        tooltip: '${v(playing ? 'stop' : 'playLine')} / ${_name(speaker)}',
        onPressed: clip == null ? null : () => audio.toggle(clip),
        icon: Icon(playing ? Symbols.stop_rounded : Symbols.play_arrow_rounded),
      ),
    );
  }

  // ---------- Bonds ----------

  Widget _bonds(List<Map> friendships, List<Map> stories) {
    final characters = _values(aux['characters'])..sort(_by('displayOrder'));
    final others = characters
        .where((c) => _num(c['characterId']) != id)
        .toList();
    final partner = _partner == -1
        ? 0
        : _partner ?? _num(others.firstOrNull?['characterId']).toInt();
    final friendship = friendships
        .where((e) => _ids(e).contains(partner))
        .firstOrNull;
    final linked = stories
        .where(
          (e) =>
              _storyCategory(e) == 'link' &&
              (partner == 0 || _ids(e).contains(partner)),
        )
        .toList();
    final rewards = _values(friendship?['rewards']);
    final bands = {
      for (final c in characters)
        if (_num(c['bandId']) > 0) _num(c['bandId']).toInt(),
    }.toList();
    final selected = characters
        .where((c) => _num(c['characterId']) == (partner == 0 ? id : partner))
        .firstOrNull;
    final band = _band ?? _num(selected?['bandId'] ?? item['bandId']).toInt();
    final partners = others.where((c) => _num(c['bandId']) == band).toList();
    final sameBand = _num(item['bandId']) == band;
    return _section$(
      Symbols.handshake_rounded,
      t.label('characterBonds', 'Character Bonds'),
      friendships.length,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                for (final other in bands)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Material(
                      color: band == other
                          ? scheme.secondaryContainer
                          : scheme.surfaceContainer,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(
                          width: 2,
                          color: band == other
                              ? scheme.primary
                              : Colors.transparent,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => setState(() => _band = other),
                        child: Container(
                          constraints: const BoxConstraints(
                            minWidth: 64,
                            minHeight: 48,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          alignment: Alignment.center,
                          child: switch (widget.visuals?.bandLogo(other)) {
                            final String logo => SizedBox(
                              height: 32,
                              width: 96,
                              child: AppImage(candidates: [logo]),
                            ),
                            _ => Text('$other'),
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _FriendshipBoard(
            root:
                'https://haneoka.org/assets/${state.server}/Assets/AddressableResources',
            band: band,
            lead: id,
            sameBand: sameBand,
            partners: [
              for (final c in partners)
                (_num(c['characterId']).toInt(), t.text(c['characterName'])),
            ],
            selected: partner,
            onSelected: (value) => setState(() {
              _partner = partner == value ? -1 : value;
            }),
          ),
          if (friendship != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Material(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(Corner.large),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => openLink(context, '/catalog/stories/link'),
                  child: Row(
                    children: [
                      if (friendship['storyBanner'] case final String banner)
                        SizedBox(
                          width: 144,
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: AppImage(
                              candidates: [_asset(banner)],
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${_name(id)} × ${_name(partner)}',
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              t.label('characterBonds', 'Character Bonds'),
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
              ),
            ),
          if (linked.isNotEmpty)
            _section$(
              Symbols.auto_stories_rounded,
              t.label('story', 'Story'),
              linked.length,
              _grid(
                [
                  for (final entry in linked)
                    Tile(
                      title: t.text(entry['title']),
                      subtitle: '',
                      images: [
                        for (final key in ['banner', 'image'])
                          if (entry[key] case final String path) _asset(path),
                      ],
                      aspectRatio: 16 / 9,
                      fit: BoxFit.cover,
                      media: entry['banner'] == null && entry['image'] == null
                          ? StoryFaces(
                              faces: [
                                for (final other in _ids(entry)) ?_face(other),
                              ],
                            )
                          : null,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => StoryReaderScreen(
                            episode: {
                              ...entry.cast<String, Object?>(),
                              'storyKey': entry['storyKey'] ?? entry['storyId'],
                            },
                          ),
                        ),
                      ),
                    ),
                ],
                minWidth: 220,
                aspectRatio: 16 / 9,
              ),
            ),
          if (rewards.isNotEmpty)
            _section$(
              Symbols.redeem_rounded,
              t.label('rewards', 'Rewards'),
              rewards.length,
              Column(
                children: [
                  for (final row in rewards)
                    _rewardRow(
                      row,
                      caption:
                          '${t.label('friendship', 'Friendship')} ${row['rank'] ?? ''}',
                    ),
                ],
              ),
            ),
          if (friendship == null && linked.isEmpty && rewards.isEmpty) _empty(),
        ],
      ),
    );
  }

  // ---------- Missions ----------

  Widget _missions() {
    final future = _load('character-missions');
    return FutureBuilder(
      future: future,
      builder: (context, snapshot) {
        if (future != null && !snapshot.hasData && !snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final missions = _values(snapshot.data, 'missions')
          ..sort((a, b) {
            for (final key in ['missionType', 'priority', 'missionId']) {
              final compare = _num(a[key]).compareTo(_num(b[key]));
              if (compare != 0) return compare;
            }
            return 0;
          });
        final groups = <int, List<Map>>{};
        for (final mission in missions) {
          (groups[_num(mission['missionType']).toInt()] ??= []).add(mission);
        }
        final types = groups.keys.toList()..sort();
        final type = types.contains(_missionType)
            ? _missionType
            : (types.firstOrNull ?? 0);
        String typeLabel(int type) {
          final first = groups[type]!.first;
          final title = t.text(first['title']);
          return '${title.isEmpty ? '${first['missionTypeName'] ?? type}' : title} (${groups[type]!.length})';
        }

        final name = t.text(item['characterName']);
        return _section$(
          Symbols.checklist_rounded,
          t.label('missions', 'Missions'),
          missions.length,
          missions.isEmpty
              ? _empty()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownMenu<int>(
                      key: ValueKey(type),
                      expandedInsets: EdgeInsets.zero,
                      label: Text(t.label('type', 'Type')),
                      initialSelection: type,
                      onSelected: (value) =>
                          setState(() => _missionType = value ?? type),
                      dropdownMenuEntries: [
                        for (final value in types)
                          DropdownMenuEntry(
                            value: value,
                            label: typeLabel(value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (final entry in groups[type] ?? const <Map>[])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(switch (t.text(entry['title'])) {
                                    '' => '${entry['missionTypeName'] ?? ''}',
                                    final title => title,
                                  }, style: theme.textTheme.titleSmall),
                                  Text(
                                    t
                                        .text(entry['description'])
                                        .replaceAll('{CharacterId}', name)
                                        .replaceAll(
                                          '{AchievementCount}',
                                          '${entry['achievementCount'] ?? ''}',
                                        )
                                        .replaceAll(
                                          '{Value}',
                                          '${entry['value'] ?? ''}',
                                        ),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (final reward in _values(entry['rewards']))
                              Padding(
                                padding: const EdgeInsets.only(left: 12),
                                child: Tooltip(
                                  message: switch (t.text(
                                    (reward['resolved'] as Map?)?['name'],
                                  )) {
                                    '' => '${reward['resourceTypeName'] ?? ''}',
                                    final name => name,
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox.square(
                                        dimension: 28,
                                        child: switch ((reward['resolved']
                                            as Map?)?['image']) {
                                          final String image => AppImage(
                                            candidates: [_asset(image)],
                                          ),
                                          _ => Icon(
                                            Symbols.redeem_rounded,
                                            size: 22,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        },
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '×${number(reward['resourceCount'])}',
                                        style: theme.textTheme.titleSmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

/// The profile's accent ground with its five lighter rules
/// (`.character-profile__visual`).
class _Stripes extends CustomPainter {
  _Stripes(this.color, this.rule);
  final Color color;
  final Color rule;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
    final paint = Paint()..color = rule;
    for (var i = 1; i <= 5; i++) {
      canvas.drawRect(
        Rect.fromLTWH(size.width * 0.2 * i - 1, 0, 1, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Stripes old) => old.color != color || old.rule != rule;
}

/// The game's friendship photo board (`.story-board`): the lead's sprite in
/// front of the band's board, each partner a portrait with the ribbon that
/// points at it, all placed from the asset's measured coordinates.
class _FriendshipBoard extends StatelessWidget {
  const _FriendshipBoard({
    required this.root,
    required this.band,
    required this.lead,
    required this.sameBand,
    required this.partners,
    required this.selected,
    required this.onSelected,
  });
  final String root;
  final int band;
  final int lead;
  final bool sameBand;
  final List<(int id, String name)> partners;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final view = MediaQuery.sizeOf(context);
    final height = view.width < 600
        ? (view.width * 0.95).clamp(0.0, 420.0)
        : (view.height * 0.46).clamp(240.0, 460.0);
    final slots = sameBand ? _selfSlots : _otherSlots;
    return Container(
      height: height,
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Corner.extraLarge),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      child: AspectRatio(
        aspectRatio: 1312 / 964,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth, h = constraints.maxHeight;
            final portrait = w * 0.2668;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: AppImage(
                    candidates: ['$root/Band/$band/Friendship/photo_board.png'],
                  ),
                ),
                Positioned(
                  left: w * 0.5 - w * 0.7805 / 2,
                  bottom: -h * 0.038,
                  width: w * 0.7805,
                  height: h * 1.0622,
                  child: AppImage(
                    candidates: [
                      '$root/Character/Image/$lead/character_sprite.png',
                    ],
                    alignment: Alignment.bottomCenter,
                  ),
                ),
                if (sameBand)
                  Positioned(
                    left: w * 0.1335,
                    top: h * 0.0892,
                    width: w * 0.1905,
                    height: h * 0.1452,
                    child: AppImage(
                      candidates: ['$root/Band/$band/band_logo.png'],
                    ),
                  ),
                for (final (index, (id, name)) in partners.indexed)
                  () {
                    final slot = slots.elementAtOrNull(index) ?? _otherSlots[0];
                    final rotation = sameBand && band == 2 && index == 0
                        ? 168.146055
                        : slot.$5;
                    final left = w * slot.$1 / 100 - portrait / 2;
                    final top = h * slot.$2 / 100 - portrait / 2;
                    final arrowW = portrait * 0.4571;
                    final arrowH = portrait * 0.2286;
                    return Positioned(
                      left: left,
                      top: top,
                      width: portrait,
                      height: portrait,
                      child: Semantics(
                        button: true,
                        selected: selected == id,
                        label: name,
                        child: GestureDetector(
                          onTap: () => onSelected(id),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                left: portrait * slot.$3 / 100 - arrowW / 2,
                                top: portrait * slot.$4 / 100 - arrowH / 2,
                                width: arrowW,
                                height: arrowH,
                                child: Transform.rotate(
                                  angle: rotation * 3.141592653589793 / 180,
                                  child: AppImage(
                                    candidates: [
                                      '$root/Band/$band/Friendship/FriendshipArrow_1.png',
                                    ],
                                  ),
                                ),
                              ),
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: selected == id
                                        ? const [
                                            BoxShadow(
                                              color: Color(0xFF48DBEA),
                                              blurRadius: 9,
                                              spreadRadius: 1,
                                            ),
                                            BoxShadow(
                                              color: Colors.white,
                                              blurRadius: 2,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: AppImage(
                                    candidates: [
                                      '$root/Character/Image/$id/board_icon.png',
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }(),
              ],
            );
          },
        ),
      ),
    );
  }
}
