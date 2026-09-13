FROM alpine

RUN apk --no-cache --no-progress upgrade && \
    apk --no-cache --no-progress add bash samba shadow tini tzdata \
        ca-certificates curl nginx nginx-mod-http-dav-ext apache2-utils && \
    # The nginx package's own user/group are unused (the workers run as
    # smbuser:smb) and sit on uid 100/gid 101, which is what smbuser wants.
    deluser nginx 2>/dev/null; delgroup nginx 2>/dev/null; \
    addgroup -S -g 101 smb && \
    adduser -S -D -H -h /tmp -s /sbin/nologin -G smb -u 100 \
        -g 'Samba User' smbuser && \
    rm -f /etc/nginx/http.d/default.conf && \
    mkdir -p /data /run/nginx && \
    chown smbuser:smb /data && chmod 2775 /data && \
    ln -sf /dev/stderr /var/log/nginx/error.log && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    rm -rf /tmp/*

COPY --chmod=755 entrypoint.sh /usr/bin/
COPY smb.conf /etc/samba/smb.conf
COPY nginx.conf /etc/nginx/nginx.conf
COPY webdav.conf /etc/nginx/http.d/webdav.conf

VOLUME /data

EXPOSE 137/udp 138/udp 139 445 8080

HEALTHCHECK --interval=60s --timeout=15s \
            CMD smbclient -L \\localhost -U % -m SMB3 && \
                curl -sS -o /dev/null http://localhost:8080/

STOPSIGNAL SIGTERM

ENTRYPOINT ["/sbin/tini", "--", "/usr/bin/entrypoint.sh"]
