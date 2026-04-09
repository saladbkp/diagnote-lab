#!/usr/bin/env bash
set -euo pipefail

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB_BIN="$ANDROID_SDK_ROOT/platform-tools/adb"
EMU_BIN="$HOME/.cache/android-old-tools/tools/emulator"
AVD_NAME="kernel_challenges"
PORTS="5554,5555"
KERNEL_IMG="/tmp/rev-pwn-agent-self-study/ctf_archive/hack10-2026/p1/android_kernel_pwn/images/goldfish_3.10_zImage"
LOG_FILE="/tmp/kernel_challenges_old_emu.log"
PID_FILE="/tmp/kernel_challenges_emulator.pid"

usage() {
  cat <<'EOF'
Usage: akep_server.sh <start|stop|restart|status|logs|devices>
EOF
}

require_bins() {
  if [[ ! -x "$ADB_BIN" ]]; then
    echo "[-] adb not found: $ADB_BIN"
    exit 1
  fi
  if [[ ! -x "$EMU_BIN" ]]; then
    echo "[-] old emulator not found: $EMU_BIN"
    exit 1
  fi
  if [[ ! -f "$KERNEL_IMG" ]]; then
    echo "[-] kernel image not found: $KERNEL_IMG"
    exit 1
  fi
}

stop_server() {
  set +e
  "$ADB_BIN" kill-server >/dev/null 2>&1
  if [[ -f "$PID_FILE" ]]; then
    kill -9 "$(cat "$PID_FILE")" >/dev/null 2>&1
    rm -f "$PID_FILE"
  fi
  pkill -9 -f "emulator64-arm @${AVD_NAME}" >/dev/null 2>&1
  pkill -9 -f "tools/emulator @${AVD_NAME}" >/dev/null 2>&1
  pkill -9 -f "qemu-system.*${AVD_NAME}" >/dev/null 2>&1
  set -e
  echo "[+] stopped"
}

start_server() {
  require_bins
  stop_server

  nohup "$EMU_BIN" "@${AVD_NAME}" \
    -ports "$PORTS" \
    -show-kernel \
    -kernel "$KERNEL_IMG" \
    -no-boot-anim -no-snapshot -no-audio -no-window \
    -engine classic -verbose \
    >"$LOG_FILE" 2>&1 &

  echo $! >"$PID_FILE"
  sleep 2
  "$ADB_BIN" start-server >/dev/null 2>&1
  echo "[+] started pid $(cat "$PID_FILE")"
  echo "[+] log: $LOG_FILE"
}

status_server() {
  local running="no"
  if [[ -f "$PID_FILE" ]] && ps -p "$(cat "$PID_FILE")" >/dev/null 2>&1; then
    running="yes"
  fi
  echo "[+] running: $running"
  if [[ "$running" == "yes" ]]; then
    ps -p "$(cat "$PID_FILE")" -o pid,etime,%cpu,%mem,cmd --no-headers
  fi
  "$ADB_BIN" devices -l || true
}

logs_server() {
  tail -n 120 "$LOG_FILE"
}

devices_server() {
  "$ADB_BIN" devices -l
}

cmd="${1:-}"
case "$cmd" in
  start) start_server ;;
  stop) stop_server ;;
  restart) stop_server; start_server ;;
  status) status_server ;;
  logs) logs_server ;;
  devices) devices_server ;;
  *) usage; exit 1 ;;
esac

