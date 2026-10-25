/// The Rust lottery kernel is loaded only by compute workers. Linux runs those
/// workers in its independent helper process, outside Flutter's UI runtime.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'num.dart';

class _Kernel {
  _Kernel() {
    final directory = File(Platform.resolvedExecutable).parent.path;
    final library = Platform.isIOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open(
            Platform.isAndroid
                ? 'libhaneoka_team_engine.so'
                : Platform.isWindows
                ? '$directory/haneoka_team_engine.dll'
                : Platform.isMacOS
                ? '$directory/../Frameworks/libhaneoka_team_engine.dylib'
                : '$directory/lib/libhaneoka_team_engine.so',
          );
    run = library
        .lookupFunction<
          Pointer<Uint8> Function(Pointer<Uint8>),
          Pointer<Uint8> Function(Pointer<Uint8>)
        >('haneoka_luck_json');
    release = library
        .lookupFunction<
          Void Function(Pointer<Uint8>),
          void Function(Pointer<Uint8>)
        >('haneoka_string_free');
    cancel = library.lookupFunction<Void Function(), void Function()>(
      'haneoka_cancel',
    );
    context = library
        .lookupFunction<
          Pointer<Uint8> Function(Pointer<Uint8>),
          Pointer<Uint8> Function(Pointer<Uint8>)
        >('haneoka_context_json');
    stream = library
        .lookupFunction<
          Pointer<Uint8> Function(
            Pointer<Uint8>,
            Pointer<NativeFunction<Void Function(Pointer<Uint8>)>>,
          ),
          Pointer<Uint8> Function(
            Pointer<Uint8>,
            Pointer<NativeFunction<Void Function(Pointer<Uint8>)>>,
          )
        >('haneoka_context_stream_json');
    allocate = library
        .lookupFunction<
          Pointer<Uint8> Function(IntPtr),
          Pointer<Uint8> Function(int)
        >('haneoka_buffer_alloc');
    free = library
        .lookupFunction<
          Void Function(Pointer<Uint8>, IntPtr),
          void Function(Pointer<Uint8>, int)
        >('haneoka_buffer_free');
  }
  late final Pointer<Uint8> Function(Pointer<Uint8>) run;
  late final void Function(Pointer<Uint8>) release;
  late final void Function() cancel;
  late final Pointer<Uint8> Function(Pointer<Uint8>) context;
  late final Pointer<Uint8> Function(
    Pointer<Uint8>,
    Pointer<NativeFunction<Void Function(Pointer<Uint8>)>>,
  )
  stream;
  late final Pointer<Uint8> Function(int) allocate;
  late final void Function(Pointer<Uint8>, int) free;
}

final _Kernel? _kernel = nativeLuckAvailable ? _Kernel() : null;
bool get nativeLuckAvailable =>
    Platform.isLinux ||
    Platform.isWindows ||
    Platform.isMacOS ||
    Platform.isAndroid ||
    Platform.isIOS;
void cancelNativeComputations() => _kernel?.cancel();

Doc nativeLuck(Doc input) {
  return _invoke(input, _kernel!.run);
}

Doc _read(Pointer<Uint8> pointer) {
  if (pointer == nullptr) throw StateError('native-engine-result');
  var length = 0;
  while (pointer[length] != 0) {
    length++;
  }
  final output = objectRow(
    jsonDecode(utf8.decode(pointer.asTypedList(length))),
  );
  if (output['error'] != null) throw StateError('${output['error']}');
  return output;
}

Doc _invoke(Doc input, Pointer<Uint8> Function(Pointer<Uint8>) run) {
  return _invokeJson(jsonEncode(input), run);
}

Doc _invokeJson(String input, Pointer<Uint8> Function(Pointer<Uint8>) run) {
  final kernel = _kernel!;
  final bytes = utf8.encode(input);
  final pointer = kernel.allocate(bytes.length + 1);
  if (pointer == nullptr) throw StateError('native-luck-allocation');
  Pointer<Uint8> result = nullptr;
  try {
    pointer.asTypedList(bytes.length + 1)
      ..setRange(0, bytes.length, bytes)
      ..[bytes.length] = 0;
    result = run(pointer);
    return _read(result);
  } finally {
    if (result != nullptr) kernel.release(result);
    kernel.free(pointer, bytes.length + 1);
  }
}

/// One worker owns a release context. Its coordinator disposes the handle
/// before terminating the isolate, including cancellation and fatal errors.
class NativeTeamEngine {
  factory NativeTeamEngine(Doc data, {int workers = 4}) =>
      NativeTeamEngine.fromSerialized(jsonEncode(data), workers: workers);

  factory NativeTeamEngine.fromSerialized(String data, {int workers = 4}) {
    final result = _invokeJson(
      '{"op":"create","data":$data,"trustedScores":true,"workers":$workers}',
      _kernel!.context,
    );
    return NativeTeamEngine._(
      intOf(result['handle']),
      result['cooperativeFloor'] == true,
    );
  }
  NativeTeamEngine._(this.handle, this.cooperativeFloor);
  final int handle;
  final bool cooperativeFloor;
  NativeTeamEngine.fromHandle(this.handle) : cooperativeFloor = false;
  final _charts = <String>[];
  Set<String> chartsToLoad(List<String> keys) {
    final staged = [..._charts];
    final needed = <String>{};
    for (final key in keys) {
      if (!staged.contains(key)) needed.add(key);
      staged.remove(key);
      staged.add(key);
      if (staged.length > 4) staged.removeAt(0);
    }
    return needed;
  }

  void _syncCharts(Doc result) {
    _charts
      ..clear()
      ..addAll([
        for (final key in result['cachedCharts'] as List? ?? const []) '$key',
      ]);
  }

  Doc call(String op, Doc request, List<Doc> charts) {
    final result = _invoke({
      'op': op,
      'handle': handle,
      'request': request,
      'charts': charts,
    }, _kernel!.context);
    _syncCharts(result);
    return result;
  }

  Doc run(
    Doc request,
    List<Doc> charts,
    void Function(Doc) onCandidate, {
    String operation = 'run',
  }) {
    final callback = NativeCallable<Void Function(Pointer<Uint8>)>.isolateLocal(
      (Pointer<Uint8> value) => onCandidate(_read(value)),
    );
    try {
      final result = _invoke({
        'op': operation,
        'handle': handle,
        'request': request,
        'charts': charts,
      }, (input) => _kernel!.stream(input, callback.nativeFunction));
      _syncCharts(result);
      return result;
    } finally {
      callback.close();
    }
  }

  static void dispose(int handle) {
    _invoke({'op': 'dispose', 'handle': handle}, _kernel!.context);
  }
}
