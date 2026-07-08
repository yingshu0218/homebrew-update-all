class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.0.tar.gz"
  sha256 "2865152686c5694d15f33033707d40d26c9bd45c2fd109a0e4369539ec0d811f"

  def install
    bin.install "brew-ua"
  end
end
