import Flutter
import Foundation
import os

class SensorEngine {
  let queue = DispatchQueue(label: "sensor_hub", qos: .userInitiated)
  let core = EmitterCore()
  let logger = Logger(subsystem: "sensor_hub", category: "engine")
  var timer: DispatchSourceTimer?

  let batchChannel: FlutterBasicMessageChannel
  let faultChannel: FlutterBasicMessageChannel

  var deliverableEpoch = -1

  init(batchChannel: FlutterBasicMessageChannel, faultChannel: FlutterBasicMessageChannel) {
    self.batchChannel = batchChannel
    self.faultChannel = faultChannel
  }

  func stop(done: @escaping () -> Void) {
    deliverableEpoch = -1
    queue.async {
      self.core.stop()
      self.stopTimer()
      DispatchQueue.main.async(execute: done)
    }
  }

  func start(hz: Int, done: @escaping (Bool) -> Void) {
    deliverableEpoch = -1
    queue.async {
      let ok = self.core.start(hz: hz, nowNanos: SensorEngine.now(), wallMicros: SensorEngine.wallMicros())
      if !ok {
        DispatchQueue.main.async { done(false) }
        return
      }
      let epoch = self.core.epoch
      self.startTimer()
      DispatchQueue.main.async {
        self.deliverableEpoch = epoch
        done(true)
      }
    }
  }

  func setForeground(_ foreground: Bool) {
    let requestedAt = SensorEngine.now()
    queue.async {
      self.core.setForeground(foreground, nowNanos: SensorEngine.now())
      if self.core.isEmitting {
        self.startTimer()
      } else {
        self.stopTimer()
      }
      let delayMs = Double(SensorEngine.now() - requestedAt) / 1_000_000
      let emitting = self.core.isEmitting
      self.logger.info("lifecycle: foreground=\(foreground) applied after \(delayMs) ms (emitting=\(emitting))")
    }
  }

  func stats(done: @escaping ([String: Any]) -> Void) {
    queue.async {
      let stats = self.core.stats()
      DispatchQueue.main.async { done(stats) }
    }
  }

  func sendTestFault() {
    let fault = SensorFault(code: "injected", message: "Test fault from native", timestampMicros: SensorEngine.wallMicros())
    faultChannel.sendMessage(fault)
  }

  func dispose() {
    deliverableEpoch = -1
    queue.async {
      self.core.stop()
      self.stopTimer()
    }
  }

  func sendBatch(_ outgoing: OutgoingBatch) {
    if outgoing.epoch != deliverableEpoch {
      return
    }
    batchChannel.sendMessage(outgoing.batch) { _ in
      self.queue.async { self.core.onAck(epoch: outgoing.epoch) }
    }
  }

  func startTimer() {
    stopTimer()
    let newTimer = DispatchSource.makeTimerSource(queue: queue)
    newTimer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
    newTimer.setEventHandler { self.tick() }
    newTimer.resume()
    timer = newTimer
  }

  func stopTimer() {
    timer?.cancel()
    timer = nil
  }

  func tick() {
    if !core.isEmitting {
      stopTimer()
      return
    }
    let now = SensorEngine.now()
    let epoch = core.epoch
    if let outgoing = core.tick(nowNanos: now) {
      DispatchQueue.main.async { self.sendBatch(outgoing) }
    }
    if let fault = core.checkOverflow(nowNanos: now, wallMicros: SensorEngine.wallMicros()) {
      DispatchQueue.main.async {
        if epoch == self.deliverableEpoch {
          self.faultChannel.sendMessage(fault)
        }
      }
    }
  }

  static func now() -> UInt64 {
    return DispatchTime.now().uptimeNanoseconds
  }

  static func wallMicros() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1_000_000)
  }
}
