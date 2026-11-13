"""Fix esp_tinyusb 3.0.0's reversed GetObjectHandles/GetNumObjects scope.

After Component Manager downloads (or replaces) managed_components, run:
    python tools/patch_esp_tinyusb_mtp.py
    idf.py build

GetObjectHandles/GetNumObjects parent 0 means all objects; 0xFFFFFFFF means
only the storage root. The upstream dispatcher reverses these scopes, causing
nested files to appear in root listings. Folder handles keep their normal scope.

This patch is idempotent and refuses unfamiliar source instead of guessing.
It preserves line endings and does not alter Component Manager checksums.
"""

import argparse
from pathlib import Path
import sys


DEFAULT_COMPONENT = (Path(__file__).resolve().parents[1] / "managed_components" /
                     "espressif__esp_tinyusb")
OLD = b"""    return parent == MTP_ROOT_PARENT ? mtp_scan_tree_locked(storage, object_format, handles, max_handles, count) :
           mtp_scan_children_locked(storage, parent, object_format, handles, max_handles, count);"""
NEW = b"""    // Enumeration parent 0 selects all objects; 0xFFFFFFFF selects root children.
    return parent == MTP_OBJECT_HANDLE_INVALID ? mtp_scan_tree_locked(storage, object_format, handles, max_handles, count) :
           mtp_scan_children_locked(storage, parent, object_format, handles, max_handles, count);"""


def patch(component):
    source = component / "mtp" / "tinyusb_mtp_operations.c"
    data = source.read_bytes()
    newline = b"\r\n" if b"\r\n" in data else b"\n"
    old = OLD.replace(b"\n", newline)
    new = NEW.replace(b"\n", newline)
    if data.count(new) == 1 and old not in data:
        return False
    if data.count(old) != 1 or new in data:
        raise ValueError(f"Unrecognized MTP dispatcher in {source}; review the library before patching")
    source.write_bytes(data.replace(old, new, 1))
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component-dir", type=Path, default=DEFAULT_COMPONENT,
                        help="esp_tinyusb component directory (defaults to this project's managed copy)")
    args = parser.parse_args()
    try:
        changed = patch(args.component_dir)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Patched esp_tinyusb MTP enumeration." if changed else
          "esp_tinyusb MTP enumeration is already patched.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
