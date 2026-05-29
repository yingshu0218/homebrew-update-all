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

# 包含自动更新应用 – 默认跳过 Chrome/VS Code 等自带更新的 cask
brew ua -a
brew ua auto -a
```

| 选项 | 说明 |
|------|------|
| `auto` | 自动模式，跳过交互直接升级全部 |
| `-a` | 扫描所有 cask，包含自带自动更新的应用（Chrome、VS Code、Edge 等） |

> **提示**：不加 `-a` 时，Homebrew 默认跳过 `auto_updates true` 的应用，因为它们会自己后台更新。如果你希望精确控制所有包的版本，加上 `-a`。

## 脚本流程

1. **brew update** – 更新源和包信息
2. **列出可更新包** – formula 和 cask 连续编号列出（中间 `---` 分隔）
3. **逐个升级** – 每个包独立下载→安装，失败继续下一个
4. **brew cleanup** – 清理旧版本

## 卸载

```bash
brew uninstall brew-update-all
brew untap yingshu0218/update-all
```

## 许可证

MIT
