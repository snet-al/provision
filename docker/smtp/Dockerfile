# =============================================================================
# SMTP - Send-only mail relay (Postfix + OpenDKIM)
# =============================================================================
# Outbound-only SMTP for the stack. Signs with DKIM for SMTP_DOMAIN and either
# delivers directly (port 25 to the world) or forwards to SMTP_RELAY_HOST.
# All config comes from env vars — see entrypoint.sh and env/client/.env.infra.smtp
# =============================================================================
FROM alpine:3.24

RUN apk add --no-cache \
        postfix \
        opendkim \
        opendkim-utils \
        cyrus-sasl \
        cyrus-sasl-login \
        ca-certificates \
        tzdata \
    && mkdir -p /etc/opendkim/keys /run/opendkim \
    && chown opendkim:opendkim /run/opendkim

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/spool/postfix", "/etc/opendkim/keys"]
EXPOSE 25

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD postfix status >/dev/null 2>&1 && nc -z 127.0.0.1 8891 || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
