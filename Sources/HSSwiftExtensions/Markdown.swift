/// === hs.doc.markdown ===
///
/// Markdown to HTML and plaintext conversion support used by hs.doc
///
/// This module provides GitHub-Flavored-Markdown conversion support used by hs.doc.
///
/// The Lua wrapper portion is licensed under the MIT license by the Cosmic Hammer development team.

import Foundation
import CLua
import Lua
import Markdown

// MARK: - Mode Enum

private enum ModeType: Int {
    case gfm = 0
    case markdown
    case plaintext
}

// MARK: - HTML Renderer

/// Walks the swift-markdown AST and emits HTML, supporting GFM extensions
/// (tables, strikethrough, fenced code blocks, autolinks).
private struct HTMLRenderer: MarkupWalker {
    var result = ""
    let hardWrap: Bool

    init(hardWrap: Bool = false) {
        self.hardWrap = hardWrap
    }

    // MARK: Helpers

    private static func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            default:   out.append(ch)
            }
        }
        return out
    }

    // MARK: Block-level elements

    mutating func visitHeading(_ heading: Heading) -> () {
        let level = heading.level
        result += "<h\(level)>"
        descendInto(heading)
        result += "</h\(level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> () {
        result += "<p>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> () {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> () {
        if result.count > 0 && !result.hasSuffix("\n") {
            result += "\n"
        }
        let code = codeBlock.code
        if code.isEmpty {
            result += "<pre><code></code></pre>"
            return
        }
        if let lang = codeBlock.language, !lang.isEmpty {
            // Strip leading dot if present, take first word
            let langName: String
            let trimmed = lang.hasPrefix(".") ? String(lang.dropFirst()) : lang
            if let spaceIdx = trimmed.firstIndex(of: " ") {
                langName = String(trimmed[trimmed.startIndex..<spaceIdx])
            } else {
                langName = trimmed
            }
            result += "<pre lang=\"\(Self.escapeHTML(langName))\"><code>"
        } else {
            result += "<pre><code>"
        }
        result += Self.escapeHTML(code)
        result += "</code></pre>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> () {
        result += "<hr />\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> () {
        result += html.rawHTML
    }

    // MARK: Lists

    mutating func visitOrderedList(_ orderedList: OrderedList) -> () {
        if orderedList.startIndex != 1 {
            result += "<ol start=\"\(orderedList.startIndex)\">\n"
        } else {
            result += "<ol>\n"
        }
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> () {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> () {
        result += "<li>"
        descendInto(listItem)
        result += "</li>\n"
    }

    // MARK: Tables (GFM)

    mutating func visitTable(_ table: Markdown.Table) -> () {
        result += "<table>\n"
        descendInto(table)
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Markdown.Table.Head) -> () {
        result += "<thead>\n<tr>\n"
        for cell in tableHead.cells {
            let align = alignAttribute(for: cell)
            result += "<th\(align)>"
            var cellRenderer = HTMLRenderer(hardWrap: hardWrap)
            cellRenderer.descendInto(cell)
            result += cellRenderer.result
            result += "</th>\n"
        }
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Markdown.Table.Body) -> () {
        if tableBody.childCount > 0 {
            result += "<tbody>\n"
            descendInto(tableBody)
            result += "</tbody>\n"
        }
    }

    mutating func visitTableRow(_ tableRow: Markdown.Table.Row) -> () {
        result += "<tr>\n"
        for cell in tableRow.cells {
            let align = alignAttribute(for: cell)
            result += "<td\(align)>"
            var cellRenderer = HTMLRenderer(hardWrap: hardWrap)
            cellRenderer.descendInto(cell)
            result += cellRenderer.result
            result += "</td>\n"
        }
        result += "</tr>\n"
    }

    // Skip default traversal for table head/body/row since we handle them above
    mutating func visitTableCell(_ cell: Markdown.Table.Cell) -> () {
        descendInto(cell)
    }

    private func alignAttribute(for cell: Markdown.Table.Cell) -> String {
        let col = cell.indexInParent
        // Walk up to find the Table: cell -> Head/Row -> Table, or cell -> Row -> Body -> Table
        let table: Markdown.Table?
        if let t = cell.parent?.parent as? Markdown.Table {
            table = t
        } else if let t = cell.parent?.parent?.parent as? Markdown.Table {
            table = t
        } else {
            table = nil
        }
        guard let table = table else { return "" }
        let alignments = table.columnAlignments
        guard col < alignments.count else { return "" }
        guard let alignment = alignments[col] else { return "" }
        switch alignment {
        case .left:   return " align=\"left\""
        case .center: return " align=\"center\""
        case .right:  return " align=\"right\""
        }
    }

    // MARK: Inline elements

    mutating func visitText(_ text: Text) -> () {
        result += Self.escapeHTML(text.string)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> () {
        result += "<code>"
        result += Self.escapeHTML(inlineCode.code)
        result += "</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> () {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> () {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> () {
        result += "<del>"
        descendInto(strikethrough)
        result += "</del>"
    }

    mutating func visitLink(_ link: Link) -> () {
        let dest = link.destination ?? ""
        result += "<a href=\"\(Self.escapeHTML(dest))\">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitImage(_ image: Image) -> () {
        let src = image.source ?? ""
        let alt = image.plainText
        result += "<img src=\"\(Self.escapeHTML(src))\" alt=\"\(Self.escapeHTML(alt))\" />"
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> () {
        result += html.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> () {
        result += "<br />\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> () {
        if hardWrap {
            result += "<br />\n"
        } else {
            result += "\n"
        }
    }
}

// MARK: - Plaintext Renderer

/// Walks the swift-markdown AST and extracts plain text content.
private struct PlaintextRenderer: MarkupWalker {
    var result = ""

    mutating func visitText(_ text: Text) -> () {
        result += text.string
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> () {
        result += inlineCode.code
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> () {
        result += codeBlock.code
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> () {
        result += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> () {
        result += "\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> () {
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            if result.hasSuffix("\n") {
                result += "\n"
            } else {
                result += "\n\n"
            }
        }
        descendInto(paragraph)
    }

    mutating func visitHeading(_ heading: Heading) -> () {
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        descendInto(heading)
        result += "\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> () {
        descendInto(listItem)
        if !result.hasSuffix("\n") {
            result += "\n"
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> () {
        descendInto(blockQuote)
    }

    mutating func visitLink(_ link: Link) -> () {
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) -> () {
        result += image.plainText
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> () {
        descendInto(strikethrough)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> () {
        descendInto(emphasis)
    }

    mutating func visitStrong(_ strong: Strong) -> () {
        descendInto(strong)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> () {
        result += "\n"
    }

    mutating func visitTable(_ table: Markdown.Table) -> () {
        descendInto(table)
    }

    mutating func visitTableHead(_ tableHead: Markdown.Table.Head) -> () {
        descendInto(tableHead)
    }

    mutating func visitTableBody(_ tableBody: Markdown.Table.Body) -> () {
        descendInto(tableBody)
    }

    mutating func visitTableRow(_ tableRow: Markdown.Table.Row) -> () {
        descendInto(tableRow)
        if !result.hasSuffix("\n") {
            result += "\n"
        }
    }

    mutating func visitTableCell(_ cell: Markdown.Table.Cell) -> () {
        descendInto(cell)
        result += " "
    }
}

// MARK: - Conversion

private func convertMarkdown(_ input: String, mode: ModeType) -> String {
    let options: ParseOptions = [.parseBlockDirectives]
    let document = Document(parsing: input, options: options)

    switch mode {
    case .markdown, .gfm:
        let hardWrap = (mode == .gfm)
        var renderer = HTMLRenderer(hardWrap: hardWrap)
        renderer.visit(document)
        return renderer.result
    case .plaintext:
        var renderer = PlaintextRenderer()
        renderer.visit(document)
        return renderer.result
    }
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
private func markdown_convert(_ L: LuaState) throws -> CInt {
    let t1 = lua_type(L, 1)
    guard t1 == LUA_TSTRING else {
        throw LuaCallError("bad argument #1 (expected string)")
    }

    var mode: ModeType = .gfm
    if lua_gettop(L) >= 2 && lua_type(L, 2) == LUA_TSTRING {
        let modeString = String(cString: lua_tostring(L, 2)!)
        if modeString == "gfm" {
            mode = .gfm
        } else if modeString == "markdown" || modeString == "readme" {
            mode = .markdown
        } else if modeString == "plaintext" {
            mode = .plaintext
        } else {
            throw LuaCallError("bad argument #2 (invalid mode, \(modeString), specified)")
        }
    }

    // Get input as raw bytes and convert to String
    var sz: Int = 0
    let rawPtr = lua_tolstring(L, 1, &sz)!
    let inputData = Data(bytes: rawPtr, count: sz)
    let inputString = String(data: inputData, encoding: .utf8) ?? ""

    let output = convertMarkdown(inputString, mode: mode)

    // Push result as raw bytes to preserve exact byte output
    let outputData = output.data(using: .utf8) ?? Data()
    outputData.withUnsafeBytes { ptr in
        if let base = ptr.baseAddress {
            lua_pushlstring(L, base.assumingMemoryBound(to: CChar.self), outputData.count)
        } else {
            lua_pushlstring(L, "", 0)
        }
    }

    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

@_cdecl("luaopen_hs_libmarkdown")
public func luaopen_hs_libmarkdown(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 1)
        L.push(markdown_convert)
        lua_setfield(L, -2, "convert")
    }
}
