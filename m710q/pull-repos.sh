#!/usr/bin/env bash
# 매일 ~/projects 밑의 모든 git repo를 안전하게 pull 한다.
# - --ff-only: 충돌/머지 커밋을 만들지 않고, fast-forward 가능할 때만 당긴다.
# - 로컬 변경(dirty)이 있는 repo는 건너뛴다.
set -u

PROJECTS_DIR="/home/jikhanjung/projects"
LOG="/home/jikhanjung/scripts/pull-repos.log"
MAX_LOG_BYTES=$((512 * 1024))   # 로그가 이 크기를 넘으면 회전(rotate)

# 실패 알림은 공용 전송기를 통해 보낸다.
# (자격증명은 ~/.config/telegram/credentials, 헬퍼가 알아서 처리)
NOTIFY="/home/jikhanjung/scripts/notify-telegram.sh"
notify_failure() {
  [ -x "$NOTIFY" ] && "$NOTIFY" "$1"
}

# cron 환경에서도 SSH 키를 쓰도록 보장
export GIT_SSH_COMMAND="ssh -i /home/jikhanjung/.ssh/id_ed25519_git -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

# 로그 회전: 현재 로그가 너무 크면 그 달의 보관 파일(pull-repos-YYYY-MM.log)에
# 합쳐 넣고 현재 로그를 비운다. 같은 달에 여러 번 회전돼도 같은 파일에 누적된다.
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt "$MAX_LOG_BYTES" ]; then
  archive="/home/jikhanjung/scripts/pull-repos-$(date '+%Y-%m').log"
  cat "$LOG" >> "$archive"
  : > "$LOG"
fi

# 3개월보다 오래된 월별 보관 파일은 gzip으로 압축한다.
# (이미 .gz인 것과 최근 3개월치는 건드리지 않는다.)
cutoff=$(date '+%Y-%m' -d '3 months ago')
for f in /home/jikhanjung/scripts/pull-repos-[0-9][0-9][0-9][0-9]-[0-9][0-9].log; do
  [ -e "$f" ] || continue
  ym=$(basename "$f" .log); ym=${ym#pull-repos-}
  if [ "$ym" \< "$cutoff" ]; then
    gzip -f "$f"
  fi
done

failures=""   # 실패한 repo 모음 (알림용)

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
  for dir in "$PROJECTS_DIR"/*/; do
    [ -d "$dir/.git" ] || continue
    name=$(basename "$dir")

    # 로컬에 커밋 안 된 변경이 있으면 건너뜀
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      echo "[SKIP] $name (로컬 변경 있음)"
      continue
    fi

    # 커밋이 하나도 없는 빈 레포는 건너뜀 (pull 할 ref 자체가 없어 --ff-only 실패)
    if ! git -C "$dir" rev-parse --verify -q HEAD >/dev/null 2>&1; then
      echo "[SKIP] $name (커밋 없음 - 빈 레포)"
      continue
    fi

    before=$(git -C "$dir" rev-parse --short HEAD)
    if out=$(git -C "$dir" pull --ff-only 2>&1); then
      after=$(git -C "$dir" rev-parse --short HEAD)
      if [ "$before" = "$after" ]; then
        echo "[OK]   $name (최신)"
      else
        # 변경 파일 목록 전체 대신 한 줄 요약만 기록
        stat=$(git -C "$dir" diff --shortstat "$before" "$after")
        echo "[PULL] $name  $before..$after  ($stat )"
      fi
    else
      echo "[FAIL] $name"
      echo "$out" | sed 's/^/         /'
      # 에러 첫 줄만 추려서 알림 메시지에 담는다
      reason=$(echo "$out" | grep -v '^$' | head -1)
      failures="${failures}• ${name}: ${reason}"$'\n'
    fi
  done
  echo
} >> "$LOG" 2>&1

# 실패가 하나라도 있으면 Telegram 알림
if [ -n "$failures" ]; then
  notify_failure "⚠️ git pull 실패 ($(date '+%Y-%m-%d %H:%M'))
$failures자세한 내용: $LOG"
fi
