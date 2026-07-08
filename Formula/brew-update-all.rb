class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.6.3.tar.gz"
  sha256 "28b5982c23e3e42a24ebc99e975b646a70dfff8ecd438eb7ca1fcc0071434a2c"

  def install
    bin.install "brew-ua"
  end
end
