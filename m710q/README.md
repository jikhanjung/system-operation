# ~/scripts (m710q)

> **여기는 홈 디렉터리가 아니라 git 저장소의 워킹트리다.**

```
~/scripts  ->  ~/projects/system-operation/m710q
origin: git@github.com:jikhanjung/system-operation.git
```

`~/scripts/` 는 **심볼릭 링크**다. 이 디렉터리에서 파일을 고치면 그 순간 repo 가 수정된
것이고, 반대로 repo 를 고치면 다음 cron 이 곧바로 그 코드를 실행한다. 사본이 없으니
"배포" 단계도 없다.

확인:

```bash
ls -ld ~/scripts        # lrwxrwxrwx ... -> /home/jikhanjung/projects/system-operation/m710q
readlink -f ~/scripts
```

`ls -la ~/scripts/` 는 링크라는 사실을 보여주지 않는다 — 반드시 `-d` 로 볼 것.
2026-08-19 에 이 디렉터리를 "repo 밖 개인 스크립트" 로 오인한 기록이 있다.

## 고친 뒤에 할 일

```bash
cd ~/projects/system-operation
git add m710q/<파일> && git commit && git push
```

- **커밋할 곳은 여기다.** fsis2026 등 애플리케이션 repo 가 아니다.
  fsis2026 에 있던 `scripts/backup-{fsis,ghdb}.sh` 손사본은 2026-08-19 에 삭제했다 —
  아무도 실행하지 않으면서 4개월 묵은 내용으로 읽는 사람을 오도했다.
  다른 repo 에 이 스크립트들의 사본을 만들지 말 것.
- **수동 `.bak` 파일을 만들지 말 것.** 여기선 그것도 repo 파일이 된다.
  이전본은 `git show HEAD:m710q/<파일>` 로 꺼낸다.
- 폐기한 스크립트는 지우지 말고 `_retired/` 로 옮기거나 `.retired-YYYY-MM-DD` 로 개명한다.

## 무엇이 있나

| 파일 | 역할 |
|------|------|
| `backup-fsis.sh` | fsis2026 (kofhin) 백업 pull → 로컬 + NAS + dev_data + 테스트 컨테이너 |
| `backup-ghdb.sh` | ghdb (dolfinid) 백업 pull. 위와 같은 구조 |
| `backup-fcmanager.sh` | fcmanager 백업 pull |
| `lib/refresh-test-db.sh` | 테스트 컨테이너 DB 갱신 헬퍼. 위 백업 스크립트들이 `source` |
| `pull-repos.sh` | `~/projects` 밑 git repo 전체 `--ff-only` pull |
| `morning-summary.sh` | 새벽 작업 결과 점검 → 텔레그램 요약 1통 |
| `notify-telegram.sh` | 공용 텔레그램 전송기 (다른 스크립트가 호출) |
| `crontab.backup-*.txt` | crontab 스냅샷. **crontab 자체는 git 에 없으므로 유일한 기록이다** |

**cron 시각·설계 배경·알림 설정은 [`../README.md`](../README.md) 가 정본이다.**
여기에 다시 적으면 갈라지므로 옮겨 적지 않는다. 실제로 걸린 cron 은 `crontab -l` 이 진실.

## 알아둘 것

- **자격증명은 repo 밖**: `~/.config/telegram/credentials` (권한 600). 여기 두지 말 것.
- **로그가 이 디렉터리에 떨어진다**: `nightly-ingest.log`, `pull-repos.log`, `ingest-logs/`.
  `.gitignore` 의 `*.log` / `*.log.*` 로 추적 제외돼 있다.
- **테스트 컨테이너 DB 경로는 하드코딩하지 않는다** — `lib/refresh-test-db.sh` 가 컨테이너의
  `DATABASE_PATH` 와 마운트 테이블에서 역산하고 `cmp` 로 검증한다. 옛 버전은 경로를 박아두었다가
  파일→디렉터리 마운트 전환을 못 따라가, 한 달간 **"갱신 완료" 를 찍으며 아무도 안 읽는 파일에
  복사**했다 (fsis2026 devlog 237).
