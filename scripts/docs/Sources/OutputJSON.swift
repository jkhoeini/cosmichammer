import Foundation

/// Custom JSON serializer that matches Python's json.dumps output exactly:
/// - sort_keys=True (case-sensitive ASCII sort, uppercase before lowercase)
/// - indent=2
/// - separators=(",", ": ") — comma with no trailing space at line breaks, colon with trailing space
/// - ensure_ascii=False (pass through Unicode)
func serializeJSON(_ value: Any, indent: Int = 0) -> String {
    let indentStr = String(repeating: " ", count: indent)
    let nextIndent = indent + 2
    let nextIndentStr = String(repeating: " ", count: nextIndent)

    if let dict = value as? [String: Any] {
        if dict.isEmpty {
            return "{}"
        }
        // Sort keys with case-sensitive ASCII ordering (uppercase before lowercase)
        let sortedKeys = dict.keys.sorted { a, b in
            a.compare(b, options: [], range: nil, locale: nil) == .orderedAscending
        }
        var parts: [String] = []
        for key in sortedKeys {
            let keyJSON = serializeJSONString(key)
            let valJSON = serializeJSON(dict[key]!, indent: nextIndent)
            parts.append("\(nextIndentStr)\(keyJSON): \(valJSON)")
        }
        return "{\n\(parts.joined(separator: ",\n"))\n\(indentStr)}"
    }

    if let arr = value as? [Any] {
        if arr.isEmpty {
            return "[]"
        }
        var parts: [String] = []
        for element in arr {
            parts.append("\(nextIndentStr)\(serializeJSON(element, indent: nextIndent))")
        }
        return "[\n\(parts.joined(separator: ",\n"))\n\(indentStr)]"
    }

    if let str = value as? String {
        return serializeJSONString(str)
    }

    if let num = value as? Int {
        return "\(num)"
    }

    if let num = value as? Double {
        return "\(num)"
    }

    if let b = value as? Bool {
        return b ? "true" : "false"
    }

    if value is NSNull {
        return "null"
    }

    // Fallback: try NSNumber (for integers that come through as NSNumber)
    if let num = value as? NSNumber {
        return "\(num)"
    }

    return "null"
}

/// Serialize a string to JSON with proper escaping.
/// Iterates over Unicode scalars to handle combining characters correctly.
private func serializeJSONString(_ str: String) -> String {
    var result = "\""
    for scalar in str.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if scalar.value < 0x20 {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                // ensure_ascii=False: pass through all non-control chars including Unicode
                result.unicodeScalars.append(scalar)
            }
        }
    }
    result += "\""
    return result
}

/// Write docs.json
func writeJSON(to path: String, data: [[String: Any]]) {
    let jsonString = serializeJSON(data as [Any])

    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    do {
        try jsonString.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        fatal("Failed to write JSON to \(path): \(error)")
    }
}

/// Write docs_index.json
func writeJSONIndex(to path: String, data: [[String: Any]]) {
    var index: [[String: Any]] = []

    for item in data {
        guard let name = item["name"] as? String,
              let desc = item["desc"] as? String,
              let type = item["type"] as? String else { continue }

        var entry: [String: Any] = [:]
        entry["name"] = name
        entry["desc"] = desc
        entry["type"] = type
        index.append(entry)

        for subtype in typeNames {
            guard let subitems = item[subtype] as? [[String: Any]] else { continue }
            for subitem in subitems {
                guard let subName = subitem["name"] as? String,
                      let subDesc = subitem["desc"] as? String,
                      let subType = subitem["type"] as? String else { continue }

                var subEntry: [String: Any] = [:]
                subEntry["name"] = subName
                subEntry["module"] = name
                subEntry["desc"] = subDesc
                subEntry["type"] = subType
                index.append(subEntry)
            }
        }
    }

    let jsonString = serializeJSON(index as [Any])

    do {
        try jsonString.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        fatal("Failed to write JSON index to \(path): \(error)")
    }
}

/// Write annotations JSON (used for lint output)
func fixJSONFormatting(_ json: String) -> String {
    var result = json
    result = result.replacingOccurrences(of: "\" : ", with: "\": ")
    if let regex = try? NSRegularExpression(pattern: "\\[\\s*\\]", options: []) {
        let nsRange = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: nsRange, withTemplate: "[]")
    }
    return result
}
