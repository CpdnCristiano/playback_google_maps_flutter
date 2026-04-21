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
    private var baseSpeed: Double = 60.0
    
    private var vehicleMarker: Marker? = null
    private var progressPolyline: Polyline? = null
    private val trailPoints = mutableListOf<LatLng>()
    private val stopMarkers = mutableMapOf<Int, Marker>()

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
        Log.i("GoogleMapsPlayback", "init: GoogleMapsPlaybackView criada para o ID $viewId")
        mapView.onCreate(null)
        mapView.onStart()
        mapView.onResume()
        mapView.getMapAsync(this)
        channel.setMethodCallHandler(this)

        // Parse params
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
                } catch (e: Exception) {
                    Log.e("GoogleMapsPlayback", "init: Erro ao decodificar ícone do veículo: ${e.message}")
                }
            }

            (params["stopIcon"] as? ByteArray)?.let { bytes ->
                try {
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    stopIcon = BitmapDescriptorFactory.fromBitmap(bitmap)
                } catch (e: Exception) {
                    Log.e("GoogleMapsPlayback", "init: Erro ao decodificar ícone de stop: ${e.message}")
                }
            }

            initialMapType = (params["mapType"] as? Int) ?: GoogleMap.MAP_TYPE_NORMAL
            isTrafficEnabled = (params["showTraffic"] as? Boolean) ?: false
            isDarkMode = (params["isDark"] as? Boolean) ?: false
            initialStyle = params["style"] as? String
            canRotate = (params["canRotate"] as? Boolean) ?: true

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
        
        // Detecta se o usuário mexeu no mapa manualmente
        map.setOnCameraMoveStartedListener { reason ->
            if (reason == GoogleMap.OnCameraMoveStartedListener.REASON_GESTURE) {
                followVehicle = false
                followHandler.removeCallbacks(followRunnable)
            }
        }

        // Quando o mapa para de mover (soltou o dedo), volta a seguir após 500ms
        map.setOnCameraIdleListener {
            if (!followVehicle) {
                followHandler.removeCallbacks(followRunnable)
                followHandler.postDelayed(followRunnable, 500L) // 500ms
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
        
        // Habilita gestos de interação
        map.uiSettings.isZoomGesturesEnabled = true
        map.uiSettings.isScrollGesturesEnabled = true
        map.uiSettings.isTiltGesturesEnabled = true
        map.uiSettings.isRotateGesturesEnabled = true
        map.uiSettings.isZoomControlsEnabled = false // Usamos nossos próprios botões
        
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

        vehicleMarker = map.addMarker(
            MarkerOptions()
                .position(firstPoint)
                .rotation(if (canRotate) points[0].bearing.toFloat() else 0f)
                .anchor(0.5f, 0.5f)
                .flat(true)
                .zIndex(10f) // Veículo sempre no topo
        )
        if (canRotate) {
            vehicleMarker?.setIcon(vehicleIconNormal)
        } else {
            val isGoingLeft = points[0].bearing > 180
            vehicleMarker?.setIcon(if (isGoingLeft) vehicleIconNormal else vehicleIconFlipped)
        }

        val progressOptions = PolylineOptions()
            .width(12f)
            .color(polylineColor)
            .geodesic(true)
            .zIndex(2f) // Linha abaixo do veículo
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

        // Velocidade base (vinda do Flutter)
        val remainingDist = endDist - startDist
        val durationMs = ((remainingDist / baseSpeed) * 1000 / playbackSpeed).toLong()

        animator?.cancel()
        animator = ValueAnimator.ofFloat(startDist.toFloat(), endDist.toFloat()).apply {
            duration = durationMs
            interpolator = LinearInterpolator()
            addUpdateListener { anim ->
                currentGlobalDistance = (anim.animatedValue as Float).toDouble()
                updateVehiclePosition(currentGlobalDistance)
                
                // Envia o progresso virtual (índice + t) para o Flutter
                val segmentIndex = getSegmentIndexForDistance(currentGlobalDistance)
                val segmentStartDist = cumulativeDistances[segmentIndex]
                val segmentEndDist = cumulativeDistances[segmentIndex + 1]
                val localT = (currentGlobalDistance - segmentStartDist) / (segmentEndDist - segmentStartDist)
                
                channel.invokeMethod("onProgress", mapOf("index" to segmentIndex.toDouble() + localT))
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    // Só resetamos se a animação realmente chegou ao fim do trajeto total
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
        
        // Garante que todas as paradas passadas (incluindo a atual) sejam desenhadas
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

        var delta = (end.bearing - start.bearing).toFloat()
        if (delta > 180) delta -= 360
        if (delta < -180) delta += 360
        val rotation = start.bearing.toFloat() + delta * t

        // Atualiza Rastro
        trailPoints.add(pos)
        progressPolyline?.points = trailPoints
        
        // Atualiza Veículo
        vehicleMarker?.position = pos
        if (canRotate) {
            vehicleMarker?.rotation = rotation
        } else {
            val isGoingLeft = rotation > 180
            vehicleMarker?.setIcon(if (isGoingLeft) vehicleIconNormal else vehicleIconFlipped)
        }

        // Só segue o veículo se o usuário não tiver mexido no mapa manualmente e não houver animação de zoom em curso
        if (followVehicle && !isAnimatingCamera) {
            googleMap?.moveCamera(CameraUpdateFactory.newLatLng(pos))
        }

        // Lógica de Pausa nos Stops
        if (showStops && points[idx].isStop && idx != lastStopIndexPassed && !isPausedForStop) {
            lastStopIndexPassed = idx
            pauseForStop()
        }
    }

    private fun pauseForStop() {
        isPausedForStop = true
        animator?.pause()
        
        // 2 segundos divididos pela velocidade (ex: 2000ms / 2x = 1000ms)
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
        
        vehicleMarker?.position = pos
        vehicleMarker?.rotation = if (canRotate) p.bearing.toFloat() else 0f
        
        followVehicle = true
        googleMap?.moveCamera(CameraUpdateFactory.newLatLng(pos))
        
        channel.invokeMethod("onPlaybackStatusChanged", mapOf("status" to "paused"))
        channel.invokeMethod("onProgress", mapOf("index" to safeIndex.toDouble()))  
    }

    private fun updateProgressTrail(currentPos: LatLng, index: Int) {
        // Método mantido para compatibilidade com o seekTo, reconstrói o rastro até o ponto desejado
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
                stopIcon?.let { markerOptions.icon(it) }
                val marker = map.addMarker(markerOptions)
                marker?.tag = index
                marker?.let { stopMarkers[index] = it }
            }
        }
    }

    private fun renderStops() {
        val map = googleMap ?: return
        clearStops() // Limpa para reconstruir o estado correto no Seek/Toggle
        val currentIdx = getSegmentIndexForDistance(currentGlobalDistance)
        
        // Adiciona as paradas até o ponto atual
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
}

data class GoogleMapsPlaybackPoint(val lat: Double, val lng: Double, val bearing: Double, val isStop: Boolean)
