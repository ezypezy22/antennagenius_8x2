# Changelog

## 26.10.1

### Enhancements

First versioned build. Native macOS control app for the 4O3A Antenna Genius 8x2: finds the unit by its UDP broadcast and connects automatically (or by typed IP), shows both radios with their source and band, and routes each radio to an antenna with the A / B buttons, laid out and coloured like the Windows utility (A green, B blue, red on transmit). Light mode by default with a dark mode switch
Settings window with Basic information (device name), Antennas (names and RX / TX / in-band bands), Output relays designer (groups, outputs, live relay strip), Bands, Network settings (DHCP, address, password), Stack settings and Advanced options (in-band port, reboot, factory defaults)
Antennas the other radio is using are dimmed, and a refused selection explains why
Quit always works: closing the window or choosing Quit ends the app, and a second copy hands over to the one already running

### Bug Fixes

Commands are sent with a newline terminator, which firmware 4.1.19 requires
