#!/usr/bin/env bash
#===============================================================================
#          FILE: smoke.sh
#
#         USAGE: test/smoke.sh [image]
#
#   DESCRIPTION: Starts the image a few different ways and checks that SMB and
#                WebDAV both serve /data, agree on ownership and modes, honour
#                the access controls, and that the container lives and dies as
#                a supervisor should.
#===============================================================================

set -o errexit -o nounset -o pipefail

IMAGE="${1:-simplenas:test}"
PREFIX="smoke-$$"
FAILED=0

cleanup() {
    docker rm -f "$PREFIX-defaults" "$PREFIX-configured" "$PREFIX-life" \
        >/dev/null 2>&1 || true
    docker volume rm -f "$PREFIX-data" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*" >&2; FAILED=1; }

check() { # check <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1: expected '$2', got '$3'"
    fi
}

# Wait until both services answer from inside the container.
wait_ready() { local name="$1" i
    for i in $(seq 1 60); do
        if docker exec "$name" sh -c \
                'smbclient -L \\localhost -U % -m SMB3 >/dev/null 2>&1 &&
                 curl -sS -o /dev/null http://localhost:8080/' >/dev/null 2>&1
        then
            return 0
        fi
        sleep 1
    done
    echo "FAIL - $name never became ready" >&2
    docker logs "$name" >&2
    exit 1
}

# stat as "uid:gid mode", so both protocols can be compared directly.
owner_mode() { docker exec "$1" stat -c '%u:%g %a' "$2"; }

dav() { # dav <container> <method> <path> [curl args...]
    local name="$1" method="$2" path="$3"; shift 3
    docker exec "$name" curl -s -o /dev/null -w '%{http_code}' \
        -X "$method" "$@" "http://localhost:8080$path"
}

smb() { # smb <container> <share> <auth> <command>
    docker exec "$1" smbclient "//localhost/$2" $3 -c "$4" 2>&1 || true
}

echo "== defaults: no environment at all =="
docker volume create "$PREFIX-data" >/dev/null
docker run -d --name "$PREFIX-defaults" -v "$PREFIX-data:/data" \
    "$IMAGE" >/dev/null
wait_ready "$PREFIX-defaults"

docker exec "$PREFIX-defaults" sh -c 'echo webdav >/tmp/up.txt'
check "webdav PUT without credentials" 201 \
    "$(dav "$PREFIX-defaults" PUT /dav.txt -T /tmp/up.txt)"
check "webdav MKCOL without credentials" 201 \
    "$(dav "$PREFIX-defaults" MKCOL /davdir)"
check "webdav PROPFIND" 207 \
    "$(dav "$PREFIX-defaults" PROPFIND / -H 'Depth: 1')"
check "webdav PROPPATCH" 207 \
    "$(dav "$PREFIX-defaults" PROPPATCH /dav.txt)"

smb "$PREFIX-defaults" storage -N \
    'put /tmp/up.txt smb.txt; mkdir smbdir' >/dev/null
check "smb guest write" 0 "$(docker exec "$PREFIX-defaults" \
    sh -c 'test -f /data/smb.txt; echo $?')"

# The whole point of merging the images: one identity, one set of modes.
dav_file="$(owner_mode "$PREFIX-defaults" /data/dav.txt)"
smb_file="$(owner_mode "$PREFIX-defaults" /data/smb.txt)"
dav_dir="$(owner_mode "$PREFIX-defaults" /data/davdir)"
smb_dir="$(owner_mode "$PREFIX-defaults" /data/smbdir)"
check "file ownership and mode match across protocols" "$smb_file" "$dav_file"
check "dir ownership and mode match across protocols" "$smb_dir" "$dav_dir"
check "files are 100:101 0664" "100:101 664" "$dav_file"
check "dirs are 100:101 2775" "100:101 2775" "$dav_dir"

# nginx must buffer uploads on the share's own filesystem, or dav_access is
# lost to a cross-device copy. Samba has to hide the buffer.
check "upload buffer lives on the share" 0 "$(docker exec "$PREFIX-defaults" \
    sh -c 'test -d /data/.nginx-tmp; echo $?')"
listing="$(smb "$PREFIX-defaults" storage -N 'ls')"
if [[ "$listing" == *.nginx-tmp* ]]; then
    fail "upload buffer is vetoed from smb"
else
    pass "upload buffer is vetoed from smb"
fi

echo
echo "== configured: users, an extra share, webdav auth =="
docker run -d --name "$PREFIX-configured" \
    -e USER="demo;demo123" \
    -e SHARE2="media;/data/media;yes;no;no;demo;;;Media library" \
    -e WORKGROUP=TESTGROUP \
    -e WEBDAV_USERNAME=demo -e WEBDAV_PASSWORD=demo123 \
    "$IMAGE" >/dev/null
wait_ready "$PREFIX-configured"

check "smb.conf is valid" 0 "$(docker exec "$PREFIX-configured" \
    sh -c 'testparm -s >/dev/null 2>&1; echo $?')"
check "workgroup override applied" TESTGROUP "$(docker exec \
    "$PREFIX-configured" testparm -s --parameter-name=workgroup 2>/dev/null)"

docker exec "$PREFIX-configured" sh -c 'echo webdav >/tmp/up.txt'
check "webdav rejects anonymous" 401 \
    "$(dav "$PREFIX-configured" GET /)"
check "webdav accepts credentials" 201 \
    "$(dav "$PREFIX-configured" PUT /dav.txt -u demo:demo123 -T /tmp/up.txt)"

smb "$PREFIX-configured" media '-U demo%demo123' \
    'put /tmp/up.txt m.txt' >/dev/null
check "valid user can write the extra share" 0 \
    "$(docker exec "$PREFIX-configured" sh -c 'test -f /data/media/m.txt; echo $?')"
denied="$(smb "$PREFIX-configured" media -N 'ls')"
if [[ "$denied" == *ACCESS_DENIED* ]]; then
    pass "guest is denied on the extra share"
else
    fail "guest is denied on the extra share: $denied"
fi

echo
echo "== lifecycle =="
docker run -d --name "$PREFIX-life" "$IMAGE" >/dev/null
wait_ready "$PREFIX-life"
docker exec "$PREFIX-life" sh -c 'kill -9 $(cat /run/nginx/nginx.pid)'
for _ in $(seq 1 15); do
    [[ "$(docker inspect --format '{{.State.Running}}' "$PREFIX-life")" == false ]] &&
        break
    sleep 1
done
check "a dead service stops the container" false \
    "$(docker inspect --format '{{.State.Running}}' "$PREFIX-life")"
check "and reports a failure" 1 "$(docker inspect \
    --format '{{if eq .State.ExitCode 0}}0{{else}}1{{end}}' "$PREFIX-life")"

docker rm -f "$PREFIX-life" >/dev/null
docker run -d --name "$PREFIX-life" "$IMAGE" >/dev/null
wait_ready "$PREFIX-life"
start=$SECONDS
docker stop "$PREFIX-life" >/dev/null
if (( SECONDS - start < 10 )); then
    pass "docker stop is graceful, not a 10s timeout"
else
    fail "docker stop took $(( SECONDS - start ))s, the signal was not handled"
fi
check "clean exit code on stop" 143 \
    "$(docker inspect --format '{{.State.ExitCode}}' "$PREFIX-life")"

echo
if (( FAILED )); then
    echo "smoke tests FAILED" >&2
    exit 1
fi
echo "all smoke tests passed"
