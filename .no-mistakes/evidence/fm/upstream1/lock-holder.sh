#!/usr/bin/env bash
. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
fm_procevent_source_lock_acquire "$2" || exit 1
trap 'fm_procevent_source_lock_release "$2"' EXIT
: > "$3.$2.ready"
while [ ! -e "$3" ]; do sleep 0.02; done
