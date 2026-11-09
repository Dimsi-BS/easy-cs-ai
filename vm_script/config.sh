#!/usr/bin/env bash
# The session that creates or edits a configuration, see docs/spec-vm-generator.md.
# Reached through `easy-cs-ai config edit`. Writes the configuration file, never a script.
set -euo pipefail

# shellcheck source=lib/generator.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/generator.sh"

EDIT_FILE=""

usage() {
    cat <<'EOF'
Usage: config edit [<file>] [options]

Creates a configuration (no file) or edits one (<file>) in an interactive
session, and writes the configuration file. It writes no script: run
`easy-cs-ai script <file>` for that. Before writing, the session asks the
name of the file to write (default: the file opened, or ./easy-cs-ai.json);
an existing file other than the one opened is confirmed first.

  --dry-run                run the whole session, print the result on stderr, write nothing
  --help --version --verbose
EOF
}

parse_args() {
    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
        --help) usage; exit 0 ;;
        --version) printf '%s\n' "$GENERATOR_VERSION"; exit 0 ;;
        --verbose) export EASY_CS_AI_VERBOSE=1 ;;
        --dry-run) DRY=1 ;;
        --json) die "$EXIT_USAGE" "--json is not available for config edit: a session is interactive" ;;
        -*) die "$EXIT_USAGE" "unknown argument: $arg" ;;
        *)
            [[ -z "$EDIT_FILE" ]] || die "$EXIT_USAGE" "one configuration file at a time"
            EDIT_FILE="$arg"
            ;;
        esac
    done
}

main() {
    parse_args "$@"
    _require_jq
    if [[ -n "$EDIT_FILE" ]]; then
        run_editor "$EDIT_FILE"
        return 0
    fi
    run_session
    EDIT_ORIGINAL=""
    EDIT_CONFIG="$(jq -c . <<<"$SESSION_CONFIG")"
    run_editor_loop ""
}

main "$@"
