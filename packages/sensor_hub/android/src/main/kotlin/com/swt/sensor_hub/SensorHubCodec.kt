package com.swt.sensor_hub

import io.flutter.plugin.common.StandardMessageCodec
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

object SensorHubCodec : StandardMessageCodec() {
    const val BATCH_TYPE = 128
    const val FAULT_TYPE = 129

    override fun writeValue(stream: ByteArrayOutputStream, value: Any?) {
        if (value is SensorBatch) {
            stream.write(BATCH_TYPE)
            val count = value.values.size
            val header = ByteBuffer.allocate(12).order(ByteOrder.nativeOrder())
            header.putLong(value.startMicros)
            header.putInt(count)
            stream.write(header.array(), 0, 12)
            addPadding(stream)
            if (count > 0) {
                val body = ByteBuffer.allocate(count * 4).order(ByteOrder.nativeOrder())
                body.asFloatBuffer().put(value.values)
                stream.write(body.array(), 0, count * 4)
            }
        } else if (value is SensorFault) {
            stream.write(FAULT_TYPE)
            writeValue(stream, value.code)
            writeValue(stream, value.message)
            val time = ByteBuffer.allocate(8).order(ByteOrder.nativeOrder())
            time.putLong(value.timestampMicros)
            stream.write(time.array(), 0, 8)
        } else {
            super.writeValue(stream, value)
        }
    }

    override fun readValueOfType(type: Byte, buffer: ByteBuffer): Any? {
        val typeNumber = type.toInt() and 0xFF
        if (typeNumber == BATCH_TYPE) {
            val startMicros = buffer.getLong()
            val count = buffer.getInt()
            require(count >= 0) { "negative count $count" }
            skipPadding(buffer)
            val values = FloatArray(count)
            if (count > 0) {
                buffer.asFloatBuffer().get(values)
                buffer.position(buffer.position() + count * 4)
            }
            return SensorBatch(startMicros, values)
        }
        if (typeNumber == FAULT_TYPE) {
            val code = readValue(buffer) as String
            val message = readValue(buffer) as String
            return SensorFault(code, message, buffer.getLong())
        }
        return super.readValueOfType(type, buffer)
    }

    fun addPadding(stream: ByteArrayOutputStream) {
        while (stream.size() % 4 != 0) {
            stream.write(0)
        }
    }

    fun skipPadding(buffer: ByteBuffer) {
        while (buffer.position() % 4 != 0) {
            buffer.position(buffer.position() + 1)
        }
    }
}
