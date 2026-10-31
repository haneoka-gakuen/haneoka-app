import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('ko'),
    Locale('zh'),
    Locale('zh', 'TW'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Haneoka'**
  String get appTitle;

  /// No description provided for @importTitle.
  ///
  /// In en, this message translates to:
  /// **'Add game account'**
  String get importTitle;

  /// No description provided for @sourceShizuku.
  ///
  /// In en, this message translates to:
  /// **'This phone · Shizuku'**
  String get sourceShizuku;

  /// No description provided for @sourceGrantFolder.
  ///
  /// In en, this message translates to:
  /// **'This phone · game folder'**
  String get sourceGrantFolder;

  /// No description provided for @sourceFiles.
  ///
  /// In en, this message translates to:
  /// **'Files or folder'**
  String get sourceFiles;

  /// No description provided for @sourceAdb.
  ///
  /// In en, this message translates to:
  /// **'Android phone · USB or Wi-Fi'**
  String get sourceAdb;

  /// No description provided for @sourceIosBackup.
  ///
  /// In en, this message translates to:
  /// **'iPhone or iPad backup'**
  String get sourceIosBackup;

  /// No description provided for @releaseIntlOfficial.
  ///
  /// In en, this message translates to:
  /// **'International · official site'**
  String get releaseIntlOfficial;

  /// No description provided for @releaseIntlStore.
  ///
  /// In en, this message translates to:
  /// **'International · app store'**
  String get releaseIntlStore;

  /// No description provided for @releaseJp.
  ///
  /// In en, this message translates to:
  /// **'Japan'**
  String get releaseJp;

  /// No description provided for @release.
  ///
  /// In en, this message translates to:
  /// **'Release'**
  String get release;

  /// No description provided for @shizukuNotRunning.
  ///
  /// In en, this message translates to:
  /// **'Shizuku is not running'**
  String get shizukuNotRunning;

  /// No description provided for @shizukuUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Shizuku needs updating'**
  String get shizukuUnsupported;

  /// No description provided for @openShizuku.
  ///
  /// In en, this message translates to:
  /// **'Open Shizuku'**
  String get openShizuku;

  /// No description provided for @read.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get read;

  /// No description provided for @reading.
  ///
  /// In en, this message translates to:
  /// **'Reading'**
  String get reading;

  /// No description provided for @noSaves.
  ///
  /// In en, this message translates to:
  /// **'No save found'**
  String get noSaves;

  /// No description provided for @noGameInBackup.
  ///
  /// In en, this message translates to:
  /// **'This backup has no Our Notes data'**
  String get noGameInBackup;

  /// No description provided for @backupPassword.
  ///
  /// In en, this message translates to:
  /// **'Backup password'**
  String get backupPassword;

  /// No description provided for @wrongPassword.
  ///
  /// In en, this message translates to:
  /// **'Wrong backup password'**
  String get wrongPassword;

  /// No description provided for @noBackups.
  ///
  /// In en, this message translates to:
  /// **'No backups'**
  String get noBackups;

  /// No description provided for @chooseBackupFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose backup folder'**
  String get chooseBackupFolder;

  /// No description provided for @encrypted.
  ///
  /// In en, this message translates to:
  /// **'Encrypted'**
  String get encrypted;

  /// No description provided for @devices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get devices;

  /// No description provided for @noDevices.
  ///
  /// In en, this message translates to:
  /// **'No phone connected'**
  String get noDevices;

  /// No description provided for @deviceUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'Allow USB debugging on the phone'**
  String get deviceUnauthorized;

  /// No description provided for @adbMissing.
  ///
  /// In en, this message translates to:
  /// **'adb not found'**
  String get adbMissing;

  /// No description provided for @chooseAdb.
  ///
  /// In en, this message translates to:
  /// **'Choose adb'**
  String get chooseAdb;

  /// No description provided for @getPlatformTools.
  ///
  /// In en, this message translates to:
  /// **'Get platform tools'**
  String get getPlatformTools;

  /// No description provided for @pairWireless.
  ///
  /// In en, this message translates to:
  /// **'Pair over Wi-Fi'**
  String get pairWireless;

  /// No description provided for @pairAddress.
  ///
  /// In en, this message translates to:
  /// **'IP address and port'**
  String get pairAddress;

  /// No description provided for @pairCode.
  ///
  /// In en, this message translates to:
  /// **'Pairing code'**
  String get pairCode;

  /// No description provided for @connectAddress.
  ///
  /// In en, this message translates to:
  /// **'Connect address'**
  String get connectAddress;

  /// No description provided for @pairFailed.
  ///
  /// In en, this message translates to:
  /// **'Pairing failed'**
  String get pairFailed;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @gameNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'Our Notes is not installed'**
  String get gameNotInstalled;

  /// No description provided for @accounts.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get accounts;

  /// No description provided for @playerId.
  ///
  /// In en, this message translates to:
  /// **'Player ID'**
  String get playerId;

  /// No description provided for @savedAt.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get savedAt;

  /// No description provided for @source.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get source;

  /// No description provided for @playerExp.
  ///
  /// In en, this message translates to:
  /// **'Player EXP'**
  String get playerExp;

  /// No description provided for @vipRank.
  ///
  /// In en, this message translates to:
  /// **'T.G.W CARD'**
  String get vipRank;

  /// No description provided for @highScoreRating.
  ///
  /// In en, this message translates to:
  /// **'High score rating'**
  String get highScoreRating;

  /// No description provided for @clears.
  ///
  /// In en, this message translates to:
  /// **'Cleared songs'**
  String get clears;

  /// No description provided for @exportTeam.
  ///
  /// In en, this message translates to:
  /// **'Copy for team builder'**
  String get exportTeam;

  /// No description provided for @exportSave.
  ///
  /// In en, this message translates to:
  /// **'Save as file'**
  String get exportSave;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Game settings'**
  String get settings;

  /// No description provided for @latestLive.
  ///
  /// In en, this message translates to:
  /// **'Latest live'**
  String get latestLive;

  /// No description provided for @entries.
  ///
  /// In en, this message translates to:
  /// **'{count} entries'**
  String entries(int count);

  /// No description provided for @sec_memberCards.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get sec_memberCards;

  /// No description provided for @sec_snapshots.
  ///
  /// In en, this message translates to:
  /// **'Snapshots'**
  String get sec_snapshots;

  /// No description provided for @sec_characters.
  ///
  /// In en, this message translates to:
  /// **'Character ranks'**
  String get sec_characters;

  /// No description provided for @sec_friendships.
  ///
  /// In en, this message translates to:
  /// **'Friendships'**
  String get sec_friendships;

  /// No description provided for @sec_bandItems.
  ///
  /// In en, this message translates to:
  /// **'Band items'**
  String get sec_bandItems;

  /// No description provided for @sec_items.
  ///
  /// In en, this message translates to:
  /// **'Items'**
  String get sec_items;

  /// No description provided for @sec_songs.
  ///
  /// In en, this message translates to:
  /// **'Song results'**
  String get sec_songs;

  /// No description provided for @sec_ratings.
  ///
  /// In en, this message translates to:
  /// **'Rating songs'**
  String get sec_ratings;

  /// No description provided for @sec_challengeSongs.
  ///
  /// In en, this message translates to:
  /// **'Challenge songs'**
  String get sec_challengeSongs;

  /// No description provided for @sec_events.
  ///
  /// In en, this message translates to:
  /// **'Events'**
  String get sec_events;

  /// No description provided for @sec_challengeLives.
  ///
  /// In en, this message translates to:
  /// **'Challenge lives'**
  String get sec_challengeLives;

  /// No description provided for @sec_gacha.
  ///
  /// In en, this message translates to:
  /// **'Gacha'**
  String get sec_gacha;

  /// No description provided for @sec_stories.
  ///
  /// In en, this message translates to:
  /// **'Stories read'**
  String get sec_stories;

  /// No description provided for @sec_decks.
  ///
  /// In en, this message translates to:
  /// **'Teams'**
  String get sec_decks;

  /// No description provided for @sec_missions.
  ///
  /// In en, this message translates to:
  /// **'Missions'**
  String get sec_missions;

  /// No description provided for @sec_limitedMissions.
  ///
  /// In en, this message translates to:
  /// **'Limited missions'**
  String get sec_limitedMissions;

  /// No description provided for @sec_characterMissions.
  ///
  /// In en, this message translates to:
  /// **'Character missions'**
  String get sec_characterMissions;

  /// No description provided for @sec_seasonPass.
  ///
  /// In en, this message translates to:
  /// **'Season pass'**
  String get sec_seasonPass;

  /// No description provided for @sec_monthlyPass.
  ///
  /// In en, this message translates to:
  /// **'Monthly pass'**
  String get sec_monthlyPass;

  /// No description provided for @sec_loginBonuses.
  ///
  /// In en, this message translates to:
  /// **'Login bonuses'**
  String get sec_loginBonuses;

  /// No description provided for @sec_costumes.
  ///
  /// In en, this message translates to:
  /// **'Costumes'**
  String get sec_costumes;

  /// No description provided for @sec_currentCostumes.
  ///
  /// In en, this message translates to:
  /// **'Worn costumes'**
  String get sec_currentCostumes;

  /// No description provided for @sec_backgrounds.
  ///
  /// In en, this message translates to:
  /// **'Backgrounds'**
  String get sec_backgrounds;

  /// No description provided for @sec_stamps.
  ///
  /// In en, this message translates to:
  /// **'Stamps'**
  String get sec_stamps;

  /// No description provided for @sec_degrees.
  ///
  /// In en, this message translates to:
  /// **'Titles'**
  String get sec_degrees;

  /// No description provided for @sec_profileCards.
  ///
  /// In en, this message translates to:
  /// **'Profile cards'**
  String get sec_profileCards;

  /// No description provided for @sec_laneSkins.
  ///
  /// In en, this message translates to:
  /// **'Lane skins'**
  String get sec_laneSkins;

  /// No description provided for @sec_noteSkins.
  ///
  /// In en, this message translates to:
  /// **'Note skins'**
  String get sec_noteSkins;

  /// No description provided for @sec_noteEffectSkins.
  ///
  /// In en, this message translates to:
  /// **'Note effects'**
  String get sec_noteEffectSkins;

  /// No description provided for @sec_noteSounds.
  ///
  /// In en, this message translates to:
  /// **'Note sounds'**
  String get sec_noteSounds;

  /// No description provided for @sec_spots.
  ///
  /// In en, this message translates to:
  /// **'Spots'**
  String get sec_spots;

  /// No description provided for @sec_memory.
  ///
  /// In en, this message translates to:
  /// **'Memories'**
  String get sec_memory;

  /// No description provided for @sec_liveBoost.
  ///
  /// In en, this message translates to:
  /// **'Live boost'**
  String get sec_liveBoost;

  /// No description provided for @sec_liveSkip.
  ///
  /// In en, this message translates to:
  /// **'Live skip'**
  String get sec_liveSkip;

  /// No description provided for @sec_vip.
  ///
  /// In en, this message translates to:
  /// **'T.G.W CARD'**
  String get sec_vip;

  /// No description provided for @sec_offlineBonus.
  ///
  /// In en, this message translates to:
  /// **'Offline bonus'**
  String get sec_offlineBonus;

  /// No description provided for @sec_arena.
  ///
  /// In en, this message translates to:
  /// **'Arena'**
  String get sec_arena;

  /// No description provided for @playerRank.
  ///
  /// In en, this message translates to:
  /// **'Player rank'**
  String get playerRank;

  /// No description provided for @sec_songUnlocks.
  ///
  /// In en, this message translates to:
  /// **'Song unlocks'**
  String get sec_songUnlocks;

  /// No description provided for @sec_challengeUnlocks.
  ///
  /// In en, this message translates to:
  /// **'Challenge song unlocks'**
  String get sec_challengeUnlocks;

  /// No description provided for @sec_friendshipRewards.
  ///
  /// In en, this message translates to:
  /// **'Bond rewards'**
  String get sec_friendshipRewards;

  /// No description provided for @sec_stampFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favourite stamps'**
  String get sec_stampFavorites;

  /// No description provided for @sec_exchange.
  ///
  /// In en, this message translates to:
  /// **'Exchange'**
  String get sec_exchange;

  /// No description provided for @sec_shop.
  ///
  /// In en, this message translates to:
  /// **'Shop'**
  String get sec_shop;

  /// No description provided for @importHeadline.
  ///
  /// In en, this message translates to:
  /// **'Read your Our Notes game account'**
  String get importHeadline;

  /// No description provided for @importIntro.
  ///
  /// In en, this message translates to:
  /// **'Haneoka reads the save the game keeps on your device and shows your rank, cards, song clears and items. The save stays on this device; exports leave out your name and account ID.'**
  String get importIntro;

  /// No description provided for @versionQuestion.
  ///
  /// In en, this message translates to:
  /// **'Which version do you play?'**
  String get versionQuestion;

  /// No description provided for @versionHint.
  ///
  /// In en, this message translates to:
  /// **'Used for files that don\'t say which version they come from.'**
  String get versionHint;

  /// No description provided for @methodsTitle.
  ///
  /// In en, this message translates to:
  /// **'How to read it'**
  String get methodsTitle;

  /// No description provided for @recommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended'**
  String get recommended;

  /// No description provided for @stepsShow.
  ///
  /// In en, this message translates to:
  /// **'Steps'**
  String get stepsShow;

  /// No description provided for @methodShizukuTitle.
  ///
  /// In en, this message translates to:
  /// **'This phone, with Shizuku'**
  String get methodShizukuTitle;

  /// No description provided for @methodShizukuSummary.
  ///
  /// In en, this message translates to:
  /// **'Reads the game\'s save directly. Needs the Shizuku app running.'**
  String get methodShizukuSummary;

  /// No description provided for @methodShizukuSteps.
  ///
  /// In en, this message translates to:
  /// **'Install Shizuku and start it with wireless debugging or root.\nTap Read save, then allow Haneoka when Shizuku asks.'**
  String get methodShizukuSteps;

  /// No description provided for @methodFolderTitle.
  ///
  /// In en, this message translates to:
  /// **'This phone, game folder access'**
  String get methodFolderTitle;

  /// No description provided for @methodFolderSummary.
  ///
  /// In en, this message translates to:
  /// **'On Android 13 and earlier you can let Haneoka read the game\'s data folder once; later reads need no setup.'**
  String get methodFolderSummary;

  /// No description provided for @methodFolderSteps.
  ///
  /// In en, this message translates to:
  /// **'Choose the version above, then tap Choose folder.\nIn the system picker that opens on the game\'s folder, tap Use this folder and Allow.'**
  String get methodFolderSteps;

  /// No description provided for @methodFilesTitle.
  ///
  /// In en, this message translates to:
  /// **'From copied files'**
  String get methodFilesTitle;

  /// No description provided for @methodFilesSummary.
  ///
  /// In en, this message translates to:
  /// **'A save copied off a device: the game\'s files folder, a ZIP of it, an iPhone app export (.imazingapp), or a Haneoka export.'**
  String get methodFilesSummary;

  /// No description provided for @methodFilesSteps.
  ///
  /// In en, this message translates to:
  /// **'Android: copy Android/data/<game>/files to this device with a file manager or a computer.\niPhone: on a computer, open iMazing, select Our Notes and export its app data.\nTap Choose files (or Choose folder) and pick what you copied.'**
  String get methodFilesSteps;

  /// No description provided for @methodBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'iPhone or iPad backup'**
  String get methodBackupTitle;

  /// No description provided for @methodBackupSummary.
  ///
  /// In en, this message translates to:
  /// **'Reads a Finder or iTunes backup of your iPhone or iPad on this computer.'**
  String get methodBackupSummary;

  /// No description provided for @methodBackupSteps.
  ///
  /// In en, this message translates to:
  /// **'Back up the device to this computer in Finder or iTunes. Encrypted backups work; you\'ll be asked for the password.\nTap Open backups and choose the device.'**
  String get methodBackupSteps;

  /// No description provided for @methodAdbTitle.
  ///
  /// In en, this message translates to:
  /// **'Android phone, over USB or Wi-Fi'**
  String get methodAdbTitle;

  /// No description provided for @methodAdbSummary.
  ///
  /// In en, this message translates to:
  /// **'Bundled ADB reads saves from this computer’s connected Android phone.'**
  String get methodAdbSummary;

  /// No description provided for @methodAdbSteps.
  ///
  /// In en, this message translates to:
  /// **'Enable Developer options and USB debugging on the phone.\nConnect by cable and approve this computer, then tap Read connected device.\nFor multiple phones or Wi-Fi pairing, use Choose device / wireless pairing.'**
  String get methodAdbSteps;

  /// No description provided for @iosNote.
  ///
  /// In en, this message translates to:
  /// **'iOS doesn\'t let one app read another app\'s data, so on iPhone the save comes from a copy made on a computer.'**
  String get iosNote;

  /// No description provided for @readSave.
  ///
  /// In en, this message translates to:
  /// **'Read save'**
  String get readSave;

  /// No description provided for @chooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose folder'**
  String get chooseFolder;

  /// No description provided for @chooseFiles.
  ///
  /// In en, this message translates to:
  /// **'Choose files'**
  String get chooseFiles;

  /// No description provided for @openBackups.
  ///
  /// In en, this message translates to:
  /// **'Open backups'**
  String get openBackups;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @readAgain.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get readAgain;

  /// No description provided for @importedAccounts.
  ///
  /// In en, this message translates to:
  /// **'Game accounts'**
  String get importedAccounts;

  /// No description provided for @savedOn.
  ///
  /// In en, this message translates to:
  /// **'Saved {time}'**
  String savedOn(String time);

  /// No description provided for @removeAccount.
  ///
  /// In en, this message translates to:
  /// **'Remove from this device'**
  String get removeAccount;

  /// No description provided for @removeAccountConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from Haneoka? The game\'s own save is not touched.'**
  String removeAccountConfirm(String name);

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @importMore.
  ///
  /// In en, this message translates to:
  /// **'Add game account'**
  String get importMore;

  /// No description provided for @foundAccounts.
  ///
  /// In en, this message translates to:
  /// **'{count} game accounts found'**
  String foundAccounts(int count);

  /// No description provided for @profileOverview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get profileOverview;

  /// No description provided for @songClears.
  ///
  /// In en, this message translates to:
  /// **'Song clears'**
  String get songClears;

  /// No description provided for @cleared.
  ///
  /// In en, this message translates to:
  /// **'Cleared'**
  String get cleared;

  /// No description provided for @fullCombo.
  ///
  /// In en, this message translates to:
  /// **'Full combo'**
  String get fullCombo;

  /// No description provided for @allPerfect.
  ///
  /// In en, this message translates to:
  /// **'All perfect'**
  String get allPerfect;

  /// No description provided for @ofSongs.
  ///
  /// In en, this message translates to:
  /// **'of {total}'**
  String ofSongs(String total);

  /// No description provided for @ownedMembers.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get ownedMembers;

  /// No description provided for @ownedSnapshots.
  ///
  /// In en, this message translates to:
  /// **'Snapshots'**
  String get ownedSnapshots;

  /// No description provided for @viewAll.
  ///
  /// In en, this message translates to:
  /// **'View all'**
  String get viewAll;

  /// No description provided for @currencies.
  ///
  /// In en, this message translates to:
  /// **'Items'**
  String get currencies;

  /// No description provided for @eventsPlayed.
  ///
  /// In en, this message translates to:
  /// **'Events'**
  String get eventsPlayed;

  /// No description provided for @eventPoints.
  ///
  /// In en, this message translates to:
  /// **'{points} pt'**
  String eventPoints(String points);

  /// No description provided for @exportsTitle.
  ///
  /// In en, this message translates to:
  /// **'Use it elsewhere'**
  String get exportsTitle;

  /// No description provided for @exportTeamHint.
  ///
  /// In en, this message translates to:
  /// **'Your cards and progress for the team builder.'**
  String get exportTeamHint;

  /// No description provided for @exportSaveHint.
  ///
  /// In en, this message translates to:
  /// **'The whole save as JSON, without your name or account ID.'**
  String get exportSaveHint;

  /// No description provided for @rawData.
  ///
  /// In en, this message translates to:
  /// **'Raw data'**
  String get rawData;

  /// No description provided for @copyId.
  ///
  /// In en, this message translates to:
  /// **'Copy ID'**
  String get copyId;

  /// No description provided for @tutorialDone.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get tutorialDone;

  /// No description provided for @noAccountsYet.
  ///
  /// In en, this message translates to:
  /// **'No game accounts yet'**
  String get noAccountsYet;

  /// No description provided for @haneokaAccount.
  ///
  /// In en, this message translates to:
  /// **'Haneoka account'**
  String get haneokaAccount;

  /// No description provided for @haneokaAccountSummary.
  ///
  /// In en, this message translates to:
  /// **'Sign in to show your game accounts on your public profile.'**
  String get haneokaAccountSummary;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// No description provided for @signInFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not sign in'**
  String get signInFailed;

  /// No description provided for @profileLink.
  ///
  /// In en, this message translates to:
  /// **'Public profile'**
  String get profileLink;

  /// No description provided for @linkToProfile.
  ///
  /// In en, this message translates to:
  /// **'Link to my account'**
  String get linkToProfile;

  /// No description provided for @linkSignInFirst.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your Haneoka account to link this player.'**
  String get linkSignInFirst;

  /// No description provided for @linkExplain.
  ///
  /// In en, this message translates to:
  /// **'Only the player ID, name, rank, rating, collection counts and song clears are sent. The save itself stays on this device.'**
  String get linkExplain;

  /// No description provided for @linked.
  ///
  /// In en, this message translates to:
  /// **'Linked'**
  String get linked;

  /// No description provided for @showOnProfile.
  ///
  /// In en, this message translates to:
  /// **'Show on my public profile'**
  String get showOnProfile;

  /// No description provided for @syncNow.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get syncNow;

  /// No description provided for @unlink.
  ///
  /// In en, this message translates to:
  /// **'Unlink'**
  String get unlink;

  /// No description provided for @unlinkConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove this player from your Haneoka account?'**
  String get unlinkConfirm;

  /// No description provided for @linkedElsewhere.
  ///
  /// In en, this message translates to:
  /// **'This player is linked to another account'**
  String get linkedElsewhere;

  /// No description provided for @linkFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the link'**
  String get linkFailed;

  /// No description provided for @linkUpdated.
  ///
  /// In en, this message translates to:
  /// **'Link updated'**
  String get linkUpdated;

  /// No description provided for @syncedOn.
  ///
  /// In en, this message translates to:
  /// **'Updated {date}'**
  String syncedOn(String date);

  /// No description provided for @openProfile.
  ///
  /// In en, this message translates to:
  /// **'Open profile'**
  String get openProfile;

  /// Team builder: importing cards needs a read save of the selected server.
  ///
  /// In en, this message translates to:
  /// **'No game account for this server yet.'**
  String get teamBuilderNoSave;

  /// No description provided for @updateSave.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get updateSave;

  /// No description provided for @updateSaveHint.
  ///
  /// In en, this message translates to:
  /// **'Reads this game account\'s latest save and replaces the stored copy. Other game accounts stay unchanged.'**
  String get updateSaveHint;

  /// No description provided for @importToTeamBuilder.
  ///
  /// In en, this message translates to:
  /// **'Import to team builder'**
  String get importToTeamBuilder;

  /// No description provided for @importToTeamHint.
  ///
  /// In en, this message translates to:
  /// **'Review and import cards, snapshots, character levels and band items directly from this save.'**
  String get importToTeamHint;

  /// No description provided for @saveAccountMismatch.
  ///
  /// In en, this message translates to:
  /// **'This save belongs to another game account or server. Choose a save for this game account.'**
  String get saveAccountMismatch;

  /// No description provided for @saveUpdated.
  ///
  /// In en, this message translates to:
  /// **'Game account updated'**
  String get saveUpdated;

  /// No description provided for @syncFromGame.
  ///
  /// In en, this message translates to:
  /// **'Sync from game'**
  String get syncFromGame;

  /// No description provided for @syncedFromGame.
  ///
  /// In en, this message translates to:
  /// **'Synced from the game'**
  String get syncedFromGame;

  /// No description provided for @syncSessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Sign-in expired. Read the save again.'**
  String get syncSessionExpired;

  /// No description provided for @syncUnrecognized.
  ///
  /// In en, this message translates to:
  /// **'The game\'s data couldn\'t be read.'**
  String get syncUnrecognized;

  /// No description provided for @syncFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach the game server.'**
  String get syncFailed;

  /// No description provided for @cardSort.
  ///
  /// In en, this message translates to:
  /// **'Card order'**
  String get cardSort;

  /// No description provided for @sortRarity.
  ///
  /// In en, this message translates to:
  /// **'Rarity'**
  String get sortRarity;

  /// No description provided for @sortNewest.
  ///
  /// In en, this message translates to:
  /// **'Newest cards'**
  String get sortNewest;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'ko', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'TW':
            return AppLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'ko':
      return AppLocalizationsKo();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
