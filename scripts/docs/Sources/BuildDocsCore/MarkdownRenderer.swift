import Foundation

/// Cached check for whether cmark is available
private var cmarkAvailable: Bool? = nil
private var cmarkPath: String? = nil

private func findCmark() -> String? {
    if let cached = cmarkAvailable {
        return cached ? cmarkPath : nil
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", "cmark"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty {
                cmarkAvailable = true
                cmarkPath = path
                dbg("Found cmark at: \(path)")
                return path
            }
        }
    } catch {}

    cmarkAvailable = false
    cmarkPath = nil
    dbg("cmark not found, using built-in renderer")
    return nil
}

/// Render Markdown text to HTML.
/// Tries to use `cmark` from PATH first; falls back to a built-in subset renderer.
func renderMarkdown(_ input: String) -> String {
    if let path = findCmark(), let result = renderWithCmark(input, path: path) {
        return result
    }
    return renderMarkdownBuiltin(input)
}

/// Strip `<p>` from start and `</p>\n` from end
func stripParagraph(_ text: String) -> String {
    var result = text
    result = result.replacingOccurrences(of: "<p>", with: "")
    result = result.replacingOccurrences(of: "</p>\n", with: "")
    return result
}

// MARK: - cmark

private func renderWithCmark(_ input: String, path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--unsafe"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return nil
    }

    stdinPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
    stdinPipe.fileHandleForWriting.closeFile()

    process.waitUntilExit()

    if process.terminationStatus != 0 {
        return nil
    }

    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: outputData, encoding: .utf8)
}

// MARK: - Built-in Markdown Renderer

private func renderMarkdownBuiltin(_ input: String) -> String {
    let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var result = ""
    var i = 0
    var paragraphLines: [String] = []

    func flushParagraph() {
        if !paragraphLines.isEmpty {
            let text = paragraphLines.joined(separator: "\n")
            result += "<p>" + renderInline(text) + "</p>\n"
            paragraphLines = []
        }
    }

    while i < lines.count {
        let line = lines[i]

        // Fenced code block
        if line.hasPrefix("```") {
            flushParagraph()
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count && !lines[i].hasPrefix("```") {
                codeLines.append(lines[i])
                i += 1
            }
            if i < lines.count { i += 1 } // skip closing ```
            let code = escapeHTML(codeLines.joined(separator: "\n"))
            if !lang.isEmpty {
                result += "<pre><code class=\"language-\(lang)\">\(code)\n</code></pre>\n"
            } else {
                result += "<pre><code>\(code)\n</code></pre>\n"
            }
            continue
        }

        // Headers
        if line.hasPrefix("#") {
            flushParagraph()
            var level = 0
            var idx = line.startIndex
            while idx < line.endIndex && line[idx] == "#" {
                level += 1
                idx = line.index(after: idx)
            }
            let headerText = String(line[idx...]).trimmingCharacters(in: .whitespaces)
            result += "<h\(level)>\(renderInline(headerText))</h\(level)>\n"
            i += 1
            continue
        }

        // Unordered list items
        if line.hasPrefix("* ") || line.hasPrefix("- ") {
            flushParagraph()
            result += "<ul>\n"
            while i < lines.count && (lines[i].hasPrefix("* ") || lines[i].hasPrefix("- ") || lines[i].hasPrefix("  ")) {
                let listLine = lines[i]
                if listLine.hasPrefix("* ") || listLine.hasPrefix("- ") {
                    let itemText = String(listLine.dropFirst(2))
                    result += "<li>\(renderInline(itemText))</li>\n"
                }
                // Sub-items or continuations — append to previous for simplicity
                i += 1
            }
            result += "</ul>\n"
            continue
        }

        // Blank line
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            flushParagraph()
            i += 1
            continue
        }

        // Regular text — accumulate for paragraph
        paragraphLines.append(line)
        i += 1
    }

    flushParagraph()
    return result
}

private func renderInline(_ text: String) -> String {
    var result = text

    // Code spans: `code`
    result = replacePattern(result, pattern: "`([^`]+)`") { match in
        "<code>\(escapeHTML(match))</code>"
    }

    // Bold: **text**
    result = replacePattern(result, pattern: "\\*\\*(.+?)\\*\\*") { match in
        "<strong>\(match)</strong>"
    }

    // Italic: *text*
    result = replacePattern(result, pattern: "\\*(.+?)\\*") { match in
        "<em>\(match)</em>"
    }

    // Links: [text](url)
    result = replaceLinkPattern(result)

    return result
}

private func replacePattern(_ input: String, pattern: String, replacement: (String) -> String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return input
    }
    var result = input
    let nsRange = NSRange(result.startIndex..., in: result)
    let matches = regex.matches(in: result, options: [], range: nsRange)

    // Process matches in reverse to preserve indices
    for match in matches.reversed() {
        guard let fullRange = Range(match.range, in: result),
              let captureRange = Range(match.range(at: 1), in: result) else { continue }
        let captured = String(result[captureRange])
        result.replaceSubrange(fullRange, with: replacement(captured))
    }
    return result
}

private func replaceLinkPattern(_ input: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", options: []) else {
        return input
    }
    var result = input
    let nsRange = NSRange(result.startIndex..., in: result)
    let matches = regex.matches(in: result, options: [], range: nsRange)

    for match in matches.reversed() {
        guard let fullRange = Range(match.range, in: result),
              let textRange = Range(match.range(at: 1), in: result),
              let urlRange = Range(match.range(at: 2), in: result) else { continue }
        let text = String(result[textRange])
        let url = String(result[urlRange])
        result.replaceSubrange(fullRange, with: "<a href=\"\(url)\">\(text)</a>")
    }
    return result
}

private func escapeHTML(_ text: String) -> String {
    var result = text
    result = result.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    result = result.replacingOccurrences(of: "\"", with: "&quot;")
    return result
}
