library google_maps_plus;

import 'package:collection/collection.dart';
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
        Polyline,
        PolylineId,
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

class GoogleMapsPlus extends StatefulWidget {
  final MapType mapType;
  final CameraPosition initialCameraPosition;
  final Set<Marker> markers;
  final Set<Polygon> polygons;
  final Set<Circle> circles;
  final Set<Polyline> polylines;
  final bool mapToolbarEnabled;
  final bool buildingsEnabled;
  final bool myLocationEnabled;
  final bool myLocationButtonEnabled;
  final bool trafficEnabled;
  final bool compassEnabled;
  final bool rotateGesturesEnabled;
  final bool scrollGesturesEnabled;
  final bool zoomControlsEnabled;
  final bool zoomGesturesEnabled;
  final bool tiltGesturesEnabled;
  final EdgeInsets padding;
  final bool indoorViewEnabled;
  final CameraTargetBounds cameraTargetBounds;
  final MinMaxZoomPreference minMaxZoomPreference;
  final String? cloudMapId;
  final ValueChanged<LatLng>? onTap;
  final ArgumentCallback<int>? onCameraMoveStarted;
  final CameraPositionCallback? onCameraMove;
  final VoidCallback? onCameraIdle;
  final ArgumentCallback<LatLng>? onLongPress;
  final ValueChanged<MarkerId>? onMarkerTap;
  final dynamic clusterManagers; // Aceitando genericamente se houver
  final GoogleMapsPlusCreatedCallback? onMapCreated;

  // Custom theme variables (if you still want to use your dark mode logic easily)
  final bool isDark;
  final String? darkModeStyle;
  final double defaultSpeed; // meters per second
  final Duration maxAnimationDuration;

  const GoogleMapsPlus({
    super.key,
    required this.initialCameraPosition,
    this.mapType = MapType.normal,
    this.markers = const <Marker>{},
    this.polygons = const <Polygon>{},
    this.circles = const <Circle>{},
    this.polylines = const <Polyline>{},
    this.mapToolbarEnabled = true,
    this.buildingsEnabled = true,
    this.myLocationEnabled = false,
    this.myLocationButtonEnabled = true,
    this.trafficEnabled = false,
    this.compassEnabled = true,
    this.rotateGesturesEnabled = true,
    this.scrollGesturesEnabled = true,
    this.zoomControlsEnabled = true,
    this.zoomGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
    this.padding = EdgeInsets.zero,
    this.indoorViewEnabled = false,
    this.cameraTargetBounds = CameraTargetBounds.unbounded,
    this.minMaxZoomPreference = MinMaxZoomPreference.unbounded,
    this.cloudMapId,
    this.onTap,
    this.onLongPress,
    this.onMarkerTap,
    this.onCameraMoveStarted,
    this.onCameraMove,
    this.onCameraIdle,
    this.clusterManagers,
    this.onMapCreated,
    this.isDark = false,
    this.darkModeStyle,
    this.defaultSpeed = 60.0,
    this.maxAnimationDuration = const Duration(seconds: 5),
  });

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
      style: darkModeStyle,
      padding: [padding.top, padding.left, padding.bottom, padding.right],
      defaultSpeed: defaultSpeed,
      maxAnimationDuration: maxAnimationDuration.inMilliseconds.toDouble(),
    );
  }

  @override
  State<GoogleMapsPlus> createState() => _GoogleMapsPlusState();
}

class _GoogleMapsPlusState extends State<GoogleMapsPlus> {
  GoogleMapsPlusController? _controller;
  MethodChannel? _channel;

  late Map<MarkerId, Marker> _markerMap;
  late Map<PolylineId, Polyline> _polylineMap;
  late Map<PolygonId, Polygon> _polygonMap;
  late Map<CircleId, Circle> _circleMap;

  @override
  void initState() {
    super.initState();
    _updateCaches();
  }

  @override
  void didUpdateWidget(GoogleMapsPlus oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateCaches();
    if (_channel != null) {
      if (!setEquals(widget.markers, oldWidget.markers)) {
        _updateMarkers(oldWidget.markers, widget.markers);
      }
      if (!setEquals(widget.polylines, oldWidget.polylines)) {
        _updatePolylines(oldWidget.polylines, widget.polylines);
      }
      if (!setEquals(widget.circles, oldWidget.circles)) {
        _updateCircles(oldWidget.circles, widget.circles);
      }
      if (!setEquals(widget.polygons, oldWidget.polygons)) {
        _updatePolygons(oldWidget.polygons, widget.polygons);
      }
    }

    // Update settings if they changed
    final prevSettings = oldWidget._getSettings();
    final currSettings = widget._getSettings();
    
    // Simplest way to check for changes is to compare JSON or specific fields.
    // In POO, we could implement operator == on MapSettings.
    if (currSettings.toJson().toString() != prevSettings.toJson().toString()) {
      _channel!.invokeMethod('updateOptions', currSettings.toJson());
    }
  }

  void _updateCaches() {
    _markerMap = {for (final m in widget.markers) m.markerId: m};
    _polylineMap = {for (final p in widget.polylines) p.polylineId: p};
    _polygonMap = {for (final p in widget.polygons) p.polygonId: p};
    _circleMap = {for (final c in widget.circles) c.circleId: c};
  }

  void _updateMarkers(Set<Marker> previous, Set<Marker> current) {
    if (setEquals(previous, current)) {
      return;
    }

    final Map<MarkerId, Marker> prevMap = {
      for (final m in previous) m.markerId: m,
    };
    final Map<MarkerId, Marker> currMap = {
      for (final m in current) m.markerId: m,
    };

    final Set<MarkerId> prevIds = prevMap.keys.toSet();
    final Set<MarkerId> currIds = currMap.keys.toSet();

    final Set<MarkerId> addedIds = currIds.difference(prevIds);
    final Set<MarkerId> removedIds = prevIds.difference(currIds);
    final Set<MarkerId> commonIds = currIds.intersection(prevIds);

    for (final id in addedIds) {
      final marker = currMap[id]!;
      _channel!.invokeMethod('marker_add', {'marker': marker.toJson()});
    }

    for (final id in commonIds) {
      final oldMarker = prevMap[id]!;
      final newMarker = currMap[id]!;

      if (newMarker == oldMarker) {
        continue;
      }

      // If position or rotation changed, use marker_move for animation
      if (newMarker.position != oldMarker.position ||
          newMarker.rotation != oldMarker.rotation) {
        _channel!.invokeMethod('marker_move', {
          'id': newMarker.markerId.value,
          'lat': newMarker.position.latitude,
          'lng': newMarker.position.longitude,
          'rotation': newMarker.rotation,
        });
      }

      // If icon changed, update it
      if (newMarker.icon != oldMarker.icon) {
        _channel!.invokeMethod('marker_icon', {
          'id': newMarker.markerId.value,
          'icon': newMarker.icon.toJson(),
        });
      }

      // Handle other changes (alpha, zIndex, etc.) if needed via a full add or specific calls
      // For markers, usually these are the most common updates during playback
    }

    for (final id in removedIds) {
      _channel!.invokeMethod('marker_remove', {'id': id.value});
    }
  }

  void _updateCircles(Set<Circle> previous, Set<Circle> current) {
    if (setEquals(previous, current)) {
      return;
    }

    final Map<CircleId, Circle> prevMap = {
      for (final c in previous) c.circleId: c,
    };
    final Map<CircleId, Circle> currMap = {
      for (final c in current) c.circleId: c,
    };

    final Set<CircleId> prevIds = prevMap.keys.toSet();
    final Set<CircleId> currIds = currMap.keys.toSet();

    final Set<CircleId> addedIds = currIds.difference(prevIds);
    final Set<CircleId> removedIds = prevIds.difference(currIds);
    final Set<CircleId> commonIds = currIds.intersection(prevIds);

    final List<Circle> circlesToAdd = addedIds
        .map((id) => currMap[id]!)
        .toList();
    final List<String> circleIdsToRemove = removedIds
        .map((id) => id.value)
        .toList();
    final List<Circle> circlesToChange = [];

    for (final id in commonIds) {
      final oldCircle = prevMap[id]!;
      final newCircle = currMap[id]!;
      if (oldCircle != newCircle) {
        circlesToChange.add(newCircle);
      }
    }

    if (circlesToAdd.isNotEmpty ||
        circlesToChange.isNotEmpty ||
        circleIdsToRemove.isNotEmpty) {
      _channel!.invokeMethod('circles/update', {
        'toAdd': circlesToAdd.map((c) => _circleToMap(c)).toList(),
        'toChange': circlesToChange.map((c) => _circleToMap(c)).toList(),
        'toRemove': circleIdsToRemove,
      });
    }
  }

  void _updatePolylines(Set<Polyline> previous, Set<Polyline> current) {
    if (setEquals(previous, current)) {
      return;
    }

    final Map<PolylineId, Polyline> prevMap = {
      for (final p in previous) p.polylineId: p,
    };
    final Map<PolylineId, Polyline> currMap = {
      for (final p in current) p.polylineId: p,
    };

    final Set<PolylineId> prevIds = prevMap.keys.toSet();
    final Set<PolylineId> currIds = currMap.keys.toSet();

    final Set<PolylineId> addedIds = currIds.difference(prevIds);
    final Set<PolylineId> removedIds = prevIds.difference(currIds);
    final Set<PolylineId> commonIds = currIds.intersection(prevIds);

    final List<Polyline> polylinesToAdd = addedIds
        .map((id) => currMap[id]!)
        .toList();
    final List<String> polylineIdsToRemove = removedIds
        .map((id) => id.value)
        .toList();
    final List<Polyline> polylinesToChange = [];

    for (final id in commonIds) {
      final oldPoly = prevMap[id]!;
      final newPoly = currMap[id]!;
      if (oldPoly != newPoly) {
        polylinesToChange.add(newPoly);
      }
    }

    if (polylinesToAdd.isNotEmpty ||
        polylinesToChange.isNotEmpty ||
        polylineIdsToRemove.isNotEmpty) {
      _channel!.invokeMethod('polylines/update', {
        'toAdd': polylinesToAdd.map((p) => _polylineToMap(p)).toList(),
        'toChange': polylinesToChange.map((p) => _polylineToMap(p)).toList(),
        'toRemove': polylineIdsToRemove,
      });
    }
  }

  void _updatePolygons(Set<Polygon> previous, Set<Polygon> current) {
    if (setEquals(previous, current)) return;

    final Map<PolygonId, Polygon> prevMap = {
      for (final p in previous) p.polygonId: p,
    };
    final Map<PolygonId, Polygon> currMap = {
      for (final p in current) p.polygonId: p,
    };

    final Set<PolygonId> prevIds = prevMap.keys.toSet();
    final Set<PolygonId> currIds = currMap.keys.toSet();

    final Set<PolygonId> addedIds = currIds.difference(prevIds);
    final Set<PolygonId> removedIds = prevIds.difference(currIds);
    final Set<PolygonId> commonIds = currIds.intersection(prevIds);

    final List<Polygon> polygonsToAdd = addedIds
        .map((id) => currMap[id]!)
        .toList();
    final List<String> polygonIdsToRemove = removedIds
        .map((id) => id.value)
        .toList();
    final List<Polygon> polygonsToChange = [];

    for (final id in commonIds) {
      final oldPolygon = prevMap[id]!;
      final newPolygon = currMap[id]!;
      if (oldPolygon != newPolygon) {
        polygonsToChange.add(newPolygon);
      }
    }

    if (polygonsToAdd.isNotEmpty ||
        polygonsToChange.isNotEmpty ||
        polygonIdsToRemove.isNotEmpty) {
      _channel!.invokeMethod('polygons/update', {
        'toAdd': polygonsToAdd.map((p) => _polygonToMap(p)).toList(),
        'toChange': polygonsToChange.map((p) => _polygonToMap(p)).toList(),
        'toRemove': polygonIdsToRemove,
      });
    }
  }

  Map<String, dynamic> _markerToMap(Marker marker) {
    return marker.toJson() as Map<String, dynamic>;
  }

  Map<String, dynamic> _polylineToMap(Polyline polyline) {
    return polyline.toJson() as Map<String, dynamic>;
  }

  Map<String, dynamic> _circleToMap(Circle circle) {
    return circle.toJson() as Map<String, dynamic>;
  }

  Map<String, dynamic> _polygonToMap(Polygon polygon) {
    return polygon.toJson() as Map<String, dynamic>;
  }

  @override
  Widget build(BuildContext context) {
    const String viewType = 'br.com.cpndntech.google_maps_plus/plus';

    final Map<String, dynamic> creationParams = widget._getSettings().toJson();
    creationParams['initialCameraPosition'] = widget.initialCameraPosition.toMap();
    creationParams['markers'] = widget.markers.map(_markerToMap).toList();
    creationParams['circles'] = widget.circles.map(_circleToMap).toList();
    creationParams['polylines'] = widget.polylines.map(_polylineToMap).toList();
    creationParams['polygons'] = widget.polygons.map(_polygonToMap).toList();
    creationParams['cloudMapId'] = widget.cloudMapId;

    if (defaultTargetPlatform == TargetPlatform.android) {
      return PlatformViewLink(
        viewType: viewType,
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
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
              _channel = MethodChannel(
                'br.com.cpndntech.google_maps_plus/map_$id',
              );

              _channel!.setMethodCallHandler((call) async {
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
                      widget.onCameraMoveStarted!(
                        call.arguments['reason'] as int,
                      );
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
                    final marker = _markerMap[MarkerId(id)];
                    if (marker != null && marker.onTap != null) {
                      marker.onTap!();
                    }
                    if (widget.onMarkerTap != null) {
                      widget.onMarkerTap!(MarkerId(id));
                    }
                    break;
                  case 'onCircleTap':
                    final String id = call.arguments['id'];
                    final circle = _circleMap[CircleId(id)];
                    if (circle != null && circle.onTap != null) {
                      circle.onTap!();
                    }
                    break;
                  case 'onPolylineTap':
                    final String id = call.arguments['id'];
                    final polyline = _polylineMap[PolylineId(id)];
                    if (polyline != null && polyline.onTap != null) {
                      polyline.onTap!();
                    }
                    break;
                  case 'onPolygonTap':
                    final String id = call.arguments['id'];
                    final polygon = _polygonMap[PolygonId(id)];
                    if (polygon != null && polygon.onTap != null) {
                      polygon.onTap!();
                    }
                    break;
                  case 'onInfoWindowTap':
                    final String id = call.arguments['id'];
                    final marker = _markerMap[MarkerId(id)];
                    if (marker != null && marker.infoWindow.onTap != null) {
                      marker.infoWindow.onTap!();
                    }
                    break;
                }
              });

              if (widget.onMapCreated != null) {
                _controller = GoogleMapsPlusController._(_channel!);
                widget.onMapCreated!(_controller!);
              }
            })
            ..create();
        },
      );
    }

    return Text(
      '$defaultTargetPlatform is not supported by the google_maps_plus imperative view',
    );
  }
}

class GoogleMapsPlusController {
  final MethodChannel channel;

  GoogleMapsPlusController._(this.channel);

  /// Libera recursos e para processos em execução no mapa.
  void dispose() {
    channel.invokeMethod('follow_marker', {'id': null});
    // Adicione outras limpezas aqui se necessário
  }

  // Imperative Methods that trigger animations and high-performance native behavior

  /// Centraliza a câmera em um marker específico e o segue se ele se mover.
  /// Passe [id] null para parar de seguir.
  Future<void> followMarker(String? id) async {
    await channel.invokeMethod('follow_marker', {'id': id});
  }

  /// Fits the camera to the specified LatLngBounds.
  Future<void> fitBounds(LatLngBounds bounds, {double padding = 60.0}) async {
    await channel.invokeMethod('fit_bounds', {
      'points': [
        {'lat': bounds.southwest.latitude, 'lng': bounds.southwest.longitude},
        {'lat': bounds.northeast.latitude, 'lng': bounds.northeast.longitude},
      ],
      'padding': padding,
    });
  }

  /// Fits the camera to include all provided LatLng points.
  Future<void> fitBoundsFromPoints(
    List<LatLng> points, {
    double padding = 60.0,
  }) async {
    await channel.invokeMethod('fit_bounds', {
      'points': points
          .map((p) => {'lat': p.latitude, 'lng': p.longitude})
          .toList(),
      'padding': padding,
    });
  }

  /// Anima a câmera baseado em um [CameraUpdate].
  /// Suporta os casos mais comuns como newLatLngBounds, newLatLng, zoomIn, zoomOut.
  Future<void> animateCamera(CameraUpdate update) async {
    final json = (update as dynamic)
        .toJson(); // CameraUpdate expõe toJson no platform_interface

    // O formato do JSON varia conforme o tipo de update
    // Ex: ['newLatLngBounds', [[lat, lng], [lat, lng]], padding]
    if (json is List && json.isNotEmpty) {
      final type = json[0] as String;

      switch (type) {
        case 'newLatLngBounds':
          final List<dynamic> boundsList = json[1];
          final double padding = (json[2] as num).toDouble();
          final southwest = boundsList[0] as List<dynamic>;
          final northeast = boundsList[1] as List<dynamic>;

          await channel.invokeMethod('fit_bounds', {
            'points': [
              {'lat': southwest[0], 'lng': southwest[1]},
              {'lat': northeast[0], 'lng': northeast[1]},
            ],
            'padding': padding,
          });
          break;

        case 'zoomIn':
          await channel.invokeMethod('zoomIn');
          break;

        case 'zoomOut':
          await channel.invokeMethod('zoomOut');
          break;

        case 'newLatLng':
          final List<dynamic> latLng = json[1];
          await channel.invokeMethod('fit_bounds', {
            'points': [
              {'lat': latLng[0], 'lng': latLng[1]},
            ],
            'padding': 0.0,
          });
          break;

        case 'newCameraPosition':
          final Map<dynamic, dynamic> pos = json[1];
          final List<dynamic> target = pos['target'];
          final double? zoom = pos['zoom']?.toDouble();

          await channel.invokeMethod('move_camera', {
            'lat': target[0],
            'lng': target[1],
            'zoom': zoom,
          });
          break;

        case 'newLatLngZoom':
          final List<dynamic> latLng = json[1];
          final double zoom = (json[2] as num).toDouble();
          await channel.invokeMethod('move_camera', {
            'lat': latLng[0],
            'lng': latLng[1],
            'zoom': zoom,
          });
          break;

        default:
          debugPrint(
            'IMPERATIVE_MAP: animateCamera type "$type" not yet implemented.',
          );
      }
    }
  }

  Future<void> moveMarker(
    String id,
    LatLng targetPosition, {
    double rotation = 0.0,
  }) async {
    await channel.invokeMethod('marker_move', {
      'id': id,
      'lat': targetPosition.latitude,
      'lng': targetPosition.longitude,
      'rotation': rotation,
    });
  }

  Future<void> updateMarkerIcon(String id, Uint8List bytes) async {
    await channel.invokeMethod('marker_icon', {'id': id, 'bytes': bytes});
  }

  Future<void> removeMarker(String id) async {
    await channel.invokeMethod('marker_remove', {'id': id});
  }

  // Camera Controls
  Future<void> zoomIn() async {
    await channel.invokeMethod('zoomIn');
  }

  /// Zooms out from the map.
  Future<void> zoomOut() async {
    await channel.invokeMethod('zoomOut');
  }

  /// Shows the info window for a specific marker.
  Future<void> showMarkerInfoWindow(MarkerId markerId) async {
    await channel.invokeMethod('marker_show_info_window', {
      'id': markerId.value,
    });
  }
}
