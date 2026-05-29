class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持交互选择或自动模式"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "SHA256_PLACEHOLDER"

  def install
    bin.install "brew-ua"
  end
end
