import 'engine/api.dart';
import 'pt_recommendation.dart' show canonical;
import 'settings.dart';

class ComparedResult {
  ComparedResult({
    required this.hit,
    required this.settings,
    required this.input,
    required this.identity,
    required this.session,
    required this.position,
    this.placements,
  });
  final EngineHit hit;
  final BuildSettings settings;
  final EngineRequest input;
  final Object? identity;
  final String session;
  final int position;
  final List<int>? placements;
  bool listed = true;
  String get formation =>
      canonical([hit.song?.toJson(), hit.members, hit.snaps]);
  String get conditions {
    final goal = goalJson(input.goal)..remove('songs');
    return canonical([
      identity,
      hit.song?.toJson(),
      goal,
      input.songRules,
      input.aggregation,
      hit.aggregate?.map((part) => part.song?.toJson()).toList(),
      input.player.toJson(),
      input.unknownPolicy.name,
      settings.route,
      settings.measure,
      settings.boosts,
      settings.challengePoints,
      settings.ptCycle,
      placements,
    ]);
  }

  String get id => canonical([
    session,
    settings.route,
    settings.measure,
    formation,
    hit.members
        .map(
          (key) => input.members
              .where((row) => row.key == key)
              .firstOrNull
              ?.toJson(),
        )
        .toList(),
    hit.snaps
        .map(
          (key) =>
              input.snaps.where((row) => row.key == key).firstOrNull?.toJson(),
        )
        .toList(),
  ]);
  Map<String, int> difference(ComparedResult other) {
    final bindings = {
      for (var i = 0; i < hit.members.length; i++) hit.members[i]: hit.snaps[i],
    };
    int growth = 0;
    for (final key in other.hit.members.where(hit.members.contains)) {
      if (canonical(
            input.members.where((row) => row.key == key).firstOrNull?.toJson(),
          ) !=
          canonical(
            other.input.members
                .where((row) => row.key == key)
                .firstOrNull
                ?.toJson(),
          )) {
        growth++;
      }
    }
    for (final key in other.hit.snaps.where(
      (key) => key != null && hit.snaps.contains(key),
    )) {
      if (canonical(
            input.snaps.where((row) => row.key == key).firstOrNull?.toJson(),
          ) !=
          canonical(
            other.input.snaps
                .where((row) => row.key == key)
                .firstOrNull
                ?.toJson(),
          )) {
        growth++;
      }
    }
    return {
      'members': other.hit.members
          .where((key) => !hit.members.contains(key))
          .length,
      'snaps': other.hit.snaps
          .where((key) => key != null && !hit.snaps.contains(key))
          .length,
      'bindings': other.hit.members
          .asMap()
          .entries
          .where(
            (entry) =>
                bindings.containsKey(entry.value) &&
                bindings[entry.value] != other.hit.snaps[entry.key],
          )
          .length,
      'growth': growth,
      'leader': hit.members.first == other.hit.members.first ? 0 : 1,
    };
  }
}
