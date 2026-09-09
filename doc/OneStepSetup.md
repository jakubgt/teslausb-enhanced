# One-step setup

This is a streamlined process for setting up the Pi. You'll flash the 64-bit Raspberry Pi OS Lite (Debian Trixie) image and then fill out a config file. Raspberry Pi Zero 2 W is supported; use the 64-bit Lite image and connect the Tesla to its USB data/OTG port.

## Notes

- Assumes your Pi has access to Wifi, with internet access (during setup). (But all setup methods do currently.) USB networking is still enabled for troubleshooting or manual setup
- This image will work for either _headless_ (tested) or _manual_ (tested less) setup.
- Currently not tested with the rclone method when using headless setup, however you can specify 'none' as the archive method in the config file, which will configure the pi as a wifi-accessible USB drive, so you can then [configure rclone](./SetupRClone.md) or [configure rsync](./SetupRSync.md) and rerun the setup-teslausb script.

## Configure the SD card before first boot of the Pi

1.  Download a published release's Raspberry Pi Zero 2 W arm64/Trixie `.img.xz` plus its `.sha256` file. Public GitHub assets need no sign-in; a private mirror requires an authorized account. Verify the SHA-256 digest, then flash the compressed file directly using [Raspberry Pi Imager](https://www.raspberrypi.com/software/) or a similar flashing tool. Use a high-endurance card: 64 GB is the minimum and 128 GB or larger is recommended. If the release has no image asset, build the exact tag with the pinned [64-bit Trixie pi-gen instructions](../pi-gen-sources/Readme.md).

    In Raspberry Pi Imager, click **Operating System**, scroll to **Use custom**, and select the local `.img.xz`; extraction is not required. Flashing erases the selected card. Decline Imager OS customization because TeslaUSB has its own first-boot configuration and SSH provisioning.

1.  Mount the card again and open `teslausb_config_wizard.html` from its `boot` partition. Complete the offline form, download `teslausb_setup.json`, and copy that downloaded file to the root of the `boot` partition. The wizard does not use the network, analytics, browser storage, or remote scripts; it recommends conservative Zero 2 W values and generates its web password locally.

    Every fresh image needs `SSID`, `WIFIPASS`, and an explicit uppercase ISO 3166-1 alpha-2 `WIFI_COUNTRY` for the physical location where it will operate (`GB`, not `UK`, for the United Kingdom). TeslaUSB will not guess a regulatory domain or enable Wi-Fi with a missing/unrecognized country. The recommended starting profile uses `ARCHIVE_SYSTEM: "none"`, `CAM_SIZE: "40G"`, a named timezone, web authentication, and no destructive `DATA_DRIVE` selection. Configure an archive only after the local system is healthy.

    Enter the decimal GB capacity printed on the card in the wizard (for example, enter `1000` for a 1 TB card). `CAM_SIZE` uses binary GiB (`G` or case-sensitive `GiB` input), so never copy the printed capacity into it. In particular, do not use `500G` on a 512 GB card. The wizard rejects values above these conservative ceilings and does not save the card capacity in the JSON:

    | Capacity printed on card | Maximum `CAM_SIZE` |
    | ---: | ---: |
    | 64 GB | `40G` |
    | 128 GB | `100G` |
    | 256 GB | `210G` |
    | 512 GB | `440G` |
    | 1 TB (1000 GB) | `880G` |
    | 1.5 TB (1500 GB) | `1330G` |
    | 2 TB (2000 GB) | `1780G` |

    These are ceilings, not targets. `20G` is accepted as the hard minimum, while `40G` remains the recommended starting value. Subtract any `MUSIC_SIZE`, `LIGHTSHOW_SIZE`, `BOOMBOX_SIZE`, and `INCREASE_ROOT_SIZE` allocations from the applicable ceiling. The ceiling rule is `floor-to-10(0.90 * advertised decimal GB - 15)` and deliberately leaves room for card-label conversion, system data, filesystem metadata, and snapshots.

    Advanced users can instead copy `teslausb_setup.json.sample` to `teslausb_setup.json` and edit its `variables` object. The checked-in [JSON sample](../pi-gen-sources/00-teslausb-tweaks/files/teslausb_setup.json.sample) and [declarative configuration guide](DeclarativeConfig.md) describe the required native JSON types.

    Existing installs may continue to use `teslausb_setup_variables.conf`, but that executable shell format is deprecated. The optional [configuration helper](ConfigTool.md) can safely migrate a literal legacy file to JSON, preflight an edited legacy file without executing it, and create a redacted support copy.

    > **Note** When creating/editing the configuration file on Windows, ensure that it is saved with the correct extension. It is recommended to disable the "hide extensions for known file types" option in Windows so you can see the full file name.

    The following quoting guidance applies only if you deliberately keep using the legacy `.conf` format. Be sure that all values, especially your WiFi SSID and password, are properly quoted according to [Bash quoting rules](https://www.gnu.org/software/bash/manual/bash.html#Quoting).
    If a value does not contain a single quote character, enclose the entire value in single quotes. Characters such as spaces, `&`, `/`, `\`, `*`, and `$` are preserved literally inside single quotes and do not need additional escaping:

    ```
    export WIFIPASS='password'
    export WIFI_COUNTRY='US'
    ```

    This works even when the value contains characters that would otherwise be special to Bash.

    If the value contains a single quote, use Bash's ANSI-C quoting syntax. For example, if the password is `pass'word`, use:

    ```
    export WIFIPASS=$'pass\'word'
    ```

    ANSI-C quoted values do interpret backslash escapes, so double literal backslashes. For example, if the password is `pass'wo\rd`, use:

    ```
    export WIFIPASS=$'pass\'wo\\rd'
    ```

    Similarly if your WiFi SSID has spaces in its name, make sure they're escaped or quoted.

    For example, if your SSID were

    ```
    Foo Bar 2.4 GHz
    ```

    you would use

    ```
    export SSID=Foo\ Bar\ 2.4\ GHz
    ```

    or

    ```
    export SSID='Foo Bar 2.4 GHz'
    ```

1.  Boot it in your Pi, give it a few minutes, watching for a series of flashes (2, 3, 4, 5) and then a reboot and/or the CAM/music drives to become available on your PC/Mac. If you configured automatic music syncing, the drives won't be available on the PC/Mac until music syncing is complete. The LED flash stages during setup are:

    | Stage (number of flashes) | Activity                                                           |
    | ------------------------- | ------------------------------------------------------------------ |
    | 2                         | Verify the requested configuration is creatable                    |
    | 3                         | Grab scripts to start/continue setup                               |
    | 4                         | Create partition and files to store camera clips/music)            |
    | 5                         | Setup completed; remounting filesystems as read-only and rebooting |

The Pi should be reachable at `teslausb.local` over Wifi (if automatic setup works) or USB networking (if it doesn't). Fresh images lock the known default login password during image construction, before first boot or SSH startup. To use SSH, configure `SSH_USER_PASSWORD` before first boot or, preferably, configure `SSH_ROOT_PUBLIC_KEY`; explicitly retaining the image default with `SSH_ALLOW_DEFAULT_PASSWORD=true` is insecure. Setup takes about 5 minutes, or more depending on network speed.

If you set `TIME_ZONE` to `auto`, setup downloads the exact [tzupdate revision `2d41763825fcfae3f2266bf1628ce245ab285f5a`](https://github.com/marcone/tzupdate/commit/2d41763825fcfae3f2266bf1628ce245ab285f5a) into a root-private temporary directory and verifies SHA-256 `7e6769fcf6c2a19a3492a9d62bd529714081132b12244796a4800269804857cb` before running it. A checksum mismatch stops setup. A named zone such as `America/Chicago` uses the installed zoneinfo data and does not download this helper.

If plugged into just a power source, or your car, give it a few minutes until the LED starts pulsing steadily which means the archive loop is running and you're good to go.

You should see in `/teslausb` the `TESLAUSB_SETUP_FINISHED` and `WIFI_ENABLED` files as markers of headless setup success as well.

## Security

Given that the Pi contains sensitive information like your home wifi password and possible a Tesla account access token, please consider the following:

1. If WiFi Access Point is configured, ensure it is configured with a strong password. Make it something better than Passw0rd, more than 8 characters. The longer the password the better. See [here](https://en.wikipedia.org/wiki/Password_strength) or [here](https://xkcd.com/936/) for password strength.

2. Web authentication is enabled by default. For a headless first boot, strongly prefer setting both `WEB_USERNAME` and a unique 12–72-byte `WEB_PASSWORD` in `teslausb_setup.json` (or the deprecated legacy `.conf`) so you already know the login. If both are omitted, setup generates a random login in the root-only file `/root/teslausb-web-credentials`; retrieve it from a local console or with `sudo cat /root/teslausb-web-credentials` after configuring SSH access. `WEB_AUTH_DISABLED=true` is an explicit insecure opt-out that should be used only on a fully trusted network. The web interface can view recordings and trigger administrative actions, so do not expose it directly to the internet (for example, with router port forwarding). HTTP Basic Authentication protects access but does not encrypt traffic; use it only on a network you trust or access TeslaUSB through a secure VPN.

3. If you enabled an SSH login password, keep it unique. To rotate it later, SSH into the Pi, run the following commands, and enter a new password when prompted:

```
   sudo -i
   /root/bin/remountfs_rw
   passwd pi
   reboot
```

4. Remember that the Pi contains a configuration file with sensitive information. If your Pi is stolen or you suspect an unauthorized person accessed it, immediately change your Tesla account password (if you configured the Pi to use your Tesla credentials to keep the car awake during archiving) and home wifi password.

### Troubleshooting

- TeslaUSB opens the built-in modern interface at `/`, also available directly at `/modern/`. Open `http://teslausb.local/index.html?ui=legacy` to force Classic and clear its saved preference for the older optional interface at `/new/`. That optional interface is available only if separately installed. Clear the browser's site data for `teslausb.local` if a redirect loop remains. Trying the Pi's IP address can distinguish name-resolution problems from web-server problems.
- If everything seems to be working, but you still don't see the USB drive(s) either on your local machine, or in the car, check that you are indeed using a USB data cable, and not a charge-only cable. Also ensure you are plugged into the USB port on the Raspberry PI, and not the power port.
- `ssh` to `pi@teslausb.local` (assuming Wifi came up, or your Pi is connected to your computer via USB) and look at the `/teslausb/teslausb-headless-setup.log`.
- Try `sudo -i` and then run `/etc/rc.local`. The scripts are fairly resilient to restarting and not re-running previous steps, and will tell you about progress/failure.
- If Wifi didn't come up:
  - Double-check `SSID`, `WIFIPASS`, and the uppercase ISO 3166-1 alpha-2 `WIFI_COUNTRY` in `teslausb_setup.json` (or the deprecated legacy `.conf`). The country must describe the Pi's physical operating location. Remove `WIFI_ENABLED`, then boot the SD in your Pi to retry automatic Wifi setup.
  - If you are using a WiFi network with a _hidden SSID_, edit `/boot/wpa_supplicant.conf.sample` and uncomment the line `scan_ssid=1` in the `network={...}` block.
  - If still no go, re-run `/etc/rc.local`
  - If all else fails, copy `/boot/wpa_supplicant.conf.sample` to `/boot/wpa_supplicant.conf`, add `country=XX` near the top using your real uppercase ISO 3166-1 alpha-2 country code, and replace the `TEMP` values with your network settings.
- Note: if you get an error about `read-only filesystem`, you may have to `sudo -i` and run `/root/bin/remountfs_rw`.
- Try `date` to ensure the system clock is set correctly. If it is too far off, SSL/TLS Authentication will fail, preventing the installation from completing. You can set the date like `date -s "2 JAN 2022 15:04:05"`
- Try `tail -f /teslausb/teslausb-headless-setup.log` to watch the logs during installation, which may shed some light on any errors occurring. Press `Ctrl-C` to stop watching logs.

More troubleshooting information in the [wiki](https://github.com/marcone/teslausb/wiki/Troubleshooting)

# Background information

## What happens under the covers

When the Pi boots the first time:

- A `/teslausb/teslausb-headless-setup.log` file will be created and stages logged.
- Marker files will be created in `teslausb` like `TESLA_USB_SETUP_STARTED` and `TESLA_USB_SETUP_FINISHED` to track progress.
- Wifi is detected by looking for `/teslausb/WIFI_ENABLED` and, if absent, first applies the explicit `WIFI_COUNTRY`, then creates the connection using `SSID` and `WIFIPASS` from the validated JSON configuration (or deprecated legacy `.conf`) and reboots.
- The Pi LED will flash patterns (2, 3, 4, 5) as it gets to each stage (labeled in the setup-teslausb script).
- After the final stage and reboot the LED will go back to normal. Remember, the step to remount the filesystem takes a few minutes.

At this point the next boot should start the Dashcam/music drives like normal. If you're watching the LED it will start flashing every 1 second, which is the archive loop running.

> **Note** Don't delete the `TESLAUSB_SETUP_FINISHED` or `WIFI_ENABLED` files. This is how the system knows setup is complete.

# Image modification sources

The sources for the image modifications, and instructions, are in the
[pi-gen-sources folder](../pi-gen-sources/Readme.md).
