#!/usr/bin/env python3
"""Collect files for clean MoonBit package publish."""

import shutil
import json
from pathlib import Path

ROOT = Path(__file__).parent.parent
PUBLISH = ROOT / "publish"

# Packages to include (with their source .mbt files)
PACKAGES = {
    "punycode": ["punycode.mbt"],
    "normalization": ["normalization.mbt", "decomposition.mbt", "composition.mbt",
                      "canonical_order.mbt", "hangul.mbt"],
    "idna": ["idna.mbt", "processing.mbt", "validation.mbt"],
    "internal/ucd": ["ccc.mbt", "decomposition.mbt", "composition.mbt",
                     "case_mapping.mbt", "general_category.mbt"],
    "internal/idna": ["mapping.mbt", "bidi.mbt", "joining.mbt"],
}


def clean_pkg_json(pkg_json: dict) -> dict:
    """Remove test-import from moon.pkg.json."""
    return {k: v for k, v in pkg_json.items() if k != "test-import"}


def main():
    # 1. Remove existing publish/ folder
    if PUBLISH.exists():
        shutil.rmtree(PUBLISH)
    PUBLISH.mkdir()

    # 2. Copy root files
    shutil.copy(ROOT / "moon.mod.json", PUBLISH / "moon.mod.json")
    shutil.copy(ROOT / "LICENSE", PUBLISH / "LICENSE")

    # 3. Copy packages
    for pkg_path, mbt_files in PACKAGES.items():
        src_dir = ROOT / pkg_path
        dst_dir = PUBLISH / pkg_path
        dst_dir.mkdir(parents=True, exist_ok=True)

        # Copy .mbt files
        for mbt_file in mbt_files:
            shutil.copy(src_dir / mbt_file, dst_dir / mbt_file)

        # Copy and clean moon.pkg.json
        pkg_json_path = src_dir / "moon.pkg.json"
        with open(pkg_json_path) as f:
            pkg_json = json.load(f)
        cleaned = clean_pkg_json(pkg_json)
        with open(dst_dir / "moon.pkg.json", "w") as f:
            json.dump(cleaned, f, indent=2)
            f.write("\n")

    # 4. Print summary
    print(f"Published to {PUBLISH}")
    for pkg in PACKAGES:
        print(f"  - {pkg}/")


if __name__ == "__main__":
    main()
