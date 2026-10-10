#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# A fake llmfit on the PATH answers like the real one (observed with v1.1.16):
#   info <name> --json   {"system":…,"models":[{…}]}, or {"error":{"kind","message"}} and exit 1
#   fit --json -n N      {"system":…,"models":[…]} limited to the models that fit
#   recommend --json     {"system":…,"models":[…]}

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../../install_scripts/provisioning/llmfit.sh"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    STATE="$EASY_CS_AI_ROOT/var/lib/easy-cs-ai"
    unset EASY_CS_AI_LOCK_HELD EASY_CS_AI_LLMFIT_VERSION
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/llmfit" <<'FAKE'
#!/usr/bin/env bash
echo "llmfit $*" >>"${CALLS:-/dev/null}"
# the hardware overrides are global options, before the subcommand
while [[ "${1:-}" == --ram || "${1:-}" == --memory || "${1:-}" == --cpu-cores ]]; do shift 2; done
case "$1" in
--version) echo "llmfit 1.1.16" ;;
info)
    case "$2" in
    meta-llama/Llama-3.2-3B-Instruct)
        echo '{"system":{},"models":[{"name":"meta-llama/Llama-3.2-3B-Instruct","fit_level":"Good","run_mode":"CPU","memory_required_gb":4.75,"memory_available_gb":9.96}]}' ;;
    meta-llama/Llama-3.1-70B-Instruct)
        echo '{"system":{},"models":[{"name":"meta-llama/Llama-3.1-70B-Instruct","fit_level":"Too Tight","run_mode":"CPU","memory_required_gb":43.92,"memory_available_gb":9.96}]}' ;;
    *) echo '{"error":{"kind":"model_not_found","message":"No model found matching x"}}'; exit 1 ;;
    esac ;;
fit)
    echo '{"system":{},"models":[
      {"name":"meta-llama/Llama-3.2-3B","ollama_name":"llama3.2:3b","fit_level":"Good","run_mode":"CPU","score":70,"memory_required_gb":3.1,"memory_available_gb":9.96},
      {"name":"meta-llama/Llama-3.2-3B-Instruct","ollama_name":"llama3.2:3b","fit_level":"Good","run_mode":"CPU","score":80,"memory_required_gb":4.75,"memory_available_gb":9.96},
      {"name":"deepseek-ai/DeepSeek-R1-Distill-Qwen-14B","ollama_name":"deepseek-r1:14b","fit_level":"Marginal","run_mode":"CPU","score":60,"memory_required_gb":9.5,"memory_available_gb":9.96}]}' ;;
recommend)
    [[ "${FAKE_BROKEN:-}" == 1 ]] && { echo "not json"; exit 0; }
    echo '{"system":{},"models":[{"name":"m","fit_level":"Good"}]}' ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/llmfit"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export CALLS="$BATS_TEST_TMPDIR/calls"
}

llmfit() { run --separate-stderr bash "$SCRIPT" "$@"; }

# --- describe, usage ---------------------------------------------------------------------------

@test "describe is valid and declares the provisioning actions" {
    llmfit describe
    [ "$status" -eq 0 ]
    run jq -r '.name, .type, .native.command, (.actions | join(" "))' <<<"$output"
    [ "${lines[0]}" = "llmfit" ]
    [ "${lines[1]}" = "provisioning" ]
    [ "${lines[2]}" = "llmfit" ]
    [[ "${lines[3]}" == *"recommend"*"check"* ]]
}

@test "usage errors exit 2" {
    llmfit
    [ "$status" -eq 2 ]
    llmfit frobnicate
    [ "$status" -eq 2 ]
    llmfit install --nope
    [ "$status" -eq 2 ]
    llmfit install --version 1.x
    [ "$status" -eq 2 ]
    llmfit install --health-timeout abc
    [ "$status" -eq 2 ]
}

@test "--version prints the script version, with a value it selects the llmfit version" {
    llmfit --version
    [ "$output" = "0.1.0" ]
    llmfit install --version 1.2.0
    [ "$(jq -r .version "$STATE/components/llmfit.json")" = "1.2.0" ]
}

# --- install, status, uninstall ----------------------------------------------------------------

@test "install records the state: no service, no endpoint, the binary as a file" {
    llmfit install
    [ "$status" -eq 0 ]
    run jq -c '[.name, .type, .version, .default, .files, has("service"), has("endpoint")]' "$STATE/components/llmfit.json"
    [ "$output" = '["llmfit","provisioning","1.1.16",true,["/usr/local/bin/llmfit"],false,false]' ]
    [ ! -e "$STATE/pending/llmfit.json" ]
    [[ "$stderr" == *"llmfit install start version=1.1.16"* ]]
}

@test "install twice changes nothing; a new version updates the state" {
    llmfit install
    before="$(cat "$STATE/components/llmfit.json")"
    llmfit install
    [[ "$stderr" == *"already installed"* ]]
    [ "$(cat "$STATE/components/llmfit.json")" = "$before" ]
    llmfit install --version 1.1.17
    [[ "$stderr" != *"already installed"* ]]
    [ "$(jq -r .version "$STATE/components/llmfit.json")" = "1.1.17" ]
}

@test "--dry-run changes nothing" {
    llmfit install --dry-run
    [ "$status" -eq 0 ]
    [ ! -e "$STATE/components/llmfit.json" ]
}

@test "status: not installed exits 4; installed and answering is healthy; broken JSON is exit 6" {
    llmfit status
    [ "$status" -eq 4 ]
    llmfit install
    llmfit status
    [ "$status" -eq 0 ]
    run jq -c '[.installed, .running, .healthy, .version]' <<<"$output"
    [ "$output" = '[true,true,true,"1.1.16"]' ]
    FAKE_BROKEN=1 llmfit status
    [ "$status" -eq 6 ]
    run jq -r .healthy <<<"$output"
    [ "$output" = "false" ]
}

@test "uninstall accepts --purge, which the CLI forwards to every component, and has nothing more to remove" {
    llmfit install
    llmfit uninstall --purge
    [ "$status" -eq 0 ]
    [ ! -e "$STATE/components/llmfit.json" ]
}

@test "uninstall removes the state; not installed is exit 4; a dependent blocks it" {
    llmfit uninstall
    [ "$status" -eq 4 ]
    llmfit install
    bash -c "source '${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh'; state_write other '{\"name\":\"other\",\"type\":\"engine\",\"requires\":[\"provisioning\"]}'"
    llmfit uninstall
    [ "$status" -eq 4 ]
    llmfit uninstall --force
    [ "$status" -eq 0 ]
    [ ! -e "$STATE/components/llmfit.json" ]
}

# --- recommend ----------------------------------------------------------------------------------

@test "recommend prints llmfit's JSON untouched and passes its options" {
    llmfit install
    llmfit recommend -n 3 --use-case coding
    [ "$status" -eq 0 ]
    run jq -r '.models[0].name' <<<"$output"
    [ "$output" = "m" ]
    grep -q 'llmfit recommend --json --no-dashboard -n 3 --use-case coding' "$CALLS"
}

@test "recommend and check need an installed llmfit" {
    llmfit recommend
    [ "$status" -eq 4 ]
    llmfit check meta-llama/Llama-3.2-3B-Instruct
    [ "$status" -eq 4 ]
}

# --- check -----------------------------------------------------------------------------------------

@test "check by Hugging Face name: fits, with the reason" {
    llmfit install
    llmfit check meta-llama/Llama-3.2-3B-Instruct
    [ "$status" -eq 0 ]
    run jq -r '.fits, .reason' <<<"$output"
    [ "${lines[0]}" = "true" ]
    [[ "${lines[1]}" == *"fit Good"*"needs 4.75 GB of 9.96 GB"* ]]
}

@test "check: Too Tight does not fit but exits 0" {
    llmfit install
    llmfit check meta-llama/Llama-3.1-70B-Instruct
    [ "$status" -eq 0 ]
    run jq -r '.fits, .reason' <<<"$output"
    [ "${lines[0]}" = "false" ]
    [[ "${lines[1]}" == *"Too Tight"*"needs 43.92 GB"* ]]
}

@test "check by Ollama tag uses the best scored entry that carries it" {
    llmfit install
    llmfit check llama3.2:3b
    [ "$status" -eq 0 ]
    run jq -r '.fits, .reason' <<<"$output"
    [ "${lines[0]}" = "true" ]
    [[ "${lines[1]}" == "meta-llama/Llama-3.2-3B-Instruct:"* ]]
}

@test "check: Marginal still fits" {
    llmfit install
    llmfit check deepseek-r1:14b
    [ "$(jq -r .fits <<<"$output")" = "true" ]
}

@test "check of an unknown model is exit 1 and suggests --force; no name is exit 2" {
    llmfit install
    llmfit check nosuchmodel
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"does not know 'nosuchmodel'"*"--force"* ]]
    llmfit check
    [ "$status" -eq 2 ]
}

# --- sizing for another machine (docs/spec-ai-interface.md) ------------------------------------------

@test "recommend sizes for another machine: the --target-* options become llmfit's global options, before the subcommand" {
    llmfit install
    : >"$CALLS"
    llmfit recommend --target-ram 8 --target-vram=24 --target-cpu-cores 4 -n 3
    [ "$status" -eq 0 ]
    grep -qx 'llmfit --ram 8 --memory 24 --cpu-cores 4 recommend --json --no-dashboard -n 3' "$CALLS"
}

@test "check sizes for another machine, by Hugging Face name and by Ollama tag" {
    llmfit install
    : >"$CALLS"
    llmfit check meta-llama/Llama-3.2-3B-Instruct --target-ram 8
    [ "$status" -eq 0 ]
    grep -qx 'llmfit --ram 8 info meta-llama/Llama-3.2-3B-Instruct --json --no-dashboard' "$CALLS"
    : >"$CALLS"
    llmfit check llama3.2:3b --target-ram 8 --target-cpu-cores 2
    [ "$status" -eq 0 ]
    grep -qx 'llmfit --ram 8 --cpu-cores 2 fit --json -n 100000 --no-dashboard' "$CALLS"
}

@test "without --target-* llmfit is called as before" {
    llmfit install
    : >"$CALLS"
    llmfit check meta-llama/Llama-3.2-3B-Instruct
    grep -qx 'llmfit info meta-llama/Llama-3.2-3B-Instruct --json --no-dashboard' "$CALLS"
}

@test "--target-* needs a positive whole number and only applies to recommend and check" {
    llmfit install
    llmfit recommend --target-ram 0
    [ "$status" -eq 2 ]
    llmfit recommend --target-ram eight
    [ "$status" -eq 2 ]
    llmfit recommend --target-ram
    [ "$status" -eq 2 ]
    llmfit status --target-ram 8
    [ "$status" -eq 2 ]
    llmfit install --target-vram 8
    [ "$status" -eq 2 ]
}

@test "a missing llmfit is exit 4 with the command that installs it" {
    llmfit recommend --target-ram 8
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"easy-cs-ai install provisioning llmfit"* ]]
}

@test "describe declares the target options of recommend and check, apart from the install options" {
    llmfit describe
    run jq -r '(.action_options.recommend | map(.name) | join(" ")), (.action_options.check | map(.name) | join(" ")), (.options | map(.name) | join(" "))' <<<"$output"
    [ "${lines[0]}" = "target-ram target-vram target-cpu-cores" ]
    [ "${lines[1]}" = "target-ram target-vram target-cpu-cores" ]
    [[ "${lines[2]}" != *target* ]]
}
