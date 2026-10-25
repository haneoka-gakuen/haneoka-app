/// Reward-only ranking shared by farming settings, native requests and results.
library;

import 'engine/api.dart';
import 'engine/num.dart';

const rewardMetrics = ['points', 'challenge-points', 'items'];

class RewardPlan {
  RewardPlan(this.primary, this.options, this.tieOrder);
  factory RewardPlan.empty([String primary = 'points']) => RewardPlan(primary, {
    for (final metric in rewardMetrics)
      metric: {'mode': 'ignore', 'rate': null, 'auto': false},
  }, []);
  factory RewardPlan.fromJson(Doc json) => RewardPlan(
    '${json['primary']}',
    {
      for (final metric in rewardMetrics)
        metric: {...objectRow(objectRow(json['options'])[metric])},
    },
    [for (final value in json['tieOrder'] as List? ?? const []) '$value'],
  );
  factory RewardPlan.legacy(Doc settings) {
    if (settings['weighted'] != true) {
      var plan = RewardPlan.empty('${settings['measure']}');
      if (plan.primary != 'challenge-points') {
        plan = plan.mode(plan.primary == 'points' ? 'items' : 'points', 'tie');
        if (settings['ptCycle'] == true) {
          plan = plan.mode('challenge-points', 'convert').option(
            'challenge-points',
            {'auto': true},
          );
        }
      }
      return plan;
    }
    final weights = {
      'points': numOf(settings['weightPoints']),
      'items': numOf(settings['weightItems']),
      'challenge-points': numOf(settings['weightCp']),
    };
    final primary =
        rewardMetrics.where((metric) => weights[metric]! > 0).firstOrNull ??
        '${settings['measure']}';
    var plan = RewardPlan.empty(primary);
    for (final metric in rewardMetrics) {
      if (metric != primary && weights[metric]! > 0) {
        plan = plan.mode(metric, 'convert').option(metric, {
          'rate': weights[metric]! / weights[primary]!,
        });
      }
    }
    return plan;
  }
  final String primary;
  final Map<String, Doc> options;
  final List<String> tieOrder;
  Doc toJson() => {
    'primary': primary,
    'options': options,
    'tieOrder': tieOrder,
  };
  RewardPlan option(String metric, Doc patch) => RewardPlan(primary, {
    ...options,
    metric: {...options[metric]!, ...patch},
  }, tieOrder);
  RewardPlan mode(String metric, String mode) => RewardPlan(
    primary,
    {
      ...options,
      metric: {...options[metric]!, 'mode': mode},
    },
    [
      for (final value in tieOrder)
        if (value != metric) value,
      if (mode == 'tie') metric,
    ],
  );
  RewardPlan main(String metric) {
    if (metric == primary) return this;
    var next = mode(metric, 'ignore');
    if (next.options[primary]!['mode'] == 'ignore') {
      next = next.mode(primary, 'tie');
    }
    return RewardPlan(metric, {
      for (final entry in next.options.entries)
        entry.key: {...entry.value, 'rate': null},
    }, next.tieOrder);
  }

  RewardPlan first(String metric) => RewardPlan(primary, options, [
    metric,
    ...tieOrder.where((value) => value != metric),
  ]);
  RewardPlan effective(bool challenge) => challenge
      ? (primary == 'challenge-points' ? main('points') : this).mode(
          'challenge-points',
          'ignore',
        )
      : this;
  bool get autoCp =>
      primary != 'challenge-points' &&
      options['challenge-points']!['mode'] == 'convert' &&
      options['challenge-points']!['auto'] == true;
  Doc? compile(List<SongRef> songs, int consumption) {
    final terms = <Doc>[
      {'metric': primary, 'weight': 10000},
    ];
    for (final metric in rewardMetrics) {
      final option = options[metric]!;
      if (metric == primary ||
          option['mode'] != 'convert' ||
          metric == 'challenge-points' && option['auto'] == true) {
        continue;
      }
      final rate = option['rate'];
      if (rate is! num || !rate.isFinite || rate < 0 || rate > 100000) {
        return null;
      }
      final weight = (rate * 10000).round();
      if (weight > 0) terms.add({'metric': metric, 'weight': weight});
    }
    if (autoCp && (songs.isEmpty || consumption <= 0)) return null;
    return {
      'unit': 10000,
      'levels': [
        terms,
        for (final metric in tieOrder)
          if (metric != primary && options[metric]!['mode'] == 'tie')
            [
              {'metric': metric, 'weight': 1},
            ],
      ],
      if (autoCp)
        'autoCp': {
          'songs': [for (final song in songs) song.toJson()],
          'consumption': consumption,
        },
    };
  }
}
