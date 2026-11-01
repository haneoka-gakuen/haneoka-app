import '../save/export.dart';
import '../save/game_save.dart';

/// A save sent to the website's team builder from a native screen; the page
/// asks for it once it has opened (`pendingBoxImport`).
class PendingImport {
  PendingImport._();
  static ({String server, String text})? _value;

  static void set(GameSave save) =>
      _value = (server: save.server ?? 'intl', text: exportTeamPackage(save));

  static ({String server, String text})? take() {
    final value = _value;
    _value = null;
    return value;
  }
}

/// Gacha history read from the game server on a native screen, taken by the
/// website's gacha history page once it has opened (`pendingGachaHistory`).
class PendingHistory {
  PendingHistory._();
  static List<({String name, String text})>? _files;

  static void set(List<({String name, String text})> files) => _files = files;

  static List<({String name, String text})>? take() {
    final value = _files;
    _files = null;
    return value;
  }
}

/// Song progress from a native save page, taken by the website's song
/// progress page once it has opened (`pendingSongProgress`).
class PendingProgress {
  PendingProgress._();
  static Map<String, int>? _marks;

  static void set(Map<String, int> marks) => _marks = marks;

  static Map<String, int>? take() {
    final value = _marks;
    _marks = null;
    return value;
  }
}
