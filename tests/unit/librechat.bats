#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    REAL="${BATS_TEST_DIRNAME}/../../install_scripts"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    SYS="$EASY_CS_AI_ROOT"
    STATE="$SYS/var/lib/easy-cs-ai"
    CONF="$SYS/etc/easy-cs-ai/librechat"
    SECRETS="$SYS/etc/easy-cs-ai/secrets"
    CALLS="$BATS_TEST_TMPDIR/calls"
    : >"$CALLS"
    export CALLS
    # a tree of its own, so that the script finds a fake nginx next to its lib: `..` of a
    # symlinked lib would resolve to the real tree
    TREE="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$TREE/chat-interface" "$TREE/proxy"
    cp -r "$REAL/lib" "$TREE/lib"
    cp -r "$REAL/templates" "$TREE/templates"
    cp "$REAL/chat-interface/librechat.sh" "$TREE/chat-interface/librechat.sh"
    SCRIPT="$TREE/chat-interface/librechat.sh"
    export EASY_CS_AI_LIB="$TREE/lib"
    make_fake_nginx
    # a Docker that is already there, so that nothing depends on the machine running the tests
    printf '#!/bin/sh\n[ "$1" = compose ] && echo "Docker Compose version v2.29.0"\nexit 0\n' >"$BATS_TEST_TMPDIR/docker"
    chmod +x "$BATS_TEST_TMPDIR/docker"
    export EASY_CS_AI_DOCKER="$BATS_TEST_TMPDIR/docker"
    unset EASY_CS_AI_LOCK_HELD FAKE_PROXY_FAIL EASY_CS_AI_LIBRECHAT_PORT EASY_CS_AI_LIBRECHAT_BIND \
        EASY_CS_AI_LIBRECHAT_DB_PORT EASY_CS_AI_LIBRECHAT_ALLOW_REGISTRATION EASY_CS_AI_LIBRECHAT_VERSION
    install_state nginx proxy '"params":{"server-name":"ai.test","site-port":"8443"},"listen":{"site_port":8443}'
}

install_state() {
    bash -c "source '$TREE/lib/common.sh'; state_write $1 '{\"name\":\"$1\",\"type\":\"$2\",$3}'"
}

make_fake_nginx() {
    cat >"$TREE/proxy/nginx.sh" <<'FAKE'
#!/usr/bin/env bash
echo "nginx $*" >>"$CALLS"
[[ -z "${FAKE_PROXY_FAIL:-}" ]] || exit "$FAKE_PROXY_FAIL"
case "$1" in
add-site) printf '{"url":"https://ai.test:8443/"}\n' ;;
esac
exit 0
FAKE
    chmod +x "$TREE/proxy/nginx.sh"
}

lc() { run --separate-stderr bash "$SCRIPT" "$@"; }

# --- describe, help, usage -----------------------------------------------------

@test "describe prints valid metadata without root or state" {
    lc describe
    [ "$status" -eq 0 ]
    run jq -r '.name, .type, .schema_version, .health_timeout, (.requires | join(",")), .native.command, (.options | map(.name) | join(","))' <<<"$output"
    [ "${lines[0]}" = "librechat" ]
    [ "${lines[1]}" = "chat-interface" ]
    [ "${lines[2]}" = "1" ]
    [ "${lines[3]}" = "300" ]
    [ "${lines[4]}" = "nginx" ]
    [ "${lines[5]}" = "docker compose -f {compose_file}" ]
    [ "${lines[6]}" = "port,bind,db-port,allow-registration,version,health-timeout,lock-timeout" ]
}

@test "describe lists the actions of a chat interface" {
    lc describe
    for a in install uninstall status describe add-endpoint remove-endpoint; do
        run jq -e --arg a "$a" '.actions | index($a)' <<<"$(bash "$SCRIPT" describe)"
        [ "$status" -eq 0 ]
    done
}

@test "describe warns about the open registration, so the generator can show it before the VM exists" {
    lc describe
    run jq -r '.options[] | select(.name == "allow-registration") | [.default, .warn.when, .warn.message] | join("|")' <<<"$output"
    [[ "$output" == "true|true|registration is open: the first account created becomes the administrator"* ]]
    [[ "$output" == *"--allow-registration false" ]]
}

@test "describe flags no secret option: the secrets are generated" {
    lc describe
    run jq -r '[.options[] | select(.secret)] | length' <<<"$output"
    [ "$output" = "0" ]
}

@test "--help and --version print on stdout and succeed" {
    lc --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: librechat.sh"* ]]
    lc install --version
    [ "$status" -eq 0 ]
    [ "$output" = "0.1.0" ]
}

@test "usage errors exit 2" {
    lc
    [ "$status" -eq 2 ]
    lc frobnicate
    [ "$status" -eq 2 ]
    lc install --nope
    [ "$status" -eq 2 ]
    lc install --port abc
    [ "$status" -eq 2 ]
    lc install --port 70000
    [ "$status" -eq 2 ]
    lc install --db-port 0
    [ "$status" -eq 2 ]
    lc install --port 3080 --db-port 3080
    [ "$status" -eq 2 ]
    lc install --bind 'a b'
    [ "$status" -eq 2 ]
    lc install --allow-registration maybe
    [ "$status" -eq 2 ]
    lc install --version one
    [ "$status" -eq 2 ]
    lc install --health-timeout x
    [ "$status" -eq 2 ]
}

@test "install needs the proxy: exit 4 when nginx is not installed" {
    rm "$STATE/components/nginx.json"
    lc install
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"required component nginx is not installed"* ]]
    [ ! -e "$CONF" ]
}

# --- install -----------------------------------------------------------------------

@test "install writes the compose file, the configuration, the secrets and the unit, and records the state" {
    lc install
    [ "$status" -eq 0 ]
    [ -f "$CONF/docker-compose.yml" ]
    [ -f "$CONF/librechat.yaml" ]
    [ -f "$SECRETS/librechat.env" ]
    [ -f "$SECRETS/librechat-db.env" ]
    [ -f "$SYS/etc/systemd/system/easy-cs-ai-librechat.service" ]
    run jq -r '.name, .type, .default, .version, .params.port, .params.bind, .params["db-port"], .params["allow-registration"], .service.unit, .service.compose_file, (.requires | join(",")), (.endpoints | length), (.data_dirs | join(","))' \
        "$STATE/components/librechat.json"
    [ "${lines[0]}" = "librechat" ]
    [ "${lines[1]}" = "chat-interface" ]
    [ "${lines[2]}" = "true" ]
    [ "${lines[3]}" = "0.8.7" ]
    [ "${lines[4]}" = "3080" ]
    [ "${lines[5]}" = "127.0.0.1" ]
    [ "${lines[6]}" = "27017" ]
    [ "${lines[7]}" = "true" ]
    [ "${lines[8]}" = "easy-cs-ai-librechat.service" ]
    [ "${lines[9]}" = "/etc/easy-cs-ai/librechat/docker-compose.yml" ]
    [ "${lines[10]}" = "nginx" ]
    [ "${lines[11]}" = "0" ]
    [ "${lines[12]}" = "docker-volume:easy-cs-ai-librechat_pgdata,docker-volume:easy-cs-ai-librechat_ferretdb-state" ]
    [ ! -e "$STATE/pending/librechat.json" ]
}

@test "the compose file pins the images by digest, shares the host network for the api and publishes the database on the loopback" {
    lc install
    f="$CONF/docker-compose.yml"
    grep -q 'image: ghcr.io/danny-avila/librechat@sha256:c5db3331b845e1f289f8d04c0c77936c4bbe372f76730a804abc1c37e44d23a9' "$f"
    grep -q 'image: ghcr.io/ferretdb/ferretdb@sha256:5706414241eb84f0515512c37b46db0f1b1eac9e5ceb7e4c2523211c184b1985' "$f"
    grep -q 'image: ghcr.io/ferretdb/postgres-documentdb@sha256:2386795ec2aa7ae559304361979f1dc5708d383ee9020ae63dadc2940dfe58f7' "$f"
    grep -q '^name: easy-cs-ai-librechat' "$f"
    grep -q 'network_mode: host' "$f"
    grep -q '"127.0.0.1:27017:27017"' "$f"
    grep -q 'condition: service_healthy' "$f"
    grep -q 'pg_isready -U ferret -d postgres' "$f"
    # FerretDB's /state is a named volume: an anonymous one is a new volume at each re-creation and is never purged
    grep -q -- '- ferretdb-state:/state' "$f"
    grep -q '^  ferretdb-state:$' "$f"
    grep -q '^  pgdata:$' "$f"
    grep -q 'env_file: /etc/easy-cs-ai/secrets/librechat.env' "$f"
    grep -q 'env_file: /etc/easy-cs-ai/secrets/librechat-db.env' "$f"
    grep -q -- '- /etc/easy-cs-ai/librechat/librechat.yaml:/app/librechat.yaml:ro' "$f"
    ! grep -q 'ports:.*3080' "$f"
    ! grep -q '\${' "$f"
}

@test "the api listens on the loopback and reaches the database and the public URL of nginx" {
    lc install
    f="$SECRETS/librechat.env"
    grep -q '^HOST=127.0.0.1$' "$f"
    grep -q '^PORT=3080$' "$f"
    grep -q '^MONGO_URI=mongodb://ferret:[0-9a-f]\{48\}@127.0.0.1:27017/LibreChat$' "$f"
    grep -q '^ALLOW_REGISTRATION=true$' "$f"
    grep -q '^DOMAIN_CLIENT=https://ai.test:8443$' "$f"
    grep -q '^DOMAIN_SERVER=https://ai.test:8443$' "$f"
    grep -q '^TRUST_PROXY=1$' "$f"
    grep -q '^CREDS_KEY=[0-9a-f]\{64\}$' "$f"
    grep -q '^CREDS_IV=[0-9a-f]\{32\}$' "$f"
    ! grep -q '\${' "$f"
}

@test "the database containers share one password" {
    lc install
    pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SECRETS/librechat-db.env")"
    [ "${#pw}" -eq 48 ]
    grep -q "^FERRETDB_POSTGRESQL_URL=postgres://ferret:$pw@postgres:5432/postgres$" "$SECRETS/librechat-db.env"
    grep -q "@127.0.0.1:27017/LibreChat" "$SECRETS/librechat.env"
    grep -q ":$pw@" "$SECRETS/librechat.env"
}

@test "the unit starts and stops the stack through Docker Compose and is a oneshot" {
    lc install
    f="$SYS/etc/systemd/system/easy-cs-ai-librechat.service"
    grep -q '^Type=oneshot$' "$f"
    grep -q '^RemainAfterExit=yes$' "$f"
    grep -q "^ExecStart=$BATS_TEST_TMPDIR/docker compose -f /etc/easy-cs-ai/librechat/docker-compose.yml up -d$" "$f"
    grep -q "^ExecStop=$BATS_TEST_TMPDIR/docker compose -f /etc/easy-cs-ai/librechat/docker-compose.yml down$" "$f"
    grep -q '^Requires=docker.service$' "$f"
}

@test "secrets are never printed, have the right modes and stay out of the state" {
    lc install
    pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SECRETS/librechat-db.env")"
    jwt="$(sed -n 's/^JWT_SECRET=//p' "$SECRETS/librechat.env")"
    [[ "$output" != *"$pw"* && "$stderr" != *"$pw"* && "$output" != *"$jwt"* && "$stderr" != *"$jwt"* ]]
    [ "$(stat -c %a "$SECRETS/librechat.env")" = "600" ]
    [ "$(stat -c %a "$SECRETS/librechat-db.env")" = "600" ]
    [ "$(stat -c %a "$SECRETS")" = "700" ]
    [ "$(stat -c %a "$CONF/docker-compose.yml")" = "644" ]
    run cat "$STATE/components/librechat.json"
    [[ "$output" != *"$pw"* && "$output" != *"$jwt"* ]]
    run jq -c '.secrets' "$STATE/components/librechat.json"
    [ "$output" = '["/etc/easy-cs-ai/secrets/librechat.env","/etc/easy-cs-ai/secrets/librechat-db.env"]' ]
}

@test "the files recorded for uninstall never include the secrets" {
    lc install
    run jq -c '.files | sort' "$STATE/components/librechat.json"
    [[ "$output" == *"/etc/easy-cs-ai/librechat/docker-compose.yml"* ]]
    [[ "$output" == *"/etc/systemd/system/easy-cs-ai-librechat.service"* ]]
    [[ "$output" != *"secrets"* ]]
}

@test "a second install changes nothing: same files, same secrets, same state" {
    lc install
    before="$(cat "$SECRETS/librechat.env" "$SECRETS/librechat-db.env")"
    state_before="$(cat "$STATE/components/librechat.json")"
    sleep 1
    lc install
    [ "$status" -eq 0 ]
    [ "$(cat "$SECRETS/librechat.env" "$SECRETS/librechat-db.env")" = "$before" ]
    [ "$(cat "$STATE/components/librechat.json")" = "$state_before" ]
}

@test "install opens the registration by default and says so; --allow-registration false closes it silently" {
    lc install
    [[ "$stderr" == *"[WARN] registration is open: the first account created becomes the administrator"* ]]
    grep -q '^ALLOW_REGISTRATION=true$' "$SECRETS/librechat.env"
    lc install --allow-registration false
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"registration is open"* ]]
    grep -q '^ALLOW_REGISTRATION=false$' "$SECRETS/librechat.env"
    [ "$(jq -r '.params["allow-registration"]' "$STATE/components/librechat.json")" = "false" ]
}

@test "changing the registration keeps the secrets and recreates the api by Compose, not the whole stack" {
    lc install
    pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SECRETS/librechat-db.env")"
    jwt="$(sed -n 's/^JWT_SECRET=//p' "$SECRETS/librechat.env")"
    lc install --allow-registration false
    [ "$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SECRETS/librechat-db.env")" = "$pw" ]
    [ "$(sed -n 's/^JWT_SECRET=//p' "$SECRETS/librechat.env")" = "$jwt" ]
}

@test "the registration accepts the usual spellings of a boolean" {
    lc install --allow-registration NO
    [ "$status" -eq 0 ]
    grep -q '^ALLOW_REGISTRATION=false$' "$SECRETS/librechat.env"
    EASY_CS_AI_LIBRECHAT_ALLOW_REGISTRATION=yes lc install
    grep -q '^ALLOW_REGISTRATION=true$' "$SECRETS/librechat.env"
}

@test "--port, --db-port and --bind reach the files and the state" {
    lc install --port 4000 --db-port 28017 --bind 0.0.0.0
    [ "$status" -eq 0 ]
    grep -q '^PORT=4000$' "$SECRETS/librechat.env"
    grep -q '^HOST=0.0.0.0$' "$SECRETS/librechat.env"
    grep -q '@127.0.0.1:28017/LibreChat$' "$SECRETS/librechat.env"
    grep -q '"127.0.0.1:28017:27017"' "$CONF/docker-compose.yml"
    [ "$(jq -r '.params.port, .params["db-port"], .params.bind' "$STATE/components/librechat.json" | tr '\n' ' ')" = "4000 28017 0.0.0.0 " ]
    # nginx reaches a wildcard bind on the loopback
    grep -q 'nginx add-site librechat http://127.0.0.1:4000' "$CALLS"
}

@test "a version other than the pinned one is pulled by tag, with a warning" {
    lc install --version 0.9.1
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"LibreChat 0.9.1 is pulled by tag"* ]]
    grep -q 'image: ghcr.io/danny-avila/librechat:v0.9.1$' "$CONF/docker-compose.yml"
    [ "$(jq -r .version "$STATE/components/librechat.json")" = "0.9.1" ]
    lc install --version 0.8.7
    grep -q 'librechat@sha256:' "$CONF/docker-compose.yml"
}

@test "the web interface is served by nginx once installed, and its URL is recorded" {
    lc install
    [ "$status" -eq 0 ]
    grep -q '^nginx add-site librechat http://127.0.0.1:3080$' "$CALLS"
    [ "$(jq -r .url "$STATE/components/librechat.json")" = "https://ai.test:8443/" ]
}

@test "when nginx cannot serve the site the install stops with its exit code, installed and re-runnable" {
    FAKE_PROXY_FAIL=6 lc install
    [ "$status" -eq 6 ]
    [[ "$stderr" == *"installed but nginx could not serve it"* ]]
    [ -f "$STATE/components/librechat.json" ]
    lc install
    [ "$status" -eq 0 ]
    [ "$(jq -r .url "$STATE/components/librechat.json")" = "https://ai.test:8443/" ]
}

@test "a reinstall keeps the endpoints and the URL" {
    lc install
    lc add-endpoint ollama-m http://127.0.0.1:11434/v1 --model m
    lc install --allow-registration false
    [ "$status" -eq 0 ]
    [ "$(jq -c '.endpoints | map(.name)' "$STATE/components/librechat.json")" = '["ollama-m"]' ]
    [ "$(jq -r .url "$STATE/components/librechat.json")" = "https://ai.test:8443/" ]
    grep -q 'name: "ollama-m"' "$CONF/librechat.yaml"
}

@test "--default is applied only on request after the first install" {
    lc install
    [ "$(jq -r .default "$STATE/components/librechat.json")" = "true" ]
    install_state other chat-interface '"default":false'
    lc install --default
    [ "$status" -eq 0 ]
    [ "$(jq -r .default "$STATE/components/other.json")" = "false" ]
}

@test "install journals start and end" {
    lc install
    [[ "$stderr" == *"librechat install start version=0.8.7 params=port=3080,bind=127.0.0.1,db-port=27017,allow-registration=true"* ]]
    [[ "$stderr" == *"librechat install end exit=0"* ]]
}

@test "install --dry-run changes nothing and still shows the registration warning" {
    lc install --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"registration is open"* ]]
    [ ! -e "$CONF" ]
    [ ! -e "$STATE/components/librechat.json" ]
    [ ! -s "$CALLS" ]
}

@test "install fails at once when the component lock is held" {
    mkdir -p "$STATE/locks"
    (
        exec 8>>"$STATE/locks/chat-interface-librechat.lock"
        flock 8
        sleep 5
    ) &
    holder=$!
    sleep 1
    lc install
    kill "$holder" 2>/dev/null || true
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"another action is running on librechat"* ]]
}

@test "when Docker is missing the install asks for its apt repository first" {
    export EASY_CS_AI_DOCKER="$BATS_TEST_TMPDIR/no-such-docker"
    printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$SYS/etc-os-release.tmp"
    mkdir -p "$SYS/etc"
    mv "$SYS/etc-os-release.tmp" "$SYS/etc/os-release"
    lc install
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"installing Docker from its apt repository (ubuntu noble"* ]]
    [ -f "$SYS/etc/apt/sources.list.d/docker.list" ]
}

# --- endpoints ----------------------------------------------------------------------

@test "add-endpoint declares the endpoint with its model, records it and prints its URL" {
    lc install
    lc add-endpoint ollama-llama3.2-3b http://127.0.0.1:11434/v1 --model llama3.2:3b
    [ "$status" -eq 0 ]
    [ "$(jq -r .url <<<"$output")" = "http://127.0.0.1:11434/v1" ]
    f="$CONF/librechat.yaml"
    grep -q '^endpoints:$' "$f"
    grep -q '    - name: "ollama-llama3.2-3b"' "$f"
    grep -q '      apiKey: "unused"' "$f"
    grep -q '      baseURL: "http://127.0.0.1:11434/v1"' "$f"
    grep -q '        default: \["llama3.2:3b"\]' "$f"
    grep -q '        fetch: false' "$f"
    grep -q '      titleConvo: false' "$f"
    run jq -c '.endpoints' "$STATE/components/librechat.json"
    [ "$output" = '[{"name":"ollama-llama3.2-3b","url":"http://127.0.0.1:11434/v1","model":"llama3.2:3b"}]' ]
}

@test "add-endpoint recreates only the api container, with no dependency" {
    lc install
    : >"$CALLS"
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m
    [[ "$stderr" == *"docker compose up -d --no-deps --force-recreate api"* ]]
}

@test "add-endpoint without a model fetches the list of models of the endpoint" {
    lc install
    lc add-endpoint e1 http://127.0.0.1:8001/v1
    [ "$status" -eq 0 ]
    grep -q '        default: \["e1"\]' "$CONF/librechat.yaml"
    grep -q '        fetch: true' "$CONF/librechat.yaml"
}

@test "add-endpoint never writes an API key: the engines on the same machine need none" {
    lc install
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m
    ! grep -q 'Bearer' "$CONF/librechat.yaml"
    grep -c 'apiKey: "unused"' "$CONF/librechat.yaml" | grep -q '^1$'
}

@test "add-endpoint is idempotent and updates a changed URL" {
    lc install
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m
    first="$output"
    : >"$CALLS"
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m
    [ "$output" = "$first" ]
    [[ "$stderr" != *"force-recreate"* ]]
    lc add-endpoint e1 http://127.0.0.1:11435/v1 --model m
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"force-recreate"* ]]
    [ "$(jq -c '.endpoints | map(.url)' "$STATE/components/librechat.json")" = '["http://127.0.0.1:11435/v1"]' ]
    [ "$(grep -c 'name: "e1"' "$CONF/librechat.yaml")" -eq 1 ]
}

@test "several endpoints coexist" {
    lc install
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m1
    lc add-endpoint e2 http://127.0.0.1:8001/v1 --model m2
    [ "$(jq -c '.endpoints | map(.name)' "$STATE/components/librechat.json")" = '["e1","e2"]' ]
    [ "$(grep -c '    - name:' "$CONF/librechat.yaml")" -eq 2 ]
}

@test "add-endpoint validates its arguments and needs an installed LibreChat" {
    lc add-endpoint e1 http://127.0.0.1:11434/v1
    [ "$status" -eq 4 ]
    lc install
    lc add-endpoint
    [ "$status" -eq 2 ]
    lc add-endpoint 'Bad Name' http://127.0.0.1:11434/v1
    [ "$status" -eq 2 ]
    lc add-endpoint ../x http://127.0.0.1:11434/v1
    [ "$status" -eq 2 ]
    lc add-endpoint e1
    [ "$status" -eq 2 ]
    lc add-endpoint e1 'http://x"; evil: "'
    [ "$status" -eq 2 ]
    lc add-endpoint e1 ftp://127.0.0.1
    [ "$status" -eq 2 ]
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model 'a"b'
    [ "$status" -eq 2 ]
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model
    [ "$status" -eq 2 ]
}

@test "remove-endpoint removes the entry, and the endpoints key with the last one; it is idempotent" {
    lc install
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m1
    lc add-endpoint e2 http://127.0.0.1:8001/v1 --model m2
    lc remove-endpoint e1
    [ "$status" -eq 0 ]
    ! grep -q 'name: "e1"' "$CONF/librechat.yaml"
    grep -q 'name: "e2"' "$CONF/librechat.yaml"
    lc remove-endpoint e2
    [ "$(jq -c '.endpoints' "$STATE/components/librechat.json")" = "[]" ]
    ! grep -q 'endpoints:' "$CONF/librechat.yaml"
    : >"$CALLS"
    lc remove-endpoint e2
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"force-recreate"* ]]
}

@test "add-endpoint and remove-endpoint --dry-run change nothing" {
    lc install
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m --dry-run
    [ "$status" -eq 0 ]
    ! grep -q 'name: "e1"' "$CONF/librechat.yaml"
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m
    lc remove-endpoint e1 --dry-run
    grep -q 'name: "e1"' "$CONF/librechat.yaml"
}

@test "the generated YAML stays valid with endpoints" {
    lc install
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model llama3.2:3b
    lc add-endpoint e2 http://127.0.0.1:8001/v1
    python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert d["version"] == "1.2.8"; assert [e["name"] for e in d["endpoints"]["custom"]] == ["e1", "e2"]; assert d["endpoints"]["custom"][0]["models"]["default"] == ["llama3.2:3b"]' "$CONF/librechat.yaml" ||
        skip "python3 with PyYAML is not available"
}

# --- status -------------------------------------------------------------------------

@test "status of a missing LibreChat exits 4" {
    lc status
    [ "$status" -eq 4 ]
    [ "$(jq -r .installed <<<"$output")" = "false" ]
}

@test "status of an installed LibreChat reports it and exits 6 without health in test mode" {
    lc install
    lc status
    [ "$status" -eq 6 ]
    run jq -r '.installed, .healthy, .version, .schema_version' <<<"$output"
    [ "${lines[0]}" = "true" ]
    [ "${lines[1]}" = "false" ]
    [ "${lines[2]}" = "0.8.7" ]
    [ "${lines[3]}" = "1" ]
}

# --- uninstall ----------------------------------------------------------------------

@test "uninstall removes the stack, the unit and the state, and keeps the database and the secrets" {
    lc install
    pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SECRETS/librechat-db.env")"
    : >"$CALLS"
    lc uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$CONF/docker-compose.yml" ]
    [ ! -e "$CONF/librechat.yaml" ]
    [ ! -e "$SYS/etc/systemd/system/easy-cs-ai-librechat.service" ]
    [ ! -e "$STATE/components/librechat.json" ]
    [ ! -e "$STATE/pending/librechat.json" ]
    [ -f "$SECRETS/librechat.env" ]
    [ "$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SECRETS/librechat-db.env")" = "$pw" ]
    [[ "$stderr" == *"the database and the secrets are kept"* ]]
    [[ "$stderr" == *"docker compose down"* && "$stderr" != *"down -v"* ]]
}

@test "uninstall tells nginx to stop serving the site" {
    lc install
    : >"$CALLS"
    lc uninstall
    grep -q '^nginx remove-site librechat$' "$CALLS"
}

@test "uninstall still succeeds when nginx cannot remove the site, with a warning" {
    lc install
    FAKE_PROXY_FAIL=6 lc uninstall
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"could not remove the site librechat"* ]]
    [ ! -e "$STATE/components/librechat.json" ]
}

@test "a reinstall after an uninstall reuses the kept secrets, so the kept database still opens" {
    lc install
    pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SECRETS/librechat-db.env")"
    jwt="$(sed -n 's/^JWT_SECRET=//p' "$SECRETS/librechat.env")"
    lc uninstall
    lc install
    [ "$status" -eq 0 ]
    [ "$(sed -n 's/^POSTGRES_PASSWORD=//p' "$SECRETS/librechat-db.env")" = "$pw" ]
    [ "$(sed -n 's/^JWT_SECRET=//p' "$SECRETS/librechat.env")" = "$jwt" ]
}

@test "uninstall --purge also removes the volume, the images and the secrets" {
    lc install
    lc uninstall --purge
    [ "$status" -eq 0 ]
    [ ! -e "$SECRETS/librechat.env" ]
    [ ! -e "$SECRETS/librechat-db.env" ]
    [[ "$stderr" == *"docker compose down -v --rmi all"* ]]
}

@test "uninstall of a LibreChat that is not installed exits 4" {
    lc uninstall
    [ "$status" -eq 4 ]
}

@test "uninstall cleans a failed install left as a pending manifest" {
    bash -c "source '$TREE/lib/common.sh'; pending_begin chat-interface librechat; track_file /etc/easy-cs-ai/librechat/docker-compose.yml"
    mkdir -p "$CONF"
    : >"$CONF/docker-compose.yml"
    lc uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$CONF/docker-compose.yml" ]
    [ ! -e "$STATE/pending/librechat.json" ]
}

@test "uninstall is refused while another component requires LibreChat, unless --force" {
    lc install
    install_state dependent chat-interface '"requires":["librechat"],"default":false'
    lc uninstall
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"dependent requires librechat"* ]]
    lc uninstall --force
    [ "$status" -eq 0 ]
}

@test "uninstall --dry-run changes nothing" {
    lc install
    lc uninstall --dry-run
    [ "$status" -eq 0 ]
    [ -f "$STATE/components/librechat.json" ]
    [ -f "$CONF/docker-compose.yml" ]
}

# --- an endpoint on another machine: a key and a certificate ---------------------------------

KEY=sk-the-key_0123456789.abc
mk_cert() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=$2" \
        -addext "subjectAltName=DNS:$2" -keyout "$BATS_TEST_TMPDIR/$1.key" -out "$BATS_TEST_TMPDIR/$1.crt" 2>/dev/null
}
mk_key() { printf '%s\n' "${2:-$KEY}" >"$BATS_TEST_TMPDIR/$1"; chmod 600 "$BATS_TEST_TMPDIR/$1"; }
secret_of() { printf '%s/librechat-endpoint-%s.env' "$SECRETS" "$1"; }

@test "add-endpoint declares the options of the remote link in its describe" {
    lc describe
    [ "$(jq -c '.action_options["add-endpoint"] | map(.name)' <<<"$output")" = '["model","api-key-file","ca-file"]' ]
}

@test "without the new options the rendered files are the ones of a local endpoint, byte for byte" {
    lc install
    compose_before="$(cat "$CONF/docker-compose.yml")"
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model m
    [ "$(cat "$CONF/docker-compose.yml")" = "$compose_before" ]
    run ! grep -q 'NODE_EXTRA_CA_CERTS\|librechat-endpoint\|ca-bundle' "$CONF/docker-compose.yml"
    grep -q '      apiKey: "unused"' "$CONF/librechat.yaml"
    grep -q '    env_file: ' "$CONF/docker-compose.yml"
    [ ! -e "$CONF/ca-bundle.crt" ]
    [ "$(jq -c '.endpoints' "$STATE/components/librechat.json")" = '[{"name":"e1","url":"http://127.0.0.1:11434/v1","model":"m"}]' ]
}

@test "--api-key-file: a secret file of its own, an environment reference in the yaml, the key nowhere else" {
    lc install
    mk_key k.txt
    : >"$CALLS"
    lc add-endpoint e1 https://llm.test/e1/v1 --model m --api-key-file "$BATS_TEST_TMPDIR/k.txt"
    [ "$status" -eq 0 ]
    f="$(secret_of e1)"
    [ "$(cat "$f")" = "EASY_CS_AI_KEY_E1=$KEY" ]
    [ "$(stat -c %a "$f")" = 600 ]
    # librechat.yaml carries a reference, the container reads the value from its environment file
    grep -qF '      apiKey: "${EASY_CS_AI_KEY_E1}"' "$CONF/librechat.yaml"
    grep -qF "      - /etc/easy-cs-ai/secrets/librechat-endpoint-e1.env" "$CONF/docker-compose.yml"
    grep -qF "      - /etc/easy-cs-ai/secrets/librechat.env" "$CONF/docker-compose.yml"
    # the key is in no other file, not in the state, the logs or the output
    run ! grep -rqF "$KEY" "$CONF" "$STATE"
    [[ "$output" != *"$KEY"* && "$stderr" != *"$KEY"* ]]
    # the path is in the secrets of the state, the value nowhere; the endpoint is recorded with a mark
    [ "$(jq -c '.secrets | map(select(test("endpoint")))' "$STATE/components/librechat.json")" = '["/etc/easy-cs-ai/secrets/librechat-endpoint-e1.env"]' ]
    [ "$(jq -c '.endpoints' "$STATE/components/librechat.json")" = '[{"name":"e1","url":"https://llm.test/e1/v1","model":"m","key":true}]' ]
}

@test "--api-key-file - reads stdin, a file that is too open is refused with exit 2, and --dry-run shows no key" {
    lc install
    run --separate-stderr bash -c 'printf "%s\n" "$1" | bash "$0" add-endpoint e1 https://llm.test/v1 --api-key-file -' "$SCRIPT" "$KEY"
    [ "$status" -eq 0 ]
    [ "$(cat "$(secret_of e1)")" = "EASY_CS_AI_KEY_E1=$KEY" ]
    mk_key open.txt
    chmod 644 "$BATS_TEST_TMPDIR/open.txt"
    lc add-endpoint e2 https://llm.test/v2 --api-key-file "$BATS_TEST_TMPDIR/open.txt"
    [ "$status" -eq 2 ]
    [ ! -e "$(secret_of e2)" ]
    mk_key ok.txt
    lc add-endpoint e3 https://llm.test/v3 --api-key-file "$BATS_TEST_TMPDIR/ok.txt" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output$stderr" != *"$KEY"* ]]
    [ ! -e "$(secret_of e3)" ]
    # a key the container could not read as it is written is refused
    mk_key bad.txt 'a b$c'
    lc add-endpoint e4 https://llm.test/v4 --api-key-file "$BATS_TEST_TMPDIR/bad.txt"
    [ "$status" -eq 2 ]
    lc add-endpoint e5 https://llm.test/v5 --api-key-file "$BATS_TEST_TMPDIR/missing"
    [ "$status" -eq 2 ]
}

@test "--ca-file: the certificate is copied, the bundle rebuilt and trusted by the api container" {
    lc install
    mk_cert c1 llm1.test
    mk_cert c2 llm2.test
    lc add-endpoint e1 https://llm1.test/v1 --ca-file "$BATS_TEST_TMPDIR/c1.crt"
    [ "$status" -eq 0 ]
    cmp "$CONF/ca-e1.crt" "$BATS_TEST_TMPDIR/c1.crt"
    cmp "$CONF/ca-bundle.crt" "$BATS_TEST_TMPDIR/c1.crt"
    grep -q 'NODE_EXTRA_CA_CERTS: /etc/easy-cs-ai/ca-bundle.crt' "$CONF/docker-compose.yml"
    grep -qF "      - /etc/easy-cs-ai/librechat/ca-bundle.crt:/etc/easy-cs-ai/ca-bundle.crt:ro" "$CONF/docker-compose.yml"
    lc add-endpoint e2 https://llm2.test/v1 --ca-file "$BATS_TEST_TMPDIR/c2.crt"
    # the endpoints share one bundle, rebuilt from all of them
    [ "$(grep -c 'BEGIN CERTIFICATE' "$CONF/ca-bundle.crt")" -eq 2 ]
    [ "$(jq -c '.files | map(select(test("ca-")))' "$STATE/components/librechat.json")" = '["/etc/easy-cs-ai/librechat/ca-bundle.crt","/etc/easy-cs-ai/librechat/ca-e1.crt","/etc/easy-cs-ai/librechat/ca-e2.crt"]' ]
    [ "$(jq -c '.endpoints | map(.ca)' "$STATE/components/librechat.json")" = '[true,true]' ]
}

@test "--ca-file refuses something that is not a PEM certificate" {
    lc install
    printf 'not a certificate\n' >"$BATS_TEST_TMPDIR/bad.crt"
    lc add-endpoint e1 https://llm.test/v1 --ca-file "$BATS_TEST_TMPDIR/bad.crt"
    [ "$status" -eq 2 ]
    lc add-endpoint e1 https://llm.test/v1 --ca-file "$BATS_TEST_TMPDIR/absent.crt"
    [ "$status" -eq 2 ]
    [ ! -e "$CONF/ca-e1.crt" ]
}

@test "the same key and certificate again change nothing, a new one replaces the old" {
    lc install
    mk_key k.txt
    mk_cert c1 llm1.test
    mk_cert c2 llm2.test
    lc add-endpoint e1 https://llm1.test/v1 --model m --api-key-file "$BATS_TEST_TMPDIR/k.txt" --ca-file "$BATS_TEST_TMPDIR/c1.crt"
    state="$(cat "$STATE/components/librechat.json")"
    : >"$CALLS"
    lc add-endpoint e1 https://llm1.test/v1 --model m --api-key-file "$BATS_TEST_TMPDIR/k.txt" --ca-file "$BATS_TEST_TMPDIR/c1.crt"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"force-recreate"* ]]
    [ "$(cat "$STATE/components/librechat.json")" = "$state" ]
    # a new key
    mk_key k2.txt other-key-value-98765
    lc add-endpoint e1 https://llm1.test/v1 --model m --api-key-file "$BATS_TEST_TMPDIR/k2.txt" --ca-file "$BATS_TEST_TMPDIR/c1.crt"
    [[ "$stderr" == *"force-recreate"* ]]
    [ "$(cat "$(secret_of e1)")" = "EASY_CS_AI_KEY_E1=other-key-value-98765" ]
    # a new certificate: the container is recreated although the compose file does not change
    lc add-endpoint e1 https://llm1.test/v1 --model m --api-key-file "$BATS_TEST_TMPDIR/k2.txt" --ca-file "$BATS_TEST_TMPDIR/c2.crt"
    [[ "$stderr" == *"force-recreate"* ]]
    cmp "$CONF/ca-bundle.crt" "$BATS_TEST_TMPDIR/c2.crt"
    # the same endpoint with no option goes back to the local link: no key, no certificate
    lc add-endpoint e1 https://llm1.test/v1 --model m
    [ ! -e "$(secret_of e1)" ] && [ ! -e "$CONF/ca-e1.crt" ] && [ ! -e "$CONF/ca-bundle.crt" ]
    grep -q '      apiKey: "unused"' "$CONF/librechat.yaml"
    run ! grep -q 'NODE_EXTRA_CA_CERTS' "$CONF/docker-compose.yml"
}

@test "remove-endpoint removes the key, the certificate and its share of the bundle" {
    lc install
    mk_key k.txt
    mk_cert c1 llm1.test
    mk_cert c2 llm2.test
    lc add-endpoint e1 https://llm1.test/v1 --api-key-file "$BATS_TEST_TMPDIR/k.txt" --ca-file "$BATS_TEST_TMPDIR/c1.crt"
    lc add-endpoint e2 https://llm2.test/v1 --ca-file "$BATS_TEST_TMPDIR/c2.crt"
    lc remove-endpoint e1
    [ "$status" -eq 0 ]
    [ ! -e "$(secret_of e1)" ] && [ ! -e "$CONF/ca-e1.crt" ]
    cmp "$CONF/ca-bundle.crt" "$BATS_TEST_TMPDIR/c2.crt"
    run ! grep -q 'EASY_CS_AI_KEY_E1' "$CONF/librechat.yaml" "$CONF/docker-compose.yml"
    [ "$(jq -c '[(.secrets | map(select(test("endpoint")))), (.files | map(select(test("ca-e1"))))]' "$STATE/components/librechat.json")" = '[[],[]]' ]
    lc remove-endpoint e2
    [ ! -e "$CONF/ca-bundle.crt" ]
}

@test "uninstall removes the certificates and the bundle and keeps the key, --purge removes the key too" {
    lc install
    mk_key k.txt
    mk_cert c1 llm1.test
    lc add-endpoint e1 https://llm1.test/v1 --api-key-file "$BATS_TEST_TMPDIR/k.txt" --ca-file "$BATS_TEST_TMPDIR/c1.crt"
    lc uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$CONF/ca-e1.crt" ] && [ ! -e "$CONF/ca-bundle.crt" ]
    [ ! -d "$CONF" ]
    [ -f "$(secret_of e1)" ]
    lc install
    lc add-endpoint e1 https://llm1.test/v1 --api-key-file "$BATS_TEST_TMPDIR/k.txt"
    lc uninstall --purge
    [ "$status" -eq 0 ]
    [ ! -e "$(secret_of e1)" ]
}

@test "a reinstall keeps the remote endpoints and their files" {
    lc install
    mk_key k.txt
    mk_cert c1 llm1.test
    lc add-endpoint e1 https://llm1.test/v1 --model m --api-key-file "$BATS_TEST_TMPDIR/k.txt" --ca-file "$BATS_TEST_TMPDIR/c1.crt"
    lc install
    [ "$status" -eq 0 ]
    [ -f "$(secret_of e1)" ] && [ -f "$CONF/ca-bundle.crt" ]
    grep -qF 'EASY_CS_AI_KEY_E1' "$CONF/librechat.yaml"
    grep -q 'NODE_EXTRA_CA_CERTS' "$CONF/docker-compose.yml"
    [ "$(jq -c '.secrets | map(select(test("endpoint")))' "$STATE/components/librechat.json")" = '["/etc/easy-cs-ai/secrets/librechat-endpoint-e1.env"]' ]
}

@test "add-endpoint options are given once: a second --model, --api-key-file or --ca-file is a usage error" {
    lc install
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model a --model b
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--model is given more than once"* ]]
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --model=a --model=b
    [ "$status" -eq 2 ]
    mk_key k.txt
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --api-key-file "$BATS_TEST_TMPDIR/k.txt" --api-key-file "$BATS_TEST_TMPDIR/k.txt"
    [ "$status" -eq 2 ]
    mk_cert c1 llm1.test
    lc add-endpoint e1 http://127.0.0.1:11434/v1 --ca-file "$BATS_TEST_TMPDIR/c1.crt" --ca-file "$BATS_TEST_TMPDIR/c1.crt"
    [ "$status" -eq 2 ]
    [ "$(jq -c '.endpoints' "$STATE/components/librechat.json")" = '[]' ]
}
