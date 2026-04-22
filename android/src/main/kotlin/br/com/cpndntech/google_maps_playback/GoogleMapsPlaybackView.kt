package br.com.cpndntech.google_maps_playback

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.view.View
import android.view.animation.LinearInterpolator
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.GoogleMap
import com.google.android.gms.maps.MapView
import com.google.android.gms.maps.OnMapReadyCallback
import com.google.android.gms.maps.model.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import android.util.Log
import java.net.URL
import kotlin.concurrent.thread

class GoogleMapsPlaybackView(
    private val context: Context,
    private val viewId: Int,
    private val creationParams: Map<String, Any>?,
    messenger: BinaryMessenger
) : PlatformView, OnMapReadyCallback, MethodChannel.MethodCallHandler {

    private val mapView: MapView = MapView(context)
    private var googleMap: GoogleMap? = null
    private val channel: MethodChannel = MethodChannel(messenger, "br.com.cpndntech.google_maps_playback/playback_$viewId")

    private var points: List<GoogleMapsPlaybackPoint> = emptyList()
    private var cumulativeDistances = mutableListOf<Double>()
    private var totalDistance = 0.0
    
    private var showStops: Boolean = false
    private var initialMapType: Int = GoogleMap.MAP_TYPE_NORMAL
    private var isTrafficEnabled: Boolean = false
    private var isDarkMode: Boolean = false
    private var initialStyle: String? = null
    private var canRotate: Boolean = true
    private var dynamicRotation: Boolean = false
    private var baseSpeed: Double = 60.0
    
    private var vehicleMarker: Marker? = null
    private var progressPolyline: Polyline? = null
    private val trailPoints = mutableListOf<LatLng>()
    private val stopMarkers = mutableMapOf<Int, Marker>()
    
    private val customMarkers = mutableMapOf<String, Marker>()
    private val customCircles = mutableMapOf<String, Circle>()
    private val customPolylines = mutableMapOf<String, Polyline>()

    private var currentGlobalDistance = 0.0
    private var lastStopIndexPassed = -1
    private var isPausedForStop = false
    private var playbackSpeed = 1
    private var animator: ValueAnimator? = null
    private var isPlaying = false
    private var followVehicle = true
    private var isAnimatingCamera = false
    private var stopIcon: BitmapDescriptor? = null
    
    private val followHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val followRunnable = Runnable { 
        followVehicle = true 
    }
    
    private var polylineColor: Int = Color.BLUE
    private var vehicleIconNormal: BitmapDescriptor? = null
    private var vehicleIconFlipped: BitmapDescriptor? = null

    init {
        mapView.onCreate(null)
        mapView.onStart()
        mapView.onResume()
        mapView.getMapAsync(this)
        channel.setMethodCallHandler(this)

        creationParams?.let { params ->
            val rawPoints = params["points"] as? List<Map<String, Any>>
            val pts = mutableListOf<GoogleMapsPlaybackPoint>()
            rawPoints?.forEachIndexed { index, map ->
                pts.add(GoogleMapsPlaybackPoint(
                    lat = map["lat"] as Double,
                    lng = map["lng"] as Double,
                    bearing = (map["bearing"] as? Double) ?: 0.0,
                    isStop = map["isStop"] as? Boolean == true
                ))
            }
            points = pts
            
            calculateDistances()

            showStops = (params["showStops"] as? Boolean) ?: false
            baseSpeed = (params["baseSpeed"] as? Double) ?: 60.0
            
            (params["vehicleIcon"] as? ByteArray)?.let { bytes ->
                try {
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    vehicleIconNormal = BitmapDescriptorFactory.fromBitmap(bitmap)
                    val flipped = flipBitmapHorizontally(bitmap)
                    vehicleIconFlipped = BitmapDescriptorFactory.fromBitmap(flipped)    
                } catch (e: Exception) { }
            }

            (params["stopIcon"] as? ByteArray)?.let { bytes ->
                try {
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    stopIcon = BitmapDescriptorFactory.fromBitmap(bitmap)
                } catch (e: Exception) { }
            }

            initialMapType = (params["mapType"] as? Int) ?: GoogleMap.MAP_TYPE_NORMAL
            isTrafficEnabled = (params["showTraffic"] as? Boolean) ?: false
            isDarkMode = (params["isDark"] as? Boolean) ?: false
            initialStyle = params["style"] as? String
            canRotate = (params["canRotate"] as? Boolean) ?: true
            dynamicRotation = (params["dynamicRotation"] as? Boolean) ?: false

            val polylineColorHex = (params["polylineColor"] as? String) ?: "#0000FF"
            try {
                polylineColor = Color.parseColor(polylineColorHex)
            } catch (e: Exception) {
                polylineColor = Color.BLUE
            }
        }
    }

    private fun calculateDistances() {
        cumulativeDistances.clear()
        totalDistance = 0.0
        cumulativeDistances.add(0.0)
        
        for (i in 0 until points.size - 1) {
            val p1 = points[i]
            val p2 = points[i+1]
            val results = FloatArray(1)
            android.location.Location.distanceBetween(p1.lat, p1.lng, p2.lat, p2.lng, results)
            val dist = results[0].toDouble()
            totalDistance += dist
            cumulativeDistances.add(totalDistance)
        }
    }

    override fun getView(): View = mapView

    override fun onMapReady(map: GoogleMap) {
        googleMap = map
        
        map.setOnCameraMoveStartedListener { reason ->
            if (reason == GoogleMap.OnCameraMoveStartedListener.REASON_GESTURE) {
                followVehicle = false
                followHandler.removeCallbacks(followRunnable)
            }
        }

        map.setOnCameraIdleListener {
            if (!followVehicle) {
                followHandler.removeCallbacks(followRunnable)
                followHandler.postDelayed(followRunnable, 500L)
            }
        }
        
        setupMap()
    }

    override fun dispose() {
        animator?.cancel()
        animator = null
        followHandler.removeCallbacks(followRunnable)
        googleMap?.clear()
        mapView.onDestroy()
        channel.setMethodCallHandler(null)
    }

    private fun setupMap() {
        val map = googleMap ?: return
        map.mapType = initialMapType
        map.isTrafficEnabled = isTrafficEnabled
        
        map.uiSettings.isZoomGesturesEnabled = (creationParams?.get("zoomGesturesEnabled") as? Boolean) ?: true
        map.uiSettings.isScrollGesturesEnabled = (creationParams?.get("scrollGesturesEnabled") as? Boolean) ?: true
        map.uiSettings.isTiltGesturesEnabled = (creationParams?.get("tiltGesturesEnabled") as? Boolean) ?: true
        map.uiSettings.isRotateGesturesEnabled = (creationParams?.get("rotateGesturesEnabled") as? Boolean) ?: true
        map.uiSettings.isZoomControlsEnabled = false
        
        val showUserLocation = (creationParams?.get("showUserLocation") as? Boolean) ?: false
        if (showUserLocation) {
            try {
                map.isMyLocationEnabled = true
            } catch (e: SecurityException) {
                // Ignore if permissions are not granted
            }
        }
        
        if (isDarkMode) {
            initialStyle?.let { style ->
                map.setMapStyle(MapStyleOptions(style))
            } ?: run {
                map.setMapStyle(MapStyleOptions("[{\"elementType\": \"geometry\",\"stylers\": [{\"color\": \"#242f3e\"}]}]"))
            }
        }

        if (points.isEmpty()) return

        val firstPoint = LatLng(points[0].lat, points[0].lng)
        map.moveCamera(CameraUpdateFactory.newLatLngZoom(firstPoint, 16f))

        var initialRotation = if (canRotate) points[0].bearing.toFloat() else 0f
        if (canRotate && dynamicRotation && points.size > 1) {
            initialRotation = computeHeading(points[0].lat, points[0].lng, points[1].lat, points[1].lng).toFloat()
        }

        vehicleMarker = map.addMarker(
            MarkerOptions()
                .position(firstPoint)
                .rotation(initialRotation)
                .anchor(0.5f, 0.5f)
                .flat(true)
                .zIndex(10f)
        )
        
        val effectiveIcon = vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)
        val effectiveIconFlipped = vehicleIconFlipped ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)

        if (canRotate) {
            vehicleMarker?.setIcon(effectiveIcon)
        } else {
            val isGoingLeft = points[0].bearing > 180
            vehicleMarker?.setIcon(if (isGoingLeft) effectiveIcon else effectiveIconFlipped)
        }

        val progressOptions = PolylineOptions()
            .width(12f)
            .color(polylineColor)
            .geodesic(true)
            .zIndex(2f)
        progressPolyline = map.addPolyline(progressOptions)

        if (showStops) renderStops()

        map.setOnMarkerClickListener { marker ->
            val index = marker.tag as? Int
            if (index != null) {
                seekTo(index)
                channel.invokeMethod("onStopClick", mapOf("index" to index))
            }
            true
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "play" -> {
                if (!isPlaying) {
                    startAnimation()
                    channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "playing"))
                }
                result.success(null)
            }
            "pause" -> {
                isPlaying = false
                animator?.cancel()
                channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "paused"))
                result.success(null)
            }
            "seek" -> {
                val index = call.argument<Int>("index") ?: 0
                seekTo(index)
                result.success(null)
            }
            "getPlaybackDuration" -> {
                var stopsCount = 0
                if (showStops) {
                    stopsCount = points.count { it.isStop }
                }
                val travelTime = totalDistance / (baseSpeed * playbackSpeed)
                val stopTime = stopsCount * (Math.max(100L, (2000L / playbackSpeed).toLong()) / 1000.0)
                result.success(travelTime + stopTime)
            }
            "zoomIn" -> {
                isAnimatingCamera = true
                googleMap?.animateCamera(CameraUpdateFactory.zoomIn(), object : GoogleMap.CancelableCallback {
                    override fun onFinish() { isAnimatingCamera = false }
                    override fun onCancel() { isAnimatingCamera = false }
                })
                result.success(null)
            }
            "zoomOut" -> {
                isAnimatingCamera = true
                googleMap?.animateCamera(CameraUpdateFactory.zoomOut(), object : GoogleMap.CancelableCallback {
                    override fun onFinish() { isAnimatingCamera = false }
                    override fun onCancel() { isAnimatingCamera = false }
                })
                result.success(null)
            }
            "setSpeed" -> {
                playbackSpeed = call.argument<Int>("speed") ?: 1
                if (isPlaying) {
                    animator?.cancel()
                    startAnimation()
                }
                result.success(null)
            }
            "toggleStops" -> {
                showStops = call.argument<Boolean>("show") ?: false
                if (showStops) renderStops() else clearStops()
                result.success(null)
            }
            "setMapType" -> {
                val mapType = call.argument<Int>("mapType") ?: 1
                googleMap?.mapType = mapType
                result.success(null)
            }
            "setTrafficEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                googleMap?.isTrafficEnabled = enabled
                result.success(null)
            }
            "setMapStyle" -> {
                val style = call.argument<String>("style")
                googleMap?.setMapStyle(if (style != null) MapStyleOptions(style) else null)
                result.success(null)
            }
            "updateOptions" -> {
                val options = call.arguments as? Map<String, Any> ?: return
                if (options.containsKey("baseSpeed")) {
                    baseSpeed = (options["baseSpeed"] as Double)
                    if (isPlaying) { animator?.cancel(); startAnimation() }
                }
                if (options.containsKey("showUserLocation")) {
                    try { googleMap?.isMyLocationEnabled = options["showUserLocation"] as Boolean } catch (e: Exception) {}
                }
                if (options.containsKey("mapType")) googleMap?.mapType = options["mapType"] as Int
                if (options.containsKey("showTraffic")) googleMap?.isTrafficEnabled = options["showTraffic"] as Boolean
                if (options.containsKey("zoomGesturesEnabled")) googleMap?.uiSettings?.isZoomGesturesEnabled = options["zoomGesturesEnabled"] as Boolean
                if (options.containsKey("scrollGesturesEnabled")) googleMap?.uiSettings?.isScrollGesturesEnabled = options["scrollGesturesEnabled"] as Boolean
                if (options.containsKey("tiltGesturesEnabled")) googleMap?.uiSettings?.isTiltGesturesEnabled = options["tiltGesturesEnabled"] as Boolean
                if (options.containsKey("rotateGesturesEnabled")) googleMap?.uiSettings?.isRotateGesturesEnabled = options["rotateGesturesEnabled"] as Boolean
                if (options.containsKey("isDark")) {
                    val isDark = options["isDark"] as Boolean
                    if (isDark) {
                        val style = options["style"] as? String
                        if (style != null) googleMap?.setMapStyle(MapStyleOptions(style))
                        else googleMap?.setMapStyle(MapStyleOptions("[{\"elementType\": \"geometry\",\"stylers\": [{\"color\": \"#242f3e\"}]}]"))
                    } else {
                        googleMap?.setMapStyle(null)
                    }
                }
                if (options.containsKey("canRotate")) canRotate = options["canRotate"] as Boolean
                if (options.containsKey("dynamicRotation")) dynamicRotation = options["dynamicRotation"] as Boolean
                if (options.containsKey("showStops")) {
                    showStops = options["showStops"] as Boolean
                    if (showStops) renderStops() else clearStops()
                }
                result.success(null)
            }
            "addMarkers" -> {
                val markers = call.argument<List<Map<String, Any>>>("markers") ?: emptyList()
                markers.forEach { m ->
                    val id = m["id"] as String
                    val lat = m["lat"] as Double
                    val lng = m["lng"] as Double
                    val anchorX = (m["anchorX"] as Double).toFloat()
                    val anchorY = (m["anchorY"] as Double).toFloat()
                    val rotation = (m["rotation"] as Double).toFloat()
                    val zIndex = (m["zIndex"] as Double).toFloat()
                    val flat = m["flat"] as Boolean

                    val options = MarkerOptions()
                        .position(LatLng(lat, lng))
                        .anchor(anchorX, anchorY)
                        .rotation(rotation)
                        .zIndex(zIndex)
                        .flat(flat)

                    val iconBytes = m["iconBytes"] as? ByteArray
                    if (iconBytes != null) {
                        try {
                            val bitmap = BitmapFactory.decodeByteArray(iconBytes, 0, iconBytes.size)
                            options.icon(BitmapDescriptorFactory.fromBitmap(bitmap))
                        } catch (e: Exception) {}
                    }

                    val marker = googleMap?.addMarker(options)
                    if (marker != null) {
                        customMarkers[id]?.remove()
                        customMarkers[id] = marker
                    }
                }
                result.success(null)
            }
            "clearMarkers" -> {
                customMarkers.values.forEach { it.remove() }
                customMarkers.clear()
                result.success(null)
            }
            "addCircles" -> {
                val circles = call.argument<List<Map<String, Any>>>("circles") ?: emptyList()
                circles.forEach { c ->
                    val id = c["id"] as String
                    val lat = c["lat"] as Double
                    val lng = c["lng"] as Double
                    val radius = c["radius"] as Double
                    val fillColor = Color.parseColor(c["fillColor"] as String)
                    val strokeColor = Color.parseColor(c["strokeColor"] as String)
                    val strokeWidth = (c["strokeWidth"] as Double).toFloat()
                    val zIndex = (c["zIndex"] as Double).toFloat()

                    val options = CircleOptions()
                        .center(LatLng(lat, lng))
                        .radius(radius)
                        .fillColor(fillColor)
                        .strokeColor(strokeColor)
                        .strokeWidth(strokeWidth)
                        .zIndex(zIndex)

                    val circle = googleMap?.addCircle(options)
                    if (circle != null) {
                        customCircles[id]?.remove()
                        customCircles[id] = circle
                    }
                }
                result.success(null)
            }
            "clearCircles" -> {
                customCircles.values.forEach { it.remove() }
                customCircles.clear()
                result.success(null)
            }
            "addPolylines" -> {
                val polylines = call.argument<List<Map<String, Any>>>("polylines") ?: emptyList()
                polylines.forEach { p ->
                    val id = p["id"] as String
                    val pointsRaw = p["points"] as List<Map<String, Double>>
                    val pts = pointsRaw.map { LatLng(it["lat"]!!, it["lng"]!!) }
                    val color = Color.parseColor(p["color"] as String)
                    val width = (p["width"] as Double).toFloat()
                    val zIndex = (p["zIndex"] as Double).toFloat()

                    val options = PolylineOptions()
                        .addAll(pts)
                        .color(color)
                        .width(width)
                        .zIndex(zIndex)

                    val polyline = googleMap?.addPolyline(options)
                    if (polyline != null) {
                        customPolylines[id]?.remove()
                        customPolylines[id] = polyline
                    }
                }
                result.success(null)
            }
            "clearPolylines" -> {
                customPolylines.values.forEach { it.remove() }
                customPolylines.clear()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun flipBitmapHorizontally(original: Bitmap): Bitmap {
        val matrix = android.graphics.Matrix()
        matrix.preScale(-1f, 1f)
        return Bitmap.createBitmap(original, 0, 0, original.width, original.height, matrix, true)
    }

    private fun startAnimation() {
        if (totalDistance <= 0) return
        isPlaying = true
        
        val startDist = currentGlobalDistance
        val endDist = totalDistance
        
        if (startDist >= endDist) {
            currentGlobalDistance = 0.0
            startAnimation()
            return
        }

        val remainingDist = endDist - startDist
        val durationMs = ((remainingDist / baseSpeed) * 1000 / playbackSpeed).toLong()

        animator?.cancel()
        animator = ValueAnimator.ofFloat(startDist.toFloat(), endDist.toFloat()).apply {
            duration = durationMs
            interpolator = LinearInterpolator()
            addUpdateListener { anim ->
                currentGlobalDistance = (anim.animatedValue as Float).toDouble()
                updateVehiclePosition(currentGlobalDistance)
                
                val segmentIndex = getSegmentIndexForDistance(currentGlobalDistance)
                val segmentStartDist = cumulativeDistances[segmentIndex]
                val segmentEndDist = cumulativeDistances[segmentIndex + 1]
                val localT = (currentGlobalDistance - segmentStartDist) / (segmentEndDist - segmentStartDist)
                
                channel.invokeMethod("onProgress", mapOf("index" to segmentIndex.toDouble() + localT))
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    if (isPlaying && animator == animation && currentGlobalDistance >= (totalDistance - 0.1)) {
                        currentGlobalDistance = 0.0
                        isPlaying = false
                        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "finished"))
                    }
                }
            })
            start()
        }
    }

    private fun updateVehiclePosition(distance: Double) {
        if (points.size < 2) return
        
        val idx = getSegmentIndexForDistance(distance)
        
        if (showStops) {
            for (i in 0..idx) {
                checkAndAddStop(i)
            }
        }
        
        val start = points[idx]
        val end = points[idx + 1]
        
        val segmentStartDist = cumulativeDistances[idx]
        val segmentEndDist = cumulativeDistances[idx + 1]
        val t = ((distance - segmentStartDist) / (segmentEndDist - segmentStartDist)).toFloat().coerceIn(0f, 1f)

        val lat = start.lat + (end.lat - start.lat) * t.toDouble()
        val lng = start.lng + (end.lng - start.lng) * t.toDouble()
        val pos = LatLng(lat, lng)

        var rotation: Float
        if (dynamicRotation) {
            rotation = computeHeading(start.lat, start.lng, end.lat, end.lng).toFloat()
        } else {
            var delta = (end.bearing - start.bearing).toFloat()
            if (delta > 180) delta -= 360
            if (delta < -180) delta += 360
            rotation = start.bearing.toFloat() + delta * t
        }

        trailPoints.add(pos)
        progressPolyline?.points = trailPoints
        
        vehicleMarker?.position = pos
        
        val effectiveIcon = vehicleIconNormal ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)
        val effectiveIconFlipped = vehicleIconFlipped ?: BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_CYAN)

        if (canRotate) {
            vehicleMarker?.rotation = rotation
            vehicleMarker?.setIcon(effectiveIcon)
        } else {
            val isGoingLeft = rotation > 180
            vehicleMarker?.setIcon(if (isGoingLeft) effectiveIcon else effectiveIconFlipped)
        }

        if (followVehicle && !isAnimatingCamera) {
            googleMap?.moveCamera(CameraUpdateFactory.newLatLng(pos))
        }

        if (showStops && points[idx].isStop && idx != lastStopIndexPassed && !isPausedForStop) {
            lastStopIndexPassed = idx
            pauseForStop()
        }
    }

    private fun pauseForStop() {
        isPausedForStop = true
        animator?.pause()
        
        val pauseDuration = (2000L / playbackSpeed.coerceAtLeast(1)).coerceAtLeast(100L)
        
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            isPausedForStop = false
            animator?.resume()
        }, pauseDuration)
    }

    private fun getSegmentIndexForDistance(distance: Double): Int {
        if (distance <= 0) return 0
        if (distance >= totalDistance) return points.size - 2
        
        for (i in 0 until cumulativeDistances.size - 1) {
            if (distance < cumulativeDistances[i + 1]) {
                return i
            }
        }
        return points.size - 2
    }

    private fun seekTo(index: Int) {
        isPlaying = false
        animator?.cancel()
        val safeIndex = index.coerceIn(0, points.size - 1)
        currentGlobalDistance = cumulativeDistances[safeIndex]
        
        val p = points[safeIndex]
        val pos = LatLng(p.lat, p.lng)
        
        updateProgressTrail(pos, safeIndex)
        if (showStops) renderStops()
        
        var initialRotation = if (canRotate) p.bearing.toFloat() else 0f
        if (canRotate && dynamicRotation && safeIndex < points.size - 1) {
            val nextP = points[safeIndex + 1]
            initialRotation = computeHeading(p.lat, p.lng, nextP.lat, nextP.lng).toFloat()
        }

        vehicleMarker?.position = pos
        vehicleMarker?.rotation = initialRotation
        
        followVehicle = true
        googleMap?.moveCamera(CameraUpdateFactory.newLatLng(pos))
        
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "paused"))
        channel.invokeMethod("onProgress", mapOf("index" to safeIndex.toDouble()))  
    }

    private fun updateProgressTrail(currentPos: LatLng, index: Int) {
        trailPoints.clear()
        for (i in 0 until index) {
            trailPoints.add(LatLng(points[i].lat, points[i].lng))
        }
        trailPoints.add(currentPos)
        progressPolyline?.points = trailPoints
    }

    private fun checkAndAddStop(index: Int) {
        val map = googleMap ?: return
        if (points[index].isStop) {
            if (!stopMarkers.containsKey(index)) {
                val p = points[index]
                val markerOptions = MarkerOptions()
                    .position(LatLng(p.lat, p.lng))
                    .alpha(0.9f)
                    .zIndex(5f) 
                
                val icon = stopIcon ?: BitmapDescriptorFactory.defaultMarker()
                markerOptions.icon(icon)
                
                val marker = map.addMarker(markerOptions)
                marker?.tag = index
                marker?.let { stopMarkers[index] = it }
            }
        }
    }

    private fun renderStops() {
        val map = googleMap ?: return
        clearStops()
        val currentIdx = getSegmentIndexForDistance(currentGlobalDistance)
        
        for (i in 0..currentIdx) {
            if (points[i].isStop) {
                checkAndAddStop(i)
            }
        }
    }

    private fun clearStops() {
        stopMarkers.values.forEach { it.remove() }
        stopMarkers.clear()
    }

    private fun computeHeading(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val fromLat = Math.toRadians(lat1)
        val fromLng = Math.toRadians(lng1)
        val toLat = Math.toRadians(lat2)
        val toLng = Math.toRadians(lng2)
        val dLng = toLng - fromLng
        val y = kotlin.math.sin(dLng) * kotlin.math.cos(toLat)
        val x = kotlin.math.cos(fromLat) * kotlin.math.sin(toLat) - kotlin.math.sin(fromLat) * kotlin.math.cos(toLat) * kotlin.math.cos(dLng)
        val heading = kotlin.math.atan2(y, x)
        return (Math.toDegrees(heading) + 360) % 360
    }
}

data class GoogleMapsPlaybackPoint(val lat: Double, val lng: Double, val bearing: Double, val isStop: Boolean)
