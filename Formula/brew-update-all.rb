class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.5.1.tar.gz"
  sha256 "ce957196e6b7d40df5da0f61fc1c07746753a088a54a449a34798b2ed5f3ab05"

  def install
    bin.install "brew-ua"
  end
end
