import Foundation

// MARK: - HTML Output

public func writeHTML(outputDir: String, templateDir: String, title: String, sourceUrlBase: String, data: [[String: Any]]) {
    writeTemplatedOutput(
        outputDir: outputDir,
        templateDir: templateDir,
        title: title,
        sourceUrlBase: sourceUrlBase,
        data: data,
        extension: "html"
    )
}

// MARK: - Markdown Output

public func writeMarkdown(outputDir: String, templateDir: String, title: String, sourceUrlBase: String, data: [[String: Any]]) {
    writeTemplatedOutput(
        outputDir: outputDir,
        templateDir: templateDir,
        title: title,
        sourceUrlBase: sourceUrlBase,
        data: data,
        extension: "md"
    )
}

// MARK: - Templated Output

private func writeTemplatedOutput(outputDir: String, templateDir: String, title: String, sourceUrlBase: String, data: [[String: Any]], extension ext: String) {
    let fm = FileManager.default

    // Ensure output directory exists
    if !fm.fileExists(atPath: outputDir) {
        do {
            try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        } catch {
            fatal("Output directory is not a directory, and/or can't be created: \(error)")
        }
    }

    // Read index template
    let indexTemplatePath = "\(templateDir)/index.j2.\(ext)"
    guard let indexTemplate = try? String(contentsOfFile: indexTemplatePath, encoding: .utf8) else {
        fatal("Unable to open index.j2.\(ext): file not found at \(indexTemplatePath)")
    }

    // Read module template
    let moduleTemplatePath = "\(templateDir)/module.j2.\(ext)"
    guard let moduleTemplate = try? String(contentsOfFile: moduleTemplatePath, encoding: .utf8) else {
        fatal("Unable to open module.j2.\(ext): file not found at \(moduleTemplatePath)")
    }

    var processedData = data

    if ext == "html" {
        // Pre-render Markdown fields to HTML
        processedData = processMarkdownFields(processedData)
        // Write debug file
        writeJSON(to: outputDir + "/templated_docs.json", data: processedData)
        writeJSONIndex(to: outputDir + "/docs_index.json", data: data)
    }

    // Render and write index
    let indexContext: [String: Any] = [
        "data": processedData,
        "links": links as [[String: Any]],
        "title": title,
    ]
    let indexRender = renderTemplate(indexTemplate, context: indexContext)
    let indexPath = "\(outputDir)/index.\(ext)"
    do {
        try indexRender.write(toFile: indexPath, atomically: true, encoding: .utf8)
    } catch {
        fatal("Unable to create \(indexPath): \(error)")
    }
    dbg("Wrote index.\(ext)")

    // Render and write each module
    for module in processedData {
        guard let moduleName = module["name"] as? String else { continue }

        let moduleContext: [String: Any] = [
            "module": module,
            "type_order": typeNames,
            "type_desc": typeDesc as [String: Any],
            "source_url_base": sourceUrlBase,
        ]
        let moduleRender = renderTemplate(moduleTemplate, context: moduleContext)
        let modulePath = "\(outputDir)/\(moduleName).\(ext)"
        do {
            try moduleRender.write(toFile: modulePath, atomically: true, encoding: .utf8)
        } catch {
            fatal("Unable to write \(modulePath): \(error)")
        }
        dbg("Wrote \(moduleName).\(ext)")
    }

    // For HTML, copy supporting files
    if ext == "html" {
        let cssSource = "\(templateDir)/docs.css"
        let cssDest = "\(outputDir)/docs.css"
        let jsSource = "\(templateDir)/jquery.js"
        let jsDest = "\(outputDir)/jquery.js"

        try? fm.removeItem(atPath: cssDest)
        try? fm.copyItem(atPath: cssSource, toPath: cssDest)
        try? fm.removeItem(atPath: jsDest)
        try? fm.copyItem(atPath: jsSource, toPath: jsDest)
    }
}

// MARK: - Markdown Field Processing

func processMarkdownFields(_ data: [[String: Any]]) -> [[String: Any]] {
    var result = data

    for i in 0..<result.count {
        var module = result[i]

        // Module-level fields
        if let desc = module["desc"] as? String {
            module["desc_gfm"] = renderMarkdown(desc)
        }
        if let doc = module["doc"] as? String {
            module["doc_gfm"] = renderMarkdown(doc)
        }

        // Process each type's items
        for itemType in typeNames {
            if var items = module[itemType] as? [[String: Any]] {
                for j in 0..<items.count {
                    var item = items[j]
                    dbg("Preparing template data for: \(item["def"] as? String ?? "")")

                    if let def = item["def"] as? String {
                        item["def_gfm"] = stripParagraph(renderMarkdown(def))
                    }
                    if let desc = item["desc"] as? String {
                        item["desc_gfm"] = renderMarkdown(desc)
                    }
                    if let doc = item["doc"] as? String {
                        item["doc_gfm"] = renderMarkdown(doc)
                    }
                    if let notes = item["notes"] as? [String] {
                        item["notes_gfm"] = renderMarkdown(notes.joined(separator: "\n"))
                    }
                    if ["Function", "Constructor", "Method"].contains(itemType) {
                        if let parameters = item["parameters"] as? [String] {
                            item["parameters_gfm"] = renderMarkdown(parameters.joined(separator: "\n"))
                        }
                        if let returns = item["returns"] as? [String] {
                            item["returns_gfm"] = renderMarkdown(returns.joined(separator: "\n"))
                        }
                    }
                    if let examples = item["examples"] as? [String] {
                        item["examples_gfm"] = renderMarkdown(examples.joined(separator: "\n"))
                    }

                    items[j] = item
                }
                module[itemType] = items
            }
        }

        // Also process the deprecated 'items' list
        if var items = module["items"] as? [[String: Any]] {
            for j in 0..<items.count {
                var item = items[j]
                if let def = item["def"] as? String {
                    item["def_gfm"] = stripParagraph(renderMarkdown(def))
                }
                if let doc = item["doc"] as? String {
                    item["doc_gfm"] = renderMarkdown(doc)
                }
                items[j] = item
            }
            module["items"] = items
        }

        result[i] = module
    }

    return result
}
