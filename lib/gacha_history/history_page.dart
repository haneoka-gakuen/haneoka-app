import '../core/site_date.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:game_data_exporter/gacha_history_points.dart';

import '../account/haneoka_account.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../core/storage.dart';
import '../save/account_store.dart';
import '../save/game_save.dart';
import '../shell/links.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../sources/files.dart';
import '../ui/game_account_sheet.dart';
import '../ui/game_release_picker.dart';
import 'game_history_client.dart';
import 'history_catalog.dart';
import 'history_cloud_sync.dart';
import 'history_repository.dart';
import 'history_sessions.dart';
import 'history_screen.dart';
import 'history_snapshot.dart';
import 'history_view.dart';

Future<Object?> _historyJson(Uint8List bytes) =>
    Isolate.run(() => jsonDecode(utf8.decode(bytes)));

void openGameHistory(BuildContext context, GameSave save) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HistoryPage(initialSave: save, readOnOpen: true),
        settings: const RouteSettings(name: '/gacha-history'),
      ),
    );

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    this.initialSave,
    this.readOnOpen = false,
    this.initialTab,
  });
  final GameSave? initialSave;
  final bool readOnOpen;
  final String? initialTab;
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryChoice {
  const _HistoryChoice(
    this.key,
    this.region,
    this.save,
    this.record, {
    this.persist,
  });
  final String key;
  final GameHistoryRegion region;
  final GameSave? save;
  final StoredHistory? record;
  final HistorySession? persist;
}

class _HistoryPageState extends State<HistoryPage> {
  final _repository = HistoryRepository.instance;
  final _accounts = AccountStore.instance;
  final _sessions = HistorySessionStore.instance;
  final _cloud = HistoryCloudSync.instance;
  String? _cloudOwner;
  Map<String, HistorySession> get _persists => _sessions.records;
  static final _catalogs = <(HaneokaApi, int), Future<HistoryCatalog>>{};
  String _selected = '';
  String _historyKind = '';
  String? _errorCode;
  bool _importing = false;
  bool _opened = false;
  bool _ready = false;
  final _preferredRegions = <String, String>{};
  String? _currencyCode;
  final _conversions = <String, GachaHistoryConversion>{};
  final _defaultConversions =
      <(String, double?, double?), GachaHistoryConversion>{};

  String _t(String key) =>
      AppScope.of(context).text('catalog.gachaHistory.$key');

  @override
  void initState() {
    super.initState();
    _repository.addListener(_changed);
    _accounts.addListener(_changed);
    _cloudOwner = _cloud.owner;
    _cloud.addListener(_cloudChanged);
    unawaited(_load());
  }

  Future<void> _load() async {
    await Future.wait([_repository.load(), _accounts.load(), _sessions.load()]);
    final preferences = await SharedPreferences.getInstance();
    try {
      final regions = jsonDecode(
        preferences.getString('gachaHistory.regions') ?? '{}',
      );
      if (regions is Map) {
        for (final entry in regions.entries) {
          if (entry.key is String && entry.value is String) {
            _preferredRegions[entry.key as String] = entry.value as String;
          }
        }
      }
    } on FormatException {
      // Region selection starts from the most recent successful read.
    }
    final currency = preferences.getString('gachaHistory.currency');
    double? price(String key) {
      final value = preferences.getDouble(key);
      return value != null && value.isFinite && value >= 0 ? value : null;
    }

    if (currency != null &&
        const {
          'JPY',
          'TWD',
          'HKD',
          'MOP',
          'USD',
          'KRW',
          'CNY',
        }.contains(currency)) {
      _currencyCode = currency;
      if (preferences.getBool('gachaHistory.price.$currency') != false) {
        _conversions[currency] = GachaHistoryConversion(
          currencyCode: currency,
          freeUnitGemPrice: price('gachaHistory.freeUnitGemPrice') ?? 0,
          paidUnitGemPrice:
              price('gachaHistory.paidUnitGemPrice') ??
              price('gachaHistory.unitGemPrice'),
        );
      }
    }
    for (final code in const [
      'JPY',
      'TWD',
      'HKD',
      'MOP',
      'USD',
      'KRW',
      'CNY',
    ]) {
      if (preferences.getBool('gachaHistory.price.$code') != true) continue;
      _conversions[code] = GachaHistoryConversion(
        currencyCode: code,
        freeUnitGemPrice: price('gachaHistory.price.$code.free') ?? 0,
        paidUnitGemPrice: price('gachaHistory.price.$code.paid'),
      );
    }
    if (mounted) setState(() => _ready = true);
    unawaited(_cloud.sync());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _cloudChanged() {
    if (!mounted) return;
    setState(() {
      if (_cloudOwner != _cloud.owner) {
        _cloudOwner = _cloud.owner;
        _errorCode = null;
        _historyKind = '';
        if (!_choices().any((choice) => choice.key == _selected)) {
          _selected = '';
        }
      }
    });
  }

  @override
  void dispose() {
    _cloud.removeListener(_cloudChanged);
    _repository.removeListener(_changed);
    _accounts.removeListener(_changed);
    super.dispose();
  }

  SaveCollector _collector(List<HistorySession> persists) => SaveCollector(
    onDocument: (document, candidate) {
      final release = candidate.release;
      if (release == null) return;
      final session = HistorySession.fromDocument(
        document,
        release,
        candidate.modifiedAt,
      );
      if (session != null) persists.add(session);
    },
  );

  HistorySession? _persistFor(GameSave save) {
    final key = historyPersistKey(
      save.documents[SaveDocumentKind.persist]?.data,
    );
    return _persists['$key-${save.server}'];
  }

  List<_HistoryChoice> _choices() {
    final saves = [..._accounts.saves];
    final initial = widget.initialSave;
    if (initial != null &&
        !saves.any((save) => historySaveKey(save) == historySaveKey(initial))) {
      saves.insert(0, initial);
    }
    final records = {
      for (final record in _cloud.visibleRecords) record.key: record,
    };
    final byCloudKey = {
      for (final record in records.values)
        HistoryCloudSync.accountKeyFor(record): record,
    };
    StoredHistory? recordFor(GameSave save, GameHistoryRegion region) {
      final persist = historyPersistKey(
        save.documents[SaveDocumentKind.persist]?.data,
      );
      return records[HistoryRepository.accountKey(save, region)] ??
          records[HistoryRepository.persistAccountKey(
            save.documents[SaveDocumentKind.persist]?.data,
            region,
          )] ??
          (persist == null
              ? null
              : byCloudKey[historyPortableKey(
                  '$persist-${region.id}',
                  region.id,
                )]);
    }

    final choices = [
      for (final save in saves)
        for (final region in GameHistoryRegion.values)
          if (region.catalogServer == save.server)
            _HistoryChoice(
              HistoryRepository.accountKey(save, region),
              region,
              save,
              recordFor(save, region),
              persist: _persistFor(save),
            ),
    ];
    for (final persist in _persists.values) {
      if (saves.any(
        (save) =>
            save.server == persist.release.server &&
            historyPersistKey(save.documents[SaveDocumentKind.persist]?.data) ==
                persist.sessionKey,
      )) {
        continue;
      }
      for (final region in GameHistoryRegion.values) {
        if (region.catalogServer != persist.release.server) continue;
        final key = '${persist.sessionKey}-${region.id}';
        choices.add(
          _HistoryChoice(
            key,
            region,
            null,
            records[key] ?? byCloudKey[historyPortableKey(key, region.id)],
            persist: persist,
          ),
        );
      }
    }
    final used = {
      ...choices.map((choice) => choice.key),
      ...choices.map((choice) => choice.record?.key),
      for (final choice in choices)
        if (choice.save case final save?)
          HistoryRepository.persistAccountKey(
            save.documents[SaveDocumentKind.persist]?.data,
            choice.region,
          ),
    };
    return [
      ...choices,
      for (final record in records.values)
        if (!used.contains(record.key))
          _HistoryChoice(
            record.key,
            GameHistoryRegion.values.firstWhere(
              (region) => region.id == record.snapshot.server,
            ),
            null,
            record,
          ),
    ];
  }

  String? _cloudKey(_HistoryChoice? choice) {
    if (choice == null) return null;
    if (choice.record case final record?) {
      return HistoryCloudSync.accountKeyFor(record);
    }
    final hash =
        choice.persist?.sessionKey ??
        historyPersistKey(
          choice.save?.documents[SaveDocumentKind.persist]?.data,
        );
    return hash == null
        ? null
        : historyPortableKey('$hash-${choice.region.id}', choice.region.id);
  }

  String _regionLabel(GameHistoryRegion region) => _t(switch (region) {
    GameHistoryRegion.jp => 'regionJp',
    GameHistoryRegion.hmt => 'regionHmt',
    GameHistoryRegion.en => 'regionEn',
    GameHistoryRegion.ko => 'regionKo',
  });

  String? get _error => _errorCode == null
      ? null
      : _t(switch (_errorCode) {
          'history_missing_session' => 'errorMissingSession',
          'history_session_expired' => 'errorSessionExpired',
          'history_service_unavailable' => 'errorServiceUnavailable',
          'history_version_unavailable' => 'errorVersionUnavailable',
          'history_response_invalid' => 'errorResponseInvalid',
          'history_import_invalid' => 'errorImportInvalid',
          'history_catalog_unavailable' => 'errorCatalogUnavailable',
          _ => 'errorNetwork',
        });

  GameHistoryRegion? _preferredRegion(
    GameRelease release, {
    GameSave? save,
    HistorySession? session,
  }) {
    if (release == GameRelease.jp) return GameHistoryRegion.jp;
    final identity = save == null ? session?.sessionKey : historySaveKey(save);
    final remembered = GameHistoryRegion.values
        .where(
          (region) =>
              region.id == _preferredRegions[identity] &&
              region.catalogServer == release.server,
        )
        .firstOrNull;
    if (remembered != null) return remembered;
    final keys = {
      if (save != null) historySaveKey(save),
      if (session != null) session.sessionKey,
      if (save != null)
        historyPersistKey(save.documents[SaveDocumentKind.persist]?.data),
    }.whereType<String>().toSet();
    final previous =
        _repository.records
            .where((record) => keys.contains(record.saveKey))
            .toList()
          ..sort(
            (a, b) => b.snapshot.queriedAt.compareTo(a.snapshot.queriedAt),
          );
    if (previous.isNotEmpty) {
      return GameHistoryRegion.values.firstWhere(
        (region) => region.id == previous.first.snapshot.server,
      );
    }
    return null;
  }

  Future<void> _rememberRegion(_HistoryChoice choice) async {
    final identity = choice.save == null
        ? choice.persist?.sessionKey
        : historySaveKey(choice.save!);
    if (identity == null) return;
    _preferredRegions[identity] = choice.region.id;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'gachaHistory.regions',
      jsonEncode(_preferredRegions),
    );
  }

  Future<void> _refresh(String key, {bool select = true}) async {
    final choice = _choices().where((value) => value.key == key).firstOrNull;
    if (choice == null || (choice.save == null && choice.persist == null)) {
      return;
    }
    if (mounted && (select || _selected == key)) {
      setState(() {
        if (select) _selected = key;
        _errorCode = null;
      });
    }
    try {
      if (choice.persist case final persist?) {
        await _repository.refreshPersist(
          persist.document,
          choice.region,
          account: choice.save,
        );
      } else {
        await _repository.refresh(choice.save!, choice.region);
      }
      await _rememberRegion(choice);
      unawaited(_cloud.sync(force: true, localChange: true));
    } on GameHistoryException catch (error) {
      if (mounted && _selected == key) setState(() => _errorCode = error.code);
    } on Exception {
      if (mounted && _selected == key) {
        setState(() => _errorCode = 'history_network_error');
      }
    }
  }

  Future<void> _acceptSaves(
    Iterable<GameSave> values, {
    Iterable<HistorySession> persists = const [],
  }) async {
    final saves = values.toList(), sessions = persists.toList();
    if ((saves.isEmpty && sessions.isEmpty) ||
        saves.any((save) => save.release == null)) {
      throw const FormatException('history_import_invalid');
    }
    for (final save in saves) {
      await _accounts.put(save);
      unawaited(HaneokaAccount.instance.syncIfLinked(save));
    }
    await _sessions.putAll(sessions);
    unawaited(_cloud.sync(force: true, localChange: true));
    final save = saves.firstOrNull, persist = sessions.firstOrNull;
    final release = save?.release ?? persist!.release;
    final preferred = _preferredRegion(release, save: save, session: persist);
    final region = preferred ?? GameHistoryRegion.hmt;
    final choice = _choices().where((choice) {
      if (choice.region != region) return false;
      if (save != null) {
        return choice.key == HistoryRepository.accountKey(save, region);
      }
      return choice.persist?.sessionKey == persist!.sessionKey;
    }).firstOrNull;
    if (!mounted || choice == null) return;
    setState(() => _selected = choice.key);
    if (preferred != null &&
        (choice.persist != null ||
            (choice.save != null &&
                historySessionFromSave(choice.save!) != null))) {
      unawaited(_refresh(_selected));
    }
  }

  Future<void> _files() async {
    final chosen = await FilePicker.pickFiles();
    if (chosen.isEmpty || !mounted) return;
    setState(() {
      _importing = true;
      _errorCode = null;
    });
    CacheStorage.instance.beginImport();
    try {
      if (chosen.length > 128) {
        throw const FormatException('history_import_invalid');
      }
      final persists = <HistorySession>[];
      final collector = _collector(persists);
      final current = _choices()
          .where((value) => value.key == _selected)
          .firstOrNull;
      final initialRelease =
          current?.save?.release ??
          current?.persist?.release ??
          (AppScope.of(context).server == 'jp'
              ? GameRelease.jp
              : GameRelease.intlOfficial);
      GameRelease? rawRelease;
      var snapshots = 0;
      final rawAccounts = <GameSave>[];
      var totalBytes = 0;
      for (final file in chosen) {
        final length = await file.length();
        if (length == null) {
          throw const FormatException('history_import_invalid');
        }
        totalBytes += length;
        if (length > historyResponseLimit * 2 ||
            totalBytes > historyResponseLimit * 4) {
          throw const FormatException('history_import_invalid');
        }
        final bytes = await file.readAsBytes();
        Object? json;
        try {
          json = await _historyJson(bytes);
        } on FormatException {
          json = null;
        }
        if (json is Map &&
            (json['schema'] == historySnapshotSchema ||
                json['format'] == 'otonote-gacha-history')) {
          final record = await _repository.import(
            HistorySnapshot.fromJson(json),
          );
          _selected = record.key;
          snapshots++;
        } else if (AccountStore.decode(json) case final save?) {
          if (save.release == null) {
            throw const FormatException('history_import_invalid');
          }
          rawAccounts.add(save);
        } else {
          if (!mounted) return;
          final declaredRelease =
              json is Map && json['schema'] == 'haneoka-game-save-v1'
              ? GameRelease.fromPackage('${json['release']}')
              : null;
          if (declaredRelease == null) {
            rawRelease ??= await chooseGameSaveRelease(
              context,
              initial: initialRelease,
            );
            if (rawRelease == null) return;
          }
          FileSaveSource(
            collector,
            release: declaredRelease ?? rawRelease,
          ).addBytes(bytes, file.path ?? file.name);
        }
      }
      if (collector.saves.isNotEmpty ||
          rawAccounts.isNotEmpty ||
          persists.isNotEmpty) {
        await _acceptSaves([
          ...collector.saves,
          ...rawAccounts,
        ], persists: persists);
      } else if (snapshots == 0) {
        throw const FormatException('history_import_invalid');
      }
    } on TypeError {
      if (mounted) setState(() => _errorCode = 'history_import_invalid');
    } on Exception {
      if (mounted) setState(() => _errorCode = 'history_import_invalid');
    } finally {
      CacheStorage.instance.endImport();
      if (mounted) setState(() => _importing = false);
    }
  }

  /// One entry for every way in: a stored game account, a new one read
  /// from the game, or a history file.
  Future<void> _import() async {
    final choice = await chooseGameAccount(
      context,
      actions: [
        GameAccountSheetAction(
          'files',
          Symbols.upload_file_rounded,
          _t('filesSource'),
        ),
      ],
    );
    if (choice == null || !mounted) return;
    if (choice.action == 'files') return _files();
    setState(() => _errorCode = null);
    try {
      await _acceptSaves([choice.save!]);
    } on FormatException {
      if (mounted) setState(() => _errorCode = 'history_import_invalid');
    }
  }

  Future<void> _export(GachaHistoryExport selection) async {
    final choice = _choices()
        .where((value) => value.key == selection.accountKey)
        .firstOrNull;
    final snapshot = choice == null
        ? null
        : _snapshotFor(choice, selection.historyKind);
    if (snapshot == null) return;
    final indexes = selection.batches
        .map((batch) => int.tryParse(batch.id.split(':').last))
        .whereType<int>()
        .toSet();
    final identity =
        snapshot.accountKey ??
        (choice!.record!.saveKey == null
            ? choice.record!.key
            : historyPortableKey(choice.record!.key, snapshot.server));
    final selected = snapshot.forAccount(identity).selected(indexes);
    await FilePicker.saveFile(
      fileName: 'haneoka-gacha-${snapshot.server}.json',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(selected.toJson()))),
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
  }

  HistorySnapshot? _snapshotFor(_HistoryChoice choice, String? kind) {
    final snapshot = choice.record?.history(kind), save = choice.save;
    if (snapshot == null || save == null) return snapshot;
    final HistoryAccountState state;
    try {
      state = projectHistoryAccountState(
        save.player,
        server: choice.region.id,
        collectedAt: (save.modifiedAt ?? DateTime.now())
            .toUtc()
            .toIso8601String(),
      );
    } on FormatException {
      return snapshot;
    }
    final previousAt = snapshot.accountState?['collectedAt'];
    if (previousAt is String &&
        DateTime.parse(previousAt)
            .isAfter(DateTime.parse(state['collectedAt'] as String))) {
      return snapshot;
    }
    return snapshot.withAccountState(state);
  }

  Future<void> _images(List<GlobalKey> pages) async {
    final archive = Archive();
    Uint8List? first;
    for (var index = 0; index < pages.length; index++) {
      final boundary = pages[index].currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw const FormatException('history_image');
      }
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw const FormatException('history_image');
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        first ??= bytes;
        archive.addFile(
          ArchiveFile('haneoka-gacha-${index + 1}.png', bytes.length, bytes),
        );
      } finally {
        image.dispose();
      }
    }
    if (pages.isEmpty || first == null) return;
    final zipped = pages.length > 1;
    await FilePicker.saveFile(
      fileName: 'haneoka-gacha.${zipped ? 'zip' : 'png'}',
      bytes: zipped ? Uint8List.fromList(ZipEncoder().encode(archive)) : first,
      type: FileType.custom,
      allowedExtensions: [zipped ? 'zip' : 'png'],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final choices = _choices();
    if (_ready && _selected.isEmpty && choices.isNotEmpty) {
      final initial = widget.initialSave;
      final preferred = initial?.release == null
          ? null
          : _preferredRegion(initial!.release!, save: initial);
      _selected =
          choices
              .where(
                (value) =>
                    initial != null &&
                    value.save != null &&
                    value.region == preferred &&
                    historySaveKey(value.save!) == historySaveKey(initial),
              )
              .firstOrNull
              ?.key ??
          choices.first.key;
    }
    final current = choices
        .where((value) => value.key == _selected)
        .firstOrNull;
    if (_ready && !_opened && current != null) {
      _opened = true;
      if (widget.readOnOpen &&
          current.save?.release != null &&
          _preferredRegion(current.save!.release!, save: current.save) !=
              null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_refresh(_selected));
        });
      }
    }
    final snapshot = current == null
        ? null
        : _snapshotFor(current, _historyKind);
    final needsCatalog = snapshot?.executions.isNotEmpty ?? false;
    final api = state.apiFor(current?.region.catalogServer ?? state.server);
    final catalog = !needsCatalog
        ? null
        : cachedResource(_catalogs, (
            api,
            api.revision,
          ), () => HistoryCatalog.load(api));
    return FutureBuilder<HistoryCatalog>(
      key: ValueKey((api, api.revision)),
      future: catalog,
      builder: (context, data) {
        final source = data.data;
        final currencyCode =
            _currencyCode ??
            switch (current?.region) {
              GameHistoryRegion.jp => 'JPY',
              GameHistoryRegion.en => 'USD',
              GameHistoryRegion.ko => 'KRW',
              _ => 'TWD',
            };
        final defaultConversion = historyDefaultGemConversion(
          currencyCode,
          baseTopUp: source?.baseTopUp,
        );
        final conversion =
            _conversions[currencyCode] ??
            _defaultConversions.putIfAbsent((
              currencyCode,
              defaultConversion.freeUnitGemPrice,
              defaultConversion.paidUnitGemPrice,
            ), () => defaultConversion);
        final fallback = snapshot == null
            ? <GachaHistoryBatch>[]
            : [
                for (final (index, execution) in snapshot.executions.indexed)
                  GachaHistoryBatch(
                    id: '$index',
                    accountKey: _selected,
                    poolId: execution.poolId ?? '',
                    productId: execution.productId,
                    pulledAt: execution.executedAt == null
                        ? null
                        : DateTime.fromMillisecondsSinceEpoch(
                            execution.executedAt! * 1000,
                            isUtc: true,
                          ),
                    drawCount: execution.prizes.length,
                    prizes: [
                      for (final prize in execution.prizes)
                        GachaHistoryPrize(
                          id: prize.prizeId,
                          kind: 'unknown',
                          name: '${_t('unknown')} · ${prize.prizeId}',
                          rarity: '',
                          rarityLabel: _t('unknown'),
                          quantity: 1,
                          converted: prize.converted,
                        ),
                    ],
                    cost: GachaHistoryCost(
                      freeGems: execution.freeGems,
                      paidGems: execution.paidGems,
                      tickets: execution.tickets,
                    ),
                  ),
              ];
        final cloudKey = _cloudKey(current);
        return GachaHistoryScreen(
          cloudSignedIn: _cloud.signedIn,
          cloudBusy: _cloud.busy,
          cloudLinked: _cloud.isLinked(cloudKey),
          cloudRefreshPending: _cloud.pendingFor(cloudKey),
          cloudErrorCode: _cloud.errorCode,
          onCloudLink: cloudKey == null
              ? null
              : (linked) => unawaited(_cloud.setLinked(cloudKey, linked)),
          onCloudSync: () => unawaited(_cloud.sync(force: true)),
          onCloudRefresh:
              cloudKey == null ||
                  !_cloud.isLinked(cloudKey) ||
                  !_cloud.hasDocument(cloudKey)
              ? null
              : () => unawaited(_cloud.requestRefresh(cloudKey)),
          accounts: [
            for (final choice in choices)
              GachaHistoryAccount(
                key: choice.key,
                server: choice.region.id,
                offsetMinutes: choice.region.offsetMinutes,
                serverLabel: _regionLabel(choice.region),
                label:
                    choice.save?.name ??
                    (choice.record == null
                        ? null
                        : SiteDate.day(state.text.locale).withTime().format(
                            choice.record!.snapshot.queriedAt.toLocal(),
                          )) ??
                    _t('account'),
              ),
          ],
          pools:
              source?.poolViews(
                state.text.text,
                (category) => state.text(
                  'catalog.recruitments.types.$category',
                  category,
                ),
                snapshot: snapshot,
              ) ??
              const [],
          batches: snapshot == null
              ? const []
              : source?.batchViews(
                      snapshot,
                      _selected,
                      state.text.text,
                      _t('unknown'),
                    ) ??
                    fallback,
          selectedAccountKey: _selected,
          historyKinds:
              current?.record?.histories
                  .map((history) => history.historyKind)
                  .toList() ??
              const [],
          selectedHistoryKind: snapshot?.historyKind ?? '',
          onHistoryKindChanged: (kind) => setState(() => _historyKind = kind),
          historyLoaded: snapshot != null,
          busy: !_ready || _importing || _repository.isReading(_selected),
          error: _error,
          catalogLoading:
              needsCatalog && data.connectionState == ConnectionState.waiting,
          catalogError: needsCatalog && data.hasError
              ? _t('errorCatalogUnavailable')
              : null,
          onCatalogRetry: () => setState(() {
            _catalogs.remove((api, api.revision));
          }),
          onAccountChanged: (key) {
            setState(() {
              _selected = key;
              _historyKind = '';
              _errorCode = null;
            });
            final choice = _choices()
                .where((value) => value.key == key)
                .firstOrNull;
            if (choice != null) unawaited(_rememberRegion(choice));
          },
          onRefresh: current?.save == null && current?.persist == null
              ? null
              : (key) => unawaited(_refresh(key)),
          onImport: _import,
          initialTab: widget.initialTab,
          onExport: snapshot == null
              ? null
              : (value) => unawaited(_export(value)),
          onExportImage: snapshot == null ? null : _images,
          currencyConversion: conversion,
          onConversionChanged: (value) {
            final changedCurrency = value.currencyCode != currencyCode;
            if (!changedCurrency) {
              _conversions[value.currencyCode] = value;
            }
            setState(() => _currencyCode = value.currencyCode);
            unawaited(_saveConversion(value, savePrices: !changedCurrency));
          },
          onOpenCard: (href) => unawaited(openLink(context, href)),
        );
      },
    );
  }

  Future<void> _saveConversion(
    GachaHistoryConversion value, {
    bool savePrices = true,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('gachaHistory.currency', value.currencyCode);
    final priceKey = 'gachaHistory.price.${value.currencyCode}';
    if (!savePrices) {
      if (!preferences.containsKey(priceKey)) {
        await preferences.setBool(priceKey, false);
      }
      return;
    }
    await preferences.setBool(priceKey, true);
    for (final (key, price) in [
      ('gachaHistory.freeUnitGemPrice', value.freeUnitGemPrice),
      ('gachaHistory.paidUnitGemPrice', value.paidUnitGemPrice),
      ('gachaHistory.price.${value.currencyCode}.free', value.freeUnitGemPrice),
      ('gachaHistory.price.${value.currencyCode}.paid', value.paidUnitGemPrice),
    ]) {
      if (price != null) {
        await preferences.setDouble(key, price);
      } else {
        await preferences.remove(key);
      }
    }
    await preferences.remove('gachaHistory.unitGemPrice');
  }
}
