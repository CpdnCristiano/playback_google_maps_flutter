package br.com.cpndntech.google_maps_plus

import android.animation.ValueAnimator
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
    var playbackSettings = PlaybackSettings()
    
    private var points: List<GoogleMapsPlaybackPoint> = emptyList()
    private var cumulativeDistances = mutableListOf<Double>()
    private var totalDistance = 0.0
    
    private var vehicleMarker: Marker? = null
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

    var followEnabled = true

    fun setPoints(newPoints: List<GoogleMapsPlaybackPoint>) {
        this.points = newPoints
        calculateDistances()
        reset()
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
        
        val firstPos = LatLng(points[0].lat, points[0].lng)
        
        vehicleMarker?.remove()
        vehicleMarker = googleMap.addMarker(MarkerOptions().position(firstPos).anchor(0.5f, 0.5f).flat(true).zIndex(10f).apply {
            Convert.toBitmapDescriptor(playbackSettings.vehicleIcon)?.let { icon(it) } ?: icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN))
        })

        progressPolyline?.remove()
        if (playbackSettings.drawTrail) {
            progressPolyline = googleMap.addPolyline(PolylineOptions().width(5f * density).color(Convert.toColor(playbackSettings.polylineColor)).zIndex(2f).geodesic(true))
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
        playbackAnimator?.pause()
        channel.invokeMethod("onStopReached", mapOf("index" to index))
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "stopped"))

        val delayMs = (2000L / playbackSpeed)
        mainHandler.postDelayed({
            if (isPausedForStop) {
                isPausedForStop = false
                playbackAnimator?.resume()
                channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "playing"))
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

        // Reconstrói a trilha até a posição buscada
        trailPoints.clear()
        for (i in 0 until safeIndex) {
            trailPoints.add(LatLng(points[i].lat, points[i].lng))
        }
        lastTrailIdx = safeIndex - 1  // updateVehiclePosition ancora em points[safeIndex] ao rodar
        progressPolyline?.points = trailPoints.toList()

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
        val t = if (segmentDist > 0) ((distance - cumulativeDistances[idx]) / segmentDist).toFloat().coerceIn(0f, 1f) else 0f
        
        // Catmull-Rom Interpolation
        val p1 = points[idx]
        val p2 = points[idx + 1]
        val p0 = if (idx > 0) points[idx - 1] else p1
        val p3 = if (idx + 2 < points.size) points[idx + 2] else p2
        
        val pos = interpolateCatmullRom(p0, p1, p2, p3, t)
        
        vehicleMarker?.position = pos
        if (playbackSettings.canRotate) {
            val rotation = if (playbackSettings.dynamicRotation) {
                getCatmullRomHeading(p0, p1, p2, p3, t)
            } else {
                points[idx].bearing.toFloat()
            }
            vehicleMarker?.rotation = rotation
        }

        if (followEnabled) {
            googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(pos))
        }

        if (playbackSettings.drawTrail) {
            // Ancora nos waypoints exatos ao entrar em cada novo segmento,
            // depois adiciona a posição Catmull-Rom — trilha nunca ultrapassa o carro
            if (idx > lastTrailIdx) {
                for (i in maxOf(0, lastTrailIdx + 1)..idx) {
                    trailPoints.add(LatLng(points[i].lat, points[i].lng))
                }
                lastTrailIdx = idx
            }
            trailPoints.add(pos)
            progressPolyline?.points = trailPoints.toList()
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
        points.forEachIndexed { index, point ->
            if (point.isStop) checkAndAddStop(index)
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
