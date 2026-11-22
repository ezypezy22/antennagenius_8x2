# Antenna Genius 8x2 for macOS

A native macOS control app for the 4O3A Antenna Genius 8x2 antenna switch.
It finds the unit by its UDP broadcast, connects over TCP (port 9007), and offers
a panel modelled on the Windows utility plus a Settings window.

## Build

Requires the Swift toolchain (Command Line Tools are enough; no Xcode project).

```
./bundle.sh      # build/AntennaGenius.app (universal: Apple silicon and Intel)
./make_dmg.sh    # dist/AntennaGenius-<version>-macos-universal.dmg
```

macOS asks for Local Network access on first launch; allow it or discovery will not work.

### Signing and notarization

Without a certificate the app is signed ad hoc, and Gatekeeper on other Macs blocks it: open it once, then
choose Open Anyway in System Settings › Privacy & Security. To ship a build that opens normally, use a
Developer ID Application certificate and a notarytool keychain profile:

```
xcrun notarytool store-credentials AG --apple-id you@example.com --team-id TEAMID --password <app-specific password>
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=AG ./make_dmg.sh
```

### Releases and update checks

To publish: bump `VERSION`, add its `## <version>` section to `CHANGELOG.md`, commit and push, then run
`./release.sh`. It builds the DMG from the pushed commit and writes cumulative release notes: every
CHANGELOG section newer than the last 26.10.x (set `NOTES_SINCE` to change that; `--notes-only` previews them).

The app checks the GitHub releases of this repository at launch and every 24 hours while it runs (it can be
turned off in the gear menu). When a newer version is out it offers the release page once, and the main window
shows an "available" banner until that version is installed, even after Later or Skip This Version. It reads the version from the release tag, or else
from the DMG file name, so keep `AntennaGenius-<version>-…dmg` as the asset name.

## Remote access

A unit reached from outside its LAN (by typing its address or host name on the connect screen) greets the
app with `AUTH`. The app then asks for the unit's remote access password (set under Settings › Network),
logs in with `auth code=…` and keeps the password in the login Keychain.
A new password set from the app must be exactly 8 characters (firmware 4.1.19 refuses longer ones with
0x20) with upper and lower case, a digit and a symbol; printable ASCII only, without `|` or `=`, which the
command syntax can't carry. `network get` reports only `auth=1` (a password is set), never the password,
so the app sends `auth=` only when a new password is typed. Eight characters is short for a service on the
internet: prefer reaching the unit over a VPN to forwarding TCP 9007.

## Band from CAT (rigctld or flrig)

For radios without a FlexRadio link or band data cable, Settings › Bands › CAT (this Mac) reads each radio's
frequency from Hamlib `rigctld` (TCP, default port 4532, command `f`) or `flrig` (XML-RPC, default port 12345,
`rig.get_vfo`) and sends `port set <n> auto=0 source=MANUAL band=<b>`, using the band ranges configured on the
device. Changes wait while the port transmits. It works only while the app is running; for rigctld, start it
with your radio's model and serial port, e.g. `rigctld -m 3073 -r /dev/cu.usbserial-XXXX -s 19200`.

## Presets and links

Presets › Save Current Setup as Preset… stores each shown radio's RX and TX antennas (output relays to switch on
can be added in Manage Presets…). The first nine presets are ⌥⌘1–⌥⌘9.

The app handles `agenius://` links, so Stream Deck (Open or Website action), Shortcuts (Open URLs) and scripts
(`open "agenius://…"`) can drive it:

```
agenius://select?radio=A&antenna=3       # antenna by number…
agenius://select?radio=B&antenna=Yagi    # …or by name (case, spaces and _ ignored)
agenius://release?radio=A
agenius://preset?name=Contest
```

Focus returns to the app that was in front (e.g. the logger) unless the link adds `focus=1`. Presets and links
never switch a radio that is transmitting. Native Shortcuts actions (App Intents) would need an Xcode build,
since `swift build` doesn't produce the App Intents metadata.

## Activity, usage and notifications

Gear menu › Activity… shows the change history (antenna, band and source per radio, with who asked for it)
and usage: time per band and antenna, and transmit time from the port's `tx` flag. The API has no power, SWR
or other sensor readings, so transmit time is the only RF figure available. History and usage are kept in
`~/Library/Application Support/Antenna Genius/`. Notifications (device offline/back, CAT lost/back) can be turned
off in gear menu › Notifications.

## Tests

`swift test` (needs XCTest, which comes with Xcode; the Command Line Tools alone do not include it).
GitHub Actions runs the tests and the universal build on every push to main and on pull requests.

## Protocol notes (firmware 4.1.19)

- Commands end with `\n` (or `\r\n`), not a bare `\r` as the published spec says.
- Antenna selection needs the port source set to MANUAL; an antenna must be enabled
  for the port's band (band 0 allows RX only by default; the app skips its own RX mask check at band 0 but always checks the TX mask).
- `sub antenna` and `sub group` are not supported.

API reference: https://github.com/4o3a/genius-api-docs/wiki
