#!/usr/bin/env bash
# LibreChat install script (chat interface), see docs/spec-script-contract.md,
# search/librechat.md and docs/decision-librechat-install.md.
#
#   librechat.sh <action> [options]
#   actions: install uninstall status describe add-endpoint remove-endpoint
#
# LibreChat runs as three containers started by Docker Compose (the api, FerretDB
# and PostgreSQL), driven by a systemd unit. The api container shares the network
# of the machine to reach the engines on their loopback address. The nginx proxy
# serves the web interface over HTTPS (`proxy add-site`).
set -euo pipefail

readonly NAME=librechat
readonly TYPE=chat-interface
readonly SCRIPT_VERSION=0.1.0
readonly UNIT=easy-cs-ai-librechat.service
readonly HEALTH_TIMEOUT=300
readonly PROJECT=easy-cs-ai-librechat
readonly VOLUME_ENTRIES=("docker-volume:${PROJECT}_pgdata" "docker-volume:${PROJECT}_ferretdb-state")
readonly ACTIONS="install uninstall status describe add-endpoint remove-endpoint"
readonly DEFAULT_PORT=3080
readonly DEFAULT_DB_PORT=27017
readonly MIN_FREE_MB=12288
readonly PROXY=nginx
# LibreChat release, and the images of the stack pinned by digest: the ones of the
# FerretDB test (LibreChat v0.8.7, FerretDB 2.7.0 and its DocumentDB PostgreSQL
# 17-0.107.0-ferretdb-2.7.0). FerretDB and PostgreSQL are a pair pinned with the
# script. Another --version is pulled by tag.
readonly DEFAULT_VERSION=0.8.7
readonly IMAGE_API_REPO=ghcr.io/danny-avila/librechat
readonly IMAGE_API_DIGEST=sha256:c5db3331b845e1f289f8d04c0c77936c4bbe372f76730a804abc1c37e44d23a9
readonly IMAGE_FERRETDB=ghcr.io/ferretdb/ferretdb@sha256:5706414241eb84f0515512c37b46db0f1b1eac9e5ceb7e4c2523211c184b1985
readonly IMAGE_POSTGRES=ghcr.io/ferretdb/postgres-documentdb@sha256:2386795ec2aa7ae559304361979f1dc5708d383ee9020ae63dadc2940dfe58f7
readonly REGISTRATION_WARNING="registration is open: the first account created becomes the administrator, and anyone who reaches the site can sign up; close it with: easy-cs-ai install chat-interface librechat --allow-registration false"

LIB_DIR="${EASY_CS_AI_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)}"
readonly LIB_DIR
readonly TEMPLATE_DIR="$LIB_DIR/../templates/librechat"
readonly PROXY_SCRIPT="$LIB_DIR/../proxy/$PROXY.sh"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

ACTION="" FORCE=0 PURGE=0 MAKE_DEFAULT=0 ENDPOINT_MODEL="" ENDPOINT_KEY_FILE="" ENDPOINT_CA_FILE=""
POSITIONAL=()

usage() {
    cat <<EOF
Usage: librechat.sh <action> [options]

Actions: $ACTIONS

  add-endpoint <name> <url> [--model <model>] [--api-key-file <path|->] [--ca-file <path>]
                                                declare an OpenAI-compatible endpoint (prints its URL)
  remove-endpoint <name>                        remove it

Options:
  --port <n>                 listening port on the machine (default $DEFAULT_PORT, EASY_CS_AI_LIBRECHAT_PORT)
  --bind <address>           listening address (default 127.0.0.1, EASY_CS_AI_LIBRECHAT_BIND)
  --db-port <n>              loopback port of the database, FerretDB (default $DEFAULT_DB_PORT, EASY_CS_AI_LIBRECHAT_DB_PORT)
  --allow-registration <b>   true (default) or false: may anyone create an account
  --version <x.y.z>          LibreChat version (default $DEFAULT_VERSION, EASY_CS_AI_LIBRECHAT_VERSION)
  --model <model>            add-endpoint: the model the endpoint serves (else the engine's list is fetched)
  --api-key-file <path>      add-endpoint: the API key the endpoint expects (mode 0600, or - for stdin), kept as a secret
  --ca-file <path>           add-endpoint: the certificate (or CA) the endpoint is verified against, for a self-signed or private-CA proxy
  --health-timeout <s>       seconds to wait for LibreChat (default $HEALTH_TIMEOUT)
  --lock-timeout <s>         wait for a busy component lock instead of failing
  --default                  install: make LibreChat the default chat interface
  --force                    uninstall: even if another component requires it
  --purge                    uninstall: also delete the database, the images and the secrets
  --help --version --verbose --dry-run --json
EOF
}

# --- Options ------------------------------------------------------------------

# The contract gives --version two meanings: the common flag (print the script
# version) and, for install, the component version to install. A value after
# it selects the second; it is renamed so the common parser leaves it alone.
rename_version_option() {
    RENAMED=()
    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        if [[ "$arg" == --version && $# -gt 0 && "$1" != -* ]]; then
            RENAMED+=(--component-version "$1")
            shift
        elif [[ "$arg" == --version=* ]]; then
            RENAMED+=(--component-version "${arg#*=}")
        else
            RENAMED+=("$arg")
        fi
    done
}

parse_args() {
    rename_version_option "$@"
    parse_common_options "${RENAMED[@]}"
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
        --port | --bind | --db-port | --allow-registration | --health-timeout | --lock-timeout | --component-version)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            value="$1"
            shift
            opt="${opt#--}"
            set_option "$NAME" "${opt#component-}" "$value"
            ;;
        --port=* | --bind=* | --db-port=* | --allow-registration=* | --health-timeout=* | --lock-timeout=*)
            value="${opt#*=}"
            opt="${opt%%=*}"
            set_option "$NAME" "${opt#--}" "$value"
            ;;
        --model)
            once_only --model
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            ENDPOINT_MODEL="$1"
            shift
            ;;
        --model=*) once_only --model; ENDPOINT_MODEL="${opt#*=}" ;;
        --api-key-file)
            once_only --api-key-file
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            ENDPOINT_KEY_FILE="$1"
            shift
            ;;
        --api-key-file=*) once_only --api-key-file; ENDPOINT_KEY_FILE="${opt#*=}" ;;
        --ca-file)
            once_only --ca-file
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            ENDPOINT_CA_FILE="$1"
            shift
            ;;
        --ca-file=*) once_only --ca-file; ENDPOINT_CA_FILE="${opt#*=}" ;;
        --default) MAKE_DEFAULT=1 ;;
        --force) FORCE=1 ;;
        --purge) PURGE=1 ;;
        -*) die "$EXIT_USAGE" "unknown option: $opt" ;;
        *) POSITIONAL+=("$opt") ;;
        esac
    done
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)); }

resolve_options() {
    set_option_default "$NAME" port "$DEFAULT_PORT"
    set_option_default "$NAME" bind 127.0.0.1
    set_option_default "$NAME" db-port "$DEFAULT_DB_PORT"
    set_option_default "$NAME" allow-registration true
    set_option_default "$NAME" version "$DEFAULT_VERSION"
    set_option_default "$NAME" health-timeout "$HEALTH_TIMEOUT"
    PORT="$(get_option "$NAME" port)"
    BIND="$(get_option "$NAME" bind)"
    DB_PORT="$(get_option "$NAME" db-port)"
    ALLOW_REG="$(get_option "$NAME" allow-registration)"
    VERSION="$(get_option "$NAME" version)"
    HEALTH="$(get_option "$NAME" health-timeout)"
    valid_port "$PORT" || die "$EXIT_USAGE" "invalid port '$PORT'"
    valid_port "$DB_PORT" || die "$EXIT_USAGE" "invalid database port '$DB_PORT'"
    if [[ "$PORT" == "$DB_PORT" ]]; then
        die "$EXIT_USAGE" "--port and --db-port must differ"
    fi
    if [[ ! "$BIND" =~ ^[A-Za-z0-9.:-]+$ ]]; then
        die "$EXIT_USAGE" "invalid bind address '$BIND'"
    fi
    case "${ALLOW_REG,,}" in
    true | yes | 1) ALLOW_REG=true ;;
    false | no | 0) ALLOW_REG=false ;;
    *) die "$EXIT_USAGE" "invalid --allow-registration '$ALLOW_REG': true or false expected" ;;
    esac
    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z]+)*$ ]]; then
        die "$EXIT_USAGE" "invalid version '$VERSION'"
    fi
    if [[ ! "$HEALTH" =~ ^[0-9]+$ ]]; then
        die "$EXIT_USAGE" "invalid health timeout '$HEALTH'"
    fi
    if [[ "$VERSION" == "$DEFAULT_VERSION" ]]; then
        IMAGE_API="$IMAGE_API_REPO@$IMAGE_API_DIGEST"
    else
        IMAGE_API="$IMAGE_API_REPO:v$VERSION"
    fi
}

# adopt_recorded_params: for actions on an installed LibreChat, use the parameters
# recorded at install unless the caller gave others.
adopt_recorded_params() {
    local json key
    if json="$(state_read "$NAME")"; then
        for key in port bind db-port allow-registration; do
            set_option_default "$NAME" "$key" "$(jq -r --arg k "$key" '.params[$k] // empty' <<<"$json")"
        done
        set_option_default "$NAME" version "$(jq -r '.version // empty' <<<"$json")"
    fi
}

# client_host: address to reach the server (a wildcard bind is reached locally).
client_host() {
    case "$1" in
    0.0.0.0 | "::" | "[::]") printf '127.0.0.1\n' ;;
    *) printf '%s\n' "$1" ;;
    esac
}

local_url() { printf 'http://%s:%s\n' "$(client_host "$BIND")" "$PORT"; }

# --- Paths (logical, EASY_CS_AI_ROOT is applied by root_path) ---------------------

config_dir_logical() { printf '%s\n' "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }
conf_dir() { printf '%s/librechat\n' "$(config_dir_logical)"; }
compose_file() { printf '%s/docker-compose.yml\n' "$(conf_dir)"; }
yaml_file() { printf '%s/librechat.yaml\n' "$(conf_dir)"; }
env_file() { printf '%s/secrets/librechat.env\n' "$(config_dir_logical)"; }
db_env_file() { printf '%s/secrets/librechat-db.env\n' "$(config_dir_logical)"; }
# The key of an endpoint on another machine is a secret of its own, read by the api container
# through its environment (the file holds one variable) and never written in librechat.yaml. Its
# certificate is public: one file per endpoint and one bundle of them all, since the container takes one.
endpoint_key_file() { printf '%s/secrets/librechat-endpoint-%s.env\n' "$(config_dir_logical)" "$1"; }
endpoint_ca_file() { printf '%s/ca-%s.crt\n' "$(conf_dir)" "$1"; }
ca_bundle_file() { printf '%s/ca-bundle.crt\n' "$(conf_dir)"; }
# endpoint_key_var <name>: the environment variable that holds the key of an endpoint.
endpoint_key_var() { printf 'EASY_CS_AI_KEY_%s\n' "$(tr 'a-z.-' 'A-Z__' <<<"$1")"; }
# where the bundle is seen in the api container
readonly CA_BUNDLE_IN_CONTAINER=/etc/easy-cs-ai/ca-bundle.crt
unit_file() { printf '/etc/systemd/system/%s\n' "$UNIT"; }

# --- describe / helpers -----------------------------------------------------------

describe() {
    _require_jq
    jq -n --arg sv "$SCRIPT_VERSION" --arg cv "$DEFAULT_VERSION" --argjson ht "$HEALTH_TIMEOUT" \
        --arg actions "$ACTIONS" --arg warn "$REGISTRATION_WARNING" --arg port "$DEFAULT_PORT" \
        --arg dbport "$DEFAULT_DB_PORT" --arg proxy "$PROXY" '{
        schema_version: 1, name: "librechat", type: "chat-interface", script_version: $sv,
        component_version: $cv, requires: [$proxy], provides: ["chat-ui"],
        platforms: ["debian", "ubuntu"], health_timeout: $ht,
        native: { command: "docker compose -f {compose_file}" },
        resources: { ram_gb: 2, disk_gb: 6.2, source: "guess", basis: "api, FerretDB and PostgreSQL measured at 694 MiB at idle on 2026-10-16 with an empty database, declared three times higher for accounts and conversations (a guess); the images take about 6.2 GB (measured)" },
        options: [
          { name: "port", env: "EASY_CS_AI_LIBRECHAT_PORT", default: $port, secret: false, type: "integer", min: 1, max: 65535, description: "Listening port of LibreChat on the machine (nginx serves it over HTTPS)" },
          { name: "bind", env: "EASY_CS_AI_LIBRECHAT_BIND", default: "127.0.0.1", secret: false, description: "Listening address of LibreChat" },
          { name: "db-port", env: "EASY_CS_AI_LIBRECHAT_DB_PORT", default: $dbport, secret: false, type: "integer", min: 1, max: 65535, description: "Loopback port of the database (FerretDB)" },
          { name: "allow-registration", env: "EASY_CS_AI_LIBRECHAT_ALLOW_REGISTRATION", default: "true", secret: false, type: "boolean",
            description: "Whether anyone who reaches the site can create an account (true or false)",
            warn: { when: "true", message: $warn } },
          { name: "version", env: "EASY_CS_AI_LIBRECHAT_VERSION", default: $cv, secret: false, description: "LibreChat version to install" },
          { name: "health-timeout", env: "EASY_CS_AI_LIBRECHAT_HEALTH_TIMEOUT", default: ($ht | tostring), secret: false, type: "integer", min: 0, description: "Seconds to wait for LibreChat after start" },
          { name: "lock-timeout", env: "EASY_CS_AI_LIBRECHAT_LOCK_TIMEOUT", default: "0", secret: false, type: "integer", min: 0, description: "Seconds to wait for a busy component lock" }
        ],
        actions: ($actions | split(" ")),
        action_options: {
          "add-endpoint": [
            { name: "model", type: "string", description: "The model the endpoint serves; without it the list of the engine is fetched" },
            { name: "api-key-file", type: "string", description: "The API key the endpoint expects: a file of mode 0600 or stricter, or - for stdin, never on the command line" },
            { name: "ca-file", type: "string", description: "PEM certificate (or CA) the endpoint is verified against, for a proxy with a self-signed or private-CA certificate" }
          ]
        }
      }'
}

# run_logged <action> <command…>: journal start and end around a changing
# action. The command runs in a subshell so that a die still logs the end.
run_logged() {
    local action="$1" start=$SECONDS rc=0
    shift
    log_event "$NAME $action start version=$VERSION params=port=$PORT,bind=$BIND,db-port=$DB_PORT,allow-registration=$ALLOW_REG"
    ("$@") || rc=$?
    log_event "$NAME $action end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}

service_active() { ! is_test_root && systemctl is-active --quiet "$UNIT"; }

port_in_use() {
    command -v ss >/dev/null 2>&1 && [[ -n "$(ss -H -ltn "sport = :$1" 2>/dev/null)" ]]
}

# check_free <path> <megabytes>
check_free() {
    local free
    free="$(df -Pm "$1" | awk 'NR==2 {print $4}')"
    if ((free < $2)); then
        die "$EXIT_PRECONDITION" "not enough disk space on $1: ${free} MB free, $2 MB needed"
    fi
}

# compose <args…>: docker compose on our file. Its output goes to stderr (stdout is
# for machine-readable output). Nothing runs in test mode.
compose() {
    if is_test_root; then
        log_info "(test mode) docker compose $*"
        return 0
    fi
    "$(_docker_bin)" compose -f "$(compose_file)" "$@" >&2
}

# compose_services_up: the three containers run (read-only, stdout is captured).
compose_services_up() {
    local running
    running="$("$(_docker_bin)" compose -f "$(compose_file)" ps --status running --services 2>/dev/null | grep -c . || true)"
    ((running == 3))
}

# proxy_script <args…>: the nginx script of the same tree. Its stdout is returned.
proxy_script() { bash "$PROXY_SCRIPT" "$@"; }

proxy_state() { state_read "$PROXY" 2>/dev/null || true; }

# public_domain: the URL browsers use (nginx serves the site on its own port).
public_domain() {
    local json name port
    json="$(proxy_state)"
    name="$(jq -r '.params["server-name"] // empty' <<<"${json:-null}")"
    port="$(jq -r '.params["site-port"] // .listen.site_port // 8443' <<<"${json:-null}")"
    if [[ -n "$name" ]]; then
        printf 'https://%s:%s\n' "$name" "$port"
    else
        local_url
    fi
}

hex_secret() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# kept_value <logical-file> <KEY>: the value already stored in an env file, if any.
kept_value() {
    local file
    file="$(root_path "$1")"
    [[ -f "$file" ]] || return 0
    sed -n "s/^$2=//p" "$file" | head -1
}

# --- install ----------------------------------------------------------------------

preflight() {
    require_root
    require_platform
    _require_jq
    require_component "$PROXY"
    if is_test_root; then
        return 0
    fi
    local ours=0
    if service_active && state_read "$NAME" >/dev/null 2>&1; then
        ours=1
    fi
    if ((!ours)); then
        port_in_use "$PORT" && die "$EXIT_PRECONDITION" "port $PORT is already in use by another process"
        port_in_use "$DB_PORT" && die "$EXIT_PRECONDITION" "port $DB_PORT is already in use by another process (a MongoDB on this machine? use --db-port)"
        if ! state_read "$NAME" >/dev/null 2>&1; then
            if [[ -d /var/lib/docker ]]; then check_free /var/lib/docker "$MIN_FREE_MB"; else check_free /var/lib "$MIN_FREE_MB"; fi
        fi
    fi
}

pull_images() {
    local image
    if is_test_root; then
        log_info "(test mode) would pull the images: $IMAGE_API $IMAGE_FERRETDB $IMAGE_POSTGRES"
        return 0
    fi
    for image in "$IMAGE_API" "$IMAGE_FERRETDB" "$IMAGE_POSTGRES"; do
        if "$(_docker_bin)" image inspect "$image" >/dev/null 2>&1; then
            log_debug "image already present: $image"
            continue
        fi
        log_info "pulling $image"
        "$(_docker_bin)" pull -q "$image" >/dev/null || die "$EXIT_NETWORK" "could not pull $image"
    done
}

# ensure_secrets: the database password and the LibreChat keys, generated once and
# kept by every later run (the database already holds the password, and the keys
# decrypt what LibreChat stored). Exports them for the templates; never logs them.
ensure_secrets() {
    local v
    v="$(kept_value "$(db_env_file)" POSTGRES_PASSWORD)"
    LC_DB_PASSWORD="${v:-$(hex_secret 24)}"
    v="$(kept_value "$(env_file)" JWT_SECRET)"
    LC_JWT_SECRET="${v:-$(generate_secret)}"
    v="$(kept_value "$(env_file)" JWT_REFRESH_SECRET)"
    LC_JWT_REFRESH_SECRET="${v:-$(generate_secret)}"
    v="$(kept_value "$(env_file)" CREDS_KEY)"
    LC_CREDS_KEY="${v:-$(hex_secret 32)}"
    v="$(kept_value "$(env_file)" CREDS_IV)"
    LC_CREDS_IV="${v:-$(hex_secret 16)}"
    export LC_DB_PASSWORD LC_JWT_SECRET LC_JWT_REFRESH_SECRET LC_CREDS_KEY LC_CREDS_IV
    mkdir -p "$(root_path "$(config_dir_logical)/secrets")"
    chmod 0700 "$(root_path "$(config_dir_logical)/secrets")"
}

# endpoints_block <endpoints-json>: the `endpoints:` part of librechat.yaml, empty
# without endpoint. Names, URLs and models are validated before they get here, so
# they need no escaping. Without a model, the list of models is fetched from the endpoint.
endpoints_block() {
    jq -r '
      if length == 0 then empty else
        "endpoints:\n  custom:",
        (.[] | "    - name: \"\(.name)\"\n      apiKey: \"\(if .key then "${EASY_CS_AI_KEY_" + (.name | ascii_upcase | gsub("[.-]"; "_")) + "}" else "unused" end)\"\n      baseURL: \"\(.url)\"\n      models:\n        default: [\"\(.model // .name)\"]\n        fetch: \(if .model then "false" else "true" end)\n      titleConvo: false\n      modelDisplayLabel: \"\(.name)\"")
      end' <<<"$1"
}

# render_yaml <endpoints-json>: 0 when librechat.yaml changed, 10 when identical.
render_yaml() {
    LC_ENDPOINTS_BLOCK="$(endpoints_block "$1")"
    export LC_ENDPOINTS_BLOCK
    render_template "$TEMPLATE_DIR/librechat.yaml" "$(yaml_file)" 0644 root:root
}

# export_render_vars: the variables the templates read, from the options of the run.
export_render_vars() {
    LC_BIND="$BIND" LC_PORT="$PORT" LC_DB_PORT="$DB_PORT" LC_ALLOW_REGISTRATION="$ALLOW_REG"
    LC_DOMAIN="$(public_domain)"
    LC_IMAGE_API="$IMAGE_API" LC_IMAGE_FERRETDB="$IMAGE_FERRETDB" LC_IMAGE_POSTGRES="$IMAGE_POSTGRES"
    LC_ENV_FILE="$(env_file)" LC_DB_ENV_FILE="$(db_env_file)" LC_YAML_FILE="$(yaml_file)"
    LC_CONF_DIR="$(conf_dir)" LC_COMPOSE_FILE="$(compose_file)"
    LC_CA_BUNDLE="$(ca_bundle_file)" LC_CA_IN_CONTAINER="$CA_BUNDLE_IN_CONTAINER"
    LC_DOCKER_BIN="$(command -v "$(_docker_bin)" 2>/dev/null || printf '/usr/bin/docker')"
    export LC_BIND LC_PORT LC_DB_PORT LC_ALLOW_REGISTRATION LC_DOMAIN LC_IMAGE_API LC_IMAGE_FERRETDB LC_IMAGE_POSTGRES \
        LC_ENV_FILE LC_DB_ENV_FILE LC_YAML_FILE LC_CONF_DIR LC_COMPOSE_FILE LC_DOCKER_BIN LC_CA_BUNDLE LC_CA_IN_CONTAINER
}

# render_compose <endpoints-json>: docker-compose.yml. The api container reads the key of each endpoint
# on another machine from the environment file of that key, and trusts the certificates of the bundle.
# The markers of the template become what the endpoints need, and nothing when none needs anything,
# so the file is the one of a stack with local endpoints only. 0 when it changed, 10 when identical.
# shellcheck disable=SC2016  # the ${...} are for the template, not for this shell
render_compose() {
    local eps="$1" tmp line name rc=0 block_env block_environment="" block_vols=""
    block_env='    env_file: ${LC_ENV_FILE}'
    if jq -e 'any(.[]; .key)' >/dev/null <<<"$eps"; then
        block_env=$'    env_file:\n      - ${LC_ENV_FILE}'
        while IFS= read -r name; do
            block_env+=$'\n      - '"$(endpoint_key_file "$name")"
        done < <(jq -r '.[] | select(.key) | .name' <<<"$eps")
    fi
    if jq -e 'any(.[]; .ca)' >/dev/null <<<"$eps"; then
        block_environment=$'    environment:\n      NODE_EXTRA_CA_CERTS: ${LC_CA_IN_CONTAINER}'
        block_vols='      - ${LC_CA_BUNDLE}:${LC_CA_IN_CONTAINER}:ro'
    fi
    tmp="$(mktemp)"
    while IFS= read -r line; do
        case "$line" in
        '#@API_ENV@') printf '%s\n' "$block_env" ;;
        '#@API_ENVIRONMENT@') [[ -z "$block_environment" ]] || printf '%s\n' "$block_environment" ;;
        '#@API_VOLUMES@') [[ -z "$block_vols" ]] || printf '%s\n' "$block_vols" ;;
        *) printf '%s\n' "$line" ;;
        esac
    done <"$TEMPLATE_DIR/docker-compose.yml" >"$tmp"
    render_template "$tmp" "$(compose_file)" 0644 root:root || rc=$?
    rm -f "$tmp"
    return "$rc"
}

# render_all <endpoints-json>: every generated file. Sets YAML_CHANGED and
# returns 0 when one changed, 10 when none.
render_all() {
    local identical=1 rc pair template dest mode
    YAML_CHANGED=0
    export_render_vars
    mkdir -p "$(root_path "$(conf_dir)")"
    track_file "$(conf_dir)"
    rc=0
    render_compose "$1" || rc=$?
    if ((rc == 0)); then
        identical=0
    elif ((rc != 10)); then
        exit "$rc"
    fi
    for pair in \
        "db.env|$(db_env_file)|0600" \
        "librechat.env|$(env_file)|0600" \
        "easy-cs-ai-librechat.service|$(unit_file)|0644"; do
        rc=0
        IFS='|' read -r template dest mode <<<"$pair"
        render_template "$TEMPLATE_DIR/$template" "$dest" "$mode" root:root || rc=$?
        if ((rc == 0)); then
            identical=0
        elif ((rc != 10)); then
            exit "$rc"
        fi
    done
    rc=0
    render_yaml "$1" || rc=$?
    if ((rc == 0)); then
        identical=0
        YAML_CHANGED=1
    elif ((rc != 10)); then
        exit "$rc"
    fi
    return "$((identical ? 10 : 0))"
}

# current_endpoints: the endpoints recorded in the state, `[]` before the first install.
current_endpoints() { state_read "$NAME" 2>/dev/null | jq -c '.endpoints // []' || printf '[]\n'; }

# wait_ready: LibreChat answers /health then /readyz, and the three containers run.
wait_ready() {
    local url unit="${1:-}"
    url="$(local_url)"
    wait_for_http "$url/health" "$HEALTH" "$unit" || return "$?"
    wait_for_http "$url/readyz" 60 "$unit" || return "$?"
    if ! is_test_root && ! compose_services_up; then
        log_error "the three containers (api, ferretdb, postgres) do not all run"
        return "$EXIT_VERIFY"
    fi
}

show_logs() {
    is_test_root && return 0
    compose logs --tail 20 || true
}

record_state() {
    local json files secrets
    # the keys of the endpoints on other machines, recorded by add-endpoint, stay with the two files of the stack
    secrets="$(jq -nc --arg a "$(env_file)" --arg b "$(db_env_file)" --argjson extra "$(state_read "$NAME" 2>/dev/null | jq -c '.secrets // []' || printf '[]')" '[$a, $b] + ($extra - [$a, $b])')"
    files="$( (pending_read "$NAME"; state_read "$NAME" 2>/dev/null || true) |
        jq -sc --argjson s "$secrets" '[.[] | (.files // [])[]] | unique | map(select(. as $f | $s | index($f) | not))')"
    json="$(jq -n --arg v "$VERSION" --arg sv "$SCRIPT_VERSION" --arg port "$PORT" --arg bind "$BIND" \
        --arg dbport "$DB_PORT" --arg reg "$ALLOW_REG" --arg unit "$UNIT" --arg cf "$(compose_file)" \
        --arg proxy "$PROXY" --argjson vols "$(printf '%s\n' "${VOLUME_ENTRIES[@]}" | jq -R . | jq -sc .)" --argjson files "$files" --argjson secrets "$secrets" \
        --argjson default "$MAKE_DEFAULT" '{
        name: "librechat", type: "chat-interface", version: $v, script_version: $sv,
        params: { port: $port, bind: $bind, "db-port": $dbport, "allow-registration": $reg },
        service: { unit: $unit, compose_file: $cf }, requires: [$proxy],
        files: $files, data_dirs: $vols, secrets: $secrets
      } + (if $default == 1 then { default: true } else {} end)')"
    if ! state_read "$NAME" >/dev/null 2>&1; then
        json="$(jq '. + { endpoints: [] }' <<<"$json")"
    fi
    state_write "$NAME" "$json"
}

do_install() {
    local rc=0 was_active=0 endpoints
    service_active && was_active=1
    pending_begin "$TYPE" "$NAME"
    [[ "$VERSION" == "$DEFAULT_VERSION" ]] ||
        log_warn "LibreChat $VERSION is pulled by tag: only $DEFAULT_VERSION is pinned by digest and tested with this script"
    [[ "$ALLOW_REG" != true ]] || log_warn "$REGISTRATION_WARNING"
    ensure_docker
    pull_images
    ensure_secrets
    endpoints="$(current_endpoints)"
    render_all "$endpoints" || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
    if ((!was_active)); then
        systemd_enable_now "$UNIT"
    elif ((rc == 0)); then
        # a running stack: Compose recreates what changed; a new librechat.yaml is a
        # bind-mounted file, which it does not see, so the api is recreated by hand
        compose up -d
        if ((YAML_CHANGED)); then
            compose up -d --no-deps --force-recreate api
        fi
    else
        log_info "already installed, nothing to change"
    fi
    if is_test_root; then
        log_info "(test mode) health check skipped"
    else
        wait_ready "$UNIT" || {
            show_logs
            exit "$EXIT_VERIFY"
        }
    fi
    record_state
    if ((MAKE_DEFAULT)); then
        defaults_set "$TYPE" "$NAME"
    fi
    pending_remove "$NAME"
    log_info "LibreChat $VERSION is installed and answers on $(local_url)"
}

# record_site <url>: the public URL of the web site, once nginx serves it.
record_site() {
    state_write "$NAME" "$(state_read "$NAME" | jq --arg u "$1" '{ name: .name, type: .type, url: $u }')"
}

# expose_site: nginx serves the interface over HTTPS. Done once the install has
# released its lock, since a script holds at most one component lock and
# `proxy add-site` takes the proxy's own. An install that stops here is installed
# and converges when run again.
expose_site() {
    local out url rc=0
    out="$(proxy_script add-site "$NAME" "http://$(client_host "$BIND"):$PORT")" || rc=$?
    if ((rc)); then
        log_error "LibreChat is installed but nginx could not serve it (exit $rc): run again once the proxy works"
        exit "$rc"
    fi
    url="$(jq -r '.url' <<<"$out")"
    with_component_lock "$TYPE" "$NAME" install-site run_logged install-site record_site "$url"
    log_info "LibreChat is served on $url"
}

cmd_install() {
    preflight
    if is_dry_run; then
        log_info "dry run: would install Docker if needed, pull the LibreChat $VERSION, FerretDB and PostgreSQL images," \
            "write $(compose_file) and the secrets (port $PORT, database port $DB_PORT, registration $ALLOW_REG)," \
            "start $UNIT, have $PROXY serve it over HTTPS and record the state"
        [[ "$ALLOW_REG" != true ]] || log_warn "$REGISTRATION_WARNING"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" install run_logged install do_install
    expose_site
}

# --- uninstall --------------------------------------------------------------------

remove_path() {
    local path="$1"
    if [[ "$path" != /?* || "$path" == *..* ]]; then
        log_warn "ignoring suspicious path in state: $path"
        return 0
    fi
    rm -rf "$(root_path "$path")"
}

do_uninstall() {
    local state="" pending="" other path secrets
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
    systemd_disable_now "$UNIT"
    if [[ -f "$(root_path "$(compose_file)")" ]]; then
        # the unit stops the stack; this also covers a failed install that has no unit yet
        if ((PURGE)); then
            compose down -v --rmi all || log_warn "could not remove the volume and the images of the stack"
        else
            compose down || log_warn "could not stop the containers"
        fi
    fi
    secrets="$(jq -nc --arg a "$(env_file)" --arg b "$(db_env_file)" '[$a, $b]')"
    while IFS= read -r path; do
        [[ -n "$path" ]] && remove_path "$path"
    done < <(jq -rs --argjson s "$secrets" '[.[] | (.files // [])[]] | unique | map(select(. as $f | $s | index($f) | not))[]' <<<"$state $pending")
    remove_path "$(unit_file)"
    remove_path "$(yaml_file)"
    remove_path "$(compose_file)"
    rmdir "$(root_path "$(conf_dir)")" 2>/dev/null || true
    if ((PURGE)); then
        remove_path "$(env_file)"
        remove_path "$(db_env_file)"
        # and the keys of the endpoints on other machines
        while IFS= read -r path; do
            [[ -n "$path" ]] && remove_path "$path"
        done < <(jq -rs '[.[] | (.secrets // [])[]] | unique[]' <<<"$state $pending")
    else
        # user data: the database holds the password of db.env, and LibreChat's keys decrypt what it stored
        log_info "the database and the secrets are kept (--purge removes them)"
    fi
    state_remove "$NAME"
    pending_remove "$NAME"
    _systemctl daemon-reload
    log_info "LibreChat is uninstalled"
}

# unexpose_site: nginx stops serving the interface (best effort: LibreChat is gone).
unexpose_site() {
    state_read "$PROXY" >/dev/null 2>&1 || return 0
    proxy_script remove-site "$NAME" >/dev/null || log_warn "could not remove the site $NAME from $PROXY: run 'easy-cs-ai component proxy $PROXY remove-site $NAME'"
}

cmd_uninstall() {
    require_root
    _require_jq
    if is_dry_run; then
        log_info "dry run: would stop and remove the containers, the unit and the configuration" \
            "(database and secrets kept unless --purge), and remove the site from $PROXY"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" uninstall run_logged uninstall do_uninstall
    unexpose_site
}

# --- status -------------------------------------------------------------------------

cmd_status() {
    _require_jq
    local json installed=false running=false healthy=false version=null rc=0 url
    if json="$(state_read "$NAME")"; then
        installed=true
        version="$(jq '.version' <<<"$json")"
        service_active && running=true
        if ! is_test_root; then
            url="$(local_url)"
            if curl -fsS -o /dev/null --max-time 5 "$url/health" 2>/dev/null &&
                curl -fsS -o /dev/null --max-time 5 "$url/readyz" 2>/dev/null; then
                # the containers can only be listed by a user who reaches Docker
                if ! "$(_docker_bin)" info >/dev/null 2>&1 || compose_services_up; then
                    healthy=true
                fi
            fi
        fi
        [[ "$healthy" == true ]] || rc=$EXIT_VERIFY
    else
        rc=$EXIT_PRECONDITION
    fi
    jq -n --argjson i "$installed" --argjson r "$running" --argjson h "$healthy" --argjson v "$version" \
        '{ schema_version: 1, name: "librechat", installed: $i, running: $r, healthy: $h, version: $v }'
    return "$rc"
}

# --- endpoints ----------------------------------------------------------------------

require_installed() {
    state_read "$NAME" >/dev/null 2>&1 || die "$EXIT_PRECONDITION" "$NAME is not installed"
}

check_endpoint_name() {
    if [[ -z "${1:-}" || ! "$1" =~ ^[a-z0-9][a-z0-9.-]*$ || "$1" == *..* ]]; then
        die "$EXIT_USAGE" "invalid or missing endpoint name '${1:-}' (lowercase letters, digits, . and -)"
    fi
}

check_endpoint_url() {
    if [[ ! "${1:-}" =~ ^https?://[][A-Za-z0-9.:-]+(/[A-Za-z0-9._~/%-]*)?$ ]]; then
        die "$EXIT_USAGE" "invalid or missing endpoint URL '${1:-}'"
    fi
}

check_endpoint_model() {
    if [[ -n "$1" && ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]]; then
        die "$EXIT_USAGE" "invalid model name '$1'"
    fi
}

# apply_endpoints <new-endpoints-json>: write docker-compose.yml and librechat.yaml, then recreate only
# the api container when one of them or a file it reads (a key, the bundle) changed, and wait for it. A
# failure restores the old files and exits 6, the state untouched. Returns 0 either way when nothing
# failed. FILES_CHANGED is 1 when the caller changed a key file or a certificate.
FILES_CHANGED=0
apply_endpoints() {
    local new="$1" old rc=0 rc2=0
    old="$(current_endpoints)"
    export_render_vars
    render_compose "$new" || rc=$?
    ((rc == 0 || rc == 10)) || exit "$rc"
    render_yaml "$new" || rc2=$?
    ((rc2 == 0 || rc2 == 10)) || exit "$rc2"
    ((rc == 0 || rc2 == 0 || FILES_CHANGED)) || return 0
    compose up -d --no-deps --force-recreate api
    if is_test_root; then
        return 0
    fi
    if ! wait_for_http "$(local_url)/readyz" "$HEALTH" ""; then
        log_error "LibreChat does not answer after the change, restoring the previous endpoints"
        render_compose "$old" || true
        render_yaml "$old" || true
        compose up -d --no-deps --force-recreate api || true
        show_logs
        exit "$EXIT_VERIFY"
    fi
}

# put_file <logical-path> <mode>: the content on stdin, atomically. Returns 0 when the file changed,
# 10 when it was identical (and sets FILES_CHANGED when it changed).
put_file() {
    local path="$1" mode="$2" dest tmp
    dest="$(root_path "$path")"
    mkdir -p "${dest%/*}"
    tmp="$(mktemp "${dest%/*}/.${dest##*/}.XXXXXX")"
    cat >"$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 10
    fi
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
    FILES_CHANGED=1
}

# drop_file <logical-path>: remove a file, noting that the api container must be recreated.
drop_file() {
    local dest
    dest="$(root_path "$1")"
    [[ -e "$dest" ]] || return 0
    rm -f "$dest"
    FILES_CHANGED=1
}

# rebuild_bundle <endpoints-json>: the certificates of the endpoints that have one, in one file (the
# api container takes one); no bundle when none has.
rebuild_bundle() {
    local name rc=0
    if jq -e 'any(.[]; .ca)' >/dev/null <<<"$1"; then
        put_file "$(ca_bundle_file)" 0644 < <(
            while IFS= read -r name; do
                cat "$(root_path "$(endpoint_ca_file "$name")")"
            done < <(jq -r '.[] | select(.ca) | .name' <<<"$1")
        ) || rc=$?
        ((rc == 0 || rc == 10)) || exit "$rc"
    else
        drop_file "$(ca_bundle_file)"
    fi
}

# state_secrets_files <endpoints-json>: the state `secrets` and `files` after a change of endpoints: the
# key files and the certificates (with the bundle) of the endpoints are the only ones that move.
write_endpoints_state() {
    local new="$1" st
    st="$(state_read "$NAME")"
    state_write "$NAME" "$(jq --argjson e "$new" --arg conf "$(conf_dir)/" --arg sec "$(config_dir_logical)/secrets/librechat-endpoint-" \
        --arg bundle "$(ca_bundle_file)" '
        ([$e[] | select(.key) | $sec + .name + ".env"]) as $keys
        | ([$e[] | select(.ca) | $conf + "ca-" + .name + ".crt"]) as $cas
        | { name: .name, type: .type, endpoints: $e,
            secrets: (((.secrets // []) | map(select(startswith($sec) | not))) + $keys),
            files: (((.files // []) | map(select((startswith($conf + "ca-") | not))))
                    + $cas + (if ($cas | length) > 0 then [$bundle] else [] end) | unique) }' <<<"$st")"
}

# key_value <file|->: the API key of an endpoint, read once: a file of mode 0600 or stricter, or stdin. It
# is written in an environment file, so a character that file would read differently is refused.
key_value() {
    local key
    key="$(read_secret "$1")" || exit "$?"
    [[ "$key" =~ ^[A-Za-z0-9._~+/=:-]{1,512}$ ]] || die "$EXIT_USAGE" "the API key has a character that cannot be given to the container (letters, digits and . _ ~ + / = : - are accepted)"
    printf '%s\n' "$key"
}

do_add_endpoint() {
    local name="$1" url="$2" model="$3" key="$4" ca="$5" new rc=0 var other
    FILES_CHANGED=0
    var="$(endpoint_key_var "$name")"
    other="$(current_endpoints | jq -r --arg n "$name" --arg v "$var" '.[] | select(.name != $n and .key and (("EASY_CS_AI_KEY_" + (.name | ascii_upcase | gsub("[.-]"; "_"))) == $v)) | .name' | head -n 1)"
    if [[ -n "$key" && -n "$other" ]]; then
        die "$EXIT_USAGE" "the key of $name would share its variable with the endpoint $other: choose another name"
    fi
    mkdir -p "$(root_path "$(config_dir_logical)/secrets")"
    chmod 0700 "$(root_path "$(config_dir_logical)/secrets")"
    if [[ -n "$key" ]]; then
        put_file "$(endpoint_key_file "$name")" 0600 < <(printf '%s=%s\n' "$var" "$key") || rc=$?
        ((rc == 0 || rc == 10)) || exit "$rc"
    else
        drop_file "$(endpoint_key_file "$name")"
    fi
    rc=0
    if [[ -n "$ca" ]]; then
        put_file "$(endpoint_ca_file "$name")" 0644 <"$ca" || rc=$?
        ((rc == 0 || rc == 10)) || exit "$rc"
    else
        drop_file "$(endpoint_ca_file "$name")"
    fi
    new="$(current_endpoints | jq -c --arg n "$name" --arg u "$url" --arg m "$model" --argjson k "$([[ -n "$key" ]] && printf true || printf false)" --argjson c "$([[ -n "$ca" ]] && printf true || printf false)" '
        (map(select(.name != $n))) + [{ name: $n, url: $u } + (if $m != "" then { model: $m } else {} end)
            + (if $k then { key: true } else {} end) + (if $c then { ca: true } else {} end)]')"
    rebuild_bundle "$new"
    apply_endpoints "$new"
    write_endpoints_state "$new"
    log_info "endpoint $name declared ($url)"
    jq -n --arg u "$url" '{ url: $u }'
}

cmd_add_endpoint() {
    local key="" ca=""
    check_endpoint_name "${POSITIONAL[0]:-}"
    check_endpoint_url "${POSITIONAL[1]:-}"
    check_endpoint_model "$ENDPOINT_MODEL"
    if [[ -n "$ENDPOINT_CA_FILE" ]]; then
        [[ -r "$ENDPOINT_CA_FILE" ]] || die "$EXIT_USAGE" "certificate not readable: $ENDPOINT_CA_FILE"
        openssl x509 -in "$ENDPOINT_CA_FILE" -noout >/dev/null 2>&1 || die "$EXIT_USAGE" "$ENDPOINT_CA_FILE is not a PEM certificate"
        ca="$ENDPOINT_CA_FILE"
    fi
    # the key is read once, here: stdin cannot be read twice and nothing goes through a command line
    if [[ -n "$ENDPOINT_KEY_FILE" ]]; then
        key="$(key_value "$ENDPOINT_KEY_FILE")" || exit "$?"
    fi
    require_root
    require_installed
    if is_dry_run; then
        log_info "dry run: would declare the endpoint ${POSITIONAL[0]} (${POSITIONAL[1]}) and recreate the api container"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" add-endpoint run_logged add-endpoint do_add_endpoint \
        "${POSITIONAL[0]}" "${POSITIONAL[1]}" "$ENDPOINT_MODEL" "$key" "$ca"
}

do_remove_endpoint() {
    local name="$1" new
    FILES_CHANGED=0
    new="$(current_endpoints | jq -c --arg n "$name" 'map(select(.name != $n))')"
    drop_file "$(endpoint_key_file "$name")"
    drop_file "$(endpoint_ca_file "$name")"
    rebuild_bundle "$new"
    apply_endpoints "$new"
    write_endpoints_state "$new"
    log_info "endpoint $name is removed"
}

cmd_remove_endpoint() {
    check_endpoint_name "${POSITIONAL[0]:-}"
    require_root
    require_installed
    if is_dry_run; then
        log_info "dry run: would remove the endpoint ${POSITIONAL[0]} and recreate the api container"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" remove-endpoint run_logged remove-endpoint do_remove_endpoint "${POSITIONAL[0]}"
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
    add-endpoint) cmd_add_endpoint ;;
    remove-endpoint) cmd_remove_endpoint ;;
    esac
}

main "$@"
