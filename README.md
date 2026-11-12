# MUNBYN RW403B Bluetooth driver for macOS

Open-source CUPS backend and Bluetooth helper for printing to a MUNBYN RW403B from the normal macOS Print dialog. It sends a compressed bitmap protocol over Bluetooth LE; it does not require MUNBYN’s proprietary driver.

**Status:** experimental, physically verified on one RW403B-N. Complete 4 × 6-inch and 2 × 1-inch PDFs printed and their QR codes scanned correctly. Removing trailing white raster rows eliminated an extra blank label. Compatibility with other firmware revisions is not established.

Original project code is **MIT licensed**. The bundled [Heatshrink](https://github.com/atomicobject/heatshrink) codec retains its **ISC license**. No MUNBYN code or binaries are distributed.

## Requirements

- macOS with Apple's CUPS/PPD driver support and Bluetooth LE.
- Xcode Command Line Tools (`xcode-select --install`) and Python 3 for setup and testing.
- A powered-on RW403B with gap labels loaded, and its Bluetooth MAC address.
- One logged-in user running the helper. This version configures one printer and one login account per Mac.

The native programs use system frameworks and CUPS. Python and third-party packages are not required for printing after installation. Builds target macOS 13 or later, but older macOS versions and Intel hardware have not been physically tested. macOS warns that PPD printer drivers are deprecated; future CUPS/macOS versions may require changes.

## Find and configure the printer

Run the following from a local checkout, as your normal login user. Do not build or configure with `sudo`.

```sh
sh discover.sh
```

This builds and opens **RW403B Discovery**, which scans advertisements for 30 seconds. Allow Bluetooth permission when prompted. Copy the UUID shown for your printer, then close the discovery window. It does not connect to the printer or send a print job. If the printer is absent, disconnect other phone/tablet printing apps and check that it is powered on. Discovery displays nearby RW403B names and identifiers locally; it does not upload them.

Obtain the printer's **MAC address** from its built-in self-test label. On the tested RW403B, two quick Feed-button taps print that label; do not hold the button. The CoreBluetooth UUID is assigned by macOS and is different from the MAC address.

Replace both placeholders with your printer's values:

```sh
python3 configure.py --uuid 'YOUR-COREBLUETOOTH-UUID' --mac 'YOUR-PRINTER-MAC'
sh test.sh
sh build.sh
sh make-manifest.sh
```

Configuration is saved under `.local/`, with private file permissions. The login user ID is detected automatically. Build-time copies are kept under `build/config/`; both directories are ignored by Git. The backend and helper embed these values, so **do not publish your configured binaries or configuration files**. Changing the printer or login account requires rebuilding and reinstalling both components.

`test.sh` uses temporary synthetic configuration and never contacts Bluetooth, prints, installs, or overwrites your configured build. It tests configuration validation, packet framing, Heatshrink round trips, raster polarity, media/copy limits, trailing-white trimming, and malformed/truncated input. It also compiles the discovery app. The portable setup scripts and discovery UI are new; they have build/offline validation, not a separate physical installation test.

## Install

Review the shell scripts, then run:

```sh
sh install-user.sh
sudo /bin/sh install.sh
```

Allow Bluetooth access for **RW403B Bluetooth** when prompted. The helper runs in the background without a menu-bar item, Dock icon, or window. The installer creates the CUPS queue `Munbyn_RW403B_BLE`, displayed as **MUNBYN RW403B Bluetooth**. It does not print a test job, change the default printer, or enable printer sharing.

The user installer opens the helper at login through a LaunchAgent. The launcher exits after opening the app; there is no KeepAlive daemon. The system installer checks the locally generated build manifest and refuses existing installation paths or a conflicting queue. These checks detect stale or accidentally changed build files; they are not an independent signature or security audit. Apps are locally ad-hoc signed, not notarized; rebuilding may prompt for Bluetooth permission again.

## Print and verify

1. Keep **RW403B Bluetooth** running. Reopen `~/Applications/RW403B Bluetooth.app` if it was quit.
2. Select **MUNBYN RW403B Bluetooth** in an application's Print dialog.
3. Select **2 x 1 inches**, **4 x 6 inches**, or **100 x 150 mm** to match the loaded stock. Width runs across the printhead; height runs along the feed direction.
4. Use actual size / 100% scaling for a PDF already sized to the label.
5. Check the physical result. A submitted job, accepted Bluetooth packets, and a correct printed label are separate outcomes.

Custom paper sizes are enabled for widths of **40-104 mm** and feed lengths of **25.4-200 mm**. Enter the actual adhesive-label dimensions, excluding the gap, and use zero non-printable margins in the macOS custom-paper dialog. The image itself should retain normal content margins. A 2 x 1-inch page is 144 x 72 points and renders at 406 x 203 dots; it does not require rotating the paper to portrait.

Versions before 0.3.0 declared fixed paper sizes and accepted only large-label rasters. A custom size selected in macOS could still arrive as the default 4 x 6 raster. Update both the helper and paper definitions, then close and reopen existing Print dialogs to refresh cached capabilities.

An optional test PDF includes a border, QR code, Code 128 barcode, bottom marker, and a two-inch measuring line. Generating it needs ReportLab in a local virtual environment:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install reportlab
.venv/bin/python tests/make-label.py build/test-label.pdf
open build/test-label.pdf
```

Print one copy on 4 × 6 stock. Confirm all four border edges and **BOTTOM** are visible, the QR code reads `RW403B-BLUETOOTH-4X6`, the marked line measures two inches, and no additional blank label is ejected. Multi-page/copy jobs, sleep/wake, cancellation during transmission, and printing at the extreme bottom edge still need physical testing. Use ordinary label margins.

For the smaller acceptance label:

```sh
.venv/bin/python tests/make-2x1-label.py build/test-2x1.pdf
open build/test-2x1.pdf
```

Print it at actual size with **2 x 1 inches** selected. Check the full border and **BOTTOM**, exactly one label, and a QR scan of `RW403B-2X1`. The preset and equivalent custom size are covered by offline CUPS raster checks. A job submitted through CUPS using the custom 2 x 1-inch size physically printed its complete border and bottom marker, its QR scan matched, and no extra blank label fed out. Other custom sizes have not been physically verified.

## Architecture

```text
Application Print dialog
  -> macOS CUPS and built-in PDF-to-raster conversion
  -> native CUPS client
  -> private Unix socket
  -> logged-in user's native Bluetooth helper
  -> selected RW403B over Bluetooth LE
```

The helper validates the entire raster before contacting Bluetooth, checks the printer's identity and idle status, sends paced packets, and waits for section acknowledgements and a completion report. It returns a result to CUPS through the socket. The socket directory is `/private/tmp/rw403b-<uid>/` with mode 0700; the socket is 0600. Both endpoints verify peer identity. No TCP port or LAN service is opened.

The user-session helper was necessary in the tested environment: macOS denied direct CUPS processes Bluetooth permission. Apple's built-in HCRP backend completed a job without producing a print. A binary identity query worked over RFCOMM in a user session, but direct CUPS/RFCOMM printing was not established. This project never opens a Bluetooth serial device file.

At 203 dpi, a 4 × 6-inch raster is 812 × 1218 dots. The BLE protocol uses whole-byte rows and whole-mm widths at eight dots/mm, so the helper pads four white pixels at the right, without stretching content. It removes only trailing white rows, preserving all ink and its top origin.

## Installed components

| Location | Purpose |
| --- | --- |
| `/usr/libexec/cups/backend/rw403bble` | Root-owned CUPS client, mode 0700 |
| `/Library/Printers/PPDs/Contents/Resources/RW403BOpenSource.ppd` | Label sizes and raster settings |
| `/Library/Printers/RW403BOpenSource/LICENSES.txt` | MIT and ISC notices |
| `/Library/Printers/RW403BOpenSource/device-uri` | Private installation identity used during updates/removal |
| `~/Applications/RW403B Bluetooth.app` | Native background helper |
| `~/Library/LaunchAgents/org.local.rw403bbridge.plist` | Opens the helper at login |
| `~/Library/Logs/RW403B/bridge.log` and `.previous` | Local diagnostics |
| `/private/tmp/rw403b-<uid>/print.sock` | Private socket, recreated at helper startup |

CUPS also stores the queue configuration and PPD. macOS manages the helper's Bluetooth permission. Discovery remains in the checkout's ignored `build/` directory and is not installed as a login item.

## Update or remove

First review or cancel unfinished jobs in this queue. For a source update with the same printer and account:

```sh
sh test.sh
sh build.sh
sh make-manifest.sh
sh uninstall-user.sh
sh install-user.sh
sudo /bin/sh update-backend.sh
sudo /bin/sh update-paper.sh
```

The paper update refreshes the existing queue without changing its device URI or enabling sharing. If the printer or account changes, remove the installed system and user components before reconfiguring, rebuilding, and installing. Do not print while only one component has been updated.

To remove:

```sh
sh uninstall-user.sh
sudo /bin/sh uninstall.sh
```

These scripts remove the listed RW403B components and queue. Other printers and defaults are preserved. Delete the checkout separately if no longer needed. Bluetooth permission entries are managed in System Settings.

## Errors and cancellation

Open the local diagnostic log with `open "$HOME/Library/Logs/RW403B/bridge.log"`. A successful startup records **Ready**.

To check whether the helper is running, use `pgrep -u "$(id -u)" -x rw403bbridge` or search for `rw403bbridge` in Activity Monitor. To stop it, first finish or cancel queued jobs, then quit that process in Activity Monitor; reopen the app to start it again.

Check Bluetooth permission, label stock, cover position, printer power, and other printing apps. Review logs for identifying data before sharing them.

Failures after possible transmission are held for review, without automatic retry. Check the physical printer before resubmitting: a partial label may have printed or data may remain buffered. Canceling through Print Center signals the helper, but cannot retract bytes already transmitted. No factory reset, calibration, speed, density, or paper-setting commands are sent automatically.

The helper may release a lingering classic Bluetooth connection to the selected printer before BLE discovery. It does not toggle global Bluetooth or disconnect other devices.

## Protocol and licensing

See [PROTOCOL.md](PROTOCOL.md) for wire format, observations, and source references. The implementation was written from static protocol inspection and physical testing. Vendor source and proprietary filters are not included.

- [MIT license](LICENSE) for original project code.
- [Heatshrink ISC license](vendor/heatshrink/LICENSE), retained verbatim. Vendored source matches upstream commit `7d419e1fa4830d0b919b9b6a91fe2fb786cf3280`.
- [Combined installation notices](LICENSES.txt).
- [CUPS backend interface](https://www.cups.org/doc/man-backend.html).
- [Apple CUPS sandbox implementation](https://github.com/apple/cups/blob/master/scheduler/process.c).
