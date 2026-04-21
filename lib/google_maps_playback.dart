import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Represents a geographic point in the map playback.
class GoogleMapsPlaybackPoint {
  /// The latitude of the point.
  final double lat;
  
  /// The longitude of the point.
  final double lng;
  
  /// The bearing (rotation) of the vehicle at this point.
  final double bearing;
  
  /// Whether this point represents a stop/event marker.
  final bool isStop;

  GoogleMapsPlaybackPoint({
    required this.lat,
    required this.lng,
    required this.bearing,
    this.isStop = false,
  });

  /// Converts the point to a map for platform channel communication.
  Map<String, dynamic> toMap() {
    return {
      'lat': lat,
      'lng': lng,
      'bearing': bearing,
      'isStop': isStop,
    };
  }
}

/// Callback for when the [GoogleMapsPlaybackController] is created.
typedef GoogleMapsPlaybackCreatedCallback =
    void Function(GoogleMapsPlaybackController controller);

/// A widget that displays a native Google Maps view with playback capabilities.
class GoogleMapsPlayback extends StatelessWidget {
  /// The list of points to be played back.
  final List<GoogleMapsPlaybackPoint> points;
  
  /// The bytes of the vehicle icon.
  final Uint8List vehicleIcon;
  
  /// The bytes of the stop icon (optional).
  final Uint8List? stopIcon;
  
  /// Whether to show stop markers.
  final bool showStops;
  
  /// The color of the polyline trail.
  final Color polylineColor;
  
  /// The initial map type (1: Normal, 2: Satellite, 3: Terrain, 4: Hybrid).
  final int mapType;
  
  /// Whether to show traffic on the map.
  final bool showTraffic;
  
  /// Whether dark mode is enabled for the map.
  final bool isDark;
  
  /// Custom JSON style for dark mode or specific themes.
  final String? darkModeStyle;
  
  /// Whether the vehicle icon should rotate based on bearing.
  final bool canRotate;
  
  /// The base playback speed in meters per second (default is 60.0).
  final double baseSpeed;
  
  /// Called when the map view is created.
  final GoogleMapsPlaybackCreatedCallback? onMapCreated;
  
  /// Which gestures should be consumed by the map.
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;

  const GoogleMapsPlayback({
    super.key,
    required this.points,
    required this.vehicleIcon,
    this.stopIcon,
    this.showStops = true,
    this.polylineColor = Colors.blue,
    this.mapType = 1,
    this.showTraffic = false,
    this.isDark = false,
    this.darkModeStyle,
    this.canRotate = true,
    this.baseSpeed = 60.0,
    this.onMapCreated,
    this.gestureRecognizers,
  });

  @override
  Widget build(BuildContext context) {
    const String viewType = 'br.com.cpndntech.google_maps_playback/playback';

    final Map<String, dynamic> creationParams = {
      'points': points.map((e) => e.toMap()).toList(),
      'vehicleIcon': vehicleIcon,
      'stopIcon': stopIcon,
      'showStops': showStops,
      'polylineColor':
          '#${polylineColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      'mapType': mapType,
      'showTraffic': showTraffic,
      'isDark': isDark,
      'style': darkModeStyle,
      'canRotate': canRotate,
      'baseSpeed': baseSpeed,
    };

    if (defaultTargetPlatform == TargetPlatform.android) {
      return PlatformViewLink(
        viewType: viewType,
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers:
                gestureRecognizers ??
                const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          );
        },
        onCreatePlatformView: (params) {
          return PlatformViewsService.initSurfaceAndroidView(
              id: params.id,
              viewType: viewType,
              layoutDirection: TextDirection.ltr,
              creationParams: creationParams,
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () {
                params.onFocusChanged(true);
              },
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..addOnPlatformViewCreatedListener((id) {
              if (onMapCreated != null) {
                onMapCreated!(GoogleMapsPlaybackController._(id));
              }
            })
            ..create();
        },
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        onPlatformViewCreated: (id) {
          if (onMapCreated != null) {
            onMapCreated!(GoogleMapsPlaybackController._(id));
          }
        },
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }

    return Text(
      '$defaultTargetPlatform is not supported by the google_maps_playback plugin',
    );
  }
}

/// Controller for the [GoogleMapsPlayback] widget.
/// Used to control the playback, zoom, and map settings.
class GoogleMapsPlaybackController {
  final MethodChannel _channel;
  
  /// Called when the playback progress changes.
  /// The value is the current point index (can be fractional during interpolation).
  void Function(double)? onProgress;
  
  /// Called when the playback status changes (e.g., 'playing', 'paused', 'finished').
  void Function(String)? onPlaybackStatusChanged;

  GoogleMapsPlaybackController._(int id)
    : _channel = MethodChannel(
        'br.com.cpndntech.google_maps_playback/playback_$id',
      ) {
    _channel.setMethodCallHandler(_handleMethod);
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'onProgress':
        final double index = call.arguments['index']?.toDouble() ?? 0.0;
        onProgress?.call(index);
        break;
      case 'onPlaybackStatusChanged':
        final String status = call.arguments['status'] as String;
        onPlaybackStatusChanged?.call(status);
        break;
    }
  }

  /// Starts or resumes the map playback.
  Future<void> play() async {
    await _channel.invokeMethod('play');
  }

  /// Pauses the map playback.
  Future<void> pause() async {
    await _channel.invokeMethod('pause');
  }

  /// Seeks to a specific point in the list.
  Future<void> seek(int index) async {
    await _channel.invokeMethod('seek', {'index': index});
  }

  /// Zooms in on the map.
  Future<void> zoomIn() {
    return _channel.invokeMethod('zoomIn');
  }

  /// Zooms out from the map.
  Future<void> zoomOut() {
    return _channel.invokeMethod('zoomOut');
  }

  /// Sets the playback speed multiplier (e.g., 1, 2, 4).
  Future<void> setSpeed(int speed) async {
    await _channel.invokeMethod('setSpeed', {'speed': speed});
  }

  /// Toggles the visibility of stop markers.
  Future<void> toggleStops(bool show) async {
    await _channel.invokeMethod('toggleStops', {'show': show});
  }

  /// Sets the map type (1: Normal, 2: Satellite, 3: Terrain, 4: Hybrid).
  Future<void> setMapType(int mapType) async {
    await _channel.invokeMethod('setMapType', {'mapType': mapType});
  }

  /// Enables or disables traffic display.
  Future<void> setTrafficEnabled(bool enabled) async {
    await _channel.invokeMethod('setTrafficEnabled', {'enabled': enabled});
  }

  /// Updates the map style using a JSON string.
  Future<void> setMapStyle(String? style) async {
    await _channel.invokeMethod('setMapStyle', {
      'style': style,
    });
  }

  /// Toggles dark mode and optionally sets a custom style.
  Future<void> setDarkMode(bool isDark, {String? style}) async {
    await _channel.invokeMethod('setDarkMode', {
      'isDark': isDark,
      'style': style,
    });
  }
}
