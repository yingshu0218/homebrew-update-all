class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.0.tar.gz"
  sha256 "fc77471d66046dd60008ee45cb85a83a4762dc804c08e976762426b18cab1024"

  def install
    bin.install "brew-ua"
  end
end
