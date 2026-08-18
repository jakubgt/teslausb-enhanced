#!/usr/bin/env python3
"""Validate and emit TeslaUSB's strict declarative setup configuration.

The emit0 format is private to teslausb-config-loader.sh.  Every field is
NUL-delimited so values are never re-parsed as shell source.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path
from typing import Any


MAX_CONFIG_BYTES = 1024 * 1024
MAX_STRING_BYTES = 16 * 1024
MAX_ARRAY_ITEMS = 128

BOOLEAN_NAMES = {
    "ARCHIVE_RECENTCLIPS",
    "ARCHIVE_SAVEDCLIPS",
    "ARCHIVE_SENTRYCLIPS",
    "ARCHIVE_TRACKMODECLIPS",
    "CONFIGURE_ARCHIVING",
    "DISCORD_ENABLED",
    "GOTIFY_ENABLED",
    "IFTTT_ENABLED",
    "MATRIX_ENABLED",
    "NOTIFICATION_COMMAND_ENABLED",
    "NTFY_ENABLED",
    "PUSHOVER_ENABLED",
    "SAMBA_ENABLED",
    "SAMBA_GUEST",
    "SIGNAL_ENABLED",
    "SKIP_READONLY",
    "SLACK_ENABLED",
    "SNAPSHOTS_ENABLED",
    "SNS_ENABLED",
    "SSH_ALLOW_DEFAULT_PASSWORD",
    "SSH_DISABLE_PASSWORD_AUTHENTICATION",
    "TELEGRAM_ENABLED",
    "TELEGRAM_SILENT_NOTIFY",
    "TEMPERATURE_POSTARCHIVE",
    "UPGRADE_PACKAGES",
    "USE_EXFAT",
    "WEBHOOK_ENABLED",
    "WEB_AUTH_DISABLED",
}

INTEGER_RANGES = {
    "ARCHIVE_DELAY": (0, 86400),
    "ARCHIVE_RETRY_ATTEMPTS_PER_RUN": (1, 20),
    "ARCHIVE_RETRY_BASE_SECONDS": (1, 86400),
    "ARCHIVE_RETRY_MAX_SECONDS": (1, 604800),
    "ARCHIVE_RSYNC_TIMEOUT": (1, 86400),
    "AUTOFS_WAIT_SECONDS": (1, 600),
    "DIRTY_BACKGROUND_BYTES": (0, 2**31 - 1),
    "DIRTY_RATIO": (0, 100),
    "FORCE_SYNC_TIMEOUT_SECONDS": (1, 86400),
    "GOTIFY_PRIORITY": (-2, 10),
    "MUSIC_RSYNC_TIMEOUT": (1, 86400),
    "NTFY_PRIORITY": (1, 5),
    "PIP_RETRIES": (0, 20),
    "PIP_TIMEOUT_SECONDS": (1, 600),
    "RCLONE_CONNECT_TIMEOUT": (1, 3600),
    "RCLONE_IO_TIMEOUT": (1, 86400),
    "RSYNC_SSH_CONNECT_TIMEOUT": (1, 3600),
    "SENTRY_CASE": (1, 3),
    "SNAPSHOT_INTERVAL": (60, 86400),
    "TEMPERATURE_CAUTION": (-100000, 200000),
    "TEMPERATURE_INTERVAL": (1, 86400),
    "TEMPERATURE_WARNING": (-100000, 200000),
    "TESLAUSB_CURL_CONNECT_TIMEOUT": (1, 3600),
    "TESLAUSB_CURL_MAX_TIME": (1, 86400),
    "TESLAUSB_NOTIFICATION_TIMEOUT_SECONDS": (1, 3600),
    "TESLA_BLE_ARTIFACT_MAX_BYTES": (1, 1024 * 1024 * 1024),
    "TESLA_BLE_COMMAND_TIMEOUT_SECONDS": (1, 3600),
}

ARRAY_NAMES = {
    "INSTALL_USER_REQUESTED_PACKAGES",
    "RCLONE_FLAGS",
}

STRING_NAMES = {
    "AP_IP",
    "AP_PASS",
    "AP_SSID",
    "ARCHIVE_SERVER",
    "ARCHIVE_SYSTEM",
    "AWS_ACCESS_KEY_ID",
    "AWS_REGION",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SNS_TOPIC_ARN",
    "BOOMBOX_SIZE",
    "BRANCH",
    "CAM_SIZE",
    "CIFS_SEC",
    "CIFS_VERSION",
    "CPU_GOVERNOR",
    "DATA_DRIVE",
    "DISCORD_WEBHOOK_URL",
    "GOTIFY_APP_TOKEN",
    "GOTIFY_DOMAIN",
    "IFTTT_EVENT_NAME",
    "IFTTT_KEY",
    "INCREASE_ROOT_SIZE",
    "KEEP_AWAKE_WEBHOOK_URL",
    "LIGHTSHOW_SIZE",
    "MATRIX_PASSWORD",
    "MATRIX_ROOM",
    "MATRIX_SERVER_URL",
    "MATRIX_USERNAME",
    "MUSIC_SHARE_NAME",
    "MUSIC_SIZE",
    "NOTIFICATION_COMMAND_FINISH",
    "NOTIFICATION_COMMAND_START",
    "NOTIFICATION_TITLE",
    "NTFY_TOKEN",
    "NTFY_URL",
    "PUSHOVER_APP_KEY",
    "PUSHOVER_USER_KEY",
    "RCLONE_DRIVE",
    "RCLONE_PATH",
    "REPO",
    "RSYNC_PATH",
    "RSYNC_SERVER",
    "RSYNC_USER",
    "SAMBA_PASSWORD",
    "SAMBA_USER",
    "SHARE_DOMAIN",
    "SHARE_NAME",
    "SHARE_PASSWORD",
    "SHARE_USER",
    "SIGNAL_FROM_NUM",
    "SIGNAL_TO_NUM",
    "SIGNAL_URL",
    "SLACK_WEBHOOK_URL",
    "SSH_ROOT_PUBLIC_KEY",
    "SSH_USER_PASSWORD",
    "SSID",
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CHAT_ID",
    "TESLAFI_API_TOKEN",
    "TESLAUSB_HOSTNAME",
    "TESLA_BLE_ARTIFACT_FILE",
    "TESLA_BLE_ARTIFACT_SHA256",
    "TESLA_BLE_ARTIFACT_VERSION",
    "TESLA_BLE_VIN",
    "TESSIE_API_TOKEN",
    "TESSIE_VIN",
    "TIME_ZONE",
    "TRIGGER_FILE_ANY",
    "TRIGGER_FILE_RECENT",
    "TRIGGER_FILE_SAVED",
    "TRIGGER_FILE_SENTRY",
    "WEBHOOK_URL",
    "WEB_ALLOWED_HOSTS",
    "WEB_PASSWORD",
    "WEB_USERNAME",
    "WEBUI_RELEASE",
    "WEBUI_SHA256",
    "WIFIPASS",
    "WIFI_COUNTRY",
}

ALLOWED_NAMES = BOOLEAN_NAMES | set(INTEGER_RANGES) | ARRAY_NAMES | STRING_NAMES
ARCHIVE_SYSTEMS = {"cifs", "nfs", "none", "rclone", "rsync"}
SIZE_PATTERN = re.compile(r"^([1-9][0-9]*)([KMG])$")
CAM_SIZE_PATTERN = re.compile(r"^([1-9][0-9]*)(?:G|GiB)$")
MIN_CAM_SIZE_GIB = 20
MAX_CAM_SIZE_GIB = 1780
MAX_STORAGE_SIZE_KIB = MAX_CAM_SIZE_GIB * 1024 * 1024
HOSTNAME_PATTERN = re.compile(r"^(?=.{1,63}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
SAFE_REF_PATTERN = re.compile(r"^[A-Za-z0-9._/-]+$")
RELEASE_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$")
WEB_USER_PATTERN = re.compile(r"^[A-Za-z0-9_.@-]{1,64}$")
SHA256_PATTERN = re.compile(r"^[0-9a-fA-F]{64}$")
PACKAGE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+.-]*$")
VIN_PATTERN = re.compile(r"^[A-HJ-NPR-Za-hj-npr-z0-9]{17}$")
# Generated from iso3166-country-codes.json. The test suite requires exact
# parity with that canonical list while this validator remains self-contained
# when it is installed in /root/bin during an upgrade.
ISO3166_ALPHA2_CODES = frozenset("""
AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ
BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ
CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ
DE DJ DK DM DO DZ
EC EE EG EH ER ES ET
FI FJ FK FM FO FR
GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY
HK HM HN HR HT HU
ID IE IL IM IN IO IQ IR IS IT
JE JM JO JP
KE KG KH KI KM KN KP KR KW KY KZ
LA LB LC LI LK LR LS LT LU LV LY
MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ
NA NC NE NF NG NI NL NO NP NR NU NZ
OM
PA PE PF PG PH PK PL PM PN PR PS PT PW PY
QA
RE RO RS RU RW
SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ
TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ
UA UG UM US UY UZ
VA VC VE VG VI VN VU
WF WS
YE YT
ZA ZM ZW
""".split())
CONTROL_CHARACTER_PATTERN = re.compile(r"[\x00-\x1f\x7f]")
TIME_ZONE_SEGMENT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
DEVICE_PATH_SEGMENT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+:-]*$")
CIFS_VERSIONS = {"default", "1.0", "2.0", "2.1", "3.0", "3.02", "3.1.1"}
CIFS_SECURITY_MODES = {
    "none", "krb5", "krb5i", "ntlm", "ntlmi", "ntlmv2", "ntlmv2i",
    "ntlmssp", "ntlmsspi",
}
NOTIFICATION_REQUIREMENTS = {
    "SIGNAL_ENABLED": ("SIGNAL_URL", "SIGNAL_TO_NUM", "SIGNAL_FROM_NUM"),
    "PUSHOVER_ENABLED": ("PUSHOVER_USER_KEY", "PUSHOVER_APP_KEY"),
    "GOTIFY_ENABLED": ("GOTIFY_DOMAIN", "GOTIFY_APP_TOKEN", "GOTIFY_PRIORITY"),
    "DISCORD_ENABLED": ("DISCORD_WEBHOOK_URL",),
    "IFTTT_ENABLED": ("IFTTT_EVENT_NAME", "IFTTT_KEY"),
    "WEBHOOK_ENABLED": ("WEBHOOK_URL",),
    "SLACK_ENABLED": ("SLACK_WEBHOOK_URL",),
    "MATRIX_ENABLED": ("MATRIX_SERVER_URL", "MATRIX_USERNAME", "MATRIX_PASSWORD", "MATRIX_ROOM"),
    "SNS_ENABLED": ("AWS_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SNS_TOPIC_ARN"),
    "TELEGRAM_ENABLED": ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID"),
    "NTFY_ENABLED": ("NTFY_URL",),
}
KNOWN_PLACEHOLDER_VALUES = {
    "password",
    "raspberry",
    "username",
    "hostname",
    "hostname_or_ip",
    "http://<url>:8080",
    "http://domain/path/",
    "https://gotify.domain.com",
    "country_code_and_number_configured_with_signal",
    "123456789",
    "bot123456789:abcdefghijklmnopqrstuvqxyz987654321",
}


class ConfigError(ValueError):
    """A user-facing validation error."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ConfigError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ConfigError(f"non-finite JSON number is not allowed: {value}")


def _require_pair(variables: dict[str, Any], left: str, right: str) -> None:
    if (left in variables) != (right in variables):
        raise ConfigError(f"{left} and {right} must either both be set or both be omitted")


def _require_nonempty(variables: dict[str, Any], name: str, context: str = "") -> None:
    if name not in variables or variables[name] == "":
        suffix = f" {context}" if context else ""
        raise ConfigError(f"{name} is required{suffix}")


def _looks_like_placeholder(value: str) -> bool:
    lowered = value.strip().lower()
    return (
        lowered in KNOWN_PLACEHOLDER_VALUES
        or lowered.startswith((
            "your_", "your-", "put_your_", "put-your-", "replace_with_",
            "replace-with-", "choose-a-unique-", "put_the_", "put-the-",
        ))
        or "<redacted>" in lowered
        or re.search(r"<[^>]+>", lowered) is not None
        or lowered.endswith(("_goes_here", "-goes-here"))
        or lowered.startswith("your_archive_")
    )


def _validate_ref(value: str) -> bool:
    if not value or len(value) > 255 or not SAFE_REF_PATTERN.fullmatch(value):
        return False
    if value.startswith("/") or value.endswith("/") or ".." in value or "//" in value or "@{" in value:
        return False
    return all(part and not part.startswith(".") and not part.endswith((".", ".lock")) for part in value.split("/"))


def _is_allowed_web_host(value: str) -> bool:
    candidate = value[1:-1] if value.startswith("[") and value.endswith("]") else value
    try:
        ipaddress.ip_address(candidate)
        return True
    except ValueError:
        pass
    if not candidate or len(candidate) > 253:
        return False
    return all(HOSTNAME_PATTERN.fullmatch(label) for label in candidate.split("."))


def _is_safe_time_zone(value: str) -> bool:
    if value == "auto":
        return True
    if not value or len(value.encode("utf-8")) > 255 or value.startswith(("/", "\\")):
        return False
    components = value.split("/")
    return all(
        component not in {".", ".."} and TIME_ZONE_SEGMENT_PATTERN.fullmatch(component)
        for component in components
    )


def _is_safe_trigger_name(value: str) -> bool:
    return (
        value not in {"", ".", ".."}
        and "/" not in value
        and "\\" not in value
        and len(value.encode("utf-8")) <= 255
        and not CONTROL_CHARACTER_PATTERN.search(value)
    )


def _is_safe_device_path(value: str) -> bool:
    if not value.startswith("/dev/"):
        return False
    components = value[len("/dev/"):].split("/")
    return all(
        component not in {"", ".", ".."}
        and DEVICE_PATH_SEGMENT_PATTERN.fullmatch(component)
        for component in components
    )


def validate_document(document: Any) -> tuple[dict[str, Any], list[str]]:
    if not isinstance(document, dict):
        raise ConfigError("the document must be a JSON object")
    allowed_top_level = {"$schema", "schema_version", "variables"}
    unknown_top_level = sorted(set(document) - allowed_top_level)
    if unknown_top_level:
        raise ConfigError(f"unknown top-level key(s): {', '.join(unknown_top_level)}")
    if type(document.get("schema_version")) is not int or document["schema_version"] != 1:
        raise ConfigError("schema_version must be the integer 1")
    if "$schema" in document and not isinstance(document["$schema"], str):
        raise ConfigError("$schema must be a string when present")
    variables = document.get("variables")
    if not isinstance(variables, dict):
        raise ConfigError("variables must be a JSON object")

    unknown = sorted(set(variables) - ALLOWED_NAMES)
    if unknown:
        raise ConfigError(f"unsupported variable(s): {', '.join(unknown)}")

    for name, value in variables.items():
        if name in BOOLEAN_NAMES:
            if type(value) is not bool:
                raise ConfigError(f"{name} must be a JSON boolean")
        elif name in INTEGER_RANGES:
            if type(value) is not int:
                raise ConfigError(f"{name} must be a JSON integer")
            minimum, maximum = INTEGER_RANGES[name]
            if value < minimum or value > maximum:
                raise ConfigError(f"{name} must be between {minimum} and {maximum}")
        elif name in ARRAY_NAMES:
            if not isinstance(value, list):
                raise ConfigError(f"{name} must be a JSON array of strings")
            if len(value) > MAX_ARRAY_ITEMS:
                raise ConfigError(f"{name} contains more than {MAX_ARRAY_ITEMS} items")
            for index, item in enumerate(value):
                if not isinstance(item, str):
                    raise ConfigError(f"{name}[{index}] must be a string")
                if CONTROL_CHARACTER_PATTERN.search(item) or len(item.encode("utf-8")) > MAX_STRING_BYTES:
                    raise ConfigError(f"{name}[{index}] is too large or contains a control character")
        elif not isinstance(value, str):
            raise ConfigError(f"{name} must be a JSON string")

        if isinstance(value, str):
            if CONTROL_CHARACTER_PATTERN.search(value):
                raise ConfigError(f"{name} must not contain control characters")
            if len(value.encode("utf-8")) > MAX_STRING_BYTES:
                raise ConfigError(f"{name} exceeds {MAX_STRING_BYTES} UTF-8 bytes")

    _require_nonempty(variables, "ARCHIVE_SYSTEM")
    _require_nonempty(variables, "CAM_SIZE")
    archive_system = variables["ARCHIVE_SYSTEM"]
    if archive_system not in ARCHIVE_SYSTEMS:
        raise ConfigError(f"ARCHIVE_SYSTEM must be one of: {', '.join(sorted(ARCHIVE_SYSTEMS))}")
    if archive_system == "cifs":
        for name in ("ARCHIVE_SERVER", "SHARE_NAME", "SHARE_USER", "SHARE_PASSWORD"):
            _require_nonempty(variables, name, "for CIFS archiving")
    elif archive_system == "nfs":
        for name in ("ARCHIVE_SERVER", "SHARE_NAME"):
            _require_nonempty(variables, name, "for NFS archiving")
    elif archive_system == "rsync":
        for name in ("RSYNC_USER", "RSYNC_SERVER", "RSYNC_PATH"):
            _require_nonempty(variables, name, "for rsync archiving")
    elif archive_system == "rclone":
        for name in ("RCLONE_DRIVE", "RCLONE_PATH"):
            _require_nonempty(variables, name, "for rclone archiving")

    _require_pair(variables, "SSID", "WIFIPASS")
    _require_pair(variables, "AP_SSID", "AP_PASS")
    _require_pair(variables, "WEB_USERNAME", "WEB_PASSWORD")
    _require_pair(variables, "WEBUI_RELEASE", "WEBUI_SHA256")

    cam_size_match = CAM_SIZE_PATTERN.fullmatch(variables["CAM_SIZE"])
    if not cam_size_match:
        raise ConfigError(
            "CAM_SIZE must use an explicit G or GiB suffix, such as 40G"
        )
    cam_size_digits = cam_size_match.group(1)
    if len(cam_size_digits) > 4:
        raise ConfigError(
            f"CAM_SIZE must be between {MIN_CAM_SIZE_GIB}G and {MAX_CAM_SIZE_GIB}G; "
            "40G is recommended"
        )
    cam_size_gib = int(cam_size_digits)
    if cam_size_gib < MIN_CAM_SIZE_GIB or cam_size_gib > MAX_CAM_SIZE_GIB:
        raise ConfigError(
            f"CAM_SIZE must be between {MIN_CAM_SIZE_GIB}G and {MAX_CAM_SIZE_GIB}G; "
            "40G is recommended"
        )
    variables["CAM_SIZE"] = f"{cam_size_gib}G"

    for name in ("MUSIC_SIZE", "LIGHTSHOW_SIZE", "BOOMBOX_SIZE", "INCREASE_ROOT_SIZE"):
        if name not in variables or variables[name] in {"", "0"}:
            continue
        size_match = SIZE_PATTERN.fullmatch(variables[name])
        if not size_match:
            raise ConfigError(
                f"{name} must use an explicit K, M, or G suffix, such as 512M or 4G"
            )
        size_digits = size_match.group(1)
        if len(size_digits) > 10:
            raise ConfigError(
                f"{name} must not exceed {MAX_CAM_SIZE_GIB}G"
            )
        size_kib = int(size_digits) * {
            "K": 1,
            "M": 1024,
            "G": 1024 * 1024,
        }[size_match.group(2)]
        if size_kib > MAX_STORAGE_SIZE_KIB:
            raise ConfigError(
                f"{name} must not exceed {MAX_CAM_SIZE_GIB}G"
            )

    if "TESLAUSB_HOSTNAME" in variables and not HOSTNAME_PATTERN.fullmatch(variables["TESLAUSB_HOSTNAME"]):
        raise ConfigError("TESLAUSB_HOSTNAME must be one DNS label of 1-63 characters")
    if "REPO" in variables and not REPOSITORY_PATTERN.fullmatch(variables["REPO"]):
        raise ConfigError("REPO is not a valid GitHub owner name")
    if "BRANCH" in variables and not _validate_ref(variables["BRANCH"]):
        raise ConfigError("BRANCH is not a safe Git reference")
    if "WEB_ALLOWED_HOSTS" in variables:
        allowed_hosts = [item for item in re.split(r"[\s,]+", variables["WEB_ALLOWED_HOSTS"]) if item]
        if not allowed_hosts or any(not _is_allowed_web_host(item) for item in allowed_hosts):
            raise ConfigError("WEB_ALLOWED_HOSTS must contain exact DNS names or IP addresses without ports")
    if "WEBUI_RELEASE" in variables:
        webui_release = variables["WEBUI_RELEASE"]
        if (webui_release.lower() == "latest" or ".." in webui_release or
                not RELEASE_PATTERN.fullmatch(webui_release)):
            raise ConfigError("WEBUI_RELEASE must name an immutable tag using safe release characters")
    if "WEB_USERNAME" in variables and not WEB_USER_PATTERN.fullmatch(variables["WEB_USERNAME"]):
        raise ConfigError("WEB_USERNAME contains unsupported characters or is too long")
    if "WEB_PASSWORD" in variables:
        password = variables["WEB_PASSWORD"]
        password_bytes = len(password.encode("utf-8"))
        if "\n" in password or "\r" in password or password_bytes < 12 or password_bytes > 72:
            raise ConfigError("WEB_PASSWORD must be 12-72 UTF-8 bytes with no newline")
        if password.lower() in {"raspberry", "password", "teslausb", variables["WEB_USERNAME"].lower()}:
            raise ConfigError("WEB_PASSWORD uses an unsafe default or matches WEB_USERNAME")
    if variables.get("WEB_AUTH_DISABLED") is True and (
            "WEB_USERNAME" in variables or "WEB_PASSWORD" in variables):
        raise ConfigError("WEB_AUTH_DISABLED cannot be combined with WEB_USERNAME or WEB_PASSWORD")
    if "AP_SSID" in variables:
        ssid_bytes = len(variables["AP_SSID"].encode("utf-8"))
        if ssid_bytes < 1 or ssid_bytes > 32:
            raise ConfigError("AP_SSID must be 1-32 UTF-8 bytes")
    if "AP_PASS" in variables:
        passphrase_bytes = len(variables["AP_PASS"].encode("utf-8"))
        if passphrase_bytes < 8 or passphrase_bytes > 63 or variables["AP_PASS"].lower() == "password":
            raise ConfigError("AP_PASS must be 8-63 UTF-8 bytes and not use the sample password")
    if "AP_IP" in variables:
        try:
            ap_ip = ipaddress.IPv4Address(variables["AP_IP"])
        except ipaddress.AddressValueError as exc:
            raise ConfigError("AP_IP must be an IPv4 address") from exc
        if int(ap_ip) & 0xff not in range(1, 10):
            raise ConfigError("AP_IP must end in .1 through .9, outside the .10-.254 DHCP pool")
    if "ARCHIVE_SERVER" in variables and variables["ARCHIVE_SERVER"]:
        if not _is_allowed_web_host(variables["ARCHIVE_SERVER"]):
            raise ConfigError("ARCHIVE_SERVER must be an exact DNS name or IP address without a port")
    if archive_system == "nfs" and not variables["SHARE_NAME"].startswith("/"):
        raise ConfigError("SHARE_NAME must be an absolute exported path for NFS archiving")
    if "CIFS_VERSION" in variables and variables["CIFS_VERSION"] not in CIFS_VERSIONS:
        raise ConfigError(f"CIFS_VERSION must be one of: {', '.join(sorted(CIFS_VERSIONS))}")
    if "CIFS_SEC" in variables and variables["CIFS_SEC"] not in CIFS_SECURITY_MODES:
        raise ConfigError(f"CIFS_SEC must be one of: {', '.join(sorted(CIFS_SECURITY_MODES))}")
    if "TIME_ZONE" in variables and variables["TIME_ZONE"] and not _is_safe_time_zone(variables["TIME_ZONE"]):
        raise ConfigError("TIME_ZONE must be auto or a relative zoneinfo name without traversal")
    if "WIFI_COUNTRY" in variables and variables["WIFI_COUNTRY"] not in ISO3166_ALPHA2_CODES:
        raise ConfigError(
            "WIFI_COUNTRY must be a valid uppercase two-letter ISO 3166-1 alpha-2 regulatory country code"
        )
    for trigger_name in ("TRIGGER_FILE_ANY", "TRIGGER_FILE_RECENT", "TRIGGER_FILE_SAVED", "TRIGGER_FILE_SENTRY"):
        if trigger_name in variables and not _is_safe_trigger_name(variables[trigger_name]):
            raise ConfigError(f"{trigger_name} must be one filename, not a path")
    if variables.get("SAMBA_ENABLED") is True and variables.get("SAMBA_GUEST") is not True:
        _require_nonempty(variables, "SAMBA_PASSWORD", "for authenticated Samba sharing")
        if len(variables["SAMBA_PASSWORD"].encode("utf-8")) < 12:
            raise ConfigError("SAMBA_PASSWORD must be at least 12 UTF-8 bytes")
    if "WEBUI_SHA256" in variables and not SHA256_PATTERN.fullmatch(variables["WEBUI_SHA256"]):
        raise ConfigError("WEBUI_SHA256 must be exactly 64 hexadecimal characters")
    if "TESLA_BLE_ARTIFACT_SHA256" in variables and not SHA256_PATTERN.fullmatch(variables["TESLA_BLE_ARTIFACT_SHA256"]):
        raise ConfigError("TESLA_BLE_ARTIFACT_SHA256 must be exactly 64 hexadecimal characters")
    for vin_name in ("TESLA_BLE_VIN", "TESSIE_VIN"):
        if vin_name in variables and not VIN_PATTERN.fullmatch(variables[vin_name]):
            raise ConfigError(f"{vin_name} must be a 17-character VIN")
    if "SSH_ROOT_PUBLIC_KEY" in variables and any(c in variables["SSH_ROOT_PUBLIC_KEY"] for c in "\r\n"):
        raise ConfigError("SSH_ROOT_PUBLIC_KEY must contain exactly one line")
    if "SSH_USER_PASSWORD" in variables:
        ssh_password = variables["SSH_USER_PASSWORD"]
        if any(c in ssh_password for c in "\r\n") or len(ssh_password.encode("utf-8")) < 12:
            raise ConfigError("SSH_USER_PASSWORD must be at least 12 UTF-8 bytes with no newline")
    if ("DATA_DRIVE" in variables and variables["DATA_DRIVE"]
            and not _is_safe_device_path(variables["DATA_DRIVE"])):
        raise ConfigError(
            "DATA_DRIVE must be an absolute whole-disk path under /dev without traversal"
        )
    if "INSTALL_USER_REQUESTED_PACKAGES" in variables:
        for package in variables["INSTALL_USER_REQUESTED_PACKAGES"]:
            if not PACKAGE_PATTERN.fullmatch(package):
                raise ConfigError(f"unsupported package name: {package}")

    keep_awake_names = ("TESLAFI_API_TOKEN", "TESSIE_API_TOKEN", "TESLA_BLE_VIN", "KEEP_AWAKE_WEBHOOK_URL")
    if any(variables.get(name) for name in keep_awake_names):
        _require_nonempty(variables, "SENTRY_CASE", "when a keep-awake method is configured")
        if variables.get("TESLAFI_API_TOKEN") and variables["SENTRY_CASE"] not in {1, 2}:
            raise ConfigError("SENTRY_CASE must be 1 or 2 for TeslaFi")
    if variables.get("TESSIE_API_TOKEN"):
        _require_nonempty(variables, "TESSIE_VIN", "when Tessie is configured")

    if ("ARCHIVE_RETRY_BASE_SECONDS" in variables and "ARCHIVE_RETRY_MAX_SECONDS" in variables and
            variables["ARCHIVE_RETRY_BASE_SECONDS"] > variables["ARCHIVE_RETRY_MAX_SECONDS"]):
        raise ConfigError("ARCHIVE_RETRY_BASE_SECONDS must not exceed ARCHIVE_RETRY_MAX_SECONDS")

    for enabled_name, required_names in NOTIFICATION_REQUIREMENTS.items():
        if variables.get(enabled_name) is True:
            for required_name in required_names:
                _require_nonempty(variables, required_name, f"when {enabled_name}=true")
    if variables.get("NOTIFICATION_COMMAND_ENABLED") is True and not (
            variables.get("NOTIFICATION_COMMAND_START") or variables.get("NOTIFICATION_COMMAND_FINISH")):
        raise ConfigError(
            "NOTIFICATION_COMMAND_START or NOTIFICATION_COMMAND_FINISH is required "
            "when NOTIFICATION_COMMAND_ENABLED=true"
        )

    keep_awake = [
        name
        for name in keep_awake_names
        if variables.get(name)
    ]
    if len(keep_awake) > 1:
        raise ConfigError(f"only one keep-awake method may be configured, found: {', '.join(keep_awake)}")

    for name, value in variables.items():
        values = value if isinstance(value, list) else [value]
        for candidate in values:
            if isinstance(candidate, str) and _looks_like_placeholder(candidate):
                raise ConfigError(f"{name} still contains a sample placeholder")

    warnings: list[str] = []
    if variables.get("SSID") and "WIFI_COUNTRY" not in variables:
        warnings.append(
            "WIFI_COUNTRY is absent; a new image will refuse to enable Wi-Fi until an "
            "uppercase two-letter regulatory country is configured"
        )
    if variables.get("DATA_DRIVE"):
        warnings.append(f"DATA_DRIVE={variables['DATA_DRIVE']} will be wiped and repartitioned during setup")
    if variables.get("SSH_ALLOW_DEFAULT_PASSWORD") is True:
        warnings.append("SSH_ALLOW_DEFAULT_PASSWORD=true retains a known default password")
    if variables.get("NOTIFICATION_COMMAND_ENABLED") is True:
        warnings.append("notification command values are intentionally executed when notifications run")
    return variables, warnings


def load_config(path: Path) -> tuple[dict[str, Any], list[str]]:
    if path.is_symlink() or not path.is_file():
        raise ConfigError(f"{path} must be a regular file, not a symbolic link")
    if path.stat().st_size > MAX_CONFIG_BYTES:
        raise ConfigError(f"{path} exceeds {MAX_CONFIG_BYTES} bytes")
    try:
        with path.open("r", encoding="utf-8") as stream:
            document = json.load(stream, object_pairs_hook=_unique_object, parse_constant=_reject_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ConfigError(f"unable to read valid UTF-8 JSON from {path}: {exc}") from exc
    return validate_document(document)


def emit0(variables: dict[str, Any]) -> None:
    output = sys.stdout.buffer
    for name in sorted(variables):
        value = variables[name]
        if isinstance(value, list):
            fields = ["A", name, str(len(value)), *value]
        else:
            if type(value) is bool:
                rendered = "true" if value else "false"
            else:
                rendered = str(value)
            fields = ["S", name, rendered]
        for field in fields:
            output.write(field.encode("utf-8"))
            output.write(b"\0")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("emit0", "get-ble-vin", "validate"))
    parser.add_argument("config", type=Path)
    args = parser.parse_args(argv)
    try:
        variables, warnings = load_config(args.config)
    except ConfigError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    for warning in warnings:
        print(f"WARNING: {warning}", file=sys.stderr)
    if args.command == "validate":
        print(f"Validated schema version 1 with {len(variables)} variable(s).")
    elif args.command == "get-ble-vin":
        # This narrow accessor lets the fixed privileged web dispatcher read
        # only the VIN it needs without exporting every configured secret to
        # the tesla-control subprocess environment.
        print(variables.get("TESLA_BLE_VIN", ""))
    else:
        emit0(variables)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
