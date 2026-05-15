import Cocoa
import LuaSkin
import Darwin.sys.sysctl
import Darwin.POSIX.sys.types
import Darwin.Mach
import IOKit

// MARK: - Host Functions

/// hs.host.addresses() -> table
/// Function
/// Gets a list of network addresses for the current machine
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table of strings containing the network addresses of the current machine
///
/// Notes:
///  * The results will include IPv4 and IPv6 addresses
private func hostAddresses(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let addresses = Host.current().addresses as [String]? else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    var i: lua_Integer = 1
    for address in addresses {
        lua_pushinteger(L, i)
        lua_pushstring(L, address)
        lua_settable(L, -3)
        i += 1
    }

    return 1
}

/// hs.host.names() -> table
/// Function
/// Gets a list of network names for the current machine
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table of strings containing the network names of the current machine
///
/// Notes:
///  * This function should be used sparingly, as it may involve blocking network access to resolve hostnames
private func hostNames(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let names = Host.current().names as [String]? else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    var i: lua_Integer = 1
    for name in names {
        lua_pushinteger(L, i)
        lua_pushstring(L, name)
        lua_settable(L, -3)
        i += 1
    }

    return 1
}

/// hs.host.localizedName() -> string
/// Function
/// Gets the name of the current machine, as displayed in the Finder sidebar
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the name of the current machine
private func hostLocalizedName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushstring(L, Host.current().localizedName)
    return 1
}

/// hs.host.vmStat() -> table
/// Function
/// Returns a table containing virtual memory statistics for the current machine, as well as the page size (in bytes) and physical memory size (in bytes).
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the following keys:
///    * anonymousPages          -- the total number of pages that are anonymous
///    * cacheHits               -- number of object cache hits
///    * cacheLookups            -- number of object cache lookups
///    * fileBackedPages         -- the total number of pages that are file-backed (non-swap)
///    * memSize                 -- physical memory size in bytes
///    * pageIns                 -- the total number of requests for pages from a pager (such as the inode pager).
///    * pageOuts                -- the total number of pages that have been paged out.
///    * pageSize                -- page size in bytes
///    * pagesActive             -- the total number of pages currently in use and pageable.
///    * pagesCompressed         -- the total number of pages that have been compressed by the VM compressor.
///    * pagesCopyOnWrite        -- the number of faults that caused a page to be copied (generally caused by copy-on-write faults).
///    * pagesDecompressed       -- the total number of pages that have been decompressed by the VM compressor.
///    * pagesFree               -- the total number of free pages in the system.
///    * pagesInactive           -- the total number of pages on the inactive list.
///    * pagesPurgeable          -- the total number of purgeable pages.
///    * pagesPurged             -- the total number of pages that have been purged.
///    * pagesReactivated        -- the total number of pages that have been moved from the inactive list to the active list (reactivated).
///    * pagesSpeculative        -- the total number of pages on the speculative list.
///    * pagesThrottled          -- the total number of pages on the throttled list (not wired but not pageable).
///    * pagesUsedByVMCompressor -- the number of pages used to store compressed VM pages.
///    * pagesWiredDown          -- the total number of pages wired down. That is, pages that cannot be paged out.
///    * pagesZeroFilled         -- the total number of pages that have been zero-filled on demand.
///    * swapIns                 -- the total number of compressed pages that have been swapped out to disk.
///    * swapOuts                -- the total number of compressed pages that have been swapped back in from disk.
///    * translationFaults       -- the number of times the "vm_fault" routine has been called.
///    * uncompressedPages       -- the total number of pages (uncompressed) held within the compressor
///
/// Notes:
///  * The table returned has a __tostring() metamethod which allows listing it's contents in the Hammerspoon console by typing `hs.host.vmStats()`.
///  * Except for the addition of cacheHits, cacheLookups, pageSize and memSize, the results for this function should be identical to the OS X command `vm_stat`.
///  * Adapted primarily from the source code to Apple's vm_stat command located at http://www.opensource.apple.com/source/system_cmds/system_cmds-643.1.1/vm_stat.tproj/vm_stat.c
private func hs_vmstat(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    var mib: [Int32] = [CTL_HW, HW_PAGESIZE]
    var pagesize: UInt32 = 0
    var length = MemoryLayout<UInt32>.size
    if sysctl(&mib, 2, &pagesize, &length, nil, 0) < 0 {
        skin.logError("hs.host.vmStat() error: Error getting page size (\(errno)): \(String(cString: strerror(errno)))")
        return 0
    }

    mib = [CTL_HW, HW_MEMSIZE]
    var memsize: UInt64 = 0
    length = MemoryLayout<UInt64>.size
    if sysctl(&mib, 2, &memsize, &length, nil, 0) < 0 {
        skin.logError("hs.host.vmStat() error: Error getting mem size (\(errno)): \(String(cString: strerror(errno)))")
        return 0
    }

    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var vm_stat = vm_statistics64_data_t()
    let retVal = withUnsafeMutablePointer(to: &vm_stat) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
        }
    }

    if retVal != KERN_SUCCESS {
        skin.logError("hs.host.vmStat() error: Error getting VM Statistics: \(String(cString: mach_error_string(retVal)))")
        return 0
    }

    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(Int64(vm_stat.free_count) - Int64(vm_stat.speculative_count)))
    lua_setfield(L, -2, "pagesFree")
    lua_pushinteger(L, lua_Integer(vm_stat.active_count))
    lua_setfield(L, -2, "pagesActive")
    lua_pushinteger(L, lua_Integer(vm_stat.inactive_count))
    lua_setfield(L, -2, "pagesInactive")
    lua_pushinteger(L, lua_Integer(vm_stat.speculative_count))
    lua_setfield(L, -2, "pagesSpeculative")
    lua_pushinteger(L, lua_Integer(vm_stat.throttled_count))
    lua_setfield(L, -2, "pagesThrottled")
    lua_pushinteger(L, lua_Integer(vm_stat.wire_count))
    lua_setfield(L, -2, "pagesWiredDown")
    lua_pushinteger(L, lua_Integer(vm_stat.purgeable_count))
    lua_setfield(L, -2, "pagesPurgeable")
    lua_pushinteger(L, lua_Integer(vm_stat.faults))
    lua_setfield(L, -2, "translationFaults")
    lua_pushinteger(L, lua_Integer(vm_stat.cow_faults))
    lua_setfield(L, -2, "pagesCopyOnWrite")
    lua_pushinteger(L, lua_Integer(vm_stat.zero_fill_count))
    lua_setfield(L, -2, "pagesZeroFilled")
    lua_pushinteger(L, lua_Integer(vm_stat.reactivations))
    lua_setfield(L, -2, "pagesReactivated")
    lua_pushinteger(L, lua_Integer(vm_stat.purges))
    lua_setfield(L, -2, "pagesPurged")
    lua_pushinteger(L, lua_Integer(vm_stat.external_page_count))
    lua_setfield(L, -2, "fileBackedPages")
    lua_pushinteger(L, lua_Integer(vm_stat.internal_page_count))
    lua_setfield(L, -2, "anonymousPages")
    lua_pushinteger(L, lua_Integer(vm_stat.total_uncompressed_pages_in_compressor))
    lua_setfield(L, -2, "uncompressedPages")
    lua_pushinteger(L, lua_Integer(vm_stat.compressor_page_count))
    lua_setfield(L, -2, "pagesUsedByVMCompressor")
    lua_pushinteger(L, lua_Integer(vm_stat.decompressions))
    lua_setfield(L, -2, "pagesDecompressed")
    lua_pushinteger(L, lua_Integer(vm_stat.compressions))
    lua_setfield(L, -2, "pagesCompressed")
    lua_pushinteger(L, lua_Integer(vm_stat.pageins))
    lua_setfield(L, -2, "pageIns")
    lua_pushinteger(L, lua_Integer(vm_stat.pageouts))
    lua_setfield(L, -2, "pageOuts")
    lua_pushinteger(L, lua_Integer(vm_stat.swapins))
    lua_setfield(L, -2, "swapIns")
    lua_pushinteger(L, lua_Integer(vm_stat.swapouts))
    lua_setfield(L, -2, "swapOuts")
    lua_pushinteger(L, lua_Integer(vm_stat.lookups))
    lua_setfield(L, -2, "cacheLookups")
    lua_pushinteger(L, lua_Integer(vm_stat.hits))
    lua_setfield(L, -2, "cacheHits")
    lua_pushinteger(L, lua_Integer(pagesize))
    lua_setfield(L, -2, "pageSize")
    lua_pushinteger(L, lua_Integer(memsize))
    lua_setfield(L, -2, "memSize")

    return 1
}

/// hs.host.cpuUsageTicks() -> table
/// Function
/// Returns a table containing the current cpu usage information for the system in `ticks` since the most recent system boot.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the following:
///    * Individual tables, indexed by the core number, for each CPU core with the following keys in each subtable:
///      * user   -- number of ticks the cpu core has spent in user mode since system startup.
///      * system -- number of ticks the cpu core has spent in system mode since system startup.
///      * nice   --
///      * active -- For convenience, when you just want the total CPU usage, this is the sum of user, system, and nice.
///      * idle   -- number of ticks the cpu core has spent idle
///    * The key `overall` containing the same keys as described above but based upon the combined total of all cpu cores for the system.
///    * The key `n` containing the number of cores detected.
///
/// Notes:
///  * CPU mode ticks are updated during system interrupts and are incremented based upon the mode the CPU is in at the time of the interrupt. By its nature, this is always going to be approximate, and a single call to this function will return the current tick values since the system was last rebooted.
///  * To generate a snapshot of the system's usage "at this moment", you must take two samples and calculate the difference between them.  The [hs.host.cpuUsage](#cpuUsage) function is a wrapper which does this for you and returns the cpu usage statistics as a percentage of the total number of ticks which occurred during the sample period you specify when invoking `hs.host.cpuUsage`.
///
///  * Historically on Unix based systems, the `nice` cpu state represents processes for which the execution priority has been reduced to allow other higher priority processes access to more system resources.  The source code for the version of the [XNU Kernel](https://opensource.apple.com/source/xnu/xnu-3789.41.3/) currently provided by Apple (for macOS 10.12.3) shows this value as returned by the `host_processor_info` as hardcoded to 0.  For completeness, this value *is* included in the statistics returned by this function, but unless Apple makes a change in the future, it is not expected to provide any useful information.
///
///  * Adapted primarily from code found at http://stackoverflow.com/questions/6785069/get-cpu-percent-usage
private func hs_cpuUsageTicks(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    var numCPUs: UInt32 = 0
    var mib: [Int32] = [CTL_HW, HW_NCPU]
    var sizeOfNumCPUs = MemoryLayout<UInt32>.size
    let status = sysctl(&mib, 2, &numCPUs, &sizeOfNumCPUs, nil, 0)
    if status != 0 { numCPUs = 1 }

    var cpuInfo: processor_info_array_t?
    var numCpuInfo: mach_msg_type_number_t = 0
    var numCPUsU: natural_t = 0
    let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo)

    if err == KERN_SUCCESS, let cpuInfo = cpuInfo {
        var overallInUser: UInt64 = 0
        var overallInSystem: UInt64 = 0
        var overallInNice: UInt64 = 0
        var overallInIdle: UInt64 = 0
        var overallInUse: UInt64 = 0

        lua_newtable(L)
        for i in 0..<Int(numCPUs) {
            let inUser   = UInt32(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_USER)])
            let inSystem = UInt32(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_SYSTEM)])
            let inNice   = UInt32(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_NICE)])
            let inIdle   = UInt32(cpuInfo[Int(CPU_STATE_MAX) * i + Int(CPU_STATE_IDLE)])
            let inUse    = inUser + inSystem + inNice

            overallInUser   += UInt64(inUser)
            overallInSystem += UInt64(inSystem)
            overallInNice   += UInt64(inNice)
            overallInIdle   += UInt64(inIdle)
            overallInUse    += UInt64(inUse)

            lua_newtable(L)
            lua_pushinteger(L, lua_Integer(inUser));   lua_setfield(L, -2, "user")
            lua_pushinteger(L, lua_Integer(inSystem)); lua_setfield(L, -2, "system")
            lua_pushinteger(L, lua_Integer(inNice));   lua_setfield(L, -2, "nice")
            lua_pushinteger(L, lua_Integer(inUse));    lua_setfield(L, -2, "active")
            lua_pushinteger(L, lua_Integer(inIdle));   lua_setfield(L, -2, "idle")
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }

        lua_newtable(L)
        lua_pushinteger(L, lua_Integer(overallInUser));   lua_setfield(L, -2, "user")
        lua_pushinteger(L, lua_Integer(overallInSystem)); lua_setfield(L, -2, "system")
        lua_pushinteger(L, lua_Integer(overallInNice));   lua_setfield(L, -2, "nice")
        lua_pushinteger(L, lua_Integer(overallInUse));    lua_setfield(L, -2, "active")
        lua_pushinteger(L, lua_Integer(overallInIdle));   lua_setfield(L, -2, "idle")
        lua_setfield(L, -2, "overall")

        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(MemoryLayout<integer_t>.size * Int(numCpuInfo)))
    } else {
        skin.logError("hs.host.cpuUsage() error: \(String(cString: mach_error_string(err)))")
        return 0
    }

    lua_pushinteger(L, lua_Integer(numCPUs))
    lua_setfield(L, -2, "n")
    return 1
}

/// hs.host.operatingSystemVersionString() -> string
/// Function
/// The operating system version as a human readable string.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The operating system version as a human readable string.
///
/// Notes:
///  * According to the OS X Developer documentation, "The operating system version string is human readable, localized, and is appropriate for displaying to the user. This string is not appropriate for parsing."
private func hs_operatingSystemVersionString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let pinfo = ProcessInfo.processInfo
    lua_pushstring(L, pinfo.operatingSystemVersionString)
    return 1
}

/// hs.host.thermalState() -> string
/// Function
/// The current thermal state of the computer, as a human readable string
///
/// Parameters:
///  * None
///
/// Returns:
///  * The system's thermal state as a human readable string
private func hs_thermalStateString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)

    let state = ProcessInfo.processInfo.thermalState
    let returnState: String
    switch state {
    case .nominal:  returnState = "nominal"
    case .fair:     returnState = "fair"
    case .serious:  returnState = "serious"
    case .critical: returnState = "critical"
    @unknown default: returnState = "unknown"
    }

    skin.pushNSObject(returnState as NSString)
    return 1
}

/// hs.host.operatingSystemVersion() -> table
/// Function
/// The operating system version as a table containing the major, minor, and patch numbers.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The operating system version as a table containing the keys major, minor, and patch corresponding to the version number determined and a key named "exact" or "approximation" depending upon the method used to determine the OS Version information.
///
/// Notes:
///  * Prior to 10.10 (Yosemite), there was no definitive way to reliably get an exact OS X version number without either mapping it to the Darwin kernel version, mapping it to the AppKitVersionNumber (the recommended method), or parsing the result of NSProcessingInfo's `operatingSystemVersionString` selector, which Apple states is not guaranteed to be reliably parsable.
///    * for OS X versions prior to 10.10, the version number is approximately determined by evaluating the AppKitVersionNumber.  For these operating systems, the `approximate` key is defined and set to true, as the exact patch level cannot be definitively determined.
///    * for OS X Versions starting at 10.10 and going forward, an exact value for the version number can be determined with NSProcessingInfo's `operatingSystemVersion` selector and the `exact` key is defined and set to true if this method is used.
private func hs_operatingSystemVersion(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let osv = ProcessInfo.processInfo.operatingSystemVersion

    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(osv.majorVersion)); lua_setfield(L, -2, "major")
    lua_pushinteger(L, lua_Integer(osv.minorVersion)); lua_setfield(L, -2, "minor")
    lua_pushinteger(L, lua_Integer(osv.patchVersion)); lua_setfield(L, -2, "patch")
    lua_pushboolean(L, 1);                             lua_setfield(L, -2, "exact")

    return 1
}

/// hs.host.interfaceStyle() -> string
/// Function
/// Returns the OS X interface style for the current user.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string representing the current user interface style, or nil if the default style is in use.
///
/// Notes:
///  * As of OS X 10.10.4, other than the default style, only "Dark" is recognized as a valid style.
private func hs_interfaceStyle(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
        lua_pushstring(L, style)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.host.uuid() -> string
/// Function
/// Returns a newly generated UUID as a string
///
/// Parameters:
///  * None
///
/// Returns:
///  * a newly generated UUID as a string
///
/// Notes:
///  * See also `hs.host.globallyUniqueString`
///  * UUIDs (Universally Unique Identifiers), also known as GUIDs (Globally Unique Identifiers) or IIDs (Interface Identifiers), are 128-bit values. UUIDs created by NSUUID conform to RFC 4122 version 4 and are created with random bytes.
private func hs_uuid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushstring(L, UUID().uuidString)
    return 1
}

/// hs.host.globallyUniqueString() -> string
/// Function
/// Returns a newly generated global unique identifier as a string
///
/// Parameters:
///  * None
///
/// Returns:
///  * a newly generated global unique identifier as a string
///
/// Notes:
///  * See also `hs.host.uuid`
///  * The global unique identifier for a process includes the host name, process ID, and a time stamp, which ensures that the ID is unique for the network. This property generates a new string each time it is invoked, and it uses a counter to guarantee that strings are unique.
///  * This is often used as a file or directory name in conjunction with `hs.host.temporaryDirectory()` when creating temporary files.
private func hs_globallyUniqueString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushstring(L, ProcessInfo.processInfo.globallyUniqueString)
    return 1
}

/// hs.host.idleTime() -> seconds
/// Function
/// Returns the number of seconds the computer has been idle.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the idle time in seconds
///
/// Notes:
///  * Idle time is defined as no mouse move nor keyboard entry, etc. and is determined by querying the HID (Human Interface Device) subsystem.
///  * This code is directly inspired by code found at http://www.xs-labs.com/en/archives/articles/iokit-idle-time/
private func hs_idleTime(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var ioPort: mach_port_t = 0
    var status = IOMainPort(mach_port_t(MACH_PORT_NULL), &ioPort)
    if status != KERN_SUCCESS {
        luaL_error(L, "Error communicating with IOKit: \(status)")
        return 0
    }

    var ioIterator: io_iterator_t = 0
    status = IOServiceGetMatchingServices(ioPort, IOServiceMatching("IOHIDSystem"), &ioIterator)
    if status != KERN_SUCCESS {
        luaL_error(L, "Error accessing IOHIDSystem: \(status)")
        return 0
    }

    let ioObject = IOIteratorNext(ioIterator)
    if ioObject == 0 {
        IOObjectRelease(ioIterator)
        luaL_error(L, "Invalid iterator returned for IOHIDSystem")
        return 0
    }

    var properties: Unmanaged<CFMutableDictionary>?
    status = IORegistryEntryCreateCFProperties(ioObject, &properties, kCFAllocatorDefault, 0)
    guard status == KERN_SUCCESS, let props = properties?.takeRetainedValue() as? [String: Any] else {
        IOObjectRelease(ioIterator)
        luaL_error(L, "Cannot get system properties for IOHIDSystem: \(status)")
        return 0
    }

    guard let idle = props["HIDIdleTime"] else {
        IOObjectRelease(ioIterator)
        luaL_error(L, "Cannot get system idle time from system properties for IOHIDSystem")
        return 0
    }

    var time: UInt64 = 0
    if let idleData = idle as? Data {
        time = idleData.withUnsafeBytes { $0.load(as: UInt64.self) }
    } else if let idleNumber = idle as? NSNumber {
        time = idleNumber.uint64Value
    } else {
        IOObjectRelease(ioIterator)
        luaL_error(L, "Unsupported type for HIDIdleTime")
        return 0
    }

    IOObjectRelease(ioIterator)

    lua_pushinteger(L, lua_Integer(time >> 30))
    return 1
}

/// hs.host.volumeInformation([showHidden]) -> table
/// Function
/// Returns a table of information about disk volumes attached to the system
///
/// Parameters:
///  * showHidden - An optional boolean, true to show hidden volumes, false to not show hidden volumes. Defaults to false.
///
/// Returns:
///  * A table of information, where the keys are the paths of disk volumes
///
/// Notes:
///  * The possible keys in the table are:
///   * NSURLVolumeTotalCapacityKey - Size of the volume in bytes
///   * NSURLVolumeAvailableCapacityKey - Available space on the volume in bytes
///   * NSURLVolumeIsAutomountedKey - Boolean indicating if the volume was automounted
///   * NSURLVolumeIsBrowsableKey - Boolean indicating if the volume can be browsed
///   * NSURLVolumeIsEjectableKey - Boolean indicating if the volume should be ejected before its media is removed
///   * NSURLVolumeIsInternalKey - Boolean indicating if the volume is an internal drive or an external drive
///   * NSURLVolumeIsLocalKey - Boolean indicating if the volume is a local or remote drive
///   * NSURLVolumeIsReadOnlyKey - Boolean indicating if the volume is read only
///   * NSURLVolumeIsRemovableKey - Boolean indicating if the volume's media can be physically ejected from the drive (e.g. a DVD)
///   * NSURLVolumeMaximumFileSizeKey - Maximum file size the volume can support, in bytes
///   * NSURLVolumeUUIDStringKey - The UUID of volume's filesystem
///   * NSURLVolumeURLForRemountingKey - For remote volumes, the network URL of the volume
///   * NSURLVolumeLocalizedNameKey - Localized version of the volume's name
///   * NSURLVolumeNameKey - The volume's name
///   * NSURLVolumeLocalizedFormatDescriptionKey - Localized description of the volume
/// * Not all keys will be present for all volumes
/// * The meanings of NSURLVolumeIsEjectableKey and NSURLVolumeIsRemovableKey are not generally useful for determining if a drive is removable in the modern sense (e.g. a USB drive) as much of this terminology dates back to when USB didn't exist and removable drives were things like Floppy/DVD drives. If you're trying to determine if a drive is not fixed into the computer, you may need to use a combination of these keys, but which exact combination you should use, is not consistent across macOS versions.
private func hs_volumeInformation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let fileManager = FileManager.default
    let volumeInfo = NSMutableDictionary()

    let urlResourceKeys: [URLResourceKey] = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeIsAutomountedKey,
        .volumeIsBrowsableKey,
        .volumeIsEjectableKey,
        .volumeIsInternalKey,
        .volumeIsLocalKey,
        .volumeIsReadOnlyKey,
        .volumeIsRemovableKey,
        .volumeMaximumFileSizeKey,
        .volumeUUIDStringKey,
        .volumeURLForRemountingKey,
        .volumeLocalizedNameKey,
        .volumeNameKey,
        .volumeLocalizedFormatDescriptionKey
    ]

    var options: FileManager.VolumeEnumerationOptions = .skipHiddenVolumes
    if lua_type(L, 1) == LUA_TBOOLEAN && lua_toboolean(L, 1) != 0 {
        options = []
    }

    let resourceKeySet = Set(urlResourceKeys)
    if let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: urlResourceKeys, options: options) {
        for url in urls {
            if let result = try? url.resourceValues(forKeys: resourceKeySet),
               let path = url.path as String? {
                let dict = NSMutableDictionary()
                for key in urlResourceKeys {
                    if let value = result.allValues[key] {
                        dict[key.rawValue] = value
                    }
                }
                volumeInfo[path] = dict
            }
        }
    }

    skin.pushNSObject(volumeInfo)
    return 1
}

/// hs.host.gpuVRAM() -> table
/// Function
/// Returns the model and VRAM size for the installed GPUs.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table whose key-value pairs represent the GPUs for the current system.  Each key is a string containing the name for an installed GPU and its value is the GPU's VRAM size in MB.  If the VRAM size cannot be determined for a specific GPU, its value will be -1.0.
///
/// Notes:
///  * If your GPU reports -1.0 as the memory size, please submit an issue to the Hammerspoon github repository and include any information that you can which may be relevant, such as: Macintosh model, macOS version, is the GPU built in or a third party expansion card, the GPU model and VRAM as best you can determine (see the System Information application in the Utilities folder and look at the Graphics/Display section) and anything else that you think might be important.
private func hs_vramSize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var iterator: io_iterator_t = 0
    let err = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPCIDevice"), &iterator)
    if err != KERN_SUCCESS {
        luaL_error(L, "IOServiceGetMatchingServices failed: \(err)")
        return 0
    }

    lua_newtable(L)

    var device = IOIteratorNext(iterator)
    while device != 0 {
        defer {
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }

        guard let nameRef = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "IOName" as CFString, kCFAllocatorDefault, 0) else {
            continue
        }
        let name = nameRef as! CFString
        guard CFStringCompare(name, "display" as CFString, CFStringCompareFlags(rawValue: 0)) == .compareEqualTo else {
            continue
        }

        guard let modelRef = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "model" as CFString, kCFAllocatorDefault, 0) else {
            continue
        }
        let modelData = modelRef as! CFData

        var valueInBytes = true
        var vramSizeRef = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "VRAM,totalsize" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
        if vramSizeRef == nil {
            valueInBytes = false
            vramSizeRef = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "VRAM,totalMB" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
        }

        if let vramRef = vramSizeRef {
            var size: UInt64 = 0
            let type = CFGetTypeID(vramRef)
            if type == CFDataGetTypeID() {
                let data = vramRef as! CFData
                let dataLength = CFDataGetLength(data)
                CFDataGetBytes(data, CFRangeMake(0, dataLength), &size)
                if dataLength == MemoryLayout<UInt32>.size {
                    size = UInt64((data as Data).withUnsafeBytes { $0.load(as: UInt32.self) })
                }
            } else if type == CFNumberGetTypeID() {
                CFNumberGetValue(vramRef as! CFNumber, .sInt64Type, &size)
            }

            if valueInBytes { size >>= 20 }
            lua_pushnumber(L, lua_Number(size))
        } else {
            lua_pushnumber(L, -1)
        }

        let modelPtr = CFDataGetBytePtr(modelData)!
        lua_setfield(L, -2, modelPtr.withMemoryRebound(to: CChar.self, capacity: CFDataGetLength(modelData)) { $0 })
    }

    IOObjectRelease(iterator)
    return 1
}

// MARK: - C Callback Wrappers

private let hostAddresses_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hostAddresses(L) }
private let hostNames_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hostNames(L) }
private let hostLocalizedName_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hostLocalizedName(L) }
private let hs_vmstat_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_vmstat(L) }
private let hs_cpuUsageTicks_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_cpuUsageTicks(L) }
private let hs_operatingSystemVersion_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_operatingSystemVersion(L) }
private let hs_operatingSystemVersionString_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_operatingSystemVersionString(L) }
private let hs_thermalStateString_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_thermalStateString(L) }
private let hs_interfaceStyle_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_interfaceStyle(L) }
private let hs_uuid_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_uuid(L) }
private let hs_globallyUniqueString_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_globallyUniqueString(L) }
private let hs_volumeInformation_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_volumeInformation(L) }
private let hs_idleTime_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_idleTime(L) }
private let hs_vramSize_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hs_vramSize(L) }

// MARK: - Module Registration

private let hostlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("addresses"),                    func: hostAddresses_C),
    luaL_Reg(name: strdup("names"),                        func: hostNames_C),
    luaL_Reg(name: strdup("localizedName"),                func: hostLocalizedName_C),
    luaL_Reg(name: strdup("vmStat"),                       func: hs_vmstat_C),
    luaL_Reg(name: strdup("cpuUsageTicks"),                func: hs_cpuUsageTicks_C),
    luaL_Reg(name: strdup("operatingSystemVersion"),       func: hs_operatingSystemVersion_C),
    luaL_Reg(name: strdup("operatingSystemVersionString"), func: hs_operatingSystemVersionString_C),
    luaL_Reg(name: strdup("thermalState"),                 func: hs_thermalStateString_C),
    luaL_Reg(name: strdup("interfaceStyle"),               func: hs_interfaceStyle_C),
    luaL_Reg(name: strdup("uuid"),                         func: hs_uuid_C),
    luaL_Reg(name: strdup("globallyUniqueString"),         func: hs_globallyUniqueString_C),
    luaL_Reg(name: strdup("volumeInformation"),            func: hs_volumeInformation_C),
    luaL_Reg(name: strdup("idleTime"),                     func: hs_idleTime_C),
    luaL_Reg(name: strdup("gpuVRAM"),                      func: hs_vramSize_C),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libhost")
public func luaopen_hs_libhost(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    var lib = hostlib
    skin.registerLibrary("hs.host", functions: &lib, metaFunctions: nil)

    return 1
}
