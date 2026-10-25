import 'dart:math' as math;

import 'engine/api.dart';
import 'engine/num.dart';
import 'settings.dart';

class ResultMetric {
  const ResultMetric(
    this.id,
    this.label,
    this.value, {
    this.digits = 0,
    this.unit = '',
    this.relative = true,
  });
  final String id, label, unit;
  final num value;
  final int digits;
  final bool relative;
}

ResultMetric resultMetric(
  EngineHit hit,
  BuildSettings s,
  String Function(String, String) text,
) {
  if (s.goal == GoalKind.potential && hit.potential != null) {
    return ResultMetric(
      'potential',
      text('potential', 'Potential'),
      hit.potential!.potential,
    );
  }
  if ((s.goal == GoalKind.event || s.goal == GoalKind.plan) &&
      hit.event != null) {
    final event = hit.event!;
    if (event.rewardPlan case final plan?) {
      final levels = plan['levels'] as List;
      final primary = '${objectRow((levels.first as List).first)['metric']}';
      final label = (levels.first as List).length > 1
          ? text('rewardPlan.converted', 'Converted rewards')
          : primary == 'points'
          ? text('pointsPerPlay', 'Event points per play')
          : primary == 'items'
          ? text('rewardPlan.itemsPerPlay', 'Badges per play')
          : text('cpPerPlay', 'Challenge points per play');
      return ResultMetric(
        'reward-plan:$plan',
        label,
        event.mean,
        digits: 4,
        unit: primary == 'points'
            ? 'PT'
            : primary == 'challenge-points'
            ? 'CP'
            : '',
      );
    }
    if (s.weighted) {
      final weights = s.weights!,
          direct = event.directMean ?? event.mean,
          other = event.otherMean ?? 0;
      final points = numOf(weights['points']) > 0 ? direct : other;
      final items = numOf(weights['points']) > 0 ? other : direct;
      return ResultMetric(
        'weighted',
        text('weightedTotal', 'Weighted total per play'),
        numOf(weights['points']) * points +
            numOf(weights['items']) * items +
            (s.route == 'live'
                ? numOf(weights['challengePoints']) * event.challengePoints
                : 0),
        digits: 1,
      );
    }
    final measure = s.goal == GoalKind.plan ? 'points' : s.measure;
    final label = measure == 'items'
        ? text('itemsPerPlay', 'Items per play')
        : measure == 'challenge-points'
        ? text('cpPerPlay', 'Challenge points per play')
        : text('pointsPerPlay', 'Event points per play');
    final converted = s.ptCycle && s.route != 'challenge';
    return ResultMetric(
      '$measure:${converted ? 'converted' : 'direct'}',
      converted
          ? '$label · ${text('farm.converted', 'Direct rewards + CP conversion')}'
          : label,
      measure == 'challenge-points' ? event.challengePoints : event.mean,
      digits: 1,
      unit: measure == 'points'
          ? 'pt'
          : measure == 'challenge-points'
          ? 'CP'
          : '',
    );
  }
  if (s.goal != GoalKind.power && hit.score != null) {
    final score = hit.score!;
    if (s.goal == GoalKind.score &&
        s.scoreTarget != 'none' &&
        score.orders.isNotEmpty) {
      final target = s.targetScore ?? 0;
      if (s.scoreTarget == 'at-least') {
        return ResultMetric(
          'at-least',
          text('reachRate', 'Orders reaching the target'),
          score.orders.where((value) => value >= target).length /
              score.orders.length *
              100,
          digits: 1,
          unit: '%',
          relative: false,
        );
      }
      return ResultMetric(
        'capped',
        text('cappedScore', 'Capped average'),
        score.orders.fold<num>(
              0,
              (sum, value) => sum + math.min(value, target),
            ) /
            score.orders.length,
      );
    }
    return switch (s.criterion) {
      'min' => ResultMetric(
        'min',
        text('worstScore', 'Worst-order score'),
        score.min,
      ),
      'max' => ResultMetric(
        'max',
        text('bestScore', 'Best-order score'),
        score.max,
      ),
      _ => ResultMetric(
        'mean',
        text('expectedScore', 'Average score'),
        score.mean,
      ),
    };
  }
  return ResultMetric('power', text('power', 'Power'), hit.power);
}
