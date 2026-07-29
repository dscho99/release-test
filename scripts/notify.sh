#!/usr/bin/env bash
#
# 롤오버 결과를 외부 엔드포인트로 POST 한다.
#
# 아직 실제 트리거 스펙(엔드포인트, 페이로드, 인증 방식)이 정해지지 않아서
# 범용 웹훅 형태로 두었다. 스펙이 정해지면 payload 조립 부분만 고치면 된다.

set -euo pipefail

TRIGGER_URL="${TRIGGER_URL:-}"
RESULT_FILE="${RESULT_FILE:-rollover-result.json}"
TRIGGER_TOKEN="${TRIGGER_TOKEN:-}"
TRIGGER_TOKEN_HEADER="${TRIGGER_TOKEN_HEADER:-Authorization}"
TRIGGER_TOKEN_PREFIX="${TRIGGER_TOKEN_PREFIX:-Bearer }"
# 옮긴 게 없어도 보낼지 여부.
NOTIFY_WHEN_EMPTY="${NOTIFY_WHEN_EMPTY:-false}"

log() { printf '%s\n' "$*" >&2; }

if [[ -z "$TRIGGER_URL" ]]; then
  log "TRIGGER_URL 이 비어 있어 트리거를 건너뛴다."
  exit 0
fi

if [[ ! -f "$RESULT_FILE" ]]; then
  log "결과 파일이 없다: $RESULT_FILE"
  exit 1
fi

rolled_count="$(jq '.rolled | length' "$RESULT_FILE")"
if [[ "$rolled_count" -eq 0 && "$NOTIFY_WHEN_EMPTY" != "true" ]]; then
  log "옮긴 마일스톤이 없어 트리거를 건너뛴다."
  exit 0
fi

if [[ "$(jq -r '.dry_run' "$RESULT_FILE")" == "true" ]]; then
  log "dry-run 이라 트리거를 건너뛴다."
  exit 0
fi

payload="$(
  jq -c \
    --arg event "milestone.rollover" \
    --arg run_url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
    '{event: $event, run_url: $run_url, result: .}' "$RESULT_FILE"
)"

headers=(-H "Content-Type: application/json")
if [[ -n "$TRIGGER_TOKEN" ]]; then
  headers+=(-H "${TRIGGER_TOKEN_HEADER}: ${TRIGGER_TOKEN_PREFIX}${TRIGGER_TOKEN}")
fi

log "POST $TRIGGER_URL (rolled=$rolled_count)"
# --fail-with-body: 4xx/5xx 에서 응답 본문을 보여주고 종료 코드를 실패로 만든다.
curl --silent --show-error --fail-with-body \
  --retry 3 --retry-connrefused --max-time 30 \
  "${headers[@]}" \
  --data "$payload" \
  "$TRIGGER_URL"
