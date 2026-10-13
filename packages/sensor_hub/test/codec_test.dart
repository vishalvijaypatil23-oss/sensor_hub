import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensor_hub/sensor_hub.dart';

const SensorHubCodec codec = SensorHubCodec();
const int startTime = 1760000000000000;

Uint8List toBytes(ByteData data) {
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

int encodedSize(int sampleCount) {
  SensorBatch batch = SensorBatch(startMicros: startTime, values: Float32List(sampleCount));
  return codec.encodeMessage(batch)!.lengthInBytes;
}

void main() {
  test('layout: type | int64 startMicros | int32 count | padding | float32 values', () {
    expect(Endian.host, Endian.little, reason: 'all phones we ship on are little-endian');
    SensorBatch batch = SensorBatch(startMicros: 0x0102030405060708, values: Float32List.fromList([1.0, -2.0]));
    Uint8List bytes = toBytes(codec.encodeMessage(batch)!);

    expect(bytes.length, 16 + 4 * 2);
    expect(bytes[0], 128);
    expect(bytes.sublist(1, 9), [8, 7, 6, 5, 4, 3, 2, 1]);
    expect(bytes.sublist(9, 13), [2, 0, 0, 0]);
    expect(bytes.sublist(13, 16), [0, 0, 0]);
    expect(bytes.sublist(16, 20), [0x00, 0x00, 0x80, 0x3F]);
    expect(bytes.sublist(20, 24), [0x00, 0x00, 0x00, 0xC0]);
  });

  test('empty batch is 16 bytes and round-trips', () {
    SensorBatch batch = SensorBatch(startMicros: 5, values: Float32List(0));
    ByteData encoded = codec.encodeMessage(batch)!;
    expect(encoded.lengthInBytes, 16);
    expect(codec.decodeMessage(encoded), batch);
  });

  group('the int width trap', () {
    test('StandardMessageCodec changes the int size at 2^31, so the receiver cannot assume one type', () {
      const StandardMessageCodec standard = StandardMessageCodec();
      ByteData small = standard.encodeMessage(0x7FFFFFFF)!;
      ByteData large = standard.encodeMessage(0x80000000)!;
      expect(small.getUint8(0), 3);
      expect(small.lengthInBytes, 5);
      expect(large.getUint8(0), 4);
      expect(large.lengthInBytes, 9);
    });

    test('startMicros is always 8 bytes and survives values above 2^31', () {
      List<int> starts = [
        0,
        1,
        -1,
        0x7FFFFFFF,
        0x80000000,
        0x80000001,
        0xFFFFFFFF,
        0x100000000,
        startTime,
        (1 << 53) + 1,
        0x7FFFFFFFFFFFFFFF,
        -0x7FFFFFFFFFFFFFFF - 1,
      ];
      for (int start in starts) {
        SensorBatch batch = SensorBatch(startMicros: start, values: Float32List.fromList([1]));
        ByteData encoded = codec.encodeMessage(batch)!;
        expect(encoded.lengthInBytes, 20, reason: 'size must not depend on the value ($start)');
        expect(encoded.getInt64(1, Endian.little), start);
        SensorBatch decoded = codec.decodeMessage(encoded) as SensorBatch;
        expect(decoded.startMicros, start, reason: '$start');
      }
    });
  });

  test('SensorFault round-trips with its type', () {
    SensorFault fault = SensorFault(
      code: 'backpressure_overflow',
      message: 'dropped 3 oldest samples',
      timestampMicros: startTime + 1,
    );
    SensorFault decoded = codec.decodeMessage(codec.encodeMessage(fault)) as SensorFault;
    expect(decoded, fault);
    expect(decoded.kind, SensorFaultKind.overflow);
  });

  test('normal values still use the standard codec', () {
    Object? value = codec.decodeMessage(codec.encodeMessage({'a': 1, 'b': 'x'}));
    expect(value, {'a': 1, 'b': 'x'});
  });

  group('broken input is rejected', () {
    test('missing values', () {
      ByteData data = ByteData(13);
      data.setUint8(0, 128);
      data.setInt32(9, 4, Endian.little);
      expect(() => codec.decodeMessage(data), throwsA(anything));
    });

    test('negative count', () {
      ByteData data = ByteData(16);
      data.setUint8(0, 128);
      data.setInt32(9, -1, Endian.little);
      expect(() => codec.decodeMessage(data), throwsFormatException);
    });

    test('extra bytes at the end', () {
      ByteData good = codec.encodeMessage(SensorBatch(startMicros: 1, values: Float32List(1)))!;
      ByteData data = ByteData(good.lengthInBytes + 1);
      toBytes(data).setAll(0, toBytes(good));
      expect(() => codec.decodeMessage(data), throwsFormatException);
    });
  });

  test('bytes per sample: this codec vs one Map per sample on an EventChannel', () {
    Map<String, Object> oneSample = {'timestampMicros': startTime, 'value': 0.123};
    int naiveSize = const StandardMethodCodec().encodeSuccessEnvelope(oneSample).lengthInBytes;

    String table = 'naive Map/EventChannel: $naiveSize B per sample, 1 message per sample\n';
    table += 'samples/batch  bytes  B/sample\n';
    for (int n in [1, 10, 40, 400]) {
      int size = encodedSize(n);
      table += '${n.toString().padLeft(13)}  ${size.toString().padLeft(5)}  ${(size / n).toStringAsFixed(2)}\n';
    }
    // ignore: avoid_print
    print(table);

    expect(naiveSize, 48);
    expect(encodedSize(1), 20);
    expect(encodedSize(10), 56);
    expect(encodedSize(400), 1616);
  });
}
