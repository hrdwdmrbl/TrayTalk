#!/bin/sh
set -eu

if [ "${CONFIGURATION:-}" != "Release" ]; then
    exit 0
fi

missing=0

validate_setting() {
    name="$1"
    value="$2"

    if [ -z "$value" ] || printf '%s' "$value" | grep -Eq '[$][(]|your-google-oauth-|[<>]'; then
        echo "error: $name is missing or still a placeholder." >&2
        missing=1
    fi
}

validate_setting "GOOGLE_OAUTH_CLIENT_ID" "${GOOGLE_OAUTH_CLIENT_ID:-}"
validate_setting "GOOGLE_OAUTH_CLIENT_SECRET" "${GOOGLE_OAUTH_CLIENT_SECRET:-}"

if [ "$missing" -ne 0 ]; then
    echo "error: Create Config/GoogleOAuth.local.xcconfig with production GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET before building or archiving Release." >&2
    exit 1
fi
