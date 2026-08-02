#!/usr/bin/env bash
# 새벽 cron 작업들이 오늘 모두 정상 완료됐는지 점검하고 텔레그램으로 요약 1건 발송.
# 마지막 작업(nightly-ingest 06:30: sync→ingest→push) 이후에 돌도록 cron 등록 (예: 30 7 * * *).
# 전부 정상이면 ✅, 하나라도 미완료/실패면 ⚠️ 로 매일 1통 보낸다(데일리 하트비트).
set -u

NOTIFY="${NOTIFY:-/home/jikhanjung/scripts/notify-telegram.sh}"   # 테스트 시 스텁으로 교체 가능
TODAY=$(date +%F)

ok_all=1
lines=""

# 백업 작업: 로그에 "오늘 날짜 ... 완료 ==========" 라인이 있으면 성공
check_backup() {
  local name="$1" logf="$2"
  if grep -qE "^${TODAY}.*완료 ==========" "$logf" 2>/dev/null; then
    lines="${lines}✅ ${name}"$'\n'
  else
    lines="${lines}❌ ${name} (오늘 완료 기록 없음)"$'\n'
    ok_all=0
  fi
}

check_backup "dolfin DB"  "/home/jikhanjung/backup/backup.log"
check_backup "fsis2026"   "/home/jikhanjung/backups/fsis2026/backup.log"
check_backup "ghdb"       "/home/jikhanjung/backups/ghdb/backup.log"
check_backup "fcmanager"  "/home/jikhanjung/backups/fcmanager/backup.log"
check_backup "cdGTS sync" "/home/jikhanjung/backups/cdGTS/sync.log"

# git pull(pull-repos): 로그의 마지막 실행 블록이 오늘이고 [FAIL]이 없으면 성공
PULL_LOG="/home/jikhanjung/scripts/pull-repos.log"
pull_block=$(tac "$PULL_LOG" 2>/dev/null | awk '/^===== /{print; exit} {print}' | tac)
if echo "$pull_block" | head -1 | grep -q "$TODAY"; then
  pf=$(echo "$pull_block" | grep -c '^\[FAIL\]')
  pp=$(echo "$pull_block" | grep -c '^\[PULL\]')
  if [ "$pf" -eq 0 ]; then
    lines="${lines}✅ git pull (갱신 ${pp}개)"$'\n'
  else
    lines="${lines}❌ git pull (실패 ${pf}개)"$'\n'
    ok_all=0
  fi
else
  lines="${lines}❌ git pull (오늘 실행 기록 없음)"$'\n'
  ok_all=0
fi

# .md sync + ingest(nightly-ingest): 06:30 파이프라인이 sync→ingest→push를
# 한 로그에 남긴다. 오늘 마지막 실행 블록(===== nightly-ingest start ~)을 읽어
# sync 완료와 ingest 결과를 각각 점검한다.
# (구 sync-devdocs.log는 standalone cron이 nightly-ingest로 교체되면서 더 이상
#  갱신되지 않으므로 nightly-ingest.log를 본다.)
INGEST_LOG="${INGEST_LOG:-/home/jikhanjung/scripts/nightly-ingest.log}"
ni_block=$(tac "$INGEST_LOG" 2>/dev/null | awk '/===== nightly-ingest start/{print; exit} {print}' | tac)
if echo "$ni_block" | head -1 | grep -q "$TODAY"; then
  # --- sync ---
  if echo "$ni_block" | grep -q '^==== synced '; then
    sdirs=$(echo "$ni_block" | sed -n 's/^==== synced \([0-9]*\) source dirs.*/\1/p')
    stot=$(echo "$ni_block" | sed -n 's/^Total md in raw\/: \([0-9]*\).*/\1/p')
    lines="${lines}✅ .md sync (${sdirs}개 디렉토리, ${stot} md)"$'\n'
  else
    lines="${lines}❌ .md sync (완료 기록 없음)"$'\n'
    ok_all=0
  fi
  # --- ingest ---
  # ⚠️ INCOMPLETE 판정을 push 검사보다 먼저 볼 것. 미완 실행도 커밋·push 를
  # 하므로(부분 작업 보존 + 다음 실행의 clean tree), pushed: 만 보면 실패를
  # ✅ 로 보고한다 — 2026-08-01 에 실제로 그렇게 하루를 놓쳤다.
  if ! echo "$ni_block" | grep -q '===== nightly-ingest done'; then
    lines="${lines}❌ ingest (완료(done) 라인 없음 — 중단/타임아웃 의심)"$'\n'
    ok_all=0
  elif echo "$ni_block" | grep -q 'nightly-ingest done (INCOMPLETE'; then
    ni_reason=$(echo "$ni_block" | sed -n 's/^\[[^]]*\] ❌ ingest 미완: //p' | tail -1)
    lines="${lines}❌ ingest 미완 (${ni_reason:-사유 미상}) — 다음 실행이 재시도"$'\n'
    ok_all=0
  elif echo "$ni_block" | grep -q 'ERROR:'; then
    lines="${lines}❌ ingest (ERROR 발생 — 로그 확인)"$'\n'
    ok_all=0
  elif echo "$ni_block" | grep -qE '^\[[^]]*\] pushed: '; then
    subj=$(echo "$ni_block" | sed -n 's/^\[[^]]*\] pushed: [0-9a-f]* \(.*\)/\1/p' | tail -1)
    lines="${lines}✅ ingest (push: ${subj})"$'\n'
  elif echo "$ni_block" | grep -q 'no delta'; then
    lines="${lines}✅ ingest (델타 없음 — 변경 사항 없음)"$'\n'
  else
    lines="${lines}✅ ingest (완료 — push 없음/NO_PUSH)"$'\n'
  fi
else
  lines="${lines}❌ .md sync/ingest (오늘 실행 기록 없음)"$'\n'
  ok_all=0
fi

# devdocs 미완 ingest 마커: 오늘 실행과 무관하게, 처리 안 끝난 델타가 남아 있으면
# 계속 알린다(오늘 nightly 가 아예 안 돌았어도 잡히도록 별도 검사).
DEVDOCS_PENDING="${DEVDOCS_PENDING:-/home/jikhanjung/projects/devdocs/.ingest-pending}"
if [ -f "$DEVDOCS_PENDING" ]; then
  dp_att=$(sed -n 's/^attempts: //p' "$DEVDOCS_PENDING" | head -1)
  dp_first=$(sed -n 's/^first-failed: //p' "$DEVDOCS_PENDING" | head -1)
  dp_n=$(sed -n '/^--- pending delta/,$p' "$DEVDOCS_PENDING" | tail -n +2 | grep -c . || true)
  lines="${lines}⚠️ devdocs 미완 ingest 대기 (${dp_n:-?}건, ${dp_att:-?}회 시도, 최초 ${dp_first:-?})"$'\n'
  ok_all=0
fi

# naverland 크롤러: run-crawler.sh(02:00)가 남긴 상태 파일(오늘·SUCCESS 확인)
NL_STATUS="/srv/naverland/logs/crawler_status.txt"
nl_line=$(head -1 "$NL_STATUS" 2>/dev/null)
if echo "$nl_line" | grep -q "^${TODAY}"; then
  if echo "$nl_line" | grep -q "SUCCESS"; then
    lines="${lines}✅ naverland 크롤러 (${nl_line#*| })"$'\n'
  else
    lines="${lines}❌ naverland 크롤러 (${nl_line#*| })"$'\n'
    ok_all=0
  fi
else
  lines="${lines}❌ naverland 크롤러 (오늘 실행 기록 없음)"$'\n'
  ok_all=0
fi

if [ "$ok_all" -eq 1 ]; then
  header="✅ 새벽 작업 전부 정상 완료 (${TODAY})"
else
  header="⚠️ 새벽 작업 점검 — 일부 미완료/실패 (${TODAY})"
fi

[ -x "$NOTIFY" ] && "$NOTIFY" "${header}
${lines}"
