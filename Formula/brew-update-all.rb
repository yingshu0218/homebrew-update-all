class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.10.tar.gz"
  sha256 "437413e103c2981344ca4b9f484808c8f286d3c90fd05b43460a8778d4cef7fa"

  def install
    bin.install "brew-ua"
  end
end
