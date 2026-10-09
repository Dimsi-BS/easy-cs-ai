#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../../install_scripts/proxy/nginx.sh"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    SYS="$EASY_CS_AI_ROOT"
    STATE="$SYS/var/lib/easy-cs-ai"
    CONF="$SYS/etc/nginx"
    SECRETS="$SYS/etc/easy-cs-ai/secrets"
    unset EASY_CS_AI_LOCK_HELD EASY_CS_AI_NGINX_PORT EASY_CS_AI_NGINX_BIND EASY_CS_AI_NGINX_SERVER_NAME \
        EASY_CS_AI_NGINX_TLS EASY_CS_AI_NGINX_API_KEY
}

nginx() { run --separate-stderr bash "$SCRIPT" "$@"; }

# --- describe, help, usage -----------------------------------------------------

@test "describe prints valid metadata without root or state" {
    nginx describe
    [ "$status" -eq 0 ]
    run jq -r '.name, .type, .schema_version, .health_timeout, (.options | map(.name) | join(","))' <<<"$output"
    [ "${lines[0]}" = "nginx" ]
    [ "${lines[1]}" = "proxy" ]
    [ "${lines[2]}" = "1" ]
    [ "${lines[3]}" = "30" ]
    [[ "${lines[4]}" == port,bind,server-name,tls,api-key,* ]]
}

@test "describe flags the API key as a secret and lists the proxy actions" {
    nginx describe
    run jq -r '.options[] | select(.name == "api-key") | .secret' <<<"$output"
    [ "$output" = "true" ]
    nginx describe
    for a in install uninstall status describe add-upstream remove-upstream show-key; do
        run jq -e --arg a "$a" '.actions | index($a)' <<<"$(bash "$SCRIPT" describe)"
        [ "$status" -eq 0 ]
    done
}

@test "--help and --version print on stdout and succeed" {
    nginx --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: nginx.sh"* ]]
    nginx install --version
    [ "$status" -eq 0 ]
    [ "$output" = "0.1.0" ]
}

@test "usage errors exit 2" {
    nginx
    [ "$status" -eq 2 ]
    nginx frobnicate
    [ "$status" -eq 2 ]
    nginx install --nope
    [ "$status" -eq 2 ]
    nginx install --port abc
    [ "$status" -eq 2 ]
    nginx install --port 70000
    [ "$status" -eq 2 ]
    nginx install --port
    [ "$status" -eq 2 ]
    nginx install --server-name 'a b'
    [ "$status" -eq 2 ]
    nginx install --api-key-file
    [ "$status" -eq 2 ]
}

@test "the certificate strategies that are not implemented yet are refused with exit 2" {
    nginx install --tls provided
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"not implemented yet"* ]]
    nginx install --tls letsencrypt
    [ "$status" -eq 2 ]
    nginx install --tls bogus
    [ "$status" -eq 2 ]
    [ ! -e "$STATE/components/nginx.json" ]
}

# --- install -----------------------------------------------------------------------

@test "install records the state, the configuration, the key and the certificate" {
    nginx install --server-name ai.test
    [ "$status" -eq 0 ]
    [ -f "$CONF/conf.d/easy-cs-ai.conf" ]
    [ -f "$CONF/easy-cs-ai/api-key.conf" ]
    [ -f "$SECRETS/nginx.api-key" ]
    [ -f "$SECRETS/nginx.tls-key" ]
    [ -f "$SYS/etc/easy-cs-ai/nginx/server.crt" ]
    run jq -r '.name, .type, .default, .params.port, .params["server-name"], .params.tls, .listen.tls, .service.unit, (.upstreams | length)' \
        "$STATE/components/nginx.json"
    [ "${lines[0]}" = "nginx" ]
    [ "${lines[1]}" = "proxy" ]
    [ "${lines[2]}" = "true" ]
    [ "${lines[3]}" = "443" ]
    [ "${lines[4]}" = "ai.test" ]
    [ "${lines[5]}" = "self-signed" ]
    [ "${lines[6]}" = "self-signed" ]
    [ "${lines[7]}" = "nginx.service" ]
    [ "${lines[8]}" = "0" ]
    [ ! -e "$STATE/pending/nginx.json" ]
}

@test "the nginx variables survive the templating and the key is in the map" {
    nginx install --server-name ai.test
    key="$(cat "$SECRETS/nginx.api-key")"
    grep -q '\$easy_cs_ai_authorized = 0' "$CONF/conf.d/easy-cs-ai.conf"
    grep -q 'server_name ai.test;' "$CONF/conf.d/easy-cs-ai.conf"
    grep -q 'listen 0.0.0.0:443 ssl;' "$CONF/conf.d/easy-cs-ai.conf"
    grep -qF "\"Bearer $key\" 1;" "$CONF/easy-cs-ai/api-key.conf"
    grep -q 'map \$http_authorization \$easy_cs_ai_authorized' "$CONF/easy-cs-ai/api-key.conf"
}

@test "secrets are never printed and files have the right modes" {
    nginx install --server-name ai.test
    key="$(cat "$SECRETS/nginx.api-key")"
    [[ "$output" != *"$key"* && "$stderr" != *"$key"* ]]
    [ "$(stat -c %a "$SECRETS/nginx.api-key")" = "600" ]
    [ "$(stat -c %a "$SECRETS/nginx.tls-key")" = "600" ]
    [ "$(stat -c %a "$CONF/easy-cs-ai/api-key.conf")" = "600" ]
    [ "$(stat -c %a "$SYS/etc/easy-cs-ai/nginx/server.crt")" = "644" ]
    run jq -c '.secrets' "$STATE/components/nginx.json"
    [[ "$output" != *"$key"* ]]
}

@test "the generated key is long enough and the certificate covers the server name and localhost" {
    nginx install --server-name ai.test
    [ "$(wc -c <"$SECRETS/nginx.api-key")" -ge 40 ]
    run openssl x509 -in "$SYS/etc/easy-cs-ai/nginx/server.crt" -noout -ext subjectAltName
    [[ "$output" == *"DNS:ai.test"* && "$output" == *"DNS:localhost"* && "$output" == *"IP Address:127.0.0.1"* ]]
}

@test "install journals start and end" {
    nginx install --server-name ai.test --port 8443
    [[ "$stderr" == *"nginx install start params=port=8443,bind=0.0.0.0,server-name=ai.test,tls=self-signed"* ]]
    [[ "$stderr" == *"nginx install end exit=0"* ]]
}

@test "the API key comes from a file, stdin or the environment, and a bad one is refused" {
    printf 'file-key-0123456789abcdef\n' >"$BATS_TEST_TMPDIR/key"
    chmod 600 "$BATS_TEST_TMPDIR/key"
    nginx install --server-name ai.test --api-key-file "$BATS_TEST_TMPDIR/key"
    [ "$(cat "$SECRETS/nginx.api-key")" = "file-key-0123456789abcdef" ]
    run bash -c "printf 'stdin-key-0123456789abcdef\n' | bash '$SCRIPT' install --server-name ai.test --api-key-file -"
    [ "$status" -eq 0 ]
    [ "$(cat "$SECRETS/nginx.api-key")" = "stdin-key-0123456789abcdef" ]
    EASY_CS_AI_NGINX_API_KEY=env-key-0123456789abcdef nginx install --server-name ai.test
    [ "$(cat "$SECRETS/nginx.api-key")" = "env-key-0123456789abcdef" ]
    nginx install --server-name ai.test --api-key-file "$BATS_TEST_TMPDIR/key"
    chmod 644 "$BATS_TEST_TMPDIR/key"
    nginx install --server-name ai.test --api-key-file "$BATS_TEST_TMPDIR/key"
    [ "$status" -eq 2 ]
    EASY_CS_AI_NGINX_API_KEY='short key;' nginx install --server-name ai.test
    [ "$status" -eq 2 ]
}

@test "a second install keeps the generated key and the certificate and changes nothing" {
    nginx install --server-name ai.test
    key="$(cat "$SECRETS/nginx.api-key")"
    cert="$(cat "$SYS/etc/easy-cs-ai/nginx/server.crt")"
    state="$(cat "$STATE/components/nginx.json")"
    nginx install --server-name ai.test
    [ "$status" -eq 0 ]
    [ "$(cat "$SECRETS/nginx.api-key")" = "$key" ]
    [ "$(cat "$SYS/etc/easy-cs-ai/nginx/server.crt")" = "$cert" ]
    [ "$(cat "$STATE/components/nginx.json")" = "$state" ]
}

@test "a new server name regenerates the certificate and re-renders the configuration" {
    nginx install --server-name ai.test
    cert="$(cat "$SYS/etc/easy-cs-ai/nginx/server.crt")"
    nginx install --server-name other.test --port 8443 --bind 127.0.0.1
    [ "$status" -eq 0 ]
    [ "$(cat "$SYS/etc/easy-cs-ai/nginx/server.crt")" != "$cert" ]
    grep -q 'server_name other.test;' "$CONF/conf.d/easy-cs-ai.conf"
    grep -q 'listen 127.0.0.1:8443 ssl;' "$CONF/conf.d/easy-cs-ai.conf"
    [ "$(jq -r .params.port "$STATE/components/nginx.json")" = "8443" ]
}

@test "reinstall keeps the recorded upstreams" {
    nginx install --server-name ai.test
    nginx add-upstream ollama-llama http://127.0.0.1:11434
    nginx install --server-name ai.test --port 8443
    [ "$(jq -r '.upstreams[0].name' "$STATE/components/nginx.json")" = "ollama-llama" ]
}

@test "--default is applied only on request after the first install" {
    bash -c "source '${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh'; state_write caddy '{\"name\":\"caddy\",\"type\":\"proxy\"}'"
    nginx install --server-name ai.test
    [ "$(jq -r .default "$STATE/components/nginx.json")" = "false" ]
    nginx install --server-name ai.test --default
    [ "$(jq -r .default "$STATE/components/nginx.json")" = "true" ]
}

@test "--dry-run changes nothing" {
    nginx install --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"dry run"* ]]
    [ ! -e "$STATE/components/nginx.json" ]
    [ ! -e "$CONF/conf.d/easy-cs-ai.conf" ]
}

@test "install fails at once when the component lock is held" {
    mkdir -p "$STATE/locks"
    (
        exec 8>>"$STATE/locks/proxy-nginx.lock"
        flock 8
        sleep 5
    ) &
    holder=$!
    sleep 1
    nginx install --server-name ai.test
    kill "$holder" 2>/dev/null || true
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"another action is running on nginx"* ]]
}

# --- upstreams ---------------------------------------------------------------------

@test "add-upstream renders the location, records it and prints the public URL" {
    nginx install --server-name ai.test
    nginx add-upstream ollama-llama3.2-3b http://127.0.0.1:11434
    [ "$status" -eq 0 ]
    [ "$(jq -r .url <<<"$output")" = "https://ai.test/ollama-llama3.2-3b/v1" ]
    f="$CONF/easy-cs-ai/upstreams/ollama-llama3.2-3b.conf"
    grep -q 'location /ollama-llama3.2-3b/ {' "$f"
    grep -q 'proxy_pass http://127.0.0.1:11434/;' "$f"
    grep -q 'proxy_buffering off;' "$f"
    grep -q 'proxy_read_timeout 600s;' "$f"
    grep -q 'proxy_set_header Host \$host;' "$f"
    run jq -c '.upstreams' "$STATE/components/nginx.json"
    [ "$output" = '[{"name":"ollama-llama3.2-3b","url":"http://127.0.0.1:11434"}]' ]
}

@test "the public URL carries a non-default port" {
    nginx install --server-name ai.test --port 8443
    nginx add-upstream m http://127.0.0.1:8001
    [ "$(jq -r .url <<<"$output")" = "https://ai.test:8443/m/v1" ]
}

@test "add-upstream is idempotent and updates a changed URL" {
    nginx install --server-name ai.test
    nginx add-upstream m http://127.0.0.1:8001
    first="$output"
    nginx add-upstream m http://127.0.0.1:8001
    [ "$output" = "$first" ]
    nginx add-upstream m http://127.0.0.1:8002
    [ "$status" -eq 0 ]
    [ "$(jq -c '.upstreams' "$STATE/components/nginx.json")" = '[{"name":"m","url":"http://127.0.0.1:8002"}]' ]
    grep -q 'proxy_pass http://127.0.0.1:8002/;' "$CONF/easy-cs-ai/upstreams/m.conf"
}

@test "add-upstream validates its arguments and needs an installed proxy" {
    nginx add-upstream m http://127.0.0.1:8001
    [ "$status" -eq 4 ]
    nginx install --server-name ai.test
    nginx add-upstream
    [ "$status" -eq 2 ]
    nginx add-upstream 'Bad Name' http://127.0.0.1:8001
    [ "$status" -eq 2 ]
    nginx add-upstream ../x http://127.0.0.1:8001
    [ "$status" -eq 2 ]
    nginx add-upstream m
    [ "$status" -eq 2 ]
    nginx add-upstream m 'http://x; return 200;'
    [ "$status" -eq 2 ]
    nginx add-upstream m ftp://127.0.0.1
    [ "$status" -eq 2 ]
}

@test "remove-upstream removes the location and the record, and is idempotent" {
    nginx install --server-name ai.test
    nginx add-upstream m http://127.0.0.1:8001
    nginx remove-upstream m
    [ "$status" -eq 0 ]
    [ ! -e "$CONF/easy-cs-ai/upstreams/m.conf" ]
    [ "$(jq -c '.upstreams' "$STATE/components/nginx.json")" = "[]" ]
    nginx remove-upstream m
    [ "$status" -eq 0 ]
}

@test "add-upstream and remove-upstream --dry-run change nothing" {
    nginx install --server-name ai.test
    nginx add-upstream m http://127.0.0.1:8001 --dry-run
    [ "$status" -eq 0 ]
    [ ! -e "$CONF/easy-cs-ai/upstreams/m.conf" ]
}

# --- show-key ----------------------------------------------------------------------

@test "show-key prints the key and nothing else on stdout" {
    nginx install --server-name ai.test
    nginx show-key
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$SECRETS/nginx.api-key")" ]
}

@test "show-key needs an installed proxy" {
    nginx show-key
    [ "$status" -eq 4 ]
}

# --- status ------------------------------------------------------------------------

@test "status of a missing proxy exits 4" {
    nginx status
    [ "$status" -eq 4 ]
    run jq -r '.installed, .version' <<<"$output"
    [ "${lines[0]}" = "false" ]
    [ "${lines[1]}" = "null" ]
}

@test "status of an installed proxy reports it and exits 6 without health in test mode" {
    nginx install --server-name ai.test
    nginx status
    [ "$status" -eq 6 ]
    run jq -r '.installed, .healthy' <<<"$output"
    [ "${lines[0]}" = "true" ]
    [ "${lines[1]}" = "false" ]
}

# --- uninstall ---------------------------------------------------------------------

@test "uninstall removes the configuration, the secrets, the certificate and the state" {
    nginx install --server-name ai.test
    nginx add-upstream m http://127.0.0.1:8001
    nginx uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$CONF/conf.d/easy-cs-ai.conf" ]
    [ ! -e "$CONF/easy-cs-ai" ]
    [ ! -e "$SECRETS/nginx.api-key" ]
    [ ! -e "$SECRETS/nginx.tls-key" ]
    [ ! -e "$SYS/etc/easy-cs-ai/nginx/server.crt" ]
    [ ! -e "$STATE/components/nginx.json" ]
    [ ! -e "$STATE/pending/nginx.json" ]
}

@test "uninstall of a proxy that is not installed exits 4" {
    nginx uninstall
    [ "$status" -eq 4 ]
}

@test "uninstall cleans a failed install left as a pending manifest" {
    mkdir -p "$STATE/pending" "$CONF/conf.d"
    printf '{"name":"nginx","type":"proxy","files":["/etc/nginx/conf.d/easy-cs-ai.conf"],"units":[],"data_dirs":[]}\n' \
        >"$STATE/pending/nginx.json"
    : >"$CONF/conf.d/easy-cs-ai.conf"
    nginx uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$CONF/conf.d/easy-cs-ai.conf" ]
    [ ! -e "$STATE/pending/nginx.json" ]
}

@test "uninstall is refused while another component requires nginx, unless --force" {
    nginx install --server-name ai.test
    bash -c "source '${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh'; state_write librechat '{\"name\":\"librechat\",\"type\":\"chat-interface\",\"requires\":[\"nginx\"]}'"
    nginx uninstall
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"librechat requires nginx"* ]]
    nginx uninstall --force
    [ "$status" -eq 0 ]
    [ ! -f "$STATE/components/nginx.json" ]
}
