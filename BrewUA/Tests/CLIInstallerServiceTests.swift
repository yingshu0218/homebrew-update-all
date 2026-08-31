import XCTest
import Foundation

/// CLIInstallerService:版本解析 / 临时目录安装卸载往返 / 覆盖安装 / 资源解析。
/// brewPrefix 全部注入临时目录,不触达真实 Homebrew。
final class CLIInstallerServiceTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeScript(_ dir: URL, version: String?) throws -> URL {
        let url = dir.appendingPathComponent("script-\(UUID().uuidString)")
        let versionLine = version.map { "BREW_UA_VERSION=\"\($0)\"\n" } ?? ""
        try "#!/bin/zsh\n\(versionLine)echo hi\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 版本解析

    func testParseVersion() {
        XCTAssertEqual(CLIInstallerService.parseVersion(fromScript: "BREW_UA_VERSION=\"1.8.7\""), "1.8.7")
        XCTAssertEqual(CLIInstallerService.parseVersion(fromScript: "  BREW_UA_VERSION = \"2.0.0\"  # 注释"), "2.0.0")
        XCTAssertEqual(CLIInstallerService.parseVersion(fromScript: "x=1\nBREW_UA_VERSION=\"10.20.30\"\n"), "10.20.30")
        // 反例
        XCTAssertNil(CLIInstallerService.parseVersion(fromScript: "no version here"))
        XCTAssertNil(CLIInstallerService.parseVersion(fromScript: "BREW_UA_VERSION=\"\""))
        XCTAssertNil(CLIInstallerService.parseVersion(fromScript: "BREW_UA_VERSION="))
    }

    // MARK: - 安装/卸载往返

    func testInstallUninstallRoundtrip() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = try writeScript(tmp, version: "9.9.9")
        let prefix = tmp.appendingPathComponent("brewroot")

        // 初始:未安装(bundledScript 注入伪造脚本,与测试 bundle 内的真实资源隔离)
        let before = await CLIInstallerService.checkStatus(brewPrefix: prefix.path, bundle: Bundle(for: Self.self), bundledScript: script)
        XCTAssertEqual(before.status, .notInstalled)
        XCTAssertEqual(before.bundledVersion, "9.9.9")

        // 安装
        let installed = try await CLIInstallerService.install(brewPrefix: prefix.path, bundledURL: script)
        XCTAssertEqual(installed, "9.9.9")
        let target = prefix.appendingPathComponent("bin/brew-ua")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let perms = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o755)

        // 状态:已安装 + 版本一致(不判过期)
        let after = await CLIInstallerService.checkStatus(brewPrefix: prefix.path, bundle: Bundle(for: Self.self), bundledScript: script)
        XCTAssertEqual(after.status, .installed(version: "9.9.9"))
        XCTAssertFalse(after.isOutdated)

        // 卸载;未安装时再卸载不抛错
        try await CLIInstallerService.uninstall(brewPrefix: prefix.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try await CLIInstallerService.uninstall(brewPrefix: prefix.path)
        let cleared = await CLIInstallerService.checkStatus(brewPrefix: prefix.path, bundle: Bundle(for: Self.self), bundledScript: script)
        XCTAssertEqual(cleared.status, .notInstalled)
    }

    // MARK: - 覆盖安装与来源未知检测

    func testReinstallOverwritesAndForeignDetection() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let prefix = tmp.appendingPathComponent("brewroot")

        // 第一次装 v1.0.0
        _ = try await CLIInstallerService.install(brewPrefix: prefix.path,
                                                  bundledURL: writeScript(tmp, version: "1.0.0"))
        // 第二次覆盖装 v2.0.0,内容应被完全替换
        _ = try await CLIInstallerService.install(brewPrefix: prefix.path,
                                                  bundledURL: writeScript(tmp, version: "2.0.0"))
        let target = prefix.appendingPathComponent("bin/brew-ua")
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("2.0.0"))
        XCTAssertFalse(text.contains("1.0.0"))

        // 目标被替换为无版本标记的文件 → installedForeign
        try "echo no-version\n".write(to: target, atomically: true, encoding: .utf8)
        let bundled = try writeScript(tmp, version: "2.0.0")
        let foreign = await CLIInstallerService.checkStatus(brewPrefix: prefix.path, bundle: Bundle(for: Self.self), bundledScript: bundled)
        XCTAssertEqual(foreign.status, .installedForeign)

        // installedForeign 时 isOutdated 不误报
        XCTAssertFalse(foreign.isOutdated)
    }

    // MARK: - brew 未找到

    func testBrewNotFoundWithEmptyPrefix() async {
        // 显式注入空串 → 不触达真实 brew,直接判定 brewNotFound
        let status = await CLIInstallerService.checkStatus(brewPrefix: "", bundle: Bundle(for: Self.self))
        XCTAssertEqual(status.status, .brewNotFound)
        XCTAssertNil(status.targetURL)
    }

    // MARK: - 资源解析(测试 bundle 注册的仓库根脚本)

    func testBundledScriptInTestBundle() throws {
        guard let url = CLIInstallerService.bundledScriptURL(bundle: Bundle(for: Self.self)) else {
            return XCTFail("测试 bundle 未注册 brew-ua 资源(检查 project.yml)")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertNotNil(CLIInstallerService.parseVersion(fromScript: text), "脚本应含 BREW_UA_VERSION 标记")
    }
}
