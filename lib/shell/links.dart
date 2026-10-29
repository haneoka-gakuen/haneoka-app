import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../catalog/cross_server.dart';
import '../catalog/profiles.dart';
import '../catalog/missions.dart';
import '../core/app_state.dart';
import '../home/announcements.dart';
import '../stories/stories.dart';
import 'page.dart';
import 'routes.dart';
import 'route_paths.dart';
import '../catalog/source_route.dart';

/// The website's entity kinds (`RESOURCE_KINDS`) and the API resource each
/// browses, for addresses like `/intl/ja/events/1/`.
const _kindResources = {
  'circle': 'circle',
  'challenge': 'challenge',
  'arena': 'arena',
  'chat-customizations': 'chat-customizations',
  'songs': 'songs',
  'events': 'events',
  'characters': 'characters',
  'member-cards': 'cards',
  'support-cards': 'support-cards',
  'skills': 'skills',
  'comics': 'comics',
  'gacha': 'gacha',
  'login-campaigns': 'login-campaigns',
  'missions': 'missions',
  'passes': 'passes',
  'tgw-card': 'tgw-card',
  'shop': 'shop',
  'exchange': 'exchange',
  'stamps': 'stamps',
  'stickers': 'stickers',
  'backgrounds': 'backgrounds',
  'items': 'items',
  'band-items': 'band-items',
  'real-lives': 'real-lives',
};

const _servers = {'jp', 'intl'};
const _locales = {'ja', 'en', 'zh-TW', 'zh-CN', 'ko'};

/// Opens a haneoka.org address inside the app: an entity's page, or the
/// collection or tool the address names. Addresses on other sites open in
/// the browser. Returns false when there is nothing to open.
Future<bool> openLink(
  BuildContext context,
  String href, {
  ValueChanged<String>? navigate,
}) async {
  navigate ??= ShellScope.of(context)?.navigate;
  final uri = Uri.tryParse(href);
  if (uri == null) return false;
  if (uri.path.isEmpty && uri.hasFragment) return false;
  if (uri.hasScheme && !const {'http', 'https'}.contains(uri.scheme)) {
    if (!const {'mailto', 'tel', 'sonolus'}.contains(uri.scheme)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  if (uri.host.isNotEmpty && uri.host != 'haneoka.org') {
    return launchUrl(
      uri.hasScheme ? uri : uri.replace(scheme: 'https'),
      mode: LaunchMode.externalApplication,
    );
  }
  final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2 &&
      !_servers.contains(parts.first) &&
      _locales.contains(parts[1])) {
    final source = parts.removeAt(0);
    parts.removeAt(0);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: uri.toString()),
        builder: (_) => NativeCatalogSourceRoute(
          route: Uri(
            path: '/${parts.join('/')}',
            query: uri.hasQuery ? uri.query : null,
          ),
          source: source,
        ),
      ),
    );
    return true;
  }
  final server = parts.isNotEmpty && _servers.contains(parts.first)
      ? parts.removeAt(0)
      : null;
  if (parts.isNotEmpty && _locales.contains(parts.first)) parts.removeAt(0);
  final canonical = canonicalAppPath(
    '/${parts.map(Uri.encodeComponent).join('/')}',
  );
  parts
    ..clear()
    ..addAll(Uri.parse(canonical).pathSegments);
  if (parts.take(2).join('/') == 'account/reset-password' ||
      parts.take(2).join('/') == 'account/app') {
    return launchUrl(
      Uri.parse('https://haneoka.org').resolve(href),
      mode: LaunchMode.externalApplication,
    );
  }
  if (parts.isEmpty) {
    navigate?.call(
      Uri(
        path: '/',
        queryParameters: {...uri.queryParameters, 'server': ?server},
      ).toString(),
    );
    return navigate != null;
  }
  if (parts.first == 'catalog' &&
      const {
        'live2d',
        'spine',
        'help',
        'skills',
        'stories',
      }.contains(parts.elementAtOrNull(1))) {
    final kind = parts[1],
        id =
            parts.elementAtOrNull(2) ??
            uri.queryParameters[kind == 'stories'
                ? 'story'
                : kind == 'skills'
                ? 'skill'
                : 'topic'];
    navigate?.call(
      Uri(
        path:
            '/catalog/$kind${id == null ? '' : '/${Uri.encodeComponent(id)}'}',
        queryParameters: {...uri.queryParameters, 'server': ?server},
        fragment: uri.hasFragment ? uri.fragment : null,
      ).toString(),
    );
    return navigate != null;
  }
  if (parts.take(2).join('/') == 'catalog/songs' &&
      const {'chart', 'ranking'}.contains(parts.elementAtOrNull(3))) {
    navigate?.call(
      Uri(
        path: '/${parts.map(Uri.encodeComponent).join('/')}',
        queryParameters: {...uri.queryParameters, 'server': ?server},
      ).toString(),
    );
    return navigate != null;
  }
  if (parts.first == 'arena' ||
      parts.take(2).join('/') == 'catalog/arena' ||
      parts.first == 'team-builder') {
    final path = parts.first == 'arena'
        ? '/catalog/${parts.join('/')}'
        : '/${parts.join('/')}';
    navigate?.call(
      Uri(
        path: path,
        queryParameters: {...uri.queryParameters, 'server': ?server},
        fragment: uri.hasFragment ? uri.fragment : null,
      ).toString(),
    );
    return navigate != null;
  }
  if (parts.first == 'charts') {
    navigate?.call(
      Uri(
        path: '/charts/${parts.skip(1).join('/')}',
        queryParameters: uri.queryParameters,
      ).toString(),
    );
    return navigate != null;
  }
  if ((parts.first == 'chart-simulator' && uri.queryParameters['id'] != null) ||
      (parts.first == 'stories' &&
          parts.length > 1 &&
          uri.queryParameters['view'] == 'play')) {
    navigate?.call(
      Uri(
        path: '/${parts.join('/')}',
        queryParameters: {...uri.queryParameters, 'server': ?server},
      ).toString(),
    );
    return navigate != null;
  }
  if (parts.length >= 3 &&
      parts.first == 'catalog' &&
      _kindResources.containsKey(parts[1]) &&
      !(parts[1] == 'events' && parts[2] == 'tracker')) {
    parts.removeAt(0);
  }
  if (parts.join('/') == 'events/tracker') {
    navigate?.call('/catalog/events/tracker');
    return navigate != null;
  }
  // Only the entity parameter opens a detail; search/sort/band parameters remain collection state.
  if (parts.length == 2 &&
      parts.first == 'catalog' &&
      _kindResources.containsKey(parts[1])) {
    final parameter = switch (parts[1]) {
      'member-cards' => 'card',
      'support-cards' => 'snap',
      'characters' => 'character',
      'comics' => 'comic',
      'stamps' => 'stamp',
      'stickers' => 'sticker',
      'backgrounds' => 'background',
      'songs' => 'song',
      'events' ||
      'real-lives' ||
      'gacha' ||
      'login-campaigns' ||
      'shop' ||
      'exchange' ||
      'passes' => 'entry',
      _ => 'item',
    };
    final id = uri.queryParameters[parameter];
    if (id != null && id.isNotEmpty) {
      parts
        ..removeAt(0)
        ..add(id);
    }
  }
  if (parts.length == 4 &&
      parts.first == 'community' &&
      const {'gbp', 'sekai'}.contains(parts[1]) &&
      parts[2] == 'stories') {
    final api = AppScope.of(context)
        .providerApi(parts[1] == 'gbp' ? 'bestdori' : 'sekai');
    final story = uri.queryParameters['story'];
    if (story != null && story.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: '/${parts.map(Uri.encodeComponent).join('/')}?${uri.query}',
          ),
          builder: (_) =>
              StoryReaderScreen(episode: {'storyKey': story}, api: api),
        ),
      );
      return true;
    }
    final card = uri.queryParameters['card'];
    if (parts[1] == 'gbp' &&
        parts[3] == 'card' &&
        card != null &&
        card.isNotEmpty) {
      await openStoryCard(context, api, card);
      return true;
    }
  }
  final story = parts.first == 'stories' && parts.length > 1
      ? parts[1]
      : parts.first == 'catalog' && parts.elementAtOrNull(1) == 'stories'
      ? uri.queryParameters['story'] ?? uri.queryParameters['episode']
      : null;
  if (story != null && story.isNotEmpty) {
    final state = AppScope.of(context);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StoryReaderScreen(
          episode: {'storyKey': story},
          api: state.apiFor(server ?? state.server),
        ),
      ),
    );
    return true;
  }
  if (parts.length == 2 &&
      parts.first == 'announcements' &&
      RegExp(r'^[1-9]\d*$').hasMatch(parts[1])) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: '/announcements/${parts[1]}'),
        builder: (_) => AnnouncementScreen(
          entry: {'id': int.parse(parts[1])},
          server: server ?? AppScope.of(context).server,
        ),
      ),
    );
    return true;
  }
  if (const {'song-meta', 'catalog/song-meta'}.contains(parts.join('/'))) {
    navigate?.call(
      Uri(
        path: '/catalog/song-meta',
        queryParameters: {
          ...uri.queryParametersAll,
          if (server != null) 'server': [server],
        },
        fragment: uri.hasFragment ? uri.fragment : null,
      ).toString(),
    );
    return navigate != null;
  }
  if (parts.length == 1 &&
      const {
        'player-ranks',
        'friendship-ranks',
        'band-rating',
        'high-score-rating',
      }.contains(parts.first)) {
    navigate?.call(
      Uri(
        path: '/catalog/${parts.first}',
        queryParameters: {'server': ?server},
      ).toString(),
    );
    return navigate != null;
  }
  final resource = _kindResources[parts.first];
  if (resource != null) {
    final profile = catalogProfiles
        .where((p) => p.resource == resource)
        .firstOrNull;
    if (profile == null) return false;
    if (resource == 'missions' && parts.length >= 2) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: Uri(
              path: '/catalog/missions/${parts[1]}',
              queryParameters: {'server': ?server},
            ).toString(),
          ),
          builder: (_) => MissionDetailScreen(id: parts[1], server: server),
        ),
      );
      return true;
    }
    if (parts.length >= 2) {
      final selected = AppScope.maybeOf(context)?.server;
      openEntity(context, profile, {
        profile.id.first: int.tryParse(parts[1]) ?? parts[1],
        '_key': parts[1],
        if (server != null && server != selected) serverKey: server,
      }, api: server == null ? null : AppScope.of(context).apiFor(server));
      return true;
    }
    navigate?.call(
      Uri(
        path: '/catalog/${parts.first}',
        queryParameters: {...uri.queryParameters, 'server': ?server},
      ).toString(),
    );
    return navigate != null;
  }
  // A playlist is addressed by query: `/community/playlists?playlist=<id>`.
  final playlist = uri.queryParameters['playlist'];
  if (parts.join('/') == 'community/playlists' && playlist != null) {
    parts.add(playlist);
  }
  // A GBP or Project Sekai song: `/community/songs-bestdori/detail/?song=1`.
  final song = uri.queryParameters['song'];
  if (const {
        'community/gbp/songs/detail',
        'community/sekai/songs/detail',
      }.contains(parts.join('/')) &&
      song != null) {
    parts
      ..removeLast()
      ..add(song);
  }
  final route = Uri.parse('/${parts.map(Uri.encodeComponent).join('/')}')
      .replace(
        queryParameters: {...uri.queryParameters, 'server': ?server},
        fragment: uri.hasFragment ? uri.fragment : null,
      )
      .toString();
  if (navigate != null) {
    navigate(route);
    return true;
  }
  return false;
}
