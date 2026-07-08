class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.6.5.tar.gz"
  sha256 "959bf943de03cfe0533928f49a44aaec61c4651cd2f1d633aa53ca93a4edf73d"

  def install
    bin.install "brew-ua"
  end
end
