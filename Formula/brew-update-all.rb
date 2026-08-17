class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.7.tar.gz"
  sha256 "37b2ce4c91be43accfa5a1ed531c363c02d7d160e39994bbbd9a6e2af94aa87c"

  def install
    bin.install "brew-ua"
  end

  test do
    assert_match "brew ua", shell_output("#{bin}/brew-ua --help")
  end
end
