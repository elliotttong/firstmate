#!/usr/bin/env bash
# fm-notion.sh - command surface for the optional Notion board.
#
# Usage:
#   fm-notion.sh whoami
#   fm-notion.sh query <actions|projects> [--limit N]   (filter JSON on stdin)
#   fm-notion.sh ensure-schema [--dry-run]
#   fm-notion.sh down
#   fm-notion.sh --help
#
# `down` prints what the captain has put on the board for firstmate, one line
# each: `ready <page-id> <title>` for a row in firstmate's lane (Lane=Claude)
# with Ready ticked and no Task ID yet, and `answer <task-id> <page-id>
# <answer>` for a row flagged Needs you that now carries an Answer. Any other
# Lane, including empty, is not firstmate's. A board field can raise work or
# carry an answer; it never grants merge, destructive, irreversible, or
# security-sensitive authority.
#
# `ensure-schema` adds the board's missing Action Items properties and never
# retypes, renames, or deletes one that exists; bin/fm-notion.py owns the
# field list. Repo options are the projects cloned under $FM_HOME/projects
# plus firstmate.
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
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
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
  down)
    db=$(resolve_db actions)
    [ -n "$db" ] || die_usage "no database id configured for 'actions'"
    FM_NOTION_DB=$db exec python3 "$ENGINE" down "$@"
    ;;
  ensure-schema)
    db=$(resolve_db actions)
    [ -n "$db" ] || die_usage "no database id configured for 'actions'"
    # Repo options are the registered projects plus firstmate itself.
    repos=firstmate
    if [ -d "$FM_HOME/projects" ]; then
      for p in "$FM_HOME"/projects/*/; do
        [ -d "$p" ] || continue
        p=${p%/}
        repos="$repos,${p##*/}"
      done
    fi
    FM_NOTION_DB=$db FM_NOTION_REPOS=$repos exec python3 "$ENGINE" ensure-schema "$@"
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
