package br.com.cpndntech.google_maps_plus

import android.graphics.Color
import com.google.android.gms.maps.GoogleMap
import com.google.android.gms.maps.model.*

// --- Classes de Dados ---

data class GoogleMapsPlaybackPoint(
    val lat: Double,
    val lng: Double,
    val bearing: Double,
    val isStop: Boolean
)

data class MapSettings(
    val mapType: Int = GoogleMap.MAP_TYPE_NORMAL,
    val showTraffic: Boolean = false,
    val showBuildings: Boolean = true,
    val showUserLocation: Boolean = false,
    val showMyLocationButton: Boolean = true,
    val compassEnabled: Boolean = true,
    val mapToolbarEnabled: Boolean = true,
    val rotateGesturesEnabled: Boolean = true,
    val scrollGesturesEnabled: Boolean = true,
    val zoomControlsEnabled: Boolean = true,
    val zoomGesturesEnabled: Boolean = true,
    val tiltGesturesEnabled: Boolean = true,
    val indoorViewEnabled: Boolean = false,
    val isDark: Boolean = false,
    val style: String? = null,
    val padding: List<Double>? = null,
    val initialMarkers: List<Map<String, Any>>? = null,
    val initialCircles: List<Map<String, Any>>? = null,
    val initialPolylines: List<Map<String, Any>>? = null,
    val initialPolygons: List<Map<String, Any>>? = null,
    val defaultSpeed: Double = 60.0,
    val maxAnimationDuration: Long = 2000L
)

data class PlaybackSettings(
    val baseSpeed: Double = 60.0,
    val canRotate: Boolean = true,
    val dynamicRotation: Boolean = false,
    val showStops: Boolean = false,
    val vehicleIcon: Any? = null,
    val stopIcon: Any? = null,
    val drawTrail: Boolean = true,
    val polylineColor: Any? = null,
    val points: List<Map<String, Any>>? = null,
    val autoStart: Boolean = false
)

// --- Utilitários de Conversão ---

object Convert {
    fun toDouble(o: Any?): Double? {
        return (o as? Number)?.toDouble()
    }

    fun toMapSettings(data: Any?): MapSettings {
        val m = data as? Map<String, Any> ?: return MapSettings()
        return MapSettings(
            mapType = m.getInt("mapType", GoogleMap.MAP_TYPE_NORMAL),
            showTraffic = m.getBool("showTraffic", false),
            showBuildings = m.getBool("showBuildings", true),
            showUserLocation = m.getBool("showUserLocation", false),
            showMyLocationButton = m.getBool("showMyLocationButton", true),
            compassEnabled = m.getBool("compassEnabled", true),
            mapToolbarEnabled = m.getBool("mapToolbarEnabled", true),
            rotateGesturesEnabled = m.getBool("rotateGesturesEnabled", true),
            scrollGesturesEnabled = m.getBool("scrollGesturesEnabled", true),
            zoomControlsEnabled = m.getBool("zoomControlsEnabled", true),
            zoomGesturesEnabled = m.getBool("zoomGesturesEnabled", true),
            tiltGesturesEnabled = m.getBool("tiltGesturesEnabled", true),
            indoorViewEnabled = m.getBool("indoorViewEnabled", false),
            isDark = m.getBool("isDark", false),
            style = m.getString("style"),
            padding = m.getList("padding"),
            initialMarkers = m.getList("markers"),
            initialCircles = m.getList("circles"),
            initialPolylines = m.getList("polylines"),
            initialPolygons = m.getList("polygons"),
            defaultSpeed = m.getDouble("defaultSpeed", 60.0),
            maxAnimationDuration = m.getLong("maxAnimationDuration", 2000L)
        )
    }

    fun toPlaybackSettings(data: Any?): PlaybackSettings {
        val m = data as? Map<String, Any> ?: return PlaybackSettings()
        return PlaybackSettings(
            baseSpeed = m.getDouble("baseSpeed", 60.0),
            canRotate = m.getBool("canRotate", true),
            dynamicRotation = m.getBool("dynamicRotation", false),
            showStops = m.getBool("showStops", false),
            vehicleIcon = m["vehicleIcon"],
            stopIcon = m["stopIcon"],
            drawTrail = m.getBool("drawTrail", true),
            polylineColor = m["polylineColor"],
            points = m.getList("points"),
            autoStart = m.getBool("autoStart", false)
        )
    }

    // --- Helpers de Extensão para Map ---

    private fun Map<String, Any>.getInt(key: String, default: Int): Int = (this[key] as? Number)?.toInt() ?: default
    private fun Map<String, Any>.getBool(key: String, default: Boolean): Boolean = this[key] as? Boolean ?: default
    private fun Map<String, Any>.getDouble(key: String, default: Double): Double = (this[key] as? Number)?.toDouble() ?: default
    private fun Map<String, Any>.getLong(key: String, default: Long): Long = (this[key] as? Number)?.toLong() ?: default
    private fun Map<String, Any>.getString(key: String): String? = this[key] as? String
    private fun <T> Map<String, Any>.getList(key: String): List<T>? = this[key] as? List<T>

    // --- Outras Conversões (Marcadores, etc) ---

    fun toMarkerUpdates(data: Any?): MapObjectUpdates<MarkerData> {
        val map = data as? Map<String, Any> ?: return MapObjectUpdates(emptyList(), emptyList(), emptyList())
        val add = (map["toAdd"] as? List<Map<String, Any>>)?.map { MarkerData(it["markerId"] as String, it) } ?: emptyList()
        val change = (map["toChange"] as? List<Map<String, Any>>)?.map { MarkerData(it["markerId"] as String, it) } ?: emptyList()
        val remove = (map["toRemove"] as? List<String>) ?: emptyList()
        return MapObjectUpdates(add, change, remove)
    }

    fun toPolylineUpdates(data: Any?): MapObjectUpdates<PolylineData> {
        val map = data as? Map<String, Any> ?: return MapObjectUpdates(emptyList(), emptyList(), emptyList())
        val add = (map["toAdd"] as? List<Map<String, Any>>)?.map { PolylineData(it["polylineId"] as String, it) } ?: emptyList()
        val change = (map["toChange"] as? List<Map<String, Any>>)?.map { PolylineData(it["polylineId"] as String, it) } ?: emptyList()
        val remove = (map["toRemove"] as? List<String>) ?: emptyList()
        return MapObjectUpdates(add, change, remove)
    }

    fun toCircleUpdates(data: Any?): MapObjectUpdates<CircleData> {
        val map = data as? Map<String, Any> ?: return MapObjectUpdates(emptyList(), emptyList(), emptyList())
        val add = (map["toAdd"] as? List<Map<String, Any>>)?.map { CircleData(it["circleId"] as String, it) } ?: emptyList()
        val change = (map["toChange"] as? List<Map<String, Any>>)?.map { CircleData(it["circleId"] as String, it) } ?: emptyList()
        val remove = (map["toRemove"] as? List<String>) ?: emptyList()
        return MapObjectUpdates(add, change, remove)
    }

    fun toPolygonUpdates(data: Any?): MapObjectUpdates<PolygonData> {
        val map = data as? Map<String, Any> ?: return MapObjectUpdates(emptyList(), emptyList(), emptyList())
        val add = (map["toAdd"] as? List<Map<String, Any>>)?.map { PolygonData(it["polygonId"] as String, it) } ?: emptyList()
        val change = (map["toChange"] as? List<Map<String, Any>>)?.map { PolygonData(it["polygonId"] as String, it) } ?: emptyList()
        val remove = (map["toRemove"] as? List<String>) ?: emptyList()
        return MapObjectUpdates(add, change, remove)
    }

    fun toLatLng(data: Any?): LatLng? {
        if (data is List<*>) {
            if (data.size < 2) return null
            val lat = (data[0] as? Number)?.toDouble() ?: return null
            val lng = (data[1] as? Number)?.toDouble() ?: return null
            return LatLng(lat, lng)
        }
        if (data is Map<*, *>) {
            val lat = (data["latitude"] ?: data["lat"]) as? Number ?: return null
            val lng = (data["longitude"] ?: data["lng"]) as? Number ?: return null
            return LatLng(lat.toDouble(), lng.toDouble())
        }
        return null
    }

    fun toColor(data: Any?): Int {
        if (data == null) return Color.BLUE
        if (data is String) return try { Color.parseColor(data) } catch (e: Exception) { Color.BLUE }
        if (data is Number) return data.toInt()
        return Color.BLUE
    }

    fun toBitmapDescriptor(data: Any?): BitmapDescriptor? {
        val list = data as? List<*> ?: return null
        if (list.isEmpty()) return null
        val type = list[0] as? String ?: return null
        return when (type) {
            "defaultMarker" -> {
                val hue = if (list.size > 1) (list[1] as? Number)?.toFloat() ?: 0.0f else 0.0f
                BitmapDescriptorFactory.defaultMarker(hue)
            }
            "fromAsset", "fromAssetImage" -> BitmapDescriptorFactory.fromAsset(list[1] as? String ?: return null)
            "fromBytes" -> {
                val bytes = list[1] as? ByteArray ?: return null
                BitmapDescriptorFactory.fromBitmap(android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
            }
            "asset" -> BitmapDescriptorFactory.fromAsset((list[1] as? Map<*, *>)?.get("assetName") as? String ?: return null)
            "bytes" -> {
                val bytes = (list[1] as? Map<*, *>)?.get("byteData") as? ByteArray ?: return null
                BitmapDescriptorFactory.fromBitmap(android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
            }
            else -> null
        }
    }

    fun toMarkerOptions(data: Map<String, Any>): MarkerOptions {
        val options = MarkerOptions()
        toLatLng(data["position"])?.let { options.position(it) }
        (data["anchor"] as? List<*>)?.let { options.anchor((it[0] as? Number)?.toFloat() ?: 0.5f, (it[1] as? Number)?.toFloat() ?: 0.5f) }
        (data["rotation"] as? Number)?.let { options.rotation(it.toFloat()) }
        (data["zIndex"] as? Number)?.let { options.zIndex(it.toFloat()) }
        (data["flat"] as? Boolean)?.let { options.flat(it) }
        (data["alpha"] as? Number)?.let { options.alpha(it.toFloat()) }
        toBitmapDescriptor(data["icon"])?.let { options.icon(it) }
        return options
    }

    fun toCircleOptions(data: Map<String, Any>, density: Float): CircleOptions {
        val options = CircleOptions()
        toLatLng(data["center"])?.let { options.center(it) }
        (data["radius"] as? Number)?.let { options.radius(it.toDouble()) }
        options.strokeWidth(((data["strokeWidth"] as? Number)?.toFloat() ?: 10f) * density)
        options.strokeColor(toColor(data["strokeColor"]))
        options.fillColor(toColor(data["fillColor"]))
        options.zIndex((data["zIndex"] as? Number)?.toFloat() ?: 0f)
        options.visible(data["visible"] as? Boolean ?: true)
        return options
    }

    fun toPolylineOptions(data: Map<String, Any>, density: Float): PolylineOptions {
        val options = PolylineOptions()
        (data["points"] as? List<*>)?.mapNotNull { toLatLng(it) }?.let { options.addAll(it) }
        options.width(((data["width"] as? Number)?.toFloat() ?: 10f) * density)
        options.color(toColor(data["color"]))
        options.zIndex((data["zIndex"] as? Number)?.toFloat() ?: 0f)
        options.geodesic(data["geodesic"] as? Boolean ?: false)
        options.visible(data["visible"] as? Boolean ?: true)
        return options
    }

    fun toPolygonOptions(data: Map<String, Any>, density: Float): PolygonOptions {
        val options = PolygonOptions()
        (data["points"] as? List<*>)?.mapNotNull { toLatLng(it) }?.let { options.addAll(it) }
        options.strokeWidth(((data["strokeWidth"] as? Number)?.toFloat() ?: 10f) * density)
        options.strokeColor(toColor(data["strokeColor"]))
        options.fillColor(toColor(data["fillColor"]))
        options.zIndex((data["zIndex"] as? Number)?.toFloat() ?: 0f)
        options.geodesic(data["geodesic"] as? Boolean ?: false)
        options.visible(data["visible"] as? Boolean ?: true)
        return options
    }

    fun interpretMarker(m: Map<String, Any>, marker: Marker) {
        toLatLng(m["position"])?.let { marker.position = it }
        (m["anchor"] as? List<*>)?.let { marker.setAnchor((it[0] as? Number)?.toFloat() ?: 0.5f, (it[1] as? Number)?.toFloat() ?: 0.5f) }
        (m["rotation"] as? Number)?.let { marker.rotation = it.toFloat() }
        (m["zIndex"] as? Number)?.let { marker.zIndex = it.toFloat() }
        (m["flat"] as? Boolean)?.let { marker.isFlat = it }
        (m["alpha"] as? Number)?.let { marker.alpha = it.toFloat() }
    }

    fun interpretCircle(c: Map<String, Any>, circle: Circle, density: Float) {
        toLatLng(c["center"])?.let { circle.center = it }
        (c["radius"] as? Number)?.let { circle.radius = it.toDouble() }
        (c["strokeWidth"] as? Number)?.let { circle.strokeWidth = it.toFloat() * density }
        circle.strokeColor = toColor(c["strokeColor"])
        circle.fillColor = toColor(c["fillColor"])
        (c["zIndex"] as? Number)?.let { circle.zIndex = it.toFloat() }
        (c["visible"] as? Boolean)?.let { circle.isVisible = it }
    }

    fun interpretPolyline(p: Map<String, Any>, polyline: Polyline, density: Float) {
        (p["points"] as? List<*>)?.mapNotNull { toLatLng(it) }?.let { polyline.points = it }
        (p["width"] as? Number)?.let { polyline.width = it.toFloat() * density }
        polyline.color = toColor(p["color"])
        (p["zIndex"] as? Number)?.let { polyline.zIndex = it.toFloat() }
        (p["geodesic"] as? Boolean)?.let { polyline.isGeodesic = it }
        (p["visible"] as? Boolean)?.let { polyline.isVisible = it }
    }

    fun interpretPolygon(p: Map<String, Any>, polygon: Polygon, density: Float) {
        (p["points"] as? List<*>)?.mapNotNull { toLatLng(it) }?.let { polygon.points = it }
        (p["strokeWidth"] as? Number)?.let { polygon.strokeWidth = it.toFloat() * density }
        polygon.strokeColor = toColor(p["strokeColor"])
        polygon.fillColor = toColor(p["fillColor"])
        (p["zIndex"] as? Number)?.let { polygon.zIndex = it.toFloat() }
        (p["geodesic"] as? Boolean)?.let { polygon.isGeodesic = it }
        (p["visible"] as? Boolean)?.let { polygon.isVisible = it }
    }
}

// --- Estruturas Auxiliares ---

data class MapObjectUpdates<T>(val toAdd: List<T>, val toChange: List<T>, val toRemove: List<String>)
data class MarkerData(val id: String, val data: Map<String, Any>)
data class PolylineData(val id: String, val data: Map<String, Any>)
data class CircleData(val id: String, val data: Map<String, Any>)
data class PolygonData(val id: String, val data: Map<String, Any>)

object MethodNames {
    const val UPDATE_OPTIONS = "updateOptions"
    const val MARKERS_UPDATE = "markers/update"
    const val POLYLINES_UPDATE = "polylines/update"
    const val CIRCLES_UPDATE = "circles/update"
    const val POLYGONS_UPDATE = "polygons/update"
    const val MARKER_ADD = "marker_add"
    const val MARKER_MOVE = "marker_move"
    const val MARKER_ICON = "marker_icon"
    const val MARKER_REMOVE = "marker_remove"
    const val MARKER_SHOW_INFO_WINDOW = "marker_show_info_window"
    const val CIRCLE_ADD = "circle_add"
    const val CIRCLE_REMOVE = "circle_remove"
    const val POLYLINE_ADD = "polyline_add"
    const val POLYLINE_REMOVE = "polyline_remove"
    const val POLYGON_ADD = "polygon_add"
    const val POLYGON_REMOVE = "polygon_remove"
    const val ZOOM_IN = "zoomIn"
    const val ZOOM_OUT = "zoomOut"
    const val FOLLOW_MARKER = "follow_marker"
    const val MOVE_CAMERA = "move_camera"
    const val SET_DEFAULT_SPEED = "set_default_speed"
    const val SET_MAX_ANIMATION_DURATION = "set_max_animation_duration"
}
