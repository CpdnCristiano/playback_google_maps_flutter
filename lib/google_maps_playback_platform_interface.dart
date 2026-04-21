import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'google_maps_playback_method_channel.dart';

abstract class GoogleMapsPlaybackPlatform extends PlatformInterface {
  /// Constructs a GoogleMapsPlaybackPlatform.
  GoogleMapsPlaybackPlatform() : super(token: _token);

  static final Object _token = Object();

  static GoogleMapsPlaybackPlatform _instance = MethodChannelGoogleMapsPlayback();

  /// The default instance of [GoogleMapsPlaybackPlatform] to use.
  ///
  /// Defaults to [MethodChannelGoogleMapsPlayback].
  static GoogleMapsPlaybackPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [GoogleMapsPlaybackPlatform] when
  /// they register themselves.
  static set instance(GoogleMapsPlaybackPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
