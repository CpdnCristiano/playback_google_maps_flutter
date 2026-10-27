import Foundation
import GoogleMaps
import Flutter
import UIKit

class PlaybackManager: NSObject {
    struct RouteAnchor {
        let point: CLLocationCoordinate2D
        let shapeIndex: Int
        let shapeFraction: Double
    }

    private struct SnappedSegment {
        let points: [CLLocationCoordinate2D]
        let cumulativeDistances: [Double]
        let totalDistance: Double
        let fallback: Bool
    }

    private struct SnappedProgress {
        let position: CLLocationCoordinate2D
        let heading: Double
        let trailPoints: [CLLocationCoordinate2D]
    }

    private struct RouteProjection {
        let segmentIndex: Int
        let fraction: Double
        let point: CLLocationCoordinate2D
        let distance: Double
    }

    private let mapView: GMSMapView
    private let channel: FlutterMethodChannel
    private let registrar: FlutterPluginRegistrar
    
    var playbackSettings = PlaybackSettings(
        baseSpeed: 60.0,
        canRotate: true,
        dynamicRotation: false,
        showStops: false,
        vehicleIcon: nil,
        stopIcon: nil,
        drawTrail: true,
        polylineColor: nil,
        autoStart: false,
        useSnappedRoute: false
    )
    
    private let turnDurationMs: Double = 300.0
    private let turnAngleThreshold: Double = 30.0

    private var currentSegmentIndex: Int = 0
    private var currentSegmentFraction: Double = 0.0
    private var isTurning: Bool = false
    private var turnProgress: Double = 0.0
    private var turnStartHeading: Double = 0.0
    private var turnDeltaHeading: Double = 0.0
    private var lastFrameTimeMs: Double = 0.0
    private var lastProgressEmitTime: CFTimeInterval = 0

    private var points: [GoogleMapsPlaybackPoint] = []
    private var segmentHeadings: [Double] = []
    private var snappedRoute: [CLLocationCoordinate2D] = []  // Rota completa da Valhalla
    private var routeAnchors: [RouteAnchor] = []
    private var snappedSegments: [SnappedSegment] = []
    private var snappedFallbackCount: Int = 0
    private var cumulativeDistances: [Double] = []
    private var totalDistance: Double = 0.0
    private let maxAnchorDistanceMeters: Double = 80.0
    private let maxLengthRatio: Double = 8.0
    
    private var vehicleMarker: GMSMarker?
    private var vehicleIconNormal: UIImage?
    private var vehicleIconFlipped: UIImage?
    private var lastAppliedIcon: UIImage?
    private var progressPolyline: GMSPolyline?
    private var stopMarkers: [Int: GMSMarker] = [:]
    
    private var currentGlobalDistance: Double = 0.0
    private var playbackSpeed: Int = 1
    var isPlaying: Bool = false
    private var isPausedForStop: Bool = false
    private var lastStopIndexPassed: Int = -1
    private var lastTrailIdx: Int = -1
    private var trailPath = GMSMutablePath()
    private var maxRenderedStopIndex: Int = -1  // Controla até qual índice renderizar stops
    
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var distanceAtStartOfAnimation: Double = 0
    private var animationDurationMs: Int64 = 0
    
    var followEnabled: Bool = true

    init(mapView: GMSMapView, channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar) {
        self.mapView = mapView
        self.channel = channel
        self.registrar = registrar
    }

    func setPoints(_ newPoints: [GoogleMapsPlaybackPoint]) {
        self.points = newPoints
        calculateDistances()
        buildSnappedSegments()
        reset()
        setupInitialState()  // Reconstrói o estado inicial com novos pontos
    }

    func setSnappedRoute(_ newSnappedRoute: [CLLocationCoordinate2D], anchors: [RouteAnchor] = []) {
        self.snappedRoute = newSnappedRoute
        self.routeAnchors = anchors
        buildSnappedSegments()
        NSLog("PlaybackManager: Snapped route set with \(newSnappedRoute.count) points")
    }

    func getDebugPlaybackSummary() -> String {
        let validSegments = max(0, snappedSegments.count - snappedFallbackCount)
        return "Play: orig=\(points.count), snapped=\(snappedRoute.count), anchors=\(routeAnchors.count), seg=\(snappedSegments.count), ok=\(validSegments), fallback=\(snappedFallbackCount)"
    }

    private func calculateDistances() {
        cumulativeDistances.removeAll()
        segmentHeadings.removeAll()
        totalDistance = 0.0
        guard !points.isEmpty else { return }
        cumulativeDistances.append(0.0)
        for i in 0..<(points.count - 1) {
            let dist = CLLocation(latitude: points[i].lat, longitude: points[i].lng).distance(from: CLLocation(latitude: points[i+1].lat, longitude: points[i+1].lng))
            totalDistance += dist
            cumulativeDistances.append(totalDistance)
        }

        if points.count >= 2 {
            var lastValidHeading = points[0].bearing
            for i in 0..<(points.count - 1) {
                let p1 = CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng)
                let p2 = CLLocationCoordinate2D(latitude: points[i + 1].lat, longitude: points[i + 1].lng)
                if !sameCoordinate(p1, p2) {
                    lastValidHeading = computeHeading(from: p1, to: p2)
                    break
                }
            }
            for i in 0..<(points.count - 1) {
                let p1 = CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng)
                let p2 = CLLocationCoordinate2D(latitude: points[i + 1].lat, longitude: points[i + 1].lng)
                if !sameCoordinate(p1, p2) {
                    lastValidHeading = computeHeading(from: p1, to: p2)
                }
                segmentHeadings.append(lastValidHeading)
            }
        }
    }

    private func shortestAngle(from: Double, to: Double) -> Double {
        var diff = (to - from).truncatingRemainder(dividingBy: 360.0)
        if diff > 180.0 { diff -= 360.0 }
        if diff < -180.0 { diff += 360.0 }
        return diff
    }

    func setupInitialState() {
        if points.isEmpty { return }

        prepareVehicleIcons()
        
        let firstPos = CLLocationCoordinate2D(latitude: points[0].lat, longitude: points[0].lng)
        let initialHeading: Double = {
            if !segmentHeadings.isEmpty {
                return segmentHeadings[0]
            }
            return points[0].bearing
        }()
        
        vehicleMarker?.map = nil
        lastAppliedIcon = nil
        let marker = GMSMarker(position: firstPos)
        marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
        marker.isFlat = true
        marker.zIndex = 10
        marker.map = mapView
        let initialIcon = vehicleIconNormal ?? GMSMarker.markerImage(with: .cyan)
        marker.icon = initialIcon
        lastAppliedIcon = initialIcon
        vehicleMarker = marker

        applyVehicleAppearance(heading: playbackSettings.dynamicRotation ? initialHeading : points[0].bearing)

        progressPolyline?.map = nil
        if playbackSettings.drawTrail {
            let poly = GMSPolyline()
            poly.strokeWidth = 6
            poly.strokeColor = Convert.toColor(playbackSettings.polylineColor)
            poly.geodesic = false
            poly.zIndex = 2
            poly.map = mapView
            progressPolyline = poly
        }

        if playbackSettings.showStops { renderStops() }
        
        currentSegmentIndex = 0
        currentSegmentFraction = 0.0
        isTurning = false
        turnProgress = 0.0

        mapView.animate(to: GMSCameraPosition.camera(withTarget: firstPos, zoom: 16))
        
        if playbackSettings.autoStart {
            play()
        }
    }

    func play() {
        if totalDistance <= 0 || points.count < 2 || isPlaying { return }
        if currentSegmentIndex >= points.count - 1 {
            currentSegmentIndex = 0
            currentSegmentFraction = 0.0
            isTurning = false
            turnProgress = 0.0
        }
        isPlaying = true
        startAnimation()
        channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "playing"])
    }

    private func startAnimation() {
        stopDisplayLink()

        guard playbackSettings.baseSpeed > 0, playbackSpeed > 0 else {
            isPlaying = false
            return
        }

        if playbackSettings.useSnappedRoute && !snappedSegments.isEmpty {
            let remainingDistance = max(totalDistance - currentGlobalDistance, 0)
            let rawDurationMs = ((remainingDistance / playbackSettings.baseSpeed) * 1000.0) / Double(playbackSpeed)
            animationDurationMs = Int64(rawDurationMs)

            if animationDurationMs <= 0 {
                currentGlobalDistance = totalDistance
                updateVehiclePosition(totalDistance)
                isPlaying = false
                channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "finished"])
                return
            }

            startTime = CACurrentMediaTime()
            distanceAtStartOfAnimation = currentGlobalDistance

            displayLink = CADisplayLink(target: self, selector: #selector(animationStep))
            displayLink?.add(to: .main, forMode: .common)
            return
        }

        lastFrameTimeMs = 0.0
        displayLink = CADisplayLink(target: self, selector: #selector(animationStep))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func animationStep() {
        if !isPlaying || points.count < 2 { return }

        if playbackSettings.useSnappedRoute && !snappedSegments.isEmpty {
            let elapsedMs = Int64((CACurrentMediaTime() - startTime) * 1000.0)
            let fraction = min(max(Double(elapsedMs) / Double(animationDurationMs), 0), 1)
            currentGlobalDistance = distanceAtStartOfAnimation + (totalDistance - distanceAtStartOfAnimation) * fraction
            
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

            if playbackSettings.showStops && points[idx].isStop && idx != lastStopIndexPassed {
                lastStopIndexPassed = idx
                pauseForStop(idx)
            }
            return
        }

        let nowMs = CACurrentMediaTime() * 1000.0
        if lastFrameTimeMs <= 0.0 {
            lastFrameTimeMs = nowMs
            return
        }

        let dtMs = min(max(nowMs - lastFrameTimeMs, 0.0), 100.0)
        lastFrameTimeMs = nowMs

        if isTurning {
            let effectiveTurnDurationMs = playbackSpeed > 0 ? turnDurationMs / Double(playbackSpeed) : turnDurationMs
            turnProgress += effectiveTurnDurationMs > 0.0 ? (dtMs / effectiveTurnDurationMs) : 1.0
            let pos = CLLocationCoordinate2D(latitude: points[currentSegmentIndex].lat, longitude: points[currentSegmentIndex].lng)
            if turnProgress < 1.0 {
                let raw = (turnStartHeading + turnDeltaHeading * turnProgress).truncatingRemainder(dividingBy: 360.0)
                let heading = (raw + 360.0).truncatingRemainder(dividingBy: 360.0)
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.0)
                CATransaction.setDisableActions(true)
                vehicleMarker?.position = pos
                applyVehicleAppearance(heading: heading)
                CATransaction.commit()
                if followEnabled {
                    mapView.moveCamera(GMSCameraUpdate.setTarget(pos))
                }
                return
            } else {
                isTurning = false
                turnProgress = 0.0
                let finalHeading = (playbackSettings.dynamicRotation && currentSegmentIndex < segmentHeadings.count)
                    ? segmentHeadings[currentSegmentIndex]
                    : points[currentSegmentIndex].bearing
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.0)
                CATransaction.setDisableActions(true)
                vehicleMarker?.position = pos
                applyVehicleAppearance(heading: finalHeading)
                CATransaction.commit()
                if followEnabled {
                    mapView.moveCamera(GMSCameraUpdate.setTarget(pos))
                }
                return
            }
        }

        // Avança pontos duplicados na mesma coordenada (distância zero)
        while currentSegmentIndex < points.count - 1 {
            let p1 = points[currentSegmentIndex]
            let p2 = points[currentSegmentIndex + 1]
            let start = CLLocationCoordinate2D(latitude: p1.lat, longitude: p1.lng)
            let end = CLLocationCoordinate2D(latitude: p2.lat, longitude: p2.lng)
            let dist = distanceBetween(start, end)
            if dist >= 0.01 { break }

            checkStopAtPoint(currentSegmentIndex + 1)
            if currentSegmentIndex + 1 >= points.count - 1 {
                finishPlaybackAtLastPoint()
                return
            }
            let nextIdx = currentSegmentIndex + 1
            let inHeading = segmentHeadings[currentSegmentIndex]
            let outHeading = segmentHeadings[nextIdx]
            let diff = shortestAngle(from: inHeading, to: outHeading)
            currentSegmentIndex = nextIdx
            currentSegmentFraction = 0.0
            if playbackSettings.canRotate && playbackSettings.dynamicRotation && abs(diff) > turnAngleThreshold {
                isTurning = true
                turnProgress = 0.0
                turnStartHeading = inHeading
                turnDeltaHeading = diff
                return
            }
        }

        let segIdx = currentSegmentIndex
        let p1 = points[segIdx]
        let p2 = points[segIdx + 1]
        let start = CLLocationCoordinate2D(latitude: p1.lat, longitude: p1.lng)
        let end = CLLocationCoordinate2D(latitude: p2.lat, longitude: p2.lng)
        let dist = distanceBetween(start, end)

        let baseDurationMs = playbackSettings.baseSpeed > 0 ? (dist / playbackSettings.baseSpeed) * 1000.0 : 0.0
        let segmentDurationMs = playbackSpeed > 0 ? baseDurationMs / Double(playbackSpeed) : 0.0

        if segmentDurationMs > 0.0 {
            currentSegmentFraction += dtMs / segmentDurationMs
        } else {
            currentSegmentFraction = 1.0
        }

        if currentSegmentFraction < 1.0 {
            let f = min(max(currentSegmentFraction, 0.0), 1.0)
            let pos = CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * f,
                longitude: start.longitude + (end.longitude - start.longitude) * f
            )
            let heading = (playbackSettings.dynamicRotation && segIdx < segmentHeadings.count)
                ? segmentHeadings[segIdx]
                : p1.bearing

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.0)
            CATransaction.setDisableActions(true)
            vehicleMarker?.position = pos
            applyVehicleAppearance(heading: heading)
            CATransaction.commit()

            if followEnabled {
                mapView.moveCamera(GMSCameraUpdate.setTarget(pos))
            }
            updateTrail(lastPassedIndex: segIdx, currentPos: pos)

            let now = CACurrentMediaTime()
            if now - lastProgressEmitTime >= 0.03 {
                lastProgressEmitTime = now
                channel.invokeMethod("onProgress", arguments: ["index": Double(segIdx) + f])
            }
        } else {
            // Completa obrigatoriamente a chegada até o ponto `end` antes de mudar de segmento
            currentSegmentFraction = 1.0
            let arriveHeading = (playbackSettings.dynamicRotation && segIdx < segmentHeadings.count)
                ? segmentHeadings[segIdx]
                : p1.bearing

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.0)
            CATransaction.setDisableActions(true)
            vehicleMarker?.position = end
            applyVehicleAppearance(heading: arriveHeading)
            CATransaction.commit()

            if followEnabled {
                mapView.moveCamera(GMSCameraUpdate.setTarget(end))
            }
            updateTrail(lastPassedIndex: segIdx + 1, currentPos: end)
            channel.invokeMethod("onProgress", arguments: ["index": Double(segIdx + 1)])

            checkStopAtPoint(segIdx + 1)

            if segIdx + 1 >= points.count - 1 {
                finishPlaybackAtLastPoint()
                return
            }

            let nextIdx = segIdx + 1
            let inHeading = segmentHeadings[segIdx]
            let outHeading = segmentHeadings[nextIdx]
            let diff = shortestAngle(from: inHeading, to: outHeading)

            currentSegmentIndex = nextIdx
            currentSegmentFraction = 0.0

            if playbackSettings.canRotate && playbackSettings.dynamicRotation && abs(diff) > turnAngleThreshold {
                isTurning = true
                turnProgress = 0.0
                turnStartHeading = inHeading
                turnDeltaHeading = diff
            }
        }
    }

    private func finishPlaybackAtLastPoint() {
        let lastIdx = points.count - 1
        currentSegmentIndex = max(points.count - 2, 0)
        currentSegmentFraction = 1.0
        isTurning = false
        turnProgress = 0.0
        let lastPoint = CLLocationCoordinate2D(latitude: points[lastIdx].lat, longitude: points[lastIdx].lng)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.0)
        CATransaction.setDisableActions(true)
        vehicleMarker?.position = lastPoint
        CATransaction.commit()
        if followEnabled {
            mapView.moveCamera(GMSCameraUpdate.setTarget(lastPoint))
        }
        updateTrail(lastPassedIndex: lastIdx, currentPos: lastPoint)
        isPlaying = false
        stopDisplayLink()
        channel.invokeMethod("onProgress", arguments: ["index": Double(lastIdx)])
        channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "finished"])
    }

    private func updateTrail(lastPassedIndex: Int, currentPos: CLLocationCoordinate2D) {
        guard playbackSettings.drawTrail else { return }
        let path = GMSMutablePath()
        let limit = min(lastPassedIndex, points.count - 1)
        if limit >= 0 {
            for i in 0...limit {
                path.add(CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng))
            }
        }
        if path.count() == 0 || !sameCoordinate(path.coordinate(at: path.count() - 1), currentPos) {
            path.add(currentPos)
        }
        progressPolyline?.path = path
    }

    private func checkStopAtPoint(_ pointIndex: Int) {
        guard pointIndex >= 0 && pointIndex < points.count else { return }
        if playbackSettings.showStops && points[pointIndex].isStop {
            checkAndAddStop(pointIndex)
            if pointIndex != lastStopIndexPassed {
                lastStopIndexPassed = pointIndex
                pauseForStop(pointIndex)
            }
        }
    }

    func pause() {
        isPlaying = false
        isPausedForStop = false
        stopDisplayLink()
        let currentIdx = Double(currentSegmentIndex) + min(max(currentSegmentFraction, 0.0), 1.0)
        channel.invokeMethod("onProgress", arguments: ["index": currentIdx])
        channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "paused"])
    }

    private func pauseForStop(_ index: Int) {
        isPausedForStop = true
        // Notifica apenas que chegou no stop, mas não pausa nem avisa pausa
        channel.invokeMethod("onStopReached", arguments: ["index": index])

        let delay = 2.0 / Double(playbackSpeed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.isPausedForStop else { return }
            self.isPausedForStop = false
            // Continua silenciosamente — nenhuma notificação
        }
    }

    func resumeFromStop() {
        guard isPausedForStop else { return }
        isPausedForStop = false
        startAnimation()
        channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "playing"])
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func seekTo(_ index: Int) {
        pause()
        guard !points.isEmpty else { return }
        let idx = index.clamped(to: 0...(points.count - 1))
        currentGlobalDistance = cumulativeDistances[idx]
        lastStopIndexPassed = idx - 1  // permite que o stop nesse índice dispare pausa ao retomar

        // Remove marcadores de parada que estão além do índice buscado
        let keysToRemove = stopMarkers.keys.filter { $0 >= idx }
        for key in keysToRemove {
            stopMarkers[key]?.map = nil
            stopMarkers.removeValue(forKey: key)
        }
        maxRenderedStopIndex = idx - 1  // Não reconstrói stops além deste índice

        let targetPoint = CLLocationCoordinate2D(latitude: points[idx].lat, longitude: points[idx].lng)
        currentSegmentIndex = min(idx, max(points.count - 2, 0))
        currentSegmentFraction = idx >= points.count - 1 ? 1.0 : 0.0
        isTurning = false
        turnProgress = 0.0

        let segHeading = currentSegmentIndex < segmentHeadings.count ? segmentHeadings[currentSegmentIndex] : points[idx].bearing
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.0)
        CATransaction.setDisableActions(true)
        vehicleMarker?.position = targetPoint
        applyVehicleAppearance(heading: playbackSettings.dynamicRotation ? segHeading : points[idx].bearing)
        CATransaction.commit()

        if followEnabled {
            mapView.moveCamera(GMSCameraUpdate.setTarget(targetPoint))
        }

        if playbackSettings.useSnappedRoute && !snappedSegments.isEmpty {
            trailPath = GMSMutablePath()
            lastTrailIdx = -1
            progressPolyline?.path = trailPath
            updateVehiclePosition(currentGlobalDistance)
        } else {
            updateTrail(lastPassedIndex: idx, currentPos: targetPoint)
        }

        channel.invokeMethod("onProgress", arguments: ["index": Double(idx)])
    }

    func setSpeed(_ speed: Int) {
        if playbackSpeed == speed { return }
        let wasPlaying = isPlaying
        playbackSpeed = speed
        if playbackSettings.useSnappedRoute && !snappedSegments.isEmpty && wasPlaying {
            pause()
            play()
        }
    }

    private func updateVehiclePosition(_ distance: Double) {
        if points.count < 2 { return }
        let idx = getSegmentIndexForDistance(distance)
        let segmentDist = cumulativeDistances[idx + 1] - cumulativeDistances[idx]
        let t = segmentDist > 0 ? (distance - cumulativeDistances[idx]) / segmentDist : 0.0
        let snappedProgress = playbackSettings.useSnappedRoute ? getProgressOnSnappedSegment(idx, segmentT: t) : nil
        
        let clampedT = min(max(t, 0.0), 1.0)
        let p1 = points[idx]
        let p2 = points[idx + 1]

        let pos: CLLocationCoordinate2D
        if let snappedProgress {
            pos = snappedProgress.position
        } else {
            pos = CLLocationCoordinate2D(
                latitude: p1.lat + (p2.lat - p1.lat) * clampedT,
                longitude: p1.lng + (p2.lng - p1.lng) * clampedT
            )
        }
        
        let heading: Double
        if let snappedProgress {
            heading = snappedProgress.heading
        } else if playbackSettings.dynamicRotation {
            let start = CLLocationCoordinate2D(latitude: p1.lat, longitude: p1.lng)
            let end = CLLocationCoordinate2D(latitude: p2.lat, longitude: p2.lng)
            if !sameCoordinate(start, end) {
                heading = computeHeading(from: start, to: end)
            } else {
                heading = p1.bearing
            }
        } else {
            heading = points[idx].bearing
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.0)
        CATransaction.setDisableActions(true)
        vehicleMarker?.position = pos
        applyVehicleAppearance(heading: heading)
        CATransaction.commit()

        if followEnabled {
            mapView.moveCamera(GMSCameraUpdate.setTarget(pos))
        }

        if playbackSettings.drawTrail {
            if let snappedProgress {
                progressPolyline?.path = buildTrailFromSnappedRoute(currentSegmentIndex: idx, currentProgress: snappedProgress)
            } else {
                if trailPath.count() == 0, let first = points.first {
                    trailPath.add(CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng))
                }

                if idx > lastTrailIdx {
                    for i in (lastTrailIdx + 1)...idx {
                        if i < points.count {
                            let pt = points[i]
                            let routePoint = CLLocationCoordinate2D(latitude: pt.lat, longitude: pt.lng)
                            if !sameCoordinate(trailPath.coordinate(at: trailPath.count() - 1), routePoint) {
                                trailPath.add(routePoint)
                            }
                        }
                    }
                    lastTrailIdx = idx
                }

                if trailPath.count() == 0 {
                    trailPath.add(pos)
                } else {
                    let lastPoint = trailPath.coordinate(at: trailPath.count() - 1)
                    if !sameCoordinate(lastPoint, pos) && distanceBetween(lastPoint, pos) >= 1.0 {
                        trailPath.add(pos)
                    }
                }

                progressPolyline?.path = trailPath
            }
        }
        
        if playbackSettings.showStops {
            // Atualiza o máximo índice rendizado conforme avança
            if idx > maxRenderedStopIndex {
                maxRenderedStopIndex = idx
            }
            // Só reconstrói stops até maxRenderedStopIndex
            for i in 0...maxRenderedStopIndex {
                if points[i].isStop {
                    checkAndAddStop(i)
                }
            }
        }
    }

    private func buildSnappedSegments() {
        guard points.count >= 2, snappedRoute.count >= 2 else {
            snappedSegments = []
            snappedFallbackCount = 0
            return
        }

        var segments: [SnappedSegment] = []
        var fallbackCount = 0
        if routeAnchors.count == points.count {
            for i in 0..<(points.count - 1) {
                let startProjection = anchorToProjection(routeAnchors[i])
                let endProjection = anchorToProjection(routeAnchors[i + 1])
                let safeEndProjection = routeOrder(endProjection) < routeOrder(startProjection)
                    ? startProjection
                    : endProjection
                let segmentPoints = buildSegmentPoints(from: startProjection, to: safeEndProjection)
                let result = createSnappedSegment(originalSegmentIndex: i, segmentPoints: segmentPoints)
                if result.fallback { fallbackCount += 1 }
                segments.append(result)
            }
            snappedSegments = segments
            snappedFallbackCount = fallbackCount
            return
        }

        var previousProjection: RouteProjection?

        for i in 0..<(points.count - 1) {
            let startPoint = CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng)
            let endPoint = CLLocationCoordinate2D(latitude: points[i + 1].lat, longitude: points[i + 1].lng)
            let startProjection = previousProjection ?? findProjectionOnSnappedRoute(
                to: startPoint,
                minSegmentIndex: 0,
                minFraction: 0
            )
            var endProjection = findProjectionOnSnappedRoute(
                to: endPoint,
                minSegmentIndex: startProjection.segmentIndex,
                minFraction: startProjection.fraction
            )

            if routeOrder(endProjection) < routeOrder(startProjection) {
                endProjection = startProjection
            }

            let segmentPoints = buildSegmentPoints(from: startProjection, to: endProjection)
            let result = createSnappedSegment(originalSegmentIndex: i, segmentPoints: segmentPoints)
            if result.fallback { fallbackCount += 1 }
            segments.append(result)
            previousProjection = endProjection
        }

        snappedSegments = segments
        snappedFallbackCount = fallbackCount
    }

    private func anchorToProjection(_ anchor: RouteAnchor) -> RouteProjection {
        let safeShapeIndex = min(max(anchor.shapeIndex, 0), snappedRoute.count - 2)
        return RouteProjection(
            segmentIndex: safeShapeIndex,
            fraction: min(max(anchor.shapeFraction, 0), 1),
            point: anchor.point,
            distance: 0
        )
    }

    private func buildSegmentPoints(from start: RouteProjection, to end: RouteProjection) -> [CLLocationCoordinate2D] {
        guard !snappedRoute.isEmpty else { return [] }

        var segmentPoints: [CLLocationCoordinate2D] = [start.point]

        if start.segmentIndex == end.segmentIndex {
            if !sameCoordinate(start.point, end.point) {
                segmentPoints.append(end.point)
            }
            return segmentPoints
        }

        for vertexIndex in (start.segmentIndex + 1)...end.segmentIndex {
            segmentPoints.append(snappedRoute[vertexIndex])
        }

        if !sameCoordinate(segmentPoints.last, end.point) {
            segmentPoints.append(end.point)
        }

        return segmentPoints
    }

    private func createSnappedSegment(
        originalSegmentIndex: Int,
        segmentPoints: [CLLocationCoordinate2D]
    ) -> SnappedSegment {
        guard !segmentPoints.isEmpty else {
            return buildFallbackSegment(originalSegmentIndex: originalSegmentIndex)
        }

        var cumulativeDistances: [Double] = [0.0]
        var totalDistance: Double = 0.0

        for i in 0..<(segmentPoints.count - 1) {
            totalDistance += distanceBetween(segmentPoints[i], segmentPoints[i + 1])
            cumulativeDistances.append(totalDistance)
        }

        let startOriginal = CLLocationCoordinate2D(latitude: points[originalSegmentIndex].lat, longitude: points[originalSegmentIndex].lng)
        let endOriginal = CLLocationCoordinate2D(latitude: points[originalSegmentIndex + 1].lat, longitude: points[originalSegmentIndex + 1].lng)
        let directDistance = distanceBetween(startOriginal, endOriginal)
        let startDistance = distanceBetween(segmentPoints.first ?? startOriginal, startOriginal)
        let endDistance = distanceBetween(segmentPoints.last ?? endOriginal, endOriginal)
        let lengthRatio = directDistance > 0 ? totalDistance / directDistance : 1.0
        let shouldFallback = startDistance > maxAnchorDistanceMeters ||
            endDistance > maxAnchorDistanceMeters ||
            lengthRatio > maxLengthRatio

        if shouldFallback {
            return buildFallbackSegment(originalSegmentIndex: originalSegmentIndex)
        }

        return SnappedSegment(
            points: segmentPoints,
            cumulativeDistances: cumulativeDistances,
            totalDistance: totalDistance,
            fallback: false
        )
    }

    private func buildFallbackSegment(originalSegmentIndex: Int) -> SnappedSegment {
        let start = CLLocationCoordinate2D(latitude: points[originalSegmentIndex].lat, longitude: points[originalSegmentIndex].lng)
        let end = CLLocationCoordinate2D(latitude: points[originalSegmentIndex + 1].lat, longitude: points[originalSegmentIndex + 1].lng)
        let total = distanceBetween(start, end)
        return SnappedSegment(
            points: [start, end],
            cumulativeDistances: [0.0, total],
            totalDistance: total,
            fallback: true
        )
    }

    private func findProjectionOnSnappedRoute(
        to target: CLLocationCoordinate2D,
        minSegmentIndex: Int,
        minFraction: Double
    ) -> RouteProjection {
        let safeMinSegmentIndex = min(max(minSegmentIndex, 0), snappedRoute.count - 2)
        var bestProjection: RouteProjection?

        for segmentIndex in safeMinSegmentIndex..<(snappedRoute.count - 1) {
            let projection = projectPointOnSegment(
                target,
                start: snappedRoute[segmentIndex],
                end: snappedRoute[segmentIndex + 1],
                segmentIndex: segmentIndex
            )

            if segmentIndex == safeMinSegmentIndex && projection.fraction < minFraction {
                continue
            }

            if bestProjection == nil || projection.distance < bestProjection!.distance {
                bestProjection = projection
            }
        }

        return bestProjection ?? RouteProjection(
            segmentIndex: safeMinSegmentIndex,
            fraction: minFraction,
            point: snappedRoute[safeMinSegmentIndex],
            distance: distanceBetween(target, snappedRoute[safeMinSegmentIndex])
        )
    }

    private func projectPointOnSegment(
        _ target: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        segmentIndex: Int
    ) -> RouteProjection {
        let averageLatRad = ((start.latitude + end.latitude + target.latitude) / 3.0) * .pi / 180.0
        let cosLat = cos(averageLatRad)

        let ax = start.longitude * cosLat
        let ay = start.latitude
        let bx = end.longitude * cosLat
        let by = end.latitude
        let px = target.longitude * cosLat
        let py = target.latitude

        let abx = bx - ax
        let aby = by - ay
        let ab2 = abx * abx + aby * aby
        let rawFraction = ab2 > 0 ? ((px - ax) * abx + (py - ay) * aby) / ab2 : 0
        let fraction = min(max(rawFraction, 0), 1)

        let projected = CLLocationCoordinate2D(
            latitude: start.latitude + fraction * (end.latitude - start.latitude),
            longitude: start.longitude + fraction * (end.longitude - start.longitude)
        )

        return RouteProjection(
            segmentIndex: segmentIndex,
            fraction: fraction,
            point: projected,
            distance: distanceBetween(target, projected)
        )
    }

    private func getProgressOnSnappedSegment(_ segmentIndex: Int, segmentT: Double) -> SnappedProgress? {
        guard snappedSegments.indices.contains(segmentIndex) else { return nil }
        let segment = snappedSegments[segmentIndex]
        guard !segment.points.isEmpty else { return nil }

        if segment.points.count == 1 || segment.totalDistance <= 0 {
            let point = segment.points[0]
            return SnappedProgress(position: point, heading: points[segmentIndex].bearing, trailPoints: [point])
        }

        let targetDistance = min(max(segment.totalDistance * segmentT, 0), segment.totalDistance)

        for i in 0..<(segment.points.count - 1) {
            let startDistance = segment.cumulativeDistances[i]
            let endDistance = segment.cumulativeDistances[i + 1]
            if targetDistance <= endDistance || i == segment.points.count - 2 {
                let edgeDistance = endDistance - startDistance
                let localT = edgeDistance > 0 ? min(max((targetDistance - startDistance) / edgeDistance, 0), 1) : 0.0
                let startPoint = segment.points[i]
                let endPoint = segment.points[i + 1]
                let position = CLLocationCoordinate2D(
                    latitude: startPoint.latitude + localT * (endPoint.latitude - startPoint.latitude),
                    longitude: startPoint.longitude + localT * (endPoint.longitude - startPoint.longitude)
                )

                var trailPoints = Array(segment.points[0...i])
                if !sameCoordinate(trailPoints.last, position) {
                    trailPoints.append(position)
                }

                return SnappedProgress(position: position, heading: computeHeading(from: startPoint, to: endPoint), trailPoints: trailPoints)
            }
        }

        guard let lastPoint = segment.points.last else { return nil }
        return SnappedProgress(
            position: lastPoint,
            heading: computeHeading(from: segment.points[segment.points.count - 2], to: lastPoint),
            trailPoints: segment.points
        )
    }

    private func buildTrailFromSnappedRoute(currentSegmentIndex: Int, currentProgress: SnappedProgress) -> GMSMutablePath {
        let path = GMSMutablePath()

        for segmentIndex in 0..<currentSegmentIndex {
            appendTrailPoints(to: path, additions: snappedSegments[segmentIndex].points)
        }

        appendTrailPoints(to: path, additions: currentProgress.trailPoints)
        return path
    }

    private func appendTrailPoints(to path: GMSMutablePath, additions: [CLLocationCoordinate2D]) {
        guard !additions.isEmpty else { return }
        let shouldSkipFirst = path.count() > 0 && sameCoordinate(path.coordinate(at: path.count() - 1), additions.first)
        let startIndex = shouldSkipFirst ? 1 : 0
        guard startIndex < additions.count else { return }

        for index in startIndex..<additions.count {
            path.add(additions[index])
        }
    }

    private func distanceBetween(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    private func sameCoordinate(_ lhs: CLLocationCoordinate2D?, _ rhs: CLLocationCoordinate2D?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.latitude - rhs.latitude) < 0.0000001 && abs(lhs.longitude - rhs.longitude) < 0.0000001
    }

    private func routeOrder(_ projection: RouteProjection) -> Double {
        Double(projection.segmentIndex) + projection.fraction
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
        // Renderiza apenas os stops já passados
        let currentIdx = (playbackSettings.useSnappedRoute && !snappedSegments.isEmpty)
            ? getSegmentIndexForDistance(currentGlobalDistance)
            : currentSegmentIndex
        if currentIdx >= 0 {
            for i in 0...min(currentIdx, points.count - 1) {
                if points[i].isStop { checkAndAddStop(i) }
            }
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
        marker.icon = Convert.toIcon(playbackSettings.stopIcon, registrar: registrar)
        stopMarkers[index] = marker
    }

    private func computeHeading(from: GoogleMapsPlaybackPoint, to: GoogleMapsPlaybackPoint) -> Double {
        let fLat = from.lat * .pi / 180.0, fLng = from.lng * .pi / 180.0, tLat = to.lat * .pi / 180.0, tLng = to.lng * .pi / 180.0
        let y = sin(tLng - fLng) * cos(tLat), x = cos(fLat) * sin(tLat) - sin(fLat) * cos(tLat) * cos(tLng - fLng)
        return (atan2(y, x) * 180.0 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func computeHeading(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let fLat = from.latitude * .pi / 180.0
        let fLng = from.longitude * .pi / 180.0
        let tLat = to.latitude * .pi / 180.0
        let tLng = to.longitude * .pi / 180.0
        let y = sin(tLng - fLng) * cos(tLat)
        let x = cos(fLat) * sin(tLat) - sin(fLat) * cos(tLat) * cos(tLng - fLng)
        return (atan2(y, x) * 180.0 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func prepareVehicleIcons() {
        let fallback = GMSMarker.markerImage(with: .cyan)
        let normal = Convert.toIcon(playbackSettings.vehicleIcon, registrar: registrar)
        let source = normal ?? fallback
        vehicleIconNormal = source
        vehicleIconFlipped = flipImageHorizontally(source)
    }

    private func flipImageHorizontally(_ image: UIImage) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return image
        }

        context.translateBy(x: image.size.width, y: 0)
        context.scaleBy(x: -1, y: 1)
        image.draw(in: CGRect(origin: .zero, size: image.size))

        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    private func applyVehicleAppearance(heading: Double) {
        guard let vehicleMarker else { return }

        if playbackSettings.canRotate {
            vehicleMarker.rotation = heading
            let targetIcon = vehicleIconNormal ?? GMSMarker.markerImage(with: .cyan)
            if lastAppliedIcon !== targetIcon {
                vehicleMarker.icon = targetIcon
                lastAppliedIcon = targetIcon
            }
            return
        }

        let isGoingLeft = heading > 180.0
        vehicleMarker.rotation = 0
        let targetIcon = isGoingLeft
            ? (vehicleIconNormal ?? GMSMarker.markerImage(with: .cyan))
            : (vehicleIconFlipped ?? vehicleIconNormal ?? GMSMarker.markerImage(with: .cyan))
        if lastAppliedIcon !== targetIcon {
            vehicleMarker.icon = targetIcon
            lastAppliedIcon = targetIcon
        }
    }

    private func reset() {
        stopDisplayLink()
        currentSegmentIndex = 0
        currentSegmentFraction = 0.0
        isTurning = false
        turnProgress = 0.0
        lastFrameTimeMs = 0.0
        currentGlobalDistance = 0.0
        isPlaying = false
        isPausedForStop = false
        lastStopIndexPassed = -1
        lastTrailIdx = -1
        trailPath = GMSMutablePath()
        maxRenderedStopIndex = -1
        lastAppliedIcon = nil
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
}

private extension Int {
    func clamped(to limits: ClosedRange<Self>) -> Self { return Swift.min(Swift.max(self, limits.lowerBound), limits.upperBound) }
}
