# Setting up external USB drive (SSD) with Pi4

This guide explains how to use a Raspberry Pi 4 and a separate USB drive to host your CAM and MUSIC files.

#### Limitations

- This layout uses separate boot and data drives. Raspberry Pi 4 and 5 systems that support USB boot should generally boot TeslaUSB directly from the USB drive instead.
- `DATA_DRIVE` erases the entire selected disk. Verify the device path carefully; all existing data on that disk will be lost.
- Cannot resize existing partitions.

## Hardware

1. Raspberry Pi4 - Any RAM option will work.
2. An SD card for the operating system when using a separate data drive. It is not required when the Pi is configured to boot directly from USB.
3. USB Drive - SSD preferred due to low power requirements.
4. Optional, but highly recommended - Heatsink case as Pi4 can get very hot.
5. Optional - X855 mSata board for a more compact setup.

## teslausb_setup_variables.conf configuration

To use a separate external data drive, add
`export DATA_DRIVE=/dev/sdX` to `teslausb_setup_variables.conf`.
Ensure that you are providing the disk location and not a partition.

The rest of the setup follows the [one-step setup guide](OneStepSetup.md). Both `/backingfiles` and `/mutable` will be placed on the external drive while the operating-system drive is kept read-only.
