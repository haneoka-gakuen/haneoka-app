import 'dart:async';
import 'dart:isolate';

import 'puzzle_model.dart';

void _solve((SendPort, int, List<int>, List<int>, int) input) {
  final (reply, size, tiles, goal, budget) = input;
  reply.send(solvePuzzle(size, tiles, goal, budget));
}

class PuzzleSolveTask {
  PuzzleSolveTask(int size, List<int> tiles, List<int> goal, int budget) {
    _reply.listen((value) {
      if (!_result.isCompleted) _result.complete(value as SolveResult);
      _close();
    });
    _errors.listen((_) {
      if (!_result.isCompleted) {
        _result.complete(SolveResult('error', [], 0, 0, 0));
      }
      _close();
    });
    Isolate.spawn(
      _solve,
      (_reply.sendPort, size, tiles, goal, budget),
      onError: _errors.sendPort,
      errorsAreFatal: true,
    ).then(
      (worker) {
        if (_closed) {
          worker.kill(priority: Isolate.immediate);
        } else {
          _worker = worker;
        }
      },
      onError: (Object _) {
        if (!_result.isCompleted) {
          _result.complete(SolveResult('error', [], 0, 0, 0));
        }
        _close();
      },
    );
  }
  final _reply = ReceivePort(), _errors = ReceivePort();
  final _result = Completer<SolveResult>();
  Isolate? _worker;
  bool _closed = false;
  Future<SolveResult> get result => _result.future;
  void cancel() {
    if (!_result.isCompleted) {
      _result.complete(SolveResult('cancelled', [], 0, 0, 0));
    }
    _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _worker?.kill(priority: Isolate.immediate);
    _reply.close();
    _errors.close();
  }
}
