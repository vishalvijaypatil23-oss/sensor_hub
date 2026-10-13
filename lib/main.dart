import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sensor_hub/sensor_hub.dart';

const int sensorHz = 200;
const int chartSamples = sensorHz * 3;

void main() {
  runApp(const SensorDemoApp());
}

class SensorDemoApp extends StatelessWidget {
  const SensorDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sensor_hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const SensorScreen(),
    );
  }
}

class SensorScreen extends StatefulWidget {
  const SensorScreen({super.key});

  @override
  State<SensorScreen> createState() => SensorScreenState();
}

class SensorScreenState extends State<SensorScreen> with SingleTickerProviderStateMixin {
  MethodChannelSensorHub hub = SensorHub.instance as MethodChannelSensorHub;

  late AnimationController frameTicker;
  StreamSubscription<SensorBatch>? batchSubscription;
  StreamSubscription<SensorFault>? faultSubscription;
  Timer? statsTimer;

  bool showPerformance = true;
  bool isRunning = false;
  SensorInfo? info;
  Map<Object?, Object?> nativeStats = {};

  Float32List chartValues = Float32List(chartSamples);
  int totalSamples = 0;
  Stopwatch timeSinceLastBatch = Stopwatch();

  int batchCount = 0;
  int largestBatch = 0;
  int timestampGaps = 0;
  int lastStartMicros = 0;
  int expectedNextStart = 0;
  int batchesThisSecond = 0;
  int batchesPerSecond = 0;
  List<SensorFault> faults = [];

  @override
  void initState() {
    super.initState();
    frameTicker = AnimationController(vsync: this, duration: const Duration(seconds: 1));
    frameTicker.repeat();
    batchSubscription = hub.batches.listen(onBatch);
    faultSubscription = hub.faults.listen(onFault);
    statsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      updateStats();
    });
    startSensor(firstTime: true);
  }

  @override
  void dispose() {
    batchSubscription?.cancel();
    faultSubscription?.cancel();
    statsTimer?.cancel();
    frameTicker.dispose();
    super.dispose();
  }

  void onBatch(SensorBatch batch) {
    if (expectedNextStart != 0 && (batch.startMicros - expectedNextStart).abs() > 1) {
      timestampGaps++;
    }
    expectedNextStart = batch.startMicros + (batch.count * 1000000 / sensorHz).round();

    for (int i = 0; i < batch.count; i++) {
      chartValues[(totalSamples + i) % chartSamples] = batch.values[i];
    }
    totalSamples += batch.count;
    batchCount++;
    batchesThisSecond++;
    largestBatch = max(largestBatch, batch.count);
    lastStartMicros = batch.startMicros;
    timeSinceLastBatch.reset();
    timeSinceLastBatch.start();
  }

  void onFault(SensorFault fault) {
    setState(() {
      faults.add(fault);
    });
  }

  Future<void> startSensor({bool firstTime = false}) async {
    expectedNextStart = 0;
    try {
      if (firstTime) {
        SensorInfo sensorInfo = await hub.describe();
        if (!mounted) return;
        setState(() {
          info = sensorInfo;
        });
      }
      await hub.start(hz: sensorHz);
      if (!mounted) return;
      setState(() {
        isRunning = true;
      });
    } on SensorFault {
    }
  }

  Future<void> stopSensor() async {
    try {
      await hub.stop();
    } on SensorFault {
    }
    if (!mounted) return;
    setState(() {
      isRunning = false;
    });
  }

  Future<void> injectFault() async {
    try {
      await hub.debugInjectFault();
    } on SensorFault {
    }
  }

  Future<void> updateStats() async {
    batchesPerSecond = batchesThisSecond;
    batchesThisSecond = 0;
    try {
      nativeStats = await hub.debugStats();
    } on SensorFault {
    }
    if (mounted) {
      setState(() {});
    }
  }

  void blockUi() {
    Stopwatch stopwatch = Stopwatch();
    stopwatch.start();
    while (stopwatch.elapsedMilliseconds < 1000) {
    }
  }

  @override
  Widget build(BuildContext context) {
    String sensorText = 'Sensor: ...';
    if (info != null) {
      sensorText = 'Sensor: ${info!.model} · max ${info!.maxHz} Hz';
    }

    String averageBatch = '-';
    if (batchCount > 0) {
      averageBatch = (totalSamples / batchCount).toStringAsFixed(1);
    }

    String pendingText = '-';
    String droppedText = '-';
    if (nativeStats.isNotEmpty) {
      pendingText =
          '${nativeStats['pending']} / ${nativeStats['capacity']}  (high-water ${nativeStats['highWater']})';
      droppedText = '${nativeStats['dropped']}';
    }

    String faultText = '0';
    if (faults.isNotEmpty) {
      faultText = '${faults.length} · last: ${faults.last.code}';
    }

    List<Widget> page = [];
    if (showPerformance) {
      page.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: PerformanceOverlay.allEnabled(),
      ));
    }
    page.add(Expanded(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Text(sensorText),
          const SizedBox(height: 8),
          RepaintBoundary(
            child: SizedBox(
              height: 180,
              child: CustomPaint(
                painter: WavePainter(this, Theme.of(context).colorScheme),
              ),
            ),
          ),
          const SizedBox(height: 12),
          statRow('Rate', isRunning ? '$sensorHz Hz' : '$sensorHz Hz (stopped)'),
          statRow('Batches / s', '$batchesPerSecond   (limit 20)'),
          statRow('Samples / batch (avg)', averageBatch),
          statRow('Largest batch', '$largestBatch'),
          statRow('Last startMicros', '$lastStartMicros'),
          statRow('Timestamp gaps', '$timestampGaps'),
          statRow('Native pending / capacity', pendingText),
          statRow('Native dropped', droppedText),
          statRow('Faults', faultText),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: isRunning ? null : startSensor, child: const Text('Start')),
              OutlinedButton(onPressed: isRunning ? stopSensor : null, child: const Text('Stop')),
              OutlinedButton(onPressed: blockUi, child: const Text('Block UI 1 s')),
              OutlinedButton(onPressed: injectFault, child: const Text('Inject fault')),
            ],
          ),
        ],
      ),
    ));

    return Scaffold(
      appBar: AppBar(
        title: const Text('sensor_hub · 200 Hz'),
        actions: [
          const Text('perf'),
          Switch(
            value: showPerformance,
            onChanged: (value) {
              setState(() {
                showPerformance = value;
              });
            },
          ),
        ],
      ),
      body: SafeArea(child: Column(children: page)),
    );
  }

  Widget statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class WavePainter extends CustomPainter {
  WavePainter(this.screen, this.colors) : super(repaint: screen.frameTicker);

  final SensorScreenState screen;
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    double middle = size.height / 2;
    Paint axisPaint = Paint();
    axisPaint.color = colors.outlineVariant;
    axisPaint.strokeWidth = 1;
    canvas.drawLine(Offset(0, middle), Offset(size.width, middle), axisPaint);

    int sampleCount = min(screen.totalSamples, chartSamples);
    if (sampleCount < 2) {
      return;
    }

    double shift = screen.timeSinceLastBatch.elapsedMicroseconds / 1000000 * sensorHz;
    shift = min(shift, sensorHz * 0.1);
    double stepX = size.width / chartSamples;
    double height = size.height * 0.42 / 1.1;

    Path path = Path();
    for (int i = 0; i < sampleCount; i++) {
      int sampleNumber = screen.totalSamples - sampleCount + i;
      double samplesAgo = (sampleCount - 1 - i) + shift;
      double x = size.width - samplesAgo * stepX;
      double y = middle - screen.chartValues[sampleNumber % chartSamples] * height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    Paint linePaint = Paint();
    linePaint.color = colors.primary;
    linePaint.style = PaintingStyle.stroke;
    linePaint.strokeWidth = 1.6;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawPath(path, linePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(WavePainter oldDelegate) {
    return false;
  }
}
