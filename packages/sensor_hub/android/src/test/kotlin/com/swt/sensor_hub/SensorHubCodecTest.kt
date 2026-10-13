package com.swt.sensor_hub

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SensorHubCodecTest {
    fun toByteArray(buffer: ByteBuffer): ByteArray {
        buffer.rewind()
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        return bytes
    }

    fun decode(bytes: ByteArray): Any? {
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        buffer.rewind()
        return SensorHubCodec.decodeMessage(buffer)
    }

    @Test
    fun `batch is 16 + 4n bytes and startMicros above 2^31 survives`() {
        val start = (1L shl 31) + 12_345L
        val values = floatArrayOf(0.5f, -1.25f, Float.NaN)
        val encoded = toByteArray(SensorHubCodec.encodeMessage(SensorBatch(start, values))!!)

        assertEquals(16 + 4 * 3, encoded.size)
        assertEquals(128, encoded[0].toInt() and 0xFF)
        val reader = ByteBuffer.wrap(encoded).order(ByteOrder.nativeOrder())
        assertEquals(start, reader.getLong(1))
        assertEquals(3, reader.getInt(9))
        assertEquals(0.5f, reader.getFloat(16))

        val decoded = decode(encoded) as SensorBatch
        assertEquals(start, decoded.startMicros)
        assertEquals(values.size, decoded.values.size)
        for (i in values.indices) {
            assertEquals(values[i].toRawBits(), decoded.values[i].toRawBits())
        }
    }

    @Test
    fun `the trap itself - the standard codec returns Integer or Long depending on the value`() {
        val smallIntFromDart = ByteBuffer.allocate(5).order(ByteOrder.nativeOrder())
        smallIntFromDart.put(3.toByte())
        smallIntFromDart.putInt(5)
        assertTrue(decode(smallIntFromDart.array()) is Int)

        val bigValue = toByteArray(SensorHubCodec.encodeMessage(5_000_000_000L)!!)
        assertTrue(decode(bigValue) is Long)
    }

    @Test
    fun `fault round trip`() {
        val fault = SensorFault("backpressure_overflow", "dropped 3", 1_760_000_000_000_000L)
        val decoded = decode(toByteArray(SensorHubCodec.encodeMessage(fault)!!)) as SensorFault
        assertEquals(fault.code, decoded.code)
        assertEquals(fault.message, decoded.message)
        assertEquals(fault.timestampMicros, decoded.timestampMicros)
    }
}
