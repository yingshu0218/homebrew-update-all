class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.4.tar.gz"
  sha256 "732d0369115401f22c44c8f18c9448fa1b3f022a9c2171e5cdba0f5868d9aaf4"

  def install
    bin.install "brew-ua"
  end
end
