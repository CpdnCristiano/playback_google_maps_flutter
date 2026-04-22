import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'google_maps_plus_platform_interface.dart';

/// An implementation of [GoogleMapsPlusPlatform] that uses method channels.
class MethodChannelGoogleMapsPlus extends GoogleMapsPlusPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('google_maps_plus');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
