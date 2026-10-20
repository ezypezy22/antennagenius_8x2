# Antenna Genius 8x2 for macOS

A native macOS control app for the 4O3A Antenna Genius 8x2 antenna switch.
It finds the unit by its UDP broadcast, connects over TCP (port 9007), and offers
a panel modelled on the Windows utility plus a Settings window.

## Build

Requires the Swift toolchain (Command Line Tools are enough; no Xcode project).

```
./bundle.sh      # build/AntennaGenius.app
./make_dmg.sh    # build/AntennaGenius.dmg
```

macOS asks for Local Network access on first launch; allow it or discovery will not work.

## Tests

`swift test` (needs XCTest, which comes with Xcode; the Command Line Tools alone do not include it).

## Protocol notes (firmware 4.1.19)

- Commands end with `\n` (or `\r\n`), not a bare `\r` as the published spec says.
- Antenna selection needs the port source set to MANUAL; an antenna must be enabled
  for the port's band (band 0 allows RX only by default).
- `sub antenna` and `sub group` are not supported.

API reference: https://github.com/4o3a/genius-api-docs/wiki
