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

# --- sizing for another machine (docs/spec-model-fit.md) ------------------------------------------

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
    [ "${lines[2]}" = "target-cpu-cores component chat-interface" ]
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

# A fake tree of components for `plan`: EASY_CS_AI_LIB points at its lib/ directory, whose parent
# holds the <type>/ directories, where only `describe` answers (docs/spec-script-contract.md).
#   engine/one    1 GB of RAM, 2 of disk, one process, GPU rule 0.9 and 1
#   engine/per    1 GB of RAM per model, 2 of disk, one instance per model, GPU rule 0.9 and 1
#   engine/nogpu  1 GB of RAM, 2 of disk, resources but no GPU rule
#   chat-interface/chat  2 GB of RAM, 6 of disk
#   proxy/prox    0.5 GB of RAM, 0.5 of disk
#   proxy/bare    no resources; proxy/broken answers something that is not JSON; no script for engine/ghost
make_tree() {
    local t="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$t"/{engine,chat-interface,proxy,provisioning}
    ln -s "$(cd "$BATS_TEST_DIRNAME/../../install_scripts/lib" && pwd)" "$t/lib"
    fake_component engine one '{"ram_gb":1,"disk_gb":2,"per_model":false,"gpu":{"utilization":0.9,"fixed_gb":1},"source":"guess","basis":"b"}'
    fake_component engine per '{"ram_gb":1,"disk_gb":2,"per_model":true,"gpu":{"utilization":0.9,"fixed_gb":1},"source":"vendor","basis":"b"}'
    fake_component engine nogpu '{"ram_gb":1,"disk_gb":2,"source":"guess","basis":"b"}'
    fake_component chat-interface chat '{"ram_gb":2,"disk_gb":6,"source":"measured","basis":"b"}'
    fake_component proxy prox '{"ram_gb":0.5,"disk_gb":0.5,"source":"guess","basis":"b"}'
    fake_component proxy bare ''
    printf '#!/usr/bin/env bash\necho "not json"\n' >"$t/proxy/broken.sh"
    export EASY_CS_AI_LIB="$t/lib"
}

# fake_component <type> <name> <resources-json, or empty for none>
fake_component() {
    local f="$BATS_TEST_TMPDIR/tree/$1/$2.sh" r="${3:-null}"
    [[ -n "$3" ]] || r=null
    printf '#!/usr/bin/env bash\n[[ "$1" == describe ]] && echo '"'"'{"name":"%s","type":"%s","resources":%s}'"'"'\n' "$2" "$1" "$r" >"$f"
}

@test "plan: the margin is the system plus what the components declare, for both quantisations" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m --component engine/one --component chat-interface/chat --component proxy/prox --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.context, .vcpu, .chat_interface, .unsized, .undeclared]' <<<"$output")" = '[8192,null,true,[],[]]' ]
    [ "$(jq -c '.models[0] | [.typed, .name, .engine]' <<<"$output")" = '["hf/m","hf/m",null]' ]
    [ "$(jq -c '.quantisations.best.quants' <<<"$output")" = '["Q8_0"]' ]
    # RAM without GPU: 9.93 + 1 system + 1 engine + 2 chat + 0.5 proxy = 14.43, rounded up once
    [ "$(jq -c '.quantisations.best.ram_no_gpu' <<<"$output")" = '{"model_gb":9.93,"margin_gb":5.07,"total_gb":15,"total_mb":15360,"margin_parts":{"system":1,"engine":1,"chat_interface":2,"proxy":0.5}}' ]
    # GPU memory: 10.43 / 0.9 + 1 = 12.59
    [ "$(jq -c '.quantisations.best.gpu_memory' <<<"$output")" = '{"model_gb":10.43,"margin_gb":2.57,"total_gb":13,"margin_basis":"model / 0.9, 1 for the CUDA context"}' ]
    # RAM with a GPU: 1 + 1 + 2 + 0.5 = 4.5
    [ "$(jq -c '.quantisations.best.gpu_ram' <<<"$output")" = '{"model_gb":0,"margin_gb":5,"total_gb":5,"total_mb":5120,"margin_parts":{"system":1,"engine":1,"chat_interface":2,"proxy":0.5}}' ]
    # disk: 8.43 + 10 system + 2 + 6 + 0.5 = 26.93
    [ "$(jq -c '.quantisations.best.disk' <<<"$output")" = '{"model_gb":8.43,"margin_gb":18.57,"total_gb":27,"margin_parts":{"system":10,"engine":2,"chat_interface":6,"proxy":0.5}}' ]
    [ "$(jq -c '.quantisations.default.ram_no_gpu | [.total_gb, .total_mb]' <<<"$output")" = '[11,11264]' ]
    [ "$(jq -r '.quantisations.default.quants[]' <<<"$output")" = "Q4_K_M" ]
    # every part has its source in the document
    [ "$(jq -c '.components' <<<"$output")" = '[{"type":"engine","name":"one","declared":true,"ram_gb":1,"disk_gb":2,"source":"guess"},{"type":"chat-interface","name":"chat","declared":true,"ram_gb":2,"disk_gb":6,"source":"measured"},{"type":"proxy","name":"prox","declared":true,"ram_gb":0.5,"disk_gb":0.5,"source":"guess"}]' ]
}

@test "plan: the three parts of the margin have the same keys, the keys of the other types only when named" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m --component engine/one --json
    [ "$(jq -c '.quantisations.best | [.ram_no_gpu, .gpu_ram, .disk] | map(.margin_parts | keys)' <<<"$output")" = '[["chat_interface","engine","system"],["chat_interface","engine","system"],["chat_interface","engine","system"]]' ]
    [ "$(jq -c '.quantisations.best.disk.margin_parts' <<<"$output")" = '{"system":10,"engine":2,"chat_interface":0}' ]
    llmfit plan hf/m --component engine/one --component proxy/prox --component provisioning/fit --json
    [ "$(jq -c '.quantisations.best | [.ram_no_gpu, .gpu_ram, .disk] | map(.margin_parts | keys)' <<<"$output")" = '[["chat_interface","engine","provisioning","proxy","system"],["chat_interface","engine","provisioning","proxy","system"],["chat_interface","engine","provisioning","proxy","system"]]' ]
}

@test "plan: one instance per model adds up, one process counts the largest, on the same models" {
    llmfit install
    make_planning_llmfit
    make_tree
    # hf/m is 9.93 / 10.43 GB, hf/small a third of that: 3.31 / 3.48
    llmfit plan hf/m hf/small --component engine/one --json
    [ "$status" -eq 0 ]
    # the largest counts: RAM 9.93 + 1 + 1, GPU 10.43 / 0.9 + 1 = 12.59, disks add up
    [ "$(jq -c '.quantisations.best | [.ram_no_gpu.total_gb, .gpu_memory.total_gb, .gpu_ram.total_gb, .disk.model_gb]' <<<"$output")" = '[12,13,2,11.24]' ]
    llmfit plan hf/m hf/small --component engine/per --json
    [ "$status" -eq 0 ]
    # the sum: RAM 13.24 + 1 system + 1 per model, GPU (10.43 / 0.9 + 1) + (3.48 / 0.9 + 1) = 17.45, RAM with a GPU 1 + 2
    [ "$(jq -c '.quantisations.best | [.ram_no_gpu.total_gb, .gpu_memory.total_gb, .gpu_ram.total_gb, .disk.model_gb]' <<<"$output")" = '[17,18,3,11.24]' ]
    [[ "$(jq -r '.quantisations.best.gpu_memory.margin_basis' <<<"$output")" == *"each model, summed"* ]]
}

@test "plan: a model carries its engine, which picks the engine it is counted on" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m@one hf/small@per --component engine/one --component engine/per --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.models[] | [.typed, .name, .engine]]' <<<"$output")" = '[["hf/m","hf/m","one"],["hf/small","hf/small","per"]]' ]
    # one holds hf/m (RAM 9.93, GPU 12.59), per holds hf/small: the largest of the engines, their RAM added
    [ "$(jq -c '.quantisations.best | [.ram_no_gpu.model_gb, .ram_no_gpu.margin_parts.engine, .ram_no_gpu.total_gb, .gpu_memory.total_gb]' <<<"$output")" = '[9.93,2,13,13]' ]
    # a model with no @ goes to the only engine named
    llmfit plan hf/m --component engine/one --json
    [ "$(jq -c '.models[0].engine' <<<"$output")" = "null" ]
}

@test "plan: a model that names no engine of the call, or one of several engines, is a usage error" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m --component engine/one --component engine/per --json
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"needs @<engine>"* ]]
    llmfit plan hf/m@ghost --component engine/one --json
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"'ghost'"*"declared: one"* ]]
    llmfit plan hf/m@one --json
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"declared: none"* ]]
    llmfit plan hf/m@ --component engine/one --json
    [ "$status" -eq 2 ]
    llmfit plan @one --component engine/one --json
    [ "$status" -eq 2 ]
    ! grep -q "info" "$CALLS"
}

@test "plan: a component without resources, without a script or with a broken describe is undeclared and adds nothing" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m --component engine/one --component proxy/bare --component proxy/ghost2 --component proxy/broken --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.undeclared' <<<"$output")" = '["proxy/bare","proxy/ghost2","proxy/broken"]' ]
    [ "$(jq -c '.components | map([.name, .declared])' <<<"$output")" = '[["one",true],["bare",false],["ghost2",false],["broken",false]]' ]
    [[ "$stderr" == *"describe of proxy/broken failed or is not JSON"* ]]
    # what is declared still counts, the undeclared ones add 0 (and are not 0 declared)
    [ "$(jq -c '.quantisations.best.ram_no_gpu.margin_parts' <<<"$output")" = '{"system":1,"engine":1,"chat_interface":0,"proxy":0}' ]
}

@test "plan: an engine with resources and no GPU rule is sized with the generic one and says so, and stays declared" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m --component engine/nogpu --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.undeclared' <<<"$output")" = '[]' ]
    [[ "$(jq -r '.quantisations.best.gpu_memory.margin_basis' <<<"$output")" == *"generic GPU rule, nogpu declares none"* ]]
    [ "$(jq -r '.quantisations.best.gpu_memory.total_gb' <<<"$output")" = 13 ]
}

@test "plan: no component gives the generic engine of before, undeclared, with its GB in the engine part" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.components, .undeclared, .chat_interface]' <<<"$output")" = '[[],["engine (generic)"],false]' ]
    [ "$(jq -c '.quantisations.best | [.ram_no_gpu, .gpu_memory, .gpu_ram, .disk]' <<<"$output")" = '[{"model_gb":9.93,"margin_gb":2.07,"total_gb":12,"total_mb":12288,"margin_parts":{"system":1,"engine":1,"chat_interface":0}},{"model_gb":10.43,"margin_gb":2.57,"total_gb":13,"margin_basis":"model / 0.9, 1 for the CUDA context (generic engine, none declared)"},{"model_gb":0,"margin_gb":2,"total_gb":2,"total_mb":2048,"margin_parts":{"system":1,"engine":1,"chat_interface":0}},{"model_gb":8.43,"margin_gb":10.57,"total_gb":19,"margin_parts":{"system":10,"engine":0,"chat_interface":0}}]' ]
}

@test "plan: --chat-interface is the shorthand of --component chat-interface/librechat" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m --chat-interface --target-cpu-cores 4 --json
    [ "$status" -eq 0 ]
    short="$output"
    [ "$(jq -c '[.vcpu, .chat_interface]' <<<"$short")" = '[4,true]' ]
    llmfit plan hf/m --component chat-interface/librechat --target-cpu-cores 4 --json
    [ "$output" = "$short" ]
    # the declaration of the shipped LibreChat, not the 4 GB of before
    [ "$(jq -c '.quantisations.best.ram_no_gpu.margin_parts.chat_interface' <<<"$short")" = 2 ]
}

@test "plan: the largest model sizes the memory, the disks add up, each model is announced" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m hf/small --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.quantisations.best | [.ram_no_gpu.model_gb, .disk.model_gb, .disk.total_gb]' <<<"$output")" = '[9.93,11.24,22]' ]
    [[ "$stderr" == *"sizing hf/m with llmfit (1/2)"*"sizing hf/small with llmfit (2/2)"* ]]
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
    [ "$(jq -c '[.models, .unsized, .quantisations, .context, .stack]' <<<"$output")" = '[[],["nosuchmodel"],null,null,null]' ]
}

@test "plan needs llmfit and a model or a component, and takes neither --target-ram nor suggest's options" {
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
    llmfit suggest --component engine/one
    [ "$status" -eq 2 ]
    llmfit plan hf/m --component engine
    [ "$status" -eq 2 ]
}

# --- a stack with no model ---------------------------------------------------------------------------

@test "plan: components and no model answer for a VM with no model, without calling llmfit" {
    make_tree
    # llmfit is not installed: a model would be exit 4, a stack with none is not
    llmfit plan --component engine/one --component proxy/prox --target-cpu-cores 4 --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.models, .quantisations, .vcpu, .unsized, .undeclared]' <<<"$output")" = '[[],null,4,[],[]]' ]
    # 1 system + 1 engine + 0.5 proxy = 2.5, disk 10 + 2 + 0.5 = 12.5
    [ "$(jq -c '.stack' <<<"$output")" = '{"ram_no_gpu":{"model_gb":0,"margin_gb":3,"total_gb":3,"total_mb":3072,"margin_parts":{"system":1,"engine":1,"chat_interface":0,"proxy":0.5}},"disk":{"model_gb":0,"margin_gb":13,"total_gb":13,"margin_parts":{"system":10,"engine":2,"chat_interface":0,"proxy":0.5}},"models_included":false}' ]
    ! grep -q llmfit "${CALLS:-/dev/null}" 2>/dev/null
}

@test "plan: a VM with no model and no engine says nothing of the models, and a per_model engine adds no RAM" {
    make_tree
    llmfit plan --component chat-interface/chat --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.stack.models_included, .stack.ram_no_gpu.total_gb, .stack.disk.total_gb]' <<<"$output")" = '[null,3,16]' ]
    llmfit plan --component chat-interface/chat
    [[ "$output" == *"VM with no model: RAM 3 GB, disk 16 GB"* ]]
    [[ "$output" != *"models not included"* && "$output" != *"GPU memory"* ]]
    llmfit plan --component engine/per --json
    [ "$(jq -c '[.stack.models_included, .stack.ram_no_gpu.margin_parts.engine, .stack.disk.margin_parts.engine, .stack.ram_no_gpu.total_gb]' <<<"$output")" = '[false,0,2,1]' ]
}

@test "plan: with no model and an engine the text warns that the models come on top, and the GPU is not sized" {
    make_tree
    llmfit plan --component engine/one --component chat-interface/chat
    [ "$status" -eq 0 ]
    [[ "$output" == *"VM with no model: RAM 4 GB, disk 18 GB"* ]]
    [[ "$output" == *"GPU memory: not sized, no model"* ]]
    [[ "$output" == *"vCPU: not sized"* && "$output" != *"by llmfit"* ]]
    [[ "$output" == *"models not included: add the memory, GPU memory and disk of each model you will install on this VM"* ]]
    [[ "$output" == *"1 system (constant), 1 engine (guess), 2 chat interface (measured)"* ]]
}

@test "plan: --chat-interface alone is a component: a stack, not exit 2" {
    llmfit plan --chat-interface --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.stack != null, .chat_interface]' <<<"$output")" = '[true,true]' ]
}

# --- the declarations of the shipped components -----------------------------------------------------

@test "every shipped describe declares well-formed resources" {
    local root="${BATS_TEST_DIRNAME}/../../install_scripts" f
    for f in "$root"/engine/*.sh "$root"/proxy/*.sh "$root"/chat-interface/*.sh "$root"/provisioning/*.sh; do
        run bash "$f" describe
        [ "$status" -eq 0 ]
        run jq -e '.resources | (.ram_gb >= 0) and (.disk_gb >= 0) and (.source | IN("measured", "vendor", "guess")) and ((.basis | type) == "string" and (.basis | length) > 0)' <<<"$(bash "$f" describe)"
        [ "$status" -eq 0 ] || { echo "$f"; false; }
    done
}

@test "the reference stack: the RAM margin is 1 system, 1 engine and 2 chat interface, the disk adds up to 18.2" {
    llmfit install
    make_planning_llmfit
    llmfit plan hf/m --component provisioning/llmfit --component proxy/nginx --component engine/ollama --component chat-interface/librechat --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.undeclared' <<<"$output")" = '[]' ]
    [ "$(jq -c '.quantisations.best.ram_no_gpu.margin_parts' <<<"$output")" = '{"system":1,"engine":1,"chat_interface":2,"provisioning":0,"proxy":0}' ]
    [ "$(jq -c '.quantisations.best.gpu_ram.margin_parts' <<<"$output")" = '{"system":1,"engine":1,"chat_interface":2,"provisioning":0,"proxy":0}' ]
    [ "$(jq -c '.quantisations.best.disk.margin_parts | [.system, .engine, .chat_interface] | add' <<<"$output")" = 18.2 ]
    [ "$(jq -c '.quantisations.best.gpu_memory.margin_basis' <<<"$output")" = '"model / 0.9, 1 for the CUDA context"' ]
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

@test "plan prints the recommendation for a person: the margin shown as estimated, with what it is made of and its sources" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m hf/small --component engine/one --component chat-interface/chat
    [ "$status" -eq 0 ]
    [[ "$output" == *"Recommended VM, from llmfit (context of 8192 tokens) plus an ESTIMATED margin"* ]]
    [[ "$output" == *"hf/m: best Q8_0 9.93 GB, default Q4_K_M 6.16 GB, disk 8.43 or 4.66 GB"* ]]
    [[ "$output" == *"vCPU: not sized by llmfit"* ]]
    [[ "$output" == *"with the best quantisation (Q8_0):"* ]]
    [[ "$output" == *"VM without GPU: RAM 14 GB (14336 MB) = 9.93 model + 4.07 estimated margin (1 system (constant), 1 engine (guess), 2 chat interface (measured))"* ]]
    [[ "$output" == *"VM with a GPU:  GPU memory 13 GB = 10.43 model + 2.57 estimated margin (model / 0.9, 1 for the CUDA context); RAM 4 GB (4096 MB), estimated (1 system (constant), 1 engine (guess), 2 chat interface (measured))"* ]]
    [[ "$output" == *"disk: 30 GB = 11.24 models + 18.76 estimated (10 system (constant), 2 engine (guess), 6 chat interface (measured))"* ]]
    [[ "$output" == *"with the default quantisation (Q4_K_M):"* ]]
    # a total is as reliable as its least reliable part
    [[ "$output" == *"the margin is as reliable as its least reliable part: guess"* ]]
    # the progress goes to stderr, not into the text
    [[ "$output" != *"sizing"* ]]
    [[ "$stderr" == *"sizing hf/m with llmfit (1/2)"* ]]
}

@test "plan, for a person: the cores, what is not covered, a model not estimated" {
    llmfit install
    make_planning_llmfit
    make_tree
    llmfit plan hf/m nosuch --component proxy/bare --target-cpu-cores 4
    [ "$status" -eq 0 ]
    [[ "$output" == *"vCPU: 4"* ]]
    [[ "$output" == *"not covered: proxy/bare, engine (generic), the margin is incomplete"* ]]
    [[ "$output" == *"1 engine (generic)"* ]]
    [[ "$output" == *"nosuch: not estimated (llmfit does not know it), the recommendation does not cover it"* ]]
    llmfit plan nosuch
    [ "$status" -eq 0 ]
    [[ "$output" == *"Recommended VM:"*"nosuch: not estimated"* ]]
    [[ "$output" != *"VM without GPU"* ]]
}

@test "an option of an action that is not repeatable is a usage error when it is given twice, --component is repeatable" {
    llmfit install
    make_planning_llmfit
    llmfit suggest --target-ram 8 --target-ram 16
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--target-ram is given more than once"* ]]
    llmfit suggest --target-ram=8 --target-ram 16
    [ "$status" -eq 2 ]
    llmfit suggest -n 2 -n 3
    [ "$status" -eq 2 ]
    llmfit plan hf/m --chat-interface --chat-interface
    [ "$status" -eq 2 ]
    make_tree
    llmfit plan hf/m --component engine/one --component proxy/prox --json
    [ "$status" -eq 0 ]
    # the describe says which one may be repeated
    llmfit describe
    [ "$(jq -c '[.action_options.plan[] | select(.repeatable == true) | .name]' <<<"$output")" = '["component"]' ]
}
