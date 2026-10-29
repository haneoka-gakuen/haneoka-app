import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// The website's catalogue presentations (`Presentation` in catalog-screen):
/// each decides a tile's subhead, emblems, marks and filters.
enum Presentation {
  song,
  member,
  support,
  character,
  comic,
  stamp,
  item,
  bandItem,
  background,
  system,
  skill,
}

/// How a catalogue resource is shown: the same profiles the website uses.
class CatalogProfile {
  const CatalogProfile({
    required this.resource,
    required this.label,
    required this.icon,
    required this.presentation,
    this.id = const ['id'],
    this.title = const ['title', 'name'],
    this.image = const ['image', 'thumbnail'],
    this.detail = const [],
    this.document,
    this.minWidth = 260,
    this.aspectRatio = 1,
    this.small = false,
    this.fit = BoxFit.contain,
    this.defaultSort = 'id',
    this.descending = true,
  });

  /// The API resource name.
  final String resource;

  /// The website's message path for its name.
  final String label;
  final IconData icon;
  final Presentation presentation;
  final List<String> id, title, image, detail;

  /// The key holding the collection inside the document, when not top level.
  final String? document;

  /// `--tile-min` and `--tile-ratio` of the website's collection.
  final double minWidth;
  final double aspectRatio;

  /// Small symbols take three columns on phones from 390 dp.
  final bool small;
  final BoxFit fit;
  final String defaultSort;
  final bool descending;
}

/// The catalogue, in the website's drawer order.
const catalogProfiles = <CatalogProfile>[
  CatalogProfile(resource: 'circle', label: 'navigation.circle', icon: Symbols.groups_rounded, presentation: Presentation.system, document: 'entries'),
  CatalogProfile(resource: 'challenge', label: 'navigation.challenge', icon: Symbols.swords_rounded, presentation: Presentation.system, document: 'entries'),
  CatalogProfile(
    resource: 'arena',
    label: 'navigation.arena',
    icon: Symbols.swords_rounded,
    presentation: Presentation.system,
    document: 'entries',
    title: ['title'],
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'chat-customizations',
    label: 'navigation.chatCustomizations',
    icon: Symbols.chat_rounded,
    presentation: Presentation.item,
    document: 'entries',
    detail: ['kind', 'initialOwnership'],
  ),
  CatalogProfile(
    resource: 'songs',
    label: 'navigation.songs',
    icon: Symbols.library_music_rounded,
    presentation: Presentation.song,
    id: ['musicId', 'songId', 'id'],
    title: ['musicTitle', 'title', 'name'],
    image: ['jacketUrl', 'jacket', 'jacketThumbUrl', 'thumbnail', 'image'],
    detail: ['bandName', 'composer', 'lyricist', 'arranger', 'publishedAt'],
    minWidth: 160,
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'events',
    label: 'navigation.events',
    icon: Symbols.event_rounded,
    presentation: Presentation.system,
    document: 'entries',
    detail: ['kind', 'startAt', 'endAt'],
    aspectRatio: 16 / 9,

    id: ['id'],
    title: ['title'],
    image: ['image'],
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'characters',
    label: 'navigation.characters',
    icon: Symbols.group_rounded,
    presentation: Presentation.character,
    id: ['characterId', 'id'],
    title: ['characterName', 'name'],
    image: ['thumbnailImage', 'profileImage', 'faceImage', 'image'],
    detail: [
      'birthday',
      'height',
      'school',
      'schoolClass',
      'constellation',
      'favoriteFood',
      'hobby',
    ],
    minWidth: 148,
    aspectRatio: 3 / 4,

    small: true,
    defaultSort: 'order',
    descending: false,
  ),
  CatalogProfile(
    resource: 'cards',
    label: 'navigation.memberCards',
    icon: Symbols.style_rounded,
    presentation: Presentation.member,
    id: ['cardId', 'id'],
    title: ['prefix', 'cardName', 'name'],
    image: ['images.thumbnail', 'thumbnail', 'image'],
    detail: ['rarity', 'cardType', 'releasedAt'],
    minWidth: 172,
    aspectRatio: 3 / 4,
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'support-cards',
    label: 'navigation.supportCards',
    icon: Symbols.collections_rounded,
    presentation: Presentation.support,
    id: ['supportCardId', 'id'],
    title: ['prefix', 'cardName', 'name'],
    image: ['images.thumbnail', 'thumbnail', 'image'],
    detail: ['rarity', 'cardType', 'releasedAt'],
    minWidth: 172,
    aspectRatio: 16 / 9,
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'skills',
    label: 'catalog.cards.fields.skills',
    icon: Symbols.bolt_rounded,
    presentation: Presentation.skill,
    title: ['skillName', 'name', 'title'],
    image: ['icon', 'image'],
    minWidth: 132,
    small: true,
    descending: false,
  ),
  CatalogProfile(
    resource: 'comics',
    label: 'navigation.comics',
    icon: Symbols.menu_book_rounded,
    presentation: Presentation.comic,
    id: ['comicId', 'id'],
    image: ['thumbnail', 'image'],
    detail: ['subTitle', 'characterIds', 'publicStartAt'],
    minWidth: 240,
    aspectRatio: 4 / 3,
    title: ['title', 'name'],
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'gacha',
    label: 'navigation.gacha',
    icon: Symbols.redeem_rounded,
    presentation: Presentation.system,
    document: 'entries',
    detail: ['category', 'startAt', 'endAt'],
    aspectRatio: 16 / 9,
    id: ['id'],
    title: ['title'],
    image: ['image'],
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'login-campaigns',
    label: 'navigation.loginCampaigns',
    icon: Symbols.event_available_rounded,
    presentation: Presentation.system,
    document: 'entries',
    aspectRatio: 16 / 9,
    detail: ['kind', 'startAt', 'endAt'],
    id: ['id'],
    title: ['title'],
    image: ['image'],
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'missions',
    label: 'navigation.systemNavMissions',
    icon: Symbols.fact_check_rounded,
    presentation: Presentation.system,
    document: 'entries',
    aspectRatio: 16 / 9,
  ),
  CatalogProfile(
    resource: 'passes',
    label: 'navigation.systemNavPasses',
    icon: Symbols.workspace_premium_rounded,
    presentation: Presentation.system,
    document: 'entries',
    aspectRatio: 16 / 9,
    detail: ['kind', 'startAt', 'endAt'],
    id: ['id'],
    title: ['title'],
    image: ['image'],
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'tgw-card',
    label: 'catalog.tgwCard.card',
    icon: Symbols.credit_card_rounded,
    presentation: Presentation.system,
    document: 'entries',
    aspectRatio: 16 / 9,
    descending: false,
  ),
  CatalogProfile(
    resource: 'shop',
    label: 'navigation.shop',
    icon: Symbols.storefront_rounded,
    presentation: Presentation.system,
    document: 'entries',
    aspectRatio: 16 / 9,
    detail: ['startAt', 'endAt'],
    id: ['id'],
    title: ['title'],
    image: ['image'],
    defaultSort: 'availability',
    descending: false,
  ),
  CatalogProfile(
    resource: 'exchange',
    label: 'navigation.exchange',
    icon: Symbols.swap_horiz_rounded,
    presentation: Presentation.system,
    document: 'entries',
    aspectRatio: 16 / 9,
    detail: ['category', 'startAt', 'endAt'],
    id: ['id'],
    title: ['title'],
    image: ['image'],
    defaultSort: 'availability',
    descending: false,
  ),
  CatalogProfile(
    resource: 'stamps',
    label: 'navigation.stamps',
    icon: Symbols.emoji_emotions_rounded,
    presentation: Presentation.stamp,
    id: ['stampId', 'id'],
    detail: ['characterIds', 'releasedAt'],
    minWidth: 132,
    small: true,
    title: ['name', 'title'],
    image: ['image', 'thumbnail'],
    defaultSort: 'release',
  ),
  CatalogProfile(
    resource: 'stickers',
    label: 'navigation.stickers',
    icon: Symbols.sticky_note_2_rounded,
    presentation: Presentation.stamp,
    id: ['stickerId', 'id'],
    document: 'entries',
    detail: ['description', 'characterIds', 'releasedAt'],
    minWidth: 132,
    small: true,
    title: ['name', 'title'],
    image: ['image'],
    defaultSort: 'id',
  ),
  CatalogProfile(
    resource: 'backgrounds',
    label: 'navigation.backgrounds',
    icon: Symbols.wallpaper_rounded,
    presentation: Presentation.background,
    id: ['backgroundId', 'id'],
    document: 'entries',
    image: ['thumbnail', 'image'],
    aspectRatio: 16 / 9,

    detail: ['description'],
    title: ['name', 'title'],
    defaultSort: 'id',
  ),
  CatalogProfile(
    resource: 'items',
    label: 'navigation.items',
    icon: Symbols.inventory_2_rounded,
    presentation: Presentation.item,
    id: ['itemId', 'id'],
    document: 'items',
    minWidth: 132,
    small: true,
    detail: ['itemTypeName', 'max'],
    title: ['name', 'title'],
    image: ['image', 'thumbnail'],
    defaultSort: 'id',
    descending: false,
  ),
  CatalogProfile(
    resource: 'band-items',
    label: 'navigation.bandItems',
    icon: Symbols.piano_rounded,
    presentation: Presentation.bandItem,
    id: ['bandItemId', 'itemId', 'id'],
    document: 'items',
    minWidth: 132,
    small: true,
    detail: ['bandId'],
    title: ['name', 'title'],
    image: ['image', 'icon', 'thumbnail'],
    defaultSort: 'order',
    descending: false,
  ),
  CatalogProfile(
    resource: 'real-lives',
    label: 'navigation.realLives',
    icon: Symbols.festival_rounded,
    presentation: Presentation.system,
    document: 'entries',
    aspectRatio: 16 / 9,
    detail: ['kind', 'startAt', 'endAt'],
    id: ['id'],
    title: ['title'],
    image: ['image'],
    defaultSort: 'release',
  ),
];

/// Reads a dotted path from a record.
Object? readPath(Object? value, String path) {
  Object? node = value;
  for (final part in path.split('.')) {
    node = node is Map ? node[part] : null;
  }
  return node;
}

Object? firstOf(Map<String, Object?> record, List<String> paths) {
  for (final path in paths) {
    final value = readPath(record, path);
    if (value != null && value != '' && !(value is List && value.isEmpty)) {
      return value;
    }
  }
  return null;
}
