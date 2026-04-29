import Foundation
import GoogleMaps
import Flutter

// --- Modelos de Dados ---

struct GoogleMapsPlaybackPoint {
    let lat: Double
    let lng: Double
    let bearing: Double
    let isStop: Bool
}

struct MapSettings {
    let mapType: Int
    let showTraffic: Bool
    let showBuildings: Bool
    let showUserLocation: Bool
    let showMyLocationButton: Bool
    let compassEnabled: Bool
    let rotateGesturesEnabled: Bool
    let scrollGesturesEnabled: Bool
    let zoomGesturesEnabled: Bool
    let tiltGesturesEnabled: Bool
    let indoorViewEnabled: Bool
    let isDark: Bool
    let style: String?
    let padding: [Double]?
    let initialMarkers: [[String: Any]]?
    let initialCircles: [[String: Any]]?
    let initialPolylines: [[String: Any]]?
    let initialPolygons: [[String: Any]]?
    let defaultSpeed: Double
    let maxAnimationDuration: Double
}

struct PlaybackSettings {
    let baseSpeed: Double
    let canRotate: Bool
    let dynamicRotation: Bool
    let showStops: Bool
    let vehicleIcon: Any?
    let stopIcon: Any?
    let drawTrail: Bool
    let polylineColor: Any?
    let points: [[String: Any]]?
    let autoStart: Bool
}

// --- Conversor ---

class Convert {
    
    static func toMapSettings(_ data: Any?) -> MapSettings {
        let m = data as? [String: Any] ?? [:]
        return MapSettings(
            mapType: m.getInt("mapType", 1),
            showTraffic: m.getBool("showTraffic", false),
            showBuildings: m.getBool("showBuildings", true),
            showUserLocation: m.getBool("showUserLocation", false),
            showMyLocationButton: m.getBool("showMyLocationButton", true),
            compassEnabled: m.getBool("compassEnabled", true),
            rotateGesturesEnabled: m.getBool("rotateGesturesEnabled", true),
            scrollGesturesEnabled: m.getBool("scrollGesturesEnabled", true),
            zoomGesturesEnabled: m.getBool("zoomGesturesEnabled", true),
            tiltGesturesEnabled: m.getBool("tiltGesturesEnabled", true),
            indoorViewEnabled: m.getBool("indoorViewEnabled", false),
            isDark: m.getBool("isDark", false),
            style: m.getString("style"),
            padding: m.getList("padding"),
            initialMarkers: m.getList("markers"),
            initialCircles: m.getList("circles"),
            initialPolylines: m.getList("polylines"),
            initialPolygons: m.getList("polygons"),
            defaultSpeed: m.getDouble("defaultSpeed", 60.0),
            maxAnimationDuration: m.getDouble("maxAnimationDuration", 2000.0) / 1000.0
        )
    }

    static func toPlaybackSettings(_ data: Any?) -> PlaybackSettings {
        let m = data as? [String: Any] ?? [:]
        return PlaybackSettings(
            baseSpeed: m.getDouble("baseSpeed", 60.0),
            canRotate: m.getBool("canRotate", true),
            dynamicRotation: m.getBool("dynamicRotation", false),
            showStops: m.getBool("showStops", false),
            vehicleIcon: m["vehicleIcon"],
            stopIcon: m["stopIcon"],
            drawTrail: m.getBool("drawTrail", true),
            polylineColor: m["polylineColor"],
            points: m.getList("points"),
            autoStart: m.getBool("autoStart", false)
        )
    }

    // --- Outras Conversões ---

    static func toMarkerUpdates(_ data: Any?) -> MapObjectUpdates<MarkerData> {
        guard let map = data as? [String: Any] else { return MapObjectUpdates(toAdd: [], toChange: [], toRemove: []) }
        let add = (map["toAdd"] as? [[String: Any]])?.map { MarkerData(id: $0["markerId"] as! String, data: $0) } ?? []
        let change = (map["toChange"] as? [[String: Any]])?.map { MarkerData(id: $0["markerId"] as! String, data: $0) } ?? []
        let remove = (map["toRemove"] as? [String]) ?? []
        return MapObjectUpdates(toAdd: add, toChange: change, toRemove: remove)
    }

    static func toPolylineUpdates(_ data: Any?) -> MapObjectUpdates<PolylineData> {
        guard let map = data as? [String: Any] else { return MapObjectUpdates(toAdd: [], toChange: [], toRemove: []) }
        let add = (map["toAdd"] as? [[String: Any]])?.map { PolylineData(id: $0["polylineId"] as! String, data: $0) } ?? []
        let change = (map["toChange"] as? [[String: Any]])?.map { PolylineData(id: $0["polylineId"] as! String, data: $0) } ?? []
        let remove = (map["toRemove"] as? [String]) ?? []
        return MapObjectUpdates(toAdd: add, toChange: change, toRemove: remove)
    }

    static func toCircleUpdates(_ data: Any?) -> MapObjectUpdates<CircleData> {
        guard let map = data as? [String: Any] else { return MapObjectUpdates(toAdd: [], toChange: [], toRemove: []) }
        let add = (map["toAdd"] as? [[String: Any]])?.map { CircleData(id: $0["circleId"] as! String, data: $0) } ?? []
        let change = (map["toChange"] as? [[String: Any]])?.map { CircleData(id: $0["circleId"] as! String, data: $0) } ?? []
        let remove = (map["toRemove"] as? [String]) ?? []
        return MapObjectUpdates(toAdd: add, toChange: change, toRemove: remove)
    }

    static func toPolygonUpdates(_ data: Any?) -> MapObjectUpdates<PolygonData> {
        guard let map = data as? [String: Any] else { return MapObjectUpdates(toAdd: [], toChange: [], toRemove: []) }
        let add = (map["toAdd"] as? [[String: Any]])?.map { PolygonData(id: $0["polygonId"] as! String, data: $0) } ?? []
        let change = (map["toChange"] as? [[String: Any]])?.map { PolygonData(id: $0["polygonId"] as! String, data: $0) } ?? []
        let remove = (map["toRemove"] as? [String]) ?? []
        return MapObjectUpdates(toAdd: add, toChange: change, toRemove: remove)
    }

    static func toCoordinate(_ data: Any?) -> CLLocationCoordinate2D? {
        guard let list = data as? [Any], list.count >= 2 else { return nil }
        guard let lat = toDouble(list[0]), let lng = toDouble(list[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    static func toDouble(_ data: Any?) -> Double? {
        if let d = data as? Double { return d }
        if let ns = data as? NSNumber { return ns.doubleValue }
        return nil
    }
    
    static func toColor(_ data: Any?) -> UIColor {
        let colorInt: Int64?
        if let v = data as? Int64 { colorInt = v }
        else if let v = data as? Int { colorInt = Int64(v) }
        else { return .blue }
        let c = colorInt!
        return UIColor(red: CGFloat((c >> 16) & 0xFF) / 255.0, green: CGFloat((c >> 8) & 0xFF) / 255.0, blue: CGFloat(c & 0xFF) / 255.0, alpha: CGFloat((c >> 24) & 0xFF) / 255.0)
    }
    
    static func toIcon(_ data: Any?, registrar: FlutterPluginRegistrar? = nil) -> UIImage? {
        guard let list = data as? [Any], !list.isEmpty else { return nil }
        let type = list[0] as? String
        let screenScale = UIScreen.main.scale
        switch type {
        case "fromAsset":
            if let assetName = list[1] as? String {
                return loadAssetImage(assetName, registrar: registrar)
            }
        case "fromAssetImage":
            // list: [type, assetName, pixelRatio, size:[w,h]]
            if let assetName = list[1] as? String {
                let image = loadAssetImage(assetName, registrar: registrar)
                // Respeita o size explícito em pontos lógicos, ignora pixelRatio
                if let img = image, list.count >= 4,
                   let sizeList = list[3] as? [Any], sizeList.count >= 2,
                   let w = toDouble(sizeList[0]), let h = toDouble(sizeList[1]), w > 0, h > 0 {
                    return resizeImage(img, to: CGSize(width: w, height: h))
                }
                return image
            }
        case "fromBytes":
            // Bytes já estão na resolução física da tela; aplicar screenScale para obter tamanho lógico correto
            if let bytes = list[1] as? FlutterStandardTypedData {
                if let image = UIImage(data: bytes.data, scale: screenScale) {
                    return fixOrientation(image)
                }
            }
        case "asset":
            if let params = list[1] as? [String: Any], let assetName = params["assetName"] as? String {
                return loadAssetImage(assetName, registrar: registrar)
            }
        case "bytes":
            if let params = list[1] as? [String: Any], let bytes = params["byteData"] as? FlutterStandardTypedData {
                if let image = UIImage(data: bytes.data, scale: screenScale) {
                    return fixOrientation(image)
                }
            }
        default: return nil
        }
        return nil
    }

    private static func loadAssetImage(_ assetName: String, registrar: FlutterPluginRegistrar?) -> UIImage? {
        if let reg = registrar {
            let key = reg.lookupKey(forAsset: assetName)
            if let path = Bundle.main.path(forResource: key, ofType: nil) {
                return UIImage(contentsOfFile: path)
            }
        }
        return UIImage(named: assetName)
    }

    private static func fixOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }

    private static func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, UIScreen.main.scale)
        image.draw(in: CGRect(origin: .zero, size: size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }
    
    static func interpretMarker(_ m: [String: Any], marker: GMSMarker, registrar: FlutterPluginRegistrar? = nil) {
        if let coord = toCoordinate(m["position"]) { marker.position = coord }
        if let anchor = m["anchor"] as? [Any], anchor.count >= 2 { marker.groundAnchor = CGPoint(x: toDouble(anchor[0]) ?? 0.5, y: toDouble(anchor[1]) ?? 0.5) }
        if let rotation = toDouble(m["rotation"]) { marker.rotation = rotation }
        if let zIndex = toDouble(m["zIndex"]) { marker.zIndex = Int32(zIndex) }
        if let flat = m["flat"] as? Bool { marker.isFlat = flat }
        if let opacity = toDouble(m["alpha"]) { marker.opacity = Float(opacity) }
        if let iconData = m["icon"] { marker.icon = toIcon(iconData, registrar: registrar) }
    }
    
    static func interpretCircle(_ c: [String: Any], circle: GMSCircle) {
        if let coord = toCoordinate(c["center"]) { circle.position = coord }
        if let radius = toDouble(c["radius"]) { circle.radius = radius }
        circle.fillColor = toColor(c["fillColor"]); circle.strokeColor = toColor(c["strokeColor"])
        if let strokeWidth = toDouble(c["strokeWidth"]) { circle.strokeWidth = CGFloat(strokeWidth) }
        if let zIndex = toDouble(c["zIndex"]) { circle.zIndex = Int32(zIndex) }
    }
    
    static func interpretPolyline(_ p: [String: Any], polyline: GMSPolyline) {
        if let pts = p["points"] as? [Any] {
            let path = GMSMutablePath()
            for pt in pts { if let coord = toCoordinate(pt) { path.add(coord) } }
            polyline.path = path
        }
        polyline.strokeColor = toColor(p["color"])
        if let width = toDouble(p["width"]) { polyline.strokeWidth = CGFloat(width) }
        if let zIndex = toDouble(p["zIndex"]) { polyline.zIndex = Int32(zIndex) }
        if let geodesic = p["geodesic"] as? Bool { polyline.geodesic = geodesic }
    }
    
    static func interpretPolygon(_ poly: [String: Any], polygon: GMSPolygon) {
        if let pts = poly["points"] as? [Any] {
            let path = GMSMutablePath()
            for pt in pts { if let coord = toCoordinate(pt) { path.add(coord) } }
            polygon.path = path
        }
        polygon.strokeColor = toColor(poly["strokeColor"]); polygon.fillColor = toColor(poly["fillColor"])
        if let width = toDouble(poly["strokeWidth"]) { polygon.strokeWidth = CGFloat(width) }
        if let zIndex = toDouble(poly["zIndex"]) { polygon.zIndex = Int32(zIndex) }
        if let geodesic = poly["geodesic"] as? Bool { polygon.geodesic = geodesic }
    }
}

// --- Helpers de Dicionário ---

extension Dictionary where Key == String {
    func getInt(_ key: String, _ defaultVal: Int) -> Int { return self[key] as? Int ?? defaultVal }
    func getBool(_ key: String, _ defaultVal: Bool) -> Bool { return self[key] as? Bool ?? defaultVal }
    func getDouble(_ key: String, _ defaultVal: Double) -> Double { return Convert.toDouble(self[key]) ?? defaultVal }
    func getString(_ key: String) -> String? { return self[key] as? String }
    func getList<T>(_ key: String) -> [T]? { return self[key] as? [T] }
}

// --- Estruturas Auxiliares ---

struct MapObjectUpdates<T> { let toAdd: [T]; let toChange: [T]; let toRemove: [String] }
struct MarkerData { let id: String; let data: [String: Any] }
struct PolylineData { let id: String; let data: [String: Any] }
struct CircleData { let id: String; let data: [String: Any] }
struct PolygonData { let id: String; let data: [String: Any] }

struct MethodNames {
    static let updateOptions = "updateOptions"
    static let markersUpdate = "markers/update"
    static let polylinesUpdate = "polylines/update"
    static let circlesUpdate = "circles/update"
    static let polygonsUpdate = "polygons/update"
    static let markerAdd = "marker_add"; static let markerMove = "marker_move"; static let markerIcon = "marker_icon"; static let markerRemove = "marker_remove"; static let markerShowInfoWindow = "marker_show_info_window"
    static let circleAdd = "circle_add"; static let circleRemove = "circle_remove"
    static let polylineAdd = "polyline_add"; static let polylineRemove = "polyline_remove"
    static let polygonAdd = "polygon_add"; static let polygonRemove = "polygon_remove"
    static let zoomIn = "zoomIn"; static let zoomOut = "zoomOut"; static let followMarker = "follow_marker"; static let moveCamera = "move_camera"
    static let setDefaultSpeed = "set_default_speed"; static let setMaxAnimationDuration = "set_max_animation_duration"
}
