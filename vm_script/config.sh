#!/usr/bin/env bash
# The session that creates or edits a configuration, see docs/spec-vm-generator.md.
# Reached through `easy-cs-ai config new` and `easy-cs-ai config edit <file>`. Writes the
# configuration file, never a script.
set -euo pipefail

# shellcheck source=lib/generator.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/generator.sh"

MODE=""
EDIT_FILE=""

usage() {
    cat <<'EOF'
Usage: config new [options]
       config edit <file> [options]

`new` creates a configuration and `edit` opens an existing one to add or change
things, both in an interactive session that writes the configuration file. It
writes no script: run `easy-cs-ai script <file>` for that. Before writing, the
session asks the name of the file to write (default: the file opened, or
./easy-cs-ai.json for a new one); an existing file other than the one opened is
confirmed first.

  --dry-run                run the whole session, print the result on stderr, write nothing
  --help --version --verbose
EOF
}

parse_args() {
    local arg
    case "${1:-}" in
    new | edit)
        MODE="$1"
        shift
        ;;
    --help) usage; exit 0 ;;
    --version) printf '%s\n' "$GENERATOR_VERSION"; exit 0 ;;
    *) die "$EXIT_USAGE" "config needs new or edit <file>: to create a configuration run easy-cs-ai config new, to change one easy-cs-ai config edit <file>" ;;
    esac
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
        --help) usage; exit 0 ;;
        --version) printf '%s\n' "$GENERATOR_VERSION"; exit 0 ;;
        --verbose) export EASY_CS_AI_VERBOSE=1 ;;
        --dry-run) DRY=1 ;;
        --json) die "$EXIT_USAGE" "--json is not available for config $MODE: a session is interactive" ;;
        -*) die "$EXIT_USAGE" "unknown argument: $arg" ;;
        *)
            [[ -z "$EDIT_FILE" ]] || die "$EXIT_USAGE" "one configuration file at a time"
            EDIT_FILE="$arg"
            ;;
        esac
    done
    if [[ "$MODE" == new && -n "$EDIT_FILE" ]]; then
        die "$EXIT_USAGE" "config new takes no file, the session asks the name of the file to write: to change $EDIT_FILE run easy-cs-ai config edit $EDIT_FILE"
    fi
    if [[ "$MODE" == edit && -z "$EDIT_FILE" ]]; then
        die "$EXIT_USAGE" "config edit needs the file to edit: to create a configuration run easy-cs-ai config new"
    fi
}

main() {
    parse_args "$@"
    _require_jq
    if [[ "$MODE" == edit ]]; then
        run_editor "$EDIT_FILE"
        return 0
    fi
    run_session
    EDIT_ORIGINAL=""
    EDIT_CONFIG="$(jq -c . <<<"$SESSION_CONFIG")"
    run_editor_loop ""
}

main "$@"
