# release-test

릴리즈 마일스톤 자동화. 현재는 **rc 마일스톤 롤오버** 하나가 들어 있다.

## 뭘 하나

`v1.0.0-rc.0` 처럼 `rc.<숫자>` 로 끝나는 마일스톤이 **마감일 오후 5시(KST)** 를 넘기면:

1. 그 마일스톤에 남아 있는 **열린 이슈를 다음 rc 마일스톤(`rc.1`)으로 옮긴다**
2. 다음 마일스톤이 없으면 **새로 만든다** (due date = 이전 마일스톤 due date + `CADENCE_DAYS`)
3. `TRIGGER_URL` 이 설정돼 있으면 결과를 **HTTP POST 로 보낸다**

**기한이 지난 마일스톤을 닫는 건 사람이 한다.** 이슈만 비워 두고 마일스톤은 열린 채로
남긴다. 뭘 닫아야 하는지는 Actions 실행 요약(Summary)에 링크로 뜬다.

### 왜 두 번 돌지 않나

마일스톤을 닫지 않으니 기한 지난 마일스톤이 계속 열려 있고, cron 은 매일 같은
마일스톤을 다시 집는다. 그래서 **"옮길 열린 이슈가 없으면 건너뛴다"가 종료 조건**이다.
한 번 옮기고 나면 그 마일스톤에 열린 이슈가 0개라 다음 실행부터는 아무것도 하지 않고
(다음 마일스톤을 또 만들지도, 트리거를 또 쏘지도 않는다), 사람이 닫을 때까지 조용하다.

닫기까지 자동으로 하려면 `CLOSE_MILESTONE=true`.

## 마감 시각은 왜 여기서 정하나

**GitHub 마일스톤은 시각을 저장하지 않는다.** `due_on` 에 무슨 시각을 넘겨도
`T00:00:00Z` 로 뭉개고, 날짜만 넘기면 422 로 거절한다. 실제로 확인한 결과:

```
POST due_on=2026-07-01T08:00:00Z  →  "due_on": "2026-07-01T00:00:00Z"
POST due_on=2026-07-01T23:59:00Z  →  "due_on": "2026-07-01T00:00:00Z"
POST due_on=2026-07-01           →  422 Invalid request
```

그래서 마일스톤에서는 날짜만 받고 **"오후 5시"는 이 스크립트가 고정한다**
(`DEADLINE_HOUR=17`, `DEADLINE_TZ_OFFSET=9`). 마감 시각 = 마감일 17:00 KST =
`due_on` 자정 UTC + 8시간.

`due_on` 의 날짜 부분만 떼어 자정 UTC 로 다시 만든 뒤 오프셋을 더하므로, 저장된
시각이 무엇이든(과거 데이터든 GitHub 이 규칙을 바꾸든) 결과가 흔들리지 않는다.
한국은 서머타임이 없어 연중 고정이다.

## 왜 cron 인가

GitHub 에는 "마일스톤 기한이 도래했다"는 웹훅 이벤트가 없다. `milestone` 이벤트는
`created` / `edited` / `closed` / `opened` / `deleted` 뿐이다. 그래서 매일
08:00 UTC(= 17:00 KST)에 깨어나 마감 시각을 직접 비교하는 폴링 방식을 쓴다.

마감 판정은 cron 이 아니라 `DEADLINE_HOUR` 가 하므로, **cron 이 밀리거나 더 자주
돌아도 오후 5시 전에는 절대 옮기지 않는다.** 반대로 러너가 지연되면 5시보다 늦게
돌 수는 있다 (GitHub 의 예약 워크플로는 원래 정시 보장이 없다).

새 마일스톤의 due date 는 실행 시각이 아니라 이전 마일스톤의 due date 기준으로
계산하므로, 실행이 늦어져도 일정 자체는 밀리지 않는다.

## 마일스톤 이름 표기

**`3.2.0-rc.1` 형식이 유일하게 맞다.** `rc` 와 숫자 사이에 점이 있어야 한다.

`3.2.0-rc1` 같은 변형은 **일부러 인식하지 않는다.** 조용히 받아주면 오타가 굳어지고,
같은 릴리즈에 마일스톤이 두 개 생긴다. 패턴에 안 맞는 마일스톤은 로그에
`건너뜀: '...' 은 rc 패턴에 맞지 않는다` 로 남고 그대로 무시된다.

## 구성

```
.github/workflows/milestone-rollover.yaml   cron + 수동 실행
scripts/rollover.sh                         마일스톤 롤오버
scripts/notify.sh                           결과 HTTP POST
```

Go 나 컨테이너 이미지는 쓰지 않는다. 하는 일이 GitHub API 호출 몇 번이라
러너에 기본 설치된 `gh` + `jq` + `curl` 로 충분하다. 로직이 커지면 그때
Go CLI 로 옮기면 된다.

## 실행

수동 실행은 Actions 탭 → `milestone-rollover` → Run workflow. **`dry_run` 기본값이
`true`** 라 아무것도 바꾸지 않고 계획만 로그에 찍는다. 실제로 반영하려면 체크를 끈다.

로컬에서:

```bash
gh auth login
REPO=dscho99/release-test DRY_RUN=true ./scripts/rollover.sh
```

## 설정

워크플로 `env` 또는 셸 환경변수로 넘긴다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `REPO` | `$GITHUB_REPOSITORY` | 대상 레포 (`owner/name`) |
| `DRY_RUN` | `false` | `true` 면 쓰기 없이 계획만 출력 |
| `CADENCE_DAYS` | `14` | 다음 rc 마일스톤을 새로 만들 때 쓸 간격 |
| `CLOSE_MILESTONE` | `false` | 기한 지난 마일스톤을 닫을지. 기본은 사람이 닫는다 |
| `DEADLINE_HOUR` | `17` | 마감 시각(로컬). 마일스톤에는 저장 못 하므로 여기서 고정 |
| `DEADLINE_TZ_OFFSET` | `9` | 로컬 타임존의 UTC 오프셋 (KST = +9) |
| `RC_PATTERN` | `^(.*)rc\.([0-9]+)$` | 대상 제목 패턴. 그룹1=접두사, 그룹2=rc 번호 |
| `INCLUDE_PULLS` | `true` | PR 도 함께 옮길지 |

### Secrets

| Secret | 필수 | 설명 |
|---|---|---|
| `TRIGGER_URL` | 아니오 | 없으면 트리거 스텝을 건너뛴다 |
| `TRIGGER_TOKEN` | 아니오 | 있으면 `Authorization: Bearer <token>` 로 붙는다 |

`GITHUB_TOKEN` 은 Actions 가 자동으로 넣어준다.

## 트리거 페이로드

```json
{
  "event": "milestone.rollover",
  "run_url": "https://github.com/dscho99/release-test/actions/runs/123",
  "result": {
    "repo": "dscho99/release-test",
    "dry_run": false,
    "rolled": [
      {
        "from": {
          "number": 1,
          "title": "v1.0.0-rc.0",
          "url": "https://github.com/dscho99/release-test/milestone/1"
        },
        "to": { "number": 2, "title": "v1.0.0-rc.1", "created": true },
        "moved_issues": [12, 15, 18],
        "closed": false,
        "needs_manual_close": true
      }
    ]
  }
}
```

dry-run 이거나 옮긴 게 없으면 POST 하지 않는다 (`NOTIFY_WHEN_EMPTY=true` 로 변경 가능).

**이 페이로드 형태는 아직 실제 스펙에 맞춘 게 아니다.** 받는 쪽이 정해지면
`scripts/notify.sh` 의 `payload` 조립 부분만 고치면 된다.

## 아직 안 된 것

- **크로스 레포**: 지금은 워크플로가 있는 레포만 대상. 다른 레포를 건드리려면
  기본 `GITHUB_TOKEN` 으로는 안 되고 PAT 이나 GitHub App 이 필요하다.
- **트리거 스펙**: 위 참고.
