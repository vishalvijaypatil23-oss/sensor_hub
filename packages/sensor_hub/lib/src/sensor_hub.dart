import 'dart:async';

import 'package:flutter/services.dart';

import 'codec.dart';
import 'models.dart';

const String controlChannelName = 'sensor_hub/control';
const String batchChannelName = 'sensor_hub/batches';
const String faultChannelName = 'sensor_hub/faults';

abstract class SensorHub {
  static SensorHub? _instance;

  static SensorHub get instance {
    _instance ??= MethodChannelSensorHub();
    return _instance!;
  }

  Future<void> start({required int hz});
  Future<void> stop();
  Future<SensorInfo> describe();
  Stream<SensorBatch> get batches;
  Stream<SensorFault> get faults;
}

class SafeSensorHubCodec extends SensorHubCodec {
  const SafeSensorHubCodec();

  @override
  Object? decodeMessage(ByteData? message) {
    try {
      return super.decodeMessage(message);
    } catch (error) {
      return SensorFault(code: 'decode_error', message: error.toString());
    }
  }
}

class MethodChannelSensorHub implements SensorHub {
  MethodChannelSensorHub({BinaryMessenger? binaryMessenger})
      : controlChannel = MethodChannel(controlChannelName, const StandardMethodCodec(), binaryMessenger),
        batchChannel = BasicMessageChannel<Object?>(batchChannelName, const SafeSensorHubCodec(),
            binaryMessenger: binaryMessenger),
        faultChannel = BasicMessageChannel<Object?>(faultChannelName, const SafeSensorHubCodec(),
            binaryMessenger: binaryMessenger);

  static MethodChannelSensorHub? currentHub;

  final MethodChannel controlChannel;
  final BasicMessageChannel<Object?> batchChannel;
  final BasicMessageChannel<Object?> faultChannel;

  final StreamController<SensorBatch> batchController = StreamController<SensorBatch>.broadcast(sync: true);
  final StreamController<SensorFault> faultController = StreamController<SensorFault>.broadcast(sync: true);

  Future<void>? attachFuture;
  bool isAttached = false;
  bool isRunning = false;

  int startCount = 0;

  @override
  Stream<SensorBatch> get batches => batchController.stream;

  @override
  Stream<SensorFault> get faults => faultController.stream;

  @override
  Future<void> start({required int hz}) async {
    if (hz <= 0) {
      throw ArgumentError.value(hz, 'hz', 'must be greater than 0');
    }
    startCount++;
    int thisStart = startCount;
    isRunning = false;

    await ensureAttached();
    await callNative('start', {'hz': hz});

    if (thisStart == startCount && isAttached) {
      isRunning = true;
    }
  }

  @override
  Future<void> stop() async {
    startCount++;
    isRunning = false;

    await ensureAttached();
    await callNative('stop');
  }

  @override
  Future<SensorInfo> describe() async {
    await ensureAttached();
    Map<Object?, Object?>? info = await callNative('describe');
    if (info == null) {
      throw reportFault(SensorFault(code: 'internal', message: 'describe returned nothing'));
    }
    return SensorInfo(
      model: info['model'] as String? ?? 'unknown',
      maxHz: info['maxHz'] as int? ?? 0,
    );
  }

  Future<Map<Object?, Object?>> debugStats() async {
    await ensureAttached();
    Map<Object?, Object?>? stats = await callNative('debugStats');
    return stats ?? {};
  }

  Future<void> debugInjectFault() async {
    await ensureAttached();
    await callNative('debugInjectFault');
  }

  Future<void> ensureAttached() {
    attachFuture ??= attach();
    return attachFuture!;
  }

  Future<void> attach() async {
    if (currentHub != null && currentHub != this) {
      currentHub!.detach();
    }
    currentHub = this;

    batchChannel.setMessageHandler(onBatchMessage);
    faultChannel.setMessageHandler(onFaultMessage);

    try {
      await callNative('attach');
    } catch (error) {
      attachFuture = null;
      rethrow;
    }
    isAttached = true;
  }

  void detach() {
    isAttached = false;
    isRunning = false;
    startCount++;
    batchController.close();
    faultController.close();
  }

  Future<Object?> onBatchMessage(Object? message) async {
    if (message is SensorFault) {
      reportFault(message);
    } else if (message is SensorBatch) {
      if (isAttached && isRunning) {
        batchController.add(message);
      }
    } else {
      reportFault(SensorFault(code: 'decode_error', message: 'Unexpected $message on $batchChannelName'));
    }
    return true;
  }

  Future<Object?> onFaultMessage(Object? message) async {
    if (message is SensorFault && isAttached) {
      reportFault(message);
    }
    return null;
  }

  SensorFault reportFault(SensorFault fault) {
    if (!faultController.isClosed) {
      faultController.add(fault);
    }
    return fault;
  }

  Future<dynamic> callNative(String method, [Object? arguments]) async {
    try {
      return await controlChannel.invokeMethod<dynamic>(method, arguments);
    } on PlatformException catch (e) {
      throw reportFault(SensorFault(code: e.code, message: e.message ?? e.code));
    } on MissingPluginException catch (e) {
      throw reportFault(SensorFault(code: 'missing_plugin', message: e.message ?? method));
    }
  }
}
