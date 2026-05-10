cask "lgtv-control" do
  version "0.5.0"
  sha256 "f82454b9dc767758eeb253694369338fbf7545ac13d31d3217a9b3326eeaebf9"

  url "https://github.com/li-yifei/lg-tv-control-menubar/releases/download/v#{version}/LG-TV-Control.app.zip"
  name "LG TV Control"
  desc "Menu bar app and CLI for controlling an LG webOS TV"
  homepage "https://github.com/li-yifei/lg-tv-control-menubar"

  app "LG TV Control.app"
  binary "#{appdir}/LG TV Control.app/Contents/MacOS/LGTVControl", target: "lgtv"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/LG TV Control.app"],
                   sudo: false
  end

  zap trash: [
    "~/.config/lgtv-pairing.json",
  ]
end
