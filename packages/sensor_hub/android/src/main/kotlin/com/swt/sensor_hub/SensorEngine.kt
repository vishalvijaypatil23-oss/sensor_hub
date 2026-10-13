package com.swt.sensor_hub

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BasicMessageChannel

class SensorEngine(val batchChannel: BasicMessageChannel<Any>, val faultChannel: BasicMessageChannel<Any>) {
    val thread = HandlerThread("sensor_hub")
    val sensorHandler: Handler
    val mainHandler = Handler(Looper.getMainLooper())
    val core = EmitterCore()

    var deliverableEpoch = -1

    val tickTask = object : Runnable {
        override fun run() {
            tick()
            if (core.isEmitting) {
                sensorHandler.postDelayed(this, TICK_MS)
            }
        }
    }

    init {
        thread.start()
        sensorHandler = Handler(thread.looper)
    }

    fun stop(done: () -> Unit) {
        deliverableEpoch = -1
        sensorHandler.post {
            core.stop()
            sensorHandler.removeCallbacks(tickTask)
            mainHandler.post(done)
        }
    }

    fun start(hz: Int, done: (String?) -> Unit) {
        deliverableEpoch = -1
        sensorHandler.post {
            try {
                core.start(hz, SystemClock.elapsedRealtimeNanos(), wallMicros())
            } catch (e: IllegalArgumentException) {
                mainHandler.post { done(e.message) }
                return@post
            }
            val epoch = core.epoch
            sensorHandler.removeCallbacks(tickTask)
            sensorHandler.post(tickTask)
            mainHandler.post {
                deliverableEpoch = epoch
                done(null)
            }
        }
    }

    fun setForeground(foreground: Boolean) {
        val requestedAt = SystemClock.elapsedRealtime()
        sensorHandler.post {
            core.setForeground(foreground, SystemClock.elapsedRealtimeNanos())
            sensorHandler.removeCallbacks(tickTask)
            if (core.isEmitting) {
                sensorHandler.post(tickTask)
            }
            val delay = SystemClock.elapsedRealtime() - requestedAt
            Log.i("SensorHub", "lifecycle: foreground=$foreground applied after $delay ms (emitting=${core.isEmitting})")
        }
    }

    fun stats(done: (Map<String, Any>) -> Unit) {
        sensorHandler.post {
            val stats = core.stats()
            mainHandler.post { done(stats) }
        }
    }

    fun sendTestFault() {
        faultChannel.send(SensorFault("injected", "Test fault from native", wallMicros()))
    }

    fun dispose() {
        deliverableEpoch = -1
        mainHandler.removeCallbacksAndMessages(null)
        sensorHandler.removeCallbacksAndMessages(null)
        thread.quitSafely()
    }

    fun sendBatch(outgoing: OutgoingBatch) {
        if (outgoing.epoch != deliverableEpoch) return
        batchChannel.send(outgoing.batch) {
            sensorHandler.post { core.onAck(outgoing.epoch) }
        }
    }

    fun tick() {
        val now = SystemClock.elapsedRealtimeNanos()
        val epoch = core.epoch
        val outgoing = try {
            core.tick(now)
        } catch (e: Exception) {
            Log.e("SensorHub", "generator failed", e)
            core.stop()
            val fault = SensorFault("internal", e.toString(), wallMicros())
            mainHandler.post { faultChannel.send(fault) }
            return
        }
        if (outgoing != null) {
            mainHandler.post { sendBatch(outgoing) }
        }
        val fault = core.checkOverflow(now, wallMicros())
        if (fault != null) {
            mainHandler.post {
                if (epoch == deliverableEpoch) faultChannel.send(fault)
            }
        }
    }

    fun wallMicros(): Long = System.currentTimeMillis() * 1000L

    companion object {
        const val TICK_MS = 10L
    }
}
