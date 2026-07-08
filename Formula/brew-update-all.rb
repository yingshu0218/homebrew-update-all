class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.7.2.tar.gz"
  sha256 "c9e3bc041decceb95be45a462df28200baf6077ef4db22ce5102a75219318eb5"

  def install
    bin.install "brew-ua"
  end
end
