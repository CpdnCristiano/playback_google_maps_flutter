// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.googlemaps;

import android.animation.ValueAnimator;
import android.location.Location;
import android.view.animation.LinearInterpolator;
import com.google.android.gms.maps.model.Cap;
import com.google.android.gms.maps.model.LatLng;
import com.google.android.gms.maps.model.PatternItem;
import com.google.android.gms.maps.model.Polyline;
import java.util.ArrayList;
import java.util.List;

/** Controller of a single Polyline on the map. */
class PolylineController implements PolylineOptionsSink {
  private final Polyline polyline;
  private final String googleMapsPolylineId;
  private boolean consumeTapEvents;
  private final float density;

  private ValueAnimator pointsAnimator;

  PolylineController(Polyline polyline, boolean consumeTapEvents, float density) {
    this.polyline = polyline;
    this.consumeTapEvents = consumeTapEvents;
    this.density = density;
    this.googleMapsPolylineId = polyline.getId();
  }

  void remove() {
    if (pointsAnimator != null) pointsAnimator.cancel();
    polyline.remove();
  }

  @Override
  public void setConsumeTapEvents(boolean consumeTapEvents) {
    this.consumeTapEvents = consumeTapEvents;
    polyline.setClickable(consumeTapEvents);
  }

  @Override
  public void setColor(int color) {
    polyline.setColor(color);
  }

  @Override
  public void setEndCap(Cap endCap) {
    polyline.setEndCap(endCap);
  }

  @Override
  public void setGeodesic(boolean geodesic) {
    polyline.setGeodesic(geodesic);
  }

  @Override
  public void setJointType(int jointType) {
    polyline.setJointType(jointType);
  }

  @Override
  public void setPattern(List<PatternItem> pattern) {
    polyline.setPattern(pattern);
  }

  @Override
  public void setPoints(List<LatLng> points) {
    final List<LatLng> oldPoints = polyline.getPoints();
    
    if (oldPoints.isEmpty() || points.size() != oldPoints.size() + 1) {
      polyline.setPoints(points);
      return;
    }

    // Check if the new points start with the old points
    boolean match = true;
    for (int i = 0; i < oldPoints.size(); i++) {
        if (!oldPoints.get(i).equals(points.get(i))) {
            match = false;
            break;
        }
    }

    if (!match) {
        polyline.setPoints(points);
        return;
    }

    if (pointsAnimator != null) {
      pointsAnimator.cancel();
    }

    final LatLng startPoint = oldPoints.get(oldPoints.size() - 1);
    final LatLng endPoint = points.get(points.size() - 1);

    long duration = 500; // Fixed 500ms for Polylines

    pointsAnimator = ValueAnimator.ofFloat(0f, 1f);
    pointsAnimator.setDuration(duration);
    pointsAnimator.setInterpolator(new LinearInterpolator());
    pointsAnimator.addUpdateListener(animation -> {
      float v = (float) animation.getAnimatedValue();
      double lat = v * endPoint.latitude + (1 - v) * startPoint.latitude;
      double lng = v * endPoint.longitude + (1 - v) * startPoint.longitude;
      
      List<LatLng> currentPoints = new ArrayList<>(oldPoints);
      currentPoints.add(new LatLng(lat, lng));
      polyline.setPoints(currentPoints);
    });
    pointsAnimator.start();
  }

  @Override
  public void setStartCap(Cap startCap) {
    polyline.setStartCap(startCap);
  }

  @Override
  public void setVisible(boolean visible) {
    polyline.setVisible(visible);
  }

  @Override
  public void setWidth(float width) {
    polyline.setWidth(width * density);
  }

  @Override
  public void setZIndex(float zIndex) {
    polyline.setZIndex(zIndex);
  }

  String getGoogleMapsPolylineId() {
    return googleMapsPolylineId;
  }

  boolean consumeTapEvents() {
    return consumeTapEvents;
  }
}
