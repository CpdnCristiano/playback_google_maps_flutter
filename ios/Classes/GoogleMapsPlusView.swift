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
        
        updateMapSettings()
        
        manager.defaultSpeed = mapSettings.defaultSpeed
        manager.maxAnimationDuration = mapSettings.maxAnimationDuration
        
        // Limpa objetos antigos e adiciona novos de forma atômica
        manager.setupInitialObjects(
            markers: mapSettings.initialMarkers,
            circles: mapSettings.initialCircles,
            polylines: mapSettings.initialPolylines,
            polygons: mapSettings.initialPolygons
        )
        
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
    
    private func updateMapSettings() {
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
    }
    
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let manager = mapObjectsManager
        let pManager = playbackManager
        let args = call.arguments as? [String: Any]
        
        switch call.method {
        case MethodNames.updateOptions:
            let oldPoints = playbackSettings.points
            mapSettings = Convert.toMapSettings(args)
            playbackSettings = Convert.toPlaybackSettings(args)
            let newPoints = playbackSettings.points
            
            // Verifica se os pontos realmente mudaram (conteúdo, não referência)
            let pointsChanged: Bool
            switch (oldPoints, newPoints) {
            case (nil, nil):
                pointsChanged = false
            case (nil, _), (_, nil):
                pointsChanged = true
            case let (old?, new?):
                // Compara tamanho primeiro, depois conteúdo via string
                pointsChanged = (old.count != new.count) || ("\(old)" != "\(new)")
            }
            
            // Se os pontos mudaram, reinicia o playback
            if pointsChanged {
                pManager?.playbackSettings = playbackSettings
                setupMap() // Reinicia tudo incluindo setupInitialState
            } else {
                // Se só mudaram configurações do mapa, apenas atualiza sem resetar
                pManager?.playbackSettings = playbackSettings
                updateMapSettings()
            }
            result(nil)
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
        case "marker_icon":
            if let id = args?["id"] as? String {
                let iconData = args?["icon"] ?? args?["bytes"]
                if let data = iconData {
                    manager?.updateMarkerIcon(id: id, iconData: data)
                }
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
        
        // Map configuration methods
        case "setMapStyle":
            if let style = args?["style"] as? String {
                do {
                    mapView.mapStyle = try GMSMapStyle(jsonString: style)
                } catch {
                    print("Map style error: \(error)")
                }
            } else {
                mapView.mapStyle = nil
            }
            result(nil)
        case "setMapType":
            if let mapType = args?["mapType"] as? Int {
                mapView.mapType = GMSMapViewType(rawValue: UInt(mapType)) ?? .normal
            }
            result(nil)
        case "setTrafficEnabled":
            mapView.isTrafficEnabled = args?["enabled"] as? Bool ?? false
            result(nil)
        case "setMyLocationEnabled":
            mapView.isMyLocationEnabled = args?["enabled"] as? Bool ?? false
            result(nil)
        case "getZoomLevel":
            result(Double(mapView.camera.zoom))
        case "getVisibleRegion":
            let bounds = GMSCoordinateBounds(region: mapView.projection.visibleRegion())
            result([
                "swLat": bounds.southWest.latitude,
                "swLng": bounds.southWest.longitude,
                "neLat": bounds.northEast.latitude,
                "neLng": bounds.northEast.longitude
            ])
        case "getScreenCoordinate":
            if let lat = args?["lat"] as? Double, let lng = args?["lng"] as? Double {
                let point = mapView.projection.point(for: CLLocationCoordinate2D(latitude: lat, longitude: lng))
                result(["x": Int(point.x), "y": Int(point.y)])
            } else {
                result(FlutterError(code: "ERROR", message: "Invalid arguments", details: nil))
            }
        case "getLatLng":
            if let x = args?["x"] as? Int, let y = args?["y"] as? Int {
                let coord = mapView.projection.coordinate(for: CGPoint(x: x, y: y))
                result(["lat": coord.latitude, "lng": coord.longitude])
            } else {
                result(FlutterError(code: "ERROR", message: "Invalid arguments", details: nil))
            }
        case "takeSnapshot":
            UIGraphicsBeginImageContextWithOptions(mapView.bounds.size, true, 0)
            mapView.layer.render(in: UIGraphicsGetCurrentContext()!)
            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            result(image?.pngData())
        case "marker_show_info_window":
            if let id = args?["id"] as? String {
                manager?.showInfoWindow(id: id)
            }
            result(nil)
        case "marker_hide_info_window":
            if let id = args?["id"] as? String {
                manager?.hideInfoWindow(id: id)
            }
            result(nil)
        case "marker_is_info_window_shown":
            if let id = args?["id"] as? String {
                result(manager?.isInfoWindowShown(id: id) ?? false)
            } else {
                result(false)
            }
            
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
