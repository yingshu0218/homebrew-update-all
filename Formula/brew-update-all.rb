class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.1.tar.gz"
  sha256 "2cabf56f39d63e931b2a3d7541ea7184998f340dc3b29c4eec2b400f0173737e"

  def install
    bin.install "brew-ua"
  end
end
