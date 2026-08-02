# Archive reliability

TeslaUSB builds a SHA-256 manifest for every non-empty transfer batch. CIFS and NFS destinations are verified locally; rsync destinations receive a checksum dry run; and rclone uses `rclone check`. Source links are removed only after the destination verifies and a copy of the manifest has been published under `.teslausb-manifests/` at the archive destination.

The source is fingerprinted before and after hashing and checked again immediately before removal. If a recording changes during transfer or cleanup, TeslaUSB retains it and retries instead of deleting it using stale metadata. Retries use bounded exponential backoff. The failure count and next-attempt timestamp are written atomically to `/mutable/teslausb/archive-retry.state`, so a service restart does not reset a failing transfer into a tight loop.

Current progress is written atomically to `/mutable/teslausb/archive-status.json` and exposed by `/api/v1/status`. It reports pending and transferred file/byte counts, timestamps, the latest result, and a short message. The dashboard tolerates older installations where this object is unavailable.

Advanced retry and transport bounds can be adjusted with `ARCHIVE_RETRY_ATTEMPTS_PER_RUN`, `ARCHIVE_RETRY_BASE_SECONDS`, `ARCHIVE_RETRY_MAX_SECONDS`, `ARCHIVE_RSYNC_TIMEOUT`, `RSYNC_SSH_CONNECT_TIMEOUT`, `RCLONE_CONNECT_TIMEOUT`, and `RCLONE_IO_TIMEOUT`. Defaults favor unattended recovery and refuse unbounded waits. Increase a timeout only when a known slow archive requires it.

These checks detect incomplete or changed transfers; they do not make an untrusted archive server trustworthy. A server administrator can still replace both recordings and manifests after upload. Keep independent backups for footage that must be preserved.
