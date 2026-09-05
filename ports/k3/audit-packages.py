#!/usr/bin/env python3
"""Compare Omarchy's package manifests with current Arch RISC-V repositories.

Reads package metadata only; it neither installs packages nor executes PKGBUILDs.
Availability does not establish that a package works on the K3 GPU or BSP.
"""
import argparse
import collections
import datetime
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request


def read_database(data, repository):
  packages = {}
  with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
    for entry in archive:
      if not entry.isfile() or not entry.name.endswith("/desc"):
        continue
      fields = {}
      key = None
      for line in archive.extractfile(entry).read().decode().splitlines():
        if line.startswith("%") and line.endswith("%"):
          key = line.strip("%")
          fields[key] = []
        elif line and key:
          fields[key].append(line)
      if "NAME" in fields and fields.get("ARCH", [""])[0] in ("riscv64", "any"):
        name = fields["NAME"][0]
        packages[name] = {
          "repository": repository,
          "version": fields["VERSION"][0],
          "architecture": fields["ARCH"][0],
          "provides": fields.get("PROVIDES", []),
        }
  return packages


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--mirror", default="https://archriscv.felixc.at/repo")
  parser.add_argument("--output", type=Path, default=Path("build/package-audit"))
  args = parser.parse_args()
  root = Path(__file__).resolve().parents[2]
  args.output.mkdir(parents=True, exist_ok=True)
  packages, sources = {}, []
  for repo in ("core", "extra"):
    url = f"{args.mirror.rstrip('/')}/{repo}/{repo}.db"
    with urllib.request.urlopen(url, timeout=90) as response:
      data = response.read()
    (args.output / f"{repo}.db").write_bytes(data)
    sources.append({"url": url, "sha256": hashlib.sha256(data).hexdigest()})
    packages.update(read_database(data, repo))
  providers = collections.defaultdict(list)
  for name, metadata in packages.items():
    for provision in metadata["provides"]:
      providers[provision.split("=")[0]].append(name)
  rows = []
  for manifest in sorted((root / "install").glob("omarchy-*.packages")):
    for line in manifest.read_text().splitlines():
      name = line.split("#", 1)[0].strip()
      if not name:
        continue
      row = {"manifest": manifest.name, "package": name}
      if name in packages:
        row.update(status="available", **packages[name])
      elif name in providers:
        row.update(status="provider-review", providers=sorted(providers[name]))
      else:
        row["status"] = "missing"
      rows.append(row)
  report = {
    "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "sources": sources,
    "note": "Repository metadata only. Providers need version/conflict review; missing includes hardware-specific and optional packages. No board runtime validation.",
    "packages": rows,
  }
  (args.output / "packages.json").write_text(json.dumps(report, indent=2) + "\n")
  lines = ["# Omarchy RISC-V package audit", "", report["note"], ""]
  for manifest in sorted({row["manifest"] for row in rows}):
    subset = [row for row in rows if row["manifest"] == manifest]
    counts = collections.Counter(row["status"] for row in subset)
    lines += [f"## {manifest}", "", ", ".join(f"{key}: {value}" for key, value in sorted(counts.items())), "", "| Package | Status | Version or provider |", "| --- | --- | --- |"]
    for row in subset:
      detail = row.get("version", ", ".join(row.get("providers", [])))
      lines.append(f"| {row['package']} | {row['status']} | {detail} |")
    lines.append("")
  (args.output / "packages.md").write_text("\n".join(lines))
  for manifest in sorted({row["manifest"] for row in rows}):
    print(manifest, dict(collections.Counter(row["status"] for row in rows if row["manifest"] == manifest)))
  print(f"Report: {args.output / 'packages.md'}")


if __name__ == "__main__":
  main()
