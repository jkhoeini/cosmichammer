import ArgumentParser
import BuildDocsCore
import Foundation

struct BuildDocs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "BuildDocs",
        abstract: "Cosmic Hammer API Documentation Builder"
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
    var title: String = "Cosmic Hammer"

    @Option(name: [.customShort("u"), .customLong("source_url_base")], help: "Base URL for source links")
    var sourceUrlBase: String = "https://github.com/cosmichammer/cosmic-hammer/blob/master/"

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

BuildDocs.main()
