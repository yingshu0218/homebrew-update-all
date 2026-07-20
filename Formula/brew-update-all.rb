class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.8.1.tar.gz"
  sha256 "66235e546d1e78dc427f80f7e9dc4e02e982689f5d102a40a825f898d8143030"

  def install
    bin.install "brew-ua"
  end
end
