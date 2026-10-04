#!/usr/bin/env python3
"""Hand a freshly uploaded TestFlight build to the external "Public" group.

External groups have no auto-distribute, so after the upload this script:
  1. waits until the build (pubspec build number) is VALID in App Store Connect,
  2. sets "What to Test" for en-GB and en-US from the newest release note,
  3. adds the build to the external group named "Public",
  4. submits the build for Beta App Review (once per build).

Every step checks current state first, so re-running is safe.

Env: APPSTORE_ISSUER_ID, APPSTORE_API_KEY_ID, APPSTORE_API_PRIVATE_KEY (the .p8
contents). Needs: pip install pyjwt cryptography requests

Usage: python tool/testflight_public.py [--build N] [--timeout-min 30]
"""
import argparse
import os
import re
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
APP_ID = "6811691176"
GROUP_NAME = "Public"
LOCALES = ("en-GB", "en-US")  # en-GB is the app's primary locale; review submit 422s without it
FALLBACK_NOTES = (
    "Pair it with your LG TV, then try power on and off, volume, opening apps "
    "and the touchpad. If anything misbehaves, tell me with the TestFlight "
    "feedback button."
)
ROOT = Path(__file__).resolve().parent.parent
IR_WORD = re.compile(r"\bIR\b")  # same rule as ReleaseNotes.forDevice: iOS has no IR blaster


class AscError(Exception):
    pass


def _token():
    # Signed per request: a token minted once expires during the processing wait.
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["APPSTORE_ISSUER_ID"], "iat": now, "exp": now + 600,
         "aud": "appstoreconnect-v1"},
        os.environ["APPSTORE_API_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": os.environ["APPSTORE_API_KEY_ID"], "typ": "JWT"},
    )


def call(method, path, body=None, ok=(200, 201, 204), **params):
    """Returns parsed JSON ({} for 204/empty). Retries transient failures."""
    last = None
    for attempt in range(5):
        try:
            r = requests.request(
                method, API + path, params=params or None, json=body, timeout=60,
                headers={"Authorization": "Bearer " + _token()})
        except requests.RequestException as e:
            last = f"{type(e).__name__}: {e}"
        else:
            if r.status_code in ok:
                try:
                    return r.json()
                except ValueError:
                    return {}
            if r.status_code not in (429, 500, 502, 503, 504):
                raise AscError(f"{method} {path} -> {r.status_code}: {_errors(r)}")
            last = f"{r.status_code}: {_errors(r)}"
        time.sleep(5 * (attempt + 1))
    raise AscError(f"{method} {path} failed after retries ({last})")


def _errors(r):
    try:
        errs = r.json().get("errors") or []
        return "; ".join(f"{e.get('code')}: {e.get('detail') or e.get('title')}" for e in errs)[:600]
    except ValueError:
        return r.text[:300]


def pubspec_build_number():
    m = re.search(r"^version:\s*[\w.]+\+(\d+)\s*$", (ROOT / "pubspec.yaml").read_text(), re.M)
    if not m:
        raise AscError("could not read the build number from pubspec.yaml")
    return m.group(1)


def _dart_strings_in_first_list(src):
    """String literals of the first list after `Release(` in the `all` list."""
    start = src.index("static const List<Release> all")
    i = src.index("Release(", start)
    i = src.index("[", i)
    depth, out = 0, []
    while i < len(src):
        c = src[i]
        if c in "'\"":
            j = i + 1
            while src[j] != c:
                j += 2 if src[j] == "\\" else 1
            if depth == 1:
                out.append(re.sub(r"\\(.)", r"\1", src[i + 1:j]))
            i = j
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return out


def whats_new():
    try:
        notes = _dart_strings_in_first_list((ROOT / "lib/theme/release_notes.dart").read_text(encoding="utf-8"))
    except (ValueError, IndexError, OSError) as e:
        print(f"release notes unreadable ({e}); using fallback text")
        notes = []
    notes = [n.strip() for n in notes if n.strip() and not IR_WORD.search(n)]
    return "\n".join(notes)[:4000] if notes else FALLBACK_NOTES


def wait_for_build(number, timeout_s):
    deadline = time.time() + timeout_s
    while True:
        data = call("GET", "/v1/builds", **{
            "filter[app]": APP_ID, "filter[version]": number,
            "sort": "-uploadedDate", "limit": 5}).get("data", [])
        if data:
            state = data[0]["attributes"]["processingState"]
            if state == "VALID":
                return data[0]["id"]
            if state in ("INVALID", "FAILED"):
                raise AscError(f"build {number} processing ended as {state}")
            print(f"build {number} is {state}; waiting")
        else:
            print(f"build {number} not listed yet; waiting")
        if time.time() > deadline:
            raise AscError(f"build {number} not VALID within the timeout")
        time.sleep(30)


def set_whats_new(build_id, text):
    existing = {
        d["attributes"]["locale"]: d for d in
        call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations", limit=50).get("data", [])}
    for locale in LOCALES:
        cur = existing.get(locale)
        if cur is None:
            call("POST", "/v1/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
            print(f"What to Test created for {locale}")
        elif cur["attributes"].get("whatsNew") != text:
            call("PATCH", f"/v1/betaBuildLocalizations/{cur['id']}", {"data": {
                "type": "betaBuildLocalizations", "id": cur["id"],
                "attributes": {"whatsNew": text}}})
            print(f"What to Test updated for {locale}")
        else:
            print(f"What to Test already current for {locale}")


def add_to_group(build_id):
    groups = call("GET", f"/v1/apps/{APP_ID}/betaGroups", limit=200).get("data", [])
    match = [g for g in groups
             if g["attributes"]["name"] == GROUP_NAME and not g["attributes"]["isInternalGroup"]]
    if not match:
        raise AscError(f'no external beta group named "{GROUP_NAME}" on app {APP_ID}')
    gid = match[0]["id"]
    in_group = {b["id"] for b in call("GET", f"/v1/betaGroups/{gid}/builds", limit=200).get("data", [])}
    if build_id in in_group:
        print(f'build already in "{GROUP_NAME}"')
        return
    call("POST", f"/v1/betaGroups/{gid}/relationships/builds",
         {"data": [{"type": "builds", "id": build_id}]})
    print(f'added build to "{GROUP_NAME}"')


def submit_for_review(build_id):
    def current():
        try:
            return call("GET", f"/v1/builds/{build_id}/betaAppReviewSubmission").get("data")
        except AscError as e:
            if " 404:" in str(e):
                return None
            raise

    sub = current()
    if sub:
        print("beta review submission exists:", sub["attributes"]["betaReviewState"])
        return
    call("POST", "/v1/betaAppReviewSubmissions", {"data": {
        "type": "betaAppReviewSubmissions",
        "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    sub = current()
    print("submitted for beta review:", sub["attributes"]["betaReviewState"] if sub else "ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=None, help="build number (default: from pubspec.yaml)")
    ap.add_argument("--timeout-min", type=int, default=30)
    args = ap.parse_args()
    number = args.build or pubspec_build_number()
    missing = [k for k in ("APPSTORE_ISSUER_ID", "APPSTORE_API_KEY_ID", "APPSTORE_API_PRIVATE_KEY")
               if not os.environ.get(k)]
    if missing:
        sys.exit("missing env: " + ", ".join(missing))
    try:
        build_id = wait_for_build(number, args.timeout_min * 60)
        set_whats_new(build_id, whats_new())
        add_to_group(build_id)
        submit_for_review(build_id)
    except AscError as e:
        msg = (f"Build {number} reached TestFlight (the upload step succeeded), but handing it to "
               f'the "{GROUP_NAME}" group failed: {e}. Re-running this job would fail on the '
               "duplicate build number; instead run tool/testflight_public.py locally "
               f"(it is idempotent) with --build {number}.")
        print("::error::" + msg)
        sys.exit(1)
    print(f"build {number} is set for the \"{GROUP_NAME}\" group")


if __name__ == "__main__":
    main()
