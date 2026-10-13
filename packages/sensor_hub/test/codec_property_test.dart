import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensor_hub/sensor_hub.dart';

const SensorHubCodec codec = SensorHubCodec();
final Random random = Random(20261012);

int randomInt64() {
  if (random.nextInt(10) == 0) {
    List<int> edges = [0, 0x7FFFFFFF, 0x80000000, 0x7FFFFFFFFFFFFFFF, -0x7FFFFFFFFFFFFFFF - 1, -1];
    return edges[random.nextInt(edges.length)];
  }
  int high = random.nextInt(1 << 32);
  int low = random.nextInt(1 << 32);
  return (high << 32) | low;
}

double randomDouble() {
  int pick = random.nextInt(50);
  if (pick == 0) {
    List<double> special = [double.nan, double.infinity, double.negativeInfinity, -0.0, 0.0];
    return special[random.nextInt(special.length)];
  }
  if (pick == 1) {
    return (random.nextDouble() - 0.5) * 1e-40;
  }
  double magnitude = pow(10, random.nextInt(13) - 6).toDouble();
  return (random.nextDouble() * 2 - 1) * magnitude;
}

void main() {
  test('1000 random batches encode and decode to the same values', () {
    int totalSamples = 0;

    for (int i = 0; i < 1000; i++) {
      int count = random.nextInt(10) == 0 ? random.nextInt(2001) : random.nextInt(64);
      List<double> source = [];
      for (int j = 0; j < count; j++) {
        source.add(randomDouble());
      }
      SensorBatch batch = SensorBatch(startMicros: randomInt64(), values: Float32List.fromList(source));

      SensorBatch decoded = codec.decodeMessage(codec.encodeMessage(batch)) as SensorBatch;

      expect(decoded.startMicros, batch.startMicros, reason: 'batch $i');
      expect(decoded.count, count, reason: 'batch $i');

      Uint32List expectedBits = batch.values.buffer.asUint32List();
      Uint32List actualBits = decoded.values.buffer.asUint32List(decoded.values.offsetInBytes, count);
      for (int j = 0; j < count; j++) {
        if (expectedBits[j] != actualBits[j]) {
          fail('batch $i sample $j: bits ${expectedBits[j].toRadixString(16)} != ${actualBits[j].toRadixString(16)}');
        }
      }

      for (int j = 0; j < count; j++) {
        double original = source[j];
        double result = decoded.values[j];
        if (original.isNaN) {
          expect(result.isNaN, isTrue);
          continue;
        }
        if (original.isInfinite) {
          continue;
        }
        double allowed = max(original.abs() * pow(2, -24).toDouble(), pow(2, -150).toDouble());
        if ((original - result).abs() > allowed) {
          fail('batch $i sample $j: $original vs $result is more than $allowed');
        }
      }
      totalSamples += count;
    }

    expect(totalSamples, greaterThan(10000));
  });
}
