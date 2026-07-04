#!/usr/bin/env bash
# 새벽 cron 작업들이 오늘 모두 정상 완료됐는지 점검하고 텔레그램으로 요약 1건 발송.
# 마지막 작업(nightly-ingest 06:30: sync→ingest→push) 이후에 돌도록 cron 등록 (예: 30 7 * * *).
# 전부 정상이면 ✅, 하나라도 미완료/실패면 ⚠️ 로 매일 1통 보낸다(데일리 하트비트).
set -u

NOTIFY="/home/jikhanjung/scripts/notify-telegram.sh"
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
INGEST_LOG="/home/jikhanjung/scripts/nightly-ingest.log"
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
  if ! echo "$ni_block" | grep -q '===== nightly-ingest done'; then
    lines="${lines}❌ ingest (완료(done) 라인 없음 — 중단/타임아웃 의심)"$'\n'
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

if [ "$ok_all" -eq 1 ]; then
  header="✅ 새벽 작업 전부 정상 완료 (${TODAY})"
else
  header="⚠️ 새벽 작업 점검 — 일부 미완료/실패 (${TODAY})"
fi

[ -x "$NOTIFY" ] && "$NOTIFY" "${header}
${lines}"
