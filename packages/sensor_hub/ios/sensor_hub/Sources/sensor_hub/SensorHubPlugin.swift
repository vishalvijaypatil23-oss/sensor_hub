import Flutter
import UIKit

public class SensorHubPlugin: NSObject, FlutterPlugin {
  let engine: SensorEngine

  init(engine: SensorEngine) {
    self.engine = engine
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let batchChannel = FlutterBasicMessageChannel(
      name: "sensor_hub/batches", binaryMessenger: messenger, codec: sensorHubCodec)
    let faultChannel = FlutterBasicMessageChannel(
      name: "sensor_hub/faults", binaryMessenger: messenger, codec: sensorHubCodec)
    let plugin = SensorHubPlugin(engine: SensorEngine(batchChannel: batchChannel, faultChannel: faultChannel))

    let controlChannel = FlutterMethodChannel(name: "sensor_hub/control", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(plugin, channel: controlChannel)

    let center = NotificationCenter.default
    center.addObserver(plugin, selector: #selector(appWentToBackground),
                       name: UIApplication.willResignActiveNotification, object: nil)
    center.addObserver(plugin, selector: #selector(appCameToForeground),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(plugin, selector: #selector(appWentToBackground),
                       name: UIScene.willDeactivateNotification, object: nil)
    center.addObserver(plugin, selector: #selector(appCameToForeground),
                       name: UIScene.didActivateNotification, object: nil)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    NotificationCenter.default.removeObserver(self)
    engine.dispose()
  }

  @objc func appWentToBackground() {
    engine.setForeground(false)
  }

  @objc func appCameToForeground() {
    engine.setForeground(true)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "attach", "stop":
      engine.stop { result(nil) }

    case "start":
      let arguments = call.arguments as? [String: Any]
      let hz = (arguments?["hz"] as? NSNumber)?.intValue ?? 0
      if hz < 1 || hz > EmitterCore.maxHz {
        result(FlutterError(code: "invalid_argument",
                            message: "hz must be in 1...\(EmitterCore.maxHz), was \(hz)", details: nil))
        return
      }
      engine.start(hz: hz) { ok in
        if ok {
          result(nil)
        } else {
          result(FlutterError(code: "invalid_argument", message: "hz rejected", details: nil))
        }
      }

    case "describe":
      result(["model": "\(SensorHubPlugin.modelName()) (synthetic)", "maxHz": EmitterCore.maxHz])

    case "debugStats":
      engine.stats { stats in result(stats) }

    case "debugInjectFault":
      engine.sendTestFault()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func modelName() -> String {
    if let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return "Simulator \(simulator)"
    }
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return machine
  }
}
