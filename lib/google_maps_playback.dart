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

/// Represents a simple geographic coordinate used in polylines.
class PlaybackLatLng {
  final double lat;
  final double lng;

  PlaybackLatLng(this.lat, this.lng);

  Map<String, dynamic> toMap() => {'lat': lat, 'lng': lng};
}

/// Represents a custom marker to be drawn on the map.
class PlaybackCustomMarker {
  final String id;
  final PlaybackLatLng position;
  final Uint8List? iconBytes;
  final double anchorX;
  final double anchorY;
  final double rotation;
  final double zIndex;
  final bool flat;

  PlaybackCustomMarker({
    required this.id,
    required this.position,
    this.iconBytes,
    this.anchorX = 0.5,
    this.anchorY = 1.0,
    this.rotation = 0.0,
    this.zIndex = 0.0,
    this.flat = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'lat': position.lat,
      'lng': position.lng,
      'iconBytes': iconBytes,
      'anchorX': anchorX,
      'anchorY': anchorY,
      'rotation': rotation,
      'zIndex': zIndex,
      'flat': flat,
    };
  }
}

/// Represents a custom circle (e.g. for a geofence) to be drawn on the map.
class PlaybackCustomCircle {
  final String id;
  final PlaybackLatLng position;
  final double radius;
  final Color fillColor;
  final Color strokeColor;
  final double strokeWidth;
  final double zIndex;

  PlaybackCustomCircle({
    required this.id,
    required this.position,
    required this.radius,
    this.fillColor = const Color(0x220000FF),
    this.strokeColor = const Color(0xFF0000FF),
    this.strokeWidth = 2.0,
    this.zIndex = 0.0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'lat': position.lat,
      'lng': position.lng,
      'radius': radius,
      'fillColor': '#${fillColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      'strokeColor': '#${strokeColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      'strokeWidth': strokeWidth,
      'zIndex': zIndex,
    };
  }
}

/// Represents a custom polyline to be drawn on the map.
class PlaybackCustomPolyline {
  final String id;
  final List<PlaybackLatLng> points;
  final Color color;
  final double width;
  final double zIndex;

  PlaybackCustomPolyline({
    required this.id,
    required this.points,
    this.color = const Color(0xFF000000),
    this.width = 3.0,
    this.zIndex = 0.0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'points': points.map((p) => p.toMap()).toList(),
      'color': '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      'width': width,
      'zIndex': zIndex,
    };
  }
}

/// Callback for when the [GoogleMapsPlaybackController] is created.
typedef GoogleMapsPlaybackCreatedCallback =
    void Function(GoogleMapsPlaybackController controller);

/// A widget that displays a native Google Maps view with playback capabilities.
class GoogleMapsPlayback extends StatefulWidget {
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
  
  /// Whether to calculate the rotation dynamically based on the movement vector
  final bool dynamicRotation;
  
  /// The base playback speed in meters per second (default is 60.0).
  final double baseSpeed;
  
  /// Whether to show the user's location on the map (requires permissions handled by the app).
  final bool showUserLocation;
  
  /// Whether zoom gestures are enabled.
  final bool zoomGesturesEnabled;
  
  /// Whether scroll gestures are enabled.
  final bool scrollGesturesEnabled;
  
  /// Whether tilt gestures are enabled.
  final bool tiltGesturesEnabled;
  
  /// Whether rotate gestures are enabled.
  final bool rotateGesturesEnabled;
  
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
    this.dynamicRotation = false,
    this.baseSpeed = 60.0,
    this.showUserLocation = false,
    this.zoomGesturesEnabled = true,
    this.scrollGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
    this.rotateGesturesEnabled = true,
    this.onMapCreated,
    this.gestureRecognizers,
  });

  @override
  State<GoogleMapsPlayback> createState() => _GoogleMapsPlaybackState();
}

class _GoogleMapsPlaybackState extends State<GoogleMapsPlayback> {
  MethodChannel? _channel;

  @override
  void didUpdateWidget(GoogleMapsPlayback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_channel == null) return;

    final Map<String, dynamic> updates = {};

    if (widget.baseSpeed != oldWidget.baseSpeed) updates['baseSpeed'] = widget.baseSpeed;
    if (widget.showUserLocation != oldWidget.showUserLocation) updates['showUserLocation'] = widget.showUserLocation;
    if (widget.mapType != oldWidget.mapType) updates['mapType'] = widget.mapType;
    if (widget.showTraffic != oldWidget.showTraffic) updates['showTraffic'] = widget.showTraffic;
    if (widget.isDark != oldWidget.isDark) updates['isDark'] = widget.isDark;
    if (widget.darkModeStyle != oldWidget.darkModeStyle) updates['style'] = widget.darkModeStyle;
    if (widget.canRotate != oldWidget.canRotate) updates['canRotate'] = widget.canRotate;
    if (widget.dynamicRotation != oldWidget.dynamicRotation) updates['dynamicRotation'] = widget.dynamicRotation;
    if (widget.showStops != oldWidget.showStops) updates['showStops'] = widget.showStops;
    if (widget.zoomGesturesEnabled != oldWidget.zoomGesturesEnabled) updates['zoomGesturesEnabled'] = widget.zoomGesturesEnabled;
    if (widget.scrollGesturesEnabled != oldWidget.scrollGesturesEnabled) updates['scrollGesturesEnabled'] = widget.scrollGesturesEnabled;
    if (widget.tiltGesturesEnabled != oldWidget.tiltGesturesEnabled) updates['tiltGesturesEnabled'] = widget.tiltGesturesEnabled;
    if (widget.rotateGesturesEnabled != oldWidget.rotateGesturesEnabled) updates['rotateGesturesEnabled'] = widget.rotateGesturesEnabled;

    if (updates.isNotEmpty) {
      _channel!.invokeMethod('updateOptions', updates);
    }
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('br.com.cpndntech.google_maps_playback/playback_$id');
    if (widget.onMapCreated != null) {
      widget.onMapCreated!(GoogleMapsPlaybackController._(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    const String viewType = 'br.com.cpndntech.google_maps_playback/playback';

    final Map<String, dynamic> creationParams = {
      'points': widget.points.map((e) => e.toMap()).toList(),
      'vehicleIcon': widget.vehicleIcon,
      'stopIcon': widget.stopIcon,
      'showStops': widget.showStops,
      'polylineColor':
          '#${widget.polylineColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      'mapType': widget.mapType,
      'showTraffic': widget.showTraffic,
      'isDark': widget.isDark,
      'style': widget.darkModeStyle,
      'canRotate': widget.canRotate,
      'dynamicRotation': widget.dynamicRotation,
      'baseSpeed': widget.baseSpeed,
      'showUserLocation': widget.showUserLocation,
      'zoomGesturesEnabled': widget.zoomGesturesEnabled,
      'scrollGesturesEnabled': widget.scrollGesturesEnabled,
      'tiltGesturesEnabled': widget.tiltGesturesEnabled,
      'rotateGesturesEnabled': widget.rotateGesturesEnabled,
    };

    if (defaultTargetPlatform == TargetPlatform.android) {
      return PlatformViewLink(
        viewType: viewType,
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers:
                widget.gestureRecognizers ??
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
            ..addOnPlatformViewCreatedListener(_onPlatformViewCreated)
            ..create();
        },
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        onPlatformViewCreated: _onPlatformViewCreated,
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

  /// Gets the estimated exact duration of the animation.
  /// This takes into account the current `baseSpeed`, `playbackSpeed`, `showStops`,
  /// and the total distance between all points.
  Future<Duration> getPlaybackDuration() async {
    final double? seconds = await _channel.invokeMethod('getPlaybackDuration');
    if (seconds == null) return Duration.zero;
    return Duration(milliseconds: (seconds * 1000).round());
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

  /// Adds multiple custom markers to the map.
  Future<void> addMarkers(List<PlaybackCustomMarker> markers) async {
    await _channel.invokeMethod('addMarkers', {
      'markers': markers.map((m) => m.toMap()).toList(),
    });
  }

  /// Clears all custom markers from the map.
  Future<void> clearMarkers() async {
    await _channel.invokeMethod('clearMarkers');
  }

  /// Adds multiple custom circles (e.g. geofences) to the map.
  Future<void> addCircles(List<PlaybackCustomCircle> circles) async {
    await _channel.invokeMethod('addCircles', {
      'circles': circles.map((c) => c.toMap()).toList(),
    });
  }

  /// Clears all custom circles from the map.
  Future<void> clearCircles() async {
    await _channel.invokeMethod('clearCircles');
  }

  /// Adds multiple custom polylines to the map.
  Future<void> addPolylines(List<PlaybackCustomPolyline> polylines) async {
    await _channel.invokeMethod('addPolylines', {
      'polylines': polylines.map((p) => p.toMap()).toList(),
    });
  }

  /// Clears all custom polylines from the map.
  Future<void> clearPolylines() async {
    await _channel.invokeMethod('clearPolylines');
  }

  /// Clears all custom shapes (markers, circles, polylines) from the map.
  Future<void> clearAllCustomShapes() async {
    await clearMarkers();
    await clearCircles();
    await clearPolylines();
  }
}
