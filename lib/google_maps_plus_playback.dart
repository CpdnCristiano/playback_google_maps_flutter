part of 'google_maps_plus.dart';

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
    return {'lat': lat, 'lng': lng, 'bearing': bearing, 'isStop': isStop};
  }

  Map<String, dynamic> toJson() => toMap();
}

/// Callback for when the [GoogleMapsPlaybackController] is created.
typedef GoogleMapsPlusPlaybackCreatedCallback =
    void Function(GoogleMapsPlusPlaybackController controller);

/// A widget that displays a native Google Maps view with playback capabilities.
class GoogleMapsPlusPlayback extends StatefulWidget {
  /// The list of points to be played back.
  final List<GoogleMapsPlaybackPoint> points;

  /// The icon for the vehicle (Asset, Bytes or Default).
  final BitmapDescriptor vehicleIcon;

  /// The icon for stops/events (optional).
  final BitmapDescriptor? stopIcon;

  /// Whether to show stop markers.
  final bool showStops;

  /// The color of the polyline trail.
  final Color polylineColor;

  /// Whether to draw the polyline trail of the vehicle's progress.
  final bool drawTrail;
  final bool autoStart;

  /// The initial map type.
  final MapType mapType;

  /// Whether to show traffic on the map.
  final bool trafficEnabled;

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

  /// Whether to show the user's location on the map.
  final bool myLocationEnabled;

  /// Whether the my location button is enabled.
  final bool myLocationButtonEnabled;

  /// Whether buildings are enabled.
  final bool buildingsEnabled;

  /// Whether the compass is enabled.
  final bool compassEnabled;

  /// Whether the map toolbar is enabled.
  final bool mapToolbarEnabled;

  /// Whether zoom controls are enabled.
  final bool zoomControlsEnabled;

  /// Whether zoom gestures are enabled.
  final bool zoomGesturesEnabled;

  /// Whether scroll gestures are enabled.
  final bool scrollGesturesEnabled;

  /// Whether tilt gestures are enabled.
  final bool tiltGesturesEnabled;

  /// Whether rotate gestures are enabled.
  final bool rotateGesturesEnabled;

  /// Map padding.
  final EdgeInsets padding;

  /// Whether indoor view is enabled.
  final bool indoorViewEnabled;

  /// The initial camera position.
  final CameraPosition? initialCameraPosition;

  /// The initial markers to display on the map.
  final Set<Marker> markers;

  /// The initial polylines to display on the map.
  final Set<Polyline> polylines;

  /// The initial circles to display on the map.
  final Set<Circle> circles;

  /// The initial polygons to display on the map.
  final Set<Polygon> polygons;

  /// Called when the map view is created.
  final GoogleMapsPlusPlaybackCreatedCallback? onMapCreated;

  /// Which gestures should be consumed by the map.
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;

  /// The default speed for animated map objects (meters/second).
  final double defaultSpeed;

  /// The maximum duration for map object animations.
  final Duration maxAnimationDuration;

  /// Called when the playback progress changes.
  final ValueChanged<double>? onProgress;

  /// Called when the playback status (playing, paused, etc.) changes.
  final ValueChanged<String>? onPlaybackStatusChanged;

  const GoogleMapsPlusPlayback({
    super.key,
    required this.points,
    required this.vehicleIcon,
    this.stopIcon,
    this.showStops = true,
    this.polylineColor = Colors.blue,
    this.drawTrail = true,
    this.autoStart = false,
    this.mapType = MapType.normal,
    this.trafficEnabled = false,
    this.isDark = false,
    this.darkModeStyle,
    this.canRotate = true,
    this.dynamicRotation = false,
    this.baseSpeed = 60.0,
    this.myLocationEnabled = false,
    this.myLocationButtonEnabled = true,
    this.buildingsEnabled = true,
    this.compassEnabled = true,
    this.mapToolbarEnabled = true,
    this.zoomControlsEnabled = true,
    this.zoomGesturesEnabled = true,
    this.scrollGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
    this.rotateGesturesEnabled = true,
    this.padding = EdgeInsets.zero,
    this.indoorViewEnabled = false,
    this.initialCameraPosition,
    this.markers = const <Marker>{},
    this.polylines = const <Polyline>{},
    this.circles = const <Circle>{},
    this.polygons = const <Polygon>{},
    this.defaultSpeed = 60.0,
    this.maxAnimationDuration = const Duration(milliseconds: 2000),
    this.onMapCreated,
    this.gestureRecognizers,
    this.onProgress,
    this.onPlaybackStatusChanged,
  });

  _MapSettings _getMapSettings() {
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

  _PlaybackSettings _getPlaybackSettings() {
    return _PlaybackSettings(
      baseSpeed: baseSpeed,
      canRotate: canRotate,
      dynamicRotation: dynamicRotation,
      showStops: showStops,
      vehicleIcon: vehicleIcon.toJson(),
      stopIcon: stopIcon?.toJson(),
      drawTrail: drawTrail,
      autoStart: autoStart,
      polylineColor:
          '#${polylineColor.toARGB32().toRadixString(16).padLeft(8, '0')}',
      points: points.map((p) => p.toJson()).toList(),
    );
  }

  @override
  State<GoogleMapsPlusPlayback> createState() => _GoogleMapsPlusPlaybackState();
}

class _GoogleMapsPlusPlaybackState extends State<GoogleMapsPlusPlayback> {
  MethodChannel? _channel;
  GoogleMapsPlusPlaybackController? _controller;

  @override
  void didUpdateWidget(GoogleMapsPlusPlayback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_channel == null) {
      return;
    }

    // Update settings if they changed using OOP approach
    final prevMapSettings = oldWidget._getMapSettings();
    final currMapSettings = widget._getMapSettings();
    final prevPlaybackSettings = oldWidget._getPlaybackSettings();
    final currPlaybackSettings = widget._getPlaybackSettings();

    if (currMapSettings.toJson().toString() !=
            prevMapSettings.toJson().toString() ||
        currPlaybackSettings.toJson().toString() !=
            prevPlaybackSettings.toJson().toString()) {
      _channel!.invokeMethod('updateOptions', {
        ...currMapSettings.toJson(),
        ...currPlaybackSettings.toJson(),
      });
    }

    if (!setEquals(widget.markers, oldWidget.markers)) {
      final oldMarkers = {for (var m in oldWidget.markers) m.markerId: m};
      final newMarkers = {for (var m in widget.markers) m.markerId: m};

      final markersToAdd = widget.markers
          .where((m) => !oldMarkers.containsKey(m.markerId))
          .toList();
      final markersToChange = widget.markers
          .where(
            (m) =>
                oldMarkers.containsKey(m.markerId) &&
                m != oldMarkers[m.markerId],
          )
          .toList();
      final markerIdsToRemove = oldWidget.markers
          .where((m) => !newMarkers.containsKey(m.markerId))
          .map((m) => m.markerId.value)
          .toList();

      for (final marker in markersToAdd) {
        _channel!.invokeMethod('marker_add', {'marker': marker.toJson()});
      }

      for (final marker in markersToChange) {
        final oldMarker = oldMarkers[marker.markerId]!;

        if (marker.position != oldMarker.position ||
            marker.rotation != oldMarker.rotation) {
          _channel!.invokeMethod('marker_move', {
            'id': marker.markerId.value,
            'lat': marker.position.latitude,
            'lng': marker.position.longitude,
            'rotation': marker.rotation,
          });
        }

        if (marker.icon != oldMarker.icon) {
          _channel!.invokeMethod('marker_icon', {
            'id': marker.markerId.value,
            'icon': marker.icon.toJson(),
          });
        }
      }

      for (final id in markerIdsToRemove) {
        _channel!.invokeMethod('marker_remove', {'id': id});
      }
    }
    if (!setEquals(widget.polylines, oldWidget.polylines)) {
      debugPrint('Polylines have changed');
      final oldPolylines = {for (var p in oldWidget.polylines) p.polylineId: p};
      final newPolylines = {for (var p in widget.polylines) p.polylineId: p};

      final polylinesToAdd = widget.polylines
          .where((p) => !oldPolylines.containsKey(p.polylineId))
          .toList();
      final polylinesToChange = widget.polylines
          .where(
            (p) =>
                oldPolylines.containsKey(p.polylineId) &&
                p != oldPolylines[p.polylineId],
          )
          .toList();
      final polylineIdsToRemove = oldWidget.polylines
          .where((p) => !newPolylines.containsKey(p.polylineId))
          .map((p) => p.polylineId.value)
          .toList();

      if (polylinesToAdd.isNotEmpty ||
          polylinesToChange.isNotEmpty ||
          polylineIdsToRemove.isNotEmpty) {
        _channel!.invokeMethod('polylines/update', {
          'toAdd': polylinesToAdd.map((p) => p.toJson()).toList(),
          'toChange': polylinesToChange.map((p) => p.toJson()).toList(),
          'toRemove': polylineIdsToRemove,
        });
      }
    }

    if (!setEquals(widget.circles, oldWidget.circles)) {
      final oldCircles = {for (var c in oldWidget.circles) c.circleId: c};
      final newCircles = {for (var c in widget.circles) c.circleId: c};

      final circlesToAdd = widget.circles
          .where((c) => !oldCircles.containsKey(c.circleId))
          .toList();
      final circlesToChange = widget.circles
          .where(
            (c) =>
                oldCircles.containsKey(c.circleId) &&
                c != oldCircles[c.circleId],
          )
          .toList();
      final circleIdsToRemove = oldWidget.circles
          .where((c) => !newCircles.containsKey(c.circleId))
          .map((c) => c.circleId.value)
          .toList();

      if (circlesToAdd.isNotEmpty ||
          circlesToChange.isNotEmpty ||
          circleIdsToRemove.isNotEmpty) {
        _channel!.invokeMethod('circles/update', {
          'toAdd': circlesToAdd.map((c) => c.toJson()).toList(),
          'toChange': circlesToChange.map((c) => c.toJson()).toList(),
          'toRemove': circleIdsToRemove,
        });
      }
    }

    if (!setEquals(widget.polygons, oldWidget.polygons)) {
      final oldPolygons = {for (var p in oldWidget.polygons) p.polygonId: p};
      final newPolygons = {for (var p in widget.polygons) p.polygonId: p};

      final polygonsToAdd = widget.polygons
          .where((p) => !oldPolygons.containsKey(p.polygonId))
          .toList();
      final polygonsToChange = widget.polygons
          .where(
            (p) =>
                oldPolygons.containsKey(p.polygonId) &&
                p != oldPolygons[p.polygonId],
          )
          .toList();
      final polygonIdsToRemove = oldWidget.polygons
          .where((p) => !newPolygons.containsKey(p.polygonId))
          .map((p) => p.polygonId.value)
          .toList();

      if (polygonsToAdd.isNotEmpty ||
          polygonsToChange.isNotEmpty ||
          polygonIdsToRemove.isNotEmpty) {
        _channel!.invokeMethod('polygons/update', {
          'toAdd': polygonsToAdd.map((p) => p.toJson()).toList(),
          'toChange': polygonsToChange.map((p) => p.toJson()).toList(),
          'toRemove': polygonIdsToRemove,
        });
      }
    }
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('br.com.cpndntech.google_maps_plus/map_$id');
    _channel!.setMethodCallHandler(_handleMethodCall);
    _controller = GoogleMapsPlusPlaybackController._(id);

    // Se didUpdateWidget disparou antes do canal estar pronto (race condition
    // com dados assíncronos), os updates foram ignorados. Reenviar as
    // configurações atuais garante que o estado correto seja aplicado.
    _channel!.invokeMethod('updateOptions', {
      ...widget._getMapSettings().toJson(),
      ...widget._getPlaybackSettings().toJson(),
      'markers': widget.markers.map((e) => e.toJson()).toList(),
      'circles': widget.circles.map((e) => e.toJson()).toList(),
      'polylines': widget.polylines.map((e) => e.toJson()).toList(),
      'polygons': widget.polygons.map((e) => e.toJson()).toList(),
    });

    if (widget.onMapCreated != null) {
      widget.onMapCreated!(_controller!);
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onProgress':
        final index = call.arguments['index'];
        final double? doubleIndex = (index is num) ? index.toDouble() : null;
        if (doubleIndex != null) {
          widget.onProgress?.call(doubleIndex);
        }
        break;
      case 'onPlaybackStatusChanged':
        final status = call.arguments['status'];
        if (status is String) {
          widget.onPlaybackStatusChanged?.call(status);
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    const String viewType = 'br.com.cpndntech.google_maps_plus/playback';

    final Map<String, dynamic> creationParams = {
      ...widget._getMapSettings().toJson(),
      ...widget._getPlaybackSettings().toJson(),
    };
    if (widget.initialCameraPosition != null) {
      creationParams['initialCameraPosition'] = widget.initialCameraPosition!
          .toMap();
    }
    creationParams['markers'] = widget.markers.map((e) => e.toJson()).toList();
    creationParams['circles'] = widget.circles.map((e) => e.toJson()).toList();
    creationParams['polylines'] = widget.polylines
        .map((e) => e.toJson())
        .toList();
    creationParams['polygons'] = widget.polygons
        .map((e) => e.toJson())
        .toList();

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
      '$defaultTargetPlatform is not supported by the google_maps_plus plugin',
    );
  }
}

/// Controller for the [GoogleMapsPlusPlayback] widget.
/// Used to control the playback, zoom, and map settings.
class GoogleMapsPlusPlaybackController extends GoogleMapsPlusController {
  GoogleMapsPlusPlaybackController._(int id)
    : super._(MethodChannel('br.com.cpndntech.google_maps_plus/map_$id'));

  /// Starts or resumes the map playback.
  Future<void> play() async {
    await channel.invokeMethod('play');
  }

  /// Pauses the map playback.
  Future<void> pause() async {
    await channel.invokeMethod('pause');
  }

  /// Seeks to a specific point in the list.
  Future<void> seek(int index) async {
    await channel.invokeMethod('seek', {'index': index});
  }

  /// Gets the estimated exact duration of the animation.
  /// This takes into account the current `baseSpeed`, `playbackSpeed`, `showStops`,
  /// and the total distance between all points.
  Future<Duration> getPlaybackDuration() async {
    final double? seconds = await channel.invokeMethod('getPlaybackDuration');
    if (seconds == null) return Duration.zero;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// Zooms in on the map.
  Future<void> zoomIn() {
    return channel.invokeMethod('zoomIn');
  }

  /// Zooms out from the map.
  Future<void> zoomOut() {
    return channel.invokeMethod('zoomOut');
  }

  /// Sets the playback speed multiplier (e.g., 1, 2, 4).
  Future<void> setSpeed(int speed) async {
    await channel.invokeMethod('setSpeed', {'speed': speed});
  }

  /// Toggles the visibility of stop markers.
  Future<void> toggleStops(bool show) async {
    await channel.invokeMethod('toggleStops', {'show': show});
  }

  /// Sets the map type (1: Normal, 2: Satellite, 3: Terrain, 4: Hybrid).
  Future<void> setMapType(int mapType) async {
    await channel.invokeMethod('setMapType', {'mapType': mapType});
  }

  /// Enables or disables traffic display.
  Future<void> setTrafficEnabled(bool enabled) async {
    await channel.invokeMethod('setTrafficEnabled', {'enabled': enabled});
  }

  /// Updates the map style using a JSON string.
  Future<void> setMapStyle(String? style) async {
    await channel.invokeMethod('setMapStyle', {'style': style});
  }

  /// Toggles dark mode and optionally sets a custom style.
  Future<void> setDarkMode(bool isDark, {String? style}) async {
    await channel.invokeMethod('setDarkMode', {
      'isDark': isDark,
      'style': style,
    });
  }

  /// Adds multiple custom markers to the map.
  Future<void> addMarkers(Set<Marker> markers) async {
    await channel.invokeMethod('addMarkers', {
      'markers': markers.map((m) => m.toJson()).toList(),
    });
  }

  /// Clears all custom markers from the map.
  Future<void> clearMarkers() async {
    await channel.invokeMethod('clearMarkers');
  }

  /// Adds multiple custom circles (e.g. geofences) to the map.
  Future<void> addCircles(Set<Circle> circles) async {
    await channel.invokeMethod('addCircles', {
      'circles': circles.map((c) => c.toJson()).toList(),
    });
  }

  /// Clears all custom circles from the map.
  Future<void> clearCircles() async {
    await channel.invokeMethod('clearCircles');
  }

  /// Adds multiple custom polylines to the map.
  Future<void> addPolylines(Set<Polyline> polylines) async {
    await channel.invokeMethod('addPolylines', {
      'polylines': polylines.map((p) => p.toJson()).toList(),
    });
  }

  /// Clears all custom polylines from the map.
  Future<void> clearPolylines() async {
    await channel.invokeMethod('clearPolylines');
  }

  /// Adds multiple custom polygons to the map.
  Future<void> addPolygons(Set<Polygon> polygons) async {
    await channel.invokeMethod('addPolygons', {
      'polygons': polygons.map((p) => p.toJson()).toList(),
    });
  }

  /// Clears all custom polygons from the map.
  Future<void> clearPolygons() async {
    await channel.invokeMethod('clearPolygons');
  }

  /// Clears all custom shapes (markers, circles, polylines) from the map.
  Future<void> clearAllCustomShapes() async {
    await clearMarkers();
    await clearCircles();
    await clearPolylines();
  }

  /// Updates markers on the map using a diff-based approach.
  Future<void> updateMarkers(
    Set<Marker> markersToAdd,
    Set<Marker> markersToChange,
    Set<MarkerId> markerIdsToRemove,
  ) async {
    await channel.invokeMethod('markers/update', {
      'toAdd': markersToAdd.map((m) => m.toJson()).toList(),
      'toChange': markersToChange.map((m) => m.toJson()).toList(),
      'toRemove': markerIdsToRemove.map((m) => m.value).toList(),
    });
  }

  /// Updates polylines on the map using a diff-based approach.
  Future<void> updatePolylines(
    Set<Polyline> polylinesToAdd,
    Set<Polyline> polylinesToChange,
    Set<PolylineId> polylineIdsToRemove,
  ) async {
    await channel.invokeMethod('polylines/update', {
      'toAdd': polylinesToAdd.map((p) => p.toJson()).toList(),
      'toChange': polylinesToChange.map((p) => p.toJson()).toList(),
      'toRemove': polylineIdsToRemove.map((p) => p.value).toList(),
    });
  }

  /// Updates circles on the map using a diff-based approach.
  Future<void> updateCircles(
    Set<Circle> circlesToAdd,
    Set<Circle> circlesToChange,
    Set<CircleId> circleIdsToRemove,
  ) async {
    await channel.invokeMethod('circles/update', {
      'toAdd': circlesToAdd.map((c) => c.toJson()).toList(),
      'toChange': circlesToChange.map((c) => c.toJson()).toList(),
      'toRemove': circleIdsToRemove.map((c) => c.value).toList(),
    });
  }

  /// Updates polygons on the map using a diff-based approach.
  Future<void> updatePolygons(
    Set<Polygon> polygonsToAdd,
    Set<Polygon> polygonsToChange,
    Set<PolygonId> polygonIdsToRemove,
  ) async {
    await channel.invokeMethod('polygons/update', {
      'toAdd': polygonsToAdd.map((p) => p.toJson()).toList(),
      'toChange': polygonsToChange.map((p) => p.toJson()).toList(),
      'toRemove': polygonIdsToRemove.map((p) => p.value).toList(),
    });
  }
}
