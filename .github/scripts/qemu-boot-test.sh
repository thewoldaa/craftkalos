#!/usr/bin/env bash
# QEMU Boot Test for CraftkalOS ISO
set -euo pipefail

MODE="bios"
TIMEOUT=300
ISO=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1"; exit 1 ;;
  esac
done

if [[ ! -f "$ISO" ]]; then echo "ERROR: ISO not found: $ISO"; exit 1; fi
mkdir -p "$OUTPUT_DIR"

SERIAL_LOG="$OUTPUT_DIR/serial.log"
QEMU_LOG="$OUTPUT_DIR/qemu.log"
QMP_PORT=$(( (RANDOM % 10000) + 20000 ))
SCREENSHOT_INTERVAL=15

KVM_ACCEL=""
if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
  KVM_ACCEL="kvm"
  echo "KVM available — using hardware acceleration"
else
  KVM_ACCEL="tcg"
  echo "KVM not available — falling back to TCG software emulation"
fi

QEMU_ARGS=(
  -machine type=q35,accel="$KVM_ACCEL"
  -m 4096
  -smp 1
  -cdrom "$ISO"
  -boot order=d
  -vga virtio
  -display none
  -vnc :0
  -serial file:"$SERIAL_LOG"
  -qmp tcp:127.0.0.1:$QMP_PORT,server,nowait
  -no-reboot
  -D "$QEMU_LOG"
)

if [[ "$MODE" = "uefi" ]]; then
  OVMF_FOUND=""
  for path in \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF.fd \
    /usr/share/ovmf/x64/OVMF.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd; do
    if [[ -f "$path" ]]; then
      QEMU_ARGS+=(-bios "$path")
      OVMF_FOUND="$path"
      echo "Using OVMF firmware: $path"
      break
    fi
  done
  if [[ -z "$OVMF_FOUND" ]]; then
    echo "WARN: OVMF firmware not found — UEFI test may fail"
  fi
fi

qmp_send() {
  local cmd="$1"
  python3 -c "
import json, socket, sys
try:
  s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  s.settimeout(3)
  s.connect(('127.0.0.1', $QMP_PORT))
  data = s.recv(4096)
  s.send(json.dumps({'execute':'qmp_capabilities'}).encode() + b'\n')
  s.recv(4096)
  s.send(json.dumps($cmd).encode() + b'\n')
  s.recv(4096)
except Exception as e:
  sys.stderr.write(str(e) + '\n')
finally:
  s.close()
" 2>/dev/null || true
}

MIN_BOOT_TIME=20

BOOT_PATTERNS=(
  "craftkalos login:"
  "root@craftkalos"
  "root@cachyos"
  "login:"
  "labwc"
  "sddm"
  "gdm"
  "lightdm"
  "display manager"
  "wayland"
  "startx"
)

INTERMEDIATE_PATTERNS=(
  "Linux version"
  "kernel.*command line"
  "Run /init as init process"
  "Reached target"
  "Started.*Journal Service"
  "startup finished in"
  "serial.*configured"
  "agetty"
)

echo "Starting QEMU ($MODE mode)..."
qemu-system-x86_64 "${QEMU_ARGS[@]}" &
QEMU_PID=$!

for i in $(seq 1 30); do
  if python3 -c "
import socket
try:
  s = socket.socket()
  s.settimeout(1)
  s.connect(('127.0.0.1', $QMP_PORT))
  s.close()
  print('ready')
except:
  pass
" 2>/dev/null | grep -q ready; then
    break
  fi
  sleep 0.5
done

START_TIME=$(date +%s)
SCREENSHOT_NUM=0
LAST_SCREENSHOT_TIME=0
BOOT_DETECTED=""
RESULT="timeout"

while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))

  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    RESULT="timeout"
    echo "TIMEOUT reached (${TIMEOUT}s)"
    break
  fi

  if [[ $((ELAPSED - LAST_SCREENSHOT_TIME)) -ge $SCREENSHOT_INTERVAL ]]; then
    SCREENSHOT_NUM=$((SCREENSHOT_NUM + 1))
    PPM_FILE="$OUTPUT_DIR/boot-$(printf '%02d' $SCREENSHOT_NUM).ppm"
    PNG_FILE="$OUTPUT_DIR/boot-$(printf '%02d' $SCREENSHOT_NUM).png"
    qmp_send "{'execute':'screendump','arguments':{'filename':'$PPM_FILE'}}"
    if [[ -f "$PPM_FILE" ]] && [[ -s "$PPM_FILE" ]]; then
      convert "$PPM_FILE" "$PNG_FILE" 2>/dev/null && rm -f "$PPM_FILE" || true
      echo "Screenshot $SCREENSHOT_NUM captured ($ELAPSED s)"
    fi
    LAST_SCREENSHOT_TIME=$ELAPSED
  fi

  if [[ $ELAPSED -ge $MIN_BOOT_TIME ]] && [[ -f "$SERIAL_LOG" ]] && [[ -s "$SERIAL_LOG" ]]; then
    for pattern in "${BOOT_PATTERNS[@]}"; do
      if grep -qiE "$pattern" "$SERIAL_LOG" 2>/dev/null; then
        BOOT_DETECTED="$pattern"
        RESULT="pass"
        echo "Login/DE detected! Pattern: '$pattern' ($ELAPSED s)"
        break 2
      fi
    done
    if [[ "$RESULT" != "pass" ]]; then
      for pattern in "${INTERMEDIATE_PATTERNS[@]}"; do
        if grep -qiE "$pattern" "$SERIAL_LOG" 2>/dev/null; then
          BOOT_DETECTED="$pattern"
          RESULT="intermediate"
        fi
      done
    fi
  fi

  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" 2>/dev/null || true
    RESULT="qemu-exit"
    echo "QEMU process exited unexpectedly"
    break
  fi

  sleep 2
done

SCREENSHOT_NUM=$((SCREENSHOT_NUM + 1))
PPM_FILE="$OUTPUT_DIR/boot-$(printf '%02d' $SCREENSHOT_NUM).ppm"
PNG_FILE="$OUTPUT_DIR/boot-$(printf '%02d' $SCREENSHOT_NUM).png"
qmp_send "{'execute':'screendump','arguments':{'filename':'$PPM_FILE'}}"
if [[ -f "$PPM_FILE" ]] && [[ -s "$PPM_FILE" ]]; then
  convert "$PPM_FILE" "$PNG_FILE" 2>/dev/null && rm -f "$PPM_FILE" || true
  echo "Final screenshot captured"
fi

kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

echo "---"
echo "RESULT=$RESULT"
echo "BOOT_DETECTED=$BOOT_DETECTED"
echo "ELAPSED=$ELAPSED"
echo "SCREENSHOTS=$SCREENSHOT_NUM"
echo "MODE=$MODE"
echo "KVM_ACCEL=$KVM_ACCEL"

if [[ "$RESULT" = "pass" ]]; then
  exit 0
elif [[ "$RESULT" = "intermediate" ]]; then
  exit 0
else
  exit 1
fi
