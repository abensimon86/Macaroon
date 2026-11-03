#!/bin/bash
# ==============================================================================
# Macaroon - Chrome Cookie Backup & Export (macOS only)
# Chrome cookies. Decrypted. Editor-ready.
# ==============================================================================
# A single-file Bash launcher with an embedded Python implementation.
# Bash handles startup; Python handles SQLite, validation, and cookie decryption.
#
# DEFAULT WORKFLOW
#   1. Quit Google Chrome and wait three seconds.
#   2. Verify Chrome has stopped, then copy the Default profile to the Desktop.
#   3. Ask for a domain, unless --domain was supplied.
#   4. Read matching cookies from the NEW backup, including subdomains.
#   5. Read Chrome Safe Storage when needed, or use a supplied password.
#      A password retrieved from Keychain is shown once on the terminal by default.
#   6. Export a Cookie-Editor JSON file and a human-readable record file.
#
# REQUIREMENTS
#   - macOS only (supported platform); backup and Keychain access use macOS tools.
#   - Python 3.9 or newer, with the pycryptodome package installed.
#   - Google Chrome's Default profile in its standard location.
#   - No separate sqlite3 command-line installation is needed.
#
# EXAMPLES
#   bash macaroon.sh
#   bash macaroon.sh --domain okta.com
#   bash macaroon.sh --domain okta.com -o ./cookies.json
#   bash macaroon.sh abc.txt -o ./cookies.json --timezone UTC
#   bash macaroon.sh --domain okta.com --safe-storage-password
#   bash macaroon.sh --domain okta.com --safe-storage-password 'YOUR_PASSWORD'
#   bash macaroon.sh --domain okta.com --hide-safe-storage-password
#   bash macaroon.sh --help
#
# PASSWORD OPTIONS
#   --safe-storage-password
#       Ask for a known password using hidden terminal input; do not access Keychain.
#       Keep this option last, or follow it with another --option, to omit its value.
#   --safe-storage-password PASSWORD
#       Use the literal supplied password; do not access Keychain. WARNING: a value
#       on the command line may appear in shell history and process listings.
#   --hide-safe-storage-password
#       Do not display a password retrieved from Keychain. Manually supplied
#       passwords are never redisplayed, regardless of this option.
#
# DEFAULT OUTPUT DIRECTORY
#   ~/Desktop/Chrome-Default-profile-YYYYMMDD-HHMMSS/cookie-export/
#     abc.txt             Selected database records; may contain plaintext values.
#     cookie-editor.json  Decrypted cookies, ready for Cookie-Editor import.
#
# IMPORTANT
#   - Use only with profiles and accounts you are authorized to access.
#   - The backup contains the ENTIRE Default profile, not only selected cookies.
#   - Chrome is not reopened automatically. Keep it closed during the backup.
#   - macOS may ask you to authorize Keychain or application-control access.
#   - Without a supplied password, the matching local Keychain item is required.
#   - No password is embedded in the script or written to a separate password file.
#   - Keychain passwords are displayed directly on /dev/tty, NOT stdout/stderr.
#     They may remain in terminal scrollback or be captured by terminal recording.
#     Display is skipped if no terminal is available; use --hide-safe-storage-password
#     to suppress it explicitly. This does not bypass any Keychain authorization.
#   - This script performs no network requests and installs nothing automatically.
#   - Decryption supports the existing AES-CBC v10 format only.
#   - Treat the full backup and both exported files as sensitive data.
#
# EXIT CODES
#   0   Successful export.
#   1   Runtime, validation, backup, or decryption error.
#   2   Partial export with --skip-errors, or invalid command-line arguments.
#   130 Interrupted by the user; existing backups/intermediate files are kept.
# ==============================================================================

set -euo pipefail
umask 077

# Override this variable to select an existing virtual environment or interpreter:
#   PYTHON_BIN="$HOME/my-venv/bin/python3" bash macaroon.sh
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    printf 'ERROR: Python interpreter not found: %s\n' "$PYTHON_BIN" >&2
    printf 'Install Python 3.9+ or set PYTHON_BIN to an existing interpreter.\n' >&2
    exit 1
fi

if ! "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    printf 'ERROR: Python 3.9 or newer is required.\n' >&2
    exit 1
fi

# Quoting the heredoc delimiter prevents Bash from expanding the Python source.
# Command-line arguments are forwarded unchanged to Python.
exec "$PYTHON_BIN" - "$@" <<'PYTHON'
"""Macaroon: macOS-only Chrome cookie backup, decryption, and JSON export.

Supplying an existing text input file enables conversion-only mode: Chrome is
not closed and no new profile backup is created. Both modes share the same
validation, lazy Keychain access, decryption, and atomic JSON export logic.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import warnings
from contextlib import closing
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterable, Iterator, Optional, TextIO
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

try:
    from Crypto.Cipher import AES
    from Crypto.Util.Padding import unpad
except ModuleNotFoundError:
    print(
        "ERROR: The pycryptodome package is missing. Install it into the Python "
        "environment selected by PYTHON_BIN, for example:\n"
        "  python3 -m pip install pycryptodome",
        file=sys.stderr,
    )
    sys.exit(1)


# ------------------------------------------------------------------------------
# Configuration and shared types
# ------------------------------------------------------------------------------

SCRIPT_NAME = "macaroon.sh"
SCRIPT_VERSION = "3.2"
PROFILE_RELATIVE_PATH = Path("Library/Application Support/Google/Chrome/Default")
BACKUP_PREFIX = "Chrome-Default-profile"
EXPORT_DIRECTORY_NAME = "cookie-export"
CHROME_QUIT_DELAY_SECONDS = 3
KEYCHAIN_SERVICE = "Chrome Safe Storage"
# argparse uses this sentinel when --safe-storage-password has no following value.
PROMPT_FOR_PASSWORD = object()

# Parameters used by the supported macOS Chrome AES-CBC v10 cookie format.
COOKIE_PREFIX = b"v10"
PBKDF2_SALT = b"saltysalt"
PBKDF2_ITERATIONS = 1003
DERIVED_KEY_BYTES = 16
COOKIE_IV = b" " * 16

# Chromium values mapped to Cookie-Editor's JSON representation.
SAME_SITE_MAP = {"-1": None, "0": "no_restriction", "1": "lax", "2": "strict"}
REQUIRED_FIELDS = {
    "host_key", "name", "path", "expires", "is_secure", "is_httponly", "samesite"
}

CookieFields = dict[str, str]
# Each record carries its original/estimated starting line and any parser errors.
CookieRecord = tuple[Optional[int], CookieFields, list[str]]
_warned: set[str] = set()


def warn_once(tag: str, message: str) -> None:
    """Print a warning only once per process, even for large cookie exports."""
    if tag not in _warned:
        _warned.add(tag)
        print(f"WARNING: {message}", file=sys.stderr)


# ------------------------------------------------------------------------------
# Optional legacy text input
# ------------------------------------------------------------------------------


def read_records(path: Path) -> Iterator[CookieRecord]:
    """Read SQLite-style `key = value` records from an existing UTF-8 file.

    A repeated host_key starts a new record, so blank separators are optional.
    Long encrypted_hex values may continue on subsequent hexadecimal lines.
    Parsing errors are attached to their record for --skip-errors handling.
    """
    fields: CookieFields = {}
    errors: list[str] = []
    first_line = None
    previous_key = None

    with path.open(encoding="utf-8-sig") as source:
        for line_number, line in enumerate(source, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if re.fullmatch(r"[-=]{3,}", stripped):
                continue
            if first_line is None:
                first_line = line_number
            if previous_key == "encrypted_hex" and re.fullmatch(
                r"[0-9a-fA-F\s]+", stripped
            ):
                fields[previous_key] += stripped
                continue

            match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", stripped)
            if not match:
                errors.append(f"Line {line_number}: expected key = value.")
                previous_key = None
                continue

            key, value = match.groups()
            if key == "host_key" and "host_key" in fields:
                yield first_line, fields, errors
                fields, errors = {}, []
                first_line = line_number
                previous_key = None
            if key in fields:
                errors.append(
                    f"Line {line_number}: field {key} appears more than once in this record."
                )
            else:
                fields[key] = value
            previous_key = key

        if fields or errors:
            yield first_line, fields, errors


# ------------------------------------------------------------------------------
# Domain selection
# ------------------------------------------------------------------------------


def normalize_domain(text: str) -> str:
    """Validate a domain and normalize common leading wildcard notation.

    okta.com, .okta.com, *.okta.com, and %.okta.com all select the root domain
    plus its subdomains. URLs, paths, SQL fragments, and other wildcard patterns
    are rejected. Internationalized names are converted to ASCII IDNA form.
    """
    domain = text.strip().lower().rstrip(".")
    if domain.startswith(("*.", "%.")):
        domain = domain[2:]
    if domain.startswith("."):
        domain = domain[1:]
    try:
        domain = domain.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise ValueError("Invalid domain name.") from exc

    labels = domain.split(".")
    if len(domain) > 253 or any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in labels
    ):
        raise ValueError(
            "Enter a domain only, such as okta.com, without https://, a path, or quotes."
        )
    return domain


def prompt_domain() -> str:
    """Ask for a valid domain using the terminal rather than Python's stdin.

    stdin contains this embedded Python program, so input() would not read from
    the user's terminal. Opening /dev/tty also keeps piped input separate.
    """
    try:
        with open("/dev/tty", "r", encoding="utf-8") as reader, open(
            "/dev/tty", "w", encoding="utf-8"
        ) as writer:
            while True:
                writer.write(
                    "Which domain would you like to export? "
                    "Example: okta.com (includes subdomains): "
                )
                writer.flush()
                answer = reader.readline()
                if not answer:
                    raise RuntimeError("No domain was supplied; operation cancelled.")
                try:
                    return normalize_domain(answer)
                except ValueError as exc:
                    writer.write(f"{exc}\n")
                    writer.flush()
    except OSError as exc:
        raise RuntimeError(
            "No interactive terminal is available. Use --domain okta.com instead."
        ) from exc


# ------------------------------------------------------------------------------
# Chrome shutdown and collision-safe profile backup
# ------------------------------------------------------------------------------


def create_profile_backup() -> Path:
    """Quit Chrome and copy Default into a fresh, private Desktop directory.

    Existing backups are never merged or overwritten. A numeric suffix resolves
    timestamp collisions. A failed copy may leave a partial backup for inspection.
    No force-kill is used if Chrome refuses or takes too long to quit.
    """
    if sys.platform != "darwin":
        raise RuntimeError("Automatic profile backup is supported on macOS only.")

    profile = Path.home() / PROFILE_RELATIVE_PATH
    desktop = Path.home() / "Desktop"
    if not profile.is_dir():
        raise RuntimeError(f"Chrome's Default profile directory was not found: {profile}")
    if not desktop.is_dir():
        raise RuntimeError(f"Desktop directory was not found: {desktop}")

    print(
        f"[1/4] Closing Google Chrome and waiting {CHROME_QUIT_DELAY_SECONDS} seconds...",
        flush=True,
    )
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", 'tell application "Google Chrome" to quit'],
        stdout=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("Could not close Chrome. Quit it manually and try again.")
    time.sleep(CHROME_QUIT_DELAY_SECONDS)

    # pgrep returns 0 for a match and 1 when no matching process exists.
    result = subprocess.run(
        ["/usr/bin/pgrep", "-x", "Google Chrome"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode == 0:
        raise RuntimeError(
            "Chrome is still running. Quit it completely and try again; no backup was made."
        )
    if result.returncode != 1:
        raise RuntimeError("Could not verify that Chrome stopped; no backup was made.")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base_name = f"{BACKUP_PREFIX}-{stamp}"
    suffix = 0
    while True:
        backup = desktop / (base_name if suffix == 0 else f"{base_name}-{suffix}")
        try:
            backup.mkdir(mode=0o700)
            break
        except FileExistsError:
            suffix += 1

    print(f"[2/4] Backing up the Default profile to: {backup}", flush=True)
    try:
        result = subprocess.run(
            ["/usr/bin/ditto", str(profile), str(backup)],
            stdout=subprocess.DEVNULL,
            check=False,
        )
    finally:
        # ditto can preserve source permissions; keep the backup root private.
        backup.chmod(0o700)
    if result.returncode != 0:
        raise RuntimeError(f"Backup failed. A partial backup may remain at: {backup}")

    print(f"Backup completed: {backup}", flush=True)
    return backup


# ------------------------------------------------------------------------------
# Read-only SQLite extraction from the new backup
# ------------------------------------------------------------------------------


def query_profile_cookies(backup: Path, domain: str) -> list[CookieFields]:
    """Load cookies for the exact domain and its subdomains from a backup.

    Both profile database layouts are supported: Cookies and Network/Cookies.
    Domain values use bound SQL parameters, not string interpolation. The query
    matches domain-label boundaries, excluding lookalikes such as notokta.com.
    Persistent expiry dates are emitted in UTC; zero expiry remains a session.
    """
    candidates = (backup / "Cookies", backup / "Network" / "Cookies")
    database = next((candidate for candidate in candidates if candidate.is_file()), None)
    if database is None:
        raise RuntimeError(f"No Cookies or Network/Cookies database exists in: {backup}")

    print(f"Reading the backed-up cookie database: {database}", flush=True)
    try:
        # mode=ro prevents changes to the copied cookie database. The live
        # profile is never queried. closing() also closes the connection on error.
        with closing(
            sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
        ) as connection:
            connection.row_factory = sqlite3.Row
            rows = connection.execute(
                """
                SELECT
                    host_key,
                    name,
                    value,
                    hex(encrypted_value) AS encrypted_hex,
                    length(encrypted_value) AS enc_len,
                    path,
                    CASE
                        WHEN expires_utc = 0 THEN '0'
                        ELSE strftime(
                            '%Y-%m-%dT%H:%M:%SZ',
                            expires_utc / 1000000.0 - 11644473600,
                            'unixepoch'
                        )
                    END AS expires,
                    is_secure,
                    is_httponly,
                    samesite
                FROM cookies
                WHERE lower(ltrim(host_key, '.')) = ?
                   OR lower(ltrim(host_key, '.')) LIKE ?
                ORDER BY host_key, name
                """,
                (domain, "%." + domain),
            ).fetchall()
    except sqlite3.Error as exc:
        raise RuntimeError(f"Could not read the backed-up cookie database: {exc}") from exc

    records = []
    for row in rows:
        if row["expires"] is None:
            raise ValueError("A cookie contains an expires_utc value that cannot be converted.")
        fields = {key: "" if row[key] is None else str(row[key]) for key in row.keys()}
        records.append(fields)
    return records


# ------------------------------------------------------------------------------
# Password input, terminal-only display, and AES-CBC v10 decryption
# ------------------------------------------------------------------------------


def prompt_safe_storage_password() -> str:
    """Read an already-known password with echo disabled and no Keychain access.

    Never fall back to visible input or to stdin, which contains this program.
    This avoids a Keychain dialog; it does not grant or change Keychain permissions.
    """
    try:
        with open("/dev/tty", "w", encoding="utf-8") as terminal:
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                password = getpass.getpass(
                    "Enter the existing Chrome Safe Storage password (input hidden): ",
                    stream=terminal,
                )
    except (OSError, EOFError, getpass.GetPassWarning) as exc:
        raise RuntimeError(
            "Hidden password input is unavailable. Run from an interactive terminal; "
            "the script will not fall back to visible input or Keychain access."
        ) from exc
    if not password:
        raise RuntimeError("The supplied Safe Storage password must not be empty.")
    return password


def display_safe_storage_password(password: bytes) -> None:
    """Show a retrieved secret on the controlling terminal, never in output files.

    No stdout/stderr fallback is allowed: redirecting the exporter's normal output
    must not silently write the password into a log. Terminal recording and
    scrollback can still retain the displayed value. Reject unsafe terminal text.
    """
    try:
        text = password.decode("utf-8")
    except UnicodeDecodeError:
        warn_once("password-display-encoding", "Password display skipped: value is not UTF-8.")
        return
    if any(not character.isprintable() for character in text):
        warn_once("password-display-controls", "Password display skipped: value contains unsafe terminal characters.")
        return
    try:
        with open("/dev/tty", "w", encoding="utf-8") as terminal:
            terminal.write(
                "\nSECURITY WARNING: The password below is sensitive and may remain "
                "in terminal scrollback or recordings.\n"
                f"Chrome Safe Storage password: {text}\n"
                "Use --hide-safe-storage-password to suppress this display.\n\n"
            )
            terminal.flush()
    except OSError:
        warn_once(
            "password-display-no-terminal",
            "No writable terminal is available; Safe Storage password display was skipped. "
            "The password was not sent to stdout or stderr.",
        )


class Decryptor:
    """Derive a key once from a supplied password or a single Keychain read.

    A supplied password always takes priority and never falls back to Keychain.
    Manual passwords are not redisplayed. Retrieved Keychain passwords are shown
    once on /dev/tty unless disabled. All passwords are used literally, not
    Base64-decoded; the derived key is cached for the current run only.
    """

    def __init__(
        self, password: Optional[str] = None, prompt_for_password: bool = False,
        show_keychain_password: bool = True,
    ) -> None:
        self.key: Optional[bytes] = None
        self._password = password
        self._prompt_for_password = prompt_for_password
        self._show_keychain_password = show_keychain_password

    def get_key(self) -> bytes:
        """Resolve a password lazily and cache its PBKDF2-derived AES key."""
        if self.key is not None:
            return self.key
        if self._prompt_for_password:
            password = prompt_safe_storage_password().encode("utf-8")
        elif self._password is not None:
            password = self._password.encode("utf-8")
        else:
            password = self.read_keychain_password()
            if self._show_keychain_password:
                display_safe_storage_password(password)

        if not password:
            raise RuntimeError("The supplied Safe Storage password must not be empty.")
        self.key = hashlib.pbkdf2_hmac(
            "sha1", password, PBKDF2_SALT, PBKDF2_ITERATIONS, DERIVED_KEY_BYTES
        )
        self._password = None
        return self.key

    @staticmethod
    def read_keychain_password() -> bytes:
        """Read the local macOS Keychain item without changing its access policy."""
        if sys.platform != "darwin":
            raise RuntimeError("Automatic Chrome Safe Storage access requires macOS.")

        try:
            result = subprocess.run(
                ["/usr/bin/security", "find-generic-password", "-w", "-s", KEYCHAIN_SERVICE],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        except OSError as exc:
            raise RuntimeError("Could not run the macOS security command.") from exc
        if result.returncode != 0:
            raise RuntimeError(
                f"Could not read {KEYCHAIN_SERVICE} from the Keychain "
                f"(exit code {result.returncode}). Confirm that the item exists, "
                "the Keychain is unlocked, and any macOS access request was approved."
            )

        # Remove only the command's trailing line endings, not password spaces.
        password = result.stdout.rstrip(b"\r\n")
        if not password:
            raise RuntimeError("The Keychain returned an empty Safe Storage password.")
        return password

    def decrypt(self, fields: CookieFields) -> str:
        """Return a plaintext value or decrypt one validated v10 payload."""
        hex_value = fields.get("encrypted_hex", "").strip()
        plain_value = fields.get("value", "")
        if not hex_value:
            return plain_value
        if plain_value:
            raise ValueError("Both value and encrypted_hex are populated; choose one source.")
        try:
            encrypted = bytes.fromhex(hex_value)
        except ValueError as exc:
            raise ValueError("encrypted_hex is not valid hexadecimal.") from exc

        if fields.get("enc_len"):
            try:
                declared_length = int(fields["enc_len"])
            except ValueError as exc:
                raise ValueError("enc_len must be an integer.") from exc
            if declared_length != len(encrypted):
                raise ValueError(
                    f"enc_len declares {declared_length} bytes, but {len(encrypted)} were found."
                )
        if not encrypted.startswith(COOKIE_PREFIX):
            raise ValueError("Only v10 encryption is supported; expected hex prefix 763130.")

        ciphertext = encrypted[len(COOKIE_PREFIX):]
        if not ciphertext or len(ciphertext) % AES.block_size:
            raise ValueError("The payload after v10 must contain a multiple of 16 bytes.")
        padded = AES.new(self.get_key(), AES.MODE_CBC, iv=COOKIE_IV).decrypt(ciphertext)
        try:
            decrypted = unpad(padded, AES.block_size)
        except ValueError as exc:
            raise ValueError("Invalid padding; check the Safe Storage item and encrypted data.") from exc

        # Some versions prepend SHA-256(host_key). Remove it only on an exact
        # match; never blindly discard the first 32 bytes of a legacy value.
        domain_hash = hashlib.sha256(fields["host_key"].encode("utf-8")).digest()
        if decrypted.startswith(domain_hash):
            decrypted = decrypted[len(domain_hash):]
        else:
            warn_once(
                "legacy",
                "At least one cookie has no matching domain hash; trying the legacy "
                "format without a domain-hash prefix.",
            )
        try:
            return decrypted.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError(
                "The decrypted value is not UTF-8. Check the Safe Storage item and "
                "the original host_key, including any leading dot."
            ) from exc


# ------------------------------------------------------------------------------
# Cookie validation and Cookie-Editor conversion
# ------------------------------------------------------------------------------


def read_bool(fields: CookieFields, key: str) -> bool:
    """Accept the original SQLite 0/1 representation or explicit true/false."""
    value = fields[key].lower()
    if value in {"1", "true"}:
        return True
    if value in {"0", "false"}:
        return False
    raise ValueError(f"Field {key} must be 0/1 or true/false.")


def expiration_timestamp(text: str, timezone_name: Optional[str]) -> Optional[float]:
    """Convert an ISO expiry to Unix seconds; return None for session cookies."""
    if text.lower() in {"", "0", "none", "null", "session"}:
        return None
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(
            "expires must be an ISO timestamp, such as 2030-11-26T16:15:14Z, "
            "or 0 for a session cookie."
        ) from exc

    if dt.tzinfo is None:
        if timezone_name:
            dt = dt.replace(tzinfo=ZoneInfo(timezone_name))
        else:
            warn_once(
                "local-time",
                "Expiry dates without a timezone are interpreted in the computer's local timezone.",
            )
    timestamp = dt.timestamp()
    if timestamp <= time.time():
        warn_once("expired", "Some cookies have expired and may be deleted immediately after import.")
    return timestamp


def make_cookie(
    fields: CookieFields, decryptor: Decryptor, timezone_name: Optional[str]
) -> dict:
    """Validate one record and build its Cookie-Editor JSON object."""
    missing = sorted(REQUIRED_FIELDS - fields.keys())
    if missing:
        raise ValueError("Missing fields: " + ", ".join(missing))
    if "value" not in fields and "encrypted_hex" not in fields:
        raise ValueError("At least one of value or encrypted_hex is required.")

    domain, name, path = fields["host_key"], fields["name"], fields["path"]
    if not domain or any(c.isspace() or ord(c) == 127 for c in domain) or "/" in domain:
        raise ValueError("host_key must contain a domain only, without https:// or a path.")
    if not name or any(
        c.isspace() or ord(c) < 32 or ord(c) == 127 or c in ";=" for c in name
    ):
        raise ValueError("The cookie name is empty or invalid.")
    if not path.startswith("/") or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise ValueError("path must start with / and contain no control characters.")

    secure = read_bool(fields, "is_secure")
    http_only = read_bool(fields, "is_httponly")
    if name.startswith(("__Secure-", "__Host-")) and not secure:
        raise ValueError("__Secure- and __Host- cookies require is_secure = 1.")
    if name.startswith("__Host-") and (domain.startswith(".") or path != "/"):
        raise ValueError("__Host- cookies require host_key without a leading dot and path = /.")
    if fields["samesite"] not in SAME_SITE_MAP:
        raise ValueError("samesite must be -1, 0, 1, or 2, using Chromium's database values.")
    same_site = SAME_SITE_MAP[fields["samesite"]]
    if same_site == "no_restriction" and not secure:
        warn_once("insecure-none", "SameSite=None without Secure may be rejected by the browser.")

    expires = expiration_timestamp(fields["expires"], timezone_name)
    value = decryptor.decrypt(fields)
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("The cookie value contains control characters; check the domain and key.")
    cookie = {
        "domain": domain,
        "hostOnly": not domain.startswith("."),
        "httpOnly": http_only,
        "name": name,
        "path": path,
        "sameSite": same_site,
        "secure": secure,
        "session": expires is None,
        "value": value,
    }
    if expires is not None:
        cookie["expirationDate"] = expires
    return cookie


# ------------------------------------------------------------------------------
# Private, atomic output files
# ------------------------------------------------------------------------------


def atomic_write(output: Path, write_content: Callable[[TextIO], None]) -> None:
    """Replace an output only after a complete write to a mode-0600 temp file.

    The temporary file lives in the destination directory so os.replace() stays
    on one filesystem. A failed write leaves any previous output unchanged.
    """
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=output.parent,
            prefix=".cookie-export-", delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            write_content(handle)
        os.replace(temporary_path, output)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def write_export(output: Path, cookies: list[dict]) -> None:
    """Write the final Cookie-Editor array without exposing partial JSON."""
    def write_content(handle: TextIO) -> None:
        json.dump(cookies, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    atomic_write(output, write_content)


def write_raw_records(output: Path, records: list[CookieFields]) -> None:
    """Save selected SQLite-style records for inspection or later conversion."""
    def write_content(handle: TextIO) -> None:
        for fields in records:
            for key, value in fields.items():
                handle.write(f"{key} = {value}\n")
            handle.write("\n")

    atomic_write(output, write_content)


# ------------------------------------------------------------------------------
# Command-line interface and workflow orchestration
# ------------------------------------------------------------------------------


def parse_arguments() -> argparse.Namespace:
    """Describe both the default backup workflow and conversion-only mode."""
    parser = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        description=(
            "Macaroon is a macOS-only CLI to back up Chrome's Default profile, "
            "select a domain, and export decrypted "
            "cookies for Cookie-Editor. An optional input file selects conversion-only mode."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  bash macaroon.sh
  bash macaroon.sh --domain okta.com
  bash macaroon.sh --domain okta.com -o ./cookies.json
  bash macaroon.sh abc.txt -o ./cookies.json --timezone UTC
  bash macaroon.sh --domain okta.com --safe-storage-password
  bash macaroon.sh --domain okta.com --safe-storage-password 'YOUR_PASSWORD'
  bash macaroon.sh --domain okta.com --hide-safe-storage-password

Platform: macOS only.
Privacy: the complete profile backup and exported cookies are sensitive.
Retrieved Keychain passwords are shown once on the terminal by default.
Use --hide-safe-storage-password to suppress that display.
Prefer hidden password input over a command-line value, which can be exposed.
Chrome remains closed after the backup workflow finishes.
""",
    )
    parser.add_argument(
        "--version", action="version",
        version=f"Macaroon {SCRIPT_VERSION} (macOS only; backup + domain + Keychain)",
    )
    parser.add_argument(
        "input", nargs="?",
        help="existing text records to convert; skips Chrome shutdown and profile backup",
    )
    parser.add_argument(
        "--domain",
        help="domain to export, including subdomains; otherwise prompt after the backup",
    )
    parser.add_argument(
        "-o", "--output",
        help=(
            "JSON destination; defaults to the new backup's cookie-export/cookie-editor.json, "
            "or ./cookie-editor.json in conversion-only mode"
        ),
    )
    parser.add_argument(
        "--timezone",
        help="timezone for naive text expiry dates, e.g. UTC; database expiry dates use UTC",
    )
    parser.add_argument(
        "--skip-errors", action="store_true",
        help="skip invalid records, export valid ones, and exit with status 2 if any were skipped",
    )
    parser.add_argument(
        "--safe-storage-password", nargs="?", const=PROMPT_FOR_PASSWORD,
        metavar="PASSWORD",
        help=(
            "use an existing password without accessing Keychain; omit PASSWORD for hidden "
            "terminal input (recommended), or supply it directly with shell-history/process-list risk"
        ),
    )
    parser.add_argument(
        "--hide-safe-storage-password", action="store_true",
        help="suppress terminal display of a password retrieved from Keychain",
    )
    args = parser.parse_args()
    if args.input and args.domain is not None:
        parser.error("An existing input file cannot be combined with --domain.")
    if args.safe_storage_password == "":
        parser.error("--safe-storage-password requires a nonempty password; omit its value for hidden input.")
    return args


def prepare_records(args: argparse.Namespace) -> tuple[Iterable[CookieRecord], Path]:
    """Choose existing input or create a fresh backup and domain-filtered records."""
    if args.output and not Path(args.output).expanduser().parent.is_dir():
        raise ValueError("The requested output directory does not exist.")

    if args.input:
        source = Path(args.input).expanduser()
        output = Path(args.output or "cookie-editor.json").expanduser()
        if source.resolve() == output.resolve():
            raise ValueError("Input and output files must be different.")
        return read_records(source), output

    # Validate an explicit domain before taking any action that closes Chrome.
    domain = normalize_domain(args.domain) if args.domain is not None else None
    backup = create_profile_backup()
    print("[3/4] Selecting cookies by domain...", flush=True)
    domain = domain or prompt_domain()
    fields_list = query_profile_cookies(backup, domain)
    if not fields_list:
        raise RuntimeError(
            f"No cookies were found for {domain} or its subdomains in the Default profile. "
            f"No import file was created. Backup kept at: {backup}"
        )

    export_dir = backup / EXPORT_DIRECTORY_NAME
    export_dir.mkdir(mode=0o700)
    source = export_dir / "abc.txt"
    output = Path(args.output).expanduser() if args.output else export_dir / "cookie-editor.json"
    if source.resolve() == output.resolve():
        raise ValueError("Input and output files must be different.")
    write_raw_records(source, fields_list)
    print(f"Matched {len(fields_list)} records for {domain}, including subdomains.")
    print(f"Raw records saved: {source}")
    print("[4/4] Validating and decrypting cookies, then writing the JSON export...", flush=True)

    # Preserve original field values instead of parsing the diagnostic text again.
    records: list[CookieRecord] = []
    line_number = 1
    for fields in fields_list:
        records.append((line_number, fields, []))
        line_number += len(fields) + 1
    return records, output


def convert_records(
    records: Iterable[CookieRecord], output: Path,
    timezone_name: Optional[str], skip_errors: bool,
    safe_storage_password: Optional[str] = None, prompt_for_password: bool = False,
    show_keychain_password: bool = True,
) -> int:
    """Validate/decrypt all records and write one deduplicated JSON export.

    For repeated (domain, path, name) identities, the last valid record wins.
    Keychain failures are fatal rather than silently producing an empty export.
    No JSON output is replaced until every selected record has been processed.
    """
    decryptor = Decryptor(
        password=safe_storage_password, prompt_for_password=prompt_for_password,
        show_keychain_password=show_keychain_password,
    )
    cookies_by_identity: dict[tuple[str, str, str], dict] = {}
    total = failed = duplicates = 0

    for index, (line_number, fields, parse_errors) in enumerate(records, 1):
        total = index
        try:
            if parse_errors:
                raise ValueError(" ".join(parse_errors))
            cookie = make_cookie(fields, decryptor, timezone_name)
        except (ValueError, OverflowError) as exc:
            message = f"Record {index} (starting at line {line_number}): {exc}"
            if not skip_errors:
                raise ValueError(
                    message + " No new JSON export was written. "
                    "Use --skip-errors to skip invalid records."
                ) from exc
            failed += 1
            print(f"SKIPPED: {message}", file=sys.stderr)
            continue

        identity = (cookie["domain"].lower(), cookie["path"], cookie["name"])
        if identity in cookies_by_identity:
            duplicates += 1
            del cookies_by_identity[identity]
        cookies_by_identity[identity] = cookie
        if index % 500 == 0:
            print(f"Processed {index} records...", file=sys.stderr)

    if total == 0:
        raise ValueError("No cookie records were found in the input file.")
    if not cookies_by_identity:
        raise ValueError(f"All {total} records failed. No new JSON export was written.")

    cookies = list(cookies_by_identity.values())
    write_export(output, cookies)
    print(f"\nExport created: {output.resolve()}")
    print(
        f"Records read: {total} | Unique cookies exported: {len(cookies)} | "
        f"Duplicates merged: {duplicates} | Failed: {failed}"
    )
    if duplicates:
        print("For identical domain/name/path combinations, the last valid record was kept.")
    if failed:
        print("WARNING: This is a partial export; skipped-record details are listed above.", file=sys.stderr)
    print("SECURITY: The JSON contains decrypted cookie values. Do not share it.")
    return 2 if failed else 0


def main() -> int:
    """Validate options, prepare records, and run the shared export pipeline."""
    args = parse_arguments()
    password_option = args.safe_storage_password
    prompt_for_password = password_option is PROMPT_FOR_PASSWORD
    supplied_password = None if prompt_for_password else password_option
    if supplied_password is not None:
        warn_once(
            "password-command-line",
            "A password supplied on the command line may appear in shell history and process "
            "listings. Prefer --safe-storage-password without a value for hidden terminal input.",
        )
    if args.timezone:
        try:
            ZoneInfo(args.timezone)
        except ZoneInfoNotFoundError as exc:
            raise ValueError(f"Unknown timezone: {args.timezone}") from exc
    records, output = prepare_records(args)
    return convert_records(
        records, output, args.timezone, args.skip_errors,
        safe_storage_password=supplied_password,
        prompt_for_password=prompt_for_password,
        show_keychain_password=not args.hide_safe_storage_password,
    )


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, EOFError, OverflowError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print(
            "\nOperation cancelled. Existing backups and intermediate files have been kept.",
            file=sys.stderr,
        )
        sys.exit(130)
PYTHON
