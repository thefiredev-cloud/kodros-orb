# Build guide: kodros-orb

The app builds and runs on macOS only. The Pi client tests also run on Linux. The full app build was not run on the Linux workstation that prepared this guide.

## You need

- macOS 14 or later on Apple silicon.
- `swiftc` from Xcode or the Command Line Tools.
- A code-signing identity in your keychain. A self-signed certificate works. The default name is `MeshVault Local Code Signing`. To use another name, set `SIGN_IDENTITY`.
- The `pi` executable for the Pi coding agent.

## Create a signing identity

macOS drops Screen Recording, Microphone and Speech Recognition grants every time an ad-hoc signed app is rebuilt. A stable identity keeps them.

1. Open Keychain Access, then Certificate Assistant, then Create a Certificate.
2. Name it `MeshVault Local Code Signing` (or your own name), set Identity Type to Self Signed Root and Certificate Type to Code Signing.
3. Run `security find-identity -p codesigning` and confirm the name appears.

On a host without GUI access you can keep the identity in its own keychain. Set both variables and `build.sh` unlocks that keychain and signs by hash:

```bash
export SIGN_KEYCHAIN="$HOME/Library/Keychains/orb-signing.keychain-db"
export SIGN_KEYCHAIN_PASSWORD_FILE="$HOME/.orb-signing-password"   # file holding the keychain password
```

## Build

```bash
git clone https://github.com/thefiredev-cloud/kodros-orb.git
cd kodros-orb
./build.sh
```

`build.sh` compiles `Sources/*.swift` with `swiftc -O -whole-module-optimization -target arm64-apple-macosx14.0`, packs `Kodros Orb.app`, signs it with identifier `ai.meshvault.piorb` and verifies the signature. It stops with an error if the identity is missing.

## Install

```bash
./install.sh
```

This runs `build.sh`, copies the app to `~/Applications/Kodros Orb.app`, writes `~/Library/LaunchAgents/ai.meshvault.piorb.plist` and starts it with `launchctl bootstrap` and `kickstart`. An older `Mesh Orb.app` in `~/Applications` is moved aside to `Mesh Orb.app.bak-<date>`, not deleted. Run `install.sh` only on a Mac you own.

## Test

The Pi client suite compiles with plain `swiftc`, so it runs on Linux too:

```bash
swiftc Sources/PiClient.swift Sources/SlashCommandCompletion.swift Sources/Speakable.swift Tests/PiClientTests.swift -o /tmp/orb-tests
PI_EXECUTABLE="$PWD/Tests/Fixtures/fake-pi" /tmp/orb-tests
```

On 2026-11-18 this ran 9 tests on Linux with Swift 6.4.2 and all passed. `Tests/Fixtures/fake-pi` is a stand-in for the real agent.

## First run

Click the orb or press Option-Space. macOS asks for microphone, speech recognition and screen recording access. The app cannot grant them for you. Type `/help` for the command list.

## Troubleshooting

- `signing identity ... not in keychain`: create the identity above, or set `SIGN_IDENTITY`.
- The orb does not start: read `~/Library/Logs/PiOrb.error.log`.
- The panel shows no connection: the app did not find `pi`. Set `PI_EXECUTABLE` or put `pi` in one of the paths listed in the README.
- `@` commands fail: add a `Host remote-host` entry to `~/.ssh/config`.
