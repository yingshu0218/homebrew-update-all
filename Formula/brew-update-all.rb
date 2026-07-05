class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.4.0.tar.gz"
  sha256 "8289120db3493a74eb80a491a9722fa67c67045ac3e9b9a99b692684914f1b42"

  def install
    bin.install "brew-ua"
  end
end
