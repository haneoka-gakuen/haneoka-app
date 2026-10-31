// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Haneoka';

  @override
  String get importTitle => 'Add game account';

  @override
  String get sourceShizuku => 'This phone · Shizuku';

  @override
  String get sourceGrantFolder => 'This phone · game folder';

  @override
  String get sourceFiles => 'Files or folder';

  @override
  String get sourceAdb => 'Android phone · USB or Wi-Fi';

  @override
  String get sourceIosBackup => 'iPhone or iPad backup';

  @override
  String get releaseIntlOfficial => 'International · official site';

  @override
  String get releaseIntlStore => 'International · app store';

  @override
  String get releaseJp => 'Japan';

  @override
  String get release => 'Release';

  @override
  String get shizukuNotRunning => 'Shizuku is not running';

  @override
  String get shizukuUnsupported => 'Shizuku needs updating';

  @override
  String get openShizuku => 'Open Shizuku';

  @override
  String get read => 'Read';

  @override
  String get reading => 'Reading';

  @override
  String get noSaves => 'No save found';

  @override
  String get noGameInBackup => 'This backup has no Our Notes data';

  @override
  String get backupPassword => 'Backup password';

  @override
  String get wrongPassword => 'Wrong backup password';

  @override
  String get noBackups => 'No backups';

  @override
  String get chooseBackupFolder => 'Choose backup folder';

  @override
  String get encrypted => 'Encrypted';

  @override
  String get devices => 'Devices';

  @override
  String get noDevices => 'No phone connected';

  @override
  String get deviceUnauthorized => 'Allow USB debugging on the phone';

  @override
  String get adbMissing => 'adb not found';

  @override
  String get chooseAdb => 'Choose adb';

  @override
  String get getPlatformTools => 'Get platform tools';

  @override
  String get pairWireless => 'Pair over Wi-Fi';

  @override
  String get pairAddress => 'IP address and port';

  @override
  String get pairCode => 'Pairing code';

  @override
  String get connectAddress => 'Connect address';

  @override
  String get pairFailed => 'Pairing failed';

  @override
  String get refresh => 'Refresh';

  @override
  String get gameNotInstalled => 'Our Notes is not installed';

  @override
  String get accounts => 'Accounts';

  @override
  String get playerId => 'Player ID';

  @override
  String get savedAt => 'Saved';

  @override
  String get source => 'Source';

  @override
  String get playerExp => 'Player EXP';

  @override
  String get vipRank => 'T.G.W CARD';

  @override
  String get highScoreRating => 'High score rating';

  @override
  String get clears => 'Cleared songs';

  @override
  String get exportTeam => 'Copy for team builder';

  @override
  String get exportSave => 'Save as file';

  @override
  String get copied => 'Copied';

  @override
  String get saved => 'Saved';

  @override
  String get settings => 'Game settings';

  @override
  String get latestLive => 'Latest live';

  @override
  String entries(int count) {
    return '$count entries';
  }

  @override
  String get sec_memberCards => 'Members';

  @override
  String get sec_snapshots => 'Snapshots';

  @override
  String get sec_characters => 'Character ranks';

  @override
  String get sec_friendships => 'Friendships';

  @override
  String get sec_bandItems => 'Band items';

  @override
  String get sec_items => 'Items';

  @override
  String get sec_songs => 'Song results';

  @override
  String get sec_ratings => 'Rating songs';

  @override
  String get sec_challengeSongs => 'Challenge songs';

  @override
  String get sec_events => 'Events';

  @override
  String get sec_challengeLives => 'Challenge lives';

  @override
  String get sec_gacha => 'Gacha';

  @override
  String get sec_stories => 'Stories read';

  @override
  String get sec_decks => 'Teams';

  @override
  String get sec_missions => 'Missions';

  @override
  String get sec_limitedMissions => 'Limited missions';

  @override
  String get sec_characterMissions => 'Character missions';

  @override
  String get sec_seasonPass => 'Season pass';

  @override
  String get sec_monthlyPass => 'Monthly pass';

  @override
  String get sec_loginBonuses => 'Login bonuses';

  @override
  String get sec_costumes => 'Costumes';

  @override
  String get sec_currentCostumes => 'Worn costumes';

  @override
  String get sec_backgrounds => 'Backgrounds';

  @override
  String get sec_stamps => 'Stamps';

  @override
  String get sec_degrees => 'Titles';

  @override
  String get sec_profileCards => 'Profile cards';

  @override
  String get sec_laneSkins => 'Lane skins';

  @override
  String get sec_noteSkins => 'Note skins';

  @override
  String get sec_noteEffectSkins => 'Note effects';

  @override
  String get sec_noteSounds => 'Note sounds';

  @override
  String get sec_spots => 'Spots';

  @override
  String get sec_memory => 'Memories';

  @override
  String get sec_liveBoost => 'Live boost';

  @override
  String get sec_liveSkip => 'Live skip';

  @override
  String get sec_vip => 'T.G.W CARD';

  @override
  String get sec_offlineBonus => 'Offline bonus';

  @override
  String get sec_arena => 'Arena';

  @override
  String get playerRank => 'Player rank';

  @override
  String get sec_songUnlocks => 'Song unlocks';

  @override
  String get sec_challengeUnlocks => 'Challenge song unlocks';

  @override
  String get sec_friendshipRewards => 'Bond rewards';

  @override
  String get sec_stampFavorites => 'Favourite stamps';

  @override
  String get sec_exchange => 'Exchange';

  @override
  String get sec_shop => 'Shop';

  @override
  String get importHeadline => 'Read your Our Notes game account';

  @override
  String get importIntro =>
      'Haneoka reads the save the game keeps on your device and shows your rank, cards, song clears and items. The save stays on this device; exports leave out your name and account ID.';

  @override
  String get versionQuestion => 'Which version do you play?';

  @override
  String get versionHint =>
      'Used for files that don\'t say which version they come from.';

  @override
  String get methodsTitle => 'How to read it';

  @override
  String get recommended => 'Recommended';

  @override
  String get stepsShow => 'Steps';

  @override
  String get methodShizukuTitle => 'This phone, with Shizuku';

  @override
  String get methodShizukuSummary =>
      'Reads the game\'s save directly. Needs the Shizuku app running.';

  @override
  String get methodShizukuSteps =>
      'Install Shizuku and start it with wireless debugging or root.\nTap Read save, then allow Haneoka when Shizuku asks.';

  @override
  String get methodFolderTitle => 'This phone, game folder access';

  @override
  String get methodFolderSummary =>
      'On Android 13 and earlier you can let Haneoka read the game\'s data folder once; later reads need no setup.';

  @override
  String get methodFolderSteps =>
      'Choose the version above, then tap Choose folder.\nIn the system picker that opens on the game\'s folder, tap Use this folder and Allow.';

  @override
  String get methodFilesTitle => 'From copied files';

  @override
  String get methodFilesSummary =>
      'A save copied off a device: the game\'s files folder, a ZIP of it, an iPhone app export (.imazingapp), or a Haneoka export.';

  @override
  String get methodFilesSteps =>
      'Android: copy Android/data/<game>/files to this device with a file manager or a computer.\niPhone: on a computer, open iMazing, select Our Notes and export its app data.\nTap Choose files (or Choose folder) and pick what you copied.';

  @override
  String get methodBackupTitle => 'iPhone or iPad backup';

  @override
  String get methodBackupSummary =>
      'Reads a Finder or iTunes backup of your iPhone or iPad on this computer.';

  @override
  String get methodBackupSteps =>
      'Back up the device to this computer in Finder or iTunes. Encrypted backups work; you\'ll be asked for the password.\nTap Open backups and choose the device.';

  @override
  String get methodAdbTitle => 'Android phone, over USB or Wi-Fi';

  @override
  String get methodAdbSummary =>
      'Bundled ADB reads saves from this computer’s connected Android phone.';

  @override
  String get methodAdbSteps =>
      'Enable Developer options and USB debugging on the phone.\nConnect by cable and approve this computer, then tap Read connected device.\nFor multiple phones or Wi-Fi pairing, use Choose device / wireless pairing.';

  @override
  String get iosNote =>
      'iOS doesn\'t let one app read another app\'s data, so on iPhone the save comes from a copy made on a computer.';

  @override
  String get readSave => 'Read save';

  @override
  String get chooseFolder => 'Choose folder';

  @override
  String get chooseFiles => 'Choose files';

  @override
  String get openBackups => 'Open backups';

  @override
  String get connect => 'Connect';

  @override
  String get readAgain => 'Read again';

  @override
  String get importedAccounts => 'Game accounts';

  @override
  String savedOn(String time) {
    return 'Saved $time';
  }

  @override
  String get removeAccount => 'Remove from this device';

  @override
  String removeAccountConfirm(String name) {
    return 'Remove $name from Haneoka? The game\'s own save is not touched.';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get remove => 'Remove';

  @override
  String get importMore => 'Add game account';

  @override
  String foundAccounts(int count) {
    return '$count game accounts found';
  }

  @override
  String get profileOverview => 'Overview';

  @override
  String get songClears => 'Song clears';

  @override
  String get cleared => 'Cleared';

  @override
  String get fullCombo => 'Full combo';

  @override
  String get allPerfect => 'All perfect';

  @override
  String ofSongs(String total) {
    return 'of $total';
  }

  @override
  String get ownedMembers => 'Members';

  @override
  String get ownedSnapshots => 'Snapshots';

  @override
  String get viewAll => 'View all';

  @override
  String get currencies => 'Items';

  @override
  String get eventsPlayed => 'Events';

  @override
  String eventPoints(String points) {
    return '$points pt';
  }

  @override
  String get exportsTitle => 'Use it elsewhere';

  @override
  String get exportTeamHint => 'Your cards and progress for the team builder.';

  @override
  String get exportSaveHint =>
      'The whole save as JSON, without your name or account ID.';

  @override
  String get rawData => 'Raw data';

  @override
  String get copyId => 'Copy ID';

  @override
  String get tutorialDone => 'Started';

  @override
  String get noAccountsYet => 'No game accounts yet';

  @override
  String get haneokaAccount => 'Haneoka account';

  @override
  String get haneokaAccountSummary =>
      'Sign in to show your game accounts on your public profile.';

  @override
  String get signIn => 'Sign in';

  @override
  String get signOut => 'Sign out';

  @override
  String get signInFailed => 'Could not sign in';

  @override
  String get profileLink => 'Public profile';

  @override
  String get linkToProfile => 'Link to my account';

  @override
  String get linkSignInFirst =>
      'Sign in to your Haneoka account to link this player.';

  @override
  String get linkExplain =>
      'Only the player ID, name, rank, rating, collection counts and song clears are sent. The save itself stays on this device.';

  @override
  String get linked => 'Linked';

  @override
  String get showOnProfile => 'Show on my public profile';

  @override
  String get syncNow => 'Update';

  @override
  String get unlink => 'Unlink';

  @override
  String get unlinkConfirm => 'Remove this player from your Haneoka account?';

  @override
  String get linkedElsewhere => 'This player is linked to another account';

  @override
  String get linkFailed => 'Could not update the link';

  @override
  String get linkUpdated => 'Link updated';

  @override
  String syncedOn(String date) {
    return 'Updated $date';
  }

  @override
  String get openProfile => 'Open profile';

  @override
  String get teamBuilderNoSave => 'No game account for this server yet.';

  @override
  String get updateSave => 'Read again';

  @override
  String get updateSaveHint =>
      'Reads this game account\'s latest save and replaces the stored copy. Other game accounts stay unchanged.';

  @override
  String get importToTeamBuilder => 'Import to team builder';

  @override
  String get importToTeamHint =>
      'Review and import cards, snapshots, character levels and band items directly from this save.';

  @override
  String get saveAccountMismatch =>
      'This save belongs to another game account or server. Choose a save for this game account.';

  @override
  String get saveUpdated => 'Game account updated';

  @override
  String get syncFromGame => 'Sync from game';

  @override
  String get syncedFromGame => 'Synced from the game';

  @override
  String get syncSessionExpired => 'Sign-in expired. Read the save again.';

  @override
  String get syncUnrecognized => 'The game\'s data couldn\'t be read.';

  @override
  String get syncFailed => 'Couldn\'t reach the game server.';

  @override
  String get cardSort => 'Card order';

  @override
  String get sortRarity => 'Rarity';

  @override
  String get sortNewest => 'Newest cards';
}
