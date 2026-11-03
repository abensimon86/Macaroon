Macaroon

Chrome cookies. Decrypted. Editor-ready.

A macOS-only command-line tool that backs up Chrome's Default profile, extracts domain-filtered cookies from SQLite, decrypts supported values, and exports Cookie-Editor-ready JSON.

Macaroon is a single Bash script with an embedded Python implementation. It runs locally, makes no network requests, and does not install dependencies automatically.


[!WARNING]
Use only with profiles and accounts you own or are authorized to access. The full profile backup and exported cookies contain sensitive data. By default, a password retrieved from Chrome Safe Storage is displayed once in the terminal. Add --hide-safe-storage-password to suppress this display.

Requirements

•
macOS — the supported platform. The backup workflow uses osascript, pgrep, and ditto; automatic password retrieval uses macOS Keychain.

•
Python 3.9 or newer, with the pycryptodome package installed.

•
Google Chrome's Default profile at its standard location:

Plain Text


~/Library/Application Support/Google/Chrome/Default





•
Access to the matching Chrome Safe Storage Keychain item, unless you supply its existing password yourself.

•
Enough free space on the Desktop volume for a copy of the entire profile.

A separate sqlite3 command-line installation is not required. SQLite access is handled by Python's standard library.

Installation

Clone the repository and install the Python dependency in a virtual environment:

Bash


git clone https://github.com/abensimon86/Macaroon.git
cd Macaroon

python3 -m venv .venv
source .venv/bin/activate
python -m pip install pycryptodome



Alternatively, download macaroon.sh from the repository, open its directory in Terminal, and run the same virtual-environment setup commands.

Keep the virtual environment activated when running the examples below. No executable permission change is needed when launching the script with bash.

To use an existing interpreter without activating its environment:

Bash


PYTHON_BIN="$PWD/.venv/bin/python3" bash macaroon.sh --help



Quick start

Run the complete workflow and enter a domain when prompted:

Bash


bash macaroon.sh --hide-safe-storage-password



Or provide a domain up front:

Bash


bash macaroon.sh --domain example.com --hide-safe-storage-password



The hide flag is recommended when you do not need to see the Safe Storage password. It suppresses password display, not any authorization dialog required by macOS.

What happens during a run?

1.
Chrome is asked to quit, followed by a three-second wait.

2.
Macaroon verifies that Chrome has stopped. If it is still running, the workflow stops without force-killing it or copying the profile.

3.
The entire Default profile is copied to a new timestamped directory on the Desktop.

4.
You choose a domain, unless --domain was supplied.

5.
Matching cookies are read from the backup created in this run, never from the live profile database.

6.
If encrypted cookies are encountered, Macaroon uses a supplied password or retrieves Chrome Safe Storage from Keychain once. The derived key is reused for that run.

7.
Selected records and a decrypted JSON export are written to the backup's cookie-export directory.

Chrome remains closed. Keep it closed during the backup; the script does not reopen it automatically. macOS may request permission to control Chrome or access Keychain.

Domain filtering

A domain includes both the root domain and its subdomains. For example, example.com matches:

Plain Text


example.com
.example.com
login.example.com
.login.example.com



It does not match lookalikes such as notexample.com or example.com.other.test.

The inputs .example.com, *.example.com, and %.example.com are also normalized to example.com. Quote wildcard-containing values in the shell:

Bash


bash macaroon.sh --domain '*.example.com' --hide-safe-storage-password



Enter a domain only, without a URL scheme, path, or surrounding quotes in the interactive prompt. SQL parameters are bound separately from the query rather than interpolated into it.

Password handling

Retrieve the password from Keychain

Without a password flag, Macaroon reads the local Chrome Safe Storage item when it first needs to decrypt a cookie. macOS may ask you to authorize access.

Bash


bash macaroon.sh --domain example.com



After a successful Keychain read, the password is displayed once directly on /dev/tty. It is not sent to stdout or stderr and is not written to a separate password file. However, terminal scrollback, screen sharing, or terminal recording can still expose it. If there is no writable terminal, display is skipped.

To suppress the display:

Bash


bash macaroon.sh --domain example.com --hide-safe-storage-password



Supply an existing password with hidden input

If you already know the matching Safe Storage password, use the flag without a value:

Bash


bash macaroon.sh --domain example.com --safe-storage-password



You will be prompted in the terminal with input hidden. Keychain is not accessed, and no Keychain authorization dialog is requested by this password path. The script may still trigger other macOS permissions for the backup workflow.

Keep this optional-value flag last, as shown above, or follow it with another option. Otherwise, the next positional argument will be interpreted as its password value.

Supply the password directly

Bash


bash macaroon.sh --domain example.com --safe-storage-password 'YOUR_PASSWORD'



Replace the placeholder with the actual password. This form is supported but not recommended: command-line values may appear in shell history or process listings. Prefer hidden input.

Supplied passwords are used literally, even if they resemble Base64. They are not redisplayed. A failed supplied password does not trigger a fallback to Keychain. If all selected cookies are plaintext, no password is requested or retrieved.

Output files

By default, each successful backup workflow produces:

Plain Text


~/Desktop/Chrome-Default-profile-YYYYMMDD-HHMMSS/
├── ...                         # Complete copied Default profile
└── cookie-export/
    ├── abc.txt                 # Selected SQLite-style records
    └── cookie-editor.json      # Decrypted Cookie-Editor JSON array



If a backup name already exists, a numeric suffix is added instead of merging or overwriting the old backup.

abc.txt can contain plaintext cookie values as well as encrypted hexadecimal values. cookie-editor.json contains the final plaintext values and supported cookie attributes. Both files are sensitive.

Backup/export directory roots are restricted to the current user (0700), and generated record/JSON files use owner-only permissions (0600). Output files are written through temporary files and atomically replaced after a complete write. These permissions do not encrypt the files.

Choose a different JSON destination with -o:

Bash


bash macaroon.sh --domain example.com \
  --hide-safe-storage-password \
  -o ./cookies.json



The destination directory must already exist. The raw record file stays inside the new backup. An existing custom JSON destination is replaced after a successful export; if conversion fails before that, its previous contents remain unchanged.

Convert an existing record file

Supplying a positional text file selects conversion-only mode. Chrome is not closed and no new profile backup is created.

Bash


bash macaroon.sh abc.txt -o ./cookie-editor.json \
  --timezone UTC \
  --hide-safe-storage-password



In this mode, the default JSON destination is ./cookie-editor.json. The input and output must be different files. A text input file cannot be combined with --domain.

The input format uses key = value fields. Each repeated host_key starts another cookie record; blank separators are optional. For example, this synthetic plaintext record can be converted without a password:

Plain Text


host_key = example.com
name = demo
value = synthetic-example-value
path = /
expires = 0
is_secure = 1
is_httponly = 1
samesite = 1



For encrypted records, use encrypted_hex instead of a populated value; enc_len may declare the encrypted byte length. The supported encryption prefix is v10, represented as 763130 in hexadecimal.

--timezone controls how expiry dates without timezone information are interpreted in text input. Without it, such dates use the computer's local timezone. Dates extracted directly from the database already include UTC. Session cookies use expires = 0.

Command-line options

•
--domain DOMAIN — export the domain and its subdomains; otherwise prompt after the backup.

•
-o FILE, --output FILE — choose the JSON destination.

•
--safe-storage-password [PASSWORD] — use a known password without accessing Keychain; omit the value for hidden terminal input.

•
--hide-safe-storage-password — suppress terminal display of a password retrieved from Keychain.

•
--timezone ZONE — interpret naive text expiry dates in a named timezone, such as UTC or Asia/Jerusalem.

•
--skip-errors — skip invalid records and export valid ones. Returns exit code 2 if any records were skipped and a partial export was created.

•
--help — show usage and examples.

•
--version — show the tool version and supported platform.

Without --skip-errors, a failed record prevents a new JSON export. Keychain/input failures remain fatal, and no JSON export is produced if every record fails. A full backup or intermediate record file may remain after an error or interruption.

Compatibility and limitations

•
macOS is the supported platform. Windows and Linux browser workflows are not supported.

•
The backup workflow is fixed to Chrome's Default profile. It does not automatically select other profiles, Chrome Beta/Canary, or other Chromium browsers. Check chrome://version in the intended profile and inspect Profile Path before using the tool.

•
Both Cookies and Network/Cookies database locations are recognized inside the new backup.

•
Only AES-CBC v10 encrypted values are supported. A Chrome version number alone does not guarantee compatibility; other encryption formats are rejected.

•
The matching Safe Storage password is required. A profile copied from another Mac may not match the item in the current Mac's Keychain.

•
The exported JSON preserves supported attributes, including domain, path, Secure, HttpOnly, SameSite, and session/expiry information. It is not a complete browser-profile or session migration format.

•
Cookies sharing the same domain, path, and name are deduplicated; the last valid record wins. Partition-related metadata is not exported.

•
Expired cookies are reported but not automatically excluded. Imported cookies may be rejected or may no longer represent a valid session.

Troubleshooting

pycryptodome is missing
Activate the virtual environment used during installation, then run python -m pip install pycryptodome. If using PYTHON_BIN, install the package with that same interpreter.

Chrome is still running
Quit Chrome completely, resolve any pending browser dialogs, and run again. Macaroon does not force-kill the browser.

The Default profile or cookie database was not found
Check Profile Path in chrome://version. The current workflow only copies the standard Default directory. Do not assume the visible profile name matches its directory name.

Keychain access failed
Confirm that the matching Chrome Safe Storage item exists, the Keychain is unlocked, and you approved any required macOS access request. Suppressing password display does not suppress authentication requirements.

Invalid padding or unsupported encryption
Check that the password belongs to the source profile's Safe Storage item and that the cookie payload uses the supported v10 format. Do not Base64-decode the password.

No matching cookies were found
Check the domain and profile. The backup is retained, but no import JSON is created for an empty result.

No interactive terminal is available
Use --domain to avoid the domain prompt. Hidden password input requires an interactive terminal; it will not fall back to visible input. Password display is skipped if no writable terminal is available.

Exit codes

•
0 — successful export.

•
1 — runtime, validation, backup, or decryption failure.

•
2 — a partial export with skipped records, or invalid command-line arguments.

•
130 — interrupted by the user; existing backups and intermediate files are kept.

Security and responsible use

Cookie values can grant access to authenticated accounts. Keep backups and exports private, and follow your organization's policies when working with managed devices or work accounts.

Never commit Safe Storage passwords, exported cookies, cookie databases, terminal captures containing secrets, or full Chrome profile backups to this repository. Use synthetic values in examples and issue reports. Review files before uploading them; custom output filenames may not be covered by ignore rules.

Macaroon does not modify Keychain access policies or bypass macOS authorization. The script makes no network requests; cloning this repository and installing dependencies are separate setup operations that require network access. JSON exports are not encrypted, and backups are not removed automatically. Retain them only as long as needed and handle them as credentials.

