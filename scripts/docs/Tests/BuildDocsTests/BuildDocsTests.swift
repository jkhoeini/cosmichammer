import Foundation
@testable import BuildDocsCore
import XCTest

final class BuildDocsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        debug = false
        failOnWarn = true
        hasWarned = false
        lintMode = false
        lints = []
        standaloneMode = false
    }

    func testFindCodeFilesIncludesSwiftAndSortsDeterministically() throws {
        let fixture = fixtureURL("scan")
        let files = findCodeFiles(in: fixture.path).map {
            URL(fileURLWithPath: $0).path.replacingOccurrences(of: fixture.path + "/", with: "")
        }

        XCTAssertEqual(files, [
            "a.lua",
            "b.swift",
            "sub/c.m",
            "sub/d.swift",
        ])
    }

    func testExtractDocstringsIncludesLuaChunkAtEOF() throws {
        let file = try writeTempFile(
            named: "eof.lua",
            contents: """
            --- === hs.eof ===
            --- EOF module.
            local module = {}
            --- hs.eof.finish()
            --- Function
            --- Ends at EOF.
            """
        )

        let chunks = extractDocstrings(from: file.path)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.last?[2], "hs.eof.finish()")
        if let last = chunks.last, last.count > 4 {
            XCTAssertEqual(last[4], "Ends at EOF.")
        }
    }

    func testExtractDocstringsParsesIndentedSwiftAPIAndIgnoresNonAPIComments() throws {
        let file = try writeTempFile(
            named: "SwiftDocs.swift",
            contents: """
            /// Implementation detail, not an API doc.
            /// This should not be emitted.
            private let helper = 1

                /// === hs.swiftdemo ===
                /// Swift demo module.
            enum SwiftDemo {}

                /// hs.swiftdemo.answer
                /// Constant
                /// Exported from Swift.
            let answer = 42

                /// hs.swiftdemo.incomplete()
                /// Function
                /// This is missing a Returns section.
            func incomplete() {}
            """
        )

        let chunks = extractDocstrings(from: file.path)

        XCTAssertEqual(chunks.map { $0[2] }, [
            "=== hs.swiftdemo ===",
            "hs.swiftdemo.answer",
        ])
    }

    func testExtractDocstringsKeepsIndentedObjectiveCCommentsOutOfDocs() throws {
        let file = try writeTempFile(
            named: "ObjCComments.m",
            contents: """
            /// === hs.objc ===
            /// Objective-C module.

            static void helper(void) {
                /// Internal implementation note.
                /// This should not become API documentation.
            }
            """
        )

        let chunks = extractDocstrings(from: file.path)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?[2], "=== hs.objc ===")
    }

    func testProcessDocstringsAssignsModulesParsesSectionsAndOverwritesDuplicates() throws {
        let chunks = [
            ["fixture.lua", "1", "=== hs.demo ===", "", "Demo module.", "Longer module docs."],
            ["fixture.lua", "10", "=== hs.demo.child ===", "", "Child module."],
            [
                "fixture.lua", "20", "hs.demo.action(value)", "Function", "Old description.",
                "Parameters:", " * value - Value to use", "Returns:", " * string",
            ],
            [
                "fixture.lua", "30", "hs.demo.action(value)", "Function", "New description.",
                "Parameters:", " * value - Value to use", "Returns:", " * boolean",
                "Notes:", " * Stable", "", "Examples:", "hs.demo.action(\"x\")",
            ],
            ["fixture.lua", "50", "hs.demo.child.enabled", "Constant", "Child constant."],
        ]

        let raw = processDocstrings(chunks, standalone: false)
        var lintErrors: [LintError] = []
        let demo = processModule(
            name: "hs.demo",
            raw: try XCTUnwrap(raw["hs.demo"]),
            standalone: false,
            failOnWarn: false,
            lints: &lintErrors
        )
        let child = processModule(
            name: "hs.demo.child",
            raw: try XCTUnwrap(raw["hs.demo.child"]),
            standalone: false,
            failOnWarn: false,
            lints: &lintErrors
        )

        XCTAssertEqual(demo.items.map(\.signature), ["hs.demo.action(value)"])
        XCTAssertEqual(demo.items.first?.desc, "New description.")
        XCTAssertEqual(demo.items.first?.parameters, [" * value - Value to use"])
        XCTAssertEqual(demo.items.first?.returns, [" * boolean"])
        XCTAssertEqual(demo.items.first?.notes, [" * Stable"])
        XCTAssertEqual(demo.items.first?.examples, ["hs.demo.action(\"x\")"])
        XCTAssertEqual(child.items.first?.signature, "hs.demo.child.enabled")
    }

    func testRenderTemplateSupportsLoopsConditionsAndFilters() {
        let template = """
        {% for item in items %}
        {% if item.visible %}
        {{ item.name | replace("hs.","") }}
        {% endif %}
        {% endfor %}
        """
        let output = renderTemplate(template, context: [
            "items": [
                ["name": "hs.one", "visible": true],
                ["name": "hs.two", "visible": false],
            ],
        ])

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "one")
    }

    func testMarkdownRenderingIsDeterministicForInlineMarkup() {
        XCTAssertEqual(
            renderMarkdown("**Bold** `hs.demo`"),
            "<p><strong>Bold</strong> <code>hs.demo</code></p>\n"
        )
    }

    func testWriteHTMLWritesSearchIndexBesideIndex() throws {
        let templateDir = try makeTempDir().appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)
        try "index {{ title }}".write(
            to: templateDir.appendingPathComponent("index.j2.html"),
            atomically: true,
            encoding: .utf8
        )
        try "module {{ module.name }}".write(
            to: templateDir.appendingPathComponent("module.j2.html"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(to: templateDir.appendingPathComponent("docs.css"), atomically: true, encoding: .utf8)
        try "".write(to: templateDir.appendingPathComponent("jquery.js"), atomically: true, encoding: .utf8)

        let outputDir = try makeTempDir().appendingPathComponent("html")
        writeHTML(
            outputDir: outputDir.path,
            templateDir: templateDir.path,
            title: "Test Docs",
            sourceUrlBase: "",
            data: [[
                "name": "hs.demo",
                "type": "Module",
                "desc": "Demo module.",
                "doc": "Demo module.",
                "Function": [[
                    "name": "action",
                    "type": "Function",
                    "desc": "Does work.",
                ]],
            ]]
        )

        let indexPath = outputDir.appendingPathComponent("docs_index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexPath.path))
        XCTAssertTrue(try String(contentsOf: indexPath).contains("hs.demo"))
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BuildDocsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTempFile(named name: String, contents: String) throws -> URL {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
