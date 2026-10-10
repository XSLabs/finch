/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreLocation. Finch has no positioning (no GPS, Wi-Fi positioning service or
 * location daemon) yet, so it answers as a Mac with Location Services turned off:
 * +locationServicesEnabled is NO, an app that asks for authorization is denied, and
 * asking for locations fails with kCLErrorDenied; geocoding, which needs Apple's
 * servers, fails with kCLErrorNetwork. The value classes (locations, headings,
 * regions, placemarks, visits) and the geodesy (distances on the WGS 84 ellipsoid)
 * work in full.
 */
#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

const CLLocationCoordinate2D kCLLocationCoordinate2DInvalid = {-180, -180};

BOOL
CLLocationCoordinate2DIsValid(CLLocationCoordinate2D coord)
{
    return coord.latitude >= -90 && coord.latitude <= 90 && coord.longitude >= -180 && coord.longitude <= 180;
}

CLLocationCoordinate2D
CLLocationCoordinate2DMake(CLLocationDegrees latitude, CLLocationDegrees longitude)
{
    CLLocationCoordinate2D c = {latitude, longitude};
    return c;
}

@interface NSObject (FinchCLInit)
- (instancetype)_finchInit __attribute__((objc_method_family(init)));
@end
@implementation NSObject (FinchCLInit)
- (instancetype)_finchInit { return [self init]; }
@end

/* Vincenty's inverse formula on the WGS 84 ellipsoid (metres); the great circle if it
   doesn't converge (nearly antipodal points). */
static double
geodesic_distance(CLLocationCoordinate2D p1, CLLocationCoordinate2D p2)
{
    const double a = 6378137.0, f = 1 / 298.257223563, b = a * (1 - f);
    double L = (p2.longitude - p1.longitude) * M_PI / 180;
    double U1 = atan((1 - f) * tan(p1.latitude * M_PI / 180)), U2 = atan((1 - f) * tan(p2.latitude * M_PI / 180));
    double sinU1 = sin(U1), cosU1 = cos(U1), sinU2 = sin(U2), cosU2 = cos(U2);
    double lambda = L, prev, sinSigma, cosSigma, sigma, cos2Alpha, cos2SigmaM;
    int i = 0;
    do {
        double sinL = sin(lambda), cosL = cos(lambda);
        sinSigma = sqrt((cosU2 * sinL) * (cosU2 * sinL) + (cosU1 * sinU2 - sinU1 * cosU2 * cosL) * (cosU1 * sinU2 - sinU1 * cosU2 * cosL));
        if (sinSigma == 0)
            return 0;
        cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosL;
        sigma = atan2(sinSigma, cosSigma);
        double sinAlpha = cosU1 * cosU2 * sinL / sinSigma;
        cos2Alpha = 1 - sinAlpha * sinAlpha;
        cos2SigmaM = cos2Alpha != 0 ? cosSigma - 2 * sinU1 * sinU2 / cos2Alpha : 0;
        double C = f / 16 * cos2Alpha * (4 + f * (4 - 3 * cos2Alpha));
        prev = lambda;
        lambda = L + (1 - C) * f * sinAlpha * (sigma + C * sinSigma * (cos2SigmaM + C * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));
    } while (fabs(lambda - prev) > 1e-12 && ++i < 200);
    if (i >= 200) {
        double phi1 = p1.latitude * M_PI / 180, phi2 = p2.latitude * M_PI / 180;
        double h = sin((phi2 - phi1) / 2) * sin((phi2 - phi1) / 2) + cos(phi1) * cos(phi2) * sin(L / 2) * sin(L / 2);
        return 2 * 6371008.8 * asin(sqrt(h));
    }
    double uSq = cos2Alpha * (a * a - b * b) / (b * b);
    double A = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)));
    double B = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)));
    double dSigma = B * sinSigma * (cos2SigmaM + B / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
                                                         B / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)));
    return b * A * (sigma - dSigma);
}

/* --- locations --- */

@implementation CLFloor {
    NSInteger _level;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (NSInteger)level { return _level; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeInteger:_level forKey:@"level"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super _finchInit]))
        _level = [coder decodeIntegerForKey:@"level"];
    return self;
}
@end

@implementation CLLocationSourceInformation {
    BOOL _simulated, _accessory;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithSoftwareSimulationState:(BOOL)isSoftware andExternalAccessoryState:(BOOL)wasProducedByAccessory
{
    if ((self = [super init])) {
        _simulated = isSoftware;
        _accessory = wasProducedByAccessory;
    }
    return self;
}
- (BOOL)isSimulatedBySoftware { return _simulated; }
- (BOOL)isProducedByAccessory { return _accessory; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBool:_simulated forKey:@"simulated"];
    [coder encodeBool:_accessory forKey:@"accessory"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithSoftwareSimulationState:[coder decodeBoolForKey:@"simulated"]
                       andExternalAccessoryState:[coder decodeBoolForKey:@"accessory"]];
}
@end

@implementation CLLocation {
    CLLocationCoordinate2D _coordinate;
    CLLocationDistance _altitude, _ellipsoidalAltitude;
    CLLocationAccuracy _horizontalAccuracy, _verticalAccuracy;
    CLLocationDirection _course;
    CLLocationDirectionAccuracy _courseAccuracy;
    CLLocationSpeed _speed;
    CLLocationSpeedAccuracy _speedAccuracy;
    NSDate *_timestamp;
    CLLocationSourceInformation *_sourceInformation;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithLatitude:(CLLocationDegrees)latitude longitude:(CLLocationDegrees)longitude
{
    return [self initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude) altitude:0 horizontalAccuracy:0
                   verticalAccuracy:-1 timestamp:[NSDate date]];
}

- (instancetype)initWithCoordinate:(CLLocationCoordinate2D)coordinate altitude:(CLLocationDistance)altitude
                horizontalAccuracy:(CLLocationAccuracy)hAccuracy verticalAccuracy:(CLLocationAccuracy)vAccuracy
                         timestamp:(NSDate *)timestamp
{
    return [self initWithCoordinate:coordinate altitude:altitude horizontalAccuracy:hAccuracy verticalAccuracy:vAccuracy
                             course:-1 courseAccuracy:-1 speed:-1 speedAccuracy:-1 timestamp:timestamp];
}

- (instancetype)initWithCoordinate:(CLLocationCoordinate2D)coordinate altitude:(CLLocationDistance)altitude
                horizontalAccuracy:(CLLocationAccuracy)hAccuracy verticalAccuracy:(CLLocationAccuracy)vAccuracy
                            course:(CLLocationDirection)course speed:(CLLocationSpeed)speed timestamp:(NSDate *)timestamp
{
    return [self initWithCoordinate:coordinate altitude:altitude horizontalAccuracy:hAccuracy verticalAccuracy:vAccuracy
                             course:course courseAccuracy:-1 speed:speed speedAccuracy:-1 timestamp:timestamp];
}

- (instancetype)initWithCoordinate:(CLLocationCoordinate2D)coordinate altitude:(CLLocationDistance)altitude
                horizontalAccuracy:(CLLocationAccuracy)hAccuracy verticalAccuracy:(CLLocationAccuracy)vAccuracy
                            course:(CLLocationDirection)course courseAccuracy:(CLLocationDirectionAccuracy)courseAccuracy
                             speed:(CLLocationSpeed)speed speedAccuracy:(CLLocationSpeedAccuracy)speedAccuracy
                         timestamp:(NSDate *)timestamp
{
    return [self initWithCoordinate:coordinate altitude:altitude horizontalAccuracy:hAccuracy verticalAccuracy:vAccuracy
                             course:course courseAccuracy:courseAccuracy speed:speed speedAccuracy:speedAccuracy
                          timestamp:timestamp sourceInfo:[[CLLocationSourceInformation alloc] initWithSoftwareSimulationState:NO
                                                                                                    andExternalAccessoryState:NO]];
}

- (instancetype)initWithCoordinate:(CLLocationCoordinate2D)coordinate altitude:(CLLocationDistance)altitude
                horizontalAccuracy:(CLLocationAccuracy)hAccuracy verticalAccuracy:(CLLocationAccuracy)vAccuracy
                            course:(CLLocationDirection)course courseAccuracy:(CLLocationDirectionAccuracy)courseAccuracy
                             speed:(CLLocationSpeed)speed speedAccuracy:(CLLocationSpeedAccuracy)speedAccuracy
                         timestamp:(NSDate *)timestamp sourceInfo:(CLLocationSourceInformation *)sourceInfo
{
    if ((self = [super init])) {
        _coordinate = coordinate;
        _altitude = _ellipsoidalAltitude = altitude;
        _horizontalAccuracy = hAccuracy;
        _verticalAccuracy = vAccuracy;
        _course = course;
        _courseAccuracy = courseAccuracy;
        _speed = speed;
        _speedAccuracy = speedAccuracy;
        _timestamp = timestamp ?: [NSDate date];
        _sourceInformation = sourceInfo;
    }
    return self;
}

- (CLLocationCoordinate2D)coordinate { return _coordinate; }
- (CLLocationDistance)altitude { return _altitude; }
- (CLLocationDistance)ellipsoidalAltitude { return _ellipsoidalAltitude; }
- (CLLocationAccuracy)horizontalAccuracy { return _horizontalAccuracy; }
- (CLLocationAccuracy)verticalAccuracy { return _verticalAccuracy; }
- (CLLocationDirection)course { return _course; }
- (CLLocationDirectionAccuracy)courseAccuracy { return _courseAccuracy; }
- (CLLocationSpeed)speed { return _speed; }
- (CLLocationSpeedAccuracy)speedAccuracy { return _speedAccuracy; }
- (NSDate *)timestamp { return _timestamp; }
- (CLFloor *)floor { return nil; }
- (CLLocationSourceInformation *)sourceInformation { return _sourceInformation; }

- (CLLocationDistance)distanceFromLocation:(const CLLocation *)location
{
    return geodesic_distance(_coordinate, location.coordinate);
}

- (CLLocationDistance)getDistanceFrom:(const CLLocation *)location { return [self distanceFromLocation:location]; }

- (NSString *)description
{
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateStyle = NSDateFormatterShortStyle;
    f.timeStyle = NSDateFormatterFullStyle;
    return [NSString stringWithFormat:@"<%+.8f,%+.8f> +/- %.2fm (speed %.2f mps / course %.2f) @ %@", _coordinate.latitude,
                                      _coordinate.longitude, _horizontalAccuracy, _speed, _course, [f stringFromDate:_timestamp]];
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_coordinate.latitude forKey:@"kCLLocationCodingKeyCoordinateLatitude"];
    [coder encodeDouble:_coordinate.longitude forKey:@"kCLLocationCodingKeyCoordinateLongitude"];
    [coder encodeDouble:_altitude forKey:@"kCLLocationCodingKeyAltitude"];
    [coder encodeDouble:_horizontalAccuracy forKey:@"kCLLocationCodingKeyHorizontalAccuracy"];
    [coder encodeDouble:_verticalAccuracy forKey:@"kCLLocationCodingKeyVerticalAccuracy"];
    [coder encodeDouble:_course forKey:@"kCLLocationCodingKeyCourse"];
    [coder encodeDouble:_courseAccuracy forKey:@"kCLLocationCodingKeyCourseAccuracy"];
    [coder encodeDouble:_speed forKey:@"kCLLocationCodingKeySpeed"];
    [coder encodeDouble:_speedAccuracy forKey:@"kCLLocationCodingKeySpeedAccuracy"];
    [coder encodeObject:_timestamp forKey:@"kCLLocationCodingKeyTimestamp"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    CLLocationCoordinate2D c = {[coder decodeDoubleForKey:@"kCLLocationCodingKeyCoordinateLatitude"],
                                [coder decodeDoubleForKey:@"kCLLocationCodingKeyCoordinateLongitude"]};
    return [self initWithCoordinate:c altitude:[coder decodeDoubleForKey:@"kCLLocationCodingKeyAltitude"]
                 horizontalAccuracy:[coder decodeDoubleForKey:@"kCLLocationCodingKeyHorizontalAccuracy"]
                   verticalAccuracy:[coder decodeDoubleForKey:@"kCLLocationCodingKeyVerticalAccuracy"]
                             course:[coder decodeDoubleForKey:@"kCLLocationCodingKeyCourse"]
                     courseAccuracy:[coder decodeDoubleForKey:@"kCLLocationCodingKeyCourseAccuracy"]
                              speed:[coder decodeDoubleForKey:@"kCLLocationCodingKeySpeed"]
                      speedAccuracy:[coder decodeDoubleForKey:@"kCLLocationCodingKeySpeedAccuracy"]
                          timestamp:[coder decodeObjectOfClass:[NSDate class] forKey:@"kCLLocationCodingKeyTimestamp"]];
}

@end

@implementation CLHeading
+ (BOOL)supportsSecureCoding { return YES; }
- (CLLocationDirection)magneticHeading { return -1; }
- (CLLocationDirection)trueHeading { return -1; }
- (CLLocationDirection)headingAccuracy { return -1; }
- (CLHeadingComponentValue)x { return 0; }
- (CLHeadingComponentValue)y { return 0; }
- (CLHeadingComponentValue)z { return 0; }
- (NSDate *)timestamp { return [NSDate date]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [self _finchInit]; }
@end

@implementation CLVisit
+ (BOOL)supportsSecureCoding { return YES; }
- (NSDate *)arrivalDate { return [NSDate distantPast]; }
- (NSDate *)departureDate { return [NSDate distantFuture]; }
- (CLLocationCoordinate2D)coordinate { return kCLLocationCoordinate2DInvalid; }
- (CLLocationAccuracy)horizontalAccuracy { return -1; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (instancetype)initWithCoder:(NSCoder *)coder { return [self _finchInit]; }
@end

/* --- regions --- */

@implementation CLRegion {
    @protected
    NSString *_identifier;
    CLLocationCoordinate2D _center;
    CLLocationDistance _radius;
    BOOL _notifyOnEntry, _notifyOnExit;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initCircularRegionWithCenter:(CLLocationCoordinate2D)center radius:(CLLocationDistance)radius identifier:(NSString *)identifier
{
    if ((self = [super _finchInit])) {
        _center = center;
        _radius = radius;
        _identifier = [identifier copy];
        _notifyOnEntry = _notifyOnExit = YES;
    }
    return self;
}

- (CLLocationCoordinate2D)center { return _center; }
- (CLLocationDistance)radius { return _radius; }
- (NSString *)identifier { return _identifier; }
- (BOOL)notifyOnEntry { return _notifyOnEntry; }
- (void)setNotifyOnEntry:(BOOL)v { _notifyOnEntry = v; }
- (BOOL)notifyOnExit { return _notifyOnExit; }
- (void)setNotifyOnExit:(BOOL)v { _notifyOnExit = v; }

- (BOOL)containsCoordinate:(CLLocationCoordinate2D)coordinate
{
    return geodesic_distance(_center, coordinate) <= _radius;
}

- (NSUInteger)hash { return _identifier.hash; }
- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[CLRegion class]] && [((CLRegion *)other)->_identifier isEqualToString:_identifier];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"identifier"];
    [coder encodeDouble:_center.latitude forKey:@"latitude"];
    [coder encodeDouble:_center.longitude forKey:@"longitude"];
    [coder encodeDouble:_radius forKey:@"radius"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initCircularRegionWithCenter:CLLocationCoordinate2DMake([coder decodeDoubleForKey:@"latitude"], [coder decodeDoubleForKey:@"longitude"])
                                       radius:[coder decodeDoubleForKey:@"radius"]
                                   identifier:[coder decodeObjectOfClass:[NSString class] forKey:@"identifier"]];
}
- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ (identifier:'%@', center:<%+.8f,%+.8f>, radius:%.2fm)", NSStringFromClass([self class]),
                                      _identifier, _center.latitude, _center.longitude, _radius];
}

@end

@implementation CLCircularRegion
- (instancetype)initWithCenter:(CLLocationCoordinate2D)center radius:(CLLocationDistance)radius identifier:(NSString *)identifier
{
    return [self initCircularRegionWithCenter:center radius:radius identifier:identifier];
}
@end

@implementation CLBeaconRegion
@end

/* --- placemarks and geocoding --- */

@implementation CLPlacemark {
    CLLocation *_location;
    NSString *_name;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithPlacemark:(CLPlacemark *)placemark
{
    if ((self = [super _finchInit])) {
        _location = placemark.location;
        _name = [placemark.name copy];
    }
    return self;
}
- (CLLocation *)location { return _location; }
- (CLRegion *)region { return nil; }
- (NSTimeZone *)timeZone { return nil; }
- (NSDictionary *)addressDictionary { return nil; }
- (NSString *)name { return _name; }
- (NSString *)thoroughfare { return nil; }
- (NSString *)subThoroughfare { return nil; }
- (NSString *)locality { return nil; }
- (NSString *)subLocality { return nil; }
- (NSString *)administrativeArea { return nil; }
- (NSString *)subAdministrativeArea { return nil; }
- (NSString *)postalCode { return nil; }
- (NSString *)ISOcountryCode { return nil; }
- (NSString *)country { return nil; }
- (NSString *)inlandWater { return nil; }
- (NSString *)ocean { return nil; }
- (NSArray<NSString *> *)areasOfInterest { return nil; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_location forKey:@"location"];
    [coder encodeObject:_name forKey:@"name"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super _finchInit])) {
        _location = [coder decodeObjectOfClass:[CLLocation class] forKey:@"location"];
        _name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"];
    }
    return self;
}
@end

/* Geocoding asks Apple's servers, which Finch doesn't use: each request fails as
   it does offline. */
@implementation CLGeocoder {
    BOOL _geocoding;
}

- (BOOL)isGeocoding { return _geocoding; }

- (void)_finchFail:(CLGeocodeCompletionHandler)handler
{
    if (!handler)
        return;
    _geocoding = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_geocoding = NO;
      handler(nil, [NSError errorWithDomain:kCLErrorDomain code:kCLErrorNetwork userInfo:nil]);
    });
}

- (void)reverseGeocodeLocation:(CLLocation *)location completionHandler:(CLGeocodeCompletionHandler)completionHandler
{
    [self _finchFail:completionHandler];
}
- (void)reverseGeocodeLocation:(CLLocation *)location preferredLocale:(NSLocale *)locale completionHandler:(CLGeocodeCompletionHandler)completionHandler
{
    [self _finchFail:completionHandler];
}
- (void)geocodeAddressDictionary:(NSDictionary *)addressDictionary completionHandler:(CLGeocodeCompletionHandler)completionHandler
{
    [self _finchFail:completionHandler];
}
- (void)geocodeAddressString:(NSString *)addressString completionHandler:(CLGeocodeCompletionHandler)completionHandler
{
    [self _finchFail:completionHandler];
}
- (void)geocodeAddressString:(NSString *)addressString inRegion:(CLRegion *)region completionHandler:(CLGeocodeCompletionHandler)completionHandler
{
    [self _finchFail:completionHandler];
}
- (void)geocodeAddressString:(NSString *)addressString inRegion:(CLRegion *)region preferredLocale:(NSLocale *)locale
           completionHandler:(CLGeocodeCompletionHandler)completionHandler
{
    [self _finchFail:completionHandler];
}
- (void)geocodePostalAddress:(id)postalAddress completionHandler:(CLGeocodeCompletionHandler)completionHandler
{
    [self _finchFail:completionHandler];
}
- (void)geocodePostalAddress:(id)postalAddress preferredLocale:(NSLocale *)locale completionHandler:(CLGeocodeCompletionHandler)completionHandler
{
    [self _finchFail:completionHandler];
}
- (void)cancelGeocode { _geocoding = NO; }
@end

/* --- the manager: Location Services off --- */

static NSString *const kAuthorizationKey = @"FinchCoreLocationAuthorization";

@implementation CLLocationManager {
    __weak id<CLLocationManagerDelegate> _delegate;
    CLLocationDistance _distanceFilter;
    CLLocationAccuracy _desiredAccuracy;
    CLActivityType _activityType;
    CLLocationDegrees _headingFilter;
    BOOL _pauses, _background;
    NSString *_purpose;
}

+ (BOOL)locationServicesEnabled { return NO; }
+ (BOOL)headingAvailable { return NO; }
+ (BOOL)significantLocationChangeMonitoringAvailable { return NO; }
+ (BOOL)isMonitoringAvailableForClass:(Class)regionClass { return NO; }
+ (BOOL)regionMonitoringAvailable { return NO; }
+ (BOOL)regionMonitoringEnabled { return NO; }
+ (BOOL)isRangingAvailable { return NO; }
+ (BOOL)deferredLocationUpdatesAvailable { return NO; }

static CLAuthorizationStatus
stored_status(void)
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kAuthorizationKey];
    return v ? (CLAuthorizationStatus)[v intValue] : kCLAuthorizationStatusNotDetermined;
}

+ (CLAuthorizationStatus)authorizationStatus { return stored_status(); }

- (instancetype)init
{
    if ((self = [super init])) {
        _distanceFilter = kCLDistanceFilterNone;
        _desiredAccuracy = kCLLocationAccuracyBest;
        _activityType = CLActivityTypeOther;
        _headingFilter = 1;
        _pauses = YES;
    }
    return self;
}

- (CLAuthorizationStatus)authorizationStatus { return stored_status(); }
- (CLAccuracyAuthorization)accuracyAuthorization { return CLAccuracyAuthorizationReducedAccuracy; }
- (BOOL)isAuthorizedForWidgetUpdates { return NO; }
- (id<CLLocationManagerDelegate>)delegate { return _delegate; }

/* As on macOS, a new delegate hears the current authorization. */
- (void)setDelegate:(id<CLLocationManagerDelegate>)delegate
{
    _delegate = delegate;
    if (delegate)
        [self _finchTellAuthorization];
}

- (void)_finchTellAuthorization
{
    __weak CLLocationManager *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      CLLocationManager *me = weakSelf;
      id<CLLocationManagerDelegate> d = me->_delegate;
      if ([d respondsToSelector:@selector(locationManagerDidChangeAuthorization:)])
          [d locationManagerDidChangeAuthorization:me];
      else if ([d respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)])
          [d locationManager:me didChangeAuthorizationStatus:stored_status()];
    });
}

- (void)_finchFail
{
    __weak CLLocationManager *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      CLLocationManager *me = weakSelf;
      id<CLLocationManagerDelegate> d = me->_delegate;
      if ([d respondsToSelector:@selector(locationManager:didFailWithError:)])
          [d locationManager:me didFailWithError:[NSError errorWithDomain:kCLErrorDomain code:kCLErrorDenied userInfo:nil]];
    });
}

/* Location Services are off: a request is answered with denial. */
- (void)requestWhenInUseAuthorization
{
    if (stored_status() == kCLAuthorizationStatusNotDetermined) {
        [[NSUserDefaults standardUserDefaults] setInteger:kCLAuthorizationStatusDenied forKey:kAuthorizationKey];
        [self _finchTellAuthorization];
    }
}

- (void)requestAlwaysAuthorization { [self requestWhenInUseAuthorization]; }

- (void)requestTemporaryFullAccuracyAuthorizationWithPurposeKey:(NSString *)purposeKey completion:(void (^)(NSError *))completion
{
    if (completion)
        dispatch_async(dispatch_get_main_queue(), ^{
          completion([NSError errorWithDomain:kCLErrorDomain code:kCLErrorDenied userInfo:nil]);
        });
}

- (void)requestTemporaryFullAccuracyAuthorizationWithPurposeKey:(NSString *)purposeKey
{
    [self requestTemporaryFullAccuracyAuthorizationWithPurposeKey:purposeKey completion:nil];
}

- (void)startUpdatingLocation { [self _finchFail]; }
- (void)stopUpdatingLocation {}
- (void)requestLocation { [self _finchFail]; }
- (void)startUpdatingHeading { [self _finchFail]; }
- (void)stopUpdatingHeading {}
- (void)dismissHeadingCalibrationDisplay {}
- (void)startMonitoringSignificantLocationChanges { [self _finchFail]; }
- (void)stopMonitoringSignificantLocationChanges {}
- (void)startMonitoringVisits { [self _finchFail]; }
- (void)stopMonitoringVisits {}

- (void)startMonitoringForRegion:(CLRegion *)region
{
    __weak CLLocationManager *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      CLLocationManager *me = weakSelf;
      id<CLLocationManagerDelegate> d = me->_delegate;
      if ([d respondsToSelector:@selector(locationManager:monitoringDidFailForRegion:withError:)])
          [d locationManager:me monitoringDidFailForRegion:region
                   withError:[NSError errorWithDomain:kCLErrorDomain code:kCLErrorRegionMonitoringDenied userInfo:nil]];
    });
}

- (void)startMonitoringForRegion:(CLRegion *)region desiredAccuracy:(CLLocationAccuracy)accuracy
{
    [self startMonitoringForRegion:region];
}

- (void)stopMonitoringForRegion:(CLRegion *)region {}
- (void)requestStateForRegion:(CLRegion *)region {}
- (void)startRangingBeaconsInRegion:(CLBeaconRegion *)region {}
- (void)stopRangingBeaconsInRegion:(CLBeaconRegion *)region {}
- (void)startRangingBeaconsSatisfyingConstraint:(CLBeaconIdentityConstraint *)constraint {}
- (void)stopRangingBeaconsSatisfyingConstraint:(CLBeaconIdentityConstraint *)constraint {}
- (void)allowDeferredLocationUpdatesUntilTraveled:(CLLocationDistance)distance timeout:(NSTimeInterval)timeout {}
- (void)disallowDeferredLocationUpdates {}

- (BOOL)locationServicesEnabled { return NO; }
- (BOOL)headingAvailable { return NO; }
- (NSString *)purpose { return _purpose; }
- (void)setPurpose:(NSString *)purpose { _purpose = [purpose copy]; }
- (CLActivityType)activityType { return _activityType; }
- (void)setActivityType:(CLActivityType)t { _activityType = t; }
- (CLLocationDistance)distanceFilter { return _distanceFilter; }
- (void)setDistanceFilter:(CLLocationDistance)d { _distanceFilter = d; }
- (CLLocationAccuracy)desiredAccuracy { return _desiredAccuracy; }
- (void)setDesiredAccuracy:(CLLocationAccuracy)a { _desiredAccuracy = a; }
- (BOOL)pausesLocationUpdatesAutomatically { return _pauses; }
- (void)setPausesLocationUpdatesAutomatically:(BOOL)v { _pauses = v; }
- (BOOL)allowsBackgroundLocationUpdates { return _background; }
- (void)setAllowsBackgroundLocationUpdates:(BOOL)v { _background = v; }
- (CLLocation *)location { return nil; }
- (CLLocationDegrees)headingFilter { return _headingFilter; }
- (void)setHeadingFilter:(CLLocationDegrees)f { _headingFilter = f; }
- (CLDeviceOrientation)headingOrientation { return CLDeviceOrientationPortrait; }
- (void)setHeadingOrientation:(CLDeviceOrientation)o {}
- (CLHeading *)heading { return nil; }
- (CLLocationDistance)maximumRegionMonitoringDistance { return -1; }
- (NSSet *)monitoredRegions { return [NSSet set]; }
- (NSSet *)rangedRegions { return [NSSet set]; }
- (NSSet *)rangedBeaconConstraints { return [NSSet set]; }

@end

/* Private classes apps link: the simulator's location override, and place inference. */
@interface CLSimulationManager : NSObject
@end
@implementation CLSimulationManager
- (void)clearSimulatedLocations {}
- (void)startLocationSimulation {}
- (void)stopLocationSimulation {}
- (void)appendSimulatedLocation:(CLLocation *)location {}
- (void)flush {}
@end

@interface _CLPlaceInference : NSObject
@end
@implementation _CLPlaceInference
@end
