// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Haneoka';

  @override
  String get importTitle => '添加游戏账号';

  @override
  String get sourceShizuku => '本机 · Shizuku';

  @override
  String get sourceGrantFolder => '本机 · 游戏文件夹';

  @override
  String get sourceFiles => '文件或文件夹';

  @override
  String get sourceAdb => '安卓手机 · USB 或无线';

  @override
  String get sourceIosBackup => 'iPhone 或 iPad 备份';

  @override
  String get releaseIntlOfficial => '国际服 · 官网版';

  @override
  String get releaseIntlStore => '国际服 · 应用商店版';

  @override
  String get releaseJp => '日服';

  @override
  String get release => '版本';

  @override
  String get shizukuNotRunning => 'Shizuku 未运行';

  @override
  String get shizukuUnsupported => '需要更新 Shizuku';

  @override
  String get openShizuku => '打开 Shizuku';

  @override
  String get read => '读取';

  @override
  String get reading => '正在读取';

  @override
  String get noSaves => '没有找到存档';

  @override
  String get noGameInBackup => '这个备份里没有 Our Notes 的数据';

  @override
  String get backupPassword => '备份密码';

  @override
  String get wrongPassword => '备份密码不正确';

  @override
  String get noBackups => '没有备份';

  @override
  String get chooseBackupFolder => '选择备份文件夹';

  @override
  String get encrypted => '已加密';

  @override
  String get devices => '设备';

  @override
  String get noDevices => '没有连接手机';

  @override
  String get deviceUnauthorized => '在手机上允许 USB 调试';

  @override
  String get adbMissing => '找不到 adb';

  @override
  String get chooseAdb => '选择 adb';

  @override
  String get getPlatformTools => '获取 Platform Tools';

  @override
  String get pairWireless => '无线配对';

  @override
  String get pairAddress => 'IP 地址和端口';

  @override
  String get pairCode => '配对码';

  @override
  String get connectAddress => '连接地址';

  @override
  String get pairFailed => '配对失败';

  @override
  String get refresh => '刷新';

  @override
  String get gameNotInstalled => '没有安装 Our Notes';

  @override
  String get accounts => '账号';

  @override
  String get playerId => '玩家 ID';

  @override
  String get savedAt => '保存时间';

  @override
  String get source => '来源';

  @override
  String get playerExp => '玩家经验';

  @override
  String get vipRank => 'T.G.W CARD';

  @override
  String get highScoreRating => '高分评级';

  @override
  String get clears => '通关歌曲';

  @override
  String get exportTeam => '复制到配队工具';

  @override
  String get exportSave => '保存为文件';

  @override
  String get copied => '已复制';

  @override
  String get saved => '已保存';

  @override
  String get settings => '游戏设置';

  @override
  String get latestLive => '最近一次演出';

  @override
  String entries(int count) {
    return '$count 条';
  }

  @override
  String get sec_memberCards => '成员';

  @override
  String get sec_snapshots => '留影';

  @override
  String get sec_characters => '角色等级';

  @override
  String get sec_friendships => '羁绊';

  @override
  String get sec_bandItems => '乐队道具';

  @override
  String get sec_items => '道具';

  @override
  String get sec_songs => '歌曲成绩';

  @override
  String get sec_ratings => '评级歌曲';

  @override
  String get sec_challengeSongs => '挑战歌曲';

  @override
  String get sec_events => '活动';

  @override
  String get sec_challengeLives => '挑战演出';

  @override
  String get sec_gacha => '招募';

  @override
  String get sec_stories => '已读故事';

  @override
  String get sec_decks => '编队';

  @override
  String get sec_missions => '任务';

  @override
  String get sec_limitedMissions => '限时任务';

  @override
  String get sec_characterMissions => '角色任务';

  @override
  String get sec_seasonPass => '季票';

  @override
  String get sec_monthlyPass => '月卡';

  @override
  String get sec_loginBonuses => '登录奖励';

  @override
  String get sec_costumes => '服装';

  @override
  String get sec_currentCostumes => '当前服装';

  @override
  String get sec_backgrounds => '背景';

  @override
  String get sec_stamps => '贴纸';

  @override
  String get sec_degrees => '称号';

  @override
  String get sec_profileCards => '名片';

  @override
  String get sec_laneSkins => '轨道皮肤';

  @override
  String get sec_noteSkins => '音符皮肤';

  @override
  String get sec_noteEffectSkins => '音符特效';

  @override
  String get sec_noteSounds => '打击音效';

  @override
  String get sec_spots => '地点';

  @override
  String get sec_memory => '回忆';

  @override
  String get sec_liveBoost => '演出加成';

  @override
  String get sec_liveSkip => '演出跳过';

  @override
  String get sec_vip => 'T.G.W CARD';

  @override
  String get sec_offlineBonus => '离线奖励';

  @override
  String get sec_arena => '竞技场';

  @override
  String get playerRank => '玩家等级';

  @override
  String get sec_songUnlocks => '乐曲解锁';

  @override
  String get sec_challengeUnlocks => '挑战歌曲解锁';

  @override
  String get sec_friendshipRewards => '羁绊奖励';

  @override
  String get sec_stampFavorites => '收藏贴纸';

  @override
  String get sec_exchange => '交换所';

  @override
  String get sec_shop => '商店';

  @override
  String get importHeadline => '读取 Our Notes 游戏账号';

  @override
  String get importIntro =>
      'Haneoka 读取游戏保存在设备上的存档，展示你的等级、卡牌、歌曲通关和道具。存档只留在本机；导出时不会包含你的昵称和账号 ID。';

  @override
  String get versionQuestion => '你玩的是哪个版本？';

  @override
  String get versionHint => '用于无法自动识别版本的文件。';

  @override
  String get methodsTitle => '读取方式';

  @override
  String get recommended => '推荐';

  @override
  String get stepsShow => '步骤';

  @override
  String get methodShizukuTitle => '本机 · 通过 Shizuku';

  @override
  String get methodShizukuSummary => '直接读取游戏存档，需要 Shizuku 正在运行。';

  @override
  String get methodShizukuSteps =>
      '安装 Shizuku，并通过无线调试或 root 启动它。\n点击“读取存档”，在 Shizuku 询问时允许 Haneoka。';

  @override
  String get methodFolderTitle => '本机 · 授权游戏文件夹';

  @override
  String get methodFolderSummary =>
      'Android 13 及以下可以授权 Haneoka 读取游戏数据文件夹，之后读取无需再设置。';

  @override
  String get methodFolderSteps =>
      '在上方选择版本，然后点击“选择文件夹”。\n系统文件选择器会打开游戏文件夹，点击“使用此文件夹”并允许。';

  @override
  String get methodFilesTitle => '从复制出来的文件';

  @override
  String get methodFilesSummary =>
      '从设备复制出来的存档：游戏的 files 文件夹、它的 ZIP、iPhone 应用导出（.imazingapp），或 Haneoka 导出的文件。';

  @override
  String get methodFilesSteps =>
      'Android：用文件管理器或电脑，把 Android/data/<游戏>/files 复制到这台设备。\niPhone：在电脑上打开 iMazing，选中 Our Notes 并导出应用数据。\n点击“选择文件”（或“选择文件夹”），选中复制出来的内容。';

  @override
  String get methodBackupTitle => 'iPhone / iPad 备份';

  @override
  String get methodBackupSummary =>
      '读取这台电脑上 iPhone 或 iPad 的 Finder / iTunes 备份。';

  @override
  String get methodBackupSteps =>
      '在 Finder 或 iTunes 中把设备备份到这台电脑。加密备份也可以，会询问密码。\n点击“打开备份”并选择设备。';

  @override
  String get methodAdbTitle => 'Android 手机 · USB 或 Wi-Fi';

  @override
  String get methodAdbSummary => '使用随应用附带的 ADB，读取连接到这台电脑的 Android 手机存档。';

  @override
  String get methodAdbSteps =>
      '在手机上开启开发者选项和 USB 调试。\n用数据线连接，在手机上授权这台电脑，然后点击“读取已连接设备”。\n多台手机或 Wi-Fi 连接使用“选择设备／无线配对”。';

  @override
  String get iosNote => 'iOS 不允许应用读取其他应用的数据，因此在 iPhone 上需要先在电脑上导出一份存档副本。';

  @override
  String get readSave => '读取存档';

  @override
  String get chooseFolder => '选择文件夹';

  @override
  String get chooseFiles => '选择文件';

  @override
  String get openBackups => '打开备份';

  @override
  String get connect => '连接';

  @override
  String get readAgain => '重新读取';

  @override
  String get importedAccounts => '游戏账号';

  @override
  String savedOn(String time) {
    return '存档时间 $time';
  }

  @override
  String get removeAccount => '从本机移除';

  @override
  String removeAccountConfirm(String name) {
    return '要从 Haneoka 移除 $name 吗？游戏本身的存档不受影响。';
  }

  @override
  String get cancel => '取消';

  @override
  String get remove => '移除';

  @override
  String get importMore => '添加游戏账号';

  @override
  String foundAccounts(int count) {
    return '找到 $count 个游戏账号';
  }

  @override
  String get profileOverview => '概览';

  @override
  String get songClears => '歌曲通关';

  @override
  String get cleared => '通关';

  @override
  String get fullCombo => '全连';

  @override
  String get allPerfect => '全完美';

  @override
  String ofSongs(String total) {
    return '共 $total';
  }

  @override
  String get ownedMembers => '成员';

  @override
  String get ownedSnapshots => '留影';

  @override
  String get viewAll => '查看全部';

  @override
  String get currencies => '道具';

  @override
  String get eventsPlayed => '活动';

  @override
  String eventPoints(String points) {
    return '$points pt';
  }

  @override
  String get exportsTitle => '在别处使用';

  @override
  String get exportTeamHint => '你的卡牌和进度，用于队伍搭建工具。';

  @override
  String get exportSaveHint => '完整存档的 JSON，不含昵称和账号 ID。';

  @override
  String get rawData => '原始数据';

  @override
  String get copyId => '复制 ID';

  @override
  String get tutorialDone => '开始游戏';

  @override
  String get noAccountsYet => '还没有游戏账号';

  @override
  String get haneokaAccount => 'Haneoka 账号';

  @override
  String get haneokaAccountSummary => '登录后可将游戏账号展示在公开主页上。';

  @override
  String get signIn => '登录';

  @override
  String get signOut => '退出登录';

  @override
  String get signInFailed => '无法登录';

  @override
  String get profileLink => '公开主页';

  @override
  String get linkToProfile => '关联到我的账号';

  @override
  String get linkSignInFirst => '登录 Haneoka 账号后即可关联此玩家。';

  @override
  String get linkExplain => '只会上传玩家 ID、名称、等级、评级、持有数量和歌曲通关数，存档本身仅保存在本设备。';

  @override
  String get linked => '已关联';

  @override
  String get showOnProfile => '在公开主页展示';

  @override
  String get syncNow => '更新';

  @override
  String get unlink => '解除关联';

  @override
  String get unlinkConfirm => '要将此玩家从 Haneoka 账号中移除吗？';

  @override
  String get linkedElsewhere => '此玩家已关联到其他账号';

  @override
  String get linkFailed => '无法更新关联';

  @override
  String get linkUpdated => '关联已更新';

  @override
  String syncedOn(String date) {
    return '$date 更新';
  }

  @override
  String get openProfile => '打开主页';

  @override
  String get teamBuilderNoSave => '还没有此服务器的游戏账号。';

  @override
  String get updateSave => '重新读取';

  @override
  String get updateSaveHint => '读取此游戏账号的最新存档，替换本机旧数据，其他游戏账号不受影响。';

  @override
  String get importToTeamBuilder => '导入配队';

  @override
  String get importToTeamHint => '直接使用此游戏账号的成员卡、留影、角色等级和乐队道具，预览后确认导入。';

  @override
  String get saveAccountMismatch => '读取到的存档属于其他游戏账号或服务器，请选择此游戏账号的存档。';

  @override
  String get saveUpdated => '游戏账号已更新';

  @override
  String get syncFromGame => '从游戏同步';

  @override
  String get syncedFromGame => '已从游戏同步';

  @override
  String get syncSessionExpired => '登录已失效，请重新读取存档。';

  @override
  String get syncUnrecognized => '无法识别游戏返回的数据。';

  @override
  String get syncFailed => '无法连接游戏服务器。';

  @override
  String get cardSort => '卡牌排序';

  @override
  String get sortRarity => '稀有度';

  @override
  String get sortNewest => '最新卡牌';
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');

  @override
  String get appTitle => 'Haneoka';

  @override
  String get importTitle => '新增遊戲帳號';

  @override
  String get sourceShizuku => '本機 · Shizuku';

  @override
  String get sourceGrantFolder => '本機 · 遊戲資料夾';

  @override
  String get sourceFiles => '檔案或資料夾';

  @override
  String get sourceAdb => 'Android 手機 · USB 或無線';

  @override
  String get sourceIosBackup => 'iPhone 或 iPad 備份';

  @override
  String get releaseIntlOfficial => '國際服 · 官網版';

  @override
  String get releaseIntlStore => '國際服 · 應用商店版';

  @override
  String get releaseJp => '日服';

  @override
  String get release => '版本';

  @override
  String get shizukuNotRunning => 'Shizuku 未執行';

  @override
  String get shizukuUnsupported => '需要更新 Shizuku';

  @override
  String get openShizuku => '開啟 Shizuku';

  @override
  String get read => '讀取';

  @override
  String get reading => '正在讀取';

  @override
  String get noSaves => '沒有找到存檔';

  @override
  String get noGameInBackup => '這個備份裡沒有 Our Notes 的資料';

  @override
  String get backupPassword => '備份密碼';

  @override
  String get wrongPassword => '備份密碼不正確';

  @override
  String get noBackups => '沒有備份';

  @override
  String get chooseBackupFolder => '選擇備份資料夾';

  @override
  String get encrypted => '已加密';

  @override
  String get devices => '裝置';

  @override
  String get noDevices => '沒有連接手機';

  @override
  String get deviceUnauthorized => '在手機上允許 USB 偵錯';

  @override
  String get adbMissing => '找不到 adb';

  @override
  String get chooseAdb => '選擇 adb';

  @override
  String get getPlatformTools => '取得 Platform Tools';

  @override
  String get pairWireless => '無線配對';

  @override
  String get pairAddress => 'IP 位址和連接埠';

  @override
  String get pairCode => '配對碼';

  @override
  String get connectAddress => '連線位址';

  @override
  String get pairFailed => '配對失敗';

  @override
  String get refresh => '重新整理';

  @override
  String get gameNotInstalled => '沒有安裝 Our Notes';

  @override
  String get accounts => '帳號';

  @override
  String get playerId => '玩家 ID';

  @override
  String get savedAt => '儲存時間';

  @override
  String get source => '來源';

  @override
  String get playerExp => '玩家經驗';

  @override
  String get vipRank => 'T.G.W CARD';

  @override
  String get highScoreRating => '高分評級';

  @override
  String get clears => '通關歌曲';

  @override
  String get exportTeam => '複製到配隊工具';

  @override
  String get exportSave => '儲存為檔案';

  @override
  String get copied => '已複製';

  @override
  String get saved => '已儲存';

  @override
  String get settings => '遊戲設定';

  @override
  String get latestLive => '最近一次演出';

  @override
  String entries(int count) {
    return '$count 筆';
  }

  @override
  String get sec_memberCards => '成員';

  @override
  String get sec_snapshots => '留影';

  @override
  String get sec_characters => '角色等級';

  @override
  String get sec_friendships => '羈絆';

  @override
  String get sec_bandItems => '樂團道具';

  @override
  String get sec_items => '道具';

  @override
  String get sec_songs => '歌曲成績';

  @override
  String get sec_ratings => '評級歌曲';

  @override
  String get sec_challengeSongs => '挑戰歌曲';

  @override
  String get sec_events => '活動';

  @override
  String get sec_challengeLives => '挑戰演出';

  @override
  String get sec_gacha => '招募';

  @override
  String get sec_stories => '已讀故事';

  @override
  String get sec_decks => '編隊';

  @override
  String get sec_missions => '任務';

  @override
  String get sec_limitedMissions => '限時任務';

  @override
  String get sec_characterMissions => '角色任務';

  @override
  String get sec_seasonPass => '季票';

  @override
  String get sec_monthlyPass => '月卡';

  @override
  String get sec_loginBonuses => '登入獎勵';

  @override
  String get sec_costumes => '服裝';

  @override
  String get sec_currentCostumes => '目前服裝';

  @override
  String get sec_backgrounds => '背景';

  @override
  String get sec_stamps => '貼圖';

  @override
  String get sec_degrees => '稱號';

  @override
  String get sec_profileCards => '名片';

  @override
  String get sec_laneSkins => '軌道外觀';

  @override
  String get sec_noteSkins => '音符外觀';

  @override
  String get sec_noteEffectSkins => '音符特效';

  @override
  String get sec_noteSounds => '打擊音效';

  @override
  String get sec_spots => '地點';

  @override
  String get sec_memory => '回憶';

  @override
  String get sec_liveBoost => '演出加成';

  @override
  String get sec_liveSkip => '演出跳過';

  @override
  String get sec_vip => 'T.G.W CARD';

  @override
  String get sec_offlineBonus => '離線獎勵';

  @override
  String get sec_arena => '競技場';

  @override
  String get playerRank => '玩家等級';

  @override
  String get sec_songUnlocks => '樂曲解鎖';

  @override
  String get sec_challengeUnlocks => '挑戰歌曲解鎖';

  @override
  String get sec_friendshipRewards => '羈絆獎勵';

  @override
  String get sec_stampFavorites => '收藏貼圖';

  @override
  String get sec_exchange => '兌換所';

  @override
  String get sec_shop => '商店';

  @override
  String get importHeadline => '讀取 Our Notes 遊戲帳號';

  @override
  String get importIntro =>
      'Haneoka 讀取遊戲保存在裝置上的存檔，顯示你的等級、卡牌、歌曲通關與道具。存檔只留在本機；匯出時不包含你的暱稱與帳號 ID。';

  @override
  String get versionQuestion => '你玩的是哪個版本？';

  @override
  String get versionHint => '用於無法自動辨識版本的檔案。';

  @override
  String get methodsTitle => '讀取方式';

  @override
  String get recommended => '推薦';

  @override
  String get stepsShow => '步驟';

  @override
  String get methodShizukuTitle => '本機 · 透過 Shizuku';

  @override
  String get methodShizukuSummary => '直接讀取遊戲存檔，需要 Shizuku 正在執行。';

  @override
  String get methodShizukuSteps =>
      '安裝 Shizuku，並透過無線偵錯或 root 啟動。\n點選「讀取存檔」，在 Shizuku 詢問時允許 Haneoka。';

  @override
  String get methodFolderTitle => '本機 · 授權遊戲資料夾';

  @override
  String get methodFolderSummary =>
      'Android 13 及以下可授權 Haneoka 讀取遊戲資料夾，之後讀取不需再設定。';

  @override
  String get methodFolderSteps =>
      '在上方選擇版本，然後點選「選擇資料夾」。\n系統檔案選擇器會開啟遊戲資料夾，點選「使用這個資料夾」並允許。';

  @override
  String get methodFilesTitle => '從複製出來的檔案';

  @override
  String get methodFilesSummary =>
      '從裝置複製出來的存檔：遊戲的 files 資料夾、它的 ZIP、iPhone App 匯出（.imazingapp），或 Haneoka 匯出的檔案。';

  @override
  String get methodFilesSteps =>
      'Android：用檔案管理器或電腦，把 Android/data/<遊戲>/files 複製到這台裝置。\niPhone：在電腦上開啟 iMazing，選取 Our Notes 並匯出 App 資料。\n點選「選擇檔案」（或「選擇資料夾」），選取複製出來的內容。';

  @override
  String get methodBackupTitle => 'iPhone / iPad 備份';

  @override
  String get methodBackupSummary =>
      '讀取這台電腦上 iPhone 或 iPad 的 Finder / iTunes 備份。';

  @override
  String get methodBackupSteps =>
      '在 Finder 或 iTunes 中把裝置備份到這台電腦。加密備份也可以，會詢問密碼。\n點選「開啟備份」並選擇裝置。';

  @override
  String get methodAdbTitle => 'Android 手機 · USB 或 Wi-Fi';

  @override
  String get methodAdbSummary => '使用應用程式內附的 ADB，讀取連接到這台電腦的 Android 手機存檔。';

  @override
  String get methodAdbSteps =>
      '在手機開啟開發人員選項與 USB 偵錯。\n用傳輸線連接，在手機授權這台電腦，然後點選「讀取已連接裝置」。\n多台手機或 Wi-Fi 連線使用「選擇裝置／無線配對」。';

  @override
  String get iosNote => 'iOS 不允許 App 讀取其他 App 的資料，因此在 iPhone 上需要先在電腦上匯出一份存檔副本。';

  @override
  String get readSave => '讀取存檔';

  @override
  String get chooseFolder => '選擇資料夾';

  @override
  String get chooseFiles => '選擇檔案';

  @override
  String get openBackups => '開啟備份';

  @override
  String get connect => '連接';

  @override
  String get readAgain => '重新讀取';

  @override
  String get importedAccounts => '遊戲帳號';

  @override
  String savedOn(String time) {
    return '存檔時間 $time';
  }

  @override
  String get removeAccount => '從本機移除';

  @override
  String removeAccountConfirm(String name) {
    return '要從 Haneoka 移除 $name 嗎？遊戲本身的存檔不受影響。';
  }

  @override
  String get cancel => '取消';

  @override
  String get remove => '移除';

  @override
  String get importMore => '新增遊戲帳號';

  @override
  String foundAccounts(int count) {
    return '找到 $count 個遊戲帳號';
  }

  @override
  String get profileOverview => '概覽';

  @override
  String get songClears => '歌曲通關';

  @override
  String get cleared => '通關';

  @override
  String get fullCombo => '全連';

  @override
  String get allPerfect => '全完美';

  @override
  String ofSongs(String total) {
    return '共 $total';
  }

  @override
  String get ownedMembers => '團員';

  @override
  String get ownedSnapshots => '快照';

  @override
  String get viewAll => '查看全部';

  @override
  String get currencies => '道具';

  @override
  String get eventsPlayed => '活動';

  @override
  String eventPoints(String points) {
    return '$points pt';
  }

  @override
  String get exportsTitle => '在別處使用';

  @override
  String get exportTeamHint => '你的卡牌與進度，用於隊伍搭配工具。';

  @override
  String get exportSaveHint => '完整存檔的 JSON，不含暱稱與帳號 ID。';

  @override
  String get rawData => '原始資料';

  @override
  String get copyId => '複製 ID';

  @override
  String get tutorialDone => '開始遊戲';

  @override
  String get noAccountsYet => '還沒有遊戲帳號';

  @override
  String get haneokaAccount => 'Haneoka 帳號';

  @override
  String get haneokaAccountSummary => '登入後可將遊戲帳號展示在公開個人頁面上。';

  @override
  String get signIn => '登入';

  @override
  String get signOut => '登出';

  @override
  String get signInFailed => '無法登入';

  @override
  String get profileLink => '公開個人頁面';

  @override
  String get linkToProfile => '關聯到我的帳號';

  @override
  String get linkSignInFirst => '登入 Haneoka 帳號後即可關聯此玩家。';

  @override
  String get linkExplain => '只會上傳玩家 ID、名稱、等級、評級、持有數量和歌曲通關數，存檔本身僅保存在本裝置。';

  @override
  String get linked => '已關聯';

  @override
  String get showOnProfile => '在公開個人頁面展示';

  @override
  String get syncNow => '更新';

  @override
  String get unlink => '解除關聯';

  @override
  String get unlinkConfirm => '要將此玩家從 Haneoka 帳號中移除嗎？';

  @override
  String get linkedElsewhere => '此玩家已關聯到其他帳號';

  @override
  String get linkFailed => '無法更新關聯';

  @override
  String get linkUpdated => '關聯已更新';

  @override
  String syncedOn(String date) {
    return '$date 更新';
  }

  @override
  String get openProfile => '開啟個人頁面';

  @override
  String get teamBuilderNoSave => '還沒有此伺服器的遊戲帳號。';

  @override
  String get updateSave => '重新讀取';

  @override
  String get updateSaveHint => '讀取此遊戲帳號的最新存檔，取代本機舊資料，其他遊戲帳號不受影響。';

  @override
  String get importToTeamBuilder => '匯入配隊';

  @override
  String get importToTeamHint => '直接使用此遊戲帳號的成員卡、留影、角色等級和樂團道具，預覽後確認匯入。';

  @override
  String get saveAccountMismatch => '讀取到的存檔屬於其他遊戲帳號或伺服器，請選擇此遊戲帳號的存檔。';

  @override
  String get saveUpdated => '遊戲帳號已更新';

  @override
  String get syncFromGame => '從遊戲同步';

  @override
  String get syncedFromGame => '已從遊戲同步';

  @override
  String get syncSessionExpired => '登入已失效，請重新讀取存檔。';

  @override
  String get syncUnrecognized => '無法識別遊戲回傳的資料。';

  @override
  String get syncFailed => '無法連線至遊戲伺服器。';

  @override
  String get cardSort => '卡牌排序';

  @override
  String get sortRarity => '稀有度';

  @override
  String get sortNewest => '最新卡牌';
}
