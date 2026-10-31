import 'package:flutter/widgets.dart';

import 'route_paths.dart';

import 'package:material_symbols_icons/symbols.dart';

/// One page in the drawer: the website's route, label and icon
/// (`src/config/navigation.ts`), with its children in the community tree.
class NavItem {
  const NavItem(this.route, this.label, this.icon, [this.children = const []]);
  final String route;
  final String label;
  final IconData icon;
  final List<NavItem> children;
}

int routeMatch(String current, String candidate) {
  var path = canonicalAppPath(Uri.parse(current).path);
  if (path.startsWith('/stories/')) {
    final mode = Uri.parse(current).queryParameters['mode'];
    path = mode == null ? '/catalog/stories' : '/catalog/stories/$mode';
  }
  return path == candidate || candidate != '/' && path.startsWith('$candidate/')
      ? candidate.length
      : -1;
}

NavItem? activeNavigationItem(String route) {
  NavItem? best;
  var score = -1;
  void walk(List<NavItem> items) {
    for (final item in items) {
      final match = routeMatch(route, item.route);
      if (match > score) {
        best = item;
        score = match;
      }
      walk(item.children);
    }
  }

  for (final section in navSections) {
    walk(section.items);
  }
  walk(utilityItems);
  return best;
}

/// A headed group of pages inside a destination (`NavSection`); the
/// archive mirrors fold behind their headline.
class NavSection {
  const NavSection(
    this.id,
    this.label,
    this.icon,
    this.items, {
    this.collapsible = false,
  });
  final String id;
  final String label;
  final IconData icon;
  final List<NavItem> items;
  final bool collapsible;
}

/// A top-level destination (`PRIMARY_DESTINATIONS`): its own page, and the
/// sections that open beneath it in the drawer.
class NavDestination {
  const NavDestination(
    this.id,
    this.route,
    this.label,
    this.icon,
    this.sections,
  );
  final String id;
  final String route;
  final String label;
  final IconData icon;
  final List<NavSection> sections;
}

const _storyRoutes = [
  ('event', Symbols.local_activity_rounded),
  ('band', Symbols.groups_rounded),
  ('link', Symbols.diversity_1_rounded),
  ('birthday', Symbols.cake_rounded),
  ('home', Symbols.home_rounded),
  ('afterlive', Symbols.celebration_rounded),
  ('tutorial', Symbols.school_rounded),
];
const _bestdoriStoryRoutes = [
  ('event', Symbols.event_rounded),
  ('band', Symbols.groups_rounded),
  ('main', Symbols.auto_stories_rounded),
  ('afterlive', Symbols.celebration_rounded),
  ('card', Symbols.style_rounded),
];
const _sekaiStoryRoutes = [
  ('event', Symbols.event_rounded),
  ('unit', Symbols.groups_rounded),
  ('character', Symbols.person_rounded),
  ('card', Symbols.style_rounded),
  ('area', Symbols.map_rounded),
  ('special', Symbols.auto_awesome_rounded),
  ('mysekai', Symbols.chair_rounded),
  ('live', Symbols.mic_rounded),
];

String _capital(String key) => key[0].toUpperCase() + key.substring(1);

/// The website's drawer, in its order. Anon Tokyo is hidden on the website
/// for now (`isTemporarilyHiddenRoute`), so it is here too.
final navSections = <NavSection>[
  const NavSection('home', 'navigation.home', Symbols.home_rounded, [
    NavItem(
      '/announcements',
      'home.announcements.title',
      Symbols.newspaper_rounded,
    ),
    NavItem(
      '/calendar',
      'tools.calendar.title',
      Symbols.calendar_month_rounded,
    ),
    NavItem('/join', 'legal.join.title', Symbols.handshake_rounded),
    NavItem('/sponsor', 'legal.sponsor.title', Symbols.favorite_rounded),
    NavItem('/download', 'download.title', Symbols.download_rounded),
  ]),
  const NavSection('library', 'navigation.library', Symbols.category_rounded, [
    NavItem(
      '/catalog/songs',
      'navigation.songs',
      Symbols.library_music_rounded,
    ),
    NavItem(
      '/catalog/song-meta',
      'catalog.songs.fields.songMeta',
      Symbols.monitoring_rounded,
    ),
    NavItem('/catalog/events', 'navigation.events', Symbols.event_rounded),
    NavItem('/catalog/arena', 'navigation.arena', Symbols.swords_rounded),
    NavItem(
      '/catalog/chat-customizations',
      'navigation.chatCustomizations',
      Symbols.chat_rounded,
    ),
    NavItem(
      '/catalog/events/tracker',
      'tools.eventTracker.title',
      Symbols.leaderboard_rounded,
    ),
    NavItem(
      '/catalog/characters',
      'navigation.characters',
      Symbols.group_rounded,
    ),
    NavItem(
      '/catalog/member-cards',
      'navigation.memberCards',
      Symbols.style_rounded,
    ),
    NavItem(
      '/catalog/support-cards',
      'navigation.supportCards',
      Symbols.collections_rounded,
    ),
    NavItem(
      '/catalog/skills',
      'catalog.cards.fields.skills',
      Symbols.bolt_rounded,
    ),
    NavItem('/catalog/comics', 'navigation.comics', Symbols.menu_book_rounded),
    NavItem('/catalog/gacha', 'navigation.gacha', Symbols.redeem_rounded),
    NavItem(
      '/catalog/login-campaigns',
      'navigation.loginCampaigns',
      Symbols.event_available_rounded,
    ),
    NavItem(
      '/catalog/missions',
      'navigation.systemNavMissions',
      Symbols.fact_check_rounded,
    ),
    NavItem(
      '/catalog/passes',
      'navigation.systemNavPasses',
      Symbols.workspace_premium_rounded,
    ),
    NavItem(
      '/catalog/tgw-card',
      'catalog.tgwCard.card',
      Symbols.credit_card_rounded,
    ),
    NavItem('/catalog/studio', 'catalog.studio.title', Symbols.piano_rounded),
    NavItem(
      '/catalog/player-ranks',
      'catalog.progression.playerRank',
      Symbols.trending_up_rounded,
    ),
    NavItem(
      '/catalog/friendship-ranks',
      'catalog.progression.friendshipRank',
      Symbols.diversity_1_rounded,
    ),
    NavItem(
      '/catalog/band-rating',
      'catalog.progression.bandRating',
      Symbols.monitoring_rounded,
    ),
    NavItem(
      '/catalog/high-score-rating',
      'catalog.progression.highScoreRating',
      Symbols.leaderboard_rounded,
    ),
    NavItem('/catalog/shop', 'navigation.shop', Symbols.storefront_rounded),
    NavItem(
      '/catalog/exchange',
      'navigation.exchange',
      Symbols.swap_horiz_rounded,
    ),
    NavItem(
      '/catalog/stamps',
      'navigation.stamps',
      Symbols.emoji_emotions_rounded,
    ),
    NavItem('/catalog/stickers', 'navigation.stickers', Symbols.style_rounded),
    NavItem(
      '/catalog/backgrounds',
      'navigation.backgrounds',
      Symbols.wallpaper_rounded,
    ),
    NavItem('/catalog/items', 'navigation.items', Symbols.inventory_2_rounded),
    NavItem(
      '/catalog/band-items',
      'navigation.bandItems',
      Symbols.piano_rounded,
    ),
    NavItem(
      '/catalog/real-lives',
      'navigation.realLives',
      Symbols.festival_rounded,
    ),
  ]),
  NavSection('stories', 'navigation.stories', Symbols.auto_stories_rounded, [
    for (final (key, icon) in _storyRoutes)
      NavItem(
        '/catalog/stories/$key',
        key == 'birthday'
            ? 'story.labels.birthdayStory'
            : 'story.navigation.$key',
        icon,
      ),
  ]),
  const NavSection('tools', 'navigation.tools', Symbols.construction_rounded, [
    NavItem('/catalog/live2d', 'navigation.live2d', Symbols.animation_rounded),
    NavItem(
      '/catalog/spine',
      'navigation.spine',
      Symbols.accessibility_new_rounded,
    ),
    NavItem(
      '/catalog/assets',
      'navigation.assets',
      Symbols.folder_open_rounded,
    ),
    NavItem('/catalog/help', 'navigation.help', Symbols.help_rounded),
    NavItem(
      '/player-profile',
      'tools.playerProfile.title',
      Symbols.person_search_rounded,
    ),
    NavItem('/team-builder', 'tools.teamBuilder.title', Symbols.groups_rounded),
    NavItem(
      '/song-progress',
      'catalog.songProgress.title',
      Symbols.check_circle_rounded,
    ),
    NavItem('/stamp-maker', 'tools.stampMaker.title', Symbols.image_rounded),
    NavItem(
      '/gacha-history',
      'catalog.gachaHistory.title',
      Symbols.history_rounded,
    ),
    NavItem(
      '/chart-editor/create',
      'navigation.chartEditor',
      Symbols.edit_rounded,
    ),
  ]),
  const NavSection(
    'games',
    'navigation.games',
    Symbols.sports_esports_rounded,
    [
      NavItem(
        '/sonolus',
        'catalog.sonolus.title',
        Symbols.sports_esports_rounded,
      ),
      NavItem(
        '/song-puzzle',
        'tools.songPuzzle.title',
        Symbols.extension_rounded,
      ),
      NavItem('/song-guess', 'catalog.songGuess.title', Symbols.help_rounded),
    ],
  ),
  const NavSection('community', 'navigation.community', Symbols.forum_rounded, [
    NavItem(
      '/community/feeds',
      'community.page.feedRecommended',
      Symbols.dynamic_feed_rounded,
      [
        NavItem(
          '/community/latest',
          'community.page.feedLatest',
          Symbols.schedule_rounded,
        ),
        NavItem('/community/tags', 'community.page.tags', Symbols.sell_rounded),
      ],
    ),
    NavItem(
      '/community/mine',
      'community.page.navigation.mine',
      Symbols.person_rounded,
      [
        NavItem(
          '/community/following',
          'community.page.feedFollowing',
          Symbols.group_rounded,
        ),
        NavItem(
          '/community/bookmarks',
          'community.page.bookmarks',
          Symbols.bookmarks_rounded,
        ),
        NavItem(
          '/community/notifications',
          'community.page.notifications',
          Symbols.notifications_rounded,
        ),
        NavItem(
          '/community/activity',
          'community.page.activity',
          Symbols.comment_rounded,
        ),
      ],
    ),
    NavItem(
      '/community/playlists',
      'community.page.playlistPage.title',
      Symbols.queue_music_rounded,
    ),
    NavItem(
      '/community/charts',
      'community.charts.title',
      Symbols.music_note_rounded,
    ),
    NavItem(
      '/community/forums',
      'community.page.forums',
      Symbols.forum_rounded,
    ),
  ]),
  NavSection(
    'mirrors',
    'navigation.gbpArchive',
    Symbols.library_music_rounded,
    collapsible: true,
    [
      const NavItem(
        '/community/gbp/songs',
        'community.page.songsBestDori',
        Symbols.library_music_rounded,
      ),
      for (final (key, icon) in _bestdoriStoryRoutes)
        NavItem(
          '/community/gbp/stories/$key',
          'story.navigation.bestdori${_capital(key)}',
          icon,
        ),
    ],
  ),
  NavSection(
    'sekai',
    'navigation.projectSekai',
    Symbols.music_note_rounded,
    collapsible: true,
    [
      const NavItem(
        '/community/sekai/songs',
        'community.page.sekai.title',
        Symbols.library_music_rounded,
      ),
      for (final (key, icon) in _sekaiStoryRoutes)
        NavItem(
          '/community/sekai/stories/$key',
          'community.page.sekai.stories.$key',
          icon,
        ),
    ],
  ),
];

NavSection _section(String id) => navSections.firstWhere((s) => s.id == id);

/// The drawer's destinations, each with the sections it opens.
final navDestinations = <NavDestination>[
  NavDestination('home', '/', 'navigation.home', Symbols.home_rounded, [
    _section('home'),
  ]),
  NavDestination(
    'catalog',
    '/catalog',
    'navigation.catalog',
    Symbols.category_rounded,
    [_section('library')],
  ),
  NavDestination(
    'stories',
    '/catalog/stories',
    'navigation.stories',
    Symbols.auto_stories_rounded,
    [_section('stories')],
  ),
  NavDestination(
    'tools',
    '/tools',
    'navigation.tools',
    Symbols.construction_rounded,
    [_section('tools')],
  ),
  NavDestination(
    'games',
    '/games',
    'navigation.games',
    Symbols.sports_esports_rounded,
    [_section('games')],
  ),
  NavDestination(
    'community',
    '/community',
    'navigation.community',
    Symbols.forum_rounded,
    [_section('community'), _section('mirrors'), _section('sekai')],
  ),
  const NavDestination(
    'search',
    '/search',
    'common.actions.search',
    Symbols.search_rounded,
    [],
  ),
];

/// Below the sections (`UTILITY_DESTINATIONS`).
const utilityItems = [
  NavItem('/account', 'navigation.account', Symbols.account_circle_rounded),
  NavItem('/settings', 'navigation.settings', Symbols.settings_rounded),
  NavItem('/about', 'navigation.about', Symbols.info_rounded),
];

/// Every route, children included, for lookup.
Iterable<NavItem> get allNavItems sync* {
  Iterable<NavItem> walk(List<NavItem> items) sync* {
    for (final item in items) {
      yield item;
      yield* walk(item.children);
    }
  }

  for (final destination in navDestinations) {
    yield NavItem(destination.route, destination.label, destination.icon);
  }
  for (final section in navSections) {
    yield* walk(section.items);
  }
  yield* utilityItems;
  // Linked from Settings and sign-up, not from the drawer.
  yield const NavItem(
    '/privacy',
    'legal.privacy.title',
    Symbols.policy_rounded,
  );
  yield const NavItem('/terms', 'legal.terms.title', Symbols.gavel_rounded);
}
