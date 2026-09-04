#!/usr/bin/env python3
"""Transactional, append-only root SSH key enrollment for the card installer.

The caller verifies this module and the public-key payload, holds its installer
lock, makes the root filesystem writable, and persists prepare()'s JSON state
BEFORE apply(). On any interrupted/failed outer transaction call rollback(state).
No account password, account lock, sshd configuration, or existing key changes.
"""

import base64
import hashlib
import ipaddress
import os
from pathlib import Path
import re
import shlex
import stat
import struct
import subprocess
import tempfile


ROOT = Path("/")
MAX_KEYS_BYTES = 1024 * 1024
COMMAND_ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"}


class EnrollmentError(RuntimeError):
    """Enrollment cannot safely proceed without changing existing policy."""


def _command(argv):
    try:
        return subprocess.run(argv, check=True, capture_output=True, text=True,
                              timeout=30, env=COMMAND_ENV).stdout.strip()
    except (subprocess.SubprocessError, OSError) as exc:
        # Do not expose shadow data or arbitrary command output in boot logs.
        raise EnrollmentError(f"SSH check failed: {Path(argv[0]).name}") from exc


def _root_path(name):
    return ROOT / name.lstrip("/")


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _audit_directories(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise EnrollmentError("SSH transaction path must be absolute and normalized")
    for directory in (path, *path.parents):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise EnrollmentError("SSH path contains an unsafe parent directory")


def _secure_read(path, *, maximum=MAX_KEYS_BYTES, require_root_group=False):
    path = Path(path)
    _audit_directories(path.parent)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                info.st_mode & 0o022 or info.st_nlink != 1 or
                (require_root_group and info.st_gid != 0)):
            raise EnrollmentError("SSH file is not a safe root-owned regular file")
        if info.st_size > maximum:
            raise EnrollmentError("SSH file exceeds the safe size limit")
        with os.fdopen(fd, "rb", closefd=False) as source:
            data = source.read(maximum + 1)
        if len(data) > maximum:
            raise EnrollmentError("SSH file exceeds the safe size limit")
        return data, {"mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid,
                      "gid": info.st_gid}
    finally:
        os.close(fd)


def validate_key(data):
    """Accept one ordinary Ed25519 public key, never authorized_keys options."""
    if not isinstance(data, bytes) or len(data) > 4096:
        raise EnrollmentError("Expected one short Ed25519 public-key line")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise EnrollmentError("Public key must be ASCII") from exc
    text = text.removesuffix("\n").removesuffix("\r")
    if any(ord(char) < 32 or ord(char) > 126 for char in text):
        raise EnrollmentError("Public key contains control characters or multiple lines")
    match = re.fullmatch(r"ssh-ed25519 +([A-Za-z0-9+/]+={0,2})(?: +[ -~]+)?", text)
    if not match:
        raise EnrollmentError("Expected an Ed25519 public key without key options")
    try:
        wire = base64.b64decode(match.group(1), validate=True)
    except ValueError as exc:
        raise EnrollmentError("Invalid public-key encoding") from exc
    expected_prefix = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32)
    if len(wire) != len(expected_prefix) + 32 or not wire.startswith(expected_prefix):
        raise EnrollmentError("Public-key wire type or length is invalid")
    canonical_blob = base64.b64encode(wire).decode("ascii")
    if canonical_blob != match.group(1):
        raise EnrollmentError("Public-key encoding is not canonical")
    return text.encode("ascii") + b"\n"


def merge_key(existing, key):
    """Preserve every existing byte; never bypass restrictions on the same key."""
    if b"\0" in existing or len(existing) > MAX_KEYS_BYTES:
        raise EnrollmentError("Existing authorized_keys is invalid or too large")
    new_type, new_blob = key.decode("ascii").split()[:2]
    found_plain = False
    for line in existing.decode("utf-8", "surrogateescape").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            parts = shlex.split(line, comments=False, posix=True)
        except ValueError as exc:
            raise EnrollmentError("Existing authorized_keys contains an ambiguous line") from exc
        for index, part in enumerate(parts[:-1]):
            if part == new_type and parts[index + 1] == new_blob:
                if index != 0 and (index != 1 or parts[0] != "restrict,pty"):
                    raise EnrollmentError("This key already has restrictions; preserving them unchanged")
                found_plain = True
                break
    if found_plain:
        return existing
    separator = b"\n" if existing and not existing.endswith(b"\n") else b""
    # Retain interactive maintenance commands/PTY but disable forwarding,
    # agent/X11 forwarding and user rc execution for this dedicated key.
    result = existing + separator + b"restrict,pty " + key
    if len(result) > MAX_KEYS_BYTES:
        raise EnrollmentError("Merged authorized_keys exceeds the safe size limit")
    return result


def parse_policy(text):
    policy = {}
    relevant = {"permitrootlogin", "pubkeyauthentication", "authenticationmethods", "authorizedkeysfile",
                "pubkeyacceptedalgorithms", "usepam", "allowusers", "denyusers", "allowgroups", "denygroups",
                "forcecommand", "chrootdirectory", "revokedkeys"}
    for line in text.splitlines():
        name, _, value = line.partition(" ")
        name = name.lower()
        # sshd -T legitimately emits repeated HostKey/ListenAddress/AcceptEnv.
        # They are not root-key policy fields and must not reject normal Debian.
        if name not in relevant:
            continue
        if name in policy:
            raise EnrollmentError("Unexpected duplicate SSH effective-policy field")
        policy[name] = value.strip()
    return policy


def check_policy(policy, *, password_locked):
    if policy.get("permitrootlogin") not in {"yes", "prohibit-password", "without-password"}:
        raise EnrollmentError("Existing SSH policy does not permit ordinary root public-key login")
    if policy.get("pubkeyauthentication") != "yes":
        raise EnrollmentError("Existing SSH policy disables public-key authentication")
    if not set(policy.get("authenticationmethods", "").split()) & {"any", "publickey"}:
        raise EnrollmentError("Existing SSH policy requires additional authentication factors")
    allowed_paths = {".ssh/authorized_keys", "/root/.ssh/authorized_keys", "%h/.ssh/authorized_keys"}
    if not set(policy.get("authorizedkeysfile", "").split()) & allowed_paths:
        raise EnrollmentError("Existing SSH policy uses another authorized-keys location")
    if "ssh-ed25519" not in policy.get("pubkeyacceptedalgorithms", "").split(","):
        raise EnrollmentError("Existing SSH policy does not accept Ed25519 keys")
    if password_locked and policy.get("usepam") != "yes":
        raise EnrollmentError("Root is password-locked and SSH does not use PAM; policy was not changed")
    for name in ("allowusers", "denyusers", "allowgroups", "denygroups"):
        if policy.get(name):
            raise EnrollmentError(f"Existing SSH {name} restrictions require manual review")
    for name in ("forcecommand", "chrootdirectory", "revokedkeys"):
        if policy.get(name, "none") != "none":
            raise EnrollmentError(f"Existing SSH {name} policy requires manual review")
    return {"root_public_key_policy": "allowed", "use_pam": policy.get("usepam"),
            "password_locked": password_locked,
            "connection_test": "pending; PAM and network login still require a real SSH test"}


def _root_account():
    passwd, _ = _secure_read(_root_path("/etc/passwd"))
    shadow, _ = _secure_read(_root_path("/etc/shadow"))
    records = [line.split(b":") for line in passwd.splitlines() if line.startswith(b"root:")]
    secrets = [line.split(b":") for line in shadow.splitlines() if line.startswith(b"root:")]
    if (len(records) != 1 or len(records[0]) != 7 or records[0][2:4] != [b"0", b"0"] or
            records[0][5] != b"/root" or len(secrets) != 1 or len(secrets[0]) != 9):
        raise EnrollmentError("Root account layout is not the supported TeslaUSB layout")
    shell = records[0][6].decode("ascii")
    if shell not in {"/bin/bash", "/bin/sh", "/usr/bin/bash", "/usr/bin/sh"}:
        raise EnrollmentError("Root account has a restricted or unsupported login shell")
    if not os.access(_root_path(shell), os.X_OK):
        raise EnrollmentError("Root login shell is not executable")
    if secrets[0][2] == b"0" or secrets[0][7] not in {b"", b"-1"}:
        raise EnrollmentError("Root account has a forced password change or expiry; preserving it")
    if not secrets[0][1]:
        raise EnrollmentError("Root account has an unexpected empty password field")
    return secrets[0][1].startswith((b"!", b"*"))


def _service_state():
    output = _command(["/usr/bin/systemctl", "show", "ssh.service", "--property=LoadState",
                       "--property=UnitFileState", "--property=ActiveState"])
    fields = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    if fields.get("LoadState") != "loaded" or fields.get("UnitFileState") not in {
            "enabled", "disabled", "enabled-runtime"}:
        raise EnrollmentError("SSH service is missing, masked, or has an unsupported enable state")
    if fields.get("ActiveState") not in {"active", "inactive", "failed"}:
        raise EnrollmentError("SSH service is changing state; retry after it settles")
    return {"enabled": fields["UnitFileState"], "active": fields["ActiveState"] == "active"}


def _sync_directory(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomic_write(path, data, metadata=None):
    metadata = metadata or {"mode": 0o600, "uid": 0, "gid": 0}
    _audit_directories(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".teslausb-ssh-", dir=path.parent)
    try:
        os.fchown(fd, metadata["uid"], metadata["gid"])
        os.fchmod(fd, metadata["mode"])
        with os.fdopen(fd, "wb", closefd=False) as target:
            target.write(data)
            target.flush()
            os.fsync(fd)
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        os.close(fd)
        if os.path.lexists(temporary):
            os.unlink(temporary)


def _current_keys():
    ssh_dir = _root_path("/root/.ssh")
    _audit_directories(ssh_dir.parent)
    if not os.path.lexists(ssh_dir):
        return False, None, None
    _audit_directories(ssh_dir)
    path = ssh_dir / "authorized_keys"
    if not os.path.lexists(path):
        return True, None, None
    data, metadata = _secure_read(path, require_root_group=True)
    return True, data, metadata


def prepare(public_key_path, backup_dir, client_address=None):
    """Prepare a JSON state and durable backups, without changing SSH targets."""
    if os.geteuid() != 0:
        raise EnrollmentError("SSH enrollment requires root")
    backup_dir = Path(backup_dir)
    _audit_directories(backup_dir)
    if stat.S_IMODE(backup_dir.stat().st_mode) & 0o077:
        raise EnrollmentError("SSH transaction backup directory must be private")
    for name in ("ssh-authorized-keys.before", "ssh-authorized-keys.after", "ssh-enrollment.pub"):
        if os.path.lexists(backup_dir / name):
            raise EnrollmentError("SSH backup files already exist; recover the previous transaction")
    public_key, _ = _secure_read(public_key_path, maximum=4096, require_root_group=True)
    key = validate_key(public_key)
    password_locked = _root_account()
    _command(["/usr/sbin/sshd", "-t"])
    address = str(ipaddress.ip_address(client_address)) if client_address else "127.0.0.1"
    policy = parse_policy(_command(["/usr/sbin/sshd", "-T", "-C",
                                    f"user=root,host={address},addr={address}"]))
    report = check_policy(policy, password_locked=password_locked)
    report["evaluated_client_address"] = address
    report["match_context"] = "client address supplied" if client_address else "loopback only; remote Match rules unverified"
    service = _service_state()
    existed, original, metadata = _current_keys()
    replacement = merge_key(original or b"", key)
    _atomic_write(backup_dir / "ssh-enrollment.pub", key)
    fingerprint = _command(["/usr/bin/ssh-keygen", "-l", "-E", "sha256", "-f",
                            str(backup_dir / "ssh-enrollment.pub")])
    if not re.fullmatch(r"256 SHA256:[A-Za-z0-9+/]+ .+ \(ED25519\)", fingerprint):
        raise EnrollmentError("ssh-keygen did not recognize the expected Ed25519 key")
    report["key_fingerprint"] = fingerprint.split()[1]
    if original is not None:
        _atomic_write(backup_dir / "ssh-authorized-keys.before", original)
    _atomic_write(backup_dir / "ssh-authorized-keys.after", replacement)
    return {"version": 1, "backup_dir": str(backup_dir), "directory_existed": existed,
            "original_sha256": _digest(original) if original is not None else None,
            "replacement_sha256": _digest(replacement), "original_metadata": metadata,
            "service": service, "report": report}


def _validate_state(state):
    if not isinstance(state, dict) or state.get("version") != 1:
        raise EnrollmentError("Unsupported SSH transaction state")
    backup_dir = Path(state.get("backup_dir", ""))
    # State is authenticated by the root-owned installer journal. Enforce its
    # only data paths nonetheless; no target path is ever taken from state.
    _audit_directories(backup_dir)
    if stat.S_IMODE(backup_dir.stat().st_mode) & 0o077:
        raise EnrollmentError("SSH backup directory is not private")
    if type(state.get("directory_existed")) is not bool:
        raise EnrollmentError("Invalid SSH directory state")
    for name in ("original_sha256", "replacement_sha256"):
        value = state.get(name)
        if name == "original_sha256" and value is None:
            continue
        if not isinstance(value, str) or not re.fullmatch("[0-9a-f]{64}", value):
            raise EnrollmentError("Invalid SSH file digest in journal")
    original = None
    metadata = state.get("original_metadata")
    if state["original_sha256"] is not None:
        if (not isinstance(metadata, dict) or metadata.get("uid") != 0 or metadata.get("gid") != 0 or
                type(metadata.get("mode")) is not int or not 0 <= metadata["mode"] <= 0o777 or
                metadata["mode"] & 0o022):
            raise EnrollmentError("Unsafe SSH original metadata in journal")
        original, _ = _secure_read(backup_dir / "ssh-authorized-keys.before", require_root_group=True)
        if _digest(original) != state["original_sha256"]:
            raise EnrollmentError("SSH original backup digest mismatch")
    elif metadata is not None:
        raise EnrollmentError("Unexpected SSH original metadata")
    replacement, _ = _secure_read(backup_dir / "ssh-authorized-keys.after", require_root_group=True)
    if _digest(replacement) != state["replacement_sha256"]:
        raise EnrollmentError("SSH replacement backup digest mismatch")
    service = state.get("service", {})
    if service.get("enabled") not in {"enabled", "disabled", "enabled-runtime"} or type(service.get("active")) is not bool:
        raise EnrollmentError("Invalid SSH service state in journal")
    return original, replacement


def apply(state):
    original, replacement = _validate_state(state)
    existed, current, metadata = _current_keys()
    if existed != state["directory_existed"] or current != original or metadata != state["original_metadata"]:
        raise EnrollmentError("SSH targets changed after preflight; no existing keys were overwritten")
    if not existed:
        os.mkdir(_root_path("/root/.ssh"), 0o700)
        _sync_directory(_root_path("/root"))
    if current != replacement:
        _atomic_write(_root_path("/root/.ssh/authorized_keys"), replacement)
    _command(["/usr/sbin/sshd", "-t"])
    current_service = _service_state()
    if current_service != state["service"]:
        raise EnrollmentError("SSH service changed after preflight; refusing concurrent changes")
    if current_service["enabled"] in {"disabled", "enabled-runtime"}:
        _command(["/usr/bin/systemctl", "enable", "ssh.service"])
    if not current_service["active"]:
        _command(["/usr/bin/systemctl", "start", "ssh.service"])
    final_service = _service_state()
    if not final_service["active"] or final_service["enabled"] != "enabled":
        raise EnrollmentError("SSH did not become active and enabled")
    return dict(state["report"], enrollment="installed", service="active")


def rollback(state):
    """Idempotently recover before/after files; refuse unrelated later edits."""
    original, replacement = _validate_state(state)
    existed, current, metadata = _current_keys()
    if current not in (original, replacement):
        raise EnrollmentError("SSH keys changed outside this transaction; refusing rollback overwrite")
    if current is not None and metadata not in (state["original_metadata"], {"mode": 0o600, "uid": 0, "gid": 0}):
        raise EnrollmentError("SSH key permissions changed outside this transaction; refusing rollback overwrite")
    current_service = _service_state()
    if not state["service"]["active"] and current_service["active"]:
        _command(["/usr/bin/systemctl", "stop", "ssh.service"])
    if state["service"]["enabled"] == "disabled" and current_service["enabled"] != "disabled":
        _command(["/usr/bin/systemctl", "disable", "ssh.service"])
    elif state["service"]["enabled"] == "enabled-runtime" and current_service["enabled"] != "enabled-runtime":
        _command(["/usr/bin/systemctl", "disable", "ssh.service"])
        _command(["/usr/bin/systemctl", "enable", "--runtime", "ssh.service"])
    if original is None:
        if current is not None:
            os.unlink(_root_path("/root/.ssh/authorized_keys"))
            _sync_directory(_root_path("/root/.ssh"))
    elif current != original or metadata != state["original_metadata"]:
        _atomic_write(_root_path("/root/.ssh/authorized_keys"), original, state["original_metadata"])
    if not state["directory_existed"] and existed:
        try:
            os.rmdir(_root_path("/root/.ssh"))
            _sync_directory(_root_path("/root"))
        except OSError:
            # Preserve unrelated files that may have been created since prepare.
            pass


recover = rollback
