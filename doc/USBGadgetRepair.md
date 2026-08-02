# Manual USB gadget repair

Use **Repair USB gadget** on the TeslaUSB status page only when the car or a
computer no longer sees the virtual drives and toggling them off and on did not
help. The dashboard requires a second confirmation because a repair briefly
disconnects every exported drive.

The repair operation is guarded rather than autonomous. It:

1. takes the same exclusive lock used by normal gadget enable/disable
   operations and enforces a 60-second attempt interval;
2. verifies configfs, the USB device controller, the helper scripts, and all
   configured backing images before changing the gadget;
3. flushes pending writes, releases the existing gadget, and rebuilds it using
   the normal TeslaUSB enable/disable helpers, with bounded operation times;
4. verifies that the gadget is bound to a real UDC and that every expected LUN
   points to the correct backing image.

If the rebuild or final verification fails, the operation leaves the USB gadget
disconnected and reports the failure in the dashboard. It does not modify,
format, mount, or repair the contents of a backing image. Run diagnostics and
inspect `journalctl -t teslausb-gadget-repair` before trying again.

There is deliberately no watchdog or scheduled self-repair. Automatic USB
disconnect/reconnect can interrupt a recording in progress, so recovery remains
an explicit operator action until it has been validated against the target car.

Trusted local API clients can request the same operation with:

```console
curl --fail-with-body --user 'YOUR_WEB_USERNAME' -X POST \
  -H 'X-TeslaUSB-Request: 1' \
  http://teslausb.local/api/v1/actions/drives/repair
```

`curl` prompts for the configured web password, keeping it out of the command
and shell history. Replace `YOUR_WEB_USERNAME` with the username configured for
the TeslaUSB web interface. Only omit `--user` on an installation where web
authentication was explicitly disabled.
