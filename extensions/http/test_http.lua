local http = require("hs.http")

_G["respCode"] = 0
_G["respBody"] = ""
_G["respHeaders"] = {}

local REQUEST_HEADERS = {
  ["accept-language"] = "en",
  ["user-agent"] = "CosmicHammerTests/1",
  Accept = "*/*",
}

local RESPONSE_BODY = "local deterministic response\n"
local httpBaseURL = os.getenv("COSMIC_HAMMER_TEST_HTTP_BASE_URL")

local function resetResponse()
  _G["respCode"] = 0
  _G["respBody"] = ""
  _G["respHeaders"] = {}
end

local function startHttpTestServer()
  if type(httpBaseURL) ~= "string" or httpBaseURL == "" then
    error("COSMIC_HAMMER_TEST_HTTP_BASE_URL is required", 2)
  end
  return httpBaseURL
end

_G["callback"] = function(code, body, headers)
  _G["respCode"] = code
  _G["respBody"] = body
  _G["respHeaders"] = headers
end

function testHttpDoAsyncRequestWithCachePolicyParamValues()
  if (type(_G["respCode"]) == "number" and type(_G["respBody"]) == "string" and type(_G["respHeaders"]) == "table" and _G["respCode"] > 0) then
    -- check return code
    assertIsEqual(200, _G["respCode"])
    assertGreaterThan(0, string.len(_G["respBody"]))
    return success()
  else
    return "Waiting for success..."
  end
end

-- check request should be redirected if [enableRedirect|cachePolicy] param is given as cachePolicy
--  check point: response code == 200
function testHttpDoAsyncRequestWithCachePolicyParam()
  resetResponse()
  http.doAsyncRequest(
    startHttpTestServer() .. "/redirect",
    'GET',
    nil,
    REQUEST_HEADERS,
    _G["callback"],
    'protocolCachePolicy'
  )

  return success()
end

function testHttpDoAsyncRequestWithoutEnableRedirectAndCachePolicyParamValues()
  if (type(_G["respCode"]) == "number" and type(_G["respBody"]) == "string" and type(_G["respHeaders"]) == "table" and _G["respCode"] > 0) then
    -- check return code
    assertIsEqual(200, _G["respCode"])
    assertGreaterThan(0, string.len(_G["respBody"]))
    return success()
  else
    return "Waiting for success..."
  end
end

-- check request should be redirected if [enableRedirect|cachePolicy] param is not given.
--  check point: response code == 200
function testHttpDoAsyncRequestWithoutEnableRedirectAndCachePolicyParam()
  resetResponse()
  http.doAsyncRequest(
    startHttpTestServer() .. "/redirect",
    'GET',
    nil,
    REQUEST_HEADERS,
    _G["callback"]
  )

  return success()
end

function testHttpDoAsyncRequestWithRedirectionValues()
  if (type(_G["respCode"]) == "number" and type(_G["respBody"]) == "string" and type(_G["respHeaders"]) == "table" and _G["respCode"] > 0) then
    -- check return code
    assertIsEqual(200, _G["respCode"])
    assertGreaterThan(0, string.len(_G["respBody"]))
    return success()
  else
    return "Waiting for success..."
  end
end

-- check request should be redirected if [enableRedirect|cachePolicy] param is set to true as enableRedirect
--  check point: response code == 200
function testHttpDoAsyncRequestWithRedirection()
  resetResponse()
  http.doAsyncRequest(
    startHttpTestServer() .. "/redirect",
    'GET',
    nil,
    REQUEST_HEADERS,
    _G["callback"],
    true
  )

  return success()
end

function testHttpDoAsyncRequestWithoutRedirectionValues()
  if (type(_G["respCode"]) == "number" and type(_G["respBody"]) == "string" and type(_G["respHeaders"]) == "table" and _G["respCode"] > 0) then
    -- check return code
    assertIsEqual(301, _G["respCode"])
    return success()
  else
    return "Waiting for success..."
  end
end

-- check request should not be redirected if [enableRedirect|cachePolicy] param is set to false as enableRedirect
--  check point: response code == 301
function testHttpDoAsyncRequestWithoutRedirection()
  resetResponse()
  http.doAsyncRequest(
    startHttpTestServer() .. "/redirect",
    'GET',
    nil,
    REQUEST_HEADERS,
    _G["callback"],
    false
  )

  return success()
end
