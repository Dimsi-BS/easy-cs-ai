#!/usr/bin/env bash
# nginx reverse proxy install script (HTTPS + API key), see
# docs/spec-script-contract.md, search/nginx.md and docs/decision-nginx-certificates.md.
#
#   nginx.sh <action> [options]
#   actions: install uninstall status describe add-upstream remove-upstream show-key
set -euo pipefail

readonly NAME=nginx
readonly TYPE=proxy
readonly SCRIPT_VERSION=0.1.0
readonly UNIT=nginx.service
readonly HEALTH_TIMEOUT=30
readonly MAIN_CONF=/etc/nginx/conf.d/easy-cs-ai.conf
readonly NGX_DIR_LOGICAL=/etc/nginx/easy-cs-ai
readonly UPSTREAM_DIR=/etc/nginx/easy-cs-ai/upstreams
readonly HEALTH_PATH=/easy-cs-ai/health
readonly ACTIONS="install uninstall status describe add-upstream remove-upstream show-key"
# Only the strategy that is implemented, see the decision document.
readonly TLS_IMPLEMENTED="self-signed"
readonly TLS_RESERVED="provided letsencrypt"

LIB_DIR="${EASY_CS_AI_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)}"
readonly LIB_DIR
readonly TEMPLATE_DIR="$LIB_DIR/../templates/nginx"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

ACTION="" FORCE=0 MAKE_DEFAULT=0 API_KEY_FILE=""
POSITIONAL=()

usage() {
    cat <<EOF
Usage: nginx.sh <action> [options]

Actions: $ACTIONS

  add-upstream <name> <url>   expose an internal HTTP URL under /<name>/ (prints its public URL)
  remove-upstream <name>      stop exposing it
  show-key                    print the API key (the only action that prints a secret)

Options:
  --port <n>              HTTPS port (default 443, EASY_CS_AI_NGINX_PORT)
  --bind <address>        listening address (default 0.0.0.0, EASY_CS_AI_NGINX_BIND)
  --server-name <name>    name in the certificate and the URLs (default: the hostname, EASY_CS_AI_NGINX_SERVER_NAME)
  --tls <strategy>        certificate strategy: self-signed (default). provided and letsencrypt are not implemented yet
  --api-key-file <path>   file holding the API key (mode 0600), or - for stdin; generated when absent
                          (EASY_CS_AI_NGINX_API_KEY is also read)
  --health-timeout <s>    seconds to wait for the proxy (default $HEALTH_TIMEOUT)
  --lock-timeout <s>      wait for a busy component lock instead of failing
  --default               install: make nginx the default proxy
  --force                 uninstall: even if another component requires it
  --purge                 uninstall: accepted, the proxy keeps no user data
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
        --port | --bind | --server-name | --tls | --health-timeout | --lock-timeout)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            set_option "$NAME" "${opt#--}" "$1"
            shift
            ;;
        --port=* | --bind=* | --server-name=* | --tls=* | --health-timeout=* | --lock-timeout=*)
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
        --default) MAKE_DEFAULT=1 ;;
        --force) FORCE=1 ;;
        --purge) ;;
        -*) die "$EXIT_USAGE" "unknown option: $opt" ;;
        *) POSITIONAL+=("$opt") ;;
        esac
    done
}

default_server_name() { hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'localhost\n'; }

resolve_options() {
    set_option_default "$NAME" port 443
    set_option_default "$NAME" bind 0.0.0.0
    set_option_default "$NAME" server-name "$(default_server_name)"
    set_option_default "$NAME" tls "$TLS_IMPLEMENTED"
    set_option_default "$NAME" health-timeout "$HEALTH_TIMEOUT"
    PORT="$(get_option "$NAME" port)"
    BIND="$(get_option "$NAME" bind)"
    SERVER_NAME="$(get_option "$NAME" server-name)"
    TLS="$(get_option "$NAME" tls)"
    HEALTH="$(get_option "$NAME" health-timeout)"
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
        die "$EXIT_USAGE" "invalid port '$PORT'"
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
    case " $TLS_RESERVED " in
    *" $TLS "*) die "$EXIT_USAGE" "--tls $TLS is not implemented yet (see docs/decision-nginx-certificates.md), only $TLS_IMPLEMENTED is" ;;
    esac
    if [[ "$TLS" != "$TLS_IMPLEMENTED" ]]; then
        die "$EXIT_USAGE" "unknown --tls strategy '$TLS' (expected: $TLS_IMPLEMENTED)"
    fi
}

# adopt_recorded_params: for actions on an installed proxy, use the parameters
# recorded at install unless the caller gave others.
adopt_recorded_params() {
    local json key
    if json="$(state_read "$NAME")"; then
        for key in port bind server-name tls; do
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

# listen_address: the nginx `listen` value (an IPv6 address needs brackets).
listen_address() {
    local bind="$BIND"
    if [[ "$bind" == *:* && "$bind" != \[* ]]; then
        bind="[$bind]"
    fi
    printf '%s:%s\n' "$bind" "$PORT"
}

# public_url <upstream>: the OpenAI-style base URL of an upstream.
public_url() {
    local port=""
    [[ "$PORT" == 443 ]] || port=":$PORT"
    printf 'https://%s%s/%s/v1\n' "$SERVER_NAME" "$port" "$1"
}

# --- Paths (logical, EASY_CS_AI_ROOT is applied by root_path) -------------------

secret_file() { printf '%s/secrets/nginx.api-key\n' "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }
tls_key_file() { printf '%s/secrets/nginx.tls-key\n' "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }
tls_cert_file() { printf '%s/nginx/server.crt\n' "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }

# --- describe / helpers -----------------------------------------------------------

describe() {
    _require_jq
    jq -n --arg sv "$SCRIPT_VERSION" --argjson ht "$HEALTH_TIMEOUT" --arg actions "$ACTIONS" '{
        schema_version: 1, name: "nginx", type: "proxy", script_version: $sv,
        component_version: "distribution package", requires: [], provides: ["https", "api-key"],
        platforms: ["debian", "ubuntu"], health_timeout: $ht,
        native: { command: "nginx" },
        options: [
          { name: "port", env: "EASY_CS_AI_NGINX_PORT", default: "443", secret: false, description: "HTTPS port" },
          { name: "bind", env: "EASY_CS_AI_NGINX_BIND", default: "0.0.0.0", secret: false, description: "Listening address" },
          { name: "server-name", env: "EASY_CS_AI_NGINX_SERVER_NAME", default: "hostname", secret: false, description: "Name in the certificate and in the public URLs" },
          { name: "tls", env: "EASY_CS_AI_NGINX_TLS", default: "self-signed", secret: false, description: "Certificate strategy (only self-signed is implemented)" },
          { name: "api-key", env: "EASY_CS_AI_NGINX_API_KEY", default: "generated", secret: true, description: "API key clients send as a Bearer token" },
          { name: "health-timeout", env: "EASY_CS_AI_NGINX_HEALTH_TIMEOUT", default: ($ht | tostring), secret: false, description: "Seconds to wait for the proxy after a change" },
          { name: "lock-timeout", env: "EASY_CS_AI_NGINX_LOCK_TIMEOUT", default: "0", secret: false, description: "Seconds to wait for a busy component lock" }
        ],
        actions: ($actions | split(" "))
      }'
}

# run_logged <action> <command…>: journal start and end around a changing action.
run_logged() {
    local action="$1" start=$SECONDS rc=0
    shift
    log_event "$NAME $action start params=port=$PORT,bind=$BIND,server-name=$SERVER_NAME,tls=$TLS"
    ("$@") || rc=$?
    log_event "$NAME $action end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}

service_active() { ! is_test_root && systemctl is-active --quiet "$UNIT"; }

port_in_use() {
    command -v ss >/dev/null 2>&1 && [[ -n "$(ss -H -ltn "sport = :$PORT" 2>/dev/null)" ]]
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

valid_key() { [[ "$1" =~ ^[A-Za-z0-9._~-]{16,}$ ]]; }

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
    valid_key "$key" || die "$EXIT_USAGE" "the API key must be at least 16 characters among A-Z a-z 0-9 . _ ~ -"
    printf '%s\n' "$key"
}

store_api_key() {
    local rc=0
    printf '%s\n' "$1" | write_file "$(secret_file)" 0600 || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
}

# cert_matches: a certificate and its key exist and already cover the server name.
cert_matches() {
    local cert
    cert="$(root_path "$(tls_cert_file)")"
    [[ -f "$cert" && -f "$(root_path "$(tls_key_file)")" ]] &&
        openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -qF "$SERVER_NAME"
}

make_certificate() {
    local cert key san
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
    log_info "generating a self-signed certificate for $SERVER_NAME"
    (umask 077 && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj "/CN=$SERVER_NAME" -addext "subjectAltName=$san,DNS:localhost,IP:127.0.0.1" \
        -keyout "$key" -out "$cert" 2>/dev/null) || die "$EXIT_ERROR" "could not generate the certificate"
    chmod 0644 "$cert"
    chmod 0600 "$key"
}

# --- Probe --------------------------------------------------------------------------

# probe_code [<key>]: HTTP status of the health path, the certificate pinned
# (verification is never disabled). The key goes through curl's config on
# stdin, not on the command line.
probe_code() {
    local url cert
    url="https://$(client_host "$BIND"):$PORT$HEALTH_PATH"
    cert="$(root_path "$(tls_cert_file)")"
    if [[ -n "${1:-}" ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "$1" |
            curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$cert" -K - "$url" 2>/dev/null || true
    else
        curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$cert" "$url" 2>/dev/null || true
    fi
}

# probe_ok <key>: 401 without the key and 200 with it, which proves TLS and auth.
probe_ok() {
    [[ "$(probe_code "")" == 401 && "$(probe_code "$1")" == 200 ]]
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
}

# render_all <key>: the two configuration files. 0 when one changed, 10 when none.
render_all() {
    local identical=1 rc pair template dest mode
    export DOLLAR='$'
    NGX_LISTEN="$(listen_address)"
    NGX_SERVER_NAME="$SERVER_NAME"
    NGX_CERT="$(root_path "$(tls_cert_file)")"
    NGX_KEY="$(root_path "$(tls_key_file)")"
    NGX_DIR="$(root_path "$NGX_DIR_LOGICAL")"
    NGX_API_KEY="$1"
    export NGX_LISTEN NGX_SERVER_NAME NGX_CERT NGX_KEY NGX_DIR NGX_API_KEY
    mkdir -p "$(root_path "$UPSTREAM_DIR")"
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
    json="$(jq -n --arg v "$(nginx_version)" --arg sv "$SCRIPT_VERSION" --arg port "$PORT" --arg bind "$BIND" \
        --arg sn "$SERVER_NAME" --arg tls "$TLS" --arg unit "$UNIT" --arg cert "$(tls_cert_file)" \
        --arg apikey "$(secret_file)" --arg tlskey "$(tls_key_file)" --argjson files "$files" \
        --argjson default "$MAKE_DEFAULT" '{
        name: "nginx", type: "proxy", version: $v, script_version: $sv,
        params: { port: $port, bind: $bind, "server-name": $sn, tls: $tls },
        listen: { address: $bind, port: ($port | tonumber), tls: $tls, certificate: $cert },
        service: { unit: $unit }, requires: [], files: $files, data_dirs: [],
        secrets: [$apikey, $tlskey]
      } + (if $default == 1 then { default: true } else {} end)')"
    if ! state_read "$NAME" >/dev/null 2>&1; then
        json="$(jq '. + { upstreams: [] }' <<<"$json")"
    fi
    state_write "$NAME" "$json"
}

do_install() {
    local key rc=0
    pending_begin "$TYPE" "$NAME"
    # `|| exit`: this runs under `||` in run_logged, where set -e is off.
    key="$(resolve_api_key)" || exit "$?"
    apt_install nginx openssl curl ca-certificates
    store_api_key "$key"
    make_certificate
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
    log_info "nginx proxy is installed on https://$SERVER_NAME:$PORT (self-signed certificate $(tls_cert_file))"
}

cmd_install() {
    preflight
    if is_dry_run; then
        log_info "dry run: would install the nginx package, generate the API key and a self-signed" \
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
        '{ schema_version: 1, name: "nginx", installed: $i, running: $r, healthy: $h, version: $v }'
    return "$rc"
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
    show-key) cmd_show_key ;;
    esac
}

main "$@"
