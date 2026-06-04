local M = {}

M.preloadAliases = {
  { "hs.application.watcher", "hs.libapplicationwatcher" },
  { "hs.audiodevice.watcher", "hs.libaudiodevicewatcher" },
  { "hs.battery.watcher", "hs.libbatterywatcher" },
  { "hs.bonjour.service", "hs.libbonjourservice" },
  { "hs.caffeinate.watcher", "hs.libcaffeinatewatcher" },
  { "hs.canvas.matrix", "hs.canvas_matrix" },
  { "hs.drawing.color", "hs.drawing_color" },
  { "hs.doc.hsdocs", "hs.hsdocs" },
  { "hs.doc.markdown", "hs.libmarkdown" },
  { "hs.doc.builder", "hs.doc_builder" },
  { "hs.fs.volume", "hs.libfsvolume" },
  { "hs.fs.xattr", "hs.libfsxattr" },
  { "hs.host.locale", "hs.host_locale" },
  { "hs.httpserver.hsminweb", "hs.httpserver_hsminweb" },
  { "hs.location.geocoder", "hs.location_geocoder" },
  { "hs.network.configuration", "hs.network_configuration" },
  { "hs.network.host", "hs.network_host" },
  { "hs.network.ping", "hs.network_ping" },
  { "hs.pasteboard.watcher", "hs.libpasteboardwatcher" },
  { "hs.screen.watcher", "hs.libscreenwatcher" },
  { "hs.socket.udp", "hs.libsocketudp" },
  { "hs.spaces.watcher", "hs.libspaces_watcher" },
  { "hs.uielement.watcher", "hs.libuielementwatcher" },
  { "hs.usb.watcher", "hs.libusbwatcher" },
  { "hs.webview.datastore", "hs.libwebviewdatastore" },
  { "hs.webview.usercontent", "hs.libwebviewusercontent" },
  { "hs.webview.toolbar", "hs.webview_toolbar" },
  { "hs.wifi.watcher", "hs.libwifiwatcher" },
  { "hs.window.filter", "hs.window_filter" },
  { "hs.window.highlight", "hs.window_highlight" },
  { "hs.window.layout", "hs.window_layout" },
  { "hs.window.switcher", "hs.window_switcher" },
  { "hs.window.tiling", "hs.window_tiling" },
}

local function requireField(context, name, expectedType)
  local value = context[name]
  if type(value) ~= expectedType then
    error(string.format("boot context field %s must be %s, got %s", name, expectedType, type(value)), 3)
  end
  return value
end

function M.validateContext(context)
  if type(context) ~= "table" then
    error("setup.lua expected one boot context table", 3)
  end

  requireField(context, "extensionsPath", "string")
  requireField(context, "configFileDisplayPath", "string")
  requireField(context, "configFilePath", "string")
  requireField(context, "configDir", "string")
  requireField(context, "docsJSONPath", "string")
  requireField(context, "hasInitFile", "boolean")
  requireField(context, "autoloadExtensions", "boolean")

  return context
end

function M.installPreloadAliases()
  local preload = function(m) return function() return require(m) end end

  for _, alias in ipairs(M.preloadAliases) do
    package.preload[alias[1]] = preload(alias[2])
  end
end

return M
