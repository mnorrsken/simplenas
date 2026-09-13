#!/usr/bin/env bash
#===============================================================================
#          FILE: entrypoint.sh
#
#   DESCRIPTION: Configures and supervises smbd (+ optional nmbd) and nginx,
#                which serve /data over SMB and WebDAV respectively. The
#                container exits as soon as any of them does.
#
#         NOTES: The share and user helpers are cut down from dperson's
#                samba.sh (https://github.com/dperson/samba), AGPL-3.0.
#===============================================================================

set -o nounset                              # Treat unset variables as an error

SMB_CONF=/etc/samba/smb.conf

log() { echo "entrypoint: $*" >&2; }

### share: append a share definition to smb.conf
# Arguments:
#   share) share name
#   path) path to share
#   browsable) 'yes' or 'no', default 'yes'
#   readonly) 'yes' or 'no', default 'no'
#   guest) 'yes' or 'no', default 'yes'
#   users) comma separated list of allowed users, 'all' for everyone
#   admins) comma separated list of admin users
#   writelist) comma separated list of users that can write to a RO share
#   comment) description of the share
share() { local name="$1" path="$2" browsable="${3:-yes}" ro="${4:-no}" \
                guest="${5:-yes}" users="${6:-}" admins="${7:-}" \
                writelist="${8:-}" comment="${9:-}"
    sed -i "/^\[$name\]/,/^\$/d" "$SMB_CONF"
    {
        echo "[$name]"
        echo "   path = $path"
        echo "   browsable = $browsable"
        echo "   read only = $ro"
        echo "   guest ok = $guest"
        [[ $users && $users != all ]] && echo "   valid users = ${users//,/ }"
        [[ $admins && $admins != none ]] && echo "   admin users = ${admins//,/ }"
        [[ $writelist && $writelist != none ]] &&
            echo "   write list = ${writelist//,/ }"
        [[ $comment && $comment != none ]] && echo "   comment = $comment"
        echo ""
    } >>"$SMB_CONF"

    # Only touch a path we create ourselves; an existing mount keeps whatever
    # ownership the host or the orchestrator gave it.
    [[ -d $path ]] || {
        mkdir -p "$path"
        chown smbuser:smb "$path"
        chmod 2775 "$path"
    }
}

### user: add a system user and the matching samba account
# Arguments:
#   name) for user
#   password) for user
#   id) uid for user
#   group) for user
#   gid) for group
user() { local name="$1" passwd="$2" id="${3:-}" group="${4:-}" gid="${5:-}"
    [[ $group ]] && { grep -q "^$group:" /etc/group ||
                addgroup ${gid:+-g $gid} "$group"; }
    grep -q "^$name:" /etc/passwd ||
        adduser -D -H -s /sbin/nologin ${group:+-G $group} ${id:+-u $id} "$name"
    printf '%s\n%s\n' "$passwd" "$passwd" | smbpasswd -s -a "$name" >/dev/null
}

### perms: fix ownership and modes of every share path, recursively
perms() { local path
    while read -r path; do
        log "fixing ownership and permissions under $path"
        chown -Rh smbuser:smb "$path"
        find "$path" -type d ! -perm -2775 -exec chmod 2775 {} +
        find "$path" -type f ! -perm -0664 -exec chmod 0664 {} +
    done < <(awk -F ' = ' '/^ *path = /{print $2}' "$SMB_CONF")
}

### env_values: print the values of VAR, VAR1, VAR2, ... one per line
# Arguments:
#   prefix) variable name prefix
env_values() { env | sed -n "s/^$1[0-9_]*=//p"; }

### split_apply: call a function with a ';' separated spec as its arguments
# Arguments:
#   func) function to call
#   min) minimum number of fields
#   spec) the ';' separated string
split_apply() { local func="$1" min="$2" spec="$3" fields
    IFS=';' read -r -a fields <<< "$spec"
    if [[ ${#fields[@]} -lt $min ]]; then
        log "ignoring malformed $func definition: $spec"
        return
    fi
    "$func" "${fields[@]}"
}

### Renumber the service account. smbd forces every SMB session onto it and
### the nginx workers run as it, so both protocols write identical ownership.
[[ "${USERID:-}" =~ ^[0-9]+$ ]] && usermod -u "$USERID" -o smbuser
[[ "${GROUPID:-}" =~ ^[0-9]+$ ]] && groupmod -g "$GROUPID" -o smb
chown -Rh smbuser:smb /var/lib/nginx /var/log/nginx /run/nginx

[[ -n "${WORKGROUP:-}" ]] &&
    sed -i "s|^\( *workgroup = \).*|\1$WORKGROUP|" "$SMB_CONF"

while read -r spec; do
    [[ -n $spec ]] && split_apply share 2 "$spec"
done < <(env_values SHARE)

while read -r spec; do
    [[ -n $spec ]] && split_apply user 2 "$spec"
done < <(env_values USER)

[[ -n "${PERMISSIONS:-}" ]] && perms

### WebDAV basic auth. webdav.conf includes the snippet unconditionally, so
### write an empty one when no credentials are supplied.
if [[ -n "${WEBDAV_USERNAME:-}" && -n "${WEBDAV_PASSWORD:-}" ]]; then
    htpasswd -cb /etc/nginx/htpasswd "$WEBDAV_USERNAME" "$WEBDAV_PASSWORD"
    chown smbuser:smb /etc/nginx/htpasswd
    chmod 640 /etc/nginx/htpasswd
    cat >/etc/nginx/webdav-auth.conf <<'EOF'
auth_basic "WebDAV";
auth_basic_user_file /etc/nginx/htpasswd;
EOF
else
    log "WEBDAV_USERNAME/WEBDAV_PASSWORD not set, WebDAV is unauthenticated"
    : >/etc/nginx/webdav-auth.conf
fi

pids=()

# umask 002 so MKCOL creates 0775 directories; mkdir(2) is umask-masked and
# nginx has no directive for it. dav_access still governs file modes.
( umask 002; exec nginx -g 'daemon off;' ) &
pids+=($!)

if [[ -n "${NMBD:-}" ]]; then
    ionice -c 3 nmbd -F --no-process-group &
    pids+=($!)
fi

ionice -c 3 smbd -F --no-process-group </dev/null &
pids+=($!)

stopping=0
stop() { stopping=1; kill -TERM "${pids[@]}" 2>/dev/null; }
trap stop INT TERM

wait -n
rc=$?

# nginx and smbd exit 0 when signalled, so report a failure when a service goes
# away on its own and nothing asked us to shut down.
(( stopping == 0 && rc == 0 )) && rc=1

log "a service exited with status $rc, stopping the container"
stop
wait
exit $rc
