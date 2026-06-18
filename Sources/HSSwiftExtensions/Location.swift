import Cocoa
import CLua
import Lua
import HSDSTCore
import os.log
import CoreLocation

// MARK: - Module-level state

private let USERDATA_TAG   = "hs.location"
private let GEOCODE_UD_TAG = "hs.location.geocode"
private var callbackValue: LuaValue?
private var location: HSLocation?

private var backgroundCallbacks = [Int32: LuaValue]()

// MARK: - HSLocation class

private class HSLocation: NSObject, CLLocationManagerDelegate {
    var manager: CLLocationManager!
    var generation: UInt64 = 0

    override init() {
        super.init()
        manager = CLLocationManager()
        manager.purpose = "Cosmic Hammer location extension"
        manager.delegate = self
        generation = lua_currentStateGeneration()
    }

    /// Idempotent teardown: stop the location manager, nil delegate,
    /// stop monitoring all regions.  Does NOT touch callbackValue -- that
    /// is handled at module level.
    func teardownManager() {
        if let mgr = manager {
            precondition(mgr.delegate === self || mgr.delegate == nil, "teardownManager called but delegate is not self")
            mgr.delegate = nil
            mgr.stopUpdatingLocation()
            for region in mgr.monitoredRegions {
                mgr.stopMonitoring(for: region)
            }
            manager = nil
        }
        assert(manager == nil, "manager must be nil after teardown")
    }

    private func invokeCallback(_ setup: @escaping (LuaState) -> Void) {
        assert(generation != 0, "invokeCallback called before generation was set")
        DispatchQueue.main.async {
            guard let cb = callbackValue else { return }
            guard lua_isStateGenerationValid(self.generation) else { return }
            let L = lua_getCurrentState()!
            let topBefore = lua_gettop(L)
            cb.push(onto: L)
            setup(L)
            assert(lua_gettop(L) == topBefore, "invokeCallback must restore stack to its original level")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        invokeCallback { L in
            lua_pushany(L, "didUpdateLocations" as NSString)
            pushCLLocationArray(L, locations)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        invokeCallback { L in
            lua_pushany(L, "didEnterRegion" as NSString)
            pushCLRegion(L, region)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        invokeCallback { L in
            lua_pushany(L, "didExitRegion" as NSString)
            pushCLRegion(L, region)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        invokeCallback { L in
            lua_pushany(L, "didFailWithError" as NSString)
            lua_pushany(L, error.localizedDescription as NSString)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                         withError error: Error) {
        invokeCallback { L in
            lua_pushany(L, "monitoringDidFailForRegion" as NSString)
            pushCLRegion(L, region)
            lua_pushany(L, error.localizedDescription as NSString)
            if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        invokeCallback { L in
            lua_pushany(L, "didChangeAuthorizationStatus" as NSString)

            let statusString: String
            switch status {
            case .notDetermined: statusString = "undefined"
            case .restricted:    statusString = "restricted"
            case .denied:        statusString = "denied"
            case .authorized:    statusString = "authorized"
            @unknown default:
                statusString = "unrecognized CLAuthorizationStatus: \(status.rawValue), notify developers"
            }
            lua_pushany(L, statusString as NSString)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        invokeCallback { L in
            lua_pushany(L, "didStartMonitoringForRegion" as NSString)
            pushCLRegion(L, region)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

private func checkLocationManager() -> Bool {
    if location == nil {
        location = HSLocation()
    }
    return location != nil ? CLLocationManager.locationServicesEnabled() : false
}

// MARK: - Module Functions

// internally used function
private func location_registerCallback(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    let topBefore = lua_gettop(L)
    if lua_type(L, 1) == LUA_TFUNCTION {
        callbackValue = L.ref(index: 1)
    } else {
        callbackValue = nil
    }
    lua_pushvalue(L, 1)
    assert(lua_gettop(L) == topBefore + 1, "location_registerCallback must push exactly 1 value")
    return 1
}

/// hs.location.servicesEnabled() -> bool
/// Function
/// Gets the state of OS X Location Services
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if Location Services are enabled, otherwise false
private func location_locationServicesEnabled(_ L: LuaState) throws -> CInt {
    // no args to validate
    L.push(CLLocationManager.locationServicesEnabled())
    return 1
}

/// hs.location.authorizationStatus() -> string
/// Function
/// Returns a string describing the authorization status of Cosmic Hammer's use of Location Services.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string matching one of the following:
///    * "undefined"  - The user has not yet made a choice regarding whether Cosmic Hammer can use location services.
///    * "restricted" - Cosmic Hammer is not authorized to use location services. The user cannot change this status, possibly due to active restrictions such as parental controls being in place.
///    * "denied"     - The user explicitly denied the use of location services for Cosmic Hammer or location services are currently disabled in System Preferences.
///    * "authorized" - Cosmic Hammer is authorized to use location services.
///
/// Notes:
///  * The first time you use a function which requires Location Services, you will be prompted to grant Cosmic Hammer access. If you wish to change this permission after the initial prompt, you may do so from the Location Services section of the Security & Privacy section in the System Preferences application.
private func location_authorizationStatus(_ L: LuaState) throws -> CInt {

    let status = environmentGet(L).location.authorizationStatus()
    let statusString: String
    // Protocol returns Int matching CLAuthorizationStatus raw values:
    // 0 = notDetermined, 1 = restricted, 2 = denied, 3 = authorized
    switch status {
    case 0: statusString = "undefined"
    case 1: statusString = "restricted"
    case 2: statusString = "denied"
    case 3: statusString = "authorized"
    default:
        statusString = "unrecognized authorization status: \(status), notify developers"
    }
    lua_pushany(L, statusString as NSString)
    return 1
}

/// hs.location.distance(from, to) -> meters
/// Function
/// Measures the distance between two points of latitude and longitude
///
/// Parameters:
///  * `from` - A locationTable as described in the module header
///  * `to`   - A locationTable as described in the module header
///
/// Returns:
///  * A number containing the distance between `from` and `to` in meters. The measurement is made by tracing a line that follows an idealised curvature of the earth
///
/// Notes:
///  * This function does not require Location Services to be enabled for Cosmic Hammer.
private func location_distanceBetween(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    guard let pointA = toCLLocation(L, at: 1) else {
        throw LuaCallError("bad argument #1 (expected locationTable)")
    }
    guard let pointB = toCLLocation(L, at: 2) else {
        throw LuaCallError("bad argument #2 (expected locationTable)")
    }
    let distance = pointA.distance(from: pointB)
    assert(distance >= 0, "CLLocation.distance must be non-negative")
    L.push(distance)
    return 1
}

// internally used function
private func location_startWatching(_ L: LuaState) throws -> CInt {
    // no args to validate
    let env = environmentGet(L)
    env.location.startUpdating { _, _ in }
    let ok = checkLocationManager()
    if ok { location?.manager.startUpdatingLocation() }
    L.push(ok)
    return 1
}

// internally used function
private func location_stopWatching(_ L: LuaState) throws -> CInt {
    // no args to validate
    environmentGet(L).location.stopUpdating()
    location?.manager.stopUpdatingLocation()
    return 0
}

/// hs.location.get() -> locationTable or nil
/// Function
/// Returns a table representing the current location
///
/// Parameters:
///  * None
///
/// Returns:
///  * If successful, a locationTable as described in the module header, otherwise nil.
///
/// Notes:
///  * This function activates Location Services for Cosmic Hammer, so the first time you call this, you may be prompted to authorise Cosmic Hammer to use Location Services.
///  * If access to Location Services is enabled for Cosmic Hammer, this function will return the most recent cached data for the computer's location.
///    * Internally, the Location Services cache is updated whenever additional WiFi networks are detected or lost (not necessarily joined). When update tracking is enabled with the [hs.location.start](#start) function, calculations based upon the RSSI of all currently seen networks are preformed more often to provide a more precise fix, but it's still based on the WiFi networks near you.
private func location_getLocation(_ L: LuaState) throws -> CInt {
    if let coord = environmentGet(L).location.currentLocation() {
        lua_newtable(L)
        L.push(coord.latitude);               lua_setfield(L, -2, "latitude")
        L.push(coord.longitude);              lua_setfield(L, -2, "longitude")
        L.push(coord.altitude);               lua_setfield(L, -2, "altitude")
        L.push(coord.horizontalAccuracy);     lua_setfield(L, -2, "horizontalAccuracy")
        L.push(coord.verticalAccuracy);       lua_setfield(L, -2, "verticalAccuracy")
        L.push(coord.timestamp.timeIntervalSince1970); lua_setfield(L, -2, "timestamp")
        L.push("CLLocation");                 lua_setfield(L, -2, "__luaSkinType")
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.location.dstOffset() -> number
/// Function
/// Returns a number giving the current daylight savings time offset
///
/// Parameters:
///  * None
///
/// Returns:
///  * The number of minutes of daylight savings offset, zero if there is no offset
///
/// Notes:
///  * This value is derived from the currently configured system timezone, it does not use Location Services
private func location_dstOffset(_ L: LuaState) throws -> CInt {

    let tz = TimeZone.current
    var interval: TimeInterval = 0
    if tz.isDaylightSavingTime() {
        interval = tz.daylightSavingTimeOffset()
    }

    L.push(interval)
    return 1
}

// internally used function
private func location_monitoredRegions(_ L: LuaState) throws -> CInt {
    if let loc = location {
        pushCLRegionArray(L, Array(loc.manager.monitoredRegions))
    } else {
        lua_newtable(L)
    }
    return 1
}

// internally used function
private func location_addMonitoredRegion(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    luaL_checktype(L, 1, LUA_TTABLE)
    guard let region = toCLCircularRegion(L, at: 1) else {
        throw LuaCallError("bad argument #1 (expected regionTable)")
    }
    if checkLocationManager() {
        location?.manager.startMonitoring(for: region)
        L.push(true)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// internally used function
private func location_removeMonitoredRegion(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    luaL_checktype(L, 1, LUA_TSTRING)
    let identifier = lua_tovalue(L, at: 1) as! String

    if let loc = location {
        var targetRegion: CLCircularRegion?
        for region in loc.manager.monitoredRegions {
            if let circular = region as? CLCircularRegion, identifier == circular.identifier {
                targetRegion = circular
                break
            }
        }
        if let target = targetRegion {
            loc.manager.stopMonitoring(for: target)
            L.push(true)
        } else {
            L.push(false)
        }
    } else {
        L.push(false)
    }
    return 1
}

// internally used function, may document for testing purposes
private func location_fakeLocationChange(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    let message = lua_tovalue(L, at: 1) as! String

    guard let loc = location else {
        L.push(false)
        return 1
    }

    switch message {
    case "didUpdateLocations":
        guard let clLoc = toCLLocation(L, at: 2) else {
            throw LuaCallError("bad argument #2 (expected locationTable)")
        }
        loc.locationManager(loc.manager, didUpdateLocations: [clLoc])

    case "didEnterRegion":
        guard let region = toCLCircularRegion(L, at: 2) else {
            throw LuaCallError("bad argument #2 (expected regionTable)")
        }
        loc.locationManager(loc.manager, didEnterRegion: region)

    case "didExitRegion":
        guard let region = toCLCircularRegion(L, at: 2) else {
            throw LuaCallError("bad argument #2 (expected regionTable)")
        }
        loc.locationManager(loc.manager, didExitRegion: region)

    case "didFailWithError":
        let error = NSError(domain: "fakeError", code: Int(lua_tointegerx(L, 2, nil)), userInfo: nil)
        loc.locationManager(loc.manager, didFailWithError: error)

    case "monitoringDidFailForRegion":
        guard let region = toCLCircularRegion(L, at: 2) else {
            throw LuaCallError("bad argument #2 (expected regionTable)")
        }
        let error = NSError(domain: "fakeError", code: Int(lua_tointegerx(L, 3, nil)), userInfo: nil)
        loc.locationManager(loc.manager, monitoringDidFailFor: region, withError: error)

    case "didChangeAuthorizationStatus":
        let status = lua_tovalue(L, at: 2) as! String
        let statusCode: CLAuthorizationStatus
        switch status {
        case "undefined":  statusCode = .notDetermined
        case "restricted": statusCode = .restricted
        case "denied":     statusCode = .denied
        case "authorized": statusCode = .authorized
        default:
            throw LuaCallError("bad argument #2 (\(status) is not a recognized status)")
        }
        loc.locationManager(loc.manager, didChangeAuthorization: statusCode)

    case "didStartMonitoringForRegion":
        guard let region = toCLCircularRegion(L, at: 2) else {
            throw LuaCallError("bad argument #2 (expected regionTable)")
        }
        loc.locationManager(loc.manager, didStartMonitoringFor: region)

    default:
        throw LuaCallError("bad argument #1 (\(message) is not a recognized message)")
    }

    L.push(true)
    return 1
}

// EDSunriseSet is defined in EDSunriseSet_new.swift (HSSwiftExtensions target)

// MARK: - Sunrise/Sunset Functions

private func sunturns(_ L: UnsafeMutablePointer<lua_State>!) -> EDSunriseSet? {
    precondition(L != nil, "Lua state must not be nil")
    precondition(lua_gettop(L) >= 2, "sunturns requires at least 2 arguments")

    var date: Date
    var tz: TimeZone
    var latitude: Double = 0
    var longitude: Double = 0
    var offset: Double = 0

    // This is unconventional, but is the easiest way to cope with the older Lua implementation's API
    var idx: Int32 = 2
    if lua_type(L, 1) == LUA_TTABLE {
        guard let loc = toCLLocation(L, at: 1) else {
            _ = luaL_argerror(L, 1, "expected locationTable")
            return nil
        }
        latitude = loc.coordinate.latitude
        longitude = loc.coordinate.longitude
    } else {
        latitude = lua_tonumber(L, 1)
        longitude = lua_tonumber(L, 2)
        idx += 1
    }

    // We now need to be careful because we're using `idx` for relative arguments
    offset = lua_tonumber(L, idx)
    tz = TimeZone(secondsFromGMT: Int(offset * 60 * 60))!
    idx += 1

    if lua_type(L, idx) == LUA_TTABLE {
        let dateTable = lua_tovalue(L, at: idx) as! NSDictionary
        var dateParts = DateComponents()
        dateParts.year = (dateTable["year"] as? NSNumber)?.intValue ?? 0
        dateParts.month = (dateTable["month"] as? NSNumber)?.intValue ?? 0
        dateParts.day = (dateTable["day"] as? NSNumber)?.intValue ?? 0
        dateParts.hour = (dateTable["hour"] as? NSNumber)?.intValue ?? 0
        dateParts.minute = (dateTable["min"] as? NSNumber)?.intValue ?? 0
        dateParts.second = (dateTable["sec"] as? NSNumber)?.intValue ?? 0
        dateParts.timeZone = tz
        dateParts.calendar = Calendar(identifier: .gregorian)

        date = dateParts.date!
    } else {
        date = Date()
    }

    return EDSunriseSet.sunriseset(withDate: date, timezone: tz, latitude: latitude, longitude: longitude)
}

/// hs.location.sunrise(latitude, longitude, offset[, date]) -> number or string
/// Function
/// Returns the time of official sunrise for the supplied location
///
/// Parameters:
///  * `latitude`  - A number containing a latitude
///  * `longitude` - A number containing a longitude
///  * `offset`    - A number containing the offset from UTC (in hours) for the given latitude/longitude.
///  * `date`      - An optional table containing date information (equivalent to the output of ```os.date("*t")```). Defaults to the current date
///
/// Returns:
///  * A number containing the time of sunrise (represented as seconds since the epoch) for the given date. If no date is given, the current date is used. If the sun doesn't rise on the given day, the string "N/R" is returned.
///
/// Notes:
///  * You can turn the return value into a more useful structure, with ```os.date("*t", returnvalue)```
///  * For compatibility with the locationTable object returned by [hs.location.get](#get), this function can also be invoked as `hs.location.sunrise(locationTable, offset[, date])`.
private func location_sunrise(_ L: LuaState) throws -> CInt {
    guard let suntimes = sunturns(L) else { return 0 }
    L.push(lua_Integer(suntimes.sunrise.timeIntervalSince1970))
    return 1
}

/// hs.location.sunset(latitude, longitude, offset[, date]) -> number or string
/// Function
/// Returns the time of official sunset for the supplied location
///
/// Parameters:
///  * `latitude`  - A number containing a latitude
///  * `longitude` - A number containing a longitude
///  * `offset`    - A number containing the offset from UTC (in hours) for the given latitude/longitude.
///  * `date`      - An optional table containing date information (equivalent to the output of ```os.date("*t")```). Defaults to the current date
///
/// Returns:
///  * A number containing the time of sunset (represented as seconds since the epoch) for the given date. If no date is given, the current date is used. If the sun doesn't set on the given day, the string "N/S" is returned.
///
/// Notes:
///  * You can turn the return value into a more useful structure, with ```os.date("*t", returnvalue)```
///  * For compatibility with the locationTable object returned by [hs.location.get](#get), this function can also be invoked as `hs.location.sunset(locationTable, offset[, date])`.
private func location_sunset(_ L: LuaState) throws -> CInt {
    guard let suntimes = sunturns(L) else { return 0 }
    L.push(lua_Integer(suntimes.sunset.timeIntervalSince1970))
    return 1
}

// MARK: - Geocoder Functions

/// hs.location.geocoder.lookupLocation(locationTable, fn) -> geocoderObject
/// Constructor
/// Look up geocoding information for the specified location.
///
/// Parameters:
///  * `locationTable` - a locationTable as described in the `hs.location` header specifying a location to obtain geocoding information about.
///  * `fn`            - A callback function which should expect 2 arguments and return none:
///    * `state`  - a boolean indicating whether or not geocoding data was provided
///    * `result` - if `state` is true indicating that geocoding was successful, this argument will be a table containing one or more placemarkTables (as described in the module header) containing the geocoding data available for the location.  If `state` is false, this argument will be a string containing an error message describing the problem encountered.
///
/// Returns:
///  * a geocodingObject
///
/// Notes:
///  * This constructor requires internet access and the callback will be invoked with an error message if the internet is not currently accessible.
///  * This constructor does not require Location Services to be enabled for Cosmic Hammer.
private func clgeocoder_lookupLocation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "Lua state must not be nil")
    precondition(lua_gettop(L) >= 2, "lookupLocation requires location and callback arguments")
    guard let theLocation = toCLLocation(L, at: 1) else {
        _ = luaL_argerror(L, 1, "expected locationTable")
        return 0
    }
    luaL_checktype(L, 2, LUA_TFUNCTION)
    let fnRef = L.ref(index: 2)
    let fnKey = nextBackgroundKey()
    backgroundCallbacks[fnKey] = fnRef

    let geoItem = CLGeocoder()
    let generation = lua_currentStateGeneration()
    geoItem.reverseGeocodeLocation(theLocation) { placemark, error in
        guard lua_isStateGenerationValid(generation), let L = lua_getCurrentState() else {
            backgroundCallbacks.removeValue(forKey: fnKey)
            return
        }
        if let cb = backgroundCallbacks[fnKey] {
            cb.push(onto: L)
            L.push(error == nil)
            if let error = error {
                lua_pushany(L, error.localizedDescription as NSString)
            } else {
                pushCLPlacemarkArray(L, placemark)
            }
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
            backgroundCallbacks.removeValue(forKey: fnKey)
        }
    }
    L.push(userdata: geoItem)
    return 1
}

/// hs.location.geocoder.lookupAddress(address, fn) -> geocoderObject
/// Constructor
/// Look up geocoding information for the specified address.
///
/// Parameters:
///  * `address` - a string containing address information as commonly expressed in your locale.
///  * `fn`      - A callback function which should expect 2 arguments and return none:
///    * `state`  - a boolean indicating whether or not geocoding data was provided
///    * `result` - if `state` is true indicating that geocoding was successful, this argument will be a table containing one or more placemarkTables (as described in the module header) containing the geocoding data available for the location.  If `state` is false, this argument will be a string containing an error message describing the problem encountered.
///
/// Returns:
///  * a geocodingObject
///
/// Notes:
///  * This constructor requires internet access and the callback will be invoked with an error message if the internet is not currently accessible.
///  * This constructor does not require Location Services to be enabled for Cosmic Hammer.
private func clgeocoder_lookupAddress(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "Lua state must not be nil")
    precondition(lua_gettop(L) >= 2, "lookupAddress requires address and callback arguments")
    let searchString = lua_tovalue(L, at: 1) as! String
    luaL_checktype(L, 2, LUA_TFUNCTION)
    let fnRef = L.ref(index: 2)
    let fnKey = nextBackgroundKey()
    backgroundCallbacks[fnKey] = fnRef

    let geoItem = CLGeocoder()
    let generation = lua_currentStateGeneration()
    geoItem.geocodeAddressString(searchString) { placemark, error in
        guard lua_isStateGenerationValid(generation), let L = lua_getCurrentState() else {
            backgroundCallbacks.removeValue(forKey: fnKey)
            return
        }
        if let cb = backgroundCallbacks[fnKey] {
            cb.push(onto: L)
            L.push(error == nil)
            if let error = error {
                lua_pushany(L, error.localizedDescription as NSString)
            } else {
                pushCLPlacemarkArray(L, placemark)
            }
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
            backgroundCallbacks.removeValue(forKey: fnKey)
        }
    }
    L.push(userdata: geoItem)
    return 1
}

/// hs.location.geocoder.lookupAddressNear(address, [regionTable], fn) -> geocoderObject
/// Constructor
/// Look up geocoding information for the specified address.
///
/// Parameters:
///  * `address`     - a string containing address information as commonly expressed in your locale.
///  * `regionTable` - an optional regionTable as described in the `hs.location` header used to prioritize the order of the results found.  If this parameter is not provided and Location Services is enabled for Cosmic Hammer, a region containing current location is used.
///  * `fn`          - A callback function which should expect 2 arguments and return none:
///    * `state`  - a boolean indicating whether or not geocoding data was provided
///    * `result` - if `state` is true indicating that geocoding was successful, this argument will be a table containing one or more placemarkTables (as described in the module header) containing the geocoding data available for the location.  If `state` is false, this argument will be a string containing an error message describing the problem encountered.
///
/// Returns:
///  * a geocodingObject
///
/// Notes:
///  * This constructor requires internet access and the callback will be invoked with an error message if the internet is not currently accessible.
///  * This constructor does not require Location Services to be enabled for Cosmic Hammer.
///  * While a partial address can be given, the more information you provide, the more likely the results will be useful.  The `regionTable` only determines sort order if multiple entries are returned, it does not constrain the search.
private func clgeocoder_lookupAddressNear(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "Lua state must not be nil")
    precondition(lua_gettop(L) >= 2, "lookupAddressNear requires at least address and callback arguments")
    let searchString = lua_tovalue(L, at: 1) as! String
    var theRegion: CLCircularRegion? = nil

    let fnIdx: Int32
    if lua_gettop(L) == 2 {
        fnIdx = 2
    } else {
        theRegion = toCLCircularRegion(L, at: 2)
        fnIdx = 3
    }
    luaL_checktype(L, fnIdx, LUA_TFUNCTION)
    let fnRef = L.ref(index: fnIdx)
    let fnKey = nextBackgroundKey()
    backgroundCallbacks[fnKey] = fnRef

    let geoItem = CLGeocoder()
    let generation = lua_currentStateGeneration()
    geoItem.geocodeAddressString(searchString, in: theRegion) { placemark, error in
        guard lua_isStateGenerationValid(generation), let L = lua_getCurrentState() else {
            backgroundCallbacks.removeValue(forKey: fnKey)
            return
        }
        if let cb = backgroundCallbacks[fnKey] {
            cb.push(onto: L)
            L.push(error == nil)
            if let error = error {
                lua_pushany(L, error.localizedDescription as NSString)
            } else {
                pushCLPlacemarkArray(L, placemark)
            }
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
            backgroundCallbacks.removeValue(forKey: fnKey)
        }
    }
    L.push(userdata: geoItem)
    return 1
}

/// Monotonic key generator for backgroundCallbacks dictionary.
private var _nextBackgroundKey: Int32 = 0
private func nextBackgroundKey() -> Int32 {
    _nextBackgroundKey += 1
    return _nextBackgroundKey
}

// MARK: - Lua<->NSObject Conversion Functions

@discardableResult
private func pushCLLocation(_ L: UnsafeMutablePointer<lua_State>!, _ loc: CLLocation?) -> Int32 {
    guard let loc else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    L.push(loc.coordinate.latitude);               lua_setfield(L, -2, "latitude")
    L.push(loc.coordinate.longitude);              lua_setfield(L, -2, "longitude")
    L.push(loc.altitude);                          lua_setfield(L, -2, "altitude")
    L.push(loc.horizontalAccuracy);                lua_setfield(L, -2, "horizontalAccuracy")
    L.push(loc.verticalAccuracy);                  lua_setfield(L, -2, "verticalAccuracy")
    L.push(loc.course);                            lua_setfield(L, -2, "course")
    L.push(loc.speed);                             lua_setfield(L, -2, "speed")
    L.push(loc.timestamp.timeIntervalSince1970);   lua_setfield(L, -2, "timestamp")
    L.push("CLLocation");                          lua_setfield(L, -2, "__luaSkinType")
    return 1
}

@discardableResult
private func pushCLLocationArray(_ L: UnsafeMutablePointer<lua_State>!, _ locations: [CLLocation]) -> Int32 {
    precondition(L != nil, "Lua state must not be nil")
    let topBefore = lua_gettop(L)
    lua_createtable(L, Int32(locations.count), 0)
    for (offset, location) in locations.enumerated() {
        pushCLLocation(L, location)
        lua_rawseti(L, -2, lua_Integer(offset + 1))
    }
    assert(lua_gettop(L) == topBefore + 1, "pushCLLocationArray must push exactly one table")
    return 1
}

@discardableResult
private func pushCLCircularRegion(_ L: UnsafeMutablePointer<lua_State>!, _ theRegion: CLCircularRegion?) -> Int32 {
    guard let theRegion else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    lua_pushany(L, theRegion.identifier as NSString);    lua_setfield(L, -2, "identifier")
    L.push(theRegion.center.latitude);        lua_setfield(L, -2, "latitude")
    L.push(theRegion.center.longitude);       lua_setfield(L, -2, "longitude")
    L.push(theRegion.radius);                 lua_setfield(L, -2, "radius")
    L.push(theRegion.notifyOnEntry);          lua_setfield(L, -2, "notifyOnEntry")
    L.push(theRegion.notifyOnExit);           lua_setfield(L, -2, "notifyOnExit")
    return 1
}

@discardableResult
private func pushCLRegion(_ L: UnsafeMutablePointer<lua_State>!, _ region: CLRegion?) -> Int32 {
    guard let region else {
        lua_pushnil(L)
        return 1
    }

    if let circularRegion = region as? CLCircularRegion {
        return pushCLCircularRegion(L, circularRegion)
    }

    lua_newtable(L)
    lua_pushany(L, region.identifier as NSString);        lua_setfield(L, -2, "identifier")
    L.push(region.notifyOnEntry);     lua_setfield(L, -2, "notifyOnEntry")
    L.push(region.notifyOnExit);      lua_setfield(L, -2, "notifyOnExit")
    return 1
}

@discardableResult
private func pushCLRegionArray(_ L: UnsafeMutablePointer<lua_State>!, _ regions: [CLRegion]) -> Int32 {
    precondition(L != nil, "Lua state must not be nil")
    let topBefore = lua_gettop(L)
    lua_createtable(L, Int32(regions.count), 0)
    for (offset, region) in regions.enumerated() {
        pushCLRegion(L, region)
        lua_rawseti(L, -2, lua_Integer(offset + 1))
    }
    assert(lua_gettop(L) == topBefore + 1, "pushCLRegionArray must push exactly one table")
    return 1
}

private func toCLLocation(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> CLLocation? {
    precondition(L != nil, "Lua state must not be nil")
    precondition(idx != 0, "Lua index must not be zero")
    let absIdx = lua_absindex(L, idx)
    assert(absIdx > 0, "absolute index must be positive")

    guard lua_type(L, absIdx) == LUA_TTABLE else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG):toCLLocation expected table, found \(String(cString: lua_typename(L, lua_type(L, absIdx))))")
        return nil
    }

    var loc = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
    var altitude: CLLocationDistance = 0.0
    var hAccuracy: CLLocationAccuracy = 0.0
    var vAccuracy: CLLocationAccuracy = -1.0
    var course: CLLocationDirection = -1.0
    var speed: CLLocationSpeed = -1.0
    var timestamp = Date()

    let hasLatitude = lua_getfield(L, absIdx, "latitude") == LUA_TNUMBER
    if hasLatitude { loc.latitude = lua_tonumber(L, -1) }
    let hasLongitude = lua_getfield(L, absIdx, "longitude") == LUA_TNUMBER
    if hasLongitude { loc.longitude = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "altitude") == LUA_TNUMBER           { altitude = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "horizontalAccuracy") == LUA_TNUMBER { hAccuracy = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "verticalAccuracy") == LUA_TNUMBER   { vAccuracy = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "course") == LUA_TNUMBER             { course = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "speed") == LUA_TNUMBER              { speed = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "timestamp") == LUA_TNUMBER {
        timestamp = Date(timeIntervalSince1970: lua_tonumber(L, -1))
    }
    lua_pop(L, 8)

    guard hasLatitude, hasLongitude else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG):toCLLocation expected numeric latitude and longitude fields")
        return nil
    }

    return CLLocation(coordinate: loc,
                      altitude: altitude,
                      horizontalAccuracy: hAccuracy,
                      verticalAccuracy: vAccuracy,
                      course: course,
                      speed: speed,
                      timestamp: timestamp)
}

private func toCLCircularRegion(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> CLCircularRegion? {
    precondition(L != nil, "Lua state must not be nil")
    precondition(idx != 0, "Lua index must not be zero")
    let absIdx = lua_absindex(L, idx)
    assert(absIdx > 0, "absolute index must be positive")

    guard lua_type(L, absIdx) == LUA_TTABLE else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG):toCLCircularRegion expected table, found \(String(cString: lua_typename(L, lua_type(L, absIdx))))")
        return nil
    }

    var theCenter = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
    var theRadius: CLLocationDistance = 0.0
    var theIdentifier = UUID().uuidString

    if lua_getfield(L, absIdx, "longitude") == LUA_TNUMBER { theCenter.longitude = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "latitude") == LUA_TNUMBER  { theCenter.latitude = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "radius") == LUA_TNUMBER    { theRadius = lua_tonumber(L, -1) }
    if lua_getfield(L, absIdx, "identifier") == LUA_TSTRING, let identifier = lua_tostringValue(L, at: -1) {
        theIdentifier = identifier
    }
    lua_pop(L, 4)

    let theRegion = CLCircularRegion(center: theCenter, radius: theRadius, identifier: theIdentifier)

    if lua_getfield(L, absIdx, "notifyOnEntry") == LUA_TBOOLEAN { theRegion.notifyOnEntry = lua_toboolean(L, -1) != 0 }
    if lua_getfield(L, absIdx, "notifyOnExit") == LUA_TBOOLEAN  { theRegion.notifyOnExit = lua_toboolean(L, -1) != 0 }
    lua_pop(L, 2)

    return theRegion
}

@discardableResult
private func pushCLPlacemark(_ L: UnsafeMutablePointer<lua_State>!, _ thePlace: CLPlacemark?) -> Int32 {
    guard let thePlace else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    pushCLLocation(L, thePlace.location);           lua_setfield(L, -2, "location")
    lua_pushany(L, thePlace.name as NSString?);     lua_setfield(L, -2, "name")

    lua_pushany(L, thePlace.addressDictionary as NSDictionary?); lua_setfield(L, -2, "addressDictionary")

    lua_pushany(L, thePlace.isoCountryCode as NSString?);        lua_setfield(L, -2, "countryCode")
    lua_pushany(L, thePlace.country as NSString?);               lua_setfield(L, -2, "country")
    lua_pushany(L, thePlace.postalCode as NSString?);            lua_setfield(L, -2, "postalCode")
    lua_pushany(L, thePlace.administrativeArea as NSString?);    lua_setfield(L, -2, "administrativeArea")
    lua_pushany(L, thePlace.subAdministrativeArea as NSString?); lua_setfield(L, -2, "subAdministrativeArea")
    lua_pushany(L, thePlace.locality as NSString?);              lua_setfield(L, -2, "locality")
    lua_pushany(L, thePlace.subLocality as NSString?);           lua_setfield(L, -2, "subLocality")
    lua_pushany(L, thePlace.thoroughfare as NSString?);          lua_setfield(L, -2, "thoroughfare")
    lua_pushany(L, thePlace.subThoroughfare as NSString?);       lua_setfield(L, -2, "subThoroughfare")
    pushCLRegion(L, thePlace.region);                            lua_setfield(L, -2, "region")

    if let tz = thePlace.timeZone {
        lua_pushany(L, tz.abbreviation() as NSString?)
        lua_setfield(L, -2, "timeZone")
    }

    lua_pushany(L, thePlace.inlandWater as NSString?);       lua_setfield(L, -2, "inlandWater")
    lua_pushany(L, thePlace.ocean as NSString?);             lua_setfield(L, -2, "ocean")
    lua_pushany(L, thePlace.areasOfInterest as NSArray?);    lua_setfield(L, -2, "areasOfInterest")
    return 1
}

@discardableResult
private func pushCLPlacemarkArray(_ L: UnsafeMutablePointer<lua_State>!, _ placemarks: [CLPlacemark]?) -> Int32 {
    precondition(L != nil, "Lua state must not be nil")
    guard let placemarks else {
        lua_pushnil(L)
        return 1
    }

    let topBefore = lua_gettop(L)
    lua_createtable(L, Int32(placemarks.count), 0)
    for (offset, placemark) in placemarks.enumerated() {
        pushCLPlacemark(L, placemark)
        lua_rawseti(L, -2, lua_Integer(offset + 1))
    }
    assert(lua_gettop(L) == topBefore + 1, "pushCLPlacemarkArray must push exactly one table")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func meta_gc(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    // Release all background geocoder callback LuaValues
    backgroundCallbacks.removeAll()

    // Release the module-level callback LuaValue
    callbackValue = nil

    // Tear down the location manager
    if let loc = location {
        loc.teardownManager()
        location = nil
    }
    assert(location == nil, "location must be nil after gc")
    assert(callbackValue == nil, "callbackValue must be nil after gc")
    assert(backgroundCallbacks.isEmpty, "backgroundCallbacks must be empty after gc")
    return 0
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_liblocation")
func luaopen_hs_liblocation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // in case a reload skipped meta_gc for some reason
        if location != nil {
            location?.teardownManager()
            location = nil
        }
        callbackValue = nil
        backgroundCallbacks.removeAll()
        _nextBackgroundKey = 0

        // Register idiomatic Metatable<CLGeocoder> with LuaSwift.
        L.register(Metatable<CLGeocoder>(
            fields: [
                "geocoding": .memberfn { $0.isGeocoding },
                "cancel": .closure { L in
                    let geoItem: CLGeocoder = try L.checkArgument(1)
                    geoItem.cancelGeocode()
                    lua_pushnil(L)
                    return 1
                },
            ],
            tostring: .closure { L in
                let geoItem: CLGeocoder = try L.checkArgument(1)
                let title = geoItem.isGeocoding ? "geocoding" : "idle"
                L.push("\(GEOCODE_UD_TAG): \(title) (\(lua_topointer(L, 1)!))")
                return 1
            }
        ))

        // -- Post-registration metatable patching for CLGeocoder --
        L.pushMetatable(for: CLGeocoder.self)

        // Replace __gc: cancel geocode, then deinitialize the Any box
        L.push({ (L: LuaState!) -> CInt in
            if let geoItem: CLGeocoder = L.touserdata(1) {
                geoItem.cancelGeocode()
            }
            let rawptr = lua_touserdata(L, 1)!
            rawptr.assumingMemoryBound(to: Any.self).deinitialize(count: 1)
            return 0
        })
        lua_setfield(L, -2, "__gc")

        // __eq for geocoder objects
        L.push({ (L: LuaState!) -> CInt in
            if let obj1: CLGeocoder = L.touserdata(1),
               let obj2: CLGeocoder = L.touserdata(2) {
                L.push(obj1.isEqual(obj2))
            } else {
                L.push(false)
            }
            return 1
        })
        lua_setfield(L, -2, "__eq")

        // Set __type and __name
        L.push(GEOCODE_UD_TAG)
        lua_setfield(L, -2, "__type")
        L.push(GEOCODE_UD_TAG)
        lua_setfield(L, -2, "__name")

        // Registry alias so core_getObjectMetatable("hs.location.geocode") resolves
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, GEOCODE_UD_TAG)

        // Create module table
        lua_createtable(L, 0, 14)
        L.push(location_locationServicesEnabled);  lua_setfield(L, -2, "servicesEnabled")
        L.push(location_authorizationStatus);      lua_setfield(L, -2, "authorizationStatus")
        L.push(location_distanceBetween);          lua_setfield(L, -2, "distance")
        L.push(location_startWatching);            lua_setfield(L, -2, "start")
        L.push(location_stopWatching);             lua_setfield(L, -2, "stop")
        L.push(location_getLocation);              lua_setfield(L, -2, "get")
        L.push(location_dstOffset);                lua_setfield(L, -2, "dstOffset")
        L.push(location_sunrise);                  lua_setfield(L, -2, "sunrise")
        L.push(location_sunset);                   lua_setfield(L, -2, "sunset")
        L.push(location_registerCallback);         lua_setfield(L, -2, "_registerCallback")
        L.push(location_monitoredRegions);         lua_setfield(L, -2, "_monitoredRegions")
        L.push(location_addMonitoredRegion);       lua_setfield(L, -2, "_addMonitoredRegion")
        L.push(location_removeMonitoredRegion);    lua_setfield(L, -2, "_removeMonitoredRegion")
        L.push(location_fakeLocationChange);       lua_setfield(L, -2, "_fakeLocationChange")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(meta_gc);                           lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        // hs.location.geocoder submodule
        lua_createtable(L, 0, 3)
        L.push(clgeocoder_lookupAddress)
        lua_setfield(L, -2, "lookupAddress")
        L.push(clgeocoder_lookupLocation)
        lua_setfield(L, -2, "lookupLocation")
        L.push(clgeocoder_lookupAddressNear)
        lua_setfield(L, -2, "lookupAddressNear")
        lua_setfield(L, -2, "geocoder")
    }
}
