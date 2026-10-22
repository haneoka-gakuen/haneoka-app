/// Merges the responses of a search split by leader over several isolates
/// (`team-builder/engine/merge.ts`). Every team has one leader, so each
/// shard's per-song top k is exact over its leaders; the union, without
/// repeated member sets, holds the exact top k.
library;

import 'dart:math' as math;

import 'api.dart';
import 'execution.dart';
import 'num.dart';
import 'search.dart' show SearchStats;

String _setKey(EngineHit hit) =>
    '${hit.song?.key ?? '-'}|${([...hit.members]..sort()).join(',')}';

List<EngineHit> _topDistinct(Iterable<EngineHit> hits, int k) {
  final best = <String, EngineHit>{};
  for (final hit in hits) {
    final key = _setKey(hit);
    final known = best[key];
    if (known == null || compareHits(hit, known) < 0) best[key] = hit;
  }
  return stableSorted(best.values, compareHits).take(k).toList();
}

EngineResponse mergeShardResponses(
  List<EngineResponse> responses,
  int k,
  double elapsedMs,
) {
  final first = responses.first;
  final results = [
    for (final (index, result) in first.results.indexed)
      () {
        final parts = [
          for (final response in responses) response.results[index],
        ];
        final bounds = [for (final part in parts) ?part.bound];
        final floors = [for (final part in parts) ?part.floor];
        final hits = _topDistinct([for (final part in parts) ...part.hits], k);
        final exclusions = [for (final part in parts) ?part.excludedBelow];
        final exhausted = parts.every(
          (part) =>
              part.proven ||
              part.excludedBelow != null ||
              part.exclusion != null,
        );
        final excludedBelow = exhausted && hits.isEmpty && exclusions.isNotEmpty
            ? exclusions.reduce(math.max)
            : null;
        final exclusion = exhausted && hits.isEmpty
            ? parts
                  .map((part) => part.exclusion)
                  .whereType<RewardCutoff>()
                  .firstOrNull
            : null;
        final proven =
            exclusion == null &&
            exhausted &&
            excludedBelow == null &&
            parts.every(
              (part) =>
                  (part.exclusion == null ||
                      (hits.length >= k &&
                          hits[k - 1].key >= part.exclusion!.key)) &&
                  (part.excludedBelow == null ||
                      (hits.length >= k &&
                          hits[k - 1].key >= part.excludedBelow!)),
            );
        final stats = SearchStats();
        for (final part in parts) {
          final elapsed = math.max(stats.elapsedMs, part.stats.elapsedMs);
          stats.add(part.stats);
          stats.elapsedMs = elapsed;
        }
        return SongResult(
          song: result.song,
          hits: hits,
          proven: proven,
          bound: proven || bounds.isEmpty ? null : bounds.reduce(math.max),
          stats: stats,
          rewardPhase:
              parts.every((part) => part.rewardPhase == parts.first.rewardPhase)
              ? parts.first.rewardPhase
              : null,
          excludedBelow: excludedBelow,
          exclusion: exclusion,
          floor: floors.isEmpty ? null : floors.reduce(math.max),
        );
      }(),
  ];
  return EngineResponse(
    results: results,
    overall: stableSorted([
      for (final result in results) ...result.hits,
    ], compareHits).take(k).toList(),
    unknownCards: first.unknownCards,
    elapsedMs: elapsedMs,
  );
}

/// Whether every song of a merged search kept k teams at or above its
/// floor (otherwise it must run again without one).
bool aspirationHeld(EngineResponse response, int k) => response.results.every(
  (result) =>
      result.excludedBelow != null ||
      result.floor == null ||
      result.hits.where((hit) => hit.key >= result.floor!).length >= k,
);
