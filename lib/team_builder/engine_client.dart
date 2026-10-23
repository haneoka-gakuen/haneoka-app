/// The engine in a background isolate: it compiles the release once and
/// serves searches. Cancelling kills the isolate, so a long search never
/// blocks; the next call starts a fresh one (`engine/client.ts`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../chart/runtime_chart.dart' show RuntimeChart;
import '../core/storage.dart';

import 'dart:ui' show IsolateNameServer;

import 'package:flutter/services.dart';

import 'engine/api.dart';
import 'engine/execution.dart';
import 'engine/box.dart';
import 'engine/live.dart' show PlayModel, ap;
import 'engine/master.dart';
import 'engine/merge.dart';
import 'engine/num.dart';
import 'engine/native_luck.dart';
import 'engine/objectives.dart' show RouteKind;
import 'engine/power.dart';
import 'engine/search.dart' show SearchStats;

class EngineCancelled implements Exception {
  const EngineCancelled();
}

/// A search for one team's skill windows, for the timeline view.
class TimelineRequest {
  TimelineRequest({
    required this.members,
    required this.snaps,
    required this.unknownPolicy,
    required this.memberKeys,
    required this.snapKeys,
    required this.song,
    required this.order,
    this.play = ap,
  });
  factory TimelineRequest.fromJson(Map<String, Object?> json) =>
      TimelineRequest(
        members: [
          for (final row in json['members'] as List)
            MemberInput.fromJson(objectRow(row)),
        ],
        snaps: [
          for (final row in json['snaps'] as List)
            SnapInput.fromJson(objectRow(row)),
        ],
        unknownPolicy: UnknownPolicy.values.byName('${json['unknownPolicy']}'),
        memberKeys: [for (final key in json['memberKeys'] as List) '$key'],
        snapKeys: [for (final key in json['snapKeys'] as List) key as String?],
        song: SongRef.fromJson(objectRow(json['song'])),
        order: intListOf(json['order']),
        play: PlayModel.fromJson(objectRow(json['play'])),
      );
  Map<String, Object?> toJson() => {
    'members': [for (final row in members) row.toJson()],
    'snaps': [for (final row in snaps) row.toJson()],
    'unknownPolicy': unknownPolicy.name,
    'memberKeys': memberKeys,
    'snapKeys': snapKeys,
    'song': song.toJson(),
    'order': order,
    'play': play.toJson(),
  };
  final List<MemberInput> members;
  final List<SnapInput> snaps;
  final UnknownPolicy unknownPolicy;

  /// Formation slots, leader first.
  final List<String> memberKeys;
  final List<String?> snapKeys;
  final SongRef song;

  /// Formation slot firing at each chart skill event.
  final List<int> order;
  final PlayModel play;
}

class Timeline {
  Timeline(this.durationMs, this.density, this.fever, this.windows);
  factory Timeline.fromJson(Map<String, Object?> json) => Timeline(
    intOf(json['durationMs']),
    intListOf(json['density']),
    [
      for (final row in json['fever'] as List)
        (intOf((row as List)[0]), intOf(row[1])),
    ],
    [
      for (final row in json['windows'] as List)
        SkillWindow.fromJson(objectRow(row)),
    ],
  );
  Map<String, Object?> toJson() => {
    'durationMs': durationMs,
    'density': density,
    'fever': [
      for (final r in fever) [r.$1, r.$2],
    ],
    'windows': [for (final w in windows) w.toJson()],
  };
  final int durationMs;

  /// Note counts per 500 ms.
  final List<int> density;
  final List<(int, int)> fever;
  final List<SkillWindow> windows;
}

typedef _Call = (
  int id,
  String kind,
  Object request,
  Map<String, Uint8List> charts,
);

Future<String> _encodeData(Doc data) => Isolate.run(() => jsonEncode(data));
Future<int> _createNativeContext(String payload) =>
    Isolate.run(() => NativeTeamEngine(jsonDecode(payload) as Doc).handle);

const _engineChannel = MethodChannel('org.haneoka/team_engine');

class _DisplayCall {
  _DisplayCall(this.kind, this.request, this.progress, this.snapshot);
  final String kind;
  final Object request;
  final void Function(int, int)? progress;
  final void Function(EngineSnapshot)? snapshot;
  final completer = Completer<Object?>();
  EngineResponse? latest;
}

/// UI endpoint. The separate Flutter engine owns its coordinator, worker pool,
/// heaps, scores, sorting, snapshots and JSON; this endpoint only displays replies.
class EngineClient {
  EngineClient(this.data, this.chartUrl);
  final Doc data;
  final String? Function(SongRef) chartUrl;
  final _key = 'haneoka-engine-${DateTime.now().microsecondsSinceEpoch}';
  final _pending = <int, _DisplayCall>{};
  int _nextId = 0, _generation = 0;
  bool _disposed = false;
  Object? _failure;
  Isolate? _bridge;
  ReceivePort? _replies, _errors;
  SendPort? _port;
  Future<SendPort>? _ready;
  OwnedTemporaryDirectory? _temporary;

  Future<void> _releaseTemporary() async {
    final owned = _temporary;
    _temporary = null;
    await owned?.dispose();
  }

  Future<SendPort> _connect() => _ready ??= () async {
    if (_disposed) throw const EngineCancelled();
    final ready = Completer<SendPort>();
    final replies = _replies = ReceivePort();
    final errors = _errors = ReceivePort();
    errors.listen((error) async {
      final failure = StateError('engine-bridge:$error');
      _failure = failure;
      if (!ready.isCompleted) ready.completeError(failure);
      for (final call in _pending.values) {
        if (!call.completer.isCompleted) call.completer.completeError(failure);
      }
      _pending.clear();
      await _releaseTemporary();
    });
    replies.listen((message) async {
      if (message is SendPort) {
        _port = message;
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      final (id, kind, payload) = message as (int, String, Object?);
      if (kind == 'fatal') {
        _failure = StateError('$payload');
        for (final call in _pending.values) {
          if (!call.completer.isCompleted) {
            call.completer.completeError(_failure!);
          }
        }
        _pending.clear();
        await _releaseTemporary();
        return;
      }
      if (kind == 'native-start') {
        if (_disposed) return;
        try {
          await _engineChannel.invokeMethod<void>('start', {'key': _key});
        } catch (error) {
          _port?.send((0, 'native-error', '$error'));
        }
        return;
      }
      if (kind == 'native-dispose') {
        try {
          if (!Platform.isLinux) {
            await _engineChannel.invokeMethod<void>('dispose', {'key': _key});
          }
        } finally {
          replies.close();
          errors.close();
          _bridge?.kill(priority: Isolate.immediate);
          await _releaseTemporary();
        }
        return;
      }
      final call = _pending[id];
      if (call == null || call.completer.isCompleted) return;
      if (kind == 'snapshot') {
        final value = payload as EngineSnapshot;
        call.latest = value.response;
        call.snapshot?.call(value);
        return;
      }
      if (kind == 'progress') {
        final (done, total) = payload as (int, int);
        call.progress?.call(done, total);
        return;
      }
      _pending.remove(id);
      if (kind == 'error') {
        call.completer.completeError(StateError('$payload'));
      } else if (kind == 'cancelled') {
        call.completer.completeError(const EngineCancelled());
      } else {
        call.completer.complete(payload);
      }
    });
    final urls = {
      for (final value in objectRow(data['songs']).values)
        for (final difficulty in dataRows(objectRow(value)['difficulty']))
          '${intOf(objectRow(value)['musicId'])}:${intOf(difficulty['difficulty'])}':
              chartUrl(
                SongRef(
                  intOf(objectRow(value)['musicId']),
                  intOf(difficulty['difficulty']),
                ),
              ) ??
              '',
    };
    try {
      if (Platform.isLinux) {
        _temporary = await CacheStorage.instance.createTemporaryDirectory(
          'engine-',
        );
        if (utf8.encode('${_temporary!.directory.path}/ipc').length >= 108) {
          throw const FileSystemException('Engine IPC path exceeds 107 bytes');
        }
      }
      if (_disposed) throw const EngineCancelled();
      final bridge = await Isolate.spawn(
        _displayBridge,
        (replies.sendPort, data, urls, _key, _temporary?.directory.path),
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
      if (_disposed || _failure != null) {
        bridge.kill(priority: Isolate.immediate);
        if (_disposed) throw const EngineCancelled();
        throw _failure!;
      }
      _bridge = bridge;
      return await ready.future;
    } catch (_) {
      replies.close();
      errors.close();
      await _releaseTemporary();
      rethrow;
    }
  }();

  void warm() => _connect().ignore();
  Future<T> _call<T>(
    String kind,
    Object request, [
    void Function(int, int)? progress,
    void Function(EngineSnapshot)? snapshot,
  ]) {
    if (_disposed) return Future.error(const EngineCancelled());
    if (_failure != null) return Future.error(_failure!);
    final id = ++_nextId, generation = _generation;
    final call = _DisplayCall(kind, request, progress, snapshot);
    _pending[id] = call;
    Timer? timer;
    if (request is EngineRequest && request.deadline!.isFinite) {
      timer = Timer(
        Duration(microseconds: (remaining(request.deadline!) * 1000).ceil()),
        () {
          if (!_pending.containsKey(id) || call.completer.isCompleted) return;
          _pending.remove(id);
          final response = call.latest ?? emptyResponse(request);
          response.stopReason = 'budget';
          call.completer.complete(response);
          _port?.send((id, 'abort', null));
        },
      );
    }
    _connect().then(
      (port) {
        if (!_pending.containsKey(id)) return;
        if (generation != _generation) {
          _pending.remove(id);
          if (request is EngineRequest) {
            call.completer.complete(
              emptyResponse(request)..stopReason = 'cancelled',
            );
          } else {
            call.completer.completeError(const EngineCancelled());
          }
          return;
        }
        port.send((id, kind, request));
      },
      onError: (Object error, StackTrace stack) {
        if (_pending.remove(id) != null && !call.completer.isCompleted) {
          call.completer.completeError(error, stack);
        }
      },
    );
    return call.completer.future
        .then((value) => value as T)
        .whenComplete(() => timer?.cancel());
  }

  Future<EngineResponse> run(
    EngineRequest request, [
    void Function(int, int)? progress,
    void Function(EngineSnapshot)? snapshot,
  ]) => _call(
    'run',
    request.copyWith(
      keepTimeLimit: false,
      deadline: deadlineOf(request),
      requestId: request.requestId ?? '$_key-${_nextId + 1}',
    ),
    progress,
    snapshot,
  );
  Future<List<TeamEvaluation>> evaluate(EvaluateRequest request) =>
      _call('evaluate', request);
  Future<Timeline> timeline(TimelineRequest request) =>
      _call('timeline', request);
  void cancel() {
    _generation++;
    _port?.send((0, 'cancel', null));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    for (final call in _pending.values) {
      if (!call.completer.isCompleted) {
        call.completer.completeError(const EngineCancelled());
      }
    }
    _pending.clear();
    IsolateNameServer.removePortNameMapping(_key);
    if (_port != null) {
      _port!.send((0, 'dispose', null));
    } else {
      _bridge?.kill(priority: Isolate.immediate);
      _replies?.close();
      _errors?.close();
      _releaseTemporary().ignore();
    }
  }
}

/// Transport runs beside the UI, while all compute and GC-heavy allocations
/// run in another isolate group. Only JSON and SendPorts cross that boundary.
void _displayBridge(
  (SendPort, Doc, Map<String, String>, String, String?) args,
) {
  final (ui, data, urls, key, temporaryDirectory) = args;
  final calls = ReceivePort(), replies = ReceivePort();
  final host = Completer<SendPort>(), initialized = Completer<void>();
  initialized.future.ignore();
  final kinds = <int, String>{};
  final aborted = <int>{};
  var generation = 0, disposed = false;
  if (!IsolateNameServer.registerPortWithName(replies.sendPort, key)) {
    throw StateError('engine-port-registration');
  }
  ui.send(calls.sendPort);
  if (Platform.isLinux) {
    _processTransport(replies.sendPort, temporaryDirectory!).catchError((
      Object error,
    ) {
      calls.sendPort.send((0, 'native-error', '$error'));
      ui.send((0, 'fatal', '$error'));
    });
  } else {
    ui.send((0, 'native-start', key));
  }
  void close() {
    IsolateNameServer.removePortNameMapping(key);
    calls.close();
    replies.close();
    ui.send((0, 'native-dispose', null));
  }

  replies.listen((message) {
    if (message is SendPort) {
      if (!host.isCompleted) host.complete(message);
      return;
    }
    final row = objectRow(jsonDecode(message as String));
    final id = intOf(row['id']), kind = '${row['kind']}';
    if (kind == 'fatal') {
      if (!host.isCompleted) {
        host.completeError(StateError('${row['message']}'));
      }
      for (final callId in kinds.keys.toList()) {
        ui.send((callId, 'error', row['message']));
      }
      kinds.clear();
      if (!initialized.isCompleted) {
        initialized.completeError(StateError('${row['message']}'));
      }
      ui.send((0, 'fatal', row['message']));
      disposed = true;
      generation++;
      close();
      return;
    }
    if (kind == 'ready') {
      if (!initialized.isCompleted) initialized.complete();
      return;
    }
    if (kind == 'disposed') {
      close();
      return;
    }
    if (kind == 'error' && id == 0) {
      if (!initialized.isCompleted) {
        initialized.completeError(StateError('${row['message']}'));
      }
      return;
    }
    if (kind == 'snapshot') {
      ui.send((id, kind, EngineSnapshot.fromJson(objectRow(row['snapshot']))));
    } else if (kind == 'progress') {
      ui.send((id, kind, (intOf(row['done']), intOf(row['total']))));
    } else if (kind == 'error' || kind == 'cancelled') {
      kinds.remove(id);
      ui.send((id, kind, row['message']));
    } else if (kind == 'result') {
      final result = switch (kinds.remove(id)) {
        'run' => EngineResponse.fromJson(objectRow(row['result'])),
        'evaluate' => [
          for (final value in row['result'] as List)
            TeamEvaluation.fromJson(objectRow(value)),
        ],
        'timeline' => Timeline.fromJson(objectRow(row['result'])),
        _ => null,
      };
      if (result != null) ui.send((id, 'result', result));
    }
  });
  final boot = () async {
    final port = await host.future.timeout(const Duration(seconds: 20));
    port.send(
      jsonEncode({'id': 0, 'kind': 'init', 'data': data, 'urls': urls}),
    );
    await initialized.future.timeout(const Duration(seconds: 20));
    return port;
  }();
  boot.ignore();
  calls.listen((message) async {
    final (id, kind, request) = message as (int, String, Object?);
    if (kind == 'native-error') {
      if (!host.isCompleted) host.completeError(StateError('$request'));
      return;
    }
    if (kind == 'cancel') {
      generation++;
      if (host.isCompleted) {
        try {
          (await host.future).send(jsonEncode({'id': 0, 'kind': 'cancel'}));
        } catch (_) {}
      }
      return;
    }
    if (kind == 'abort') {
      aborted.add(id);
      if (host.isCompleted) {
        try {
          (await host.future).send(jsonEncode({'id': id, 'kind': 'abort'}));
        } catch (_) {}
      }
      return;
    }
    if (kind == 'dispose') {
      disposed = true;
      generation++;
      try {
        (await host.future.timeout(const Duration(seconds: 5)))
            .send(jsonEncode({'id': 0, 'kind': 'dispose'}));
      } catch (_) {
        close();
      }
      return;
    }
    final current = generation;
    try {
      final port = await boot;
      if (disposed || aborted.remove(id)) return;
      if (current != generation) {
        if (request is EngineRequest) {
          ui.send((
            id,
            'result',
            emptyResponse(request)..stopReason = 'cancelled',
          ));
        } else {
          ui.send((id, 'cancelled', null));
        }
        return;
      }
      kinds[id] = kind;
      final value = switch (request) {
        EngineRequest() => request.toJson(),
        EvaluateRequest() => request.toJson(),
        TimelineRequest() => request.toJson(),
        _ => throw StateError('engine-request'),
      };
      port.send(jsonEncode({'id': id, 'kind': kind, 'request': value}));
    } catch (error) {
      ui.send((id, 'error', '$error'));
    }
  });
}

/// Linux runs a separate application process: even VM-wide pauses and runtime
/// worker threads are kept out of the process handling input and drawing.
Future<void> _processTransport(
  SendPort replies,
  String temporaryDirectory,
) async {
  final directory = Directory(temporaryDirectory);
  final path = '${directory.path}/ipc';
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  Process? process;
  Socket? socket;
  final proxy = ReceivePort();
  var closing = false;
  Future<void> cleanup() async {
    if (closing) return;
    closing = true;
    proxy.close();
    socket?.destroy();
    await server.close();
    process?.kill();
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      if (await directory.exists()) rethrow;
    }
  }

  try {
    process = await Process.start(
      Platform.resolvedExecutable,
      ['--haneoka-team-engine-process=$path'],
      environment: {'HANEOKA_COMPUTE_PROCESS': '1'},
    );
    process.stdout.drain<void>().ignore();
    process.stderr.drain<void>().ignore();
    process.exitCode.then((code) {
      if (!closing) {
        replies.send(
          jsonEncode({
            'id': 0,
            'kind': 'fatal',
            'message': 'engine-process-exit:$code',
          }),
        );
        cleanup().ignore();
      }
    });
    socket = await server.first.timeout(const Duration(seconds: 20));
    await server.close();
    proxy.listen((message) {
      socket!.writeln(message as String);
    });
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final value = objectRow(jsonDecode(line));
            if (value['kind'] == 'disposed') {
              cleanup().then((_) => replies.send(line));
            } else {
              replies.send(line);
            }
          },
          onError: (Object error) {
            if (!closing) {
              replies.send(
                jsonEncode({
                  'id': 0,
                  'kind': 'fatal',
                  'message': 'engine-process-io:$error',
                }),
              );
            }
            cleanup().ignore();
          },
          onDone: () => cleanup().ignore(),
        );
    replies.send(proxy.sendPort);
  } catch (_) {
    await cleanup();
    rethrow;
  }
}

Future<void> runTeamEngineProcess(String path) async {
  final socket = await Socket.connect(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  final replies = ReceivePort(), lifetime = ReceivePort();
  final ready = Completer<SendPort>();
  final worker = await Isolate.spawn(
    _engineHostWorker,
    (replies.sendPort, lifetime.sendPort),
    errorsAreFatal: true,
    onError: lifetime.sendPort,
    onExit: lifetime.sendPort,
  );
  replies.listen((message) {
    if (message is SendPort) {
      ready.complete(message);
      return;
    }
    socket.writeln(message as String);
  });
  socket.done.then((_) => exit(0), onError: (Object _) => exit(0));
  final port = await ready.future;
  socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(port.send, onError: (Object _) => exit(0), onDone: () => exit(0));
  await lifetime.first;
  await socket.flush();
  socket.destroy();
  replies.close();
  lifetime.close();
  worker.kill();
  exit(0);
}

/// Booted by a separate native FlutterEngine, not FlutterEngineGroup.spawn.
/// Its root only starts a background coordinator, so platform threads also
/// never parse master data, merge results or run the solver.
Future<void> runTeamEngineHost(String key) async {
  final reply = IsolateNameServer.lookupPortByName(key);
  if (reply == null) return;
  final lifetime = ReceivePort();
  await Isolate.spawn(
    _engineHostWorker,
    (reply, lifetime.sendPort),
    errorsAreFatal: true,
    onError: lifetime.sendPort,
    onExit: lifetime.sendPort,
  );
  final exit = await lifetime.first;
  lifetime.close();
  if (exit is List) {
    reply.send(
      jsonEncode({
        'id': 0,
        'kind': 'fatal',
        'message': 'engine-crashed:${exit.first}',
      }),
    );
  }
}

void _engineHostWorker((SendPort, SendPort) ports) {
  final (reply, _) = ports;
  final calls = ReceivePort();
  reply.send(calls.sendPort);
  _EngineCoordinator? engine;
  final requests = <int, EngineRequest>{};
  void send(int id, String kind, [Object? result]) => reply.send(
    jsonEncode({
      'id': id,
      'kind': kind,
      if (kind == 'result') 'result': result,
    }),
  );
  calls.listen((message) async {
    final row = objectRow(jsonDecode(message as String));
    final id = intOf(row['id']), kind = '${row['kind']}';
    try {
      if (kind == 'init') {
        final data = objectRow(row['data']), urls = objectRow(row['urls']);
        engine = _EngineCoordinator(data, (song) => urls[song.key] as String?)
          ..warm();
        send(0, 'ready');
        return;
      }
      if (kind == 'dispose') {
        engine?.dispose();
        send(0, 'disposed');
        calls.close();
        return;
      }
      if (kind == 'cancel') {
        engine?.cancel();
        return;
      }
      if (kind == 'abort') {
        final request = requests[id];
        if (request != null) engine?.abort(request.requestId!);
        return;
      }
      final current = engine ?? (throw StateError('engine-not-ready'));
      final input = objectRow(row['request']);
      switch (kind) {
        case 'run':
          final request = EngineRequest.fromJson(input);
          requests[id] = request;
          var shownAt = -double.infinity;
          var showedCandidate = false;
          final result = await current.run(
            request,
            (done, total) => reply.send(
              jsonEncode({
                'id': id,
                'kind': 'progress',
                'done': done,
                'total': total,
              }),
            ),
            (snapshot) {
              final now = executionClock();
              final first =
                  !showedCandidate && snapshot.response.overall.isNotEmpty;
              if (!first &&
                  snapshot.stopReason == null &&
                  now - shownAt < 250) {
                return;
              }
              shownAt = now;
              showedCandidate |= snapshot.response.overall.isNotEmpty;
              reply.send(
                jsonEncode({
                  'id': id,
                  'kind': 'snapshot',
                  'snapshot': snapshot.toJson(),
                }),
              );
            },
          );
          requests.remove(id);
          send(id, 'result', result.toJson());
        case 'evaluate':
          send(id, 'result', [
            for (final value in await current.evaluate(
              EvaluateRequest.fromJson(input),
            ))
              value.toJson(),
          ]);
        case 'timeline':
          send(
            id,
            'result',
            (await current.timeline(TimelineRequest.fromJson(input))).toJson(),
          );
        default:
          throw StateError('engine-call:$kind');
      }
    } catch (error) {
      requests.remove(id);
      reply.send(
        jsonEncode({
          'id': id,
          'kind': error is EngineCancelled ? 'cancelled' : 'error',
          'message': '$error',
        }),
      );
    }
  });
}

/// One engine isolate: compiles the release once, then serves calls.
class _Worker {
  _Worker(this.serializedData, this.chartUrls);
  final Future<String> serializedData;
  final Map<String, String> chartUrls;
  Isolate? _isolate;
  SendPort? _port;
  ReceivePort? _replies;
  ReceivePort? _failures;
  Completer<SendPort>? _spawnReady;
  int _generation = 0;
  int? _nativeHandle;
  Future<void>? _ready;
  var _nextId = 1;
  final _pending =
      <
        int,
        (
          Completer<Object?>,
          void Function(int, int)?,
          void Function(EngineSnapshot)?,
        )
      >{};
  final _times = <String, double>{
    'initializationMs': 0,
    'networkMs': 0,
    'computationMs': 0,
  };
  String? _phase;
  double _phaseAt = 0;
  void _setPhase(String? phase) {
    final now = executionClock();
    if (_phase != null) _times[_phase!] = _times[_phase!]! + now - _phaseAt;
    _phase = phase;
    _phaseAt = now;
  }

  double _time(String phase) =>
      _times[phase]! + (_phase == phase ? executionClock() - _phaseAt : 0);
  double get initializationMs => _time('initializationMs');
  double get networkMs => _time('networkMs');
  double get computationMs => _time('computationMs');

  /// Calls in flight; 0 when idle.
  int get load => _pending.length;
  bool get started => _ready != null;

  Future<void> _spawn() => _ready ??= () async {
    _setPhase('initializationMs');
    final generation = _generation;
    final payload = await serializedData;
    if (generation != _generation) throw const EngineCancelled();
    if (nativeLuckAvailable) {
      final handle = await _createNativeContext(payload);
      if (generation != _generation) {
        NativeTeamEngine.dispose(handle);
        throw const EngineCancelled();
      }
      _nativeHandle = handle;
    }
    final replies = _replies = ReceivePort();
    final ready = _spawnReady = Completer<SendPort>();
    final failures = _failures = ReceivePort();
    failures.listen((failure) {
      _disposeNative();
      final error = StateError(
        'engine-crashed:${failure is List ? failure.first : 'worker exited'}',
      );
      if (!ready.isCompleted) ready.completeError(error);
      for (final pending in _pending.values) {
        pending.$1.completeError(error);
      }
      _pending.clear();
      _setPhase(null);
      _isolate?.kill(priority: Isolate.immediate);
      _replies?.close();
      _failures?.close();
      _isolate = null;
      _port = null;
      _ready = null;
    });
    replies.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      final (id, kind, payload) = message as (int, String, Object?);
      final pending = _pending[id];
      if (pending == null) return;
      if (kind == 'phase') {
        _setPhase(payload as String);
        return;
      }
      if (kind == 'snapshot') {
        pending.$3?.call(payload as EngineSnapshot);
        return;
      }
      if (kind == 'progress') {
        final (done, total) = payload as (int, int);
        pending.$2?.call(done, total);
        return;
      }
      _setPhase(null);
      _pending.remove(id);
      if (kind == 'error') {
        pending.$1.completeError(StateError('$payload'));
      } else {
        pending.$1.complete(payload);
      }
    });
    late final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _main,
        (replies.sendPort, payload, chartUrls, _nativeHandle),
        errorsAreFatal: true,
        onError: failures.sendPort,
        onExit: failures.sendPort,
      );
    } catch (_) {
      _disposeNative();
      failures.close();
      replies.close();
      _spawnReady = null;
      _ready = null;
      _setPhase(null);
      rethrow;
    }
    if (generation != _generation) {
      isolate.kill(priority: Isolate.immediate);
      throw const EngineCancelled();
    }
    _isolate = isolate;
    _port = await ready.future;
    _setPhase(null);
  }();

  Future<void> warm() => _spawn();

  Future<T> call<T>(
    String kind,
    Object request,
    Map<String, Uint8List> charts, [
    void Function(int done, int total)? progress,
    void Function(EngineSnapshot)? snapshot,
  ]) async {
    await _spawn();
    _setPhase('computationMs');
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = (completer, progress, snapshot);
    _port!.send((id, kind, request, charts));
    return (await completer.future) as T;
  }

  void cancel() {
    _generation++;
    _disposeNative();
    if (_spawnReady != null && !_spawnReady!.isCompleted) {
      _spawnReady!.completeError(const EngineCancelled());
    }
    _failures?.close();
    _failures = null;
    _setPhase(null);
    for (final pending in _pending.values) {
      pending.$1.completeError(const EngineCancelled());
    }
    _pending.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _replies?.close();
    _isolate = null;
    _port = null;
    _ready = null;
  }

  void _disposeNative() {
    final handle = _nativeHandle;
    _nativeHandle = null;
    if (handle != null) NativeTeamEngine.dispose(handle);
  }
}

/// Worker count follows physical cores on Linux and mobile memory limits.
int _poolSize() {
  final cores = Platform.numberOfProcessors;
  var limit = Platform.isAndroid || Platform.isIOS ? 2 : 8;
  if (Platform.isLinux) {
    try {
      final physical = <String>{};
      final cpuName = RegExp(r'/cpu[0-9]+$');
      for (final cpu in Directory('/sys/devices/system/cpu').listSync()) {
        if (!cpuName.hasMatch(cpu.path)) continue;
        final topology = '${cpu.path}/topology';
        final package = File('$topology/physical_package_id')
            .readAsStringSync()
            .trim();
        final core = File('$topology/core_id').readAsStringSync().trim();
        if (package == '-1' || core == '-1') {
          physical.clear();
          break;
        }
        physical.add('$package:$core');
        if (physical.length >= limit) break;
      }
      if (physical.isNotEmpty) limit = math.min(limit, physical.length);
    } on FileSystemException {
      // Sandboxed Linux installations may hide CPU topology.
    }
  }
  return math.max(1, math.min(limit, cores - 1));
}

/// Below this many members one isolate finishes before the others compile.
const _parallelMinMembers = 15;

/// How long one isolate tries before a song fans out over the pool.
const _quickMs = 700.0;

/// Leader shards per isolate: enough for free isolates to even out uneven
/// subtrees.
const _shardsPerWorker = 4;

/// The engine isolates (`engine/client.ts`): a search runs one song at a
/// time; quick proofs spread over the pool, harder songs split by leader.
class _ShardRun {
  _ShardRun(this.floor);
  double floor;
  bool retry = false;
}

class _EngineCoordinator {
  _EngineCoordinator(this.data, this.chartUrl) {
    final encoded = _encodeData(data);
    final urls = {
      for (final value in objectRow(data['songs']).values)
        for (final difficulty in dataRows(objectRow(value)['difficulty']))
          '${intOf(objectRow(value)['musicId'])}:${intOf(difficulty['difficulty'])}':
              chartUrl(
                SongRef(
                  intOf(objectRow(value)['musicId']),
                  intOf(difficulty['difficulty']),
                ),
              ) ??
              '',
    };
    _pool = [for (var i = 0; i < _poolSize(); i++) _Worker(encoded, urls)];
  }

  /// The merged release document.
  final Doc data;

  /// The pinned chart address of a song difficulty, or null when unknown.
  final String? Function(SongRef song) chartUrl;

  late final List<_Worker> _pool;
  final _bytes = <String, Uint8List>{};
  final _pendingCharts = <String, Future<Uint8List>>{};
  int _chartBytes = 0;
  double _downloadMs = 0;
  final _chartClient = http.Client();

  /// Compiles the release ahead of the first call; the other isolates
  /// compile only when a search fans out.
  void warm() => _pool.first.warm().then((_) {
    for (final worker in _pool.skip(1)) {
      worker.warm().ignore();
    }
  }).ignore();

  _Worker _idlest() => stableSorted(
    _pool,
    (a, b) => a.load != b.load
        ? a.load - b.load
        : (b.started ? 1 : 0) - (a.started ? 1 : 0),
  ).first;

  Future<Uint8List> _chartBytesFor(SongRef song) {
    final known = _bytes.remove(song.key);
    if (known != null) {
      _bytes[song.key] = known;
      return Future.value(known);
    }
    return _pendingCharts[song.key] ??= () async {
      final started = executionClock();
      try {
        final url = chartUrl(song);
        if (url == null) throw RangeError('unknown-chart:${song.key}');
        http.Response? response;
        for (var attempt = 0; attempt < 3; attempt++) {
          if (attempt > 0) {
            await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
          }
          try {
            response = await _chartClient.get(Uri.parse(url));
            if (response.statusCode < 500) break;
          } catch (_) {
            response = null;
          }
        }
        if (response == null) throw StateError('chart-network');
        if (response.statusCode != 200) {
          throw StateError('chart-http-${response.statusCode}');
        }
        final release = response.headers['x-haneoka-release-id'];
        if (release != null &&
            release != Uri.parse(url).queryParameters['release']) {
          throw StateError('chart-release-identity-mismatch');
        }
        final bytes = response.bodyBytes;
        // This is the backend's compressed working set, separate from the
        // user's disk-cache setting. It covers the catalog without repeated
        // network reads while keeping native-worker memory bounded.
        const budget = 64 * 1024 * 1024;
        if (bytes.length <= budget) {
          while (_bytes.isNotEmpty && _chartBytes + bytes.length > budget) {
            _chartBytes -= _bytes.remove(_bytes.keys.first)!.length;
          }
          _bytes[song.key] = bytes;
          _chartBytes += bytes.length;
        }
        return bytes;
      } finally {
        _downloadMs += executionClock() - started;
        _pendingCharts.remove(song.key);
      }
    }();
  }

  Future<Map<String, Uint8List>> _charts(List<SongRef> songs) async => {
    for (final song in songs) song.key: await _chartBytesFor(song),
  };

  Future<void> _queue = Future.value();
  int _generation = 0, _requestId = 0;
  void Function(String)? _activeStop;
  String? _activeRequestId;

  Future<EngineResponse> run(
    EngineRequest request, [
    void Function(int done, int total)? progress,
    void Function(EngineSnapshot)? snapshot,
  ]) {
    final started = executionClock(), generation = _generation;
    final task = request.copyWith(
      keepTimeLimit: false,
      deadline: deadlineOf(request),
      requestId:
          request.requestId ??
          'native-${DateTime.now().microsecondsSinceEpoch}-${++_requestId}',
      contextKey:
          request.contextKey ??
          jsonEncode([
            data['identity'],
            objectRow(data['crossServer'])['identities'],
            request.toJson(),
          ]),
    );
    var expired = false;
    Timer? timer;
    final waiting = Completer<EngineResponse>();
    if (task.deadline!.isFinite) {
      timer = Timer(
        Duration(microseconds: (remaining(task.deadline!) * 1000).ceil()),
        () {
          expired = true;
          final response = emptyResponse(task)..stopReason = 'budget';
          snapshot?.call(
            EngineSnapshot(
              requestId: task.requestId!,
              contextKey: task.contextKey!,
              response: response,
              completed: 0,
              total: response.results.length,
              stopReason: 'budget',
            ),
          );
          waiting.complete(response);
        },
      );
    }
    final queued = _queue.then<EngineResponse>((_) {
      timer?.cancel();
      if (expired || generation != _generation) {
        return emptyResponse(task)
          ..stopReason = expired ? 'budget' : 'cancelled';
      }
      return _execute(task, started, progress, snapshot);
    });
    _queue = queued.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return Future.any([queued, waiting.future])
        .whenComplete(() => timer?.cancel());
  }

  EngineRequest _of(EngineRequest request, SongRef song, double deadline) =>
      request.copyWith(
        goal: switch (request.goal) {
          ScoreGoal(:final criterion, :final play, :final challengeEventId) =>
            ScoreGoal([song], criterion, play, challengeEventId),
          GekisoGoal(
            :final criterion,
            :final accuracy,
            :final rank,
            :final seeds,
          ) =>
            GekisoGoal(
              songs: [song],
              criterion: criterion,
              accuracy: accuracy,
              rank: rank,
              seeds: seeds,
            ),
          final EventGoal goal => goal.copyWith(songs: [song]),
          final goal => goal,
        },
        deadline: deadline,
        seeds: request.seeds.where((hit) => hit.song == song).toList(),
        completed: request.completed
            .where((result) => result.song == song)
            .toList(),
      );

  Future<EngineResponse> _execute(
    EngineRequest request,
    double started,
    void Function(int, int)? progress,
    void Function(EngineSnapshot)? snapshot,
  ) async {
    final downloadStart = _downloadMs;
    final before = [
      for (final worker in _pool)
        (worker.initializationMs, worker.computationMs, worker.networkMs),
    ];
    var latest = emptyResponse(request);
    for (final result in latest.results) {
      result.hits = request.seeds
          .where((hit) => hit.song == result.song)
          .take(request.k)
          .toList();
    }
    latest.overall.addAll(
      stableSorted([
        for (final result in latest.results) ...result.hits,
      ], compareHits).take(request.k),
    );
    var stopped = false, lastShown = -double.infinity;
    void publish(EngineResponse response, [bool force = false]) {
      if (stopped) return;
      final hadCandidate = latest.overall.isNotEmpty;
      for (final result in response.results) {
        final previous = latest.results
            .where((r) => r.song == result.song)
            .firstOrNull;
        if (previous != null && !result.proven) {
          final seen = <String>{};
          result.hits =
              stableSorted([...result.hits, ...previous.hits], compareHits)
                  .where(
                    (hit) => seen.add(([...hit.members]..sort()).join(',')),
                  )
                  .take(request.k)
                  .toList();
        }
      }
      latest = EngineResponse(
        results: response.results,
        overall: stableSorted([
          for (final r in response.results) ...r.hits,
        ], compareHits).take(request.k).toList(),
        unknownCards: response.unknownCards,
        elapsedMs: executionClock() - started,
        plan: response.plan,
        stopReason: response.stopReason,
        error: response.error,
        timing: EngineTiming(
          initializationMs: [
            for (final (i, worker) in _pool.indexed)
              worker.initializationMs - before[i].$1,
          ].fold(0, (a, b) => a + b),
          computationMs: [
            for (final (i, worker) in _pool.indexed)
              worker.computationMs - before[i].$2,
          ].fold(0, (a, b) => a + b),
          networkMs:
              _downloadMs -
              downloadStart +
              [
                for (final (i, worker) in _pool.indexed)
                  worker.networkMs - before[i].$3,
              ].fold(0, (a, b) => a + b),
          wallMs: executionClock() - started,
        ),
      );
      if (!force &&
          (hadCandidate || latest.overall.isEmpty) &&
          executionClock() - lastShown < 100) {
        return;
      }
      lastShown = executionClock();
      snapshot?.call(
        EngineSnapshot(
          requestId: request.requestId!,
          contextKey: request.contextKey!,
          response: latest,
          completed: latest.results
              .where((r) => r.proven || r.exclusion != null)
              .length,
          total: latest.results.length,
          stopReason: latest.stopReason,
        ),
      );
    }

    final interrupted = Completer<EngineResponse>();
    void stop(String reason) {
      if (stopped) return;
      latest.stopReason = reason;
      publish(latest, true);
      stopped = true;
      cancelNativeComputations();
      for (final worker in _pool) {
        worker.cancel();
      }
      interrupted.complete(latest);
    }

    _activeStop = stop;
    _activeRequestId = request.requestId;
    final deadline = request.deadline!;
    final timer = deadline.isFinite
        ? Timer(
            Duration(microseconds: (remaining(deadline) * 1000).ceil()),
            () => stop('budget'),
          )
        : null;
    void accept(EngineSnapshot value) {
      if (!stopped &&
          value.requestId == request.requestId &&
          value.contextKey == request.contextKey) {
        publish(value.response);
      }
    }

    Future<EngineResponse> send(
      _Worker worker,
      EngineRequest task, [
      void Function(EngineSnapshot)? onSnapshot,
      bool forwardProgress = true,
    ]) async {
      if (stopped || remaining(task.deadline!) == 0) return emptyResponse(task);
      final loaded = await _charts(
        requestSongs(task).whereType<SongRef>().toList(),
      );
      if (stopped || remaining(task.deadline!) == 0) return emptyResponse(task);
      return worker.call(
        'run',
        task,
        loaded,
        forwardProgress ? progress : null,
        onSnapshot ?? accept,
      );
    }

    Future<EngineResponse> work() async {
      if (remaining(deadline) == 0) {
        stop('budget');
        return latest;
      }
      if (completeResponse(latest)) return latest;
      final gekiso = request.goal is GekisoGoal;
      final songs = requestSongs(request);
      final eventGoal = request.goal;
      final missions =
          eventGoal is EventGoal &&
              eventGoal.gekiso != null &&
              request.k == 1 &&
              eventGoal.songs.length == 1
          ? intListOf(
              objectRow(
                objectRow(
                  objectRow(data['songs'])['${eventGoal.songs.first.songId}'],
                )['gekisou'],
              )['missionTypes'],
            )
          : <int>[];
      final wholeReward =
          missions.isNotEmpty &&
          missions.every((kind) => kind == 2 || kind == 3);
      final phasedReward =
          nativeLuckAvailable &&
          missions.isNotEmpty &&
          missions.every((kind) => kind == 1);
      final parallel =
          !wholeReward &&
          _pool.length > 1 &&
          request.members.length >= _parallelMinMembers &&
          request.goal is! PlanGoal &&
          !(gekiso && request.constraints.leader != null && songs.length == 1);
      if (!parallel) return send(_idlest(), request);
      if (songs.length > 1 && songs.every((song) => song != null)) {
        final parts = [...latest.results];
        EngineResponse merged() => EngineResponse(
          results: [...parts],
          overall: [],
          unknownCards: latest.unknownCards,
          elapsedMs: executionClock() - started,
        );
        var next = 0, done = 0;
        Future<void> runSong(_Worker worker) async {
          while (!stopped && remaining(deadline) > 0 && next < songs.length) {
            final index = next++, song = songs[index]!;
            if (parts[index].proven) {
              progress?.call(++done, songs.length);
              continue;
            }
            final share =
                remaining(deadline) * _pool.length / (songs.length - index);
            final task = _of(
              request,
              song,
              math.min(deadline, executionClock() + share),
            );
            final response = await send(worker, task, (value) {
              if (stopped ||
                  value.contextKey != request.contextKey ||
                  value.requestId != request.requestId) {
                return;
              }
              parts[index] = value.response.results.firstOrNull ?? parts[index];
              publish(merged());
            }, false);
            if (stopped) return;
            parts[index] = response.results.firstOrNull ?? parts[index];
            publish(merged());
            progress?.call(++done, songs.length);
          }
        }

        await Future.wait([for (final worker in _pool) runSong(worker)]);
        return merged();
      }
      Future<EngineResponse> runShards(
        EngineRequest request,
        void Function(EngineResponse) publish, [
        int stage = -1,
      ]) async {
        var seeds = request.seeds;
        if (gekiso) {
          final seeding = await send(
            _idlest(),
            request.copyWith(seedOnly: true),
          );
          publish(seeding);
          seeds = [for (final r in seeding.results) ...r.hits];
        } else if (!request.noFloor && stage < 0) {
          final quick = await send(
            _idlest(),
            request.copyWith(
              deadline: math.min(deadline, executionClock() + _quickMs),
            ),
            (value) => publish(value.response),
          );
          publish(quick);
          if (completeResponse(quick)) return quick;
          seeds = [for (final r in quick.results) ...r.hits];
        }
        final goal = request.goal;
        final sampledRewards = goal is EventGoal && goal.gekiso != null;
        final nominalGekiso = goal is GekisoGoal && goal.seeds == 0;
        final workers = request.rewardPhase != null
            ? _pool.take(4).toList()
            : nominalGekiso
            ? _pool.take(5).toList()
            : _pool;
        final count = gekiso || sampledRewards
            ? (request.constraints.leader == null ? workers.length : 1)
            : workers.length * _shardsPerWorker;
        double valueOf(EngineHit hit) => switch (request.rewardPhase?['kind']) {
          'other' => hit.event?.otherMean ?? 0,
          'score' => hit.score?.mean ?? 0,
          _ => hit.key,
        };
        final responses = [
          for (var i = 0; i < count; i++) emptyResponse(request),
        ];
        for (final response in responses) {
          for (final result in response.results) {
            result.hits = seeds
                .where((hit) => hit.song == result.song)
                .take(request.k)
                .toList();
          }
        }
        var next = 0, done = 0;
        EngineResponse merge() => mergeShardResponses(
          responses,
          request.k,
          executionClock() - started,
        );
        final active = <_Worker, _ShardRun>{};
        Future<void> runShard(_Worker worker) async {
          while (!stopped && remaining(deadline) > 0 && next < count) {
            final index = next++;
            while (!stopped && remaining(deadline) > 0) {
              final current = merge();
              final floors = {
                for (final result in current.results)
                  if (result.song != null && result.hits.length >= request.k)
                    result.song!.key: valueOf(result.hits[request.k - 1]),
              };
              final job = _ShardRun(
                floors.values.fold<double>(-double.infinity, math.max),
              );
              active[worker] = job;
              final phase = request.rewardPhase;
              final phaseFloor = phase != null && phase['kind'] != 'primary'
                  ? {...phase, 'floor': math.max(0.0, job.floor)}
                  : phase;
              late EngineResponse response;
              try {
                response = await send(
                  worker,
                  request.copyWith(
                    seeds: sampledRewards ? current.overall : seeds,
                    seeded:
                        gekiso || (phase != null && current.overall.isNotEmpty),
                    rewardPhase: phaseFloor,
                    shard: (index: index, count: count),
                    floors: phase != null && phase['kind'] != 'primary'
                        ? const {}
                        : floors,
                  ),
                  (value) {
                    if (stopped ||
                        job.retry ||
                        !identical(active[worker], job) ||
                        value.contextKey != request.contextKey ||
                        value.requestId != request.requestId) {
                      return;
                    }
                    if (phase != null &&
                        value.response.overall.length >= request.k) {
                      job.floor = math.max(
                        job.floor,
                        valueOf(value.response.overall[request.k - 1]),
                      );
                    }
                    responses[index] = value.response;
                    publish(merge());
                  },
                  false,
                );
              } catch (_) {
                if (job.retry && !stopped) continue;
                rethrow;
              } finally {
                active.remove(worker);
              }
              if (stopped) return;
              responses[index] = response;
              publish(merge());
              done++;
              progress?.call(
                stage < 0 ? done : stage * count + done,
                stage < 0 ? count : 3 * count,
              );
              if (sampledRewards &&
                  !request.noFloor &&
                  completeResponse(response) &&
                  response.overall.length >= request.k) {
                final floor = valueOf(response.overall[request.k - 1]);
                for (final entry in active.entries) {
                  if (!entry.value.retry && floor > entry.value.floor) {
                    entry.value.retry = true;
                    entry.key.cancel();
                  }
                }
              }
              break;
            }
          }
        }

        await Future.wait([for (final worker in workers) runShard(worker)]);
        final merged = merge();
        if (!aspirationHeld(merged, request.k) &&
            !request.noFloor &&
            remaining(deadline) > 0) {
          return send(
            _idlest(),
            request.copyWith(seeds: merged.overall, noFloor: true),
          );
        }
        return merged;
      }

      if (!phasedReward) return runShards(request, publish);
      var seeds = request.seeds;
      var response = emptyResponse(request);
      for (final (stage, kind) in ['primary', 'other', 'score'].indexed) {
        if (stopped || remaining(deadline) == 0) return latest;
        final best = seeds.firstOrNull;
        final phase = <String, Object?>{
          'kind': kind,
          if (kind != 'primary') 'reward': best!.key,
          if (kind == 'score') 'other': best!.event?.otherMean ?? 0,
        };
        EngineResponse publicResponse(EngineResponse value) => EngineResponse(
          results: [
            for (final part in value.results)
              SongResult(
                song: part.song,
                hits: [...part.hits],
                proven: kind == 'score' && part.proven,
                bound: null,
                stats: part.stats,
                excludedBelow: part.excludedBelow,
                exclusion: part.exclusion,
              ),
          ],
          overall: [...value.overall],
          unknownCards: value.unknownCards,
          elapsedMs: value.elapsedMs,
          stopReason: value.stopReason,
          error: value.error,
        );
        response = await runShards(
          request.copyWith(
            seeds: seeds,
            rewardPhase: phase,
            completed: const [],
          ),
          (value) => publish(publicResponse(value)),
          stage,
        );
        if (stopped) return latest;
        if (!completeResponse(response) || response.overall.isEmpty) {
          return publicResponse(response);
        }
        if (response.results.any((part) => part.rewardPhase != kind)) {
          throw StateError('engine-reward-phase-mismatch');
        }
        seeds = response.overall;
        response = publicResponse(response);
      }
      return response;
    }

    try {
      final response = await Future.any([work(), interrupted.future]);
      if (!stopped) {
        response.stopReason = completeResponse(response)
            ? 'complete'
            : 'budget';
        publish(response, true);
      }
      return latest;
    } catch (error) {
      if (stopped) return latest;
      latest.error = '$error';
      stop('error');
      if (latest.overall.isNotEmpty) return latest;
      rethrow;
    } finally {
      timer?.cancel();
      if (_activeStop == stop) {
        _activeStop = null;
        _activeRequestId = null;
      }
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() work) {
    final generation = _generation;
    final queued = _queue.then((_) {
      if (generation != _generation) throw const EngineCancelled();
      return work();
    });
    _queue = queued.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return queued;
  }

  Future<List<TeamEvaluation>> evaluate(EvaluateRequest request) => _enqueue(
    () async =>
        _pool.first.call('evaluate', request, await _charts(request.songs)),
  );
  Future<Timeline> timeline(TimelineRequest request) => _enqueue(
    () async =>
        _pool.first.call('timeline', request, await _charts([request.song])),
  );

  void abort(String requestId) {
    if (_activeRequestId == requestId) {
      cancelNativeComputations();
      _activeStop?.call('budget');
    }
  }

  /// Stops every call in flight.
  void cancel() {
    cancelNativeComputations();
    _generation++;
    _activeStop?.call('cancelled');
    for (final worker in _pool) {
      worker.cancel();
    }
  }

  void dispose() {
    cancel();
    _chartClient.close();
  }
}

class EvaluateRequest {
  EvaluateRequest({
    required this.members,
    required this.snaps,
    required this.player,
    required this.unknownPolicy,
    required this.team,
    required this.songs,
    required this.play,
    required this.challengeEventId,
    required this.event,
  });
  factory EvaluateRequest.fromJson(Map<String, Object?> json) =>
      EvaluateRequest(
        members: [
          for (final row in json['members'] as List)
            MemberInput.fromJson(objectRow(row)),
        ],
        snaps: [
          for (final row in json['snaps'] as List)
            SnapInput.fromJson(objectRow(row)),
        ],
        player: PlayerInput.fromJson(objectRow(json['player'])),
        unknownPolicy: UnknownPolicy.values.byName('${json['unknownPolicy']}'),
        team: TeamSpec.fromJson(objectRow(json['team'])),
        songs: [
          for (final row in json['songs'] as List)
            SongRef.fromJson(objectRow(row)),
        ],
        play: PlayModel.fromJson(objectRow(json['play'])),
        challengeEventId: (json['challengeEventId'] as num?)?.toInt(),
        event: json['event'] is Map
            ? (
                eventId: intOf(objectRow(json['event'])['eventId']),
                route: RouteKind.values.byName(
                  '${objectRow(json['event'])['route']}',
                ),
                consumption: intOf(objectRow(json['event'])['consumption']),
              )
            : null,
      );
  Map<String, Object?> toJson() => {
    'members': [for (final r in members) r.toJson()],
    'snaps': [for (final r in snaps) r.toJson()],
    'player': player.toJson(),
    'unknownPolicy': unknownPolicy.name,
    'team': team.toJson(),
    'songs': [for (final r in songs) r.toJson()],
    'play': play.toJson(),
    'challengeEventId': challengeEventId,
    'event': event == null
        ? null
        : {
            'eventId': event!.eventId,
            'route': event!.route.name,
            'consumption': event!.consumption,
          },
  };
  final List<MemberInput> members;
  final List<SnapInput> snaps;
  final PlayerInput player;
  final UnknownPolicy unknownPolicy;
  final TeamSpec team;
  final List<SongRef> songs;
  final PlayModel play;
  final int? challengeEventId;
  final ({int eventId, RouteKind route, int consumption})? event;
}

void _main((SendPort, String, Map<String, String>, int?) args) {
  final (reply, json, urls, nativeHandle) = args;
  final native = nativeHandle == null
      ? null
      : NativeTeamEngine.fromHandle(nativeHandle);
  var activeId = 0;
  final client = http.Client();
  late final master = compileTeamData(jsonDecode(json) as Doc);
  final bytes = <String, Uint8List>{};
  Future<Uint8List> loadBytes(SongRef song) async {
    final cached = bytes.remove(song.key);
    if (cached != null) return cached;
    final url = urls[song.key];
    if (url == null || url.isEmpty) throw StateError('chart-file-missing');
    reply.send((activeId, 'phase', 'networkMs'));
    http.Response? response;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
      try {
        response = await client.get(Uri.parse(url));
        if (response.statusCode < 500) break;
      } catch (_) {
        response = null;
      }
    }
    if (response == null) throw StateError('chart-network');
    if (response.statusCode != 200) {
      throw StateError('chart-http:${response.statusCode}');
    }
    final release = response.headers['x-haneoka-release-id'];
    final pinned = Uri.parse(url).queryParameters['release'];
    if (release != null && release != pinned) {
      throw StateError('chart-release-identity-mismatch');
    }
    reply.send((activeId, 'phase', 'computationMs'));
    return response.bodyBytes;
  }

  late final charts = ChartCache(
    master,
    (song) async => RuntimeChart.fromBytes(await loadBytes(song)),
  );
  Future<List<Doc>> nativeSources(List<SongRef> songs) async {
    final needed = native!.chartsToLoad([for (final song in songs) song.key]);
    final sources = <Doc>[];
    for (final song in songs) {
      if (!needed.contains(song.key)) {
        bytes.remove(song.key);
        continue;
      }
      final raw = await loadBytes(song);
      final decoded = raw.length >= 2 && raw[0] == 0x1f && raw[1] == 0x8b
          ? gzip.decode(raw)
          : raw;
      sources.add({
        'song': song.toJson(),
        'chart': jsonDecode(utf8.decode(decoded)),
      });
    }
    return sources;
  }

  final port = ReceivePort();
  reply.send(port.sendPort);
  port.listen((message) async {
    final (id, kind, request, chartBytes) = message as _Call;
    activeId = id;
    bytes.addAll(chartBytes);
    try {
      final Object result;
      switch (kind) {
        case 'run':
          final r = request as EngineRequest;
          if (native != null) {
            final sources = await nativeSources(
              requestSongs(r).whereType<SongRef>().toList(),
            );
            result = EngineResponse.fromJson(
              native.run(r.toJson(), sources, (value) {
                final song = value['song'] is Map
                    ? SongRef.fromJson(objectRow(value['song']))
                    : null;
                final hits = [
                  for (final hit in value['hits'] as List)
                    EngineHit.fromJson(objectRow(hit)),
                ];
                final response = emptyResponse(r);
                final index = response.results.indexWhere(
                  (row) => row.song == song,
                );
                if (index >= 0) {
                  response.results[index] = SongResult(
                    song: song,
                    hits: hits,
                    proven: false,
                    bound: double.infinity,
                    stats: SearchStats(),
                  );
                }
                response.overall.addAll(hits);
                reply.send((
                  id,
                  'snapshot',
                  EngineSnapshot(
                    requestId: r.requestId!,
                    contextKey: r.contextKey!,
                    response: response,
                    completed: 0,
                    total: response.results.length,
                  ),
                ));
              }),
            );
            reply.send((
              id,
              'progress',
              (requestSongs(r).length, requestSongs(r).length),
            ));
            break;
          }
          result = await runEngine(
            master,
            charts,
            r,
            onProgress: (done, total) =>
                reply.send((id, 'progress', (done, total))),
            onSnapshot: (snapshot) => reply.send((id, 'snapshot', snapshot)),
          );
        case 'evaluate':
          final r = request as EvaluateRequest;
          if (native != null) {
            final resultJson = native.call(
              'evaluateAll',
              r.toJson(),
              await nativeSources(r.songs),
            );
            result = [
              for (final row in resultJson['evaluations'] as List)
                TeamEvaluation.fromJson(objectRow(row)),
            ];
            break;
          }
          result = await evaluateTeam(
            master,
            charts,
            members: r.members,
            snaps: r.snaps,
            player: r.player,
            unknownPolicy: r.unknownPolicy,
            team: r.team,
            songs: r.songs,
            play: r.play,
            challengeEventId: r.challengeEventId,
            event: r.event,
          );
        case 'timeline':
          if (native != null) {
            final r = request as TimelineRequest;
            result = Timeline.fromJson(
              native.call(
                'timeline',
                r.toJson(),
                await nativeSources([r.song]),
              ),
            );
            break;
          }
          result = await _timeline(master, charts, request as TimelineRequest);
        default:
          throw UnsupportedError(kind);
      }
      reply.send((id, 'result', result));
    } catch (error) {
      reply.send((id, 'error', '$error'));
    }
  });
}

Future<Timeline> _timeline(
  EngineMaster master,
  ChartCache charts,
  TimelineRequest request,
) async {
  final box = resolveBox(
    master,
    request.members,
    request.snaps,
    request.unknownPolicy,
  );
  final chart = await charts.chart(request.song);
  final density = List<int>.filled(((chart.lastNoteMs + 1000) / 500).ceil(), 0);
  for (final time in chart.times) {
    density[time ~/ 500]++;
  }
  final members = [
    for (final key in request.memberKeys)
      box.members.firstWhere((member) => member.key == key),
  ];
  final snaps = <SnapState?>[
    for (final key in request.snapKeys)
      key == null
          ? null
          : box.snaps.where((snap) => snap.key == key).firstOrNull,
  ];
  return Timeline(
    chart.lastNoteMs + 1000,
    density,
    chart.feverMs,
    skillWindows(master, chart, members, snaps, request.order),
  );
}
