//
//  EDSunriseSet.swift
//
//  Created by Ernesto Garcia on 20/08/11.
//  Copyright 2011 Ernesto Garcia. All rights reserved.
//

//  C/C++ sun calculations created by Paul Schlyter
//  sunriset.c
//  http://stjarnhimlen.se/english.html
//  SUNRISET.C - computes Sun rise/set times, start/end of twilight, and
//  the length of the day at any date and latitude
//  Written as DAYLEN.C, 1989-08-16
//  Modified to SUNRISET.C, 1992-12-01
//  (c) Paul Schlyter, 1989, 1992
//  Released to the public domain by Paul Schlyter, December 1992

import Foundation

// MARK: - Constants

private let INV360 = 1.0 / 360.0
private let RADEG  = 180.0 / .pi
private let DEGRAD = Double.pi / 180.0

// Trigonometric functions in degrees
private func sind(_ x: Double) -> Double { sin(x * DEGRAD) }
private func cosd(_ x: Double) -> Double { cos(x * DEGRAD) }
private func tand(_ x: Double) -> Double { tan(x * DEGRAD) }
private func atand(_ x: Double) -> Double { RADEG * atan(x) }
private func asind(_ x: Double) -> Double { RADEG * asin(x) }
private func acosd(_ x: Double) -> Double { RADEG * acos(x) }
private func atan2d(_ y: Double, _ x: Double) -> Double { RADEG * atan2(y, x) }

/// Number of days elapsed since 2000 Jan 0.0 (which is equal to 1999 Dec 31, 0h UT)
private func daysSince2000Jan0(year y: Int, month m: Int, day d: Int) -> Double {
    Double(367 * y - ((7 * (y + ((m + 9) / 12))) / 4) + ((275 * m) / 9) + d - 730530)
}

// MARK: - EDSunriseSet

@objc class EDSunriseSet: NSObject {

    // MARK: Public read-only properties

    @objc private(set) var date: Date
    @objc private(set) var sunset: Date!
    @objc private(set) var sunrise: Date!
    @objc private(set) var civilTwilightStart: Date!
    @objc private(set) var civilTwilightEnd: Date!
    @objc private(set) var nauticalTwilightStart: Date!
    @objc private(set) var nauticalTwilightEnd: Date!
    @objc private(set) var astronomicalTwilightStart: Date!
    @objc private(set) var astronomicalTwilightEnd: Date!

    @objc private(set) var localSunrise: DateComponents!
    @objc private(set) var localSunset: DateComponents!
    @objc private(set) var localCivilTwilightStart: DateComponents!
    @objc private(set) var localCivilTwilightEnd: DateComponents!
    @objc private(set) var localNauticalTwilightStart: DateComponents!
    @objc private(set) var localNauticalTwilightEnd: DateComponents!
    @objc private(set) var localAstronomicalTwilightStart: DateComponents!
    @objc private(set) var localAstronomicalTwilightEnd: DateComponents!

    // MARK: Private properties

    private var latitude: Double
    private var longitude: Double
    private var timezone: TimeZone
    private var calendar: Calendar
    private var utcTimeZone: TimeZone

    private static let kSecondsInHour: Double = 60.0 * 60.0

    // MARK: - Initialization

    @objc init(date: Date, timezone tz: TimeZone, latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = tz
        self.date = date

        self.calendar = Calendar(identifier: .gregorian)
        self.utcTimeZone = TimeZone(abbreviation: "UTC")!

        super.init()

        calculate()
    }

    @objc class func sunriseset(withDate date: Date, timezone tz: TimeZone, latitude: Double, longitude: Double) -> EDSunriseSet {
        return EDSunriseSet(date: date, timezone: tz, latitude: latitude, longitude: longitude)
    }

    // MARK: - Calculations (from sunriset.c)

    /// Reduce angle to within 0..360 degrees
    private func revolution(_ x: Double) -> Double {
        return x - 360.0 * floor(x * INV360)
    }

    /// Reduce angle to within -180..+180 degrees
    private func rev180(_ x: Double) -> Double {
        return x - 360.0 * floor(x * INV360 + 0.5)
    }

    private func gmst0(_ d: Double) -> Double {
        // Sidtime at 0h UT = L (Sun's mean longitude) + 180.0 degr
        // L = M + w, as defined in sunpos().
        return revolution((180.0 + 356.0470 + 282.9404) + (0.9856002585 + 4.70935e-5) * d)
    }

    /// Computes the Sun's ecliptic longitude and distance
    /// at an instant given in d, number of days since 2000 Jan 0.0.
    private func sunpos(atDay d: Double) -> (lon: Double, r: Double) {
        // Compute mean elements
        let M = revolution(356.0470 + 0.9856002585 * d)  // Mean anomaly of the Sun
        let w = 282.9404 + 4.70935e-5 * d                // Mean longitude of perihelion
        let e = 0.016709 - 1.151e-9 * d                  // Eccentricity of Earth's orbit

        // Compute true longitude and radius vector
        let E = M + e * RADEG * sind(M) * (1.0 + e * cosd(M)) // Eccentric anomaly
        let x = cosd(E) - e
        let y = sqrt(1.0 - e * e) * sind(E)
        let r = sqrt(x * x + y * y)       // Solar distance
        let v = atan2d(y, x)              // True anomaly
        var lon = v + w                    // True solar longitude
        if lon >= 360.0 {
            lon -= 360.0
        }
        return (lon, r)
    }

    private func sunRADec(atDay d: Double) -> (ra: Double, dec: Double, r: Double) {
        // Compute Sun's ecliptical coordinates
        let (lon, r) = sunpos(atDay: d)

        // Compute ecliptic rectangular coordinates
        let xs = r * cosd(lon)
        let ys = r * sind(lon)
        // zs = 0 because the Sun is always in the ecliptic plane

        // Compute obliquity of ecliptic (inclination of Earth's axis)
        let obl_ecl = 23.4393 - 3.563e-7 * d

        // Convert to equatorial rectangular coordinates - x is unchanged
        let xe = xs
        let ye = ys * cosd(obl_ecl)
        let ze = ys * sind(obl_ecl)

        // Convert to spherical coordinates
        let ra = atan2d(ye, xe)
        let dec = atan2d(ze, sqrt(xe * xe + ye * ye))

        return (ra, dec, r)
    }

    private func sunRiseSet(forYear year: Int, month: Int, day: Int,
                            longitude lon: Double, latitude lat: Double) -> (rc: Int, trise: Double, tset: Double) {
        return sunRiseSetHelper(forYear: year, month: month, day: day,
                                longitude: lon, latitude: lat,
                                altitude: -35.0 / 60.0, upperLimb: 1)
    }

    private func civilTwilight(forYear year: Int, month: Int, day: Int,
                               longitude lon: Double, latitude lat: Double) -> (rc: Int, trise: Double, tset: Double) {
        return sunRiseSetHelper(forYear: year, month: month, day: day,
                                longitude: lon, latitude: lat,
                                altitude: -6.0, upperLimb: 0)
    }

    private func nauticalTwilight(forYear year: Int, month: Int, day: Int,
                                  longitude lon: Double, latitude lat: Double) -> (rc: Int, trise: Double, tset: Double) {
        return sunRiseSetHelper(forYear: year, month: month, day: day,
                                longitude: lon, latitude: lat,
                                altitude: -12.0, upperLimb: 0)
    }

    private func astronomicalTwilight(forYear year: Int, month: Int, day: Int,
                                      longitude lon: Double, latitude lat: Double) -> (rc: Int, trise: Double, tset: Double) {
        return sunRiseSetHelper(forYear: year, month: month, day: day,
                                longitude: lon, latitude: lat,
                                altitude: -18.0, upperLimb: 0)
    }

    /// Note: year,month,date = calendar date, 1801-2099 only.
    ///       Eastern longitude positive, Western longitude negative
    ///       Northern latitude positive, Southern latitude negative
    ///       The longitude value IS critical in this function!
    ///       altit = the altitude which the Sun should cross
    ///               Set to -35/60 degrees for rise/set, -6 degrees
    ///               for civil, -12 degrees for nautical and -18
    ///               degrees for astronomical twilight.
    ///         upper_limb: non-zero -> upper limb, zero -> center
    ///               Set to non-zero (e.g. 1) when computing rise/set
    ///               times, and to zero when computing start/end of
    ///               twilight.
    /// Return value:  0 = sun rises/sets this day
    ///               +1 = sun above the specified "horizon" 24 hours
    ///               -1 = sun is below the specified "horizon" 24 hours
    private func sunRiseSetHelper(forYear year: Int, month: Int, day: Int,
                                  longitude lon: Double, latitude lat: Double,
                                  altitude altit: Double, upperLimb upper_limb: Int) -> (rc: Int, trise: Double, tset: Double) {
        var altit = altit

        // Days since 2000 Jan 0.0 (negative before)
        let d = daysSince2000Jan0(year: year, month: month, day: day) + 0.5 - lon / 360.0

        var rc = 0

        // Compute local sidereal time of this moment
        let sidtime = revolution(gmst0(d) + 180.0 + lon)

        // Compute Sun's RA + Decl at this moment
        let (sRA, sdec, sr) = sunRADec(atDay: d)

        // Compute time when Sun is at south - in hours UT
        let tsouth = 12.0 - rev180(sidtime - sRA) / 15.0

        // Compute the Sun's apparent radius, degrees
        let sradius = 0.2666 / sr

        // Do correction to upper limb, if necessary
        if upper_limb != 0 {
            altit -= sradius
        }

        // Compute the diurnal arc that the Sun traverses to reach
        // the specified altitude altit:
        let t: Double
        let cost = (sind(altit) - sind(lat) * sind(sdec)) / (cosd(lat) * cosd(sdec))
        if cost >= 1.0 {
            rc = -1
            t = 0.0       // Sun always below altit
        } else if cost <= -1.0 {
            rc = +1
            t = 12.0      // Sun always above altit
        } else {
            t = acosd(cost) / 15.0   // The diurnal arc, hours
        }

        // Store rise and set times - in hours UT
        let trise = tsouth - t
        let tset = tsouth + t

        return (rc, trise, tset)
    }

    // MARK: - Private helpers

    private func utcTime(_ dateComponents: DateComponents, withOffset interval: TimeInterval) -> Date {
        var cal = calendar
        cal.timeZone = utcTimeZone
        return cal.date(from: dateComponents)!.addingTimeInterval(interval)
    }

    private func localTime(_ refDate: Date) -> DateComponents {
        var cal = calendar
        cal.timeZone = timezone
        return cal.dateComponents([.hour, .minute, .second], from: refDate)
    }

    override var description: String {
        return """
            Date: \(date.description)
            TimeZone: \(timezone.identifier)
            Local Sunrise: \(localSunrise.description)
            Local Sunset: \(localSunset.description)
            Local Civil Twilight Start: \(localCivilTwilightStart.description)
            Local Civil Twilight End: \(localCivilTwilightEnd.description)
            Local Nautical Twilight Start: \(localNauticalTwilightStart.description)
            Local Nautical Twilight End: \(localNauticalTwilightEnd.description)
            Local Astronomical Twilight Start: \(localAstronomicalTwilightStart.description)
            Local Astronomical Twilight End: \(localAstronomicalTwilightEnd.description)
            """
    }

    // MARK: - Calculation methods

    private func calculateSunriseSunset() {
        var cal = calendar
        cal.timeZone = timezone
        let dateComponents = cal.dateComponents([.year, .month, .day], from: date)

        let (_, rise, set) = sunRiseSet(forYear: dateComponents.year!, month: dateComponents.month!, day: dateComponents.day!,
                                        longitude: longitude, latitude: latitude)
        let secondsRise = rise * EDSunriseSet.kSecondsInHour
        let secondsSet = set * EDSunriseSet.kSecondsInHour

        sunrise = utcTime(dateComponents, withOffset: secondsRise)
        sunset = utcTime(dateComponents, withOffset: secondsSet)
        localSunrise = localTime(sunrise)
        localSunset = localTime(sunset)
    }

    private func calculateTwilight() {
        var cal = calendar
        cal.timeZone = timezone
        let dateComponents = cal.dateComponents([.year, .month, .day], from: date)

        // Civil twilight
        var (_, start, end) = civilTwilight(forYear: dateComponents.year!, month: dateComponents.month!, day: dateComponents.day!,
                                            longitude: longitude, latitude: latitude)
        civilTwilightStart = utcTime(dateComponents, withOffset: start * EDSunriseSet.kSecondsInHour)
        civilTwilightEnd = utcTime(dateComponents, withOffset: end * EDSunriseSet.kSecondsInHour)
        localCivilTwilightStart = localTime(civilTwilightStart)
        localCivilTwilightEnd = localTime(civilTwilightEnd)

        // Nautical twilight
        (_, start, end) = nauticalTwilight(forYear: dateComponents.year!, month: dateComponents.month!, day: dateComponents.day!,
                                           longitude: longitude, latitude: latitude)
        nauticalTwilightStart = utcTime(dateComponents, withOffset: start * EDSunriseSet.kSecondsInHour)
        nauticalTwilightEnd = utcTime(dateComponents, withOffset: end * EDSunriseSet.kSecondsInHour)
        localNauticalTwilightStart = localTime(nauticalTwilightStart)
        localNauticalTwilightEnd = localTime(nauticalTwilightEnd)

        // Astronomical twilight
        (_, start, end) = astronomicalTwilight(forYear: dateComponents.year!, month: dateComponents.month!, day: dateComponents.day!,
                                               longitude: longitude, latitude: latitude)
        astronomicalTwilightStart = utcTime(dateComponents, withOffset: start * EDSunriseSet.kSecondsInHour)
        astronomicalTwilightEnd = utcTime(dateComponents, withOffset: end * EDSunriseSet.kSecondsInHour)
        localAstronomicalTwilightStart = localTime(astronomicalTwilightStart)
        localAstronomicalTwilightEnd = localTime(astronomicalTwilightEnd)
    }

    private func calculate() {
        calculateSunriseSunset()
        calculateTwilight()
    }
}
