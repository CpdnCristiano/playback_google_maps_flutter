package br.com.cpndntech.google_maps_plus

import android.animation.ValueAnimator
import android.os.Handler
import android.os.Looper
import android.view.animation.LinearInterpolator
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.GoogleMap
import com.google.android.gms.maps.model.*

class MapObjectsManager(private val googleMap: GoogleMap, private val density: Float) {
    private val mainHandler = Handler(Looper.getMainLooper())
    
    val markers = mutableMapOf<String, Marker>()
    val circles = mutableMapOf<String, Circle>()
    val polylines = mutableMapOf<String, Polyline>()
    val polygons = mutableMapOf<String, Polygon>()
    
    private val animators = mutableMapOf<String, ValueAnimator>()
    private val pendingIcons = mutableMapOf<String, BitmapDescriptor>()
    
    var defaultSpeed: Double = 60.0
    var maxAnimationDuration: Long = 10000L
    var followedMarkerId: String? = null
    var followEnabled = true

    // MARKERS
    fun addMarker(m: Map<String, Any>) {
        addMarkerInternal(m)
    }

    private fun addMarkerInternal(m: Map<String, Any>) {
        val id = m["markerId"] as? String ?: return
        val position = Convert.toLatLng(m["position"]) ?: return
        val rotation = (m["rotation"] as? Number)?.toFloat() ?: 0.0f
        
        val existing = markers[id]
        if (existing != null) {
            animateMarkerMoveInternal(existing, id, position, rotation)
            Convert.interpretMarker(m, existing)
            
            val descriptor = Convert.toBitmapDescriptor(m["icon"])
            if (descriptor != null) {
                if (animators.containsKey(id)) {
                    pendingIcons[id] = descriptor
                } else {
                    existing.setIcon(descriptor)
                }
            }
        } else {
            val options = Convert.toMarkerOptions(m)
            googleMap.addMarker(options)?.let { 
                it.tag = id
                markers[id] = it 
            }
        }
    }

    fun moveMarker(id: String, lat: Double, lng: Double, rotation: Float) {
        markers[id]?.let { animateMarkerMoveInternal(it, id, LatLng(lat, lng), rotation) }
    }

    fun updateMarkerIcon(id: String, iconData: Any) {
        mainHandler.post {
            val descriptor = Convert.toBitmapDescriptor(iconData) ?: return@post
            if (animators.containsKey(id)) {
                pendingIcons[id] = descriptor
            } else {
                markers[id]?.setIcon(descriptor)
            }
        }
    }

    fun removeMarker(id: String) {
        mainHandler.post {
            animators[id]?.cancel()
            animators.remove(id)
            pendingIcons.remove(id)
            markers[id]?.remove()
            markers.remove(id)
        }
    }

    fun applyMarkerUpdates(updates: MapObjectUpdates<MarkerData>) {
        mainHandler.post {
            updates.toRemove.forEach { removeMarker(it) }
            (updates.toAdd + updates.toChange).forEach { addMarkerInternal(it.data) }
        }
    }

    private fun animateMarkerMoveInternal(marker: Marker, id: String, targetPosition: LatLng, rotation: Float) {
        val currentPosition = marker.position
        val results = FloatArray(1)
        android.location.Location.distanceBetween(
            currentPosition.latitude, currentPosition.longitude,
            targetPosition.latitude, targetPosition.longitude,
            results
        )
        val distanceInMeters = results[0]

        if (distanceInMeters < 0.1) {
            marker.position = targetPosition
            marker.rotation = rotation
            if (id == followedMarkerId && followEnabled) {
                googleMap.moveCamera(CameraUpdateFactory.newLatLng(targetPosition))
            }
            return
        }

        val projection = googleMap.projection
        val visibleBounds = projection.visibleRegion.latLngBounds
        val expandedBounds = expandBounds(visibleBounds, 1.2)

        if (!expandedBounds.contains(currentPosition) && !expandedBounds.contains(targetPosition)) {
            marker.position = targetPosition
            marker.rotation = rotation
            return
        }

        val durationMs = ((distanceInMeters / defaultSpeed * 1000).toLong()).coerceIn(300L, maxAnimationDuration)
        animators[id]?.cancel()

        val animator = ValueAnimator.ofFloat(0f, 1f)
        animator.duration = durationMs
        animator.interpolator = LinearInterpolator()

        val startRotation = marker.rotation
        var deltaRotation = rotation - startRotation
        if (deltaRotation > 180f) deltaRotation -= 360f
        if (deltaRotation < -180f) deltaRotation += 360f

        animator.addUpdateListener { anim ->
            val t = anim.animatedFraction
            val animLat = currentPosition.latitude + (targetPosition.latitude - currentPosition.latitude) * t
            val animLng = currentPosition.longitude + (targetPosition.longitude - currentPosition.longitude) * t
            val pos = LatLng(animLat, animLng)
            marker.position = pos
            marker.rotation = startRotation + deltaRotation * t
            
            if (id == followedMarkerId && followEnabled) {
                googleMap.moveCamera(CameraUpdateFactory.newLatLng(pos))
            }
        }

        animator.addListener(object : android.animation.AnimatorListenerAdapter() {
            override fun onAnimationEnd(animation: android.animation.Animator) {
                animators.remove(id)
                pendingIcons.remove(id)?.let { descriptor ->
                    markers[id]?.setIcon(descriptor)
                }
            }
        })

        animator.start()
        animators[id] = animator
    }

    private fun expandBounds(bounds: LatLngBounds, factor: Double): LatLngBounds {
        val center = bounds.center
        val latSpan = bounds.northeast.latitude - bounds.southwest.latitude
        val lngSpan = bounds.northeast.longitude - bounds.southwest.longitude
        val newNe = LatLng(center.latitude + latSpan * factor / 2.0, center.longitude + lngSpan * factor / 2.0)
        val newSw = LatLng(center.latitude - latSpan * factor / 2.0, center.longitude - lngSpan * factor / 2.0)
        return LatLngBounds(newSw, newNe)
    }

    // SHAPES (CIRCLES, POLYLINES, POLYGONS)
    fun applyCircleUpdates(updates: MapObjectUpdates<CircleData>) {
        mainHandler.post {
            updates.toRemove.forEach { removeCircleInternal(it) }
            (updates.toAdd + updates.toChange).forEach { addCircleInternal(it.data) }
        }
    }

    fun addCircle(c: Map<String, Any>) {
        addCircleInternal(c)
    }

    private fun addCircleInternal(c: Map<String, Any>) {
        val id = c["circleId"] as? String ?: return
        val existing = circles[id]
        if (existing != null) {
            Convert.interpretCircle(c, existing, density)
        } else {
            val options = Convert.toCircleOptions(c, density)
            googleMap.addCircle(options)?.let { 
                it.tag = id
                circles[id] = it 
            }
        }
    }

    fun removeCircle(id: String) {
        removeCircleInternal(id)
    }

    private fun removeCircleInternal(id: String) {
        circles[id]?.remove()
        circles.remove(id)
    }

    fun applyPolylineUpdates(updates: MapObjectUpdates<PolylineData>) {
        updates.toRemove.forEach { removePolylineInternal(it) }
        (updates.toAdd + updates.toChange).forEach { addPolylineInternal(it.data) }
    }

    fun addPolyline(p: Map<String, Any>) {
        addPolylineInternal(p)
    }

    private fun addPolylineInternal(p: Map<String, Any>) {
        val id = p["polylineId"] as? String ?: return
        val existing = polylines[id]
        if (existing != null) {
            Convert.interpretPolyline(p, existing, density)
        } else {
            val options = Convert.toPolylineOptions(p, density)
            googleMap.addPolyline(options)?.let { 
                it.tag = id
                polylines[id] = it 
            }
        }
    }

    fun removePolyline(id: String) {
        mainHandler.post { removePolylineInternal(id) }
    }

    private fun removePolylineInternal(id: String) {
        polylines[id]?.remove()
        polylines.remove(id)
    }

    fun applyPolygonUpdates(updates: MapObjectUpdates<PolygonData>) {
        updates.toRemove.forEach { removePolygonInternal(it) }
        (updates.toAdd + updates.toChange).forEach { addPolygonInternal(it.data) }
    }

    fun addPolygon(p: Map<String, Any>) {
        addPolygonInternal(p)
    }

    private fun addPolygonInternal(p: Map<String, Any>) {
        val id = p["polygonId"] as? String ?: return
        val existing = polygons[id]
        if (existing != null) {
            Convert.interpretPolygon(p, existing, density)
        } else {
            val options = Convert.toPolygonOptions(p, density)
            googleMap.addPolygon(options)?.let { 
                it.tag = id
                polygons[id] = it 
            }
        }
    }

    fun removePolygon(id: String) {
        mainHandler.post { removePolygonInternal(id) }
    }

    private fun removePolygonInternal(id: String) {
        polygons[id]?.remove()
        polygons.remove(id)
    }

    fun clearAll() {
        mainHandler.post {
            markers.values.forEach { it.remove() }
            markers.clear()
            circles.values.forEach { it.remove() }
            circles.clear()
            polylines.values.forEach { it.remove() }
            polylines.clear()
            polygons.values.forEach { it.remove() }
            polygons.clear()
            animators.values.forEach { it.cancel() }
            animators.clear()
            pendingIcons.clear()
        }
    }

    fun showMarkerInfoWindow(id: String) {
        mainHandler.post {
            markers[id]?.showInfoWindow()
        }
    }

    fun hideMarkerInfoWindow(id: String) {
        mainHandler.post {
            markers[id]?.hideInfoWindow()
        }
    }

    fun isMarkerInfoWindowShown(id: String): Boolean {
        return markers[id]?.isInfoWindowShown ?: false
    }
}
