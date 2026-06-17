#!/usr/bin/env bash
# 새벽 cron 작업들이 오늘 모두 정상 완료됐는지 점검하고 텔레그램으로 요약 1건 발송.
# 마지막 작업(pull-repos 06:00) 이후에 돌도록 cron 등록 (예: 30 6 * * *).
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
check_backup "FcSky"      "/home/jikhanjung/backups/FcSky/backup.log"
check_backup "fcmanager"  "/home/jikhanjung/backups/fcmanager/backup.log"

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

if [ "$ok_all" -eq 1 ]; then
  header="✅ 새벽 작업 전부 정상 완료 (${TODAY})"
else
  header="⚠️ 새벽 작업 점검 — 일부 미완료/실패 (${TODAY})"
fi

[ -x "$NOTIFY" ] && "$NOTIFY" "${header}
${lines}"
