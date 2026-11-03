# version and sha256 are updated by `make publish`.
cask "reclaim" do
  version "0.1.1"
  sha256 "34659fc0cf7ef0cb598c2ec39c37aaf64ac35705d907a955a087fcea85eef912"

  url "https://github.com/PanterSoft/Reclaim/releases/download/v#{version}/Reclaim-#{version}.zip"
  name "Reclaim"
  desc "Free up disk space with APFS clones and transparent compression"
  homepage "https://github.com/PanterSoft/Reclaim"

  depends_on macos: :ventura

  app "Reclaim.app"
  binary "#{appdir}/Reclaim.app/Contents/Resources/reclaim"

  # ponytail: release builds are ad-hoc signed; drop this once signed with a Developer ID.
  app_path = "#{appdir}/Reclaim.app"
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", app_path],
                          writable_paths: ["Reclaim.app"], writable_base: :appdir
  end

  uninstall quit: "io.github.reclaim.Reclaim"

  zap trash: [
    "~/Library/Logs/Reclaim",
    "~/Library/Preferences/io.github.reclaim.Reclaim.plist",
  ]
end
