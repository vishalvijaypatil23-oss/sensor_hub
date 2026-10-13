package com.swt.sensor_hub

import kotlin.math.PI
import kotlin.math.max
import kotlin.math.sin

class SensorBatch(val startMicros: Long, val values: FloatArray)

class SensorFault(val code: String, val message: String, val timestampMicros: Long)

class OutgoingBatch(val epoch: Int, val batch: SensorBatch)

class SignalGenerator(val seed: Long) {
    var state = seed

    fun reset() {
        state = seed
    }

    fun next(index: Long, hz: Int): Float {
        val time = index.toDouble() / hz
        val noise = nextRandom() * 2.0 - 1.0
        return (sin(2.0 * PI * time) + 0.1 * noise).toFloat()
    }

    fun nextRandom(): Double {
        state += 0x9E3779B97F4A7C15uL.toLong()
        var z = state
        z = (z xor (z ushr 30)) * 0xBF58476D1CE4E5B9uL.toLong()
        z = (z xor (z ushr 27)) * 0x94D049BB133111EBuL.toLong()
        z = z xor (z ushr 31)
        return (z ushr 11).toDouble() / (1L shl 53).toDouble()
    }
}

class SampleBuffer(val capacity: Int) {
    val ring = FloatArray(capacity)
    var head = 0
    var size = 0
    var firstIndex = 0L
    var dropped = 0L
    var highWater = 0

    fun clear(nextIndex: Long) {
        head = 0
        size = 0
        firstIndex = nextIndex
    }

    fun add(index: Long, value: Float) {
        if (size == 0) {
            firstIndex = index
        }
        if (size == capacity) {
            head = (head + 1) % capacity
            firstIndex++
            size--
            dropped++
        }
        ring[(head + size) % capacity] = value
        size++
        highWater = max(highWater, size)
    }

    fun takeAll(): FloatArray {
        val values = FloatArray(size)
        for (i in 0 until size) {
            values[i] = ring[(head + i) % capacity]
        }
        firstIndex += size
        head = 0
        size = 0
        return values
    }
}

class EmitterCore(seed: Long = DEFAULT_SEED) {
    var epoch = 0
    var hz = 0
    var running = false
    var foreground = true
    val isEmitting: Boolean
        get() = running && foreground

    val generator = SignalGenerator(seed)
    var buffer = SampleBuffer(1)
    var baseWallMicros = 0L
    var nextIndex = 0L
    var anchorNanos = 0L
    var anchorIndex = 0L
    var waitingForAck = false
    var lastSendNanos = Long.MIN_VALUE / 2
    var reportedDrops = 0L
    var lastFaultNanos = Long.MIN_VALUE / 2

    fun start(hz: Int, nowNanos: Long, wallMicros: Long) {
        require(hz in 1..MAX_HZ) { "hz must be in 1..$MAX_HZ, was $hz" }
        stop()
        this.hz = hz
        generator.reset()
        buffer = SampleBuffer(bufferSizeFor(hz))
        nextIndex = 0
        baseWallMicros = wallMicros
        reportedDrops = 0
        running = true
        anchorNanos = nowNanos
        anchorIndex = nextIndex
    }

    fun stop() {
        running = false
        epoch++
        waitingForAck = false
        lastSendNanos = Long.MIN_VALUE / 2
        buffer.clear(nextIndex)
    }

    fun setForeground(value: Boolean, nowNanos: Long) {
        if (value == foreground) return
        if (!value) {
            makeSamples(nowNanos)
            foreground = false
        } else {
            foreground = true
            anchorNanos = nowNanos
            anchorIndex = nextIndex
        }
    }

    fun tick(nowNanos: Long): OutgoingBatch? {
        makeSamples(nowNanos)
        if (!isEmitting || waitingForAck) return null
        if (nowNanos - lastSendNanos < MIN_SEND_INTERVAL_NANOS) return null
        if (buffer.size == 0) return null

        val firstIndex = buffer.firstIndex
        val values = buffer.takeAll()
        waitingForAck = true
        lastSendNanos = nowNanos
        return OutgoingBatch(epoch, SensorBatch(startMicrosOf(firstIndex), values))
    }

    fun onAck(ackEpoch: Int) {
        if (ackEpoch == epoch) waitingForAck = false
    }

    fun checkOverflow(nowNanos: Long, wallMicros: Long): SensorFault? {
        val newDrops = buffer.dropped - reportedDrops
        if (newDrops <= 0) return null
        if (nowNanos - lastFaultNanos < 1_000_000_000L) return null
        reportedDrops = buffer.dropped
        lastFaultNanos = nowNanos
        return SensorFault(
            "backpressure_overflow",
            "Dart did not read batches for more than ${MAX_WAIT_SECONDS}s; dropped $newDrops oldest samples",
            wallMicros,
        )
    }

    fun startMicrosOf(index: Long): Long = baseWallMicros + index * 1_000_000L / hz

    fun stats(): Map<String, Any> {
        return mapOf(
            "pending" to buffer.size,
            "capacity" to buffer.capacity,
            "highWater" to buffer.highWater,
            "dropped" to buffer.dropped,
        )
    }

    fun makeSamples(nowNanos: Long) {
        if (!isEmitting) return
        val elapsed = nowNanos - anchorNanos
        if (elapsed < 0) return
        val dueCount = anchorIndex + elapsed * hz / 1_000_000_000L + 1
        while (nextIndex < dueCount) {
            buffer.add(nextIndex, generator.next(nextIndex, hz))
            nextIndex++
        }
    }

    companion object {
        const val DEFAULT_SEED = 0x5EED5EEDL
        const val MAX_HZ = 1000
        const val MIN_SEND_INTERVAL_NANOS = 50_000_000L
        const val MAX_WAIT_SECONDS = 2

        fun bufferSizeFor(hz: Int): Int = max(hz * MAX_WAIT_SECONDS, 64)
    }
}
