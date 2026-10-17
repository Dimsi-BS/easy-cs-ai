#!/usr/bin/env bash
# nginx reverse proxy install script (HTTPS + API key), see
# docs/spec-script-contract.md, search/nginx.md and docs/decision-nginx-certificates.md.
#
#   nginx.sh <action> [options]
#   actions: install uninstall status describe add-upstream remove-upstream list-upstreams add-site remove-site show-key
set -euo pipefail

readonly NAME=nginx
readonly TYPE=proxy
readonly SCRIPT_VERSION=0.1.0
readonly UNIT=nginx.service
readonly HEALTH_TIMEOUT=30
readonly MAIN_CONF=/etc/nginx/conf.d/easy-cs-ai.conf
readonly NGX_DIR_LOGICAL=/etc/nginx/easy-cs-ai
readonly UPSTREAM_DIR=/etc/nginx/easy-cs-ai/upstreams
readonly SITE_DIR=/etc/nginx/easy-cs-ai/sites
readonly HEALTH_PATH=/easy-cs-ai/health
readonly ACTIONS="install uninstall status describe add-upstream remove-upstream list-upstreams add-site remove-site show-key"
readonly ACME_CONF=/etc/nginx/conf.d/easy-cs-ai-acme.conf
readonly ACME_ROOT=/var/www/easy-cs-ai-acme
readonly LE_DIR=/etc/letsencrypt
# Certificate strategies, see docs/decision-nginx-certificates.md. The first is the default.
readonly TLS_STRATEGIES="self-signed provided letsencrypt"

LIB_DIR="${EASY_CS_AI_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)}"
readonly LIB_DIR
readonly TEMPLATE_DIR="$LIB_DIR/../templates/nginx"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

ACTION="" FORCE=0 PURGE=0 MAKE_DEFAULT=0 API_KEY_FILE="" TLS_KEY_FILE=""
POSITIONAL=()

usage() {
    cat <<EOF
Usage: nginx.sh <action> [options]

Actions: $ACTIONS

  add-upstream <name> <url>   expose an internal HTTP URL under /<name>/ (prints its public URL)
  remove-upstream <name>      stop exposing it
  list-upstreams              the models the proxy fronts with the URL a client of another machine uses (JSON)
  add-site <name> <url>       serve a web site (browsers, no API key) on --site-port (prints its public URL)
  remove-site <name>          stop serving it
  show-key                    print the API key (the only action that prints a secret)

Options:
  --port <n>              HTTPS port (default 443, EASY_CS_AI_NGINX_PORT)
  --bind <address>        listening address (default 0.0.0.0, EASY_CS_AI_NGINX_BIND)
  --site-port <n>         HTTPS port of the web site added with add-site (default 8443, EASY_CS_AI_NGINX_SITE_PORT)
  --server-name <name>    name in the certificate and the URLs (default: the hostname, EASY_CS_AI_NGINX_SERVER_NAME)
  --tls <strategy>        certificate: self-signed (default), provided or letsencrypt
  --tls-cert <path>       provided: the certificate (PEM, full chain first)
  --tls-key-file <path>   provided: its private key (PEM, mode 0600, not encrypted), or - for stdin
                          (EASY_CS_AI_NGINX_TLS_KEY holds the PEM text)
  --tls-email <address>   letsencrypt: contact address for expiry notices (optional)
  --tls-accept-terms [v]  letsencrypt: accept the Let's Encrypt subscriber agreement (required)
                          letsencrypt also needs an explicit --server-name, a public domain
                          pointing to this machine, reachable on port 80 from the Internet
  --api-key-file <path>   file holding the API key (mode 0600), or - for stdin; generated when absent
                          (EASY_CS_AI_NGINX_API_KEY is also read)
  --health-timeout <s>    seconds to wait for the proxy (default $HEALTH_TIMEOUT)
  --lock-timeout <s>      wait for a busy component lock instead of failing
  --default               install: make nginx the default proxy
  --force                 uninstall: even if another component requires it
  --purge                 uninstall: also delete the Let's Encrypt certificate of this name
  --help --version --verbose --dry-run --json
EOF
}

# --- Options ------------------------------------------------------------------

parse_args() {
    parse_common_options "$@"
    set -- "${COMMON_REST[@]}"
    if [[ $# -eq 0 ]]; then
        if wants_help || wants_version; then
            return 0
        fi
        usage >&2
        exit "$EXIT_USAGE"
    fi
    ACTION="$1"
    shift
    local opt value
    while [[ $# -gt 0 ]]; do
        opt="$1"
        shift
        case "$opt" in
        --port | --bind | --site-port | --server-name | --tls | --tls-cert | --tls-email | --health-timeout | --lock-timeout)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            set_option "$NAME" "${opt#--}" "$1"
            shift
            ;;
        --port=* | --bind=* | --site-port=* | --server-name=* | --tls=* | --tls-cert=* | --tls-email=* | --health-timeout=* | --lock-timeout=*)
            value="${opt#*=}"
            opt="${opt%%=*}"
            set_option "$NAME" "${opt#--}" "$value"
            ;;
        --api-key-file)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            API_KEY_FILE="$1"
            shift
            ;;
        --api-key-file=*) API_KEY_FILE="${opt#*=}" ;;
        --tls-key-file)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            TLS_KEY_FILE="$1"
            shift
            ;;
        --tls-key-file=*) TLS_KEY_FILE="${opt#*=}" ;;
        --tls-accept-terms)
            # a bare flag means true; apply passes the value as text
            if [[ $# -gt 0 && "$1" =~ ^(true|false|yes|no|1|0)$ ]]; then
                set_option "$NAME" tls-accept-terms "$1"
                shift
            else
                set_option "$NAME" tls-accept-terms true
            fi
            ;;
        --tls-accept-terms=*) set_option "$NAME" tls-accept-terms "${opt#*=}" ;;
        --default) MAKE_DEFAULT=1 ;;
        --force) FORCE=1 ;;
        --purge) PURGE=1 ;;
        -*) die "$EXIT_USAGE" "unknown option: $opt" ;;
        *) POSITIONAL+=("$opt") ;;
        esac
    done
}

default_server_name() { hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'localhost\n'; }

# recorded_tls: the strategy recorded at the last install, empty when none.
recorded_tls() { state_read "$NAME" 2>/dev/null | jq -r '.params.tls // empty' || true; }

# validate_tls: what each strategy needs, checked before any side effect.
validate_tls() {
    local cert email
    cert="$(get_option "$NAME" tls-cert)"
    if [[ "$TLS" != provided && ( -n "$cert" || -n "$TLS_KEY_FILE" || -n "$(get_option "$NAME" tls-key)" ) ]]; then
        die "$EXIT_USAGE" "--tls-cert and --tls-key-file only go with --tls provided"
    fi
    case "$TLS" in
    provided)
        if [[ -z "$cert" ]]; then
            # a re-run keeps the certificate already installed
            [[ "$(recorded_tls)" == provided ]] || die "$EXIT_USAGE" "--tls provided needs --tls-cert and --tls-key-file"
        elif [[ -z "$TLS_KEY_FILE" && -z "$(get_option "$NAME" tls-key)" ]]; then
            die "$EXIT_USAGE" "--tls-cert needs its key: --tls-key-file <path>, - for stdin, or EASY_CS_AI_NGINX_TLS_KEY"
        fi
        ;;
    letsencrypt)
        [[ -n "$SERVER_NAME_GIVEN" ]] ||
            die "$EXIT_USAGE" "--tls letsencrypt needs an explicit --server-name: the public domain name of this machine"
        if [[ "$SERVER_NAME" != *.* || "$SERVER_NAME" =~ ^[0-9.]+$ ]]; then
            die "$EXIT_USAGE" "--tls letsencrypt needs a public domain name, not '$SERVER_NAME'"
        fi
        [[ "$(get_option "$NAME" tls-accept-terms)" =~ ^(true|yes|1)$ ]] ||
            die "$EXIT_USAGE" "--tls letsencrypt needs --tls-accept-terms: the Let's Encrypt subscriber agreement must be accepted"
        email="$(get_option "$NAME" tls-email)"
        if [[ -n "$email" && ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
            die "$EXIT_USAGE" "invalid --tls-email '$email'"
        fi
        ;;
    esac
}

resolve_options() {
    SERVER_NAME_GIVEN="$(get_option "$NAME" server-name)"
    set_option_default "$NAME" port 443
    set_option_default "$NAME" bind 0.0.0.0
    set_option_default "$NAME" site-port 8443
    set_option_default "$NAME" server-name "$(default_server_name)"
    set_option_default "$NAME" tls self-signed
    set_option_default "$NAME" health-timeout "$HEALTH_TIMEOUT"
    PORT="$(get_option "$NAME" port)"
    BIND="$(get_option "$NAME" bind)"
    SITE_PORT="$(get_option "$NAME" site-port)"
    SERVER_NAME="$(get_option "$NAME" server-name)"
    TLS="$(get_option "$NAME" tls)"
    HEALTH="$(get_option "$NAME" health-timeout)"
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
        die "$EXIT_USAGE" "invalid port '$PORT'"
    fi
    if [[ ! "$SITE_PORT" =~ ^[0-9]+$ ]] || ((SITE_PORT < 1 || SITE_PORT > 65535)); then
        die "$EXIT_USAGE" "invalid site port '$SITE_PORT'"
    fi
    if [[ ! "$BIND" =~ ^[A-Za-z0-9.:-]+$ ]]; then
        die "$EXIT_USAGE" "invalid bind address '$BIND'"
    fi
    if [[ ! "$SERVER_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        die "$EXIT_USAGE" "invalid server name '$SERVER_NAME'"
    fi
    if [[ ! "$HEALTH" =~ ^[0-9]+$ ]]; then
        die "$EXIT_USAGE" "invalid health timeout '$HEALTH'"
    fi
    case " $TLS_STRATEGIES " in
    *" $TLS "*) ;;
    *) die "$EXIT_USAGE" "unknown --tls strategy '$TLS' (expected: $TLS_STRATEGIES)" ;;
    esac
    if [[ "$ACTION" == install ]]; then
        validate_tls
    fi
}

# adopt_recorded_params: for actions on an installed proxy, use the parameters
# recorded at install unless the caller gave others.
adopt_recorded_params() {
    local json key
    if json="$(state_read "$NAME")"; then
        for key in port bind site-port server-name tls; do
            set_option_default "$NAME" "$key" "$(jq -r --arg k "$key" '.params[$k] // empty' <<<"$json")"
        done
    fi
}

# client_host: address to reach the server (a wildcard bind is reached locally).
client_host() {
    case "$1" in
    0.0.0.0 | "::" | "[::]") printf '127.0.0.1\n' ;;
    *) printf '%s\n' "$1" ;;
    esac
}

# listen_address [<port>]: the nginx `listen` value (an IPv6 address needs
# brackets), for the HTTPS port unless another is given.
listen_address() {
    local bind="$BIND"
    if [[ "$bind" == *:* && "$bind" != \[* ]]; then
        bind="[$bind]"
    fi
    printf '%s:%s\n' "$bind" "${1:-$PORT}"
}

# public_url <upstream>: the OpenAI-style base URL of an upstream.
public_url() {
    local port=""
    [[ "$PORT" == 443 ]] || port=":$PORT"
    printf 'https://%s%s/%s/v1\n' "$SERVER_NAME" "$port" "$1"
}

# site_url: the public URL of a web site, which has its own port.
site_url() { printf 'https://%s:%s/\n' "$SERVER_NAME" "$SITE_PORT"; }

# --- Paths (logical, EASY_CS_AI_ROOT is applied by root_path) -------------------

secret_file() { printf '%s/secrets/nginx.api-key\n' "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }
tls_key_file() { printf '%s/secrets/nginx.tls-key\n' "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }
tls_cert_file() { printf '%s/nginx/server.crt\n' "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }
config_dir_logical() { printf '%s\n' "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }

# cert_path / key_path: what nginx is given. Let's Encrypt keeps its own files.
cert_path() {
    if [[ "$TLS" == letsencrypt ]]; then printf '%s/live/%s/fullchain.pem\n' "$LE_DIR" "$SERVER_NAME"; else tls_cert_file; fi
}
key_path() {
    if [[ "$TLS" == letsencrypt ]]; then printf '%s/live/%s/privkey.pem\n' "$LE_DIR" "$SERVER_NAME"; else tls_key_file; fi
}

# --- describe / helpers -----------------------------------------------------------

describe() {
    _require_jq
    jq -n --arg sv "$SCRIPT_VERSION" --argjson ht "$HEALTH_TIMEOUT" --arg actions "$ACTIONS" '{
        schema_version: 1, name: "nginx", type: "proxy", script_version: $sv,
        component_version: "distribution package", requires: [], provides: ["https", "api-key"],
        platforms: ["debian", "ubuntu"], health_timeout: $ht,
        native: { command: "nginx" },
        resources: { ram_gb: 0, disk_gb: 0, source: "guess", basis: "Small beside the rest, to measure" },
        options: [
          { name: "port", env: "EASY_CS_AI_NGINX_PORT", default: "443", secret: false, type: "integer", min: 1, max: 65535, description: "HTTPS port" },
          { name: "bind", env: "EASY_CS_AI_NGINX_BIND", default: "0.0.0.0", secret: false, description: "Listening address" },
          { name: "site-port", env: "EASY_CS_AI_NGINX_SITE_PORT", default: "8443", secret: false, type: "integer", min: 1, max: 65535, description: "HTTPS port of the web site added with add-site (a chat interface for browsers, no API key)" },
          { name: "server-name", env: "EASY_CS_AI_NGINX_SERVER_NAME", default: "hostname", secret: false, description: "Name in the certificate and in the public URLs" },
          { name: "tls", env: "EASY_CS_AI_NGINX_TLS", default: "self-signed", secret: false, type: "enum", values: ["self-signed", "provided", "letsencrypt"], description: "Certificate strategy: self-signed, provided or letsencrypt" },
          { name: "tls-cert", env: "EASY_CS_AI_NGINX_TLS_CERT", default: "", secret: false, description: "provided: path of the certificate (PEM, full chain first)" },
          { name: "tls-key", env: "EASY_CS_AI_NGINX_TLS_KEY", default: "", secret: true, description: "provided: the private key of the certificate (PEM, not encrypted)" },
          { name: "tls-email", env: "EASY_CS_AI_NGINX_TLS_EMAIL", default: "", secret: false, description: "letsencrypt: contact address for expiry notices" },
          { name: "tls-accept-terms", env: "EASY_CS_AI_NGINX_TLS_ACCEPT_TERMS", default: "false", secret: false, type: "boolean", description: "letsencrypt: accept the Lets Encrypt subscriber agreement (required)" },
          { name: "api-key", env: "EASY_CS_AI_NGINX_API_KEY", default: "generated", secret: true, description: "API key clients send as a Bearer token" },
          { name: "health-timeout", env: "EASY_CS_AI_NGINX_HEALTH_TIMEOUT", default: ($ht | tostring), secret: false, type: "integer", min: 0, description: "Seconds to wait for the proxy after a change" },
          { name: "lock-timeout", env: "EASY_CS_AI_NGINX_LOCK_TIMEOUT", default: "0", secret: false, type: "integer", min: 0, description: "Seconds to wait for a busy component lock" }
        ],
        actions: ($actions | split(" "))
      }'
}

# run_logged <action> <command…>: journal start and end around a changing action.
run_logged() {
    local action="$1" start=$SECONDS rc=0
    shift
    log_event "$NAME $action start params=port=$PORT,bind=$BIND,site-port=$SITE_PORT,server-name=$SERVER_NAME,tls=$TLS"
    ("$@") || rc=$?
    log_event "$NAME $action end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}

service_active() { ! is_test_root && systemctl is-active --quiet "$UNIT"; }

port_in_use() {
    command -v ss >/dev/null 2>&1 && [[ -n "$(ss -H -ltn "sport = :${1:-$PORT}" 2>/dev/null)" ]]
}

nginx_version() {
    local out=""
    if ! is_test_root && command -v nginx >/dev/null 2>&1; then
        out="$(nginx -v 2>&1 || true)"
    fi
    if [[ "$out" =~ nginx/([0-9][0-9A-Za-z.+~-]*) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf 'unknown\n'
    fi
}

# nginx_reload: `nginx -t` (exit 6 on failure, as in the contract), then reload
# when running, else enable and start.
nginx_reload() {
    if is_test_root; then
        log_info "(test mode) nginx -t, then reload $UNIT"
        return 0
    fi
    nginx -t >&2 || return "$EXIT_VERIFY"
    if service_active; then
        systemctl reload "$UNIT" >&2 || return "$EXIT_VERIFY"
    else
        systemctl enable --now "$UNIT" >&2 || return "$EXIT_VERIFY"
    fi
}

# write_file <logical-path> <mode>: content on stdin, atomic, tracked. Returns 0
# when the file changed and 10 when identical, the rule of render_template.
write_file() {
    local path="$1" mode="$2" dest tmp
    dest="$(root_path "$path")"
    if [[ -n "$_PENDING_NAME" ]]; then
        track_file "$path"
    fi
    mkdir -p "${dest%/*}"
    tmp="$(mktemp "${dest%/*}/.${dest##*/}.XXXXXX")"
    cat >"$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 10
    fi
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
}

# --- API key and certificate ------------------------------------------------------

valid_key() { [[ "$1" =~ ^[A-Za-z0-9._~-]{16,128}$ ]]; }

# resolve_api_key: the channels of the contract (file or stdin, environment),
# then the key already installed, else a generated one. Prints it, never logs it.
resolve_api_key() {
    local key="" file
    file="$(root_path "$(secret_file)")"
    if [[ -n "$API_KEY_FILE" ]]; then
        key="$(read_secret "$API_KEY_FILE")"
    elif [[ -n "$(get_option "$NAME" api-key)" ]]; then
        key="$(get_option "$NAME" api-key)"
    elif [[ -s "$file" ]]; then
        IFS= read -r key <"$file" || true
    else
        key="$(generate_secret)"
    fi
    valid_key "$key" || die "$EXIT_USAGE" "the API key must be 16 to 128 characters among A-Z a-z 0-9 . _ ~ -"
    printf '%s\n' "$key"
}

store_api_key() {
    local rc=0
    printf '%s\n' "$1" | write_file "$(secret_file)" 0600 || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
}

# cert_matches: a certificate and its key exist and already cover the server name.
cert_matches() {
    local cert prev
    prev="$(recorded_tls)"
    # a certificate left by another strategy is not ours to keep
    [[ -z "$prev" || "$prev" == self-signed ]] || return 1
    cert="$(root_path "$(tls_cert_file)")"
    [[ -f "$cert" && -f "$(root_path "$(tls_key_file)")" ]] &&
        openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -qF "$SERVER_NAME"
}

# machine_addresses: the addresses of global scope of this machine (not loopback, not link-local), one
# per line. EASY_CS_AI_NGINX_ADDRESSES (space separated) replaces the detection, for the tests; in
# test mode without it there is none, the machine running the tests is not the one being installed.
machine_addresses() {
    if [[ -n "${EASY_CS_AI_NGINX_ADDRESSES+x}" ]]; then
        # shellcheck disable=SC2086
        [[ -z "$EASY_CS_AI_NGINX_ADDRESSES" ]] || printf '%s\n' $EASY_CS_AI_NGINX_ADDRESSES
        return 0
    fi
    ! is_test_root || return 0
    if command -v ip >/dev/null 2>&1; then
        ip -o addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
    elif command -v hostname >/dev/null 2>&1; then
        # shellcheck disable=SC2046
        printf '%s\n' $(hostname -I 2>/dev/null)
    fi
}

# certificate_addresses: ",IP:<address>" for each address of the machine, only for a self-signed
# certificate with no --server-name (the address of the VM is usually not known when its script is
# generated, docs/spec-two-vm.md#the-certificate-of-the-engine-vm). With a name given the certificate
# is the one of the name, as before.
certificate_addresses() {
    local addr
    [[ -z "$SERVER_NAME_GIVEN" && "$TLS" == self-signed ]] || return 0
    while IFS= read -r addr; do
        [[ "$addr" =~ ^[0-9A-Fa-f.:]+$ && "$addr" != 127.0.0.1 && "$addr" != "$SERVER_NAME" ]] || continue
        printf ',IP:%s' "$addr"
    done < <(machine_addresses | sort -u)
}

make_certificate() {
    local cert key san subject
    cert="$(root_path "$(tls_cert_file)")"
    key="$(root_path "$(tls_key_file)")"
    track_file "$(tls_cert_file)"
    track_file "$(tls_key_file)"
    if cert_matches; then
        log_info "the certificate already covers $SERVER_NAME"
        return 0
    fi
    mkdir -p "${cert%/*}" "${key%/*}"
    chmod 0700 "${key%/*}"
    if [[ "$SERVER_NAME" =~ ^[0-9.]+$ ]]; then
        san="IP:$SERVER_NAME"
    else
        san="DNS:$SERVER_NAME"
    fi
    san="$san,DNS:localhost,IP:127.0.0.1$(certificate_addresses)"
    # a common name is limited to 64 characters (a fully qualified container hostname can be longer);
    # the names are all in the subject alternative name, which is what clients check
    subject="/CN=$SERVER_NAME"
    ((${#SERVER_NAME} <= 64)) || subject="/O=easy-cs-ai"
    log_info "generating a self-signed certificate for $SERVER_NAME"
    (umask 077 && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj "$subject" -addext "subjectAltName=$san" \
        -keyout "$key" -out "$cert" 2>/dev/null) || die "$EXIT_ERROR" "could not generate the certificate"
    chmod 0644 "$cert"
    chmod 0600 "$key"
}

# --- Provided certificate -----------------------------------------------------------

# key_pem: the private key given by --tls-key-file (file or stdin) or the environment.
key_pem() {
    local value mode
    if [[ "$TLS_KEY_FILE" == - ]]; then
        value="$(cat)"
    elif [[ -n "$TLS_KEY_FILE" ]]; then
        [[ -f "$TLS_KEY_FILE" ]] || die "$EXIT_USAGE" "TLS key file not found: $TLS_KEY_FILE"
        mode="$(stat -c '%a' "$TLS_KEY_FILE")"
        if ((8#$mode & 8#077)); then
            die "$EXIT_USAGE" "TLS key file $TLS_KEY_FILE has mode $mode, 600 or stricter required"
        fi
        value="$(cat "$TLS_KEY_FILE")"
    else
        value="$(get_option "$NAME" tls-key)"
    fi
    [[ -n "$value" ]] || die "$EXIT_USAGE" "the TLS key is empty"
    printf '%s\n' "$value"
}

# check_pair <cert-file> <key-pem>: valid, not expired, and the key belongs to it.
check_pair() {
    local cert="$1" key="$2" from_cert from_key
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "$EXIT_USAGE" "$cert is not a PEM certificate"
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || die "$EXIT_USAGE" "the certificate $cert has expired"
    from_cert="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)"
    from_key="$(printf '%s\n' "$key" | openssl pkey -pubout -passin pass: 2>/dev/null || true)"
    if [[ -z "$from_key" || "$from_cert" != "$from_key" ]]; then
        die "$EXIT_USAGE" "the TLS key is unreadable (an encrypted key is not supported) or does not match the certificate"
    fi
    openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1 || log_warn "the certificate expires in less than 30 days"
    openssl x509 -in "$cert" -noout -checkhost "$SERVER_NAME" 2>/dev/null | grep -q 'does match' ||
        log_warn "the certificate does not cover the server name $SERVER_NAME"
}

install_provided() {
    local cert_src pem rc=0
    cert_src="$(get_option "$NAME" tls-cert)"
    if [[ -z "$cert_src" ]]; then
        log_info "keeping the provided certificate already installed"
        track_file "$(tls_cert_file)"
        track_file "$(tls_key_file)"
        return 0
    fi
    [[ -r "$cert_src" ]] || die "$EXIT_USAGE" "certificate not readable: $cert_src"
    pem="$(key_pem)" || exit "$?"
    check_pair "$cert_src" "$pem"
    write_file "$(tls_cert_file)" 0644 <"$cert_src" || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
    rc=0
    printf '%s\n' "$pem" | write_file "$(tls_key_file)" 0600 || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
    log_info "installed the provided certificate"
}

# --- Let's Encrypt -------------------------------------------------------------------

remove_acme() {
    rm -f "$(root_path "$ACME_CONF")"
    rm -rf "$(root_path "$ACME_ROOT")"
}

# render_acme: the port 80 server that answers the HTTP-01 challenge.
render_acme() {
    local rc=0
    export DOLLAR='$' NGX_SERVER_NAME="$SERVER_NAME" NGX_ACME_ROOT="$ACME_ROOT"
    if [[ "$PORT" == 443 ]]; then NGX_PORT_SUFFIX=""; else NGX_PORT_SUFFIX=":$PORT"; fi
    export NGX_PORT_SUFFIX
    track_file "$ACME_ROOT"
    mkdir -p "$(root_path "$ACME_ROOT")"
    render_template "$TEMPLATE_DIR/acme.conf" "$ACME_CONF" 0644 root:root || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
}

# obtain_letsencrypt: certbot, once. The renewal is certbot's own timer, and its
# deploy hook reloads nginx. A failure is exit 5, never a self-signed certificate.
obtain_letsencrypt() {
    local email args
    if [[ -s "$(root_path "$(cert_path)")" ]]; then
        log_info "a Let's Encrypt certificate already exists for $SERVER_NAME, certbot renews it"
        return 0
    fi
    email="$(get_option "$NAME" tls-email)"
    args=(certbot certonly --webroot -w "$ACME_ROOT" -d "$SERVER_NAME" --cert-name "$SERVER_NAME"
        --non-interactive --agree-tos --deploy-hook "systemctl reload $UNIT")
    if [[ -n "$email" ]]; then
        args+=(-m "$email")
    else
        args+=(--register-unsafely-without-email)
    fi
    if is_test_root; then
        log_info "(test mode) would run: ${args[*]}"
        return 0
    fi
    log_info "requesting a certificate for $SERVER_NAME from Let's Encrypt"
    "${args[@]}" >&2 ||
        die "$EXIT_NETWORK" "Let's Encrypt refused or could not be reached; the domain must point to this machine and port 80 be open (see /var/log/letsencrypt/letsencrypt.log)"
}

# --- Probe --------------------------------------------------------------------------

# probe_code [<key>]: HTTP status of the health path, the certificate pinned
# (verification is never disabled). The key goes through curl's config on
# stdin, not on the command line.
probe_code() {
    local host url args=(-sS -o /dev/null -w '%{http_code}' --max-time 5)
    host="$(client_host "$BIND")"
    url="https://$host:$PORT$HEALTH_PATH"
    case "$TLS" in
    self-signed) args+=(--cacert "$(root_path "$(tls_cert_file)")") ;;
    letsencrypt)
        # trusted by the system: connect by name so that it is verified
        url="https://$SERVER_NAME:$PORT$HEALTH_PATH"
        args+=(--resolve "$SERVER_NAME:$PORT:$host")
        ;;
    # provided: the CA may be unknown to this machine. The request only reaches the
    # loopback to prove nginx and the key; served_cert_matches proves the certificate.
    provided) args+=(--insecure) ;;
    esac
    if [[ -n "${1:-}" ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "$1" | curl "${args[@]}" -K - "$url" 2>/dev/null || true
    else
        curl "${args[@]}" "$url" 2>/dev/null || true
    fi
}

# served_cert_matches: nginx serves the certificate that was provided.
served_cert_matches() {
    local served file
    served="$(openssl s_client -connect "$(client_host "$BIND"):$PORT" -servername "$SERVER_NAME" </dev/null 2>/dev/null |
        openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
    file="$(openssl x509 -in "$(root_path "$(tls_cert_file)")" -noout -fingerprint -sha256 2>/dev/null || true)"
    [[ -n "$served" && "$served" == "$file" ]]
}

# probe_ok <key>: 401 without the key and 200 with it, which proves TLS and auth.
probe_ok() {
    [[ "$(probe_code "")" == 401 && "$(probe_code "$1")" == 200 ]] &&
        { [[ "$TLS" != provided ]] || served_cert_matches; }
}

wait_for_proxy() {
    local key="$1" deadline=$((SECONDS + HEALTH))
    while :; do
        probe_ok "$key" && return 0
        if systemctl is-failed --quiet "$UNIT"; then
            log_error "$UNIT failed while waiting for the proxy"
            return "$EXIT_VERIFY"
        fi
        if ((SECONDS >= deadline)); then
            log_error "the proxy did not answer 401 without the key and 200 with it within ${HEALTH}s"
            return "$EXIT_VERIFY"
        fi
        sleep 2
    done
}

# --- install ------------------------------------------------------------------------

preflight() {
    require_root
    require_platform
    _require_jq
    if is_test_root; then
        return 0
    fi
    if port_in_use && ! { service_active && state_read "$NAME" >/dev/null 2>&1; }; then
        die "$EXIT_PRECONDITION" "port $PORT is already in use by another process"
    fi
    # the HTTP-01 challenge needs port 80: ours, or nginx's own (the distribution's default site)
    if [[ "$TLS" == letsencrypt ]] && port_in_use 80 && ! service_active; then
        die "$EXIT_PRECONDITION" "port 80 is in use by another process, Let's Encrypt needs it"
    fi
}

# render_all <key>: the two configuration files. 0 when one changed, 10 when none.
render_all() {
    local identical=1 rc pair template dest mode
    export DOLLAR='$'
    NGX_LISTEN="$(listen_address)"
    NGX_SERVER_NAME="$SERVER_NAME"
    NGX_CERT="$(root_path "$(cert_path)")"
    NGX_KEY="$(root_path "$(key_path)")"
    NGX_DIR="$(root_path "$NGX_DIR_LOGICAL")"
    NGX_API_KEY="$1"
    export NGX_LISTEN NGX_SERVER_NAME NGX_CERT NGX_KEY NGX_DIR NGX_API_KEY
    mkdir -p "$(root_path "$UPSTREAM_DIR")" "$(root_path "$SITE_DIR")"
    track_file "$NGX_DIR_LOGICAL"
    for pair in "api-key.conf|$NGX_DIR_LOGICAL/api-key.conf|0600" "easy-cs-ai.conf|$MAIN_CONF|0644"; do
        rc=0
        IFS='|' read -r template dest mode <<<"$pair"
        render_template "$TEMPLATE_DIR/$template" "$dest" "$mode" root:root || rc=$?
        if ((rc == 0)); then
            identical=0
        elif ((rc != 10)); then
            exit "$rc"
        fi
    done
    return "$((identical ? 10 : 0))"
}

record_state() {
    local json files
    files="$( (pending_read "$NAME"; state_read "$NAME" 2>/dev/null || true) | jq -sc '[.[] | (.files // [])[]] | unique')"
    json="$(jq -n --arg v "$(nginx_version)" --arg sv "$SCRIPT_VERSION" --arg port "$PORT" --arg bind "$BIND" --arg sport "$SITE_PORT" \
        --arg sn "$SERVER_NAME" --arg tls "$TLS" --arg unit "$UNIT" --arg cert "$(cert_path)" \
        --arg email "$(get_option "$NAME" tls-email)" \
        --arg apikey "$(secret_file)" --arg tlskey "$(tls_key_file)" --argjson files "$files" \
        --argjson default "$MAKE_DEFAULT" '{
        name: "nginx", type: "proxy", version: $v, script_version: $sv,
        params: ({ port: $port, bind: $bind, "site-port": $sport, "server-name": $sn, tls: $tls }
          + (if $tls == "letsencrypt" and $email != "" then { "tls-email": $email } else {} end)),
        listen: { address: $bind, port: ($port | tonumber), site_port: ($sport | tonumber), tls: $tls, certificate: $cert },
        service: { unit: $unit }, requires: [], files: $files, data_dirs: [],
        secrets: ([$apikey] + (if $tls == "letsencrypt" then [] else [$tlskey] end))
      } + (if $default == 1 then { default: true } else {} end)')"
    if ! state_read "$NAME" >/dev/null 2>&1; then
        json="$(jq '. + { upstreams: [], sites: [] }' <<<"$json")"
    fi
    state_write "$NAME" "$json"
}

do_install() {
    local key rc=0
    pending_begin "$TYPE" "$NAME"
    # `|| exit`: this runs under `||` in run_logged, where set -e is off.
    key="$(resolve_api_key)" || exit "$?"
    if [[ "$TLS" == letsencrypt ]]; then
        apt_install nginx openssl curl ca-certificates certbot
    else
        apt_install nginx openssl curl ca-certificates
    fi
    mkdir -p "$(root_path "$(config_dir_logical)/secrets")"
    chmod 0700 "$(root_path "$(config_dir_logical)/secrets")"
    store_api_key "$key"
    case "$TLS" in
    self-signed)
        remove_acme
        make_certificate
        ;;
    provided)
        remove_acme
        install_provided
        ;;
    letsencrypt)
        render_acme
        nginx_reload || exit "$EXIT_VERIFY"
        obtain_letsencrypt
        ;;
    esac
    render_all "$key" || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
    nginx_reload || {
        log_error "the nginx configuration is invalid; 'easy-cs-ai uninstall proxy nginx' removes what was written"
        exit "$EXIT_VERIFY"
    }
    systemd_enable_now "$UNIT"
    if is_test_root; then
        log_info "(test mode) health check skipped"
    else
        wait_for_proxy "$key" || {
            journalctl -u "$UNIT" -n 20 --no-pager >&2 || true
            exit "$EXIT_VERIFY"
        }
    fi
    record_state
    if ((MAKE_DEFAULT)); then
        defaults_set "$TYPE" "$NAME"
    fi
    pending_remove "$NAME"
    log_info "nginx proxy is installed on https://$SERVER_NAME:$PORT (certificate: $TLS)"
}

cmd_install() {
    preflight
    if is_dry_run; then
        log_info "dry run: would install the nginx package, generate the API key, set up the $TLS" \
            "certificate for $SERVER_NAME, write $MAIN_CONF (listen $(listen_address)), reload nginx and record the state"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" install run_logged install do_install
}

# --- uninstall ----------------------------------------------------------------------

remove_path() {
    local path="$1"
    if [[ "$path" != /?* || "$path" == *..* ]]; then
        log_warn "ignoring suspicious path in state: $path"
        return 0
    fi
    rm -rf "$(root_path "$path")"
}

do_uninstall() {
    local state="" pending="" other path
    state="$(state_read "$NAME" 2>/dev/null || true)"
    pending="$(pending_read "$NAME" 2>/dev/null || true)"
    if [[ -z "$state" && -z "$pending" ]]; then
        die "$EXIT_PRECONDITION" "$NAME is not installed"
    fi
    if ((!FORCE)); then
        # shellcheck disable=SC2119
        while read -r other; do
            [[ "$other" == "$NAME" || -z "$other" ]] && continue
            if state_read "$other" | jq -e --arg n "$NAME" '(.requires // []) | index($n)' >/dev/null; then
                die "$EXIT_PRECONDITION" "$other requires $NAME, uninstall it first or use --force"
            fi
        done < <(state_list)
    fi
    while IFS= read -r path; do
        [[ -n "$path" ]] && remove_path "$path"
    done < <(jq -rs '[.[] | (.files // [])[]] | unique[]' <<<"$state $pending")
    remove_path "$MAIN_CONF"
    remove_path "$NGX_DIR_LOGICAL"
    remove_path "$ACME_CONF"
    remove_path "$ACME_ROOT"
    if [[ "$TLS" == letsencrypt ]]; then
        if ((PURGE)) && ! is_test_root && command -v certbot >/dev/null 2>&1; then
            certbot delete --cert-name "$SERVER_NAME" --non-interactive >&2 ||
                log_warn "could not delete the Let's Encrypt certificate of $SERVER_NAME"
        else
            log_info "the Let's Encrypt certificate of $SERVER_NAME is kept (--purge deletes it)"
        fi
    fi
    # The distribution's package and service are shared: they stay, without our configuration.
    if service_active; then
        nginx_reload || log_warn "nginx did not reload after the clean-up, check: nginx -t"
    fi
    state_remove "$NAME"
    pending_remove "$NAME"
    log_info "the proxy configuration is removed (the nginx package and service are kept)"
}

cmd_uninstall() {
    require_root
    _require_jq
    if is_dry_run; then
        log_info "dry run: would remove the proxy configuration, certificate, API key and the state"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" uninstall run_logged uninstall do_uninstall
}

# --- status -------------------------------------------------------------------------

cmd_status() {
    _require_jq
    local json installed=false running=false healthy=false version=null rc=0 key="" file
    if json="$(state_read "$NAME")"; then
        installed=true
        version="$(jq '.version' <<<"$json")"
        service_active && running=true
        if ! is_test_root; then
            file="$(secret_file)"
            if [[ -r "$file" ]]; then
                IFS= read -r key <"$file" || true
            fi
            if [[ -n "$key" ]]; then
                ! probe_ok "$key" || healthy=true
            else
                # Unprivileged: the key is unreadable, but a 401 without it still proves TLS and auth.
                [[ "$(probe_code "")" != 401 ]] || healthy=true
            fi
        fi
        [[ "$healthy" == true ]] || rc=$EXIT_VERIFY
    else
        rc=$EXIT_PRECONDITION
    fi
    jq -n --argjson i "$installed" --argjson r "$running" --argjson h "$healthy" --argjson v "$version" \
        --argjson names "$(certificate_names)" \
        '{ schema_version: 1, name: "nginx", installed: $i, running: $r, healthy: $h, version: $v, certificate_names: $names }'
    return "$rc"
}

# certificate_names: the DNS names and the addresses of the certificate nginx serves, as a JSON array,
# read from the certificate itself and not from the state (docs/spec-two-vm.md): what the administrator
# needs to know to pick the host of the URL the web VM uses. [] when it cannot be read.
certificate_names() {
    local cert out
    cert="$(root_path "$(cert_path)")"
    if [[ -r "$cert" ]] && out="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)"; then
        out="$(sed -n '2,$p' <<<"$out" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/^DNS://; s/^IP Address://' | grep . || true)"
        printf '%s' "$out" | jq -R . | jq -sc .
    else
        printf '[]\n'
    fi
}

# --- upstreams ----------------------------------------------------------------------

require_installed() {
    state_read "$NAME" >/dev/null 2>&1 || die "$EXIT_PRECONDITION" "$NAME is not installed"
}

check_upstream_name() {
    if [[ -z "${1:-}" || ! "$1" =~ ^[a-z0-9][a-z0-9.-]*$ || "$1" == *..* ]]; then
        die "$EXIT_USAGE" "invalid or missing upstream name '${1:-}' (lowercase letters, digits, . and -)"
    fi
}

check_upstream_url() {
    if [[ ! "${1:-}" =~ ^https?://[][A-Za-z0-9.:-]+(/[A-Za-z0-9._~/%-]*)?$ ]]; then
        die "$EXIT_USAGE" "invalid or missing upstream URL '${1:-}'"
    fi
}

do_add_upstream() {
    local name="$1" url="${2%/}" dest backup="" rc=0
    dest="$(root_path "$UPSTREAM_DIR/$name.conf")"
    if [[ -f "$dest" ]]; then
        backup="$(mktemp)"
        cp -p "$dest" "$backup"
    fi
    export DOLLAR='$' NGX_UPSTREAM="$name" NGX_UPSTREAM_URL="$url"
    render_template "$TEMPLATE_DIR/upstream.conf" "$UPSTREAM_DIR/$name.conf" 0644 root:root || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
    if ((rc == 0)) && ! nginx_reload; then
        if [[ -n "$backup" ]]; then cp -p "$backup" "$dest"; else rm -f "$dest"; fi
        [[ -z "$backup" ]] || rm -f "$backup"
        die "$EXIT_VERIFY" "nginx refused the configuration for $name, change reverted"
    fi
    [[ -z "$backup" ]] || rm -f "$backup"
    state_write "$NAME" "$(state_read "$NAME" | jq --arg n "$name" --arg u "$url" --arg f "$UPSTREAM_DIR/$name.conf" '{
        name: .name, type: .type,
        upstreams: (((.upstreams // []) | map(select(.name != $n))) + [{ name: $n, url: $u }]),
        files: (((.files // []) + [$f]) | unique)
      }')"
    log_info "upstream $name now fronts $url"
    jq -n --arg u "$(public_url "$name")" '{ url: $u }'
}

cmd_add_upstream() {
    check_upstream_name "${POSITIONAL[0]:-}"
    check_upstream_url "${POSITIONAL[1]:-}"
    require_root
    require_installed
    if is_dry_run; then
        log_info "dry run: would expose ${POSITIONAL[1]} under /${POSITIONAL[0]}/"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" add-upstream run_logged add-upstream do_add_upstream "${POSITIONAL[0]}" "${POSITIONAL[1]}"
}

do_remove_upstream() {
    local name="$1"
    rm -f "$(root_path "$UPSTREAM_DIR/$name.conf")"
    nginx_reload || die "$EXIT_VERIFY" "nginx did not accept the configuration after removing $name"
    state_write "$NAME" "$(state_read "$NAME" | jq --arg n "$name" --arg f "$UPSTREAM_DIR/$name.conf" '{
        name: .name, type: .type,
        upstreams: ((.upstreams // []) | map(select(.name != $n))),
        files: ((.files // []) | map(select(. != $f)))
      }')"
    log_info "upstream $name is removed"
}

# list-upstreams: the models the proxy fronts, each with the URL a client of another machine uses (the
# state keeps the internal URL of the engine, which no other machine can use). Read-only: no root, no
# lock, not journaled; it answers whether the proxy is healthy or not. It never prints the API key.
cmd_list_upstreams() {
    _require_jq
    require_installed
    local name list='[]'
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        list="$(jq -c --arg n "$name" --arg u "$(public_url "$name")" '. + [{name: $n, url: $u}]' <<<"$list")"
    done < <(state_read "$NAME" | jq -r '(.upstreams // [])[].name')
    jq -n --argjson l "$list" '$l'
}

cmd_remove_upstream() {
    check_upstream_name "${POSITIONAL[0]:-}"
    require_root
    require_installed
    if is_dry_run; then
        log_info "dry run: would stop exposing ${POSITIONAL[0]}"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" remove-upstream run_logged remove-upstream do_remove_upstream "${POSITIONAL[0]}"
}

# --- sites --------------------------------------------------------------------------
# A site is a web page for browsers (the chat interface): its own `server` on its
# own port, same certificate, no API key, so the API server keeps requiring the key
# on every path (docs/decision-librechat-install.md, point 3).

check_site_url() {
    if [[ ! "${1:-}" =~ ^https?://[][A-Za-z0-9.:-]+/?$ ]]; then
        die "$EXIT_USAGE" "invalid or missing site URL '${1:-}' (a scheme, a host and a port, no path)"
    fi
}

# site_var <name>: the name as a part of an nginx variable.
site_var() { printf '%s\n' "${1//[^A-Za-z0-9]/_}"; }

# check_site_slot <name>: one site per site port, which is not the API port and
# is free (nginx itself holding it for this very site is fine).
check_site_slot() {
    local name="$1" other own
    if [[ "$SITE_PORT" == "$PORT" ]]; then
        die "$EXIT_PRECONDITION" "the site port $SITE_PORT is the HTTPS port of the API: reinstall nginx with another --site-port"
    fi
    other="$(state_read "$NAME" | jq -r --arg n "$name" '[(.sites // [])[] | select(.name != $n) | .name][0] // empty')"
    if [[ -n "$other" ]]; then
        die "$EXIT_PRECONDITION" "the site $other already uses port $SITE_PORT: one site per --site-port"
    fi
    if ! is_test_root; then
        own="$(state_read "$NAME" | jq -r --arg n "$name" '(.sites // []) | any(.name == $n)')"
        if [[ "$own" != true ]] && port_in_use "$SITE_PORT"; then
            die "$EXIT_PRECONDITION" "port $SITE_PORT is already in use by another process"
        fi
    fi
}

do_add_site() {
    local name="$1" url="${2%/}" file="$SITE_DIR/$1.conf" dest backup="" rc=0
    check_site_slot "$name"
    dest="$(root_path "$file")"
    if [[ -f "$dest" ]]; then
        backup="$(mktemp)"
        cp -p "$dest" "$backup"
    fi
    mkdir -p "$(root_path "$SITE_DIR")"
    DOLLAR='$' NGX_SITE="$name" NGX_SITE_URL="$url" NGX_SERVER_NAME="$SERVER_NAME"
    NGX_SITE_VAR="$(site_var "$name")"
    NGX_SITE_LISTEN="$(listen_address "$SITE_PORT")"
    NGX_CERT="$(root_path "$(cert_path)")"
    NGX_KEY="$(root_path "$(key_path)")"
    export DOLLAR NGX_SITE NGX_SITE_VAR NGX_SITE_URL NGX_SITE_LISTEN NGX_SERVER_NAME NGX_CERT NGX_KEY
    render_template "$TEMPLATE_DIR/site.conf" "$file" 0644 root:root || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
    if ((rc == 0)) && ! nginx_reload; then
        if [[ -n "$backup" ]]; then cp -p "$backup" "$dest"; else rm -f "$dest"; fi
        [[ -z "$backup" ]] || rm -f "$backup"
        die "$EXIT_VERIFY" "nginx refused the configuration for the site $name, change reverted"
    fi
    [[ -z "$backup" ]] || rm -f "$backup"
    state_write "$NAME" "$(state_read "$NAME" | jq --arg n "$name" --arg u "$url" --arg f "$file" --arg sp "$SITE_PORT" '{
        name: .name, type: .type,
        params: ((.params // {}) + { "site-port": $sp }),
        listen: ((.listen // {}) + { site_port: ($sp | tonumber) }),
        sites: (((.sites // []) | map(select(.name != $n))) + [{ name: $n, url: $u }]),
        files: (((.files // []) + [$f]) | unique)
      }')"
    log_info "site $name now fronts $url"
    jq -n --arg u "$(site_url)" '{ url: $u }'
}

cmd_add_site() {
    check_upstream_name "${POSITIONAL[0]:-}"
    check_site_url "${POSITIONAL[1]:-}"
    require_root
    require_installed
    if is_dry_run; then
        log_info "dry run: would serve ${POSITIONAL[1]} on https://$SERVER_NAME:$SITE_PORT/"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" add-site run_logged add-site do_add_site "${POSITIONAL[0]}" "${POSITIONAL[1]}"
}

do_remove_site() {
    local name="$1"
    rm -f "$(root_path "$SITE_DIR/$name.conf")"
    nginx_reload || die "$EXIT_VERIFY" "nginx did not accept the configuration after removing the site $name"
    state_write "$NAME" "$(state_read "$NAME" | jq --arg n "$name" --arg f "$SITE_DIR/$name.conf" '{
        name: .name, type: .type,
        sites: ((.sites // []) | map(select(.name != $n))),
        files: ((.files // []) | map(select(. != $f)))
      }')"
    log_info "site $name is removed"
}

cmd_remove_site() {
    check_upstream_name "${POSITIONAL[0]:-}"
    require_root
    require_installed
    if is_dry_run; then
        log_info "dry run: would stop serving the site ${POSITIONAL[0]}"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" remove-site run_logged remove-site do_remove_site "${POSITIONAL[0]}"
}

# show-key: the only action that prints a secret, on explicit request.
cmd_show_key() {
    require_root
    require_installed
    local file
    file="$(root_path "$(secret_file)")"
    [[ -r "$file" ]] || die "$EXIT_PRECONDITION" "the API key file is missing: $(secret_file)"
    cat "$file"
}

# --- main ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    if wants_help; then
        usage
        return 0
    fi
    if wants_version; then
        printf '%s\n' "$SCRIPT_VERSION"
        return 0
    fi
    case " $ACTIONS " in
    *" $ACTION "*) ;;
    *) die "$EXIT_USAGE" "unknown action '$ACTION' (expected: $ACTIONS)" ;;
    esac
    if [[ "$ACTION" == describe ]]; then
        describe
        return 0
    fi
    if [[ "$ACTION" != install ]]; then
        adopt_recorded_params
    fi
    resolve_options
    case "$ACTION" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    add-upstream) cmd_add_upstream ;;
    remove-upstream) cmd_remove_upstream ;;
    list-upstreams) cmd_list_upstreams ;;
    add-site) cmd_add_site ;;
    remove-site) cmd_remove_site ;;
    show-key) cmd_show_key ;;
    esac
}

main "$@"
