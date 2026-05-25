import Cocoa
import LuaSkin
import CoreLocation

// MARK: - Module-level state

private let USERDATA_TAG   = "hs.location"
private let GEOCODE_UD_TAG = "hs.location.geocode"
private var refTable: LSRefTable = LUA_NOREF
private var callbackRef: Int32 = LUA_NOREF
private var location: HSLocation?

private var backgroundCallbacks = NSMutableSet()

// MARK: - Helper

private func get_objectFromUserdata<T: AnyObject>(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!
    return Unmanaged<T>.fromOpaque(ptr.load(as: UnsafeMutableRawPointer.self)).takeUnretainedValue()
}

// MARK: - HSLocation class

private class HSLocation: NSObject, CLLocationManagerDelegate {
    var manager: CLLocationManager!

    override init() {
        super.init()
        manager = CLLocationManager()
        manager.purpose = "Cosmic Hammer location extension"
        manager.delegate = self
    }

    deinit {
        if let mgr = manager {
            mgr.delegate = nil
            mgr.stopUpdatingLocation()
            for region in mgr.monitoredRegions {
                mgr.stopMonitoring(for: region)
            }
            manager = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        DispatchQueue.main.async {
            if callbackRef != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: callbackRef)
                skin.pushNSObject("didUpdateLocations" as NSString)
                skin.pushNSObject(locations as NSArray)
                skin.protectedCallAndError("hs.location:didUpdateLocations callback", nargs: 2, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        DispatchQueue.main.async {
            if callbackRef != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: callbackRef)
                skin.pushNSObject("didEnterRegion" as NSString)
                skin.pushNSObject(region)
                skin.protectedCallAndError("hs.location:didEnterRegion callback", nargs: 2, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        DispatchQueue.main.async {
            if callbackRef != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: callbackRef)
                skin.pushNSObject("didExitRegion" as NSString)
                skin.pushNSObject(region)
                skin.protectedCallAndError("hs.location:didExitRegion callback", nargs: 2, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            if callbackRef != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: callbackRef)
                skin.pushNSObject("didFailWithError" as NSString)
                skin.pushNSObject(error.localizedDescription as NSString)
                skin.protectedCallAndError("hs.location:didFailWithError callback", nargs: 2, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                         withError error: Error) {
        DispatchQueue.main.async {
            if callbackRef != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: callbackRef)
                skin.pushNSObject("monitoringDidFailForRegion" as NSString)
                skin.pushNSObject(region)
                skin.pushNSObject(error.localizedDescription as NSString)
                skin.protectedCallAndError("hs.location:monitoringDidFailForRegion callback", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            if callbackRef != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: callbackRef)
                skin.pushNSObject("didChangeAuthorizationStatus" as NSString)

                let statusString: String
                switch status {
                case .notDetermined: statusString = "undefined"
                case .restricted:    statusString = "restricted"
                case .denied:        statusString = "denied"
                case .authorized:    statusString = "authorized"
                @unknown default:
                    statusString = "unrecognized CLAuthorizationStatus: \(status.rawValue), notify developers"
                }
                skin.pushNSObject(statusString as NSString)
                skin.protectedCallAndError("hs.location:didChangeAuthorizationStatus callback", nargs: 2, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        DispatchQueue.main.async {
            if callbackRef != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: callbackRef)
                skin.pushNSObject("didStartMonitoringForRegion" as NSString)
                skin.pushNSObject(region)
                skin.protectedCallAndError("hs.location:didStartMonitoringForRegion", nargs: 2, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
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
private func location_registerCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    callbackRef = skin.luaUnref(refTable, ref: callbackRef)
    if lua_type(L, 1) == LUA_TFUNCTION {
        lua_pushvalue(L, 1)
        callbackRef = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
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
private func location_locationServicesEnabled(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TBREAK)
    lua_pushboolean(L, CLLocationManager.locationServicesEnabled() ? 1 : 0)
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
private func location_authorizationStatus(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let status = CLLocationManager.authorizationStatus()
    let statusString: String
    switch status {
    case .notDetermined: statusString = "undefined"
    case .restricted:    statusString = "restricted"
    case .denied:        statusString = "denied"
    case .authorized:    statusString = "authorized"
    @unknown default:
        statusString = "unrecognized CLAuthorizationStatus: \(status.rawValue), notify developers"
    }
    skin.pushNSObject(statusString as NSString)
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
private func location_distanceBetween(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TTABLE, LS_TBREAK)
    let pointA: CLLocation = skin.luaObject(at:1, toClass: "CLLocation") as! CLLocation
    let pointB: CLLocation = skin.luaObject(at:2, toClass: "CLLocation") as! CLLocation
    lua_pushnumber(L, pointA.distance(from: pointB))
    return 1
}

// internally used function
private func location_startWatching(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TBREAK)
    lua_pushboolean(L, checkLocationManager() ? 1 : 0)
    if lua_toboolean(L, -1) != 0 { location?.manager.startUpdatingLocation() }
    return 1
}

// internally used function
private func location_stopWatching(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TBREAK)
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
private func location_getLocation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    if checkLocationManager() {
        skin.pushNSObject(location?.manager.location)
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
private func location_dstOffset(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let tz = TimeZone.current
    var interval: TimeInterval = 0
    if tz.isDaylightSavingTime() {
        interval = tz.daylightSavingTimeOffset()
    }

    lua_pushnumber(skin.l, interval)
    return 1
}

// internally used function
private func location_monitoredRegions(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    if let loc = location {
        skin.pushNSObject(loc.manager.monitoredRegions as NSSet)
    } else {
        lua_newtable(L)
    }
    return 1
}

// internally used function
private func location_addMonitoredRegion(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TBREAK)
    guard let region = skin.luaObject(at:1, toClass: "CLCircularRegion") as? CLCircularRegion else {
        return 0
    }
    if checkLocationManager() {
        location?.manager.startMonitoring(for: region)
        lua_pushboolean(L, 1)
    } else {
        lua_pushnil(L)
    }
    return 1
}

// internally used function
private func location_removeMonitoredRegion(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let identifier = skin.toNSObject(at:1) as! String

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
            lua_pushboolean(L, 1)
        } else {
            lua_pushboolean(L, 0)
        }
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

// internally used function, may document for testing purposes
private func location_fakeLocationChange(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK | LS_TVARARG)
    let message = skin.toNSObject(at:1) as! String

    guard let loc = location else {
        lua_pushboolean(L, 0)
        return 1
    }

    switch message {
    case "didUpdateLocations":
        skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TBREAK)
        let clLoc = skin.luaObject(at:2, toClass: "CLLocation") as! CLLocation
        loc.locationManager(loc.manager, didUpdateLocations: [clLoc])

    case "didEnterRegion":
        skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TBREAK)
        let region = skin.luaObject(at:2, toClass: "CLCircularRegion") as! CLCircularRegion
        loc.locationManager(loc.manager, didEnterRegion: region)

    case "didExitRegion":
        skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TBREAK)
        let region = skin.luaObject(at:2, toClass: "CLCircularRegion") as! CLCircularRegion
        loc.locationManager(loc.manager, didExitRegion: region)

    case "didFailWithError":
        skin.checkArgs(LS_TSTRING, LS_TNUMBER, LS_TBREAK)
        let error = NSError(domain: "fakeError", code: Int(lua_tointegerx(L, 2, nil)), userInfo: nil)
        loc.locationManager(loc.manager, didFailWithError: error)

    case "monitoringDidFailForRegion":
        skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TNUMBER, LS_TBREAK)
        let region = skin.luaObject(at:2, toClass: "CLCircularRegion") as! CLCircularRegion
        let error = NSError(domain: "fakeError", code: Int(lua_tointegerx(L, 3, nil)), userInfo: nil)
        loc.locationManager(loc.manager, monitoringDidFailFor: region, withError: error)

    case "didChangeAuthorizationStatus":
        skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TBREAK)
        let status = skin.toNSObject(at:2) as! String
        let statusCode: CLAuthorizationStatus
        switch status {
        case "undefined":  statusCode = .notDetermined
        case "restricted": statusCode = .restricted
        case "denied":     statusCode = .denied
        case "authorized": statusCode = .authorized
        default:
            return luaL_argerror(L, 2, "\(status) is not a recognized status")
        }
        loc.locationManager(loc.manager, didChangeAuthorization: statusCode)

    case "didStartMonitoringForRegion":
        skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TBREAK)
        let region = skin.luaObject(at:2, toClass: "CLCircularRegion") as! CLCircularRegion
        loc.locationManager(loc.manager, didStartMonitoringFor: region)

    default:
        return luaL_argerror(L, 1, "\(message) is not a recognized message")
    }

    lua_pushboolean(L, 1)
    return 1
}

// EDSunriseSet is defined in EDSunriseSet_new.swift (HSSwiftExtensions target)

// MARK: - Sunrise/Sunset Functions

private func sunturns(_ L: UnsafeMutablePointer<lua_State>!) -> EDSunriseSet {
    let skin = LuaSkin.skin(with: L)

    var date: Date
    var tz: TimeZone
    var latitude: Double = 0
    var longitude: Double = 0
    var offset: Double = 0

    // This is unconventional, but is the easiest way to cope with the older Lua implementation's API
    var idx: Int32 = 2
    if lua_type(L, 1) == LUA_TTABLE {
        skin.checkArgs(LS_TTABLE, LS_TNUMBER, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
        let loc = skin.toNSObject(at:1) as! CLLocation
        latitude = loc.coordinate.latitude
        longitude = loc.coordinate.longitude
    } else {
        skin.checkArgs(LS_TNUMBER, LS_TNUMBER, LS_TNUMBER, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
        latitude = lua_tonumber(L, 1)
        longitude = lua_tonumber(L, 2)
        idx += 1
    }

    // We now need to be careful because we're using `idx` for relative arguments
    offset = lua_tonumber(L, idx)
    tz = TimeZone(secondsFromGMT: Int(offset * 60 * 60))!
    idx += 1

    if lua_type(L, idx) == LUA_TTABLE {
        let dateTable = skin.toNSObject(at:idx) as! NSDictionary
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
private func location_sunrise(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let suntimes = sunturns(L)
    lua_pushinteger(L, lua_Integer(suntimes.sunrise.timeIntervalSince1970))
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
private func location_sunset(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let suntimes = sunturns(L)
    lua_pushinteger(L, lua_Integer(suntimes.sunset.timeIntervalSince1970))
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
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TFUNCTION, LS_TBREAK)
    let theLocation = skin.luaObject(at:1, toClass: "CLLocation") as! CLLocation
    lua_pushvalue(L, 2)
    let fnRef = skin.luaRef(refTable)
    backgroundCallbacks.add(NSNumber(value: fnRef))

    let geoItem = CLGeocoder()
    geoItem.reverseGeocodeLocation(theLocation) { placemark, error in
        if backgroundCallbacks.contains(NSNumber(value: fnRef)) {
            let _skin = LuaSkin.skin(with: nil)
            let _L = _skin.l!
            _skin.pushLuaRef(refTable, ref: fnRef)
            lua_pushboolean(_L, error == nil ? 1 : 0)
            if let error = error {
                _skin.pushNSObject(error.localizedDescription as NSString)
            } else {
                _skin.pushNSObject(placemark as NSArray?)
            }
            _skin.protectedCallAndError("hs.location.geocode:lookupLocation callback", nargs: 2, nresults: 0)
            _skin.luaUnref(refTable, ref: fnRef)
            backgroundCallbacks.remove(NSNumber(value: fnRef))
        }
    }
    skin.pushNSObject(geoItem)
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
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TFUNCTION, LS_TBREAK)
    let searchString = skin.toNSObject(at:1) as! String
    lua_pushvalue(L, 2)
    let fnRef = skin.luaRef(refTable)
    backgroundCallbacks.add(NSNumber(value: fnRef))

    let geoItem = CLGeocoder()
    geoItem.geocodeAddressString(searchString) { placemark, error in
        if backgroundCallbacks.contains(NSNumber(value: fnRef)) {
            let _skin = LuaSkin.skin(with: nil)
            let _L = _skin.l!
            _skin.pushLuaRef(refTable, ref: fnRef)
            lua_pushboolean(_L, error == nil ? 1 : 0)
            if let error = error {
                _skin.pushNSObject(error.localizedDescription as NSString)
            } else {
                _skin.pushNSObject(placemark as NSArray?)
            }
            _skin.protectedCallAndError("hs.location.geocode:lookupAddress callback", nargs: 2, nresults: 0)
            _skin.luaUnref(refTable, ref: fnRef)
            backgroundCallbacks.remove(NSNumber(value: fnRef))
        }
    }
    skin.pushNSObject(geoItem)
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
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK | LS_TVARARG)
    let searchString = skin.toNSObject(at:1) as! String
    var theRegion: CLCircularRegion? = nil

    if lua_gettop(L) == 2 {
        skin.checkArgs(LS_TSTRING, LS_TFUNCTION, LS_TBREAK)
        lua_pushvalue(L, 2)
    } else {
        skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TFUNCTION, LS_TBREAK)
        theRegion = skin.luaObject(at:2, toClass: "CLCircularRegion") as? CLCircularRegion
        lua_pushvalue(L, 3)
    }
    let fnRef = skin.luaRef(refTable)
    backgroundCallbacks.add(NSNumber(value: fnRef))

    let geoItem = CLGeocoder()
    geoItem.geocodeAddressString(searchString, in: theRegion) { placemark, error in
        if backgroundCallbacks.contains(NSNumber(value: fnRef)) {
            let _skin = LuaSkin.skin(with: nil)
            let _L = _skin.l!
            _skin.pushLuaRef(refTable, ref: fnRef)
            lua_pushboolean(_L, error == nil ? 1 : 0)
            if let error = error {
                _skin.pushNSObject(error.localizedDescription as NSString)
            } else {
                _skin.pushNSObject(placemark as NSArray?)
            }
            _skin.protectedCallAndError("hs.location.geocode:lookupAddressNear callback", nargs: 2, nresults: 0)
            _skin.luaUnref(refTable, ref: fnRef)
            backgroundCallbacks.remove(NSNumber(value: fnRef))
        }
    }
    skin.pushNSObject(geoItem)
    return 1
}

// MARK: - Geocoder Methods

/// hs.location.geocoder:geocoding() -> boolean
/// Method
/// Returns a boolean indicating whether or not the geocoding process is still active.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean indicating if the geocoding process is still active.  If false, then the callback function either has already been called or will be as soon as the main thread of Cosmic Hammer becomes idle again.
private func clgeocoder_isGeocoding(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, GEOCODE_UD_TAG, LS_TBREAK)
    let geoItem: CLGeocoder = skin.toNSObject(at:1) as! CLGeocoder
    lua_pushboolean(L, geoItem.isGeocoding ? 1 : 0)
    return 1
}

/// hs.location.geocoder:cancel() -> nil
/// Method
/// Cancels the pending or in progress geocoding request.
///
/// Parameters:
///  * None
///
/// Returns:
///  * nil to facilitate garbage collection by assigning this result to the geocodeObject
///
/// Notes:
///  * This method has no effect if the geocoding process has already completed.
private func clgeocoder_cancelGeocoding(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, GEOCODE_UD_TAG, LS_TBREAK)
    let geoItem: CLGeocoder = skin.toNSObject(at:1) as! CLGeocoder
    geoItem.cancelGeocode()
    lua_pushnil(L)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushCLGeocoder(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let value = obj as! CLGeocoder
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    valuePtr.storeBytes(of: Unmanaged.passRetained(value).toOpaque(), as: UnsafeMutableRawPointer.self)
    luaL_getmetatable(L, GEOCODE_UD_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toCLGeocoderFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, GEOCODE_UD_TAG) != nil {
        let value: CLGeocoder = get_objectFromUserdata(L, idx, GEOCODE_UD_TAG)
        return value
    } else {
        skin.logError("expected \(GEOCODE_UD_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

private func pushCLLocation(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let loc = obj as! CLLocation
    lua_newtable(L)
    lua_pushnumber(L, loc.coordinate.latitude);               lua_setfield(L, -2, "latitude")
    lua_pushnumber(L, loc.coordinate.longitude);              lua_setfield(L, -2, "longitude")
    lua_pushnumber(L, loc.altitude);                          lua_setfield(L, -2, "altitude")
    lua_pushnumber(L, loc.horizontalAccuracy);                lua_setfield(L, -2, "horizontalAccuracy")
    lua_pushnumber(L, loc.verticalAccuracy);                  lua_setfield(L, -2, "verticalAccuracy")
    lua_pushnumber(L, loc.course);                            lua_setfield(L, -2, "course")
    lua_pushnumber(L, loc.speed);                             lua_setfield(L, -2, "speed")
    lua_pushnumber(L, loc.timestamp.timeIntervalSince1970);   lua_setfield(L, -2, "timestamp")
    lua_pushstring(L, "CLLocation");                          lua_setfield(L, -2, "__luaSkinType")
    return 1
}

private func pushCLCircularRegion(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theRegion = obj as! CLCircularRegion
    lua_newtable(L)
    skin.pushNSObject(theRegion.identifier as NSString); lua_setfield(L, -2, "identifier")
    lua_pushnumber(L, theRegion.center.latitude);        lua_setfield(L, -2, "latitude")
    lua_pushnumber(L, theRegion.center.longitude);       lua_setfield(L, -2, "longitude")
    lua_pushnumber(L, theRegion.radius);                 lua_setfield(L, -2, "radius")
    lua_pushboolean(L, theRegion.notifyOnEntry ? 1 : 0); lua_setfield(L, -2, "notifyOnEntry")
    lua_pushboolean(L, theRegion.notifyOnExit ? 1 : 0);  lua_setfield(L, -2, "notifyOnExit")
    return 1
}

private func CLLocationFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)

    guard lua_type(L, idx) == LUA_TTABLE else {
        skin.logError("\(USERDATA_TAG):CLLocationFromLua expected table, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }

    var loc = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
    var altitude: CLLocationDistance = 0.0
    var hAccuracy: CLLocationAccuracy = 0.0
    var vAccuracy: CLLocationAccuracy = -1.0
    var course: CLLocationDirection = -1.0
    var speed: CLLocationSpeed = -1.0
    var timestamp = Date()

    if lua_getfield(L, idx, "latitude") == LUA_TNUMBER           { loc.latitude = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "longitude") == LUA_TNUMBER          { loc.longitude = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "altitude") == LUA_TNUMBER           { altitude = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "horizontalAccuracy") == LUA_TNUMBER { hAccuracy = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "verticalAccuracy") == LUA_TNUMBER   { vAccuracy = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "course") == LUA_TNUMBER             { course = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "speed") == LUA_TNUMBER              { speed = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "timestamp") == LUA_TNUMBER {
        timestamp = Date(timeIntervalSince1970: lua_tonumber(L, -1))
    }
    lua_pop(L, 8)

    return CLLocation(coordinate: loc,
                      altitude: altitude,
                      horizontalAccuracy: hAccuracy,
                      verticalAccuracy: vAccuracy,
                      course: course,
                      speed: speed,
                      timestamp: timestamp)
}

private func CLCircularRegionFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)

    guard lua_type(L, idx) == LUA_TTABLE else {
        skin.logError("\(USERDATA_TAG):CLCircularRegionFromLua expected table, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }

    var theCenter = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
    var theRadius: CLLocationDistance = 0.0
    var theIdentifier = UUID().uuidString

    if lua_getfield(L, idx, "longitude") == LUA_TNUMBER  { theCenter.longitude = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "latitude") == LUA_TNUMBER   { theCenter.latitude = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "radius") == LUA_TNUMBER     { theRadius = lua_tonumber(L, -1) }
    if lua_getfield(L, idx, "identifier") == LUA_TSTRING  { theIdentifier = skin.toNSObject(at:-1) as! String }
    lua_pop(L, 4)

    let theRegion = CLCircularRegion(center: theCenter, radius: theRadius, identifier: theIdentifier)

    if lua_getfield(L, idx, "notifyOnEntry") == LUA_TBOOLEAN { theRegion.notifyOnEntry = lua_toboolean(L, -1) != 0 }
    if lua_getfield(L, idx, "notifyOnExit") == LUA_TBOOLEAN  { theRegion.notifyOnExit = lua_toboolean(L, -1) != 0 }
    lua_pop(L, 2)

    return theRegion
}

private func pushCLPlacemark(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let thePlace = obj as! CLPlacemark
    lua_newtable(L)
    skin.pushNSObject(thePlace.location);              lua_setfield(L, -2, "location")
    skin.pushNSObject(thePlace.name as NSString?);     lua_setfield(L, -2, "name")

    skin.pushNSObject(thePlace.addressDictionary as NSDictionary?); lua_setfield(L, -2, "addressDictionary")

    skin.pushNSObject(thePlace.isoCountryCode as NSString?);        lua_setfield(L, -2, "countryCode")
    skin.pushNSObject(thePlace.country as NSString?);               lua_setfield(L, -2, "country")
    skin.pushNSObject(thePlace.postalCode as NSString?);            lua_setfield(L, -2, "postalCode")
    skin.pushNSObject(thePlace.administrativeArea as NSString?);    lua_setfield(L, -2, "administrativeArea")
    skin.pushNSObject(thePlace.subAdministrativeArea as NSString?); lua_setfield(L, -2, "subAdministrativeArea")
    skin.pushNSObject(thePlace.locality as NSString?);              lua_setfield(L, -2, "locality")
    skin.pushNSObject(thePlace.subLocality as NSString?);           lua_setfield(L, -2, "subLocality")
    skin.pushNSObject(thePlace.thoroughfare as NSString?);          lua_setfield(L, -2, "thoroughfare")
    skin.pushNSObject(thePlace.subThoroughfare as NSString?);       lua_setfield(L, -2, "subThoroughfare")
    skin.pushNSObject(thePlace.region);                             lua_setfield(L, -2, "region")

    if let tz = thePlace.timeZone {
        skin.pushNSObject(tz.abbreviation() as NSString?)
        lua_setfield(L, -2, "timeZone")
    }

    skin.pushNSObject(thePlace.inlandWater as NSString?);       lua_setfield(L, -2, "inlandWater")
    skin.pushNSObject(thePlace.ocean as NSString?);             lua_setfield(L, -2, "ocean")
    skin.pushNSObject(thePlace.areasOfInterest as NSArray?);    lua_setfield(L, -2, "areasOfInterest")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func clgeocoder_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let obj = skin.luaObject(at:1, toClass: "CLGeocoder") as! CLGeocoder
    let title = obj.isGeocoding ? "geocoding" : "idle"
    let ptr = lua_topointer(L, 1)
    skin.pushNSObject("\(GEOCODE_UD_TAG): \(title) (\(String(describing: ptr)))" as NSString)
    return 1
}

private func clgeocoder_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, GEOCODE_UD_TAG) != nil && luaL_testudata(L, 2, GEOCODE_UD_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at:1, toClass: "CLGeocoder") as! CLGeocoder
        let obj2 = skin.luaObject(at:2, toClass: "CLGeocoder") as! CLGeocoder
        lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func clgeocoder_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, GEOCODE_UD_TAG)!
    let obj = Unmanaged<CLGeocoder>.fromOpaque(ptr.load(as: UnsafeMutableRawPointer.self)).takeRetainedValue()
    obj.cancelGeocode()
    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    backgroundCallbacks.enumerateObjects { ref, _ in
        if let num = ref as? NSNumber {
            skin.luaUnref(refTable, ref: num.int32Value)
        }
    }
    backgroundCallbacks.removeAllObjects()

    // make sure we don't get a last-minute callback during teardown
    callbackRef = skin.luaUnref(refTable, ref: callbackRef)
    if let loc = location {
        if let mgr = loc.manager {
            mgr.delegate = nil
            mgr.stopUpdatingLocation()
            for region in mgr.monitoredRegions {
                mgr.stopMonitoring(for: region)
            }
            loc.manager = nil
        }
        location = nil
    }
    return 0
}

// MARK: - luaL_Reg tables

private var clgeocode_moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("lookupAddress"),     func: clgeocoder_lookupAddress),
    luaL_Reg(name: strdup("lookupLocation"),    func: clgeocoder_lookupLocation),
    luaL_Reg(name: strdup("lookupAddressNear"), func: clgeocoder_lookupAddressNear),
    luaL_Reg(name: nil,                         func: nil),
]

private var clgeocoder_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("geocoding"),  func: clgeocoder_isGeocoding),
    luaL_Reg(name: strdup("cancel"),     func: clgeocoder_cancelGeocoding),
    luaL_Reg(name: strdup("__tostring"), func: clgeocoder_tostring),
    luaL_Reg(name: strdup("__eq"),       func: clgeocoder_eq),
    luaL_Reg(name: strdup("__gc"),       func: clgeocoder_gc),
    luaL_Reg(name: nil,                  func: nil),
]

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("servicesEnabled"),        func: location_locationServicesEnabled),
    luaL_Reg(name: strdup("authorizationStatus"),    func: location_authorizationStatus),
    luaL_Reg(name: strdup("distance"),               func: location_distanceBetween),
    luaL_Reg(name: strdup("start"),                  func: location_startWatching),
    luaL_Reg(name: strdup("stop"),                   func: location_stopWatching),
    luaL_Reg(name: strdup("get"),                    func: location_getLocation),
    luaL_Reg(name: strdup("dstOffset"),              func: location_dstOffset),
    luaL_Reg(name: strdup("sunrise"),                func: location_sunrise),
    luaL_Reg(name: strdup("sunset"),                 func: location_sunset),

    luaL_Reg(name: strdup("_registerCallback"),      func: location_registerCallback),
    luaL_Reg(name: strdup("_monitoredRegions"),      func: location_monitoredRegions),
    luaL_Reg(name: strdup("_addMonitoredRegion"),    func: location_addMonitoredRegion),
    luaL_Reg(name: strdup("_removeMonitoredRegion"), func: location_removeMonitoredRegion),
    luaL_Reg(name: strdup("_fakeLocationChange"),    func: location_fakeLocationChange),

    luaL_Reg(name: nil,                              func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

// MARK: - Compat helper

// luaL_newlib is a macro in C; we replicate it in Swift
private func luaL_newlib_compat(_ L: UnsafeMutablePointer<lua_State>!, _ lib: inout [luaL_Reg]) {
    luaL_checkversion(L)
    lua_createtable(L, 0, Int32(lib.count - 1))
    luaL_setfuncs(L, &lib, 0)
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_liblocation")
func luaopen_hs_liblocation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    // in case a reload skipped meta_gc for some reason
    if location != nil { location = nil }

    refTable = skin.registerLibrary(USERDATA_TAG, functions: &moduleLib, metaFunctions: &module_metaLib)

    skin.registerPushNSHelper(pushCLLocation,             forClass: "CLLocation")
    skin.registerLuaObjectHelper(CLLocationFromLua,       forClass: "CLLocation",
                                 withTableMapping: "CLLocation")

    skin.registerPushNSHelper(pushCLCircularRegion,       forClass: "CLCircularRegion")
    skin.registerLuaObjectHelper(CLCircularRegionFromLua, forClass: "CLCircularRegion",
                                 withTableMapping: "CLCircularRegion")

    // hs.location.geocoder submodule
    luaL_newlib_compat(L, &clgeocode_moduleLib); lua_setfield(L, -2, "geocoder")
    skin.registerObject(GEOCODE_UD_TAG, objectFunctions: &clgeocoder_metaLib)

    skin.registerPushNSHelper(pushCLGeocoder,             forClass: "CLGeocoder")
    skin.registerLuaObjectHelper(toCLGeocoderFromLua,     forClass: "CLGeocoder",
                                 withUserdataMapping: GEOCODE_UD_TAG)

    skin.registerPushNSHelper(pushCLPlacemark,            forClass: "CLPlacemark")

    backgroundCallbacks = NSMutableSet()
    return 1
}
