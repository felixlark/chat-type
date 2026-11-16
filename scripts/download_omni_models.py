#!/usr/bin/env python3
"""Download and verify the pinned public models used by ChatType's Omni runtime."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


class PublicModelRedirects(urllib.request.HTTPRedirectHandler):
    def __init__(self) -> None:
        super().__init__()
        self.hosts: set[str] = set()

    def redirect_request(self, request, response, code, message, headers, new_url):
        parsed = urllib.parse.urlparse(new_url)
        host = parsed.hostname or ""
        if parsed.scheme != "https" or not (
            host == "huggingface.co" or host.endswith(".huggingface.co")
            or host.endswith(".hf.co") or host.endswith(".xethub.hf.co")
        ):
            raise ValueError(f"Unapproved model redirect host: {host}")
        self.hosts.add(host)
        return super().redirect_request(request, response, code, message, headers, new_url)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[1] / "scripts/fixtures/omni-models.json")
    parser.add_argument("--models-root", type=Path, default=Path.home() / "Library/Application Support/ChatType/Models")
    parser.add_argument("--model", action="append", help="Manifest model id; omitted downloads both ASR models and VAD")
    parser.add_argument("--receipt", type=Path, required=True)
    arguments = parser.parse_args()
    manifest = json.loads(arguments.manifest.read_text())
    if manifest["schemaVersion"] != 1:
        raise ValueError("Unsupported manifest schema")
    selected = set(arguments.model or [model["id"] for model in manifest["models"]])
    if selected - {model["id"] for model in manifest["models"]}:
        raise ValueError("Unknown model id")
    redirects = PublicModelRedirects()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), redirects)
    receipt = {"source": manifest["source"], "models": [], "downloadHosts": ["huggingface.co"]}
    os.umask(0o077)
    for model in manifest["models"]:
        if model["id"] not in selected:
            continue
        directory = arguments.models_root / model["id"] / model["revision"]
        directory.mkdir(parents=True, exist_ok=True)
        for entry in model["files"]:
            target = directory / entry["name"]
            if target.exists() and target.stat().st_size == entry["bytes"] and digest(target) == entry["sha256"]:
                print(f"verified {model['id']}/{entry['name']}", flush=True)
                continue
            partial = target.with_name(target.name + ".partial")
            offset = partial.stat().st_size if partial.exists() else 0
            if offset >= entry["bytes"]:
                if offset == entry["bytes"] and digest(partial) == entry["sha256"]:
                    partial.replace(target)
                    print(f"verified {model['id']}/{entry['name']}", flush=True)
                    continue
                partial.unlink()
                offset = 0
            url = f"https://huggingface.co/{model['repo']}/resolve/{model['revision']}/{urllib.parse.quote(entry['name'])}"
            request = urllib.request.Request(url, headers={"User-Agent": "ChatType-model-download/1"})
            if offset:
                request.add_header("Range", f"bytes={offset}-")
            print(f"downloading {model['id']}/{entry['name']} bytes={entry['bytes']} resume={offset}", flush=True)
            try:
                response = opener.open(request, timeout=60)
            except urllib.error.HTTPError as error:
                if error.code != 416 or not offset:
                    raise
                partial.unlink()
                offset = 0
                request.remove_header("Range")
                response = opener.open(request, timeout=60)
            with response:
                if offset and response.status != 206:
                    offset = 0
                with partial.open("ab" if offset else "wb") as destination:
                    for block in iter(lambda: response.read(1024 * 1024), b""):
                        destination.write(block)
                    destination.flush()
                    os.fsync(destination.fileno())
            if partial.stat().st_size != entry["bytes"] or digest(partial) != entry["sha256"]:
                raise ValueError(f"Model integrity check failed: {model['id']}/{entry['name']}")
            partial.replace(target)
        (directory / "verified-manifest.json").write_text(json.dumps(model, indent=2) + "\n")
        receipt["models"].append({"id": model["id"], "revision": model["revision"], "path": str(directory), "verifiedFiles": len(model["files"]), "bytes": sum(entry["bytes"] for entry in model["files"])})
        receipt["downloadHosts"] = sorted({"huggingface.co"} | redirects.hosts)
        arguments.receipt.parent.mkdir(parents=True, exist_ok=True)
        arguments.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"ready {model['id']}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Model download HTTP status {error.code}; partial files retained") from None
    except urllib.error.URLError as error:
        raise SystemExit(f"Model download transport failure: {type(error.reason).__name__}; partial files retained") from None
