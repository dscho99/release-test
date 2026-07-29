#!/usr/bin/env bash
#
# Mattermost incoming webhook 으로 메시지를 보낸다.
#
#   ./scripts/mattermost.sh "보낼 **마크다운** 메시지"
#
# MATTERMOST_WEBHOOK_URL 이 비어 있으면 조용히 건너뛴다 (fork PR 등 secret 이
# 없는 실행에서 워크플로를 실패시키지 않기 위해).
#
# 스펙: https://developers.mattermost.com/integrate/webhooks/incoming/
# text 는 마크다운을 지원하고 16383자까지 들어간다.

set -euo pipefail

MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"
text="${1:-}"
# 사내망 밖(GitHub 호스티드 러너)에서는 Mattermost 에 아예 닿지 않는다.
# 오래 매달려 봐야 어차피 timeout 이므로 짧게 끊는다. 사내 러너로 옮기면
# 여유롭게 잡아도 된다.
TIMEOUT="${MATTERMOST_TIMEOUT:-10}"
RETRY="${MATTERMOST_RETRY:-2}"

log() { printf '%s\n' "$*" >&2; }

if [[ -z "$text" ]]; then
  log "보낼 메시지가 비어 있다."
  exit 1
fi

if [[ -z "$MATTERMOST_WEBHOOK_URL" ]]; then
  log "MATTERMOST_WEBHOOK_URL 이 없어 Mattermost 발송을 건너뛴다."
  exit 0
fi

# jq 로 만들어야 따옴표·개행·유니코드가 안전하게 이스케이프된다.
payload="$(jq -nc --arg text "$text" '{text: $text}')"

log "Mattermost 발송 (${#text}자)"
curl --silent --show-error --fail-with-body \
  --retry "$RETRY" --retry-connrefused --max-time "$TIMEOUT" \
  -H "Content-Type: application/json" \
  --data "$payload" \
  "$MATTERMOST_WEBHOOK_URL"
echo
