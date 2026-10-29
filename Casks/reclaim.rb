# version and sha256 are updated by `make publish`.
cask "reclaim" do
  version "0.1.0"
  sha256 "b68177201c692e37a738f9bc30584be7368363b7320f1c88c19a8a6b23bdbaff"

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
