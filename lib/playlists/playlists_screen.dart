import '../core/site_date.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/haneoka_account.dart';
import '../community/community_widgets.dart';
import '../community/reactions.dart';
import '../community/user_screen.dart';
import '../core/app_state.dart';
import '../core/audio.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/shapes.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'library.dart';

const _titleMax = 60;
const _descriptionMax = 1000;
const _trackMax = 500;

String _t(
  BuildContext context,
  String key,
  String fallback, [
  Map<String, Object?> values = const {},
]) => communityLabel(context, 'playlistPage.$key', fallback, values);

String playlistTitle(BuildContext context, Playlist playlist) {
  final title = playlist.title;
  if (title is Map && title['key'] is String) {
    final key = (title['key'] as String).replaceFirst('playlistPage.', '');
    return _t(context, key, switch (key) {
      'newReleases' => 'New releases',
      'gameBgm' => 'Game BGM',
      _ => 'All songs',
    });
  }
  final text = AppScope.of(context).text.text(title);
  return text.isEmpty ? '${title ?? '—'}' : text;
}

String songName(BuildContext context, LibrarySong song) => song.bgm != null
    ? _t(context, 'bgm.${song.bgm}', song.bgm!)
    : AppScope.of(context).songTitle(song.row['musicTitle'] ?? song.title);

String artistOf(BuildContext context, LibrarySong song) {
  final t = AppScope.of(context).text;
  final names = song.performer?.names ?? const [];
  return names.isNotEmpty
      ? names.map(t.text).where((n) => n.isNotEmpty).join(' · ')
      : t.text(song.bandName);
}

Future<Json> _playlistApi(String path, {String method = 'GET', Object? body}) =>
    communityRequest(method, '/api/v1/community/playlists$path', body: body);

/// Shared state of the playlists views: the library and the lists.
class _Hub extends ChangeNotifier {
  _Hub(this.state);
  final AppState state;
  SongLibrary? library;
  List<Playlist> official = [];
  List<Playlist> community = [];
  String? communityCursor;
  String communitySort = 'new';
  bool communityLoading = false;
  List<Playlist> mine = [];
  List<Playlist> liked = [];
  Object? error;

  Future<void> load() async {
    error = null;
    final game = state.api
        .json('/api/v1/garupa/playlists')
        .then(
          (data) => jsonList((data as Map?)?['playlists']),
          onError: (_) => <Json>[],
        );
    loadPersonal();
    loadCommunity(false);
    try {
      final library = await loadSongLibrary(state.server, state.api);
      this.library = library;
      official = officialPlaylists(library, await game);
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  Future<void> loadPersonal() async {
    await HaneokaAccount.instance.load();
    if (!HaneokaAccount.instance.signedIn) {
      mine = [];
      liked = [];
    } else {
      final [created, saved] = await Future.wait([
        _playlistApi('?scope=mine&limit=60')
            .catchError((Object _) => <String, Object?>{}),
        _playlistApi('?scope=liked&limit=60')
            .catchError((Object _) => <String, Object?>{}),
      ]);
      mine = [
        for (final row in jsonList(created['playlists']))
          communityPlaylist(row),
      ];
      liked = [
        for (final row in jsonList(saved['playlists'])) communityPlaylist(row),
      ];
    }
    notifyListeners();
  }

  Future<void> loadCommunity(bool append) async {
    if (communityLoading) return;
    communityLoading = true;
    notifyListeners();
    try {
      final cursor = append && communityCursor != null
          ? '&cursor=${Uri.encodeQueryComponent(communityCursor!)}'
          : '';
      final data = await _playlistApi(
        '?scope=public&sort=$communitySort$cursor',
      );
      final rows = [
        for (final row in jsonList(data['playlists'])) communityPlaylist(row),
      ];
      community = append ? [...community, ...rows] : rows;
      communityCursor = data['nextCursor'] as String?;
    } catch (_) {
      if (!append) community = [];
      communityCursor = null;
    } finally {
      communityLoading = false;
      notifyListeners();
    }
  }

  List<(TrackRef, LibrarySong?)> songsOf(Playlist playlist) => [
    for (final ref in playlist.refs) (ref, library?.byKey[ref.key]),
  ];

  Future<Playlist> complete(Playlist playlist) async {
    if (playlist.complete || playlist.kind != 'community') return playlist;
    final data = await _playlistApi('/${playlist.id}');
    return communityPlaylist(jsonMap(data['playlist']), complete: true);
  }

  /// Queues every playable song, from [start] (`play`).
  Future<bool> play(
    BuildContext context,
    Playlist playlist, [
    LibrarySong? start,
  ]) async {
    final songs = [
      for (final (_, song) in songsOf(playlist))
        if (song != null && song.audio.isNotEmpty) song,
    ];
    if (songs.isEmpty) return false;
    final queue = [
      for (final song in songs)
        Track(
          id: song.key,
          url: song.audio,
          title: songName(context, song),
          subtitle: artistOf(context, song),
          artwork: song.thumb,
        ),
    ];
    final index = start == null
        ? 0
        : songs.indexOf(start).clamp(0, songs.length - 1);
    await state.audio.playQueue(queue, index);
    return true;
  }
}

/// Playlists (`playlist-hub`): haneoka picks, the reader's own, Stage
/// Challenge and in-game lists, and the community's.
class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key, this.open});

  /// A playlist to open once the lists load (`?playlist=`).
  final String? open;
  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  _Hub? _hub;
  String _query = '';
  String _mineTab = 'created';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hub == null) {
      _hub = _Hub(AppScope.of(context));
      _hub!.load().then((_) => _openInitial());
    }
  }

  Future<void> _openInitial() async {
    final id = widget.open;
    if (id == null || !mounted) return;
    final hub = _hub!;
    var playlist = hub.official
        .where((p) => p.id == id || p.aliases.contains(id))
        .firstOrNull;
    if (playlist == null && RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) {
      try {
        final data = await _playlistApi('/$id');
        playlist = communityPlaylist(jsonMap(data['playlist']), complete: true);
      } catch (_) {}
    }
    if (playlist != null && mounted) await _open(playlist);
  }

  @override
  void dispose() {
    _hub?.dispose();
    super.dispose();
  }

  bool _listed(Playlist playlist) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return '${playlistTitle(context, playlist)} ${playlist.owner?.name ?? ''} ${playlist.description ?? ''}'
        .toLowerCase()
        .contains(query);
  }

  Future<void> _open(Playlist playlist) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _PlaylistDetail(hub: _hub!, playlist: playlist),
    ),
  );

  Future<void> _create([
    List<TrackRef> tracks = const [],
    String title = '',
  ]) async {
    if (!await requireSession(context) || !mounted) return;
    final saved = await Navigator.of(context).push<Playlist>(
      MaterialPageRoute(
        builder: (_) =>
            _PlaylistEditor(hub: _hub!, tracks: tracks, title: title),
      ),
    );
    if (saved != null && mounted) {
      await _hub!.loadPersonal();
      if (mounted) await _open(saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = _hub!;
    return ShellPage(
      title: _t(context, 'title', 'Playlists'),
      search: ShellSearch(
        label: _t(context, 'search', 'Search playlists'),
        onChanged: (value) => setState(() => _query = value),
      ),
      body: ListenableBuilder(
        listenable: hub,
        builder: (context, _) {
          final theme = Theme.of(context);
          if (hub.library == null) {
            return Center(
              child: hub.error != null
                  ? FilledButton.tonal(
                      onPressed: hub.load,
                      child: Text(_t(context, 'retry', 'Retry')),
                    )
                  : const CircularProgressIndicator(),
            );
          }
          final featured = hub.official
              .where((p) => p.kind == 'official' && _listed(p))
              .toList();
          final stage = hub.official
              .where((p) => p.group == 'stage-challenge' && _listed(p))
              .toList();
          final other = hub.official
              .where((p) => p.group == 'other' && _listed(p))
              .toList();
          final personal = (_mineTab == 'created' ? hub.mine : hub.liked)
              .where(_listed)
              .toList();
          final community = hub.community.where(_listed).toList();
          final signedIn = HaneokaAccount.instance.signedIn;
          return ListView(
            padding: pagePadding(context),
            children: [
              _Shelf(
                title: _t(context, 'featured', 'haneoka picks'),
                lists: featured,
                feature: true,
                hub: hub,
                onOpen: _open,
              ),
              if (signedIn)
                _Shelf(
                  title: _t(context, 'mine', 'My playlists'),
                  lists: personal,
                  hub: hub,
                  onOpen: _open,
                  onCreate: _mineTab == 'created' && _query.isEmpty
                      ? () => _create()
                      : null,
                  action: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: 'created',
                        label: Text(_t(context, 'created', 'Created')),
                      ),
                      ButtonSegment(
                        value: 'liked',
                        label: Text(_t(context, 'liked', 'Saved')),
                      ),
                    ],
                    selected: {_mineTab},
                    onSelectionChanged: (v) =>
                        setState(() => _mineTab = v.single),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Material(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(Corner.extraLarge),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final mark = ShapedIcon(
                            shape: MaterialShapes.cookie9Sided,
                            size: 56,
                            child: const Icon(
                              Symbols.library_music_rounded,
                              size: 28,
                            ),
                          );
                          final title = Text(
                            _t(
                              context,
                              'inviteTitle',
                              'Make your own playlists',
                            ),
                            style: theme.textTheme.titleMedium,
                          );
                          final button = FilledButton.tonal(
                            onPressed: () async {
                              await requireSession(context);
                              if (mounted) hub.loadPersonal();
                            },
                            child: Text(_t(context, 'signIn', 'Sign in')),
                          );
                          return constraints.maxWidth >= 600
                              ? Row(
                                  children: [
                                    mark,
                                    const SizedBox(width: 16),
                                    Expanded(child: title),
                                    button,
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    mark,
                                    const SizedBox(height: 16),
                                    title,
                                    const SizedBox(height: 16),
                                    button,
                                  ],
                                );
                        },
                      ),
                    ),
                  ),
                ),
              _Shelf(
                title: _t(context, 'stageChallenges', 'Stage Challenge'),
                lists: stage,
                hub: hub,
                onOpen: _open,
              ),
              _Shelf(
                title: _t(context, 'inGame', 'In game'),
                lists: other,
                hub: hub,
                onOpen: _open,
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _t(context, 'community', 'Community playlists'),
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: 'new',
                        label: Text(_t(context, 'sortNew', 'Newest')),
                      ),
                      ButtonSegment(
                        value: 'popular',
                        label: Text(_t(context, 'sortPopular', 'Popular')),
                      ),
                    ],
                    selected: {hub.communitySort},
                    onSelectionChanged: (v) {
                      hub.communitySort = v.single;
                      hub.loadCommunity(false);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (community.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: hub.communityLoading
                        ? const CircularProgressIndicator()
                        : Text(
                            _query.isNotEmpty
                                ? _t(
                                    context,
                                    'noResults',
                                    'No matching playlists',
                                  )
                                : _t(
                                    context,
                                    'communityEmpty',
                                    'No community playlists yet',
                                  ),
                          ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = ((constraints.maxWidth + 16) / 200)
                        .floor()
                        .clamp(2, 6);
                    final width =
                        (constraints.maxWidth - 16 * (columns - 1)) / columns;
                    return Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        for (final playlist in community)
                          SizedBox(
                            width: width,
                            child: _Card(
                              playlist: playlist,
                              hub: hub,
                              onOpen: _open,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              if (hub.communityCursor != null && _query.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: FilledButton.tonal(
                      onPressed: hub.communityLoading
                          ? null
                          : () => hub.loadCommunity(true),
                      child: Text(_t(context, 'loadMore', 'Load more')),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A playlist's square cover: one jacket, a mosaic of four, or a band logo
/// over its newest jacket (`cover`).
class PlaylistCoverArt extends StatelessWidget {
  const PlaylistCoverArt({
    super.key,
    required this.playlist,
    required this.library,
  });
  final Playlist playlist;
  final SongLibrary? library;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final images = coverImages(playlist, library);
    final logo = playlist.cover.kind == 'band' ? playlist.cover.logo : null;
    Widget image(String url) =>
        AppImage(candidates: [url], fit: BoxFit.cover, localized: false);
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Corner.large),
        child: Container(
          color: scheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (images.mosaic.isNotEmpty)
                GridView.count(
                  crossAxisCount: 2,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: [for (final url in images.mosaic) image(url)],
                )
              else if (images.single != null)
                image(images.single!)
              else if (playlist.cover.url != null)
                image(playlist.cover.url!)
              else
                const Icon(Symbols.queue_music_rounded, size: 40),
              if (logo != null && logo.isNotEmpty)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  height: 40,
                  child: AppImage(
                    candidates: [logo],
                    fit: BoxFit.contain,
                    localized: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.playlist,
    required this.hub,
    required this.onOpen,
    this.feature = false,
  });
  final Playlist playlist;
  final _Hub hub;
  final ValueChanged<Playlist> onOpen;
  final bool feature;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onOpen(playlist),
      borderRadius: BorderRadius.circular(Corner.large),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              PlaylistCoverArt(playlist: playlist, library: hub.library),
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Symbols.music_note_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                      Text(
                        '${playlist.trackCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (playlist.visibility == 'private')
                const Positioned(
                  top: 8,
                  left: 8,
                  child: Icon(
                    Symbols.lock_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            playlistTitle(context, playlist),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: feature
                ? theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.bodyMedium,
          ),
          if (!feature && playlist.kind == 'community')
            _OwnerLine(playlist: playlist),
        ],
      ),
    );
  }
}

class _OwnerLine extends StatelessWidget {
  const _OwnerLine({required this.playlist});
  final Playlist playlist;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (playlist.kind != 'community') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.verified_rounded,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            playlist.kind == 'game'
                ? _t(context, 'inGamePlaylist', 'In-game playlist')
                : _t(context, 'official', 'haneoka picks'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }
    final owner = playlist.owner;
    final name = owner?.name ?? _t(context, 'member', 'Member');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CommunityAvatar(image: owner?.image, name: name, size: 18),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// One row of playlists that scrolls sideways (`shelf`).
class _Shelf extends StatefulWidget {
  const _Shelf({
    required this.title,
    required this.lists,
    required this.hub,
    required this.onOpen,
    this.feature = false,
    this.action,
    this.onCreate,
  });
  final String title;
  final List<Playlist> lists;
  final _Hub hub;
  final ValueChanged<Playlist> onOpen;
  final bool feature;
  final Widget? action;
  final VoidCallback? onCreate;
  @override
  State<_Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<_Shelf> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _page(int direction) => _scroll.animateTo(
    (_scroll.offset + direction * _scroll.position.viewportDimension * 0.85)
        .clamp(0, _scroll.position.maxScrollExtent),
    duration: Durations.medium2,
    curve: Easing.standard,
  );

  @override
  Widget build(BuildContext context) {
    if (widget.lists.isEmpty && widget.onCreate == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final width = widget.feature ? 216.0 : 168.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.title, style: theme.textTheme.headlineSmall),
              ),
              ?widget.action,
              IconButton(
                tooltip: _t(context, 'previous', 'Previous'),
                onPressed: () => _page(-1),
                icon: const Icon(Symbols.chevron_left_rounded),
              ),
              IconButton(
                tooltip: _t(context, 'next', 'Next'),
                onPressed: () => _page(1),
                icon: const Icon(Symbols.chevron_right_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: width + (widget.feature ? 40 : 56),
            child: ListView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              children: [
                if (widget.onCreate != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: SizedBox(
                      width: width,
                      child: InkWell(
                        onTap: widget.onCreate,
                        borderRadius: BorderRadius.circular(Corner.large),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AspectRatio(
                              aspectRatio: 1,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(
                                    Corner.large,
                                  ),
                                ),
                                child: const Icon(
                                  Symbols.add_rounded,
                                  size: 40,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(_t(context, 'create', 'New playlist')),
                          ],
                        ),
                      ),
                    ),
                  ),
                for (final playlist in widget.lists)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: SizedBox(
                      width: width,
                      child: _Card(
                        playlist: playlist,
                        hub: widget.hub,
                        onOpen: widget.onOpen,
                        feature: widget.feature,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A playlist with its songs (`renderDetail`).
class _PlaylistDetail extends StatefulWidget {
  const _PlaylistDetail({required this.hub, required this.playlist});
  final _Hub hub;
  final Playlist playlist;
  @override
  State<_PlaylistDetail> createState() => _PlaylistDetailState();
}

class _PlaylistDetailState extends State<_PlaylistDetail> {
  late Playlist _playlist = widget.playlist;
  bool _descriptionOpen = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_playlist.kind != 'community') return;
    try {
      final data = await _playlistApi('/${_playlist.id}');
      if (mounted) {
        setState(
          () => _playlist = communityPlaylist(
            jsonMap(data['playlist']),
            complete: true,
          ),
        );
      }
    } catch (_) {}
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _toggleLike() async {
    if (!await requireSession(context)) return;
    final liked = !_playlist.viewerLiked;
    try {
      final result = await _playlistApi(
        '/${_playlist.id}/like',
        method: 'PUT',
        body: {'liked': liked},
      );
      if (!mounted) return;
      setState(() {
        _playlist.viewerLiked = result['liked'] == true;
        _playlist.likeCount =
            (result['likeCount'] as num?)?.toInt() ?? _playlist.likeCount;
      });
      widget.hub.loadPersonal();
    } catch (_) {}
  }

  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<Playlist>(
      MaterialPageRoute(
        builder: (_) => _PlaylistEditor(hub: widget.hub, playlist: _playlist),
      ),
    );
    if (!mounted) return;
    if (saved == null) {
      // Deleted, or nothing saved.
      await widget.hub.loadPersonal();
      if (!widget.hub.mine.any((p) => p.id == _playlist.id) && mounted) {
        Navigator.of(context).pop();
      }
      return;
    }
    setState(() => _playlist = saved);
    widget.hub.loadPersonal();
  }

  Future<void> _copy() async {
    if (!await requireSession(context) || !mounted) return;
    final title = _t(context, 'copyTitle', '{title} (copy)', {
      'title': playlistTitle(context, _playlist),
    });
    final saved = await Navigator.of(context).push<Playlist>(
      MaterialPageRoute(
        builder: (_) => _PlaylistEditor(
          hub: widget.hub,
          tracks: _playlist.refs,
          title: title.length > _titleMax
              ? title.substring(0, _titleMax)
              : title,
        ),
      ),
    );
    if (saved != null && mounted) {
      await widget.hub.loadPersonal();
      if (mounted) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => _PlaylistDetail(hub: widget.hub, playlist: saved),
          ),
        );
      }
    }
  }

  Future<void> _addTo(LibrarySong song) async {
    if (!await requireSession(context) || !mounted) return;
    final hub = widget.hub;
    await hub.loadPersonal();
    if (!mounted) return;
    final target = await showModalBottomSheet<Playlist>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Symbols.add_rounded),
            title: Text(_t(context, 'create', 'New playlist')),
            onTap: () => Navigator.pop(
              context,
              Playlist(
                id: '',
                kind: 'community',
                title: '',
                cover: const PlaylistCover('auto'),
                refs: const [],
                trackCount: 0,
                preview: const [],
                complete: true,
              ),
            ),
          ),
          for (final playlist in hub.mine)
            ListTile(
              leading: SizedBox(
                width: 48,
                child: PlaylistCoverArt(
                  playlist: playlist,
                  library: hub.library,
                ),
              ),
              title: Text(playlistTitle(context, playlist)),
              subtitle: Text(
                _t(context, 'songCount', '{count} songs', {
                  'count': playlist.trackCount,
                }),
              ),
              onTap: () => Navigator.pop(context, playlist),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    if (target.id.isEmpty) {
      await Navigator.of(context).push<Playlist>(
        MaterialPageRoute(
          builder: (_) => _PlaylistEditor(hub: hub, tracks: [song.ref]),
        ),
      );
      hub.loadPersonal();
      return;
    }
    try {
      final full = await hub.complete(target);
      if (!mounted) return;
      final title = playlistTitle(context, full);
      if (full.refs.any(
        (r) => r.key == song.ref.key || song.aliases.contains(r.key),
      )) {
        _say(
          _t(context, 'alreadyInPlaylist', 'Already in {title}', {
            'title': title,
          }),
        );
        return;
      }
      if (full.refs.length >= _trackMax) {
        _say(
          _t(
            context,
            'playlistFull',
            'A playlist holds at most {count} songs',
            {'count': _trackMax},
          ),
        );
        return;
      }
      await _playlistApi(
        '/${full.id}',
        method: 'PUT',
        body: _draftBody(
          title: title,
          description: full.description,
          visibility: full.visibility,
          cover: full.cover,
          tracks: [...full.refs, song.ref],
          version: full.version,
        ),
      );
      if (mounted) {
        _say(
          _t(context, 'addedToPlaylist', 'Added to {title}', {'title': title}),
        );
      }
      hub.loadPersonal();
    } catch (_) {
      if (mounted) {
        _say(_t(context, 'unavailable', 'Playlists are unavailable'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub;
    final playlist = _playlist;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppScope.of(context).text;
    final rows = hub.songsOf(playlist);
    final playable = rows.where((r) => r.$2?.audio.isNotEmpty ?? false).length;
    final fromNotes = rows
        .where((r) => r.$2?.ref.provider == 'our-notes')
        .length;
    final fromGbp = rows.where((r) => r.$2?.ref.provider == 'bestdori').length;
    final description = playlist.description?.trim() ?? '';
    final stats = [
      _t(context, 'songCount', '{count} songs', {'count': playlist.trackCount}),
      if (fromNotes > 0 && fromGbp > 0) 'Our Notes $fromNotes · GBP $fromGbp',
      if (playable < rows.length && hub.library != null)
        _t(context, 'playableCount', '{count} playable', {'count': playable}),
      if (playlist.updatedAt > 0)
        _t(context, 'updated', 'Updated {date}', {
          'date': SiteDate.day(t.locale)
              .format(DateTime.fromMillisecondsSinceEpoch(playlist.updatedAt)),
        }),
    ];
    Future<void> play([LibrarySong? start]) async {
      final played = await hub.play(context, playlist, start);
      if (!played && mounted) {
        _say(_t(this.context, 'audioUnavailable', 'No audio'));
      }
    }

    return ShellPage(
      title: playlistTitle(context, playlist),
      actions: [
        if (playlist.kind == 'community')
          BarAction(
            icon: Symbols.share_rounded,
            label: _t(context, 'share', 'Share'),
            onPressed: () {
              Clipboard.setData(
                ClipboardData(
                  text:
                      '$communityOrigin/${t.locale}/community/playlists/?playlist=${playlist.id}',
                ),
              );
              _say(_t(context, 'linkCopied', 'Link copied'));
            },
          ),
      ],
      body: ListView(
        padding: pagePadding(context),
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 600;
              final cover = SizedBox(
                width: wide ? 220 : 180,
                child: PlaylistCoverArt(
                  playlist: playlist,
                  library: hub.library,
                ),
              );
              final copy = Column(
                crossAxisAlignment: wide
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  Text(
                    playlist.visibility == 'private'
                        ? '${_t(context, 'communityPlaylist', 'Playlist')} · ${_t(context, 'private', 'Private')}'
                        : _t(context, 'communityPlaylist', 'Playlist'),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    playlistTitle(context, playlist),
                    textAlign: wide ? TextAlign.start : TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap:
                        playlist.kind == 'community' && playlist.owner != null
                        ? () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CommunityUserScreen(
                                uid: '${playlist.owner!.uid}',
                              ),
                            ),
                          )
                        : null,
                    child: _OwnerLine(playlist: playlist),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () =>
                          setState(() => _descriptionOpen = !_descriptionOpen),
                      child: Text(
                        description,
                        maxLines: _descriptionOpen ? null : 2,
                        overflow: _descriptionOpen
                            ? null
                            : TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(stats.join(' · '), style: theme.textTheme.bodySmall),
                ],
              );
              final actions = Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: wide ? WrapAlignment.start : WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: playable == 0 ? null : play,
                    icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
                    label: Text(_t(context, 'playAll', 'Play all')),
                  ),
                  if (playlist.kind == 'community' &&
                      !playlist.viewerOwns &&
                      playlist.visibility == 'public')
                    (playlist.viewerLiked
                        ? FilledButton.tonalIcon
                        : OutlinedButton.icon)(
                      onPressed: _toggleLike,
                      icon: Icon(
                        Symbols.favorite_rounded,
                        fill: playlist.viewerLiked ? 1 : 0,
                      ),
                      label: Text(
                        '${playlist.viewerLiked ? _t(context, 'collected', 'Saved') : _t(context, 'collect', 'Save')}'
                        '${playlist.likeCount > 0 ? ' · ${playlist.likeCount}' : ''}',
                      ),
                    ),
                  if (playlist.kind == 'community' && playlist.viewerOwns)
                    OutlinedButton.icon(
                      onPressed: _edit,
                      icon: const Icon(Symbols.edit_rounded),
                      label: Text(_t(context, 'edit', 'Edit')),
                    ),
                  if (playlist.id != 'official:bgm')
                    OutlinedButton.icon(
                      onPressed: rows.isEmpty ? null : _copy,
                      icon: const Icon(Symbols.content_copy_rounded),
                      label: Text(
                        _t(context, 'copyToMine', 'Save as my playlist'),
                      ),
                    ),
                ],
              );
              return wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        cover,
                        const SizedBox(width: 24),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              copy,
                              const SizedBox(height: 16),
                              actions,
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        cover,
                        const SizedBox(height: 16),
                        copy,
                        const SizedBox(height: 16),
                        actions,
                      ],
                    );
            },
          ),
          const SizedBox(height: 24),
          if (!playlist.complete)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(_t(context, 'emptyPlaylist', 'No songs yet')),
              ),
            )
          else
            ListenableBuilder(
              listenable: hub.state.audio,
              builder: (context, _) => Column(
                children: [
                  for (final (index, (_, song)) in rows.indexed)
                    _TrackRow(
                      index: index,
                      song: song,
                      playing:
                          song != null &&
                          hub.state.audio.current?.id == song.key,
                      onPlay: song == null ? null : () => play(song),
                      onAdd: song == null || song.bgm != null
                          ? null
                          : () => _addTo(song),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.index,
    required this.song,
    required this.playing,
    this.onPlay,
    this.onAdd,
  });
  final int index;
  final LibrarySong? song;
  final bool playing;
  final VoidCallback? onPlay;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final song = this.song;
    final locale = AppScope.of(context).text.locale;
    final leading = SizedBox(
      width: 32,
      child: Center(
        child: playing
            ? Icon(Symbols.graphic_eq_rounded, size: 18, color: scheme.primary)
            : Text('${index + 1}', style: theme.textTheme.bodyMedium),
      ),
    );
    if (song == null) {
      return ListTile(
        leading: leading,
        title: Text(_t(context, 'songUnavailable', 'Song unavailable')),
        enabled: false,
      );
    }
    return ListTile(
      onTap: song.audio.isEmpty ? null : onPlay,
      contentPadding: const EdgeInsetsDirectional.only(start: 0, end: 4),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(Corner.small),
            child: SizedBox.square(
              dimension: 48,
              child: AppImage(
                candidates: [song.thumb],
                fit: BoxFit.cover,
                localized: false,
              ),
            ),
          ),
        ],
      ),
      title: Text(
        songName(context, song),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: playing ? scheme.primary : null),
      ),
      subtitle: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outline),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              song.ref.provider == 'our-notes' ? 'Our Notes' : 'GBP',
              style: theme.textTheme.labelSmall,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              artistOf(context, song),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: song.bgm != null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: _t(context, 'addToPlaylist', 'Add to playlist'),
                  onPressed: onAdd,
                  icon: const Icon(Symbols.add_rounded),
                ),
                IconButton(
                  tooltip: _t(context, 'songDetails', 'Song details'),
                  onPressed: () =>
                      openLink(context, songDetailPath(song, locale)),
                  icon: const Icon(Symbols.chevron_right_rounded),
                ),
              ],
            ),
    );
  }
}

Map<String, Object?> _draftBody({
  required String title,
  required String? description,
  required String visibility,
  required PlaylistCover cover,
  required List<TrackRef> tracks,
  int? version,
}) => {
  'title': title.trim(),
  'description': (description?.trim().isEmpty ?? true)
      ? null
      : description!.trim(),
  'visibility': visibility,
  'coverKind': cover.kind == 'song' || cover.kind == 'upload'
      ? cover.kind
      : 'auto',
  'coverSong': cover.kind == 'song' ? cover.song?.toJson() : null,
  'coverAttachmentId': cover.kind == 'upload' ? cover.attachmentId : null,
  'tracks': [for (final ref in tracks) ref.toJson()],
  'version': ?version,
};

/// Creating or editing one of the reader's playlists (`renderEditor`).
class _PlaylistEditor extends StatefulWidget {
  const _PlaylistEditor({
    required this.hub,
    this.playlist,
    this.tracks = const [],
    this.title = '',
  });
  final _Hub hub;
  final Playlist? playlist;
  final List<TrackRef> tracks;
  final String title;
  @override
  State<_PlaylistEditor> createState() => _PlaylistEditorState();
}

class _PlaylistEditorState extends State<_PlaylistEditor> {
  late final _title = TextEditingController(
    text: widget.playlist == null
        ? widget.title
        : playlistTitle(context, widget.playlist!),
  );
  late final _description = TextEditingController(
    text: widget.playlist?.description ?? '',
  );
  late String _visibility = widget.playlist?.visibility ?? 'public';
  late String _coverKind = switch (widget.playlist?.cover.kind) {
    'song' => 'song',
    'upload' => 'upload',
    _ => 'auto',
  };
  late TrackRef? _coverSong = widget.playlist?.cover.song;
  late final List<TrackRef> _tracks = [
    ...(widget.playlist?.refs ?? widget.tracks),
  ];
  bool _saving = false;
  String _error = '';

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(
        () => _error = _t(context, 'titleRequired', 'Give the playlist a name'),
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    final existing = widget.playlist;
    try {
      final data = await _playlistApi(
        existing == null ? '' : '/${existing.id}',
        method: existing == null ? 'POST' : 'PUT',
        body: _draftBody(
          title: _title.text,
          description: _description.text,
          visibility: _visibility,
          cover: PlaylistCover(
            _coverKind,
            song: _coverSong,
            attachmentId: existing?.cover.attachmentId,
          ),
          tracks: _tracks,
          version: existing?.version,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t(context, 'savedToast', 'Playlist saved'))),
      );
      Navigator.of(context)
          .pop(communityPlaylist(jsonMap(data['playlist']), complete: true));
    } on AccountError catch (error) {
      if (mounted) setState(() => _error = error.code);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = _t(context, 'unavailable', 'Playlists are unavailable'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t(context, 'deleteTitle', 'Delete this playlist?')),
        content: Text(
          _t(
            context,
            'deleteBody',
            'It disappears for everyone who saved it. This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t(context, 'cancel', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_t(context, 'deleteAction', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _playlistApi('/${widget.playlist!.id}', method: 'DELETE');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t(context, 'deleted', 'Playlist deleted'))),
      );
      Navigator.of(context).pop();
    } catch (_) {}
  }

  Future<void> _pick() async {
    final picked = await showModalBottomSheet<List<TrackRef>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _SongPicker(library: widget.hub.library!, selected: _tracks),
    );
    if (picked != null) {
      setState(() {
        _tracks
          ..clear()
          ..addAll(picked.take(_trackMax));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub;
    final theme = Theme.of(context);
    final existing = widget.playlist;
    return ShellPage(
      title: existing == null
          ? _t(context, 'create', 'New playlist')
          : _t(context, 'editTitle', 'Edit playlist'),
      actions: [
        if (existing != null)
          BarAction(
            icon: Symbols.delete_rounded,
            label: _t(context, 'delete', 'Delete playlist'),
            onPressed: _delete,
          ),
      ],
      body: ListView(
        padding: pagePadding(context),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _title,
                    maxLength: _titleMax,
                    decoration: InputDecoration(
                      labelText: _t(context, 'name', 'Name'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _description,
                    maxLength: _descriptionMax,
                    minLines: 2,
                    maxLines: 6,
                    decoration: InputDecoration(
                      labelText: _t(context, 'description', 'Description'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  RadioGroup<String>(
                    groupValue: _visibility,
                    onChanged: (v) =>
                        setState(() => _visibility = v ?? 'public'),
                    child: Column(
                      children: [
                        RadioListTile(
                          value: 'public',
                          title: Text(_t(context, 'public', 'Public')),
                          subtitle: Text(
                            _t(
                              context,
                              'publicHint',
                              'Shown in community playlists',
                            ),
                          ),
                        ),
                        RadioListTile(
                          value: 'private',
                          title: Text(_t(context, 'private', 'Private')),
                          subtitle: Text(
                            _t(context, 'privateHint', 'Only you can see it'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _t(context, 'cover', 'Cover'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: 'auto',
                        label: Text(_t(context, 'coverAuto', 'Automatic')),
                      ),
                      ButtonSegment(
                        value: 'song',
                        label: Text(_t(context, 'coverSong', 'Song jacket')),
                      ),
                      if (_coverKind == 'upload')
                        ButtonSegment(
                          value: 'upload',
                          label: Text(_t(context, 'coverUpload', 'Upload')),
                        ),
                    ],
                    selected: {_coverKind},
                    onSelectionChanged: (v) => setState(() {
                      _coverKind = v.single;
                      if (_coverKind == 'song' && _coverSong == null) {
                        _coverSong = _tracks.firstOrNull;
                      }
                    }),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _coverKind == 'song'
                        ? _t(
                            context,
                            'coverSongHint',
                            'Add songs first, then pick one of their jackets.',
                          )
                        : _t(
                            context,
                            'coverAutoHint',
                            'Uses the jackets of the first four songs.',
                          ),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (_coverKind == 'song' && _tracks.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 72,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final ref in _tracks)
                            if (hub.library?.byKey[ref.key] case final song?)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: InkWell(
                                  onTap: () => setState(() => _coverSong = ref),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        width: 3,
                                        color: _coverSong?.key == ref.key
                                            ? theme.colorScheme.primary
                                            : Colors.transparent,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        Corner.small,
                                      ),
                                    ),
                                    child: SizedBox.square(
                                      dimension: 64,
                                      child: AppImage(
                                        candidates: [song.thumb],
                                        fit: BoxFit.cover,
                                        localized: false,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_t(context, 'tracks', 'Tracks')} · ${_tracks.length}',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: hub.library == null ? null : _pick,
                        icon: const Icon(Symbols.add_rounded),
                        label: Text(_t(context, 'addSongs', 'Add songs')),
                      ),
                    ],
                  ),
                  if (_tracks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          _t(
                            context,
                            'emptyEditorBody',
                            'Add songs from Our Notes and GBP.',
                          ),
                        ),
                      ),
                    )
                  else
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      onReorderItem: (from, to) => setState(() {
                        _tracks.insert(to, _tracks.removeAt(from));
                      }),
                      children: [
                        for (final (index, ref) in _tracks.indexed)
                          ListTile(
                            key: ValueKey(ref.key),
                            leading: SizedBox.square(
                              dimension: 40,
                              child: switch (hub.library?.byKey[ref.key]) {
                                final song? => AppImage(
                                  candidates: [song.thumb],
                                  fit: BoxFit.cover,
                                  localized: false,
                                ),
                                null => const Icon(Symbols.music_off_rounded),
                              },
                            ),
                            title: Text(
                              switch (hub.library?.byKey[ref.key]) {
                                final song? => songName(context, song),
                                null => _t(
                                  context,
                                  'songUnavailable',
                                  'Song unavailable',
                                ),
                              },
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: _t(context, 'removeSong', 'Remove'),
                                  onPressed: () =>
                                      setState(() => _tracks.removeAt(index)),
                                  icon: const Icon(Symbols.close_rounded),
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: const Icon(
                                    Symbols.drag_handle_rounded,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Symbols.check_rounded),
                    label: Text(
                      _saving
                          ? _t(context, 'saving', 'Saving…')
                          : _t(context, 'saveAction', 'Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Picking songs from both games, by band or by search (`renderPicker`).
class _SongPicker extends StatefulWidget {
  const _SongPicker({required this.library, required this.selected});
  final SongLibrary library;
  final List<TrackRef> selected;
  @override
  State<_SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends State<_SongPicker> {
  late final List<TrackRef> _selected = [...widget.selected];
  String _query = '';
  String _band = '';

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final t = AppScope.of(context).text;
    final query = _query.trim().toLowerCase();
    final songs = library.songs
        .where((song) {
          if (_band.isNotEmpty && song.bandKey != _band) return false;
          if (query.isEmpty) return true;
          return '${songName(context, song)} ${artistOf(context, song)}'
              .toLowerCase()
              .contains(query);
        })
        .toList()
        .reversed
        .toList();
    final keys = {for (final ref in _selected) ref.key};
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Symbols.search_rounded),
                hintText: _t(context, 'searchSongs', 'Search songs or artists'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(_t(context, 'allBands', 'All')),
                    selected: _band.isEmpty,
                    onSelected: (_) => setState(() => _band = ''),
                  ),
                ),
                for (final band in library.bands)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(t.text(band.name)),
                      selected: _band == band.key,
                      onSelected: (_) => setState(
                        () => _band = _band == band.key ? '' : band.key,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: songs.isEmpty
                ? Center(
                    child: Text(_t(context, 'noSongs', 'No matching songs')),
                  )
                : ListView.builder(
                    itemCount: songs.length,
                    itemBuilder: (context, index) {
                      final song = songs[index];
                      final chosen =
                          keys.contains(song.key) ||
                          song.aliases.any(keys.contains);
                      return CheckboxListTile(
                        value: chosen,
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            if (_selected.length < _trackMax) {
                              _selected.add(song.ref);
                            }
                          } else {
                            _selected.removeWhere(
                              (r) =>
                                  r.key == song.key ||
                                  song.aliases.contains(r.key),
                            );
                          }
                        }),
                        secondary: SizedBox.square(
                          dimension: 40,
                          child: AppImage(
                            candidates: [song.thumb],
                            fit: BoxFit.cover,
                            localized: false,
                          ),
                        ),
                        title: Text(
                          songName(context, song),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          artistOf(context, song),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: Text(
                    '${_t(context, 'done', 'Done')} · ${_selected.length}',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
