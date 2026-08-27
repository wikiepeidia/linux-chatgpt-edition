#!/bin/sh

tty_path=$(tty 2>/dev/null || true)
if [ "$tty_path" = /dev/tty1 ] && [ -z "${DISPLAY:-}" ] && [ "${_300K_SESSION_ATTEMPTED:-0}" != 1 ]; then
    export _300K_SESSION_ATTEMPTED=1
    exec /usr/local/bin/300k-runtime session
fi
