import XCTest

final class ConfigServiceTests: XCTestCase {
    private func makeConfig() throws -> (URL, ConfigService) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brewua-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, ConfigService(fileURL: directory.appendingPathComponent("ignored_casks")))
    }

    func testLegacyCaskAndTypedFormulaRulesDoNotCrossKinds() {
        let rules: Set<String> = ["firefox", "formula:firefox", "owner/tap/tool", "formula:owner/tap/tool"]
        XCTAssertTrue(ConfigService.isIgnored(name: "firefox", kind: .cask, rules: rules))
        XCTAssertFalse(ConfigService.isIgnored(name: "firefox", kind: .formula, rules: ["firefox"]))
        XCTAssertTrue(ConfigService.isIgnored(name: "firefox", kind: .formula, rules: rules))
        XCTAssertTrue(ConfigService.isIgnored(name: "owner/tap/tool", kind: .cask, rules: rules))
        XCTAssertFalse(ConfigService.isIgnored(name: "other/tap/tool", kind: .cask, rules: rules))
        XCTAssertTrue(ConfigService.isIgnored(name: "other/tap/tool", kind: .formula, rules: ["formula:tool"]))
        XCTAssertFalse(ConfigService.isIgnored(name: "owner/tap/tool", kind: .formula, rules: ["tool"]))
    }

    func testWritesSharedFormatAtomicallyToInjectedTemporaryPath() throws {
        let (directory, config) = try makeConfig()
        try config.addIgnored("firefox", kind: .cask)
        try config.addIgnored("firefox", kind: .formula)
        try config.addIgnored("owner/tap/tool", kind: .formula)

        XCTAssertEqual(config.loadIgnored(), ["firefox", "formula:firefox", "formula:owner/tap/tool"])
        let diskText = try String(contentsOf: config.ignoredFileURL, encoding: .utf8)
        XCTAssertEqual(diskText, "firefox\nformula:firefox\nformula:owner/tap/tool\n")
        XCTAssertTrue(config.ignoredFileURL.path.hasPrefix(directory.path))
        XCTAssertFalse(config.ignoredFileURL.path.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testRemovingFullTapPackageAlsoRemovesMatchingShortRuleOfSameKind() throws {
        let (_, config) = try makeConfig()
        try config.addIgnored("tool", kind: .formula)
        try config.addIgnored("tool", kind: .cask)
        try config.removeIgnoredMatching(name: "owner/tap/tool", kind: .formula)

        XCTAssertEqual(config.loadIgnored(), ["tool"])
        XCTAssertFalse(ConfigService.isIgnored(name: "owner/tap/tool", kind: .formula, rules: config.loadIgnored()))
        XCTAssertTrue(ConfigService.isIgnored(name: "owner/tap/tool", kind: .cask, rules: config.loadIgnored()))
    }
}
