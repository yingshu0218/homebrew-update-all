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
```

## 脚本流程

1. **brew update** – 更新源和包信息
2. **列出可更新包** – formula 和 cask 连续编号列出（中间 `---` 分隔）
3. **逐个升级** – 每个包独立下载→安装，失败继续下一个
4. **brew cleanup** – 清理旧版本

## 许可证

MIT
