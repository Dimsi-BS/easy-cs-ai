#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The parity of the two ways to walk the journey (docs/spec-journey.md#parity): a session played
# from scripted answers, and the same decisions written as a configuration the way a program
# writes it. For each scenario of tests/unit/parity/ (a `.answers` file and its `.json` oracle,
# written by hand and not by the session) they must give the same configuration, the same plan
# and the same script, and what the session shows must be what the plan says.
#
# Fake catalog (`use_fake`, the default): provisioning llmfit, proxy prox, engine ollama (port,
# api-key secret), chat-interface chat (requires the type proxy, option allow-registration warns
# when true). `use_real` runs the shipped scripts instead.

SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
    GEN="${BATS_TEST_DIRNAME}/../../vm_script/generate.sh"
    CLI="${BATS_TEST_DIRNAME}/../../package/bin/easy-cs-ai"
    REAL="${BATS_TEST_DIRNAME}/../../install_scripts"
    PARITY="${BATS_TEST_DIRNAME}/parity"
    export EASY_CS_AI_HOME="$BATS_TEST_TMPDIR/home"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    export CALLS="$BATS_TEST_TMPDIR/llmfit-calls"
    export LLMFIT_READY="$BATS_TEST_TMPDIR/llmfit-ready"
    unset EASY_CS_AI_LOCK_HELD EASY_CS_AI_CLI_VERSION
    : >"$CALLS"
    PKG=(--package-version 0.1.0 --package-sha256 "$SHA")
    use_fake
    cd "$BATS_TEST_TMPDIR"
}

# --- catalogs --------------------------------------------------------------------------------

use_real() { export EASY_CS_AI_HOME="$REAL"; }

use_fake() {
    export EASY_CS_AI_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$EASY_CS_AI_HOME"/{provisioning,proxy,engine,chat-interface}
    ln -s "$REAL/lib" "$EASY_CS_AI_HOME/lib"
    ln -s "$REAL/guide.txt" "$EASY_CS_AI_HOME/guide.txt"
    printf 'provisioning llmfit\nproxy prox\nengine ollama\nchat-interface chat\n' >"$EASY_CS_AI_HOME/ranks.conf"
    : >"$EASY_CS_AI_HOME/default-models.conf"
    make_fake proxy prox '[]' '[]'
    make_fake engine ollama '[]' '[{"name":"port","default":"11434","secret":false,"description":"Listening port"},{"name":"api-key","default":"","secret":true,"description":"Key"}]'
    make_fake chat-interface chat '["proxy"]' '[{"name":"allow-registration","default":"true","secret":false,"description":"Open to all","warn":{"when":"true","message":"registration is open"}}]'
    make_llmfit
}

make_fake() {
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<FAKE
#!/usr/bin/env bash
jq -n '{name: "$2", type: "$1", component_version: "9.9", requires: $3, platforms: ["debian","ubuntu"], options: $4}'
FAKE
}

# llmfit is shipped, and installed here only once $LLMFIT_READY exists (llmfit_ready). Its
# suggest, check and plan print what the generator shows as it is.
make_llmfit() {
    cat >"$EASY_CS_AI_HOME/provisioning/llmfit.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$1" in
describe) jq -n '{name: "llmfit", type: "provisioning", component_version: "9.9", requires: [], platforms: ["debian","ubuntu"], options: []}' ;;
status)
    [[ -e "$LLMFIT_READY" ]] || { echo '{"installed":false,"running":false,"healthy":false}'; exit 4; }
    echo '{"installed":true,"running":true,"healthy":true}' ;;
suggest) printf '   1) llama3.2:3b                  Good, needs 2.4 GB\n   2) small:1b                     Perfect, needs 1.2 GB\n' ;;
plan) printf '\nFAKE RECOMMENDATION\n' ;;
check) echo '{"fits":true,"reason":"ok"}' ;;
esac
FAKE
}

llmfit_ready() { touch "$LLMFIT_READY"; }

# --- the two ways -------------------------------------------------------------------------------

# answers_of <file>: the lines to type. A line starting with # is a comment, a trailing ` # note`
# is cut, and an empty line is an answer (the default).
answers_of() { sed -E -e '/^#/d' -e 's/[[:space:]]+#.*$//' "$1"; }

# canonical <file>: the configuration with its keys sorted, and an option written as a number or
# a boolean read as its text (docs/spec-config.md: values are strings, numbers or booleans, and
# reach a script as text), which is all the session ever writes.
canonical() {
    jq -S '.components |= map(if .options then .options |= map_values(if type == "object" then . else tostring end) else . end)' "$1"
}

# embedded <script>: the configuration the script carries.
embedded() { sed -n "/<<'EASY_CS_AI_CONFIG'/,/^EASY_CS_AI_CONFIG\$/p" "$1" | sed '1d;$d'; }

# bare <script>: the script without the date of its header, the only thing that changes between
# two runs, and without the configuration it embeds.
bare() {
    sed -E -e 's/ on [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ on DATE/' \
        -e "/<<'EASY_CS_AI_CONFIG'/,/^EASY_CS_AI_CONFIG\$/d" "$1"
}

# What the last summary of a session shows, from its stderr.
summary_order() {
    awk '/^  components, in install order:/ {out = ""; inb = 1; next} /^  models:/ {inb = 0} inb {out = out $1 " " $2 "\n"} END {printf "%s", out}' <<<"$1"
}
summary_models() { sed -n 's/^  models: //p' <<<"$1" | tail -n 1; }
# the warnings of the options: "    <component> --<option>=<value>: <message>"
summary_warnings() { grep -E '^    [^ ]+ --[a-z-]+=[^ ]*: ' <<<"$1" | sort -u || true; }

# parity <catalog> <scenario> [<oracle>]: play tests/unit/parity/<catalog>/<scenario>.answers in
# a session and compare it with the oracle, the .json of the same name unless another is given.
parity() {
    local dir="$PARITY/$1" scenario="$2" oracle plan session_err
    oracle="$dir/${3:-$2}.json"
    [ -r "$dir/$scenario.answers" ]
    [ -r "$oracle" ]
    answers_of "$dir/$scenario.answers" >stdin.txt

    # the decisions, written as a program writes them, are a valid configuration for a new VM
    run --separate-stderr bash "$CLI" config validate "$oracle" --target fresh --json
    [ "$status" -eq 0 ]
    plan="$output"

    # same configuration
    run --separate-stderr bash "$GEN" --config-only --output session.json <stdin.txt
    [ "$status" -eq 0 ]
    session_err="$stderr"
    diff -u <(canonical "$oracle") <(canonical session.json)

    # what the session shows is what the plan says
    [ "$(summary_order "$session_err")" = "$(jq -r '.plan.components[] | "\(.type) \(.name)"' <<<"$plan")" ]
    [ "$(summary_models "$session_err")" = "$(jq -r '[.plan.models[].name] | if length == 0 then "none" else join(", ") end' <<<"$plan")" ]
    diff -u <(jq -r '.warnings[] | "    \(.component.name) --\(.option)=\(.value): \(.message)"' <<<"$plan" | sort -u) \
        <(summary_warnings "$session_err")

    # same plan: the document of the generator on the oracle is the document of `config validate`
    run --separate-stderr bash "$GEN" --config "$oracle" --json "${PKG[@]}" --output c.sh
    [ "$status" -eq 0 ]
    diff -u <(jq -S . <<<"$plan") <(jq -S 'del(.script)' <<<"$output")

    # same script: all of it but the date, and the configuration it embeds, which is compared
    # as a configuration (the order of the keys and the spelling of an option are not decisions)
    run --separate-stderr bash "$GEN" "${PKG[@]}" --output session.sh <stdin.txt
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$GEN" --config "$oracle" "${PKG[@]}" --output oracle.sh </dev/null
    [ "$status" -eq 0 ]
    diff -u <(bare oracle.sh) <(bare session.sh)
    embedded oracle.sh >oracle-embedded.json
    embedded session.sh >session-embedded.json
    diff -u <(canonical oracle-embedded.json) <(canonical session-embedded.json)
}

# --- fake catalog -------------------------------------------------------------------------------

@test "parity: an engine and one model, added unchecked as no llmfit is in the stack" {
    parity fake minimal
}

@test "parity: a chat interface, the proxy it requires, an option, and a default that warns" {
    parity fake stack
    # `parity` compared the warnings of the plan with the summary of the session; here the
    # default does warn, so that comparison was not about nothing
    run --separate-stderr bash "$CLI" config validate "$PARITY/fake/stack.json" --target fresh --json
    [ "$(jq -r '.warnings | length' <<<"$output")" = 1 ]
}

@test "parity: a refused dependency sends the session back, and it ends on the same decisions" {
    parity fake refused minimal
}

@test "parity: a wrong answer and a redone step give the result of the straight path" {
    parity fake detour stack
}

@test "parity: models chosen from the hardware, with llmfit in the stack" {
    llmfit_ready
    parity fake hardware-first
    grep -qx 'suggest --target-ram 16 --target-cpu-cores 4' "$CALLS"
}

@test "parity: models named first, the VM they need is shown and nothing of it is stored" {
    llmfit_ready
    parity fake models-first
    grep -qx 'plan m1 m2' "$CALLS"
}

# --- the shipped scripts ------------------------------------------------------------------------

@test "parity, shipped scripts: the default stack with every option at its default" {
    use_real
    parity real default-stack
}

@test "parity, shipped scripts: another server name, the registration closed, no llmfit" {
    use_real
    parity real closed-registration
}

# --- structure: a question is a field, a missing answer is reported -----------------------------------

# every_option_is_asked: for each component of the catalog, a session that selects it (and accepts
# what it requires) asks every option of it, and says it will generate a secret.
every_option_is_asked() {
    local catalog selection type name opt secret asked=0
    run --separate-stderr bash "$CLI" catalog --json
    [ "$status" -eq 0 ]
    catalog="$output"
    while IFS=$'\t' read -r type name; do
        # one answer per type that has a component: this one, and none for the others, then the
        # defaults (the dependencies are accepted, the confirmation is yes)
        selection="$(jq -r --arg t "$type" --arg n "$name" '. as $c | $c.types[]
            | select(. as $x | $c.components | any(.type == $x)) | if . == $t then $n else "none" end' <<<"$catalog")"
        { printf '%s\n' "$selection"; printf '\n%.0s' {1..200}; } >stdin.txt
        run --separate-stderr bash "$GEN" --config-only --output cfg.json <stdin.txt
        [ "$status" -eq 0 ]
        [ -s cfg.json ]
        while IFS=$'\t' read -r opt secret; do
            asked=$((asked + 1))
            if [ "$secret" = true ]; then
                [[ "$stderr" == *"$name: $opt is a secret"* ]]
            else
                [[ "$stderr" == *"$name --$opt: "* || "$stderr" == *"$name --$opt ["* ]]
            fi
        done < <(jq -r --arg t "$type" --arg n "$name" '.components[] | select(.type == $t and .name == $n)
            | .describe.options[]? | [.name, (.secret // false)] | @tsv' <<<"$catalog")
    done < <(jq -r '.components[] | [.type, .name] | @tsv' <<<"$catalog")
    # the check ran on something
    [ "$asked" -gt 0 ]
}

@test "a question is a field: the session asks every option of the fake catalog" {
    every_option_is_asked
}

@test "a question is a field: the session asks every option of the shipped scripts" {
    use_real
    every_option_is_asked
}

@test "a missing answer is reported to a program, and it is the question the session asks" {
    echo '{"schema_version":1,"components":[{"type":"chat-interface","name":"chat"}]}' >cfg.json
    run --separate-stderr bash "$CLI" config validate cfg.json --target fresh --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0].code' <<<"$output")" = missing_requirement ]
    [[ "$(jq -r '.errors[0].message' <<<"$output")" == *proxy* ]]
    [ "$(jq -r '.plan' <<<"$output")" = null ]
    # the session proposes it, and what it writes is then valid
    answers_of "$PARITY/fake/stack.answers" | sed '1,2s/.*/none/' >stdin.txt
    run --separate-stderr bash "$GEN" --config-only --output session.json <stdin.txt
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"chat requires proxy: add proxy prox?"* ]]
    run --separate-stderr bash "$CLI" config validate session.json --target fresh --json
    [ "$status" -eq 0 ]
}

# --- the guide ----------------------------------------------------------------------------------

@test "the guide names only commands and options that exist" {
    run bash "$CLI" --help
    [ "$status" -eq 0 ]
    usage="$output"
    # `easy-cs-ai <word>`: the word is a command (or a type) of the usage
    while read -r word; do
        grep -qw -- "$word" <<<"$usage" || { echo "the guide names the command '$word', which the usage does not list" >&2; false; }
    done < <(grep -oE 'easy-cs-ai [a-z][a-z-]*' "$REAL/guide.txt" | cut -d' ' -f2 | sort -u)
    # `--option`: it appears in a script of the project
    while read -r flag; do
        grep -rqF -e "$flag" "$CLI" "$REAL/lib" "$REAL/provisioning" "$GEN" || { echo "the guide names the option '$flag', which no script knows" >&2; false; }
    done < <(grep -oE -- '--[a-z][a-z-]*' "$REAL/guide.txt" | sort -u)
}

@test "the guide lists what a program never does on its own" {
    # docs/spec-journey.md#what-a-program-never-does-on-its-own
    for word in uninstall remove '--prune' '--purge' exec show-key; do
        grep -qF -e "$word" "$REAL/guide.txt" || { echo "the guide does not name $word" >&2; false; }
    done
}
