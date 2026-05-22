import Foundation

// MARK: - Constants

let typeNames = [
    "Deprecated",
    "Command",
    "Constant",
    "Variable",
    "Function",
    "Constructor",
    "Field",
    "Method",
]

let sectionNames = ["Parameters", "Returns", "Notes", "Examples"]

let typeDesc: [String: String] = [
    "Constant": "Useful values which cannot be changed",
    "Variable": "Configurable values",
    "Function": "API calls offered directly by the extension",
    "Method": "API calls which can only be made on an object returned by a constructor",
    "Constructor": "API calls which return an object, typically one that offers API methods",
    "Command": "External shell commands",
    "Field": "Variables which can only be accessed from an object returned by a constructor",
    "Deprecated": "API features which will be removed in an future release",
]

let links: [[String: String]] = [
    ["name": "Website", "url": "https://www.cosmichammer.org/"],
    ["name": "GitHub page", "url": "https://github.com/cosmichammer/cosmic-hammer"],
    ["name": "Getting Started Guide", "url": "https://www.cosmichammer.org/go/"],
    ["name": "Spoon Plugin Documentation", "url": "https://github.com/cosmichammer/cosmic-hammer/blob/master/SPOONS.md"],
    ["name": "Official Spoon repository", "url": "https://www.cosmichammer.org/Spoons"],
    ["name": "Discord server", "url": "https://discord.gg/vxchqkRbkR"],
    ["name": "LuaSkin API docs", "url": "https://www.cosmichammer.org/docs/LuaSkin/"],
]

// MARK: - Chunk indices

let CHUNK_FILE = 0
let CHUNK_LINE = 1
let CHUNK_SIGN = 2
let CHUNK_TYPE = 3
let CHUNK_DESC = 4

// MARK: - Data Model

struct LintError {
    let file: String
    let line: Int
    let title: String
    let message: String
    let annotationLevel: String

    func toDictionary() -> [String: Any] {
        return [
            "annotation_level": annotationLevel,
            "file": file,
            "line": line,
            "message": message,
            "title": title,
        ]
    }
}

struct DocItem {
    var name: String
    var signature: String
    var def: String
    var type: String
    var desc: String
    var doc: String
    var strippedDoc: String
    var file: String
    var lineno: String
    var parameters: [String]?
    var returns: [String]?
    var notes: [String]?
    var examples: [String]?

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "signature": signature,
            "def": def,
            "type": type,
            "desc": desc,
            "doc": doc,
            "stripped_doc": strippedDoc,
            "file": file,
            "lineno": lineno,
        ]
        if let p = parameters {
            dict["parameters"] = p
        }
        if let r = returns {
            dict["returns"] = r
        }
        if let n = notes {
            dict["notes"] = n
        }
        if let e = examples {
            dict["examples"] = e
        }
        return dict
    }
}

struct DocModule {
    var name: String
    var type: String = "Module"
    var desc: String
    var doc: String
    var strippedDoc: String
    var submodules: [String] = []
    var items: [DocItem] = []
    var itemsByType: [String: [DocItem]] = [:]

    init(name: String, desc: String, doc: String, strippedDoc: String) {
        self.name = name
        self.desc = desc
        self.doc = doc
        self.strippedDoc = strippedDoc
        for t in typeNames {
            itemsByType[t] = []
        }
    }

    mutating func addItem(_ item: DocItem) {
        items.append(item)
        itemsByType[item.type, default: []].append(item)
    }

    mutating func sortItems(ofType typeName: String) {
        itemsByType[typeName]?.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "type": type,
            "desc": desc,
            "doc": doc,
            "stripped_doc": strippedDoc,
            "submodules": submodules,
            "items": items.map { $0.toDictionary() },
        ]
        for t in typeNames {
            dict[t] = (itemsByType[t] ?? []).map { $0.toDictionary() }
        }
        return dict
    }
}

class RawModule {
    var header: [String]
    var items: OrderedDict = OrderedDict()

    init(header: [String]) {
        self.header = header
    }
}

/// Ordered dictionary that preserves insertion order but overwrites on duplicate keys
/// (matching Python dict behavior)
class OrderedDict {
    private(set) var keys: [String] = []
    private var dict: [String: [String]] = [:]

    subscript(key: String) -> [String]? {
        get { dict[key] }
        set {
            if let val = newValue {
                if dict[key] == nil {
                    keys.append(key)
                }
                dict[key] = val
            } else {
                keys.removeAll { $0 == key }
                dict.removeValue(forKey: key)
            }
        }
    }

    var pairs: [(String, [String])] {
        return keys.map { ($0, dict[$0]!) }
    }

    var isEmpty: Bool { keys.isEmpty }
}

// MARK: - Processing Functions

func findItemnameFromSignature(_ signature: String) -> String {
    // Split on ( [ or whitespace, take first part
    var result = ""
    for char in signature {
        if char == "(" || char == "[" || char == " " {
            break
        }
        result.append(char)
    }
    return result
}

func removeMethodFromItemname(_ itemname: String) -> String {
    if let idx = itemname.firstIndex(of: ":") {
        return String(itemname[..<idx])
    }
    return itemname
}

func findBasenameFromItemname(_ itemname: String) -> String {
    let splitchar: Character = itemname.contains(":") ? ":" : "."
    let lastPart = itemname.split(separator: splitchar).last.map(String.init) ?? itemname
    return lastPart.split(separator: " ").first.map(String.init) ?? lastPart
}

func findModuleForItem(modules: [String], item: String, standalone: Bool) -> String {
    dbg("find_module_for_item: Searching for: \(item)")

    // Root level items shortcut
    if !standalone && item.filter({ $0 == "." }).count == 1 && !item.contains(":") {
        dbg("find_module_for_item: Using root-level shortcut")
        return "hs"
    }

    // Methods shortcut
    if item.filter({ $0 == ":" }).count == 1 {
        dbg("find_module_for_item: Using method shortcut")
        let module = item.split(separator: ":").first.map(String.init) ?? item
        dbg("find_module_for_item: Found: \(module)")
        return module
    }

    var matches: [String] = []
    for mod in modules {
        if item.hasPrefix(mod) {
            matches.append(mod)
        }
    }
    matches.sort()
    dbg("find_module_for_item: Found options: \(matches)")

    guard let module = matches.last else {
        fatal("Unable to find module for: \(item)")
    }

    dbg("find_module_for_item: Found: \(module)")
    return module
}

func getSectionFromChunk(_ chunk: [String], sectionName: String, item: DocItem, lints: inout [LintError]) -> [String] {
    var section: [String] = []
    var inSection = false
    var isDone = false

    for line in chunk {
        if isDone { break }
        if line == sectionName {
            inSection = true
            continue
        }
        if inSection {
            var hitAnotherSection = false
            for checkName in sectionNames {
                if line == checkName + ":" {
                    hitAnotherSection = true
                    isDone = true
                    break
                }
            }
            if !isDone && !hitAnotherSection {
                section.append(line)
            }
        }
    }

    // Remove trailing blank line
    if !section.isEmpty && section.last == "" {
        section.removeLast()
    }

    // Check for blank lines within non-Notes/Examples sections
    if section.contains("") && sectionName != "Notes:" && sectionName != "Examples:" {
        let message = "\(item.signature) has a blank line in \(sectionName)"
        warn(message)
        lints.append(LintError(
            file: item.file,
            line: Int(item.lineno)! + 3,
            title: "Blank lines should not occur within sections",
            message: message,
            annotationLevel: "failure"
        ))
    }

    return section
}

func stripSectionsFromChunk(_ chunk: [String]) -> [String] {
    var stripped: [String] = []
    var inSection = false
    for line in chunk {
        let trimmed = line
        // Check if this line is a section header (line without trailing colon is in sectionNames)
        var isSectionHeader = false
        if trimmed.hasSuffix(":") {
            let withoutColon = String(trimmed.dropLast())
            if sectionNames.contains(withoutColon) {
                isSectionHeader = true
            }
        }
        if isSectionHeader {
            inSection = true
            continue
        } else if trimmed == "" {
            inSection = false
            continue
        } else {
            if !inSection {
                stripped.append(line)
            }
        }
    }
    return stripped
}

func processDocstrings(_ docstrings: [[String]], standalone: Bool) -> [String: RawModule] {
    var docs: [String: RawModule] = [:]

    // First pass: find all modules
    for chunk in docstrings {
        if chunk[CHUNK_SIGN].hasPrefix("===") {
            let modulename = chunk[CHUNK_SIGN].trimmingCharacters(in: CharacterSet(charactersIn: "= "))
            dbg("process_docstrings: Module: \(modulename) at \(chunk[CHUNK_FILE]):\(chunk[CHUNK_LINE])")
            docs[modulename] = RawModule(header: chunk)
        }
    }

    // Second pass: assign items to modules
    // Using dict-like behavior: duplicate item names overwrite (matching Python)
    for chunk in docstrings {
        if !chunk[CHUNK_SIGN].hasPrefix("===") {
            let itemname = findItemnameFromSignature(chunk[CHUNK_SIGN])
            dbg("process_docstrings: Found item: \(itemname) at \(chunk[CHUNK_FILE]):\(chunk[CHUNK_LINE])")
            let modulename = findModuleForItem(modules: Array(docs.keys), item: itemname, standalone: standalone)
            dbg("process_docstrings:   Assigning item to module: \(modulename)")
            docs[modulename]?.items[itemname] = chunk
        }
    }

    return docs
}

func processModule(name modulename: String, raw rawModule: RawModule, standalone: Bool, failOnWarn: Bool, lints: inout [LintError]) -> DocModule {
    dbg("Processing module: \(modulename)")
    let header = rawModule.header
    dbg("Header: \(header[CHUNK_DESC])")

    let desc = header[CHUNK_DESC]
    let docLines = Array(header[CHUNK_DESC...])
    let doc = docLines.joined(separator: "\n")
    let strippedDocLines = Array(header[(CHUNK_DESC + 1)...])
    let strippedDoc = strippedDocLines.joined(separator: "\n")

    var module = DocModule(name: modulename, desc: desc, doc: doc, strippedDoc: strippedDoc)

    for (itemname, chunk) in rawModule.items.pairs {
        dbg("  Processing item: \(itemname)")

        if !typeNames.contains(chunk[CHUNK_TYPE]) {
            fatal("UNKNOWN TYPE: \(chunk[CHUNK_TYPE]) (\(chunk))")
        }

        let basename = findBasenameFromItemname(itemname)

        var item = DocItem(
            name: basename,
            signature: chunk[CHUNK_SIGN],
            def: chunk[CHUNK_SIGN],
            type: chunk[CHUNK_TYPE],
            desc: chunk[CHUNK_DESC],
            doc: Array(chunk[CHUNK_DESC...]).joined(separator: "\n"),
            strippedDoc: stripSectionsFromChunk(Array(chunk[(CHUNK_DESC + 1)...])).joined(separator: "\n"),
            file: chunk[CHUNK_FILE],
            lineno: chunk[CHUNK_LINE]
        )

        // Extract sections
        let chunkContent = Array(chunk.dropFirst(0)) // full chunk for section search
        for section in ["Parameters", "Returns", "Notes", "Examples"] {
            if chunkContent.contains(section + ":") {
                let sectionData = getSectionFromChunk(chunkContent, sectionName: section + ":", item: item, lints: &lints)
                switch section {
                case "Parameters": item.parameters = sectionData
                case "Returns": item.returns = sectionData
                case "Notes": item.notes = sectionData
                case "Examples": item.examples = sectionData
                default: break
                }
            }
        }

        // Function/Constructor/Method specific processing
        if ["Function", "Constructor", "Method"].contains(item.type) {
            if item.desc.hasPrefix("Alias for [`") {
                item.parameters = []
                item.returns = []
                item.notes = []
            } else {
                do {
                    let sigWithoutReturn = item.signature.split(separator: "->").first.map(String.init) ?? item.signature
                    let sigParams: String
                    if let openParen = sigWithoutReturn.firstIndex(of: "("),
                       let closeParen = sigWithoutReturn.firstIndex(of: ")") {
                        sigParams = String(sigWithoutReturn[sigWithoutReturn.index(after: openParen)..<closeParen])
                    } else {
                        sigParams = sigWithoutReturn
                    }
                    let sigParamArr = sigParams.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "|" })
                    let sigArgCount = sigParamArr.count

                    // Check for multi-line description
                    let chunkFromDesc = Array(chunk[CHUNK_DESC...])
                    if let paramsIdx = chunkFromDesc.firstIndex(of: "Parameters:") {
                        let descSection = chunkFromDesc[0..<paramsIdx].filter { $0 != "" }
                        if descSection.count > 1 {
                            let message = "Function/Method/Constructor description for \(sigWithoutReturn) should be a single line. Other content may belong in the Notes: section."
                            warn(message)
                            lints.append(LintError(
                                file: item.file,
                                line: Int(item.lineno)! + 3,
                                title: "Docstring function/method/constructor description should not be multiline",
                                message: message,
                                annotationLevel: "failure"
                            ))
                        }
                    }

                    // Clean up parameters
                    if let params = item.parameters {
                        var cleanParams: [String] = []
                        for line in params {
                            if line.hasPrefix(" * ") {
                                cleanParams.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
                            } else if line.hasPrefix("  * ") || line.hasPrefix("   * ") {
                                var adjustedLine = line
                                if line.hasPrefix("  * ") {
                                    adjustedLine = " " + line
                                }
                                if !cleanParams.isEmpty {
                                    cleanParams[cleanParams.count - 1] += "\n" + adjustedLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                                }
                            } else {
                                if !cleanParams.isEmpty {
                                    cleanParams[cleanParams.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                                }
                            }
                        }
                        item.parameters = cleanParams

                        // Check parameter count
                        let parameterCount = cleanParams.count
                        if parameterCount != sigArgCount {
                            let message = "SIGNATURE/PARAMETER COUNT MISMATCH: '\(sigWithoutReturn)' says \(sigArgCount) parameters ('\(sigParamArr.joined(separator: ","))'), but Parameters section has \(parameterCount) entries:\n\(cleanParams.joined(separator: "\n"))\n"
                            warn(message)
                            lints.append(LintError(
                                file: item.file,
                                line: Int(item.lineno)!,
                                title: "Docstring signature/parameter mismatch",
                                message: message,
                                annotationLevel: "failure"
                            ))
                        }
                    }

                    // Check returns
                    if item.returns == nil {
                        item.returns = []
                    }
                    if (item.returns ?? []).isEmpty && !standalone {
                        let message = "RETURN COUNT ERROR: '\(sigWithoutReturn)' does not specify a return value"
                        warn(message)
                        lints.append(LintError(
                            file: item.file,
                            line: Int(item.lineno)!,
                            title: "Docstring missing return value",
                            message: message,
                            annotationLevel: "failure"
                        ))
                    }

                    // Remove "None" returns
                    if let returns = item.returns, returns.count == 1 && returns[0] == "* None" {
                        item.returns = []
                    }

                    // Default notes
                    if item.notes == nil {
                        item.notes = []
                    }

                    // Default examples
                    if item.examples == nil {
                        item.examples = []
                    }

                } // end of do block (not actually a do-catch, just a scope)
            }
        }

        module.addItem(item)
    }

    return module
}
