#!/bin/bash
# =============================================================================
# EarthThruTime3D 백업 스크립트 (m710q 에서 하루 한 번)
#
# 이 프로젝트의 자료는 DB 가 아니라 파일이다. 운영 서버(dolfinid)의 DB 에는 관리자 계정과
# 세션뿐이고, 지질 자료는 개발 호스트(여기) 의 data/ 에서 만들어 배포 묶음으로 올라간다.
# 그래서 지킬 것은 두 가지다.
#   1. 여기 data/sources (원본 아카이브 3.6 GB, 다시 받을 수는 있다) 와 data/derived
#      (파생 자료, 다시 만드는 데 한 시간) → NAS 에 미러.
#   2. dolfinid 의 검증된 DB 스냅샷(backups/db-*.sqlite3, 매시 online-backup) 과
#      .env.django(비밀키·접근 키) → 로컬 + NAS, 날짜별 보관.
# backup-fcmanager.sh 의 구조를 따르되 테스트 컨테이너 갱신은 없다.
#
# cron 등록(m710q): crontab -e →  20 4 * * * /home/jikhanjung/scripts/backup-earththrutime.sh
# =============================================================================

set -euo pipefail

# --- 설정 ---
REMOTE="${ETT_REMOTE:-dolfinid}"                    # ~/.ssh/config 별칭 (honestjung@34.64.158.160)
REMOTE_PATH="${ETT_REMOTE_PATH:-/srv/earththrutime3d}"
PROJECT_DIR="/home/jikhanjung/projects/EarthThruTime3D"

BACKUP_DIR="/home/jikhanjung/backups/earththrutime3d"
NAS_DIR="/nas/JikhanJung/earththrutime3d_backup"
DB_HISTORY_DIR="${BACKUP_DIR}/db_history"
CURRENT_DIR="${BACKUP_DIR}/current"
LOG_FILE="${BACKUP_DIR}/backup.log"

LOCAL_DAILY_DAYS=30
NAS_DAILY_DAYS=90

mkdir -p "${DB_HISTORY_DIR}" "${CURRENT_DIR}"

# --- 실패 시 Telegram 알림 ---
NOTIFY="/home/jikhanjung/scripts/notify-telegram.sh"
notify_fail() {
    [ -x "$NOTIFY" ] && "$NOTIFY" "⚠️ $(basename "$0") 실패: $1" >/dev/null 2>&1 || true
}
trap 'rc=$?; [ "$rc" -ne 0 ] && notify_fail "비정상 종료 (exit $rc)"; true' EXIT

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
    case "$1" in *ERROR*) notify_fail "$1" ;; esac
}

# 계층형 정리: N일 초과 → 매달 1일만 보관, 12월 1일은 영구. 파일명 <prefix>YYYYMMDD.<ext>
cleanup_tiered() {
    local dir=$1 pattern=$2 prefix=$3 ext=$4 daily_days=$5
    local deleted=0
    while IFS= read -r file; do
        local base datestr month day
        base=$(basename "$file")
        datestr=${base#${prefix}}
        datestr=${datestr%.${ext}}
        month=${datestr:4:2}; day=${datestr:6:2}
        [ "$month" = "12" ] && [ "$day" = "01" ] && continue
        [ "$day" = "01" ] && continue
        rm -f "$file"
        ((deleted++)) || true
    done < <(find "$dir" -name "$pattern" -mtime +${daily_days} 2>/dev/null)
    echo $deleted
}

log "========== 백업 시작 =========="
TODAY=$(date +%Y%m%d)

# --- 1. dolfinid DB 스냅샷 (검증된 online-backup 최신본; 라이브 DB 는 긁지 않는다) ---
if ! LATEST_DB=$(ssh -q -o BatchMode=yes -o ConnectTimeout=15 "${REMOTE}" \
        "ls -1t ${REMOTE_PATH}/backups/db-*.sqlite3 2>/dev/null | head -1"); then
    log "ERROR: dolfinid ssh 접속 실패 (${REMOTE})"
    exit 1
fi
DB_SNAPSHOT="${DB_HISTORY_DIR}/db_${TODAY}.sqlite3"
if [ -n "${LATEST_DB}" ] && scp -q "${REMOTE}:${LATEST_DB}" "${DB_SNAPSHOT}"; then
    if sqlite3 "${DB_SNAPSHOT}" "PRAGMA integrity_check;" 2>/dev/null | grep -qx ok; then
        log "DB 스냅샷 완료: ${DB_SNAPSHOT##*/} ← ${LATEST_DB##*/} (integrity ok)"
        cp -f "${DB_SNAPSHOT}" "${CURRENT_DIR}/db.sqlite3"
    else
        log "ERROR: DB 스냅샷 무결성 검사 실패 (${LATEST_DB##*/}) — 채택하지 않음"
        rm -f "${DB_SNAPSHOT}"
        exit 1
    fi
else
    log "ERROR: DB 스냅샷 없음 또는 복사 실패 (dolfinid backups/db-*.sqlite3)"
    exit 1
fi
DEL=$(cleanup_tiered "${DB_HISTORY_DIR}" "db_*.sqlite3" "db_" "sqlite3" ${LOCAL_DAILY_DAYS})
[ "${DEL}" -gt 0 ] && log "로컬 DB 정리: ${DEL}개 삭제"

# --- 2. .env.django (비밀키·접근 키; 600 유지) ---
if scp -q "${REMOTE}:${REMOTE_PATH}/.env.django" "${CURRENT_DIR}/.env.django" 2>/dev/null; then
    chmod 600 "${CURRENT_DIR}/.env.django"
    log ".env.django 복사 완료"
else
    log "WARN: .env.django 복사 실패"
fi

# --- 3. NAS ---
if timeout 10 test -d "$(dirname "${NAS_DIR}")"; then
    mkdir -p "${NAS_DIR}/db_history" "${NAS_DIR}/current" "${NAS_DIR}/data"
    cp -f "${DB_SNAPSHOT}" "${NAS_DIR}/db_history/db_${TODAY}.sqlite3"
    cp -f "${DB_SNAPSHOT}" "${NAS_DIR}/current/db.sqlite3"
    [ -f "${CURRENT_DIR}/.env.django" ] && cp -f "${CURRENT_DIR}/.env.django" "${NAS_DIR}/current/.env.django"
    NDEL=$(cleanup_tiered "${NAS_DIR}/db_history" "db_*.sqlite3" "db_" "sqlite3" ${NAS_DAILY_DAYS})
    [ "${NDEL}" -gt 0 ] && log "NAS DB 정리: ${NDEL}개 삭제"

    # 개발 호스트의 자료를 미러한다. sources 는 발행처 아카이브(불변), derived 는 스크립트 산출물.
    # --delete 로 여기와 같게 둔다: 여기서 지운 파생 자료는 NAS 에서도 사라진다 (미러이지 이력이
    # 아니다 — 이력이 필요한 것은 git 에 있는 sources/·annotations/ 매니페스트다).
    for track in sources derived; do
        if [ -d "${PROJECT_DIR}/data/${track}" ]; then
            rsync -a --no-group --delete "${PROJECT_DIR}/data/${track}/" "${NAS_DIR}/data/${track}/" >> "${LOG_FILE}" 2>&1
            log "NAS data/${track} 미러 완료 ($(du -sh "${PROJECT_DIR}/data/${track}" | cut -f1))"
        else
            log "WARN: ${PROJECT_DIR}/data/${track} 없음"
        fi
    done
    # 최신 릴리스 묶음 하나: 개발 호스트 없이도 서버에 다시 올릴 수 있게.
    LATEST_SUMS=$(ls -1t "${PROJECT_DIR}"/dist/SHA256SUMS-v* 2>/dev/null | head -1 || true)
    if [ -n "${LATEST_SUMS}" ]; then
        VER=${LATEST_SUMS##*SHA256SUMS-}
        mkdir -p "${NAS_DIR}/release"
        rsync -a --no-group --delete --include="*${VER}*" --exclude="*" "${PROJECT_DIR}/dist/" "${NAS_DIR}/release/" >> "${LOG_FILE}" 2>&1
        log "NAS 릴리스 묶음: ${VER}"
    fi
    log "NAS 백업 완료"
else
    log "ERROR: NAS 마운트 없음 ($(dirname "${NAS_DIR}"))"
    exit 1
fi

NAS_TOTAL=$(timeout 30 du -sh "${NAS_DIR}" 2>/dev/null | cut -f1 || echo "N/A")
log "리포트: 로컬 DB 스냅샷 $(find "${DB_HISTORY_DIR}" -name 'db_*.sqlite3' | wc -l)개, NAS 전체=${NAS_TOTAL}"
log "========== 백업 완료 =========="
