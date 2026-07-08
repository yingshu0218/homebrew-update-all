class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.6.4.tar.gz"
  sha256 "7d316b4abc42f19773970f7847db4dd63e2a9d36d6c0e88417483ae3146eddad"

  def install
    bin.install "brew-ua"
  end
end
