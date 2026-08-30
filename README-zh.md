# brew-update-all

逐个升级 Homebrew formula 和 cask，支持交互选择和自动模式。
避免因网络问题导致批量升级失败，一个包出错不影响其他包。

## BrewUA — 图形界面版

**BrewUA** 是原生 SwiftUI macOS 应用（位于 `BrewUA/`），把同样的两阶段升级策略搬到可视化界面：

- 🏪 **应用商店式升级中心** — 检查更新、勾选清单、更新所选/全部更新
- 📦 **逐包进度** — 包大小（HTTP HEAD 探测）、实时下载速度、状态徽章（等待/下载中/已下载/安装中/完成/失败）
- 📚 **包管理页** — 浏览、搜索、升级、PIN 徽标、卸载、「仅看屏蔽」过滤
- 🔒 **升级屏蔽列表** — 与 CLI 共享同一份配置（`~/.config/brew-ua/ignored_casks`）
- 🖥 **服务管理页** — `brew services` 启停
- 🪞 **镜像源检测** — 中科大/清华/阿里云/官方自动识别（感知 shell 配置）
- 🏷 **cask 自更新徽标** — 标识应用是否自带自动更新（`auto_updates`）

源码构建需 Xcode（工程由 `BrewUA/project.yml` 经 `xcodegen` 生成）。GUI 与 CLI 版本线独立（GUI 1.x / CLI 1.8.x）。

## 安装

```bash
brew tap yingshu0218/update-all
brew install brew-update-all
```

## 使用

```bash
# 交互模式 – 输入序号选择要更新的包
brew ua

# 自动模式 – 不提示，全部更新
brew ua auto

# 只升级 formula
brew ua formula

# 只升级 cask
brew ua cask

# 包含自动更新应用 – 默认跳过 Chrome/VS Code 等自带更新的 cask
brew ua -a
brew ua auto -a
brew ua formula -a
brew ua cask -a

# 升级后深度清理下载缓存
brew ua auto --prune

# 升级后清理本次产生的临时日志
brew ua auto --clean-logs

# 环境诊断（网络 / Tap 源 / 本地配置）
brew ua ck

# 屏蔽某个 cask（不参与更新），解除屏蔽，查看屏蔽列表
brew ua ig firefox
brew ua uig firefox
brew ua igl
```

| 模式 / 选项 | 说明 |
|------|------|
| *(空)* | 交互模式，输入序号选择要升级的包 |
| `auto` | 自动模式，跳过交互直接升级全部 |
| `formula` | 只升级 formula（交互模式） |
| `cask` | 只升级 cask（交互模式） |
| `-a` | 扫描所有 cask，包含自带自动更新的应用（Chrome、VS Code、Edge 等） |
| `--prune` | 升级后深度清理下载缓存（`brew cleanup --prune=all`） |
| `--clean-logs` | 升级后清理本次产生的临时日志文件 |
| `ck` / `check` | 环境诊断：网络、Tap 源、本地配置检测 |
| `ig` / `ignore <cask>` | 屏蔽指定 cask，不再出现在更新列表 |
| `uig` / `unignore <cask>` | 解除屏蔽 |
| `igl` / `ignored` | 查看当前屏蔽列表 |

> **提示**：不加 `-a` 时，Homebrew 默认跳过 `auto_updates true` 的应用，因为它们会自己后台更新。如果你希望精确控制所有包的版本，加上 `-a`。

## 功能特性

- 🎨 **彩色界面** – 清晰的颜色区分和精致边框排版
- 📊 **进度条** – 实时显示整体升级进度和百分比
- ⏱️ **耗时统计** – 每个包的升级耗时和总耗时
- 📋 **统计摘要** – 升级完成后展示成功/失败数量和详细列表
- 🎯 **分类升级** – 支持只升级 formula 或只升级 cask
- 🚫 **屏蔽列表** – 可屏蔽指定 cask，升级时自动跳过
- 🔍 **日志记录** – 失败的包自动保存日志到独立临时目录（`/tmp/brew-ua.XXXXXX`）
- 📦 **包大小显示** – 下载后自动解析并显示每个包的大小
- ⚡ **下载速度** – formula 与 cask 下载时均实时显示进度与 MB/s 速度
- 🌀 **加载动画** – 升级过程中的 spinner 动画，实时反馈运行状态
- 🧹 **清理选项** – 支持深度清理下载缓存和临时日志

## 脚本流程

1. **brew update** – 更新源和包信息
2. **列出可更新包** – formula 和 cask 分类展示在带边框的面板中
3. **阶段 1：逐个下载** – 每个包独立下载，带进度条、实时速度、单包超时（默认 10 分钟）与失败隔离；下载卡住会被终止并跳过，不影响其他包
4. **阶段 2：逐个安装** – 只安装下载成功的包（cask 用 `brew reinstall`，formula 用 `brew upgrade`，命中缓存不重复下载）
5. **brew cleanup** – 清理旧版本
6. **统计摘要** – 展示总耗时、成功率、成功/失败包列表

## 最近更新

### v1.8.7 (2026-08-20)

- 🖥 **BrewUA 图形界面** — 原生 SwiftUI 应用：应用商店式升级中心、包管理、服务管理、镜像源检测
- 🐛 **闪退根治** — 引擎与数据流全面 `@MainActor` 隔离，杜绝后台线程改 UI 状态导致的崩溃
- ⚡ **下载体验** — HEAD 探测包大小、缓存轮询实时速度、按阶段状态徽章
- 🔒 **屏蔽列表 UI** — 红色上锁开关 +「仅看屏蔽」过滤

### v1.8.5 (2026-08-13)

- 🏗️ **两阶段升级** – 先逐个下载全部更新包（实时速度、单包超时、失败隔离），再统一安装下载成功的包；单个下载卡住不再拖垮其他包
- ⚡ **formula 下载速度** – formula 与 cask 一样实时显示 MB/s 速度
- 🖥️ **非 TTY 输出** – 管道/重定向时输出纯文本，无 ANSI 控制符噪音
- 🧪 **测试体系 + CI** – `scripts/test.sh` 冒烟测试（速度/大小/两阶段顺序/超时/失败隔离/非 TTY），CI 自动跑语法检查、测试与 `brew audit`
- 🔒 **严格模式与单实例锁** – 未定义变量立即报错；重复运行 brew-ua 会被拦截
- 📢 **版本自检** – 有新版本时自动提示升级

### v1.8.4 (2026-08-13)

- 🐛 **修复 brew 6.x 兼容**：`brew --verbose fetch` 在 Homebrew 6.x 报 "Unknown command"，导致 cask 全部失败；改用环境变量 `HOMEBREW_VERBOSE=1` 传递全局选项
- ⚡ **下载速度**：自研解析 brew 下载进度（`Downloading X/Y`），在状态行实时显示 MB/s 速度与下载进度条
- 🤖 **发布自动化**：打 `v*` tag 时自动下载 tarball 计算 sha256 并更新 Formula，不再手动发版

### v1.8.3 (2026-08-12)

- 🐛 **修复下载失败被误判为成功**：fetch 退出码取错管道位置（恒取到 tee 的 0），已改取 brew 实际退出码
- 🐛 **修复升级界面内容残留**：下载/安装阶段行数错位导致界面重叠，改用保存光标 + 清屏后统一重画
- 🐛 **修复包大小始终显示 `?`**：支持 curl 的 `20.0M` / `121k` 大小格式
- 🛡️ **临时日志安全加固**：日志从 `/tmp` 固定文件名改为独立临时目录

## 卸载

```bash
brew uninstall brew-update-all
brew untap yingshu0218/update-all
```

## 许可证

MIT
