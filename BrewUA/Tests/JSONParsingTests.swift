import XCTest

/// 针对真实 brew 命令输出格式的解析回归测试。
/// 这些格式是 M2/M3 数据层的根基,必须锁定。
final class JSONParsingTests: XCTestCase {

    /// 真实 brew outdated --formula --json 输出(单对象 snake_case)
    func testParseOutdatedFormulaJSON() {
        let json = """
        {
          "formulae": [
            {
              "name": "yingshu0218/update-all/brew-update-all",
              "installed_versions": ["1.8.6"],
              "current_version": "1.8.6",
              "pinned": false,
              "pinned_version": null
            }
          ],
          "casks": []
        }
        """
        let entries = BrewService.parseOutdatedJSON(json, kind: .formula)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "yingshu0218/update-all/brew-update-all")
        XCTAssertEqual(entries[0].currentVersion, "1.8.6")
        XCTAssertEqual(entries[0].newestVersion, "1.8.6")
        XCTAssertEqual(entries[0].kind, .formula)
    }

    /// 真实 brew outdated --cask --json 输出(cask 带 installed_versions)
    func testParseOutdatedCaskJSON() {
        let json = """
        {
          "formulae": [],
          "casks": [
            {
              "name": "bambu-studio",
              "installed_versions": ["02.07.01.62,20260616174358"],
              "current_version": "02.08.02.60,20260814163036",
              "pinned": false,
              "pinned_version": null
            }
          ]
        }
        """
        let entries = BrewService.parseOutdatedJSON(json, kind: .cask)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "bambu-studio")
        XCTAssertEqual(entries[0].currentVersion, "02.07.01.62,20260616174358")
        // 注意 cask 版本带逗号后缀,这是我们保留原样的现实
        XCTAssertEqual(entries[0].newestVersion, "02.08.02.60,20260814163036")
    }

    /// 首行可能是 API 下载警告,必须能用最后一行 JSON 兜底
    func testParseOutdatedWithLeadingGarbage() {
        let json = """
        ==> Downloading Homebrew API data
        ✔︎ JSON API packages.arm64.json
        {"formulae":[{"name":"wget","installed_versions":["1.24.5"],"current_version":"1.25.0"}],"casks":[]}
        """
        let entries = BrewService.parseOutdatedJSON(json, kind: .formula)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "wget")
    }

    /// 空结果也必须解析成功(返回 [])
    func testParseEmptyOutdated() {
        let json = #"{"formulae":[],"casks":[]}"#
        XCTAssertEqual(BrewService.parseOutdatedJSON(json, kind: .formula).count, 0)
        XCTAssertEqual(BrewService.parseOutdatedJSON(json, kind: .cask).count, 0)
    }

    /// brew tap-info --json 无参返回 [] 时,tap remote 应从文件系统收集
    func testTapInfoEmptyJSONDoesNotBreak() {
        // 这不报错即可,收集逻辑走 filesystem 通道
        let remotes = EnvDetector.collectTapRemotes(prefix: "/nonexistent-path")
        XCTAssertTrue(remotes.isEmpty)
    }

    /// 真实 brew list --formula --versions --json(6.0.x 实测格式)
    func testParseInstalledFormulaJSON() {
        let json = """
        {"formulae":[{"name":"autoconf","versions":["2.73"],"linked_version":"2.73","optlinked_version":"2.73","pinned_version":null},{"name":"bat","versions":["0.26.1"],"linked_version":"0.26.1","optlinked_version":"0.26.1","pinned_version":null}],"casks":[]}
        """
        let list = BrewService.parseInstalledList(json, kind: .formula)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "autoconf")
        XCTAssertEqual(list[0].version, "2.73")
        XCTAssertEqual(list[0].kind, .formula)
        XCTAssertFalse(list[0].isPinned)
    }

    /// 真实 brew list --cask --versions --json(cask 用 token 字段,注意不是 name)
    func testParseInstalledCaskJSONUsesToken() {
        let json = """
        {"formulae":[],"casks":[{"token":"ace-studio","versions":["2.1.3,2202"],"pinned_version":null},{"token":"arduino-ide","versions":["2.3.10"],"pinned_version":null}]}
        """
        let list = BrewService.parseInstalledList(json, kind: .cask)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "ace-studio")
        XCTAssertEqual(list[0].version, "2.1.3,2202")
        XCTAssertEqual(list[0].kind, .cask)
        // 带逗号后缀是 cask 版本现实
    }

    /// 解析 brew services list 的表格输出
    func testParseServicesOutput() {
        let out = """
        Name        Status    User  File
        mysql       started   user  ~/Library/LaunchAgents/homebrew.mxcl.mysql.plist
        redis       stopped   user  ~/Library/LaunchAgents/homebrew.mxcl.redis.plist
        """
        let services = BrewService.parseServicesOutput(out)
        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services[0].name, "mysql")
        XCTAssertTrue(services[0].isRunning)
        XCTAssertEqual(services[1].name, "redis")
        XCTAssertFalse(services[1].isRunning)
    }

    /// 真实 brew list 前常带 API 警告行,必须是整段解析失败后再逐行兜底(多行 JSON 也要能解析)
    func testParseInstalledListWithLeadingGarbageMultiline() {
        let json = """
        ==> Downloading Homebrew API data
        ✔︎ JSON API packages.arm64.json

        {
          "formulae": [
            {"name": "wget", "versions": ["1.25.0"], "linked_version": "1.25.0", "pinned_version": null}
          ],
          "casks": []
        }
        """
        let list = BrewService.parseInstalledList(json, kind: .formula)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "wget")
        XCTAssertEqual(list[0].version, "1.25.0")
    }

    /// 空 JSON 是合法结果(没装包),不是失败
    func testParseInstalledListEmptyIsValid() {
        let json = #"{"formulae":[],"casks":[]}"#
        let list = BrewService.parseInstalledList(json, kind: .formula)
        XCTAssertTrue(list.isEmpty)
    }

    // MARK: - 镜像源检测

    func testInferMirrorUSTC() {
        let text = "HOMEBREW_API_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles/api"
        XCTAssertEqual(EnvDetector.inferMirror(fromText: text), .ustc)
    }

    func testInferMirrorTsinghua() {
        let text = "export HOMEBREW_API_DOMAIN=https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
        XCTAssertEqual(EnvDetector.inferMirror(fromText: text), .tsinghua)
    }

    func testInferMirrorAliyun() {
        let text = "HOMEBREW_API_DOMAIN=https://mirrors.aliyun.com/homebrew-bottles/api"
        XCTAssertEqual(EnvDetector.inferMirror(fromText: text), .aliyun)
    }

    func testInferMirrorOfficial() {
        let text = "https://github.com/Homebrew/brew"
        XCTAssertEqual(EnvDetector.inferMirror(fromText: text), .official)
    }

    func testInferMirrorUnknown() {
        XCTAssertEqual(EnvDetector.inferMirror(fromText: "没有相关配置"), .unknown)
    }

    // MARK: - 下载 URL 提取与总大小探测

    /// Homebrew 官方 formula API 的真实结构：urls.stable.url 与 bottle.stable.files[tag].url。
    func testExtractDownloadURLFromOfficialFormulaFixtureUsesBottle() {
        let json = """
        {"formulae":[{"name":"wget","urls":{"stable":{"url":"https://ftpmirror.gnu.org/wget/wget-1.25.0.tar.gz","tag":null,"revision":null,"using":null,"checksum":"766e48423e79359ea31e41db9e5c289675947a7fcf2efdcedb726ac9d0da3784"},"head":{"url":"https://git.savannah.gnu.org/git/wget.git","branch":"master","using":null}},"bottle":{"stable":{"rebuild":0,"root_url":"https://ghcr.io/v2/homebrew/core","files":{"arm64_tahoe":{"cellar":"/opt/homebrew/Cellar","url":"https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:d89ea78fbc8ec79a80d52c7dcaa28e50c2bb435acd1470ee2cae4ef7646eff7e","sha256":"d89ea78fbc8ec79a80d52c7dcaa28e50c2bb435acd1470ee2cae4ef7646eff7e"},"arm64_sequoia":{"cellar":"/opt/homebrew/Cellar","url":"https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:899cfc98a094aa22f54d7b46762f2e9529dfa621bc2103d2612747ad251c633c","sha256":"899cfc98a094aa22f54d7b46762f2e9529dfa621bc2103d2612747ad251c633c"}}}}}],"casks":[]}
        """
        XCTAssertEqual(
            BrewService.extractDownloadURL(fromInfoJSON: json, platform: "arm64_tahoe"),
            "https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:d89ea78fbc8ec79a80d52c7dcaa28e50c2bb435acd1470ee2cae4ef7646eff7e"
        )
    }

    /// `brew --cache` 给出的 bottle tag 能识别 Homebrew 为新系统选择的旧版兼容 bottle。
    func testExtractDownloadURLUsesCacheSelectedCompatibleBottle() {
        let json = """
        {"formulae":[{"name":"fixture","urls":{"stable":{"url":"https://source.example/fixture-1.0.tar.gz"}},"bottle":{"stable":{"files":{"arm64_tahoe":{"url":"https://bottle.example/tahoe.tar.gz"},"arm64_sonoma":{"url":"https://bottle.example/sonoma.tar.gz"}}}}}],"casks":[]}
        """
        let selectedCache = URL(fileURLWithPath: "/tmp/brew-cache/fixture-1.0.arm64_sonoma.bottle.tar.gz")
        XCTAssertEqual(BrewService.extractDownloadURL(fromInfoJSON: json, platform: "arm64_tahoe", cacheFileURL: selectedCache),
                       "https://bottle.example/sonoma.tar.gz")
    }

    /// Intel macOS bottle key 是 `sequoia`，不带 `x86_64_` 前缀。
    func testExtractDownloadURLUsesIntelBottleTag() {
        let json = """
        {"formulae":[{"name":"fixture","urls":{"stable":{"url":"https://source.example/fixture-1.0.tar.gz"}},"bottle":{"stable":{"files":{"sequoia":{"url":"https://bottle.example/intel-sequoia.tar.gz"},"sonoma":{"url":"https://bottle.example/intel-sonoma.tar.gz"}}}}}],"casks":[]}
        """
        let selectedCache = URL(fileURLWithPath: "/tmp/brew-cache/fixture-1.0.sequoia.bottle.tar.gz")
        XCTAssertEqual(BrewService.extractDownloadURL(fromInfoJSON: json, platform: "sequoia", cacheFileURL: selectedCache),
                       "https://bottle.example/intel-sequoia.tar.gz")
    }

    func testBottlePlatformUsesHomebrewIntelMacOSKeys() {
        XCTAssertEqual(BrewService.bottlePlatform(architecture: "x86_64", macOSMajorVersion: 15), "sequoia")
        XCTAssertEqual(BrewService.bottlePlatform(architecture: "arm64", macOSMajorVersion: 15), "arm64_sequoia")
    }

    func testUnknownSelectedBottleDoesNotUseSourceSizeAsBottleSize() {
        let json = """
        {"formulae":[{"name":"fixture","urls":{"stable":{"url":"https://source.example/fixture-1.0.tar.gz"}},"bottle":{"stable":{"files":{"arm64_tahoe":{"url":"https://bottle.example/tahoe.tar.gz"}}}}}],"casks":[]}
        """
        let selectedCache = URL(fileURLWithPath: "/tmp/brew-cache/fixture-1.0.unknown.bottle.tar.gz")
        XCTAssertNil(BrewService.extractDownloadURL(fromInfoJSON: json, platform: "arm64_tahoe", cacheFileURL: selectedCache))
    }

    func testExtractDownloadURLFallsBackToStableSourceWhenNoBottleExists() {
        let json = """
        {"formulae":[{"name":"fixture","urls":{"stable":{"url":"https://source.example/fixture-1.0.tar.gz"}},"bottle":{"stable":{"files":{}}}}],"casks":[]}
        """
        XCTAssertEqual(BrewService.extractDownloadURL(fromInfoJSON: json, platform: "arm64_tahoe"),
                       "https://source.example/fixture-1.0.tar.gz")
    }

    /// cask 的 info JSON 用 url 字段
    func testExtractDownloadURLFromCask() {
        let json = """
        {"formulae":[],"casks":[{"token":"bambu-studio","url":"https://github.com/bambulab/BambuStudio/releases/download/v1/b.dmg"}]}
        """
        XCTAssertEqual(BrewService.extractDownloadURL(fromInfoJSON: json), "https://github.com/bambulab/BambuStudio/releases/download/v1/b.dmg")
    }

    /// cask 下载源只取 cask 的实际顶层 url，不把任意 artifact URL 当作包体。
    func testExtractDownloadURLDoesNotGuessCaskArtifactURL() {
        let json = """
        {"formulae":[],"casks":[{"token":"some-app","url":null,"artifacts":[{"url":"https://a.example.com/some.dmg"}]}]}
        """
        XCTAssertNil(BrewService.extractDownloadURL(fromInfoJSON: json))
    }

    /// 无任何 URL 信息返回 nil
    func testExtractDownloadURLNil() {
        let json = #"{"formulae":[],"casks":[]}"#
        XCTAssertNil(BrewService.extractDownloadURL(fromInfoJSON: json))
    }

    // MARK: - cask auto_updates 解析

    /// 批量 info JSON:auto_updates true/false 都正确映射
    func testParseCaskAutoUpdatesMixed() {
        let json = """
        {"formulae":[],"casks":[{"token":"google-chrome","auto_updates":true},{"token":"bambu-studio","auto_updates":false}]}
        """
        let flags = BrewService.parseCaskAutoUpdates(fromInfoJSON: json)
        XCTAssertEqual(flags["google-chrome"], true)
        XCTAssertEqual(flags["bambu-studio"], false)
        XCTAssertEqual(flags.count, 2)
    }

    /// 缺失 auto_updates 字段的 cask 不出现在结果里(不误报 false)
    func testParseCaskAutoUpdatesMissingFieldIgnored() {
        let json = """
        {"formulae":[],"casks":[{"token":"plain-app"}]}
        """
        let flags = BrewService.parseCaskAutoUpdates(fromInfoJSON: json)
        XCTAssertTrue(flags.isEmpty)
    }

    /// 空 JSON 返回空字典
    func testParseCaskAutoUpdatesEmpty() {
        XCTAssertTrue(BrewService.parseCaskAutoUpdates(fromInfoJSON: #"{"formulae":[],"casks":[]}"#).isEmpty)
    }
}
