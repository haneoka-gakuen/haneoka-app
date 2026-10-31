// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'Haneoka';

  @override
  String get importTitle => '게임 계정 추가';

  @override
  String get sourceShizuku => '이 휴대폰 · Shizuku';

  @override
  String get sourceGrantFolder => '이 휴대폰 · 게임 폴더';

  @override
  String get sourceFiles => '파일 또는 폴더';

  @override
  String get sourceAdb => 'Android 휴대폰 · USB 또는 Wi-Fi';

  @override
  String get sourceIosBackup => 'iPhone 또는 iPad 백업';

  @override
  String get releaseIntlOfficial => '글로벌 · 공식 사이트판';

  @override
  String get releaseIntlStore => '글로벌 · 스토어판';

  @override
  String get releaseJp => '일본판';

  @override
  String get release => '버전';

  @override
  String get shizukuNotRunning => 'Shizuku가 실행 중이 아닙니다';

  @override
  String get shizukuUnsupported => 'Shizuku 업데이트가 필요합니다';

  @override
  String get openShizuku => 'Shizuku 열기';

  @override
  String get read => '읽기';

  @override
  String get reading => '읽는 중';

  @override
  String get noSaves => '세이브를 찾지 못했습니다';

  @override
  String get noGameInBackup => '이 백업에는 아워 노츠 데이터가 없습니다';

  @override
  String get backupPassword => '백업 비밀번호';

  @override
  String get wrongPassword => '백업 비밀번호가 틀렸습니다';

  @override
  String get noBackups => '백업이 없습니다';

  @override
  String get chooseBackupFolder => '백업 폴더 선택';

  @override
  String get encrypted => '암호화됨';

  @override
  String get devices => '기기';

  @override
  String get noDevices => '연결된 휴대폰이 없습니다';

  @override
  String get deviceUnauthorized => '휴대폰에서 USB 디버깅을 허용하세요';

  @override
  String get adbMissing => 'adb를 찾을 수 없습니다';

  @override
  String get chooseAdb => 'adb 선택';

  @override
  String get getPlatformTools => 'Platform Tools 받기';

  @override
  String get pairWireless => 'Wi-Fi로 페어링';

  @override
  String get pairAddress => 'IP 주소와 포트';

  @override
  String get pairCode => '페어링 코드';

  @override
  String get connectAddress => '연결 주소';

  @override
  String get pairFailed => '페어링 실패';

  @override
  String get refresh => '새로고침';

  @override
  String get gameNotInstalled => '아워 노츠가 설치되어 있지 않습니다';

  @override
  String get accounts => '계정';

  @override
  String get playerId => '플레이어 ID';

  @override
  String get savedAt => '저장 시각';

  @override
  String get source => '가져온 곳';

  @override
  String get playerExp => '플레이어 경험치';

  @override
  String get vipRank => 'T.G.W CARD';

  @override
  String get highScoreRating => '하이스코어 레이팅';

  @override
  String get clears => '클리어 악곡';

  @override
  String get exportTeam => '팀 빌더용 복사';

  @override
  String get exportSave => '파일로 저장';

  @override
  String get copied => '복사했습니다';

  @override
  String get saved => '저장했습니다';

  @override
  String get settings => '게임 설정';

  @override
  String get latestLive => '최근 라이브';

  @override
  String entries(int count) {
    return '$count개';
  }

  @override
  String get sec_memberCards => '멤버';

  @override
  String get sec_snapshots => '스냅';

  @override
  String get sec_characters => '캐릭터 랭크';

  @override
  String get sec_friendships => '친밀도';

  @override
  String get sec_bandItems => '밴드 아이템';

  @override
  String get sec_items => '아이템';

  @override
  String get sec_songs => '악곡 기록';

  @override
  String get sec_ratings => '레이팅 대상곡';

  @override
  String get sec_challengeSongs => '챌린지 악곡';

  @override
  String get sec_events => '이벤트';

  @override
  String get sec_challengeLives => '챌린지 라이브';

  @override
  String get sec_gacha => '가챠';

  @override
  String get sec_stories => '읽은 스토리';

  @override
  String get sec_decks => '편성';

  @override
  String get sec_missions => '미션';

  @override
  String get sec_limitedMissions => '기간 한정 미션';

  @override
  String get sec_characterMissions => '캐릭터 미션';

  @override
  String get sec_seasonPass => '시즌 패스';

  @override
  String get sec_monthlyPass => '먼슬리 패스';

  @override
  String get sec_loginBonuses => '로그인 보너스';

  @override
  String get sec_costumes => '의상';

  @override
  String get sec_currentCostumes => '착용 중인 의상';

  @override
  String get sec_backgrounds => '배경';

  @override
  String get sec_stamps => '스탬프';

  @override
  String get sec_degrees => '칭호';

  @override
  String get sec_profileCards => '프로필 카드';

  @override
  String get sec_laneSkins => '레인 스킨';

  @override
  String get sec_noteSkins => '노트 스킨';

  @override
  String get sec_noteEffectSkins => '노트 이펙트';

  @override
  String get sec_noteSounds => '노트 효과음';

  @override
  String get sec_spots => '스폿';

  @override
  String get sec_memory => '메모리';

  @override
  String get sec_liveBoost => '라이브 부스트';

  @override
  String get sec_liveSkip => '라이브 스킵';

  @override
  String get sec_vip => 'T.G.W CARD';

  @override
  String get sec_offlineBonus => '오프라인 보너스';

  @override
  String get sec_arena => '아레나';

  @override
  String get playerRank => '플레이어 랭크';

  @override
  String get sec_songUnlocks => '악곡 해금';

  @override
  String get sec_challengeUnlocks => '챌린지 악곡 해금';

  @override
  String get sec_friendshipRewards => '인연 보상';

  @override
  String get sec_stampFavorites => '즐겨찾기 스탬프';

  @override
  String get sec_exchange => '교환소';

  @override
  String get sec_shop => '상점';

  @override
  String get importHeadline => 'Our Notes 게임 계정 읽기';

  @override
  String get importIntro =>
      '게임이 기기에 저장한 세이브를 읽어 랭크·카드·곡 클리어·아이템을 보여 줍니다. 세이브는 이 기기에만 남고, 내보낼 때 이름과 계정 ID는 포함하지 않습니다.';

  @override
  String get versionQuestion => '어느 버전을 플레이하나요?';

  @override
  String get versionHint => '버전을 알 수 없는 파일에 사용합니다.';

  @override
  String get methodsTitle => '가져오는 방법';

  @override
  String get recommended => '추천';

  @override
  String get stepsShow => '순서';

  @override
  String get methodShizukuTitle => '이 휴대폰 · Shizuku로';

  @override
  String get methodShizukuSummary => '게임 세이브를 바로 읽습니다. Shizuku가 실행 중이어야 합니다.';

  @override
  String get methodShizukuSteps =>
      'Shizuku를 설치하고 무선 디버깅이나 루트로 실행합니다.\n‘세이브 읽기’를 누르고 Shizuku가 물으면 Haneoka를 허용합니다.';

  @override
  String get methodFolderTitle => '이 휴대폰 · 게임 폴더 권한';

  @override
  String get methodFolderSummary =>
      'Android 13 이하에서는 게임 데이터 폴더 접근을 한 번 허용하면 이후엔 설정 없이 읽을 수 있습니다.';

  @override
  String get methodFolderSteps =>
      '위에서 버전을 고르고 ‘폴더 선택’을 누릅니다.\n게임 폴더가 열리면 ‘이 폴더 사용’을 누르고 허용합니다.';

  @override
  String get methodFilesTitle => '복사한 파일에서';

  @override
  String get methodFilesSummary =>
      '기기에서 복사한 세이브: 게임의 files 폴더, 그 ZIP, iPhone 앱 내보내기(.imazingapp), Haneoka 내보내기 파일.';

  @override
  String get methodFilesSteps =>
      'Android: 파일 관리자나 컴퓨터로 Android/data/<게임>/files를 이 기기로 복사합니다.\niPhone: 컴퓨터에서 iMazing을 열고 Our Notes를 선택해 앱 데이터를 내보냅니다.\n‘파일 선택’(또는 ‘폴더 선택’)으로 복사한 것을 고릅니다.';

  @override
  String get methodBackupTitle => 'iPhone / iPad 백업';

  @override
  String get methodBackupSummary =>
      '이 컴퓨터에 있는 iPhone / iPad의 Finder·iTunes 백업을 읽습니다.';

  @override
  String get methodBackupSteps =>
      'Finder나 iTunes로 기기를 이 컴퓨터에 백업합니다. 암호화된 백업도 되며, 비밀번호를 묻습니다.\n‘백업 열기’를 누르고 기기를 고릅니다.';

  @override
  String get methodAdbTitle => 'Android 휴대폰 · USB 또는 Wi-Fi';

  @override
  String get methodAdbSummary =>
      '앱에 포함된 ADB로 이 컴퓨터에 연결한 Android 기기의 세이브를 읽습니다.';

  @override
  String get methodAdbSteps =>
      '기기에서 개발자 옵션과 USB 디버깅을 켭니다.\n케이블로 연결하고 컴퓨터를 승인한 뒤 연결된 기기에서 읽기를 누릅니다.\n여러 기기나 Wi-Fi 연결은 기기 선택 / 무선 페어링을 사용합니다.';

  @override
  String get iosNote =>
      'iOS는 다른 앱의 데이터를 읽을 수 없어, iPhone에서는 컴퓨터로 내보낸 사본을 사용합니다.';

  @override
  String get readSave => '세이브 읽기';

  @override
  String get chooseFolder => '폴더 선택';

  @override
  String get chooseFiles => '파일 선택';

  @override
  String get openBackups => '백업 열기';

  @override
  String get connect => '연결';

  @override
  String get readAgain => '다시 읽기';

  @override
  String get importedAccounts => '게임 계정';

  @override
  String savedOn(String time) {
    return '$time 세이브';
  }

  @override
  String get removeAccount => '이 기기에서 삭제';

  @override
  String removeAccountConfirm(String name) {
    return 'Haneoka에서 $name을(를) 삭제할까요? 게임 자체 세이브에는 영향이 없습니다.';
  }

  @override
  String get cancel => '취소';

  @override
  String get remove => '삭제';

  @override
  String get importMore => '게임 계정 추가';

  @override
  String foundAccounts(int count) {
    return '게임 계정 $count개를 찾았습니다';
  }

  @override
  String get profileOverview => '개요';

  @override
  String get songClears => '곡 클리어';

  @override
  String get cleared => '클리어';

  @override
  String get fullCombo => '풀 콤보';

  @override
  String get allPerfect => '올 퍼펙트';

  @override
  String ofSongs(String total) {
    return '/ $total';
  }

  @override
  String get ownedMembers => '멤버';

  @override
  String get ownedSnapshots => '스냅';

  @override
  String get viewAll => '모두 보기';

  @override
  String get currencies => '아이템';

  @override
  String get eventsPlayed => '이벤트';

  @override
  String eventPoints(String points) {
    return '$points pt';
  }

  @override
  String get exportsTitle => '다른 곳에서 사용';

  @override
  String get exportTeamHint => '팀 빌더용 카드와 진행도.';

  @override
  String get exportSaveHint => '이름과 계정 ID를 뺀 세이브 전체 JSON.';

  @override
  String get rawData => '원본 데이터';

  @override
  String get copyId => 'ID 복사';

  @override
  String get tutorialDone => '시작';

  @override
  String get noAccountsYet => '아직 게임 계정이 없습니다';

  @override
  String get haneokaAccount => 'Haneoka 계정';

  @override
  String get haneokaAccountSummary => '로그인하면 게임 계정을 공개 프로필에 표시할 수 있습니다.';

  @override
  String get signIn => '로그인';

  @override
  String get signOut => '로그아웃';

  @override
  String get signInFailed => '로그인하지 못했습니다';

  @override
  String get profileLink => '공개 프로필';

  @override
  String get linkToProfile => '내 계정에 연결';

  @override
  String get linkSignInFirst => '이 플레이어를 연결하려면 Haneoka 계정에 로그인하세요.';

  @override
  String get linkExplain =>
      '플레이어 ID, 이름, 랭크, 레이팅, 보유 수, 곡 클리어 수만 전송됩니다. 저장 데이터는 이 기기에 남습니다.';

  @override
  String get linked => '연결됨';

  @override
  String get showOnProfile => '공개 프로필에 표시';

  @override
  String get syncNow => '업데이트';

  @override
  String get unlink => '연결 해제';

  @override
  String get unlinkConfirm => '이 플레이어를 Haneoka 계정에서 제거할까요?';

  @override
  String get linkedElsewhere => '이 플레이어는 다른 계정에 연결되어 있습니다';

  @override
  String get linkFailed => '연결을 업데이트하지 못했습니다';

  @override
  String get linkUpdated => '연결을 업데이트했습니다';

  @override
  String syncedOn(String date) {
    return '$date 업데이트';
  }

  @override
  String get openProfile => '프로필 열기';

  @override
  String get teamBuilderNoSave => '이 서버의 게임 계정이 아직 없습니다.';

  @override
  String get updateSave => '다시 읽기';

  @override
  String get updateSaveHint =>
      '이 게임 계정의 최신 세이브로 저장된 데이터를 교체합니다. 다른 게임 계정은 변경되지 않습니다.';

  @override
  String get importToTeamBuilder => '팀 빌더로 가져오기';

  @override
  String get importToTeamHint => '이 세이브의 카드, 스냅, 캐릭터 레벨과 밴드 아이템을 확인하고 가져옵니다.';

  @override
  String get saveAccountMismatch =>
      '다른 게임 계정이나 서버의 세이브입니다. 이 게임 계정의 세이브를 선택하세요.';

  @override
  String get saveUpdated => '게임 계정이 업데이트되었습니다';

  @override
  String get syncFromGame => '게임에서 동기화';

  @override
  String get syncedFromGame => '게임에서 동기화했습니다';

  @override
  String get syncSessionExpired => '로그인이 만료되었습니다. 세이브를 다시 읽어 주세요.';

  @override
  String get syncUnrecognized => '게임 데이터를 읽을 수 없습니다.';

  @override
  String get syncFailed => '게임 서버에 연결할 수 없습니다.';

  @override
  String get cardSort => '카드 정렬';

  @override
  String get sortRarity => '희귀도';

  @override
  String get sortNewest => '최신 카드';
}
