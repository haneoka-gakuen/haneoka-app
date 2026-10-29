import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'visuals.dart';

class CatalogQuery {
  const CatalogQuery(this.text, this.facets);
  final String text;
  final Map<String, List<String>> facets;
  CatalogQuery withMissionMode(String fallback) =>
      facets['gekisouMatch']?.isNotEmpty ?? false
      ? this
      : CatalogQuery(text, {
          ...facets,
          'gekisouMatch': [fallback],
        });
  Map<String, Object?> toJson() => {
    'schema': 'haneoka-catalog-query-v1',
    'text': text,
    'facets': facets,
  };
}

class CatalogQueryEngine {
  CatalogQueryEngine({
    required this.visuals,
    required this.game,
    required this.kind,
    this.characters,
    this.bands,
    this.aliases = const [],
  });
  final CatalogVisuals? visuals;
  final Map<int, Entry>? characters;
  final Map<int, Entry>? bands;
  Map<int, Entry> get _characters =>
      characters ?? visuals?.characters ?? const {};
  Map<int, Entry> get _bands => bands ?? visuals?.bands ?? const {};
  final List<(String, String, String)> aliases;
  final String game;
  final String kind;
  static Map<String, dynamic>? _aliases;
  static Future<void>? _loading;
  static Future<void> loadAliases() => _loading ??= rootBundle
      .loadString('assets/settings/catalog-query-aliases.json')
      .then((source) {
        _aliases = jsonDecode(source) as Map<String, dynamic>;
      });
  String? _lastQuery;
  CatalogQuery? _lastPlan;
  Map<String, List<(String, String)>>? _dictionary;
  static String normalize(String text) => unorm.nfkc(text).toLowerCase();
  static String _identity(String text) =>
      normalize(text).replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  Iterable<String> _names(Entry row, String kind) {
    final names = <String>[
      for (final value
          in kind == 'character'
              ? [row['characterName'], row['englishName']]
              : [
                  row['bandName'],
                  row['name'],
                  row['englishName'],
                  row['shortName'],
                ])
        ...switch (value) {
          List() => value.whereType<String>(),
          String() => [value],
          _ => const <String>[],
        },
    ];
    final identities = names.map(_identity).toSet();
    for (final group
        in (_aliases?[kind == 'character' ? 'characters' : 'bands'] as List? ??
            const [])) {
      final values = (group as List).cast<String>();
      if (values.any((name) => identities.contains(_identity(name)))) {
        names.addAll(values);
      }
    }
    if (kind == 'character') {
      for (final name in [...names]) {
        names.addAll(
          name.split(RegExp(r'\s+')).where((part) => part.length > 1),
        );
      }
    }
    return names.toSet();
  }

  Map<String, List<(String, String)>> _buildDictionary() {
    final result = <String, List<(String, String)>>{};
    void add(String name, String key, String value) {
      final identity = _identity(name);
      if (identity.isNotEmpty) (result[identity] ??= []).add((key, value));
    }

    for (final (name, key, value) in aliases) {
      add(name, key, value);
    }
    for (final entry in _characters.entries) {
      for (final name in _names(entry.value, 'character')) {
        add(name, 'character', '${entry.key}');
      }
    }
    for (final entry in _bands.entries) {
      for (final name in _names(entry.value, 'band')) {
        add(name, 'collectionBand', '${entry.key}');
      }
    }
    if (kind == 'card' || game == 'our-notes') {
      final attributes =
          ((_aliases?['attributes'] as Map?)?[game] as Map?) ?? const {};
      for (final entry in attributes.entries) {
        for (final name in (entry.value as List).cast<String>()) {
          add(name, 'type', '${entry.key}');
        }
      }
    }
    return result;
  }

  String removeFacets(String source, Set<String> keys) {
    final tokens = RegExp(r'''"[^"]*"|'[^']*'|\S+''')
        .allMatches(source)
        .map((m) => m[0]!)
        .toList();
    final retained = <String>[];
    for (var index = 0; index < tokens.length;) {
      var removed = 0;
      for (var count = math.min(5, tokens.length - index); count > 0; count--) {
        final value = parse(tokens.sublist(index, index + count).join(' '));
        if (value.text.isEmpty &&
            value.facets.isNotEmpty &&
            value.facets.keys.every(keys.contains)) {
          removed = count;
          break;
        }
      }
      if (removed > 0) {
        index += removed;
      } else {
        retained.add(tokens[index++]);
      }
    }
    return retained.join(' ');
  }

  CatalogQuery parse(String query) {
    if (_lastQuery == query && _lastPlan != null) return _lastPlan!;
    final facets = <String, List<String>>{};
    void add(String key, String value) {
      final values = facets[key] ??= [];
      if (key.startsWith('min') || key.startsWith('max')) {
        final numbers = [...values.map(double.parse), double.parse(value)];
        facets[key] = [
          '${numbers.reduce(key.startsWith('min') ? math.max : math.min)}',
        ];
      } else if (!values.contains(value)) {
        values.add(value);
      }
    }

    final tokens = RegExp(r'''"([^"]*)"|'([^']*)'|\S+''')
        .allMatches(query)
        .map((m) => (m[1] ?? m[2] ?? m[0]!, m[1] != null || m[2] != null))
        .toList();
    final dictionary = _dictionary ??= _buildDictionary();
    final remaining = <String>[];
    for (var index = 0; index < tokens.length; index++) {
      final token = tokens[index];
      if (token.$2) {
        remaining.add(token.$1);
        continue;
      }
      var numericMatched = false;
      for (
        var length = math.min(5, tokens.length - index);
        length >= 1;
        length--
      ) {
        final parts = tokens.sublist(index, index + length);
        if (parts.any((part) => part.$2)) continue;
        final expression = normalize(parts.map((part) => part.$1).join(' '));
        final numeric = RegExp(
          r'^(?:(lv|level|rarity|stars?|星[级級]?|稀有度|等[级級]|[级級]|レベル|[★☆*])\s*:?\s*)?(>=|<=|>|<|=|≥|≤)?\s*(\d+(?:\.\d+)?)\s*(星[级級]?|等[级級]|[级級]|レベル|[★☆*])?\s*(?:(\+)|-\s*(\d+(?:\.\d+)?)|(以上|以下))?$',
        ).firstMatch(expression);
        if (numeric == null ||
            [1, 2, 4, 5, 6, 7].every((group) => numeric[group] == null)) {
          continue;
        }
        if (kind == 'card' &&
            double.parse(numeric[3]!) > 5 &&
            numeric[1] == null &&
            numeric[4] == null) {
          continue;
        }
        String fieldFor(String marker) =>
            RegExp(r'^(rarity|stars?|星[级級]?|稀有度|[★☆*])$').hasMatch(marker)
            ? 'Rarity'
            : 'Level';
        if (numeric[1] != null &&
            numeric[4] != null &&
            fieldFor(numeric[1]!) != fieldFor(numeric[4]!)) {
          continue;
        }
        final field = numeric[1] != null || numeric[4] != null
            ? fieldFor(numeric[1] ?? numeric[4]!)
            : kind == 'song'
            ? 'Level'
            : 'Rarity';
        final value = double.parse(numeric[3]!);
        final comparison =
            numeric[2] ??
            (numeric[7] == '以上' || numeric[5] != null
                ? '>='
                : numeric[7] == '以下'
                ? '<='
                : '');
        if (comparison == '>=' || comparison == '≥') {
          add('min$field', '$value');
        } else if (comparison == '>') {
          add('min$field', '${value + (field == 'Rarity' ? 1 : 0.000001)}');
        } else if (comparison == '<=' || comparison == '≤') {
          add('max$field', '$value');
        } else if (comparison == '<') {
          add('max$field', '${value - (field == 'Rarity' ? 1 : 0.000001)}');
        } else {
          add('min$field', '$value');
          add('max$field', numeric[6] ?? '$value');
        }
        index += length - 1;
        numericMatched = true;
        break;
      }
      if (numericMatched) continue;
      final mission = RegExp(r'^(?:(only|contains):)?(combo|just|luck|mix)$')
          .firstMatch(normalize(token.$1));
      if (kind == 'song' && game == 'our-notes' && mission != null) {
        add(
          'gekisouType',
          {
            'combo': 'Combo',
            'just': 'JustCount',
            'luck': 'Luck',
            'mix': 'Mix',
          }[mission[2]]!,
        );
        if (mission[1] != null) facets['gekisouMatch'] = [mission[1]!];
        continue;
      }
      var recognized = false;
      for (
        var length = math.min(5, tokens.length - index);
        length >= 1;
        length--
      ) {
        final parts = tokens.sublist(index, index + length);
        if (parts.any(
          (part) =>
              part.$2 ||
              RegExp(r'^[-+★☆*<>=≥≤]+$').hasMatch(normalize(part.$1)),
        )) {
          continue;
        }
        final entries =
            dictionary[_identity(parts.map((part) => part.$1).join(' '))];
        if (entries == null || entries.map((e) => e.$1).toSet().length != 1) {
          continue;
        }
        for (final entry in entries) {
          add(entry.$1, entry.$2);
        }
        index += length - 1;
        recognized = true;
        break;
      }
      if (!recognized) remaining.add(token.$1);
    }
    _lastQuery = query;
    return _lastPlan = CatalogQuery(
      facets.isEmpty ? query.trim() : remaining.join(' '),
      facets,
    );
  }

  bool matches(Entry item, CatalogQuery query) {
    final facets = query.facets;
    List<String> ids(Object? source) => source is List
        ? source.map((v) => '$v').toList()
        : source == null
        ? []
        : ['$source'];
    final characters = {
      ...ids(item['characterIds']),
      ...ids(item['characterId']),
      ...ids(item['vocalCharacterIds']),
    };
    final bands = {
      ...ids(item['bandIds']),
      ...ids(item['bandId']),
      ...ids(item['collectionBand']),
      for (final id in characters)
        if (_characters[int.tryParse(id)]?['bandId'] case final Object band)
          '$band',
    };
    bool selected(String key, Iterable<String> values) =>
        !(facets[key]?.isNotEmpty ?? false) ||
        values.any(facets[key]!.contains);
    if (!selected('character', characters) ||
        !selected('collectionBand', bands) ||
        !selected('category', ids(item['musicCategories'])) ||
        !selected(
          'type',
          ids(item['cardType'] ?? item['musicType'] ?? item['attribute']),
        )) {
      return false;
    }
    double number(Object? value) => value is num
        ? value.toDouble()
        : double.tryParse('$value') ?? double.nan;
    bool range(String field, Object? raw) {
      final value = number(raw);
      final min = facets['min$field']?.firstOrNull,
          max = facets['max$field']?.firstOrNull;
      return (min == null && max == null) ||
          value.isFinite &&
              (min == null || value >= double.parse(min)) &&
              (max == null || value <= double.parse(max));
    }

    if (!range('Rarity', item['rarity'])) return false;
    if (facets.containsKey('minLevel') || facets.containsKey('maxLevel')) {
      if (!(item['difficulty'] as List? ?? const []).whereType<Map>().any(
        (row) => range(
          'Level',
          row['displayLevel'] ?? row['playLevel'] ?? row['sortLevel'],
        ),
      )) {
        return false;
      }
    }
    final missions = facets['gekisouType'];
    if (missions != null && missions.isNotEmpty) {
      final gekisou = item['gekisou'] as Map?;
      final types =
          (gekisou?['missionTypes'] ?? gekisou?['missionPattern']) as List? ??
          const [];
      final values = types
          .map(
            (v) => {'1': 'Combo', '2': 'Luck', '3': 'JustCount'}['$v'] ?? '$v',
          )
          .toList();
      if (values.length != 3 ||
          values.any((v) => !['Combo', 'Luck', 'JustCount'].contains(v))) {
        return false;
      }
      if (!(missions.contains('Mix') && values.toSet().length > 1) &&
          !(facets['gekisouMatch']?.firstOrNull == 'contains'
              ? values.any(missions.contains)
              : values.every(missions.contains))) {
        return false;
      }
    }
    return true;
  }
}
