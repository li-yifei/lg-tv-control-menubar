# LG TV Control

Small macOS menu bar app and CLI for controlling an LG webOS TV.

The app talks to the TV directly from Swift over the webOS WebSocket API and the LG IP-control TCP protocol. Pairing credentials (client key, IP control keycode) live in macOS Keychain under the `com.lgtv-control` service; non-secret config (host, MAC addresses) stays in a JSON file at `~/.config/lgtv-pairing.json`.

## Install

```sh
brew install --cask li-yifei/tap/lgtv-control
```

This installs the menu bar app to `/Applications` and symlinks a `lgtv` CLI into Homebrew's bin directory. The app is self-signed, so the cask strips the quarantine attribute on install.

To uninstall:

```sh
brew uninstall --cask lgtv-control
```

## First run

1. Launch **LG TV Control** from Spotlight or Launchpad.
2. From the menu bar icon → **Pair / Re-pair**, enter the TV's IP and accept the on-screen prompt on the TV. The client key is saved to Keychain.
3. (Optional, only needed for service-menu PIN entry) On the TV, navigate to **Settings → All Settings → Network → LG Connect Apps** and copy the 8-character IP control keycode. In the menu bar app open **Settings → IP Control Keycode**, paste it, and save.

## Features

- Volume up / down, mute toggle, set volume by slider
- Safety volume reminder with configurable threshold
- Power on (Wake-on-LAN with auto-discovered MACs) and power off
- HDMI input list and switching
- **Extra → InStart / EZ Adjust**: launch LG service menus and auto-type the 4-digit PIN over IP control
- App Intents for Shortcuts and Siri (power, volume, mute, input switching)
- Customizable single-letter menu shortcuts
- Structured CLI (`lgtv`) with `--json` for scripts and Shortcuts shell actions

## CLI

```sh
lgtv --help
lgtv status --json
lgtv volume set 12
lgtv volume up --steps 3
lgtv mute toggle
lgtv power on
lgtv input list
lgtv input switch HDMI_2
lgtv raw ssap://audio/getVolume --json
```

Reads `LG_TV_CONFIG` first, then `~/.config/lgtv-pairing.json`. Individual commands can override with `--config PATH`. Data commands write JSON to stdout with `--json`; failures go to stderr with non-zero exit.

## Build from source

```sh
./build.sh
```

Produces `build/LG TV Control.app`, `build/bin/lgtv`, and `build/LG-TV-Control.app.zip` (release artifact).

For stable Keychain access across rebuilds, generate a local self-signed code signing cert once:

```sh
./scripts/setup-codesign.sh
```

Requires `openssl@3` (`brew install openssl@3`). Without the cert, `build.sh` falls back to ad-hoc signing, and macOS will re-prompt for Keychain authorization on every rebuild.

## License

[MIT](LICENSE). Bundled third-party software (Apple's [swift-argument-parser](https://github.com/apple/swift-argument-parser), Apache 2.0) is acknowledged in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
