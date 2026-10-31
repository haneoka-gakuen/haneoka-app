// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'Haneoka';

  @override
  String get importTitle => 'ゲームアカウントを追加';

  @override
  String get sourceShizuku => 'この端末 · Shizuku';

  @override
  String get sourceGrantFolder => 'この端末 · ゲームフォルダ';

  @override
  String get sourceFiles => 'ファイルまたはフォルダ';

  @override
  String get sourceAdb => 'Android 端末 · USB または Wi-Fi';

  @override
  String get sourceIosBackup => 'iPhone / iPad のバックアップ';

  @override
  String get releaseIntlOfficial => 'グローバル版 · 公式サイト版';

  @override
  String get releaseIntlStore => 'グローバル版 · ストア版';

  @override
  String get releaseJp => '日本版';

  @override
  String get release => 'リリース';

  @override
  String get shizukuNotRunning => 'Shizuku が起動していません';

  @override
  String get shizukuUnsupported => 'Shizuku の更新が必要です';

  @override
  String get openShizuku => 'Shizuku を開く';

  @override
  String get read => '読み込む';

  @override
  String get reading => '読み込み中';

  @override
  String get noSaves => 'セーブが見つかりません';

  @override
  String get noGameInBackup => 'このバックアップにアワーノーツのデータはありません';

  @override
  String get backupPassword => 'バックアップのパスワード';

  @override
  String get wrongPassword => 'バックアップのパスワードが違います';

  @override
  String get noBackups => 'バックアップがありません';

  @override
  String get chooseBackupFolder => 'バックアップフォルダを選ぶ';

  @override
  String get encrypted => '暗号化';

  @override
  String get devices => '端末';

  @override
  String get noDevices => '端末が接続されていません';

  @override
  String get deviceUnauthorized => '端末で USB デバッグを許可してください';

  @override
  String get adbMissing => 'adb が見つかりません';

  @override
  String get chooseAdb => 'adb を選ぶ';

  @override
  String get getPlatformTools => 'Platform Tools を入手';

  @override
  String get pairWireless => 'Wi-Fi でペア設定';

  @override
  String get pairAddress => 'IP アドレスとポート';

  @override
  String get pairCode => 'ペア設定コード';

  @override
  String get connectAddress => '接続アドレス';

  @override
  String get pairFailed => 'ペア設定に失敗しました';

  @override
  String get refresh => '更新';

  @override
  String get gameNotInstalled => 'アワーノーツがインストールされていません';

  @override
  String get accounts => 'アカウント';

  @override
  String get playerId => 'プレイヤー ID';

  @override
  String get savedAt => '保存日時';

  @override
  String get source => '読み込み元';

  @override
  String get playerExp => 'プレイヤー経験値';

  @override
  String get vipRank => 'T.G.W CARD';

  @override
  String get highScoreRating => 'ハイスコアレーティング';

  @override
  String get clears => 'クリア楽曲';

  @override
  String get exportTeam => '編成ツール用にコピー';

  @override
  String get exportSave => 'ファイルに保存';

  @override
  String get copied => 'コピーしました';

  @override
  String get saved => '保存しました';

  @override
  String get settings => 'ゲーム設定';

  @override
  String get latestLive => '最新のライブ';

  @override
  String entries(int count) {
    return '$count 件';
  }

  @override
  String get sec_memberCards => 'メンバー';

  @override
  String get sec_snapshots => 'スナップ';

  @override
  String get sec_characters => 'キャラクターランク';

  @override
  String get sec_friendships => '親密度';

  @override
  String get sec_bandItems => 'バンドアイテム';

  @override
  String get sec_items => 'アイテム';

  @override
  String get sec_songs => '楽曲記録';

  @override
  String get sec_ratings => 'レーティング対象曲';

  @override
  String get sec_challengeSongs => 'チャレンジ楽曲';

  @override
  String get sec_events => 'イベント';

  @override
  String get sec_challengeLives => 'チャレンジライブ';

  @override
  String get sec_gacha => 'ガチャ';

  @override
  String get sec_stories => '既読ストーリー';

  @override
  String get sec_decks => '編成';

  @override
  String get sec_missions => 'ミッション';

  @override
  String get sec_limitedMissions => '期間限定ミッション';

  @override
  String get sec_characterMissions => 'キャラクターミッション';

  @override
  String get sec_seasonPass => 'シーズンパス';

  @override
  String get sec_monthlyPass => 'マンスリーパス';

  @override
  String get sec_loginBonuses => 'ログインボーナス';

  @override
  String get sec_costumes => '衣装';

  @override
  String get sec_currentCostumes => '着用中の衣装';

  @override
  String get sec_backgrounds => '背景';

  @override
  String get sec_stamps => 'スタンプ';

  @override
  String get sec_degrees => '称号';

  @override
  String get sec_profileCards => 'プロフィールカード';

  @override
  String get sec_laneSkins => 'レーンスキン';

  @override
  String get sec_noteSkins => 'ノーツスキン';

  @override
  String get sec_noteEffectSkins => 'ノーツエフェクト';

  @override
  String get sec_noteSounds => 'ノーツ SE';

  @override
  String get sec_spots => 'スポット';

  @override
  String get sec_memory => 'メモリー';

  @override
  String get sec_liveBoost => 'ライブブースト';

  @override
  String get sec_liveSkip => 'ライブスキップ';

  @override
  String get sec_vip => 'T.G.W CARD';

  @override
  String get sec_offlineBonus => 'オフラインボーナス';

  @override
  String get sec_arena => 'アリーナ';

  @override
  String get playerRank => 'プレイヤーランク';

  @override
  String get sec_songUnlocks => '楽曲解放';

  @override
  String get sec_challengeUnlocks => 'チャレンジ楽曲解放';

  @override
  String get sec_friendshipRewards => '絆報酬';

  @override
  String get sec_stampFavorites => 'お気に入りスタンプ';

  @override
  String get sec_exchange => '交換所';

  @override
  String get sec_shop => 'ショップ';

  @override
  String get importHeadline => 'Our Notes のゲームアカウントを読み込む';

  @override
  String get importIntro =>
      'ゲームが端末に保存しているセーブを読み込み、ランク・カード・楽曲クリア・アイテムを表示します。セーブはこの端末にだけ残り、書き出しには名前とアカウント ID を含めません。';

  @override
  String get versionQuestion => 'どのバージョンで遊んでいますか？';

  @override
  String get versionHint => 'バージョンが分からないファイルに使います。';

  @override
  String get methodsTitle => '読み込み方法';

  @override
  String get recommended => 'おすすめ';

  @override
  String get stepsShow => '手順';

  @override
  String get methodShizukuTitle => 'この端末 · Shizuku で';

  @override
  String get methodShizukuSummary => 'ゲームのセーブを直接読み込みます。Shizuku の起動が必要です。';

  @override
  String get methodShizukuSteps =>
      'Shizuku をインストールし、ワイヤレスデバッグか root で起動します。\n「セーブを読み込む」を押し、Shizuku の確認で Haneoka を許可します。';

  @override
  String get methodFolderTitle => 'この端末 · ゲームフォルダの許可';

  @override
  String get methodFolderSummary =>
      'Android 13 以前ではゲームのデータフォルダへのアクセスを一度許可すれば、以後は設定なしで読み込めます。';

  @override
  String get methodFolderSteps =>
      '上でバージョンを選び、「フォルダを選ぶ」を押します。\nゲームのフォルダが開いたら「このフォルダを使用」を押して許可します。';

  @override
  String get methodFilesTitle => 'コピーしたファイルから';

  @override
  String get methodFilesSummary =>
      '端末からコピーしたセーブ：ゲームの files フォルダ、その ZIP、iPhone アプリの書き出し（.imazingapp）、Haneoka の書き出しファイル。';

  @override
  String get methodFilesSteps =>
      'Android：ファイルマネージャーかパソコンで Android/data/<ゲーム>/files をこの端末にコピーします。\niPhone：パソコンで iMazing を開き、Our Notes を選んでアプリのデータを書き出します。\n「ファイルを選ぶ」（または「フォルダを選ぶ」）でコピーしたものを選びます。';

  @override
  String get methodBackupTitle => 'iPhone / iPad のバックアップ';

  @override
  String get methodBackupSummary =>
      'このパソコンにある iPhone / iPad の Finder・iTunes バックアップを読み込みます。';

  @override
  String get methodBackupSteps =>
      'Finder か iTunes で端末をこのパソコンにバックアップします。暗号化したバックアップも読み込めます（パスワードを尋ねます）。\n「バックアップを開く」を押して端末を選びます。';

  @override
  String get methodAdbTitle => 'Android 端末 · USB または Wi-Fi';

  @override
  String get methodAdbSummary => '同梱の ADB で、このパソコンに接続した Android 端末のセーブを読み込みます。';

  @override
  String get methodAdbSteps =>
      '端末で開発者向けオプションと USB デバッグをオンにします。\nケーブルで接続してこのパソコンを許可し、「接続済み端末から読み込む」を押します。\n複数の端末や Wi-Fi 接続は「端末を選択／無線ペア設定」を使用します。';

  @override
  String get iosNote => 'iOS では他のアプリのデータを読めないため、iPhone ではパソコンで書き出したコピーを使います。';

  @override
  String get readSave => 'セーブを読み込む';

  @override
  String get chooseFolder => 'フォルダを選ぶ';

  @override
  String get chooseFiles => 'ファイルを選ぶ';

  @override
  String get openBackups => 'バックアップを開く';

  @override
  String get connect => '接続';

  @override
  String get readAgain => 'もう一度読み込む';

  @override
  String get importedAccounts => 'ゲームアカウント';

  @override
  String savedOn(String time) {
    return '$time のセーブ';
  }

  @override
  String get removeAccount => 'この端末から削除';

  @override
  String removeAccountConfirm(String name) {
    return '$name を Haneoka から削除しますか？ゲーム本体のセーブには影響しません。';
  }

  @override
  String get cancel => 'キャンセル';

  @override
  String get remove => '削除';

  @override
  String get importMore => 'ゲームアカウントを追加';

  @override
  String foundAccounts(int count) {
    return '$count 件のゲームアカウントが見つかりました';
  }

  @override
  String get profileOverview => '概要';

  @override
  String get songClears => '楽曲クリア';

  @override
  String get cleared => 'クリア';

  @override
  String get fullCombo => 'フルコンボ';

  @override
  String get allPerfect => 'オールパーフェクト';

  @override
  String ofSongs(String total) {
    return '/ $total';
  }

  @override
  String get ownedMembers => 'メンバー';

  @override
  String get ownedSnapshots => 'スナップ';

  @override
  String get viewAll => 'すべて見る';

  @override
  String get currencies => 'アイテム';

  @override
  String get eventsPlayed => 'イベント';

  @override
  String eventPoints(String points) {
    return '$points pt';
  }

  @override
  String get exportsTitle => 'ほかで使う';

  @override
  String get exportTeamHint => 'チームビルダー用のカードと進捗。';

  @override
  String get exportSaveHint => '名前とアカウント ID を除いたセーブ全体の JSON。';

  @override
  String get rawData => '生データ';

  @override
  String get copyId => 'ID をコピー';

  @override
  String get tutorialDone => 'プレイ開始';

  @override
  String get noAccountsYet => 'まだゲームアカウントがありません';

  @override
  String get haneokaAccount => 'Haneoka アカウント';

  @override
  String get haneokaAccountSummary => 'サインインすると、ゲームアカウントを公開プロフィールに表示できます。';

  @override
  String get signIn => 'サインイン';

  @override
  String get signOut => 'サインアウト';

  @override
  String get signInFailed => 'サインインできませんでした';

  @override
  String get profileLink => '公開プロフィール';

  @override
  String get linkToProfile => 'アカウントに連携';

  @override
  String get linkSignInFirst => 'このプレイヤーを連携するには Haneoka アカウントにサインインしてください。';

  @override
  String get linkExplain =>
      '送信されるのはプレイヤー ID、名前、ランク、レーティング、所持数、楽曲クリア数のみです。セーブデータ自体はこの端末に残ります。';

  @override
  String get linked => '連携済み';

  @override
  String get showOnProfile => '公開プロフィールに表示';

  @override
  String get syncNow => '更新';

  @override
  String get unlink => '連携を解除';

  @override
  String get unlinkConfirm => 'このプレイヤーを Haneoka アカウントから外しますか？';

  @override
  String get linkedElsewhere => 'このプレイヤーは別のアカウントに連携されています';

  @override
  String get linkFailed => '連携を更新できませんでした';

  @override
  String get linkUpdated => '連携を更新しました';

  @override
  String syncedOn(String date) {
    return '$date 更新';
  }

  @override
  String get openProfile => 'プロフィールを開く';

  @override
  String get teamBuilderNoSave => 'このサーバーのゲームアカウントがまだありません。';

  @override
  String get updateSave => '再読み込み';

  @override
  String get updateSaveHint =>
      'このゲームアカウントの最新セーブで保存済みデータを置き換えます。他のゲームアカウントは変更されません。';

  @override
  String get importToTeamBuilder => '編成に取り込む';

  @override
  String get importToTeamHint => 'このセーブのカード、スナップ、キャラクターレベルとバンドアイテムを確認して取り込みます。';

  @override
  String get saveAccountMismatch =>
      '別のゲームアカウントまたはサーバーのセーブです。このゲームアカウントのセーブを選んでください。';

  @override
  String get saveUpdated => 'ゲームアカウントを更新しました';

  @override
  String get syncFromGame => 'ゲームから同期';

  @override
  String get syncedFromGame => 'ゲームから同期しました';

  @override
  String get syncSessionExpired => 'ログインの有効期限が切れました。セーブデータを読み直してください。';

  @override
  String get syncUnrecognized => 'ゲームのデータを読み取れませんでした。';

  @override
  String get syncFailed => 'ゲームサーバーに接続できません。';

  @override
  String get cardSort => 'カードの並び順';

  @override
  String get sortRarity => 'レアリティ';

  @override
  String get sortNewest => '新しいカード';
}
