import ArgumentParser
import Foundation

var debug: Bool = false
var failOnWarn: Bool = true
var hasWarned: Bool = false
var lintMode: Bool = false
var lints: [LintError] = []
var standaloneMode: Bool = false

func dbg(_ msg: String) {
    if debug {
        print("DEBUG: \(msg)")
    }
}

func warn(_ msg: String) {
    print("WARN: \(msg)")
    hasWarned = true
}

func fatal(_ msg: String) -> Never {
    print("ERROR: \(msg)")
    exit(1)
}

struct BuildDocs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "BuildDocs",
        abstract: "Hammerspoon API Documentation Builder"
    )

    @Flag(name: [.short, .customLong("validate")], help: "Ensure all docstrings are valid")
    var validate: Bool = false

    @Flag(name: [.short, .customLong("json")], help: "Output docs.json")
    var json: Bool = false

    @Flag(name: [.customShort("s"), .customLong("sql")], help: "Output docs.sqlite")
    var sql: Bool = false

    @Flag(name: [.customShort("t"), .customLong("html")], help: "Output HTML docs")
    var html: Bool = false

    @Flag(name: [.customShort("m"), .customLong("markdown")], help: "Output Markdown docs")
    var markdown: Bool = false

    @Flag(name: [.customShort("l"), .customLong("lint")], help: "Run in Lint mode. No docs will be built")
    var lint: Bool = false

    @Flag(name: [.customShort("d"), .customLong("debug")], help: "Enable debugging output")
    var debugMode: Bool = false

    @Flag(name: [.customShort("n"), .customLong("standalone")], help: "Process a single module only")
    var standalone: Bool = false

    @Option(name: [.customShort("o"), .customLong("output_dir")], help: "Directory to write outputs to")
    var outputDir: String = "build/"

    @Option(name: [.customShort("e"), .customLong("templates")], help: "Directory of HTML templates")
    var templateDir: String = "scripts/docs/templates"

    @Option(name: [.customShort("i"), .customLong("title")], help: "Title for the index page")
    var title: String = "Hammerspoon"

    @Option(name: [.customShort("u"), .customLong("source_url_base")], help: "Base URL for source links")
    var sourceUrlBase: String = "https://github.com/Hammerspoon/hammerspoon/blob/master/"

    @Argument(help: "Directories to search")
    var dirs: [String] = []

    mutating func run() throws {
        if debugMode {
            debug = true
        }
        dbg("Arguments: \(self)")

        if !validate && !json && !sql && !html && !markdown && !lint {
            fatal("At least one of validate/json/sql/html/markdown is required.")
        }

        if dirs.isEmpty {
            fatal("At least one directory is required. See DIRS")
        }

        standaloneMode = standalone

        if lint {
            lintMode = true
            failOnWarn = false
        }

        let results = doProcessing(directories: dirs)

        if validate {
            // If we got this far, we already processed and validated
        }

        if lint {
            writeAnnotationsJSON(to: outputDir + "/annotations.json", data: lints)
            emitLints(lints)
        }

        if json {
            let jsonData = results.map { $0.toDictionary() }
            writeJSON(to: outputDir + "/docs.json", data: jsonData)
            writeJSONIndex(to: outputDir + "/docs_index.json", data: jsonData)
        }

        if sql {
            let sqlData = results.map { $0.toDictionary() }
            writeSQLite(to: outputDir + "/docs.sqlite", data: sqlData)
        }

        if html {
            let htmlData = results.map { $0.toDictionary() }
            writeHTML(
                outputDir: outputDir + "/html/",
                templateDir: templateDir,
                title: title,
                sourceUrlBase: sourceUrlBase,
                data: htmlData
            )
        }

        if markdown {
            let mdData = results.map { $0.toDictionary() }
            writeMarkdown(
                outputDir: outputDir + "/markdown/",
                templateDir: templateDir,
                title: title,
                sourceUrlBase: sourceUrlBase,
                data: mdData
            )
        }

        if failOnWarn && hasWarned {
            Darwin.exit(1)
        }
    }
}

func doProcessing(directories: [String]) -> [DocModule] {
    var codefiles: [String] = []
    var rawDocstrings: [[String]] = []

    for directory in directories {
        codefiles += findCodeFiles(in: directory)
    }
    if codefiles.isEmpty {
        fatal("No .m/.lua files found")
    }

    for filename in codefiles {
        rawDocstrings += extractDocstrings(from: filename)
    }
    if rawDocstrings.isEmpty {
        fatal("No docstrings found")
    }

    let docs = processDocstrings(rawDocstrings, standalone: standaloneMode)

    if docs.isEmpty {
        fatal("No modules found")
    }

    var processedDocstrings: [DocModule] = []
    var moduleTree: [String: Any] = [:]

    for moduleName in docs.keys {
        dbg("Processing: \(moduleName)")
        var moduleDocs = processModule(
            name: moduleName,
            raw: docs[moduleName]!,
            standalone: standaloneMode,
            failOnWarn: failOnWarn,
            lints: &lints
        )
        moduleDocs.items.sort { $0.name.lowercased() < $1.name.lowercased() }
        for typeName in typeNames {
            moduleDocs.sortItems(ofType: typeName)
        }
        processedDocstrings.append(moduleDocs)

        // Build module tree
        let parts = moduleName.split(separator: ".").map(String.init)
        var cursor = moduleTree
        for part in parts {
            if cursor[part] == nil {
                cursor[part] = [String: Any]()
            }
            // We need to rebuild the tree path
            var newTree = moduleTree
            var path: [String] = []
            for p in parts {
                path.append(p)
                if p == part { break }
            }
            // Set the subtree
            setNestedValue(&newTree, path: path, value: cursor[part] as? [String: Any] ?? [:])
            moduleTree = newTree
            cursor = cursor[part] as? [String: Any] ?? [:]
        }
    }

    // Find submodules
    for i in 0..<processedDocstrings.count {
        let moduleName = processedDocstrings[i].name
        dbg("Finding submodules for: \(moduleName)")
        let parts = moduleName.split(separator: ".").map(String.init)
        var cursor = moduleTree
        for part in parts {
            cursor = cursor[part] as? [String: Any] ?? [:]
        }
        var submodules: [String] = []
        for sub in cursor.keys {
            submodules.append(sub)
        }
        submodules.sort()
        processedDocstrings[i].submodules = submodules
    }

    processedDocstrings.sort { $0.name.lowercased() < $1.name.lowercased() }
    return processedDocstrings
}

func setNestedValue(_ dict: inout [String: Any], path: [String], value: [String: Any]) {
    guard !path.isEmpty else { return }
    if path.count == 1 {
        let existing = dict[path[0]] as? [String: Any] ?? [:]
        var merged = existing
        for (k, v) in value {
            merged[k] = v
        }
        dict[path[0]] = merged
    } else {
        var sub = dict[path[0]] as? [String: Any] ?? [:]
        setNestedValue(&sub, path: Array(path.dropFirst()), value: value)
        dict[path[0]] = sub
    }
}

func writeAnnotationsJSON(to path: String, data: [LintError]) {
    let dicts = data.map { $0.toDictionary() }
    let jsonString = serializeJSON(dicts as [Any])
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    do {
        try jsonString.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        fatal("Failed to write annotations: \(error)")
    }
}

func emitLints(_ lints: [LintError]) {
    for lint in lints {
        FileHandle.standardError.write(
            "::error file=\(lint.file),line=\(lint.line),title=\(lint.title)::\(lint.message)\n"
                .data(using: .utf8)!
        )
    }
    if !lints.isEmpty {
        exit(1)
    }
}

BuildDocs.main()
