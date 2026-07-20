class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.2.tar.gz"
  sha256 "fe129eaa328638178ba6909f7c05428fe0fce7ea438bf4296da708e4ec8a4fb4"

  def install
    bin.install "brew-ua"
  end
end
