import '../core/api.dart';
import '../core/provider_api.dart';
import '../playlists/song_performer.dart';

typedef Entry = Map<String, Object?>;

/// The catalogue's presentation records (`fetchCatalogVisuals`): game emblems,
/// bands and characters, read once per release and shared by every page.
class CatalogVisuals {
  CatalogVisuals._(this.api, this.marks, this.bands, this.characters);
  final HaneokaApi api;

  /// Sprite name → absolute URL.
  final Map<String, String> marks;
  final Map<int, Entry> bands;
  final Map<int, Entry> characters;

  /// One source-scoped identity registry shared by every song presentation.
  late final PerformerRegistry songPerformers = PerformerRegistry(
    game: catalogGame(api),
    server: api.server,
    sourceId: api.sourceId,
    bands: bands,
    characters: characters,
  );

  final _portraitRegistries = Expando<PerformerRegistry>();

  /// Explicit display fallback from a formal game's pinned character source.
  /// Provider ids keep their own namespace; portrait ids are never song ids.
  PerformerRegistry withPortraitSource(CatalogVisuals formal) {
    if (songPerformers.game != 'gbp') return songPerformers;
    return _portraitRegistries[formal] ??= PerformerRegistry(
      game: songPerformers.game,
      server: api.server,
      bands: bands,
      characters: characters,
      portraitFallbacks: [
        for (final face in auditedCryChicPortraits(formal.songPerformers))
          PerformerPortrait(
            key: face.key,
            provider: face.provider,
            server: face.server,
            sourceId: face.sourceId,
            id: face.id,
            name: face.name,
            image: formal.api.asset(face.image).toString(),
          ),
      ],
    );
  }

  static final _loaded = <HaneokaApi, Future<CatalogVisuals>>{};

  static Future<CatalogVisuals> of(HaneokaApi api) =>
      cachedResource(_loaded, api, () => _load(api));

  static Future<CatalogVisuals> _load(HaneokaApi api) async {
    // A provider has no game emblems; what it has still loads.
    final results = await Future.wait([
      for (final resource in const ['ui-marks', 'bands', 'characters'])
        if (resource == 'ui-marks' && api.offlineRelease != null)
          Future<Object?>.value(null)
        else
          api
              .catalog(resource)
              .then<Object?>(
                (v) => v,
                onError: (Object error) => resource == 'ui-marks'
                    ? null
                    : Future<Object?>.error(error),
              ),
    ]);
    Map<int, Entry> byId(Object? value) => {
      if (_entries(value) case final Map<String, Object?> rows)
        for (final MapEntry(:key, :value) in rows.entries)
          if (value is Entry && int.tryParse(key) != null)
            int.parse(key): value,
    };
    final marks = <String, String>{
      if (_entries(results[0]) case final Map<String, Object?> rows)
        for (final MapEntry(:key, :value) in rows.entries)
          if (value is String)
            key: api
                .asset(
                  '/runtime/${api.server}/${value.replaceFirst(RegExp('^runtime/'), '')}',
                )
                .toString(),
    };
    return CatalogVisuals._(api, marks, byId(results[1]), byId(results[2]));
  }

  static Object? _entries(Object? value) =>
      value is Map ? value['entries'] ?? value['items'] ?? value : value;

  String? mark(String name) => marks[name];

  /// The live music-type emblem, or the card-type emblem of the same colour
  /// where the atlas scan missed it (`liveMusicTypeMark`).
  String? musicTypeMark(Object? musicType) {
    final id = (musicType as num?)?.toInt() ?? 0;
    return marks['sp_icon_live_music_type_$id.png'] ?? cardTypeMark(id);
  }

  String? cardTypeMark(Object? cardType) {
    const colours = ['', 'Red', 'Blue', 'Green', 'Yellow', 'Purple'];
    final id = (cardType as num?)?.toInt() ?? 0;
    return id > 0 && id < colours.length
        ? marks['CardType-${colours[id]}.png']
        : null;
  }

  /// A performer's emblem in an artist line: the logo, else the icon
  /// (`resolveSongPerformer`).
  String? bandLogo(Object? bandId) {
    final band = bands[(bandId as num?)?.toInt()];
    final image = band?['logo'] ?? band?['icon'];
    return image is String && image.isNotEmpty
        ? api.asset(image).toString()
        : null;
  }

  String? bandIcon(Object? bandId) {
    final icon = bands[(bandId as num?)?.toInt()]?['icon'];
    return icon is String && icon.isNotEmpty
        ? api.asset(icon).toString()
        : null;
  }
}
