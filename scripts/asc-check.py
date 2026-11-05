#!/usr/bin/env python3
"""asc-check.py — ověří ASC API klíč a záznam appky dřív, než to zjistí CI.

Bez závislostí (jen python3 + openssl). Tajné hodnoty nevypisuje.

  asc-check.py --key AuthKey_XXX.p8 --key-id XXX --issuer <uuid> --bundle-id com.ol1n.app

Exit 0 = klíč funguje a appka v App Store Connect existuje.
Exit 2 = klíč/issuer neprojde (HTTP 401/403) -> špatné APP_STORE_CONNECT_API_* secrets.
Exit 3 = appka s tímto bundle ID v ASC není -> altool pak hlásí
         "Cannot determine the Apple ID from Bundle ID" (My Apps -> + -> New App).
"""
import argparse, base64, json, subprocess, sys, time, urllib.error, urllib.parse, urllib.request


def b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """ECDSA podpis z openssl je DER SEQUENCE{r, s}; JWT ES256 chce r||s po 32 B."""
    i = 2 if der[1] < 0x80 else 3
    out = b""
    for _ in range(2):
        n = der[i + 1]
        out += der[i + 2:i + 2 + n].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + n
    return out


def token(key: str, key_id: str, issuer: str) -> str:
    head = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    body = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    msg = f"{head}.{body}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=msg,
                         capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64(der_to_raw(der))}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True)
    ap.add_argument("--key-id", required=True)
    ap.add_argument("--issuer", required=True)
    ap.add_argument("--bundle-id", required=True)
    a = ap.parse_args()

    q = urllib.parse.urlencode({"filter[bundleId]": a.bundle_id, "fields[apps]": "name,bundleId"})
    req = urllib.request.Request(f"https://api.appstoreconnect.apple.com/v1/apps?{q}",
                                 headers={"Authorization": "Bearer " + token(a.key, a.key_id, a.issuer)})
    try:
        data = json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            print(f"❌  ASC API odmítlo klíč (HTTP {e.code}): key id / issuer / .p8 k sobě nepatří.", file=sys.stderr)
            return 2
        print(f"❌  ASC API: HTTP {e.code}", file=sys.stderr)
        return 1
    # filter[bundleId] je prefixový; chceme přesnou shodu (pozor na velká písmena).
    apps = [x for x in data.get("data", []) if x["attributes"]["bundleId"] == a.bundle_id]
    if not apps:
        # Filtr API je přesný; častá chyba je jen velikost písmen (com.ol1n.Papanek vs papanek).
        allq = urllib.parse.urlencode({"limit": 200, "fields[apps]": "bundleId"})
        req = urllib.request.Request(f"https://api.appstoreconnect.apple.com/v1/apps?{allq}",
                                     headers=req.headers)
        every = json.load(urllib.request.urlopen(req, timeout=30)).get("data", [])
        near = [x["attributes"]["bundleId"] for x in every
                if x["attributes"]["bundleId"].lower() == a.bundle_id.lower()]
        hint = f" Podobné: {', '.join(near)}." if near else ""
        print(f"❌  V App Store Connect není appka s bundle ID '{a.bundle_id}'.{hint}\n"
              f"    Založ ji: appstoreconnect.apple.com → My Apps → + → New App. Bez ní TestFlight upload\n"
              f"    selže hláškou 'Cannot determine the Apple ID from Bundle ID'.", file=sys.stderr)
        return 3
    print(f"✅  ASC: klíč funguje, appka '{apps[0]['attributes']['name']}' ({a.bundle_id}) existuje")
    return 0


if __name__ == "__main__":
    sys.exit(main())
