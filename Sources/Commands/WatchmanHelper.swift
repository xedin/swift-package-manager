/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2018 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import TSCUtility
import Xcodeproj

final class WatchmanHelper {

    /// Name of the watchman-make tool.
    static let watchmanMakeTool: String = "watchman-make"

    /// Directory where watchman script should be created.
    let watchmanScriptsDir: AbsolutePath

    /// The package root.
    let packageRoot: AbsolutePath

    /// The filesystem to operator on.
    let fs: FileSystem

    let diagnostics: DiagnosticsEngine

    init(
        diagnostics: DiagnosticsEngine,
        watchmanScriptsDir: AbsolutePath,
        packageRoot: AbsolutePath,
        fs: FileSystem = localFileSystem
    ) {
        self.watchmanScriptsDir = watchmanScriptsDir
        self.diagnostics = diagnostics
        self.packageRoot = packageRoot
        self.fs = fs
    }

    func runXcodeprojWatcher(_ options: XcodeprojOptions) throws {
        let scriptPath = try createXcodegenScript(options)
        try run(scriptPath)
    }

    func createXcodegenScript(_ options: XcodeprojOptions) throws -> AbsolutePath {
        let scriptPath = watchmanScriptsDir.appending(component: "gen-xcodeproj.sh")

        let stream = BufferedOutputByteStream()
        stream <<< "#!/usr/bin/env bash" <<< "\n\n\n"
        stream <<< "# Autogenerated by SwiftPM. Do not edit!" <<< "\n\n\n"
        stream <<< "set -eu" <<< "\n\n"
        stream <<< "swift package generate-xcodeproj"
        if let xcconfigOverrides = options.xcconfigOverrides {
            stream <<< " --xcconfig-overrides " <<< xcconfigOverrides.pathString
        }
        stream <<< "\n"

        try fs.createDirectory(scriptPath.parentDirectory, recursive: true)
        try fs.writeFileContents(scriptPath, bytes: stream.bytes)
        try fs.chmod(.executable, path: scriptPath)

        return scriptPath
    }

    private func run(_ scriptPath: AbsolutePath) throws {
        // Construct the arugments.
        var args = [String]()
        args += ["--settle", "2"]
        args += ["-p", "Package.swift", "Package.resolved"]
        args += ["--run", scriptPath.pathString.spm_shellEscaped()]

        // Find and execute watchman.
        let watchmanMakeToolPath = try self.watchmanMakeToolPath()

        print("Starting:", watchmanMakeToolPath, args.joined(separator: " "))

        let pathRelativeToWorkingDirectory = watchmanMakeToolPath.relative(to: packageRoot)
        try exec(path: watchmanMakeToolPath.pathString, args: [pathRelativeToWorkingDirectory.pathString] + args)
    }

    private func watchmanMakeToolPath() throws -> AbsolutePath {
        if let toolPath = Process.findExecutable(WatchmanHelper.watchmanMakeTool) {
            return toolPath
        }
        diagnostics.emit(error: "this feature requires 'watchman' to work\n\n\n    installation instructions for 'watchman' are available at https://facebook.github.io/watchman/docs/install.html#buildinstall")
        throw Diagnostics.fatalError
    }
}
