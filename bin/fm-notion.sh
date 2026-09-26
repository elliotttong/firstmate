#!/usr/bin/env bash
# fm-notion.sh - command surface for the optional Notion board.
#
# Usage:
#   fm-notion.sh whoami
#   fm-notion.sh query <actions|projects> [--limit N]   (filter JSON on stdin)
#   fm-notion.sh --help
#
# This wrapper owns configuration; bin/fm-notion.py owns the wire format.
# Credentials and database ids come from the environment, filling missing keys
# from the gitignored $FM_HOME/.env (env wins, the same rule as bin/fm-mail.sh):
#   NOTION_TOKEN            integration token, never printed or passed on argv
#   NOTION_ACTION_ITEMS_DB  REST database id of the Action Items work database
#   NOTION_PROJECTS_DB      REST database id of the Projects database
# Those ids are REST database ids; a data source id (collection://...) returns
# a 404 that reads like a sharing problem.
#
# `query` refuses a whole-database read: stdin must carry a Notion "filter"
# (and optionally "sorts"). Each matching page prints as one JSON line with
# its properties reduced to plain values.
#
# Exit status: 0 success, 1 Notion or network failure, 2 usage or missing
# configuration.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
ENV_FILE="$FM_HOME/.env"
ENGINE="$SCRIPT_DIR/fm-notion.py"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

usage() {
  sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-notion: %s\n' "$1" >&2
  exit 2
}

env_fill() {
  local key=$1
  if [ -z "${!key:-}" ]; then
    export "$key=$(fmx_env_get "$key" "$ENV_FILE")"
  fi
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help|help) usage; exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || die_usage "python3 is required"
env_fill NOTION_TOKEN
env_fill NOTION_ACTION_ITEMS_DB
env_fill NOTION_PROJECTS_DB
[ -n "${NOTION_TOKEN:-}" ] || die_usage "NOTION_TOKEN is not set in the environment or $ENV_FILE"

resolve_db() {
  case "$1" in
    actions) printf '%s' "${NOTION_ACTION_ITEMS_DB:-}" ;;
    projects) printf '%s' "${NOTION_PROJECTS_DB:-}" ;;
    *) return 1 ;;
  esac
}

cmd=$1
shift
case "$cmd" in
  whoami)
    exec python3 "$ENGINE" whoami "$@"
    ;;
  query)
    [ "$#" -ge 1 ] || die_usage "query needs a database: actions or projects"
    db=$(resolve_db "$1") || die_usage "unknown database '$1': use actions or projects"
    [ -n "$db" ] || die_usage "no database id configured for '$1'"
    shift
    FM_NOTION_DB=$db exec python3 "$ENGINE" query "$@"
    ;;
  *)
    die_usage "unknown command '$cmd'"
    ;;
esac
