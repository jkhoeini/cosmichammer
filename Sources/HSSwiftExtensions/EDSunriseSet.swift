//
//  EDSunriseSet_new.swift
//
//  Created by Ernesto García on 20/08/11.
//  Copyright 2011 Ernesto García. All rights reserved.
//
//  Swift port preserving the full public API of EDSunriseSet.h/.m.
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
//

import Foundation

@objc class EDSunriseSet: NSObject {

    // MARK: - Public readonly properties

    @objc private(set) var date: Date
    @objc private(set) var sunset: Date
    @objc private(set) var sunrise: Date
    @objc private(set) var civilTwilightStart: Date
    @objc private(set) var civilTwilightEnd: Date
    @objc private(set) var nauticalTwilightStart: Date
    @objc private(set) var nauticalTwilightEnd: Date
    @objc private(set) var astronomicalTwilightStart: Date
    @objc private(set) var astronomicalTwilightEnd: Date

    @objc private(set) var localSunrise: DateComponents
    @objc private(set) var localSunset: DateComponents
    @objc private(set) var localCivilTwilightStart: DateComponents
    @objc private(set) var localCivilTwilightEnd: DateComponents
    @objc private(set) var localNauticalTwilightStart: DateComponents
    @objc private(set) var localNauticalTwilightEnd: DateComponents
    @objc private(set) var localAstronomicalTwilightStart: DateComponents
    @objc private(set) var localAstronomicalTwilightEnd: DateComponents

    // MARK: - Private properties

    private var latitude: Double
    private var longitude: Double
    private var timezone: TimeZone
    private var calendar: Calendar
    private let utcTimeZone: TimeZone

    // MARK: - Constants

    private static let INV360: Double = 1.0 / 360.0
    private static let RADEG: Double  = 180.0 / .pi
    private static let DEGRAD: Double = .pi / 180.0
    private static let kSecondsInHour: Double = 3600.0

    // MARK: - Trig helpers (degrees)

    private static func sind(_ x: Double) -> Double { sin(x * DEGRAD) }
    private static func cosd(_ x: Double) -> Double { cos(x * DEGRAD) }
    private static func tand(_ x: Double) -> Double { tan(x * DEGRAD) }
    private static func atand(_ x: Double) -> Double { RADEG * atan(x) }
    private static func asind(_ x: Double) -> Double { RADEG * asin(x) }
    private static func acosd(_ x: Double) -> Double { RADEG * acos(x) }
    private static func atan2d(_ y: Double, _ x: Double) -> Double { RADEG * atan2(y, x) }

    // MARK: - Initialization

    @objc init(date: Date, timezone tz: TimeZone, latitude: Double, longitude: Double) {
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = tz
        self.calendar = Calendar(identifier: .gregorian)
        self.utcTimeZone = TimeZone(abbreviation: "UTC")!

        // Placeholder values; will be overwritten by calculate()
        let epoch = Date(timeIntervalSince1970: 0)
        let emptyComps = DateComponents()
        self.sunrise = epoch
        self.sunset = epoch
        self.civilTwilightStart = epoch
        self.civilTwilightEnd = epoch
        self.nauticalTwilightStart = epoch
        self.nauticalTwilightEnd = epoch
        self.astronomicalTwilightStart = epoch
        self.astronomicalTwilightEnd = epoch
        self.localSunrise = emptyComps
        self.localSunset = emptyComps
        self.localCivilTwilightStart = emptyComps
        self.localCivilTwilightEnd = emptyComps
        self.localNauticalTwilightStart = emptyComps
        self.localNauticalTwilightEnd = emptyComps
        self.localAstronomicalTwilightStart = emptyComps
        self.localAstronomicalTwilightEnd = emptyComps

        super.init()
        calculate()
    }

    @objc static func sunriseset(withDate date: Date, timezone tz: TimeZone,
                                  latitude: Double, longitude: Double) -> EDSunriseSet {
        return EDSunriseSet(date: date, timezone: tz, latitude: latitude, longitude: longitude)
    }

    // MARK: - Description

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

    // MARK: - Astronomical calculations

    /// Reduce angle to within 0..360 degrees
    private func revolution(_ x: Double) -> Double {
        x - 360.0 * floor(x * EDSunriseSet.INV360)
    }

    /// Reduce angle to within -180..+180 degrees
    private func rev180(_ x: Double) -> Double {
        x - 360.0 * floor(x * EDSunriseSet.INV360 + 0.5)
    }

    /// Number of days elapsed since 2000 Jan 0.0
    private static func daysSince2000Jan0(year y: Int, month m: Int, day d: Int) -> Int {
        367 * y - ((7 * (y + ((m + 9) / 12))) / 4) + ((275 * m) / 9) + d - 730530
    }

    /// GMST0 — sidereal time at 0h UT
    private func gmst0(_ d: Double) -> Double {
        revolution((180.0 + 356.0470 + 282.9404) + (0.9856002585 + 4.70935e-5) * d)
    }

    /// Computes the Sun's ecliptic longitude and distance
    private func sunpos(d: Double) -> (lon: Double, r: Double) {
        let M = revolution(356.0470 + 0.9856002585 * d)
        let w = 282.9404 + 4.70935e-5 * d
        let e = 0.016709 - 1.151e-9 * d

        let E = M + e * EDSunriseSet.RADEG * EDSunriseSet.sind(M) * (1.0 + e * EDSunriseSet.cosd(M))
        let x = EDSunriseSet.cosd(E) - e
        let y = sqrt(1.0 - e * e) * EDSunriseSet.sind(E)
        let r = sqrt(x * x + y * y)
        let v = EDSunriseSet.atan2d(y, x)
        var lon = v + w
        if lon >= 360.0 { lon -= 360.0 }
        return (lon, r)
    }

    /// Computes the Sun's RA and declination
    private func sunRADec(d: Double) -> (ra: Double, dec: Double, r: Double) {
        let (lon, r) = sunpos(d: d)

        let xs = r * EDSunriseSet.cosd(lon)
        let ys = r * EDSunriseSet.sind(lon)
        // zs = 0 (Sun is always in the ecliptic plane)

        let oblEcl = 23.4393 - 3.563e-7 * d

        let xe = xs
        let ye = ys * EDSunriseSet.cosd(oblEcl)
        let ze = ys * EDSunriseSet.sind(oblEcl)

        let ra  = EDSunriseSet.atan2d(ye, xe)
        let dec = EDSunriseSet.atan2d(ze, sqrt(xe * xe + ye * ye))
        return (ra, dec, r)
    }

    // MARK: - Rise/set core

    /// Core sunrise/set helper.
    /// Returns (rise, set) in hours UT.
    /// Return code: 0 = normal, +1 = sun always above, -1 = sun always below.
    private func sunRiseSetHelper(year: Int, month: Int, day: Int,
                                  lon: Double, lat: Double,
                                  altit: Double, upperLimb: Bool) -> (rise: Double, set: Double, rc: Int) {
        let d = Double(EDSunriseSet.daysSince2000Jan0(year: year, month: month, day: day)) + 0.5 - lon / 360.0

        let sidtime = revolution(gmst0(d) + 180.0 + lon)
        let (sRA, sdec, sr) = sunRADec(d: d)
        let tsouth = 12.0 - rev180(sidtime - sRA) / 15.0
        let sradius = 0.2666 / sr

        var alt = altit
        if upperLimb { alt -= sradius }

        let cost = (EDSunriseSet.sind(alt) - EDSunriseSet.sind(lat) * EDSunriseSet.sind(sdec))
                 / (EDSunriseSet.cosd(lat) * EDSunriseSet.cosd(sdec))

        let t: Double
        let rc: Int
        if cost >= 1.0 {
            rc = -1
            t = 0.0        // Sun always below altit
        } else if cost <= -1.0 {
            rc = 1
            t = 12.0       // Sun always above altit
        } else {
            rc = 0
            t = EDSunriseSet.acosd(cost) / 15.0
        }

        return (tsouth - t, tsouth + t, rc)
    }

    private func sunRiseSet(year: Int, month: Int, day: Int,
                            lon: Double, lat: Double) -> (rise: Double, set: Double, rc: Int) {
        sunRiseSetHelper(year: year, month: month, day: day,
                         lon: lon, lat: lat, altit: -35.0 / 60.0, upperLimb: true)
    }

    private func civilTwilight(year: Int, month: Int, day: Int,
                               lon: Double, lat: Double) -> (rise: Double, set: Double, rc: Int) {
        sunRiseSetHelper(year: year, month: month, day: day,
                         lon: lon, lat: lat, altit: -6.0, upperLimb: false)
    }

    private func nauticalTwilight(year: Int, month: Int, day: Int,
                                  lon: Double, lat: Double) -> (rise: Double, set: Double, rc: Int) {
        sunRiseSetHelper(year: year, month: month, day: day,
                         lon: lon, lat: lat, altit: -12.0, upperLimb: false)
    }

    private func astronomicalTwilight(year: Int, month: Int, day: Int,
                                      lon: Double, lat: Double) -> (rise: Double, set: Double, rc: Int) {
        sunRiseSetHelper(year: year, month: month, day: day,
                         lon: lon, lat: lat, altit: -18.0, upperLimb: false)
    }

    // MARK: - Date conversion helpers

    private func utcTime(dateComponents comps: DateComponents, offset interval: TimeInterval) -> Date {
        var cal = calendar
        cal.timeZone = utcTimeZone
        return cal.date(from: comps)!.addingTimeInterval(interval)
    }

    private func localTime(from refDate: Date) -> DateComponents {
        var cal = calendar
        cal.timeZone = timezone
        return cal.dateComponents([.hour, .minute, .second], from: refDate)
    }

    // MARK: - High-level calculation

    private func calculateSunriseSunset() {
        calendar.timeZone = timezone
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let year  = comps.year!
        let month = comps.month!
        let day   = comps.day!

        let (rise, set, _) = sunRiseSet(year: year, month: month, day: day,
                                        lon: longitude, lat: latitude)

        let secondsRise = rise * EDSunriseSet.kSecondsInHour
        let secondsSet  = set  * EDSunriseSet.kSecondsInHour

        sunrise = utcTime(dateComponents: comps, offset: secondsRise)
        sunset  = utcTime(dateComponents: comps, offset: secondsSet)
        localSunrise = localTime(from: sunrise)
        localSunset  = localTime(from: sunset)
    }

    private func calculateTwilight() {
        calendar.timeZone = timezone
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let year  = comps.year!
        let month = comps.month!
        let day   = comps.day!

        // Civil twilight
        let (civilStart, civilEnd, _) = civilTwilight(year: year, month: month, day: day,
                                                      lon: longitude, lat: latitude)
        civilTwilightStart = utcTime(dateComponents: comps, offset: civilStart * EDSunriseSet.kSecondsInHour)
        civilTwilightEnd   = utcTime(dateComponents: comps, offset: civilEnd * EDSunriseSet.kSecondsInHour)
        localCivilTwilightStart = localTime(from: civilTwilightStart)
        localCivilTwilightEnd   = localTime(from: civilTwilightEnd)

        // Nautical twilight
        let (nautStart, nautEnd, _) = nauticalTwilight(year: year, month: month, day: day,
                                                       lon: longitude, lat: latitude)
        nauticalTwilightStart = utcTime(dateComponents: comps, offset: nautStart * EDSunriseSet.kSecondsInHour)
        nauticalTwilightEnd   = utcTime(dateComponents: comps, offset: nautEnd * EDSunriseSet.kSecondsInHour)
        localNauticalTwilightStart = localTime(from: nauticalTwilightStart)
        localNauticalTwilightEnd   = localTime(from: nauticalTwilightEnd)

        // Astronomical twilight
        let (astroStart, astroEnd, _) = astronomicalTwilight(year: year, month: month, day: day,
                                                             lon: longitude, lat: latitude)
        astronomicalTwilightStart = utcTime(dateComponents: comps, offset: astroStart * EDSunriseSet.kSecondsInHour)
        astronomicalTwilightEnd   = utcTime(dateComponents: comps, offset: astroEnd * EDSunriseSet.kSecondsInHour)
        localAstronomicalTwilightStart = localTime(from: astronomicalTwilightStart)
        localAstronomicalTwilightEnd   = localTime(from: astronomicalTwilightEnd)
    }

    private func calculate() {
        calculateSunriseSunset()
        calculateTwilight()
    }
}
