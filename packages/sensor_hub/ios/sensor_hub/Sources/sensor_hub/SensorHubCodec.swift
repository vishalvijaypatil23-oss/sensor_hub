import Flutter
import Foundation

let batchType: UInt8 = 128
let faultType: UInt8 = 129

class SensorHubWriter: FlutterStandardWriter {
  override func writeValue(_ value: Any) {
    if let batch = value as? SensorBatch {
      writeByte(batchType)
      var startMicros = batch.startMicros
      writeBytes(&startMicros, length: 8)
      var count = Int32(batch.values.count)
      writeBytes(&count, length: 4)
      writeAlignment(4)
      if count > 0 {
        var values = batch.values
        writeBytes(&values, length: UInt(values.count * 4))
      }
    } else if let fault = value as? SensorFault {
      writeByte(faultType)
      writeValue(fault.code)
      writeValue(fault.message)
      var timestamp = fault.timestampMicros
      writeBytes(&timestamp, length: 8)
    } else {
      super.writeValue(value)
    }
  }
}

class SensorHubReader: FlutterStandardReader {
  override func readValue(ofType type: UInt8) -> Any? {
    if type == batchType {
      var startMicros: Int64 = 0
      readBytes(&startMicros, length: 8)
      var count: Int32 = 0
      readBytes(&count, length: 4)
      readAlignment(4)
      var values = [Float](repeating: 0, count: Int(max(count, 0)))
      if count > 0 {
        readBytes(&values, length: UInt(values.count * 4))
      }
      return SensorBatch(startMicros: startMicros, values: values)
    }
    if type == faultType {
      let code = readValue() as? String ?? "unknown"
      let message = readValue() as? String ?? ""
      var timestamp: Int64 = 0
      readBytes(&timestamp, length: 8)
      return SensorFault(code: code, message: message, timestampMicros: timestamp)
    }
    return super.readValue(ofType: type)
  }
}

class SensorHubReaderWriter: FlutterStandardReaderWriter {
  override func reader(with data: Data) -> FlutterStandardReader {
    return SensorHubReader(data: data)
  }

  override func writer(with data: NSMutableData) -> FlutterStandardWriter {
    return SensorHubWriter(data: data)
  }
}

let sensorHubCodec = FlutterStandardMessageCodec(readerWriter: SensorHubReaderWriter())
