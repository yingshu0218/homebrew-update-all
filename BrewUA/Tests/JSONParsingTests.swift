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

    /// formula 的 info JSON 里 urls 数组优先
    func testExtractDownloadURLFromFormula() {
        let json = """
        {"formulae":[{"name":"wget","urls":["https://mirror.example.com/wget.tar.gz"],"url":"https://fallback.example.com/wget.tar.gz"}],"casks":[]}
        """
        XCTAssertEqual(BrewService.extractDownloadURL(fromInfoJSON: json), "https://mirror.example.com/wget.tar.gz")
    }

    /// formula 无 urls 数组时回退 url 字段
    func testExtractDownloadURLFromFormulaFallback() {
        let json = """
        {"formulae":[{"name":"wget","url":"https://fallback.example.com/wget.tar.gz"}],"casks":[]}
        """
        XCTAssertEqual(BrewService.extractDownloadURL(fromInfoJSON: json), "https://fallback.example.com/wget.tar.gz")
    }

    /// cask 的 info JSON 用 url 字段
    func testExtractDownloadURLFromCask() {
        let json = """
        {"formulae":[],"casks":[{"token":"bambu-studio","url":"https://github.com/bambulab/BambuStudio/releases/download/v1/b.dmg"}]}
        """
        XCTAssertEqual(BrewService.extractDownloadURL(fromInfoJSON: json), "https://github.com/bambulab/BambuStudio/releases/download/v1/b.dmg")
    }

    /// cask 无顶层 url 时回退 artifacts 里的 url
    func testExtractDownloadURLFromCaskArtifactsFallback() {
        let json = """
        {"formulae":[],"casks":[{"token":"some-app","url":null,"artifacts":[{"url":"https://a.example.com/some.dmg"}]}]}
        """
        XCTAssertEqual(BrewService.extractDownloadURL(fromInfoJSON: json), "https://a.example.com/some.dmg")
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