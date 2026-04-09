#!/usr/bin/env bash
set -euo pipefail

# Full build flow for AndroidKernelExploitationPlayground on Linux.
# This script is intentionally explicit so you can read and learn the pipeline.

ROOT="/tmp/rev-pwn-agent-self-study/ctf_archive/hack10-2026/p1/diagnote-lab"
GOLDFISH_DIR="$ROOT/goldfish"
PLAYGROUND_DIR="$ROOT/AndroidKernelExploitationPlayground"
TOOLCHAIN_DIR="$ROOT/arm-linux-androideabi-4.6.linux"
HELLO_DIR="$ROOT/study/hello_module"
KERNEL_BUILD_MK="$PLAYGROUND_DIR/kernel_build/Makefile"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB_BIN="$ANDROID_SDK_ROOT/platform-tools/adb"
OLD_EMU_BIN="$HOME/.cache/android-old-tools/tools/emulator"

KERNEL_ZIMAGE="$GOLDFISH_DIR/arch/arm/boot/zImage"
KERNEL_VMLINUX="$GOLDFISH_DIR/vmlinux"
LOG_FILE="/tmp/kernel_challenges_old_emu.log"

TOOLCHAIN_REPO="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.6"
TOOLCHAIN_BRANCH="kitkat-release"

usage() {
  cat <<'EOF'
Usage:
  ./build.sh all
  ./build.sh toolchain
  ./build.sh patch-kernel
  ./build.sh kernel
  ./build.sh hello
  ./build.sh start-emu
  ./build.sh start-emu-fg
  ./build.sh load-hello
  ./build.sh stop-emu

What each step does:
  toolchain   -> clone Linux ARM cross-compiler (arm-linux-androideabi-4.6)
  patch-kernel-> wire playground drivers + enable DEBUG_INFO
  kernel      -> build goldfish kernel zImage + vmlinux
  hello       -> build hello.ko against built kernel tree
  start-emu   -> boot emulator with newly built zImage (background)
  start-emu-fg-> boot emulator in foreground with verbose logs
  load-hello  -> adb push + insmod + dmesg check for "hello world"
  stop-emu    -> stop emulator/adb leftovers for clean restart
EOF
}

run_oldconfig_noninteractive() {
  # Older 3.10 trees don't have olddefconfig; feed empty answers.
  # Temporarily disable pipefail so SIGPIPE from `yes` doesn't abort the script.
  set +o pipefail
  yes "" | make oldconfig >/dev/null
  local rc=$?
  set -o pipefail
  return "$rc"
}

require_dirs() {
  [[ -d "$GOLDFISH_DIR" ]] || { echo "[-] missing $GOLDFISH_DIR"; exit 1; }
  [[ -d "$PLAYGROUND_DIR" ]] || { echo "[-] missing $PLAYGROUND_DIR"; exit 1; }
}

prepare_toolchain() {
  if [[ -x "$TOOLCHAIN_DIR/bin/arm-linux-androideabi-gcc" ]]; then
    echo "[+] toolchain ready: $TOOLCHAIN_DIR"
    return
  fi

  echo "[*] cloning toolchain ($TOOLCHAIN_BRANCH) ..."
  rm -rf "$TOOLCHAIN_DIR"
  git clone --depth 1 --branch "$TOOLCHAIN_BRANCH" "$TOOLCHAIN_REPO" "$TOOLCHAIN_DIR"
  file "$TOOLCHAIN_DIR/bin/arm-linux-androideabi-gcc"
}

patch_kernel_tree() {
  require_dirs

  echo "[*] linking playground into goldfish/drivers/vulnerabilities"
  ln -sfn "$PLAYGROUND_DIR" "$GOLDFISH_DIR/drivers/vulnerabilities"

  echo "[*] enabling CONFIG_DEBUG_INFO"
  if ! grep -q '^CONFIG_DEBUG_INFO=y$' "$GOLDFISH_DIR/arch/arm/configs/goldfish_armv7_defconfig"; then
    echo 'CONFIG_DEBUG_INFO=y' >> "$GOLDFISH_DIR/arch/arm/configs/goldfish_armv7_defconfig"
  fi
  if grep -q '^# CONFIG_MODULES is not set$' "$GOLDFISH_DIR/arch/arm/configs/goldfish_armv7_defconfig"; then
    sed -i 's/^# CONFIG_MODULES is not set$/CONFIG_MODULES=y/' "$GOLDFISH_DIR/arch/arm/configs/goldfish_armv7_defconfig"
  elif ! grep -q '^CONFIG_MODULES=y$' "$GOLDFISH_DIR/arch/arm/configs/goldfish_armv7_defconfig"; then
    echo 'CONFIG_MODULES=y' >> "$GOLDFISH_DIR/arch/arm/configs/goldfish_armv7_defconfig"
  fi

  echo "[*] ensuring vulnerabilities build path in drivers/Makefile"
  if ! grep -q 'vulnerabilities/kernel_build/' "$GOLDFISH_DIR/drivers/Makefile"; then
    printf '\nobj-y                          += vulnerabilities/kernel_build/\n' >> "$GOLDFISH_DIR/drivers/Makefile"
  fi

  echo "[*] setting minimal challenge build (hello_world only)"
  cat > "$KERNEL_BUILD_MK" <<'EOF'
obj-y += ../challenges/hello_world/module/
EOF
}

build_kernel() {
  prepare_toolchain
  patch_kernel_tree

  echo "[*] building kernel ..."
  pushd "$GOLDFISH_DIR" >/dev/null
  export ARCH=arm
  export SUBARCH=arm
  export CROSS_COMPILE=arm-linux-androideabi-
  export PATH="$TOOLCHAIN_DIR/bin:$PATH"
  # Avoid expensive git probes in setlocalversion on large/dirty trees.
  : > .scmversion
  make goldfish_armv7_defconfig
  # Force module support in .config without duplicating symbols.
  sed -i '/^CONFIG_MODULES=/d;/^# CONFIG_MODULES is not set$/d;/^CONFIG_MODULE_UNLOAD=/d;/^# CONFIG_MODULE_UNLOAD is not set$/d' .config
  # Keep ipv6/netfilter linkage consistent: some android netfilter bits are built-in.
  sed -i '/^CONFIG_IPV6=/d;/^# CONFIG_IPV6 is not set$/d' .config
  sed -i '/^CONFIG_NF_DEFRAG_IPV6=/d;/^# CONFIG_NF_DEFRAG_IPV6 is not set$/d' .config
  sed -i '/^CONFIG_IP6_NF_IPTABLES=/d;/^# CONFIG_IP6_NF_IPTABLES is not set$/d' .config
  sed -i '/^CONFIG_IP6_NF_FILTER=/d;/^# CONFIG_IP6_NF_FILTER is not set$/d' .config
  sed -i '/^CONFIG_IP6_NF_MANGLE=/d;/^# CONFIG_IP6_NF_MANGLE is not set$/d' .config
  sed -i '/^CONFIG_IP6_NF_RAW=/d;/^# CONFIG_IP6_NF_RAW is not set$/d' .config
  echo 'CONFIG_MODULES=y' >> .config
  echo 'CONFIG_MODULE_UNLOAD=y' >> .config
  echo 'CONFIG_IPV6=y' >> .config
  echo 'CONFIG_NF_DEFRAG_IPV6=y' >> .config
  echo 'CONFIG_IP6_NF_IPTABLES=y' >> .config
  echo 'CONFIG_IP6_NF_FILTER=y' >> .config
  echo 'CONFIG_IP6_NF_MANGLE=y' >> .config
  echo 'CONFIG_IP6_NF_RAW=y' >> .config
  run_oldconfig_noninteractive
  make -j"$(nproc)"
  popd >/dev/null

  echo "[+] built:"
  ls -lh "$KERNEL_ZIMAGE" "$KERNEL_VMLINUX"
}

build_hello_module() {
  prepare_toolchain
  [[ -f "$GOLDFISH_DIR/Makefile" ]] || { echo "[-] kernel tree missing"; exit 1; }
  [[ -f "$HELLO_DIR/hello.c" ]] || { echo "[-] missing $HELLO_DIR/hello.c"; exit 1; }
  [[ -f "$HELLO_DIR/Makefile" ]] || { echo "[-] missing $HELLO_DIR/Makefile"; exit 1; }
  if ! grep -q '^CONFIG_MODULES=y$' "$GOLDFISH_DIR/.config"; then
    echo "[-] CONFIG_MODULES is disabled in kernel .config"
    echo "    This kernel cannot build/load .ko modules."
    echo "    Enable CONFIG_MODULES=y then rebuild kernel first."
    exit 1
  fi

  echo "[*] building hello.ko ..."
  pushd "$HELLO_DIR" >/dev/null
  export ARCH=arm
  export CROSS_COMPILE=arm-linux-androideabi-
  export PATH="$TOOLCHAIN_DIR/bin:$PATH"
  : > "$GOLDFISH_DIR/.scmversion"
  # Ensure generated headers for external module build are in sync with .config.
  (cd "$GOLDFISH_DIR" && run_oldconfig_noninteractive)
  make -C "$GOLDFISH_DIR" prepare modules_prepare >/dev/null
  make -C "$GOLDFISH_DIR" M="$HELLO_DIR" modules
  popd >/dev/null

  ls -lh "$HELLO_DIR/hello.ko"
}

stop_emu() {
  echo "[*] stopping emulator/adb leftovers ..."
  "$ADB_BIN" kill-server >/dev/null 2>&1 || true
  pkill -9 -f 'emulator64-arm @kernel_challenges' >/dev/null 2>&1 || true
  pkill -9 -f 'tools/emulator @kernel_challenges' >/dev/null 2>&1 || true
  pkill -9 -f 'qemu-system.*kernel_challenges' >/dev/null 2>&1 || true
}

start_emu_with_new_kernel() {
  [[ -x "$OLD_EMU_BIN" ]] || { echo "[-] missing old emulator: $OLD_EMU_BIN"; exit 1; }
  [[ -f "$KERNEL_ZIMAGE" ]] || { echo "[-] missing $KERNEL_ZIMAGE (run './build.sh kernel')"; exit 1; }

  stop_emu
  export ANDROID_SDK_ROOT
  echo "[*] starting emulator with newly built zImage ..."
  nohup "$OLD_EMU_BIN" @kernel_challenges \
    -ports 5554,5555 \
    -show-kernel \
    -kernel "$KERNEL_ZIMAGE" \
    -no-boot-anim -no-snapshot -no-audio -no-window \
    -engine classic -verbose \
    >"$LOG_FILE" 2>&1 &

  sleep 3
  "$ADB_BIN" start-server >/dev/null 2>&1 || true
  echo "[+] emulator started; log: $LOG_FILE"
  "$ADB_BIN" devices -l || true
}

start_emu_foreground() {
  [[ -x "$OLD_EMU_BIN" ]] || { echo "[-] missing old emulator: $OLD_EMU_BIN"; exit 1; }
  [[ -f "$KERNEL_ZIMAGE" ]] || { echo "[-] missing $KERNEL_ZIMAGE (run './build.sh kernel')"; exit 1; }

  stop_emu
  export ANDROID_SDK_ROOT
  echo "[*] starting emulator in foreground (Ctrl+C to stop; Ctrl+Z to suspend)"
  exec "$OLD_EMU_BIN" @kernel_challenges \
    -ports 5554,5555 \
    -show-kernel \
    -kernel "$KERNEL_ZIMAGE" \
    -no-boot-anim -no-snapshot -no-audio -no-window \
    -engine classic -verbose
}

load_hello_module() {
  [[ -f "$HELLO_DIR/hello.ko" ]] || { echo "[-] missing hello.ko (run './build.sh hello')"; exit 1; }

  echo "[*] waiting for adb device ..."
  for _ in $(seq 1 60); do
    if "$ADB_BIN" devices | awk 'NR>1 {print $2}' | grep -q '^device$'; then
      break
    fi
    sleep 1
  done

  echo "[*] pushing and loading hello.ko ..."
  "$ADB_BIN" push "$HELLO_DIR/hello.ko" /data/local/tmp/hello.ko
  "$ADB_BIN" shell su -c "insmod /data/local/tmp/hello.ko" || "$ADB_BIN" shell "insmod /data/local/tmp/hello.ko"
  "$ADB_BIN" shell dmesg | tail -n 80
}

cmd="${1:-}"
case "$cmd" in
  all)
    build_kernel
    build_hello_module
    start_emu_with_new_kernel
    load_hello_module
    ;;
  toolchain) prepare_toolchain ;;
  patch-kernel) patch_kernel_tree ;;
  kernel) build_kernel ;;
  hello) build_hello_module ;;
  start-emu) start_emu_with_new_kernel ;;
  start-emu-fg) start_emu_foreground ;;
  load-hello) load_hello_module ;;
  stop-emu) stop_emu ;;
  *) usage; exit 1 ;;
esac
