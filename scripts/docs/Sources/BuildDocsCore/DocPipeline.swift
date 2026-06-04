import Foundation

public func doProcessing(directories: [String]) -> [DocModule] {
    var codefiles: [String] = []
    var rawDocstrings: [[String]] = []

    for directory in directories {
        codefiles += findCodeFiles(in: directory)
    }
    if codefiles.isEmpty {
        fatal("No .m/.lua/.swift files found")
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
            var newTree = moduleTree
            var path: [String] = []
            for p in parts {
                path.append(p)
                if p == part { break }
            }
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

public func writeAnnotationsJSON(to path: String, data: [LintError]) {
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

public func emitLints(_ lints: [LintError]) {
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
