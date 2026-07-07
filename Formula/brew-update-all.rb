class BrewUpdateAll < Formula
  desc "逐个升级 Homebrew formulae 和 cask，支持包大小显示 / 下载速度 / 深度清理 / 更新进度"
  homepage "https://github.com/yingshu0218/homebrew-update-all"
  url "https://github.com/yingshu0218/homebrew-update-all/archive/refs/tags/v1.6.2.tar.gz"
  sha256 "8774f2b00040776c57520f3eef93be727366054a01b7761d8030327cdb1d17dd"

  def install
    bin.install "brew-ua"
  end
end
