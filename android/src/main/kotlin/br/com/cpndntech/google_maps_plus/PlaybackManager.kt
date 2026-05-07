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

    var playbackSettings = PlaybackSettings()
    
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
    private var progressPolyline: Polyline? = null
    private val stopMarkers = mutableMapOf<Int, Marker>()
    
    private var currentGlobalDistance = 0.0
    private var playbackSpeed = 1
    private var playbackAnimator: ValueAnimator? = null
    var isPlaying = false
        private set
    private var isPausedForStop = false
    private var lastStopIndexPassed = -1
    private var lastTrailIdx = -1
    private val trailPoints = mutableListOf<LatLng>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var maxRenderedStopIndex = -1  // Controla até qual índice renderizar stops

    private val maxAnchorDistanceMeters = 80.0
    private val maxLengthRatio = 8.0

    var followEnabled = true

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

    fun setupInitialState() {
        if (points.isEmpty()) return

        prepareVehicleIcons()
        
        val firstPos = LatLng(points[0].lat, points[0].lng)
        val initialHeading = if (points.size > 1) {
            computeHeading(firstPos, LatLng(points[1].lat, points[1].lng))
        } else {
            points[0].bearing.toFloat()
        }
        
        vehicleMarker?.remove()
        vehicleMarker = googleMap.addMarker(
            MarkerOptions()
                .position(firstPos)
                .anchor(0.5f, 0.5f)
                .flat(true)
                .zIndex(10f)
                .apply {
                    icon(vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN))
                }
        )

        applyVehicleAppearance(initialHeading)

        progressPolyline?.remove()
        if (playbackSettings.drawTrail) {
            progressPolyline = googleMap.addPolyline(PolylineOptions().width(5f * density).color(Convert.toColor(playbackSettings.polylineColor)).zIndex(2f).geodesic(false))
        }

        if (playbackSettings.showStops) renderStops()
        
        googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLngZoom(firstPos, 16f))
        
        if (playbackSettings.autoStart) {
            play()
        }
    }

    fun play() {
        if (totalDistance <= 0 || isPlaying) return
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
    }

    fun pause() {
        isPlaying = false
        isPausedForStop = false
        mainHandler.removeCallbacksAndMessages(null)
        playbackAnimator?.cancel()
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
        currentGlobalDistance = cumulativeDistances[safeIndex]
        lastStopIndexPassed = safeIndex - 1  // permite que o stop nesse índice dispare a pausa ao retomar

        // Remove marcadores de parada que estão além do índice buscado
        val keysToRemove = stopMarkers.keys.filter { it >= safeIndex }
        keysToRemove.forEach { key ->
            stopMarkers[key]?.remove()
            stopMarkers.remove(key)
        }
        maxRenderedStopIndex = safeIndex - 1  // Não reconstrói stops além deste índice

        // A trilha snapped é reconstruída no updateVehiclePosition; o fallback usa os pontos originais.
        trailPoints.clear()
        if (snappedSegments.isEmpty()) {
            for (i in 0 until safeIndex) {
                trailPoints.add(LatLng(points[i].lat, points[i].lng))
            }
            lastTrailIdx = safeIndex - 1
            progressPolyline?.points = trailPoints.toList()
        } else {
            lastTrailIdx = -1
            progressPolyline?.points = emptyList()
        }

        updateVehiclePosition(currentGlobalDistance)
        channel.invokeMethod("onProgress", mapOf("index" to safeIndex.toDouble()))
    }

    fun setSpeed(speed: Int) {
        playbackSpeed = speed
        if (isPlaying) {
            pause()
            play()
        }
    }

    private fun updateVehiclePosition(distance: Double) {
        if (points.size < 2) return
        val idx = getSegmentIndexForDistance(distance)
        val segmentDist = cumulativeDistances[idx + 1] - cumulativeDistances[idx]
        val t = if (segmentDist > 0) ((distance - cumulativeDistances[idx]) / segmentDist) else 0.0
        val snappedProgress = if (playbackSettings.useSnappedRoute) getProgressOnSnappedSegment(idx, t) else null
        
        // O veículo segue o subtrecho snapped correspondente ao trecho original A -> B (se habilitado).
        val pos = if (snappedProgress != null) {
            snappedProgress.position
        } else {
            // Fallback: interpolar entre pontos originais (Catmull-Rom)
            val clampedT = t.toFloat().coerceIn(0f, 1f)
            
            val p1 = points[idx]
            val p2 = points[idx + 1]
            val p0 = if (idx > 0) points[idx - 1] else p1
            val p3 = if (idx + 2 < points.size) points[idx + 2] else p2
            
            interpolateCatmullRom(p0, p1, p2, p3, clampedT)
        }
        
        vehicleMarker?.position = pos
        val heading = if (snappedProgress != null) {
            snappedProgress.heading
        } else if (playbackSettings.dynamicRotation) {
            val clampedT = t.toFloat().coerceIn(0f, 1f)

            val p1 = points[idx]
            val p2 = points[idx + 1]
            val p0 = if (idx > 0) points[idx - 1] else p1
            val p3 = if (idx + 2 < points.size) points[idx + 2] else p2

            getCatmullRomHeading(p0, p1, p2, p3, clampedT)
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
                if (idx > lastTrailIdx) {
                    for (i in (lastTrailIdx + 1)..idx) {
                        if (i < points.size) {
                            trailPoints.add(LatLng(points[i].lat, points[i].lng))
                        }
                    }
                    lastTrailIdx = idx
                }
                progressPolyline?.points = trailPoints.toList()
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
        if (playbackSettings.canRotate) {
            vehicleMarker?.rotation = heading
            vehicleMarker?.setIcon(vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN))
            return
        }

        val isGoingLeft = heading > 180f
        vehicleMarker?.rotation = 0f
        vehicleMarker?.setIcon(
            if (isGoingLeft) {
                vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)
            } else {
                vehicleIconFlipped ?: vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)
            }
        )
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
        isPlaying = false
        isPausedForStop = false
        lastStopIndexPassed = -1
        lastTrailIdx = -1
        maxRenderedStopIndex = -1
        trailPoints.clear()
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

    private fun interpolateCatmullRom(p0: GoogleMapsPlaybackPoint, p1: GoogleMapsPlaybackPoint, p2: GoogleMapsPlaybackPoint, p3: GoogleMapsPlaybackPoint, t: Float): LatLng {
        val t2 = t * t
        val t3 = t2 * t
        
        val lat = 0.5 * ((2 * p1.lat) + (-p0.lat + p2.lat) * t + (2 * p0.lat - 5 * p1.lat + 4 * p2.lat - p3.lat) * t2 + (-p0.lat + 3 * p1.lat - 3 * p2.lat + p3.lat) * t3)
        val lng = 0.5 * ((2 * p1.lng) + (-p0.lng + p2.lng) * t + (2 * p0.lng - 5 * p1.lng + 4 * p2.lng - p3.lng) * t2 + (-p0.lng + 3 * p1.lng - 3 * p2.lng + p3.lng) * t3)
        
        return LatLng(lat, lng)
    }

    private fun getCatmullRomHeading(p0: GoogleMapsPlaybackPoint, p1: GoogleMapsPlaybackPoint, p2: GoogleMapsPlaybackPoint, p3: GoogleMapsPlaybackPoint, t: Float): Float {
        val t2 = t * t
        
        // Derivative of Catmull-Rom
        val dLat = 0.5 * ((-p0.lat + p2.lat) + 2 * (2 * p0.lat - 5 * p1.lat + 4 * p2.lat - p3.lat) * t + 3 * (-p0.lat + 3 * p1.lat - 3 * p2.lat + p3.lat) * t2)
        val dLng = 0.5 * ((-p0.lng + p2.lng) + 2 * (2 * p0.lng - 5 * p1.lng + 4 * p2.lng - p3.lng) * t + 3 * (-p0.lng + 3 * p1.lng - 3 * p2.lng + p3.lng) * t2)
        
        return (Math.toDegrees(Math.atan2(dLng, dLat)).toFloat() + 360f) % 360f
    }
}
