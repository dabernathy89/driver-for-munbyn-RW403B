#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate private, build-time printer configuration using only the stdlib."""
import argparse
import json
import os
from pathlib import Path
import re
import uuid


def validate(settings):
    if set(settings) != {"uid", "uuid", "mac"}:
        raise ValueError("Configuration must contain uid, uuid, and mac")
    uid = settings["uid"]
    if type(uid) is not int or not 0 < uid < 2**31:
        raise ValueError("Use a non-root login user ID")
    identifier = str(uuid.UUID(settings["uuid"])).upper()
    mac = settings["mac"].upper()
    if not re.fullmatch(r"[0-9A-F]{2}(?::[0-9A-F]{2}){5}", mac):
        raise ValueError("MAC address must contain six colon-separated hex pairs")
    return {"uid": uid, "uuid": identifier, "mac": mac}


def uri(settings):
    return f'rw403bble://{settings["uuid"]}?mac={settings["mac"]}'


def header(settings):
    return (
        "// Generated private configuration. Do not publish.\n"
        f'#define RW_USER_ID {settings["uid"]}\n'
        f'#define RW_UUID "{settings["uuid"]}"\n'
        f'#define RW_MAC "{settings["mac"]}"\n'
        f'#define RW_URI "{uri(settings)}"\n'
        f'#define RW_SOCKET_PATH "/private/tmp/rw403b-{settings["uid"]}/print.sock"\n'
    )


def load(directory):
    settings = validate(json.loads((directory / "settings.json").read_text()))
    if (directory / "Config.h").read_text() != header(settings):
        raise ValueError("Configuration files disagree; run configure.py again")
    return settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent / ".local")
    parser.add_argument("--uuid", help="CoreBluetooth UUID shown by discover.sh")
    parser.add_argument("--mac", help="MAC address on the printer's self-test label")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="Validate existing configuration")
    group.add_argument("--get", choices=("uid", "uuid", "mac", "uri"))
    args = parser.parse_args()
    try:
        if args.check or args.get:
            if args.uuid or args.mac:
                parser.error("Do not combine reading and writing configuration")
            settings = load(args.directory)
            if args.get:
                print(uri(settings) if args.get == "uri" else settings[args.get])
            return
        if not args.uuid or not args.mac:
            parser.error("Both --uuid and --mac are required")
        settings = validate({"uid": os.getuid(), "uuid": args.uuid, "mac": args.mac})
        os.umask(0o077)
        args.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if args.directory.is_symlink() or args.directory.stat().st_uid != os.getuid():
            raise ValueError("Configuration directory must belong to the current user and not be a symlink")
        args.directory.chmod(0o700)
        for name, text in (("settings.json", json.dumps(settings, indent=2) + "\n"),
                           ("Config.h", header(settings))):
            path = args.directory / name
            temporary = args.directory / (name + ".new")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as output:
                output.write(text)
            temporary.replace(path)
        print("Saved local configuration. Run sh build.sh next.")
    except (OSError, ValueError, TypeError, AttributeError) as error:
        parser.exit(1, f"Configuration error: {error}\n")


if __name__ == "__main__":
    main()
