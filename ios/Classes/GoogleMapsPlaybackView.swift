import Flutter
import UIKit
import GoogleMaps
import CoreLocation

public class GoogleMapsPlaybackView: NSObject, FlutterPlatformView, GMSMapViewDelegate {
    private let mapView: GMSMapView
    private let channel: FlutterMethodChannel
    
    private var points: [GoogleMapsPlaybackPoint] = []
    private var cumulativeDistances: [Double] = []
    private var totalDistance: Double = 0.0
    
    private var showStops: Bool = false
    private var initialMapType: GMSMapViewType = .normal
    private var isTrafficEnabled: Bool = false
    private var isDarkMode: Bool = false
    private var initialStyle: String? = nil
    private var isPlaying: Bool = false
    private var followVehicle: Bool = true
    private var isAnimatingCamera: Bool = false
    private var playbackSpeed: Int = 1
    private var followTimer: Timer?
    private var canRotate: Bool = true
    private var baseSpeed: Double = 60.0
    
    private var vehicleMarker: GMSMarker?
    private var progressPolyline: GMSPolyline?
    private var stopMarkers: [Int: GMSMarker] = [:]
    
    private var currentGlobalDistance: Double = 0.0
    private var lastStopIndexPassed: Int = -1
    private var isPausedForStop: Bool = false
    
    private var trailPath = GMSMutablePath()
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    
    private var stopIcon: UIImage?
    private var vehicleIconNormal: UIImage?
    private var vehicleIconFlipped: UIImage?
    private var polylineColor: UIColor = .blue
    
    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        self.mapView = GMSMapView(frame: frame)
        self.channel = FlutterMethodChannel(
            name: "br.com.cpndntech.google_maps_playback/playback_\(viewId)",
            binaryMessenger: messenger
        )
        
        super.init()
        
        self.mapView.delegate = self
        self.channel.setMethodCallHandler(self.handle)
        
        if let params = args as? [String: Any] {
            parseParams(params)
        }
        
        setupMap()
    }
    
    deinit {
        displayLink?.invalidate()
        displayLink = nil
        followTimer?.invalidate()
        followTimer = nil
        mapView.clear()
        channel.setMethodCallHandler(nil)
    }
    
    public func view() -> UIView {
        return mapView
    }
    
    private func parseParams(_ params: [String: Any]) {
        if let rawPoints = params["points"] as? [[String: Any]] {
            var pts: [GoogleMapsPlaybackPoint] = []
            for (index, dict) in rawPoints.enumerated() {
                pts.append(GoogleMapsPlaybackPoint(
                    lat: dict["lat"] as? Double ?? 0.0,
                    lng: dict["lng"] as? Double ?? 0.0,
                    bearing: dict["bearing"] as? Double ?? 0.0,
                    isStop: dict["isStop"] as? Bool ?? false
                ))
            }
            self.points = pts
        }
        
        calculateDistances()
        
        self.showStops = params["showStops"] as? Bool ?? false
        
        if let vehicleBytes = params["vehicleIcon"] as? FlutterStandardTypedData {
            let screenScale = UIScreen.main.scale
            if let image = UIImage(data: vehicleBytes.data, scale: screenScale) {
                self.vehicleIconNormal = image
                self.vehicleIconFlipped = flipImage(image)
            }
        }
        
        if let stopBytes = params["stopIcon"] as? FlutterStandardTypedData {
            let screenScale = UIScreen.main.scale
            if let image = UIImage(data: stopBytes.data, scale: screenScale) {
                self.stopIcon = image
            }
        }
        
        let mapTypeInt = params["mapType"] as? Int ?? 1
        switch mapTypeInt {
        case 0: self.initialMapType = .none
        case 1: self.initialMapType = .normal
        case 2: self.initialMapType = .satellite
        case 3: self.initialMapType = .terrain
        case 4: self.initialMapType = .hybrid
        default: self.initialMapType = .normal
        }
        
        self.isTrafficEnabled = params["showTraffic"] as? Bool ?? false
        self.isDarkMode = params["isDark"] as? Bool ?? false
        self.initialStyle = params["style"] as? String
        self.canRotate = params["canRotate"] as? Bool ?? true
        self.baseSpeed = params["baseSpeed"] as? Double ?? 60.0
        
        if let colorHex = params["polylineColor"] as? String {
            self.polylineColor = hexToColor(colorHex)
        }
    }
    
    private func calculateDistances() {
        cumulativeDistances.removeAll()
        totalDistance = 0.0
        cumulativeDistances.append(0.0)
        
        for i in 0..<max(0, points.count - 1) {
            let p1 = points[i]
            let p2 = points[i+1]
            let loc1 = CLLocation(latitude: p1.lat, longitude: p1.lng)
            let loc2 = CLLocation(latitude: p2.lat, longitude: p2.lng)
            let dist = loc1.distance(from: loc2)
            totalDistance += dist
            cumulativeDistances.append(totalDistance)
        }
    }
    
    public func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
        if gesture {
            followVehicle = false
            followTimer?.invalidate()
            followTimer = nil
        }
    }
    
    public func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
        if !followVehicle {
            followTimer?.invalidate()
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.followVehicle = true
            }
        }
    }
    
    private func setupMap() {
        mapView.mapType = initialMapType
        mapView.isTrafficEnabled = isTrafficEnabled
        
        // Habilita gestos de interação
        mapView.settings.zoomGestures = true
        mapView.settings.scrollGestures = true
        mapView.settings.tiltGestures = true
        mapView.settings.rotateGestures = true
        
        // Reseta qualquer ângulo ou rotação anterior
        mapView.animate(toBearing: 0)
        mapView.animate(toViewingAngle: 0)
        
        if isDarkMode {
            if let styleStr = initialStyle {
                mapView.mapStyle = try? GMSMapStyle(jsonString: styleStr)
            }
        }
        
        guard !points.isEmpty else { return }
        
        let first = points[0]
        let firstPos = CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng)
        mapView.camera = GMSCameraPosition.camera(withTarget: firstPos, zoom: 16)
        
        let marker = GMSMarker(position: firstPos)
        marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
        marker.isFlat = true
        marker.rotation = canRotate ? first.bearing : 0
        
        if canRotate {
            marker.icon = vehicleIconNormal
        } else {
            let isGoingLeft = first.bearing > 180
            marker.icon = isGoingLeft ? vehicleIconNormal : vehicleIconFlipped
        }
        
        marker.zIndex = 10 // Veículo sempre no topo
        marker.map = mapView
        self.vehicleMarker = marker
        
        let path = GMSMutablePath()
        let polyline = GMSPolyline(path: path)
        polyline.strokeColor = polylineColor
        polyline.strokeWidth = 6.0
        polyline.zIndex = 2 // Rastro abaixo do veículo
        polyline.map = mapView
        self.progressPolyline = polyline
        
        mapView.delegate = self // Escuta cliques
        
        if showStops { renderStops() }
    }
    
    // MARK: - GMSMapViewDelegate
    public func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
        if let index = marker.userData as? Int {
            seek(to: index)
            channel.invokeMethod("onStopClick", arguments: ["index": index])
        }
        return true
    }
    
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "play":
            if !isPlaying { startAnimation() }
            channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "playing"])
            result(nil)
        case "pause":
            pauseAnimation()
            channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "paused"])
            result(nil)
        case "seek":
            if let args = call.arguments as? [String: Any], let index = args["index"] as? Int {
                seek(to: index)
            }
            result(nil)
        case "zoomIn":
            isAnimatingCamera = true
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                self?.isAnimatingCamera = false
            }
            mapView.animate(toZoom: mapView.camera.zoom + 1)
            CATransaction.commit()
            result(nil)
        case "zoomOut":
            isAnimatingCamera = true
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                self?.isAnimatingCamera = false
            }
            mapView.animate(toZoom: mapView.camera.zoom - 1)
            CATransaction.commit()
            result(nil)
        case "setSpeed":
            if let args = call.arguments as? [String: Any], let speed = args["speed"] as? Int {
                playbackSpeed = speed
                if isPlaying {
                    pauseAnimation()
                    startAnimation()
                }
            }
            result(nil)
        case "toggleStops":
            if let args = call.arguments as? [String: Any], let show = args["show"] as? Bool {
                showStops = show
                if showStops { renderStops() } else { clearStops() }
            }
            result(nil)
        case "setMapType":
             if let args = call.arguments as? [String: Any], let typeInt = args["mapType"] as? Int {
                 switch typeInt {
                 case 0: mapView.mapType = .none
                 case 1: mapView.mapType = .normal
                 case 2: mapView.mapType = .satellite
                 case 3: mapView.mapType = .terrain
                 case 4: mapView.mapType = .hybrid
                 default: mapView.mapType = .normal
                 }
             }
             result(nil)
        case "setTrafficEnabled":
            if let args = call.arguments as? [String: Any], let enabled = args["enabled"] as? Bool {
                mapView.isTrafficEnabled = enabled
            }
            result(nil)
        case "setMapStyle":
            if let args = call.arguments as? [String: Any], let style = args["style"] as? String {
                mapView.mapStyle = try? GMSMapStyle(jsonString: style)
            } else {
                mapView.mapStyle = nil
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func startAnimation() {
        guard totalDistance > 0 else { return }
        
        if currentGlobalDistance >= totalDistance {
            currentGlobalDistance = 0
        }
        
        isPlaying = true
        lastFrameTime = CACurrentMediaTime()
        
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(animationStep))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func pauseAnimation() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func animationStep(displayLink: CADisplayLink) {
        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastFrameTime
        lastFrameTime = currentTime
        
        // Velocidade base (vinda do Flutter)
        let frameDistance = deltaTime * baseSpeed * Double(playbackSpeed)
        
        currentGlobalDistance += frameDistance
        
        if currentGlobalDistance >= totalDistance {
            currentGlobalDistance = totalDistance
            updateVehiclePosition(distance: currentGlobalDistance)
            pauseAnimation()
            channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "finished"])
            return
        }
        
        updateVehiclePosition(distance: currentGlobalDistance)
        
        // Progresso virtual (index + localT) para compatibilidade com o Flutter
        let idx = getSegmentIndexForDistance(currentGlobalDistance)
        let segmentStartDist = cumulativeDistances[idx]
        let segmentEndDist = cumulativeDistances[idx + 1]
        let localT = (currentGlobalDistance - segmentStartDist) / (segmentEndDist - segmentStartDist)
        
        channel.invokeMethod("onProgress", arguments: ["index": Double(idx) + localT])
    }
    
    private func updateVehiclePosition(distance: Double) {
        guard points.count >= 2 else { return }
        
        let idx = getSegmentIndexForDistance(distance)
        
        if showStops {
            for i in 0...idx {
                checkAndAddStop(at: i)
            }
        }
        
        let start = points[idx]
        let end = points[idx + 1]
        
        let segmentStartDist = cumulativeDistances[idx]
        let segmentEndDist = cumulativeDistances[idx + 1]
        let t = Float((distance - segmentStartDist) / (segmentEndDist - segmentStartDist)).clamped(to: 0...1)
        
        let lat = start.lat + (end.lat - start.lat) * Double(t)
        let lng = start.lng + (end.lng - start.lng) * Double(t)
        let pos = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        
        var delta = Float(end.bearing - start.bearing)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let rotation = Float(start.bearing) + delta * t
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vehicleMarker?.position = pos
        CATransaction.commit()
        
        if canRotate {
            vehicleMarker?.rotation = CLLocationDegrees(rotation)
        } else {
            let isGoingLeft = rotation > 180
            vehicleMarker?.icon = isGoingLeft ? vehicleIconNormal : vehicleIconFlipped
        }
        
        if followVehicle && !isAnimatingCamera {
            mapView.animate(with: GMSCameraUpdate.setTarget(pos))
        }

        // Atualiza Rastro (Simples e funcional)
        trailPath.add(pos)
        progressPolyline?.path = trailPath

        // Lógica de Pausa nos Stops (AGORA NO FINAL)
        if showStops && points[idx].isStop && idx != lastStopIndexPassed && !isPausedForStop {
            lastStopIndexPassed = idx
            pauseForStop()
        }
    }

    private func pauseForStop() {
        isPausedForStop = true
        displayLink?.isPaused = true
        
        // 2 segundos base, dividido pela velocidade
        let pauseTime = max(0.1, 2.0 / Double(playbackSpeed))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + pauseTime) { [weak self] in
            guard let self = self else { return }
            self.isPausedForStop = false
            self.displayLink?.isPaused = false
            self.lastFrameTime = CACurrentMediaTime()
        }
    }
    
    private func getSegmentIndexForDistance(_ distance: Double) -> Int {
        if distance <= 0 { return 0 }
        if distance >= totalDistance { return max(0, points.count - 2) }
        
        for i in 0..<max(0, cumulativeDistances.count - 1) {
            if distance < cumulativeDistances[i + 1] {
                return i
            }
        }
        return max(0, points.count - 2)
    }
    
    private func seek(to index: Int) {
        pauseAnimation()
        let safeIndex = max(0, min(index, points.count - 1))
        currentGlobalDistance = cumulativeDistances[safeIndex]
        
        let p = points[safeIndex]
        let pos = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
        
        updateProgressTrail(upTo: pos, at: safeIndex)
        if showStops { renderStops() }
        
        vehicleMarker?.position = pos
        vehicleMarker?.rotation = canRotate ? p.bearing : 0
        
        followVehicle = true
        mapView.moveCamera(GMSCameraUpdate.setTarget(pos))
        
        channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "paused"])
        channel.invokeMethod("onProgress", arguments: ["index": Double(safeIndex)])
    }
    
    private func updateProgressTrail(upTo currentPos: CLLocationCoordinate2D, at index: Int) {
        // Método para reconstrução total (usado no seek)
        trailPath = GMSMutablePath()
        for i in 0..<index {
            trailPath.add(CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng))
        }
        trailPath.add(currentPos)
        progressPolyline?.path = trailPath
    }
    
    private func checkAndAddStop(at index: Int) {
        if points[index].isStop && stopMarkers[index] == nil {
            let p = points[index]
            let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng))
            marker.icon = stopIcon
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.userData = index
            marker.zIndex = 5 // Abaixo do veículo (10)
            marker.map = mapView
            stopMarkers[index] = marker
        }
    }
    
    private func renderStops() {
        clearStops() // Limpa para reconstruir o estado correto no Seek/Toggle
        let currentIdx = getSegmentIndexForDistance(currentGlobalDistance)
        
        // Adiciona apenas o que falta
        for i in 0...currentIdx {
            if points[i].isStop {
                checkAndAddStop(at: i)
            }
        }
    }
    
    private func clearStops() {
        for marker in stopMarkers.values {
            marker.map = nil
        }
        stopMarkers.removeAll()
    }
    
    private func flipImage(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(x: image.size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
    
    private func hexToColor(_ hex: String) -> UIColor {
        var cString:String = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if (cString.hasPrefix("#")) { cString.remove(at: cString.startIndex) }
        if ((cString.count) != 6) { return UIColor.gray }
        var rgbValue:UInt64 = 0
        Scanner(string: cString).scanHexInt64(&rgbValue)
        return UIColor(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: CGFloat(1.0)
        )
    }
}

struct GoogleMapsPlaybackPoint {
    let lat: Double
    let lng: Double
    let bearing: Double
    let isStop: Bool
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}
