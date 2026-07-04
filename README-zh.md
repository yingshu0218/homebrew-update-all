# brew-update-all

逐个升级 Homebrew formula 和 cask，支持交互选择和自动模式。
避免因网络问题导致批量升级失败，一个包出错不影响其他包。

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
```

| 模式 / 选项 | 说明 |
|------|------|
| *(空)* | 交互模式，输入序号选择要升级的包 |
| `auto` | 自动模式，跳过交互直接升级全部 |
| `formula` | 只升级 formula（交互模式） |
| `cask` | 只升级 cask（交互模式） |
| `-a` | 扫描所有 cask，包含自带自动更新的应用（Chrome、VS Code、Edge 等） |

> **提示**：不加 `-a` 时，Homebrew 默认跳过 `auto_updates true` 的应用，因为它们会自己后台更新。如果你希望精确控制所有包的版本，加上 `-a`。

## 功能特性

- 🎨 **彩色界面** – 清晰的颜色区分和精致边框排版
- 📊 **进度条** – 实时显示升级进度和百分比
- ⏱️ **耗时统计** – 每个包的升级耗时和总耗时
- 📋 **统计摘要** – 升级完成后展示成功/失败数量和详细列表
- 🎯 **分类升级** – 支持只升级 formula 或只升级 cask
- 🔍 **日志记录** – 失败的包自动保存日志到 `/tmp/`

## 脚本流程

1. **brew update** – 更新源和包信息
2. **列出可更新包** – formula 和 cask 分类展示在带边框的面板中
3. **逐个升级** – 每个包独立下载→安装，带进度条和耗时显示，失败继续下一个
4. **brew cleanup** – 清理旧版本
5. **统计摘要** – 展示总耗时、成功率、成功/失败包列表

## 卸载

```bash
brew uninstall brew-update-all
brew untap yingshu0218/update-all
```

## 许可证

MIT
