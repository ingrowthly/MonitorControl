cask "monitorcontrol-autobrightness" do
  version :latest
  sha256 :no_check

  url "https://github.com/ingrowthly/MonitorControl/releases/latest/download/MonitorControl.dmg"
  name "MonitorControl"
  desc "MonitorControl with ambient-sensor automatic brightness"
  homepage "https://github.com/ingrowthly/MonitorControl"

  conflicts_with cask: "monitorcontrol"
  depends_on macos: :tahoe

  app "MonitorControl.app"

  zap trash: [
    "~/Library/Application Support/MonitorControl",
    "~/Library/Preferences/com.ingrowthly.MonitorControl.plist",
    "~/Library/Saved Application State/com.ingrowthly.MonitorControl.savedState",
  ]
end
