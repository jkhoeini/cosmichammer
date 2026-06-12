import Cocoa
import CLua
import Lua

// MARK: - Constants

private let USERDATA_TAG = "hs.host.locale"
private var callbackRef: LuaValue?

// MARK: - Support Functions and Classes

extension NSLocale {
    var timeIs24HourFormat: Bool {
        let formatter = DateFormatter()
        formatter.locale = self as Locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let dateString = formatter.string(from: Date())
        let amRange = dateString.range(of: formatter.amSymbol)
        let pmRange = dateString.range(of: formatter.pmSymbol)
        return amRange == nil && pmRange == nil
    }
}

private class HSLocaleChangeObserver: NSObject {
    @objc func localeChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            if let cb = callbackRef {
                let L = lua_getCurrentState()!
                cb.push(onto: L)
                if lua_pcall(L, 0, 0, 0) != LUA_OK {
                    lua_pop(L, 1)
                }
            }
        }
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localeChanged(_:)),
            name: NSLocale.currentLocaleDidChangeNotification,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSLocale.currentLocaleDidChangeNotification,
            object: nil
        )
    }
}

private var observerOfChanges: HSLocaleChangeObserver? = nil

// MARK: - Support Push Functions

// NOTE: These may one day become valid types that we want to create module support for or subclass, so...
//       create support tables for what we care about right now and don't register them as helpers

private func pushNSCalendar(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let calendar = obj as! NSCalendar

    lua_newtable(L)
    // obj-c uses zero based indexing; lua uses 1 based indexing
    lua_pushinteger(L, lua_Integer(calendar.firstWeekday + 1));     lua_setfield(L, -2, "firstWeekday")
    lua_pushinteger(L, lua_Integer(calendar.minimumDaysInFirstWeek)); lua_setfield(L, -2, "minimumDaysInFirstWeek")
    lua_pushany(L, calendar.eraSymbols);                          lua_setfield(L, -2, "eraSymbols")
    lua_pushany(L, calendar.longEraSymbols);                      lua_setfield(L, -2, "longEraSymbols")
    lua_pushany(L, calendar.monthSymbols);                        lua_setfield(L, -2, "monthSymbols")
    lua_pushany(L, calendar.quarterSymbols);                      lua_setfield(L, -2, "quarterSymbols")
    lua_pushany(L, calendar.shortMonthSymbols);                   lua_setfield(L, -2, "shortMonthSymbols")
    lua_pushany(L, calendar.shortQuarterSymbols);                 lua_setfield(L, -2, "shortQuarterSymbols")
    lua_pushany(L, calendar.shortStandaloneMonthSymbols);         lua_setfield(L, -2, "shortStandaloneMonthSymbols")
    lua_pushany(L, calendar.shortStandaloneQuarterSymbols);       lua_setfield(L, -2, "shortStandaloneQuarterSymbols")
    lua_pushany(L, calendar.shortStandaloneWeekdaySymbols);       lua_setfield(L, -2, "shortStandaloneWeekdaySymbols")
    lua_pushany(L, calendar.shortWeekdaySymbols);                 lua_setfield(L, -2, "shortWeekdaySymbols")
    lua_pushany(L, calendar.standaloneMonthSymbols);              lua_setfield(L, -2, "standaloneMonthSymbols")
    lua_pushany(L, calendar.standaloneQuarterSymbols);            lua_setfield(L, -2, "standaloneQuarterSymbols")
    lua_pushany(L, calendar.standaloneWeekdaySymbols);            lua_setfield(L, -2, "standaloneWeekdaySymbols")
    lua_pushany(L, calendar.veryShortMonthSymbols);               lua_setfield(L, -2, "veryShortMonthSymbols")
    lua_pushany(L, calendar.veryShortStandaloneMonthSymbols);     lua_setfield(L, -2, "veryShortStandaloneMonthSymbols")
    lua_pushany(L, calendar.veryShortStandaloneWeekdaySymbols);   lua_setfield(L, -2, "veryShortStandaloneWeekdaySymbols")
    lua_pushany(L, calendar.veryShortWeekdaySymbols);             lua_setfield(L, -2, "veryShortWeekdaySymbols")
    lua_pushany(L, calendar.weekdaySymbols);                      lua_setfield(L, -2, "weekdaySymbols")
    lua_pushstring(L, calendar.amSymbol);                         lua_setfield(L, -2, "AMSymbol")
    lua_pushstring(L, calendar.calendarIdentifier.rawValue);      lua_setfield(L, -2, "calendarIdentifier")
    lua_pushstring(L, calendar.pmSymbol);                         lua_setfield(L, -2, "PMSymbol")
    return 1
}

private func pushNSCharacterSet(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let charSet = obj as! NSCharacterSet

    // tweaked from http://stackoverflow.com/questions/26610931/list-of-characters-in-an-nscharacterset
    var array = [String]()
    for plane: UInt32 in 0...16 {
        if charSet.hasMemberInPlane(UInt8(plane)) {
            var c = plane << 16
            while c < (plane + 1) << 16 {
                if charSet.longCharacterIsMember(c) {
                    var c1 = c.littleEndian
                    if let s = NSString(bytes: &c1, length: 4, encoding: String.Encoding.utf32LittleEndian.rawValue) {
                        array.append(s as String)
                    }
                }
                c += 1
            }
        }
    }
    lua_pushany(L, array)
    return 1
}

private func pushNSLocale(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let locale = obj as! NSLocale

    lua_newtable(L)
    lua_pushany(L, locale.object(forKey: .identifier));                          lua_setfield(L, -2, "identifier")
    lua_pushany(L, locale.object(forKey: .languageCode));                        lua_setfield(L, -2, "languageCode")
    lua_pushany(L, locale.object(forKey: .countryCode));                         lua_setfield(L, -2, "countryCode")
    lua_pushany(L, locale.object(forKey: .scriptCode));                          lua_setfield(L, -2, "scriptCode")
    lua_pushany(L, locale.object(forKey: .variantCode));                         lua_setfield(L, -2, "variantCode")
    _ = pushNSCharacterSet(L, locale.object(forKey: .exemplarCharacterSet) as Any);              lua_setfield(L, -2, "exemplarCharacterSet")
    _ = pushNSCalendar(L, locale.object(forKey: .calendar) as Any);                              lua_setfield(L, -2, "calendar")
    lua_pushany(L, locale.object(forKey: .collationIdentifier));                 lua_setfield(L, -2, "collationIdentifier")

    if let usesMetricSystem = locale.object(forKey: .usesMetricSystem) as? NSNumber {
        lua_pushany(L, usesMetricSystem)
    } else {
        lua_pushboolean(L, 0)
    }
    lua_setfield(L, -2, "usesMetricSystem")

    lua_pushany(L, locale.object(forKey: .measurementSystem));                   lua_setfield(L, -2, "measurementSystem")
    lua_pushany(L, locale.object(forKey: .decimalSeparator));                    lua_setfield(L, -2, "decimalSeparator")
    lua_pushany(L, locale.object(forKey: .groupingSeparator));                   lua_setfield(L, -2, "groupingSeparator")
    lua_pushany(L, locale.object(forKey: .currencySymbol));                      lua_setfield(L, -2, "currencySymbol")
    lua_pushany(L, locale.object(forKey: .currencyCode));                        lua_setfield(L, -2, "currencyCode")
    lua_pushany(L, locale.object(forKey: .collatorIdentifier));                  lua_setfield(L, -2, "collatorIdentifier")
    lua_pushany(L, locale.object(forKey: .quotationBeginDelimiterKey));          lua_setfield(L, -2, "quotationBeginDelimiterKey")
    lua_pushany(L, locale.object(forKey: .quotationEndDelimiterKey));            lua_setfield(L, -2, "quotationEndDelimiterKey")
    lua_pushany(L, locale.object(forKey: .alternateQuotationBeginDelimiterKey)); lua_setfield(L, -2, "alternateQuotationBeginDelimiterKey")
    lua_pushany(L, locale.object(forKey: .alternateQuotationEndDelimiterKey));   lua_setfield(L, -2, "alternateQuotationEndDelimiterKey")

    // See http://stackoverflow.com/a/41263725
    if let tempUnit = locale.object(forKey: NSLocale.Key(rawValue: "kCFLocaleTemperatureUnitKey")) {
        lua_pushany(L, tempUnit)
        lua_setfield(L, -2, "temperatureUnit")
    }

    // see http://stackoverflow.com/a/1972487
    lua_pushboolean(L, locale.timeIs24HourFormat ? 1 : 0); lua_setfield(L, -2, "timeFormatIs24Hour")
    return 1
}

// MARK: - Module Functions

/// hs.host.locale.availableLocales() -> table
/// Function
/// Returns an array table containing the identifiers for the locales available on the system.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array table of strings specifying the locale identifiers recognized by this system.
///
/// Notes:
///  * these values can be used with [hs.host.locale.details](#details) to get details for a specific locale.
private func locale_availableLocaleIdentifiers(_ L: LuaState) throws -> CInt {
    let locales = NSLocale.availableLocaleIdentifiers
    lua_pushany(L, locales)
    return 1
}

/// hs.host.locale.preferredLanguages() -> table
/// Function
/// Returns the user's language preference order as an array of strings.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an array table of strings specifying the user's preferred languages as string identifiers.
private func locale_preferredLanguages(_ L: LuaState) throws -> CInt {
    let languages = NSLocale.preferredLanguages
    lua_pushany(L, languages)
    return 1
}

/// hs.host.locale.current() -> string
/// Function
/// Returns an string specifying the user's currently selected locale identifier.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string specifying the identifier of the user's currently selected locale.
///
/// Notes:
///  * this value can be used with [hs.host.locale.details](#details) to get details for the returned locale.
private func locale_currentIdentifier(_ L: LuaState) throws -> CInt {
    lua_pushstring(L, NSLocale.current.identifier)
    return 1
}

/// hs.host.locale.details([identifier]) -> table
/// Function
/// Returns a table containing information about the current or specified locale.
///
/// Parameters:
///  * `identifier` - an optional string, specifying the locale to display information about.  If you do not specify an identifier, information about the user's currently selected locale is returned.
///
/// Returns:
///  * a table containing one or more of the following key-value pairs:
///    * `alternateQuotationBeginDelimiterKey` - A string containing the alternating begin quotation symbol associated with the locale.
///    * `alternateQuotationEndDelimiterKey`   - A string containing the alternate end quotation symbol associated with the locale.
///    * `calendar`                            - A table containing key-value pairs describing for calendar associated with the locale.
///    * `collationIdentifier`                 - A string containing the collation associated with the locale.
///    * `collatorIdentifier`                  - A string containing the collation identifier for the locale.
///    * `countryCode`                         - A string containing the locale country code.
///    * `currencyCode`                        - A string containing the currency code associated with the locale.
///    * `currencySymbol`                      - A string containing the currency symbol associated with the locale.
///    * `decimalSeparator`                    - A string containing the decimal separator associated with the locale.
///    * `exemplarCharacterSet`                - An array table of strings which make up the exemplar character set for the locale.
///    * `groupingSeparator`                   - A string containing the numeric grouping separator associated with the locale.
///    * `identifier`                          - A string containing the locale identifier.
///    * `languageCode`                        - A string containing the locale language code.
///    * `measurementSystem`                   - A string containing the measurement system associated with the locale.
///    * `quotationBeginDelimiterKey`          - A string containing the begin quotation symbol associated with the locale.
///    * `quotationEndDelimiterKey`            - A string containing the end quotation symbol associated with the locale.
///    * `scriptCode`                          - A string containing the locale script code.
///    * `temperatureUnit`                     - A string containing the preferred measurement system for temperature.
///    * `timeFormatIs24Hour`                  - A boolean specifying whether time is expressed in a 24 hour format (true) or 12 hour format (false).
///    * `usesMetricSystem`                    - A boolean specifying whether or not the locale uses the metric system.
///    * `variantCode`                         - A string containing the locale variant code.
///
/// Notes:
///  * If you specify a locale identifier as an argument, it should be based on one of the strings returned by [hs.host.locale.availableLocales](#availableLocales).
private func locale_localeInformation(_ L: LuaState) throws -> CInt {
    let theLocale: NSLocale
    if lua_gettop(L) == 0 || lua_type(L, 1) == LUA_TNIL {
        theLocale = NSLocale.current as NSLocale
    } else {
        let localeName = String(cString: luaL_checkstring(L, 1))
        theLocale = NSLocale(localeIdentifier: localeName)
    }

    _ = pushNSLocale(L, theLocale)
    return 1
}

/// hs.host.locale.localizedString(localeCode[, baseLocaleCode]) -> string | nil, string | nil
/// Function
/// Returns the localized string for a specific language code.
///
/// Parameters:
///  * `localeCode` - The locale code for the locale you want to return the localized string of.
///  * `baseLocaleCode` - An optional string, specifying the locale to use for the string. If you do not specify a `baseLocaleCode`, the user's currently selected locale is used.
///
/// Returns:
///  * A string containing the localized string or `nil ` if either the `localeCode` or `baseLocaleCode` is invalid.
///  * A string containing the localized string including the dialect or `nil ` if either the `localeCode` or `baseLocaleCode` is invalid.
///
/// Notes:
///  * The `localeCode` and optional `baseLocaleCode` must be one of the strings returned by [hs.host.locale.availableLocales](#availableLocales).
private func locale_localizedString(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    let availableLocales = NSLocale.availableLocaleIdentifiers
    let theLocale: NSLocale

    if lua_gettop(L) == 1 {
        theLocale = NSLocale.current as NSLocale
    } else {
        let baseLocaleCode = String(cString: luaL_checkstring(L, 2))
        guard availableLocales.contains(baseLocaleCode) else {
            lua_pushnil(L)
            return 1
        }
        theLocale = NSLocale(localeIdentifier: baseLocaleCode)
    }

    let localeCode = String(cString: lua_tostring(L, 1)!)
    guard availableLocales.contains(localeCode) else {
        lua_pushnil(L)
        return 1
    }

    let localizedString = (theLocale as Locale).localizedString(forLanguageCode: localeCode)
    let localizedStringWithDialect = theLocale.displayName(forKey: .identifier, value: localeCode)

    if let s = localizedString { lua_pushstring(L, s) } else { lua_pushnil(L) }
    if let s = localizedStringWithDialect { lua_pushstring(L, s) } else { lua_pushnil(L) }
    return 2
}

private func locale_registerCallback(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TFUNCTION)
    callbackRef = L.ref(index: 1)
    return 0
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func meta_gc(_ L: LuaState) throws -> CInt {
    callbackRef = nil
    observerOfChanges?.stop()
    observerOfChanges = nil
    return 0
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libhost_locale")
public func luaopen_hs_libhost_locale(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create module table
        lua_createtable(L, 0, 6)
        L.push(locale_availableLocaleIdentifiers)
        lua_setfield(L, -2, "availableLocales")
        L.push(locale_localeInformation)
        lua_setfield(L, -2, "details")
        L.push(locale_currentIdentifier)
        lua_setfield(L, -2, "current")
        L.push(locale_preferredLanguages)
        lua_setfield(L, -2, "preferredLanguages")
        L.push(locale_localizedString)
        lua_setfield(L, -2, "localizedString")
        L.push(locale_registerCallback)
        lua_setfield(L, -2, "_registerCallback")

        // Set module metatable for __gc
        lua_createtable(L, 0, 1)
        L.push(meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        observerOfChanges = HSLocaleChangeObserver()
        observerOfChanges?.start()
    }
}
