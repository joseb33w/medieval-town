#!/usr/bin/env bash
# Stage repo files to R2 under <BUILD_ID>/commit-stage/<path> for commit_from_r2.
# usage: stage_commit.sh <root> <file...>   -> prints additions JSON to stdout (and /tmp/additions.json)
set -euo pipefail
set -a; . /mnt/session/uploads/gogi/credentials.env; set +a
ROOT="$1"; shift
cd "$ROOT"
LIST=$(printf '%s\n' "$@" | jq -R . | jq -s 'map({path: ("commit-stage/" + .)})' | jq -c '{files: .}')
RESP=$(curl -sf -X POST "$PREVIEW_DEPLOY_URL" -H "Authorization: Bearer $PREVIEW_DEPLOY_TOKEN" -H "Content-Type: application/json" -d "$LIST")
echo "$RESP" > /tmp/stage_resp.json
n=$(echo "$RESP" | jq '.files | length'); echo "minted $n urls" >&2
ADD="[]"
for i in $(seq 0 $((n-1))); do
  p=$(echo "$RESP" | jq -r ".files[$i].path"); u=$(echo "$RESP" | jq -r ".files[$i].url"); ct=$(echo "$RESP" | jq -r ".files[$i].contentType // \"application/octet-stream\"")
  rel="${p#commit-stage/}"
  curl -sf -X PUT -H "Content-Type: $ct" --upload-file "$rel" "$u" >/dev/null || { echo "PUT failed $rel" >&2; exit 1; }
  sha=$(sha256sum "$rel" | cut -d' ' -f1)
  ADD=$(echo "$ADD" | jq -c --arg path "$rel" --arg key "$BUILD_ID/$p" --arg sha "$sha" '. + [{path:$path, r2_key:$key, sha256:$sha}]')
done
echo "$ADD" > /tmp/additions.json
echo "staged $(echo "$ADD" | jq length) files -> /tmp/additions.json" >&2
