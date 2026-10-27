package br.com.cpndntech.google_maps_plus

import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.view.Choreographer
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

    var playbackSettings = PlaybackSettings()
    
    private val turnDurationMs = 300.0
    private val turnAngleThreshold = 30.0
    
    private var currentSegmentIndex = 0
    private var currentSegmentFraction = 0.0
    private var isTurning = false
    private var turnProgress = 0.0
    private var turnStartHeading = 0f
    private var turnDeltaHeading = 0f
    private var lastFrameTimeMs = 0.0

    private var points: List<GoogleMapsPlaybackPoint> = emptyList()
    private var segmentHeadings = FloatArray(0)
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

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!isPlaying) return
            val nowMs = frameTimeNanos / 1_000_000.0
            onAnimationFrame(nowMs)
        }
    }

    fun setPoints(newPoints: List<GoogleMapsPlaybackPoint>) {
        this.points = newPoints
        calculateDistances()
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
        if (points.isEmpty()) {
            segmentHeadings = FloatArray(0)
            return
        }
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

        if (points.size >= 2) {
            val headings = FloatArray(points.size - 1)
            var lastValidHeading = points[0].bearing.toFloat()
            for (i in 0 until points.size - 1) {
                val p1 = LatLng(points[i].lat, points[i].lng)
                val p2 = LatLng(points[i + 1].lat, points[i + 1].lng)
                if (!sameCoordinate(p1, p2)) {
                    lastValidHeading = computeHeading(p1, p2)
                    break
                }
            }
            for (i in 0 until points.size - 1) {
                val p1 = LatLng(points[i].lat, points[i].lng)
                val p2 = LatLng(points[i + 1].lat, points[i + 1].lng)
                if (!sameCoordinate(p1, p2)) {
                    lastValidHeading = computeHeading(p1, p2)
                }
                headings[i] = lastValidHeading
            }
            segmentHeadings = headings
        } else {
            segmentHeadings = FloatArray(0)
        }
    }

    private fun shortestAngle(from: Float, to: Float): Float {
        var diff = (to - from) % 360f
        if (diff > 180f) diff -= 360f
        if (diff < -180f) diff += 360f
        return diff
    }

    fun setupInitialState() {
        if (points.isEmpty()) return

        prepareVehicleIcons()
        
        val firstPos = LatLng(points[0].lat, points[0].lng)
        val initialHeading = if (segmentHeadings.isNotEmpty()) {
            segmentHeadings[0]
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

        applyVehicleAppearance(if (playbackSettings.dynamicRotation) initialHeading else points[0].bearing.toFloat())

        progressPolyline?.remove()
        trailPoints.clear()
        lastTrailIdx = -1
        if (playbackSettings.drawTrail) {
            progressPolyline = googleMap.addPolyline(PolylineOptions().width(5f * density).color(Convert.toColor(playbackSettings.polylineColor)).zIndex(2f).geodesic(false))
        }

        if (playbackSettings.showStops) renderStops()
        
        googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLngZoom(firstPos, 16f))
        
        currentSegmentIndex = 0
        currentSegmentFraction = 0.0
        isTurning = false
        turnProgress = 0.0

        if (playbackSettings.autoStart) {
            play()
        }
    }

    fun play() {
        if (isPlaying || points.size < 2 || totalDistance <= 0) return

        if (playbackSettings.useSnappedRoute && snappedSegments.isNotEmpty()) {
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

        if (currentSegmentIndex >= points.size - 1) {
            currentSegmentIndex = 0
            currentSegmentFraction = 0.0
            isTurning = false
            turnProgress = 0.0
        }

        isPlaying = true
        lastFrameTimeMs = 0.0
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        Choreographer.getInstance().postFrameCallback(frameCallback)
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "playing"))
    }

    fun pause() {
        isPlaying = false
        isPausedForStop = false
        mainHandler.removeCallbacksAndMessages(null)
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        playbackAnimator?.cancel()
        val currentIdx = currentSegmentIndex.toDouble() + currentSegmentFraction.coerceIn(0.0, 1.0)
        channel.invokeMethod("onProgress", mapOf("index" to currentIdx))
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "paused"))
    }

    private fun pauseForStop(index: Int) {
        isPausedForStop = true
        channel.invokeMethod("onStopReached", mapOf("index" to index))
        val delayMs = (2000L / playbackSpeed)
        mainHandler.postDelayed({
            if (isPausedForStop) {
                isPausedForStop = false
            }
        }, delayMs)
    }

    fun resumeFromStop() {
        if (!isPausedForStop) return
        isPausedForStop = false
        mainHandler.removeCallbacksAndMessages(null)
        if (!isPlaying) {
            play()
        } else {
            playbackAnimator?.resume()
        }
    }

    fun seekTo(index: Int) {
        pause()
        if (points.isEmpty()) return
        val safeIndex = index.coerceIn(0, points.size - 1)
        lastStopIndexPassed = safeIndex - 1

        val keysToRemove = stopMarkers.keys.filter { it >= safeIndex }
        keysToRemove.forEach { key ->
            stopMarkers[key]?.remove()
            stopMarkers.remove(key)
        }
        maxRenderedStopIndex = safeIndex - 1

        val targetPoint = LatLng(points[safeIndex].lat, points[safeIndex].lng)
        vehicleMarker?.position = targetPoint
        if (followEnabled) {
            googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(targetPoint))
        }

        currentSegmentIndex = safeIndex.coerceAtMost(points.size - 2)
        currentSegmentFraction = if (safeIndex >= points.size - 1) 1.0 else 0.0
        isTurning = false
        turnProgress = 0.0

        val segHeading = if (currentSegmentIndex < segmentHeadings.size) {
            segmentHeadings[currentSegmentIndex]
        } else {
            points[safeIndex].bearing.toFloat()
        }
        applyVehicleAppearance(if (playbackSettings.dynamicRotation) segHeading else points[safeIndex].bearing.toFloat())

        if (playbackSettings.drawTrail) {
            val currentTrail = ArrayList<LatLng>(safeIndex + 1)
            for (i in 0..safeIndex) {
                currentTrail.add(LatLng(points[i].lat, points[i].lng))
            }
            progressPolyline?.points = currentTrail
        }

        if (playbackSettings.useSnappedRoute && snappedSegments.isNotEmpty()) {
            currentGlobalDistance = cumulativeDistances[safeIndex]
            updateVehiclePosition(currentGlobalDistance)
        }

        channel.invokeMethod("onProgress", mapOf("index" to safeIndex.toDouble()))
    }

    fun setSpeed(speed: Int) {
        if (playbackSpeed == speed) return
        val wasPlaying = isPlaying
        playbackSpeed = speed
        if (playbackSettings.useSnappedRoute && snappedSegments.isNotEmpty() && wasPlaying) {
            pause()
            play()
        }
    }

    private fun onAnimationFrame(nowMs: Double) {
        if (!isPlaying || points.size < 2) return

        if (lastFrameTimeMs <= 0.0) {
            lastFrameTimeMs = nowMs
            Choreographer.getInstance().postFrameCallback(frameCallback)
            return
        }

        val dtMs = (nowMs - lastFrameTimeMs).coerceIn(0.0, 100.0)
        lastFrameTimeMs = nowMs

        if (isTurning) {
            turnProgress += dtMs / turnDurationMs
            val pos = LatLng(points[currentSegmentIndex].lat, points[currentSegmentIndex].lng)
            if (turnProgress < 1.0) {
                val raw = (turnStartHeading + turnDeltaHeading * turnProgress.toFloat()) % 360f
                val heading = (raw + 360f) % 360f
                vehicleMarker?.position = pos
                applyVehicleAppearance(heading)
                if (followEnabled) {
                    googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(pos))
                }
                Choreographer.getInstance().postFrameCallback(frameCallback)
                return
            } else {
                isTurning = false
                turnProgress = 0.0
                val finalHeading = if (playbackSettings.dynamicRotation && currentSegmentIndex < segmentHeadings.size) {
                    segmentHeadings[currentSegmentIndex]
                } else {
                    points[currentSegmentIndex].bearing.toFloat()
                }
                vehicleMarker?.position = pos
                applyVehicleAppearance(finalHeading)
                if (followEnabled) {
                    googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(pos))
                }
                Choreographer.getInstance().postFrameCallback(frameCallback)
                return
            }
        }

        // Avança pontos duplicados na mesma coordenada (distância zero)
        while (currentSegmentIndex < points.size - 1) {
            val p1 = points[currentSegmentIndex]
            val p2 = points[currentSegmentIndex + 1]
            val start = LatLng(p1.lat, p1.lng)
            val end = LatLng(p2.lat, p2.lng)
            val dist = distanceBetween(start, end)
            if (dist >= 0.01) break

            checkStopAtPoint(currentSegmentIndex + 1)
            if (currentSegmentIndex + 1 >= points.size - 1) {
                finishPlaybackAtLastPoint()
                return
            }
            val nextIdx = currentSegmentIndex + 1
            val inHeading = segmentHeadings[currentSegmentIndex]
            val outHeading = segmentHeadings[nextIdx]
            val diff = shortestAngle(inHeading, outHeading)
            currentSegmentIndex = nextIdx
            currentSegmentFraction = 0.0
            if (playbackSettings.canRotate && playbackSettings.dynamicRotation && Math.abs(diff) > turnAngleThreshold) {
                isTurning = true
                turnProgress = 0.0
                turnStartHeading = inHeading
                turnDeltaHeading = diff
                Choreographer.getInstance().postFrameCallback(frameCallback)
                return
            }
        }

        val segIdx = currentSegmentIndex
        val p1 = points[segIdx]
        val p2 = points[segIdx + 1]
        val start = LatLng(p1.lat, p1.lng)
        val end = LatLng(p2.lat, p2.lng)
        val dist = distanceBetween(start, end)

        val baseDurationMs = if (playbackSettings.baseSpeed > 0) (dist / playbackSettings.baseSpeed) * 1000.0 else 0.0
        val segmentDurationMs = if (playbackSpeed > 0) baseDurationMs / playbackSpeed else 0.0

        if (segmentDurationMs > 0.0) {
            currentSegmentFraction += dtMs / segmentDurationMs
        } else {
            currentSegmentFraction = 1.0
        }

        if (currentSegmentFraction < 1.0) {
            val f = currentSegmentFraction.coerceIn(0.0, 1.0)
            val pos = LatLng(
                start.latitude + (end.latitude - start.latitude) * f,
                start.longitude + (end.longitude - start.longitude) * f
            )
            val heading = if (playbackSettings.dynamicRotation && segIdx < segmentHeadings.size) {
                segmentHeadings[segIdx]
            } else {
                p1.bearing.toFloat()
            }
            vehicleMarker?.position = pos
            applyVehicleAppearance(heading)
            if (followEnabled) {
                googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(pos))
            }
            updateTrail(segIdx, pos)

            val now = System.currentTimeMillis()
            if (now - lastProgressEmitTimeMs >= 30L) {
                lastProgressEmitTimeMs = now
                channel.invokeMethod("onProgress", mapOf("index" to segIdx.toDouble() + f))
            }

            Choreographer.getInstance().postFrameCallback(frameCallback)
        } else {
            // Completa obrigatoriamente a chegada até o ponto `end` antes de mudar de segmento
            currentSegmentFraction = 1.0
            val arriveHeading = if (playbackSettings.dynamicRotation && segIdx < segmentHeadings.size) {
                segmentHeadings[segIdx]
            } else {
                p1.bearing.toFloat()
            }
            vehicleMarker?.position = end
            applyVehicleAppearance(arriveHeading)
            if (followEnabled) {
                googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(end))
            }
            updateTrail(segIdx + 1, end)
            channel.invokeMethod("onProgress", mapOf("index" to (segIdx + 1).toDouble()))

            checkStopAtPoint(segIdx + 1)

            if (segIdx + 1 >= points.size - 1) {
                finishPlaybackAtLastPoint()
                return
            }

            val nextIdx = segIdx + 1
            val inHeading = segmentHeadings[segIdx]
            val outHeading = segmentHeadings[nextIdx]
            val diff = shortestAngle(inHeading, outHeading)

            currentSegmentIndex = nextIdx
            currentSegmentFraction = 0.0

            if (playbackSettings.canRotate && playbackSettings.dynamicRotation && Math.abs(diff) > turnAngleThreshold) {
                isTurning = true
                turnProgress = 0.0
                turnStartHeading = inHeading
                turnDeltaHeading = diff
            }

            Choreographer.getInstance().postFrameCallback(frameCallback)
        }
    }

    private fun finishPlaybackAtLastPoint() {
        val lastIdx = points.size - 1
        currentSegmentIndex = (points.size - 2).coerceAtLeast(0)
        currentSegmentFraction = 1.0
        isTurning = false
        turnProgress = 0.0
        val lastPoint = LatLng(points[lastIdx].lat, points[lastIdx].lng)
        vehicleMarker?.position = lastPoint
        if (followEnabled) {
            googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(lastPoint))
        }
        updateTrail(lastIdx, lastPoint)
        isPlaying = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        channel.invokeMethod("onProgress", mapOf("index" to lastIdx.toDouble()))
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "finished"))
    }

    private fun updateTrail(lastPassedIndex: Int, currentPos: LatLng) {
        if (!playbackSettings.drawTrail) return
        val currentTrail = ArrayList<LatLng>(lastPassedIndex + 2)
        for (i in 0..lastPassedIndex) {
            if (i < points.size) {
                currentTrail.add(LatLng(points[i].lat, points[i].lng))
            }
        }
        if (currentTrail.isEmpty() || !sameCoordinate(currentTrail.last(), currentPos)) {
            currentTrail.add(currentPos)
        }
        progressPolyline?.points = currentTrail
    }

    private fun checkStopAtPoint(pointIndex: Int) {
        if (pointIndex < 0 || pointIndex >= points.size) return
        if (playbackSettings.showStops && points[pointIndex].isStop) {
            checkAndAddStop(pointIndex)
            if (pointIndex != lastStopIndexPassed) {
                lastStopIndexPassed = pointIndex
                pauseForStop(pointIndex)
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
        for (i in 0..currentSegmentIndex) {
            if (i < points.size && points[i].isStop) checkAndAddStop(i)
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
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        playbackAnimator?.cancel()
        mainHandler.removeCallbacksAndMessages(null)
        currentSegmentIndex = 0
        currentSegmentFraction = 0.0
        isTurning = false
        turnProgress = 0.0
        lastFrameTimeMs = 0.0
        currentGlobalDistance = 0.0
        isPlaying = false
        isPausedForStop = false
        lastStopIndexPassed = -1
        maxRenderedStopIndex = -1
        lastAppliedIcon = null
        trailPoints.clear()
        lastTrailIdx = -1
        lastProgressEmitTimeMs = 0L
        vehicleMarker?.remove()
        vehicleMarker = null
        progressPolyline?.remove()
        progressPolyline = null
        stopMarkers.values.forEach { it.remove() }
        stopMarkers.clear()
    }

    fun dispose() {
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        playbackAnimator?.cancel()
        reset()
    }
}
