class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持分类升级 / 彩色界面 / 进度条 / 耗时统计"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.3.0.tar.gz"
  sha256 "755e2b92408c77364709ca0fa6c78dabda26809333bc59a90c14d673877055ac"

  def install
    bin.install "brew-ua"
  end
end
