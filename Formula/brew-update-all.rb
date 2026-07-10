class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.5.tar.gz"
  sha256 "ebe0a0c6771ecaeb204c8b1b74ce2bba83621b066eb43d4b5356d47fffebea9e"

  def install
    bin.install "brew-ua"
  end
end
