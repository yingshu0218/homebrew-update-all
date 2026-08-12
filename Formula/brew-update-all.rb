class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.5.tar.gz"
  sha256 "98bfebed619db7e9d765c6a7f769fd8fc0416599918df9b2a6c164ed896f8755"

  def install
    bin.install "brew-ua"
  end
end
