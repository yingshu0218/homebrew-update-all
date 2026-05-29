class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持交互选择或自动模式"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "5fb0efd164dbe752b36bc57c3751450aaa7eb8e26a4bca4233944c0fa0a1eace"

  def install
    bin.install "brew-ua"
  end
end
