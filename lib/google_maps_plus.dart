library google_maps_plus;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';

export 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    show
        ArgumentCallback,
        ArgumentCallbacks,
        AssetMapBitmap,
        BitmapDescriptor,
        BytesMapBitmap,
        CameraPosition,
        CameraPositionCallback,
        CameraTargetBounds,
        CameraUpdate,
        Cap,
        Circle,
        CircleId,
        Cluster,
        ClusterManager,
        ClusterManagerId,
        GroundOverlay,
        GroundOverlayId,
        Heatmap,
        HeatmapGradient,
        HeatmapGradientColor,
        HeatmapId,
        HeatmapRadius,
        InfoWindow,
        JointType,
        LatLng,
        LatLngBounds,
        MapBitmapScaling,
        MapStyleException,
        MapType,
        Marker,
        MarkerId,
        MinMaxZoomPreference,
        PatternItem,
        Polygon,
        PolygonId,
        PolygonUpdates,
        Polyline,
        PolylineId,
        PolylineUpdates,
        MarkerUpdates,
        CircleUpdates,
        ScreenCoordinate,
        Tile,
        TileOverlay,
        TileOverlayId,
        TileProvider,
        WebGestureHandling,
        WeightedLatLng;

part 'map_settings.dart';
part 'playback_settings.dart';
part 'google_maps_plus_playback.dart';

typedef GoogleMapsPlusCreatedCallback = void Function(GoogleMapsPlusController controller);

int _nextMapCreationId = 0;

class GoogleMapsPlus extends StatefulWidget {
  const GoogleMapsPlus({
    super.key,
    required this.initialCameraPosition,
    this.style,
    this.onMapCreated,
    this.gestureRecognizers = const <Factory<OneSequenceGestureRecognizer>>{},
    this.compassEnabled = true,
    this.mapToolbarEnabled = true,
    this.cameraTargetBounds = CameraTargetBounds.unbounded,
    this.mapType = MapType.normal,
    this.minMaxZoomPreference = MinMaxZoomPreference.unbounded,
    this.rotateGesturesEnabled = true,
    this.scrollGesturesEnabled = true,
    this.zoomControlsEnabled = true,
    this.zoomGesturesEnabled = true,
    this.liteModeEnabled = false,
    this.tiltGesturesEnabled = true,
    this.myLocationEnabled = false,
    this.myLocationButtonEnabled = true,
    this.layoutDirection,
    this.padding = EdgeInsets.zero,
    this.indoorViewEnabled = false,
    this.trafficEnabled = false,
    this.buildingsEnabled = true,
    this.markers = const <Marker>{},
    this.polygons = const <Polygon>{},
    this.polylines = const <Polyline>{},
    this.circles = const <Circle>{},
    this.onCameraMoveStarted,
    this.onCameraMove,
    this.onCameraIdle,
    this.onTap,
    this.onLongPress,
    this.onMarkerTap,
    this.mapId,
    this.isDark = false,
    this.darkModeStyle,
    this.defaultSpeed = 60.0,
    this.maxAnimationDuration = const Duration(seconds: 5),
  });

  final GoogleMapsPlusCreatedCallback? onMapCreated;
  final CameraPosition initialCameraPosition;
  final String? style;
  final bool compassEnabled;
  final bool mapToolbarEnabled;
  final CameraTargetBounds cameraTargetBounds;
  final MapType mapType;
  final TextDirection? layoutDirection;
  final MinMaxZoomPreference minMaxZoomPreference;
  final bool rotateGesturesEnabled;
  final bool scrollGesturesEnabled;
  final bool zoomControlsEnabled;
  final bool zoomGesturesEnabled;
  final bool liteModeEnabled;
  final bool tiltGesturesEnabled;
  final EdgeInsets padding;
  final Set<Marker> markers;
  final Set<Polygon> polygons;
  final Set<Polyline> polylines;
  final Set<Circle> circles;
  final ArgumentCallback<int>? onCameraMoveStarted;
  final CameraPositionCallback? onCameraMove;
  final VoidCallback? onCameraIdle;
  final ArgumentCallback<LatLng>? onTap;
  final ArgumentCallback<LatLng>? onLongPress;
  final ArgumentCallback<MarkerId>? onMarkerTap;
  final bool myLocationEnabled;
  final bool myLocationButtonEnabled;
  final bool indoorViewEnabled;
  final bool trafficEnabled;
  final bool buildingsEnabled;
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;
  final String? mapId;

  // Custom Plus properties
  final bool isDark;
  final String? darkModeStyle;
  final double defaultSpeed;
  final Duration maxAnimationDuration;

  _MapSettings _getSettings() {
    return _MapSettings(
      mapType: mapType,
      showTraffic: trafficEnabled,
      showBuildings: buildingsEnabled,
      showUserLocation: myLocationEnabled,
      showMyLocationButton: myLocationButtonEnabled,
      compassEnabled: compassEnabled,
      mapToolbarEnabled: mapToolbarEnabled,
      rotateGesturesEnabled: rotateGesturesEnabled,
      scrollGesturesEnabled: scrollGesturesEnabled,
      zoomControlsEnabled: zoomControlsEnabled,
      zoomGesturesEnabled: zoomGesturesEnabled,
      tiltGesturesEnabled: tiltGesturesEnabled,
      indoorViewEnabled: indoorViewEnabled,
      isDark: isDark,
      style: darkModeStyle ?? style,
      padding: [padding.top, padding.left, padding.bottom, padding.right],
      defaultSpeed: defaultSpeed,
      maxAnimationDuration: maxAnimationDuration.inMilliseconds.toDouble(),
    );
  }

  @override
  State<GoogleMapsPlus> createState() => _GoogleMapsPlusState();
}

class _GoogleMapsPlusState extends State<GoogleMapsPlus> {
  final int _mapId = _nextMapCreationId++;
  GoogleMapsPlusController? _controller;
  MethodChannel? _channel;

  Map<MarkerId, Marker> _markers = <MarkerId, Marker>{};
  Map<PolygonId, Polygon> _polygons = <PolygonId, Polygon>{};
  Map<PolylineId, Polyline> _polylines = <PolylineId, Polyline>{};
  Map<CircleId, Circle> _circles = <CircleId, Circle>{};

  @override
  void initState() {
    super.initState();
    _markers = {for (final m in widget.markers) m.markerId: m};
    _polygons = {for (final p in widget.polygons) p.polygonId: p};
    _polylines = {for (final p in widget.polylines) p.polylineId: p};
    _circles = {for (final c in widget.circles) c.circleId: c};
  }

  @override
  void didUpdateWidget(GoogleMapsPlus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_channel != null) {
      if (!setEquals(widget.markers, oldWidget.markers)) {
        final MarkerUpdates updates = MarkerUpdates.from(oldWidget.markers, widget.markers);
        _channel!.invokeMethod('markers/update', updates.toJson());
        _markers = {for (final m in widget.markers) m.markerId: m};
      }
      if (!setEquals(widget.polylines, oldWidget.polylines)) {
        final PolylineUpdates updates = PolylineUpdates.from(oldWidget.polylines, widget.polylines);
        _channel!.invokeMethod('polylines/update', updates.toJson());
        _polylines = {for (final p in widget.polylines) p.polylineId: p};
      }
      if (!setEquals(widget.circles, oldWidget.circles)) {
        final CircleUpdates updates = CircleUpdates.from(oldWidget.circles, widget.circles);
        _channel!.invokeMethod('circles/update', updates.toJson());
        _circles = {for (final c in widget.circles) c.circleId: c};
      }
      if (!setEquals(widget.polygons, oldWidget.polygons)) {
        final PolygonUpdates updates = PolygonUpdates.from(oldWidget.polygons, widget.polygons);
        _channel!.invokeMethod('polygons/update', updates.toJson());
        _polygons = {for (final p in widget.polygons) p.polygonId: p};
      }

      final prevSettings = oldWidget._getSettings();
      final currSettings = widget._getSettings();
      if (currSettings.toJson().toString() != prevSettings.toJson().toString()) {
        _channel!.invokeMethod('updateOptions', currSettings.toJson());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const String viewType = 'br.com.cpndntech.google_maps_plus/plus';

    final Map<String, dynamic> creationParams = widget._getSettings().toJson();
    creationParams['initialCameraPosition'] = widget.initialCameraPosition.toMap();
    creationParams['markers'] = widget.markers.map((m) => m.toJson()).toList();
    creationParams['circles'] = widget.circles.map((c) => c.toJson()).toList();
    creationParams['polylines'] = widget.polylines.map((p) => p.toJson()).toList();
    creationParams['polygons'] = widget.polygons.map((p) => p.toJson()).toList();
    creationParams['cloudMapId'] = widget.mapId;

    if (defaultTargetPlatform == TargetPlatform.android) {
      return PlatformViewLink(
        viewType: viewType,
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: widget.gestureRecognizers,
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          );
        },
        onCreatePlatformView: (params) {
          return PlatformViewsService.initSurfaceAndroidView(
              id: params.id,
              viewType: viewType,
              layoutDirection: widget.layoutDirection ?? Directionality.of(context),
              creationParams: creationParams,
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () {
                params.onFocusChanged(true);
              },
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..addOnPlatformViewCreatedListener((id) {
              _onPlatformViewCreated(id);
            })
            ..create();
        },
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        onPlatformViewCreated: _onPlatformViewCreated,
        gestureRecognizers: widget.gestureRecognizers,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }

    return Text(
      '$defaultTargetPlatform is not supported by GoogleMapsPlus',
    );
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('br.com.cpndntech.google_maps_plus/map_$id');
    _channel!.setMethodCallHandler(_handleMethodCall);

    if (widget.onMapCreated != null) {
      _controller = GoogleMapsPlusController._(_channel!, this);
      widget.onMapCreated!(_controller!);
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onMapTap':
        if (widget.onTap != null) {
          final lat = (call.arguments['lat'] as num).toDouble();
          final lng = (call.arguments['lng'] as num).toDouble();
          widget.onTap!(LatLng(lat, lng));
        }
        break;
      case 'onMapLongPress':
        if (widget.onLongPress != null) {
          final lat = (call.arguments['lat'] as num).toDouble();
          final lng = (call.arguments['lng'] as num).toDouble();
          widget.onLongPress!(LatLng(lat, lng));
        }
        break;
      case 'onCameraMoveStarted':
        if (widget.onCameraMoveStarted != null) {
          widget.onCameraMoveStarted!(call.arguments['reason'] as int);
        }
        break;
      case 'onCameraMove':
        if (widget.onCameraMove != null) {
          final pos = call.arguments['position'] as Map;
          final target = pos['target'] as List;
          widget.onCameraMove!(
            CameraPosition(
              target: LatLng(target[0], target[1]),
              zoom: (pos['zoom'] as num).toDouble(),
              tilt: (pos['tilt'] as num).toDouble(),
              bearing: (pos['bearing'] as num).toDouble(),
            ),
          );
        }
        break;
      case 'onCameraIdle':
        if (widget.onCameraIdle != null) {
          widget.onCameraIdle!();
        }
        break;
      case 'onMarkerTap':
        final String id = call.arguments['id'];
        final markerId = MarkerId(id);
        final marker = _markers[markerId];
        if (marker != null && marker.onTap != null) {
          marker.onTap!();
        }
        if (widget.onMarkerTap != null) {
          widget.onMarkerTap!(markerId);
        }
        break;
      case 'onCircleTap':
        final String id = call.arguments['id'];
        final circle = _circles[CircleId(id)];
        if (circle != null && circle.onTap != null) {
          circle.onTap!();
        }
        break;
      case 'onPolylineTap':
        final String id = call.arguments['id'];
        final polyline = _polylines[PolylineId(id)];
        if (polyline != null && polyline.onTap != null) {
          polyline.onTap!();
        }
        break;
      case 'onPolygonTap':
        final String id = call.arguments['id'];
        final polygon = _polygons[PolygonId(id)];
        if (polygon != null && polygon.onTap != null) {
          polygon.onTap!();
        }
        break;
      case 'onInfoWindowTap':
        final String id = call.arguments['id'];
        final marker = _markers[MarkerId(id)];
        if (marker != null && marker.infoWindow.onTap != null) {
          marker.infoWindow.onTap!();
        }
        break;
    }
  }
}

class GoogleMapsPlusController {
  final MethodChannel _channel;
  final _GoogleMapsPlusState _state;

  GoogleMapsPlusController._(this._channel, this._state);

  void dispose() {
    _channel.invokeMethod('follow_marker', {'id': null});
  }

  // Imperative Methods
  Future<void> followMarker(String? id) async => _channel.invokeMethod('follow_marker', {'id': id});

  Future<void> moveMarker(String id, LatLng target, {double rotation = 0.0}) async {
    await _channel.invokeMethod('marker_move', {
      'id': id,
      'lat': target.latitude,
      'lng': target.longitude,
      'rotation': rotation,
    });
  }

  Future<void> updateMarkerIcon(String id, Uint8List bytes) async =>
      _channel.invokeMethod('marker_icon', {'id': id, 'bytes': bytes});

  Future<void> removeMarker(String id) async => _channel.invokeMethod('marker_remove', {'id': id});

  // Standard Google Maps Methods (Parity)
  Future<void> animateCamera(CameraUpdate update) async {
    final json = (update as dynamic).toJson();
    if (json is List && json.isNotEmpty) {
      final type = json[0] as String;
      switch (type) {
        case 'newLatLngBounds':
          final List<dynamic> boundsList = json[1];
          final double padding = (json[2] as num).toDouble();
          final southwest = boundsList[0] as List<dynamic>;
          final northeast = boundsList[1] as List<dynamic>;
          await _channel.invokeMethod('fit_bounds', {
            'points': [
              {'lat': southwest[0], 'lng': southwest[1]},
              {'lat': northeast[0], 'lng': northeast[1]},
            ],
            'padding': padding,
          });
          break;
        case 'newCameraPosition':
          final Map<dynamic, dynamic> pos = json[1];
          final List<dynamic> target = pos['target'];
          final double? zoom = pos['zoom']?.toDouble();
          await _channel.invokeMethod('move_camera', {
            'lat': target[0],
            'lng': target[1],
            'zoom': zoom,
          });
          break;
        case 'newLatLngZoom':
          final List<dynamic> latLng = json[1];
          final double zoom = (json[2] as num).toDouble();
          await _channel.invokeMethod('move_camera', {
            'lat': latLng[0],
            'lng': latLng[1],
            'zoom': zoom,
          });
          break;
        case 'zoomIn':
          await _channel.invokeMethod('zoomIn');
          break;
        case 'zoomOut':
          await _channel.invokeMethod('zoomOut');
          break;
      }
    }
  }

  Future<void> moveCamera(CameraUpdate update) async {
    // Para simplificar, usamos a mesma lógica de animateCamera mas podemos adicionar um flag de 'instant' no futuro
    await animateCamera(update);
  }

  Future<double> getZoomLevel() async => await _channel.invokeMethod<double>('map_get_zoom') ?? 0.0;

  Future<LatLngBounds> getVisibleRegion() async {
    final Map<String, dynamic>? bounds = await _channel.invokeMethod<Map<String, dynamic>>('map_get_bounds');
    if (bounds == null) return LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(0, 0));
    return LatLngBounds(
      southwest: LatLng(bounds['southwest'][0], bounds['southwest'][1]),
      northeast: LatLng(bounds['northeast'][0], bounds['northeast'][1]),
    );
  }

  Future<Uint8List?> takeSnapshot() async => await _channel.invokeMethod<Uint8List>('map_take_snapshot');

  Future<ScreenCoordinate> getScreenCoordinate(LatLng latLng) async {
    final Map<String, dynamic>? result = await _channel.invokeMethod<Map<String, dynamic>>('map_get_screen_coordinate', {
      'lat': latLng.latitude,
      'lng': latLng.longitude,
    });
    if (result == null) return const ScreenCoordinate(x: 0, y: 0);
    return ScreenCoordinate(x: result['x'], y: result['y']);
  }

  Future<LatLng> getLatLng(ScreenCoordinate screenCoordinate) async {
    final Map<String, dynamic>? result = await _channel.invokeMethod<Map<String, dynamic>>('map_get_latlng', {
      'x': screenCoordinate.x,
      'y': screenCoordinate.y,
    });
    if (result == null) return const LatLng(0, 0);
    return LatLng(result['lat'], result['lng']);
  }

  Future<void> showMarkerInfoWindow(MarkerId markerId) async =>
      _channel.invokeMethod('marker_show_info_window', {'id': markerId.value});

  Future<void> hideMarkerInfoWindow(MarkerId markerId) async =>
      _channel.invokeMethod('marker_hide_info_window', {'id': markerId.value});

  Future<bool> isMarkerInfoWindowShown(MarkerId markerId) async =>
      await _channel.invokeMethod<bool>('marker_is_info_window_shown', {'id': markerId.value}) ?? false;
}
