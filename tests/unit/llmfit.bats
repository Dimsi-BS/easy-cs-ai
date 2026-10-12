#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# A fake llmfit on the PATH answers like the real one (observed with v1.1.16):
#   info <name> --json   {"system":…,"models":[{…}]}, or {"error":{"kind","message"}} and exit 1
#   fit --json -n N      {"system":…,"models":[…]} limited to the models that fit
#   recommend --json     {"system":…,"models":[…]}, what `suggest` reads

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
    echo '{"system":{},"models":[
      {"name":"hf/a","ollama_name":"small:1b","fit_level":"Perfect","score":70,"memory_required_gb":1.2},
      {"name":"hf/b","ollama_name":"llama3.2:3b","fit_level":"Good","score":90,"memory_required_gb":2.4},
      {"name":"hf/c","ollama_name":"huge:70b","fit_level":"Too Tight","score":99,"memory_required_gb":48},
      {"name":"hf/d","ollama_name":null,"fit_level":"Good","score":95,"memory_required_gb":3}]}' ;;
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
    [[ "${lines[3]}" == *"suggest"*"check"*"size"*"plan"* ]]
    [[ "${lines[3]}" != *"recommend"* ]]
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

@test "suggest lists the Ollama tags that fit, best score first, never a Too Tight one" {
    llmfit install
    : >"$CALLS"
    llmfit suggest --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.models[].name]' <<<"$output")" = '["llama3.2:3b","small:1b"]' ]
    [ "$(jq -c '.models[0]' <<<"$output")" = '{"name":"llama3.2:3b","llmfit_name":"hf/b","fit_level":"Good","memory_required_gb":2.4,"score":90}' ]
    # llmfit is asked for everything, the selection is the action's
    grep -qx 'llmfit recommend --json --no-dashboard -n 100000' "$CALLS"
}

@test "suggest -n limits the list, and a wrong -n is a usage error" {
    llmfit install
    llmfit suggest --json -n 1
    [ "$(jq -c '[.models[].name]' <<<"$output")" = '["llama3.2:3b"]' ]
    llmfit suggest -n 0
    [ "$status" -eq 2 ]
    llmfit suggest -n
    [ "$status" -eq 2 ]
    llmfit check meta-llama/Llama-3.2-3B-Instruct -n 1
    [ "$status" -eq 2 ]
}

@test "suggest and check need an installed llmfit" {
    llmfit suggest --json
    [ "$status" -eq 4 ]
    llmfit check meta-llama/Llama-3.2-3B-Instruct
    [ "$status" -eq 4 ]
}

@test "recommend is not an action any more" {
    llmfit install
    llmfit recommend
    [ "$status" -eq 2 ]
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

@test "suggest sizes for another machine: the --target-* options become llmfit's global options, before the subcommand" {
    llmfit install
    : >"$CALLS"
    llmfit suggest --target-ram 8 --target-vram=24 --target-cpu-cores 4 -n 3
    [ "$status" -eq 0 ]
    grep -qx 'llmfit --ram 8 --memory 24 --cpu-cores 4 recommend --json --no-dashboard -n 100000' "$CALLS"
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

@test "--target-* needs a positive whole number and only applies to suggest and check" {
    llmfit install
    llmfit suggest --target-ram 0
    [ "$status" -eq 2 ]
    llmfit suggest --target-ram eight
    [ "$status" -eq 2 ]
    llmfit suggest --target-ram
    [ "$status" -eq 2 ]
    llmfit status --target-ram 8
    [ "$status" -eq 2 ]
    llmfit install --target-vram 8
    [ "$status" -eq 2 ]
}

# --- size ---------------------------------------------------------------------------------------

# a fake llmfit that sizes like the real one (observed with v1.1.17): the best quantisation on a
# large machine, the default one (Q4_K_M, "Too Tight") on a tiny one, a bit more with GPU memory
make_sizing_llmfit() {
    cat >"$BATS_TEST_TMPDIR/bin/llmfit" <<'FAKE'
#!/usr/bin/env bash
echo "llmfit $*" >>"${CALLS:-/dev/null}"
ram=0 mem=0
while [[ "${1:-}" == --ram || "${1:-}" == --memory ]]; do
    if [[ "$1" == --ram ]]; then ram="$2"; else mem="$2"; fi
    shift 2
done
case "$1" in
--version) echo "llmfit 1.1.16" ;;
fit) echo '{"models":[{"name":"hf/m","ollama_name":"m:8b","score":1}]}' ;;
info)
    [[ "$2" == hf/m ]] || { echo '{"error":{"kind":"model_not_found","message":"no"}}'; exit 1; }
    if ((ram > 100)); then
        quant=Q8_0 disk=8.43 req=9.93 gpu=10.43
    else
        quant=Q4_K_M disk=4.66 req=6.16 gpu=6.46
    fi
    ((mem > 0)) && req=$gpu
    # one of the four calls fails
    [[ "${FAKE_SIZE_FAIL:-}" == tiny-gpu ]] && ((ram == 1 && mem > 0)) && { echo '{"error":{"kind":"x","message":"x"}}'; exit 1; }
    jq -n --arg q "$quant" --argjson d "$disk" --argjson r "$req" \
        '{models: [{name: "hf/m", ollama_name: "m:8b", is_moe: false, best_quant: $q, disk_size_gb: $d, memory_required_gb: $r, estimate_basis: {assumed_context: 8192}}]}' ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/llmfit"
}

@test "size: memory and disk of a model for the best and the default quantisation, with and without GPU memory" {
    llmfit install
    make_sizing_llmfit
    : >"$CALLS"
    llmfit size hf/m
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.name, .context, .moe]' <<<"$output")" = '["hf/m",8192,false]' ]
    [ "$(jq -c '.best' <<<"$output")" = '{"quant":"Q8_0","disk_gb":8.43,"cpu_gb":9.93,"gpu_gb":10.43}' ]
    [ "$(jq -c '.default' <<<"$output")" = '{"quant":"Q4_K_M","disk_gb":4.66,"cpu_gb":6.16,"gpu_gb":6.46}' ]
    # a very large machine for the best figures, a tiny one for the default ones
    grep -qx 'llmfit --ram 1024 info hf/m --json --no-dashboard' "$CALLS"
    grep -qx 'llmfit --ram 1024 --memory 1024 info hf/m --json --no-dashboard' "$CALLS"
    grep -qx 'llmfit --ram 1 info hf/m --json --no-dashboard' "$CALLS"
    grep -qx 'llmfit --ram 1 --memory 1 info hf/m --json --no-dashboard' "$CALLS"
}

@test "size: one of the four llmfit calls failing is exit 1 and leaves no temporary file" {
    llmfit install
    make_sizing_llmfit
    export FAKE_SIZE_FAIL=tiny-gpu TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    llmfit size hf/m
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"llmfit could not size 'hf/m'"* ]]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "size by Ollama tag: found on a large machine, then sized by its Hugging Face name" {
    llmfit install
    make_sizing_llmfit
    : >"$CALLS"
    llmfit size m:8b
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = "hf/m" ]
    grep -qx 'llmfit --ram 1024 --memory 1024 fit --json -n 100000 --no-dashboard' "$CALLS"
}

@test "size of an unknown model is exit 1, no name is exit 2, and it needs an installed llmfit" {
    llmfit size hf/m
    [ "$status" -eq 4 ]
    llmfit install
    make_sizing_llmfit
    llmfit size nosuchmodel
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"llmfit does not know 'nosuchmodel'"* ]]
    llmfit size
    [ "$status" -eq 2 ]
    llmfit size hf/m --target-ram 8
    [ "$status" -eq 2 ]
}

@test "a missing llmfit is exit 4 with the command that installs it" {
    llmfit suggest --target-ram 8
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"easy-cs-ai install provisioning llmfit"* ]]
}

@test "describe declares the options of suggest, check and plan, apart from the install options" {
    llmfit describe
    run jq -r '(.action_options.suggest | map(.name) | join(" ")), (.action_options.check | map(.name) | join(" ")), (.action_options.plan | map(.name) | join(" ")), (.options | map(.name) | join(" ")), (.action_options | has("recommend") | tostring)' <<<"$output"
    [ "${lines[0]}" = "target-ram target-vram target-cpu-cores n" ]
    [ "${lines[1]}" = "target-ram target-vram target-cpu-cores" ]
    [ "${lines[2]}" = "target-cpu-cores chat-interface" ]
    [[ "${lines[3]}" != *target* ]]
    [ "${lines[4]}" = "false" ]
}

# --- plan -----------------------------------------------------------------------------------------

# a fake llmfit that sizes two models like the real one (best quantisation on a large machine, the
# default one on a tiny one, a bit more with GPU memory): hf/m (best Q8_0 9.93 / 10.43 GB, disk 8.43;
# default Q4_K_M 6.16 / 6.46 GB, disk 4.66) and hf/small (a third of that); any other is unknown
make_planning_llmfit() {
    cat >"$BATS_TEST_TMPDIR/bin/llmfit" <<'FAKE'
#!/usr/bin/env bash
echo "llmfit $*" >>"${CALLS:-/dev/null}"
ram=0 mem=0
while [[ "${1:-}" == --ram || "${1:-}" == --memory ]]; do
    if [[ "$1" == --ram ]]; then ram="$2"; else mem="$2"; fi
    shift 2
done
case "$1" in
--version) echo "llmfit 1.1.16" ;;
fit) echo '{"models":[{"name":"hf/m","ollama_name":"m:8b","score":1}]}' ;;
info)
    case "$2" in hf/m) k=1 ;; hf/small) k=3 ;; *) echo '{"error":{"kind":"model_not_found","message":"no"}}'; exit 1 ;; esac
    if ((ram > 100)); then
        quant=Q8_0 disk=8.43 req=9.93 gpu=10.43
    else
        quant=Q4_K_M disk=4.66 req=6.16 gpu=6.46
    fi
    ((mem > 0)) && req=$gpu
    jq -n --arg n "$2" --arg q "$quant" --argjson k "$k" --argjson d "$disk" --argjson r "$req" \
        '{models: [{name: $n, ollama_name: null, is_moe: false, best_quant: $q, disk_size_gb: ($d / $k), memory_required_gb: ($r / $k), estimate_basis: {assumed_context: 8192}}]}' ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/llmfit"
}

@test "plan: the figures of llmfit, an estimated margin, the totals rounded up, for both quantisations" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.context, .vcpu, .chat_interface, .unsized]' <<<"$output")" = '[8192,null,false,[]]' ]
    [ "$(jq -c '.models[0] | [.typed, .name]' <<<"$output")" = '["hf/m","hf/m"]' ]
    # best: RAM without GPU = model + 1 engine + 1 system, GPU memory = model / 0.9 + 1, disk + 20
    [ "$(jq -c '.quantisations.best.quants' <<<"$output")" = '["Q8_0"]' ]
    [ "$(jq -c '.quantisations.best.ram_no_gpu' <<<"$output")" = '{"model_gb":9.93,"margin_gb":2.07,"total_gb":12,"total_mb":12288,"margin_parts":{"engine":1,"system":1,"chat_interface":0}}' ]
    [ "$(jq -c '.quantisations.best.gpu_memory' <<<"$output")" = '{"model_gb":10.43,"margin_gb":2.57,"total_gb":13,"margin_basis":"model / 0.9, 1 for the CUDA context"}' ]
    [ "$(jq -c '.quantisations.best.gpu_ram' <<<"$output")" = '{"model_gb":0,"margin_gb":2,"total_gb":2,"total_mb":2048,"margin_parts":{"system_and_engine":2,"chat_interface":0}}' ]
    [ "$(jq -c '.quantisations.best.disk' <<<"$output")" = '{"model_gb":8.43,"margin_gb":20.57,"total_gb":29,"margin_parts":{"system_and_components":20}}' ]
    [ "$(jq -c '.quantisations.default.ram_no_gpu | [.total_gb, .total_mb]' <<<"$output")" = '[9,9216]' ]
    [ "$(jq -r '.quantisations.default.quants[]' <<<"$output")" = "Q4_K_M" ]
}

@test "plan: the largest model sizes the memory, the disks add up, each model is announced" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m hf/small --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.quantisations.best | [.ram_no_gpu.model_gb, .disk.model_gb, .disk.total_gb]' <<<"$output")" = '[9.93,11.24,32]' ]
    [[ "$stderr" == *"sizing hf/m with llmfit (1/2)"*"sizing hf/small with llmfit (2/2)"* ]]
}

@test "plan: a chat interface adds its share to the RAM margin, the cores are reported as given" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m --chat-interface --target-cpu-cores 4 --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.vcpu, .chat_interface]' <<<"$output")" = '[4,true]' ]
    [ "$(jq -c '.quantisations.best.ram_no_gpu | [.total_gb, .margin_parts.chat_interface]' <<<"$output")" = '[16,4]' ]
    [ "$(jq -c '.quantisations.best.gpu_ram | [.total_gb, .total_mb]' <<<"$output")" = '[6,6144]' ]
}

@test "plan: a model llmfit cannot size is listed apart and never guessed; nothing sized is no figure" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m nosuchmodel --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.models[].typed, .unsized]' <<<"$output")" = '["hf/m",["nosuchmodel"]]' ]
    [[ "$stderr" != *"does not know"* ]]
    llmfit plan nosuchmodel --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.models, .unsized, .quantisations, .context]' <<<"$output")" = '[[],["nosuchmodel"],null,null]' ]
}

@test "plan needs llmfit and a model, and takes neither --target-ram nor suggest's options" {
    llmfit plan hf/m --json
    [ "$status" -eq 4 ]
    llmfit install
    make_planning_llmfit
    llmfit plan
    [ "$status" -eq 2 ]
    llmfit plan hf/m --target-ram 8
    [ "$status" -eq 2 ]
    llmfit suggest --chat-interface
    [ "$status" -eq 2 ]
}

# --- the text for a person (without --json) --------------------------------------------------------

@test "suggest prints a numbered list for a person, the numbers and names being what the generator reads" {
    llmfit install
    llmfit suggest
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "   1) llama3.2:3b                  Good, needs 2.4 GB" ]
    [ "${lines[1]}" = "   2) small:1b                     Perfect, needs 1.2 GB" ]
    [ "${#lines[@]}" -eq 2 ]
    # nothing of the JSON, and the same models as with --json
    [[ "$output" != *'"models"'* ]]
    llmfit suggest -n 1
    [ "${#lines[@]}" -eq 1 ]
}

@test "suggest says so in a sentence when llmfit finds no model" {
    llmfit install
    cat >"$BATS_TEST_TMPDIR/bin/llmfit" <<'FAKE'
#!/usr/bin/env bash
case "$1" in --version) echo "llmfit 1.1.16" ;; recommend) echo '{"models":[]}' ;; esac
FAKE
    llmfit suggest
    [ "$status" -eq 0 ]
    [ "$output" = "llmfit finds no model to suggest for these specs" ]
    llmfit suggest --json
    [ "$(jq -c '.models' <<<"$output")" = "[]" ]
}

@test "plan prints the recommendation for a person: the margin shown as estimated, with what it is made of" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m hf/small
    [ "$status" -eq 0 ]
    [[ "$output" == *"Recommended VM, from llmfit (context of 8192 tokens) plus an ESTIMATED margin"* ]]
    [[ "$output" == *"hf/m: best Q8_0 9.93 GB, default Q4_K_M 6.16 GB, disk 8.43 or 4.66 GB"* ]]
    [[ "$output" == *"vCPU: not sized by llmfit"* ]]
    [[ "$output" == *"with the best quantisation (Q8_0):"* ]]
    [[ "$output" == *"VM without GPU: RAM 12 GB (12288 MB) = 9.93 model + 2.07 estimated margin (1 engine, 1 system)"* ]]
    [[ "$output" == *"VM with a GPU:  GPU memory 13 GB = 10.43 model + 2.57 estimated margin (model / 0.9, 1 for the CUDA context); RAM 2 GB (2048 MB), estimated"* ]]
    [[ "$output" == *"disk: 32 GB = 11.24 models + 20 estimated for the system and components"* ]]
    [[ "$output" == *"with the default quantisation (Q4_K_M):"* ]]
    # the progress goes to stderr, not into the text
    [[ "$output" != *"sizing"* ]]
    [[ "$stderr" == *"sizing hf/m with llmfit (1/2)"* ]]
}

@test "plan, for a person: the chat interface and the cores, a model not estimated, a mixture of experts" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m nosuch --chat-interface --target-cpu-cores 4
    [ "$status" -eq 0 ]
    [[ "$output" == *"vCPU: 4"* ]]
    [[ "$output" == *"(1 engine, 1 system, 4 chat interface)"* ]]
    [[ "$output" == *"nosuch: not estimated (llmfit does not know it), the recommendation does not cover it"* ]]
    llmfit plan nosuch
    [ "$status" -eq 0 ]
    [[ "$output" == *"Recommended VM:"*"nosuch: not estimated"* ]]
    [[ "$output" != *"VM without GPU"* ]]
}
