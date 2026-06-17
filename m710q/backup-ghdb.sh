#!/bin/bash
# =============================================================================
# GHDB 백업 스크립트
# 운영서버(GCP)에서 이 서버로 데이터를 pull하여 백업
# cron 등록: crontab -e → 30 3 * * * /home/jikhanjung/scripts/backup-ghdb.sh
# 수동 전체 백업: /home/jikhanjung/scripts/backup-ghdb.sh --full-snapshot
# =============================================================================

set -euo pipefail

FULL_SNAPSHOT=false
if [ "${1:-}" = "--full-snapshot" ]; then
    FULL_SNAPSHOT=true
fi

# --- 설정 ---
REMOTE_USER="honestjung"
REMOTE_HOST="34.64.158.160"
REMOTE_PATH="/srv/ghdb"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

BACKUP_DIR="/home/jikhanjung/backups/ghdb"
NAS_DIR="/nas/JikhanJung/ghdb_backup"
DB_HISTORY_DIR="${BACKUP_DIR}/db_history"
CURRENT_DIR="${BACKUP_DIR}/current"
LOG_FILE="${BACKUP_DIR}/backup.log"

LOCAL_DAILY_DAYS=30
NAS_DAILY_DAYS=90

# --- 초기화 ---
mkdir -p "${DB_HISTORY_DIR}" "${CURRENT_DIR}"

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
# 파일명 패턴: db_YYYYMMDD.sqlite3
cleanup_ghdb_db() {
    local dir=$1
    local daily_days=$2
    local deleted=0

    while IFS= read -r file; do
        local base=$(basename "$file")
        local datestr=${base#db_}
        datestr=${datestr%.sqlite3}
        local month=${datestr:4:2}
        local day=${datestr:6:2}

        # 12월 1일: 영구 보관 (연간 아카이브)
        [ "$month" = "12" ] && [ "$day" = "01" ] && continue

        # 매달 1일: 보관
        [ "$day" = "01" ] && continue

        # 나머지: 삭제 (WAL/SHM 부속 파일도 함께)
        rm -f "$file" "${file}-wal" "${file}-shm"
        ((deleted++))
    done < <(find "$dir" -name "db_*.sqlite3" ! -name "*-wal" ! -name "*-shm" -mtime +${daily_days} 2>/dev/null)

    echo $deleted
}

log "========== GHDB 백업 시작 =========="

# --- 1. DB 스냅샷 (날짜별 보관) ---
TODAY=$(date +%Y%m%d)
DB_SNAPSHOT="${DB_HISTORY_DIR}/db_${TODAY}.sqlite3"

log "DB 스냅샷 복사 중..."
if scp -q "${REMOTE}:${REMOTE_PATH}/db_ghdb.sqlite3" "${DB_SNAPSHOT}"; then
    # WAL 모드 부속 파일도 함께 복사
    scp -q "${REMOTE}:${REMOTE_PATH}/db_ghdb.sqlite3-wal" "${DB_SNAPSHOT}-wal" 2>/dev/null || true
    scp -q "${REMOTE}:${REMOTE_PATH}/db_ghdb.sqlite3-shm" "${DB_SNAPSHOT}-shm" 2>/dev/null || true
    log "DB 스냅샷 완료: ${DB_SNAPSHOT} (+wal/shm)"
else
    log "ERROR: DB 스냅샷 실패"
    exit 1
fi

# 로컬 DB 정리 (N일 초과 → 월초만 보관, 12/01 영구)
DELETED=$(cleanup_ghdb_db "${DB_HISTORY_DIR}" ${LOCAL_DAILY_DAYS})
if [ "${DELETED}" -gt 0 ]; then
    log "로컬 DB 정리: ${DELETED}개 삭제 (${LOCAL_DAILY_DAYS}일 초과, 월초/연말 보존)"
fi

# --- 2. uploads/ 미러링 ---
log "uploads/ 동기화 중..."
rsync -az --delete \
    "${REMOTE}:${REMOTE_PATH}/uploads/" \
    "${CURRENT_DIR}/uploads/" \
    >> "${LOG_FILE}" 2>&1
log "uploads/ 동기화 완료"

# --- 3. .env 백업 ---
log ".env 복사 중..."
scp -q "${REMOTE}:${REMOTE_PATH}/.env" "${CURRENT_DIR}/.env" 2>/dev/null && \
    log ".env 복사 완료" || \
    log "WARN: .env 파일 없음 (건너뜀)"

# --- 4. 현재 DB도 current/에 동기화 ---
cp "${DB_SNAPSHOT}" "${CURRENT_DIR}/db_ghdb.sqlite3"
cp -f "${DB_SNAPSHOT}-wal" "${CURRENT_DIR}/db_ghdb.sqlite3-wal" 2>/dev/null || true
cp -f "${DB_SNAPSHOT}-shm" "${CURRENT_DIR}/db_ghdb.sqlite3-shm" 2>/dev/null || true
log "current/db_ghdb.sqlite3 동기화 완료 (+wal/shm)"

# --- 5. NAS 백업 ---
if timeout 10 test -d "${NAS_DIR}"; then
    NAS_DB_DIR="${NAS_DIR}/db_history"
    NAS_CURRENT="${NAS_DIR}/current"
    mkdir -p "${NAS_DB_DIR}" "${NAS_CURRENT}"

    # NAS DB 스냅샷
    cp "${DB_SNAPSHOT}" "${NAS_DB_DIR}/db_${TODAY}.sqlite3"
    cp -f "${DB_SNAPSHOT}-wal" "${NAS_DB_DIR}/db_${TODAY}.sqlite3-wal" 2>/dev/null || true
    cp -f "${DB_SNAPSHOT}-shm" "${NAS_DB_DIR}/db_${TODAY}.sqlite3-shm" 2>/dev/null || true
    log "NAS DB 스냅샷 완료 (+wal/shm)"

    # NAS uploads 미러링
    rsync -az --no-group --delete "${CURRENT_DIR}/uploads/" "${NAS_CURRENT}/uploads/" >> "${LOG_FILE}" 2>&1
    log "NAS uploads 동기화 완료"

    # NAS .env
    [ -f "${CURRENT_DIR}/.env" ] && cp "${CURRENT_DIR}/.env" "${NAS_CURRENT}/.env"
    cp "${DB_SNAPSHOT}" "${NAS_CURRENT}/db_ghdb.sqlite3"
    cp -f "${DB_SNAPSHOT}-wal" "${NAS_CURRENT}/db_ghdb.sqlite3-wal" 2>/dev/null || true
    cp -f "${DB_SNAPSHOT}-shm" "${NAS_CURRENT}/db_ghdb.sqlite3-shm" 2>/dev/null || true

    # NAS DB 정리 (N일 초과 → 월초만 보관, 12/01 영구)
    NAS_DEL=$(cleanup_ghdb_db "${NAS_DB_DIR}" ${NAS_DAILY_DAYS})
    if [ "${NAS_DEL}" -gt 0 ]; then
        log "NAS DB 정리: ${NAS_DEL}개 삭제 (${NAS_DAILY_DAYS}일 초과, 월초/연말 보존)"
    fi
    log "NAS 백업 완료"
else
    log "WARN: NAS 디렉토리 없음 (${NAS_DIR})"
fi

# --- 6. uploads 계층형 스냅샷 (월간 full + 일간 link-dest) ---
#   - 매월 1일: 신규 월간 full 생성 (직전 월 full 을 --link-dest 로 걸어 inode 공유)
#               동시에 지난 달 daily 일괄 삭제
#   - 그 외 날짜: 이번 달 full 을 link-dest 로 일간 스냅 생성
#   - 보관: 월간 full 최근 12개월 + 매년 12월치 영구 / 일간은 현재 달만
#   - NAS 는 rsync -aH 로 하드링크 구조 보존하며 전체 스냅트리 미러
DAY=$(date +%d)
MONTH=$(date +%m)
YEAR=$(date +%Y)
YYYYMM=$(date +%Y%m)

UPLOADS_SNAP_DIR="${BACKUP_DIR}/uploads_snapshots"
MONTHLY_SNAP_DIR="${UPLOADS_SNAP_DIR}/monthly"
DAILY_SNAP_DIR="${UPLOADS_SNAP_DIR}/daily"
mkdir -p "${MONTHLY_SNAP_DIR}" "${DAILY_SNAP_DIR}"

CURRENT_MONTH_FULL="${MONTHLY_SNAP_DIR}/${YYYYMM}_full"

if [ "$FULL_SNAPSHOT" = true ] || [ "$DAY" = "01" ] || [ ! -d "${CURRENT_MONTH_FULL}" ]; then
    # 월간 full 생성 (신월/부트스트랩/강제)
    PREV_FULL=$(find "${MONTHLY_SNAP_DIR}" -maxdepth 1 -mindepth 1 -name "*_full" -type d ! -path "${CURRENT_MONTH_FULL}" | sort | tail -1)
    if [ -n "${PREV_FULL}" ]; then
        rsync -a --delete --link-dest="${PREV_FULL}/" \
            "${CURRENT_DIR}/uploads/" "${CURRENT_MONTH_FULL}/" >> "${LOG_FILE}" 2>&1
        log "월간 full 생성 (link-dest=$(basename ${PREV_FULL})): ${YYYYMM}_full"
    else
        rsync -a --delete \
            "${CURRENT_DIR}/uploads/" "${CURRENT_MONTH_FULL}/" >> "${LOG_FILE}" 2>&1
        log "월간 full 생성 (최초): ${YYYYMM}_full"
    fi

    # 새 달 시작: 지난 달 daily 일괄 삭제
    if [ "$DAY" = "01" ]; then
        PREV_YYYYMM=$(date -d "yesterday" +%Y%m)
        DEL_DAILY=0
        for daily_snap in "${DAILY_SNAP_DIR}"/${PREV_YYYYMM}*; do
            if [ -d "${daily_snap}" ]; then
                rm -rf "${daily_snap}"
                DEL_DAILY=$((DEL_DAILY + 1))
            fi
        done
        [ "${DEL_DAILY}" -gt 0 ] && log "지난 달(${PREV_YYYYMM}) daily 삭제: ${DEL_DAILY}개"
    fi
else
    # 일간 스냅 (2~31일): 이번 달 full 을 --link-dest 로
    DAILY_SNAP="${DAILY_SNAP_DIR}/${TODAY}"
    if [ -d "${DAILY_SNAP}" ]; then
        log "일간 스냅 이미 존재: ${TODAY} (skip)"
    else
        rsync -a --delete --link-dest="${CURRENT_MONTH_FULL}/" \
            "${CURRENT_DIR}/uploads/" "${DAILY_SNAP}/" >> "${LOG_FILE}" 2>&1
        log "일간 스냅 생성: ${TODAY}"
    fi
fi

# 월간 full 정리: 최근 12개월 + 매년 12월치 영구
cleanup_monthly_fulls() {
    local dir=$1
    local deleted=0
    local now_total=$((10#$YEAR * 12 + 10#$MONTH))

    while IFS= read -r snap; do
        local base=$(basename "$snap")
        local snap_yyyymm=${base%_full}
        local snap_year=${snap_yyyymm:0:4}
        local snap_month=${snap_yyyymm:4:2}

        # 12월치 영구 보관 (연간 아카이브)
        [ "$snap_month" = "12" ] && continue

        local snap_total=$((10#$snap_year * 12 + 10#$snap_month))
        local diff=$((now_total - snap_total))

        if [ "$diff" -gt 12 ]; then
            rm -rf "$snap"
            deleted=$((deleted + 1))
        fi
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -name "*_full" -type d)

    echo $deleted
}

MONTH_DEL=$(cleanup_monthly_fulls "${MONTHLY_SNAP_DIR}")
[ "${MONTH_DEL}" -gt 0 ] && log "월간 full 정리: ${MONTH_DEL}개 삭제 (12개월 초과, 12월 제외)"

# NAS 스냅트리 동기화 (하드링크 구조 보존)
if timeout 10 test -d "${NAS_DIR}"; then
    NAS_UPLOADS_SNAP_DIR="${NAS_DIR}/uploads_snapshots"
    mkdir -p "${NAS_UPLOADS_SNAP_DIR}"
    rsync -aH --no-group --delete \
        "${UPLOADS_SNAP_DIR}/" "${NAS_UPLOADS_SNAP_DIR}/" >> "${LOG_FILE}" 2>&1
    log "NAS uploads 스냅트리 동기화 완료 (-H)"
fi

# --- 7. 백업 크기 리포트 ---
DB_SIZE=$(du -sh "${DB_SNAPSHOT}" 2>/dev/null | cut -f1)
UPLOADS_SIZE=$(du -sh "${CURRENT_DIR}/uploads/" 2>/dev/null | cut -f1)
TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
DB_COUNT=$(find "${DB_HISTORY_DIR}" -name "db_*.sqlite3" | wc -l)

NAS_TOTAL="N/A"
NAS_DB_COUNT=0
if timeout 10 test -d "${NAS_DIR}"; then
    NAS_TOTAL=$(du -sh "${NAS_DIR}" 2>/dev/null | cut -f1 || echo "N/A")
    NAS_DB_COUNT=$(find "${NAS_DIR}/db_history" -name "db_*.sqlite3" 2>/dev/null | wc -l)
fi

MONTHLY_COUNT=$(find "${MONTHLY_SNAP_DIR}" -maxdepth 1 -mindepth 1 -name "*_full" -type d 2>/dev/null | wc -l)
DAILY_COUNT=$(find "${DAILY_SNAP_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
SNAP_SIZE=$(du -sh "${UPLOADS_SNAP_DIR}" 2>/dev/null | cut -f1 || echo "0")

log "리포트: 로컬 DB=${DB_SIZE}, uploads=${UPLOADS_SIZE}, 월간full=${MONTHLY_COUNT}/일간=${DAILY_COUNT}(${SNAP_SIZE}), 전체=${TOTAL_SIZE}, DB스냅샷=${DB_COUNT}개"
log "리포트: NAS 전체=${NAS_TOTAL}, DB스냅샷=${NAS_DB_COUNT}개"
log "========== GHDB 백업 완료 =========="
