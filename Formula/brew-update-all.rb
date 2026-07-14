class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.6.tar.gz"
  sha256 "b7ffc45da427d181fbf65e623a869aad70c6e8665975ef5831100a4bc7219e18"

  def install
    bin.install "brew-ua"
  end
end
