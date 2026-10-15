#!/bin/bash
# Standalone portable BloodHound Legacy (4.3.1). Native Neo4j 4.4 + JRE + GUI, all inside ./bhl next to this script.
# First run downloads and configures everything; afterwards the folder works offline and can be moved.
# Usage: ./bloodhound-legacy.sh {up|gui|start|stop|status|setup|clean}
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bhl"
password="${BHL_NEO4J_PASSWORD:-bloodhound}"
bolt_port="${BHL_BOLT_PORT:-7687}"
http_port="${BHL_HTTP_PORT:-7474}"
heap="${BHL_HEAP:-2g}"
neo4j_version="4.4.48"
neo4j_url="https://dist.neo4j.org/neo4j-community-${neo4j_version}-unix.tar.gz"
jre_url="https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jre/hotspot/normal/eclipse"
gui_url="https://github.com/BloodHoundAD/BloodHound/releases/download/v4.3.1/BloodHound-linux-x64.zip"
neo4j_home="${root}/neo4j"
java_home="${root}/java"
gui_bin="${root}/gui/BloodHound-linux-x64/BloodHound"
docker_image="neo4j:4.4"

log() { echo "[*] $*"; }
die() { echo "[!] $*" >&2; exit 1; }
dl() { curl -fL --retry 3 --connect-timeout 20 -o "$2" "$1"; }

# Fallback when dist.neo4j.org is unreachable: copy Neo4j and its JDK out of the Docker image, then drop the image.
neo4j_from_docker() {
    command -v docker >/dev/null || die "dist.neo4j.org unreachable and docker not found; put neo4j-community-*-unix.tar.gz into ${root}/ and rerun"
    local had_image=0 cid jh
    docker image inspect "${docker_image}" >/dev/null 2>&1 && had_image=1
    log "Direct download failed, extracting Neo4j from ${docker_image}"
    cid=$(docker create "${docker_image}")
    jh=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" | sed -n 's/^JAVA_HOME=//p' | head -1)
    [ -n "${jh}" ] || jh=/usr/local/openjdk-11
    docker cp "${cid}:/var/lib/neo4j" "${neo4j_home}"
    docker cp "${cid}:${jh}" "${java_home}"
    docker rm "${cid}" >/dev/null
    [ "${had_image}" = 1 ] || docker rmi "${docker_image}" >/dev/null
}

setup() {
    mkdir -p "${root}"
    if [ ! -x "${neo4j_home}/bin/neo4j" ]; then
        local tgz
        tgz=$(ls "${root}"/neo4j-community-*-unix.tar.gz 2>/dev/null | head -1 || true)
        if [ -z "${tgz}" ]; then
            log "Downloading Neo4j ${neo4j_version}"
            dl "${neo4j_url}" "${root}/neo4j.tar.gz" 2>/dev/null && tgz="${root}/neo4j.tar.gz" || rm -f "${root}/neo4j.tar.gz"
        fi
        if [ -n "${tgz}" ]; then
            mkdir -p "${neo4j_home}" && tar xzf "${tgz}" -C "${neo4j_home}" --strip-components=1 && rm -f "${root}/neo4j.tar.gz"
        else
            rm -rf "${neo4j_home}" "${java_home}"
            neo4j_from_docker
        fi
    fi
    if [ ! -x "${java_home}/bin/java" ]; then
        log "Downloading JRE 17"
        dl "${jre_url}" "${root}/jre.tar.gz"
        mkdir -p "${java_home}" && tar xzf "${root}/jre.tar.gz" -C "${java_home}" --strip-components=1 && rm -f "${root}/jre.tar.gz"
    fi
    # Docker image ships data/logs as dangling symlinks (/data, /logs): use real dirs inside the folder
    for d in data logs; do
        [ -L "${neo4j_home}/${d}" ] && rm -f "${neo4j_home}/${d}"
        mkdir -p "${neo4j_home}/${d}"
    done
    if [ ! -f "${root}/.configured" ]; then
        log "Configuring Neo4j"
        [ -f "${neo4j_home}/conf/neo4j.conf.orig" ] || cp "${neo4j_home}/conf/neo4j.conf" "${neo4j_home}/conf/neo4j.conf.orig"
        cp "${neo4j_home}/conf/neo4j.conf.orig" "${neo4j_home}/conf/neo4j.conf"
        {
            echo "dbms.default_listen_address=127.0.0.1"
            echo "dbms.connector.bolt.listen_address=127.0.0.1:${bolt_port}"
            echo "dbms.connector.http.listen_address=127.0.0.1:${http_port}"
            echo "dbms.memory.heap.initial_size=${heap}"
            echo "dbms.memory.heap.max_size=${heap}"
        } >> "${neo4j_home}/conf/neo4j.conf"
        JAVA_HOME="${java_home}" "${neo4j_home}/bin/neo4j-admin" set-initial-password "${password}" >/dev/null
        touch "${root}/.configured"
    fi
    if [ ! -x "${gui_bin}" ]; then
        log "Downloading BloodHound GUI"
        mkdir -p "${root}/gui"
        dl "${gui_url}" "${root}/gui/bh.zip"
        unzip -q -o "${root}/gui/bh.zip" -d "${root}/gui" && rm -f "${root}/gui/bh.zip"
    fi
    chmod +x "${gui_bin}" "${neo4j_home}"/bin/* 2>/dev/null || true
    # Self-contained launcher inside the folder (no dependency on this script, docker or system java)
    cat > "${root}/run.sh" <<RUN
#!/bin/bash
r="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export JAVA_HOME="\${r}/java"
"\${r}/neo4j/bin/neo4j" start
for _ in \$(seq 1 60); do (exec 3<>/dev/tcp/127.0.0.1/${bolt_port}) 2>/dev/null && break; sleep 2; done
echo "GUI login: bolt://127.0.0.1:${bolt_port}  user: neo4j  password: ${password}"
nohup "\${r}/gui/BloodHound-linux-x64/BloodHound" --no-sandbox >/dev/null 2>&1 &
RUN
    chmod +x "${root}/run.sh"
}

ready() { [ -f "${root}/.configured" ] && [ -x "${gui_bin}" ] && [ -x "${java_home}/bin/java" ]; }
neo() { JAVA_HOME="${java_home}" "${neo4j_home}/bin/neo4j" "$@"; }
wait_db() {
    log "Waiting for Neo4j on 127.0.0.1:${bolt_port}"
    for _ in $(seq 1 60); do (exec 3<>"/dev/tcp/127.0.0.1/${bolt_port}") 2>/dev/null && return; sleep 2; done
    die "Neo4j did not come up, see ${neo4j_home}/logs/neo4j.log"
}

case "${1:-}" in
    setup)  setup; echo "[+] Ready. Run: ${root}/run.sh   (or: $0 up)" ;;
    up)     ready || setup; neo start; wait_db
            echo "[+] GUI login: bolt://127.0.0.1:${bolt_port}  user: neo4j  password: ${password}"
            nohup "${gui_bin}" --no-sandbox >/dev/null 2>&1 & ;;
    start)  ready || setup; neo start; wait_db ;;
    gui)    ready || setup; nohup "${gui_bin}" --no-sandbox >/dev/null 2>&1 & ;;
    stop)   neo stop ;;
    status) neo status ;;
    clean)  read -rp "Remove ${root} including the database? (y/n) " a
            if [[ "$a" =~ ^[Yy]$ ]]; then neo stop 2>/dev/null || true; rm -rf "${root}"; fi ;;
    *)      echo "Usage: $0 {up|gui|start|stop|status|setup|clean}"
            echo "Env: BHL_NEO4J_PASSWORD BHL_BOLT_PORT BHL_HTTP_PORT BHL_HEAP"; exit 1 ;;
esac
