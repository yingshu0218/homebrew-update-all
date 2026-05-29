class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持 --greedy / 交互选择 / 自动模式"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "3a02d5ebfffd96d36c5b0389bb02b00ae868315f31b28eed2fa6718ac9a63842"

  def install
    bin.install "brew-ua"
  end
end
