#!/usr/bin/env python3
"""Publish a verified macOS DMG to the opt-in channel only.

Run from a clean checkout after building/signature verification. Authentication
uses GH_TOKEN or the existing Git credential helper; credentials are never logged.
The stable release workflow and version.json are deliberately not modified.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request

REPO = "Thalassiochthon/NormalSwitcher"
API = f"https://api.github.com/repos/{REPO}"


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asset", type=Path)
    parser.add_argument("--manifest", type=Path, default=Path("release/macos-beta.json"))
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    version = manifest["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+[a-z]", version):
        raise SystemExit("Only prerelease versions such as 1.2.0a are accepted")
    if args.asset.name != f"NormalSwitcher-{version}.dmg":
        raise SystemExit("Asset name must match the beta version")
    if git("status", "--porcelain"):
        raise SystemExit("Commit source and release metadata before publishing")
    commit = git("rev-parse", "HEAD")
    digest = hashlib.sha256(args.asset.read_bytes()).hexdigest()
    token = os.environ.get("GH_TOKEN")
    if not token:
        filled = subprocess.check_output(["git", "credential", "fill"],
            input="protocol=https\nhost=github.com\n\n", text=True)
        token = dict(line.split("=", 1) for line in filled.splitlines() if "=" in line).get("password")
    if not token:
        raise SystemExit("No GitHub credential is available")

    def request(path, method="GET", payload=None, raw=None):
        url = path if path.startswith("https://") else API + path
        if urllib.parse.urlparse(url).hostname not in ("api.github.com", "uploads.github.com"):
            raise ValueError("Unexpected API host")
        headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "NormalSwitcher-beta-publisher"}
        data = raw
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        elif raw is not None:
            headers["Content-Type"] = "application/octet-stream"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers, method=method), timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if method == "GET" and error.code == 404:
                return None
            raise SystemExit(f"GitHub {method} failed: HTTP {error.code}; no feed is advanced before the release is ready") from None

    repo = request("")
    if repo["id"] != 1449964984 or request(f"/git/commits/{commit}") is None:
        raise SystemExit("Unexpected repository or source commit is not pushed")
    stable = request("/contents/version.json?ref=personal")
    stable_data = json.loads(base64.b64decode(stable["content"]))
    if tuple(map(int, version[:-1].split("."))) <= tuple(map(int, stable_data["version"].split("."))):
        raise SystemExit("Beta must be for a newer version than stable")
    tag = "v" + version
    release = request(f"/releases/tags/{tag}")
    if release is None:
        release = request("/releases", "POST", {
            "tag_name": tag, "target_commitish": commit,
            "name": f"NormalSwitcher {version} — macOS beta",
            "body": manifest["notes"] + f"\n\nApple Silicon · macOS 13+\n\nBuild {manifest['build']} · source `{commit}`\n\n"
                    "Opt in: Settings → About → Get beta versions, then Check for Updates.\n"
                    "Включите «Настройки → О программе → Получать бета-версии», затем «Проверить обновления».\n\n"
                    f"SHA256: `{digest}`\n\n"
                    "Manual install: quit NormalSwitcher and replace the app in Applications.\n"
                    "Для ручной установки: завершите NormalSwitcher и замените приложение в «Программах».",
            "draft": True, "prerelease": True, "make_latest": "false",
        })
    if not release["prerelease"] or release["target_commitish"] != commit:
        raise SystemExit("Existing release does not match this beta source")
    asset = next((x for x in release["assets"] if x["name"] == args.asset.name), None)
    if asset is None:
        if not release["draft"]:
            raise SystemExit("Refusing to change assets in a published release")
        upload = release["upload_url"].split("{")[0] + "?name=" + urllib.parse.quote(args.asset.name)
        asset = request(upload, "POST", raw=args.asset.read_bytes())
    if asset.get("digest") != "sha256:" + digest or asset["state"] != "uploaded":
        raise SystemExit("Uploaded asset digest/state does not match; beta feed unchanged")
    if release["draft"]:
        release = request(f"/releases/{release['id']}", "PATCH",
                          {"draft": False, "prerelease": True, "make_latest": "false"})
    # Draft assets have an untagged URL; use the URL returned after publication.
    asset = next(x for x in release["assets"] if x["name"] == args.asset.name)
    feed = {**manifest, "url": release["html_url"], "sha256": digest, "source_commit": commit}
    beta = request("/contents/version-beta.json?ref=personal")
    content = json.dumps(feed, ensure_ascii=False, indent=2) + "\n"
    if beta is None or json.loads(base64.b64decode(beta["content"])) != feed:
        payload = {"branch": "personal", "message": f"Announce macOS beta {version} to opted-in users",
                   "content": base64.b64encode(content.encode()).decode()}
        if beta is not None:
            payload["sha"] = beta["sha"]
        request("/contents/version-beta.json", "PUT", payload)
    after = request("/contents/version.json?ref=personal")
    if after["sha"] != stable["sha"]:
        raise SystemExit("Stable feed changed concurrently; inspect it before proceeding")
    print(json.dumps({"release": release["html_url"], "download": asset["browser_download_url"],
                      "sha256": digest, "stable_version": stable_data["version"], "beta_version": version}, indent=2))


if __name__ == "__main__":
    main()
