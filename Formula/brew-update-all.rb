class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.3.tar.gz"
  sha256 "751bcb0358314fddf1bb7ed763b521fe6b9400544bb5e2b95f6cd4df15cfbe19"

  def install
    bin.install "brew-ua"
  end
end
