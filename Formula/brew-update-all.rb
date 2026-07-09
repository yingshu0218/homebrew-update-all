class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.4.tar.gz"
  sha256 "d26ae93b252741af0c383b3f5921f797e5c62ab78577e2591e158180f65acbc8"

  def install
    bin.install "brew-ua"
  end
end
