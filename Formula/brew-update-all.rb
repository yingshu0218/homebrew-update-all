class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.6.0.tar.gz"
  sha256 "2704872067547260ed976ac4c31d2bca98156b16d11fad20294e8f27c2b4d706"

  def install
    bin.install "brew-ua"
  end
end
