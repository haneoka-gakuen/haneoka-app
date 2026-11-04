import 'dart:isolate';
import 'dart:typed_data';

import 'package:game_data_exporter/save_codec.dart';

export 'package:game_data_exporter/save_codec.dart' show SaveCodec;

Future<Map<String, Object?>?> decodeSaveAsync(Uint8List bytes) =>
    Isolate.run(() => SaveCodec.decode(bytes));
