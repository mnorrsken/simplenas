# Changelog

## v0.1.3

Rebuild on current Alpine for security fixes. No code changes.

### Fixed
- **nginx CVE-2026-113425, CVE-2026-121810, CVE-2026-123007 and
  CVE-2026-123633** (CRITICAL, use-after-free in workers and HTTP/2 flow
  control window overflow) — fixed by nginx and nginx-mod-http-dav-ext
  1.30.7-r0. Also fixes HIGH CVE-2026-118899 and CVE-2026-123634, and MEDIUM
  CVE-2026-120967, CVE-2026-123640 and CVE-2026-125283.
- **libxml2 CVE-2026-86144** (HIGH) — fixed by libxml2 2.13.9-r3.
- **OpenSSL CVE-2026-107496, CVE-2026-95691 and CVE-2026-95692** (MEDIUM) and
  CVE-2026-88822 and CVE-2026-88823 (LOW) — fixed by libcrypto3 and libssl3
  3.5.9-r1.
- **gnutls CVE-2026-127039, CVE-2026-127040 and CVE-2026-127231** (one is a
  double free in X.509 name constraints) — fixed by gnutls 3.8.14-r0.

## v0.1.2

Rebuild on current Alpine for security fixes. No code changes.

### Fixed
- **apache2-utils CVE-2026-119618** (CRITICAL, remote code execution in
  httpd mod_http2) — the image is rebuilt on Alpine 3.24.4 with apache2-utils
  2.4.71-r0.
- **libexpat CVE-2026-113351, CVE-2026-115506, CVE-2026-117610 and
  CVE-2026-118370** (HIGH) — fixed by libexpat 2.10.0-r0.
- **Other security updates from the same rebuild** — the remaining
  apache2-utils MEDIUM CVEs (CVE-2026-106023, CVE-2026-109163) and one further
  MEDIUM.

## v0.1.1

Rebuild on current Alpine for security fixes. No code changes.

### Fixed
- **brotli-libs CVE-2026-111497** (HIGH, out-of-bounds write in the Brotli
  decoder) — the image is rebuilt on Alpine 3.24.3 with brotli-libs 1.2.1-r0.
- **Other security updates from the same rebuild** — nginx 1.30.6, pcre2,
  musl, nghttp2 and zlib.

## v0.1.0

First release. Merges the previously separate WebDAV (nginx) and SMB (samba)
images into one container.

### Added
- **One image for both protocols** — `smbd` and nginx run side by side under
  `tini`. If either exits the container exits, with a non-zero status when the
  service died on its own.
- **Working WebDAV server block** — `/data` on `:8080` with directory listings,
  no upload size limit, and the `PROPPATCH`/`MKCOL` workarounds macOS and
  Windows clients need. The old image shipped none and served the stock Alpine
  site until you mounted your own config.
- **WebDAV basic auth that is actually wired up** — the old entrypoint wrote an
  htpasswd file to `/tmp`, which nothing referenced and the build then deleted.
- **Defaults for everything** — a `storage` share on `/data`, uid 100 / gid 101,
  workgroup `WORKGROUP`. The container needs no environment at all.
- **Smoke tests** — `test/smoke.sh` exercises both protocols, the access
  controls and the container lifecycle. CI runs them on amd64 and arm64.

### Changed
- **samba.sh cut down and folded into `entrypoint.sh`** — the getopts interface
  and the `CHARMAP`, `GENERIC#`, `GLOBAL#`, `IMPORT`, `INCLUDE`, `RECYCLE`,
  `SMB`, `VETO` and `WIDELINKS` knobs are gone. `USER#`, `SHARE#`, `WORKGROUP`,
  `USERID`, `GROUPID`, `NMBD` and `PERMISSIONS` remain, all optional.
- **`smb.conf` is a plain file** instead of 40 lines of `sed` and `echo` in the
  Dockerfile.
- **nginx workers run as `smbuser:smb`** so both protocols write identical
  ownership, `0664` files and `2775` directories.
- **Recycle bin off by default.**
- **Only `/data` is a volume** — samba's `/etc`, `/var/cache/samba`,
  `/var/lib/samba`, `/var/log/samba` and `/run/samba` are not. `smb.conf` is
  baked into the image and only appended to at startup.

### Fixed
- **`PERMISSIONS` did nothing** — `chown smbuser.` is not a form busybox
  accepts, so the chown failed on every path. It also used an exact permission
  match and `chmod 775`, which stripped the setgid bit `fsGroup` sets.
- **WebDAV ignored `dav_access`** — with `/data` on its own filesystem nginx
  copied each upload across devices instead of renaming, and the copy took its
  mode from the umask. Uploads are now buffered in `/data/.nginx-tmp`.
- **`nmbd` was unsupervised** — it ran with `-D` and could die unnoticed.
- **The entrypoint traced the WebDAV password into the container log** via
  `#!/bin/sh -eux`.
