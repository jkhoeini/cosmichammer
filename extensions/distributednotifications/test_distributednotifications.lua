hs.distributednotifications = require("hs.distributednotifications")

-- Storage for a notifications watcher object
distNotWatcher = nil
-- Storage for a timer callback to modify in various tests
testDistNotValue = nil

function testDistributedNotifications()
  distNotWatcher = hs.distributednotifications.new(function(name, object, userInfo)
    if (name == "org.cosmic-hammer.CosmicHammer.testDistributedNotifications" and
        object == "org.cosmic-hammer.CosmicHammer.testRunner") then
      testDistNotValue = true
    end
  end, "org.cosmic-hammer.CosmicHammer.testDistributedNotifications")
  distNotWatcher:start()

  hs.distributednotifications.post("org.cosmic-hammer.CosmicHammer.testDistributedNotifications", "org.cosmic-hammer.CosmicHammer.testRunner")

  return success()
end

function testDistNotValueCheck()
  if (type(testDistNotValue) == "boolean" and testDistNotValue == true) then
    return success()
  else
    return string.format("Waiting for success...(%s != true)", tostring(testDistNotValue))
  end
end
