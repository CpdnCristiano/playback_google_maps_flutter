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

        // Add initial objects
        (creationParams?.get("markers") as? List<*>)?.forEach { (it as? Map<String, Any>)?.let { m -> mapObjectsManager?.addMarker(m) } }
        (creationParams?.get("polylines") as? List<*>)?.forEach { (it as? Map<String, Any>)?.let { p -> mapObjectsManager?.addPolyline(p) } }
        (creationParams?.get("circles") as? List<*>)?.forEach { (it as? Map<String, Any>)?.let { c -> mapObjectsManager?.addCircle(c) } }
        (creationParams?.get("polygons") as? List<*>)?.forEach { (it as? Map<String, Any>)?.let { pg -> mapObjectsManager?.addPolygon(pg) } }

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
        
        manager.defaultSpeed = mapSettings.defaultSpeed
        manager.maxAnimationDuration = mapSettings.maxAnimationDuration
        
        mapSettings.initialMarkers?.forEach { manager.addMarker(it) }
        mapSettings.initialCircles?.forEach { manager.addCircle(it) }
        mapSettings.initialPolylines?.forEach { manager.addPolyline(it) }
        mapSettings.initialPolygons?.forEach { manager.addPolygon(it) }

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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val manager = mapObjectsManager
        val pManager = playbackManager
        
        when (call.method) {
            MethodNames.UPDATE_OPTIONS -> {
                mapSettings = Convert.toMapSettings(call.arguments)
                playbackSettings = Convert.toPlaybackSettings(call.arguments)
                pManager?.playbackSettings = playbackSettings
                setupMap()
                result.success(null)
            }
            // Playback specific
            "play" -> { pManager?.play(); result.success(null) }
            "pause" -> { pManager?.pause(); result.success(null) }
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
