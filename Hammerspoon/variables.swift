//
//  variables.swift
//  Hammerspoon
//
//  Swift translation of variables.h / variables.m.
//  Copyright (c) 2014 Hammerspoon. All rights reserved.
//
//  The #define string constants from variables.h are not automatically
//  bridged to Swift by the Clang importer, so they are re-declared here
//  as Swift constants.  The mutable global `MJConfigFile` remains in
//  variables.m (its `extern` declaration in variables.h is bridged
//  automatically).
//

import Foundation

// MARK: - UserDefaults Keys

/// Key controlling whether the dock icon is shown.
let MJShowDockIconKey           = "MJShowDockIconKey"

/// Key controlling whether the menu-bar icon is shown.
let MJShowMenuIconKey           = "MJShowMenuIconKey"

/// Key controlling whether the console window stays on top.
let MJKeepConsoleOnTopKey       = "MJKeepConsoleOnTopKey"

/// Key recording whether the app has completed its first-run setup.
let MJHasRunAlreadyKey          = "MJHasRunAlreadyKey"

/// Key controlling whether extensions are loaded automatically.
let HSAutoLoadExtensions        = "HSAutoLoadExtensions"

/// Key controlling whether AppleScript support is enabled.
let HSAppleScriptEnabledKey     = "HSAppleScriptEnabledKey"

/// Key controlling whether clicking the dock icon opens the console.
let HSOpenConsoleOnDockClickKey = "HSOpenConsoleOnDockClickKey"

/// Key controlling console dark-mode appearance.
let HSConsoleDarkModeKey        = "HSConsoleDarkModeKey"

/// Key controlling preferences dark-mode appearance.
let HSPreferencesDarkModeKey    = "HSPreferencesDarkModeKey"
