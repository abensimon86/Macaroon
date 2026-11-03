# Macaroon

**Chrome cookies. Decrypted. Editor-ready.**

A **macOS-only** command-line tool that backs up Chrome's `Default` profile, extracts domain-filtered cookies from SQLite, decrypts supported values, and exports Cookie-Editor-ready JSON.

Macaroon is a single Bash script with an embedded Python implementation. It runs locally, makes no network requests, and does not install dependencies automatically.

> [!WARNING]
> Use only with profiles and accounts you own or are authorized to access.
>
> The full profile backup and exported cookies contain sensitive data.
>
> **By default, a password retrieved from Chrome Safe Storage is displayed once in the terminal.** Add `--hide-safe-storage-password` to suppress this display.

## Requirements

- **macOS** — the supported platform.
- **Python 3.9 or newer**.
- The **pycryptodome** Python package.
- Google Chrome's **Default** profile in its standard location.
- Access to the matching **Chrome Safe Storage** Keychain item, unless you supply its existing password.
- Enough free space for a copy of the **entire profile**.

The expected profile location is:

```text
~/Library/Application Support/Google/Chrome/Default
```

The backup workflow uses macOS tools: `osascript`, `pgrep`, and `ditto`. Automatic password retrieval uses macOS Keychain.

A separate `sqlite3` command-line installation is not required. SQLite access is handled by Python's standard library.

## Installation

Clone the repository:

```bash
git clone https://github.com/abensimon86/Macaroon.git
cd Macaroon
```

Create and activate a Python virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Install the dependency:

```bash
python -m pip install pycryptodome
```

Alternatively, download `macaroon.sh` from the repository, open its directory in Terminal, and run the same virtual-environment setup commands.

Keep the virtual environment activated when running the examples below. No executable permission change is needed when launching the script with `bash`.

To use an existing interpreter without activating its environment:

```bash
PYTHON_BIN="$PWD/.venv/bin/python3" bash macaroon.sh --help
```

## Quick Start

Run the complete workflow and enter a domain when prompted:

```bash
bash macaroon.sh --hide-safe-storage-password
```

Or provide a domain up front:

```bash
bash macaroon.sh --domain example.com --hide-safe-storage-password
```

The hide flag is recommended when you do not need to see the Safe Storage password. It suppresses password display, **not** any authorization dialog required by macOS.

### What Happens During a Run?

1. Chrome is asked to quit, followed by a three-second wait.
2. Macaroon verifies that Chrome has stopped. If it is still running, the workflow stops without force-killing it or copying the profile.
3. The entire `Default` profile is copied to a new timestamped directory on the Desktop.
4. You choose a domain, unless `--domain` was supplied.
5. Matching cookies are read from the **backup created in this run**, never from the live profile database.
6. If encrypted cookies are encountered, Macaroon uses a supplied password or retrieves Chrome Safe Storage from Keychain once. The derived key is reused for that run.
7. Selected records and a decrypted JSON export are written to the backup's `cookie-export` directory.

> [!IMPORTANT]
> Chrome remains closed. Keep it closed during the backup; the script does not reopen it automatically.
>
> macOS may request permission to control Chrome or access Keychain.

## Domain Filtering

A domain includes both the root domain and its subdomains.

For example, `example.com` matches:

```text
example.com
.example.com
login.example.com
.login.example.com
```

It does not match lookalikes such as:

```text
notexample.com
example.com.other.test
```

The following inputs are also normalized to `example.com`:

```text
.example.com
*.example.com
%.example.com
```

Quote wildcard-containing values in the shell:

```bash
bash macaroon.sh --domain '*.example.com' --hide-safe-storage-password
```

Enter a domain only, without a URL scheme, path, or surrounding quotes in the interactive prompt.

SQL parameters are bound separately from the query rather than interpolated into it.

## Password Handling

### Retrieve the Password from Keychain

Without a password flag, Macaroon reads the local `Chrome Safe Storage` item when it first needs to decrypt a cookie. macOS may ask you to authorize access.

```bash
bash macaroon.sh --domain example.com
```

After a successful Keychain read, the password is displayed once directly on `/dev/tty`.

It is not sent to stdout or stderr and is not written to a separate password file. However, terminal scrollback, screen sharing, or terminal recording can still expose it.

If there is no writable terminal, display is skipped.

To suppress the display:

```bash
bash macaroon.sh --domain example.com --hide-safe-storage-password
```

### Supply an Existing Password with Hidden Input

If you already know the matching Safe Storage password, use the flag without a value:

```bash
bash macaroon.sh --domain example.com --safe-storage-password
```

You will be prompted in the terminal with input hidden.

**Keychain is not accessed**, and no Keychain authorization dialog is requested by this password path. The script may still trigger other macOS permissions for the backup workflow.

Keep this optional-value flag last, as shown above, or follow it with another option. Otherwise, the next positional argument will be interpreted as its password value.

### Supply the Password Directly

```bash
bash macaroon.sh --domain example.com --safe-storage-password 'YOUR_PASSWORD'
```

Replace the placeholder with the actual password.

> [!CAUTION]
> This form is supported but not recommended. Command-line values may appear in shell history or process listings. Prefer hidden input.

Supplied passwords are used literally, even if they resemble Base64. They are not redisplayed.

A failed supplied password does not trigger a fallback to Keychain.

If all selected cookies are plaintext, no password is requested or retrieved.

## Output Files

By default, each successful backup workflow produces:

```text
~/Desktop/Chrome-Default-profile-YYYYMMDD-HHMMSS/
├── ...                         # Complete copied Default profile
└── cookie-export/
    ├── abc.txt                 # Selected SQLite-style records
    └── cookie-editor.json      # Decrypted Cookie-Editor JSON array
```

If a backup name already exists, a numeric suffix is added instead of merging or overwriting the old backup.

### Raw Records

`abc.txt` contains the selected database records. It can include plaintext cookie values as well as encrypted hexadecimal values.

### Cookie-Editor Export

`cookie-editor.json` contains the final plaintext values and supported cookie attributes in a JSON array intended for Cookie-Editor import.

**Both files are sensitive.**

### File Permissions

- Backup and export directory roots use owner-only permissions: `0700`.
- Generated record and JSON files use owner-only permissions: `0600`.
- Output files are written through temporary files and atomically replaced after a complete write.

These permissions do not encrypt the files.

### Custom JSON Destination

Choose a different JSON destination with `-o`:

```bash
bash macaroon.sh --domain example.com \
  --hide-safe-storage-password \
  -o ./cookies.json
```

The destination directory must already exist.

The raw record file stays inside the new backup.

An existing custom JSON destination is replaced after a successful export. If conversion fails before that, its previous contents remain unchanged.

## Convert an Existing Record File

Supplying a positional text file selects **conversion-only mode**.

Chrome is not closed, and no new profile backup is created.

```bash
bash macaroon.sh abc.txt -o ./cookie-editor.json \
  --timezone UTC \
  --hide-safe-storage-password
```

In this mode:

- The default JSON destination is `./cookie-editor.json`.
- Input and output must be different files.
- A text input file cannot be combined with `--domain`.

### Input Format

The input uses `key = value` fields.

Each repeated `host_key` starts another cookie record. Blank separators are optional.

This synthetic plaintext record can be converted without a password:

```text
host_key = example.com
name = demo
value = synthetic-example-value
path = /
expires = 0
is_secure = 1
is_httponly = 1
samesite = 1
```

For encrypted records, use `encrypted_hex` instead of a populated `value`. The optional `enc_len` field may declare the encrypted byte length.

The supported encryption prefix is `v10`, represented as `763130` in hexadecimal.

### Expiry Dates

`--timezone` controls how expiry dates without timezone information are interpreted in text input.

Without it, such dates use the computer's local timezone.

Dates extracted directly from the database already include UTC. Session cookies use:

```text
expires = 0
```

## Command-Line Options

### `--domain DOMAIN`

Export the domain and its subdomains. If omitted in the backup workflow, Macaroon prompts after creating the backup.

### `-o FILE` / `--output FILE`

Choose the JSON destination.

### `--safe-storage-password [PASSWORD]`

Use a known password without accessing Keychain.

Omit the value for hidden terminal input, or supply it directly with the command-line exposure risks described above.

### `--hide-safe-storage-password`

Suppress terminal display of a password retrieved from Keychain.

### `--timezone ZONE`

Interpret naive text expiry dates in a named timezone, such as `UTC` or `Asia/Jerusalem`.

### `--skip-errors`

Skip invalid records and export valid ones.

Returns exit code `2` if any records were skipped and a partial export was created.

### `--help`

Show usage and examples.

```bash
bash macaroon.sh --help
```

### `--version`

Show the tool version and supported platform.

```bash
bash macaroon.sh --version
```

Without `--skip-errors`, a failed record prevents a new JSON export.

Keychain access and hidden-password input failures remain fatal. No JSON export is produced if every record fails.

A full backup or intermediate record file may remain after an error or interruption.

## Compatibility and Limitations

- **macOS is the supported platform.** Windows and Linux browser workflows are not supported.
- The backup workflow is fixed to Chrome's **Default profile**. It does not automatically select other profiles, Chrome Beta/Canary, or other Chromium browsers.
- Check `chrome://version` in the intended profile and inspect **Profile Path** before using the tool.
- Both `Cookies` and `Network/Cookies` database locations are recognized inside the new backup.
- Only **AES-CBC `v10`** encrypted values are supported. A Chrome version number alone does not guarantee compatibility; other encryption formats are rejected.
- The matching Safe Storage password is required. A profile copied from another Mac may not match the item in the current Mac's Keychain.
- The JSON preserves supported attributes, including domain, path, Secure, HttpOnly, SameSite, and session/expiry information. It is not a complete browser-profile or session migration format.
- Cookies sharing the same domain, path, and name are deduplicated; the last valid record wins.
- Partition-related metadata is not exported.
- Expired cookies are reported but not automatically excluded.
- Imported cookies may be rejected or may no longer represent a valid session.

## Troubleshooting

### `pycryptodome` Is Missing

Activate the virtual environment used during installation, then run:

```bash
python -m pip install pycryptodome
```

If using `PYTHON_BIN`, install the package with that same interpreter.

### Chrome Is Still Running

Quit Chrome completely, resolve any pending browser dialogs, and run again.

Macaroon does not force-kill the browser.

### The Default Profile or Cookie Database Was Not Found

Check **Profile Path** in `chrome://version`.

The current workflow only copies the standard `Default` directory. Do not assume the visible profile name matches its directory name.

### Keychain Access Failed

Confirm that:

- The matching `Chrome Safe Storage` item exists.
- The Keychain is unlocked.
- Any required macOS access request was approved.

Suppressing password display does not suppress authentication requirements.

### Invalid Padding or Unsupported Encryption

Check that the password belongs to the source profile's Safe Storage item and that the cookie payload uses the supported `v10` format.

Do not Base64-decode the password.

### No Matching Cookies Were Found

Check the domain and profile.

The backup is retained, but no import JSON is created for an empty result.

### No Interactive Terminal Is Available

Use `--domain` to avoid the domain prompt.

Hidden password input requires an interactive terminal; it will not fall back to visible input.

Password display is skipped if no writable terminal is available.

## Exit Codes

- `0` — successful export.
- `1` — runtime, validation, backup, or decryption failure.
- `2` — a partial export with skipped records, or invalid command-line arguments.
- `130` — interrupted by the user; existing backups and intermediate files are kept.

## Security and Responsible Use

Cookie values can grant access to authenticated accounts.

Keep backups and exports private, and follow your organization's policies when working with managed devices or work accounts.

**Never commit any of the following to this repository:**

- Chrome Safe Storage passwords.
- Exported cookies.
- Cookie databases.
- Terminal captures containing secrets.
- Full Chrome profile backups.

Use synthetic values in examples and issue reports. Review files before uploading them; custom output filenames may not be covered by ignore rules.

Macaroon does not modify Keychain access policies or bypass macOS authorization.

The script makes no network requests. Cloning this repository and installing dependencies are separate setup operations that require network access.

JSON exports are not encrypted, and backups are not removed automatically. Retain them only as long as needed and handle them as credentials.
