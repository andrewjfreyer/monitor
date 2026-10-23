#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
source support/btle
PREF_BLUETOOTH_SILENCE_TIMEOUT=300
PREF_BLUETOOTH_RECOVERY_INTERVAL=900
btle_last_activity=0
btle_last_recovery=-900
quiet='LE Scan ...'
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
if btle_scan_watchdog "$quiet" 299; then fail 'startup grace'; fi
btle_scan_watchdog "$quiet" 300 || fail 'silent scanner not detected'
[ "$btle_last_recovery" = 300 ] || fail 'recovery timestamp'
if btle_scan_watchdog "$quiet" 1199; then fail 'reset storm'; fi
btle_scan_watchdog "$quiet" 1200 || fail 'retry after cooldown'
if btle_scan_watchdog 'AA:bb:CC:dd:EE:ff nearby device' 1400; then fail 'healthy traffic'; fi
[ "$btle_last_activity" = 1400 ] || fail 'activity timestamp'
btle_last_recovery=0
if btle_scan_watchdog "$quiet" 1699; then fail 'fresh activity ignored'; fi
btle_scan_watchdog "$quiet" 1700 || fail 'silence after recovery'
PREF_BLUETOOTH_SILENCE_TIMEOUT=0
if btle_scan_watchdog "$quiet" 99999; then fail 'disabled watchdog'; fi
PREF_BLUETOOTH_SILENCE_TIMEOUT=300
btle_last_activity=0
btle_last_recovery=-900
btle_scan_watchdog '' 300 || fail 'empty output from hung scan'
printf 'PASS: silence, activity, grace period, cooldown, retry and disable\n'
