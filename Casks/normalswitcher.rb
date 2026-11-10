cask "normalswitcher" do
  version "1.1.6"
  sha256 "053c4011c15d9882c8bdf47ab91c02ac24cabf6b4f6023f00096c125635cf340"

  url "https://github.com/Thalassiochthon/NormalSwitcher/releases/download/v#{version}/NormalSwitcher-#{version}.dmg"
  name "NormalSwitcher"
  desc "Correct text typed in the wrong keyboard layout"
  homepage "https://github.com/Thalassiochthon/NormalSwitcher"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :ventura

  app "NormalSwitcher.app"
end
