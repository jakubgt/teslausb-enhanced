#!/bin/bash

# Source this helper after setting SNAPSHOTS_ROOT. Children inherit the actual
# locked open file description, not a flag claiming that somebody took a lock.
# 99 is a normal busy/deferred result; 64 means a malformed inherited handle.
function acquire_snapshot_lock () {
  if [ -L "$SNAPSHOTS_ROOT" ] ||
     { [ -e "$SNAPSHOTS_ROOT" ] && [ ! -d "$SNAPSHOTS_ROOT" ]; }
  then
    echo "invalid snapshots directory" >&2
    return 64
  fi
  mkdir -p -- "$SNAPSHOTS_ROOT" || return

  if [ -n "${TESLAUSB_SNAPSHOT_LOCK_FD:-}" ]
  then
    # Bash dynamically allocates descriptors >= 10. Keep stdio and the gadget
    # guard's reserved FD 9 out of this protocol so it cannot replace our lock.
    if [[ ! "$TESLAUSB_SNAPSHOT_LOCK_FD" =~ ^[1-9][0-9]{1,8}$ ]]
    then
      echo "invalid inherited snapshot lock descriptor" >&2
      return 64
    fi
    # Both identity and flock are necessary: an environment variable alone
    # neither proves a descriptor is open nor grants ownership of the lock.
    if [ ! "/proc/$$/fd/$TESLAUSB_SNAPSHOT_LOCK_FD" -ef "$SNAPSHOTS_ROOT" ]
    then
      echo "inherited snapshot lock does not refer to the snapshots directory" >&2
      return 64
    fi
  else
    exec {TESLAUSB_SNAPSHOT_LOCK_FD}< "$SNAPSHOTS_ROOT" || return
    export TESLAUSB_SNAPSHOT_LOCK_FD
  fi

  flock -n "$TESLAUSB_SNAPSHOT_LOCK_FD" || return 99
}
