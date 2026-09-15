#!/usr/bin/env python3
"""Resolve an exact macOS InstallAssistant package from Apple's catalog."""

from __future__ import annotations

import gzip
import json
import os
import plistlib
import re
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit


CATALOG_BASE = "https://swscan.apple.com/content/catalogs/others/"
CATALOG_NAMES = {
    17: "index-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    18: "index-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    19: "index-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    20: "index-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    21: "index-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    22: "index-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    23: "index-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    24: "index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    25: "index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
}


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "brew-distill"})
    with urllib.request.urlopen(request, timeout=60) as response:
        content = response.read()
    return gzip.decompress(content) if content.startswith(b"\x1f\x8b") else content


def catalog_url() -> str:
    override = os.environ.get("DISTILL_SOFTWAREUPDATE_CATALOG_URL", "")
    if override:
        return override
    darwin_major = int(os.uname().release.split(".", 1)[0])
    name = CATALOG_NAMES.get(darwin_major, CATALOG_NAMES[25 if darwin_major >= 25 else 24])
    return CATALOG_BASE + name


def distribution_value(content: bytes, key: str) -> str:
    text = content.decode("utf-8", "replace")
    patterns = (
        rf"<key>{re.escape(key)}</key>\s*<string>([^<]+)</string>",
        rf"\b{re.escape(key)}\s*=\s*[\"']([^\"']+)[\"']",
    )
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return match.group(1).strip()
    return ""


def package_info(product: dict) -> tuple[str, str]:
    for package in product.get("Packages", []):
        url = package.get("URL", "")
        if urlsplit(url).path.endswith("/InstallAssistant.pkg"):
            return url, package.get("MetadataURL", "")
    return "", ""


def package_value(content: bytes, key: str) -> str:
    text = content.decode("utf-8", "replace")
    match = re.search(
        rf"<bundle\b[^>]*\b{re.escape(key)}=[\"']([^\"']+)[\"']",
        text,
        re.IGNORECASE,
    )
    return match.group(1).strip() if match else ""


def resolve(version: str) -> dict:
    url = catalog_url()
    catalog = plistlib.loads(fetch(url))
    for product_id, product in catalog.get("Products", {}).items():
        if not product.get("ExtendedMetaInfo", {}).get("InstallAssistantPackageIdentifiers"):
            continue
        package, package_metadata = package_info(product)
        if not package:
            continue
        distributions = product.get("Distributions", {})
        distribution = distributions.get("English") or distributions.get("en", "")
        candidate_version = ""
        build = ""
        bundle_version = ""
        if distribution:
            try:
                content = fetch(distribution)
            except (OSError, ValueError):
                content = b""
            candidate_version = distribution_value(content, "VERSION")
            build = distribution_value(content, "BUILD")
        if package_metadata:
            try:
                content = fetch(package_metadata)
            except (OSError, ValueError):
                content = b""
            bundle_version = package_value(content, "CFBundleShortVersionString")
        if not candidate_version:
            metadata_url = product.get("ServerMetadataURL", "")
            if metadata_url:
                try:
                    metadata = plistlib.loads(fetch(metadata_url))
                except (OSError, ValueError, plistlib.InvalidFileException):
                    metadata = {}
                candidate_version = str(metadata.get("CFBundleShortVersionString", ""))
        if candidate_version == version:
            return {
                "schema": 1,
                "catalog_url": url,
                "product_id": product_id,
                "version": candidate_version,
                "build": build,
                "bundle_version": bundle_version,
                "package_url": package,
            }
    raise RuntimeError(f"Apple catalog has no InstallAssistant package for {version}")


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"(?:11|12|13|14)(?:\.\d+)*", sys.argv[1]):
        print("usage: fetch-installer-catalog.py VERSION", file=sys.stderr)
        return 2
    try:
        record = resolve(sys.argv[1])
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"fetch-installer-catalog: {error}", file=sys.stderr)
        return 1
    print(json.dumps(record, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
