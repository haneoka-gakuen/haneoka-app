# Haneoka App

Flutter 原生客户端，与 [Haneoka Web](https://haneoka.org) 共用资源、账号、Box 和配队引擎协议。

## 功能与代码入口

| 功能 | 原生实现 |
| --- | --- |
| 资料库、跨服、搜索、实体与媒体 | `lib/catalog/`、`lib/search/`、`lib/tools/` |
| 五乐队竞技场排期、赛季切换、本地时区、歌曲、段位和奖励 | `lib/catalog/arena_detail.dart` |
| 配队、手动组队、留影、成长与队伍比较 | `lib/team_builder/` |
| 原队伍／重新配队的培养比较、材料与技能、批量培养优先级 | `team_growth.dart`、`team_growth_view.dart` |
| 选曲的多难度、等级／时长、筛选外／不可用、替换与撤销 | `song_picker.dart`、`pickers.dart` |
| Box 与资源选择器共用排序、按所选难度排序谱面指标 | `catalog_sort.dart`、`lib/catalog/sort_control.dart` |
| 图鉴、故事、工具、游戏与社区的资源拼贴入口 | `lib/catalog/hub_screen.dart`、`hub_data.dart` |
| 竞技场单曲／多曲共用队伍 | `arena_state.dart`、`arena.dart`、`engine/api.dart` |
| 活动 PT／CP／徽章、排序方案和资源规划 | `settings.dart`、`reward_plan.dart`、`pt_controller.dart` |
| 自定义活动的规则、属性、目标和特殊加成卡 | `manual_event.dart`、`manual_event_view.dart` |
| Box、玩家导入、备份和云同步 | `lib/team_builder/box.dart`、`lib/save/`、`lib/sources/` |
| 原生故事、Live2D、Spine、谱面播放 | `lib/stories/`、`lib/rendering/`、`lib/tools/` |
| 谱面编辑、图案、分组／图层、标记和路标 | `lib/chart_editor/` |
| SS／USC／SUS／MMW 导入导出与格式诊断 | `formats.dart`、`usc.dart`、`sus.dart`、`sus_export.dart`、`mmws.dart` |
| 编辑器快捷键、音符音效和节拍器 | `shortcuts.dart`、`feedback.dart` |
| 封面拼图、截图导入和 3–8 阶求解 | `lib/games/song_puzzle.dart`、`puzzle_recognition.dart`、`puzzle_constructive.dart`、`puzzle_solver.dart` |
| 帖子／评论编辑、版务、举报申诉、推荐偏好与多标签筛选 | `lib/community/actions.dart`、`feed_screen.dart`、`lib/account/appeals.dart` |
| 发帖与表情图层的本地草稿、恢复和顺序保存 | `lib/core/local_drafts.dart`、`lib/community/editor.dart`、`lib/tools/stamp_maker.dart` |
| 社区、歌单、谱面发布、管理 | `lib/community/`、`lib/playlists/`、`lib/admin/` |
| 日历、游玩记录、玩家查询、抽卡记录、表情制作 | `lib/home/`、`lib/records/`、`lib/gacha_history/`、`lib/tools/` |

汇总页通过公共文档缓存读取 Web 的拼贴入口、分组和版本化图片，并由 Flutter 原生布局呈现。竞技场读取同一份完整赛季投影，所有乐队共用时间轴，设备恢复前台与规则边界会刷新当前状态。

公开资源链接保留区服，资料页、故事分类、技能／帮助详情和歌曲谱面／排行榜使用同一套规范地址；跨服跳转不改写其他工作区的区服。

导航与地址由 `lib/shell/navigation.dart`、`routes.dart`、`links.dart` 管理；可见文案来自 `assets/i18n/` 的五语目录。

## 配队契约

`EngineRequest` 的 `songRules` 与 `aggregation` 在进程、分片和保存结果之间保持一致。竞技场以 `goal.arena` 指定区服、乐队、规则和组队方式；多曲结果保留 `aggregate.songs`。自定义活动以 `goal.eventEffects` 替换参考活动的加成，不改动资源数据。

培养方案冻结原始候选池、培养值、玩家加成和计算条件，分别计算原队伍前后与重新配队前后。材料数据按卡片所属区服及资源版本读取；模拟不写入 Box。批量优先级复用现有引擎进程池与按账号、区服、资源版本隔离的结果缓存。

同一账号与区服的配队页面共用 Box 本地副本；页面间即时接收卡牌与偏好更新，磁盘写入按顺序保存并固定所属账号。

普通配队、竞技场和活动规划各自保留设置与结果；竞技场偏好存放在 `pref.arena`，普通配队及活动设置存放在 `pref.build`。规则切换、区服切换和取消会中止旧任务；结果条件使用计算时的快照。

累计技能搜索、回放和结算使用与 Web 锁定一致的 Rust 引擎；活动收益按 64 位中间乘积校验，旧模型的计算检查点不复用。原生请求负责技能程序的最终兼容性，已记录培养要求在提交前核对。普通、活动、手动及固定队伍选曲都按各自的歌曲规则筛选与计算。

普通 Live 的 CP 可按最优挑战队伍折算收益；结果保留用于折算的挑战队伍，其详情、比较、时间轴与培养分析使用挑战条件。完整活动结果与推荐任务都保存在设备上，按账号、区服与资源版本恢复，写入与 Box 云同步独立。

Linux 配队在独立的实际 App 计算进程中执行，其他平台使用原生引擎宿主。`native/team_engine` 锁定共享 Rust 引擎。

## 开发

```sh
git submodule update --init --recursive
flutter pub get
flutter analyze
flutter build linux --release --no-pub
```

CI 同时执行 Flutter 分析、Rust Clippy、原生和 WASM 构建。其他平台的打包命令见 `.github/workflows/release.yml` 与 `scripts/`。

原生界面验收使用桌面与手机宽度、明暗主题和真实资源。匿名验收需要同时隔离应用目录和系统凭据服务；单独设置 XDG 目录仍会读到当前桌面钥匙串。
