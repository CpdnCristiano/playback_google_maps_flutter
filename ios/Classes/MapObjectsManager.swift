import GoogleMaps
import Flutter

class MapObjectsManager: NSObject {
    private let mapView: GMSMapView
    private let registrar: FlutterPluginRegistrar
    
    var markers: [String: GMSMarker] = [:]
    var circles: [String: GMSCircle] = [:]
    var polylines: [String: GMSPolyline] = [:]
    var polygons: [String: GMSPolygon] = [:]
    
    var defaultSpeed: Double = 60.0
    var maxAnimationDuration: Double = 2.0
    var followedMarkerId: String? = nil
    var followEnabled = true

    init(mapView: GMSMapView, registrar: FlutterPluginRegistrar) {
        self.mapView = mapView
        self.registrar = registrar
    }

    func setAllMarkers(_ markersData: [[String: Any]]) {
        markers.values.forEach { $0.map = nil }
        markers.removeAll()
        for m in markersData { addMarker(m) }
    }

    func addMarker(_ data: [String: Any]) {
        guard let id = data["markerId"] as? String else { return }
        
        if let existing = markers[id] {
            if let pos = Convert.toCoordinate(data["position"]) {
                let rotation = Convert.toDouble(data["rotation"]) ?? 0.0
                moveMarkerInternal(marker: existing, id: id, lat: pos.latitude, lng: pos.longitude, rotation: rotation)
            }
            Convert.interpretMarker(data, marker: existing)
        } else {
            let marker = GMSMarker()
            Convert.interpretMarker(data, marker: marker)
            marker.userData = id
            marker.map = mapView
            markers[id] = marker
        }
    }

    func moveMarker(id: String, lat: Double, lng: Double, rotation: Double) {
        guard let marker = markers[id] else { return }
        moveMarkerInternal(marker: marker, id: id, lat: lat, lng: lng, rotation: rotation)
    }

    func updateMarkerIcon(id: String, iconData: Any) {
        guard let marker = markers[id] else { return }
        marker.icon = Convert.toIcon(iconData)
    }

    func removeMarker(_ id: String) {
        markers[id]?.map = nil
        markers.removeValue(forKey: id)
    }

    func applyMarkerUpdates(_ updates: MapObjectUpdates<MarkerData>) {
        updates.toRemove.forEach { removeMarker($0) }
        (updates.toAdd + updates.toChange).forEach { addMarker($0.data) }
    }

    private func moveMarkerInternal(marker: GMSMarker, id: String, lat: Double, lng: Double, rotation: Double) {
        let targetPosition = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let loc1 = CLLocation(latitude: marker.position.latitude, longitude: marker.position.longitude)
        let loc2 = CLLocation(latitude: lat, longitude: lng)
        let distance = loc1.distance(from: loc2)
        
        let duration = max(0.3, min(maxAnimationDuration, distance / defaultSpeed))
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        marker.position = targetPosition
        marker.rotation = rotation
        
        if id == followedMarkerId && followEnabled {
            mapView.animate(with: GMSCameraUpdate.setTarget(targetPosition))
        }
        CATransaction.commit()
    }

    // SHAPES
    func addCircle(_ data: [String: Any]) {
        guard let id = data["circleId"] as? String else { return }
        if let existing = circles[id] {
            Convert.interpretCircle(data, circle: existing)
        } else {
            let circle = GMSCircle()
            Convert.interpretCircle(data, circle: circle)
            circle.userData = id
            circle.map = mapView
            circles[id] = circle
        }
    }

    func removeCircle(_ id: String) {
        circles[id]?.map = nil
        circles.removeValue(forKey: id)
    }

    func applyCircleUpdates(_ updates: MapObjectUpdates<CircleData>) {
        updates.toRemove.forEach { removeCircle($0) }
        (updates.toAdd + updates.toChange).forEach { addCircle($0.data) }
    }

    func addPolyline(_ data: [String: Any]) {
        guard let id = data["polylineId"] as? String else { return }
        if let existing = polylines[id] {
            Convert.interpretPolyline(data, polyline: existing)
        } else {
            let polyline = GMSPolyline()
            Convert.interpretPolyline(data, polyline: polyline)
            polyline.userData = id
            polyline.map = mapView
            polylines[id] = polyline
        }
    }

    func removePolyline(_ id: String) {
        polylines[id]?.map = nil
        polylines.removeValue(forKey: id)
    }

    func applyPolylineUpdates(_ updates: MapObjectUpdates<PolylineData>) {
        updates.toRemove.forEach { removePolyline($0) }
        (updates.toAdd + updates.toChange).forEach { addPolyline($0.data) }
    }

    func addPolygon(_ data: [String: Any]) {
        guard let id = data["polygonId"] as? String else { return }
        if let existing = polygons[id] {
            Convert.interpretPolygon(data, polygon: existing)
        } else {
            let polygon = GMSPolygon()
            Convert.interpretPolygon(data, polygon: polygon)
            polygon.userData = id
            polygon.map = mapView
            polygons[id] = polygon
        }
    }

    func removePolygon(_ id: String) {
        polygons[id]?.map = nil
        polygons.removeValue(forKey: id)
    }

    func applyPolygonUpdates(_ updates: MapObjectUpdates<PolygonData>) {
        updates.toRemove.forEach { removePolygon($0) }
        (updates.toAdd + updates.toChange).forEach { addPolygon($0.data) }
    }

    func clearAll() {
        markers.values.forEach { $0.map = nil }
        markers.removeAll()
        circles.values.forEach { $0.map = nil }
        circles.removeAll()
        polylines.values.forEach { $0.map = nil }
        polylines.removeAll()
        polygons.values.forEach { $0.map = nil }
        polygons.removeAll()
    }

    func showMarkerInfoWindow(id: String) {
        markers[id]?.map = mapView
        mapView.selectedMarker = markers[id]
    }

    func hideMarkerInfoWindow(id: String) {
        if mapView.selectedMarker == markers[id] {
            mapView.selectedMarker = nil
        }
    }

    func isMarkerInfoWindowShown(id: String) -> Bool {
        return mapView.selectedMarker == markers[id]
    }
}
