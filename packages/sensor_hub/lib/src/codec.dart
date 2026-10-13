import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

class SensorHubCodec extends StandardMessageCodec {
  const SensorHubCodec();

  static const int batchType = 128;
  static const int faultType = 129;

  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is SensorBatch) {
      buffer.putUint8(batchType);
      buffer.putInt64(value.startMicros);
      buffer.putInt32(value.count);
      buffer.putFloat32List(value.values);
    } else if (value is SensorFault) {
      buffer.putUint8(faultType);
      writeValue(buffer, value.code);
      writeValue(buffer, value.message);
      buffer.putInt64(value.timestampMicros);
    } else {
      super.writeValue(buffer, value);
    }
  }

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) {
    if (type == batchType) {
      int startMicros = buffer.getInt64();
      int count = buffer.getInt32();
      if (count < 0) {
        throw FormatException('SensorBatch with negative count $count');
      }
      Float32List values = Float32List.fromList(buffer.getFloat32List(count));
      return SensorBatch(startMicros: startMicros, values: values);
    }

    if (type == faultType) {
      Object? code = readValue(buffer);
      Object? message = readValue(buffer);
      int timestampMicros = buffer.getInt64();
      if (code is! String || message is! String) {
        throw const FormatException('SensorFault with a non-string code or message');
      }
      return SensorFault(code: code, message: message, timestampMicros: timestampMicros);
    }

    return super.readValueOfType(type, buffer);
  }
}
