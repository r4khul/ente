package io.ente.photos.platform

import io.ente.photos.platform.flutter.PhotosPlatformChannelRouter
import io.ente.photos.platform.flutter.ProcessLockChannelAdapter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

class PhotosPlatformPlugin : FlutterPlugin, ActivityAware {
    private val channelRouter = PhotosPlatformChannelRouter()
    private val processLockAdapter = ProcessLockChannelAdapter()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channelRouter.attach(binding)
        processLockAdapter.attach(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channelRouter.detach()
        processLockAdapter.detach()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        channelRouter.attachActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        channelRouter.detachActivityForConfigChanges()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        channelRouter.attachActivity(binding)
    }

    override fun onDetachedFromActivity() {
        channelRouter.detachActivity()
    }
}
