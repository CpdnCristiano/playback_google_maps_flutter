import Flutter
import UIKit

public class GoogleMapsPlaybackPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let factory = GoogleMapsPlaybackFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "br.com.cpndntech.google_maps_playback/playback")
  }
}
