import Foundation

/// A minimal Jinja2-like template engine
func renderTemplate(_ template: String, context: [String: Any]) -> String {
    let cleaned = stripComments(template)
    return renderBlock(cleaned, context: context)
}

// MARK: - Comment Stripping

private func stripComments(_ template: String) -> String {
    var result = ""
    var i = template.startIndex
    while i < template.endIndex {
        if template[i] == "{",
           template.index(after: i) < template.endIndex,
           template[template.index(after: i)] == "#" {
            // Find closing #}
            if let closeRange = template.range(of: "#}", range: template.index(i, offsetBy: 2)..<template.endIndex) {
                // Skip everything from {# to #}
                // Also consume a trailing newline if present
                var afterClose = closeRange.upperBound
                if afterClose < template.endIndex && template[afterClose] == "\n" {
                    afterClose = template.index(after: afterClose)
                }
                i = afterClose
                continue
            }
        }
        result.append(template[i])
        i = template.index(after: i)
    }
    return result
}

// MARK: - Block Rendering

private func renderBlock(_ text: String, context: [String: Any]) -> String {
    var result = ""
    var i = text.startIndex

    while i < text.endIndex {
        // Check for {% tag
        if i < text.endIndex,
           text[i] == "{",
           text.index(after: i) < text.endIndex,
           text[text.index(after: i)] == "%" {
            // Find the closing %}
            guard let closeRange = text.range(of: "%}", range: text.index(i, offsetBy: 2)..<text.endIndex) else {
                result.append(text[i])
                i = text.index(after: i)
                continue
            }
            let tagContent = String(text[text.index(i, offsetBy: 2)..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)

            // Determine if this is a for or if block
            if tagContent.hasPrefix("for ") {
                // Parse: for varname in collection
                let (body, afterEnd) = extractBlock(text, from: closeRange.upperBound, endTag: "endfor")
                let parts = tagContent.split(separator: " ", maxSplits: 3)
                // parts: ["for", varname, "in", collection]
                if parts.count >= 4 {
                    let varname = String(parts[1])
                    let collectionExpr = String(parts[3])
                    let collection = resolveExpression(collectionExpr, context: context)

                    if let arr = toArray(collection) {
                        for element in arr {
                            var innerContext = context
                            innerContext[varname] = element
                            // Consume leading newline after {% for %}
                            var bodyStr = body
                            if bodyStr.hasPrefix("\n") {
                                bodyStr = String(bodyStr.dropFirst())
                            }
                            result += renderBlock(bodyStr, context: innerContext)
                        }
                    }
                }
                i = afterEnd
                // Consume trailing newline after {% endfor %}
                if i < text.endIndex && text[i] == "\n" {
                    i = text.index(after: i)
                }
                continue

            } else if tagContent.hasPrefix("if ") {
                let condition = String(tagContent.dropFirst(3))
                let (body, afterEnd) = extractBlock(text, from: closeRange.upperBound, endTag: "endif")

                if evaluateCondition(condition, context: context) {
                    var bodyStr = body
                    if bodyStr.hasPrefix("\n") {
                        bodyStr = String(bodyStr.dropFirst())
                    }
                    result += renderBlock(bodyStr, context: context)
                }
                i = afterEnd
                // Consume trailing newline after {% endif %}
                if i < text.endIndex && text[i] == "\n" {
                    i = text.index(after: i)
                }
                continue
            }

            // Unknown tag, skip past it
            i = closeRange.upperBound
            if i < text.endIndex && text[i] == "\n" {
                i = text.index(after: i)
            }
            continue

        } else if i < text.endIndex,
                  text[i] == "{",
                  text.index(after: i) < text.endIndex,
                  text[text.index(after: i)] == "{" {
            // Variable interpolation {{ expr }}
            guard let closeRange = text.range(of: "}}", range: text.index(i, offsetBy: 2)..<text.endIndex) else {
                result.append(text[i])
                i = text.index(after: i)
                continue
            }
            let expr = String(text[text.index(i, offsetBy: 2)..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = resolveExpressionWithFilters(expr, context: context)
            result += stringify(value)
            i = closeRange.upperBound
            continue
        }

        result.append(text[i])
        i = text.index(after: i)
    }

    return result
}

// MARK: - Block Extraction

/// Find the matching endTag for a block, handling nesting
private func extractBlock(_ text: String, from start: String.Index, endTag: String) -> (String, String.Index) {
    let openTag: String
    if endTag == "endfor" {
        openTag = "for "
    } else {
        openTag = "if "
    }

    var depth = 1
    var i = start
    while i < text.endIndex {
        if text[i] == "{",
           text.index(after: i) < text.endIndex,
           text[text.index(after: i)] == "%" {
            guard let closeRange = text.range(of: "%}", range: text.index(i, offsetBy: 2)..<text.endIndex) else {
                i = text.index(after: i)
                continue
            }
            let tag = String(text[text.index(i, offsetBy: 2)..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if tag.hasPrefix(openTag) {
                depth += 1
            } else if tag == endTag {
                depth -= 1
                if depth == 0 {
                    let body = String(text[start..<i])
                    return (body, closeRange.upperBound)
                }
            }
            i = closeRange.upperBound
            continue
        }
        i = text.index(after: i)
    }

    // No matching end tag found, return rest of text
    return (String(text[start...]), text.endIndex)
}

// MARK: - Expression Resolution

private func resolveExpression(_ expr: String, context: [String: Any]) -> Any? {
    let trimmed = expr.trimmingCharacters(in: .whitespaces)

    // String literal
    if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
        return String(trimmed.dropFirst().dropLast())
    }

    // Dot access and bracket access: e.g. module.name, module["submodules"]
    // First, check for bracket access: expr["key"] or expr[variable]
    if let bracketStart = trimmed.firstIndex(of: "["),
       trimmed.hasSuffix("]") {
        let baseExpr = String(trimmed[..<bracketStart])
        let keyPart = String(trimmed[trimmed.index(after: bracketStart)..<trimmed.index(before: trimmed.endIndex)])

        let key: String
        if (keyPart.hasPrefix("\"") && keyPart.hasSuffix("\"")) ||
           (keyPart.hasPrefix("'") && keyPart.hasSuffix("'")) {
            // String literal key
            key = String(keyPart.dropFirst().dropLast())
        } else {
            // Variable key — resolve it
            key = stringify(resolveExpression(keyPart, context: context))
        }

        let base = resolveExpression(baseExpr, context: context)
        return resolveKey(key, on: base)
    }

    // Dot access
    let parts = trimmed.split(separator: ".", maxSplits: 1)
    if parts.count == 2 {
        let base = resolveExpression(String(parts[0]), context: context)
        return resolveKey(String(parts[1]), on: base)
    }

    // Simple variable lookup
    return context[trimmed]
}

private func resolveKey(_ key: String, on value: Any?) -> Any? {
    guard let value = value else { return nil }

    // Further dot access
    if key.contains(".") {
        let parts = key.split(separator: ".", maxSplits: 1)
        let base = resolveKey(String(parts[0]), on: value)
        return resolveKey(String(parts[1]), on: base)
    }

    // Bracket access within a key
    if let bracketStart = key.firstIndex(of: "["),
       key.hasSuffix("]") {
        let baseKey = String(key[..<bracketStart])
        let innerKey = String(key[key.index(after: bracketStart)..<key.index(before: key.endIndex)])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let base = resolveKey(baseKey, on: value)
        return resolveKey(innerKey, on: base)
    }

    if let dict = value as? [String: Any] {
        return dict[key]
    }
    if let dict = value as? [String: String] {
        return dict[key]
    }

    return nil
}

private func resolveExpressionWithFilters(_ expr: String, context: [String: Any]) -> Any? {
    // Check for filters: expr | filter
    // But be careful: " * " contains |, so we need to handle this correctly
    // Filters are: |length, |replace("a", "b")
    // We split on | that is not inside quotes

    let (baseExpr, filters) = splitFilters(expr)
    var value = resolveExpression(baseExpr, context: context)

    for filter in filters {
        value = applyFilter(filter, to: value)
    }

    return value
}

private func splitFilters(_ expr: String) -> (String, [String]) {
    var filters: [String] = []
    var base = ""
    var inQuotes = false
    var quoteChar: Character = "\""
    var depth = 0
    var current = ""
    var foundPipe = false

    for char in expr {
        if inQuotes {
            current.append(char)
            if char == quoteChar {
                inQuotes = false
            }
            continue
        }
        if char == "\"" || char == "'" {
            inQuotes = true
            quoteChar = char
            current.append(char)
            continue
        }
        if char == "(" {
            depth += 1
            current.append(char)
            continue
        }
        if char == ")" {
            depth -= 1
            current.append(char)
            continue
        }
        if char == "|" && depth == 0 {
            if !foundPipe {
                base = current.trimmingCharacters(in: .whitespaces)
                foundPipe = true
            } else {
                filters.append(current.trimmingCharacters(in: .whitespaces))
            }
            current = ""
            continue
        }
        current.append(char)
    }

    if foundPipe {
        filters.append(current.trimmingCharacters(in: .whitespaces))
    } else {
        base = current.trimmingCharacters(in: .whitespaces)
    }

    return (base, filters)
}

private func applyFilter(_ filter: String, to value: Any?) -> Any? {
    if filter == "length" {
        return lengthOf(value)
    }

    // replace("old", "new")
    if filter.hasPrefix("replace(") && filter.hasSuffix(")") {
        let argsStr = String(filter.dropFirst(8).dropLast())
        // Parse two string arguments
        let args = parseFilterArgs(argsStr)
        if args.count == 2, let str = value as? String {
            return str.replacingOccurrences(of: args[0], with: args[1])
        }
        return value
    }

    return value
}

private func parseFilterArgs(_ str: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inQuotes = false
    var quoteChar: Character = "\""
    var expectingComma = false

    for char in str {
        if expectingComma {
            if char == "," || char == " " {
                if char == "," { expectingComma = false }
                continue
            }
            expectingComma = false
        }
        if !inQuotes {
            if char == "\"" || char == "'" {
                inQuotes = true
                quoteChar = char
                continue
            }
            continue
        } else {
            if char == quoteChar {
                inQuotes = false
                args.append(current)
                current = ""
                expectingComma = true
                continue
            }
            current.append(char)
        }
    }
    return args
}

// MARK: - Condition Evaluation

private func evaluateCondition(_ condition: String, context: [String: Any]) -> Bool {
    let trimmed = condition.trimmingCharacters(in: .whitespaces)

    // Handle "or"
    // Split on " or " but not inside quotes
    let orParts = splitOnOperator(trimmed, operator: " or ")
    if orParts.count > 1 {
        for part in orParts {
            if evaluateCondition(part, context: context) {
                return true
            }
        }
        return false
    }

    // Handle "key" in dict
    if let inRange = trimmed.range(of: " in ") {
        let leftExpr = String(trimmed[..<inRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rightExpr = String(trimmed[inRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        let key: String
        if leftExpr.hasPrefix("\"") && leftExpr.hasSuffix("\"") {
            key = String(leftExpr.dropFirst().dropLast())
        } else {
            key = stringify(resolveExpression(leftExpr, context: context))
        }

        let collection = resolveExpression(rightExpr, context: context)
        if let dict = collection as? [String: Any] {
            return dict[key] != nil
        }
        if let arr = collection as? [String] {
            return arr.contains(key)
        }
        return false
    }

    // Handle == comparison
    if let eqRange = trimmed.range(of: " == ") {
        let leftExpr = String(trimmed[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rightExpr = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        let leftVal = resolveExpressionWithFilters(leftExpr, context: context)
        let rightVal = resolveExpressionWithFilters(rightExpr, context: context)

        return stringify(leftVal) == stringify(rightVal)
    }

    // Handle |length > 0
    if let gtRange = trimmed.range(of: "|length > ") {
        let expr = String(trimmed[..<gtRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let numStr = String(trimmed[gtRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let num = Int(numStr) ?? 0
        let value = resolveExpression(expr, context: context)
        let len = lengthOf(value)
        return len > num
    }

    // Just a variable name / expression — truthy check
    let value = resolveExpressionWithFilters(trimmed, context: context)
    return isTruthy(value)
}

private func splitOnOperator(_ str: String, operator op: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inQuotes = false
    var quoteChar: Character = "\""
    var i = str.startIndex

    while i < str.endIndex {
        if inQuotes {
            if str[i] == quoteChar {
                inQuotes = false
            }
            current.append(str[i])
            i = str.index(after: i)
            continue
        }
        if str[i] == "\"" || str[i] == "'" {
            inQuotes = true
            quoteChar = str[i]
            current.append(str[i])
            i = str.index(after: i)
            continue
        }
        // Check for operator
        if str[i...].hasPrefix(op) {
            parts.append(current)
            current = ""
            i = str.index(i, offsetBy: op.count)
            continue
        }
        current.append(str[i])
        i = str.index(after: i)
    }
    parts.append(current)
    return parts
}

// MARK: - Helpers

private func toArray(_ value: Any?) -> [Any]? {
    if let arr = value as? [Any] { return arr }
    if let arr = value as? [[String: Any]] { return arr }
    if let arr = value as? [[String: String]] { return arr }
    if let arr = value as? [String] { return arr }
    return nil
}

private func lengthOf(_ value: Any?) -> Int {
    if let arr = value as? [Any] { return arr.count }
    if let arr = value as? [[String: Any]] { return arr.count }
    if let arr = value as? [[String: String]] { return arr.count }
    if let arr = value as? [String] { return arr.count }
    if let str = value as? String { return str.count }
    if let dict = value as? [String: Any] { return dict.count }
    return 0
}

private func isTruthy(_ value: Any?) -> Bool {
    guard let value = value else { return false }
    if let b = value as? Bool { return b }
    if let i = value as? Int { return i != 0 }
    if let s = value as? String { return !s.isEmpty }
    if let arr = value as? [Any] { return !arr.isEmpty }
    if let arr = value as? [String] { return !arr.isEmpty }
    if let dict = value as? [String: Any] { return !dict.isEmpty }
    return true
}

func stringify(_ value: Any?) -> String {
    guard let value = value else { return "" }
    if let s = value as? String { return s }
    if let i = value as? Int { return "\(i)" }
    if let b = value as? Bool { return b ? "True" : "False" }
    if let arr = value as? [String] { return arr.joined(separator: ", ") }
    return "\(value)"
}
