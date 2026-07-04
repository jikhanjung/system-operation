# system-operation

여러 서버의 운영(백업·동기화·알림) 스크립트를 버전관리하는 저장소.
서버별로 하위 디렉토리를 두며, 디렉토리 이름은 각 서버의 **알림 태그**(텔레그램 메시지 앞에 붙는 `[태그]`)와 일치한다.

```
system-operation/
└── m710q/        ← 서버 m710q 의 스크립트
```

## m710q

홈 서버. 실제 실행되는 `~/scripts` 는 이 디렉토리를 가리키는 **심볼릭 링크**다
(원본 = repo, 사본 불일치 없음):

```
~/scripts -> ~/projects/system-operation/m710q
```

### 스크립트

| 파일 | cron | 설명 |
|------|------|------|
| `database_backup.sh` | `0 1 * * *` | dolfinserver DB 백업 (로컬 + NAS, 계층형 보관) |
| `backup-fsis.sh`     | `0 3 * * *` | fsis2026 백업 (운영서버 pull → 로컬 + NAS) |
| `backup-ghdb.sh`     | `30 3 * * *` | GHDB 백업 |
| `backup-fcmanager.sh`| `0 5 * * *` | fcmanager 백업 |
| `pull-repos.sh`      | `0 6 * * *` | `~/projects` 밑 모든 git repo 를 `--ff-only` pull |
| `morning-summary.sh` | `30 7 * * *` | 새벽 작업 결과를 점검해 텔레그램 요약 1통 발송 |
| `notify-telegram.sh` | (헬퍼) | 공용 텔레그램 전송기. 다른 스크립트가 호출 |

폐기된 스크립트는 `_retired/` 에 보관한다
(예: `backup-fcsky.sh` — FcSky→fcmanager 이관으로 2026-06-22 폐기).

### repo 밖 크론 작업

crontab 에는 이 repo 밖의 스크립트도 등록되어 있으며, `morning-summary.sh` 가 함께 점검한다:

| cron | 스크립트 | 설명 |
|------|----------|------|
| `0 4 * * *`  | `~/projects/cdGTS/scripts/sync-cdgts-db.sh` | cdGTS 운영 DB → 개발/테스트 DB sync (로그: `~/backups/cdGTS/sync.log`) |
| `30 6 * * *` | `~/projects/devdocs/nightly-ingest.sh` | .md sync → ingest(claude -p) → commit/push 파이프라인 (로그: `m710q/nightly-ingest.log`) |

### 알림 (Telegram)

- 전송 헬퍼: `notify-telegram.sh "메시지"` (또는 stdin)
- 자격증명은 **repo 밖**에 보관: `~/.config/telegram/credentials` (권한 600)
  ```
  TELEGRAM_BOT_TOKEN="..."
  TELEGRAM_CHAT_ID="..."
  NOTIFY_TAG="m710q"      # 메시지 앞에 [m710q] 로 붙음 (서버 식별)
  ```
- 각 백업 스크립트는 **실패 시 즉시** 알림(`ERROR` 로그 / 비정상 종료 트랩),
  `morning-summary.sh` 는 매일 아침 **전체 요약 1통**(전부 정상이면 ✅, 일부 실패면 ⚠️).

### 동작 메모

- 백업 스크립트의 NAS 접근은 모두 `timeout 10` 으로 감싸,
  NAS 가 죽어 있어도(언마운트/stale 마운트) 무한 대기 없이 건너뛴다.
- `pull-repos.sh` 로그는 512KB 초과 시 `pull-repos-YYYY-MM.log` 로 월별 보관,
  3개월 지난 월 파일은 자동 `gzip` 압축.
- 로그 파일(`*.log`, `*.log.*`)은 `.gitignore` 로 추적 제외.

## 새 서버 추가

1. 새 디렉토리 생성: `system-operation/<태그>/`
2. 해당 서버에서 그 디렉토리를 `~/scripts` 로 심볼릭 링크
3. 그 서버의 `~/.config/telegram/credentials` 에 `NOTIFY_TAG="<태그>"` 설정
