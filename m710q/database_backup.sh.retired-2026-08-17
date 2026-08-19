#!/bin/bash
# =============================================================================
# DolfinServer DB 백업 스크립트
# cron 등록: 0 1 * * * /home/jikhanjung/scripts/database_backup.sh
# =============================================================================

set -euo pipefail

# --- 설정 ---
DB_SOURCE="/home/jikhanjung/projects/dolfinserver/db.sqlite3"
LOCAL_DIR="/home/jikhanjung/backup"
NAS_DIR="/nas/JikhanJung/dolfinid_backup"
LOG_FILE="/home/jikhanjung/backup/backup.log"

LOCAL_DAILY_DAYS=30
NAS_DAILY_DAYS=90

TODAY=$(date +%F)

# --- 실패 시 Telegram 알림 (~/scripts/notify-telegram.sh 사용) ---
NOTIFY="/home/jikhanjung/scripts/notify-telegram.sh"
notify_fail() {
    [ -x "$NOTIFY" ] && "$NOTIFY" "⚠️ $(basename "$0") 실패: $1" >/dev/null 2>&1 || true
}
trap 'rc=$?; [ "$rc" -ne 0 ] && notify_fail "비정상 종료 (exit $rc)"; true' EXIT

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
    case "$1" in *ERROR*) notify_fail "$1" ;; esac
}

# 계층형 정리: N일 초과 → 매달 1일만 보관, 12월 1일은 영구 보관
# 파일명 패턴: db.sqlite3.YYYY-MM-DD
cleanup_dolfin_db() {
    local dir=$1
    local daily_days=$2
    local deleted=0

    while IFS= read -r file; do
        local base=$(basename "$file")
        local datestr=${base#db.sqlite3.}
        local month=$(echo "$datestr" | cut -d- -f2)
        local day=$(echo "$datestr" | cut -d- -f3)

        # 12월 1일: 영구 보관 (연간 아카이브)
        [ "$month" = "12" ] && [ "$day" = "01" ] && continue

        # 매달 1일: 보관
        [ "$day" = "01" ] && continue

        # 나머지: 삭제
        rm "$file"
        ((deleted++))
    done < <(find "$dir" -name "db.sqlite3.*" -mtime +${daily_days} 2>/dev/null)

    echo $deleted
}

log "========== dolfinserver 백업 시작 =========="

# --- 1. 로컬 백업 ---
if cp "${DB_SOURCE}" "${LOCAL_DIR}/db.sqlite3.${TODAY}"; then
    log "로컬 백업 완료"
else
    log "ERROR: 로컬 백업 실패"
fi

# --- 2. NAS 백업 ---
if timeout 10 test -d "${NAS_DIR}"; then
    if cp "${DB_SOURCE}" "${NAS_DIR}/db.sqlite3.${TODAY}"; then
        log "NAS 백업 완료"
    else
        log "ERROR: NAS 백업 실패"
    fi
else
    log "WARN: NAS 디렉토리 없음 (${NAS_DIR})"
fi

# --- 3. 계층형 백업 정리 ---
LOCAL_DEL=$(cleanup_dolfin_db "${LOCAL_DIR}" ${LOCAL_DAILY_DAYS})
if [ "${LOCAL_DEL}" -gt 0 ]; then
    log "로컬 정리: ${LOCAL_DEL}개 삭제 (${LOCAL_DAILY_DAYS}일 초과, 월초/연말 보존)"
fi

if timeout 10 test -d "${NAS_DIR}"; then
    NAS_DEL=$(cleanup_dolfin_db "${NAS_DIR}" ${NAS_DAILY_DAYS})
    if [ "${NAS_DEL}" -gt 0 ]; then
        log "NAS 정리: ${NAS_DEL}개 삭제 (${NAS_DAILY_DAYS}일 초과, 월초/연말 보존)"
    fi
fi

# --- 4. 리포트 ---
LOCAL_COUNT=$(find "${LOCAL_DIR}" -name "db.sqlite3.*" | wc -l)
LOCAL_SIZE=$(du -sh "${LOCAL_DIR}" 2>/dev/null | cut -f1)
NAS_COUNT=$( { timeout 10 find "${NAS_DIR}" -name "db.sqlite3.*" 2>/dev/null || true; } | wc -l )
NAS_SIZE=$(timeout 10 du -sh "${NAS_DIR}" 2>/dev/null | cut -f1 || echo "N/A")

log "리포트: 로컬=${LOCAL_COUNT}개(${LOCAL_SIZE}), NAS=${NAS_COUNT}개(${NAS_SIZE})"
log "========== dolfinserver 백업 완료 =========="
