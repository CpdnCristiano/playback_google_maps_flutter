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
    
    private enum TimelineStep {
        case move(startTimeMs: Double, durationMs: Double, segmentIndex: Int, startPoint: CLLocationCoordinate2D, endPoint: CLLocationCoordinate2D, heading: Double)
        case turn(startTimeMs: Double, durationMs: Double, pointIndex: Int, position: CLLocationCoordinate2D, startHeading: Double, deltaHeading: Double)

        var startTimeMs: Double {
            switch self {
            case .move(let s, _, _, _, _, _): return s
            case .turn(let s, _, _, _, _, _): return s
            }
        }

        var durationMs: Double {
            switch self {
            case .move(_, let d, _, _, _, _): return d
            case .turn(_, let d, _, _, _, _): return d
            }
        }

        var endTimeMs: Double {
            startTimeMs + durationMs
        }
    }

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
    ) {
        didSet {
            buildTimeline()
        }
    }

    private let turnDurationMs: Double = 300.0
    private let turnAngleThreshold: Double = 50.0
    private func getEffectiveTurnDurationMs() -> Double {
        // Pausa de curva ativa apenas em velocidade 1x.
        // Em velocidades rápidas (>1x), pausas em waypoints tornam o movimento engasgado com saltos visíveis.
        return playbackSpeed <= 1 ? turnDurationMs : 0.0
    }
    private var timelineSteps: [TimelineStep] = []
    private var totalTimelineDurationMs: Double = 0.0
    private var currentTimelineTimeMs: Double = 0.0
    private var stepStartTimesForPointIndex: [Int: Double] = [:]
    
    private var points: [GoogleMapsPlaybackPoint] = []
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
    private var lastProgressEmitTime: CFTimeInterval = 0
    
    private var currentGlobalDistance: Double = 0.0
    private var playbackSpeed: Int = 1
    var isPlaying: Bool = false
    private var isPausedForStop: Bool = false
    private var lastStopIndexPassed: Int = -1
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
        buildTimeline()
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
        totalDistance = 0.0
        guard !points.isEmpty else { return }
        cumulativeDistances.append(0.0)
        for i in 0..<(points.count - 1) {
            let dist = CLLocation(latitude: points[i].lat, longitude: points[i].lng).distance(from: CLLocation(latitude: points[i+1].lat, longitude: points[i+1].lng))
            totalDistance += dist
            cumulativeDistances.append(totalDistance)
        }
    }

    private func buildTimeline() {
        timelineSteps.removeAll()
        stepStartTimesForPointIndex.removeAll()
        totalTimelineDurationMs = 0.0
        guard points.count >= 2 else { return }

        var steps: [TimelineStep] = []
        var currentTime = 0.0
        stepStartTimesForPointIndex[0] = 0.0

        var segmentHeadings: [Double] = []
        var segmentDistances: [Double] = []
        for i in 0..<(points.count - 1) {
            let p1 = CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng)
            let p2 = CLLocationCoordinate2D(latitude: points[i + 1].lat, longitude: points[i + 1].lng)
            segmentDistances.append(distanceBetween(p1, p2))
            if !sameCoordinate(p1, p2) {
                segmentHeadings.append(computeHeading(from: p1, to: p2))
            } else {
                segmentHeadings.append(points[i].bearing)
            }
        }

        let effectiveTurnDuration = getEffectiveTurnDurationMs()

        for i in 0..<(points.count - 1) {
            let p1 = CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng)
            let p2 = CLLocationCoordinate2D(latitude: points[i + 1].lat, longitude: points[i + 1].lng)
            let dist = segmentDistances[i]
            let heading = segmentHeadings[i]

            // Curva parada (estilo iFood) apenas quando:
            // 1) Em velocidade normal (effectiveTurnDuration > 0.0)
            // 2) Ângulo de mudança expressivo (|diff| >= turnAngleThreshold) para não pausar em oscilações de GPS
            // 3) Segmento anterior e atual com comprimento real (>= 8.0 metros) para evitar jitter parado
            if i > 0 && effectiveTurnDuration > 0.0 {
                let prevHeading = segmentHeadings[i - 1]
                let prevDist = segmentDistances[i - 1]
                let diff = shortestAngle(from: prevHeading, to: heading)
                if abs(diff) >= turnAngleThreshold && dist >= 8.0 && prevDist >= 8.0 {
                    let turnStep = TimelineStep.turn(
                        startTimeMs: currentTime,
                        durationMs: effectiveTurnDuration,
                        pointIndex: i,
                        position: p1,
                        startHeading: prevHeading,
                        deltaHeading: diff
                    )
                    steps.append(turnStep)
                    currentTime += effectiveTurnDuration
                }
            }

            stepStartTimesForPointIndex[i] = currentTime
            let moveDuration = playbackSettings.baseSpeed > 0
                ? (dist / playbackSettings.baseSpeed) * 1000.0
                : 0.0

            let moveStep = TimelineStep.move(
                startTimeMs: currentTime,
                durationMs: moveDuration,
                segmentIndex: i,
                startPoint: p1,
                endPoint: p2,
                heading: heading
            )
            steps.append(moveStep)
            currentTime += moveDuration
        }

        stepStartTimesForPointIndex[points.count - 1] = currentTime
        timelineSteps = steps
        totalTimelineDurationMs = currentTime
    }

    private func shortestAngle(from: Double, to: Double) -> Double {
        var diff = (to - from).truncatingRemainder(dividingBy: 360.0)
        if diff > 180.0 { diff -= 360.0 }
        if diff < -180.0 { diff += 360.0 }
        return diff
    }

    private func getStep(for timeMs: Double) -> TimelineStep? {
        guard !timelineSteps.isEmpty else { return nil }
        if timeMs <= 0.0 { return timelineSteps.first }
        if timeMs >= totalTimelineDurationMs { return timelineSteps.last }
        var low = 0
        var high = timelineSteps.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let step = timelineSteps[mid]
            if timeMs < step.startTimeMs {
                high = mid - 1
            } else if timeMs >= step.endTimeMs {
                low = mid + 1
            } else {
                return step
            }
        }
        let safeIndex = min(max(low, 0), timelineSteps.count - 1)
        return timelineSteps[safeIndex]
    }

    func setupInitialState() {
        if points.isEmpty { return }

        prepareVehicleIcons()
        
        let firstPos = CLLocationCoordinate2D(latitude: points[0].lat, longitude: points[0].lng)
        let initialHeading: Double = {
            if let firstStep = timelineSteps.first {
                switch firstStep {
                case .move(_, _, _, _, _, let heading):
                    return heading
                case .turn(_, _, _, _, let startHeading, _):
                    return startHeading
                }
            }
            if points.count > 1 {
                return computeHeading(
                    from: firstPos,
                    to: CLLocationCoordinate2D(latitude: points[1].lat, longitude: points[1].lng)
                )
            }
            return points[0].bearing
        }()
        
        let initialIcon = vehicleIconNormal ?? GMSMarker.markerImage(with: .cyan)
        if let marker = vehicleMarker {
            marker.position = firstPos
            if lastAppliedIcon !== initialIcon {
                marker.icon = initialIcon
            }
        } else {
            let marker = GMSMarker(position: firstPos)
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.isFlat = true
            marker.zIndex = 10
            marker.icon = initialIcon
            marker.map = mapView
            vehicleMarker = marker
        }
        lastAppliedIcon = initialIcon

        applyVehicleAppearance(heading: initialHeading)

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
        
        mapView.animate(to: GMSCameraPosition.camera(withTarget: firstPos, zoom: 16))
        
        if playbackSettings.useSnappedRoute && !snappedSegments.isEmpty {
            updateVehiclePosition(0.0)
        } else {
            updateTimelineState(0.0)
        }

        if playbackSettings.autoStart {
            play()
        }
    }

    func play() {
        if isPlaying { return }

        if playbackSettings.useSnappedRoute && !snappedSegments.isEmpty {
            if totalDistance <= 0 { return }
            isPlaying = true
            startAnimation()
            channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "playing"])
            return
        }

        if totalTimelineDurationMs <= 0 { return }
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

        let remainingDurationMs = (totalTimelineDurationMs - currentTimelineTimeMs) / Double(playbackSpeed)
        animationDurationMs = Int64(remainingDurationMs)

        if animationDurationMs <= 0 {
            currentTimelineTimeMs = totalTimelineDurationMs
            updateTimelineState(totalTimelineDurationMs)
            isPlaying = false
            channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "finished"])
            return
        }

        startTime = CACurrentMediaTime()
        distanceAtStartOfAnimation = currentTimelineTimeMs

        displayLink = CADisplayLink(target: self, selector: #selector(animationStep))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func animationStep() {
        if !isPlaying { return }

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

        let elapsedMs = (CACurrentMediaTime() - startTime) * 1000.0
        currentTimelineTimeMs = distanceAtStartOfAnimation + elapsedMs * Double(playbackSpeed)

        if currentTimelineTimeMs >= totalTimelineDurationMs {
            currentTimelineTimeMs = totalTimelineDurationMs
            updateTimelineState(totalTimelineDurationMs)
            isPlaying = false
            stopDisplayLink()
            channel.invokeMethod("onPlaybackStatusChanged", arguments: ["status": "finished"])
            return
        }

        updateTimelineState(currentTimelineTimeMs)

        guard let step = getStep(for: currentTimelineTimeMs) else { return }
        let (idx, localT): (Int, Double) = {
            switch step {
            case .turn(_, _, let ptIdx, _, _, _):
                return (ptIdx, 0.0)
            case .move(let startMs, let durMs, let segIdx, _, _, _):
                let t = durMs > 0 ? min(max((currentTimelineTimeMs - startMs) / durMs, 0.0), 1.0) : 0.0
                return (segIdx, t)
            }
        }()
        let now = CACurrentMediaTime()
        if now - lastProgressEmitTime >= 0.03 || currentTimelineTimeMs >= totalTimelineDurationMs {
            lastProgressEmitTime = now
            channel.invokeMethod("onProgress", arguments: ["index": Double(idx) + localT])
        }

        if playbackSettings.showStops && points[idx].isStop && idx != lastStopIndexPassed {
            lastStopIndexPassed = idx
            pauseForStop(idx)
        }
    }

    func pause() {
        isPlaying = false
        isPausedForStop = false
        stopDisplayLink()
        if let step = getStep(for: currentTimelineTimeMs) {
            let (idx, localT): (Int, Double) = {
                switch step {
                case .turn(_, _, let ptIdx, _, _, _):
                    return (ptIdx, 0.0)
                case .move(let startMs, let durMs, let segIdx, _, _, _):
                    let t = durMs > 0 ? min(max((currentTimelineTimeMs - startMs) / durMs, 0.0), 1.0) : 0.0
                    return (segIdx, t)
                }
            }()
            channel.invokeMethod("onProgress", arguments: ["index": Double(idx) + localT])
        }
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
        lastStopIndexPassed = idx - 1  // permite que o stop nesse índice dispare pausa ao retomar

        // Remove marcadores de parada que estão além do índice buscado
        let keysToRemove = stopMarkers.keys.filter { $0 >= idx }
        for key in keysToRemove {
            stopMarkers[key]?.map = nil
            stopMarkers.removeValue(forKey: key)
        }
        maxRenderedStopIndex = idx - 1  // Não reconstrói stops além deste índice

        if playbackSettings.useSnappedRoute && !snappedSegments.isEmpty {
            currentGlobalDistance = cumulativeDistances[idx]
            updateVehiclePosition(currentGlobalDistance)
        } else {
            currentTimelineTimeMs = stepStartTimesForPointIndex[idx] ?? 0.0
            updateTimelineState(currentTimelineTimeMs)
        }
        channel.invokeMethod("onProgress", arguments: ["index": Double(idx)])
    }

    func setSpeed(_ speed: Int) {
        guard playbackSpeed != speed else { return }
        let wasPlaying = isPlaying
        let oldSpeed = playbackSpeed
        playbackSpeed = speed

        let needTimelineRebuild = (oldSpeed <= 1 && speed > 1) || (oldSpeed > 1 && speed <= 1)
        if needTimelineRebuild && !timelineSteps.isEmpty {
            let step = getStep(for: currentTimelineTimeMs)
            let (currentSegIdx, localT): (Int, Double) = {
                guard let step = step else { return (0, 0.0) }
                switch step {
                case .turn(_, _, let ptIdx, _, _, _):
                    return (ptIdx, 0.0)
                case .move(let startMs, let durMs, let segIdx, _, _, _):
                    let t = durMs > 0 ? min(max((currentTimelineTimeMs - startMs) / durMs, 0.0), 1.0) : 0.0
                    return (segIdx, t)
                }
            }()

            if wasPlaying {
                stopDisplayLink()
                isPlaying = false
            }
            buildTimeline()
            let newSegStart = stepStartTimesForPointIndex[currentSegIdx] ?? 0.0
            let moveDuration: Double = {
                for s in timelineSteps {
                    if case .move(_, let durMs, let sIdx, _, _, _) = s, sIdx == currentSegIdx {
                        return durMs
                    }
                }
                return 0.0
            }()
            currentTimelineTimeMs = min(max(newSegStart + localT * moveDuration, 0.0), totalTimelineDurationMs)
            if wasPlaying {
                play()
            }
        } else {
            if wasPlaying {
                pause()
                play()
            }
        }
    }

    private func updateTimelineState(_ timeMs: Double) {
        guard points.count >= 2, !timelineSteps.isEmpty else { return }
        let clampedTime = min(max(timeMs, 0.0), totalTimelineDurationMs)
        guard let step = getStep(for: clampedTime) else { return }

        let pos: CLLocationCoordinate2D
        let heading: Double
        let currentPointIdx: Int

        switch step {
        case .turn(let startMs, let durMs, let ptIdx, let position, let startHeading, let deltaHeading):
            let t = durMs > 0 ? min(max((clampedTime - startMs) / durMs, 0.0), 1.0) : 1.0
            pos = position
            let rawHeading = (startHeading + deltaHeading * t).truncatingRemainder(dividingBy: 360.0)
            heading = (rawHeading + 360.0).truncatingRemainder(dividingBy: 360.0)
            currentPointIdx = ptIdx

        case .move(let startMs, let durMs, let segIdx, let startPoint, let endPoint, let segHeading):
            let t = durMs > 0 ? min(max((clampedTime - startMs) / durMs, 0.0), 1.0) : 1.0
            pos = CLLocationCoordinate2D(
                latitude: startPoint.latitude + (endPoint.latitude - startPoint.latitude) * t,
                longitude: startPoint.longitude + (endPoint.longitude - startPoint.longitude) * t
            )
            heading = segHeading
            currentPointIdx = segIdx
        }

        vehicleMarker?.position = pos
        let effectiveHeading = playbackSettings.dynamicRotation ? heading : points[currentPointIdx].bearing
        applyVehicleAppearance(heading: effectiveHeading)

        if followEnabled {
            mapView.moveCamera(GMSCameraUpdate.setTarget(pos))
        }

        if playbackSettings.drawTrail {
            let path = GMSMutablePath()
            for i in 0...currentPointIdx {
                path.add(CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng))
            }
            if path.count() == 0 || !sameCoordinate(path.coordinate(at: path.count() - 1), pos) {
                path.add(pos)
            }
            progressPolyline?.path = path
        }

        if playbackSettings.showStops {
            if currentPointIdx > maxRenderedStopIndex {
                let startIdx = maxRenderedStopIndex < 0 ? 0 : maxRenderedStopIndex + 1
                for i in startIdx...currentPointIdx {
                    if points[i].isStop { checkAndAddStop(i) }
                }
                maxRenderedStopIndex = currentPointIdx
            }
        }
    }

    private func updateVehiclePosition(_ distance: Double) {
        if points.count < 2 { return }
        let idx = getSegmentIndexForDistance(distance)
        let segmentDist = cumulativeDistances[idx + 1] - cumulativeDistances[idx]
        let t = segmentDist > 0 ? (distance - cumulativeDistances[idx]) / segmentDist : 0.0
        let clampedT = min(max(t, 0.0), 1.0)
        let snappedProgress = playbackSettings.useSnappedRoute ? getProgressOnSnappedSegment(idx, segmentT: t) : nil
        
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
        
        vehicleMarker?.position = pos
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
        applyVehicleAppearance(heading: heading)

        if followEnabled {
            mapView.moveCamera(GMSCameraUpdate.setTarget(pos))
        }

        if playbackSettings.drawTrail {
            if let snappedProgress {
                progressPolyline?.path = buildTrailFromSnappedRoute(currentSegmentIndex: idx, currentProgress: snappedProgress)
            } else {
                let path = GMSMutablePath()
                for i in 0...idx {
                    path.add(CLLocationCoordinate2D(latitude: points[i].lat, longitude: points[i].lng))
                }
                if path.count() == 0 || !sameCoordinate(path.coordinate(at: path.count() - 1), pos) {
                    path.add(pos)
                }
                progressPolyline?.path = path
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
        let currentIdx = getSegmentIndexForDistance(currentGlobalDistance)
        for i in 0...currentIdx {
            if points[i].isStop { checkAndAddStop(i) }
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
        currentGlobalDistance = 0.0
        currentTimelineTimeMs = 0.0
        isPlaying = false
        isPausedForStop = false
        lastStopIndexPassed = -1
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
