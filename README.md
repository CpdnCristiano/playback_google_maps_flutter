# Google Maps Plus

A high-performance Flutter plugin for Google Maps with imperative control and advanced playback capabilities.

## Features

- **GoogleMapsPlus**: High-performance imperative map widget for real-time tracking and marker management.
- **GoogleMapsPlusPlayback**: Optimized route replay with smooth vehicle movement and trail rendering.
- **Smooth Vehicle Movement**: Optimized native animations for vehicle icons across Android and iOS.
- **Interaction Friendly**: Intelligent "Follow Vehicle" logic that suspends when the user interacts with the map and resumes automatically.
- **Highly Customizable**: Custom icons, markers, polygons, circles, and map styles.

## Installation

Add the following to your `pubspec.yaml`:

```yaml
dependencies:
  google_maps_plus:
    git:
      url: https://github.com/CpdnCristiano/playback_google_maps_flutter.git
      ref: main
```

## Basic Usage

### GoogleMapsPlus (Imperative Control)

```dart
GoogleMapsPlus(
  initialCameraPosition: CameraPosition(target: LatLng(0,0), zoom: 10),
  onMapCreated: (controller) {
    // Imperative control
    controller.animateCamera(CameraUpdate.newLatLng(LatLng(-23.5, -46.6)));
    controller.moveMarker('vehicle_1', LatLng(-23.5, -46.6), rotation: 90);
  },
)
```

### GoogleMapsPlusPlayback (Route Replay)

```dart
GoogleMapsPlusPlayback(
  points: myPlaybackPoints,
  vehicleIcon: vehicleIconBytes,
  polylineColor: Colors.blue,
  onMapCreated: (controller) {
    controller.play();
  },
)
```

## Platform Setup

### Android
Ensure you have your Google Maps API Key in `AndroidManifest.xml`:

```xml
<meta-data
    android:name="com.google.android.geo.API_KEY"
    android:value="YOUR_API_KEY_HERE"/>
```

### iOS
Add your Google Maps API Key in your `AppDelegate.swift`:

```swift
import GoogleMaps

GMSServices.provideAPIKey("YOUR_API_KEY_HERE")
```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## License
[MIT](https://choosealicense.com/licenses/mit/)
