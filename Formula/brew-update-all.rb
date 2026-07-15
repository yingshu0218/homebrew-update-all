class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.7.tar.gz"
  sha256 "b7e165b0d5be4222224cfb2e95c0ff2311d9c9ec0ba154e682ebd9a7443bb9fb"

  def install
    bin.install "brew-ua"
  end
end
