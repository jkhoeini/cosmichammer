import Foundation

/// Recursively find all .m, .lua, and .swift files in a directory.
/// Matches Python's os.walk behavior for path construction:
/// - Root directory preserves its original formatting (including trailing slash)
/// - Subdirectories are joined with os.path.join semantics (normalized)
func findCodeFiles(in path: String) -> [String] {
    var codeFiles: [String] = []
    let fileManager = FileManager.default

    // Use os.walk-like enumeration to match Python's path joining behavior
    enumerateDirectory(path, fileManager: fileManager, codeFiles: &codeFiles)

    return codeFiles
}

private func enumerateDirectory(_ dirpath: String, fileManager: FileManager, codeFiles: inout [String]) {
    dbg("Entering: \(dirpath)")

    // Resolve symlinks/normalize for directory listing, but keep dirpath as-is for path construction
    let resolvedPath: String
    if dirpath.hasSuffix("/") {
        resolvedPath = String(dirpath.dropLast())
    } else {
        resolvedPath = dirpath
    }

    guard let contents = try? fileManager.contentsOfDirectory(atPath: resolvedPath) else {
        return
    }

    var files: [String] = []
    var subdirs: [String] = []

    for entry in contents {
        let checkPath = resolvedPath + "/" + entry
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: checkPath, isDirectory: &isDir) {
            if isDir.boolValue {
                subdirs.append(entry)
            } else {
                files.append(entry)
            }
        }
    }

    for filename in files.sorted() {
        if isCodeFile(filename) {
            // Match Python: dirpath + "/" + filename
            // For root dir with trailing slash, this produces e.g. "Cosmic Hammer//file.m"
            // For subdirs (no trailing slash), this produces normal paths
            let fullPath = dirpath + "/" + filename
            dbg("  Found file: \(fullPath)")
            codeFiles.append(fullPath)
        }
    }

    for subdir in subdirs.sorted() {
        // Python's os.walk normalizes subdirectory paths (no trailing slash from root propagated)
        // os.walk joins: os.path.join(top, subdir) which normalizes
        let subdirPath = resolvedPath + "/" + subdir
        enumerateDirectory(subdirPath, fileManager: fileManager, codeFiles: &codeFiles)
    }
}

private func isCodeFile(_ filename: String) -> Bool {
    filename.hasSuffix(".m") || filename.hasSuffix(".lua") || filename.hasSuffix(".swift")
}

/// Extract docstrings from a source file.
/// Returns array of chunks where each chunk is [filename, lineNumber, line1, line2, ...]
func extractDocstrings(from filename: String) -> [[String]] {
    var docstrings: [[String]] = []
    var isInChunk = false
    var chunk: [String]? = nil
    var i = 0
    let isSwift = URL(fileURLWithPath: filename).pathExtension == "swift"

    func appendChunkIfNeeded() {
        guard let c = chunk else { return }
        if isSwift {
            guard c.count > CHUNK_SIGN else { return }
            let firstDocLine = c[CHUNK_SIGN]
            guard firstDocLine.hasPrefix("===") || firstDocLine.hasPrefix("hs.") else {
                dbg("Skipping non-API Swift docstring: \(filename):\(c[CHUNK_LINE])")
                return
            }
            if firstDocLine.hasPrefix("hs."), c.count <= CHUNK_DESC {
                dbg("Skipping incomplete Swift API docstring: \(filename):\(c[CHUNK_LINE])")
                return
            }
            if firstDocLine.hasPrefix("hs."),
               c.count > CHUNK_TYPE,
               ["Function", "Constructor", "Method"].contains(c[CHUNK_TYPE]),
               !c.contains("Returns:"),
               !(c.count > CHUNK_DESC && c[CHUNK_DESC].hasPrefix("Alias for [`")) {
                dbg("Skipping Swift callable docstring without Returns: \(filename):\(c[CHUNK_LINE])")
                return
            }
        }
        docstrings.append(c)
    }

    guard let fileContent = try? String(contentsOfFile: filename, encoding: .utf8) else {
        warn("Unable to read file: \(filename)")
        return docstrings
    }

    let lines = fileContent.components(separatedBy: "\n")
    // If the file ends with a newline, components will produce an extra empty string at the end.
    // The Python code reads lines including the \n, then strips \n.
    // We need to process lines as Python's readlines() would produce them.
    // Python's readlines() on "a\nb\n" gives ["a\n", "b\n"], and on "a\nb" gives ["a\n", "b"].
    // Our components(separatedBy:) on "a\nb\n" gives ["a", "b", ""], and on "a\nb" gives ["a", "b"].
    // We need to handle the trailing empty component: if the file ends with \n, drop the last empty element.
    var processLines = lines
    if fileContent.hasSuffix("\n") && processLines.last == "" {
        processLines.removeLast()
    }

    for line in processLines {
        i += 1
        let matchLine = isSwift ? line.trimmingCharacters(in: .whitespaces) : line
        if matchLine.hasPrefix("----") || matchLine.hasPrefix("////") {
            dbg("Skipping \(filename):\(i) - too many comment chars")
            continue
        }
        if matchLine.hasPrefix("---") || matchLine.hasPrefix("///") {
            if !isInChunk {
                isInChunk = true
                chunk = []
                chunk!.append(filename)
                chunk!.append("\(i)")
            }
            // Strip leading and trailing / and - characters (matches Python's str.strip("/-"))
            var stripped = matchLine
            while stripped.hasPrefix("/") || stripped.hasPrefix("-") {
                stripped = String(stripped.dropFirst())
            }
            while stripped.hasSuffix("/") || stripped.hasSuffix("-") {
                stripped = String(stripped.dropLast())
            }
            // Remove at most one leading space
            if stripped.hasPrefix(" ") {
                stripped = String(stripped.dropFirst())
            }
            chunk!.append(stripped)
        } else {
            if isInChunk {
                appendChunkIfNeeded()
                isInChunk = false
                chunk = nil
            }
        }
    }

    if isInChunk {
        appendChunkIfNeeded()
    }

    return docstrings
}
