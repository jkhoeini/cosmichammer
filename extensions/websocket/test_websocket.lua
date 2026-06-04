local websocket         = require "hs.websocket"
local timer             = require "hs.timer"

local doAfter           = timer.doAfter

--
-- Variables:
--
local TEST_STRING       = "ABC123"
local ECHO_PORT         = tonumber(os.getenv("COSMIC_HAMMER_TEST_WEBSOCKET_PORT")) or 8067
local ECHO_URL          = os.getenv("COSMIC_HAMMER_TEST_WEBSOCKET_URL") or ("ws://localhost:" .. tostring(ECHO_PORT) .. "/")
local FAKE_URL          = "ws://127.0.0.1:1/"
local WSS_FAKE_URL      = "wss://127.0.0.1:1/"

local webserver = nil
local requestTimer = nil

local log = require("hs.crash").crashLog

--
-- Helper functions:
--
function startEchoServer()
    if os.getenv("COSMIC_HAMMER_TEST_WEBSOCKET_URL") then return success() end
    if webserver then return success() end
    log("Starting Echo Server")
    webserver = hs.httpserver.new(false, false)
    webserver:setPort(ECHO_PORT)
    webserver:websocket("/", function(msg)
        log("Echo Server received: " .. msg)
        return msg
    end)
    webserver:setCallback(function(type, path, headers, body)
        log("Echo Server called as HTTP at: "..path.." with: "..body)
        return "Error", 400, {["Content-Type"] = "text/plain"}
    end)
    webserver:start()
end

function stopEchoServer()
    if os.getenv("COSMIC_HAMMER_TEST_WEBSOCKET_URL") then return success() end
    if not webserver then return success() end
    log("Stopping Echo Server")
    webserver:stop()
    webserver = nil
end

--
-- Test creating a new object:
--
function testNew()
  local websocketObject = websocket.new(ECHO_URL, function() end)
  assertIsUserdataOfType("hs.websocket", websocketObject)
  assertTrue(#tostring(websocketObject) > 0)
  websocketObject:close()
  return success()
end

function testNewWss()
  local websocketObject = websocket.new(WSS_FAKE_URL, function() end)
  assertIsUserdataOfType("hs.websocket", websocketObject)
  assertTrue(#tostring(websocketObject) > 0)
  websocketObject:close()
  return success()
end

--
-- Test sending a binary echo:
--
local echoTestObj = nil
local event = ""
local message = ""

function testEchoData()
  echoTestObj = websocket.new(ECHO_URL, function(e, m)
    event = e
    message = m
  end)
  requestTimer = doAfter(2, function()
    log("testEcho() sending test string")
    echoTestObj:send(TEST_STRING, true)
  end)
  return success()
end

function testEchoDataValues()
  if type(event) == "string" and event == "received" and type(message) == "string" and message == TEST_STRING then
    echoTestObj:close()
    echoTestObj = nil
    event = ""
    message = ""
    return success()
  else
    return "Waiting for echo...'"..echoTestObj:status().."', "
  end
end

function testEchoDataCleanup()
  if echoTestObj then echoTestObj:close() end
  echoTestObj = nil
  event = ""
  message = ""
  return success()
end

--
-- Test sending a text echo:
--
function testEchoText()
  echoTestObj = websocket.new(ECHO_URL, function(e, m)
    event = e
    message = m
  end)
  requestTimer = doAfter(2, function()
    log("testEcho() sending test string")
    echoTestObj:send(TEST_STRING, false)
  end)
  return success()
end

function testEchoTextValues()
  if type(event) == "string" and event == "received" and type(message) == "string" and message == TEST_STRING then
    echoTestObj:close()
    echoTestObj = nil
    event = ""
    message = ""
    return success()
  else
    return "Waiting for echo...'"..echoTestObj:status().."', "
  end
end

function testEchoTextCleanup()
  if echoTestObj then echoTestObj:close() end
  echoTestObj = nil
  event = ""
  message = ""
  return success()
end

--
-- Test the status of an open websocket:
--
local openStatusTestObj = nil

function testOpenStatus()
  openStatusTestObj = websocket.new(ECHO_URL, function() end)
  return success()
end

function testOpenStatusValues()
  local status = openStatusTestObj:status()
  if status == "open" then
    openStatusTestObj:close()
    return success()
  else
    return "Waiting for websocket to open...'"..status.."', "
  end
end

--
-- Test that closing a websocket leaves it closing or closed by the next poll:
--
local closeStatusAfterCloseTestObj = nil

function testCloseStatusAfterClose()
  closeStatusAfterCloseTestObj = websocket.new(ECHO_URL, function() end)
  closeStatusAfterCloseTestObj:close()
  return success()
end

function testCloseStatusAfterCloseValues()
  local status = closeStatusAfterCloseTestObj:status()
  if status == "closing" or status == "closed" then
    return success()
  else
    return "Waiting for websocket to start closing..."..status
  end
end

--
-- Test the status of an closed websocket:
--
local closedStatusTestObj = nil

function testClosedStatus()
  closedStatusTestObj = websocket.new(FAKE_URL, function() end)
  return success()
end

function testClosedStatusValues()
  if closedStatusTestObj:status() == "closed" then
    return success()
  else
    return "Waiting for websocket to close..."..closedStatusTestObj:status()
  end
end

--
-- Test hs.http.websocket wrapper
--

local wrapperTestObj = nil
local wrapperMessage = ""

function testLegacy()
  local http = require("hs.http")
  local legacy = http.websocket
  wrapperTestObj = legacy(ECHO_URL, function(m)
    wrapperMessage = m
  end)
  requestTimer = doAfter(2, function()
    log("testLegacy() sending test string")
    wrapperTestObj:send(TEST_STRING)
  end)
  return success()
end

function testLegacyValues()
  if type(wrapperMessage) == "string" and wrapperMessage == TEST_STRING then
    wrapperTestObj:close()
    return success()
  else
    return "Waiting for echo...'"..wrapperTestObj:status().."', "
  end
end

function testLegacyCleanup()
  if wrapperTestObj then wrapperTestObj:close() end
  wrapperTestObj = nil
  wrapperMessage = ""
  return success()
end
