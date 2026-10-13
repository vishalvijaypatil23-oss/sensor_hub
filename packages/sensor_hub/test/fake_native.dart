import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensor_hub/sensor_hub.dart';

class FakeNative {
  FakeNative(this.messenger) {
    messenger.setMockMessageHandler(controlChannelName, onControlMessage);
  }

  final TestDefaultBinaryMessenger messenger;
  final StandardMethodCodec methodCodec = const StandardMethodCodec();
  final SensorHubCodec codec = const SensorHubCodec();

  List<String> calls = [];

  Map<String, Completer<void>> heldMethods = {};

  Completer<void> hold(String method) {
    Completer<void> completer = Completer<void>();
    heldMethods[method] = completer;
    return completer;
  }

  Future<ByteData?> onControlMessage(ByteData? message) async {
    MethodCall call = methodCodec.decodeMethodCall(message);
    calls.add(call.method);

    Completer<void>? held = heldMethods.remove(call.method);
    if (held != null) {
      await held.future;
    }

    if (call.method == 'attach' || call.method == 'stop') {
      return methodCodec.encodeSuccessEnvelope(null);
    }
    if (call.method == 'start') {
      int hz = call.arguments['hz'];
      if (hz > 1000) {
        return methodCodec.encodeErrorEnvelope(code: 'invalid_argument', message: 'hz must be in 1..1000, was $hz');
      }
      return methodCodec.encodeSuccessEnvelope(null);
    }
    if (call.method == 'describe') {
      return methodCodec.encodeSuccessEnvelope({'model': 'FakePhone', 'maxHz': 1000});
    }
    return null;
  }

  Future<Object?> sendBytes(String channel, ByteData? bytes) async {
    ByteData? reply = await messenger.handlePlatformMessage(channel, bytes, null);
    return codec.decodeMessage(reply);
  }

  Future<Object?> sendBatch(SensorBatch batch) {
    return sendBytes(batchChannelName, codec.encodeMessage(batch));
  }

  Future<Object?> sendFault(SensorFault fault) {
    return sendBytes(faultChannelName, codec.encodeMessage(fault));
  }

  void dispose() {
    messenger.setMockMessageHandler(controlChannelName, null);
    messenger.setMessageHandler(batchChannelName, null);
    messenger.setMessageHandler(faultChannelName, null);
  }
}

SensorBatch makeBatch(int startMicros, int count, {double offset = 0}) {
  Float32List values = Float32List(count);
  for (int i = 0; i < count; i++) {
    values[i] = offset + i / 8;
  }
  return SensorBatch(startMicros: startMicros, values: values);
}
