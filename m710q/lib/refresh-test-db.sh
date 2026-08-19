#!/bin/bash
# =============================================================================
# refresh_test_db <container> <src_snapshot>
#
# 로컬(m710q) 테스트 컨테이너의 DB 를 그날 받은 운영 스냅샷으로 갈아끼운다.
# backup-fsis.sh / backup-ghdb.sh 가 공유한다 — 규칙이 한 호출자에만 살면 갈라진다.
#
# 호스트 경로를 하드코딩하지 않는다. 2026-07-14 에 추가된 fsis 7.5 단계는
# `/srv/fsis2026/db.sqlite3` 를 박아두고 있었는데, 그 뒤 컨테이너가 디렉터리 마운트
# (`/srv/fsis2026/db` → `/app/hostdb`)로 바뀌면서 **아무도 읽지 않는 파일**에 매일
# 복사하며 "갱신 완료" 로그를 찍었다. 2026-08-19 에 발각될 때까지 테스트 컨테이너는
# 6/29 자 DB(P33 이관 전, MuseumSpecimen 817)로 돌고 있었다.
# → 컨테이너의 DATABASE_PATH 를 읽어 마운트로 역매핑하고, 복사 후 cmp 로 검증한다.
#   마운트가 또 바뀌면 조용히 빗나가는 대신 ERROR(=telegram)로 터진다.
#
# 호출자에 `log()` 가 정의돼 있어야 한다 (ERROR 문자열이면 알림 발송).
# 컨테이너 가동 중 파일 교체 금지 — dual-writer, devlog 074. 정지 → 복사 → 재시작.
# =============================================================================

refresh_test_db() {
    local container="$1" src="$2"

    if ! command -v docker >/dev/null 2>&1; then
        log "WARN: docker 없음 — 테스트 DB 갱신 건너뜀"
        return 0
    fi
    if ! docker inspect "${container}" >/dev/null 2>&1; then
        log "WARN: 테스트 컨테이너(${container}) 없음 — 테스트 DB 갱신 건너뜀"
        return 0
    fi
    if [ ! -f "${src}" ]; then
        log "ERROR: 테스트 DB 소스 없음 (${src}) — 갱신 건너뜀"
        return 0
    fi

    # 1) 컨테이너가 실제로 여는 DB 경로
    local cpath
    cpath=$(docker inspect "${container}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
            | sed -n 's/^DATABASE_PATH=//p' | head -1)
    if [ -z "${cpath}" ]; then
        log "ERROR: ${container} 에 DATABASE_PATH 없음 — 테스트 DB 갱신 불가"
        return 0
    fi

    # 2) 컨테이너 경로 → 호스트 경로 역매핑 (최장 일치 바인드 마운트)
    local dest="" best=0 mdst msrc rest
    while IFS=$'\t' read -r mdst msrc; do
        [ -n "${mdst}" ] || continue
        case "${cpath}" in
            "${mdst}"/*)
                if [ ${#mdst} -gt ${best} ]; then
                    best=${#mdst}
                    rest=${cpath#"${mdst}"}
                    dest="${msrc}${rest}"
                fi
                ;;
        esac
    done < <(docker inspect "${container}" \
             --format '{{range .Mounts}}{{.Destination}}{{"\t"}}{{.Source}}{{"\n"}}{{end}}')

    if [ -z "${dest}" ]; then
        log "ERROR: ${container} 의 DB(${cpath})가 바인드 마운트 밖 — 컨테이너 내부 레이어? 갱신 불가"
        return 0
    fi

    # 3) 정지 → 복사 → 검증 → 재시작
    local was_running=0
    if [ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null)" = "true" ]; then
        if docker stop "${container}" >/dev/null 2>&1; then
            was_running=1
        else
            log "WARN: 테스트 컨테이너(${container}) 정지 실패 — 갱신 건너뜀 (가동 중 교체 금지)"
            return 0
        fi
    fi

    if cp -f "${src}" "${dest}"; then
        # 일관 스냅샷엔 wal/shm 이 없다 — 신선 DB 옆 낡은 WAL 은 손상 위험
        if [ -f "${src}-wal" ]; then cp -f "${src}-wal" "${dest}-wal"; else rm -f "${dest}-wal"; fi
        if [ -f "${src}-shm" ]; then cp -f "${src}-shm" "${dest}-shm"; else rm -f "${dest}-shm"; fi

        if cmp -s "${src}" "${dest}"; then
            log "테스트 서버 DB 갱신 완료: ${container} (${cpath} → ${dest})"
        else
            log "ERROR: 테스트 DB 복사 검증 실패 — ${dest} 가 ${src} 와 다름"
        fi
    else
        log "ERROR: 테스트 서버 DB 갱신 실패 (복사 오류: ${dest})"
    fi

    if [ "${was_running}" -eq 1 ]; then
        if docker start "${container}" >/dev/null 2>&1; then
            log "테스트 컨테이너(${container}) 재시작 완료"
        else
            log "ERROR: 테스트 컨테이너(${container}) 재시작 실패"
        fi
    fi
    return 0
}
