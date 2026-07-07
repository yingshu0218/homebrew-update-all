class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.6.1.tar.gz"
  sha256 "223cff0f62c4e5d792945fa05e17becb606fc8c3f890848107643a47ebb82e36"

  def install
    bin.install "brew-ua"
  end
end
