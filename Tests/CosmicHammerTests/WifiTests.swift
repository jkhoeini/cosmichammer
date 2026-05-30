import Testing

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class WifiTests {
        @Test(.skipInHeadless) func testInterfacesReturnsATable() {
            let result = runLua("""
                local wifi = require('hs.wifi')
                local interfaces = wifi.interfaces()
                if interfaces == nil then return 'Success' end
                if type(interfaces) ~= 'table' then return 'interfaces:' .. type(interfaces) end
                return 'Success'
                """)
            #expect(result == "Success", "Unexpected Wi-Fi interfaces shape: \(result ?? "nil")")
        }

        @Test(.skipInHeadless) func testInterfaceDetailsConvertsCoreWLANObjectsToTables() {
            let result = runLua("""
                local wifi = require('hs.wifi')
                local details = wifi.interfaceDetails()
                if details == nil then return 'Success' end
                if type(details) ~= 'table' then return 'details:' .. type(details) end

                local function tableOrNil(value, name)
                    if value ~= nil and type(value) ~= 'table' then
                        return name .. ':' .. type(value)
                    end
                    return nil
                end

                local function arrayOfTables(value, name)
                    local err = tableOrNil(value, name)
                    if err ~= nil then return err end
                    if value == nil then return nil end
                    for i, item in ipairs(value) do
                        if type(item) ~= 'table' then
                            return name .. '[' .. i .. ']:' .. type(item)
                        end
                    end
                    return nil
                end

                local err = tableOrNil(details.wlanChannel, 'wlanChannel')
                    or arrayOfTables(details.supportedChannels, 'supportedChannels')
                    or tableOrNil(details.configuration, 'configuration')
                    or arrayOfTables(details.cachedScanResults, 'cachedScanResults')
                if err ~= nil then return err end

                if details.configuration ~= nil then
                    err = arrayOfTables(details.configuration.networkProfiles, 'configuration.networkProfiles')
                    if err ~= nil then return err end
                end

                return 'Success'
                """)
            #expect(result == "Success", "Unexpected Wi-Fi conversion shape: \(result ?? "nil")")
        }
    }
}
