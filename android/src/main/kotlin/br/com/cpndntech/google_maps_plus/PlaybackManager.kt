package br.com.cpndntech.google_maps_plus

import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.view.animation.LinearInterpolator
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.GoogleMap
import com.google.android.gms.maps.model.*
import io.flutter.plugin.common.MethodChannel

class PlaybackManager(
    private val googleMap: GoogleMap,
    private val channel: MethodChannel,
    private val density: Float
) {
    data class RouteAnchor(
        val point: LatLng,
        val shapeIndex: Int,
        val shapeFraction: Double
    )

    private data class SnappedSegment(
        val points: List<LatLng>,
        val cumulativeDistances: List<Double>,
        val totalDistance: Double,
        val fallback: Boolean
    )

    private data class SnappedProgress(
        val position: LatLng,
        val heading: Float,
        val trailPoints: List<LatLng>
    )

    private data class RouteProjection(
        val segmentIndex: Int,
        val fraction: Double,
        val point: LatLng,
        val distance: Double
    )

    private sealed class TimelineStep {
        abstract val startTimeMs: Double
        abstract val durationMs: Double
        val endTimeMs: Double get() = startTimeMs + durationMs

        data class Move(
            override val startTimeMs: Double,
            override val durationMs: Double,
            val segmentIndex: Int,
            val startPoint: LatLng,
            val endPoint: LatLng,
            val heading: Float
        ) : TimelineStep()

        data class Turn(
            override val startTimeMs: Double,
            override val durationMs: Double,
            val pointIndex: Int,
            val position: LatLng,
            val startHeading: Float,
            val deltaHeading: Float
        ) : TimelineStep()
    }

    var playbackSettings = PlaybackSettings()
        set(value) {
            field = value
            buildTimeline()
        }
    
    private val turnDurationMs = 300.0
    private val turnAngleThreshold = 50.0
    private fun getEffectiveTurnDurationMs(): Double {
        // Pausa de curva ativa apenas em velocidade 1x.
        // Em velocidades rápidas (>1x), pausas em waypoints tornam o movimento engasgado com saltos visíveis.
        return if (playbackSpeed <= 1) turnDurationMs else 0.0
    }
    private var timelineSteps: List<TimelineStep> = emptyList()
    private var totalTimelineDurationMs: Double = 0.0
    private var currentTimelineTimeMs: Double = 0.0
    private val stepStartTimesForPointIndex = mutableMapOf<Int, Double>()

    private var points: List<GoogleMapsPlaybackPoint> = emptyList()
    private var snappedRoute: List<LatLng> = emptyList()  // Rota completa da Valhalla
    private var routeAnchors: List<RouteAnchor> = emptyList()
    private var snappedSegments: List<SnappedSegment> = emptyList()
    private var snappedFallbackCount = 0
    private var cumulativeDistances = mutableListOf<Double>()
    private var totalDistance = 0.0
    
    private var vehicleMarker: Marker? = null
    private var vehicleIconNormal: BitmapDescriptor? = null
    private var vehicleIconFlipped: BitmapDescriptor? = null
    private var lastAppliedIcon: BitmapDescriptor? = null
    private var progressPolyline: Polyline? = null
    private val stopMarkers = mutableMapOf<Int, Marker>()
    private var lastTrailIdx = -1
    private val trailPoints = mutableListOf<LatLng>()
    private var lastProgressEmitTimeMs = 0L
    private var segmentHeadings = FloatArray(0)
    private var segmentDistances = DoubleArray(0)
    private var lastRenderedSegmentIndex = -1
    
    private var currentGlobalDistance = 0.0
    private var playbackSpeed = 1
    private var playbackAnimator: ValueAnimator? = null
    var isPlaying = false
        private set
    private var isPausedForStop = false
    private var lastStopIndexPassed = -1
    private val mainHandler = Handler(Looper.getMainLooper())
    private var maxRenderedStopIndex = -1  // Controla até qual índice renderizar stops

    private val maxAnchorDistanceMeters = 80.0
    private val maxLengthRatio = 8.0

    var followEnabled = true

    fun setPoints(newPoints: List<GoogleMapsPlaybackPoint>) {
        this.points = newPoints
        calculateDistances()
        buildTimeline()
        buildSnappedSegments()
        reset()
        setupInitialState()  // Reconstrói o estado inicial com novos pontos
    }

    fun setSnappedRoute(newSnappedRoute: List<LatLng>, anchors: List<RouteAnchor> = emptyList()) {
        this.snappedRoute = newSnappedRoute
        this.routeAnchors = anchors
        buildSnappedSegments()
        android.util.Log.d("PlaybackManager", "Snapped route set with ${newSnappedRoute.size} points")
    }

    fun getDebugPlaybackSummary(): String {
        val validSegments = snappedSegments.size - snappedFallbackCount
        return "Play: orig=${points.size}, snapped=${snappedRoute.size}, anchors=${routeAnchors.size}, seg=${snappedSegments.size}, ok=$validSegments, fallback=$snappedFallbackCount"
    }

    private fun calculateDistances() {
        cumulativeDistances.clear()
        totalDistance = 0.0
        cumulativeDistances.add(0.0)
        for (i in 0 until points.size - 1) {
            val results = FloatArray(1)
            android.location.Location.distanceBetween(
                points[i].lat, points[i].lng,
                points[i + 1].lat, points[i + 1].lng,
                results
            )
            totalDistance += results[0].toDouble()
            cumulativeDistances.add(totalDistance)
        }
    }

    private fun buildTimeline() {
        timelineSteps = emptyList()
        stepStartTimesForPointIndex.clear()
        totalTimelineDurationMs = 0.0
        if (points.size < 2) return

        val steps = mutableListOf<TimelineStep>()
        var currentTime = 0.0
        stepStartTimesForPointIndex[0] = 0.0

        val segmentHeadings = FloatArray(points.size - 1)
        val segmentDistances = DoubleArray(points.size - 1)
        for (i in 0 until points.size - 1) {
            val p1 = LatLng(points[i].lat, points[i].lng)
            val p2 = LatLng(points[i + 1].lat, points[i + 1].lng)
            segmentDistances[i] = distanceBetween(p1, p2)
            segmentHeadings[i] = if (!sameCoordinate(p1, p2)) {
                computeHeading(p1, p2)
            } else {
                points[i].bearing.toFloat()
            }
        }
        this.segmentHeadings = segmentHeadings
        this.segmentDistances = segmentDistances

        val effectiveTurnDuration = getEffectiveTurnDurationMs()

        for (i in 0 until points.size - 1) {
            val p1 = LatLng(points[i].lat, points[i].lng)
            val p2 = LatLng(points[i + 1].lat, points[i + 1].lng)
            val dist = segmentDistances[i]
            val heading = segmentHeadings[i]

            // Curva parada (estilo iFood) apenas quando:
            // 1) Em velocidade normal (effectiveTurnDuration > 0.0)
            // 2) Ângulo de mudança expressivo (|diff| >= turnAngleThreshold) para não pausar em oscilações de GPS
            // 3) Segmento anterior e atual com comprimento real (>= 8.0 metros) para evitar jitter parado
            if (i > 0 && effectiveTurnDuration > 0.0) {
                val prevHeading = segmentHeadings[i - 1]
                val prevDist = segmentDistances[i - 1]
                val diff = shortestAngle(prevHeading, heading)
                if (Math.abs(diff) >= turnAngleThreshold && dist >= 8.0 && prevDist >= 8.0) {
                    val turnStep = TimelineStep.Turn(
                        startTimeMs = currentTime,
                        durationMs = effectiveTurnDuration,
                        pointIndex = i,
                        position = p1,
                        startHeading = prevHeading,
                        deltaHeading = diff
                    )
                    steps.add(turnStep)
                    currentTime += effectiveTurnDuration
                }
            }

            stepStartTimesForPointIndex[i] = currentTime
            val moveDuration = if (playbackSettings.baseSpeed > 0) {
                (dist / playbackSettings.baseSpeed) * 1000.0
            } else 0.0

            val moveStep = TimelineStep.Move(
                startTimeMs = currentTime,
                durationMs = moveDuration,
                segmentIndex = i,
                startPoint = p1,
                endPoint = p2,
                heading = heading
            )
            steps.add(moveStep)
            currentTime += moveDuration
        }

        stepStartTimesForPointIndex[points.size - 1] = currentTime
        timelineSteps = steps
        totalTimelineDurationMs = currentTime
    }

    private fun shortestAngle(from: Float, to: Float): Float {
        var diff = (to - from) % 360f
        if (diff > 180f) diff -= 360f
        if (diff < -180f) diff += 360f
        return diff
    }

    private fun getStepForTime(timeMs: Double): TimelineStep? {
        if (timelineSteps.isEmpty()) return null
        if (timeMs <= 0.0) return timelineSteps.first()
        if (timeMs >= totalTimelineDurationMs) return timelineSteps.last()
        var low = 0
        var high = timelineSteps.size - 1
        while (low <= high) {
            val mid = (low + high) ushr 1
            val step = timelineSteps[mid]
            if (timeMs < step.startTimeMs) {
                high = mid - 1
            } else if (timeMs >= step.endTimeMs) {
                low = mid + 1
            } else {
                return step
            }
        }
        return timelineSteps.getOrNull(low.coerceIn(0, timelineSteps.size - 1)) ?: timelineSteps.last()
    }

    fun setupInitialState() {
        if (points.isEmpty()) return

        prepareVehicleIcons()
        
        val firstPos = LatLng(points[0].lat, points[0].lng)
        val initialHeading = if (timelineSteps.isNotEmpty()) {
            when (val firstStep = timelineSteps.first()) {
                is TimelineStep.Move -> firstStep.heading
                is TimelineStep.Turn -> firstStep.startHeading
            }
        } else if (points.size > 1) {
            computeHeading(firstPos, LatLng(points[1].lat, points[1].lng))
        } else {
            points[0].bearing.toFloat()
        }
        
        val initialIcon = vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)

        val marker = vehicleMarker
        if (marker == null) {
            vehicleMarker = googleMap.addMarker(
                MarkerOptions()
                    .position(firstPos)
                    .anchor(0.5f, 0.5f)
                    .flat(true)
                    .zIndex(10f)
                    .icon(initialIcon)
            )
        } else {
            marker.position = firstPos
            if (lastAppliedIcon !== initialIcon) {
                marker.setIcon(initialIcon)
            }
        }
        lastAppliedIcon = initialIcon

        applyVehicleAppearance(initialHeading)

        progressPolyline?.remove()
        trailPoints.clear()
        lastTrailIdx = -1
        lastRenderedSegmentIndex = 0
        if (playbackSettings.drawTrail) {
            progressPolyline = googleMap.addPolyline(PolylineOptions().width(5f * density).color(Convert.toColor(playbackSettings.polylineColor)).zIndex(2f).geodesic(false))
        }

        if (playbackSettings.showStops) renderStops()
        
        googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLngZoom(firstPos, 16f))
        
        if (playbackSettings.useSnappedRoute && snappedSegments.isNotEmpty()) {
            updateVehiclePosition(0.0)
        } else {
            updateTimelineState(0.0)
        }

        if (playbackSettings.autoStart) {
            play()
        }
    }

    fun play() {
        if (isPlaying) return

        if (playbackSettings.useSnappedRoute && snappedSegments.isNotEmpty()) {
            if (totalDistance <= 0) return
            isPlaying = true
            val durationMs = (((totalDistance - currentGlobalDistance) / playbackSettings.baseSpeed) * 1000 / playbackSpeed).toLong()
            playbackAnimator?.cancel()
            playbackAnimator = ValueAnimator.ofFloat(currentGlobalDistance.toFloat(), totalDistance.toFloat()).apply {
                duration = durationMs
                interpolator = LinearInterpolator()
                addUpdateListener { anim ->
                    currentGlobalDistance = (anim.animatedValue as Float).toDouble()
                    updateVehiclePosition(currentGlobalDistance)
                    val idx = getSegmentIndexForDistance(currentGlobalDistance)
                    val segmentDist = cumulativeDistances[idx + 1] - cumulativeDistances[idx]
                    val localT = if (segmentDist > 0) (currentGlobalDistance - cumulativeDistances[idx]) / segmentDist else 0.0
                    channel.invokeMethod("onProgress", mapOf("index" to idx.toDouble() + localT))

                    if (playbackSettings.showStops && points[idx].isStop && idx != lastStopIndexPassed) {
                        lastStopIndexPassed = idx
                        pauseForStop(idx)
                    }

                    if (currentGlobalDistance >= totalDistance) {
                        isPlaying = false
                        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "finished"))
                    }
                }
                start()
            }
            channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "playing"))
            return
        }

        if (totalTimelineDurationMs <= 0) return
        isPlaying = true
        val remainingDurationMs = ((totalTimelineDurationMs - currentTimelineTimeMs) / playbackSpeed).toLong()

        if (remainingDurationMs <= 0) {
            currentTimelineTimeMs = totalTimelineDurationMs
            updateTimelineState(totalTimelineDurationMs)
            isPlaying = false
            channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "finished"))
            return
        }

        playbackAnimator?.cancel()
        playbackAnimator = ValueAnimator.ofFloat(currentTimelineTimeMs.toFloat(), totalTimelineDurationMs.toFloat()).apply {
            duration = remainingDurationMs
            interpolator = LinearInterpolator()
            addUpdateListener { anim ->
                currentTimelineTimeMs = (anim.animatedValue as Float).toDouble()
                updateTimelineState(currentTimelineTimeMs)

                val step = getStepForTime(currentTimelineTimeMs)
                val (idx, localT) = when (step) {
                    is TimelineStep.Turn -> Pair(step.pointIndex, 0.0)
                    is TimelineStep.Move -> {
                        val t = if (step.durationMs > 0) ((currentTimelineTimeMs - step.startTimeMs) / step.durationMs).coerceIn(0.0, 1.0) else 0.0
                        Pair(step.segmentIndex, t)
                    }
                    null -> Pair(0, 0.0)
                }

                val now = System.currentTimeMillis()
                if (now - lastProgressEmitTimeMs >= 30L || currentTimelineTimeMs >= totalTimelineDurationMs) {
                    lastProgressEmitTimeMs = now
                    channel.invokeMethod("onProgress", mapOf("index" to idx.toDouble() + localT))
                }

                if (playbackSettings.showStops && points[idx].isStop && idx != lastStopIndexPassed) {
                    lastStopIndexPassed = idx
                    pauseForStop(idx)
                }

                if (currentTimelineTimeMs >= totalTimelineDurationMs) {
                    isPlaying = false
                    channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "finished"))
                }
            }
            start()
        }
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "playing"))
    }

    fun pause() {
        isPlaying = false
        isPausedForStop = false
        mainHandler.removeCallbacksAndMessages(null)
        playbackAnimator?.cancel()
        val step = getStepForTime(currentTimelineTimeMs)
        val (idx, localT) = when (step) {
            is TimelineStep.Turn -> Pair(step.pointIndex, 0.0)
            is TimelineStep.Move -> {
                val t = if (step.durationMs > 0) ((currentTimelineTimeMs - step.startTimeMs) / step.durationMs).coerceIn(0.0, 1.0) else 0.0
                Pair(step.segmentIndex, t)
            }
            null -> Pair(0, 0.0)
        }
        channel.invokeMethod("onProgress", mapOf("index" to idx.toDouble() + localT))
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "paused"))
    }

    private fun pauseForStop(index: Int) {
        isPausedForStop = true
        // Notifica apenas que chegou no stop, mas não pausa nem avisa pausa
        channel.invokeMethod("onStopReached", mapOf("index" to index))
        val delayMs = (2000L / playbackSpeed)
        mainHandler.postDelayed({
            if (isPausedForStop) {
                isPausedForStop = false
                // Continua silenciosamente — nenhuma notificação
            }
        }, delayMs)
    }

    fun resumeFromStop() {
        if (!isPausedForStop) return
        isPausedForStop = false
        mainHandler.removeCallbacksAndMessages(null)
        playbackAnimator?.resume()
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "playing"))
    }

    fun seekTo(index: Int) {
        pause()
        if (points.isEmpty()) return
        val safeIndex = index.coerceIn(0, points.size - 1)
        lastStopIndexPassed = safeIndex - 1  // permite que o stop nesse índice dispare a pausa ao retomar

        // Remove marcadores de parada que estão além do índice buscado
        val keysToRemove = stopMarkers.keys.filter { it >= safeIndex }
        keysToRemove.forEach { key ->
            stopMarkers[key]?.remove()
            stopMarkers.remove(key)
        }
        maxRenderedStopIndex = safeIndex - 1  // Não reconstrói stops além deste índice
        lastRenderedSegmentIndex = safeIndex

        trailPoints.clear()
        if (playbackSettings.drawTrail) {
            for (i in 0 until safeIndex) {
                trailPoints.add(LatLng(points[i].lat, points[i].lng))
            }
            lastTrailIdx = safeIndex - 1
            progressPolyline?.points = trailPoints.toList()
        }

        if (playbackSettings.useSnappedRoute && snappedSegments.isNotEmpty()) {
            currentGlobalDistance = cumulativeDistances[safeIndex]
            updateVehiclePosition(currentGlobalDistance)
        } else {
            currentTimelineTimeMs = stepStartTimesForPointIndex[safeIndex] ?: 0.0
            updateTimelineState(currentTimelineTimeMs)
        }
        channel.invokeMethod("onProgress", mapOf("index" to safeIndex.toDouble()))
    }

    fun setSpeed(speed: Int) {
        if (playbackSpeed == speed) return
        val wasPlaying = isPlaying
        val oldSpeed = playbackSpeed
        playbackSpeed = speed

        val needTimelineRebuild = (oldSpeed <= 1 && speed > 1) || (oldSpeed > 1 && speed <= 1)
        if (needTimelineRebuild && timelineSteps.isNotEmpty()) {
            val step = getStepForTime(currentTimelineTimeMs)
            val currentSegIdx = when (step) {
                is TimelineStep.Turn -> step.pointIndex
                is TimelineStep.Move -> step.segmentIndex
                null -> 0
            }
            val localT = when (step) {
                is TimelineStep.Turn -> 0.0
                is TimelineStep.Move -> if (step.durationMs > 0) ((currentTimelineTimeMs - step.startTimeMs) / step.durationMs).coerceIn(0.0, 1.0) else 0.0
                null -> 0.0
            }
            if (wasPlaying) {
                isPlaying = false
                playbackAnimator?.cancel()
            }
            buildTimeline()
            val newSegStart = stepStartTimesForPointIndex[currentSegIdx] ?: 0.0
            val moveStep = timelineSteps.filterIsInstance<TimelineStep.Move>().firstOrNull { it.segmentIndex == currentSegIdx }
            val segDuration = moveStep?.durationMs ?: 0.0
            currentTimelineTimeMs = (newSegStart + localT * segDuration).coerceIn(0.0, totalTimelineDurationMs)
            if (wasPlaying) play()
        } else {
            if (wasPlaying) {
                pause()
                play()
            }
        }
    }

    private fun updateTimelineState(timeMs: Double) {
        if (points.size < 2 || timelineSteps.isEmpty()) return
        val clampedTime = timeMs.coerceIn(0.0, totalTimelineDurationMs)
        val step = getStepForTime(clampedTime) ?: return

        val pos: LatLng
        val heading: Float
        val currentPointIdx: Int

        when (step) {
            is TimelineStep.Turn -> {
                val t = if (step.durationMs > 0) {
                    ((clampedTime - step.startTimeMs) / step.durationMs).toFloat().coerceIn(0f, 1f)
                } else 1f
                pos = step.position
                val rawHeading = (step.startHeading + step.deltaHeading * t) % 360f
                heading = (rawHeading + 360f) % 360f
                currentPointIdx = step.pointIndex
                lastRenderedSegmentIndex = step.pointIndex
            }
            is TimelineStep.Move -> {
                if (lastRenderedSegmentIndex in 0 until step.segmentIndex) {
                    val vertexIndex = (lastRenderedSegmentIndex + 1).coerceAtMost(points.size - 1)
                    pos = LatLng(points[vertexIndex].lat, points[vertexIndex].lng)
                    val prevHeading = segmentHeadings.getOrElse(lastRenderedSegmentIndex) { step.heading }
                    val nextHeading = segmentHeadings.getOrElse(vertexIndex) { prevHeading }
                    val diff = shortestAngle(prevHeading, nextHeading)
                    heading = (prevHeading + diff * 0.5f + 360f) % 360f
                    currentPointIdx = vertexIndex
                    lastRenderedSegmentIndex = vertexIndex
                } else {
                    val t = if (step.durationMs > 0) {
                        ((clampedTime - step.startTimeMs) / step.durationMs).toFloat().coerceIn(0f, 1f)
                    } else 1f
                    pos = LatLng(
                        step.startPoint.latitude + (step.endPoint.latitude - step.startPoint.latitude) * t,
                        step.startPoint.longitude + (step.endPoint.longitude - step.startPoint.longitude) * t
                    )
                    val nextHeading = if (step.segmentIndex + 1 < segmentHeadings.size) segmentHeadings[step.segmentIndex + 1] else step.heading
                    val turnProgress = ((t - 0.70f) / 0.30f).coerceIn(0f, 1f)
                    val diff = shortestAngle(step.heading, nextHeading)
                    heading = (step.heading + diff * turnProgress + 360f) % 360f
                    currentPointIdx = step.segmentIndex
                    lastRenderedSegmentIndex = step.segmentIndex
                }
            }
        }

        vehicleMarker?.position = pos
        val effectiveHeading = if (playbackSettings.dynamicRotation) {
            heading
        } else {
            points[currentPointIdx].bearing.toFloat()
        }
        applyVehicleAppearance(effectiveHeading)

        if (followEnabled) {
            googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(pos))
        }

        if (playbackSettings.drawTrail) {
            if (currentPointIdx != lastTrailIdx) {
                if (currentPointIdx < lastTrailIdx) {
                    trailPoints.clear()
                    for (i in 0..currentPointIdx) {
                        trailPoints.add(LatLng(points[i].lat, points[i].lng))
                    }
                } else {
                    val start = if (lastTrailIdx < 0) 0 else lastTrailIdx + 1
                    for (i in start..currentPointIdx) {
                        val pt = LatLng(points[i].lat, points[i].lng)
                        if (trailPoints.isEmpty() || !sameCoordinate(trailPoints.last(), pt)) {
                            trailPoints.add(pt)
                        }
                    }
                }
                lastTrailIdx = currentPointIdx
                val currentList = ArrayList<LatLng>(trailPoints.size + 1)
                currentList.addAll(trailPoints)
                if (currentList.isEmpty() || !sameCoordinate(currentList.last(), pos)) {
                    currentList.add(pos)
                }
                progressPolyline?.points = currentList
            } else {
                val lastPt = trailPoints.lastOrNull()
                if (lastPt == null || distanceBetween(lastPt, pos) >= 1.0) {
                    val currentList = ArrayList<LatLng>(trailPoints.size + 1)
                    currentList.addAll(trailPoints)
                    currentList.add(pos)
                    progressPolyline?.points = currentList
                }
            }
        }

        if (playbackSettings.showStops) {
            if (currentPointIdx > maxRenderedStopIndex) {
                val startIdx = if (maxRenderedStopIndex < 0) 0 else maxRenderedStopIndex + 1
                for (i in startIdx..currentPointIdx) {
                    if (points[i].isStop) checkAndAddStop(i)
                }
                maxRenderedStopIndex = currentPointIdx
            }
        }
    }

    private fun updateVehiclePosition(distance: Double) {
        if (points.size < 2) return
        val idx = getSegmentIndexForDistance(distance)
        val segmentDist = cumulativeDistances[idx + 1] - cumulativeDistances[idx]
        val t = if (segmentDist > 0) ((distance - cumulativeDistances[idx]) / segmentDist) else 0.0
        val clampedT = t.toFloat().coerceIn(0f, 1f)
        val snappedProgress = if (playbackSettings.useSnappedRoute) getProgressOnSnappedSegment(idx, t) else null
        
        val p1 = points[idx]
        val p2 = points[idx + 1]

        // O veículo segue o subtrecho snapped (se habilitado) ou linha reta entre os pontos originais.
        val pos = if (snappedProgress != null) {
            snappedProgress.position
        } else {
            LatLng(
                p1.lat + (p2.lat - p1.lat) * clampedT,
                p1.lng + (p2.lng - p1.lng) * clampedT
            )
        }
        
        vehicleMarker?.position = pos
        val heading = if (snappedProgress != null) {
            snappedProgress.heading
        } else if (playbackSettings.dynamicRotation) {
            val start = LatLng(p1.lat, p1.lng)
            val end = LatLng(p2.lat, p2.lng)
            if (!sameCoordinate(start, end)) {
                computeHeading(start, end)
            } else {
                p1.bearing.toFloat()
            }
        } else {
            points[idx].bearing.toFloat()
        }
        applyVehicleAppearance(heading)

        if (followEnabled) {
            googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(pos))
        }

        if (playbackSettings.drawTrail) {
            if (snappedProgress != null) {
                progressPolyline?.points = buildTrailFromSnappedRoute(idx, snappedProgress)
            } else {
                val currentTrail = ArrayList<LatLng>(idx + 2)
                for (i in 0..idx) {
                    currentTrail.add(LatLng(points[i].lat, points[i].lng))
                }
                if (currentTrail.isEmpty() || !sameCoordinate(currentTrail.last(), pos)) {
                    currentTrail.add(pos)
                }
                progressPolyline?.points = currentTrail
            }
        }
        
        if (playbackSettings.showStops) {
            // Atualiza o máximo índice rendizado conforme avança
            val idx = getSegmentIndexForDistance(distance)
            if (idx > maxRenderedStopIndex) {
                maxRenderedStopIndex = idx
            }
            // Só reconstrói stops até maxRenderedStopIndex
            for (i in 0..maxRenderedStopIndex) {
                if (points[i].isStop) {
                    checkAndAddStop(i)
                }
            }
        }
    }

    private fun buildSnappedSegments() {
        if (points.size < 2 || snappedRoute.size < 2) {
            snappedSegments = emptyList()
            snappedFallbackCount = 0
            return
        }

        val segments = mutableListOf<SnappedSegment>()
        var fallbackCount = 0
        if (routeAnchors.size == points.size) {
            for (i in 0 until points.size - 1) {
                val startProjection = anchorToProjection(routeAnchors[i])
                val endProjection = anchorToProjection(routeAnchors[i + 1])
                val safeEndProjection = if (routeOrder(endProjection) < routeOrder(startProjection)) {
                    startProjection
                } else {
                    endProjection
                }
                val segmentPoints = buildSegmentPoints(startProjection, safeEndProjection)
                val result = createSnappedSegment(i, segmentPoints)
                if (result.fallback) fallbackCount++
                segments.add(result)
            }
            snappedSegments = segments
            snappedFallbackCount = fallbackCount
            return
        }

        var previousProjection: RouteProjection? = null
        for (i in 0 until points.size - 1) {
            val startPoint = LatLng(points[i].lat, points[i].lng)
            val endPoint = LatLng(points[i + 1].lat, points[i + 1].lng)
            val startProjection = previousProjection ?: findProjectionOnSnappedRoute(startPoint, 0, 0.0)
            var endProjection = findProjectionOnSnappedRoute(endPoint, startProjection.segmentIndex, startProjection.fraction)
            if (routeOrder(endProjection) < routeOrder(startProjection)) {
                endProjection = startProjection
            }
            val segmentPoints = buildSegmentPoints(startProjection, endProjection)
            val result = createSnappedSegment(i, segmentPoints)
            if (result.fallback) fallbackCount++
            segments.add(result)
            previousProjection = endProjection
        }

        snappedSegments = segments
        snappedFallbackCount = fallbackCount
    }

    private fun anchorToProjection(anchor: RouteAnchor): RouteProjection {
        val safeShapeIndex = anchor.shapeIndex.coerceIn(0, snappedRoute.lastIndex - 1)
        return RouteProjection(
            safeShapeIndex,
            anchor.shapeFraction.coerceIn(0.0, 1.0),
            anchor.point,
            0.0
        )
    }

    private fun buildSegmentPoints(start: RouteProjection, end: RouteProjection): List<LatLng> {
        if (snappedRoute.isEmpty()) return emptyList()

        val segmentPoints = mutableListOf<LatLng>()
        segmentPoints.add(start.point)

        if (start.segmentIndex == end.segmentIndex) {
            if (!sameCoordinate(start.point, end.point)) {
                segmentPoints.add(end.point)
            }
            return segmentPoints
        }

        for (vertexIndex in (start.segmentIndex + 1)..end.segmentIndex) {
            segmentPoints.add(snappedRoute[vertexIndex])
        }

        if (!sameCoordinate(segmentPoints.last(), end.point)) {
            segmentPoints.add(end.point)
        }

        return segmentPoints
    }

    private fun createSnappedSegment(originalSegmentIndex: Int, segmentPoints: List<LatLng>): SnappedSegment {
        if (segmentPoints.isEmpty()) {
            return buildFallbackSegment(originalSegmentIndex)
        }

        val cumulative = mutableListOf(0.0)
        var total = 0.0
        for (i in 0 until segmentPoints.size - 1) {
            total += distanceBetween(segmentPoints[i], segmentPoints[i + 1])
            cumulative.add(total)
        }

        val directDistance = distanceBetween(
            LatLng(points[originalSegmentIndex].lat, points[originalSegmentIndex].lng),
            LatLng(points[originalSegmentIndex + 1].lat, points[originalSegmentIndex + 1].lng)
        )

        val startDistance = distanceBetween(
            segmentPoints.first(),
            LatLng(points[originalSegmentIndex].lat, points[originalSegmentIndex].lng)
        )
        val endDistance = distanceBetween(
            segmentPoints.last(),
            LatLng(points[originalSegmentIndex + 1].lat, points[originalSegmentIndex + 1].lng)
        )

        val lengthRatio = if (directDistance > 0.0) total / directDistance else 1.0
        val shouldFallback = startDistance > maxAnchorDistanceMeters ||
            endDistance > maxAnchorDistanceMeters ||
            lengthRatio > maxLengthRatio

        if (shouldFallback) {
            return buildFallbackSegment(originalSegmentIndex)
        }

        return SnappedSegment(segmentPoints, cumulative, total, false)
    }

    private fun buildFallbackSegment(originalSegmentIndex: Int): SnappedSegment {
        val start = LatLng(points[originalSegmentIndex].lat, points[originalSegmentIndex].lng)
        val end = LatLng(points[originalSegmentIndex + 1].lat, points[originalSegmentIndex + 1].lng)
        val total = distanceBetween(start, end)
        return SnappedSegment(listOf(start, end), mutableListOf(0.0, total), total, true)
    }

    private fun findProjectionOnSnappedRoute(target: LatLng, minSegmentIndex: Int, minFraction: Double): RouteProjection {
        val safeMinSegmentIndex = minSegmentIndex.coerceIn(0, snappedRoute.lastIndex - 1)
        var bestProjection: RouteProjection? = null

        for (segmentIndex in safeMinSegmentIndex until snappedRoute.lastIndex) {
            val projection = projectPointOnSegment(
                target,
                snappedRoute[segmentIndex],
                snappedRoute[segmentIndex + 1],
                segmentIndex
            )

            if (segmentIndex == safeMinSegmentIndex && projection.fraction < minFraction) {
                continue
            }

            if (bestProjection == null || projection.distance < bestProjection.distance) {
                bestProjection = projection
            }
        }

        return bestProjection ?: RouteProjection(
            safeMinSegmentIndex,
            minFraction,
            snappedRoute[safeMinSegmentIndex],
            distanceBetween(target, snappedRoute[safeMinSegmentIndex])
        )
    }

    private fun projectPointOnSegment(target: LatLng, start: LatLng, end: LatLng, segmentIndex: Int): RouteProjection {
        val averageLatRad = Math.toRadians((start.latitude + end.latitude + target.latitude) / 3.0)
        val cosLat = Math.cos(averageLatRad)

        val ax = start.longitude * cosLat
        val ay = start.latitude
        val bx = end.longitude * cosLat
        val by = end.latitude
        val px = target.longitude * cosLat
        val py = target.latitude

        val abx = bx - ax
        val aby = by - ay
        val ab2 = abx * abx + aby * aby
        val rawFraction = if (ab2 > 0.0) ((px - ax) * abx + (py - ay) * aby) / ab2 else 0.0
        val fraction = rawFraction.coerceIn(0.0, 1.0)

        val projected = LatLng(
            start.latitude + fraction * (end.latitude - start.latitude),
            start.longitude + fraction * (end.longitude - start.longitude)
        )

        return RouteProjection(segmentIndex, fraction, projected, distanceBetween(target, projected))
    }

    private fun getProgressOnSnappedSegment(segmentIndex: Int, segmentT: Double): SnappedProgress? {
        val segment = snappedSegments.getOrNull(segmentIndex) ?: return null
        if (segment.points.isEmpty()) return null
        if (segment.points.size == 1 || segment.totalDistance <= 0.0) {
            val point = segment.points.last()
            return SnappedProgress(point, points[segmentIndex].bearing.toFloat(), listOf(point))
        }

        val targetDistance = (segment.totalDistance * segmentT).coerceIn(0.0, segment.totalDistance)
        for (i in 0 until segment.points.size - 1) {
            val startDistance = segment.cumulativeDistances[i]
            val endDistance = segment.cumulativeDistances[i + 1]
            if (targetDistance <= endDistance || i == segment.points.size - 2) {
                val edgeDistance = endDistance - startDistance
                val localT = if (edgeDistance > 0.0) {
                    ((targetDistance - startDistance) / edgeDistance).toFloat().coerceIn(0f, 1f)
                } else {
                    0f
                }

                val startPoint = segment.points[i]
                val endPoint = segment.points[i + 1]
                val position = LatLng(
                    startPoint.latitude + localT * (endPoint.latitude - startPoint.latitude),
                    startPoint.longitude + localT * (endPoint.longitude - startPoint.longitude)
                )

                val traversedPoints = mutableListOf<LatLng>()
                traversedPoints.addAll(segment.points.subList(0, i + 1))
                if (traversedPoints.lastOrNull() != position) {
                    traversedPoints.add(position)
                }

                return SnappedProgress(position, computeHeading(startPoint, endPoint), traversedPoints)
            }
        }

        val lastPoint = segment.points.last()
        return SnappedProgress(lastPoint, computeHeading(segment.points[segment.points.size - 2], lastPoint), segment.points)
    }

    private fun buildTrailFromSnappedRoute(currentSegmentIndex: Int, currentProgress: SnappedProgress): List<LatLng> {
        val routeTrail = mutableListOf<LatLng>()
        for (segmentIndex in 0 until currentSegmentIndex) {
            appendTrailPoints(routeTrail, snappedSegments[segmentIndex].points)
        }
        appendTrailPoints(routeTrail, currentProgress.trailPoints)
        return routeTrail
    }

    private fun appendTrailPoints(target: MutableList<LatLng>, additions: List<LatLng>) {
        if (additions.isEmpty()) return
        val startAt = if (target.lastOrNull() == additions.first()) 1 else 0
        for (i in startAt until additions.size) {
            target.add(additions[i])
        }
    }

    private fun sameCoordinate(first: LatLng, second: LatLng): Boolean {
        return Math.abs(first.latitude - second.latitude) < 0.0000001 &&
            Math.abs(first.longitude - second.longitude) < 0.0000001
    }

    private fun routeOrder(projection: RouteProjection): Double {
        return projection.segmentIndex + projection.fraction
    }

    private fun distanceBetween(start: LatLng, end: LatLng): Double {
        val results = FloatArray(1)
        android.location.Location.distanceBetween(
            start.latitude,
            start.longitude,
            end.latitude,
            end.longitude,
            results
        )
        return results[0].toDouble()
    }

    private fun computeHeading(start: LatLng, end: LatLng): Float {
        val startLat = Math.toRadians(start.latitude)
        val startLng = Math.toRadians(start.longitude)
        val endLat = Math.toRadians(end.latitude)
        val endLng = Math.toRadians(end.longitude)
        val y = Math.sin(endLng - startLng) * Math.cos(endLat)
        val x = Math.cos(startLat) * Math.sin(endLat) - Math.sin(startLat) * Math.cos(endLat) * Math.cos(endLng - startLng)
        return ((Math.toDegrees(Math.atan2(y, x)) + 360.0) % 360.0).toFloat()
    }

    private fun prepareVehicleIcons() {
        val fallback = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)
        vehicleIconNormal = Convert.toBitmapDescriptor(playbackSettings.vehicleIcon) ?: fallback
        vehicleIconFlipped = createFlippedIcon(playbackSettings.vehicleIcon) ?: vehicleIconNormal
    }

    private fun createFlippedIcon(iconData: Any?): BitmapDescriptor? {
        val bitmap = decodeBitmapFromIconData(iconData) ?: return null
        val matrix = Matrix().apply { preScale(-1f, 1f) }
        val flippedBitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        return BitmapDescriptorFactory.fromBitmap(flippedBitmap)
    }

    private fun decodeBitmapFromIconData(iconData: Any?): Bitmap? {
        val list = iconData as? List<*> ?: return null
        if (list.isEmpty()) return null
        val type = list[0] as? String ?: return null

        val bytes: ByteArray? = when (type) {
            "fromBytes" -> toByteArray(list.getOrNull(1))
            "bytes" -> {
                val map = list.getOrNull(1) as? Map<*, *>
                toByteArray(map?.get("byteData"))
            }
            else -> null
        }

        return if (bytes != null && bytes.isNotEmpty()) {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } else {
            null
        }
    }

    private fun toByteArray(raw: Any?): ByteArray? {
        return when (raw) {
            is ByteArray -> raw
            is List<*> -> {
                if (raw.isEmpty()) return null
                val output = ByteArray(raw.size)
                for (i in raw.indices) {
                    val value = raw[i]
                    val number = value as? Number ?: return null
                    output[i] = number.toInt().toByte()
                }
                output
            }
            else -> null
        }
    }

    private fun applyVehicleAppearance(heading: Float) {
        val marker = vehicleMarker ?: return

        if (playbackSettings.canRotate) {
            marker.rotation = heading
            val targetIcon = vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)
            if (lastAppliedIcon !== targetIcon) {
                marker.setIcon(targetIcon)
                lastAppliedIcon = targetIcon
            }
            return
        }

        val isGoingLeft = heading > 180f
        marker.rotation = 0f
        val targetIcon = if (isGoingLeft) {
            vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)
        } else {
            vehicleIconFlipped ?: vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)
        }
        if (lastAppliedIcon !== targetIcon) {
            marker.setIcon(targetIcon)
            lastAppliedIcon = targetIcon
        }
    }

    private fun getSegmentIndexForDistance(distance: Double): Int {
        if (distance <= 0) return 0
        if (distance >= totalDistance) return points.size - 2
        for (i in 0 until cumulativeDistances.size - 1) {
            if (distance < cumulativeDistances[i + 1]) return i
        }
        return points.size - 2
    }

    private fun renderStops() {
        // Renderiza apenas os stops já passados
        val currentIdx = getSegmentIndexForDistance(currentGlobalDistance)
        for (i in 0..currentIdx) {
            if (points[i].isStop) checkAndAddStop(i)
        }
    }

    private fun checkAndAddStop(index: Int) {
        if (stopMarkers.containsKey(index)) return
        val point = points[index]
        googleMap.addMarker(MarkerOptions().position(LatLng(point.lat, point.lng)).anchor(0.5f, 0.5f).zIndex(5f).apply {
            Convert.toBitmapDescriptor(playbackSettings.stopIcon)?.let { icon(it) }
        })?.let {
            it.tag = "stop_$index"
            stopMarkers[index] = it
        }
    }

    private fun reset() {
        playbackAnimator?.cancel()
        mainHandler.removeCallbacksAndMessages(null)
        currentGlobalDistance = 0.0
        currentTimelineTimeMs = 0.0
        isPlaying = false
        isPausedForStop = false
        lastStopIndexPassed = -1
        maxRenderedStopIndex = -1
        lastAppliedIcon = null
        trailPoints.clear()
        lastTrailIdx = -1
        lastProgressEmitTimeMs = 0L
        lastRenderedSegmentIndex = -1
        vehicleMarker?.remove()
        vehicleMarker = null
        progressPolyline?.remove()
        progressPolyline = null
        stopMarkers.values.forEach { it.remove() }
        stopMarkers.clear()
    }

    fun dispose() {
        playbackAnimator?.cancel()
        reset()
    }
}
