package br.com.cpndntech.google_maps_plus

import io.flutter.embedding.engine.plugins.FlutterPlugin

class GoogleMapsPlusPlugin : FlutterPlugin {
    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            "br.com.cpndntech.google_maps_plus/playback",
            GoogleMapsPlusPlaybackFactory(flutterPluginBinding.binaryMessenger)
        )
        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            "br.com.cpndntech.google_maps_plus/plus",
            GoogleMapsPlusFactory(flutterPluginBinding.binaryMessenger)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
