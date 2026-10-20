# Changelog

## 26.10.2

### Enhancements

The version number is shown as a small footer under the antenna list on the main panel, as well as on the connect screen and under Basic information
About Antenna Genius in the gear menu: shows the app name, version, author and a link to the GitHub project

## 26.10.1

### Enhancements

Main panel: laid out like the Windows utility. A title bar with a gear menu, a MANUAL / source button and a band button for each radio, then one row per antenna with an A button, the antenna name and a B button. Radio A is green, Radio B is blue and the transmitting antenna turns red; if both radios are on one antenna the name is split green and blue. Click an A or B button to route that radio to the antenna, click it again to release it
Discovery and connection: the unit is found from its 1 Hz UDP broadcast on port 9007 and the app connects by itself when exactly one is heard. With several units each one is listed with its name, IP address and firmware. If nothing is heard for a few seconds the app explains what to check, offers a button that opens the Local Network privacy settings, and lets you type the device's IP address (the last one used is remembered)
Live status: both radios' source, band, frequency and RX / TX state follow the device as it changes, including changes made from the front panel, the Windows utility or the Flex radio, and the Output relays page shows a live indicator for each of the 8 relays
MANUAL control: the MANUAL button takes a radio over from its band source (for example FLEX) and hands it back to the previous source when switched off. The band button opens a list of the unit's bands and is dimmed while a radio is following its source
Antenna selection follows the device's rules: an antenna is offered for RX or TX only if it is enabled for the radio's current band, and TX is only sent when the antenna has a TX band. With the factory defaults every antenna is available for RX on the "None" band
Antennas the other radio is using are dimmed, and if the unit refuses a selection the message says which radio holds the antenna
Settings window laid out like the Windows utility (menu on the left, green page header, Save and Cancel at the bottom right):
- Basic information: edit the device name; shows the app version, address, serial number, firmware and mode
- Antennas: edit each antenna's name and tick the bands it may use for RX, TX and in-band
- Output relays designer: add output groups that follow the selected antenna or the selected band, add outputs to a group and tick which of the 8 relays each one switches, exclusive (TRX) outputs, delete groups and outputs, and an Activate button to test an output on the real device
- Bands: edit each band's name and start / stop frequency
- Network settings: DHCP on or off, IP address, subnet mask, gateway and remote access password, checked before sending, with a confirmation because changing DHCP or the static address reboots the unit (about 20 seconds offline)
- Stack settings: enable stacking (16x2), choose the other Antenna Genius found on the network by serial number and choose External AB switches or ports 7 & 8; a button rescans the network
- Advanced options: in-band port (not configured, Radio A or Radio B), reboot the device and restore factory defaults, both with a confirmation
Light mode is the default with a Dark mode switch on the connect screen and in the gear menu; the choice is remembered
Version numbers: the version (26.10.1) comes from the VERSION file and appears in the DMG file name, on the connect screen, in the gear menu and under Basic information; make_dmg.sh writes dist/AntennaGenius-<version>-macos-<arch>.dmg
Protocol log (gear menu): shows every command and reply exchanged with the unit, with the remote access password hidden
The app shows an error banner whenever the unit rejects a command, with the command and the error code

### Bug Fixes

Nothing happened when switching antennas: firmware 4.1.19 silently ignores commands ended with a bare carriage return (as the published API describes) and needs a newline, so every command was dropped and no replies were ever received; commands now end with CR LF
Antenna selection was rejected by the unit: it only accepts a selection when the radio's source is MANUAL; the app now switches the radio to MANUAL as part of the selection instead of failing
Selecting an antenna was blocked when no band was set and Deselect set the band to None, which was wrong: RX can be selected on the "None" band, and an antenna is now released with rxant=0 txant=0
Connecting to a unit that does not support "sub antenna" (error 0x30) no longer sends that command
The device name was cut off on the connect screen ("...10.43.10.x"); the connect screen is wider and shows the name above the IP address and firmware
The device list went blank once connected, because the unit dropped out of the discovery list while the connection stayed open; the connected unit's name and address are shown instead
The band buttons showed as plain "None" text because macOS flattens the styling of a menu button's label; they are now real buttons that open a band list
The last antenna row touched the bottom of the window and its rounded corners; the panel has bottom padding
Closing the window left the app running in the background, still holding UDP port 9007, and there was no way to quit it; closing the last window, Quit in the gear menu and Command-Q now end the app (forced after one second if the normal shutdown stalls)
Opening a second copy of the app made both fight over UDP port 9007 and the unit's connection slots; a second copy now says so and switches to the one already running, and a warning is shown if another program owns the port
The remote access password was visible in the protocol log; it is now masked
