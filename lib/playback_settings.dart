part of 'google_maps_plus.dart';

class _PlaybackSettings {
  final double baseSpeed;
  final bool canRotate;
  final bool dynamicRotation;
  final bool showStops;
  final Object? vehicleIcon;
  final Object? stopIcon;
  final bool drawTrail;
  final int? polylineColor;
  final List<dynamic>? points;
  final bool autoStart;

  _PlaybackSettings({
    this.baseSpeed = 60.0,
    this.canRotate = true,
    this.dynamicRotation = false,
    this.showStops = true,
    this.vehicleIcon,
    this.stopIcon,
    this.drawTrail = true,
    this.polylineColor,
    this.points,
    this.autoStart = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'baseSpeed': baseSpeed,
      'canRotate': canRotate,
      'dynamicRotation': dynamicRotation,
      'showStops': showStops,
      'vehicleIcon': vehicleIcon,
      'stopIcon': stopIcon,
      'drawTrail': drawTrail,
      'polylineColor': polylineColor,
      'points': points,
      'autoStart': autoStart,
    };
  }
}
