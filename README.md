# Google Maps Playback

A high-performance Flutter plugin for replaying vehicle routes on Google Maps with smooth animations and trail rendering.

## Features

- **Smooth Vehicle Movement**: Optimized native animations for vehicle icons across Android and iOS.
- **Dynamic Trail Rendering**: Automatically draws the vehicle's path as it moves.
- **Stop Indicators**: Display stop markers along the route with configurable icons.
- **Playback Controls**: Play, pause, seek, and adjust playback speed (1x, 2x, 4x, etc.).
- **Interaction Friendly**: Intelligent "Follow Vehicle" logic that suspends when the user interacts with the map (gestures/zoom) and resumes automatically.
- **Highly Customizable**: Custom icons for vehicles (normal and flipped), stop signs, polyline colors, and map styles.

## Installation

Add the following to your `pubspec.yaml`:

```yaml
dependencies:
  google_maps_playback:
    git:
      url: https://github.com/CpdnCristiano/playback_google_maps_flutter.git
      ref: main
```

## Basic Usage

### Initialize the Controller

```dart
final controller = GoogleMapsPlaybackController();

// To play
controller.play();

// To pause
controller.pause();

// To seek to a specific point
controller.seek(10); // Index of the point

// To change speed
controller.setSpeed(2); // 2x speed
```

### Add the Widget to your UI

```dart
GoogleMapsPlayback(
  points: myPlaybackPoints, // List<GoogleMapsPlaybackPoint>
  controller: controller,
  vehicleIcon: vehicleIconBytes,
  stopIcon: stopIconBytes,
  polylineColor: Colors.blue,
  showStops: true,
  onProgress: (progress) {
    print("Playback progress: $progress");
  },
  onStopClick: (index) {
    print("Stop clicked at index: $index");
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
