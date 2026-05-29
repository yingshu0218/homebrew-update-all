class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持 -a / 交互选择 / 自动模式"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "5db4202cab8663b74360863f77da8c8f0d9eaf80c50acc1b8537914c4c2b6d91"

  def install
    bin.install "brew-ua"
  end
end
