import 'dart:typed_data';

class SensorBatch {
  SensorBatch({required this.startMicros, required this.values});

  final int startMicros;
  final Float32List values;

  int get count => values.length;

  @override
  bool operator ==(Object other) {
    if (other is! SensorBatch) return false;
    if (other.startMicros != startMicros || other.count != count) return false;

    Uint32List myBits = values.buffer.asUint32List(values.offsetInBytes, count);
    Uint32List otherBits = other.values.buffer.asUint32List(other.values.offsetInBytes, count);
    for (int i = 0; i < count; i++) {
      if (myBits[i] != otherBits[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(startMicros, count);

  @override
  String toString() => 'SensorBatch(startMicros: $startMicros, count: $count)';
}

class SensorInfo {
  SensorInfo({required this.model, required this.maxHz});

  final String model;
  final int maxHz;
}

enum SensorFaultKind { overflow, invalidArgument, decode, internal, injected, missingPlugin, unknown }

class SensorFault implements Exception {
  SensorFault({required this.code, required this.message, int? timestampMicros})
      : timestampMicros = timestampMicros ?? DateTime.now().microsecondsSinceEpoch;

  final String code;
  final String message;
  final int timestampMicros;

  SensorFaultKind get kind {
    switch (code) {
      case 'backpressure_overflow':
        return SensorFaultKind.overflow;
      case 'invalid_argument':
        return SensorFaultKind.invalidArgument;
      case 'decode_error':
        return SensorFaultKind.decode;
      case 'internal':
        return SensorFaultKind.internal;
      case 'injected':
        return SensorFaultKind.injected;
      case 'missing_plugin':
        return SensorFaultKind.missingPlugin;
      default:
        return SensorFaultKind.unknown;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is SensorFault &&
        other.code == code &&
        other.message == message &&
        other.timestampMicros == timestampMicros;
  }

  @override
  int get hashCode => Object.hash(code, message, timestampMicros);

  @override
  String toString() => 'SensorFault($code: $message)';
}
