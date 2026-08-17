class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.6.tar.gz"
  sha256 "8f4c46604c774ab7985f9a5063be76ece1159a3545ce0926e3b6f0f4ef246163"

  def install
    bin.install "brew-ua"
  end

  test do
    assert_match "brew ua", shell_output("#{bin}/brew-ua --help")
  end
end
