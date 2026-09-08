#!/bin/bash

# Run from a timer as the same unprivileged UID that owns private Trash storage.
# Clock verification failure retains recordings and retries on a later timer tick.
set -eu
exec /usr/bin/python3 -I /var/www/html/cgi-bin/recording-trash.py cleanup
