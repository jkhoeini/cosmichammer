/// === hs.doc.markdown ===
///
/// Markdown to HTML and plaintext conversion support used by hs.doc
///
/// This module provides GitHub-Flavored-Markdown conversion support used by hs.doc.  This module is a Lua wrapper to the C code portion of the Ruby gem `github-markdown`, available at https://rubygems.org/gems/github-markdown/versions/0.6.9.
///
/// The Ruby gem `github-markdown` was chosen as the code base for this module because it is the tool used to generate the official Hammerspoon Dash docset.
///
/// The Lua wrapper portion is licensed under the MIT license by the Hammerspoon development team.  The C code portion of the Ruby gem is licensed under the MIT license by GitHub, Inc.

import LuaSkin

private var refTable: LSRefTable = LUA_NOREF

private enum ModeType: Int {
    case GFM = 0
    case MARKDOWN
    case PLAINTEXT
}

// MARK: - Support Functions and Classes

private struct MarkdownPipeline {
    var md: OpaquePointer? // struct sd_markdown *
    var render_opts = html_renderopt()
}

private var g_markdown = MarkdownPipeline()
private var g_GFM = MarkdownPipeline()
private var g_plaintext = MarkdownPipeline()

private let rndr_blockcode_github: @convention(c) (
    UnsafeMutablePointer<buf>?,
    UnsafePointer<buf>?,
    UnsafePointer<buf>?,
    UnsafeMutableRawPointer?
) -> Void = { ob, text, lang, _ in
    guard let ob = ob else { return }

    if ob.pointee.size > 0 {
        bufputc(ob, Int32(Character("\n").asciiValue!))
    }

    guard let text = text, text.pointee.size > 0 else {
        let literal = "<pre><code></code></pre>"
        bufput(ob, literal, literal.utf8.count)
        return
    }

    if let lang = lang, lang.pointee.size > 0 {
        var i: Int = 0
        while i < lang.pointee.size && !isspace(Int32(lang.pointee.data[i])) != 0 {
            i += 1
        }

        let lang_name: UnsafePointer<UInt8>
        let lang_size: Int
        if lang.pointee.data[0] == Character(".").asciiValue! {
            lang_name = lang.pointee.data.advanced(by: 1)
            lang_size = i - 1
        } else {
            lang_name = lang.pointee.data
            lang_size = i
        }

        let prefix = "<pre lang=\""
        bufput(ob, prefix, prefix.utf8.count)
        houdini_escape_html0(ob, lang_name, lang_size, 0)
        let mid = "\"><code>"
        bufput(ob, mid, mid.utf8.count)
    } else {
        let prefix = "<pre><code>"
        bufput(ob, prefix, prefix.utf8.count)
    }

    houdini_escape_html0(ob, text.pointee.data, text.pointee.size, 0)
    let suffix = "</code></pre>\n"
    bufput(ob, suffix, suffix.utf8.count)
}

/* Max recursion nesting when parsing Markdown documents */
private let GITHUB_MD_NESTING: Int = 32

/* Default flags for all Markdown pipelines */
private let GITHUB_MD_FLAGS: UInt32 =
    UInt32(MKDEXT_NO_INTRA_EMPHASIS.rawValue) |
    UInt32(MKDEXT_LAX_SPACING.rawValue) |
    UInt32(MKDEXT_STRIKETHROUGH.rawValue) |
    UInt32(MKDEXT_TABLES.rawValue) |
    UInt32(MKDEXT_FENCED_CODE.rawValue) |
    UInt32(MKDEXT_AUTOLINK.rawValue)

/* Init the default pipeline */
private func ghmd__init_md() {
    var callbacks = sd_callbacks()

    /* No extra flags to the Markdown renderer */
    sdhtml_renderer(&callbacks, &g_markdown.render_opts, 0)
    callbacks.blockcode = rndr_blockcode_github

    g_markdown.md = sd_markdown_new(
        GITHUB_MD_FLAGS,
        GITHUB_MD_NESTING,
        &callbacks,
        &g_markdown.render_opts
    )
}

/* Init the GFM pipeline */
private func ghmd__init_gfm() {
    var callbacks = sd_callbacks()

    /*
     * The following extensions to the HTML output are enabled:
     *
     *  - HARD_WRAP: line breaks are replaced with <br> entities
     */
    sdhtml_renderer(&callbacks, &g_GFM.render_opts, UInt32(HTML_HARD_WRAP.rawValue))
    callbacks.blockcode = rndr_blockcode_github

    /* The following extensions to the parser are enabled, on top
     * of the common ones:
     *
     *  - SPACE_HEADERS: require a space between the `#` and the
     *      name of a header
     */
    g_GFM.md = sd_markdown_new(
        GITHUB_MD_FLAGS | UInt32(MKDEXT_SPACE_HEADERS.rawValue),
        GITHUB_MD_NESTING,
        &callbacks,
        &g_GFM.render_opts
    )
}

private func ghmd__init_plaintext() {
    var callbacks = sd_callbacks()

    sdtext_renderer(&callbacks)
    g_plaintext.md = sd_markdown_new(
        GITHUB_MD_FLAGS,
        GITHUB_MD_NESTING,
        &callbacks,
        nil
    )
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
private func to_html(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    var mode: ModeType = .GFM
    if lua_gettop(L) == 2 {
        let modeString = skin.toNSObject(atIndex: 2) as! NSString
        if modeString.isEqual(to: "gfm") {
            mode = .GFM
        } else if modeString.isEqual(to: "markdown") || modeString.isEqual(to: "readme") {
            mode = .MARKDOWN
        } else if modeString.isEqual(to: "plaintext") {
            mode = .PLAINTEXT
        } else {
            return luaL_argerror(L, 2, "invalid mode, \(modeString), specified")
        }
    }

    let textBody = skin.toNSObject(atIndex: 1, withOptions: LS_NSLuaStringAsDataOnly) as! NSData

    /* check for rendering mode */
    let md: OpaquePointer?
    switch mode {
    case .MARKDOWN:  md = g_markdown.md
    case .GFM:       md = g_GFM.md
    case .PLAINTEXT: md = g_plaintext.md
    }

    guard let md = md else {
        return luaL_error(L, "Invalid render mode")
    }

    /* initialize buffers */
    let output_buf = bufnew(128)!

    /* render the magic */
    sd_markdown_render(output_buf, textBody.bytes.assumingMemoryBound(to: UInt8.self), textBody.length, md)

    /* build the Lua string */
    let outputData = NSData(bytes: output_buf.pointee.data, length: output_buf.pointee.size)
    skin.pushNSObject(outputData)
    bufrelease(output_buf)

    return 1
}

// MARK: - Hammerspoon/Lua Infrastructure

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: ("convert" as NSString).utf8String, func: to_html),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libmarkdown")
public func luaopen_hs_libmarkdown(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    refTable = skin.registerLibrary("hs.doc.markdown", functions: &moduleLib, metaFunctions: nil)

    ghmd__init_md()
    ghmd__init_gfm()
    ghmd__init_plaintext()

    return 1
}
