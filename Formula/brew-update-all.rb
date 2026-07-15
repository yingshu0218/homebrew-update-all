class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.8.tar.gz"
  sha256 "0e3ef4e744c2d7507bbf2ed8c8a3173af459f8f9d0b6ff4bff64916b8709cab9"

  def install
    bin.install "brew-ua"
  end
end
