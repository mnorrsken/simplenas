# simplenas

One Alpine image that serves `/data` over **SMB** (samba) and **WebDAV**
(nginx + `ngx_http_dav_ext`). It replaces the separate `nginx-webdav` and
`samba` images, which had to run as two containers in the same pod sharing a
volume.

Both daemons run side by side under `tini`; if either exits, the container
exits, so the orchestrator restarts it.

## Defaults

The image is configured for the common case, so it needs no environment at all:

- Share `storage` on `/data`: browsable, read-write, guest access allowed.
- WebDAV on `:8080` serving the same `/data`, unauthenticated.
- Service account `smbuser:smb` is uid `100`, gid `101`. `smbd` forces every
  SMB session onto it and the nginx workers run as it, so both protocols write
  identical ownership and `0664`/`2775` modes.
- Workgroup `WORKGROUP`, SMB 2.1–3 only, printing disabled, Apple/Time Machine
  support via the `fruit` VFS module, no recycle bin.
- All logs to the container stdout/stderr.

```bash
docker run -d --name simplenas \
	-p 445:445 -p 139:139 -p 8080:8080 \
	-v nasdata:/data \
	ghcr.io/mnorrsken/simplenas
```

SMB at `smb://localhost/storage`, WebDAV at `http://localhost:8080/`.

## Configuration

Everything below is optional.

| Variable | Default | Purpose |
| --- | --- | --- |
| `USER`, `USER#` | none | Add an SMB account (see below). |
| `SHARE`, `SHARE#` | none | Add a share on top of `storage` (see below). |
| `WEBDAV_USERNAME` + `WEBDAV_PASSWORD` | none | Turn on WebDAV basic auth. |
| `WORKGROUP` | `WORKGROUP` | Workgroup name. |
| `USERID` / `GROUPID` | `100` / `101` | Renumber `smbuser` / `smb`. |
| `NMBD` | off | Start `nmbd` to advertise shares over NetBIOS. |
| `PERMISSIONS` | off | Recursively chown/chmod every share path at startup. |

`#` is a sequential integer, so `SHARE1`, `SHARE2`, … and `USER1`, `USER2`, …
all work alongside the bare names.

Restart the container after changing shares or users — samba does not
hot-reload its config.

### Users
`USER#="username;password[;uid;group;gid]"` creates a system user and the
matching samba account:

```bash
-e USER1="media;Sup3rSecret;1000;mediausers;1000"
```

Without any user, the `storage` share is open to guests.

### Shares
`SHARE#="name;/abs/path[;browsable;readonly;guest;users;admins;writelist;comment]"`

- `browsable` default `yes`, `readonly` default `no`, `guest` default `yes`.
- `users`, `admins`, `writelist` take comma lists (`all`/`none` to skip).
- A path that does not exist is created as `smbuser:smb` `2775`; an existing
  one keeps whatever ownership the host or orchestrator gave it.

```bash
-e SHARE2="media;/data/media;yes;no;no;alice,bob;;;Media library"
```

### Permissions
`PERMISSIONS=1` walks every share path and forces `smbuser:smb`, `2775` on
directories and `0664` on files. It is off by default because it is a full tree
walk on every start. You need it when `/data` comes from a host directory or a
volume the container cannot already write, or after changing `USERID`/
`GROUPID` on existing data. In Kubernetes, `securityContext.fsGroup: 101` does
the same job without the walk.

### Anything else
Edit `src/smb.conf` and rebuild. It is a plain config file, not generated.

## WebDAV

The server block is `/etc/nginx/http.d/webdav.conf`: `/data` with directory
listings, no upload size limit, and the `PROPPATCH`/`MKCOL` workarounds macOS
and Windows clients need.

**Authentication**: with both `WEBDAV_USERNAME` and `WEBDAV_PASSWORD` set,
`entrypoint.sh` writes `/etc/nginx/htpasswd` and an
`/etc/nginx/webdav-auth.conf` snippet that turns on basic auth. Without them
the snippet is empty and WebDAV is open to anyone who can reach the port.

**Upload buffer**: nginx buffers uploads in `/data/.nginx-tmp` so a `PUT` is a
rename rather than a cross-filesystem copy. Samba vetoes the directory, and it
must stay on the same filesystem as the share.

To customise nginx further, mount your own `.conf` into `/etc/nginx/http.d/`
(mounting over the directory replaces the bundled `webdav.conf`), or replace
`/etc/nginx/nginx.conf`.

## Networking & health
- Ports: `137/udp`, `138/udp`, `139/tcp`, `445/tcp`, `8080/tcp`.
- Health check every 60s: `smbclient -L \\localhost -U % -m SMB3` plus an HTTP
  request to `localhost:8080`.

## Persistence
Only `/data` is a volume. `smb.conf` is baked into the image and only appended
to at startup, so none of samba's state needs to survive a restart.

## Build and test

```bash
docker build -t simplenas:test ./src
test/smoke.sh simplenas:test
```

The smoke tests need a working Docker daemon; they start containers, write
through both protocols and compare what lands on disk. CI runs them natively
on amd64 and arm64 for every push and pull request. A `v*` tag reruns them and
then pushes a multi-arch image to `ghcr.io/mnorrsken/simplenas`.

```
src/
	Dockerfile      merged image
	entrypoint.sh   configures samba + WebDAV auth, runs and supervises both
	smb.conf        samba config, globals and the default storage share
	nginx.conf      global nginx config
	webdav.conf     WebDAV server block, installed to /etc/nginx/http.d/
test/
	smoke.sh        end-to-end checks against a built image
```

## Licence
AGPL-3.0, see [LICENSE](LICENSE). The share and user helpers in
`src/entrypoint.sh` are cut down from David Personette's
[samba.sh](https://github.com/dperson/samba).
