import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'google_maps_playback_platform_interface.dart';

/// An implementation of [GoogleMapsPlaybackPlatform] that uses method channels.
class MethodChannelGoogleMapsPlayback extends GoogleMapsPlaybackPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('google_maps_playback');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
