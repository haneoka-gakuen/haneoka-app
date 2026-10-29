/// Public GBP routes follow the game name; saved Bestdori routes remain valid.
String canonicalAppPath(String path) {
  final parts = Uri.parse(path).pathSegments
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.firstOrNull == 'cards') parts[0] = 'member-cards';
  if (parts.take(2).join('/') == 'catalog/cards') parts[1] = 'member-cards';
  if (parts.length >= 2 && parts.first == 'community') {
    if (parts[1] == 'songs-bestdori' && parts.length <= 3) {
      parts.replaceRange(1, 2, ['gbp', 'songs']);
    } else if (parts[1] == 'stories-bestdori' && parts.length == 3) {
      parts.replaceRange(1, 2, ['gbp', 'stories']);
    }
  }
  if (parts.isNotEmpty &&
      const {
        'characters',
        'songs',
        'member-cards',
        'support-cards',
        'stories',
        'comics',
        'stamps',
        'stickers',
        'backgrounds',
        'chat-customizations',
        'band-items',
        'items',
        'events',
        'arena',
        'real-lives',
        'gacha',
        'login-campaigns',
        'shop',
        'exchange',
        'circle',
        'challenge',
        'passes',
        'missions',
        'tgw-card',
        'live2d',
        'spine',
        'help',
        'skills',
        'song-meta',
        'player-ranks',
        'friendship-ranks',
        'band-rating',
        'high-score-rating',
        'studio',
        'assets',
      }.contains(parts.first)) {
    parts.insert(0, 'catalog');
  }
  return '/${parts.map(Uri.encodeComponent).join('/')}';
}

int chartDifficulty(String? value) =>
    int.tryParse(value ?? '') ??
    const {'easy': 0, 'normal': 1, 'hard': 2, 'expert': 3, 'special': 4}[value
        ?.toLowerCase()] ??
    2;
