# sensor_hub

A 200 Hz synthetic sensor (seeded 1 Hz sine + noise) streamed to Flutter as **binary batches**, with **native-side backpressure** and **native lifecycle handling**. This is one plugin package (not federated), written in Dart, Kotlin and Swift. It depends only on the Flutter SDK, and the Dart side imports `foundation` + `services`, never `widgets`.

## Use it in any app

```yaml
dependencies:
  sensor_hub:
    path: packages/sensor_hub   # or a git: url to this repo, path: packages/sensor_hub
```

```dart
import 'package:sensor_hub/sensor_hub.dart';

final hub = SensorHub.instance;
hub.batches.listen((b) => print('${b.count} samples from ${b.startMicros}'));
hub.faults.listen((f) => print('fault ${f.kind}: ${f.message}'));
final info = await hub.describe();   // model + maxHz
await hub.start(hz: 200);
// ... later
await hub.stop();
```

Backgrounding pauses emission and resume continues `startMicros` from where it stopped; the app needs no lifecycle code.

## Design

```
 native engine thread/queue               main thread                Dart (UI isolate)
 ┌───────────────────────────┐   cut    ┌──────────────┐  bytes   ┌───────────────────────┐
 │ 10 ms tick → generate due │ ───────▶ │ epoch check  │ ───────▶ │ guarded decode        │
 │ samples into a FIXED ring │  ≤1 in   │ BasicMessage │          │ gate: attached&running│
 │ (cap = 2 s of samples)    │  flight  │ Channel.send │ ◀─────── │ batches.add (sync)    │
 │ ack ⇒ may cut next batch  │ ◀─────── │ reply cb     │  reply   │ reply `true` = ready  │
 └───────────────────────────┘          └──────────────┘          └───────────────────────┘
   control: MethodChannel sensor_hub/control (attach, start, stop, describe, debugStats)
   faults:  BasicMessageChannel sensor_hub/faults (tag 129)  →  Stream<SensorFault>
```

`EmitterCore` (Kotlin and Swift, kept identical) is a single-threaded state machine. It has no Android or UIKit dependency, so it is unit-tested on the JVM with a fake clock. `SensorEngine` wraps it in threads: a HandlerThread on Android, a serial DispatchQueue plus timer on iOS.

## Codec layout (tag 128, little-endian, offsets from message start)

| off | size | field |
|---|---|---|
| 0 | 1 | tag `128` |
| 1 | 8 | `startMicros` **int64**, always 8 bytes regardless of value |
| 9 | 4 | `count` int32 |
| 13 | 3 | padding to 4-byte alignment (`WriteBuffer.putFloat32List` / `writeAlignment`) |
| 16 | 4·n | `values` float32[n] |

`SensorFault` is tag `129`: code (std string), message (std string), int64 timestampMicros. Dart (`WriteBuffer`/`ReadBuffer`), Kotlin and Swift write byte-identical output.

### Measured bytes per sample

| encoding | bytes | per sample | messages/s at 200 Hz |
|---|---|---|---|
| naive: one `Map{'timestampMicros','value'}` per EventChannel event | 48 | **48** | 200 |
| ours, 10 samples/batch (200 Hz ÷ 20 batches/s) | 56 | **5.6** | ≤ 20 |
| ours, 400 samples (2 s coalesced after a stall) | 1616 | 4.04 (→ 4) | — |

**How it was measured:** `test/codec_test.dart › bytes per sample` encodes both with the real codecs and reads `ByteData.lengthInBytes`. The naive case uses `StandardMethodCodec.encodeSuccessEnvelope`, which is what an EventChannel sends. The test asserts these exact numbers and prints the table. Per-message engine overhead (channel name, task hop) is not counted, so the real saving is larger: 10× fewer messages.

## Backpressure, and why the queue is bounded

- **At most one batch in flight.** Dart's reply to each batch message is the readiness signal. Native cuts the next batch only after that reply arrives (`onAck`, matched by epoch) **and** at least 50 ms after the previous send, so there are never more than 20 events/s.
- While Dart is busy, new samples go into `SampleBuffer`. This is a ring of `capacity = max(2 s × hz, 64)` floats (400 at 200 Hz), allocated once and never grown. If the ring is full, the oldest sample is overwritten, `firstIndex` advances so the next batch's `startMicros` stays correct, and one `backpressure_overflow` fault per second reports how many samples were dropped.
- **Memory bound:** native holds `capacity × 4` bytes of pending samples plus one batch in the channel. Nothing else exists to grow.
- **Proof:**
  - `EmitterCoreTest` runs a Dart that never replies for 60 s: exactly 1 batch is sent, `pending ≤ 400` on every tick, `highWater == 400`, and more than 11,000 samples are dropped and reported.
  - A 300 ms-slow consumer gets about 62-sample batches that stay contiguous.
  - In the app, **Block UI 1 s** freezes the isolate. The next batch is about 200 samples, the high-water mark stays ≤ capacity, and there are 0 timestamp gaps.

## Lifecycle without `WidgetsBindingObserver`

Native detects backgrounding itself:
- **Android:** `Application.ActivityLifecycleCallbacks.onActivityPaused`. `ProcessLifecycleOwner` is avoided because it delays events by 700 ms.
- **iOS:** `UIApplication.willResignActive` and `UIScene.willDeactivate`.

When backgrounded, the engine first generates the samples already due, then freezes the sample clock and cancels its timer. On foreground it re-anchors the clock at `nextIndex`. Because `startMicros = base + index·10⁶/hz`, the first batch after resume starts exactly where the last one ended, with no gap and no burst. The time from the lifecycle event to the pause being applied is logged as `SensorHub: lifecycle … applied after N ms` (logcat / Console). Measured on a real device (Micromax IN1, Android): **0–1 ms** from `onActivityPaused` to emission stopped, against a 500 ms budget; resume continued `startMicros` with 0 gaps. `EmitterCoreTest` checks that 12 s of wall time containing a 10 s background produce ≈ 2 s of contiguous sample time.

## Hot restart: why a naive `setMethodCallHandler` in a constructor breaks

`R` throws away the Dart isolate, **but not the FlutterEngine, the plugin instance, or its running timer.** With the naive version (`SensorHub() { channel.setMethodCallHandler(...) }`, then `start()`):

1. The old native emitter keeps sending into the new isolate before anything has asked for data. The engine's channel buffer even replays a batch sent before the new handler existed.
2. The new code calls `start()` again and a naive native side starts a **second** timer. Two emitters now feed one channel, so every sample arrives twice with interleaved `startMicros`.
3. Every construction silently replaces the previous handler (last wins), so creating a second hub kills the first hub's stream without any error.

**Fix:**
- `SensorHub.instance` is a singleton. Its statics reset naturally with the new isolate.
- The constructor touches no channel. On first use, `attach()` registers the one handler (`setMessageHandler` replaces by name) and calls native `attach`, which stops any leftover session and **bumps the epoch**.
- Until `attach` returns, every incoming batch is acknowledged and dropped. Stale acks are ignored natively by epoch, and the main thread forwards only batches of the current epoch.
- `start` is idempotent: it always restarts a single emitter.

`sensor_hub_test › hot restart` replays this: a second hub, a stale batch during `attach`, exactly one delivery afterwards, and the old hub closed.

## Errors are typed

- Native faults travel on their own channel as tag 129 and arrive on `faults`.
- A `PlatformException` or `MissingPluginException` from a control call is converted into a `SensorFault`, which is emitted on `faults` and thrown from the call.
- Undecodable batch bytes are caught by `SafeSensorHubCodec` and become a `decode_error` fault.
- `batches` is only ever `add`ed to, so it never carries an error.

## Tests

- **Dart** (`flutter test` in this folder): everything is at the binary level. `setMockMessageHandler` decodes control bytes, and `handlePlatformMessage` injects real encoded batches, including bytes laid out by hand as Kotlin and Swift write them.
  - 1,000-batch round-trip property test. **Float32 tolerance:** 0 (bit-exact) against the encoded `Float32List`, because the codec copies IEEE-754 bits. Against the original float64 the bound is ≤ ½ ulp = 2⁻²⁴·|x| (2⁻¹⁵⁰ for subnormals), which is the one round-to-nearest conversion when filling the list.
  - `stop()` with a batch in flight.
  - int64 `startMicros` above 2³¹ / 2³² / 2⁵³.
  - Typed faults, and hot restart.
  - `constraints_test` checks for no `widgets`, `compute()`, `dart:mirrors`, or pub.dev dependencies.
- **Kotlin** (`cd ../../android && ./gradlew :sensor_hub:testDebugUnitTest`): `EmitterCoreTest` covers the bound, rate cap, pause/resume continuity, stop/epoch and reproducibility. `SensorHubCodecTest` covers the layout and the int trap on the JVM.

**The int width trap:** `StandardMessageCodec` encodes an `int` as INT32 when it fits and INT64 otherwise. On Android it decodes to `Integer` or `Long` **by value**, so `as Long` works for 3,000,000,000 and crashes for 5. `startMicros` therefore never goes through that path (it is a raw int64 in our tag), and `hz` is read as `Number`.
