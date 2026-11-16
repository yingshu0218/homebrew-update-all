import XCTest

@MainActor
final class BrewServiceFetchTests: XCTestCase {
    func testFormulaFetchIncludesDependenciesAndCaskFetchDoesNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-fake-brew-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeBrew = directory.appendingPathComponent("brew")
        let argumentLog = directory.appendingPathComponent("arguments.txt")
        let cacheFile = directory.appendingPathComponent("cache-target.tar.gz")
        let script = """
        #!/bin/sh
        case "$1" in
          --cache) printf '%s\\n' "$BREWUA_CACHE_FILE" ;;
          info) printf '%s\\n' "$BREWUA_INFO_JSON" ;;
          fetch) printf '%s\\n' "$*" >> "$BREWUA_ARGUMENT_LOG" ;;
          *) exit 97 ;;
        esac
        """
        try script.write(to: fakeBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBrew.path)

        var environment = StreamedProcess.brewEnv
        environment["BREWUA_CACHE_FILE"] = cacheFile.path
        environment["BREWUA_ARGUMENT_LOG"] = argumentLog.path
        environment["BREWUA_INFO_JSON"] = #"{"formulae":[{"name":"same","urls":{"stable":{"url":null}},"bottle":{"stable":{"files":{}}}}],"casks":[{"token":"same","url":null}]}"#
        let config = ConfigService(fileURL: directory.appendingPathComponent("ignored_casks"))
        let service = BrewService(config: config, processFactory: { arguments in
            StreamedProcess(brewArguments: arguments, environment: environment, brewPath: fakeBrew.path)
        })
        let formula = OutdatedEntry(name: "same", currentVersion: "1", newestVersion: "2", kind: .formula, isIgnored: false)
        let cask = OutdatedEntry(name: "same", currentVersion: "1", newestVersion: "2", kind: .cask, isIgnored: false)

        try await service.fetch(package: formula, onLine: { _ in }, onProgress: { _, _, _ in })
        try await service.fetch(package: cask, onLine: { _ in }, onProgress: { _, _, _ in })

        let commands = try String(contentsOf: argumentLog, encoding: .utf8).components(separatedBy: .newlines)
        XCTAssertTrue(commands.contains("fetch --formula --deps same"))
        XCTAssertTrue(commands.contains("fetch --cask same"))
        XCTAssertFalse(commands.contains { $0.contains("fetch --cask --deps") })
    }
}
