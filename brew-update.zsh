#!/bin/zsh

set -e

echo "=== 1. 更新 Homebrew 源 ==="
brew update

echo ""
echo "=== 2. 升级 formulae（逐个下载安装）==="
for formula in $(brew outdated --formula --quiet); do
    echo "→ 正在升级 formula: $formula"
    if brew upgrade "$formula"; then
        echo "✓ $formula 升级完成"
    else
        echo "✗ $formula 升级失败，继续下一个"
    fi
done

echo ""
echo "=== 3. 升级 casks（逐个下载安装）==="
for cask in $(brew outdated --cask --quiet); do
    echo "→ 正在升级 cask: $cask"
    if brew upgrade --cask "$cask"; then
        echo "✓ $cask 升级完成"
    else
        echo "✗ $cask 升级失败，继续下一个"
    fi
done

echo ""
echo "=== 4. 清理旧版本 ==="
brew cleanup

echo ""
echo "✅ 全部完成"
