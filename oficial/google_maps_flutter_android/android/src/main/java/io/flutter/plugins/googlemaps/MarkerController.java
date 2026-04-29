// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.googlemaps;

import android.animation.ValueAnimator;
import android.location.Location;
import android.view.animation.LinearInterpolator;
import com.google.android.gms.maps.model.AdvancedMarkerOptions;
import com.google.android.gms.maps.model.BitmapDescriptor;
import com.google.android.gms.maps.model.LatLng;
import com.google.android.gms.maps.model.Marker;
import com.google.maps.android.collections.MarkerManager;
import java.lang.ref.WeakReference;

/** Controller of a single Marker on the map. */
class MarkerController implements MarkerOptionsSink {

  // Holds a weak reference to a Marker instance. The clustering library
  // dynamically manages markers, adding and removing them from the map
  // as needed based on user interaction or data changes.
  private final WeakReference<Marker> weakMarker;
  private final String googleMapsMarkerId;
  private boolean consumeTapEvents;
  
  private ValueAnimator positionAnimator;
  private ValueAnimator rotationAnimator;

  private Double speed;
  private Integer maxDuration;

  public interface OnMarkerMovedListener {
    void onMarkerMoved(String markerId, LatLng newPosition);
  }

  private OnMarkerMovedListener movedListener;

  void setOnMarkerMovedListener(OnMarkerMovedListener listener) {
    this.movedListener = listener;
  }

  MarkerController(Marker marker, boolean consumeTapEvents) {
    this.weakMarker = new WeakReference<>(marker);
    this.consumeTapEvents = consumeTapEvents;
    this.googleMapsMarkerId = marker.getId();
  }

  void removeFromCollection(MarkerManager.Collection markerCollection) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    markerCollection.remove(marker);
  }

  @Override
  public void setAlpha(float alpha) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setAlpha(alpha);
  }

  @Override
  public void setAnchor(float u, float v) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setAnchor(u, v);
  }

  @Override
  public void setConsumeTapEvents(boolean consumeTapEvents) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    this.consumeTapEvents = consumeTapEvents;
  }

  @Override
  public void setDraggable(boolean draggable) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setDraggable(draggable);
  }

  @Override
  public void setFlat(boolean flat) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setFlat(flat);
  }

  @Override
  public void setIcon(BitmapDescriptor bitmapDescriptor) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setIcon(bitmapDescriptor);
  }

  @Override
  public void setInfoWindowAnchor(float u, float v) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setInfoWindowAnchor(u, v);
  }

  @Override
  public void setInfoWindowText(String title, String snippet) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setTitle(title);
    marker.setSnippet(snippet);
  }

  private double defaultSpeed = 60.0;
  private int defaultMaxDuration = 5000;

  void setAnimationDefaults(double speed, int maxDuration) {
    this.defaultSpeed = speed;
    this.defaultMaxDuration = maxDuration;
  }

  @Override
  public void setSpeed(Double speed) {
    this.speed = speed;
  }

  @Override
  public void setMaxDuration(Integer maxDuration) {
    this.maxDuration = maxDuration;
  }

  @Override
  public void setPosition(LatLng position) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    
    final LatLng startPosition = marker.getPosition();
    if (startPosition.equals(position)) {
      return;
    }

    if (positionAnimator != null) {
      positionAnimator.cancel();
    }

    // Calculate distance in meters
    float[] results = new float[1];
    Location.distanceBetween(
        startPosition.latitude, startPosition.longitude,
        position.latitude, position.longitude,
        results);
    float distanceInMeters = results[0];

    double currentSpeed = (this.speed != null) ? this.speed : this.defaultSpeed;
    int currentMaxDuration = (this.maxDuration != null) ? this.maxDuration : this.defaultMaxDuration;

    // Duration based on speed (meters per second)
    // duration (ms) = (distance / speed) * 1000
    long duration = (long) ((distanceInMeters / currentSpeed) * 1000);
    
    // Cap duration
    if (duration > currentMaxDuration) duration = currentMaxDuration;
    if (duration < 100) duration = 100;

    positionAnimator = ValueAnimator.ofFloat(0f, 1f);
    positionAnimator.setDuration(duration);
    positionAnimator.setInterpolator(new LinearInterpolator());
    positionAnimator.addUpdateListener(animation -> {
      Marker m = weakMarker.get();
      if (m != null) {
        float v = (float) animation.getAnimatedValue();
        double lat = v * position.latitude + (1 - v) * startPosition.latitude;
        double lng = v * position.longitude + (1 - v) * startPosition.longitude;
        LatLng currentPos = new LatLng(lat, lng);
        m.setPosition(currentPos);
        if (movedListener != null) {
          movedListener.onMarkerMoved(googleMapsMarkerId, currentPos);
        }
      }
    });
    positionAnimator.start();
  }

  @Override
  public void setRotation(float rotation) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    
    final float startRotation = marker.getRotation();
    if (startRotation == rotation) {
      return;
    }

    if (rotationAnimator != null) {
      rotationAnimator.cancel();
    }

    // Normalize rotation difference to take the shortest path
    float delta = rotation - startRotation;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    
    final float finalDelta = delta;

    rotationAnimator = ValueAnimator.ofFloat(0f, 1f);
    rotationAnimator.setDuration(250);
    rotationAnimator.setInterpolator(new LinearInterpolator());
    rotationAnimator.addUpdateListener(animation -> {
      Marker m = weakMarker.get();
      if (m != null) {
        float v = (float) animation.getAnimatedValue();
        m.setRotation(startRotation + v * finalDelta);
      }
    });
    rotationAnimator.start();
  }

  @Override
  public void setVisible(boolean visible) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setVisible(visible);
  }

  @Override
  public void setZIndex(float zIndex) {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.setZIndex(zIndex);
  }

  @Override
  public void setCollisionBehavior(
      @AdvancedMarkerOptions.CollisionBehavior int collisionBehavior) {}

  String getGoogleMapsMarkerId() {
    return googleMapsMarkerId;
  }

  boolean consumeTapEvents() {
    return consumeTapEvents;
  }

  public void showInfoWindow() {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.showInfoWindow();
  }

  public void hideInfoWindow() {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return;
    }
    marker.hideInfoWindow();
  }

  public boolean isInfoWindowShown() {
    Marker marker = weakMarker.get();
    if (marker == null) {
      return false;
    }
    return marker.isInfoWindowShown();
  }
}
