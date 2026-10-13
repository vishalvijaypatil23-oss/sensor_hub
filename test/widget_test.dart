import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensor_app/main.dart';

void main() {
  testWidgets('demo screen builds without a native side (faults, not crashes)', (
    WidgetTester tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'sensor_hub/control',
      (ByteData? _) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMessageHandler('sensor_hub/control', null),
    );
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SensorDemoApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Block UI 1 s'), findsOneWidget);
    expect(find.textContaining('missing_plugin'), findsOneWidget);
  });
}
