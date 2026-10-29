import 'package:flutter/material.dart';

import '../about/about_screen.dart';
import '../about/legal_screen.dart';
import '../about/license_screen.dart';
import '../about/download_screen.dart';
import '../admin/admin_screen.dart';
import '../games/song_guess.dart';
import '../games/song_puzzle.dart';
import '../games/sonolus_screen.dart';
import '../community/editor.dart';
import '../community/charts_screen.dart';
import '../community/feed_screen.dart';
import '../community/post_screen.dart';
import '../community/sections.dart';
import '../community/user_screen.dart';
import '../playlists/playlists_screen.dart';
import '../help/help_screen.dart';
import '../search/search_screen.dart';
import '../tools/assets_screen.dart';
import '../tools/live2d_screen.dart';
import '../tools/song_progress.dart';
import '../tools/spine_screen.dart';
import '../tools/stamp_maker.dart';
import '../chart_editor/editor_screen.dart';
import '../gacha_history/history_page.dart';
import '../catalog/browse.dart';
import '../catalog/cross_server.dart' show serverKey;
import '../catalog/arena_detail.dart';
import '../catalog/missions.dart';
import '../catalog/tgw_card.dart';
import '../catalog/catalog_screen.dart';
import '../catalog/detail_screen.dart';
import '../catalog/hub_screen.dart';
import '../catalog/profiles.dart';
import '../catalog/progression.dart';
import '../catalog/skills.dart';
import '../catalog/song_meta.dart';
import '../catalog/songs.dart';
import '../catalog/studio.dart';
import '../core/api.dart';
import '../core/catalog_source.dart';
import '../core/app_state.dart';
import '../core/provider_api.dart';
import '../home/announcements.dart';
import '../home/calendar.dart';
import '../home/home_screen.dart';
import '../records/player.dart';
import '../records/records.dart' show SongRankingScreen;
import '../stories/stories.dart';
import '../stories/story_sequence_player.dart';
import '../stories/offline_stories.dart';
import '../rendering/native_chart_player_screen.dart';
import '../rendering/provider_chart_screen.dart';
import '../team_builder/team_builder_screen.dart';
import '../records/tracker.dart';
import '../home/join.dart';
import '../ui/import_screen.dart';
import 'page.dart';
import 'route_paths.dart';
import 'settings_screen.dart';

/// The website's catalogue routes and the API resource each one browses.
const catalogRoutes = {
  '/catalog/circle': 'circle',
  '/catalog/challenge': 'challenge',
  '/catalog/arena': 'arena',
  '/catalog/chat-customizations': 'chat-customizations',
  '/catalog/songs': 'songs',
  '/catalog/events': 'events',
  '/catalog/characters': 'characters',
  '/catalog/member-cards': 'cards',
  '/catalog/support-cards': 'support-cards',
  '/catalog/comics': 'comics',
  '/catalog/gacha': 'gacha',
  '/catalog/login-campaigns': 'login-campaigns',
  '/catalog/missions': 'missions',
  '/catalog/passes': 'passes',
  '/catalog/tgw-card': 'tgw-card',
  '/catalog/shop': 'shop',
  '/catalog/exchange': 'exchange',
  '/catalog/stamps': 'stamps',
  '/catalog/stickers': 'stickers',
  '/catalog/backgrounds': 'backgrounds',
  '/catalog/items': 'items',
  '/catalog/band-items': 'band-items',
  '/catalog/real-lives': 'real-lives',
};

void openEntity(
  BuildContext context,
  CatalogProfile profile,
  Map<String, Object?> item, {
  List<Map<String, Object?>>? siblings,
  HaneokaApi? api,
}) {
  final baseApi = api ?? CatalogSourceScope.apiOf(context);
  final itemServer = item[serverKey];
  final selectedApi =
      baseApi is! ProviderApi &&
          itemServer is String &&
          const {'jp', 'intl'}.contains(itemServer)
      ? AppScope.of(context).apiFor(itemServer)
      : baseApi;
  final list = siblings ?? BrowseSiblings.of(context);
  final id = '${firstOf(item, profile.id) ?? item['_key']}';
  final kind = profile.resource == 'cards' ? 'member-cards' : profile.resource;
  final path = selectedApi is ProviderApi
      ? selectedApi.provider == 'sekai'
            ? '/community/sekai/songs'
            : '/community/gbp/songs'
      : '/catalog/$kind';
  if (profile.resource == 'arena') {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: '/catalog/arena/$id'),
        builder: (_) => ArenaScreen(seasonId: id, server: selectedApi.server),
      ),
    );
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: '$path/${Uri.encodeComponent(id)}'),
      builder: (_) => CatalogSourceScope(
        api: selectedApi,
        child: DetailScreen(
          profile: profile,
          id: '${firstOf(item, profile.id) ?? item['_key']}',
          summary: item,
          siblings: list,
          api: selectedApi,
        ),
      ),
    ),
  );
}

/// The community's feeds by address and the scope each reads.
const _communityFeeds = {
  '/community/feeds': 'recommended',
  '/community/latest': 'latest',
  '/community/following': 'following',
  '/community/mine': 'mine',
  '/community/bookmarks': 'bookmarked',
};

/// The native screen for a website route, or null while it is being built.
Widget? screenFor(String route, {required ValueChanged<String> navigate}) {
  if (Uri.parse(route).path == '/offline/stories') {
    return const OfflineStoriesScreen();
  }
  final uri = Uri.parse(route);
  route = canonicalAppPath(uri.path);
  final server = uri.queryParameters['server'];
  if (const {'jp', 'intl'}.contains(server) &&
      (route == '/' ||
          route == '/calendar' ||
          route == '/announcements' ||
          route.startsWith('/catalog/')) &&
      !route.startsWith('/catalog/arena') &&
      route != '/catalog/song-meta' &&
      !progressionPages.containsKey(route.split('/').last) &&
      !route.startsWith('/catalog/missions/') &&
      uri.queryParameters['view'] != 'play' &&
      !RegExp(r'^/catalog/songs/[^/]+/(chart|ranking)$').hasMatch(route)) {
    final query = {...uri.queryParameters}..remove('server');
    final childRoute = uri
        .replace(path: route, queryParameters: query)
        .toString();
    return Builder(
      builder: (context) => CatalogSourceScope(
        api: AppScope.of(context).apiFor(server!),
        child: Builder(
          builder: (_) =>
              screenFor(childRoute, navigate: navigate) ??
              const PendingScreen(label: 'common.states.unavailable'),
        ),
      ),
    );
  }

  if (uri.path == '/admin' || uri.path.startsWith('/admin/')) {
    return AdminScreen(
      section:
          uri.path.split('/').where((p) => p.isNotEmpty).skip(1).firstOrNull ??
          'overview',
      query: uri.queryParameters,
    );
  }
  final providerChart = RegExp(r'^/community/(gbp|sekai)/songs/(\d+)/?$')
      .firstMatch(uri.path);
  if (providerChart != null && uri.queryParameters['chart'] == '1') {
    return ProviderChartScreen(
      provider: providerChart[1] == 'gbp' ? 'bestdori' : 'sekai',
      songId: providerChart[2]!,
      difficulty: uri.queryParameters['difficulty'] ?? '3',
      region: uri.queryParameters['region'],
    );
  }
  if (uri.path.replaceFirst(RegExp(r'/+$'), '') == '/download') {
    return const DownloadScreen();
  }
  if (uri.path.replaceFirst(RegExp(r'/+$'), '') == '/license') {
    return const AppLicenseScreen();
  }
  final chartRoute = uri.path
      .replaceFirst(RegExp(r'^/charts'), '/community/charts')
      .replaceFirst(RegExp(r'/+$'), '');
  if (chartRoute == '/community/charts') {
    return CommunityChartsScreen(mine: uri.queryParameters['scope'] == 'mine');
  }
  final chartPage = RegExp(r'^/community/charts/([0-9a-f-]{36})(/chart)?$')
      .firstMatch(chartRoute);
  if (chartPage != null) {
    return CommunityChartScreen(
      id: chartPage[1]!,
      playerOnly: chartPage[2] != null,
      revision: int.tryParse(uri.queryParameters['revision'] ?? ''),
      draft: uri.queryParameters['draft'] == '1',
    );
  }
  if (uri.path == '/chart-editor' || uri.path.startsWith('/chart-editor/')) {
    return ChartEditorScreen(
      key: ValueKey(uri.toString()),
      initialQuery: uri.queryParameters,
    );
  }
  if (uri.path == '/chart-simulator' && uri.queryParameters['id'] != null) {
    return NativeChartPlayerScreen(
      songId: uri.queryParameters['id'],
      server: uri.queryParameters['server'],
      difficulty: chartDifficulty(uri.queryParameters['difficulty']),
    );
  }
  final songChild = RegExp(r'^/catalog/songs/([^/]+)/(chart|ranking)/?$')
      .firstMatch(route);
  if (songChild != null) {
    if (songChild[2] == 'chart') {
      return NativeChartPlayerScreen(
        songId: songChild[1],
        server: server,
        difficulty: chartDifficulty(uri.queryParameters['difficulty']),
      );
    }
    return Builder(
      builder: (context) => SongRankingScreen(
        songId: songChild[1]!,
        title: AppScope.of(context)
            .text('catalog.rankings.songs.title', 'Ranking'),
        server: server,
      ),
    );
  }
  route = canonicalAppPath(uri.path);
  if (route == '/tools/song-puzzle') route = '/song-puzzle';
  if (route == '/tools/stamp-maker') route = '/stamp-maker';
  if (route == '/') return HomeScreen(onBrowse: navigate);
  if (route == '/settings') return const SettingsScreen();
  if (route == '/catalog') return CatalogHubScreen(navigate: navigate);
  if (route == '/tools' || route == '/games' || route == '/community') {
    return CatalogHubScreen(navigate: navigate, section: route.substring(1));
  }
  final progression = route.split('/').last;
  if (route.startsWith('/catalog/') &&
      progressionPages.containsKey(progression)) {
    return ProgressionScreen(
      key: ValueKey(uri.toString()),
      kind: progression,
      server: uri.queryParameters['server'],
    );
  }
  if (route == '/announcements') return const AnnouncementsScreen();
  if (route == '/calendar') {
    return CalendarScreen(initialQuery: uri.queryParameters);
  }
  if (route == '/join') return const JoinScreen();
  if (route == '/catalog/arena' || route.startsWith('/catalog/arena/')) {
    return ArenaScreen(
      key: ValueKey(uri.toString()),
      server: uri.queryParameters['server'],
      seasonId: route == '/catalog/arena' ? null : route.split('/').last,
      anchor: uri.fragment,
    );
  }
  if (route == '/catalog/song-meta') {
    return SongMetaScreen(
      initialQuery: uri.queryParameters,
      initialQueryAll: uri.queryParametersAll,
      server: uri.queryParameters['server'],
    );
  }
  if (route == '/catalog/skills' || route.startsWith('/catalog/skills/')) {
    return SkillsScreen(
      id: route == '/catalog/skills' ? null : route.split('/').last,
    );
  }
  if (route == '/catalog/missions') return const MissionsScreen();
  if (route == '/catalog/tgw-card') return const TgwCardScreen();
  if (route == '/catalog/studio') return const StudioScreen();
  if (route == '/catalog/events/tracker') {
    return EventTrackerScreen(initialRegion: uri.queryParameters['region']);
  }
  if (route == '/player-profile') return const PlayerProfileScreen();
  if (route == '/account') return const AccountsScreen();
  if (RegExp(r'^/account/(jp|intl)/(\d+)$').firstMatch(route) case final m?) {
    return StoredPlayerScreen(server: m[1]!, profileId: m[2]!);
  }
  if (route == '/about') return const AboutScreen();
  if (route == '/privacy') return const LegalScreen('privacy');
  if (route == '/terms') return const LegalScreen('terms');
  if (route == '/song-progress') return const SongProgressScreen();
  if (route == '/catalog/help' || route.startsWith('/catalog/help/')) {
    return HelpScreen(
      id: route == '/catalog/help' ? null : route.split('/').last,
      initialMode: uri.queryParameters['mode'],
    );
  }
  if (route == '/search') return const SearchScreen();
  if (route == '/song-guess') return const SongGuessScreen();
  if (route == '/sonolus') return const SonolusScreen();
  if (route == '/song-puzzle') return const SongPuzzleScreen();
  if (route == '/catalog/live2d') return const Live2DScreen();
  if (RegExp(r'^/catalog/live2d/([^/]+)/?$').firstMatch(route)
      case final match?) {
    return Live2DModelScreen(
      model: {'live2dKey': Uri.decodeComponent(match[1]!)},
    );
  }
  if (route == '/catalog/assets') return const AssetsScreen();
  if (route == '/catalog/spine') return const SpineScreen();
  if (RegExp(r'^/catalog/spine/([^/]+)/?$').firstMatch(route)
      case final match?) {
    return SpineModelScreen(model: {'id': Uri.decodeComponent(match[1]!)});
  }
  if (route == '/stamp-maker') return const StampMakerScreen();
  if (route == '/gacha-history') {
    return HistoryPage(
      key: ValueKey(uri.fragment),
      initialTab: uri.fragment.isEmpty ? null : uri.fragment,
    );
  }
  if (route == '/team-builder') {
    return TeamBuilderScreen(
      key: ValueKey(uri.toString()),
      server: uri.queryParameters['server'],
      initialTab: uri.queryParameters['tab'],
      returnTab: uri.queryParameters['return'],
      initialLeague: int.tryParse(uri.queryParameters['league'] ?? ''),
    );
  }
  if (route == '/catalog/stories') {
    return CatalogHubScreen(navigate: navigate, section: 'stories');
  }
  if (_communityFeeds[route] case final scope?) {
    return CommunityFeedScreen(key: ValueKey(scope), scope: scope);
  }
  if (route == '/community/posts/new') return const PostEditorScreen();
  if (RegExp(r'^/community/posts/[^/]+/edit$').hasMatch(route)) {
    return CommunityPostEditScreen(id: route.split('/')[3]);
  }
  if (route == '/community/tags') return const CommunityTagsScreen();
  if (route == '/community/playlists') return const PlaylistsScreen();
  if (RegExp(r'^/community/(gbp|sekai)/stories/([a-z]+)$').firstMatch(route)
      case final m?) {
    if (uri.queryParameters['story'] case final story? when story.isNotEmpty) {
      return Builder(
        builder: (context) => StoryReaderScreen(
          episode: {'storyKey': story},
          api: AppScope.of(context)
              .providerApi(m[1] == 'sekai' ? 'sekai' : 'bestdori'),
        ),
      );
    }
    return _ProviderStories(
      key: ValueKey(route),
      provider: m[1] == 'sekai' ? 'sekai' : 'bestdori',
      section: m[2]!,
    );
  }
  if (RegExp(r'^/community/(gbp|sekai)/songs/detail$').firstMatch(route)
      case final m?) {
    if (uri.queryParameters['song'] case final id? when id.isNotEmpty) {
      return _ProviderSong(
        provider: m[1] == 'sekai' ? 'sekai' : 'bestdori',
        id: id,
      );
    }
  }
  if (RegExp(r'^/community/(gbp|sekai)/songs/(\d+)$').firstMatch(route)
      case final m?) {
    return _ProviderSong(
      key: ValueKey(route),
      provider: m[1] == 'sekai' ? 'sekai' : 'bestdori',
      id: m[2]!,
    );
  }
  if (route == '/community/gbp/songs' || route == '/community/sekai/songs') {
    return _ProviderSongs(
      key: ValueKey(route),
      provider: route.contains('sekai') ? 'sekai' : 'bestdori',
    );
  }
  if (route.startsWith('/community/playlists/')) {
    return PlaylistsScreen(
      open: Uri.decodeComponent(
        route.substring('/community/playlists/'.length),
      ),
    );
  }
  if (route == '/community/forums') return const CommunityForumsScreen();
  if (route == '/community/notifications') {
    return const CommunityNotificationsScreen();
  }
  if (route == '/community/activity') return const CommunityActivityScreen();
  if (RegExp(r'^/community/forums/([a-z0-9]+(?:-[a-z0-9]+)*)$')
          .firstMatch(route)
      case final m?) {
    return CommunityForumBySlug(slug: m[1]!);
  }
  if (RegExp(r'^/community/posts/([0-9a-f-]{36})$').firstMatch(route)
      case final m?) {
    return PostScreen(id: m[1]!);
  }
  if (RegExp(r'^/community/users/([1-9]\d{0,15})$').firstMatch(route)
      case final m?) {
    return CommunityUserScreen(uid: m[1]!);
  }
  if (route.startsWith('/stories/')) {
    final id = Uri.decodeComponent(route.substring('/stories/'.length));
    if (uri.queryParameters['view'] == 'play') {
      return StorySequencePlayer(
        key: ValueKey(uri.toString()),
        storyId: id,
        server: uri.queryParameters['server'],
        textModeBuilder: (context, currentId) => StoryReaderScreen(
          episode: {'storyKey': currentId},
          api: AppScope.of(context).apiFor(
            uri.queryParameters['server'] ?? AppScope.of(context).server,
          ),
        ),
      );
    }
    return StoryReaderScreen(episode: {'storyKey': id});
  }
  if (route.startsWith('/catalog/stories/')) {
    final mode = route.substring('/catalog/stories/'.length);
    if (storyModes.contains(mode)) {
      return StoriesScreen(key: ValueKey(mode), mode: mode);
    }
    if (uri.queryParameters['view'] == 'play') {
      return StorySequencePlayer(
        key: ValueKey(uri.toString()),
        storyId: Uri.decodeComponent(mode),
        server: uri.queryParameters['server'],
        textModeBuilder: (context, currentId) => StoryReaderScreen(
          episode: {'storyKey': currentId},
          api: AppScope.of(context).apiFor(
            uri.queryParameters['server'] ?? AppScope.of(context).server,
          ),
        ),
      );
    }
    return StoryReaderScreen(episode: {'storyKey': Uri.decodeComponent(mode)});
  }
  if (route.startsWith('/catalog/missions/')) {
    return MissionDetailScreen(
      id: Uri.decodeComponent(route.substring('/catalog/missions/'.length)),
      server: uri.queryParameters['server'],
    );
  }
  final slash = route.lastIndexOf('/');
  final parent = slash > '/catalog'.length
      ? catalogRoutes[route.substring(0, slash)]
      : null;
  if (parent case final resource?) {
    return DetailScreen(
      key: ValueKey(route),
      profile: catalogProfiles.firstWhere((p) => p.resource == resource),
      id: Uri.decodeComponent(route.substring(slash + 1)),
      summary: const {},
    );
  }
  final resource = catalogRoutes[route];
  if (resource != null) {
    final profile = catalogProfiles.firstWhere((p) => p.resource == resource);
    void open(BuildContext context, Map<String, Object?> item) =>
        openEntity(context, profile, item);
    return profile.presentation == Presentation.song
        ? SongsScreen(onOpen: open)
        : CatalogScreen(profile: profile, onOpen: open);
  }
  return null;
}

/// A route whose native screen is still being written: its title bar and an
/// empty pane, never the website.
class PendingScreen extends StatelessWidget {
  const PendingScreen({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => ShellPage(
    title: AppScope.of(context).text(label),
    body: const SizedBox.expand(),
  );
}

/// GBP or Project Sekai songs on the song catalogue (`origin`).
class _ProviderSongs extends StatelessWidget {
  const _ProviderSongs({super.key, required this.provider});
  final String provider;
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final api = state.providerApi(provider);
    final profile = catalogProfiles.firstWhere((p) => p.resource == 'songs');
    return SongsScreen(
      api: api,
      title: provider == 'sekai'
          ? state.text('community.page.sekai.title', 'Project Sekai songs')
          : state.text('community.page.songsBestDori', 'GBP songs'),
      onOpen: (context, item) => openEntity(context, profile, item, api: api),
    );
  }
}

/// One GBP or Project Sekai song by its address.
class _ProviderSong extends StatelessWidget {
  const _ProviderSong({super.key, required this.provider, required this.id});
  final String provider;
  final String id;
  @override
  Widget build(BuildContext context) => DetailScreen(
    profile: catalogProfiles.firstWhere((p) => p.resource == 'songs'),
    id: id,
    summary: const {},
    api: AppScope.of(context).providerApi(provider),
  );
}

/// GBP or Project Sekai stories of one section (`origin`).
class _ProviderStories extends StatelessWidget {
  const _ProviderStories({
    super.key,
    required this.provider,
    required this.section,
  });
  final String provider;
  final String section;
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final capital = '${section[0].toUpperCase()}${section.substring(1)}';
    return StoriesScreen(
      mode: section,
      api: state.providerApi(provider),
      title: state.text(
        provider == 'sekai'
            ? 'community.page.sekai.stories.$section'
            : 'story.navigation.bestdori$capital',
        section,
      ),
    );
  }
}
