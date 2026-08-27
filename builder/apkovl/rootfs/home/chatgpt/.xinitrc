#!/bin/sh
set -u

openbox --config-file "$HOME/.config/openbox/rc.xml" >"$HOME/.openbox.log" 2>&1 &
openbox_pid=$!
cleanup() {
    kill "$openbox_pid" >/dev/null 2>&1 || true
}
trap 'cleanup' EXIT INT TERM HUP

sleep 1
kill -0 "$openbox_pid" >/dev/null 2>&1 || {
    printf '%s\n' '300K: Openbox failed to start' >&2
    exit 1
}
/usr/local/bin/300k-runtime serial-stage X_READY

attempt=1
while [ "$attempt" -le 2 ]; do
    wish /usr/local/lib/300k/ui.tcl >>"$HOME/.300k-ui.log" 2>&1 || true
    if ! kill -0 "$openbox_pid" >/dev/null 2>&1; then
        break
    fi
    printf '300K: UI attempt %s ended\n' "$attempt" >>"$HOME/.300k-ui.log"
    attempt=$((attempt + 1))
done

if [ "$attempt" -gt 2 ]; then
    xterm -T '300K UI recovery' -e /bin/ash -lc 'printf "The parody UI crashed twice. This shell is real.\n"; exec /bin/ash -l'
fi

wait "$openbox_pid"
