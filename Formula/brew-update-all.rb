class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.7.tar.gz"
  sha256 "face1f4426813eea0fd690333a005a2f9eb791f62af154a10fdbe177147a6cd7"

  def install
    bin.install "brew-ua"
  end

  test do
    assert_match "brew ua", shell_output("#{bin}/brew-ua --help")
  end
end
