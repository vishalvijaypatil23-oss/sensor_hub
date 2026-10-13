package com.swt.sensor_hub

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class Simulation(val core: EmitterCore) {
    var now = 0L
    val sent = mutableListOf<OutgoingBatch>()
    val faults = mutableListOf<SensorFault>()
    var maxPending = 0

    fun advance(milliseconds: Long, dartReplies: Boolean = true) {
        val end = now + milliseconds * 1_000_000L
        while (now < end) {
            now += 10_000_000L
            val outgoing = core.tick(now)
            if (outgoing != null) {
                sent.add(outgoing)
                if (dartReplies) core.onAck(outgoing.epoch)
            }
            val fault = core.checkOverflow(now, 0)
            if (fault != null) faults.add(fault)
            maxPending = maxOf(maxPending, core.buffer.size)
        }
    }
}

class EmitterCoreTest {
    val wall = 1_760_000_000_000_000L

    @Test
    fun `at 200 Hz with a fast consumer - max 20 batches per second, no samples lost`() {
        val sim = Simulation(EmitterCore())
        sim.core.start(200, 0, wall)
        sim.advance(10_000)

        assertTrue(sim.sent.size <= 10 * 20 + 1, "sent ${sim.sent.size} batches in 10 s")
        assertTrue(sim.sent.size >= 10 * 20 - 2, "sent ${sim.sent.size} batches in 10 s")
        var total = 0
        for (outgoing in sim.sent) total += outgoing.batch.values.size
        assertTrue(total in 1990..2001, "delivered $total samples")
        assertNoGaps(sim.sent, 200)
        assertTrue(sim.faults.isEmpty())
    }

    @Test
    fun `buffer stays bounded when Dart never replies`() {
        val sim = Simulation(EmitterCore())
        sim.core.start(200, 0, wall)
        sim.advance(60_000, dartReplies = false)

        val capacity = EmitterCore.bufferSizeFor(200)
        assertEquals(400, capacity)
        assertEquals(1, sim.sent.size, "only one batch may be waiting for a reply")
        assertTrue(sim.maxPending <= capacity, "pending ${sim.maxPending} > capacity $capacity")
        assertEquals(capacity, sim.core.stats()["highWater"])
        assertTrue((sim.core.stats()["dropped"] as Long) > 11_000)
        assertTrue(sim.faults.isNotEmpty() && sim.faults.size <= 60, "faults: ${sim.faults.size}")
        for (fault in sim.faults) assertEquals("backpressure_overflow", fault.code)
    }

    @Test
    fun `slow consumer gets bigger batches, never more than the buffer size`() {
        val sim = Simulation(EmitterCore())
        sim.core.start(200, 0, wall)

        var waitingSince = -1L
        for (step in 0 until 1000) {
            val sentBefore = sim.sent.size
            sim.advance(10, dartReplies = false)
            if (sim.sent.size > sentBefore) waitingSince = sim.now
            if (waitingSince >= 0 && sim.now - waitingSince >= 300_000_000L) {
                sim.core.onAck(sim.core.epoch)
                waitingSince = -1L
            }
        }

        for (i in 1 until sim.sent.size) {
            val size = sim.sent[i].batch.values.size
            assertTrue(size in 55..65, "batch $i has $size samples")
        }
        assertTrue(sim.maxPending <= 400)
        assertNoGaps(sim.sent, 200)
    }

    @Test
    fun `background pauses sending and resume continues startMicros without a gap`() {
        val sim = Simulation(EmitterCore())
        sim.core.start(200, 0, wall)
        sim.advance(1_000)
        val sentBeforePause = sim.sent.size

        sim.core.setForeground(false, sim.now)
        sim.advance(10_000)
        assertTrue(sim.sent.size <= sentBeforePause + 1, "sent while in background")
        assertEquals(false, sim.core.isEmitting)
        val sentDuringPause = sim.sent.size

        sim.core.setForeground(true, sim.now)
        sim.advance(1_000)
        assertTrue(sim.sent.size > sentDuringPause)
        assertNoGaps(sim.sent, 200)
        val span = sim.sent.last().batch.startMicros - wall
        assertTrue(span < 2_100_000L, "sample clock moved $span µs")
    }

    @Test
    fun `stop cancels the batch in flight and ignores its reply`() {
        val sim = Simulation(EmitterCore())
        sim.core.start(200, 0, wall)
        sim.advance(100, dartReplies = false)
        val inFlight = sim.sent.single()

        sim.core.stop()
        sim.core.onAck(inFlight.epoch)
        assertNull(sim.core.tick(sim.now + 1_000_000_000L))
        assertTrue(inFlight.epoch != sim.core.epoch)
    }

    @Test
    fun `same seed gives the same samples after a restart`() {
        val first = firstBatchValues()
        val second = firstBatchValues()
        assertTrue(first.contentEquals(second))
        assertTrue(first.size >= 10)
    }

    @Test
    fun `buffer drops the oldest samples and keeps the start index correct`() {
        val buffer = SampleBuffer(4)
        for (i in 0L until 10L) buffer.add(i, i.toFloat())
        assertEquals(6, buffer.dropped)
        assertEquals(6L, buffer.firstIndex)
        val values = buffer.takeAll()
        assertTrue(values.contentEquals(floatArrayOf(6f, 7f, 8f, 9f)))
        assertEquals(0, buffer.size)
        buffer.add(10, 10f)
        assertEquals(10L, buffer.firstIndex)
    }

    fun firstBatchValues(): FloatArray {
        val core = EmitterCore()
        core.start(200, 0, wall)
        val outgoing = assertNotNull(core.tick(100_000_000L))
        return outgoing.batch.values
    }

    fun assertNoGaps(sent: List<OutgoingBatch>, hz: Int) {
        for (i in 1 until sent.size) {
            val previous = sent[i - 1].batch
            val expected = previous.startMicros + previous.values.size * 1_000_000L / hz
            assertEquals(expected, sent[i].batch.startMicros, "gap before batch $i")
        }
    }
}
