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
            if playbackManager == nil { playbackManager = PlaybackManager(mapView: mapView, channel: channel, registrar: registrar) }
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
        case "resumeFromStop": pManager?.resumeFromStop(); result(nil)
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
    
    public func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
        if gesture {
            playbackManager?.followEnabled = false
            mapObjectsManager?.followEnabled = false
            followTimer?.invalidate()
        }
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
