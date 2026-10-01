#!/bin/sh
set -e

# =============================================================================
# SMTP ENTRYPOINT
# =============================================================================
# Usage: entrypoint.sh [serve|dns|test <to>]
#   serve   render config from env, start OpenDKIM + Postfix (default)
#   dns     print the SPF / DKIM / DMARC records to publish for SMTP_DOMAIN
#   test    send a test message to <to> through the running container
#
# Required env:  SMTP_DOMAIN
# Optional env:  see the defaults block below
# =============================================================================

: "${SMTP_DOMAIN:?SMTP_DOMAIN is required (e.g. example.com)}"
: "${SMTP_HOSTNAME:=mail.${SMTP_DOMAIN}}"
: "${SMTP_ALLOWED_SENDER_DOMAINS:=${SMTP_DOMAIN}}"
: "${SMTP_ALLOWED_NETWORKS:=127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
: "${SMTP_DKIM_SELECTOR:=mail}"
: "${SMTP_DKIM_BITS:=2048}"
: "${SMTP_MESSAGE_SIZE_LIMIT:=26214400}"
: "${SMTP_RELAY_HOST:=}"
: "${SMTP_RELAY_PORT:=587}"
: "${SMTP_RELAY_USER:=}"
: "${SMTP_RELAY_PASSWORD:=}"
: "${SMTP_RELAY_TLS:=true}"
: "${SMTP_DMARC_POLICY:=quarantine}"
: "${SMTP_DMARC_RUA:=postmaster@${SMTP_DOMAIN}}"

DKIM_DIR="/etc/opendkim/keys/${SMTP_DOMAIN}"
DKIM_KEY="${DKIM_DIR}/${SMTP_DKIM_SELECTOR}.private"
DKIM_TXT="${DKIM_DIR}/${SMTP_DKIM_SELECTOR}.txt"

ensure_dkim_key() {
    [ -f "$DKIM_KEY" ] && return
    echo "[smtp] generating DKIM key for ${SMTP_DOMAIN} (selector ${SMTP_DKIM_SELECTOR}, ${SMTP_DKIM_BITS} bits)"
    mkdir -p "$DKIM_DIR"
    opendkim-genkey -b "$SMTP_DKIM_BITS" -d "$SMTP_DOMAIN" -s "$SMTP_DKIM_SELECTOR" -D "$DKIM_DIR"
}

render_opendkim() {
    chown -R opendkim:opendkim /etc/opendkim/keys
    chmod 600 "$DKIM_KEY"

    cat > /etc/opendkim/opendkim.conf <<CONF
Syslog                  yes
SyslogSuccess           yes
UMask                   002
Mode                    s
Canonicalization        relaxed/simple
SubDomains              no
OversignHeaders         From
Socket                  inet:8891@127.0.0.1
PidFile                 /run/opendkim/opendkim.pid
UserID                  opendkim:opendkim
KeyTable                /etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
InternalHosts           /etc/opendkim/TrustedHosts
CONF

    : > /etc/opendkim/KeyTable
    : > /etc/opendkim/SigningTable
    for domain in $SMTP_ALLOWED_SENDER_DOMAINS; do
        key="/etc/opendkim/keys/${domain}/${SMTP_DKIM_SELECTOR}.private"
        [ -f "$key" ] || key="$DKIM_KEY"
        echo "${SMTP_DKIM_SELECTOR}._domainkey.${domain} ${domain}:${SMTP_DKIM_SELECTOR}:${key}" >> /etc/opendkim/KeyTable
        echo "*@${domain} ${SMTP_DKIM_SELECTOR}._domainkey.${domain}" >> /etc/opendkim/SigningTable
    done

    printf '%s\n' 127.0.0.1 localhost $SMTP_ALLOWED_NETWORKS > /etc/opendkim/TrustedHosts
}

render_postfix() {
    postconf -e \
        "myhostname=${SMTP_HOSTNAME}" \
        "mydomain=${SMTP_DOMAIN}" \
        "myorigin=${SMTP_DOMAIN}" \
        "mydestination=" \
        "alias_maps=" \
        "alias_database=" \
        "inet_interfaces=all" \
        "inet_protocols=ipv4" \
        "mynetworks=${SMTP_ALLOWED_NETWORKS}" \
        "message_size_limit=${SMTP_MESSAGE_SIZE_LIMIT}" \
        "maillog_file=/dev/stdout" \
        "local_transport=error:local delivery disabled" \
        "smtpd_banner=\$myhostname ESMTP" \
        "smtpd_recipient_restrictions=permit_mynetworks,reject" \
        "smtpd_sender_restrictions=permit_mynetworks,reject" \
        "smtpd_relay_restrictions=permit_mynetworks,reject_unauth_destination" \
        "smtpd_client_restrictions=permit_mynetworks,reject" \
        "smtpd_milters=inet:127.0.0.1:8891" \
        "non_smtpd_milters=inet:127.0.0.1:8891" \
        "milter_default_action=tempfail" \
        "milter_protocol=6" \
        "smtp_tls_security_level=may" \
        "smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt" \
        "smtp_tls_loglevel=1" \
        "compatibility_level=3.6"

    # Only envelope senders @allowed domains leave this box.
    : > /etc/postfix/sender_access
    for domain in $SMTP_ALLOWED_SENDER_DOMAINS; do
        echo "${domain} OK" >> /etc/postfix/sender_access
    done
    postmap lmdb:/etc/postfix/sender_access
    postconf -e "smtpd_sender_restrictions=check_sender_access lmdb:/etc/postfix/sender_access,reject"

    if [ -n "$SMTP_RELAY_HOST" ]; then
        postconf -e "relayhost=[${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT}"
        if [ "$SMTP_RELAY_TLS" = "true" ]; then
            postconf -e "smtp_tls_security_level=encrypt"
        fi
        if [ -n "$SMTP_RELAY_USER" ]; then
            echo "[${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT} ${SMTP_RELAY_USER}:${SMTP_RELAY_PASSWORD}" > /etc/postfix/sasl_passwd
            chmod 600 /etc/postfix/sasl_passwd
            postmap lmdb:/etc/postfix/sasl_passwd
            postconf -e \
                "smtp_sasl_auth_enable=yes" \
                "smtp_sasl_password_maps=lmdb:/etc/postfix/sasl_passwd" \
                "smtp_sasl_security_options=noanonymous" \
                "smtp_sasl_tls_security_options=noanonymous"
        fi
        echo "[smtp] relaying via ${SMTP_RELAY_HOST}:${SMTP_RELAY_PORT}"
    else
        postconf -e "relayhost="
        echo "[smtp] direct delivery (outbound port 25 must be open)"
    fi
}

dkim_record_value() {
    sed -e 's/.*(//' -e 's/).*//' "$1" | tr -d '\n\t"' | tr -s ' ' | sed 's/ //g'
}

print_dns() {
    ensure_dkim_key
    if [ -n "$SMTP_RELAY_HOST" ]; then
        spf="add the include that ${SMTP_RELAY_HOST} documents to this domain's v=spf1 record"
    else
        spf="v=spf1 mx a:${SMTP_HOSTNAME} ~all
     (merge into the existing v=spf1 record if there is one: two SPF records invalidate both)"
    fi

    for domain in $SMTP_ALLOWED_SENDER_DOMAINS; do
        # Same fallback as render_opendkim: domains without their own key share the SMTP_DOMAIN key.
        dkim_txt="/etc/opendkim/keys/${domain}/${SMTP_DKIM_SELECTOR}.txt"
        [ -f "$dkim_txt" ] || dkim_txt="$DKIM_TXT"
        cat <<RECORDS

DNS records for ${domain}
-----------------------------------------------------------------------------
TXT  ${domain}.
     ${spf}

TXT  ${SMTP_DKIM_SELECTOR}._domainkey.${domain}.
     $(dkim_record_value "$dkim_txt")

TXT  _dmarc.${domain}.
     v=DMARC1; p=${SMTP_DMARC_POLICY}; rua=mailto:${SMTP_DMARC_RUA}; adkim=s; aspf=s
-----------------------------------------------------------------------------
RECORDS
    done

    # Only direct delivery talks to recipient servers from this host's IP.
    if [ -z "$SMTP_RELAY_HOST" ]; then
        echo "A    ${SMTP_HOSTNAME}.        -> public IP of this host (and matching PTR record)"
    fi
}

send_test() {
    to="${1:?usage: entrypoint.sh test <recipient>}"
    from="noreply@${SMTP_DOMAIN}"
    printf 'From: %s\nTo: %s\nSubject: SMTP test from %s\n\nSent at %s from %s\n' \
        "$from" "$to" "$SMTP_HOSTNAME" "$(date -u +%FT%TZ)" "$SMTP_HOSTNAME" \
        | sendmail -f "$from" "$to"
    echo "[smtp] queued test message to ${to}; follow with: postqueue -p / mailq"
}

serve() {
    ensure_dkim_key
    render_opendkim
    render_postfix
    # Postfix keeps its own copies of resolver/CA files for chrooted services.
    cp /etc/resolv.conf /etc/hosts /etc/services /var/spool/postfix/etc/ 2>/dev/null || true
    postfix set-permissions >/dev/null 2>&1 || true

    print_dns
    syslogd -n -O /dev/stdout &
    opendkim -f -x /etc/opendkim/opendkim.conf &
    dkim_pid=$!
    # Postfix becomes PID 1 below; stop it when OpenDKIM dies so the restart policy revives both.
    (
        while kill -0 "$dkim_pid" 2>/dev/null; do sleep 5; done
        echo "[smtp] opendkim exited, stopping postfix"
        postfix stop
    ) &
    exec postfix start-fg
}

case "${1:-serve}" in
    serve) serve ;;
    dns) print_dns ;;
    test) shift; send_test "$@" ;;
    *) exec "$@" ;;
esac
