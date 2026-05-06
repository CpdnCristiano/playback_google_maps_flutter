import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:http/http.dart' as http;

class ValhallaRouteAnchor {
  const ValhallaRouteAnchor({
    required this.point,
    required this.shapeIndex,
    required this.shapeFraction,
  });

  final LatLng point;
  final int shapeIndex;
  final double shapeFraction;

  Map<String, dynamic> toJson() => {
    'lat': point.latitude,
    'lng': point.longitude,
    'shapeIndex': shapeIndex,
    'shapeFraction': shapeFraction,
  };
}

class ValhallaRouteData {
  const ValhallaRouteData({required this.route, required this.anchors});

  final List<LatLng> route;
  final List<ValhallaRouteAnchor> anchors;
}

class ValhallaHelper {
  static const String _valhallaUrl =
      'https://valhalla.cpdntech.com.br/trace_route';
  static const String _valhallaAttributesUrl =
      'https://valhalla.cpdntech.com.br/trace_attributes';

  /// Decodes a Valhalla polyline string into a list of LatLng points.
  static List<LatLng> decodePolyline(String encoded, {int precision = 6}) {
    List<LatLng> coords = [];
    int index = 0;
    int lat = 0;
    int lon = 0;
    final factor = pow(10, precision);

    while (index < encoded.length) {
      int shift = 0;
      int result = 0;
      int byte;

      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);

      int deltaLat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += deltaLat;

      shift = 0;
      result = 0;

      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);

      int deltaLon = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lon += deltaLon;

      coords.add(LatLng(lat / factor.toInt(), lon / factor.toInt()));
    }

    return coords;
  }

  /// Fetches a snapped route from Valhalla based on raw GPS points.
  static Future<List<LatLng>> getSnappedRoute(List<LatLng> points) async {
    final routeData = await getSnappedRouteData(points);
    return routeData.route;
  }

  /// Fetches the snapped route plus the exact matched anchors for each original point.
  static Future<ValhallaRouteData> getSnappedRouteData(
    List<LatLng> points,
  ) async {
    if (points.length < 2) {
      return ValhallaRouteData(route: points, anchors: const []);
    }

    final shape = points
        .map((p) => {"lat": p.latitude, "lon": p.longitude})
        .toList();

    try {
      final response = await http.post(
        Uri.parse(_valhallaAttributesUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "shape": shape,
          "costing": "auto",
          "shape_match": "map_snap",
          "filters": {
            "attributes": [
              "shape",
              "edge.begin_shape_index",
              "edge.end_shape_index",
              "matched.point",
              "matched.edge_index",
              "matched.distance_along_edge",
            ],
            "action": "include",
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final encodedShape = data["shape"];
        final decoded = decodePolyline(encodedShape);
        final anchors = _buildRouteAnchors(
          decoded,
          data["edges"] as List<dynamic>? ?? const [],
          data["matched_points"] as List<dynamic>? ?? const [],
          points,
        );
        debugPrint(
          'Valhalla: snapped ${points.length} points to ${decoded.length} points with ${anchors.length} anchors',
        );
        return ValhallaRouteData(route: decoded, anchors: anchors);
      } else {
        debugPrint('Valhalla Error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error fetching Valhalla route: $e');
    }

    final fallbackRoute = await _fetchRouteShapeFallback(shape, points);
    return ValhallaRouteData(route: fallbackRoute, anchors: const []);
  }

  static Future<List<LatLng>> _fetchRouteShapeFallback(
    List<Map<String, double>> shape,
    List<LatLng> originalPoints,
  ) async {
    try {
      final response = await http.post(
        Uri.parse(_valhallaUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "shape": shape,
          "costing": "auto",
          "shape_match": "map_snap",
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final encodedShape = data["trip"]["legs"][0]["shape"];
        return decodePolyline(encodedShape);
      }
    } catch (_) {}

    return originalPoints;
  }

  static List<ValhallaRouteAnchor> _buildRouteAnchors(
    List<LatLng> route,
    List<dynamic> rawEdges,
    List<dynamic> rawMatchedPoints,
    List<LatLng> originalPoints,
  ) {
    if (route.length < 2 || rawMatchedPoints.isEmpty) {
      return const [];
    }

    final edges = rawEdges.cast<Map<dynamic, dynamic>>();
    final matchedPoints = rawMatchedPoints.cast<Map<dynamic, dynamic>>();
    final anchors = <ValhallaRouteAnchor>[];

    for (var index = 0; index < originalPoints.length; index++) {
      final matched = index < matchedPoints.length
          ? matchedPoints[index]
          : null;
      anchors.add(
        _buildAnchorForPoint(route, edges, matched, originalPoints[index]),
      );
    }

    return anchors;
  }

  static ValhallaRouteAnchor _buildAnchorForPoint(
    List<LatLng> route,
    List<Map<dynamic, dynamic>> edges,
    Map<dynamic, dynamic>? matchedPoint,
    LatLng originalPoint,
  ) {
    final fallbackPoint = LatLng(
      (matchedPoint?['lat'] as num?)?.toDouble() ?? originalPoint.latitude,
      (matchedPoint?['lon'] as num?)?.toDouble() ?? originalPoint.longitude,
    );
    final edgeIndex = (matchedPoint?['edge_index'] as num?)?.toInt();
    final distanceAlongEdge =
        ((matchedPoint?['distance_along_edge'] as num?)?.toDouble() ?? 0.0)
            .clamp(0.0, 1.0);

    if (edgeIndex == null || edgeIndex < 0 || edgeIndex >= edges.length) {
      return _buildClosestAnchor(route, fallbackPoint);
    }

    final edge = edges[edgeIndex];
    final beginShapeIndex = (edge['begin_shape_index'] as num?)?.toInt() ?? 0;
    var endShapeIndex =
        (edge['end_shape_index'] as num?)?.toInt() ?? beginShapeIndex + 1;
    final safeBegin = beginShapeIndex.clamp(0, route.length - 2);
    endShapeIndex = endShapeIndex.clamp(safeBegin + 1, route.length - 1);

    var totalLength = 0.0;
    for (var i = safeBegin; i < endShapeIndex; i++) {
      totalLength += _distance(route[i], route[i + 1]);
    }

    if (totalLength <= 0) {
      return ValhallaRouteAnchor(
        point: route[safeBegin],
        shapeIndex: safeBegin,
        shapeFraction: 0,
      );
    }

    final targetDistance = totalLength * distanceAlongEdge;
    var accumulated = 0.0;

    for (var i = safeBegin; i < endShapeIndex; i++) {
      final segmentLength = _distance(route[i], route[i + 1]);
      final nextDistance = accumulated + segmentLength;
      if (targetDistance <= nextDistance || i == endShapeIndex - 1) {
        final localFraction = segmentLength > 0
            ? ((targetDistance - accumulated) / segmentLength).clamp(0.0, 1.0)
            : 0.0;
        return ValhallaRouteAnchor(
          point: _interpolate(route[i], route[i + 1], localFraction),
          shapeIndex: i,
          shapeFraction: localFraction,
        );
      }
      accumulated = nextDistance;
    }

    return ValhallaRouteAnchor(
      point: route[endShapeIndex],
      shapeIndex: endShapeIndex - 1,
      shapeFraction: 1,
    );
  }

  static ValhallaRouteAnchor _buildClosestAnchor(
    List<LatLng> route,
    LatLng target,
  ) {
    var bestDistance = double.infinity;
    late ValhallaRouteAnchor bestAnchor;

    for (var i = 0; i < route.length - 1; i++) {
      final projection = _projectOnSegment(route[i], route[i + 1], target);
      if (projection.$2 < bestDistance) {
        bestDistance = projection.$2;
        bestAnchor = ValhallaRouteAnchor(
          point: projection.$1,
          shapeIndex: i,
          shapeFraction: projection.$3,
        );
      }
    }

    return bestAnchor;
  }

  static (LatLng, double, double) _projectOnSegment(
    LatLng start,
    LatLng end,
    LatLng target,
  ) {
    final averageLatRad =
        ((start.latitude + end.latitude + target.latitude) / 3) * pi / 180;
    final cosLat = cos(averageLatRad);
    final ax = start.longitude * cosLat;
    final ay = start.latitude;
    final bx = end.longitude * cosLat;
    final by = end.latitude;
    final px = target.longitude * cosLat;
    final py = target.latitude;
    final abx = bx - ax;
    final aby = by - ay;
    final ab2 = abx * abx + aby * aby;
    final rawFraction = ab2 > 0
        ? (((px - ax) * abx + (py - ay) * aby) / ab2)
        : 0.0;
    final fraction = rawFraction.clamp(0.0, 1.0);
    final projected = _interpolate(start, end, fraction);
    return (projected, _distance(target, projected), fraction);
  }

  static LatLng _interpolate(LatLng start, LatLng end, double fraction) {
    return LatLng(
      start.latitude + fraction * (end.latitude - start.latitude),
      start.longitude + fraction * (end.longitude - start.longitude),
    );
  }

  static double _distance(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final h =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return 2 * earthRadius * asin(sqrt(h));
  }
}
