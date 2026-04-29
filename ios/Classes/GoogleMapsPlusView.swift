import Flutter
import UIKit
import GoogleMaps

public class GoogleMapsPlusView: NSObject, FlutterPlatformView, GMSMapViewDelegate {
    private let mapView: GMSMapView
    private let channel: FlutterMethodChannel
    private let registrar: FlutterPluginRegistrar
    
    private var mapObjectsManager: MapObjectsManager?
    private var playbackManager: PlaybackManager?
    
    private var mapSettings: MapSettings
    private var playbackSettings: PlaybackSettings
    
    private var followTimer: Timer? = nil
    private let isPlaybackMode: Bool

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        registrar: FlutterPluginRegistrar,
        isPlaybackMode: Bool = false
    ) {
        self.mapView = GMSMapView(frame: frame)
        self.registrar = registrar
        self.isPlaybackMode = isPlaybackMode
        self.channel = FlutterMethodChannel(
            name: "br.com.cpndntech.google_maps_plus/map_\(viewId)",
            binaryMessenger: registrar.messenger()
        )
        self.mapSettings = Convert.toMapSettings(args)
        self.playbackSettings = Convert.toPlaybackSettings(args)
        
        super.init()
        
        self.mapView.delegate = self
        self.channel.setMethodCallHandler(self.handle)
        
        setupMap()
    }
    
    public func view() -> UIView { return mapView }
    
    private func setupMap() {
        if mapObjectsManager == nil { mapObjectsManager = MapObjectsManager(mapView: mapView, registrar: registrar) }
        guard let manager = mapObjectsManager else { return }
        
        switch mapSettings.mapType {
        case 1: mapView.mapType = .normal
        case 2: mapView.mapType = .satellite
        case 3: mapView.mapType = .terrain
        case 4: mapView.mapType = .hybrid
        default: mapView.mapType = .normal
        }
        
        mapView.mapStyle = mapSettings.isDark ? try? GMSMapStyle(jsonString: mapSettings.style ?? "") : nil
        mapView.isTrafficEnabled = mapSettings.showTraffic
        mapView.isBuildingsEnabled = mapSettings.showBuildings
        mapView.isMyLocationEnabled = mapSettings.showUserLocation
        
        if let p = mapSettings.padding, p.count == 4 {
            mapView.padding = UIEdgeInsets(top: CGFloat(p[0]), left: CGFloat(p[1]), bottom: CGFloat(p[2]), right: CGFloat(p[3]))
        }
        
        let ui = mapView.settings
        ui.myLocationButton = mapSettings.showMyLocationButton
        ui.compassButton = mapSettings.compassEnabled
        ui.rotateGestures = mapSettings.rotateGesturesEnabled
        ui.scrollGestures = mapSettings.scrollGesturesEnabled
        ui.zoomGestures = mapSettings.zoomGesturesEnabled
        ui.tiltGestures = mapSettings.tiltGesturesEnabled
        
        manager.defaultSpeed = mapSettings.defaultSpeed
        manager.maxAnimationDuration = mapSettings.maxAnimationDuration
        
        if let markers = mapSettings.initialMarkers { manager.setAllMarkers(markers) }
        if let circles = mapSettings.initialCircles { circles.forEach { manager.addCircle($0) } }
        if let polylines = mapSettings.initialPolylines { polylines.forEach { manager.addPolyline($0) } }
        if let polygons = mapSettings.initialPolygons { polygons.forEach { manager.addPolygon($0) } }
        
        if isPlaybackMode || playbackSettings.points != nil {
            if playbackManager == nil { playbackManager = PlaybackManager(mapView: mapView, channel: channel) }
            guard let pManager = playbackManager else { return }
            pManager.playbackSettings = playbackSettings
            
            if let ptsData = playbackSettings.points {
                let pts = ptsData.map {
                    GoogleMapsPlaybackPoint(
                        lat: $0["lat"] as? Double ?? 0.0,
                        lng: $0["lng"] as? Double ?? 0.0,
                        bearing: $0["bearing"] as? Double ?? 0.0,
                        isStop: $0["isStop"] as? Bool ?? false
                    )
                }
                pManager.setPoints(pts)
            }
            pManager.setupInitialState()
        } else {
            let initialCamera = (Convert.toMapSettings(nil)).initialMarkers // dummy call just to get structure if needed
            // Use creationParams equivalent if available
            // In setupMap we usually move to initial camera if not in playback
        }
    }
    
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let manager = mapObjectsManager
        let pManager = playbackManager
        let args = call.arguments as? [String: Any]
        
        switch call.method {
        case MethodNames.updateOptions:
            mapSettings = Convert.toMapSettings(args)
            playbackSettings = Convert.toPlaybackSettings(args)
            pManager?.playbackSettings = playbackSettings
            setupMap(); result(nil)
        case "play": pManager?.play(); result(nil)
        case "pause": pManager?.pause(); result(nil)
        case "seek": pManager?.seekTo(args?["index"] as? Int ?? 0); result(nil)
        case "setSpeed": pManager?.setSpeed(args?["speed"] as? Int ?? 1); result(nil)
        case MethodNames.markersUpdate: manager?.applyMarkerUpdates(Convert.toMarkerUpdates(call.arguments)); result(nil)
        case MethodNames.polylinesUpdate: manager?.applyPolylineUpdates(Convert.toPolylineUpdates(call.arguments)); result(nil)
        case MethodNames.circlesUpdate: manager?.applyCircleUpdates(Convert.toCircleUpdates(call.arguments)); result(nil)
        case MethodNames.polygonsUpdate: manager?.applyPolygonUpdates(Convert.toPolygonUpdates(call.arguments)); result(nil)
        case MethodNames.markerAdd: if let data = args?["marker"] as? [String: Any] { manager?.addMarker(data) }; result(nil)
        case MethodNames.markerMove:
            if let id = args?["id"] as? String, let lat = args?["lat"] as? Double, let lng = args?["lng"] as? Double {
                manager?.moveMarker(id: id, lat: lat, lng: lng, rotation: args?["rotation"] as? Double ?? 0.0)
            }
            result(nil)
        case MethodNames.followMarker: 
            manager?.followedMarkerId = args?["id"] as? String
            manager?.followEnabled = true
            result(nil)
        case MethodNames.zoomIn: mapView.animate(with: GMSCameraUpdate.zoomIn()); result(nil)
        case MethodNames.zoomOut: mapView.animate(with: GMSCameraUpdate.zoomOut()); result(nil)
        case MethodNames.moveCamera:
            if let lat = args?["lat"] as? Double, let lng = args?["lng"] as? Double {
                mapView.animate(to: GMSCameraPosition.camera(withTarget: CLLocationCoordinate2D(latitude: lat, longitude: lng), zoom: args?["zoom"] as? Float ?? 10))
            }
            result(nil)
        case "move_camera_instant":
            if let lat = args?["lat"] as? Double, let lng = args?["lng"] as? Double {
                mapView.camera = GMSCameraPosition.camera(withTarget: CLLocationCoordinate2D(latitude: lat, longitude: lng), zoom: args?["zoom"] as? Float ?? 10)
            }
            result(nil)
        case "map_get_zoom": result(mapView.camera.zoom)
        case "map_get_bounds":
            let bounds = GMSCoordinateBounds(region: mapView.projection.visibleRegion())
            result([
                "southwest": [bounds.southWest.latitude, bounds.southWest.longitude],
                "northeast": [bounds.northEast.latitude, bounds.northEast.longitude]
            ])
        case "map_get_screen_coordinate":
            if let lat = args?["lat"] as? Double, let lng = args?["lng"] as? Double {
                let point = mapView.projection.point(for: CLLocationCoordinate2D(latitude: lat, longitude: lng))
                result(["x": Double(point.x), "y": Double(point.y)])
            } else { result(nil) }
        case "map_get_latlng":
            if let x = args?["x"] as? Double, let y = args?["y"] as? Double {
                let coord = mapView.projection.coordinate(for: CGPoint(x: x, y: y))
                result(["lat": coord.latitude, "lng": coord.longitude])
            } else { result(nil) }
        case "map_take_snapshot":
            UIGraphicsBeginImageContextWithOptions(mapView.bounds.size, true, 0)
            mapView.drawHierarchy(in: mapView.bounds, afterScreenUpdates: true)
            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            if let data = image?.pngData() { result(FlutterStandardTypedData(bytes: data)) }
            else { result(nil) }
        case "marker_show_info_window":
            if let id = args?["id"] as? String { manager?.showMarkerInfoWindow(id: id) }
            result(nil)
        case "marker_hide_info_window":
            if let id = args?["id"] as? String { manager?.hideMarkerInfoWindow(id: id) }
            result(nil)
        case "marker_is_info_window_shown":
            if let id = args?["id"] as? String { result(manager?.isMarkerInfoWindowShown(id: id) ?? false) }
            else { result(false) }
        default: result(FlutterMethodNotImplemented)
        }
    }
    
    public func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
        if let id = marker.userData as? String {
            if id.hasPrefix("stop_"), let idx = Int(id.replacingOccurrences(of: "stop_", with: "")) {
                playbackManager?.seekTo(idx)
                channel.invokeMethod("onStopClick", arguments: ["index": idx])
                return true
            }
            channel.invokeMethod("onMarkerTap", arguments: ["id": id])
        }
        return true
    }
    
    public func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
        channel.invokeMethod("onMapTap", arguments: ["lat": coordinate.latitude, "lng": coordinate.longitude])
    }
    
    public func mapView(_ mapView: GMSMapView, didLongPressAt coordinate: CLLocationCoordinate2D) {
        channel.invokeMethod("onMapLongPress", arguments: ["lat": coordinate.latitude, "lng": coordinate.longitude])
    }
    
    public func mapView(_ mapView: GMSMapView, didStartCameraPosition position: GMSCameraPosition) {
        channel.invokeMethod("onCameraMoveStarted", arguments: ["reason": 1]) // 1 for GESTURE (simplified)
    }
    
    public func mapView(_ mapView: GMSMapView, didChange position: GMSCameraPosition) {
        channel.invokeMethod("onCameraMove", arguments: [
            "position": [
                "target": [position.target.latitude, position.target.longitude],
                "zoom": position.zoom,
                "tilt": position.viewingAngle,
                "bearing": position.bearing
            ]
        ])
    }
    
    public func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            self.playbackManager?.followEnabled = true
            self.mapObjectsManager?.followEnabled = true
        }
        channel.invokeMethod("onCameraIdle", arguments: nil)
    }
}
