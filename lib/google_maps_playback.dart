import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

class GoogleMapsPlaybackPoint {
  final double lat;
  final double lng;
  final double bearing;
  final bool isStop;

  GoogleMapsPlaybackPoint({
    required this.lat,
    required this.lng,
    required this.bearing,
    this.isStop = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'lat': lat,
      'lng': lng,
      'bearing': bearing,
      'isStop': isStop,
    };
  }
}

typedef GoogleMapsPlaybackCreatedCallback =
    void Function(GoogleMapsPlaybackController controller);

class GoogleMapsPlayback extends StatelessWidget {
  final List<GoogleMapsPlaybackPoint> points;
  final Uint8List vehicleIcon;
  final Uint8List? stopIcon;
  final bool showStops;
  final Color polylineColor;
  final int mapType;
  final bool showTraffic;
  final bool isDark;
  final String? darkModeStyle;
  final bool canRotate;
  final double baseSpeed;
  final GoogleMapsPlaybackCreatedCallback? onMapCreated;
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

class GoogleMapsPlaybackController {
  final MethodChannel _channel;
  void Function(double)? onProgress;
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

  Future<void> play() async {
    await _channel.invokeMethod('play');
  }

  Future<void> pause() async {
    await _channel.invokeMethod('pause');
  }

  Future<void> seek(int index) async {
    await _channel.invokeMethod('seek', {'index': index});
  }

  Future<void> zoomIn() {
    return _channel.invokeMethod('zoomIn');
  }

  Future<void> zoomOut() {
    return _channel.invokeMethod('zoomOut');
  }

  Future<void> setSpeed(int speed) async {
    await _channel.invokeMethod('setSpeed', {'speed': speed});
  }

  Future<void> toggleStops(bool show) async {
    await _channel.invokeMethod('toggleStops', {'show': show});
  }

  Future<void> setStops(List<int> indices) async {
    await _channel.invokeMethod('setStops', {'indices': indices});
  }

  Future<void> setMapType(int mapType) async {
    await _channel.invokeMethod('setMapType', {'mapType': mapType});
  }

  Future<void> setTrafficEnabled(bool enabled) async {
    await _channel.invokeMethod('setTrafficEnabled', {'enabled': enabled});
  }

  Future<void> setMapStyle(String? style) async {
    await _channel.invokeMethod('setMapStyle', {
      'style': style,
    });
  }

  Future<void> setDarkMode(bool isDark, {String? style}) async {
    await _channel.invokeMethod('setDarkMode', {
      'isDark': isDark,
      'style': style,
    });
  }
}
