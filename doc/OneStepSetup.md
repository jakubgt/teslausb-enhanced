# One-step setup

This is a streamlined process for setting up the Pi. You'll flash the preconfigured Raspberry Pi OS Bookworm Lite image and then fill out a config file.

## Notes

- Assumes your Pi has access to Wifi, with internet access (during setup). (But all setup methods do currently.) USB networking is still enabled for troubleshooting or manual setup
- This image will work for either _headless_ (tested) or _manual_ (tested less) setup.
- Currently not tested with the rclone method when using headless setup, however you can specify 'none' as the archive method in the config file, which will configure the pi as a wifi-accessible USB drive, so you can then [configure rclone](./SetupRClone.md) or [configure rsync](./SetupRSync.md) and rerun the setup-teslausb script.

## Configure the SD card before first boot of the Pi

1.  Flash the [latest image release](https://github.com/marcone/teslausb/releases/latest) using [Raspberry Pi Imager](https://www.raspberrypi.com/software/) or a similar flashing tool.

    In Raspberry Pi Imager, you need to click 'Operating System' and then scroll _all the way down_ and select the 'Use custom' option.

1.  Mount the card again, and in the `boot` directory create a `teslausb_setup_variables.conf` file to export the same environment variables normally needed for manual setup (including archive info, Wifi, and push notifications (if desired).
    A sample conf file is located in the `boot` folder on the SD card. The latest sample is also available [from GitHub](https://github.com/marcone/teslausb/blob/main-dev/pi-gen-sources/00-teslausb-tweaks/files/teslausb_setup_variables.conf.sample).
    The sample file contains documentation and suggestions for values.

    If you have a local checkout of this repository and Node.js installed, the optional [configuration helper](ConfigTool.md) can generate the file from JSON, preflight an edited file without executing it, and create a redacted copy for support requests.

    > **Note** When creating/editing the configuration file on Windows, ensure that it is saved with the correct extension. It is recommended to disable the "hide extensions for known file types" option in Windows so you can see the full file name.

    Be sure that all values, especially your WiFi SSID and password, are properly quoted according to [Bash quoting rules](https://www.gnu.org/software/bash/manual/bash.html#Quoting).
    If a value does not contain a single quote character, enclose the entire value in single quotes. Characters such as spaces, `&`, `/`, `\`, `*`, and `$` are preserved literally inside single quotes and do not need additional escaping:

    ```
    export WIFIPASS='password'
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

The Pi should be reachable at `teslausb.local` over Wifi (if automatic setup works) or USB networking (if it doesn't). Fresh images lock the known default login password. To use SSH, configure `SSH_USER_PASSWORD` before first boot or, preferably, configure `SSH_ROOT_PUBLIC_KEY`; explicitly retaining the image default with `SSH_ALLOW_DEFAULT_PASSWORD=true` is insecure. Setup takes about 5 minutes, or more depending on network speed.

If plugged into just a power source, or your car, give it a few minutes until the LED starts pulsing steadily which means the archive loop is running and you're good to go.

You should see in `/teslausb` the `TESLAUSB_SETUP_FINISHED` and `WIFI_ENABLED` files as markers of headless setup success as well.

## Security

Given that the Pi contains sensitive information like your home wifi password and possible a Tesla account access token, please consider the following:

1. If WiFi Access Point is configured, ensure it is configured with a strong password. Make it something better than Passw0rd, more than 8 characters. The longer the password the better. See [here](https://en.wikipedia.org/wiki/Password_strength) or [here](https://xkcd.com/936/) for password strength.

2. Web authentication is enabled by default. For a headless first boot, strongly prefer setting both `WEB_USERNAME` and a unique 12–72-byte `WEB_PASSWORD` in `teslausb_setup_variables.conf` so you already know the login. If both are omitted, setup generates a random login in the root-only file `/root/teslausb-web-credentials`; retrieve it from a local console or with `sudo cat /root/teslausb-web-credentials` after configuring SSH access. `WEB_AUTH_DISABLED=true` is an explicit insecure opt-out that should be used only on a fully trusted network. The web interface can view recordings and trigger administrative actions, so do not expose it directly to the internet (for example, with router port forwarding). HTTP Basic Authentication protects access but does not encrypt traffic; use it only on a network you trust or access TeslaUSB through a secure VPN.

3. If you enabled an SSH login password, keep it unique. To rotate it later, SSH into the Pi, run the following commands, and enter a new password when prompted:

```
   sudo -i
   /root/bin/remountfs_rw
   passwd pi
   reboot
```

4. Remember that the Pi contains a configuration file with sensitive information. If your Pi is stolen or you suspect an unauthorized person accessed it, immediately change your Tesla account password (if you configured the Pi to use your Tesla credentials to keep the car awake during archiving) and home wifi password.

### Troubleshooting

- TeslaUSB has two web interfaces. The bundled legacy interface is `/` and the separately downloaded newer interface is `/new/`. If a saved preference redirects to a broken interface, open `http://teslausb.local/?ui=legacy` to force and remember the legacy interface, or open `http://teslausb.local/new/` directly. Clear the browser's site data for `teslausb.local` if a redirect loop remains. Trying the Pi's IP address can distinguish name-resolution problems from web-server problems.
- If everything seems to be working, but you still don't see the USB drive(s) either on your local machine, or in the car, check that you are indeed using a USB data cable, and not a charge-only cable. Also ensure you are plugged into the USB port on the Raspberry PI, and not the power port.
- `ssh` to `pi@teslausb.local` (assuming Wifi came up, or your Pi is connected to your computer via USB) and look at the `/teslausb/teslausb-headless-setup.log`.
- Try `sudo -i` and then run `/etc/rc.local`. The scripts are fairly resilient to restarting and not re-running previous steps, and will tell you about progress/failure.
- If Wifi didn't come up:
  - Double-check the SSID and WIFIPASS variables in `teslausb_setup_variables.conf`, and remove `WIFI_ENABLED`, then boot the SD in your Pi to retry automatic Wifi setup.
  - If you are using a WiFi network with a _hidden SSID_, edit `/boot/wpa_supplicant.conf.sample` and uncomment the line `scan_ssid=1` in the `network={...}` block.
  - If still no go, re-run `/etc/rc.local`
  - If all else fails, copy `/boot/wpa_supplicant.conf.sample` to `/boot/wpa_supplicant.conf` and edit out the `TEMP` variables to your desired settings.
- Note: if you get an error about `read-only filesystem`, you may have to `sudo -i` and run `/root/bin/remountfs_rw`.
- Try `date` to ensure the system clock is set correctly. If it is too far off, SSL/TLS Authentication will fail, preventing the installation from completing. You can set the date like `date -s "2 JAN 2022 15:04:05"`
- Try `tail -f /teslausb/teslausb-headless-setup.log` to watch the logs during installation, which may shed some light on any errors occurring. Press `Ctrl-C` to stop watching logs.

More troubleshooting information in the [wiki](https://github.com/marcone/teslausb/wiki/Troubleshooting)

# Background information

## What happens under the covers

When the Pi boots the first time:

- A `/teslausb/teslausb-headless-setup.log` file will be created and stages logged.
- Marker files will be created in `teslausb` like `TESLA_USB_SETUP_STARTED` and `TESLA_USB_SETUP_FINISHED` to track progress.
- Wifi is detected by looking for `/teslausb/WIFI_ENABLED` and if not, creates the `wpa_supplicant.conf` file in place, using `SSID` and `WIFIPASS` from `teslausb_setup_variables.conf` and reboots.
- The Pi LED will flash patterns (2, 3, 4, 5) as it gets to each stage (labeled in the setup-teslausb script).
- After the final stage and reboot the LED will go back to normal. Remember, the step to remount the filesystem takes a few minutes.

At this point the next boot should start the Dashcam/music drives like normal. If you're watching the LED it will start flashing every 1 second, which is the archive loop running.

> **Note** Don't delete the `TESLAUSB_SETUP_FINISHED` or `WIFI_ENABLED` files. This is how the system knows setup is complete.

# Image modification sources

The sources for the image modifications, and instructions, are in the [pi-gen-sources folder](https://github.com/marcone/teslausb/tree/main-dev/pi-gen-sources).
