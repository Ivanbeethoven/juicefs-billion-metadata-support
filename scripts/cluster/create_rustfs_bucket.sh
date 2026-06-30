#!/usr/bin/env bash
set -euo pipefail

RUSTFS_ENDPOINT="${RUSTFS_ENDPOINT:-http://127.0.0.1:9000}"
RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-rustfsadmin}"
RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY:-rustfsadmin}"
RUSTFS_BUCKET="${RUSTFS_BUCKET:-juicefs-prod}"
RUSTFS_REGION="${RUSTFS_REGION:-us-east-1}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-60}"
WAIT_INTERVAL="${WAIT_INTERVAL:-2}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

export RUSTFS_ENDPOINT RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY RUSTFS_BUCKET RUSTFS_REGION WAIT_ATTEMPTS WAIT_INTERVAL

python3 <<'PY'
import datetime as dt
import hashlib
import hmac
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

endpoint = os.environ["RUSTFS_ENDPOINT"].rstrip("/")
access_key = os.environ["RUSTFS_ACCESS_KEY"]
secret_key = os.environ["RUSTFS_SECRET_KEY"]
bucket = os.environ["RUSTFS_BUCKET"]
region = os.environ["RUSTFS_REGION"]
attempts = int(os.environ["WAIT_ATTEMPTS"])
interval = int(os.environ["WAIT_INTERVAL"])
service = "s3"
empty_hash = hashlib.sha256(b"").hexdigest()


def sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def signed_headers(method: str, url: str) -> dict[str, str]:
    parsed = urllib.parse.urlsplit(url)
    now = dt.datetime.now(dt.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_scope = now.strftime("%Y%m%d")
    credential_scope = f"{date_scope}/{region}/{service}/aws4_request"
    canonical_uri = urllib.parse.quote(parsed.path or "/", safe="/~")
    canonical_headers = (
        f"host:{parsed.netloc}\n"
        f"x-amz-content-sha256:{empty_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_header_names = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join(
        [
            method,
            canonical_uri,
            "",
            canonical_headers,
            signed_header_names,
            empty_hash,
        ]
    )
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )

    key_date = sign(("AWS4" + secret_key).encode("utf-8"), date_scope)
    key_region = sign(key_date, region)
    key_service = sign(key_region, service)
    key_signing = sign(key_service, "aws4_request")
    signature = hmac.new(key_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    authorization = (
        "AWS4-HMAC-SHA256 "
        f"Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_header_names}, "
        f"Signature={signature}"
    )
    return {
        "Authorization": authorization,
        "Host": parsed.netloc,
        "X-Amz-Content-Sha256": empty_hash,
        "X-Amz-Date": amz_date,
    }


def request(method: str, url: str) -> int:
    data = b"" if method in {"PUT", "POST"} else None
    req = urllib.request.Request(url, data=data, method=method, headers=signed_headers(method, url))
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code


bucket_url = f"{endpoint}/{bucket}"
last_status = 0

for attempt in range(1, attempts + 1):
    try:
        status = request("PUT", bucket_url)
        last_status = status
        if status in {200, 409}:
            break
        if 400 <= status < 500:
            print(f"create bucket failed with HTTP {status}", file=sys.stderr)
            sys.exit(1)
    except OSError as exc:
        if attempt == attempts:
            print(f"RustFS endpoint is not reachable: {exc}", file=sys.stderr)
            sys.exit(1)
    time.sleep(interval)
else:
    print(f"create bucket did not succeed, last HTTP status: {last_status}", file=sys.stderr)
    sys.exit(1)

status = request("HEAD", bucket_url)
if status != 200:
    print(f"bucket verification failed with HTTP {status}", file=sys.stderr)
    sys.exit(1)

print(f"bucket ready: {bucket_url}")
PY
