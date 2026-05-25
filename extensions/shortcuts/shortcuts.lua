--- === hs.shortcuts ===
---
--- List and run shortcuts from the Shortcuts app
---
--- Separate from this extension, Cosmic Hammer provides an action for use in the Shortcuts app.
--- The action is called "Execute Lua" and if it is passed a text block of valid Lua, it will execute that Lua within Cosmic Hammer.
--- You can use this action to call functions defined in your `init.lua` or to just execute chunks of Lua.
---
--- Your functions/chunks can return text, which will be returned by the action in Shortcuts.

local module = require("hs.libshortcuts")
return module
