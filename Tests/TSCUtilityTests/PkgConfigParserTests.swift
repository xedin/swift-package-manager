/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import TSCBasic
import TSCTestSupport

@testable import TSCUtility

final class PkgConfigParserTests: XCTestCase {

    func testGTK3PCFile() {
        try! loadPCFile("gtk+-3.0.pc") { parser in
            XCTAssertEqual(parser.variables, [
                "libdir": "/usr/local/Cellar/gtk+3/3.18.9/lib",
                "gtk_host": "x86_64-apple-darwin15.3.0",
                "includedir": "/usr/local/Cellar/gtk+3/3.18.9/include",
                "prefix": "/usr/local/Cellar/gtk+3/3.18.9",
                "gtk_binary_version": "3.0.0",
                "exec_prefix": "/usr/local/Cellar/gtk+3/3.18.9",
                "targets": "quartz",
                "pcfiledir": parser.pcFile.parentDirectory.pathString
            ])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk", "cairo", "cairo-gobject", "gdk-pixbuf-2.0", "gio-2.0"])
            XCTAssertEqual(parser.cFlags, ["-I/usr/local/Cellar/gtk+3/3.18.9/include/gtk-3.0"])
            XCTAssertEqual(parser.libs, ["-L/usr/local/Cellar/gtk+3/3.18.9/lib", "-lgtk-3"])
        }
    }

    func testEmptyCFlags() {
        try! loadPCFile("empty_cflags.pc") { parser in
            XCTAssertEqual(parser.variables, ["prefix": "/usr/local/bin", "exec_prefix": "/usr/local/bin", "pcfiledir": parser.pcFile.parentDirectory.pathString])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk"])
            XCTAssertEqual(parser.cFlags, [])
            XCTAssertEqual(parser.libs, ["-L/usr/local/bin", "-lgtk-3"])
        }
    }

    func testVariableinDependency() {
        try! loadPCFile("deps_variable.pc") { parser in
            XCTAssertEqual(parser.variables, ["prefix": "/usr/local/bin", "exec_prefix": "/usr/local/bin", "my_dep": "atk", "pcfiledir": parser.pcFile.parentDirectory.pathString])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk"])
            XCTAssertEqual(parser.cFlags, ["-I"])
            XCTAssertEqual(parser.libs, ["-L/usr/local/bin", "-lgtk-3"])
        }
    }

    func testUnresolvablePCFile() throws {
        do {
            try loadPCFile("failure_case.pc")
            XCTFail("Unexpected success")
        } catch PkgConfigError.parsingError(let desc) {
            XCTAssert(desc.hasPrefix("Expected a value for variable"))
        }
    }

    func testEscapedSpaces() {
        try! loadPCFile("escaped_spaces.pc") { parser in
            XCTAssertEqual(parser.variables, ["prefix": "/usr/local/bin", "exec_prefix": "/usr/local/bin", "my_dep": "atk", "pcfiledir": parser.pcFile.parentDirectory.pathString])
            XCTAssertEqual(parser.dependencies, ["gdk-3.0", "atk"])
            XCTAssertEqual(parser.cFlags, ["-I/usr/local/Wine Cellar/gtk+3/3.18.9/include/gtk-3.0", "-I/after/extra/spaces"])
            XCTAssertEqual(parser.libs, ["-L/usr/local/bin", "-lgtk 3", "-wantareal\\here", "-one\\", "-two"])
        }
    }

    /// Test custom search path get higher priority for locating pc files.
    func testCustomPcFileSearchPath() throws {
        let diagnostics = DiagnosticsEngine()

        let fs = InMemoryFileSystem(emptyFiles:
            "/usr/lib/pkgconfig/foo.pc",
            "/usr/local/opt/foo/lib/pkgconfig/foo.pc",
            "/custom/foo.pc")
        XCTAssertEqual("/custom/foo.pc", try PCFileFinder(diagnostics: diagnostics, brewPrefix: nil).locatePCFile(name: "foo", customSearchPaths: [AbsolutePath("/custom")], fileSystem: fs).pathString)
        XCTAssertEqual("/custom/foo.pc", try PkgConfig(name: "foo", additionalSearchPaths: [AbsolutePath("/custom")], diagnostics: diagnostics, fileSystem: fs, brewPrefix: nil).pcFile.pathString)
        XCTAssertEqual("/usr/lib/pkgconfig/foo.pc", try PCFileFinder(diagnostics: diagnostics, brewPrefix: nil).locatePCFile(name: "foo", customSearchPaths: [], fileSystem: fs).pathString)
        try withCustomEnv(["PKG_CONFIG_PATH": "/usr/local/opt/foo/lib/pkgconfig"]) {
            XCTAssertEqual("/usr/local/opt/foo/lib/pkgconfig/foo.pc", try PkgConfig(name: "foo", diagnostics: diagnostics, fileSystem: fs, brewPrefix: nil).pcFile.pathString)
        }
        try withCustomEnv(["PKG_CONFIG_PATH": "/usr/local/opt/foo/lib/pkgconfig:/usr/lib/pkgconfig"]) {
            XCTAssertEqual("/usr/local/opt/foo/lib/pkgconfig/foo.pc", try PkgConfig(name: "foo", diagnostics: diagnostics, fileSystem: fs, brewPrefix: nil).pcFile.pathString)
        }
    }

    func testBrewPrefix() throws {
        mktmpdir { tmpPath in
            let fakePkgConfig = tmpPath.appending(components: "bin", "pkg-config")
            try localFileSystem.createDirectory(fakePkgConfig.parentDirectory)

            let stream = BufferedOutputByteStream()
            stream <<< """
            #!/bin/sh
            echo "/Volumes/BestDrive/pkgconfig"
            """
            try localFileSystem.writeFileContents(fakePkgConfig, bytes: stream.bytes)
            // `FileSystem` does not support `chmod` on Linux, so we shell out instead.
            _ = try Process.popen(args: "chmod", "+x", fakePkgConfig.pathString)

            let diagnostics = DiagnosticsEngine()
            _ = PCFileFinder(diagnostics: diagnostics, brewPrefix: fakePkgConfig.parentDirectory.parentDirectory)
        }

        XCTAssertEqual(PCFileFinder.pkgConfigPaths, [AbsolutePath("/Volumes/BestDrive/pkgconfig")])
    }

    func testUnevenQuotes() throws {
        do {
            try loadPCFile("quotes_failure.pc")
            XCTFail("Unexpected success")
        } catch PkgConfigError.parsingError(let desc) {
            XCTAssert(desc.hasPrefix("Text ended before matching quote"))
        }
    }

    private func loadPCFile(_ inputName: String, body: ((PkgConfigParser) -> Void)? = nil) throws {
        let input = AbsolutePath(#file).parentDirectory.appending(components: "pkgconfigInputs", inputName)
        var parser = PkgConfigParser(pcFile: input, fileSystem: localFileSystem)
        try parser.parse()
        body?(parser)
    }
}
