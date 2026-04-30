package br.com.cpndntech.google_maps_plus

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.maps.*
import com.google.android.gms.maps.model.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

class GoogleMapsPlusView(
    private val context: Context,
    private val viewId: Int,
    private val creationParams: Map<String, Any>?,
    messenger: BinaryMessenger,
    private val isPlaybackMode: Boolean = false
) : PlatformView, OnMapReadyCallback, MethodChannel.MethodCallHandler {

    private val mapView: MapView = MapView(context)
    private var googleMap: GoogleMap? = null
    private val channel: MethodChannel = MethodChannel(messenger, "br.com.cpndntech.google_maps_plus/map_$viewId")
    
    private var mapObjectsManager: MapObjectsManager? = null
    private var playbackManager: PlaybackManager? = null
    
    private var mapSettings = Convert.toMapSettings(creationParams)
    private var playbackSettings = Convert.toPlaybackSettings(creationParams)

    // Follow Logic (General)
    private val followHandler = Handler(Looper.getMainLooper())
    private val followRunnable = Runnable { 
        playbackManager?.followEnabled = true
        mapObjectsManager?.followEnabled = true
    }

    init {
        mapView.onCreate(null)
        mapView.onStart()
        mapView.onResume()
        mapView.getMapAsync(this)
        channel.setMethodCallHandler(this)
    }

    override fun onMapReady(map: GoogleMap) {
        googleMap = map
        val density = context.resources.displayMetrics.density
        mapObjectsManager = MapObjectsManager(map, density)
        
        if (isPlaybackMode || playbackSettings.points != null) {
            playbackManager = PlaybackManager(map, channel, density)
            playbackManager?.playbackSettings = playbackSettings
            
            val pts = (creationParams?.get("points") as? List<Map<String, Any>>)?.map {
                GoogleMapsPlaybackPoint(
                    lat = (it["lat"] as? Number)?.toDouble() ?: 0.0,
                    lng = (it["lng"] as? Number)?.toDouble() ?: 0.0,
                    bearing = (it["bearing"] as? Number)?.toDouble() ?: 0.0,
                    isStop = it["isStop"] as? Boolean == true
                )
            } ?: emptyList()
            
            playbackManager?.setPoints(pts)
        }

        map.setOnCameraMoveStartedListener { reason ->
            if (reason == GoogleMap.OnCameraMoveStartedListener.REASON_GESTURE) {
                playbackManager?.followEnabled = false
                mapObjectsManager?.followEnabled = false
                followHandler.removeCallbacks(followRunnable)
            }
        }

        map.setOnCameraIdleListener {
            followHandler.removeCallbacks(followRunnable)
            followHandler.postDelayed(followRunnable, 500)
            channel.invokeMethod("onCameraIdle", null)
        }

        map.setOnMarkerClickListener { marker ->
            val tag = marker.tag as? String ?: return@setOnMarkerClickListener false
            if (tag.startsWith("stop_")) {
                val index = tag.substringAfter("stop_").toIntOrNull() ?: return@setOnMarkerClickListener false
                playbackManager?.seekTo(index)
                channel.invokeMethod("onStopClick", mapOf("index" to index))
                return@setOnMarkerClickListener true
            }
            channel.invokeMethod("onMarkerTap", mapOf("id" to tag))
            true
        }

        setupMap()
    }

    private fun setupMap() {
        val map = googleMap ?: return
        val manager = mapObjectsManager ?: return
        
        updateMapSettings()
        
        manager.defaultSpeed = mapSettings.defaultSpeed
        manager.maxAnimationDuration = mapSettings.maxAnimationDuration
        
        // Limpa objetos antigos e adiciona novos (tudo no main thread de forma síncrona)
        manager.setupInitialObjects(
            mapSettings.initialMarkers,
            mapSettings.initialCircles,
            mapSettings.initialPolylines,
            mapSettings.initialPolygons
        )

        if (isPlaybackMode || playbackSettings.points != null) {
            playbackManager?.setupInitialState()
        } else {
            val initialCamera = creationParams?.get("initialCameraPosition") as? Map<String, Any>
            if (initialCamera != null) {
                val target = Convert.toLatLng(initialCamera["target"])
                if (target != null) {
                    val zoom = (initialCamera["zoom"] as? Number)?.toFloat() ?: 10f
                    map.moveCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLngZoom(target, zoom))
                }
            }
        }
    }

    private fun updateMapSettings() {
        val map = googleMap ?: return
        
        map.mapType = mapSettings.mapType
        map.isTrafficEnabled = mapSettings.showTraffic
        map.isBuildingsEnabled = mapSettings.showBuildings
        map.isMyLocationEnabled = mapSettings.showUserLocation
        
        val ui = map.uiSettings
        ui.isMyLocationButtonEnabled = mapSettings.showMyLocationButton
        ui.isCompassEnabled = mapSettings.compassEnabled
        ui.isMapToolbarEnabled = mapSettings.mapToolbarEnabled
        ui.isRotateGesturesEnabled = mapSettings.rotateGesturesEnabled
        ui.isScrollGesturesEnabled = mapSettings.scrollGesturesEnabled
        ui.isZoomControlsEnabled = mapSettings.zoomControlsEnabled
        ui.isZoomGesturesEnabled = mapSettings.zoomGesturesEnabled
        ui.isTiltGesturesEnabled = mapSettings.tiltGesturesEnabled
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val manager = mapObjectsManager
        val pManager = playbackManager
        
        when (call.method) {
            MethodNames.UPDATE_OPTIONS -> {
                val oldPoints = playbackSettings.points
                mapSettings = Convert.toMapSettings(call.arguments)
                playbackSettings = Convert.toPlaybackSettings(call.arguments)
                val newPoints = playbackSettings.points
                
                // Verifica se os pontos realmente mudaram (conteúdo, não referência)
                val pointsChanged = when {
                    oldPoints == null && newPoints == null -> false
                    oldPoints == null || newPoints == null -> true
                    oldPoints.size != newPoints.size -> true
                    else -> oldPoints.toString() != newPoints.toString()
                }
                
                // Se os pontos mudaram, reinicia o playback
                if (pointsChanged) {
                    pManager?.playbackSettings = playbackSettings
                    setupMap() // Reinicia tudo incluindo setupInitialState
                } else {
                    // Se só mudaram configurações do mapa, apenas atualiza sem resetar
                    pManager?.playbackSettings = playbackSettings
                    updateMapSettings()
                }
                result.success(null)
            }
            // Playback specific
            "play" -> { pManager?.play(); result.success(null) }
            "pause" -> { pManager?.pause(); result.success(null) }
            "resumeFromStop" -> { pManager?.resumeFromStop(); result.success(null) }
            "seek" -> { pManager?.seekTo(call.argument<Int>("index") ?: 0); result.success(null) }
            "setSpeed" -> { pManager?.setSpeed(call.argument<Int>("speed") ?: 1); result.success(null) }
            
            // Map common
            MethodNames.MARKERS_UPDATE -> { manager?.applyMarkerUpdates(Convert.toMarkerUpdates(call.arguments)); result.success(null) }
            MethodNames.POLYLINES_UPDATE -> { manager?.applyPolylineUpdates(Convert.toPolylineUpdates(call.arguments)); result.success(null) }
            MethodNames.CIRCLES_UPDATE -> { manager?.applyCircleUpdates(Convert.toCircleUpdates(call.arguments)); result.success(null) }
            MethodNames.POLYGONS_UPDATE -> { manager?.applyPolygonUpdates(Convert.toPolygonUpdates(call.arguments)); result.success(null) }
            MethodNames.MARKER_ADD -> { manager?.addMarker(call.argument<Map<String, Any>>("marker") ?: return); result.success(null) }
            MethodNames.MARKER_MOVE -> {
                val id = call.argument<String>("id") ?: return
                manager?.moveMarker(id, call.argument<Double>("lat") ?: 0.0, call.argument<Double>("lng") ?: 0.0, (call.argument<Double>("rotation") ?: 0.0).toFloat())
                result.success(null)
            }
            "marker_icon" -> {
                val id = call.argument<String>("id") ?: return
                val iconData = call.argument<Any>("icon") ?: call.argument<Any>("bytes") ?: return
                manager?.updateMarkerIcon(id, iconData)
                result.success(null)
            }
            MethodNames.FOLLOW_MARKER -> { 
                manager?.followedMarkerId = call.argument<String>("id")
                manager?.followEnabled = true
                result.success(null) 
            }
            MethodNames.MOVE_CAMERA -> {
                val lat = call.argument<Double>("lat") ?: return
                val lng = call.argument<Double>("lng") ?: return
                googleMap?.animateCamera(com.google.android.gms.maps.CameraUpdateFactory.newLatLngZoom(LatLng(lat, lng), (call.argument<Double>("zoom") ?: 10.0).toFloat()))
                result.success(null)
            }
            MethodNames.ZOOM_IN -> { googleMap?.animateCamera(com.google.android.gms.maps.CameraUpdateFactory.zoomIn()); result.success(null) }
            MethodNames.ZOOM_OUT -> { googleMap?.animateCamera(com.google.android.gms.maps.CameraUpdateFactory.zoomOut()); result.success(null) }
            
            // Map configuration methods
            "setMapStyle" -> {
                val style = call.argument<String>("style")
                if (style != null) {
                    googleMap?.setMapStyle(com.google.android.gms.maps.model.MapStyleOptions(style))
                } else {
                    googleMap?.setMapStyle(null)
                }
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
            "setMyLocationEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                try {
                    googleMap?.isMyLocationEnabled = enabled
                } catch (e: SecurityException) {
                    // Ignore if permissions are not granted
                }
                result.success(null)
            }
            "getZoomLevel" -> {
                result.success(googleMap?.cameraPosition?.zoom?.toDouble() ?: 15.0)
            }
            "getVisibleRegion" -> {
                val bounds = googleMap?.projection?.visibleRegion?.latLngBounds
                if (bounds != null) {
                    result.success(mapOf(
                        "swLat" to bounds.southwest.latitude,
                        "swLng" to bounds.southwest.longitude,
                        "neLat" to bounds.northeast.latitude,
                        "neLng" to bounds.northeast.longitude
                    ))
                } else {
                    result.error("ERROR", "Failed to get visible region", null)
                }
            }
            "getScreenCoordinate" -> {
                val lat = call.argument<Double>("lat") ?: return
                val lng = call.argument<Double>("lng") ?: return
                val point = googleMap?.projection?.toScreenLocation(LatLng(lat, lng))
                if (point != null) {
                    result.success(mapOf("x" to point.x, "y" to point.y))
                } else {
                    result.error("ERROR", "Failed to get screen coordinate", null)
                }
            }
            "getLatLng" -> {
                val x = call.argument<Int>("x") ?: return
                val y = call.argument<Int>("y") ?: return
                val latLng = googleMap?.projection?.fromScreenLocation(android.graphics.Point(x, y))
                if (latLng != null) {
                    result.success(mapOf("lat" to latLng.latitude, "lng" to latLng.longitude))
                } else {
                    result.error("ERROR", "Failed to get LatLng", null)
                }
            }
            "takeSnapshot" -> {
                googleMap?.snapshot { bitmap ->
                    if (bitmap != null) {
                        val stream = java.io.ByteArrayOutputStream()
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
                        result.success(stream.toByteArray())
                    } else {
                        result.success(null)
                    }
                }
            }
            "marker_show_info_window" -> {
                val id = call.argument<String>("id") ?: return
                mapObjectsManager?.showInfoWindow(id)
                result.success(null)
            }
            "marker_hide_info_window" -> {
                val id = call.argument<String>("id") ?: return
                mapObjectsManager?.hideInfoWindow(id)
                result.success(null)
            }
            "marker_is_info_window_shown" -> {
                val id = call.argument<String>("id") ?: return
                result.success(mapObjectsManager?.isInfoWindowShown(id) ?: false)
            }
            
            else -> result.notImplemented()
        }
    }

    override fun getView(): android.view.View = mapView

    override fun dispose() {
        followHandler.removeCallbacks(followRunnable)
        playbackManager?.dispose()
        mapObjectsManager?.clearAll()
        googleMap?.clear()
        mapView.onDestroy()
        channel.setMethodCallHandler(null)
    }
}
