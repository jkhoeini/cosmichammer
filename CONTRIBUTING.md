# Contributing to Cosmic Hammer

- [Contributing to Cosmic Hammer](#contributing-to-cosmic-hammer)
  - [How is everything built?](#how-is-everything-built)
    - [Making frequent local rebuilds more convenient](#making-frequent-local-rebuilds-more-convenient)
  - [Contributing to the core app or LuaSkin](#contributing-to-the-core-app-or-luaskin)
  - [Contributing to the extensions](#contributing-to-the-extensions)
    - [Writing a new, pure-Lua extension](#writing-a-new-pure-lua-extension)
    - [Writing a new mixed Lua/Swift extension](#writing-a-new-mixed-luaswift-extension)
    - [Documenting your extension](#documenting-your-extension)
      - [Constants](#constants)
      - [Variables](#variables)
      - [Functions](#functions)
      - [Methods](#methods)
    - [Testing](#testing)
    - [Third party extension distribution](#third-party-extension-distribution)

Cosmic Hammer is composed of three separate logical areas - a Lua runtime wrapper framework called [LuaSkin](http://www.cosmichammer.org/docs/LuaSkin/Classes/LuaSkin/index.html#), the core Cosmic Hammer app which houses the LuaSkin/Lua runtime and provides the ability to load extensions, and [various extension modules](https://github.com/cosmichammer/cosmic-hammer/tree/master/extensions) that [expose system APIs](http://www.cosmichammer.org/docs/) to the user's Lua code.

## How is everything built?

The app is built using SPM (Swift Package Manager) via `just build`. A root-level `Package.swift` defines all targets under `Sources/<TargetName>/`. The justfile compiles the executable via `swift build`, then assembles the `.app` bundle (copying resources, Lua files, hs CLI, and codesigning). See `CLAUDE.md` for the full architecture.

### Making frequent local rebuilds more convenient
[Self-signing your builds](https://github.com/jkhoeini/cosmichammer/issues/643#issuecomment-158291705) will keep you from having to re-enable permissions for your locally built copy.

Create a self-signed Code Signing certificate named 'Internal Code Signing' or similar as described [here](http://bd808.com/blog/2013/10/21/creating-a-self-signed-code-certificate-for-xcode/).

Then, simply run `just rebuild` for more streamlined builds.

## Contributing to the core app or LuaSkin
This is generally very simple in terms of the workflow, but there's less likely to be any reason to work on the core app:

* Clone our GitHub [repository](https://github.com/jkhoeini/cosmichammer)
* Run `just build` to compile
* Make the changes you want
* Push them up to a fork on GitHub
* Propose a Pull Request on GitHub
* Open an issue on GitHub if you need any guidance

## Contributing to the extensions

This is really where the meat of Cosmic Hammer is. Extensions can either be pure Lua or a mixture of Lua and Objective-C (although since they are just dynamically loaded libraries, they could ultimately be compiled in almost any language, if there is a sufficiently compelling reason).

*Note*: all APIs provided by extensions should follow the camelCase naming convention. This does not need to apply to an extension's internal functions, just the ones presented to Lua.

Modifying an existing extension should follow the simple workflow above for the core app.

### Writing a new, pure-Lua extension ###

These extensions generally provide useful helper functionality for users (e.g. abstracting other extensions).

To create such an extension:

* Clone the Cosmic Hammer git repository
* cd into the `extensions` directory
* Make a directory for your extension
* Create a `modulename.lua` to contain your code, giving it the appropriate name. It should behave like any normal Lua library - that is to say, your job is to return a table containing functions/methods/constants/etc
* Ensure you document your API in our preferred format (see the code for almost any existing module for reference)
* Add a line to `extensions.manifest`: `<name><TAB>-<TAB><name>.lua`
* Build Cosmic Hammer and test your extension
* Push your changes up to a fork on GitHub
* Propose a Pull Request on GitHub
* Open an issue on GitHub if you need any guidance

### Writing a new mixed Lua/Swift extension ###

These extensions generally expose an OS level API for users to automate (e.g. adjusting screen brightness using IOKit).

To create such an extension:

* Clone the Cosmic Hammer git repository
* Create `extensions/<name>/<name>.lua` for the Lua interface
* Create the Swift source file (e.g. `lib<name>.swift`) and place it in `Sources/HSSwiftExtensions/`
* For ObjC/C files, create `Sources/HSExtensions/<name>/` and place `.m`/`.h`/`.c` files there
* Add a line to `extensions.manifest`: `<name><TAB><luaopen_hs_lib symbols><TAB><name>.lua`
* Run `scripts/generate-hsextensions.sh`
* Run `just build` and test your extension
* Push your changes up to a fork on GitHub
* Propose a Pull Request on GitHub

### Documenting your extension

Both Lua and Objective-C portions of an extension should contain in-line documentation of all of the functions they expose to users of the extension.

The format for docstrings should follow the standard described below. Note that for Lua files, the lines should begin with `---` and for Objective C files, the lines should begin with `///`.

#### Constants

```lua
--- hs.foo.someConstant
--- Constant
--- This defines the value of a thing
```

#### Variables

```lua
--- hs.foo.someVariable
--- Variable
--- This lets you influence the behaviour of this extension
```

#### Functions

Note that a function is any API function provided by an extension, which doesn't relate to an object created by the extension.

The `Parameters` and `Returns` sections should always be present. If there is nothing to describe there, simply list `* None`. The `Notes` section is optional and should only be present if there are useful notes.

```lua
--- hs.foo.someFunction(bar[, baz]) -> string or nil
--- Function
--- This is a one-line description of the function
---
--- Parameters:
---  * bar - A value for doing something
---  * baz - Some optional other value. Defaults to 'abc'
---
--- Returns:
---  * A string with some important result, or nil if an error occurred
---
--- Notes:
---  * An important first note
---  * Another important note
```

#### Methods

Note that a method is any function provided by an extension which relates to an object created by that extension. They are still technically functions, but the signature is differentiated by the presence of a `:`

The `Parameters` and `Returns` sections should always be present. If there is nothing to describe there, simply list `* None`. The `Notes` section is optional and should only be present if there are useful notes.

```lua
--- hs.foo:someMethod() -> bool
--- Method
--- This is a one-line description of the method
---
--- Parameters:
---  * None
---
--- Returns:
---  * Boolean indicating whether the operation succeeded.
```

### Testing

All new extensions in Cosmic Hammer should be landed with a test suite, and any modifications to existing extensions should add appropriate tests (which may mean creating tests, if the extension in question is not currently being fully tested).

Our test suite uses Swift Testing (`@Suite`/`@Test`/`#expect`) and lives in the SPM package at `Tests/CosmicHammerTests/`. The Lua test functions are in `extensions/<name>/test_<name>.lua`; the Swift side loads each module and calls the Lua functions.

To add tests for an extension `foo`:

 * Create `extensions/foo/test_foo.lua` with functions named `testBar` that return `success()` on pass.
 * Create `Tests/CosmicHammerTests/FooTests.swift` with a `@Suite` class inside `CosmicHammerTests`:
   ```swift
   extension CosmicHammerTests {
       @Suite(.serialized) @MainActor final class Foo {
           init() throws { try loadLuaModule("test_foo") }
           @Test func testBar() { runLuaTest() }
       }
   }
   ```
 * For hardware-dependent tests, add `.skipInHeadless`: `@Test(.skipInHeadless) func testBar() { ... }`
 * Run tests: `just test` (requires `just build` first).

The Lua test harness (`lsunit.lua` in `Tests/CosmicHammerTests/`) provides assertion helpers:

 * `assertIsEqual(expected, actual)` - Ensures that the two arguments are of the same type and value
 * `assertTrue(a)`/`assertFalse(a)` - Ensure that the argument is `true`/`false` respectively
 * `assertIsString(a)`/`assertIsNumber(a)`/`assertIsBoolean(a)`/etc - Ensure that the Lua type of a variable is correct
 * `assertIsUserdataOfType(type, a)` - Ensures that the argument is a Lua userdata object of a particular type

### Third party extension distribution

While we want to have Cosmic Hammer shipping as many useful extensions as possible, there may be reasons for you to ship your extension separately. It would probably be easier to do this in binary form, following the init.lua/internal.so form that Cosmic Hammer uses, then users can just download your extension into `~/.cosmic-hammer/<YOUR_EXTENSION_NAME>/`.

If you do choose this route, please list your extension at [https://github.com/jkhoeini/cosmichammer/wiki/Third-Party-Extensions](https://github.com/jkhoeini/cosmichammer/wiki/Third-Party-Extensions) so users can discover it easily.
