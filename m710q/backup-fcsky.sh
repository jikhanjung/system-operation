#!/bin/bash
# =============================================================================
# FC Sky 백업 스크립트 (m710q 개발/백업 호스트에서 실행)
# 운영서버(dolfinid)에서 이 서버로 DB·media·.env 를 SSH pull 하여 보관.
# fsis2026 backup-fsis.sh 를 FC Sky 규모로 단순화(단일 DB + media).
#
# cron 등록(m710q): crontab -e →  0 4 * * * /home/jikhanjung/scripts/backup-fcsky.sh
# 수동 전체 스냅:    /home/jikhanjung/scripts/backup-fcsky.sh --full-snapshot
#
# 운영서버 접속은 환경변수로 override 가능(기본값은 아래 설정):
#   FCSKY_REMOTE_USER, FCSKY_REMOTE_HOST, FCSKY_REMOTE_PATH
# =============================================================================

set -euo pipefail

FULL_SNAPSHOT=false
if [ "${1:-}" = "--full-snapshot" ]; then
    FULL_SNAPSHOT=true
fi

# --- 설정 ---
REMOTE_USER="${FCSKY_REMOTE_USER:-honestjung}"
REMOTE_HOST="${FCSKY_REMOTE_HOST:-34.64.158.160}"   # dolfinid
REMOTE_PATH="${FCSKY_REMOTE_PATH:-/srv/FcSky}"
# .env 는 운영 런타임 위치(/srv/FcSky/.env). 배포 분리 후 compose 도 여기서 실행.
REMOTE_ENV_PATH="${FCSKY_REMOTE_ENV:-/srv/FcSky/.env}"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

BACKUP_DIR="/home/jikhanjung/backups/FcSky"
NAS_DIR="/nas/JikhanJung/FcSky_backup"
DB_HISTORY_DIR="${BACKUP_DIR}/db_history"
TAR_HISTORY_DIR="${BACKUP_DIR}/tar_history"
CURRENT_DIR="${BACKUP_DIR}/current"
LOG_FILE="${BACKUP_DIR}/backup.log"

LOCAL_DAILY_DAYS=30
NAS_DAILY_DAYS=90

# --- 초기화 ---
mkdir -p "${DB_HISTORY_DIR}" "${TAR_HISTORY_DIR}" "${CURRENT_DIR}"

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
# 파일명 패턴: <prefix>_YYYYMMDD.<ext>
cleanup_tiered() {
    local dir=$1 pattern=$2 prefix=$3 ext=$4 daily_days=$5
    local deleted=0
    while IFS= read -r file; do
        local base datestr month day
        base=$(basename "$file")
        datestr=${base#${prefix}}
        datestr=${datestr%.${ext}}
        month=${datestr:4:2}; day=${datestr:6:2}
        [ "$month" = "12" ] && [ "$day" = "01" ] && continue   # 연말 영구
        [ "$day" = "01" ] && continue                          # 월초 보관
        rm -f "$file" "${file}-wal" "${file}-shm"
        ((deleted++)) || true
    done < <(find "$dir" -name "$pattern" ! -name "*-wal" ! -name "*-shm" -mtime +${daily_days} 2>/dev/null)
    echo $deleted
}

log "========== 백업 시작 =========="
TODAY=$(date +%Y%m%d)

# --- 1. DB 스냅샷 (날짜별 보관) ---
DB_SNAPSHOT="${DB_HISTORY_DIR}/db_${TODAY}.sqlite3"
log "DB 스냅샷 복사 중..."
if scp -q "${REMOTE}:${REMOTE_PATH}/db.sqlite3" "${DB_SNAPSHOT}"; then
    scp -q "${REMOTE}:${REMOTE_PATH}/db.sqlite3-wal" "${DB_SNAPSHOT}-wal" 2>/dev/null || true
    scp -q "${REMOTE}:${REMOTE_PATH}/db.sqlite3-shm" "${DB_SNAPSHOT}-shm" 2>/dev/null || true
    log "DB 스냅샷 완료: ${DB_SNAPSHOT} (+wal/shm)"
else
    log "ERROR: DB 스냅샷 실패 (${REMOTE}:${REMOTE_PATH}/db.sqlite3)"
    exit 1
fi

DELETED=$(cleanup_tiered "${DB_HISTORY_DIR}" "db_*.sqlite3" "db_" "sqlite3" ${LOCAL_DAILY_DAYS})
[ "${DELETED}" -gt 0 ] && log "로컬 DB 정리: ${DELETED}개 삭제 (${LOCAL_DAILY_DAYS}일 초과, 월초/연말 보존)"

# --- 2. media/ 미러링 ---
log "media/ 동기화 중..."
rsync -az --delete "${REMOTE}:${REMOTE_PATH}/media/" "${CURRENT_DIR}/media/" >> "${LOG_FILE}" 2>&1
log "media/ 동기화 완료"

# --- 3. .env 백업 ---
# 배포 구조 분리(devlog 050) 후 .env 는 운영 런타임 위치 /srv/FcSky/.env 에 있다
# (호스트가 직접 관리, sync 대상 아님). FCSKY_REMOTE_ENV 로 override.
scp -q "${REMOTE}:${REMOTE_ENV_PATH}" "${CURRENT_DIR}/.env" 2>/dev/null && \
    log ".env 복사 완료" || log "WARN: .env 없음 (건너뜀: ${REMOTE_ENV_PATH})"

# --- 4. nginx conf tar (운영 hourly 가 만든 최신본 1개 pull) ---
NGINX_TAR_REMOTE=$(ssh "${REMOTE}" "ls -t ${REMOTE_PATH}/backup/dolfinid_nginx_*.tar.gz 2>/dev/null | head -1" 2>/dev/null || true)
if [ -n "${NGINX_TAR_REMOTE}" ]; then
    scp -q "${REMOTE}:${NGINX_TAR_REMOTE}" "${TAR_HISTORY_DIR}/dolfinid_nginx_${TODAY}.tar.gz" 2>/dev/null \
        && log "nginx tar 보관: dolfinid_nginx_${TODAY}.tar.gz" \
        || log "WARN: nginx tar pull 실패"
    cleanup_tiered "${TAR_HISTORY_DIR}" "dolfinid_nginx_*.tar.gz" "dolfinid_nginx_" "tar.gz" ${LOCAL_DAILY_DAYS} >/dev/null
else
    log "WARN: 운영 nginx tar 없음 (운영 hourly 미구동?)"
fi

# --- 5. 현재 DB도 current/에 동기화 ---
cp "${DB_SNAPSHOT}" "${CURRENT_DIR}/db.sqlite3"
cp -f "${DB_SNAPSHOT}-wal" "${CURRENT_DIR}/db.sqlite3-wal" 2>/dev/null || true
cp -f "${DB_SNAPSHOT}-shm" "${CURRENT_DIR}/db.sqlite3-shm" 2>/dev/null || true
log "current/db.sqlite3 동기화 완료 (+wal/shm)"

# --- 6. NAS 백업 (마운트돼 있을 때만) ---
if timeout 10 test -d "${NAS_DIR}"; then
    NAS_DB_DIR="${NAS_DIR}/db_history"
    NAS_CURRENT="${NAS_DIR}/current"
    mkdir -p "${NAS_DB_DIR}" "${NAS_CURRENT}"
    cp "${DB_SNAPSHOT}" "${NAS_DB_DIR}/db_${TODAY}.sqlite3"
    cp -f "${DB_SNAPSHOT}-wal" "${NAS_DB_DIR}/db_${TODAY}.sqlite3-wal" 2>/dev/null || true
    cp -f "${DB_SNAPSHOT}-shm" "${NAS_DB_DIR}/db_${TODAY}.sqlite3-shm" 2>/dev/null || true
    rsync -az --no-group --delete "${CURRENT_DIR}/media/" "${NAS_CURRENT}/media/" >> "${LOG_FILE}" 2>&1
    [ -f "${CURRENT_DIR}/.env" ] && cp "${CURRENT_DIR}/.env" "${NAS_CURRENT}/.env"
    cp "${DB_SNAPSHOT}" "${NAS_CURRENT}/db.sqlite3"
    NAS_DEL=$(cleanup_tiered "${NAS_DB_DIR}" "db_*.sqlite3" "db_" "sqlite3" ${NAS_DAILY_DAYS})
    [ "${NAS_DEL}" -gt 0 ] && log "NAS DB 정리: ${NAS_DEL}개 삭제"
    log "NAS 백업 완료"
else
    log "WARN: NAS 디렉토리 없음 (${NAS_DIR}) — 건너뜀"
fi

# --- 7. media 계층형 스냅샷 (월간 full + 일간 link-dest) ---
DAY=$(date +%d); MONTH=$(date +%m); YEAR=$(date +%Y); YYYYMM=$(date +%Y%m)
MEDIA_SNAP_DIR="${BACKUP_DIR}/media_snapshots"
MONTHLY_SNAP_DIR="${MEDIA_SNAP_DIR}/monthly"
DAILY_SNAP_DIR="${MEDIA_SNAP_DIR}/daily"
mkdir -p "${MONTHLY_SNAP_DIR}" "${DAILY_SNAP_DIR}"
CURRENT_MONTH_FULL="${MONTHLY_SNAP_DIR}/${YYYYMM}_full"

if [ "$FULL_SNAPSHOT" = true ] || [ "$DAY" = "01" ] || [ ! -d "${CURRENT_MONTH_FULL}" ]; then
    PREV_FULL=$(find "${MONTHLY_SNAP_DIR}" -maxdepth 1 -mindepth 1 -name "*_full" -type d ! -path "${CURRENT_MONTH_FULL}" | sort | tail -1)
    if [ -n "${PREV_FULL}" ]; then
        rsync -a --delete --link-dest="${PREV_FULL}/" "${CURRENT_DIR}/media/" "${CURRENT_MONTH_FULL}/" >> "${LOG_FILE}" 2>&1
        log "월간 full 생성 (link-dest=$(basename ${PREV_FULL})): ${YYYYMM}_full"
    else
        rsync -a --delete "${CURRENT_DIR}/media/" "${CURRENT_MONTH_FULL}/" >> "${LOG_FILE}" 2>&1
        log "월간 full 생성 (최초): ${YYYYMM}_full"
    fi
    if [ "$DAY" = "01" ]; then
        PREV_YYYYMM=$(date -d "yesterday" +%Y%m)
        DEL_DAILY=0
        for daily_snap in "${DAILY_SNAP_DIR}"/${PREV_YYYYMM}*; do
            [ -d "${daily_snap}" ] && rm -rf "${daily_snap}" && DEL_DAILY=$((DEL_DAILY + 1))
        done
        [ "${DEL_DAILY}" -gt 0 ] && log "지난 달(${PREV_YYYYMM}) daily 삭제: ${DEL_DAILY}개"
    fi
else
    DAILY_SNAP="${DAILY_SNAP_DIR}/${TODAY}"
    if [ -d "${DAILY_SNAP}" ]; then
        log "일간 스냅 이미 존재: ${TODAY} (skip)"
    else
        rsync -a --delete --link-dest="${CURRENT_MONTH_FULL}/" "${CURRENT_DIR}/media/" "${DAILY_SNAP}/" >> "${LOG_FILE}" 2>&1
        log "일간 스냅 생성: ${TODAY}"
    fi
fi

# 월간 full 정리: 최근 12개월 + 매년 12월치 영구
cleanup_monthly_fulls() {
    local dir=$1 deleted=0
    local now_total=$((10#$YEAR * 12 + 10#$MONTH))
    while IFS= read -r snap; do
        local base snap_yyyymm snap_year snap_month snap_total diff
        base=$(basename "$snap"); snap_yyyymm=${base%_full}
        snap_year=${snap_yyyymm:0:4}; snap_month=${snap_yyyymm:4:2}
        [ "$snap_month" = "12" ] && continue
        snap_total=$((10#$snap_year * 12 + 10#$snap_month))
        diff=$((now_total - snap_total))
        [ "$diff" -gt 12 ] && rm -rf "$snap" && deleted=$((deleted + 1))
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -name "*_full" -type d)
    echo $deleted
}
MONTH_DEL=$(cleanup_monthly_fulls "${MONTHLY_SNAP_DIR}")
[ "${MONTH_DEL}" -gt 0 ] && log "월간 full 정리: ${MONTH_DEL}개 삭제 (12개월 초과, 12월 제외)"

# NAS 스냅트리 동기화 (하드링크 구조 보존)
if timeout 10 test -d "${NAS_DIR}"; then
    NAS_MEDIA_SNAP_DIR="${NAS_DIR}/media_snapshots"
    mkdir -p "${NAS_MEDIA_SNAP_DIR}"
    rsync -aH --no-group --delete "${MEDIA_SNAP_DIR}/" "${NAS_MEDIA_SNAP_DIR}/" >> "${LOG_FILE}" 2>&1
    log "NAS media 스냅트리 동기화 완료 (-H)"
fi

# --- 8. 개발 환경(dev_data) 동기화 (디렉토리 있을 때만) ---
DEV_DATA_DIR="/home/jikhanjung/dev_data/FcSky"
if [ -d "${DEV_DATA_DIR}" ]; then
    cp -f "${CURRENT_DIR}/db.sqlite3" "${DEV_DATA_DIR}/db.sqlite3"
    for ext in wal shm; do
        if [ -f "${CURRENT_DIR}/db.sqlite3-${ext}" ]; then
            cp -f "${CURRENT_DIR}/db.sqlite3-${ext}" "${DEV_DATA_DIR}/db.sqlite3-${ext}"
        else
            rm -f "${DEV_DATA_DIR}/db.sqlite3-${ext}"
        fi
    done
    mkdir -p "${DEV_DATA_DIR}/media"
    rsync -a --delete "${CURRENT_DIR}/media/" "${DEV_DATA_DIR}/media/" >> "${LOG_FILE}" 2>&1
    log "dev_data 동기화 완료: ${DEV_DATA_DIR}"
else
    log "WARN: dev_data 디렉토리 없음 (${DEV_DATA_DIR}) — 건너뜀"
fi

# --- 9. 리포트 ---
DB_SIZE=$(du -sh "${DB_SNAPSHOT}" 2>/dev/null | cut -f1)
MEDIA_SIZE=$(du -sh "${CURRENT_DIR}/media/" 2>/dev/null | cut -f1)
TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
DB_COUNT=$(find "${DB_HISTORY_DIR}" -name "db_*.sqlite3" | wc -l)
MONTHLY_COUNT=$(find "${MONTHLY_SNAP_DIR}" -maxdepth 1 -mindepth 1 -name "*_full" -type d 2>/dev/null | wc -l)
DAILY_COUNT=$(find "${DAILY_SNAP_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
log "리포트: DB=${DB_SIZE}, media=${MEDIA_SIZE}, 월간full=${MONTHLY_COUNT}/일간=${DAILY_COUNT}, 전체=${TOTAL_SIZE}, DB스냅샷=${DB_COUNT}개"
log "========== 백업 완료 =========="
