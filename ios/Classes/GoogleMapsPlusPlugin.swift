import Flutter
import UIKit

public class GoogleMapsPlusPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let playbackFactory = GoogleMapsPlusPlaybackFactory(messenger: registrar.messenger())
    registrar.register(playbackFactory, withId: "br.com.cpndntech.google_maps_plus/playback")
    
    let plusFactory = GoogleMapsPlusFactory(registrar: registrar)
    registrar.register(plusFactory, withId: "br.com.cpndntech.google_maps_plus/plus")
  }
}
