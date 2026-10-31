import '../core/site_date.dart';
import '../core/catalog_source.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../core/i18n.dart';
import '../core/relative_time.dart';
import '../ui/app_image.dart';
import '../ui/card_artwork.dart';
import '../ui/tile.dart';
import 'browse.dart';
import 'catalog_query.dart';
import 'cross_server.dart';
import 'profiles.dart';
import 'shop_price.dart';
import 'visuals.dart';
import 'song_presentation.dart';

const _rarities = {2: 'R', 3: 'SR', 4: 'SSR', 10: 'EX', 20: 'BD'};
const _attributes = ['', 'red', 'blue', 'green', 'yellow', 'purple'];

/// A catalogue resource as the website browses it (`catalog-screen`): the
/// profile's presentation decides each tile's subhead, emblems and marks,
/// and the filters it offers.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.profile,
    this.onOpen,
    this.owned,
    this.ownedGrowth,
    this.title,
  });
  final CatalogProfile profile;

  /// Only these entries (by id), each with a mark of the player's progress:
  /// a save's own cards, items or band items.
  final Map<String, String>? owned;
  final Map<String, CardGrowthDisplay>? ownedGrowth;
  final String? title;
  final void Function(BuildContext context, Entry item)? onOpen;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  Future<(List<Entry>, CatalogVisuals)>? _data;
  String? _band;
  List<Entry>? _railSource;
  String? _railBand;
  List<Entry> _railItems = const [];

  Object? _dataKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = CatalogSourceScope.keyOf(context);
    if (_dataKey != key) {
      _dataKey = key;
      _data = _load();
    }
  }

  Future<(List<Entry>, CatalogVisuals)> _load() async {
    final api = CatalogSourceScope.apiOf(context),
        apis = CatalogSourceScope.apisOf(context),
        selected = CatalogSourceScope.serverOf(context);
    await CatalogQueryEngine.loadAliases();
    final profile = widget.profile;
    if (crossCatalogIds.containsKey(profile.resource)) {
      final (rows, visuals) = await (
        crossServerCollection(
          resource: profile.resource,
          selected: selected,
          apis: apis,
          rowsPath: profile.document,
        ),
        CatalogVisuals.of(api),
      ).wait;
      return _owned([
        for (final row in rows)
          {'_key': '${firstOf(row, profile.id) ?? ''}', ...row},
      ], visuals);
    }
    final (document, visuals) = await (
      api.catalog(profile.resource),
      CatalogVisuals.of(api),
    ).wait;
    final source = profile.document == null
        ? document
        : readPath(document, profile.document!);
    final items = switch (source) {
      List() => source.whereType<Entry>().toList(),
      Map() => [
        for (final MapEntry(:key, :value) in source.entries)
          if (value is Entry) {'_key': key, ...value},
      ],
      _ => <Entry>[],
    };
    return _owned(items, visuals);
  }

  (List<Entry>, CatalogVisuals) _owned(
    List<Entry> items,
    CatalogVisuals visuals,
  ) {
    final api = CatalogSourceScope.apiOf(context);
    final profile = widget.profile;
    final owned = widget.owned;
    if (owned == null) return (items, visuals);
    final kit = CatalogKit(profile, AppScope.of(context).text, api, visuals);
    return (
      [
        for (final item in items)
          if (owned.containsKey(kit.id(item))) item,
      ],
      visuals,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final profile = widget.profile;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final visuals = snapshot.data?.$2;
        final kit = CatalogKit(
          profile,
          t,
          CatalogSourceScope.apiOf(context),
          visuals,
        );
        var items = snapshot.data?.$1;
        BrowseRail? rail;
        Widget? heading;
        if ((profile.presentation == Presentation.character ||
                profile.presentation == Presentation.bandItem) &&
            items != null &&
            visuals != null) {
          final bands = {
            for (final item in items)
              if (item['bandId'] case final num id) id.toInt(),
          }.toList()..sort();
          final band = bands.contains(int.tryParse(_band ?? ''))
              ? _band!
              : '${bands.firstOrNull ?? ''}';
          if (!identical(items, _railSource) || band != _railBand) {
            _railSource = items;
            _railBand = band;
            _railItems = [
              for (final item in items)
                if ('${item['bandId']}' == band) item,
            ];
          }
          items = _railItems;
          rail = BrowseRail(
            value: band,
            onSelect: (value) => setState(() => _band = value),
            items: [
              for (final id in bands)
                RailItem(
                  '$id',
                  t.text(visuals.bands[id]?['bandName']),
                  image: visuals.bandLogo(id),
                ),
            ],
          );
          heading = _BandHeading(
            band: visuals.bands[int.tryParse(band)],
            t: t,
            api: CatalogSourceScope.apiOf(context),
          );
        }
        return BrowseScreen(
          key: ValueKey(profile.resource),
          sourcePath: widget.owned == null
              ? '/catalog/${profile.resource == 'cards' ? 'member-cards' : profile.resource}'
              : null,
          title: widget.title ?? t(profile.label, profile.resource),
          items: items,
          error: snapshot.error,
          onRetry: () => setState(() => _data = _load()),
          rail: rail,
          heading: heading,
          searchText: kit.searchText,
          queryEngine:
              visuals != null &&
                  {
                    Presentation.member,
                    Presentation.support,
                  }.contains(profile.presentation)
              ? CatalogQueryEngine(
                  visuals: visuals,
                  game: 'our-notes',
                  kind: 'card',
                )
              : null,
          grid: GridSpec(
            minWidth: profile.minWidth,
            aspectRatio: profile.aspectRatio,
            small: profile.small,
          ),
          tile: (context, item) => Tile(
            title: kit.title(item),
            subtitle: kit.subtitle(item),
            adornments: kit.adornments(item),
            images: kit.images(item),
            aspectRatio: profile.aspectRatio,
            // Portraits keep the full width and clip below the head
            // (`.tile--character` media: natural height, top anchored).
            fit:
                profile.presentation == Presentation.character ||
                    profile.presentation == Presentation.bandItem
                ? BoxFit.fitWidth
                : profile.fit,
            accent: kit.accent(item),
            alignment:
                profile.presentation == Presentation.character ||
                    profile.presentation == Presentation.bandItem
                ? Alignment.topCenter
                : Alignment.center,
            media: profile.resource == 'events' && item['logo'] is String
                ? EventArtwork(
                    background: kit.api
                        .asset(
                          '${item['backgroundImage'] ?? kit.images(item).firstOrNull ?? ''}',
                        )
                        .toString(),
                    logo: kit.api.asset('${item['logo']}').toString(),
                  )
                : kit.cardArtwork(
                    item,
                    growth: widget.ownedGrowth?[kit.id(item)],
                  ),
            serverMark: serverMark(item, kit.t.call),
            marks: [
              if (profile.presentation != Presentation.member &&
                  profile.presentation != Presentation.support)
                ...kit.marks(item),
              if (widget.owned?[kit.id(item)] case final progress?
                  when progress.isNotEmpty)
                TileMark.text(MarkAt.bottomEnd, progress),
            ],
            placeholder: profile.icon,
            onTap: () => widget.onOpen?.call(context, item),
          ),
          listRow: (context, item) => _Row(
            kit: kit,
            item: item,
            growth: widget.ownedGrowth?[kit.id(item)],
            onOpen: () => widget.onOpen?.call(context, item),
          ),
          columns: kit.columns,
          facets: visuals == null ? const [] : kit.facets,
          sorts: kit.sorts,
          defaultSort: profile.defaultSort,
          descending: profile.descending,
          itemId: kit.id,
          onOpen: widget.onOpen,
        );
      },
    );
  }
}

/// A card rarity's name, as the game prints it (`cardRarityName`).
String cardRarityName(Object? value) =>
    _rarities[(value as num?)?.toInt()] ?? '';

/// What a catalogue entry shows, by presentation; the website's
/// `tileDescription`, `tileAdornment`, `cardTileOptions` and facet groups.
class CatalogKit {
  CatalogKit(this.profile, this.t, this.api, this.visuals, {this.songTitles});

  /// The reader's song-title choice (`AppState.songTitle`).
  final String Function(Object?)? songTitles;
  final CatalogProfile profile;
  final SiteText t;
  final HaneokaApi api;
  final CatalogVisuals? visuals;

  Presentation get kind => profile.presentation;
  late final songPresentation = SongPresentation(t, api, visuals);

  static final _markup = RegExp(r'<[^>]+>');
  String plain(Object? value) => t.text(value).replaceAll(_markup, '').trim();

  String id(Entry item) => '${firstOf(item, profile.id) ?? item['_key']}';

  String title(Entry item) {
    final raw = firstOf(item, profile.title);
    final value = kind == Presentation.song && songTitles != null
        ? songTitles!(raw)
        : plain(raw);
    return value.isEmpty ? '—' : value;
  }

  /// The character's colour behind its portrait (`--entity-accent`).
  Color? accent(Entry item) {
    if (kind != Presentation.character) return null;
    final hex = '${item['colorCode'] ?? ''}'.replaceFirst('#', '');
    final value = hex.length == 6 ? int.tryParse(hex, radix: 16) : null;
    return value == null ? null : Color(0xFF000000 | value);
  }

  List<String> images(Entry item) {
    // A band item's artwork lives with its band (`image()` for band-items).
    final band = (item['bandId'] as num?)?.toInt() ?? 0;
    if (kind == Presentation.bandItem && band > 0) {
      return [
        api
            .asset(
              '/assets/${item[serverKey] ?? api.server}/Assets/AddressableResources/Band/$band/BandItem/${id(item)}/band_item.png',
            )
            .toString(),
      ];
    }
    return _images(item);
  }

  List<String> _images(Entry item) => [
    for (final path in profile.image)
      if (readPath(item, path) case final String value when value.isNotEmpty)
        api.asset(value).toString(),
  ];

  List<int> characterIds(Entry item) => [
    for (final value in [
      ...?(item['characterIds'] as List?),
      ...?(item['characters'] as List?),
      if (item['characterIds'] == null && item['characters'] == null)
        item['characterId'],
    ])
      if (value is num && value > 0) value.toInt(),
  ];

  String characterName(int id) =>
      t.text(visuals?.characters[id]?['characterName']);

  String bandName(Object? id) =>
      t.text(visuals?.bands[(id as num?)?.toInt()]?['bandName']);

  String names(List<int> ids) => ids.map(characterName).join(', ');

  String subtitle(Entry item) => switch (kind) {
    Presentation.member ||
    Presentation.support ||
    Presentation.comic => names(characterIds(item)),
    Presentation.stamp =>
      profile.resource == 'stickers' && plain(item['description']).isNotEmpty
          ? plain(item['description'])
          : names(characterIds(item)),
    Presentation.character => bandName(item['bandId']),
    Presentation.bandItem => bandName(item['bandId']),
    Presentation.item =>
      plain(item['description']).isNotEmpty
          ? plain(item['description'])
          : '${item['itemTypeName'] ?? ''}',
    Presentation.background || Presentation.skill => plain(item['description']),
    Presentation.system => switch (profile.resource) {
      'shop' => shopPrice(item),
      'challenge' => t.text(item['band']),
      _ => systemWindow(item),
    },
    Presentation.song => songPresentation.artist(item),
  };

  /// A rotating entry's window (`systemRelativeSubtitle`).
  String systemWindow(Entry item) {
    final start = RelativeTime.timestamp(item['startAt']);
    final end = RelativeTime.timestamp(item['endAt']);
    if (start != null && end != null && start > 0 && end > 0 && end < start) {
      return t.label('unavailable', 'Unavailable');
    }
    return t.window(
      item['startAt'],
      item['endAt'],
      ongoing: t.label('ongoing', 'Ongoing'),
    );
  }

  /// The shop row's price as one line (`shopPriceLabel`).
  String shopPrice(Entry item) {
    final payment = (item['payment'] as Map?) ?? const {};
    if (payment['advertisement'] == true) {
      return t.label('watchAd', 'Watch an ad');
    }
    final regional = shopPriceLine(
      t.locale,
      shopPrices(payment, '${item[serverKey] ?? api.server}'),
    );
    if (regional.isNotEmpty) return regional;
    final price = payment['price'];
    if (price is num && price != 0) {
      final amount = NumberFormat(
        price % 1 == 0 ? '#,##0' : '#,##0.00',
        t.locale,
      ).format(price);
      return payment['currencyImage'] is String &&
              '${payment['currencyImage']}'.isNotEmpty
          ? '${t.text(payment['currency'])} ×$amount'
          : '$amount ${t.text(payment['currency'])}';
    }
    if (payment['storePurchase'] == true) {
      return t.label('inAppPurchase', 'In-app purchase');
    }
    return systemWindow(item);
  }

  List<String> adornments(Entry item) {
    if (kind == Presentation.song) return songPresentation.avatars(item);
    if (const {
      Presentation.member,
      Presentation.support,
      Presentation.comic,
      Presentation.stamp,
    }.contains(kind)) {
      return [
        for (final id in characterIds(item).take(3))
          if (visuals?.characters[id]?['faceImage'] case final String face)
            api.asset(face).toString(),
      ];
    }
    return const [];
  }

  String rarityName(Object? value) => cardRarityName(value);

  Widget? cardArtwork(Entry item, {CardGrowthDisplay? growth}) {
    if (kind != Presentation.member && kind != Presentation.support) {
      return null;
    }
    return CardArtwork(
      kind: kind == Presentation.member
          ? GameCardKind.member
          : GameCardKind.support,
      image: images(item).firstOrNull ?? '',
      attribute: visuals?.cardTypeMark(item['cardType']),
      attributeLabel: attributeName(item['cardType']),
      rarity: visuals?.mark(
        'RarityIconCenter_${rarityName(item['rarity'])}.png',
      ),
      rarityLabel: rarityName(item['rarity']),
      growth: growth,
    );
  }

  String attributeName(Object? value) {
    final id = (value as num?)?.toInt() ?? 0;
    return id > 0 && id < _attributes.length ? t.label(_attributes[id]) : '';
  }

  List<TileMark> marks(Entry item) {
    if (kind == Presentation.song) return songPresentation.marks(item);
    if (kind == Presentation.system) {
      final end = RelativeTime.timestamp(item['endAt']) ?? 0;
      final start = RelativeTime.timestamp(item['startAt']) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      return [
        if (!(start > now) && end > 0 && end < now)
          TileMark.text(
            MarkAt.bottomEnd,
            t.label('ended', 'Ended'),
            alert: true,
          ),
      ];
    }
    if (profile.resource == 'stickers') {
      final closed = RelativeTime.timestamp(item['closedAt']) ?? 0;
      return [
        if (closed > 0 && closed < DateTime.now().millisecondsSinceEpoch)
          TileMark.text(
            MarkAt.bottomEnd,
            t.label('retired', 'Retired'),
            alert: true,
          ),
      ];
    }
    if (kind != Presentation.member && kind != Presentation.support) {
      return const [];
    }
    final attribute = visuals?.cardTypeMark(item['cardType']);
    final rarity = visuals?.mark(
      'RarityIconCenter_${rarityName(item['rarity'])}.png',
    );
    return [
      if (attribute != null)
        TileMark.image(
          MarkAt.start,
          attribute,
          label: attributeName(item['cardType']),
        ),
      if (rarity != null)
        TileMark.image(MarkAt.end, rarity, label: rarityName(item['rarity'])),
    ];
  }

  num? releasedAt(Entry item) => RelativeTime.timestamp(
    item['releasedAt'] ?? item['publishedAt'] ?? item['publicStartAt'],
  );

  String date(num? ms) => ms == null
      ? '—'
      : SiteDate.day(t.locale)
            .format(DateTime.fromMillisecondsSinceEpoch(ms.toInt()));

  String searchText(Entry item) => [
    id(item),
    title(item),
    subtitle(item),
    ...?(firstOf(item, profile.title) as List?)?.whereType<String>(),
  ].join(' ');

  int total(Entry item) => ['performance', 'technique', 'visual'].fold(
    0,
    (sum, key) => sum + ((readPath(item, 'stat.$key') as num?)?.toInt() ?? 0),
  );

  List<TableColumn> get columns => [
    TableColumn(t.label('title'), title),
    TableColumn('', subtitle),
    if (kind == Presentation.member || kind == Presentation.support) ...[
      TableColumn(t.label('rarity'), (item) => rarityName(item['rarity'])),
      TableColumn(
        t.label('attribute'),
        (item) => attributeName(item['cardType']),
      ),
      TableColumn(t.label('total'), (item) => '${total(item)}', numeric: true),
    ],
    if (kind == Presentation.system) ...[
      TableColumn(
        t.label('start'),
        (item) => date(RelativeTime.timestamp(item['startAt'])),
      ),
      TableColumn(
        t.label('end'),
        (item) => date(RelativeTime.timestamp(item['endAt'])),
      ),
    ] else
      TableColumn(t.label('release'), (item) => date(releasedAt(item))),
    TableColumn(t.label('id'), id, numeric: true),
  ];

  /// The website's sort options for the kind (`sortOptions`) with its
  /// sort values (`sortValue`).
  List<SortSpec> get sorts {
    SortSpec sort(
      String value,
      String key,
      String fallback,
      Comparable<Object?>? Function(Entry) of,
    ) => SortSpec(value, t.label(key, fallback), of);
    num number(Object? value) =>
        value is num ? value : num.tryParse('${value ?? ''}') ?? 0;
    num firstTime(Object? value) => RelativeTime.timestamp(value) ?? 0;
    final idSort = sort(
      'id',
      'id',
      'ID',
      (item) => num.tryParse(id(item)) ?? id(item),
    );
    final titleSort = sort('title', 'title', 'Title', title);
    final release = sort(
      'release',
      'release',
      'Release',
      (item) => firstTime(
        item['releasedAt'] ??
            item['publishedAt'] ??
            item['publicStartAt'] ??
            item['startAt'],
      ),
    );
    final order = sort(
      'order',
      'order',
      'Order',
      (item) => number(
        item['displayOrder'] ?? item['order'] ?? item['sortOrder'] ?? id(item),
      ),
    );
    final characters = sort(
      'characters',
      'characters',
      'Characters',
      (item) => characterIds(item).firstOrNull ?? 0,
    );
    String skill(Entry item, String key) {
      final raw = (item['resolvedSkills'] as Map?)?[key];
      final skill = raw is List ? raw.firstOrNull : raw;
      return skill is Map ? t.text(skill['skillName']) : '';
    }

    return switch (kind) {
      Presentation.member || Presentation.support => [
        idSort,
        titleSort,
        sort(
          'character',
          'character',
          'Character',
          (item) =>
              number(item['characterId'] ?? characterIds(item).firstOrNull),
        ),
        sort(
          'band',
          'band',
          'Band',
          (item) => number(
            item['bandId'] ??
                visuals?.characters[characterIds(item).firstOrNull]?['bandId'],
          ),
        ),
        sort(
          'cardType',
          'attribute',
          'Attribute',
          (item) => number(item['cardType']),
        ),
        sort('rarity', 'rarity', 'Rarity', (item) => number(item['rarity'])),
        for (final stat in ['performance', 'technique', 'visual'])
          sort(
            stat,
            stat,
            stat,
            (item) => number(readPath(item, 'stat.$stat')),
          ),
        sort('total', 'total', 'Total', total),
        if (kind == Presentation.member) ...[
          sort(
            'leaderSkill',
            'leaderSkill',
            'Leader skill',
            (item) => skill(item, 'leader'),
          ),
          sort(
            'liveSkill',
            'liveSkill',
            'Live skill',
            (item) => skill(item, 'live'),
          ),
          sort(
            'gekisouSkill',
            'gekisouSkill',
            'Gekisou skill',
            (item) => skill(item, 'gekisou'),
          ),
        ] else ...[
          sort(
            'supportSkill',
            'supportSkill',
            'Support skill',
            (item) => skill(item, 'support'),
          ),
          sort(
            'gekisouSupportSkill',
            'gekisouSupportSkill',
            'Gekiso support skill',
            (item) => skill(item, 'gekisouSupport'),
          ),
        ],
        release,
      ],
      Presentation.character => [order, idSort, titleSort],
      Presentation.comic => [
        idSort,
        titleSort,
        sort(
          'subtitle',
          'subtitle',
          'Subtitle',
          (item) => t.text(item['subTitle']),
        ),
        characters,
        release,
      ],
      Presentation.stamp => [idSort, titleSort, characters, release],
      // The website defaults to id without offering it in the menu.
      Presentation.background => [
        SortSpec(idSort.key, idSort.label, idSort.value, hidden: true),
        titleSort,
      ],
      Presentation.bandItem => [
        order,
        idSort,
        titleSort,
        sort('band', 'band', 'Band', (item) => number(item['bandId'])),
        sort(
          'levels',
          'level',
          'Levels',
          (item) => (item['levels'] as List?)?.length ?? 0,
        ),
      ],
      Presentation.item => [
        sort(
          'id',
          'order',
          'Order',
          (item) => num.tryParse(id(item)) ?? id(item),
        ),
        titleSort,
        sort(
          'itemTypeName',
          'type',
          'Type',
          (item) => t.text(item['itemTypeName']),
        ),
        sort('max', 'size', 'Maximum', (item) => number(item['max'])),
      ],
      Presentation.system => [
        idSort,
        titleSort,
        sort('availability', 'availability', 'Ending soonest', (item) {
          // Ending soonest leads; standing offers follow, newest ids first.
          final end = firstTime(item['endAt']);
          if (end > 0) return end;
          return 9007199254740991 -
              (num.tryParse(id(item).replaceAll(RegExp(r'\D'), '')) ?? 0) *
                  1000;
        }),
        release,
      ],
      _ => [idSort, titleSort, release],
    };
  }

  List<FacetSpec> get facets {
    final visuals = this.visuals!;
    final characters = FacetSpec(
      key: 'character',
      label: t.label('character'),
      values: (item) => characterIds(item).map((id) => '$id'),
      option: (value) {
        final face = visuals.characters[int.parse(value)]?['faceImage'];
        return FacetOption(
          characterName(int.parse(value)),
          image: face is String ? api.asset(face).toString() : null,
        );
      },
    );
    final bands = FacetSpec(
      key: 'band',
      label: t.label('band'),
      values: (item) => {
        for (final id in characterIds(item))
          if (visuals.characters[id]?['bandId'] case final num band) '$band',
        if (item['bandId'] case final num band) '$band',
      },
      option: (value) => FacetOption(
        bandName(int.parse(value)),
        image: visuals.bandIcon(int.parse(value)),
      ),
    );
    const cardKinds = {Presentation.member, Presentation.support};
    const characterKinds = {
      Presentation.member,
      Presentation.support,
      Presentation.comic,
      Presentation.stamp,
    };
    return [
      if (characterKinds.contains(kind)) bands,
      if (characterKinds.contains(kind)) characters,
      if (cardKinds.contains(kind)) ...[
        FacetSpec(
          key: 'rarity',
          label: t.label('rarity'),
          values: (item) => [if (item['rarity'] != null) '${item['rarity']}'],
          option: (value) => FacetOption(
            rarityName(int.parse(value)),
            image: visuals.mark(
              'RarityIconCenter_${rarityName(int.parse(value))}.png',
            ),
            imageOnly: true,
          ),
        ),
        FacetSpec(
          key: 'type',
          label: t.label('attribute'),
          values: (item) => [
            if (item['cardType'] != null) '${item['cardType']}',
          ],
          option: (value) => FacetOption(
            attributeName(int.parse(value)),
            image: visuals.cardTypeMark(int.parse(value)),
          ),
        ),
      ],
      if (kind == Presentation.item)
        FacetSpec(
          key: 'type',
          label: t.label('type'),
          values: (item) => [
            if (item['itemTypeName'] != null) '${item['itemTypeName']}',
          ],
          option: FacetOption.new,
        ),
      if (kind == Presentation.system)
        FacetSpec(
          key: 'kind',
          label: t.label('category'),
          values: (item) => [
            if (plain(item['category']).isNotEmpty)
              plain(item['category'])
            else if (item['kind'] != null)
              '${item['kind']}',
          ],
          option: (value) => FacetOption(t.label(value, value)),
        ),
    ];
  }
}

/// The band the character rail has selected, named: icon, name and its own
/// description (`BrowseHeading`).
class _BandHeading extends StatelessWidget {
  const _BandHeading({required this.band, required this.t, required this.api});
  final Entry? band;
  final SiteText t;
  final HaneokaApi api;

  @override
  Widget build(BuildContext context) {
    final band = this.band;
    if (band == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final icon = band['icon'];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon is String)
          Padding(
            padding: EdgeInsets.only(
              right: MediaQuery.sizeOf(context).width < 600 ? 10 : 14,
            ),
            child: SizedBox(
              width: (MediaQuery.sizeOf(context).width * 0.16).clamp(
                72.0,
                132.0,
              ),
              height: 64,
              child: AppImage(candidates: [api.asset(icon).toString()]),
            ),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.text(band['bandName']),
                style: MediaQuery.sizeOf(context).width < 600
                    ? theme.textTheme.titleLarge
                    : theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 2),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 60),
                child: Text(
                  t.text(band['description']),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.kit, required this.item, this.onOpen, this.growth});
  final CatalogKit kit;
  final Entry item;
  final VoidCallback? onOpen;
  final CardGrowthDisplay? growth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = kit.subtitle(item);
    if (growth != null) {
      return InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 80 * kit.profile.aspectRatio,
                  height: 80,
                  child: ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: kit.cardArtwork(item, growth: growth),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kit.title(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListTile(
      onTap: onOpen,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: kit.profile.aspectRatio > 1.2 ? 85 : 48,
          height: 48,
          child: ColoredBox(
            color: scheme.surfaceContainerHighest,
            child:
                kit.cardArtwork(item, growth: growth) ??
                AppImage(candidates: kit.images(item), fit: kit.profile.fit),
          ),
        ),
      ),
      title: Text(
        kit.title(item),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
