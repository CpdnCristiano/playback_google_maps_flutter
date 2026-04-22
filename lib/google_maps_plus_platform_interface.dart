import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'google_maps_plus_method_channel.dart';

abstract class GoogleMapsPlusPlatform extends PlatformInterface {
  GoogleMapsPlusPlatform() : super(token: _token);
  static final Object _token = Object();
  static GoogleMapsPlusPlatform _instance = MethodChannelGoogleMapsPlus();
  static GoogleMapsPlusPlatform get instance => _instance;
  static set instance(GoogleMapsPlusPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
