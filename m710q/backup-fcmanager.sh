#!/bin/bash
# =============================================================================
# FCManager 백업 스크립트 (m710q 개발/백업 호스트에서 실행)
# 운영서버(dolfinid)에서 이 서버로 DB·media·.env 를 SSH pull 하여 보관.
# fsis2026 backup-fsis.sh 를 FCManager 규모로 단순화(단일 DB + media).
#
# ⚠️ 실행본은 /home/jikhanjung/scripts/backup-fcmanager.sh 다(cron 이 그걸 부른다). 이 repo 파일이
#    정본이며, 고치면 **호스트로 복사해야 반영된다** — self-heal 이 없는 유일한 백업 레인이라
#    2026-07-14~15 에 실제로 드리프트했다(repo 사본만 구 DB 경로에 머묾). DEPLOY.md 0.6.24 참조.
#
# cron 등록(m710q): crontab -e →  0 5 * * * /home/jikhanjung/scripts/backup-fcmanager.sh
# 수동 전체 스냅:    /home/jikhanjung/scripts/backup-fcmanager.sh --full-snapshot
#
# 운영서버 접속은 환경변수로 override 가능(기본값은 아래 설정):
#   FCMANAGER_REMOTE_USER, FCMANAGER_REMOTE_HOST, FCMANAGER_REMOTE_PATH
# =============================================================================

set -euo pipefail

FULL_SNAPSHOT=false
if [ "${1:-}" = "--full-snapshot" ]; then
    FULL_SNAPSHOT=true
fi

# --- 설정 ---
REMOTE_USER="${FCMANAGER_REMOTE_USER:-honestjung}"
REMOTE_HOST="${FCMANAGER_REMOTE_HOST:-34.64.158.160}"   # dolfinid
REMOTE_PATH="${FCMANAGER_REMOTE_PATH:-/srv/fcmanager}"
# .env 는 운영 런타임 위치(/srv/fcmanager/.env). 배포 분리 후 compose 도 여기서 실행.
REMOTE_ENV_PATH="${FCMANAGER_REMOTE_ENV:-/srv/fcmanager/.env}"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

BACKUP_DIR="/home/jikhanjung/backups/fcmanager"
NAS_DIR="/nas/JikhanJung/fcmanager_backup"
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
# **라이브 DB 를 scp 로 긁지 않는다**(0.6.24). 운영은 WAL 이라 가동 중에 본체·-wal·-shm 을 따로
# 복사하면 그 사이 체크포인트가 끼어 torn 스냅샷이 된다 — 이 트랙이 30일 로컬·90일 NAS 오프사이트를
# 먹이므로 가장 값진 백업이 가장 검증이 없었다. 대신 운영 hourly backup_db.py 가 online backup API 로
# 뜨고 PRAGMA integrity_check 까지 통과시킨 **일관된 단일 파일**을 가져온다(계약 §백업 레인).
DB_SNAPSHOT="${DB_HISTORY_DIR}/db_${TODAY}.sqlite3"
log "운영 hourly 스냅샷 조회 중..."
SNAP_INFO=$(ssh "${REMOTE}" "f=\$(ls -t ${REMOTE_PATH}/backup/fcmanager_*.sqlite3 2>/dev/null | head -1); \
    [ -n \"\$f\" ] && echo \"\$f \$(( ( \$(date +%s) - \$(stat -c %Y \"\$f\") ) / 60 ))\"" 2>/dev/null || true)
if [ -z "${SNAP_INFO}" ]; then
    log "ERROR: 운영 hourly 스냅샷 없음 (${REMOTE_PATH}/backup/fcmanager_*.sqlite3) — backup_db.py cron 확인"
    exit 1
fi
REMOTE_SNAP=${SNAP_INFO%% *}
SNAP_AGE_MIN=${SNAP_INFO##* }
# 신선도 게이트: 매시 도는 백업이 2시간 넘게 낡았다 = cron 중단, 또는 **무결성 게이트가 채택을 막는 중**.
# 후자는 운영 DB 손상 신호다. 배포 때만 도는 smoke/센티넬과 달리 이 경로는 **매일** 사람에게 닿는다
# (실패 시 telegram) — 배포가 뜸해도 탐지가 뜸해지지 않게 하는 두 번째 채널.
if [ "${SNAP_AGE_MIN}" -gt 120 ]; then
    log "ERROR: 운영 최신 스냅샷이 ${SNAP_AGE_MIN}분 전 것(>2h). hourly 중단 또는 무결성 게이트가 채택 차단 중 — ${REMOTE}:${REMOTE_PATH}/db/INTEGRITY_FAIL 과 backup/backup.log 확인"
    exit 1
fi
log "최신 스냅샷: $(basename "${REMOTE_SNAP}") (${SNAP_AGE_MIN}분 전)"
if ! scp -q "${REMOTE}:${REMOTE_SNAP}" "${DB_SNAPSHOT}.tmp"; then
    rm -f "${DB_SNAPSHOT}.tmp"
    log "ERROR: DB 스냅샷 pull 실패 (${REMOTE}:${REMOTE_SNAP})"
    exit 1
fi
# 채택 전 검증(계약 MUST) — 전송 손상까지 여기서 걸린다. 실패하면 아래 cleanup_tiered 에 **도달하지
# 않는다**: 새 스냅샷 없이 과거를 지우면 30일/90일 보관 창이 소리 없이 깎인다.
#
# 검사 커넥션을 **읽기 전용으로 열지 않는다**: 스냅샷이 WAL 모드면(0.6.24 이전 backup_db.py 가 뜬 것,
# 또는 소스 저널 모드를 물려받은 것) mode=ro 리더는 -shm 을 만들어놓고 **치울 권한이 없어** 매시 고아를
# 남긴다 — 이름이 `*.tmp-shm` 이라 cleanup_tiered 의 glob(`db_*.sqlite3`)에도 안 걸려 영구 누적된다
# (cdGTS devlog 150 §10 이 실측으로 잡은 함정. 이 스크립트도 첫 실행에서 그대로 재현했다).
# 대상은 우리가 방금 받은 임시 파일이지 라이브 DB 가 아니므로 rw 로 여는 게 맞다: 마지막 커넥션이
# 정상 종료하면 sqlite 가 -wal/-shm 을 스스로 지우고, journal_mode=DELETE 로 내려 **아카이브가
# 운영 코드 버전과 무관하게 항상 단일 파일**이 되게 한다.
# 여기서 **반출 위생도 한 번 더** 건다(방어적, 0.6.25): 운영 backup_db.py 가 이미 django_session 을
# 지우고 내보내지만, 그건 **상대 코드 버전에 기댄 가정**이다(구버전 운영·수동 스냅샷·타 호스트).
# 이 스크립트가 바로 그 사본을 NAS(0777·90일)와 테스트 컨테이너로 밀어넣는 당사자라, 신뢰 경계를
# 넘기 직전인 여기서 자기 책임으로 확인한다. 이미 깨끗하면 0행 삭제 = 무해.
# (오늘의 교훈 동형: "생산자만 고치면 끝이 아니다" — 소비자도 자기 보장을 가져야 한다.)
# 출력 규약 = 마지막 줄 `<integrity>|<제거행수>`. 2>&1 로 예외 메시지를 잡으므로 **파이썬이
# stdout/stderr 에 다른 걸 찍으면 안 된다**(찍으면 그 잡음이 그대로 판정 문자열이 된다).
SANITIZE_OUT=$(python3 -c "
import sqlite3
conn = sqlite3.connect('${DB_SNAPSHOT}.tmp')
result = conn.execute('PRAGMA integrity_check').fetchone()[0]
removed = 0
if result == 'ok':
    has = conn.execute(\"SELECT count(*) FROM sqlite_master WHERE type='table' AND name='django_session'\").fetchone()[0]
    if has:
        removed = conn.execute('SELECT count(*) FROM django_session').fetchone()[0]
        if removed:
            conn.execute('DELETE FROM django_session')
            conn.commit()
    conn.execute('PRAGMA journal_mode=DELETE')   # 아카이브에 동시 writer 는 없다 — WAL 일 이유가 없다
    conn.execute('VACUUM')                       # free page 제거(secure_delete 기본값에 기대지 않는 보장)
conn.close()
print(f'{result}|{removed}')" 2>&1) || SANITIZE_OUT="열기/PRAGMA 실패: ${SANITIZE_OUT}|0"
LAST_LINE=${SANITIZE_OUT##*$'\n'}
INTEGRITY=${LAST_LINE%%|*}
SESSIONS_REMOVED=${LAST_LINE##*|}
rm -f "${DB_SNAPSHOT}.tmp-wal" "${DB_SNAPSHOT}.tmp-shm"   # 위가 중간에 죽었을 때의 안전망
if [ "${INTEGRITY}" != "ok" ]; then
    rm -f "${DB_SNAPSHOT}.tmp"
    log "ERROR: pull 한 스냅샷이 integrity_check 실패 (${INTEGRITY}) — 미채택, 과거 스냅샷 보존"
    exit 1
fi
mv -f "${DB_SNAPSHOT}.tmp" "${DB_SNAPSHOT}"
# 구 실행(라이브 scp 시절)이 남긴 형제 파일 제거 — 남겨두면 새 본체에 낡은 -wal 이 얹힌 꼴이 된다.
rm -f "${DB_SNAPSHOT}-wal" "${DB_SNAPSHOT}-shm"
log "DB 스냅샷 완료: ${DB_SNAPSHOT} (integrity ok, 단일 파일, 반출 위생: 세션 ${SESSIONS_REMOVED}행 제거)"

DELETED=$(cleanup_tiered "${DB_HISTORY_DIR}" "db_*.sqlite3" "db_" "sqlite3" ${LOCAL_DAILY_DAYS})
[ "${DELETED}" -gt 0 ] && log "로컬 DB 정리: ${DELETED}개 삭제 (${LOCAL_DAILY_DAYS}일 초과, 월초/연말 보존)"

# --- 2. media/ 미러링 ---
log "media/ 동기화 중..."
rsync -az --delete "${REMOTE}:${REMOTE_PATH}/media/" "${CURRENT_DIR}/media/" >> "${LOG_FILE}" 2>&1
log "media/ 동기화 완료"

# --- 3. .env 백업 ---
# 배포 구조 분리(devlog 050) 후 .env 는 운영 런타임 위치 /srv/fcmanager/.env 에 있다
# (호스트가 직접 관리, sync 대상 아님). FCMANAGER_REMOTE_ENV 로 override.
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
# 스냅샷은 단일 파일 — 종전(라이브 scp) 실행이 남긴 형제 파일을 반드시 치운다. 남기면 새 본체 옆에
# 낡은 -wal 이 붙은 상태가 된다.
rm -f "${CURRENT_DIR}/db.sqlite3-wal" "${CURRENT_DIR}/db.sqlite3-shm"
log "current/db.sqlite3 동기화 완료 (단일 파일)"

# --- 6. NAS 백업 (마운트돼 있을 때만) ---
if timeout 10 test -d "${NAS_DIR}"; then
    NAS_DB_DIR="${NAS_DIR}/db_history"
    NAS_CURRENT="${NAS_DIR}/current"
    mkdir -p "${NAS_DB_DIR}" "${NAS_CURRENT}"
    cp "${DB_SNAPSHOT}" "${NAS_DB_DIR}/db_${TODAY}.sqlite3"
    rm -f "${NAS_DB_DIR}/db_${TODAY}.sqlite3-wal" "${NAS_DB_DIR}/db_${TODAY}.sqlite3-shm" \
          "${NAS_CURRENT}/db.sqlite3-wal" "${NAS_CURRENT}/db.sqlite3-shm"   # 단일 파일 — 잔재 제거
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

# --- 8. m710q 테스트 타깃(/srv/fcmanager, :8005 컨테이너) DB 갱신 ---
# 종전엔 ~/dev_data/fcmanager 를 채웠으나(runserver 런처용) 테스트는 도커 타깃으로 일원화했다
# (0.6.24) — 미러가 둘이면 드리프트만 는다.
#
# ⚠️ 여기가 cdGTS devlog 149 가 데인 자리다: 테스트 컨테이너는 이 DB 를 **WAL 로 쥐고 있고**,
#    쥔 채로 파일을 갈면 캐시 페이지와 어긋나 btree 가 깨진다(그때 테스트 DB 2회 손상, 9h 미탐지).
#    그래서 전 서비스 정지 → 교체 → 재기동으로 쓰기 주체를 직렬화하고, **정지에 실패하면 교체하지
#    않는다**(라이브 교체 금지). `docker compose down` 에 서비스명을 쓰지 않는 것도 같은 교훈 —
#    사이드카가 생기면 그것만 남아 같은 버그가 재발한다(계약 §규범 MUST).
TEST_ROOT="/srv/fcmanager"
if [ ! -d "${TEST_ROOT}/db" ]; then
    log "WARN: 테스트 타깃 없음 (${TEST_ROOT}/db) — 건너뜀"
elif ! command -v docker >/dev/null 2>&1 || [ ! -f "${TEST_ROOT}/docker-compose.yml" ]; then
    log "WARN: docker/compose 없음 — 테스트 타깃 DB 갱신 건너뜀(라이브 교체 금지)"
elif ! (cd "${TEST_ROOT}" && docker compose down) >> "${LOG_FILE}" 2>&1; then
    log "WARN: 테스트 컨테이너 정지 실패 — DB 교체 건너뜀(라이브 교체 금지)"
else
    cp -f "${DB_SNAPSHOT}" "${TEST_ROOT}/db/db.sqlite3"
    # 정지 전 컨테이너가 남긴 형제 파일 제거 — 새 본체에 낡은 -wal 이 얹히면 그것 자체가 손상이다.
    rm -f "${TEST_ROOT}/db/db.sqlite3-wal" "${TEST_ROOT}/db/db.sqlite3-shm"
    mkdir -p "${TEST_ROOT}/media"
    rsync -a --delete "${CURRENT_DIR}/media/" "${TEST_ROOT}/media/" >> "${LOG_FILE}" 2>&1
    if (cd "${TEST_ROOT}" && docker compose up -d) >> "${LOG_FILE}" 2>&1; then
        log "테스트 타깃 갱신 완료: ${TEST_ROOT} (정지→교체→재기동)"
    else
        log "ERROR: 테스트 컨테이너 재기동 실패 — DB 는 교체됨, ${TEST_ROOT} 에서 docker compose up -d 확인"
    fi
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
