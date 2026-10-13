import Foundation

class SensorBatch: NSObject {
  let startMicros: Int64
  let values: [Float]

  init(startMicros: Int64, values: [Float]) {
    self.startMicros = startMicros
    self.values = values
  }
}

class SensorFault: NSObject {
  let code: String
  let message: String
  let timestampMicros: Int64

  init(code: String, message: String, timestampMicros: Int64) {
    self.code = code
    self.message = message
    self.timestampMicros = timestampMicros
  }
}

struct OutgoingBatch {
  let epoch: Int
  let batch: SensorBatch
}

class SignalGenerator {
  let seed: UInt64
  var state: UInt64

  init(seed: UInt64) {
    self.seed = seed
    self.state = seed
  }

  func reset() {
    state = seed
  }

  func next(index: Int64, hz: Int) -> Float {
    let time = Double(index) / Double(hz)
    let noise = nextRandom() * 2.0 - 1.0
    return Float(sin(2.0 * Double.pi * time) + 0.1 * noise)
  }

  func nextRandom() -> Double {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z = z ^ (z >> 31)
    return Double(z >> 11) / 9_007_199_254_740_992.0
  }
}

class SampleBuffer {
  let capacity: Int
  var ring: [Float]
  var head = 0
  var size = 0
  var firstIndex: Int64 = 0
  var dropped: Int64 = 0
  var highWater = 0

  init(capacity: Int) {
    self.capacity = capacity
    self.ring = [Float](repeating: 0, count: capacity)
  }

  func clear(nextIndex: Int64) {
    head = 0
    size = 0
    firstIndex = nextIndex
  }

  func add(index: Int64, value: Float) {
    if size == 0 {
      firstIndex = index
    }
    if size == capacity {
      head = (head + 1) % capacity
      firstIndex += 1
      size -= 1
      dropped += 1
    }
    ring[(head + size) % capacity] = value
    size += 1
    highWater = max(highWater, size)
  }

  func takeAll() -> [Float] {
    var values = [Float]()
    for i in 0..<size {
      values.append(ring[(head + i) % capacity])
    }
    firstIndex += Int64(size)
    head = 0
    size = 0
    return values
  }
}

class EmitterCore {
  static let defaultSeed: UInt64 = 0x5EED_5EED
  static let maxHz = 1000
  static let minSendIntervalNanos: UInt64 = 50_000_000
  static let maxWaitSeconds = 2

  static func bufferSize(for hz: Int) -> Int {
    return max(hz * maxWaitSeconds, 64)
  }

  var epoch = 0
  var hz = 0
  var running = false
  var foreground = true
  var isEmitting: Bool { return running && foreground }

  let generator: SignalGenerator
  var buffer = SampleBuffer(capacity: 1)
  var baseWallMicros: Int64 = 0
  var nextIndex: Int64 = 0
  var anchorNanos: UInt64 = 0
  var anchorIndex: Int64 = 0
  var waitingForAck = false
  var lastSendNanos: UInt64? = nil
  var reportedDrops: Int64 = 0
  var lastFaultNanos: UInt64? = nil

  init(seed: UInt64 = EmitterCore.defaultSeed) {
    generator = SignalGenerator(seed: seed)
  }

  func start(hz: Int, nowNanos: UInt64, wallMicros: Int64) -> Bool {
    if hz < 1 || hz > EmitterCore.maxHz {
      return false
    }
    stop()
    self.hz = hz
    generator.reset()
    buffer = SampleBuffer(capacity: EmitterCore.bufferSize(for: hz))
    nextIndex = 0
    baseWallMicros = wallMicros
    reportedDrops = 0
    running = true
    anchorNanos = nowNanos
    anchorIndex = nextIndex
    return true
  }

  func stop() {
    running = false
    epoch += 1
    waitingForAck = false
    lastSendNanos = nil
    buffer.clear(nextIndex: nextIndex)
  }

  func setForeground(_ value: Bool, nowNanos: UInt64) {
    if value == foreground {
      return
    }
    if !value {
      makeSamples(nowNanos: nowNanos)
      foreground = false
    } else {
      foreground = true
      anchorNanos = nowNanos
      anchorIndex = nextIndex
    }
  }

  func tick(nowNanos: UInt64) -> OutgoingBatch? {
    makeSamples(nowNanos: nowNanos)
    if !isEmitting || waitingForAck || buffer.size == 0 {
      return nil
    }
    if let last = lastSendNanos, nowNanos &- last < EmitterCore.minSendIntervalNanos {
      return nil
    }
    let firstIndex = buffer.firstIndex
    let values = buffer.takeAll()
    waitingForAck = true
    lastSendNanos = nowNanos
    let batch = SensorBatch(startMicros: startMicros(of: firstIndex), values: values)
    return OutgoingBatch(epoch: epoch, batch: batch)
  }

  func onAck(epoch ackEpoch: Int) {
    if ackEpoch == epoch {
      waitingForAck = false
    }
  }

  func checkOverflow(nowNanos: UInt64, wallMicros: Int64) -> SensorFault? {
    let newDrops = buffer.dropped - reportedDrops
    if newDrops <= 0 {
      return nil
    }
    if let last = lastFaultNanos, nowNanos &- last < 1_000_000_000 {
      return nil
    }
    reportedDrops = buffer.dropped
    lastFaultNanos = nowNanos
    return SensorFault(
      code: "backpressure_overflow",
      message: "Dart did not read batches for more than \(EmitterCore.maxWaitSeconds)s; dropped \(newDrops) oldest samples",
      timestampMicros: wallMicros)
  }

  func startMicros(of index: Int64) -> Int64 {
    return baseWallMicros + index * 1_000_000 / Int64(hz)
  }

  func stats() -> [String: Any] {
    return [
      "pending": buffer.size,
      "capacity": buffer.capacity,
      "highWater": buffer.highWater,
      "dropped": buffer.dropped,
    ]
  }

  func makeSamples(nowNanos: UInt64) {
    if !isEmitting || nowNanos < anchorNanos {
      return
    }
    let elapsed = Int64(nowNanos - anchorNanos)
    let dueCount = anchorIndex + elapsed * Int64(hz) / 1_000_000_000 + 1
    while nextIndex < dueCount {
      buffer.add(index: nextIndex, value: generator.next(index: nextIndex, hz: hz))
      nextIndex += 1
    }
  }
}
