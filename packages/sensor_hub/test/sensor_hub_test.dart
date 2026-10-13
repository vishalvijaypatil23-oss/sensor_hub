import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensor_hub/sensor_hub.dart';

import 'fake_native.dart';

const int startTime = 1760000000000000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNative native;

  setUp(() {
    native = FakeNative(TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger);
  });

  tearDown(() {
    native.dispose();
  });

  test('a batch arrives decoded and Dart replies true (ready) to native', () async {
    MethodChannelSensorHub hub = MethodChannelSensorHub();
    List<SensorBatch> received = [];
    hub.batches.listen(received.add);

    await hub.start(hz: 200);
    expect(native.calls, ['attach', 'start']);

    SensorBatch batch = makeBatch(startTime, 10);
    Object? reply = await native.sendBatch(batch);

    expect(reply, isTrue, reason: 'the reply is the backpressure "ready" signal');
    expect(received, [batch]);
  });

  test('bytes written by hand, the way Kotlin/Swift write them, decode correctly', () async {
    MethodChannelSensorHub hub = MethodChannelSensorHub();
    List<SensorBatch> received = [];
    hub.batches.listen(received.add);
    await hub.start(hz: 200);

    int start = 0x7FFFFFFF + 42;
    ByteData bytes = ByteData(16 + 4 * 3);
    bytes.setUint8(0, 128);
    bytes.setInt64(1, start, Endian.little);
    bytes.setInt32(9, 3, Endian.little);
    bytes.setFloat32(16, 0.25, Endian.little);
    bytes.setFloat32(20, -1.5, Endian.little);
    bytes.setFloat32(24, 3.0, Endian.little);

    expect(await native.sendBytes(batchChannelName, bytes), isTrue);
    expect(received.single.startMicros, start);
    expect(received.single.values, [0.25, -1.5, 3.0]);
  });

  test('stop() while a batch is in flight: nothing is delivered after it completes', () async {
    MethodChannelSensorHub hub = MethodChannelSensorHub();
    List<SensorBatch> received = [];
    hub.batches.listen(received.add);
    await hub.start(hz: 200);

    SensorBatch before = makeBatch(startTime, 10);
    await native.sendBatch(before);

    Completer<void> nativeStop = native.hold('stop');
    Future<void> stopping = hub.stop();
    bool stopDone = false;
    stopping.then((_) {
      stopDone = true;
    });

    Object? reply = await native.sendBatch(makeBatch(startTime + 50000, 10));
    expect(stopDone, isFalse);
    expect(reply, isTrue, reason: 'still answered, so native never gets stuck');

    nativeStop.complete();
    await stopping;
    expect(stopDone, isTrue);

    await native.sendBatch(makeBatch(startTime + 100000, 10));
    await Future<void>.delayed(Duration.zero);

    expect(received, [before]);
  });

  test('batches before start() are dropped', () async {
    MethodChannelSensorHub hub = MethodChannelSensorHub();
    List<SensorBatch> received = [];
    hub.batches.listen(received.add);
    await hub.describe();

    expect(await native.sendBatch(makeBatch(startTime, 4)), isTrue);
    expect(received, isEmpty);
  });

  test('startMicros above 2^31, 2^32 and 2^53 survives the channel', () async {
    MethodChannelSensorHub hub = MethodChannelSensorHub();
    List<SensorBatch> received = [];
    hub.batches.listen(received.add);
    await hub.start(hz: 200);

    List<int> starts = [0x80000000, 0x80000001, 0x100000007, (1 << 53) + 1, startTime];
    for (int start in starts) {
      await native.sendBatch(makeBatch(start, 3));
    }

    List<int> receivedStarts = [];
    for (SensorBatch batch in received) {
      receivedStarts.add(batch.startMicros);
    }
    expect(receivedStarts, starts);
  });

  group('errors are typed', () {
    test('a native fault arrives on faults as a SensorFault', () async {
      MethodChannelSensorHub hub = MethodChannelSensorHub();
      List<SensorFault> faults = [];
      hub.faults.listen(faults.add);
      hub.batches.listen((_) {}, onError: (Object e) => fail('error on batches: $e'));
      await hub.start(hz: 200);

      SensorFault fault = SensorFault(
        code: 'backpressure_overflow',
        message: 'dropped 12 oldest samples',
        timestampMicros: startTime,
      );
      await native.sendFault(fault);

      expect(faults, [fault]);
      expect(faults.single.kind, SensorFaultKind.overflow);
    });

    test('bad bytes on batches become a decode fault, never an error on batches', () async {
      MethodChannelSensorHub hub = MethodChannelSensorHub();
      List<SensorFault> faults = [];
      List<Object> errors = [];
      hub.faults.listen(faults.add);
      hub.batches.listen((_) {}, onError: errors.add);
      await hub.start(hz: 200);

      ByteData truncated = ByteData(13);
      truncated.setUint8(0, 128);
      truncated.setInt64(1, startTime, Endian.little);
      truncated.setInt32(9, 1000, Endian.little);
      expect(await native.sendBytes(batchChannelName, truncated), isTrue);

      expect(errors, isEmpty);
      expect(faults.single.kind, SensorFaultKind.decode);
    });

    test('a PlatformException from start() becomes a SensorFault (thrown and sent on faults)', () async {
      MethodChannelSensorHub hub = MethodChannelSensorHub();
      List<SensorFault> faults = [];
      List<Object> errors = [];
      hub.faults.listen(faults.add);
      hub.batches.listen((_) {}, onError: errors.add);

      await expectLater(
        hub.start(hz: 5000),
        throwsA(isA<SensorFault>().having((SensorFault f) => f.kind, 'kind', SensorFaultKind.invalidArgument)),
      );
      expect(faults.single.kind, SensorFaultKind.invalidArgument);
      expect(errors, isEmpty);
    });
  });

  test('describe() returns SensorInfo', () async {
    SensorInfo info = await MethodChannelSensorHub().describe();
    expect(info.model, 'FakePhone');
    expect(info.maxHz, 1000);
  });

  test('hot restart: one handler, native is reset, old batch dropped, no duplicates', () async {
    MethodChannelSensorHub oldHub = MethodChannelSensorHub();
    List<SensorBatch> oldReceived = [];
    bool oldClosed = false;
    oldHub.batches.listen(oldReceived.add, onDone: () {
      oldClosed = true;
    });
    await oldHub.start(hz: 200);
    SensorBatch firstBatch = makeBatch(startTime, 10);
    await native.sendBatch(firstBatch);

    Completer<void> nativeAttach = native.hold('attach');
    MethodChannelSensorHub newHub = MethodChannelSensorHub();
    List<SensorBatch> newReceived = [];
    newHub.batches.listen(newReceived.add);
    Future<void> starting = newHub.start(hz: 200);
    await Future<void>.delayed(Duration.zero);

    expect(oldHub.isAttached, isFalse);
    expect(oldClosed, isTrue, reason: 'the old hub is closed and can never receive again');

    expect(await native.sendBatch(makeBatch(startTime + 50000, 10, offset: 99)), isTrue);

    nativeAttach.complete();
    await starting;

    SensorBatch freshBatch = makeBatch(startTime + 999000, 10, offset: 7);
    await native.sendBatch(freshBatch);

    expect(oldReceived, [firstBatch]);
    expect(newReceived, [freshBatch], reason: 'exactly once, and not the old batch');
    expect(native.calls.where((String c) => c == 'attach').length, 2);
  });

  test('SensorHub.instance is one shared hub', () {
    expect(identical(SensorHub.instance, SensorHub.instance), isTrue);
  });
}
