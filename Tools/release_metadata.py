#!/usr/bin/env python3
"""Validate the checked-in release identity before building or accessing keys."""
import argparse
import json
from pathlib import Path
import plistlib
import re


def read_metadata(path, tag=None):
    with Path(path).open("rb") as stream:
        info = plistlib.load(stream)
    version = info.get("CFBundleShortVersionString", "")
    build = info.get("CFBundleVersion", "")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("CFBundleShortVersionString must use MAJOR.MINOR.PATCH")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("CFBundleVersion must be a positive integer")
    if tag is not None and tag != "v" + version:
        raise ValueError(f"Release tag must be v{version}; got {tag!r}")
    return {"version": version, "build": build}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="require an exact match with Info.plist")
    args = parser.parse_args()
    try:
        print(json.dumps(read_metadata(Path(__file__).resolve().parents[1] / "Info.plist", args.tag)))
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Release metadata: {error}\n")


if __name__ == "__main__":
    main()
