import Cocoa
import LuaSkin

// MARK: - Constants

private let USERDATA_TAG = "hs.host.locale"
private var refTable: LSRefTable = LUA_NOREF
private var callbackRef: Int32 = LUA_NOREF

// MARK: - Support Functions and Classes

extension NSLocale {
    @objc var timeIs24HourFormat: Bool {
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

@objc private class HSLocaleChangeObserver: NSObject {
    @objc func localeChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            if callbackRef != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: callbackRef)
                skin.protectedCallAndError("hs.host.locale callback", nargs: 0, nresults: 0)
                _lua_stackguard_exit(skin.l)
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
    let skin = LuaSkin.skin(with: L)
    let calendar = obj as! NSCalendar

    lua_newtable(L)
    // obj-c uses zero based indexing; lua uses 1 based indexing
    lua_pushinteger(L, lua_Integer(calendar.firstWeekday + 1));     lua_setfield(L, -2, "firstWeekday")
    lua_pushinteger(L, lua_Integer(calendar.minimumDaysInFirstWeek)); lua_setfield(L, -2, "minimumDaysInFirstWeek")
    skin.pushNSObject(calendar.eraSymbols as NSArray);                          lua_setfield(L, -2, "eraSymbols")
    skin.pushNSObject(calendar.longEraSymbols as NSArray);                      lua_setfield(L, -2, "longEraSymbols")
    skin.pushNSObject(calendar.monthSymbols as NSArray);                        lua_setfield(L, -2, "monthSymbols")
    skin.pushNSObject(calendar.quarterSymbols as NSArray);                      lua_setfield(L, -2, "quarterSymbols")
    skin.pushNSObject(calendar.shortMonthSymbols as NSArray);                   lua_setfield(L, -2, "shortMonthSymbols")
    skin.pushNSObject(calendar.shortQuarterSymbols as NSArray);                 lua_setfield(L, -2, "shortQuarterSymbols")
    skin.pushNSObject(calendar.shortStandaloneMonthSymbols as NSArray);         lua_setfield(L, -2, "shortStandaloneMonthSymbols")
    skin.pushNSObject(calendar.shortStandaloneQuarterSymbols as NSArray);       lua_setfield(L, -2, "shortStandaloneQuarterSymbols")
    skin.pushNSObject(calendar.shortStandaloneWeekdaySymbols as NSArray);       lua_setfield(L, -2, "shortStandaloneWeekdaySymbols")
    skin.pushNSObject(calendar.shortWeekdaySymbols as NSArray);                 lua_setfield(L, -2, "shortWeekdaySymbols")
    skin.pushNSObject(calendar.standaloneMonthSymbols as NSArray);              lua_setfield(L, -2, "standaloneMonthSymbols")
    skin.pushNSObject(calendar.standaloneQuarterSymbols as NSArray);            lua_setfield(L, -2, "standaloneQuarterSymbols")
    skin.pushNSObject(calendar.standaloneWeekdaySymbols as NSArray);            lua_setfield(L, -2, "standaloneWeekdaySymbols")
    skin.pushNSObject(calendar.veryShortMonthSymbols as NSArray);               lua_setfield(L, -2, "veryShortMonthSymbols")
    skin.pushNSObject(calendar.veryShortStandaloneMonthSymbols as NSArray);     lua_setfield(L, -2, "veryShortStandaloneMonthSymbols")
    skin.pushNSObject(calendar.veryShortStandaloneWeekdaySymbols as NSArray);   lua_setfield(L, -2, "veryShortStandaloneWeekdaySymbols")
    skin.pushNSObject(calendar.veryShortWeekdaySymbols as NSArray);             lua_setfield(L, -2, "veryShortWeekdaySymbols")
    skin.pushNSObject(calendar.weekdaySymbols as NSArray);                      lua_setfield(L, -2, "weekdaySymbols")
    skin.pushNSObject(calendar.amSymbol as NSString);                           lua_setfield(L, -2, "AMSymbol")
    skin.pushNSObject(calendar.calendarIdentifier.rawValue as NSString);        lua_setfield(L, -2, "calendarIdentifier")
    skin.pushNSObject(calendar.pmSymbol as NSString);                           lua_setfield(L, -2, "PMSymbol")
    return 1
}

private func pushNSCharacterSet(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let charSet = obj as! NSCharacterSet

    // tweaked from http://stackoverflow.com/questions/26610931/list-of-characters-in-an-nscharacterset
    let array = NSMutableArray()
    for plane: UInt32 in 0...16 {
        if charSet.hasMemberInPlane(UInt8(plane)) {
            var c = plane << 16
            while c < (plane + 1) << 16 {
                if charSet.longCharacterIsMember(c) {
                    var c1 = c.littleEndian
                    if let s = NSString(bytes: &c1, length: 4, encoding: String.Encoding.utf32LittleEndian.rawValue) {
                        array.add(s)
                    } else {
                        skin.logDebug("\(USERDATA_TAG):NSCharacterSet skipping 0x\(String(format: "%08x", c1)) : nil string representation")
                    }
                }
                c += 1
            }
        }
    }
    skin.pushNSObject(array)
    return 1
}

private func pushNSLocale(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let locale = obj as! NSLocale

    lua_newtable(L)
    skin.pushNSObject(locale.object(forKey: .identifier) as? NSObject);                          lua_setfield(L, -2, "identifier")
    skin.pushNSObject(locale.object(forKey: .languageCode) as? NSObject);                        lua_setfield(L, -2, "languageCode")
    skin.pushNSObject(locale.object(forKey: .countryCode) as? NSObject);                         lua_setfield(L, -2, "countryCode")
    skin.pushNSObject(locale.object(forKey: .scriptCode) as? NSObject);                          lua_setfield(L, -2, "scriptCode")
    skin.pushNSObject(locale.object(forKey: .variantCode) as? NSObject);                         lua_setfield(L, -2, "variantCode")
    _ = pushNSCharacterSet(L, locale.object(forKey: .exemplarCharacterSet) as Any);              lua_setfield(L, -2, "exemplarCharacterSet")
    _ = pushNSCalendar(L, locale.object(forKey: .calendar) as Any);                              lua_setfield(L, -2, "calendar")
    skin.pushNSObject(locale.object(forKey: .collationIdentifier) as? NSObject);                 lua_setfield(L, -2, "collationIdentifier")

    if let usesMetricSystem = locale.object(forKey: .usesMetricSystem) as? NSNumber {
        skin.pushNSObject(usesMetricSystem)
    } else {
        lua_pushboolean(L, 0)
    }
    lua_setfield(L, -2, "usesMetricSystem")

    skin.pushNSObject(locale.object(forKey: .measurementSystem) as? NSObject);                   lua_setfield(L, -2, "measurementSystem")
    skin.pushNSObject(locale.object(forKey: .decimalSeparator) as? NSObject);                    lua_setfield(L, -2, "decimalSeparator")
    skin.pushNSObject(locale.object(forKey: .groupingSeparator) as? NSObject);                   lua_setfield(L, -2, "groupingSeparator")
    skin.pushNSObject(locale.object(forKey: .currencySymbol) as? NSObject);                      lua_setfield(L, -2, "currencySymbol")
    skin.pushNSObject(locale.object(forKey: .currencyCode) as? NSObject);                        lua_setfield(L, -2, "currencyCode")
    skin.pushNSObject(locale.object(forKey: .collatorIdentifier) as? NSObject);                  lua_setfield(L, -2, "collatorIdentifier")
    skin.pushNSObject(locale.object(forKey: .quotationBeginDelimiterKey) as? NSObject);          lua_setfield(L, -2, "quotationBeginDelimiterKey")
    skin.pushNSObject(locale.object(forKey: .quotationEndDelimiterKey) as? NSObject);            lua_setfield(L, -2, "quotationEndDelimiterKey")
    skin.pushNSObject(locale.object(forKey: .alternateQuotationBeginDelimiterKey) as? NSObject); lua_setfield(L, -2, "alternateQuotationBeginDelimiterKey")
    skin.pushNSObject(locale.object(forKey: .alternateQuotationEndDelimiterKey) as? NSObject);   lua_setfield(L, -2, "alternateQuotationEndDelimiterKey")

    // See http://stackoverflow.com/a/41263725
    if let tempUnit = locale.object(forKey: NSLocale.Key(rawValue: "kCFLocaleTemperatureUnitKey")) as? NSObject {
        skin.pushNSObject(tempUnit)
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
private func locale_availableLocaleIdentifiers(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let locales = NSLocale.availableLocaleIdentifiers
    skin.pushNSObject(locales as NSArray)
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
private func locale_preferredLanguages(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let languages = NSLocale.preferredLanguages
    skin.pushNSObject(languages as NSArray)
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
private func locale_currentIdentifier(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(NSLocale.current.identifier as NSString)
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
private func locale_localeInformation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    let theLocale: NSLocale
    if lua_gettop(L) == 0 {
        theLocale = NSLocale.current as NSLocale
    } else {
        let localeName: String = skin.toNSObject(atIndex: 1) as! String
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
private func locale_localizedString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    let availableLocales = NSLocale.availableLocaleIdentifiers
    let theLocale: NSLocale

    if lua_gettop(L) == 1 {
        theLocale = NSLocale.current as NSLocale
    } else {
        let baseLocaleCode: String = skin.toNSObject(atIndex: 2) as! String
        guard availableLocales.contains(baseLocaleCode) else {
            lua_pushnil(L)
            return 1
        }
        theLocale = NSLocale(localeIdentifier: baseLocaleCode)
    }

    let localeCode: String = skin.toNSObject(atIndex: 1) as! String
    guard availableLocales.contains(localeCode) else {
        lua_pushnil(L)
        return 1
    }

    let localizedString = (theLocale as Locale).localizedString(forLanguageCode: localeCode)
    let localizedStringWithDialect = theLocale.displayName(forKey: .identifier, value: localeCode)

    skin.pushNSObject(localizedString as NSString?)
    skin.pushNSObject(localizedStringWithDialect as NSString?)
    return 2
}

private func locale_registerCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)
    callbackRef = skin.luaUnref(refTable, ref: callbackRef) // should be unnecessary, but just in case
    lua_pushvalue(L, 1)
    callbackRef = skin.luaRef(refTable)
    return 0
}

// MARK: - Hammerspoon/Lua Infrastructure

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    callbackRef = skin.luaUnref(refTable, ref: callbackRef)
    observerOfChanges?.stop()
    observerOfChanges = nil
    return 0
}

// MARK: - C Callback Wrappers

private let locale_availableLocaleIdentifiers_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in locale_availableLocaleIdentifiers(L) }
private let locale_localeInformation_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in locale_localeInformation(L) }
private let locale_currentIdentifier_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in locale_currentIdentifier(L) }
private let locale_preferredLanguages_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in locale_preferredLanguages(L) }
private let locale_localizedString_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in locale_localizedString(L) }
private let locale_registerCallback_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in locale_registerCallback(L) }
private let meta_gc_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in meta_gc(L) }

// MARK: - Module Registration

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("availableLocales"),   func: locale_availableLocaleIdentifiers_C),
    luaL_Reg(name: strdup("details"),            func: locale_localeInformation_C),
    luaL_Reg(name: strdup("current"),            func: locale_currentIdentifier_C),
    luaL_Reg(name: strdup("preferredLanguages"), func: locale_preferredLanguages_C),
    luaL_Reg(name: strdup("localizedString"),    func: locale_localizedString_C),
    luaL_Reg(name: strdup("_registerCallback"),  func: locale_registerCallback_C),
    luaL_Reg(name: nil, func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc_C),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libhost_locale")
public func luaopen_hs_libhost_locale(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(USERDATA_TAG, functions: &moduleLib, metaFunctions: &module_metaLib)

    observerOfChanges = HSLocaleChangeObserver()
    observerOfChanges?.start()
    return 1
}
