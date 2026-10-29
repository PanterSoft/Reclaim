# version and sha256 are updated by `make publish`.
cask "reclaim" do
  version "0.1.0"
  sha256 "eb35d8b1a0db9826f9fecfcc47cee841c94f10e4f09ea99b7a05d0bff6b28c2f"

  url "https://github.com/PanterSoft/Reclaim/releases/download/v#{version}/Reclaim-#{version}.zip"
  name "Reclaim"
  desc "Free up disk space with APFS clones and transparent compression"
  homepage "https://github.com/PanterSoft/Reclaim"

  depends_on macos: ">= :ventura"

  app "Reclaim.app"
  binary "#{appdir}/Reclaim.app/Contents/Resources/reclaim"

  # ponytail: release builds are ad-hoc signed; drop this once signed with a Developer ID.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Reclaim.app"]
  end

  uninstall quit: "io.github.reclaim.Reclaim"

  zap trash: [
    "~/Library/Logs/Reclaim",
    "~/Library/Preferences/io.github.reclaim.Reclaim.plist",
  ]
end
