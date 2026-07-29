#!/usr/bin/env bash
#
# 기한이 지난 rc 마일스톤에 남아 있는 열린 이슈를 다음 rc 마일스톤으로 옮기고,
# 원래 마일스톤을 닫는다.
#
# GitHub 에는 "마일스톤 기한 도래" 웹훅 이벤트가 없다 (milestone 이벤트는
# created/edited/closed/opened/deleted 뿐). 그래서 워크플로가 cron 으로 깨어나
# 열린 마일스톤의 due_on 을 직접 비교하는 폴링 방식을 쓴다.
#
# 필요 권한: issues: write (마일스톤은 issues 스코프에 속한다)

set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY:?REPO 또는 GITHUB_REPOSITORY 가 필요하다}}"
# true 면 API 를 쓰기 없이 계획만 출력한다.
DRY_RUN="${DRY_RUN:-false}"
# 다음 rc 마일스톤을 새로 만들 때 쓸 간격(일). 실행 시점이 아니라 이전 마일스톤의
# due_on 에 더하므로, 워크플로가 하루 늦게 돌아도 일정이 밀리지 않는다.
CADENCE_DAYS="${CADENCE_DAYS:-14}"
# 기한이 지난 마일스톤을 닫을지 여부. 기본은 false — 닫기는 사람이 확인하고 한다.
CLOSE_MILESTONE="${CLOSE_MILESTONE:-false}"
# 대상 마일스톤 제목 패턴. 캡처 그룹 1 = 접두사, 2 = rc 번호.
RC_PATTERN="${RC_PATTERN:-^(.*)rc\.([0-9]+)$}"
# PR 도 함께 옮길지 여부. issues API 는 PR 도 돌려준다.
INCLUDE_PULLS="${INCLUDE_PULLS:-true}"
RESULT_FILE="${RESULT_FILE:-rollover-result.json}"

log() { printf '%s\n' "$*" >&2; }

# GNU date(리눅스 러너)와 BSD date(로컬 macOS) 양쪽에서 동작한다.
add_days() {
  local iso="$1" days="$2"
  date -u -d "$iso +$days days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -j -v"+${days}d" -f %Y-%m-%dT%H:%M:%SZ "$iso" +%Y-%m-%dT%H:%M:%SZ
}

now="$(date -u +%s)"
open_milestones="$(mktemp)"
trap 'rm -f "$open_milestones"' EXIT

# 열린 마일스톤을 한 번만 받아 두고 재사용한다.
gh api --paginate "repos/$REPO/milestones?state=open&sort=due_on&direction=asc" |
  jq -s 'add // []' >"$open_milestones"

# 기한이 지났고 rc 패턴에 맞는 마일스톤만 고른다.
# mapfile 은 bash 4+ 전용이라 macOS 기본 bash 3.2 에서도 돌도록 while-read 를 쓴다.
due_milestones=()
while IFS= read -r line; do
  due_milestones+=("$line")
done < <(
  jq -c --argjson now "$now" '
    .[]
    | select(.due_on != null)
    | select((.due_on | fromdateiso8601) <= $now)
  ' "$open_milestones"
)

if [[ ${#due_milestones[@]} -eq 0 ]]; then
  log "기한이 지난 열린 마일스톤이 없다."
  printf '{"repo":%s,"dry_run":%s,"rolled":[]}\n' \
    "$(jq -Rn --arg v "$REPO" '$v')" "$DRY_RUN" >"$RESULT_FILE"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "rolled_count=0" >>"$GITHUB_OUTPUT"
  exit 0
fi

# 다음 rc 마일스톤을 찾고, 없으면 만든다. 마일스톤 JSON 을 stdout 으로 돌려준다.
resolve_next_milestone() {
  local title="$1" due_on="$2"
  local existing
  existing="$(jq -c --arg t "$title" '.[] | select(.title == $t)' "$open_milestones" | head -n1)"

  if [[ -n "$existing" ]]; then
    jq -c '. + {created: false}' <<<"$existing"
    return
  fi

  local next_due
  next_due="$(add_days "$due_on" "$CADENCE_DAYS")"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [dry-run] 마일스톤 생성: $title (due $next_due)"
    jq -nc --arg t "$title" --arg d "$next_due" \
      '{number: null, title: $t, due_on: $d, created: true}'
    return
  fi

  log "  마일스톤 생성: $title (due $next_due)"
  gh api -X POST "repos/$REPO/milestones" \
    -f "title=$title" -f "due_on=$next_due" |
    jq -c '. + {created: true}'
}

rolled='[]'

for milestone in "${due_milestones[@]}"; do
  number="$(jq -r '.number' <<<"$milestone")"
  title="$(jq -r '.title' <<<"$milestone")"
  due_on="$(jq -r '.due_on' <<<"$milestone")"

  if [[ ! "$title" =~ $RC_PATTERN ]]; then
    log "건너뜀: '$title' 은 rc 패턴에 맞지 않는다."
    continue
  fi

  prefix="${BASH_REMATCH[1]}"
  rc_num="${BASH_REMATCH[2]}"
  # 10# 을 붙여 rc.08 같은 값이 8진수로 해석되는 것을 막는다.
  next_title="${prefix}rc.$((10#$rc_num + 1))"

  log "기한 지남: '$title' (due $due_on) → '$next_title'"

  # 옮길 이슈를 먼저 센다. 마일스톤을 닫지 않는 운영(기본값)에서는 기한 지난
  # 마일스톤이 계속 열려 있으므로 cron 이 매일 같은 마일스톤을 다시 집는다.
  # "남은 열린 이슈가 없으면 건너뛴다"가 종료 조건 역할을 한다. 덕분에 한 번
  # 옮기고 나면 다음 실행부터는 no-op 이고, 다음 마일스톤을 괜히 만들지도 않는다.
  pull_filter='.'
  [[ "$INCLUDE_PULLS" == "true" ]] || pull_filter='select(.pull_request == null)'
  issues=()
  while IFS= read -r line; do
    issues+=("$line")
  done < <(
    gh api --paginate "repos/$REPO/issues?milestone=$number&state=open&per_page=100" |
      jq -r ".[] | $pull_filter | .number"
  )

  # set -u 아래에서 빈 배열 확장은 bash 3.2 에서 에러가 나므로 개수를 먼저 본다.
  if [[ ${#issues[@]} -eq 0 ]]; then
    log "  옮길 열린 이슈가 없어 건너뛴다 (마일스톤 닫기는 사람이 한다)."
    continue
  fi

  next="$(resolve_next_milestone "$next_title" "$due_on")"
  next_number="$(jq -r '.number // empty' <<<"$next")"

  for issue in "${issues[@]}"; do
    if [[ "$DRY_RUN" == "true" ]]; then
      log "  [dry-run] #$issue → $next_title"
    else
      gh api -X PATCH "repos/$REPO/issues/$issue" -F "milestone=$next_number" >/dev/null
      log "  #$issue → $next_title"
    fi
  done

  # 마일스톤 닫기는 기본적으로 사람이 한다. CLOSE_MILESTONE=true 로 켤 수 있다.
  closed=false
  if [[ "$CLOSE_MILESTONE" == "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log "  [dry-run] 마일스톤 닫기: $title"
    else
      gh api -X PATCH "repos/$REPO/milestones/$number" -f state=closed >/dev/null
      log "  마일스톤 닫기: $title"
    fi
    closed=true
  else
    log "  ⚠ '$title' 은 열린 채로 둔다. 확인 후 직접 닫아라."
  fi

  entry="$(
    jq -nc \
      --argjson from_number "$number" --arg from_title "$title" \
      --argjson to "$next" \
      --argjson moved "$(printf '%s\n' "${issues[@]:-}" | jq -Rn '[inputs | select(length > 0) | tonumber]')" \
      --argjson closed "$closed" \
      --arg from_url "https://github.com/$REPO/milestone/$number" \
      '{
        from: {number: $from_number, title: $from_title, url: $from_url},
        to: {number: $to.number, title: $to.title, created: $to.created},
        moved_issues: $moved,
        closed: $closed,
        needs_manual_close: ($closed | not)
      }'
  )"
  rolled="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$rolled")"
done

jq -n --arg repo "$REPO" --argjson dry_run "$DRY_RUN" --argjson rolled "$rolled" \
  '{repo: $repo, dry_run: $dry_run, rolled: $rolled}' >"$RESULT_FILE"

log "결과: $RESULT_FILE"
jq . "$RESULT_FILE" >&2

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "rolled_count=$(jq 'length' <<<"$rolled")" >>"$GITHUB_OUTPUT"
fi

# 마일스톤 닫기는 사람이 하므로, 뭘 닫아야 하는지 Actions 요약에 남긴다.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## 마일스톤 롤오버"
    [[ "$DRY_RUN" == "true" ]] && echo "> dry-run — 아무것도 바꾸지 않았다."
    jq -r '
      .rolled[]
      | "- [\(.from.title)](\(.from.url)) → **\(.to.title)**"
        + " (이슈 \(.moved_issues | length)개"
        + (if .to.created then ", 마일스톤 새로 만듦" else "" end) + ")"
        + (if .needs_manual_close then "\n  - ⚠ **확인 후 직접 닫아야 함**" else "" end)
    ' "$RESULT_FILE"
  } >>"$GITHUB_STEP_SUMMARY"
fi
