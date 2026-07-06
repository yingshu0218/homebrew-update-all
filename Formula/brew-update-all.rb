class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.5.0.tar.gz"
  sha256 "6a6f38dcc36769adeb492e82d8e7b00251e0b9a9a15a651ec37edce4462e80ea"

  def install
    bin.install "brew-ua"
  end
end
