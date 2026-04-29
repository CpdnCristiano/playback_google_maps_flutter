// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FGMPolylineController.h"
#import "FGMPolylineController_Test.h"

#import "FGMConversionUtils.h"

@interface FGMPolylineController ()

@property(strong, nonatomic) GMSPolyline *polyline;
@property(weak, nonatomic) GMSMapView *mapView;
@property(strong, nonatomic) NSTimer *pointsTimer;
@property(strong, nonatomic) GMSMutablePath *basePath;
@property(assign, nonatomic) CLLocationCoordinate2D targetPoint;
@property(assign, nonatomic) CLLocationCoordinate2D startPoint;
@property(assign, nonatomic) NSTimeInterval duration;
@property(assign, nonatomic) NSTimeInterval startTime;

@end

@implementation FGMPolylineController

- (instancetype)initWithPath:(GMSMutablePath *)path
                  identifier:(NSString *)identifier
                     mapView:(GMSMapView *)mapView {
  self = [super init];
  if (self) {
    _polyline = [GMSPolyline polylineWithPath:path];
    _mapView = mapView;
    _polyline.userData = @[ identifier ];
  }
  return self;
}

- (void)removePolyline {
  [self.pointsTimer invalidate];
  self.pointsTimer = nil;
  self.polyline.map = nil;
}

- (void)updateFromPlatformPolyline:(FGMPlatformPolyline *)platformPolyline {
  GMSPath *oldPath = self.polyline.path;
  NSArray<FGMPlatformLatLng *> *newPoints = platformPolyline.points;

  if (oldPath.count == 0 || newPoints.count != oldPath.count + 1) {
    [FGMPolylineController updatePolyline:self.polyline
                     fromPlatformPolyline:platformPolyline
                              withMapView:self.mapView];
    return;
  }

  // Check if new points match old path
  for (NSUInteger i = 0; i < oldPath.count; i++) {
    CLLocationCoordinate2D oldCoord = [oldPath coordinateAtIndex:i];
    FGMPlatformLatLng *newPoint = newPoints[i];
    if (oldCoord.latitude != newPoint.latitude || oldCoord.longitude != newPoint.longitude) {
      [FGMPolylineController updatePolyline:self.polyline
                       fromPlatformPolyline:platformPolyline
                                withMapView:self.mapView];
      return;
    }
  }

  [self.pointsTimer invalidate];

  self.startPoint = [oldPath coordinateAtIndex:oldPath.count - 1];
  FGMPlatformLatLng *targetLatLng = newPoints[newPoints.count - 1];
  self.targetPoint = CLLocationCoordinate2DMake(targetLatLng.latitude, targetLatLng.longitude);
  self.basePath = [oldPath mutableCopy];
  
  self.duration = 0.5; // Fixed 0.5s for Polylines
  self.startTime = [NSDate timeIntervalSinceReferenceDate];

  self.pointsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                     target:self
                                                   selector:@selector(onAnimationTick:)
                                                   userInfo:nil
                                                    repeats:YES];
  
  // Still update other properties (color, width, etc.)
  [FGMPolylineController updatePolyline:self.polyline
                   fromPlatformPolyline:platformPolyline
                            withMapView:self.mapView];
}

- (void)onAnimationTick:(NSTimer *)timer {
  NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.startTime;
  double fraction = elapsed / self.duration;
  if (fraction >= 1.0) {
    fraction = 1.0;
    [self.pointsTimer invalidate];
    self.pointsTimer = nil;
  }

  CLLocationCoordinate2D current;
  current.latitude = self.startPoint.latitude + (self.targetPoint.latitude - self.startPoint.latitude) * fraction;
  current.longitude = self.startPoint.longitude + (self.targetPoint.longitude - self.startPoint.longitude) * fraction;

  GMSMutablePath *path = [self.basePath mutableCopy];
  [path addCoordinate:current];
  self.polyline.path = path;
}

+ (void)updatePolyline:(GMSPolyline *)polyline
    fromPlatformPolyline:(FGMPlatformPolyline *)platformPolyline
             withMapView:(GMSMapView *)mapView {
  polyline.tappable = platformPolyline.consumesTapEvents;
  polyline.zIndex = (int)platformPolyline.zIndex;
  GMSMutablePath *path =
      FGMGetPathFromPoints(FGMGetPointsForPigeonLatLngs(platformPolyline.points));
  polyline.path = path;
  UIColor *strokeColor = FGMGetColorForPigeonColor(platformPolyline.color);
  polyline.strokeColor = strokeColor;
  polyline.strokeWidth = platformPolyline.width;
  polyline.geodesic = platformPolyline.geodesic;
  polyline.spans =
      GMSStyleSpans(path, FGMGetStrokeStylesFromPatterns(platformPolyline.patterns, strokeColor),
                    FGMGetSpanLengthsFromPatterns(platformPolyline.patterns), kGMSLengthRhumb);

  // This must be done last, to avoid visual flickers of default property values.
  polyline.map = platformPolyline.visible ? mapView : nil;
}

@end

@interface FGMPolylinesController ()

@property(strong, nonatomic) NSMutableDictionary *polylineIdentifierToController;
@property(weak, nonatomic) NSObject<FGMMapEventDelegate> *eventDelegate;
@property(weak, nonatomic) GMSMapView *mapView;

@end
;

@implementation FGMPolylinesController

- (instancetype)initWithMapView:(GMSMapView *)mapView
                  eventDelegate:(NSObject<FGMMapEventDelegate> *)eventDelegate {
  self = [super init];
  if (self) {
    _eventDelegate = eventDelegate;
    _mapView = mapView;
    _polylineIdentifierToController = [NSMutableDictionary dictionaryWithCapacity:1];
  }
  return self;
}

- (void)addPolylines:(NSArray<FGMPlatformPolyline *> *)polylinesToAdd {
  for (FGMPlatformPolyline *polyline in polylinesToAdd) {
    GMSMutablePath *path = FGMGetPathFromPoints(FGMGetPointsForPigeonLatLngs(polyline.points));
    NSString *identifier = polyline.polylineId;
    FGMPolylineController *controller = [[FGMPolylineController alloc] initWithPath:path
                                                                         identifier:identifier
                                                                            mapView:self.mapView];
    [controller updateFromPlatformPolyline:polyline];
    self.polylineIdentifierToController[identifier] = controller;
  }
}

- (void)changePolylines:(NSArray<FGMPlatformPolyline *> *)polylinesToChange {
  for (FGMPlatformPolyline *polyline in polylinesToChange) {
    NSString *identifier = polyline.polylineId;
    FGMPolylineController *controller = self.polylineIdentifierToController[identifier];
    [controller updateFromPlatformPolyline:polyline];
  }
}

- (void)removePolylineWithIdentifiers:(NSArray<NSString *> *)identifiers {
  for (NSString *identifier in identifiers) {
    FGMPolylineController *controller = self.polylineIdentifierToController[identifier];
    if (!controller) {
      continue;
    }
    [controller removePolyline];
    [self.polylineIdentifierToController removeObjectForKey:identifier];
  }
}

- (void)didTapPolylineWithIdentifier:(NSString *)identifier {
  if (!identifier) {
    return;
  }
  FGMPolylineController *controller = self.polylineIdentifierToController[identifier];
  if (!controller) {
    return;
  }
  [self.eventDelegate didTapPolylineWithIdentifier:identifier];
}

- (bool)hasPolylineWithIdentifier:(NSString *)identifier {
  if (!identifier) {
    return false;
  }
  return self.polylineIdentifierToController[identifier] != nil;
}

@end
