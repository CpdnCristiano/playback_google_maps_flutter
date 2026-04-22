import Foundation
import GoogleMaps
import Flutter

class PlaybackManager: NSObject {
    private let mapView: GMSMapView
    private let channel: FlutterMethodChannel
    
    var playbackSettings = PlaybackSettings(
        baseSpeed: 60.0,
        canRotate: true,
        dynamicRotation: false,
        showStops: false,
        vehicleIcon: nil,
        stopIcon: nil,
        drawTrail: true,
        polylineColor: nil,
        points: nil,
        autoStart: false
    )
    
    private var points: [GoogleMapsPlaybackPoint] = []
    private var cumulativeDistances: [Double] = []
    private var totalDistance: Double = 0.0
    
    private var vehicleMarker: GMSMarker?
    private var progressPolyline: GMSPolyline?
    private var stopMarkers: [Int: GMSMarker] = [:]
    
    private var currentGlobalDistance: Double = 0.0
    private var playbackSpeed: Int = 1
    var isPlaying: Bool = false
    private var isPausedForStop: Bool = false
    
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var distanceAtStartOfAnimation: Double = 0
    
    var followEnabled: Bool = true

    init(mapView: GMSMapView, channel: FlutterMethodChannel) {
        self.mapView = mapView
        self.channel = channel
    }

    func setPoints(_ newPoints: [GoogleMapsPlaybackPoint]) {
        self.points = newPoints
        calculateDistances()
        reset()
    }

    private func calculateDistances() {
        cumulativeDistances.removeAll()
        totalDistance = 0.0
        cumulativeDistances.append(0.0)
        for i in 0..<(points.count - 1) {
            let dist = CLLocation(latitude: points[i].lat, longitude: points[i].lng).distance(from: CLLocation(latitude: points[i+1].lat, longitude: points[i+1].lng))
            totalDistance += dist
            cumulativeDistances.append(totalDistance)
        }
    }

    func setupInitialState() {
        if points.isEmpty { return }
        
        let firstPos = CLLocationCoordinate2D(latitude: points[0].lat, longitude: points[0].lng)
        
        vehicleMarker?.map = nil
        let marker = GMSMarker(position: firstPos)
        marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
        marker.isFlat = true
        marker.zIndex = 10
        marker.map = mapView
        marker.icon = Convert.toIcon(playbackSettings.vehicleIcon) ?? GMSMarker.markerImage(with: .cyan)
        vehicleMarker = marker

        progressPolyline?.map = nil
        if playbackSettings.drawTrail {
            let poly = GMSPolyline()
            poly.strokeWidth = 6
            poly.strokeColor = Convert.toColor(playbackSettings.polylineColor)
            poly.geodesic = true
            poly.zIndex = 2
            poly.map = mapView
            progressPolyline = poly
        }

        if playbackSettings.showStops { renderStops() }
        
        mapView.animate(to: GMSCameraPosition.camera(withTarget: firstPos, zoom: 16))
        
        if playbackSettings.autoStart {
            play()
        }
    }

    func play() {
        if totalDistance <= 0 || isPlaying { return }
        isPlaying = true
        startAnimation()
        channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "playing"])
    }

    private func startAnimation() {
        stopDisplayLink()
        startTime = CACurrentMediaTime()
        distanceAtStartOfAnimation = currentGlobalDistance
        displayLink = CADisplayLink(target: self, selector: #selector(animationStep))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func animationStep() {
        if !isPlaying || isPausedForStop { return }
        let elapsed = CACurrentMediaTime() - startTime
        currentGlobalDistance = distanceAtStartOfAnimation + elapsed * (playbackSettings.baseSpeed * Double(playbackSpeed))
        
        if currentGlobalDistance >= totalDistance {
            currentGlobalDistance = totalDistance
            updateVehiclePosition(totalDistance)
            isPlaying = false
            stopDisplayLink()
            channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "finished"])
            return
        }
        
        updateVehiclePosition(currentGlobalDistance)
        
        let idx = getSegmentIndexForDistance(currentGlobalDistance)
        let segmentDist = cumulativeDistances[idx + 1] - cumulativeDistances[idx]
        let localT = segmentDist > 0 ? (currentGlobalDistance - cumulativeDistances[idx]) / segmentDist : 0.0
        channel.invokeMethod("onProgress", arguments: ["index": Double(idx) + localT])
    }

    func pause() {
        isPlaying = false
        stopDisplayLink()
        channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "paused"])
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func seekTo(_ index: Int) {
        pause()
        let idx = index.clamped(to: 0...(points.count - 1))
        currentGlobalDistance = cumulativeDistances[idx]
        updateVehiclePosition(currentGlobalDistance)
        channel.invokeMethod("onProgress", arguments: ["index": Double(index)])
    }

    func setSpeed(_ speed: Int) {
        playbackSpeed = speed
        if isPlaying {
            pause()
            play()
        }
    }

    private func updateVehiclePosition(_ distance: Double) {
        if points.count < 2 { return }
        let idx = getSegmentIndexForDistance(distance)
        let segmentDist = cumulativeDistances[idx + 1] - cumulativeDistances[idx]
        let t = segmentDist > 0 ? (distance - cumulativeDistances[idx]) / segmentDist : 0.0
        
        let p1 = points[idx]
        let p2 = points[idx + 1]
        let p0 = idx > 0 ? points[idx - 1] : p1
        let p3 = idx + 2 < points.count ? points[idx + 2] : p2
        
        let pos = interpolateCatmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: t)
        
        vehicleMarker?.position = pos
        if playbackSettings.canRotate {
            let rotation: Double
            if playbackSettings.dynamicRotation {
                rotation = getCatmullRomHeading(p0: p0, p1: p1, p2: p2, p3: p3, t: t)
            } else {
                rotation = points[idx].bearing
            }
            vehicleMarker?.rotation = rotation
        }

        if followEnabled {
            mapView.animate(toLocation: pos)
        }

        if playbackSettings.drawTrail {
            let path = GMSMutablePath()
            for i in 0...idx {
                path.add(CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng))
            }
            path.add(pos)
            progressPolyline?.path = path
        }
    }

    private func getSegmentIndexForDistance(_ distance: Double) -> Int {
        if distance <= 0 { return 0 }
        if distance >= totalDistance { return points.count - 2 }
        for i in 0..<(cumulativeDistances.count - 1) {
            if distance < cumulativeDistances[i + 1] { return i }
        }
        return points.count - 2
    }

    private func renderStops() {
        for (idx, pt) in points.enumerated() {
            if pt.isStop { checkAndAddStop(idx) }
        }
    }

    private func checkAndAddStop(_ index: Int) {
        if stopMarkers[index] != nil { return }
        let pt = points[index]
        let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: pt.lat, longitude: pt.lng))
        marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
        marker.zIndex = 5
        marker.map = mapView
        marker.userData = "stop_\(index)"
        marker.icon = Convert.toIcon(playbackSettings.stopIcon)
        stopMarkers[index] = marker
    }

    private func computeHeading(from: GoogleMapsPlaybackPoint, to: GoogleMapsPlaybackPoint) -> Double {
        let fLat = from.lat * .pi / 180.0, fLng = from.lng * .pi / 180.0, tLat = to.lat * .pi / 180.0, tLng = to.lng * .pi / 180.0
        let y = sin(tLng - fLng) * cos(tLat), x = cos(fLat) * sin(tLat) - sin(fLat) * cos(tLat) * cos(tLng - fLng)
        return (atan2(y, x) * 180.0 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func reset() {
        stopDisplayLink()
        currentGlobalDistance = 0.0
        isPlaying = false
        vehicleMarker?.map = nil
        vehicleMarker = nil
        progressPolyline?.map = nil
        progressPolyline = nil
        stopMarkers.values.forEach { $0.map = nil }
        stopMarkers.removeAll()
    }

    func dispose() {
        stopDisplayLink()
        reset()
    }

    private func interpolateCatmullRom(p0: GoogleMapsPlaybackPoint, p1: GoogleMapsPlaybackPoint, p2: GoogleMapsPlaybackPoint, p3: GoogleMapsPlaybackPoint, t: Double) -> CLLocationCoordinate2D {
        let t2 = t * t
        let t3 = t2 * t
        
        let lat = 0.5 * ((2 * p1.lat) + (-p0.lat + p2.lat) * t + (2 * p0.lat - 5 * p1.lat + 4 * p2.lat - p3.lat) * t2 + (-p0.lat + 3 * p1.lat - 3 * p2.lat + p3.lat) * t3)
        let lng = 0.5 * ((2 * p1.lng) + (-p0.lng + p2.lng) * t + (2 * p0.lng - 5 * p1.lng + 4 * p2.lng - p3.lng) * t2 + (-p0.lng + 3 * p1.lng - 3 * p2.lng + p3.lng) * t3)
        
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private func getCatmullRomHeading(p0: GoogleMapsPlaybackPoint, p1: GoogleMapsPlaybackPoint, p2: GoogleMapsPlaybackPoint, p3: GoogleMapsPlaybackPoint, t: Double) -> Double {
        let t2 = t * t
        
        let dLat = 0.5 * ((-p0.lat + p2.lat) + 2 * (2 * p0.lat - 5 * p1.lat + 4 * p2.lat - p3.lat) * t + 3 * (-p0.lat + 3 * p1.lat - 3 * p2.lat + p3.lat) * t2)
        let dLng = 0.5 * ((-p0.lng + p2.lng) + 2 * (2 * p0.lng - 5 * p1.lng + 4 * p2.lng - p3.lng) * t + 3 * (-p0.lng + 3 * p1.lng - 3 * p2.lng + p3.lng) * t2)
        
        return (atan2(dLng, dLat) * 180.0 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

private extension Int {
    func clamped(to limits: ClosedRange<Self>) -> Self { return min(max(self, limits.lowerBound), limits.upperBound) }
}
