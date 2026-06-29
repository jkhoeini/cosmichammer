# Cosmic Hammer

<p align="center">
  <img src="CosmicHammer.svg" alt="Cosmic Hammer" width="200" height="200"/>
</p>

<p align="center">
  <strong>Powerful macOS automation, forged in the cosmos.</strong>
</p>

Discord: [Click to join](https://discord.gg/vxchqkRbkR)

## What is Cosmic Hammer?

This is a tool for powerful automation of macOS. At its core, Cosmic Hammer is just a bridge between the operating system and a Lua scripting engine.

What gives Cosmic Hammer its power is a set of extensions that expose specific pieces of system functionality, to the user. With these, you can write Lua scripts to control many aspects of your macOS environment.

## How do I install it?

### Manually

 * Download the [latest release](https://github.com/jkhoeini/cosmichammer/releases/latest)
 * Drag `Cosmic Hammer.app` from your `Downloads` folder to `Applications`

### Homebrew

  * `brew install cosmic-hammer --cask`

## What next?

Out of the box, Cosmic Hammer does nothing - you will need to create `~/.cosmic-hammer/init.lua` and fill it with useful code. There are several resources which can help you:
 * [Getting Started Guide](https://github.com/jkhoeini/cosmichammer/go/)
 * [API docs](https://github.com/jkhoeini/cosmichammer/docs/)
 * [FAQ](https://github.com/jkhoeini/cosmichammer/faq/)
 * [Sample Configurations](https://github.com/jkhoeini/cosmichammer/wiki/Sample-Configurations) supplied by various users
 * [OpenTelemetry Guide](docs/opentelemetry.md) for tracing, logs, metrics, and local diagnostics
 * [Contribution Guide](https://github.com/jkhoeini/cosmichammer/blob/master/CONTRIBUTING.md) for developers looking to get involved
 * An IRC channel for general chat/support/development (#cosmic-hammer on Libera)

## What is the history of the project?

Cosmic Hammer is a fork of [Hammerspoon](https://github.com/jkhoeini/cosmichammer), which is itself a fork of [Mjolnir](https://github.com/mjolnirapp/mjolnir). Mjolnir aims to be a very minimal application, with its extensions hosted externally and managed using a Lua package manager. We wanted to provide a more integrated experience.

## What is the future of the project?

Our intentions for Cosmic Hammer broadly fall into these categories:
 * Ever wider coverage of system APIs in Extensions
 * Tighter integration between extensions
 * Smoother user experience

