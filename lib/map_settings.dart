part of 'google_maps_plus.dart';

class _MapSettings {
  final MapType mapType;
  final bool showTraffic;
  final bool showBuildings;
  final bool showUserLocation;
  final bool showMyLocationButton;
  final bool compassEnabled;
  final bool mapToolbarEnabled;
  final bool rotateGesturesEnabled;
  final bool scrollGesturesEnabled;
  final bool zoomControlsEnabled;
  final bool zoomGesturesEnabled;
  final bool tiltGesturesEnabled;
  final bool indoorViewEnabled;
  final List<double>? padding;
  final double defaultSpeed;
  final double maxAnimationDuration;

  _MapSettings({
    this.mapType = MapType.normal,
    this.showTraffic = false,
    this.showBuildings = true,
    this.showUserLocation = false,
    this.showMyLocationButton = true,
    this.compassEnabled = true,
    this.mapToolbarEnabled = true,
    this.rotateGesturesEnabled = true,
    this.scrollGesturesEnabled = true,
    this.zoomControlsEnabled = true,
    this.zoomGesturesEnabled = true,
    this.tiltGesturesEnabled = true,
    this.indoorViewEnabled = false,
    this.padding,
    this.defaultSpeed = 60.0,
    this.maxAnimationDuration = 2000.0,
  });

  Map<String, dynamic> toJson() {
    return {
      'mapType': mapType.index,
      'showTraffic': showTraffic,
      'showBuildings': showBuildings,
      'showUserLocation': showUserLocation,
      'showMyLocationButton': showMyLocationButton,
      'compassEnabled': compassEnabled,
      'mapToolbarEnabled': mapToolbarEnabled,
      'rotateGesturesEnabled': rotateGesturesEnabled,
      'scrollGesturesEnabled': scrollGesturesEnabled,
      'zoomControlsEnabled': zoomControlsEnabled,
      'zoomGesturesEnabled': zoomGesturesEnabled,
      'tiltGesturesEnabled': tiltGesturesEnabled,
      'indoorViewEnabled': indoorViewEnabled,
      'padding': padding,
      'defaultSpeed': defaultSpeed,
      'maxAnimationDuration': maxAnimationDuration,
    };
  }
}
