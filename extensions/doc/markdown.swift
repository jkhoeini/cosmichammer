/// === hs.doc.markdown ===
///
/// Markdown to HTML and plaintext conversion support used by hs.doc
///
/// This module provides GitHub-Flavored-Markdown conversion support used by hs.doc.  This module is a Lua wrapper to the C code portion of the Ruby gem `github-markdown`, available at https://rubygems.org/gems/github-markdown/versions/0.6.9.
///
/// The Ruby gem `github-markdown` was chosen as the code base for this module because it is the tool used to generate the official Hammerspoon Dash docset.
///
/// The Lua wrapper portion is licensed under the MIT license by the Hammerspoon development team.  The C code portion of the Ruby gem is licensed under the MIT license by GitHub, Inc.

import Foundation
import LuaSkin

// MARK: - C Interop Declarations
//
// The sundown/github-markdown C library compiles in the HSExtensions target.
// Since HSSwiftExtensions is a separate SPM target we cannot import those
// headers directly; instead we forward-declare every C symbol we need.

// -- struct buf (from buffer.h) --------------------------------------------------
// We replicate the layout so we can read output_buf->data / ->size.
private struct CMarkdownBuf {
    var data: UnsafeMutablePointer<UInt8>?
    var size: Int       // size_t
    var asize: Int      // size_t  (allocated size)
    var unit: Int       // size_t  (reallocation unit)
}

// -- Opaque types ----------------------------------------------------------------
// sd_markdown is intentionally opaque in the C header.
// sd_callbacks and html_renderopt are large structs full of function pointers;
// we never touch their fields from Swift, so treat them as opaque blobs.

// sd_callbacks: 25 function pointers, each 8 bytes on arm64/x86_64 = 200 bytes.
// We over-allocate slightly to be safe across compiler padding differences.
private let SD_CALLBACKS_SIZE = 256

// html_renderopt: toc_data (3 ints = 12 bytes) + flags (4 bytes) + link_attributes
// function pointer (8 bytes) + possible padding = ~32 bytes. Over-allocate.
private let HTML_RENDEROPT_SIZE = 64

// -- Buffer functions (buffer.h) -------------------------------------------------
@_silgen_name("bufnew")
private func c_bufnew(_ unit: Int) -> UnsafeMutablePointer<CMarkdownBuf>?

@_silgen_name("bufrelease")
private func c_bufrelease(_ buf: UnsafeMutablePointer<CMarkdownBuf>?)

@_silgen_name("bufput")
private func c_bufput(_ buf: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer?, _ size: Int)

@_silgen_name("bufputc")
private func c_bufputc(_ buf: UnsafeMutableRawPointer?, _ c: Int32)

// -- HTML renderer (html.h) ------------------------------------------------------
@_silgen_name("sdhtml_renderer")
private func c_sdhtml_renderer(
    _ callbacks: UnsafeMutableRawPointer?,
    _ options: UnsafeMutableRawPointer?,
    _ render_flags: UInt32
)

// -- Plaintext renderer (plaintext.h) --------------------------------------------
@_silgen_name("sdtext_renderer")
private func c_sdtext_renderer(_ callbacks: UnsafeMutableRawPointer?)

// -- Markdown engine (markdown.h) ------------------------------------------------
// sd_markdown_new returns an opaque sd_markdown*.
@_silgen_name("sd_markdown_new")
private func c_sd_markdown_new(
    _ extensions: UInt32,
    _ max_nesting: Int,
    _ callbacks: UnsafeRawPointer?,
    _ opaque: UnsafeMutableRawPointer?
) -> OpaquePointer?

@_silgen_name("sd_markdown_render")
private func c_sd_markdown_render(
    _ ob: UnsafeMutableRawPointer?,
    _ document: UnsafePointer<UInt8>?,
    _ doc_size: Int,
    _ md: OpaquePointer?
)

// -- Houdini (houdini.h) ---------------------------------------------------------
@_silgen_name("houdini_escape_html0")
private func c_houdini_escape_html0(
    _ ob: UnsafeMutableRawPointer?,
    _ src: UnsafePointer<UInt8>?,
    _ size: Int,
    _ secure: Int32
)

// -- Markdown extension flags (from markdown.h enum mkd_extensions) --------------
private let MKDEXT_NO_INTRA_EMPHASIS: UInt32 = 1 << 0
private let MKDEXT_TABLES:            UInt32 = 1 << 1
private let MKDEXT_FENCED_CODE:       UInt32 = 1 << 2
private let MKDEXT_AUTOLINK:          UInt32 = 1 << 3
private let MKDEXT_STRIKETHROUGH:     UInt32 = 1 << 4
private let MKDEXT_SPACE_HEADERS:     UInt32 = 1 << 6
private let MKDEXT_LAX_SPACING:       UInt32 = 1 << 8

// -- HTML render flags (from html.h enum html_render_mode) -----------------------
private let HTML_HARD_WRAP: UInt32 = 1 << 7

// MARK: - Module Constants

private let USERDATA_TAG = "hs.doc.markdown"

private let GITHUB_MD_NESTING = 32

private let GITHUB_MD_FLAGS: UInt32 =
    MKDEXT_NO_INTRA_EMPHASIS |
    MKDEXT_LAX_SPACING       |
    MKDEXT_STRIKETHROUGH     |
    MKDEXT_TABLES            |
    MKDEXT_FENCED_CODE       |
    MKDEXT_AUTOLINK

// MARK: - Mode Enum

private enum ModeType: Int {
    case gfm = 0
    case markdown
    case plaintext
}

// MARK: - Pipeline State
//
// Each pipeline owns:
//   - a blob for sd_callbacks
//   - a blob for html_renderopt (HTML pipelines only)
//   - an opaque sd_markdown* handle

private struct MarkdownPipeline {
    var md: OpaquePointer?
    // Keep the callback/renderopt allocations alive for the lifetime of md.
    var callbacksBuf: UnsafeMutableRawPointer?
    var renderOptsBuf: UnsafeMutableRawPointer?
}

private var g_markdown  = MarkdownPipeline()
private var g_GFM       = MarkdownPipeline()
private var g_plaintext = MarkdownPipeline()

// Custom blockcode renderer that mirrors rndr_blockcode_github from markdown.m.
// The C signature is:
//   void blockcode(struct buf *ob, const struct buf *text,
//                  const struct buf *lang, void *opaque)
private let rndr_blockcode_github:
    @convention(c) (
        UnsafeMutableRawPointer?,       // ob
        UnsafeRawPointer?,              // text
        UnsafeRawPointer?,              // lang
        UnsafeMutableRawPointer?        // opaque (unused)
    ) -> Void = { obRaw, textRaw, langRaw, _ in

    guard let obRaw = obRaw else { return }
    let ob = obRaw.assumingMemoryBound(to: CMarkdownBuf.self)

    if ob.pointee.size > 0 {
        c_bufputc(obRaw, Int32(UInt8(ascii: "\n")))
    }

    // Read text buf fields (may be NULL)
    let text: UnsafePointer<CMarkdownBuf>? = textRaw?.assumingMemoryBound(to: CMarkdownBuf.self)
    let lang: UnsafePointer<CMarkdownBuf>? = langRaw?.assumingMemoryBound(to: CMarkdownBuf.self)

    let hasText = text != nil && text!.pointee.size > 0
    let hasLang = lang != nil && lang!.pointee.size > 0

    if !hasText {
        "<pre><code></code></pre>".withCString { cstr in
            c_bufput(obRaw, cstr, strlen(cstr))
        }
        return
    }

    if hasLang {
        // Find the first non-space run in lang
        let langData = lang!.pointee.data!
        let langSize = lang!.pointee.size
        var i = 0
        while i < langSize && !langData[i].isWhitespace_ascii {
            i += 1
        }

        let langName: UnsafePointer<UInt8>
        let langNameSize: Int
        if langData[0] == UInt8(ascii: ".") {
            langName = UnsafePointer(langData.advanced(by: 1))
            langNameSize = i - 1
        } else {
            langName = UnsafePointer(langData)
            langNameSize = i
        }

        "<pre lang=\"".withCString { cstr in
            c_bufput(obRaw, cstr, strlen(cstr))
        }
        c_houdini_escape_html0(obRaw, langName, langNameSize, 0)
        "\"><code>".withCString { cstr in
            c_bufput(obRaw, cstr, strlen(cstr))
        }
    } else {
        "<pre><code>".withCString { cstr in
            c_bufput(obRaw, cstr, strlen(cstr))
        }
    }

    c_houdini_escape_html0(obRaw, text!.pointee.data, text!.pointee.size, 0)
    "</code></pre>\n".withCString { cstr in
        c_bufput(obRaw, cstr, strlen(cstr))
    }
}

private extension UInt8 {
    var isWhitespace_ascii: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}

// MARK: - Pipeline Initialization

// The sd_callbacks struct is an array of function pointers. The blockcode
// callback is the very first field.  After sdhtml_renderer fills in the
// defaults we overwrite that first pointer with our custom renderer.

private func ghmd__init_md() {
    let callbacks = UnsafeMutableRawPointer.allocate(byteCount: SD_CALLBACKS_SIZE, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
    callbacks.initializeMemory(as: UInt8.self, repeating: 0, count: SD_CALLBACKS_SIZE)
    let renderOpts = UnsafeMutableRawPointer.allocate(byteCount: HTML_RENDEROPT_SIZE, alignment: MemoryLayout<Int>.alignment)
    renderOpts.initializeMemory(as: UInt8.self, repeating: 0, count: HTML_RENDEROPT_SIZE)

    c_sdhtml_renderer(callbacks, renderOpts, 0)

    // Patch blockcode (first function pointer in sd_callbacks)
    callbacks.assumingMemoryBound(to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void)?.self)
        .pointee = rndr_blockcode_github

    g_markdown.callbacksBuf = callbacks
    g_markdown.renderOptsBuf = renderOpts
    g_markdown.md = c_sd_markdown_new(GITHUB_MD_FLAGS, GITHUB_MD_NESTING, callbacks, renderOpts)
}

private func ghmd__init_gfm() {
    let callbacks = UnsafeMutableRawPointer.allocate(byteCount: SD_CALLBACKS_SIZE, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
    callbacks.initializeMemory(as: UInt8.self, repeating: 0, count: SD_CALLBACKS_SIZE)
    let renderOpts = UnsafeMutableRawPointer.allocate(byteCount: HTML_RENDEROPT_SIZE, alignment: MemoryLayout<Int>.alignment)
    renderOpts.initializeMemory(as: UInt8.self, repeating: 0, count: HTML_RENDEROPT_SIZE)

    c_sdhtml_renderer(callbacks, renderOpts, HTML_HARD_WRAP)

    // Patch blockcode
    callbacks.assumingMemoryBound(to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void)?.self)
        .pointee = rndr_blockcode_github

    g_GFM.callbacksBuf = callbacks
    g_GFM.renderOptsBuf = renderOpts
    g_GFM.md = c_sd_markdown_new(GITHUB_MD_FLAGS | MKDEXT_SPACE_HEADERS, GITHUB_MD_NESTING, callbacks, renderOpts)
}

private func ghmd__init_plaintext() {
    let callbacks = UnsafeMutableRawPointer.allocate(byteCount: SD_CALLBACKS_SIZE, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
    callbacks.initializeMemory(as: UInt8.self, repeating: 0, count: SD_CALLBACKS_SIZE)

    c_sdtext_renderer(callbacks)

    g_plaintext.callbacksBuf = callbacks
    g_plaintext.renderOptsBuf = nil
    g_plaintext.md = c_sd_markdown_new(GITHUB_MD_FLAGS, GITHUB_MD_NESTING, callbacks, nil)
}

// MARK: - Module Functions

/// hs.doc.markdown.convert(markdown, [type]) -> output
/// Function
/// Converts markdown encoded text to html or plaintext.
///
/// Parameters:
///  * markdown - a string containing the input text encoded using markdown tags
///  * type     - an optional string specifying the conversion options and output type.  Defaults to "gfm".  The currently recognized types are:
///    * "markdown"  - specifies that the output should be HTML with the standard GitHub/Markdown extensions enabled.
///    * "gfm"       - specifies that the output should be HTML with additional GitHub extensions enabled.
///    * "plaintext" - specifies that the output should plain text with the standard GitHub/Markdown extensions enabled.
///
/// Returns:
///  * an HTML or plaintext representation of the markdown encoded text provided.
///
/// Notes:
///  * The standard GitHub/Markdown extensions enabled for all conversions are:
///    * NO_INTRA_EMPHASIS -  disallow emphasis inside of words
///    * LAX_SPACING       - supports spacing like in Markdown 1.0.0 (i.e. do not require an empty line between two different blocks in a paragraph)
///    * STRIKETHROUGH     - support strikethrough with double tildes (~)
///    * TABLES            - support Markdown tables
///    * FENCED_CODE       - supports fenced code blocks surround by three back-ticks (`) or three tildes (~)
///    * AUTOLINK          - HTTP URL's are treated as links, even if they aren't marked as such with Markdown tags
///
///  * The "gfm" type also includes the following extensions:
///   * HARD_WRAP     - line breaks are replaced with <br> entities
///   * SPACE_HEADERS - require a space between the `#` and the name of a header (prevents collisions with the Issues filter)
private func markdown_convert(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    var mode: ModeType = .gfm
    if lua_gettop(L) == 2 {
        let modeString = skin.toNSObject(atIndex: 2) as! NSString
        if modeString.isEqual(to: "gfm") {
            mode = .gfm
        } else if modeString.isEqual(to: "markdown") || modeString.isEqual(to: "readme") {
            mode = .markdown
        } else if modeString.isEqual(to: "plaintext") {
            mode = .plaintext
        } else {
            return luaL_argerror(L, 2, "invalid mode, \(modeString), specified")
        }
    }

    // Get input as raw bytes (NSData)
    let textBody = skin.toNSObject(atIndex: 1, withOptions: .nsLuaStringAsDataOnly) as! NSData

    // Select the pipeline
    let md: OpaquePointer?
    switch mode {
    case .markdown:  md = g_markdown.md
    case .gfm:       md = g_GFM.md
    case .plaintext:  md = g_plaintext.md
    }

    guard let md = md else {
        return luaL_error(L, "Invalid render mode")
    }

    // Allocate output buffer
    guard let outputBuf = c_bufnew(128) else {
        return luaL_error(L, "Failed to allocate output buffer")
    }

    // Render
    c_sd_markdown_render(outputBuf, textBody.bytes.assumingMemoryBound(to: UInt8.self), textBody.length, md)

    // Build result NSData and push
    let outputData = NSData(bytes: outputBuf.pointee.data, length: outputBuf.pointee.size)
    skin.pushNSObject(outputData)

    c_bufrelease(outputBuf)

    return 1
}

// MARK: - Hammerspoon/Lua Infrastructure

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: ("convert" as NSString).utf8String, func: markdown_convert),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libmarkdown")
public func luaopen_hs_libmarkdown(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary("hs.doc.markdown", functions: &moduleLib, metaFunctions: nil)

    ghmd__init_md()
    ghmd__init_gfm()
    ghmd__init_plaintext()

    return 1
}
