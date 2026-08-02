# teslausb

## Intro

Raspberry Pi and other single-board computers (SBCs) can emulate a USB drive, so can act as a drive for your Tesla to write dashcam footage to. Because the SBC has full access to the emulated drive, it can:

- automatically copy the recordings to an archive server when you get home
- hold both dashcam recordings and music files
- automatically repair filesystem corruption produced by the Tesla's current failure to properly dismount the USB drives before cutting power to the USB ports
- serve up a web UI to view or download the recordings
- retain more than one hour of RecentClips (assuming large enough storage)

This video (not mine) has a nice overview of teslausb and how to install it:

[![teslausb intro and installation](http://img.youtube.com/vi/ETs6r1vKTO8/0.jpg)](http://www.youtube.com/watch?v=ETs6r1vKTO8 "teslausb intro and installation")

If you are interested in having more detailed information about how TeslaUsb works, have a look into the [wiki](https://github.com/marcone/teslausb/wiki).

### Dashcam encryption compatibility

Tesla vehicles with software 2026.20 or later can encrypt recordings written to the USB drive. TeslaUSB cannot currently archive or play files in `EncryptedClips`; automatic archiving and the web viewer require standard, unencrypted recordings. If encryption is enabled in your vehicle, turn off **Controls > Safety > Encrypt Dashcam Recordings**. See Tesla's [Dashcam documentation](https://www.tesla.com/ownersmanual/model3/en_us/GUID-3BCC07CE-5EA2-4F40-99D1-27690898FF3C.html) for details.

## Prerequisites

### Assumptions

- You park in range of your wireless network.
- Your wireless network is configured with WPA2 PSK access.

### Hardware

Required:

- [A Raspberry Pi or other SBC that supports USB OTG](https://github.com/marcone/teslausb/wiki/Hardware).
- A Micro SD card, at least 64 GB in size, and an adapter (if necessary) to connect the card to your computer.
- Cable(s) to connect the SBC to the Tesla (USB A/Micro B cable for the Pi Zero, USB A/C cable for the Pi 4 and 5, other SBCs vary)

Optional:

- A case and/or cooler for the SBC. For the Raspberry Pi 4 I like the ["armor case"](https://www.amazon.com/s?k=Raspberry+Pi+4+Armor+Case) (available with or without fans), which appears to do a good job of protecting the Pi while keeping it cool.
- USB Splitter if you don't want to lose a front USB port. [The Onvian Splitter](https://www.amazon.com/gp/product/B01KX4TKH6) has been reported working by multiple people on reddit. Some SBCs require separate power and data connection, so may require a splitter or a USB hub to connect to the car.

## Installing

The current prebuilt Raspberry Pi image is based on Raspberry Pi OS Bookworm Lite. For other SBCs, start with the [installation wiki](https://github.com/marcone/teslausb/wiki/Installation).

### Quick start

1. Confirm that your board supports USB OTG and use a microSD card of at least 64 GB.
2. Download the [latest prebuilt image](https://github.com/marcone/teslausb/releases/latest) and flash it with Raspberry Pi Imager's **Use custom** option.
3. Copy and edit `teslausb_setup_variables.conf.sample` on the boot partition, then save it as `teslausb_setup_variables.conf`. The optional [local configuration helper](doc/ConfigTool.md) can generate and preflight this file without executing it.
4. Before first boot, confirm the archive destination, use unique Wi-Fi and web passwords, and leave `DATA_DRIVE` unset unless you have verified the exact whole-disk device that may be erased. Keep a private backup of the original configuration.
5. Safely eject the card, boot the Pi with internet access, and allow the setup flashes, reboot, and final steady pulse to finish. Initial setup can take longer than five minutes on a slow connection.
6. Open `http://teslausb.local/` and confirm storage, network, and archive health before connecting it to the car.

See the [one-step setup guide](doc/OneStepSetup.md) for configuration choices, LED stages, security, and troubleshooting.

### Web-interface recovery

TeslaUSB provides two interfaces over the same device:

- `http://teslausb.local/` is the bundled legacy interface.
- `http://teslausb.local/new/` is the optional, separately released interface when an explicitly pinned release has been installed.

If a saved preference keeps redirecting to an interface that does not load, open `http://teslausb.local/?ui=legacy` to force and remember the legacy interface. You can also open `/new/` directly. If neither works, clear site data for `teslausb.local`, try the device's IP address, and inspect `/teslausb/teslausb-headless-setup.log` over SSH.

The bundled dashboard uses the [versioned local Web API](doc/WebAPI.md). Read requests use `GET`; actions use `POST` with a same-origin request header. The API is intended for trusted private networks and must not be exposed directly to the Internet.

Archive transfers now produce SHA-256 manifests, verify destination content before removing source links, and retain bounded retry state across service restarts. See [archive reliability](doc/ArchiveReliability.md) for behavior, status paths, and operational limits.

## Contributing

You're welcome to contribute to this repo by submitting pull requests and creating issues.
For pull requests, please split complex changes into multiple pull requests when feasible, and follow the existing code style.

## Meta

This repo contains steps and scripts originally from [this thread on Reddit](https://www.reddit.com/r/teslamotors/comments/9m9gyk/build_a_smart_usb_drive_for_your_tesla_dash_cam/)

Many people in that thread suggested that the scripts be hosted on GitHub but the author didn't seem interested in making that happen, so GitHub user "cimryan" hosted the scripts on GitHub with the Reddit user's permission.
