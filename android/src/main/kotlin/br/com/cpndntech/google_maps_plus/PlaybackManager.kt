package br.com.cpndntech.google_maps_plus

import android.animation.ValueAnimator
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
        playbackAnimator?.cancel()
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "paused"))
    }

    fun seekTo(index: Int) {
        pause()
        currentGlobalDistance = cumulativeDistances[index.coerceIn(0, points.size - 1)]
        updateVehiclePosition(currentGlobalDistance)
        channel.invokeMethod("onProgress", mapOf("index" to index.toDouble()))
    }

    fun setSpeed(speed: Int) {
        playbackSpeed = speed
        if (isPlaying) {
            playbackAnimator?.cancel()
            play()
        }
    }

    private fun updateVehiclePosition(distance: Double) {
        if (points.size < 2) return
        val idx = getSegmentIndexForDistance(distance)
        val segmentDist = cumulativeDistances[idx + 1] - cumulativeDistances[idx]
        val t = if (segmentDist > 0) ((distance - cumulativeDistances[idx]) / segmentDist).toFloat().coerceIn(0f, 1f) else 0f
        
        val pos = LatLng(
            points[idx].lat + (points[idx + 1].lat - points[idx].lat) * t,
            points[idx].lng + (points[idx + 1].lng - points[idx].lng) * t
        )
        
        vehicleMarker?.position = pos
        if (playbackSettings.canRotate) {
            val rotation = if (playbackSettings.dynamicRotation) {
                // compute bearing between points[idx] and points[idx+1]
                val results = FloatArray(2)
                android.location.Location.distanceBetween(
                    points[idx].lat, points[idx].lng,
                    points[idx + 1].lat, points[idx + 1].lng,
                    results
                )
                results[1] // initial bearing
            } else {
                points[idx].bearing.toFloat()
            }
            vehicleMarker?.rotation = rotation
        }

        if (followEnabled) {
            googleMap.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLng(pos))
        }

        if (playbackSettings.drawTrail) {
            val trailPoints = points.subList(0, idx + 1).map { LatLng(it.lat, it.lng) }.toMutableList()
            trailPoints.add(pos)
            progressPolyline?.points = trailPoints
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
        currentGlobalDistance = 0.0
        isPlaying = false
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
