import 'game_save.dart';
import 'save_view.dart';

const _difficulties = ['easy', 'normal', 'hard', 'expert'];

/// Each chart's clear mark in [save] for the website's song progress
/// (`l.{song}.{difficulty}`): the game's `_<difficulty>ClearedStatus` of 10
/// clear, 20 full combo and 30 all perfect as 1, 2 and 3.
Map<String, int> songMarks(GameSave save) => {
  for (final row in SaveView(save).rows(SaveSection.songs))
    for (final (index, name) in _difficulties.indexed)
      if (_mark(row['_${name}ClearedStatus']) case final mark when mark > 0)
        'l.${row['_mLiveMusicId']}.$index': mark,
};

int _mark(Object? status) {
  final value = status is num ? status : 0;
  return value >= 30
      ? 3
      : value >= 20
      ? 2
      : value >= 10
      ? 1
      : 0;
}
