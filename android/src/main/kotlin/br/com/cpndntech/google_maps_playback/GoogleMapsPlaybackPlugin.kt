package br.com.cpndntech.google_maps_playback

import io.flutter.embedding.engine.plugins.FlutterPlugin

class GoogleMapsPlaybackPlugin : FlutterPlugin {
    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            "br.com.cpndntech.google_maps_playback/playback",
            GoogleMapsPlaybackFactory(flutterPluginBinding.binaryMessenger)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
