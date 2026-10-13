package com.swt.sensor_hub

import android.app.Activity
import android.app.Application
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class SensorHubPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, Application.ActivityLifecycleCallbacks {
    var controlChannel: MethodChannel? = null
    var engine: SensorEngine? = null
    var application: Application? = null
    var resumedActivities = 0
    var inForeground = true

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        val batchChannel = BasicMessageChannel<Any>(messenger, "sensor_hub/batches", SensorHubCodec)
        val faultChannel = BasicMessageChannel<Any>(messenger, "sensor_hub/faults", SensorHubCodec)
        engine = SensorEngine(batchChannel, faultChannel)

        controlChannel = MethodChannel(messenger, "sensor_hub/control")
        controlChannel?.setMethodCallHandler(this)

        application = binding.applicationContext as? Application
        application?.registerActivityLifecycleCallbacks(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        application?.unregisterActivityLifecycleCallbacks(this)
        application = null
        controlChannel?.setMethodCallHandler(null)
        controlChannel = null
        engine?.dispose()
        engine = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val engine = this.engine
        if (engine == null) {
            result.error("internal", "engine detached", null)
            return
        }
        when (call.method) {
            "attach", "stop" -> engine.stop { result.success(null) }
            "start" -> {
                val hz = (call.argument<Any>("hz") as? Number)?.toInt()
                if (hz == null || hz !in 1..EmitterCore.MAX_HZ) {
                    result.error("invalid_argument", "hz must be in 1..${EmitterCore.MAX_HZ}, was $hz", null)
                    return
                }
                engine.start(hz) { error ->
                    if (error == null) result.success(null) else result.error("invalid_argument", error, null)
                }
            }
            "describe" -> {
                val info = mapOf(
                    "model" to "${Build.MANUFACTURER} ${Build.MODEL} (synthetic)",
                    "maxHz" to EmitterCore.MAX_HZ,
                )
                result.success(info)
            }
            "debugStats" -> engine.stats { stats -> result.success(stats) }
            "debugInjectFault" -> {
                engine.sendTestFault()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onActivityResumed(activity: Activity) {
        resumedActivities++
        updateForeground()
    }

    override fun onActivityPaused(activity: Activity) {
        if (resumedActivities > 0) resumedActivities--
        updateForeground()
    }

    fun updateForeground() {
        val nowInForeground = resumedActivities > 0
        if (nowInForeground != inForeground) {
            inForeground = nowInForeground
            engine?.setForeground(nowInForeground)
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}
}
