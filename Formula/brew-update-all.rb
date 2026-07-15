class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.9.tar.gz"
  sha256 "c55201b42d9ce6f1ebea214c67b63d1f2b434f3339fea668366f31f5864c13cd"

  def install
    bin.install "brew-ua"
  end
end
