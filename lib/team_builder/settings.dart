/// The Build tab's settings, stored in the box as `pref.build` in the
/// website's shape (`lit/team-builder/types.ts`), so a search set up on
/// one device opens the same on the other.
library;

import 'engine/api.dart';
import 'reward_plan.dart';
import 'engine/num.dart';

enum GoalKind { score, gekiso, event, plan, power, potential }

class BuildSettings {
  BuildSettings(Doc json)
    : _json = {..._defaults, ...json},
      _searchGoal = null {
    if (_json['goal'] == 'event' || _json['goal'] == 'plan') {
      _json['rewardMode'] = _json['goal'];
      _json['goal'] = 'score';
    }
    if (json['farming'] is! Map) {
      final custom = _json['rewardMode'] == 'event';
      _json['farming'] = {
        ...farmingDefaults,
        'play': custom
            ? _json['route'] == 'live'
                  ? 'solo'
                  : _json['route']
            : _json['ptMode'],
        for (final key in farmingDefaults.keys)
          if (custom && _json.containsKey(key)) key: _json[key],
        'measure': _json['measure'] == 'items' || custom
            ? _json['measure']
            : 'points',
        'ptCycle': _json['ptCycle'],
        'requireGrowth': !custom,
        'includeMemory': custom,
      };
    }
    final draft = farming;
    if (draft['weighted'] == true && draft['rewardPlan'] == null) {
      _json['farming'] = {
        ...draft,
        'rewardPlan': RewardPlan.legacy(draft).toJson(),
      };
    }
    if (_json['rewardMode'] != 'plan') _json['rewardMode'] = farmingMode;
  }
  final Doc _json;
  final GoalKind? _searchGoal;
  BuildSettings._search(this._json, this._searchGoal);

  // Saved legacy goals migrate to rewardMode; a live search goal must not
  // pass through that migration or it turns back into ordinary score search.
  BuildSettings forGoal(GoalKind goal) =>
      BuildSettings._search({..._json}, goal);

  static const farmingDefaults = <String, Object?>{
    'play': 'solo',
    'playMode': 'ap',
    'great': 3,
    'good': 0,
    'miss': 0,
    'missEvery': 0,
    'measure': 'points',
    'weighted': false,
    'rewardPlan': null,
    'weightPoints': 1,
    'weightItems': 0,
    'weightCp': 0,
    'requireGrowth': true,
    'unknownPolicy': 'min',
    'includeMemory': false,
    'fullRanking': false,
    'k': 1,
    'timeLimit': null,
    'ptCycle': false,
  };
  Doc get farming => {...farmingDefaults, ...objectRow(_json['farming'])};
  Doc get farmingConditions {
    final draft = farming;
    if (draft['play'] != 'gekiso') {
      return {
        ...draft,
        'playMode': draft['play'] == 'skip' ? 'ap' : draft['playMode'],
        'measure':
            draft['play'] != 'solo' && draft['measure'] == 'challenge-points'
            ? 'points'
            : draft['measure'],
      };
    }
    return {
      ...draft,
      'playMode': 'ap',
      'requireGrowth': true,
      'unknownPolicy': 'min',
      'includeMemory': false,
      'measure': draft['measure'] == 'items' ? 'items' : 'points',
      'weighted': false,
      'rewardPlan': null,
      'fullRanking': false,
      'k': 1,
      'timeLimit': null,
    };
  }

  String get farmingMode {
    final s = farmingConditions;
    return s['rewardPlan'] == null &&
            const ['solo', 'gekiso'].contains(s['play']) &&
            s['playMode'] == 'ap' &&
            s['requireGrowth'] == true &&
            s['includeMemory'] == false &&
            s['measure'] != 'challenge-points' &&
            s['weighted'] == false &&
            s['fullRanking'] == false &&
            s['k'] == 1 &&
            s['timeLimit'] == null
        ? 'recommendation'
        : 'event';
  }

  BuildSettings forFarming() {
    final s = farmingConditions;
    return BuildSettings._search({
      ..._json,
      ...s,
      'rewardMode': farmingMode,
      'goal': 'event',
      'route': const ['solo', 'gekiso'].contains(s['play'])
          ? 'live'
          : s['play'],
      'ptMode': s['play'] == 'gekiso' ? 'gekiso' : 'solo',
      'unknownPolicy': s['requireGrowth'] == true ? 'min' : s['unknownPolicy'],
    }, GoalKind.event);
  }

  static const _defaults = <String, Object?>{
    'rewardMode': 'recommendation',
    'fullRanking': false,
    'ptCycle': false,
    'ptMode': 'solo',
    'ptJust': 25,
    'ptLuckSamples': 32,
    'goal': 'score',
    'songs': <Object?>[],
    'criterion': 'mean',
    'scoreTarget': 'none',
    'targetScore': null,
    'weighted': false,
    'rewardPlan': null,
    'weightPoints': 1,
    'weightItems': 0,
    'weightCp': 0,
    'manualScoreMode': 'score',
    'gekisoSeeds': 0,
    'gekisoPlacementMode': 'rank',
    'gekisoOpponents': <Object?>['', '', ''],
    'minComboBonus': 1,
    'playMode': 'ap',
    'great': 3,
    'good': 0,
    'miss': 0,
    'missEvery': 0,
    'eventId': null,
    'measure': 'points',
    'route': 'live',
    'boosts': 3,
    'challengePoints': 200,
    'challengeRules': false,
    'powerSong': true,
    'window': 120,
    'planBudget': 100,
    'planBoostsPerLive': 3,
    'planStartingCp': 0,
    'planChallengeSongs': <Object?>[],
    'k': 1,
    'unknownPolicy': 'max',
    'scope': 'box',
    'leader': null,
    'bindings': <Object?>[],
    'noSnaps': false,
    'minBonus': null,
    'attributes': <Object?>[],
    'bands': <Object?>[],
    'minRarity': 0,
    'timeLimit': null,
    'just': 100,
    'gekisoRank': 1,
  };

  Doc toJson() => {..._json};
  BuildSettings copyWith(Doc patch) => _searchGoal == null
      ? BuildSettings({..._json, ...patch})
      : BuildSettings._search({..._json, ...patch}, _searchGoal);

  int _int(String key) => intOf(_json[key], intOf(_defaults[key]));
  int? _nullableInt(String key) =>
      _json[key] is num ? (_json[key] as num).toInt() : null;
  List<SongRef> _songs(String key) => [
    for (final song in _json[key] as List? ?? const [])
      if (song is Map && song['songId'] is num && song['difficulty'] is num)
        SongRef.fromJson(song.cast<String, Object?>()),
  ];

  GoalKind get goal =>
      _searchGoal ??
      GoalKind.values.where((g) => g.name == _json['goal']).firstOrNull ??
      GoalKind.score;
  List<SongRef> get songs => _songs('songs');
  String get scoreTarget => '${_json['scoreTarget']}';
  int? get targetScore => _nullableInt('targetScore');
  RewardPlan? get rewardPlan => _json['rewardPlan'] is Map
      ? RewardPlan.fromJson(objectRow(_json['rewardPlan']))
      : null;
  RewardPlan get effectiveRewardPlan =>
      (rewardPlan ?? RewardPlan.legacy(_json)).effective(route != 'live');
  bool get weighted => _json['weighted'] == true;
  Doc? get weights => weighted
      ? {
          'points': numOf(_json['weightPoints']),
          'items': numOf(_json['weightItems']),
          'challengePoints': numOf(_json['weightCp']),
        }
      : null;
  String get manualScoreMode => '${_json['manualScoreMode']}';
  int get gekisoSeeds => _int('gekisoSeeds');
  int get minComboBonus => _int('minComboBonus');
  bool get opponentsMode => _json['gekisoPlacementMode'] == 'opponents';
  List<String> get opponentDrafts => [
    for (final v in _json['gekisoOpponents'] as List) '$v',
  ];
  List<List<double>>? get opponents => opponentsMode
      ? [
          for (final range in opponentDrafts)
            [
              for (final token in range.trim().split(RegExp(r'[\s,，、]+')))
                if (token.isNotEmpty) double.parse(token),
            ],
        ]
      : null;
  String get criterion => '${_json['criterion']}';
  bool get allPerfect => _json['playMode'] != 'custom';
  int get great => _int('great');
  int get good => _int('good');
  int get miss => _int('miss');
  int get missEvery => _int('missEvery');
  int? get eventId => _nullableInt('eventId');
  String get measure => '${_json['measure']}';
  String get route => '${_json['route']}';
  int get boosts => _int('boosts');
  int get challengePoints => _int('challengePoints');
  bool get challengeRules => _json['challengeRules'] == true;
  bool get powerSong => _json['powerSong'] != false;
  int get window => _int('window');
  int get planBudget => _int('planBudget');
  int get planBoostsPerLive => _int('planBoostsPerLive');
  int get planStartingCp => _int('planStartingCp');
  List<SongRef> get planChallengeSongs => _songs('planChallengeSongs');
  String get rewardMode => '${_json['rewardMode']}';
  bool get fullRanking => _json['fullRanking'] == true;
  bool get ptCycle => _json['ptCycle'] == true;
  int get k => _int('k');
  String get unknownPolicy => _json['unknownPolicy'] == 'min' ? 'min' : 'max';
  bool get theoretical => _json['scope'] == 'theoretical';
  int? get leader => _nullableInt('leader');
  List<(int, int?)> get bindings => [
    for (final pair in _json['bindings'] as List? ?? const [])
      if (pair is List && pair.isNotEmpty && pair[0] is num)
        (
          (pair[0] as num).toInt(),
          pair.length > 1 && pair[1] is num ? (pair[1] as num).toInt() : null,
        ),
  ];
  bool get noSnaps => _json['noSnaps'] == true;
  double? get minBonus =>
      _json['minBonus'] is num ? (_json['minBonus'] as num).toDouble() : null;
  List<int> get attributes => intListOf(_json['attributes']);
  List<int> get bands => intListOf(_json['bands']);
  int get minRarity => _int('minRarity');
  int? get timeLimit => _nullableInt('timeLimit');
  bool get ptGekiso => _json['ptMode'] == 'gekiso';
  int get ptJust => _int('ptJust');
  int get ptLuckSamples => _int('ptLuckSamples');
  int get just => _int('just');
  int get gekisoRank => _int('gekisoRank');
}
