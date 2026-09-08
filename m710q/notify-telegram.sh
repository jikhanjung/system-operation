#!/usr/bin/env bash
# 공용 Telegram 알림 전송기. 어떤 스크립트/cron 작업에서든 호출.
#
# 사용법:
#   notify-telegram.sh "보낼 메시지"          # 인자로 전달
#   echo "여러 줄 메시지" | notify-telegram.sh  # 표준입력으로 전달
#
# 자격증명은 ~/.config/telegram/credentials 에서 읽는다.
# 자격증명이 없거나 비어 있으면 조용히 아무것도 안 하고 0으로 종료한다
# (알림 실패가 본래 작업을 망치지 않도록).
set -u

CRED="${TELEGRAM_CREDENTIALS:-$HOME/.config/telegram/credentials}"
[ -r "$CRED" ] && . "$CRED"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "notify-telegram: 자격증명이 없어 전송을 건너뜀 ($CRED)" >&2
  exit 0
fi

# 메시지: 인자가 있으면 인자, 없으면 표준입력에서
if [ "$#" -gt 0 ]; then
  msg="$*"
else
  msg="$(cat)"
fi

# 서버 식별 태그를 앞에 붙인다 (어느 서버에서 온 메시지인지 구분).
if [ -n "${NOTIFY_TAG:-}" ]; then
  msg="[${NOTIFY_TAG}] ${msg}"
fi

# 텔레그램 sendMessage 는 4096자가 상한이고, 넘으면 메시지가 잘려 오는 게 아니라
# 400 으로 **통째로** 거절된다 — 호출자는 실패를 stderr 로만 알리고, cron 에서
# 불리면 그 stderr 는 갈 곳이 없다(MTA 없음). 2026-09-08 에 morning-summary 한 통이
# 그렇게 사라졌다. 보내는 쪽에서 잘라, 어떤 호출자가 와도 알림 자체는 도착하게 한다.
# (자르기는 문자 단위여야 한다 — C 로케일의 바이트 자르기는 한글을 쪼개고
#  깨진 UTF-8 은 텔레그램이 또 거절한다)
export LC_ALL=C.utf8
LIMIT=4096
orig=${#msg}
if [ "$orig" -gt "$LIMIT" ]; then
  msg="${msg:0:$((LIMIT - 24))}
… (${orig}자에서 잘림)"
fi

resp=$(curl -s --max-time 15 \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${msg}" \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage")

case "$resp" in
  *'"ok":true'*) exit 0 ;;
  *) echo "notify-telegram: 전송 실패: $resp" >&2; exit 1 ;;
esac
