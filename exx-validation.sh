#!/bin/bash
# Exxact Validation Suite (exx-validation.sh) -- replaces exx-postinstall.sh and exx-burnin-validation.sh's burn-in dispatch.

set -o pipefail

# --- GLOBAL CONFIGURATION ---

PREREQ_MARKER="/etc/exxact_prereq_done"
# Fixed path so the systemd wizard resume knows which user to run as before REAL_USER resolves.
WIZARD_REAL_USER_MARKER="/etc/exxact_wizard_real_user"

# Bumped on any substantive change
SCRIPT_VERSION="2026-09-24.3"

# x86 or ARM architecture detected once at startup
ARCH="$(uname -m)"

# Mellanox OFED pinned from poctoolkitWIP3.sh -- a Rocky 9.4 build. Verify before trusting it on Rocky 10.
OFED_VER_ROCKY="24.04-0.6.6.0-rhel9.4-x86_64"
OFED_VER_UBUNTU="23.07-0.5.1.2-ubuntu22.04-x86_64"

# QA server (legacy). TODO(security): plaintext password, kept intentionally pending a secrets fix. Don't remove.
QA_SERVER_IP="172.25.10.35"
QA_SERVER_USER="root"
QA_SSHPASS="exxact@1"
QA_SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10)
QA_PATH="/data/scripts/fio"
QA_AVAILABLE=""

# Exxact-branded MOTD is applied only to systems whose SN matches this. Contract-manufacturing
# builds carry a customer SN, must stay unbranded, and are identified purely by failing the match.
EXX_SN_PATTERN='^sn4622[0-9]{6}$'
EXX_MOTD_REMOTE="/data/scripts/exx-motd"

# Serial-number formats the QA typo guard recognizes (see _sn_brand / _confirm_system_sn). Three
# Exxact-family brands, all length- and character-distinct so they never collide:
#   Exxact  standard : sn4622 + 6 digits  (EXX_SN_PATTERN above -- lowercase, also drives MOTD branding)
#   NSI              : SN + 8 digits
#   SabrePC          : MMDDYYYY + 4-digit sequence (a build date followed by a run number)
NSI_SN_PATTERN='^SN[0-9]{8}$'
SABREPC_SN_PATTERN='^(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[0-9]{4}[0-9]{4}$'

# Report/diagnostic backup copies land here, outside $REAL_HOME, so they survive a customer wiping their home directory.
EXXACT_ARCHIVE_DIR="/exxact"
# Diagnostic collections live under it too -- see _diag_root.

# Journal capture cap; an uncapped warning-and-above companion file means no priority event is lost.
JOURNAL_MAX_LINES=50000

# Queue depths used when a model has no calibration profile. Conservative and vendor-neutral:
# enough to produce real numbers, not enough to claim they represent the drive's ceiling.
QD_FALLBACK_SEQ=8
QD_FALLBACK_SEQ_WRITE=16
QD_FALLBACK_RAND=32
# Set by _load_qd_profile when the fallback was used -- suppresses PASS/FAIL for that run.
QD_UNCALIBRATED=0
# Models that ran on fallback depths this process, for the run-level REVIEW verdict.
QD_UNCALIBRATED_MODELS=""

# --- Storage/FIO config (ported from new_val_v1.sh). Paths are set below TARGET_DIR, once REAL_HOME is known.
CONFIG_FILES=(
    "random_read.txt"
    "random_write.txt"
    "sequential_read.txt"
    "sequential_write.txt"
)
_DISCOVERED_PATHS=()
_DISCOVERED_MODELS=()
_DISCOVERED_SERIALS=()
_DISCOVERED_CAPACITIES=()
_DISCOVERED_NUMA_NODES=()
_IE_PLAN=()

# GRAID pass/fail thresholds as named config rather than magic numbers buried in _graid_check_pass_fail.
GRAID_PASS_PCT=80
GRAID_MARGINAL_PCT=70
# An average measured-vs-baseline above this offers to re-baseline, so one degraded run isn't a permanent low bar.
GRAID_REBASELINE_TRIGGER_PCT=115

# --- Validation suite config (from new_val_v1.sh) ---
TEMP_INTERVAL=5
CPU_THRESHOLD=85
GPU_THRESHOLD=85
MEM_THRESHOLD=85
MEM_PERCENT=90
DEFAULT_TEST_DURATION=3600
declare -A RESULTS
declare -A RESULTS_TS
MONITORS_RUNNING=0

# --- Concurrent stress: CPU/Memory/GPU at once, exposing thermal/power faults no single-subsystem test sees. ---
CONCURRENT_STRESS_DURATION=14400   # 4 hours, hardcoded -- not user-prompted
# Split the memory budget between mprime and stressapptest so the pair can't trigger the OOM killer.
CONCURRENT_MPRIME_MEM_PCT=40
CONCURRENT_STRESSAPP_MEM_PCT=40

# --- Sequential per-test duration, separate from CONCURRENT_STRESS_DURATION so the two tune independently. ---
SEQUENTIAL_TEST_DURATION=14400   # 4 hours, hardcoded, per test

# --- Matrix sizes swept per GPU for the matrixMul host-vs-device correctness check. Not a stress test. ---
FP_ACCURACY_SIZES=(1024 2048 4096)

# Error tracking (install-style functions)
declare -a ERROR_LOG=()

# Colors
RESET=$'\033[0m'
TXT_RED=$'\033[91m'
BG_RED=$'\033[1;37;41m'
TXT_BLU=$'\033[38;5;51m'
TXT_GRN=$'\033[92m'
TXT_YLW=$'\033[93m'

# SIGHUP included: a dropped SSH session sends it, and it was killing inline runs mid-test.
trap '' SIGINT SIGQUIT SIGTSTP SIGHUP
trap 'stop_temp_monitors' EXIT

if [ "$(whoami)" != 'root' ]; then
  echo -e "${TXT_RED}Please retry with root privilege${RESET}"
  exit 1
fi

# The systemd wizard resume has no sudo session -- fall back to the breadcrumb file written before the reboot.
if [ -z "$SUDO_USER" ]; then
  for _wiz_arg in "$@"; do
    if [ "$_wiz_arg" = "__wizard_resume" ] && [ -s "$WIZARD_REAL_USER_MARKER" ]; then
      SUDO_USER="$(cat "$WIZARD_REAL_USER_MARKER")"
    fi
  done
  unset _wiz_arg
fi

# True on a live/installer boot (casper, dracut live, overlay or tmpfs root).
_detect_live_os() {
  local rootfs
  grep -qE '(^| )(boot=casper|boot=live|rd\.live\.image)( |$)' /proc/cmdline 2>/dev/null && return 0
  [ -d /run/live/medium ] || [ -d /cdrom/casper ] || [ -d /rofs ] && return 0
  rootfs=$(findmnt -n -o FSTYPE / 2>/dev/null)
  case "$rootfs" in overlay|tmpfs|squashfs|aufs) return 0 ;; esac
  return 1
}
LIVE_OS=0
_detect_live_os && LIVE_OS=1

# Technician owning artifacts: $SUDO_USER, else console login, else root on a live boot.
REAL_USER="$SUDO_USER"
[ "$REAL_USER" = "root" ] && REAL_USER=""
if [ -z "$REAL_USER" ]; then
  REAL_USER=$(logname 2>/dev/null)
  [ "$REAL_USER" = "root" ] && REAL_USER=""
fi
# Live boot: use root, not the unused live 'ubuntu' account whose /home nobody checks.
if [ -z "$REAL_USER" ]; then
  if [ "$LIVE_OS" = "1" ]; then
    REAL_USER="root"
  else
    echo -e "${TXT_RED}Run this with 'sudo' from your own user account (not logged in directly as root) -- the script needs \$SUDO_USER to know whose home directory/ownership to use.${RESET}"
    exit 1
  fi
fi
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
HOST="$(hostname)"
# A live account's home may be listed but not yet created; make it rather than bailing out.
if [ -n "$REAL_HOME" ] && [ ! -d "$REAL_HOME" ]; then
  mkdir -p "$REAL_HOME" 2>/dev/null && chown "$REAL_USER:$REAL_USER" "$REAL_HOME" 2>/dev/null
fi
if [ -z "$REAL_HOME" ] || [ ! -d "$REAL_HOME" ]; then
  if [ "$LIVE_OS" = "1" ] && [ -d /root ]; then
    REAL_USER="root"; REAL_HOME="/root"
  else
    echo -e "${TXT_RED}Could not resolve a home directory for '$REAL_USER'.${RESET}"
    exit 1
  fi
fi
if [ "$LIVE_OS" = "1" ]; then
  echo -e "${TXT_YLW}[WARN] Live/diskless OS detected -- running as '$REAL_USER', artifacts in $REAL_HOME.${RESET}"
  echo -e "${TXT_YLW}       Root filesystem is in RAM and is DISCARDED at reboot, $EXXACT_ARCHIVE_DIR included.${RESET}"
  echo -e "${TXT_YLW}       Upload to the QA server before rebooting -- that is the only copy that survives.${RESET}"
  # A PXE/live hostname is the image's, never the system's, and /etc doesn't survive to remember it.
  echo -e "${TXT_YLW}       Hostname here is the live image's ('$HOST'), not the system SN -- expect to type the SN.${RESET}"
fi
TARGET_DIR="$REAL_HOME/POCtoolkit"

# SN naming every artifact; a typed SN overrides the hostname. Fixed /etc path, since $STATE_DIR is itself SN-named.
# Workstation or server. Decides the default boot target: a server has no reason to spend RAM,
# CPU and a DRM master on a desktop during a burn-in, and ships to the console anyway.
# Fixed /etc path so it survives the wizard's reboots and is readable by a standalone run.
SYSTEM_TYPE_FILE="/etc/exxact_system_type"
SYSTEM_TYPE=""
[ -s "$SYSTEM_TYPE_FILE" ] && SYSTEM_TYPE=$(head -1 "$SYSTEM_TYPE_FILE" | tr -d '[:space:]')

SYSTEM_SN_FILE="/etc/exxact_system_sn"
SYSTEM_SN=""
[ -s "$SYSTEM_SN_FILE" ] && SYSTEM_SN=$(head -1 "$SYSTEM_SN_FILE" | tr -d '[:space:]')
[ -z "$SYSTEM_SN" ] && SYSTEM_SN="$HOST"
SN_CONFIRMED=""      # set once _ensure_system_sn_confirmed has asked this process

# (Re)points state paths at the current SN; lives outside $REAL_HOME so it survives a home wipe.
_resolve_state_paths() {
  local prev="$STATE_DIR"
  STATE_DIR="$EXXACT_ARCHIVE_DIR/${SYSTEM_SN}_validation-logs/state"
  mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR="$TARGET_DIR/state"
  mkdir -p "$STATE_DIR" 2>/dev/null
  # Carry earlier state over on an SN change, or a mid-sequence wizard or saved plan vanishes.
  if [ -n "$prev" ] && [ "$prev" != "$STATE_DIR" ] && [ -d "$prev" ]; then
    cp -rn "$prev/." "$STATE_DIR/" 2>/dev/null
    rm -rf "$prev" 2>/dev/null
    # rmdir not rm -rf: removes only the now-empty hostname-named parent left by the rename.
    rmdir "$(dirname "$prev")" 2>/dev/null
    echo "[INFO] Moved existing script state to $STATE_DIR"
  fi
  RESULTS_STATE_FILE="$STATE_DIR/validation_results.state"
  WIZARD_STATE_FILE="$STATE_DIR/wizard_state"
  CRYOSPARC_ACCTINFO_FILE="$STATE_DIR/cryosparc_acctinfo.txt"
  STATUS_FILE="$STATE_DIR/current_run_status.txt"
  IE_PLAN_FILE="$STATE_DIR/ie_plan.conf"
}
STATE_DIR=""
_resolve_state_paths
# Current diagnostic collection directory, set once per process so one run's captures share it.
DIAG_COLLECTION_DIR=""
LOG_DIR="$TARGET_DIR/logs"
TEMPLATE_DIR="$TARGET_DIR/fio"
SWEEP_DIR="$TEMPLATE_DIR/QDsweeps"
RESULTS_DIR="$TEMPLATE_DIR/ValidationResults"
DRIVE_DATA_DIR="$TEMPLATE_DIR/DriveData"
mkdir -p "$LOG_DIR" "$TEMPLATE_DIR" "$SWEEP_DIR" "$RESULTS_DIR" "$DRIVE_DATA_DIR"

# RESULTS doesn't survive between invocations; $RESULTS_STATE_FILE persists it across phases.

# --- Wizard: front-loads setup questions, then prereq -> base(+GPU) -> software -> QA across reboots. ---
WIZARD_LOG_FILE="$LOG_DIR/wizard.log"
WIZARD_UNIT_PATH="/etc/systemd/system/exx-wizard-resume.service"

# --- CLI-flag state: DCGM_LEVEL_OVERRIDE pins the diag level for hardware that faults higher. ---
DCGM_LEVEL_OVERRIDE=""
# DCGM_NVBANDWIDTH_DISABLE (--nvbandwidth=0): disables that one plugin, td6000bw's confirmed crash trigger.
DCGM_NVBANDWIDTH_DISABLE=""
# NOOS_MODE (--noos): PXE-live systems have nothing to install -- skip the menu, go straight to Combined validation.
NOOS_MODE=""
# KILL_MODE (--kill): stop every running test from a second terminal, no menu navigation.
KILL_MODE=""
# BTT_MODE (--btt): collect-and-exit read-only system inventory for the test team. See run_btt_collection.
BTT_MODE=""
# Functions --detach= may re-exec into. A whitelist, so a bad flag can't invoke arbitrary shell.
# Every entry must ask nothing: a detached process has stdin on /dev/null. Prompt BEFORE detaching.
EXX_DETACHABLE=(
  _run_option6_body _run_option7_body _run_option8_body
  _run_cpu_body _run_mem_body _run_gpu_body _run_smart_body
  _run_storage_plan_body dcgm_health_check amd_gpu_validation
  base_install gpu_install emli_install emli_diy_install mlnx_install fabric_install
)
# PHASE_DURATION for the single-test options; passed through --phase-duration on a detached re-exec.
PHASE_DURATION=""
PHASE_DURATION_FROM_CLI=""
# Set once the structure gate has been answered in the foreground, so detaching cannot skip it.
IE_PLAN_PRECONFIRMED=""
# STATUS_FILE lets --status report progress from any terminal; absolute path keeps re-exec cwd-independent.
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
echo -e "${TXT_GRN}exx-validation.sh version ${SCRIPT_VERSION}${RESET}"

# --- SHARED HELPERS ---
write_header() {
  local h="$*"
  printf "%s---------------------------------------------------------------%s\n" "$TXT_GRN" "$RESET"
  printf "%s %s%s\n" "$TXT_GRN" "$h" "$RESET"
  printf "%s---------------------------------------------------------------%s\n" "$TXT_GRN" "$RESET"
}

pause() {
  local message="${*:-Press [Enter] key to continue...}"
  read -rp "${TXT_BLU}${message}${RESET}" _
}

# Fatal setup error vs. routine "press enter to return" pause. Used throughout the storage/IE functions.
quit_with_enter() {
  echo -e "\n[ERROR] $1"
  read -rp "Press [Enter] to exit..."
  exit 1
}

pause_to_menu() {
  local message="$1"
  [ -n "$message" ] && echo -e "\n[INFO] $message"
  read -rp "Press [Enter] to continue..." _
}

# Serial number naming every artifact: this process -> persisted answer -> hostname.
_system_sn() {
  if [ -z "$SYSTEM_SN" ]; then
    [ -s "$SYSTEM_SN_FILE" ] && SYSTEM_SN=$(head -1 "$SYSTEM_SN_FILE" | tr -d '[:space:]')
    [ -z "$SYSTEM_SN" ] && SYSTEM_SN="$HOST"
  fi
  printf '%s\n' "$SYSTEM_SN"
}

# Echoes the brand a serial matches (Exxact / NSI / SabrePC), or nothing if it matches no known
# format. Order doesn't matter -- the three patterns are mutually exclusive by length/charset.
_sn_brand() {
  local sn="$1"
  if   [[ "$sn" =~ $EXX_SN_PATTERN ]];     then echo "Exxact"
  elif [[ "$sn" =~ $NSI_SN_PATTERN ]];     then echo "NSI"
  elif [[ "$sn" =~ $SABREPC_SN_PATTERN ]]; then echo "SabrePC"
  fi
}

_sn_print_formats() {
  echo "         Exxact  : sn4622 + 6 digits    (e.g. sn4622001234)"
  echo "         NSI     : SN + 8 digits        (e.g. SN12345678)"
  echo "         SabrePC : MMDDYYYY + 4 digits  (e.g. 092220261234)"
}

# Re-entry after a typo: loops until the serial matches an approved format, then offers to fix the hostname too.
_sn_reenter() {
  local sn ans
  while true; do
    _read_choice sn "  Enter the correct serial number: "
    sn="${sn//[^A-Za-z0-9._-]/}"      # keep it safe as a filename component
    [ -z "$sn" ] && { echo "  Serial number cannot be blank."; continue; }
    [ -n "$(_sn_brand "$sn")" ] && break
    echo -e "${TXT_YLW}  [WARN] '$sn' does not match an approved format either:${RESET}"
    _sn_print_formats
  done
  SYSTEM_SN="$sn"
  echo -e "${TXT_GRN}  [OK] '$sn' matches the $(_sn_brand "$sn") format.${RESET}"
  _yes_no ans "  Also change the hostname from '$HOST' to '$sn'? (y/n): "
  if [ "$ans" = "y" ]; then
    hostnamectl set-hostname "$sn" && HOST="$sn"
    echo "  Hostname set to $sn."
  fi
}

# Custom build: keep the hostname as-is and name artifacts by an explicitly entered serial (Enter = hostname).
_sn_custom() {
  local sn
  _read_choice sn "  Serial number to name the report/logs by [Enter = use hostname '$HOST']: "
  sn="${sn//[^A-Za-z0-9._-]/}"
  SYSTEM_SN="${sn:-$HOST}"
  echo "  Keeping custom hostname '$HOST' with serial '$SYSTEM_SN'."
}

# An approved-format hostname IS the serial -- no questions. Only a non-standard hostname prompts:
# re-enter (typo) or keep a custom hostname/serial combination.
_confirm_system_sn() {
  local ans brand
  brand=$(_sn_brand "$HOST")
  echo ""
  if [ -n "$brand" ]; then
    SYSTEM_SN="$HOST"
    echo -e "${TXT_GRN}[OK] Hostname '$HOST' matches the approved $brand serial format -- using it as the serial number.${RESET}"
    _sn_persist
    return 0
  fi
  echo "The report, log folder, diagnostics and archive are all named by serial number."
  echo -e "${TXT_YLW}[WARN] Hostname '$HOST' does not match an approved serial number format:${RESET}"
  _sn_print_formats
  echo "  1) Re-enter the serial number (the hostname is a typo)"
  echo "  2) Keep a custom, unique hostname/serial combination"
  while true; do
    _read_choice ans "Enter selection [1-2]: "
    case "$ans" in
      1) _sn_reenter; break ;;
      2) _sn_custom;  break ;;
      *) echo "Please enter 1 or 2." ;;
    esac
  done
  _sn_persist
}

# Asks once, records the answer, and applies the matching default boot target.
_confirm_system_type() {
  local ans
  echo ""
  echo "Is this system a workstation or a server?"
  echo "  1) Workstation -- boots to the GUI desktop"
  echo "  2) Server      -- boots to the command line"
  while true; do
    _read_choice ans "Enter selection [1-2]: "
    case "$ans" in
      1) SYSTEM_TYPE="workstation"; break ;;
      2) SYSTEM_TYPE="server"; break ;;
      *) echo "Please enter 1 or 2." ;;
    esac
  done
  _system_type_persist
}

_system_type_persist() {
  printf '%s\n' "$SYSTEM_TYPE" > "$SYSTEM_TYPE_FILE" 2>/dev/null
  echo "System type: $SYSTEM_TYPE"
}

# nvidia-drm.modeset decides whether the NVIDIA GPUs provide kernel modesetting.
#   workstation -> 1. Required for a Wayland GDM session. With 0, RHEL's 61-gdm.rules disables
#     Wayland, GDM falls back to X11, Xorg binds an NVIDIA GPU that may have no monitor attached,
#     and tty1 shows a black screen while tty2+ still work off the framebuffer console.
#   server -> 0. Compute only, nothing plugged in, no reason to give the GPU a display role.
_apply_display_kernel_params() {
  local want
  case "$SYSTEM_TYPE" in
    workstation) want=1 ;;
    server)      want=0 ;;
    *) echo "[INFO] System type not recorded -- leaving nvidia-drm.modeset unchanged."; return 0 ;;
  esac
  if command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL --remove-args="nvidia-drm.modeset" >/dev/null 2>&1
    grubby --update-kernel=ALL --args="nvidia-drm.modeset=$want" >/dev/null 2>&1
  elif [ -f /etc/default/grub ]; then
    sed -i 's/[[:space:]]*nvidia-drm\.modeset=[01]//g' /etc/default/grub
    sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"nvidia-drm.modeset=$want /" /etc/default/grub
    update-grub >/dev/null 2>&1 || grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
  fi
  echo "[OK] nvidia-drm.modeset=$want ($SYSTEM_TYPE) -- takes effect next boot."
}

# Applies the recorded type. Unknown type leaves the current target alone rather than guessing --
# silently switching a customer's boot behaviour is worse than doing nothing.
_apply_default_boot_target() {
  case "$SYSTEM_TYPE" in
    workstation)
      systemctl set-default graphical.target >/dev/null 2>&1 \
        && echo "[OK] Default boot target: graphical (workstation)."
      ;;
    server)
      systemctl set-default multi-user.target >/dev/null 2>&1 \
        && echo "[OK] Default boot target: multi-user / command line (server)."
      ;;
    *)
      echo "[INFO] System type not recorded -- leaving the default boot target unchanged."
      ;;
  esac
}

_sn_persist() {
  mkdir -p "$(dirname "$SYSTEM_SN_FILE")" 2>/dev/null
  printf '%s\n' "$SYSTEM_SN" > "$SYSTEM_SN_FILE"
  # Re-point state paths and force log paths to re-resolve, since everything downstream is SN-named.
  _resolve_state_paths
  VAL_INITIALIZED=0
  echo "Hostname: $HOST   Serial number: $SYSTEM_SN"
  [ "$SYSTEM_SN" != "$HOST" ] && echo "Artifacts will be named ${SYSTEM_SN}_* (hostname differs from the serial)."
  return 0
}

# Asks at most once per process, and never without a terminal -- a background run must not block.
_ensure_system_sn_confirmed() {
  [ -n "$SN_CONFIRMED" ] && return 0
  SN_CONFIRMED=1
  if [ ! -t 0 ]; then
    _system_sn >/dev/null
    return 0
  fi
  _confirm_system_sn
}

# _read_choice <outvar> <prompt...> -- menu read that exits on EOF instead of spinning forever.
_read_choice() {
  local __outvar="$1"; shift
  if ! read -rp "$*" "$__outvar"; then
    echo
    echo -e "${TXT_YLW}[EOF] No more input on stdin -- exiting rather than spin.${RESET}"
    exit 1
  fi
}

# _yes_no <outvar> <prompt> -- loops until y/n, sets outvar to y or n.
_yes_no() {
  local __ov="$1"; shift
  local __a
  while true; do
    _read_choice __a "$*"
    case "$(printf '%s' "$__a" | tr 'A-Z' 'a-z')" in
      y|yes) eval "$__ov=y"; return 0 ;;
      n|no)  eval "$__ov=n"; return 0 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# _prompt_confirmed <outvar> <label> <prompt> [allow_empty] -- reads one field, re-prompts until accepted.
_prompt_confirmed() {
  local __ov="$1" __lbl="$2" __pr="$3" __allow="${4:-}"
  local __v __ok
  while true; do
    _read_choice __v "$__pr"
    if [ -z "$__v" ] && [ "$__allow" != "allow_empty" ]; then
      echo -e "${TXT_YLW}$__lbl cannot be blank.${RESET}"
      continue
    fi
    printf '  %s: %s\n' "$__lbl" "${__v:-<blank>}"
    _yes_no __ok "Is this correct? (y/n): "
    [ "$__ok" = "y" ] && break
    echo "Re-enter it."
  done
  eval "$__ov=\"\$__v\""
}

# _review_entries <title> <"label: value">... -- final read-through; returns 0 accept, 1 re-enter.
_review_entries() {
  local __title="$1"; shift
  local __e __ok
  echo ""
  write_header "$__title"
  for __e in "$@"; do printf '  %s\n' "$__e"; done
  echo ""
  _yes_no __ok "Is all of the above correct? (y = continue, n = re-enter): "
  [ "$__ok" = "y" ] && return 0
  return 1
}

# Checks QA reachability once per run and caches it, so a CPU/Memory/GPU-only run never pays for it.
_ensure_qa_checked() {
  [ -n "$QA_AVAILABLE" ] && return
  echo "[INFO] Checking connectivity to QA server ($QA_SERVER_USER@$QA_SERVER_IP)..."
  if sshpass -p "$QA_SSHPASS" ssh "${QA_SSH_OPTS[@]}" "$QA_SERVER_USER@$QA_SERVER_IP" "exit" 2>/dev/null; then
    QA_AVAILABLE=true
    echo "[SUCCESS] QA server connection verified."
  else
    QA_AVAILABLE=false
    echo "[WARN] QA server is not reachable. Template sync and QD profile uploads will be skipped; local templates/profiles will be used instead."
  fi
}

log_failure() {
  local msg="$1"
  echo -e "${TXT_RED}[FAILED] $msg${RESET}"
  ERROR_LOG+=("$msg")
}

print_error_summary() {
  if [ ${#ERROR_LOG[@]} -eq 0 ]; then
    echo -e "${TXT_GRN}======================================================${RESET}"
    echo -e "${TXT_GRN}   OPERATION COMPLETE - NO ERRORS DETECTED            ${RESET}"
    echo -e "${TXT_GRN}======================================================${RESET}"
  else
    echo -e "${BG_RED}======================================================${RESET}"
    echo -e "${BG_RED}   COMPLETED WITH ${#ERROR_LOG[@]} ERRORS                     ${RESET}"
    echo -e "${BG_RED}======================================================${RESET}"
    for err in "${ERROR_LOG[@]}"; do
      echo -e "${TXT_RED} - $err${RESET}"
    done
  fi
}

run_and_log() {
  local func_name=$1 log_prefix=$2
  local timestamp; timestamp=$(date +"%m%d%Y-%H:%M")
  local log_file="$LOG_DIR/${log_prefix}_${timestamp}.log"
  mkdir -p "$LOG_DIR"
  chown -R "$REAL_USER:$REAL_USER" "$LOG_DIR" 2>/dev/null
  echo -e "${TXT_BLU}Logging output to: $log_file${RESET}"
  export CURRENT_LOG_FILE="$log_file"
  ERROR_LOG=()
  ("$func_name") 2>&1 | tee -a "$log_file"
}

# Login-screen (display manager) policy for Ubuntu. Root cause of the lightdm takeover (verified live
# 2026-09-24): xfce4 -> xfce4-session Recommends light-locker -> Depends lightdm (+ unity-greeter). On a
# Server-based install lightdm is then the FIRST DM, so debconf keeps it when ubuntu-desktop adds gdm3.
DM_ORIGINAL_FILE="/etc/exxact_original_dm"

_dm_current() {
  local dm=""
  [ -s /etc/X11/default-display-manager ] && dm=$(basename "$(cat /etc/X11/default-display-manager 2>/dev/null)")
  if [ -z "$dm" ]; then
    dm=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)
    [ -n "$dm" ] && dm=$(basename "$dm" .service)
  fi
  case "$dm" in .|display-manager) dm="" ;; esac
  printf '%s\n' "$dm"
}

# Records the DM the OS shipped with, once, before this script installs anything. "none" = Server install.
# Past the prereq marker it is too late to know (an older build may already have installed lightdm): "unknown".
_dm_record_original() {
  [ -f "$DM_ORIGINAL_FILE" ] && return 0
  local dm="unknown"
  [ -f "$PREREQ_MARKER" ] || { dm=$(_dm_current); dm="${dm:-none}"; }
  printf '%s\n' "$dm" > "$DM_ORIGINAL_FILE"
  vlog "DISPLAY MANAGER: original login screen recorded as '$dm'."
}

# Makes <dm> the login screen from next boot: default-display-manager, debconf for every installed DM
# (or the next apt run flips it back), and display-manager.service pointed at the REAL unit file --
# enabling gdm3.service fails because it is only an alias of gdm.service.
_dm_set() {  # _dm_set <gdm3|lightdm|sddm|...>
  local want="$1" bin="" unit="" o
  for o in "/usr/sbin/$want" "/usr/bin/$want"; do [ -x "$o" ] && { bin="$o"; break; }; done
  [ -z "$bin" ] && { log_failure "Display manager '$want' is not installed -- login screen left unchanged."; return 1; }
  for o in "/usr/lib/systemd/system/$want.service" "/lib/systemd/system/$want.service"; do
    [ -e "$o" ] && { unit=$(readlink -f "$o"); break; }
  done
  [ -z "$unit" ] && { log_failure "No systemd unit found for display manager '$want'."; return 1; }
  printf '%s\n' "$bin" > /etc/X11/default-display-manager
  for o in gdm3 lightdm sddm lxdm xdm slim nodm; do
    dpkg -s "$o" >/dev/null 2>&1 && echo "$o shared/default-x-display-manager select $want"
  done | debconf-set-selections
  ln -sf "$unit" /etc/systemd/system/display-manager.service
  systemctl daemon-reload
}

# Original DM if the OS came with one (customer image choice), else gdm3 once ubuntu-desktop provides it.
_dm_apply_policy() {
  local orig want now
  orig=$(cat "$DM_ORIGINAL_FILE" 2>/dev/null)
  if [ -n "$orig" ] && [ "$orig" != "none" ] && [ "$orig" != "unknown" ] && dpkg -s "$orig" >/dev/null 2>&1; then
    want="$orig"
  elif dpkg -s gdm3 >/dev/null 2>&1; then
    want="gdm3"
  else
    return 0
  fi
  now=$(_dm_current)
  if [ "$now" = "$want" ] && [ "$(readlink -f /etc/systemd/system/display-manager.service)" != "/etc/systemd/system/display-manager.service" ]; then
    return 0
  fi
  echo -e "${TXT_YLW}[FIX] Login screen is '${now:-none}' -- setting '$want' (takes effect next boot).${RESET}"
  _dm_set "$want" && vlog "DISPLAY MANAGER: '${now:-none}' -> '$want'."
}

install_apt_packages() {
  local pkgs=("$@")
  echo "Updating Repositories..."
  for i in {1..3}; do
    apt-get update -y && break || { echo "Repo update failed, retrying..."; echo "nameserver 8.8.8.8" > /etc/resolv.conf; sleep 2; }
  done
  echo "Installing Packages..."
  for pkg in "${pkgs[@]}"; do
    if apt-get install -y "$pkg"; then
      echo -e "${TXT_GRN}[SUCCESS] $pkg installed.${RESET}"
    else
      log_failure "Package '$pkg' failed to install."
    fi
  done
}

install_dnf_packages() {
  local pkgs=("$@")
  local all_ok=0
  echo "Installing Packages..."
  for pkg in "${pkgs[@]}"; do
    if dnf install -y "$pkg"; then
      echo -e "${TXT_GRN}[SUCCESS] $pkg installed.${RESET}"
    else
      log_failure "Package '$pkg' failed to install."
      all_ok=1
    fi
  done
  return $all_ok
}

clear_apt_locks() {
  killall apt apt-get dpkg 2>/dev/null
  rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
  dpkg --configure -a
}

# CUDA repo OS token (rhel8/9/10, ubuntu2204/2404/2604) for the running OS. Every callsite used to hardcode rhel10.
_cuda_repo_os_token() {
  . /etc/os-release
  case "$ID" in
    rocky|rhel|almalinux) echo "rhel${VERSION_ID%%.*}" ;;
    ubuntu) echo "ubuntu$(echo "$VERSION_ID" | tr -d '.')" ;;
    *) echo "" ;;
  esac
}

# CUDA repo arch segment: "sbsa" on ARM64 datacenter hardware ("arm64" 404s), "x86_64" otherwise.
_cuda_repo_arch_path() {
  case "$ARCH" in
    aarch64) echo "sbsa" ;;
    *) echo "x86_64" ;;
  esac
}

check_prereqs() {
  if [ ! -f "$PREREQ_MARKER" ]; then
    echo -e "${TXT_RED}CRITICAL: Prerequisite Install has not been run.${RESET}"
    echo "Please run Option 1 first."
    pause; return 1
  fi
  # consoleblank=0, not modeset=0: modeset now varies by system type, this does not.
  if ! grep -q "consoleblank=0" /proc/cmdline; then
    echo -e "${TXT_RED}CRITICAL: System has not rebooted since Prerequisite Install.${RESET}"
    echo "Please reboot to apply kernel parameters."
    pause; return 1
  fi
  return 0
}

qa_scp_get() {  # qa_scp_get <remote_path> <local_dest>
  sshpass -p "$QA_SSHPASS" scp "${QA_SSH_OPTS[@]}" "$QA_SERVER_USER@$QA_SERVER_IP:$1" "$2"
}

# --- 0. AUTOMATED PROVISIONING WIZARD: setup questions, then prereq -> base(+GPU) -> software -> QA. ---
WIZ_BASE_CHOICE=""
declare -a WIZ_SOFTWARE=()
# GPU driver decision captured at collection time (override|keep|""), honored by the unattended gpu_install.
GPU_DRIVER_OVERRIDE=""

# Rewrites the wizard state file from the current WIZ_*/WIZARD_PHASE globals, plus the real-user breadcrumb.
_wizard_save_state() {
  mkdir -p "$(dirname "$WIZARD_STATE_FILE")"
  {
    printf 'WIZARD_PHASE\t%s\n' "$WIZARD_PHASE"
    printf 'REAL_USER\t%s\n' "$REAL_USER"
    printf 'BASE_CHOICE\t%s\n' "$WIZ_BASE_CHOICE"
    printf 'SOFTWARE\t%s\n' "${WIZ_SOFTWARE[*]}"
    printf 'DCGM_LEVEL_OVERRIDE\t%s\n' "$DCGM_LEVEL_OVERRIDE"
    printf 'DCGM_NVBANDWIDTH_DISABLE\t%s\n' "$DCGM_NVBANDWIDTH_DISABLE"
    printf 'GPU_DRIVER_OVERRIDE\t%s\n' "$GPU_DRIVER_OVERRIDE"
  } > "$WIZARD_STATE_FILE"
  chown "$REAL_USER:$REAL_USER" "$WIZARD_STATE_FILE" 2>/dev/null
  echo "$REAL_USER" > "$WIZARD_REAL_USER_MARKER"
}

# Loads WIZARD_PHASE/WIZ_BASE_CHOICE/WIZ_SOFTWARE[] from a saved state file; phase stays empty on a first run.
_wizard_load_state() {
  WIZARD_PHASE=""
  WIZ_BASE_CHOICE=""
  WIZ_SOFTWARE=()
  [ -s "$WIZARD_STATE_FILE" ] || return 0
  local key val
  while IFS=$'\t' read -r key val; do
    case "$key" in
      WIZARD_PHASE) WIZARD_PHASE="$val" ;;
      BASE_CHOICE) WIZ_BASE_CHOICE="$val" ;;
      SOFTWARE) read -ra WIZ_SOFTWARE <<< "$val" ;;
      # Carries --dcgm=/--nvbandwidth= across reboots -- the resume unit's ExecStart can't pass CLI flags.
      DCGM_LEVEL_OVERRIDE) DCGM_LEVEL_OVERRIDE="$val" ;;
      DCGM_NVBANDWIDTH_DISABLE) DCGM_NVBANDWIDTH_DISABLE="$val" ;;
      # The GPU driver override decision, made interactively at collection, honored on the unattended resume.
      GPU_DRIVER_OVERRIDE) GPU_DRIVER_OVERRIDE="$val" ;;
    esac
  done < "$WIZARD_STATE_FILE"
}

# Idempotently registers a one-shot systemd unit that re-launches this script at next boot.
_register_wizard_resume_unit() {
  cat > "$WIZARD_UNIT_PATH" <<EOF
[Unit]
Description=exx-validation.sh wizard resume
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH __wizard_resume

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable exx-wizard-resume.service
}

_unregister_wizard_resume_unit() {
  systemctl disable --now exx-wizard-resume.service 2>/dev/null
  rm -f "$WIZARD_UNIT_PATH"
  systemctl daemon-reload 2>/dev/null
}

# Every setup question, asked once, up front, before any real work starts.
# Collection-time GPU driver decision. Runs while the tech is still at the keyboard, BEFORE any
# provisioning, so the unattended gpu_install never has to stop to ask. Detects the existing driver and,
# only when there is a real choice, asks whether to override -- storing override|keep in GPU_DRIVER_OVERRIDE.
# A matching package driver or a bare GPU needs no question and leaves GPU_DRIVER_OVERRIDE empty.
_wiz_collect_gpu_driver_decision() {
  GPU_DRIVER_OVERRIDE=""
  [ "$WIZ_BASE_CHOICE" = "gpu" ] || return 0     # only when a GPU driver install will run
  . /etc/os-release
  case "$ID" in ubuntu) ;; *) return 0 ;; esac    # override handling is on the Ubuntu driver path
  [ "$ARCH" = "aarch64" ] && return 0             # ARM ships pre-installed; no driver step

  local method run_ver tgt run_branch c
  method=$(_gpu_driver_install_method)
  run_ver=$(_gpu_running_driver_version)
  tgt=$(_gpu_target_driver_branch)

  echo ""
  write_header "GPU Driver Check"
  case "$method" in
    none)
      echo "No NVIDIA driver detected -- the packaged driver (branch ${tgt:-recommended}) will be installed."
      ;;
    run)
      echo -e "${TXT_YLW}A .run-installed NVIDIA driver was detected (version ${run_ver}).${RESET}"
      echo "It was installed from an NVIDIA .run file, NOT the native package manager."
      echo ""
      echo -e "${TXT_YLW}It is HIGHLY RECOMMENDED to override it with a native (package-managed) install.${RESET}"
      echo "A .run driver is not tracked by apt/dpkg, and leaving it in place can cause unforeseen"
      echo "issues with the rest of this script: CUDA toolkit installs, DKMS rebuilds, and"
      echo "driver/library version matching can all break against a .run driver."
      echo ""
      echo "You may choose to keep it, but if you do, later steps may fail in ways this script"
      echo "cannot recover from automatically."
      _yes_no c "Override the .run driver with a native install? (y = override [recommended] / n = keep): "
      if [ "$c" = "y" ]; then
        GPU_DRIVER_OVERRIDE="override"
        echo -e "${TXT_GRN}Will override the .run driver with a native branch-${tgt:-recommended} install.${RESET}"
      else
        GPU_DRIVER_OVERRIDE="keep"
        echo -e "${TXT_YLW}Keeping the .run driver at your request -- be aware later steps may fail.${RESET}"
      fi
      ;;
    pkg)
      run_branch="${run_ver%%.*}"
      if [ -z "$tgt" ] || [ "$run_branch" = "$tgt" ]; then
        echo "An NVIDIA driver (version ${run_ver}) is already installed via the package manager and"
        echo "matches the target branch -- it will be kept as-is."
      else
        echo "An NVIDIA driver is already installed via the package manager:"
        echo "   present:                   ${run_ver}"
        echo "   this script would install: branch ${tgt}"
        _yes_no c "Replace the existing driver with branch ${tgt}? (y = replace / n = keep existing): "
        [ "$c" = "y" ] && GPU_DRIVER_OVERRIDE="override" || GPU_DRIVER_OVERRIDE="keep"
      fi
      ;;
  esac
}

# One-line human-readable summary of the driver decision, for the review/summary blocks.
_gpu_driver_decision_label() {
  case "$GPU_DRIVER_OVERRIDE" in
    override) echo "override existing driver with native install" ;;
    keep)     echo "KEEP existing driver (override declined)" ;;
    *)        echo "install/keep automatically (no override needed)" ;;
  esac
}

_wizard_collect_answers() {
  write_header "Automated Provisioning Wizard -- Setup Questions"
  echo "Answer everything up front; the script then runs unattended through"
  echo "installation, any required reboots, software installs, and the final"
  echo "Combined QA validation."
  echo ""

  # Collected into variables and reviewed as a block; nothing is applied until the summary is accepted.
  local _wiz_change_host _wiz_new_hostname _wiz_base_sel _wiz_want_storage _wiz_sw_sel _tok _wiz_type
  local cs_license cs_email cs_last cs_first cs_root cs_ssd

  while true; do
    _wiz_new_hostname=""
    echo ""
    echo "System type -- decides the default boot target and how the desktop is configured:"
    echo "  1) Workstation -- boots to the GUI desktop"
    echo "  2) Server      -- boots to the command line"
    while true; do
      _read_choice _wiz_type "Enter selection [1-2]: "
      case "$_wiz_type" in
        1) SYSTEM_TYPE="workstation"; break ;;
        2) SYSTEM_TYPE="server"; break ;;
        *) echo "Please enter 1 or 2." ;;
      esac
    done

    echo ""
    echo "Current hostname: $(cat /etc/hostname)"
    _yes_no _wiz_change_host "Change hostname? (y/n): "
    [ "$_wiz_change_host" = "y" ] && _prompt_confirmed _wiz_new_hostname "New hostname" "Enter new hostname: "

    echo ""
    echo "Base Post-Install option:"
    echo "  1. None (skip Base/GPU Post Install entirely)"
    echo "  2. Base Post Install"
    echo "  3. Base + GPU Post Install"
    while true; do
      _read_choice _wiz_base_sel "Enter choice [1-3]: "
      case "$_wiz_base_sel" in 1|2|3) break ;; *) echo "Please enter 1, 2 or 3." ;; esac
    done
    case "$_wiz_base_sel" in
      2) WIZ_BASE_CHOICE="base" ;;
      3) WIZ_BASE_CHOICE="gpu" ;;
      *) WIZ_BASE_CHOICE="none" ;;
    esac

    echo ""
    _yes_no _wiz_want_storage "Configure storage (drive/RAID/filesystem/mount-point setup) now? (y/n): "

    echo ""
    echo "Software to install after Base Post-Install completes (space-separated"
    echo "numbers, e.g. \"1 3\"; 0 for none):"
    echo "  0. None"
    echo "  1. EMLI"
    echo "  2. EMLI DIY  (Docker + Anaconda, no preloaded images)"
    echo "  3. CryoSparc"
    echo "  4. Schrodinger  [WORK IN PROGRESS -- records choice only]"
    echo "  5. sbgrid  [WORK IN PROGRESS -- records choice only]"
    _read_choice _wiz_sw_sel "Enter choice(s): "
    WIZ_SOFTWARE=()
    for _tok in $_wiz_sw_sel; do
      case "$_tok" in
        1) WIZ_SOFTWARE+=("emli") ;;
        2) WIZ_SOFTWARE+=("emli_diy") ;;
        3) WIZ_SOFTWARE+=("cryosparc") ;;
        4) WIZ_SOFTWARE+=("schrodinger") ;;
        5) WIZ_SOFTWARE+=("sbgrid") ;;
      esac
    done

    # EMLI needs a loaded NVIDIA driver, so force Base+GPU; its reboot lands before the software phase.
    if [[ " ${WIZ_SOFTWARE[*]} " == *" emli "* || " ${WIZ_SOFTWARE[*]} " == *" emli_diy "* ]] && [ "$WIZ_BASE_CHOICE" != "gpu" ]; then
      echo -e "${TXT_YLW}NOTE: EMLI requires the GPU driver -- upgrading Base Post-Install choice to Base+GPU.${RESET}"
      WIZ_BASE_CHOICE="gpu"
    fi

    # Detect the existing GPU driver and take the override decision now, before any automation.
    _wiz_collect_gpu_driver_decision

    if [[ " ${WIZ_SOFTWARE[*]} " == *" cryosparc "* ]]; then
      echo ""
      echo "CryoSparc account info (used to run the install unattended later):"
      _prompt_confirmed cs_license "License ID"      "  License ID: "
      _prompt_confirmed cs_email   "Email Address"   "  Email Address: "
      _prompt_confirmed cs_last    "Last Name"       "  Last Name: "
      _prompt_confirmed cs_first   "First Name"      "  First Name: "
      _prompt_confirmed cs_root    "Install root"    "  Install root: "
      _prompt_confirmed cs_ssd     "SSD cache path"  "  SSD cache path: "
    fi

    local _rev=("System type:       $SYSTEM_TYPE ($([ "$SYSTEM_TYPE" = server ] && echo "boots to command line" || echo "boots to GUI desktop"))" \
                "Hostname change:   ${_wiz_new_hostname:-no change ($(cat /etc/hostname))}" \
                "Base Post-Install: $WIZ_BASE_CHOICE" \
                "Configure storage: $_wiz_want_storage" \
                "Software:          ${WIZ_SOFTWARE[*]:-none}")
    [ "$WIZ_BASE_CHOICE" = "gpu" ] && _rev+=("GPU driver:        $(_gpu_driver_decision_label)")
    if [[ " ${WIZ_SOFTWARE[*]} " == *" cryosparc "* ]]; then
      _rev+=("CryoSparc license: $cs_license" "CryoSparc email:   $cs_email" \
             "CryoSparc name:    $cs_first $cs_last" "CryoSparc root:    $cs_root" \
             "CryoSparc SSD:     $cs_ssd")
    fi
    _review_entries "Review Wizard Answers" "${_rev[@]}" && break
    echo -e "${TXT_YLW}Starting the questions over -- nothing has been applied yet.${RESET}"
  done

  # Accepted -- now apply. Type is recorded first: prereq_install reads it to pick the boot target.
  _system_type_persist
  if [ -n "$_wiz_new_hostname" ]; then
    hostnamectl set-hostname "$_wiz_new_hostname"
    HOST="$(hostname)"
  fi
  # Asked here with every other question, so the unattended run that follows never stops to ask.
  _ensure_system_sn_confirmed

  if [[ " ${WIZ_SOFTWARE[*]} " == *" cryosparc "* ]]; then
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$cs_license" "$cs_email" "$cs_last" "$cs_first" "$cs_root" "$cs_ssd" \
      > "$CRYOSPARC_ACCTINFO_FILE"
    chown "$REAL_USER:$REAL_USER" "$CRYOSPARC_ACCTINFO_FILE"
  fi

  if [ "$_wiz_want_storage" = "y" ]; then
    get_cpu_threads
    verify_environment_templates
    ie_collect_and_save_plan
  fi

  echo ""
  write_header "Summary"
  echo "Base Post-Install: $WIZ_BASE_CHOICE"
  [ "$WIZ_BASE_CHOICE" = "gpu" ] && echo "GPU driver:        $(_gpu_driver_decision_label)"
  echo "Software: ${WIZ_SOFTWARE[*]:-none}"
  echo "This will reboot up to twice, unattended, and auto-resume each time."
  local _wiz_confirm_all
  _yes_no _wiz_confirm_all "Proceed? (y/n): "
  if [ "$_wiz_confirm_all" != "y" ]; then
    echo "Aborted -- no changes made."
    exit 0
  fi
}

# Base or Base+GPU per the collected choice; a GPU install needs its own reboot for the driver.
_wizard_run_base_phase() {
  case "$WIZ_BASE_CHOICE" in
    base)
      base_install
      WIZARD_PHASE="BASE_DONE"; _wizard_save_state
      _wizard_run_from_current_phase
      ;;
    gpu)
      base_install
      gpu_install
      WIZARD_PHASE="BASE_DONE"; _wizard_save_state
      _register_wizard_resume_unit
      echo -e "${BG_RED} WARNING: SYSTEM WILL REBOOT AUTOMATICALLY FOR THE GPU DRIVER ${RESET}"
      ( sleep 5; reboot ) >> "$CURRENT_LOG_FILE" 2>&1 & disown
      exit 0
      ;;
    *)
      WIZARD_PHASE="BASE_DONE"; _wizard_save_state
      _wizard_run_from_current_phase
      ;;
  esac
}

# Runs each selected software install; Schrodinger/sbgrid have no procedure yet, so they only log.
_wizard_run_software_phase() {
  local sw
  # Runs after the GPU reboot so OFED builds against the settled kernel. No card = silent skip.
  if _mellanox_present; then
    write_header "Automated Provisioning Wizard -- Mellanox / ConnectX detected"
    lspci 2>/dev/null | grep -i 'mellanox\|connectx' | sed 's/^/  /'
    vlog "MELLANOX: adapter detected -- running OFED + MFT install"
    run_and_log mlnx_install "wizard-mlnx-install"
  else
    vlog "MELLANOX: no adapter detected -- OFED/MFT install skipped"
  fi
  for sw in "${WIZ_SOFTWARE[@]}"; do
    case "$sw" in
      # Base+GPU already ran (and rebooted) in the base phase -- never re-run gpu_install here.
      emli) _emli_run full ;;
      emli_diy) _emli_run diy ;;
      cryosparc) cryosparc_install ;;
      schrodinger) vlog "SOFTWARE: Schrodinger selected -- [WORK IN PROGRESS] no automated install yet. Recorded for the flier only." ;;
      sbgrid) vlog "SOFTWARE: sbgrid selected -- [WORK IN PROGRESS] no automated install yet. Recorded for the flier only." ;;
    esac
  done
  install_exx_motd
  WIZARD_PHASE="SOFTWARE_DONE"; _wizard_save_state
  _wizard_run_from_current_phase
}

# Final Combined QA validation, then marks the wizard done and tears down the resume unit.
_wizard_run_qa_phase() {
  write_header "Automated Provisioning Wizard -- Combined QA Validation"
  _run_option6_body
  WIZARD_PHASE="DONE"; _wizard_save_state
  _unregister_wizard_resume_unit
  write_status "Wizard: automated provisioning complete"
  echo -e "${TXT_GRN}Automated provisioning wizard complete -- see $REAL_HOME/*_qa-validation.txt${RESET}"
}

# Shared phase dispatcher, used by both the first interactive run and every systemd-triggered resume.
_wizard_run_from_current_phase() {
  case "$WIZARD_PHASE" in
    COLLECTED) prereq_install ;;   # saves state + reboots internally, does not return
    PREREQ_DONE) _wizard_run_base_phase ;;
    BASE_DONE) _wizard_run_software_phase ;;
    SOFTWARE_DONE) _wizard_run_qa_phase ;;
    DONE) echo "Wizard already completed -- see $REAL_HOME/*_qa-validation.txt" ;;
    *) echo "[ERROR] Unknown wizard phase '$WIZARD_PHASE'" ;;
  esac
}

# Menu option 1. Starts a fresh wizard run, or offers to resume one already in progress.
run_automated_wizard() {
  export CURRENT_LOG_FILE="$WIZARD_LOG_FILE"
  mkdir -p "$LOG_DIR"; chown -R "$REAL_USER:$REAL_USER" "$LOG_DIR" 2>/dev/null
  _wizard_load_state
  if [ -n "$WIZARD_PHASE" ] && [ "$WIZARD_PHASE" != "DONE" ]; then
    echo "A wizard run is already in progress (phase: $WIZARD_PHASE)."
    local _wiz_resume_choice
    read -rp "Resume it now instead of starting over? (y/n): " _wiz_resume_choice
    if [ "$_wiz_resume_choice" != "y" ]; then
      echo "Leaving existing wizard state untouched -- re-run and choose 'y' to resume, or delete $WIZARD_STATE_FILE to start fresh."
      return
    fi
    _wizard_run_from_current_phase
    return
  fi
  _wizard_collect_answers
  WIZARD_PHASE="COLLECTED"
  _wizard_save_state
  _wizard_run_from_current_phase
}

# Entry point for the systemd resume unit -- no sudo session, no terminal; picks up WIZARD_PHASE and continues.
_wizard_resume() {
  export CURRENT_LOG_FILE="$WIZARD_LOG_FILE"
  mkdir -p "$LOG_DIR"; chown -R "$REAL_USER:$REAL_USER" "$LOG_DIR" 2>/dev/null
  write_header "Automated Provisioning Wizard -- Resuming (boot-triggered)"
  _wizard_load_state
  if [ -z "$WIZARD_PHASE" ]; then
    echo "[ERROR] __wizard_resume fired but no wizard state was found at $WIZARD_STATE_FILE -- nothing to resume." | tee -a "$WIZARD_LOG_FILE"
    _unregister_wizard_resume_unit
    return 1
  fi
  _wizard_run_from_current_phase
}

# --- 1. PREREQUISITE INSTALL (from poctoolkitWIP3.sh) ---
prereq_install() {
  write_header "Starting Prerequisite Installation..."
  ERROR_LOG=()

  # Hostname change is collected up front by _wizard_collect_answers -- nothing to ask here.
  echo "Setting Target..."
  echo "nameserver 8.8.8.8" > /etc/resolv.conf

  echo "Disabling System Sleep & Power Management..."
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

  echo "Applying Kernel Parameters..."
  # nvidia-drm.modeset is NOT here -- it follows the system type, applied by
  # _apply_display_kernel_params below and re-asserted after the driver install.
  PARAMS="iommu=pt consoleblank=0 usbcore.autosuspend=-1"
  if [ -f /etc/redhat-release ]; then
    # Rocky/RHEL 9+ use BLS boot entries; grubby updates them directly and handles BIOS/UEFI itself.
    grubby --update-kernel=ALL --args="$PARAMS"
  else
    NEEDS_UPDATE=false
    for param in $PARAMS; do
      if ! grep -q "$param" /etc/default/grub; then
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$param /" /etc/default/grub
        NEEDS_UPDATE=true
      fi
    done
    [ "$NEEDS_UPDATE" = true ] && [ -f /etc/debian_version ] && update-grub
  fi

  echo "Applying Terminfo Fix..."
  [ -d "/usr/share/terminfo/l" ] && cp /usr/share/terminfo/l/linux /usr/share/terminfo/l/ 2>/dev/null

  . /etc/os-release

  if [[ "$ID" == "ubuntu" ]]; then
    # xrdp/XFCE is for REMOTE sessions only; the local login screen is set by _dm_apply_policy.
    _dm_record_original
    clear_apt_locks
    export DEBIAN_FRONTEND=noninteractive

    # General system update. Kernel NOT excluded here -- DKMS/headers resolve against $(uname -r) anyway.
    echo "Running general system update..."
    apt-get update -y
    apt-get upgrade -y
    apt-get dist-upgrade -y

    install_apt_packages "curl" "net-tools" "ipmitool" "haveged" "rng-tools-debian"
    # Trailing '-' keeps light-locker out: xfce4-session Recommends it, and it Depends on lightdm.
    apt-get install -y xfce4 light-locker- || log_failure "Package 'xfce4' failed to install."
    install_apt_packages "xfce4-goodies" "xrdp" "xorgxrdp" "dbus-x11" "xfce4-screensaver"

    # xfce4-screensaver and light-locker both try to manage XFCE screen locking -- remove one.
    if dpkg -s light-locker >/dev/null 2>&1; then
      apt-get remove --purge -y light-locker || log_failure "Failed to remove light-locker"
    fi

    ln -s /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5 2>/dev/null
    ln -s /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5 2>/dev/null

    if [ ! -f /etc/xrdp/startwm.sh ]; then
      mkdir -p /etc/xrdp
      echo -e "#!/bin/sh\nunset DBUS_SESSION_BUS_ADDRESS\nunset XDG_RUNTIME_DIR\nexec startxfce4" > /etc/xrdp/startwm.sh
      chmod +x /etc/xrdp/startwm.sh
    fi
    systemctl restart xrdp
    systemctl enable xrdp
    _dm_apply_policy

    systemctl disable unattended-upgrades
    apt-get purge -y unattended-upgrades
    systemctl daemon-reload
    snap disconnect firefox:host-hunspell || true
  fi

  # Must run before IPMI setup below, so ipmitool is installed by the time it's used.
  if [[ "$ID" =~ rocky|rhel ]]; then
    # Rocky/RHEL 8 calls this repo powertools; 9.x/10.x renamed it crb. The wrong name fails outright.
    if [[ "${VERSION_ID%%.*}" == "8" ]]; then
      dnf config-manager --set-enabled powertools
    else
      dnf config-manager --set-enabled crb
    fi
    install_dnf_packages "epel-release"

    # Kernel excluded from the update -- keeps it from outrunning what the NVIDIA driver supports.
    echo "Running general system update (kernel excluded)..."
    dnf update -y --exclude=kernel*

    install_dnf_packages "curl" "net-tools" "ipmitool" "gcc-gfortran" "tcsh" "lynx" "fio" "git"

    # "Server with GUI" is the verified group name. The group is installed either way so the
    # desktop is available on demand; only the DEFAULT boot target follows the system type.
    dnf groupinstall -y "Server with GUI" || log_failure "Desktop environment group install failed -- GUI may be unavailable"
    [ -z "$SYSTEM_TYPE" ] && [ -t 0 ] && _confirm_system_type
    _apply_default_boot_target
    _apply_display_kernel_params
    if ! dnf list --available xrdp &>/dev/null; then
      echo -e "${TXT_YLW}NOTE: xrdp is not currently packaged in EPEL for this RHEL/Rocky version -- remote desktop access isn't available out of the box (local/physical-console GUI still works).${RESET}"
    fi
  fi

  echo "Setting up IPMI 'console' User..."
  modprobe ipmi_devintf 2>/dev/null; modprobe ipmi_si 2>/dev/null
  if ! ipmitool user list 1 | grep -q -w "console"; then
    ipmitool user set name 3 "console"
    ipmitool user set password 3 "Password@123"
    ipmitool user enable 3
    ipmitool channel setaccess 1 3 link=on ipmi=on callin=on privilege=4
  fi

  echo "Moving Toolkit to $TARGET_DIR..."
  # REAL_USER/REAL_HOME already resolved globally at script start.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  if [[ "$(basename "$SCRIPT_DIR")" == "POCtoolkit" ]]; then SOURCE_DIR="$SCRIPT_DIR"
  elif [ -d "$REAL_HOME/POCtoolkit" ]; then SOURCE_DIR="$REAL_HOME/POCtoolkit"
  else SOURCE_DIR="$SCRIPT_DIR"; fi

  if [[ "$SOURCE_DIR" == "$TARGET_DIR" ]]; then
    echo "Toolkit in place."
  elif [[ "$SOURCE_DIR" == "$REAL_HOME" ]]; then
    echo "WARNING: Script is in root of home. Copying safely."
    mkdir -p "$TARGET_DIR"
    cp -r "$SOURCE_DIR/"* "$TARGET_DIR/" 2>/dev/null
  else
    rm -rf "$TARGET_DIR"
    mkdir -p "$(dirname "$TARGET_DIR")"
    mv "$SOURCE_DIR" "$TARGET_DIR"
  fi
  chown -R "$REAL_USER:$REAL_USER" "$TARGET_DIR"
  chmod -R 755 "$TARGET_DIR"

  # Storage configuration is collected up front by _wizard_collect_answers now -- nothing to ask here.
  echo "Preparing Network Reset & Reboot..."
  touch "$PREREQ_MARKER"

  # netplan is Ubuntu-only; Rocky/RHEL already runs NetworkManager with DHCP by default.
  if [[ "$ID" == "ubuntu" ]]; then
    mkdir -p /etc/netplan
    cat <<EOF > /etc/netplan/99-exxact-fix.yaml
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      critical: true
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      critical: true
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
EOF
    chmod 600 /etc/netplan/99-exxact-fix.yaml
  fi
  systemctl enable NetworkManager

  # Skip the "wait for network to come online" boot job. On multi-NIC boxes (common on our builds)
  # systemd holds network-online.target until EVERY link is up or times out, adding 30-120s to every
  # boot for links that may never carry traffic. Masking both renderers' wait units (only the active
  # one exists; the other no-ops) drops that delay -- DHCP still runs, nothing here needs to block on it.
  for _wait_unit in systemd-networkd-wait-online.service NetworkManager-wait-online.service; do
    systemctl disable "$_wait_unit" >/dev/null 2>&1
    systemctl mask "$_wait_unit" >/dev/null 2>&1
  done
  echo "[OK] Disabled network-wait-online boot job (faster boot; DHCP unaffected)."

  # Wizard hand-off: save state and register the boot-resume unit before rebooting. No-op otherwise.
  WIZARD_PHASE="PREREQ_DONE"
  _wizard_save_state
  _register_wizard_resume_unit

  echo -e "${BG_RED} WARNING: SYSTEM WILL REBOOT AUTOMATICALLY ${RESET}"
  echo "1. Applying Network Settings (SSH will drop)"
  echo "2. Rebooting System"
  echo "Logs are being written to: $CURRENT_LOG_FILE"

  (
    sleep 2
    if [[ "$ID" == "ubuntu" ]]; then netplan apply; fi
    sleep 10
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    sleep 5
    reboot
  ) >> "$CURRENT_LOG_FILE" 2>&1 & disown

  exit 0
}

# --- 2. BASE POST INSTALL (from poctoolkitWIP3.sh) ---
base_install() {
  check_prereqs || return
  write_header "Base Validation Tools Install..."
  ERROR_LOG=()
  sleep 1

  . /etc/os-release
  case "$ID$VERSION_ID" in
  rocky*|rhel*|almalinux*)
    # Verified against Rocky 10 repos; nonexistent legacy packages are dropped, not renamed.
    PACKAGES=(
      "createrepo" "dkms" "dmidecode" "dnf-plugins-core" "edac-ctl"
      "edac-util" "elfutils-libelf-devel" "epel-release" "fio"
      "freeglut-devel.x86_64" "freeglut.x86_64" "fuse-libs" "gcc-gfortran"
      "gdisk" "git" "hwloc" "ipmitool" "kernel-devel-$(uname -r)"
      "kernel-modules-extra" "kernel-rpm-macros" "alsa-lib"
      "libdrm-devel.x86_64" "libnsl" "libquadmath" "libvirt-client"
      "libXdamage-devel.x86_64" "libXfixes-devel.x86_64" "libXi-devel.x86_64"
      "libXxf86vm-devel.x86_64" "lm_sensors" "lynx" "memtester"
      "mesa-libGL-devel.x86_64" "mesa-libGLU-devel.x86_64"
      "ncurses-compat-libs" "numactl" "perl-sigtrap" "python3-devel"
      "rasdaemon" "sshpass" "stress-ng" "stressapptest" "tcl" "tcsh" "tk" "tmux" "zip"
    )
    install_dnf_packages "${PACKAGES[@]}"
    systemctl enable rasdaemon --now
    systemctl stop libvirtd.service 2>/dev/null || true
    systemctl disable libvirtd.service 2>/dev/null || true
    ;;
  ubuntu22.04|ubuntu24.04|ubuntu26.04)
    PACKAGES=(
      "build-essential" "curl" "dkms" "dmidecode" "ethtool"
      "fio" "freeglut3-dev" "gfortran" "git" "hdparm" "hwloc" "ipmitool"
      "libgles2" "libgles2-mesa-dev" "libxi-dev" "libxmu-dev"
      "linux-headers-$(uname -r)" "lm-sensors" "lynx" "mbw" "memtester" "net-tools"
      "numactl" "rasdaemon" "software-properties-common" "sshpass" "stress-ng"
      "stressapptest" "tmux" "ubuntu-desktop" "xrdp" "zip"
    )
    # libasound2 became libasound2t64 in 24.04's time_t transition; 22.04 needs the old name.
    if [[ "$VERSION_ID" == "22.04" ]]; then
      PACKAGES+=("libasound2")
    else
      PACKAGES+=("libasound2t64")
    fi
    _dm_record_original
    install_apt_packages "${PACKAGES[@]}"
    systemctl enable rasdaemon --now
    systemctl enable xrdp --now
    # ubuntu-desktop brings gdm3; a box an older build already switched to lightdm is repaired here too.
    _dm_apply_policy
    [ -z "$SYSTEM_TYPE" ] && [ -t 0 ] && _confirm_system_type
    _apply_default_boot_target
    _apply_display_kernel_params
    update-initramfs -u
    ;;
  *)
    log_failure "Base Post Install: unsupported OS '$ID $VERSION_ID' -- NO packages were installed."
    echo -e "${TXT_RED}[ERROR] Unsupported OS '$ID $VERSION_ID'. Nothing was installed.${RESET}"
    echo "        Supported: Rocky/RHEL/AlmaLinux 8-10, Ubuntu 22.04/24.04/26.04."
    ;;
  esac

  test_result=$(ipmitool user test 3 16 Password@123)
  echo "#=======================================================================================#"
  echo "IPMI CONSOLE USER TEST"
  echo "#=======================================================================================#"
  echo "Testing IPMI Credentials: $test_result"

  print_error_summary
  pause
}

# --- GPU driver disposition: never blindly install a driver over a working one (see 2026-09-18 incident). ---

# Running driver version via nvidia-smi; empty if no functional driver.
_gpu_running_driver_version() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]'
}

# How the current driver got here: run | pkg | none. The .run installer creates /usr/bin/nvidia-uninstall
# and removes it on uninstall, so it is the reliable live marker -- even when the .run registered with DKMS,
# which makes it otherwise look package-managed (seen 2026-09-18). /var/log/nvidia-installer.log persists
# forever and is NOT a reliable signal on its own. Check .run FIRST: a .run install also loads a module.
_gpu_driver_install_method() {
  [ -e /usr/bin/nvidia-uninstall ] && { echo run; return; }
  [ -n "$(_gpu_running_driver_version 2>/dev/null)" ] && { echo pkg; return; }
  echo none
}

# True on NVSwitch systems, where Fabric Manager is mandatory -- CUDA won't initialize without it. Three signals,
# the first two readable before any driver exists (per NVIDIA's Fabric Manager User Guide):
#   1. HGX A100/H100/H200: NVSwitches are PCIe devices -- NVIDIA vendor, bridge class 0680.
#   2. HGX B100/B200/B300: NVSwitches are NOT on PCIe; the host sees ConnectX-7 bridge functions whose VPD
#      carries SMDL=SW_MNG. Regular CX7 NICs lack it, so a network card alone never trips this.
#   3. Driver already loaded: nvidia-smi reports a Fabric state other than N/A.
_gpu_needs_fabricmanager() {
  lspci -nn -d 10de: 2>/dev/null | grep -qiE 'nvswitch|\[0680\]' && return 0
  local d
  for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "0x15b3" ] || continue
    grep -qa 'SW_MNG' "$d/vpd" 2>/dev/null && return 0
  done
  local fab
  fab=$(nvidia-smi -q 2>/dev/null | awk '/^ *Fabric *$/{f=1; next} f && /State/{print $NF; exit}')
  [ -n "$fab" ] && [ "$fab" != "N/A" ]
}

# Newest driver package for this GPU: highest -open branch. Not -server: that lineup lags (610 has no -server
# build), which is what pinned installs at 595. ubuntu-drivers is hardware-aware -- a pre-Turing GPU gets no
# -open offer and falls back to proprietary. NVSwitch boxes stop at the newest branch with a fabricmanager-N.
_gpu_target_driver_pkg() {
  local cands="" variant="" b fm
  command -v ubuntu-drivers >/dev/null 2>&1 && \
    cands=$(ubuntu-drivers list 2>/dev/null | grep -oE 'nvidia-driver-[0-9]+(-server)?(-open)?' | grep -v -- '-server')
  [ -z "$cands" ] && \
    cands=$(apt-cache search -n 'nvidia-driver-' 2>/dev/null | awk '{print $1}' | grep -E '^nvidia-driver-[0-9]+(-open)?$')
  [ -z "$cands" ] && return 0
  if echo "$cands" | grep -q -- '-open$'; then
    variant="-open"
    cands=$(echo "$cands" | grep -- '-open$')
  fi
  for b in $(echo "$cands" | grep -oE '[0-9]+' | sort -rnu); do
    if _gpu_needs_fabricmanager; then
      fm=$(apt-cache policy "nvidia-fabricmanager-$b" 2>/dev/null | awk '/Candidate:/{print $2}')
      if [ -z "$fm" ] || [ "$fm" = "(none)" ]; then
        vlog "GPU DRIVER: NVSwitch present and no nvidia-fabricmanager-$b -- not targeting branch $b." >&2
        continue
      fi
    fi
    echo "nvidia-driver-${b}${variant}"
    return 0
  done
}

# Major number of _gpu_target_driver_pkg; empty if undeterminable.
_gpu_target_driver_branch() { _gpu_target_driver_pkg | grep -oE '[0-9]+' | head -n1; }

# Policy verdict: INSTALL (bare GPU) | SKIP (pkg + branch matches/none newer) | OVERRIDE (.run) | ASK (pkg, differs).
_gpu_driver_disposition() {
  local method running target
  method=$(_gpu_driver_install_method)
  case "$method" in none) echo INSTALL; return ;; run) echo OVERRIDE; return ;; esac
  running=$(_gpu_running_driver_version); running=${running%%.*}
  target=$(_gpu_target_driver_branch)
  # No determinable target, or same branch already present -> keep the working driver.
  if [ -z "$target" ] || [ "$running" = "$target" ]; then echo SKIP; else echo ASK; fi
}

# Installs the target package (newest -open), or ubuntu-drivers' own pick when no target is determinable.
_gpu_install_packaged_driver() {
  local pkg; pkg=$(_gpu_target_driver_pkg)
  if [ -n "$pkg" ]; then
    vlog "GPU DRIVER: installing $pkg."
    install_apt_packages "$pkg"
  elif command -v ubuntu-drivers >/dev/null 2>&1; then
    # No --gpgpu: that flag selects the lagging -server lineup this function deliberately avoids.
    vlog "GPU DRIVER: no target package determinable -- using 'ubuntu-drivers install'."
    ubuntu-drivers install >> "$CURRENT_LOG_FILE" 2>&1 || log_failure "ubuntu-drivers install failed."
  else
    log_failure "GPU DRIVER: no target branch and ubuntu-drivers unavailable -- no driver installed."
  fi
}

# Purges package-managed NVIDIA driver packages so a chosen replacement installs without a DKMS version clash.
_gpu_purge_packaged_driver() {
  local pkgs
  # Every flavor (-server, -open, plain): a box pre-imaged with 595-open was invisible to the old -server-only match.
  mapfile -t pkgs < <(dpkg -l 2>/dev/null | awk '/^ii/ && ($2 ~ /^nvidia-(driver|dkms|kernel-common|kernel-source|compute-utils|utils)-[0-9]+(-server)?(-open)?$/){print $2}')
  if [ "${#pkgs[@]}" -gt 0 ]; then
    vlog "GPU DRIVER: purging existing packaged driver before replacement: ${pkgs[*]}"
    apt-get -y remove --purge "${pkgs[@]}" >> "$CURRENT_LOG_FILE" 2>&1
    apt-get -y autoremove >> "$CURRENT_LOG_FILE" 2>&1
  fi
}

# Removes a .run-installed driver via its own uninstaller before a packaged install.
_gpu_uninstall_runfile_driver() {
  [ -x /usr/bin/nvidia-uninstall ] || return 0
  vlog "GPU DRIVER: running nvidia-uninstall to remove the .run driver."
  /usr/bin/nvidia-uninstall --silent >> "$CURRENT_LOG_FILE" 2>&1 || log_failure "nvidia-uninstall returned non-zero."
}

# Applies the driver disposition on Ubuntu. The override/keep choice is made ahead of time at wizard
# collection (GPU_DRIVER_OVERRIDE); this only acts on it. Direct menu use with no stored decision
# falls back to an interactive prompt, and a truly unattended run with no decision keeps the working driver.
_gpu_handle_driver_ubuntu() {
  install_apt_packages "ubuntu-drivers-common" "pkg-config" "libglvnd-dev"
  local disp run_ver tgt
  disp=$(_gpu_driver_disposition); run_ver=$(_gpu_running_driver_version); tgt=$(_gpu_target_driver_branch)
  case "$disp" in
    SKIP)
      vlog "GPU DRIVER: keeping existing package-managed driver ${run_ver} (target branch ${tgt:-none} matches or is not newer)."
      echo -e "${TXT_GRN}Existing NVIDIA driver ${run_ver} is present and package-managed -- keeping it.${RESET}"
      ;;
    INSTALL)
      vlog "GPU DRIVER: no functional driver present -- installing packaged driver ${tgt:-recommended}."
      _gpu_install_packaged_driver
      ;;
    OVERRIDE|ASK)
      # A .run (OVERRIDE) or a differing package driver (ASK) -- both are a keep-vs-replace decision.
      local decision="$GPU_DRIVER_OVERRIDE"
      if [ -z "$decision" ]; then
        if [ -t 0 ]; then
          # Direct menu run (no wizard collection) -- ask now.
          if [ "$disp" = "OVERRIDE" ]; then
            echo -e "${TXT_YLW}A .run-installed NVIDIA driver (${run_ver}) was detected.${RESET}"
            echo "Overriding it with a native (package-managed) install is highly recommended;"
            echo "keeping it may cause unforeseen issues with later steps."
            local c; _yes_no c "Override with a native install? (y = override [recommended] / n = keep): "
          else
            echo "Existing driver ${run_ver} differs from target branch ${tgt:-unknown}."
            local c; _yes_no c "Replace it with branch ${tgt:-latest}-open? (y = replace / n = keep): "
          fi
          [ "$c" = "y" ] && decision="override" || decision="keep"
        else
          # Unattended with no stored decision -- never downgrade/replace silently (the 2026-09-18 break).
          decision="keep"
          vlog "GPU DRIVER: ${disp} but no stored decision and no TTY -- KEEPING existing ${run_ver} (safe default)."
        fi
      fi
      if [ "$decision" = "override" ]; then
        vlog "GPU DRIVER: overriding existing ${run_ver} (${disp}) with packaged branch ${tgt:-recommended}."
        if [ "$disp" = "OVERRIDE" ]; then _gpu_uninstall_runfile_driver; else _gpu_purge_packaged_driver; fi
        _gpu_install_packaged_driver
      else
        vlog "GPU DRIVER: keeping existing ${run_ver} per decision (${disp})."
        echo -e "${TXT_GRN}Keeping existing driver ${run_ver}.${RESET}"
        [ "$disp" = "OVERRIDE" ] && echo -e "${TXT_YLW}NOTE: a .run driver was kept -- later steps may fail in ways the script cannot auto-recover.${RESET}"
      fi
      ;;
  esac
}

# Adds NVIDIA's CUDA apt repo for Ubuntu when cuda-toolkit isn't already resolvable, via the cuda-keyring deb.
_ensure_cuda_repo_ubuntu() {
  local cand; cand=$(apt-cache policy cuda-toolkit 2>/dev/null | awk '/Candidate:/{print $2}')
  [ -n "$cand" ] && [ "$cand" != "(none)" ] && return 0
  local tok arch kr="cuda-keyring_1.1-1_all.deb"
  tok=$(_cuda_repo_os_token); arch=$(_cuda_repo_arch_path)
  ( cd /tmp && curl -fsSL -O "https://developer.download.nvidia.com/compute/cuda/repos/${tok}/${arch}/${kr}" \
      && dpkg -i "$kr" ) >> "$CURRENT_LOG_FILE" 2>&1 || log_failure "CUDA keyring/repo add failed for Ubuntu."
  apt-get update -y >> "$CURRENT_LOG_FILE" 2>&1
}

# CUDA toolkit (nvcc + cuBLAS runtime) for x86_64 Ubuntu -- gpu_burn/matrixMul need it and the Ubuntu path
# never installed it, so gpu_burn failed at runtime (libcublas not found). Toolkit ONLY, never the driver.
_install_cuda_toolkit_ubuntu() {
  [ "$ARCH" = "aarch64" ] && return 0   # aarch64 handled per-tool in install_gpuburn
  _ensure_cuda_repo_ubuntu
  install_apt_packages "cuda-toolkit"
  # cuda-toolkit is "newest"; with a driver already loaded, also install the toolkit that driver can run.
  _cuda_root_for_driver >/dev/null
  # Put CUDA libs on the loader path so runtime binaries find libcublas without LD_LIBRARY_PATH.
  if [ -d /usr/local/cuda/lib64 ]; then
    echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf
    ldconfig
  fi
}

# --- 3. GPU POST INSTALL (driver + CUDA toolkit) ---
gpu_install() {
  check_prereqs || return
  base_install
  write_header "Nvidia Driver Installation..."

  . /etc/os-release
  case "$ID$VERSION_ID" in
  ubuntu22.04|ubuntu24.04|ubuntu26.04)
    install -Dm644 /dev/null /etc/modprobe.d/blacklist-nouveau.conf
    { echo "blacklist nouveau"; echo "options nouveau modeset=0"; } > /etc/modprobe.d/blacklist-nouveau.conf
    update-initramfs -u

    if command -v nvidia-smi >/dev/null 2>&1; then
      GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
    else
      GPU_NAME="$(lspci -nn | grep -iE 'VGA|3D' | grep -i nvidia | head -n1)"
    fi
    echo "GPU Detected: $GPU_NAME"

    if [ "$ARCH" = "aarch64" ]; then
      # Driver install unverified on ARM, and Grace-class systems ship with drivers pre-installed.
      vlog "GPU INSTALL: aarch64 detected -- skipping driver install (Grace ships pre-installed). Verify 'nvidia-smi'; install manually via NVIDIA's sbsa instructions if missing."
    else
      # Disposition-driven: keep a working driver, override a .run, ask before replacing a differing one.
      _gpu_handle_driver_ubuntu
    fi
    # CUDA toolkit so gpu_burn/matrixMul have nvcc + cuBLAS. Toolkit only -- pulls no driver.
    _install_cuda_toolkit_ubuntu
    # NOTE: NVreg_EnableGSP=0 deliberately NOT set here -- Hopper/Blackwell (H200 etc.) REQUIRE GSP; forcing
    # it off breaks the driver. The old unconditional write was a latent bug on modern datacenter GPUs.
    _apply_display_kernel_params
    update-initramfs -u
    ;;
  rocky*|rhel*|almalinux*)
    # grubby is the reliable nouveau blacklist on BLS-based Rocky/RHEL 8+; modprobe.d alone loads too late.
    grubby --update-kernel=ALL --args="nouveau.modeset=0 rd.driver.blacklist=nouveau"

    if command -v nvidia-smi >/dev/null 2>&1; then
      GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
    else
      GPU_NAME="$(lspci -nn | grep -iE 'VGA|3D' | grep -i nvidia | head -n1)"
    fi
    echo "GPU Detected: $GPU_NAME"

    dnf config-manager --add-repo "https://developer.download.nvidia.com/compute/cuda/repos/$(_cuda_repo_os_token)/$(_cuda_repo_arch_path)/cuda-$(_cuda_repo_os_token).repo"
    dnf clean expire-cache

    # nvidia-open covers Turing and newer; cuda-drivers (proprietary) is the pre-Turing fallback.
    if ! install_dnf_packages "nvidia-open"; then
      log_failure "nvidia-open failed, falling back to cuda-drivers (proprietary)"
      install_dnf_packages "cuda-drivers"
    fi

    # CUDA Toolkit -- gpu-burn fails without cublas_v2.h. Verified: resolves to 13.3.1, builds clean.
    install_dnf_packages "cuda-toolkit"

    # Driver 615.x logs "unknown parameter 'NVreg_EnableGSP' ignored" -- kept only for the older
    # proprietary fallback, where it is still a real parameter.
    if ! rpm -q nvidia-open >/dev/null 2>&1; then
      echo "options nvidia NVreg_EnableGSP=0" > /etc/modprobe.d/nvidia-gsp.conf
    else
      rm -f /etc/modprobe.d/nvidia-gsp.conf
    fi
    _apply_display_kernel_params
    dracut -f
    echo -e "${TXT_YLW}NOTE: a reboot is required for the nouveau blacklist / new driver to take effect.${RESET}"
    ;;
  *)
    log_failure "GPU Post Install: unsupported OS '$ID $VERSION_ID' -- NO driver or CUDA toolkit was installed."
    echo -e "${TXT_RED}[ERROR] GPU Post Install: unsupported OS '$ID $VERSION_ID'. NO driver or CUDA toolkit was installed.${RESET}"
    ;;
  esac

  print_error_summary
  pause
}

# --- 4. MELLANOX INSTALL ---

# True when a Mellanox/ConnectX adapter is on the PCI bus. Vendor ID 15b3 catches rebranded OEM cards.
_mellanox_present() {
  lspci -nn 2>/dev/null | grep -qiE 'mellanox|connectx|\[15b3:' && return 0
  lspci 2>/dev/null | grep -qi 'mellanox\|connectx'
}

# MFT (mst/mstflint/mlxconfig/mlxfwmanager). OFED bundles it, but plain distro driver installs don't.
_mft_installed() { command -v mst &>/dev/null && command -v mlxconfig &>/dev/null; }

_mft_install() {
  _mft_installed && { echo "MFT already installed ($(mst version 2>/dev/null | head -1))."; return 0; }
  . /etc/os-release
  echo "Installing Mellanox Firmware Tools (MFT)..."
  local tgz
  # A bundled MFT tarball is the only version-pinned source; distro packages are whatever the repo carries.
  tgz=$(ls -1 "$TARGET_DIR/pkg/mft-"*.tgz 2>/dev/null | sort -V | tail -1)
  if [ -n "$tgz" ]; then
    local work; work=$(mktemp -d)
    if tar xzf "$tgz" -C "$work" && (cd "$work"/mft-*/ && ./install.sh); then
      rm -rf "$work"
      _mft_installed && { mst start 2>/dev/null; return 0; }
    fi
    rm -rf "$work"
    log_failure "MFT: bundled tarball $tgz failed to install -- falling back to distro packages."
  fi
  case "$ID$VERSION_ID" in
    rocky*|rhel*|almalinux*) install_dnf_packages "mstflint" ;;
    ubuntu22*|ubuntu24*|ubuntu26*) install_apt_packages "mstflint" ;;
    *) log_failure "MFT: unsupported OS '$ID $VERSION_ID' -- MFT was NOT installed." ; return 1 ;;
  esac
  if _mft_installed; then
    mst start 2>/dev/null; return 0
  elif command -v mstflint &>/dev/null; then
    # mstflint alone gives firmware query; mst/mlxconfig need the real MFT package from NVIDIA.
    log_failure "MFT: only mstflint installed (no mst/mlxconfig). Place mft-<ver>.tgz in $TARGET_DIR/pkg for the full toolset."
    return 0
  fi
  log_failure "MFT: installation failed -- mst/mlxconfig/mstflint all absent."
  return 1
}

mlnx_install() {
  . /etc/os-release
  if ! _mellanox_present; then
    echo "No Mellanox hardware found. Skipping."
    pause; return
  fi
  case "$ID$VERSION_ID" in
  rocky*|rhel*|almalinux*)
    # OFED_VER_ROCKY pins one Rocky 9.4 tarball; cross-version compatibility is unverified.
    if [ -f "$TARGET_DIR/pkg/MLNX_OFED_LINUX-${OFED_VER_ROCKY}.tgz" ]; then
      cp "$TARGET_DIR/pkg/MLNX_OFED_LINUX-${OFED_VER_ROCKY}.tgz" .
      tar xvzf "MLNX_OFED_LINUX-${OFED_VER_ROCKY}.tgz"
      (cd "MLNX_OFED_LINUX-${OFED_VER_ROCKY}" && ./mlnxofedinstall --add-kernel-support)
      dracut -f
    else
      log_failure "Mellanox OFED TGZ not found for Rocky ($TARGET_DIR/pkg/MLNX_OFED_LINUX-${OFED_VER_ROCKY}.tgz)"
    fi
    ;;
  ubuntu24.04|ubuntu22*|ubuntu26*)
    if [ -f "$TARGET_DIR/pkg/MLNX_OFED_LINUX-${OFED_VER_UBUNTU}.tgz" ]; then
      cp "$TARGET_DIR/pkg/MLNX_OFED_LINUX-${OFED_VER_UBUNTU}.tgz" .
      tar xvzf "MLNX_OFED_LINUX-${OFED_VER_UBUNTU}.tgz"
      (cd "MLNX_OFED_LINUX-${OFED_VER_UBUNTU}" && ./mlnxofedinstall)
    else
      log_failure "Mellanox OFED TGZ not found for Ubuntu ($TARGET_DIR/pkg/MLNX_OFED_LINUX-${OFED_VER_UBUNTU}.tgz)"
    fi
    ;;
  *)
    log_failure "Mellanox OFED: unsupported OS '$ID $VERSION_ID' -- OFED was NOT installed."
    echo -e "${TXT_RED}[ERROR] Mellanox OFED: unsupported OS '$ID $VERSION_ID'. OFED was NOT installed.${RESET}"
    ;;
  esac
  _mft_install
  echo ""
  echo "Mellanox tooling now present:"
  for t in ibstat ibstatus mst mstflint mlxconfig mlxfwmanager; do
    printf '  %-14s %s\n' "$t:" "$(command -v "$t" 2>/dev/null || echo 'NOT FOUND')"
  done
  pause
}

# --- 5. FABRIC MANAGER: only start it where NVLink exists, or it sits permanently FAILED. ---
_gpu_has_nvlink() {
  local out; out=$(nvidia-smi nvlink -s 2>/dev/null)
  [ -n "$out" ] && echo "$out" | grep -qvi "does not have or support"
}

fabric_install() {
  . /etc/os-release
  case "$ID$VERSION_ID" in
  rocky*|rhel*|almalinux*)
    dnf config-manager --add-repo "https://developer.download.nvidia.com/compute/cuda/repos/$(_cuda_repo_os_token)/$(_cuda_repo_arch_path)/cuda-$(_cuda_repo_os_token).repo"
    dnf clean expire-cache
    install_dnf_packages "nvidia-fabric-manager" "datacenter-gpu-manager-4-cuda13"
    # Rocky's CUDA repo has one rolling FabricManager build, so verify the version after install.
    FM_VER=$(rpm -q --qf '%{VERSION}\n' nvidia-fabric-manager 2>/dev/null | head -1 | cut -d. -f1)
    DRV_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | cut -d. -f1)
    if [ -n "$FM_VER" ] && [ -n "$DRV_VER" ] && [ "$FM_VER" != "$DRV_VER" ]; then
      log_failure "nvidia-fabric-manager ($FM_VER.x) does not match the running driver ($DRV_VER.x) -- Rocky's CUDA repo has no per-branch-pinned FabricManager package to request instead; verify manually before relying on NVLink fabric."
    fi
    if _gpu_has_nvlink; then
      systemctl enable --now nvidia-fabricmanager
    else
      echo "No NVLink-capable GPU detected -- nvidia-fabricmanager installed but not started (nothing for it to manage on this hardware)."
    fi
    systemctl enable --now nvidia-dcgm
    dcgmi discovery -l
    ;;
  ubuntu22.04|ubuntu24.04|ubuntu26.04)
    DRV_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | cut -d. -f1)
    if [ -z "$DRV_VER" ]; then
      log_failure "Could not detect running NVIDIA driver. FM install might mismatch."
      install_apt_packages "nvidia-fabricmanager-550" "datacenter-gpu-manager"
    else
      echo "Detected Driver Major Version: $DRV_VER"
      install_apt_packages "nvidia-fabricmanager-${DRV_VER}" "datacenter-gpu-manager"
    fi
    if _gpu_has_nvlink; then
      systemctl enable --now nvidia-fabricmanager
    else
      echo "No NVLink-capable GPU detected -- nvidia-fabricmanager installed but not started (nothing for it to manage on this hardware)."
    fi
    systemctl enable --now nvidia-dcgm
    dcgmi health --set pmi
    dcgmi discovery -l
    ;;
  *)
    log_failure "Fabric Manager: unsupported OS '$ID $VERSION_ID' -- FabricManager was NOT installed."
    echo -e "${TXT_RED}[ERROR] Fabric Manager: unsupported OS '$ID $VERSION_ID'. FabricManager was NOT installed.${RESET}"
    ;;
  esac
  print_error_summary
  pause
}

# --- 6. DCGM GPU HEALTH CHECK: one function replacing ~6 near-duplicate copies. ---
dcgm_health_check() {
  _ensure_system_sn_confirmed
  write_header "DCGM GPU Health Check"

  # Diag level is prompted, not hardcoded: level 3+ triggers a real fatal PCIe fault on some hardware.
  local diag_level
  if [ -n "$DCGM_LEVEL_OVERRIDE" ]; then
    diag_level="$DCGM_LEVEL_OVERRIDE"
    echo "DCGM diagnostic level: $diag_level (from --dcgm= override, not prompting)"
  else
    read -rp "DCGM diagnostic level to run [1-4, default 4]: " diag_level
  fi

  _dcgm_run "$diag_level"
  print_error_summary
  pause
}

# Core DCGM logic, split out so it can also run non-interactively after the concurrent stress test.
# Installs DCGM (datacenter-gpu-manager) from NVIDIA's CUDA repo when dcgmi is absent, then enables
# the nvidia-dcgm service. Idempotent -- a no-op if dcgmi is already present. Returns 1 only on an OS
# with no install path. Extracted from _dcgm_run so a standalone install (menu) can reuse it verbatim.
_dcgm_install() {
  . /etc/os-release
  if command -v dcgmi >/dev/null 2>&1; then
    echo "[OK] DCGM already installed ($(command -v dcgmi)) -- skipping package install."
  else
    case "$ID$VERSION_ID" in
    rocky*|rhel*|almalinux*)
      dnf config-manager --add-repo "https://developer.download.nvidia.com/compute/cuda/repos/$(_cuda_repo_os_token)/$(_cuda_repo_arch_path)/cuda-$(_cuda_repo_os_token).repo"
      dnf clean expire-cache
      install_dnf_packages "datacenter-gpu-manager-4-cuda13"
      ;;
    ubuntu22.04|ubuntu24.04|ubuntu26.04)
      local distribution; distribution=$(echo "$ID$VERSION_ID" | sed -e 's/\.//g')
      wget -q "https://developer.download.nvidia.com/compute/cuda/repos/$distribution/$(_cuda_repo_arch_path)/cuda-keyring_1.1-1_all.deb"
      dpkg -i cuda-keyring_1.1-1_all.deb
      apt-get update
      install_apt_packages "datacenter-gpu-manager-4-cuda13"
      ;;
    *)
      log_failure "DCGM install: unsupported OS '$ID $VERSION_ID' -- DCGM is not installed and cannot be installed automatically on this OS."
      echo -e "${TXT_RED}[ERROR] DCGM install: unsupported OS '$ID $VERSION_ID'. DCGM is not installed and cannot be installed automatically on this OS.${RESET}"
      return 1
      ;;
    esac
  fi
  systemctl enable --now nvidia-dcgm
  return 0
}

# Standalone menu action: install DCGM only (no diagnostics), then report the installed version. This
# is the "Add standalone DCGMI Install option in post-install" IE request -- a post-install step that
# provisions the tool without committing to a multi-minute health check.
dcgm_install_only() {
  write_header "DCGMI Install (standalone)"
  ERROR_LOG=()
  if _dcgm_install; then
    if command -v dcgmi >/dev/null 2>&1; then
      echo -e "${TXT_GRN}[SUCCESS] DCGM installed: $(dcgmi --version 2>/dev/null | grep -m1 'version:' || echo 'version unknown')${RESET}"
      echo "          Run the DCGM GPU Health Check (main menu 8) when ready to validate."
    else
      echo -e "${TXT_RED}[ERROR] DCGM install ran but dcgmi is still not on PATH -- check $CURRENT_LOG_FILE.${RESET}"
    fi
  fi
}

# Runs dcgmi diag so it also works on non-homogenous GPU boxes. dcgmi requires every GPU in one diag
# run to be the same model; on a mixed system (e.g. an L40S alongside an A100) a single all-GPU run
# aborts with an incompatibility error. We group GPUs by model via nvidia-smi and run diag once per
# homogeneous group with -i <indices>. One model (or no nvidia-smi) falls through to a single run.
_dcgm_diag_dispatch() {
  local level="$1"; shift
  local extra=("$@")
  local idx name model rc=0
  declare -A _dcgm_group
  local _dcgm_order=()
  while IFS=',' read -r idx name; do
    idx="${idx//[[:space:]]/}"
    name="$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$idx" ] && continue
    [ -z "${_dcgm_group[$name]+x}" ] && _dcgm_order+=("$name")
    _dcgm_group[$name]="${_dcgm_group[$name]:+${_dcgm_group[$name]},}$idx"
  done < <(nvidia-smi --query-gpu=index,name --format=csv,noheader 2>/dev/null)

  if [ "${#_dcgm_order[@]}" -le 1 ]; then
    dcgmi diag -r "$level" "${extra[@]}"     # homogeneous (or list unavailable): one all-GPU run
    return $?
  fi

  echo "--- Non-homogenous GPU system: ${#_dcgm_order[@]} distinct models -- running DCGM diag per model group ---"
  for model in "${_dcgm_order[@]}"; do
    echo
    echo "=== DCGM diag: model '$model' (GPUs ${_dcgm_group[$model]}) ==="
    dcgmi diag -r "$level" -i "${_dcgm_group[$model]}" "${extra[@]}" || rc=1
  done
  return $rc
}

_dcgm_run() {
  local diag_level="${1:-4}"
  case "$diag_level" in
    1|2|3|4) ;;
    *) diag_level=4 ;;
  esac

  ERROR_LOG=()
  _dcgm_install
  dcgmi health --set pmi
  nvidia-smi -pm 1 >/dev/null 2>&1

  # Ensures $VAL_LOGDIR exists when _dcgm_run is reached standalone. Idempotent.
  _init_validation_paths
  local file="$VAL_LOGDIR/dcgm_healthcheck.log"

  {
    echo "#======================================================================#"
    echo "DCGM HEALTH CHECK VALIDATION REPORT -- $(date)"
    echo "#======================================================================#"
    echo
    echo "--- GPU Health Check ---"
    dcgmi health --check
    echo
    echo "--- GPU Discovery ---"
    dcgmi discovery -l
    echo
    # --nvbandwidth=0 disables the one plugin that triggers a real PCIe fault, recovering level-4 coverage.
    local dcgm_extra_params=()
    if [ "$DCGM_NVBANDWIDTH_DISABLE" = "1" ]; then
      dcgm_extra_params+=(-p "nvbandwidth.is_allowed=false")
      echo "--- nvbandwidth plugin disabled via --nvbandwidth=0 ---"
    fi
    echo "--- GPU Diagnostics (level ${diag_level}, this can take several minutes) ---"
    _dcgm_diag_dispatch "$diag_level" "${dcgm_extra_params[@]}"
  } | tee "$file"

  local dcgm_issues; dcgm_issues=$(grep -i "Fail\|Error" "$file")
  if [ -n "$dcgm_issues" ]; then
    log_failure "DCGM reported issues -- see $file"
    # RESULTS is only populated when validation paths are already initialized (via option 6).
    if [ "$VAL_INITIALIZED" -eq 1 ]; then
      vrecord "DCGM" "FAIL" "issues found -- see $file"
      vrecord_evidence "DCGM" "$(echo "$dcgm_issues" | head -10)"
    fi
    return 1
  else
    echo -e "${TXT_GRN}[SUCCESS] DCGM health check clean -- see $file${RESET}"
    [ "$VAL_INITIALIZED" -eq 1 ] && vrecord "DCGM" "PASS" "clean -- see $file"
    return 0
  fi
}

# --- STANDALONE SLURM INSTALL (single-node: controller + compute co-located) ---
# IE request: a one-shot "Automated Slurm Install for Rocky and Ubuntu" that leaves the box with a
# working single-node Slurm -- munge authenticated, slurmctld+slurmd running, `sinfo` showing the node
# idle. Not a multi-node cluster: controller and compute are the same host, which is what a QA/bring-up
# box needs. The node line in slurm.conf is generated from `slurmd -C`, so CPU/socket/memory always match.
slurm_install() {
  write_header "Slurm Install (single-node: controller + compute)"
  ERROR_LOG=()
  . /etc/os-release
  local node; node="$(hostname -s)"
  local conf="/etc/slurm/slurm.conf"
  local logdir="/var/log/slurm"
  local ctld_spool="/var/spool/slurmctld" slurmd_spool="/var/spool/slurmd"

  case "$ID" in
    rocky|rhel|almalinux)
      install_dnf_packages "epel-release"
      # CRB/PowerTools carries several Slurm runtime deps on EL -- enable whichever name this release uses.
      dnf config-manager --set-enabled crb >/dev/null 2>&1 \
        || dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
      install_dnf_packages "munge" "slurm" "slurm-slurmctld" "slurm-slurmd"
      ;;
    ubuntu)
      apt-get update
      install_apt_packages "munge" "slurm-wlm"     # slurm-wlm pulls both slurmctld and slurmd
      ;;
    *)
      log_failure "Slurm install: unsupported OS '$ID $VERSION_ID' -- nothing installed."
      echo -e "${TXT_RED}[ERROR] Slurm install: unsupported OS '$ID $VERSION_ID'.${RESET}"
      return 1
      ;;
  esac

  # --- munge auth key: generate once, lock perms, enable the daemon (slurmctld/slurmd depend on it). ---
  if [ ! -s /etc/munge/munge.key ]; then
    if command -v mungekey >/dev/null 2>&1; then
      mungekey --create --force >/dev/null 2>&1
    elif command -v create-munge-key >/dev/null 2>&1; then
      create-munge-key -f >/dev/null 2>&1
    else
      dd if=/dev/urandom of=/etc/munge/munge.key bs=1 count=1024 >/dev/null 2>&1
    fi
  fi
  chown munge:munge /etc/munge/munge.key 2>/dev/null
  chmod 400 /etc/munge/munge.key 2>/dev/null
  systemctl enable --now munge

  # --- State/log dirs Slurm needs, owned by the slurm service user. ---
  mkdir -p "$ctld_spool" "$slurmd_spool" "$logdir"
  chown -R slurm:slurm "$ctld_spool" "$logdir" 2>/dev/null

  # --- slurm.conf, generated only if absent so a hand-tuned config is never clobbered. ---
  mkdir -p /etc/slurm
  if [ -f "$conf" ]; then
    echo "[INFO] $conf already exists -- leaving it in place (not regenerating)."
  else
    # slurmd -C prints this box's real hardware as a NodeName= line -- authoritative CPU/socket/memory.
    local nodespec; nodespec="$(slurmd -C 2>/dev/null | grep '^NodeName=')"
    [ -z "$nodespec" ] && nodespec="NodeName=$node CPUs=1"
    nodespec="${nodespec%% UpTime=*}"     # drop slurmd -C's live UpTime field; it's not config
    cat > "$conf" <<EOF
# Minimal single-node Slurm config generated by exx-validation.sh on $(date).
# Controller and compute are this one host ($node). Edit for a real multi-node cluster.
ClusterName=exxact
SlurmctldHost=$node
AuthType=auth/munge
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
SchedulerType=sched/backfill
SelectType=select/cons_tres
SlurmUser=slurm
StateSaveLocation=$ctld_spool
SlurmdSpoolDir=$slurmd_spool
SlurmctldLogFile=$logdir/slurmctld.log
SlurmdLogFile=$logdir/slurmd.log
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
ReturnToService=2
$nodespec State=UNKNOWN
PartitionName=debug Nodes=ALL Default=YES MaxTime=INFINITE State=UP
EOF
    chown slurm:slurm "$conf" 2>/dev/null
    chmod 644 "$conf"
    echo "[OK] Wrote $conf ($nodespec)."
  fi

  systemctl enable --now slurmctld
  systemctl enable --now slurmd

  # --- Verify: sinfo should list the node; resume it in case the first-start race left it down. ---
  sleep 3
  scontrol update nodename="$node" state=resume 2>/dev/null || true
  echo "--- sinfo ---"
  if sinfo 2>&1; then
    echo -e "${TXT_GRN}[SUCCESS] Slurm single-node install complete -- 'sinfo' responded above.${RESET}"
    echo "          Test a job with:  srun -N1 hostname"
  else
    log_failure "Slurm install: sinfo did not respond -- check 'systemctl status slurmctld slurmd'."
    echo -e "${TXT_RED}[ERROR] Slurm install: sinfo did not respond. Check slurmctld/slurmd and $logdir.${RESET}"
    return 1
  fi
}

# --- 7. EMLI INSTALL ---
# One pass replacing the legacy ngc-EMLI.sh/ngc-DIY.sh -> ngc-preinstall.sh -> ngc-install.sh chain.
# Deliberately NOT carried over: host CUDA .run toolkit + cuDNN (gpu_install owns the toolkit), apt/dnf
# upgrade passes (bumped driver/kernel mid-provision), the archived nvidia-docker repo, history wipe.
EMLI_TARBALL="/data/software/docker/emli-latest.tar.gz"
EMLI_QUICKSTART="/data/software/docker/QuickStartGuide_Exxact_NGC_EMLI.pdf"
EMLI_IMAGE_DIR="/data/nfsshare/DockerImages"
EMLI_ANACONDA="Anaconda3-2024.10-1-Linux-x86_64.sh"
EMLI_STATE_DIR="/var/lib/exx-emli"
EMLI_ASSET_DIR="$TARGET_DIR/emli"
# Curated image set from the 2025-06-13 payload. The host-specific CUDA/RAPIDS images are added in _emli_os_images.
EMLI_IMAGES_COMMON=(
  "nvcr.io_nvidia_digits-21.09-tensorflow-py3.tar.gz"
  "label_studio_latest.tar.gz"
  "nvcr.io_nvidia_tensorflow_25.02-tf2-py3.tar.gz"
  "nvcr.io_nvidia_tensorflow_23.03-tf1-py3.tar.gz"
  "nvcr.io_nvidia_pytorch_25.03-py3.tar.gz"
  "nvcr.io_nvidia_mxnet_24.06-py3.tar.gz"
)
EMLI_CUDA_IMAGE_VER="12.9.0"

# Image tarball names for this host. No rocky10/ubuntu26.04 builds exist; the nearest older base runs fine.
_emli_os_images() {
  . /etc/os-release
  local v="$EMLI_CUDA_IMAGE_VER" tag rapids
  case "$ID$VERSION_ID" in
    ubuntu22.04) tag="ubuntu22.04"; rapids="ubuntu22.04" ;;
    ubuntu24.04|ubuntu26.04) tag="ubuntu24.04"; rapids="ubuntu22.04" ;;
    rocky8*|rhel8*|almalinux8*) v="12.8.1"; tag="rockylinux8"; rapids="rockylinux8" ;;
    rocky*|rhel*|almalinux*) tag="rockylinux9"; rapids="rockylinux8" ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${EMLI_IMAGES_COMMON[@]}" \
    "nvcr.io_nvidia_cuda_${v}-runtime-${tag}.tar.gz" \
    "nvcr.io_nvidia_cuda_${v}-devel-${tag}.tar.gz" \
    "nvcr.io_nvidia_rapidsai_23.06-cuda11.8-runtime-${rapids}-py3.10.tar.gz"
}

# Streams one QA-server file to stdout. Keepalives stop a multi-hour image transfer dying on an idle NAT.
_qa_stream_file() {
  sshpass -p "$QA_SSHPASS" ssh "${QA_SSH_OPTS[@]}" -o ServerAliveInterval=30 \
    "$QA_SERVER_USER@$QA_SERVER_IP" "cat '$1'"
}

_emli_result_set() {  # _emli_result_set <key> <value> -- tab-separated, one key per line
  mkdir -p "$EMLI_STATE_DIR"
  touch "$EMLI_STATE_DIR/result"
  sed -i "/^$1\t/d" "$EMLI_STATE_DIR/result"
  printf '%s\t%s\n' "$1" "$2" >> "$EMLI_STATE_DIR/result"
}

_emli_result_get() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$EMLI_STATE_DIR/result" 2>/dev/null; }

# Only the payload pieces still used: branding, customer toolkits, container launchers. No ngc-*.sh is run.
_emli_fetch_assets() {
  local tgz="$TARGET_DIR/emli-latest.tar.gz"
  mkdir -p "$TARGET_DIR"
  echo "Fetching EMLI assets from QA server..."
  if ! qa_scp_get "$EMLI_TARBALL" "$tgz"; then
    log_failure "EMLI: asset tarball fetch failed ($EMLI_TARBALL) -- branding/toolkits skipped"
    return 1
  fi
  rm -rf "$EMLI_ASSET_DIR"; mkdir -p "$EMLI_ASSET_DIR"
  if ! tar -xzf "$tgz" -C "$EMLI_ASSET_DIR" --strip-components=1 --wildcards \
        'emli/exxact_branding/deeplearning/*' 'emli/ngc/exx-*.sh' 'emli/ngc/start*.sh' \
        'emli/ngc/tensorflow_validation.sh' 'emli/ngc/tf_gpucount.py'; then
    log_failure "EMLI: asset tarball could not be extracted -- branding/toolkits skipped"
  fi
  rm -f "$tgz"
}

# Legacy preinstall's "well-known" list minus what base_install has. No-recommends: mdadm/smartmontools pull an MTA.
_emli_base_packages() {
  . /etc/os-release
  local p
  case "$ID" in
    ubuntu)
      apt-get update -y >/dev/null 2>&1
      for p in ca-certificates gnupg curl wget pv hwinfo smartmontools mdadm; do
        apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 || log_failure "EMLI: package '$p' failed to install."
      done
      ;;
    rocky|rhel|almalinux)
      install_dnf_packages ca-certificates gnupg2 curl wget pv hwinfo smartmontools mdadm dnf-plugins-core
      dnf groupinstall -y "Development Tools" || log_failure "EMLI: 'Development Tools' group failed to install."
      ;;
  esac
}

_emli_docker_install() {
  if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    echo "Docker already installed and running ($(docker --version 2>/dev/null))."
    return 0
  fi
  . /etc/os-release
  write_header "EMLI: Docker Engine"
  case "$ID" in
    ubuntu)
      local old
      # Distro docker/containerd packages conflict with docker-ce; Docker's install docs remove them first.
      old=$(dpkg-query -W -f='${Package} ${Status}\n' docker.io docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null \
            | awk '/install ok installed/{print $1}')
      # shellcheck disable=SC2086
      [ -n "$old" ] && apt-get -y remove $old
      # Checked first: a missing suite fails apt-get update, and install_apt_packages then rewrites resolv.conf.
      if curl -fsI "https://download.docker.com/linux/ubuntu/dists/${VERSION_CODENAME}/Release" >/dev/null 2>&1; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
          > /etc/apt/sources.list.d/docker.list
        install_apt_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      else
        # A new Ubuntu release can predate Docker's repo for it; the distro build runs NGC images the same.
        vlog "EMLI: no Docker CE repo for ${VERSION_CODENAME} -- using Ubuntu's docker.io"
        install_apt_packages docker.io
      fi
      ;;
    rocky|rhel|almalinux)
      dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
      # --allowerasing swaps out podman/runc, which conflict with containerd.io (legacy did the same).
      dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        || log_failure "EMLI: docker-ce install failed."
      ;;
  esac
  systemctl enable --now docker
  if ! systemctl is-active --quiet docker; then
    log_failure "EMLI: Docker is not running after install -- container steps skipped."
    return 1
  fi
}

# Toolkit only -- it adds a runtime hook and never touches the NVIDIA driver packages.
_emli_container_toolkit_install() {
  . /etc/os-release
  # The nvidia.github.io/nvidia-docker repo is archived; a leftover list from the legacy installer breaks apt update.
  rm -f /etc/apt/sources.list.d/nvidia-docker.list /etc/yum.repos.d/nvidia-docker.repo
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    write_header "EMLI: NVIDIA Container Toolkit"
    case "$ID" in
      ubuntu)
        local list=/etc/apt/sources.list.d/nvidia-container-toolkit.list
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
          | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
          | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > "$list"
        [ -s "$list" ] || { rm -f "$list"; log_failure "EMLI: NVIDIA Container Toolkit repo fetch failed."; return 1; }
        install_apt_packages nvidia-container-toolkit
        ;;
      rocky|rhel|almalinux)
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
          -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
          || { log_failure "EMLI: NVIDIA Container Toolkit repo fetch failed."; return 1; }
        install_dnf_packages nvidia-container-toolkit
        ;;
    esac
  fi
  if command -v nvidia-ctk >/dev/null 2>&1; then
    # Registers the nvidia runtime in daemon.json; the legacy installer never did, relying on older defaults.
    nvidia-ctk runtime configure --runtime=docker && systemctl restart docker
  else
    log_failure "EMLI: nvidia-ctk missing after install -- containers will not see the GPUs."
  fi
}

_emli_anaconda_install() {
  if [ -x /usr/local/anaconda3/bin/conda ]; then
    echo "Anaconda already installed at /usr/local/anaconda3."
  elif [ "$ARCH" != "x86_64" ]; then
    log_failure "EMLI: the QA server only has x86_64 Anaconda installers -- Anaconda skipped on $ARCH."
  else
    write_header "EMLI: Anaconda ($EMLI_ANACONDA)"
    local work avail
    avail=$(df -PB1G /usr/local 2>/dev/null | awk 'NR==2{print $4}')
    if [ "${avail:-0}" -lt 10 ]; then
      log_failure "EMLI: only ${avail:-0} GiB free under /usr/local (need ~10) -- Anaconda skipped."
    else
      work=$(mktemp -d /usr/local/exx-anaconda.XXXX)
      if qa_scp_get "/data/software/Anaconda/$EMLI_ANACONDA" "$work/" \
         && bash "$work/$EMLI_ANACONDA" -b -p /usr/local/anaconda3; then
        echo -e "${TXT_GRN}[SUCCESS] Anaconda installed to /usr/local/anaconda3.${RESET}"
      else
        log_failure "EMLI: Anaconda install failed ($EMLI_ANACONDA)."
      fi
      rm -rf "$work"
    fi
  fi
  # One marked block, runtime-guarded, so re-runs never stack duplicate PATH lines like the legacy appends did.
  local rc=/etc/bash.bashrc
  [ -f /etc/bashrc ] && rc=/etc/bashrc
  if ! grep -q '# >>> exx-emli >>>' "$rc" 2>/dev/null; then
    cat >> "$rc" <<'EOF'
# >>> exx-emli >>>
[ -d /usr/local/cuda/bin ] && PATH=/usr/local/cuda/bin:$PATH
[ -d /usr/local/anaconda3/bin ] && PATH=/usr/local/anaconda3/bin:$PATH
export PATH
# <<< exx-emli <<<
EOF
  fi
}

_emli_branding() {
  local src="$EMLI_ASSET_DIR/exxact_branding/deeplearning" h
  if [ ! -d "$src" ]; then
    log_failure "EMLI: branding assets missing -- branding skipped."
    return 1
  fi
  for h in "$REAL_HOME" /root; do
    mkdir -p "$h/Exxact" "$h/Pictures"
    cp "$src"/*.pdf "$h/Exxact/"
    cp "$src"/*.jpg "$src"/*.png "$h/Pictures/"
  done
  if qa_scp_get "$EMLI_QUICKSTART" "$REAL_HOME/"; then
    cp "$REAL_HOME/$(basename "$EMLI_QUICKSTART")" /root/
  else
    log_failure "EMLI: Quick Start Guide PDF fetch failed."
  fi
  chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/Exxact" "$REAL_HOME/Pictures" "$REAL_HOME/$(basename "$EMLI_QUICKSTART")" 2>/dev/null
  # System-wide GNOME default. Legacy did this on Rocky only; Ubuntu needed a manual per-user wallpaper script.
  if command -v dconf >/dev/null 2>&1; then
    cp "$src/x_blue_wallpaper.jpg" "$src/x_lockscreen.png" /usr/share/backgrounds/
    mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
    # picture-uri-dark too: GNOME 42+ ignores picture-uri under a dark color scheme.
    cat > /etc/dconf/db/local.d/00-exx-emli-branding <<'EOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/x_blue_wallpaper.jpg'
picture-uri-dark='file:///usr/share/backgrounds/x_blue_wallpaper.jpg'
picture-options='stretched'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/x_lockscreen.png'
picture-options='stretched'
EOF
    # The local system db is only consulted when the user profile lists it.
    [ -f /etc/dconf/profile/user ] || printf 'user-db:user\n' > /etc/dconf/profile/user
    grep -qx 'system-db:local' /etc/dconf/profile/user || echo 'system-db:local' >> /etc/dconf/profile/user
    dconf update
  fi
}

# Customer toolkits always; container launchers and the TF check only for the full image install.
_emli_tools() {  # _emli_tools full|diy
  local ngc="$EMLI_ASSET_DIR/ngc" f
  if [ -d "$ngc" ]; then
    install -m 0755 "$ngc"/exx-*.sh /usr/local/bin/ || log_failure "EMLI: exx-* toolkit install failed."
  fi
  [ "$1" = "full" ] || return 0
  for f in startDigits.sh startRapids.sh startLabel_studio.sh; do
    [ -f "$ngc/$f" ] && install -m 0755 "$ngc/$f" /usr/local/bin/
  done
  # Written here, not copied: the legacy launcher made a new container per run, and the second one lost port 9000.
  cat > /usr/local/bin/startPortainer.sh <<'EOF'
#!/bin/bash
# Starts the single Portainer container (web UI on port 9000), creating it on first use.
if docker ps -a --format '{{.Names}}' | grep -qx portainer; then
  docker start portainer
else
  docker run -d --name portainer -p 9000:9000 --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
fi
EOF
  chmod 0755 /usr/local/bin/startPortainer.sh
  if [ -f "$ngc/tensorflow_validation.sh" ]; then
    # The shipped file's shebang is '#/bin/bash' (missing '!').
    sed '1s|^#/bin/bash|#!/bin/bash|' "$ngc/tensorflow_validation.sh" > "$REAL_HOME/tensorflow_validation.sh"
    cp "$ngc/tf_gpucount.py" "$REAL_HOME/"
    chmod 0755 "$REAL_HOME/tensorflow_validation.sh"
    chown "$REAL_USER:$REAL_USER" "$REAL_HOME/tensorflow_validation.sh" "$REAL_HOME/tf_gpucount.py"
  fi
}

# Streams each image straight into docker load: no temp copy, so a 24 GB image needs its space once, not twice.
_emli_load_images() {
  if [ "$ARCH" != "x86_64" ]; then
    log_failure "EMLI: QA-server NGC images are x86_64 -- image preload skipped on $ARCH."
    return 1
  fi
  local list=() img size avail need root n=0 st done_file="$EMLI_STATE_DIR/loaded-images.list"
  mapfile -t list < <(_emli_os_images)
  if [ ${#list[@]} -eq 0 ]; then
    log_failure "EMLI: no image list for this OS -- image preload skipped."
    return 1
  fi
  mkdir -p "$EMLI_STATE_DIR"; touch "$done_file"
  root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null); root=${root:-/var/lib/docker}
  write_header "EMLI: Loading ${#list[@]} NGC images into Docker"
  for img in "${list[@]}"; do
    n=$((n + 1))
    if grep -qxF "$img" "$done_file"; then
      echo "[$n/${#list[@]}] $img -- already loaded, skipping."
      continue
    fi
    size=$(sshpass -p "$QA_SSHPASS" ssh "${QA_SSH_OPTS[@]}" "$QA_SERVER_USER@$QA_SERVER_IP" \
           "stat -c %s '$EMLI_IMAGE_DIR/$img'" 2>/dev/null)
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
      log_failure "EMLI: image $img not found on QA server ($EMLI_IMAGE_DIR)."
      continue
    fi
    # Load unpacks roughly 1:1; the 20% + 10 GiB margin keeps the root disk from filling mid-load.
    avail=$(df -PB1 "$root" | awk 'NR==2{print $4}')
    need=$(( size * 12 / 10 + 10737418240 ))
    if [ "${avail:-0}" -lt "$need" ]; then
      log_failure "EMLI: $img skipped -- needs ~$((need >> 30)) GiB in $root, $((${avail:-0} >> 30)) GiB free."
      continue
    fi
    echo "[$n/${#list[@]}] Loading $img ($((size >> 20)) MiB)..."
    _qa_stream_file "$EMLI_IMAGE_DIR/$img" | docker load
    st=("${PIPESTATUS[@]}")
    if [ "${st[0]}" -eq 0 ] && [ "${st[1]}" -eq 0 ]; then
      echo "$img" >> "$done_file"
    else
      log_failure "EMLI: loading $img failed (transfer exit ${st[0]}, docker load exit ${st[1]})."
    fi
  done
}

_emli_apps() {
  if [ -x /usr/local/anaconda3/bin/pip ]; then
    /usr/local/anaconda3/bin/pip install -U label-studio || log_failure "EMLI: pip install label-studio failed."
  fi
  docker pull portainer/portainer-ce:latest || log_failure "EMLI: Portainer image pull failed (needs internet)."
  /usr/local/bin/startPortainer.sh || log_failure "EMLI: Portainer failed to start."
}

# Proves containers see every GPU: CUDA image nvidia-smi count, then TensorFlow's own count, vs the host.
_emli_verify() {  # _emli_verify full|diy
  local host_n ctr_n tf_n img tfimg ctr_res tf_res
  write_header "EMLI: Verification"
  host_n=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ')
  img=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 'nvidia/cuda:.*runtime')
  if [ -z "$img" ]; then
    ctr_res="SKIPPED (no CUDA image loaded)"
  else
    ctr_n=$(docker run --rm --gpus all "$img" nvidia-smi -L 2>/dev/null | grep -c '^GPU ')
    if [ "$host_n" -gt 0 ] && [ "$ctr_n" -eq "$host_n" ]; then
      ctr_res="PASS ($ctr_n/$host_n GPUs)"
    else
      ctr_res="FAIL ($ctr_n/$host_n GPUs)"
      log_failure "EMLI: container sees $ctr_n of $host_n GPUs ($img)."
    fi
  fi
  tfimg=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 'nvidia/tensorflow:.*tf2')
  if [ -z "$tfimg" ] || [ ! -f "$EMLI_ASSET_DIR/ngc/tf_gpucount.py" ]; then
    tf_res="SKIPPED (no TensorFlow image)"
  else
    tf_n=$(docker run --rm --gpus all -v "$EMLI_ASSET_DIR/ngc:/exx:ro" "$tfimg" python /exx/tf_gpucount.py 2>/dev/null \
           | grep -oP 'Num GPUs Available:\s*\K[0-9]+')
    if [ "$host_n" -gt 0 ] && [ "${tf_n:-0}" -eq "$host_n" ]; then
      tf_res="PASS ($tf_n/$host_n GPUs)"
    else
      tf_res="FAIL (${tf_n:-0}/$host_n GPUs)"
      log_failure "EMLI: TensorFlow sees ${tf_n:-0} of $host_n GPUs ($tfimg)."
    fi
  fi
  echo "  Container GPU check:  $ctr_res"
  echo "  TensorFlow GPU check: $tf_res"
  _emli_result_set MODE "$1"
  _emli_result_set DATE "$(date '+%Y-%m-%d %H:%M')"
  _emli_result_set CONTAINER_GPU "$ctr_res"
  _emli_result_set TF_GPU "$tf_res"
}

# Leave-behind manifest for the customer. Rewritten each run -- the legacy version appended duplicates.
_emli_write_readme() {
  local f="$REAL_HOME/00README"
  {
    echo "      Exxact EMLI GPU Box"
    echo "      Software Stack v2.0"
    echo "          $(date '+%b %d %Y')"
    echo
    echo "NVIDIA driver:  $(_gpu_running_driver_version)"
    [ -x /usr/local/cuda/bin/nvcc ] && \
      echo "CUDA toolkit:   $(/usr/local/cuda/bin/nvcc --version | grep -oP 'release \K[0-9.]+') (/usr/local/cuda, in path)"
    [ -x /usr/local/anaconda3/bin/conda ] && echo "Anaconda3:      /usr/local/anaconda3 (in path)"
    echo "Docker:         $(docker --version 2>/dev/null)"
    echo "Portainer:      http://<this-host>:9000  (start with startPortainer.sh)"
    echo
    echo "This machine has the following Docker images installed."
    echo
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null
  } > "$f"
  chown "$REAL_USER:$REAL_USER" "$f"
}

# Whole EMLI install in one pass. Safe to re-run: every step skips what is already in place.
_emli_run() {  # _emli_run full|diy
  local mode="${1:-full}"
  export DEBIAN_FRONTEND=noninteractive
  write_header "EMLI Install ($( [ "$mode" = "diy" ] && echo "DIY -- no preloaded images" || echo "full" ))"
  . /etc/os-release
  case "$ID" in
    ubuntu|rocky|rhel|almalinux) ;;
    *) log_failure "EMLI: unsupported OS '$ID $VERSION_ID' -- nothing installed."; return 1 ;;
  esac
  # Containers need a loaded driver; installing Docker without one only builds a box that fails verification.
  if [ -z "$(_gpu_running_driver_version 2>/dev/null)" ]; then
    log_failure "EMLI: no working NVIDIA driver (nvidia-smi) -- run Base+GPU, reboot, then re-run EMLI."
    return 1
  fi
  _emli_fetch_assets
  _emli_base_packages
  _emli_docker_install || return 1
  _emli_container_toolkit_install
  usermod -aG docker "$REAL_USER"
  _emli_anaconda_install
  _emli_branding
  _emli_tools "$mode"
  if [ "$mode" = "full" ]; then
    _emli_load_images
    _emli_apps
  fi
  _emli_verify "$mode"
  [ "$mode" = "full" ] && _emli_write_readme
  rm -rf "$EMLI_ASSET_DIR"
  echo -e "${TXT_GRN}EMLI install ($mode) finished -- log out and back in for docker group membership.${RESET}"
}

# Standalone menu path. Re-running gpu_install over a finished stack redoes base+initramfs and re-evaluates
# the driver against a target branch that now includes the CUDA repo -- so skip it once driver + nvcc exist.
_emli_gpu_stack() {
  local drv; drv=$(_gpu_running_driver_version 2>/dev/null)
  if [ -n "$drv" ] && [ -x /usr/local/cuda/bin/nvcc ]; then
    echo -e "${TXT_GRN}NVIDIA driver ${drv} and CUDA toolkit already present -- skipping Base+GPU re-install.${RESET}"
    vlog "EMLI: driver ${drv} + nvcc present -- gpu_install skipped"
  else
    gpu_install
  fi
}

emli_install() {
  _emli_gpu_stack
  _emli_run full
  print_error_summary
  pause
}

emli_diy_install() {
  _emli_gpu_stack
  _emli_run diy
  print_error_summary
  pause
}

# --- 8. VALIDATION SUITE (CPU / Memory / GPU / SMART) ---
VAL_INITIALIZED=0
_init_validation_paths() {
  [ "$VAL_INITIALIZED" -eq 1 ] && return
  # One stable per-system folder, so rerunning a single test updates its log in place.
  VAL_LOGDIR="$REAL_HOME/$(_system_sn)_validation-logs"
  # QD profiles generated this run live with the logs, not in the persistent cache -- they are a
  # record of how this box was tested, and they go away when the logs are cleaned up.
  QD_RUN_DIR="$VAL_LOGDIR/qd-profiles"
  mkdir -p "$VAL_LOGDIR"
  # Load persisted results BEFORE any vrecord, or testing one phase wipes every other phase's result.
  _load_persisted_results
  CPU_TEMP_LOG="$VAL_LOGDIR/cpu_temp.log"
  GPU_TEMP_LOG="$VAL_LOGDIR/gpu_temp.log"
  FAN_LOG="$VAL_LOGDIR/fan.log"
  CPU_PWR_LOG="$VAL_LOGDIR/cpu_power.log"
  PSU_PWR_LOG="$VAL_LOGDIR/psu_power.log"
  MEM_TEMP_LOG="$VAL_LOGDIR/mem_temp.log"
  SMART_BEFORE="$VAL_LOGDIR/smart_before.log"
  SMART_AFTER="$VAL_LOGDIR/smart_after.log"
  # Drive presence/SN tracking -- see _snapshot_drive_inventory/_drive_presence_tick/check_drive_presence.
  DRIVE_INVENTORY_BASELINE="$VAL_LOGDIR/drive_inventory_baseline.txt"
  DRIVE_PRESENCE_LOG="$VAL_LOGDIR/drive_presence.log"
  MPRIME_DIR="$REAL_HOME/mprime"
  GPUBURN_DIR="$REAL_HOME/gpu-burn"
  FPACC_DIR="$REAL_HOME/cuda-samples"
  VAL_INITIALIZED=1
}

vlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

vrecord() {  # vrecord <PHASE> <PASS|FAIL|WARN|SKIP> <detail...>
  local phase="$1" verdict="$2"; shift 2
  RESULTS["$phase"]="$verdict :: $*"
  RESULTS_TS["$phase"]="$(date '+%Y-%m-%d %H:%M:%S')"
  vlog "$phase: $verdict${*:+ - $*}"
  _persist_result
}

# vrecord_evidence <PHASE> <snippet...> -- stores the log excerpt behind a verdict, in a per-phase file.
vrecord_evidence() {  # vrecord_evidence <PHASE> <snippet...>
  local phase="$1"; shift
  [ -z "${VAL_LOGDIR:-}" ] && return
  local dir="$VAL_LOGDIR/evidence"
  mkdir -p "$dir" 2>/dev/null
  printf '%s\n' "$*" > "$dir/${phase}.txt"
  chown -R "$REAL_USER:$REAL_USER" "$dir" 2>/dev/null
}

# Rewrites the whole state file on every record, avoiding stale duplicate lines for a retested phase.
_persist_result() {
  mkdir -p "$(dirname "$RESULTS_STATE_FILE")"
  : > "$RESULTS_STATE_FILE"
  local p
  for p in "${!RESULTS[@]}"; do
    printf '%s\t%s\t%s\n' "$p" "${RESULTS[$p]}" "${RESULTS_TS[$p]:-}" >> "$RESULTS_STATE_FILE"
  done
  chown "$REAL_USER:$REAL_USER" "$RESULTS_STATE_FILE" 2>/dev/null
}

# Loads the state file as a baseline, filling only phases this process hasn't freshly produced.
_load_persisted_results() {
  [ -s "$RESULTS_STATE_FILE" ] || return
  local phase verdict ts
  while IFS=$'\t' read -r phase verdict ts; do
    [ -z "$phase" ] && continue
    if [ -z "${RESULTS[$phase]+x}" ]; then
      RESULTS["$phase"]="$verdict"
      RESULTS_TS["$phase"]="$ts"
    fi
  done < "$RESULTS_STATE_FILE"
}

mark_temp() {
  CURRENT_PHASE="$1"
  # Written to a file, not just $CURRENT_PHASE: _status_ticker forks early and freezes its copy.
  echo "$1" > "${STATE_DIR:-/tmp}/current_phase.txt" 2>/dev/null
  local marker="### $(date '+%Y-%m-%d %H:%M:%S') PHASE: $1 ###"
  echo "$marker" >> "$CPU_TEMP_LOG"
  echo "$marker" >> "$GPU_TEMP_LOG"
  echo "$marker" >> "$FAN_LOG"
}

# Maps mark_temp's grep-friendly phase labels to human-facing names for the dashboard header.
_dashboard_phase_label() {
  case "$1" in
    MPRIME) echo "CPU Torture Test" ;;
    MEMORY) echo "Memory Torture Test" ;;
    GPU-BURN) echo "GPU Torture Test" ;;
    CONCURRENT-STRESS|PSU-CONCURRENT-STRESS) echo "System-wide Torture Test" ;;
    DCGM) echo "DCGM Diagnostics" ;;
    FP-ACCURACY) echo "Floating Point Accuracy Test" ;;
    SMARTCTL) echo "SMART Health Check" ;;
    COMPLETE) echo "Complete" ;;
    "") echo "Running" ;;
    *) echo "$1" ;;
  esac
}

# Instantaneous CPU utilization from two /proc/stat samples 0.3s apart -- no mpstat dependency.
_dashboard_cpu_load_pct() {
  local a b
  a=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat 2>/dev/null)
  sleep 0.3
  b=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat 2>/dev/null)
  awk -v a="$a" -v b="$b" 'BEGIN{
    split(a, A); split(b, B)
    total = B[1]-A[1]; idle = B[2]-A[2]
    if (total <= 0) { print "n/a"; exit }
    printf "%.0f", (1 - idle/total) * 100
  }'
}

# Renders one live monitor screen. sections = cpu/mem/gpu; PWR always shows; peak passed in, reported via _DASH_LAST_TOTAL_WATTS.
_dashboard_render() {  # _dashboard_render "<sections>" "<max_watts>"
  local sections="$1" max_watts="${2:-0}"
  local phase; phase=$(cat "${STATE_DIR:-}/current_phase.txt" 2>/dev/null)
  local label; label=$(_dashboard_phase_label "$phase")
  local elapsed_fmt="unknown"
  if [ -n "$RUN_START_EPOCH" ]; then
    local secs=$(( $(date +%s) - RUN_START_EPOCH ))
    elapsed_fmt="$((secs/3600))h $(((secs%3600)/60))m $((secs%60))s"
  fi

  # Always sampled -- the PWR section needs it regardless of which sections are active.
  local sdr_out; sdr_out=$(ipmitool sdr 2>/dev/null)

  clear
  echo "════════ STATUS @ $(date '+%H:%M:%S') ════════"
  echo "SCRIPT_VERSION: $SCRIPT_VERSION"
  echo "HOST: $(hostname)"
  echo "PHASE: $label"
  echo "RUN_DIR: ${VAL_LOGDIR:-unknown}"
  echo "SCRIPT_PID: $$"
  echo "STARTED: ${RUN_START_TS:-unknown}"
  echo "ELAPSED: $elapsed_fmt"
  echo "UPDATED: $(date '+%Y-%m-%d %H:%M:%S')"

  if [[ "$sections" == *cpu* ]]; then
    local cpu_pct cpu_temp cpu_pwr loadavg
    cpu_pct=$(_dashboard_cpu_load_pct)
    cpu_temp=$(echo "$sdr_out" | grep -oP 'TEMP_CPU\d+\s*\|\s*\K[\d.]+' | sort -rn | head -1)
    cpu_pwr=$(echo "$sdr_out" | grep -oP 'PWR_CPU\d+\s*\|\s*\K[\d.]+' | awk '{s+=$1} END{if (NR>0) print s; else print ""}')
    loadavg=$(uptime 2>/dev/null | grep -oP 'load average:\s*\K.*')
    echo "--- CPU ---"
    echo "Load: ${cpu_pct:-n/a}%"
    echo "Temp: ${cpu_temp:-n/a}"
    echo "Power: ${cpu_pwr:-n/a}W"
    echo "core load average: ${loadavg:-n/a}"
  fi

  if [[ "$sections" == *mem* ]]; then
    local mem_pct dimm_labels dimm_temps
    mem_pct=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
    dimm_labels=$(echo "$sdr_out" | grep -oP 'TEMP_DDR5_\K\S+(?=\s*\|)' | paste -sd, -)
    dimm_temps=$(echo "$sdr_out" | grep 'TEMP_DDR5_' | grep -oP '\|\s*\K[\d.]+(?= degrees)' | paste -sd, -)
    echo "--- MEM ---"
    echo "Load: ${mem_pct:-n/a}%"
    if [ -n "$dimm_labels" ]; then
      echo "Temp Sources: $dimm_labels"
      echo "Temp: $dimm_temps"
    fi
    free -h 2>/dev/null | awk 'NR==1 || NR==2'
  fi

  if [[ "$sections" == *gpu* ]]; then
    echo "--- GPU ---"
    echo "ID, Load, Temp, Power, Clock"
    nvidia-smi --query-gpu=index,utilization.gpu,temperature.gpu,power.draw,clocks.sm --format=csv,noheader 2>/dev/null
  fi

  # Each power source kept separate. Total = sum of PSU *_PIN (AC input), the real wall draw.
  echo "--- PWR ---"
  echo "$sdr_out" | grep -E '^(PWR_CPU|PWR_PSU)' | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); gsub(/^[ \t]+|[ \t]+$/,"",$2); printf "%-16s %s\n", $1":", $2}'
  nvidia-smi --query-gpu=index,power.draw --format=csv,noheader,nounits 2>/dev/null | awk -F',' '{gsub(/^[ \t]+/,"",$2); printf "GPU%-13s %sW\n", $1":", $2}'

  local total_watts
  total_watts=$(echo "$sdr_out" | grep -oP 'PWR_PSU\d+_PIN\s*\|\s*\K[\d.]+' | awk '{s+=$1} END{if (NR>0) print s; else print ""}')
  _DASH_LAST_TOTAL_WATTS="$total_watts"
  echo "Total: ${total_watts:-n/a}W"
  echo "Max: ${max_watts}W"

  echo "════════════════════════════════════════════"
}

# --- Status introspection: written periodically so --status can answer phase/duration/temps from any terminal. ---
write_status() {  # write_status <phase note...>
  local elapsed=""
  if [ -n "$RUN_START_EPOCH" ]; then
    elapsed="$(( $(date +%s) - RUN_START_EPOCH ))s"
  fi
  {
    echo "SCRIPT_VERSION: $SCRIPT_VERSION"
    echo "HOST: $(hostname)"
    echo "PHASE: ${CURRENT_PHASE:-$*}"
    echo "RUN_DIR: ${VAL_LOGDIR:-unknown}"
    echo "SCRIPT_PID: $$"
    echo "STARTED: ${RUN_START_TS:-unknown}"
    echo "ELAPSED: ${elapsed:-unknown}"
    echo "UPDATED: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "--- CPU/MEMORY ---"
    uptime
    free -h | awk 'NR<=2'
    echo "--- GPU ---"
    nvidia-smi --query-gpu=index,utilization.gpu,temperature.gpu,power.draw,clocks.sm --format=csv,noheader 2>/dev/null
  } > "$STATUS_FILE" 2>/dev/null
}

# Background loop refreshing $STATUS_FILE and, in live mode, redrawing the dashboard.
_status_ticker() {  # _status_ticker "<sections>"
  local sections="${1:-cpu mem gpu}"
  local max_watts=0
  local tick=0
  while true; do
    sleep 2
    tick=$((tick + 1))
    # The dashboard ticks every 2s; the status file is throttled to every 8th tick (~16s).
    if [ $((tick % 8)) -eq 0 ]; then
      write_status
    fi
    if [ "$MONITOR_MODE" = "live" ]; then
      _dashboard_render "$sections" "$max_watts"
      # _dashboard_render reports its computed Total via this global -- track the running peak for next tick.
      if [[ "$_DASH_LAST_TOTAL_WATTS" =~ ^[0-9.]+$ ]] \
         && awk -v w="$_DASH_LAST_TOTAL_WATTS" -v m="$max_watts" 'BEGIN{exit !(w>m)}'; then
        max_watts="$_DASH_LAST_TOTAL_WATTS"
      fi
    fi
  done
}

# Sets up RUN_START_EPOCH/TS plus a ticker, forced live -- for short tests where a prompt isn't worth adding.
_start_dashboard() {  # _start_dashboard "<sections>"
  RUN_START_EPOCH=$(date +%s)
  RUN_START_TS=$(date '+%Y-%m-%d %H:%M:%S')
  MONITOR_MODE="live"
  _status_ticker "$1" &
  STATUS_TICKER_PID=$!
}

_stop_dashboard() {
  kill "$STATUS_TICKER_PID" 2>/dev/null
}

# --- Live status: read from the process table, so installs and tests both show, with or without a run log. ---

_fmt_secs() {  # _fmt_secs <seconds> -> 1h02m03s / 4m05s / 12s
  local s=${1:-0}
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60))
  else printf '%ds' "$s"; fi
}

# One readable line for a process, or nothing if it is plumbing (shells, sleep, tee, sudo...).
_status_describe() {  # _status_describe "<args>"
  local a="$1" bin w2; bin=$(basename "${a%% *}")
  # "sh /usr/sbin/update-initramfs -u" / "python3 /usr/bin/ubuntu-drivers" -- name the script, not the interpreter.
  case "$bin" in
    sh|bash|dash|python3|python|perl)
      w2=$(echo "$a" | awk '{print $2}')
      case "$w2" in /*|./*) bin=$(basename "$w2"); a="${a#* }" ;; esac ;;
  esac
  case "$bin" in
    apt-get|apt)
      case "$a" in
        *" install "*) echo "Installing package(s): $(echo "$a" | sed -E 's/.* install //; s/(^| )-[^ ]+//g; s/^ +//')" ;;
        *" update"*)   echo "Refreshing package lists (apt-get update)" ;;
        *"dist-upgrade"*|*" upgrade"*|*"full-upgrade"*) echo "Upgrading installed system packages" ;;
        *" remove "*|*" purge "*|*"autoremove"*) echo "Removing package(s): $(echo "$a" | sed -E 's/.* (remove|purge|autoremove) //; s/(^| )-[^ ]+//g')" ;;
        *) echo "Package manager: $a" ;;
      esac ;;
    dnf|yum)
      case "$a" in
        *" install "*|*"groupinstall"*) echo "Installing package(s): $(echo "$a" | sed -E 's/.* (group)?install //; s/(^| )-[^ ]+//g; s/^ +//')" ;;
        *" update"*|*" upgrade"*) echo "Upgrading installed system packages" ;;
        *) echo "Package manager: $a" ;;
      esac ;;
    dpkg) ;;   # the maintainer-script line below is more specific
    *.postinst|*.preinst|*.prerm|*.postrm)
      echo "  configuring package $(basename "${bin%.*}") ($(echo "${bin##*.}"))" ;;
    dkms)            echo "Building kernel module with DKMS (NVIDIA driver) -- can take several minutes" ;;
    update-initramfs|dracut|mkinitramfs|dracut-install) echo "Rebuilding initramfs" ;;
    update-grub|grub-mkconfig|grub2-mkconfig|grubby) echo "Updating bootloader config" ;;
    snap)            echo "Snap: $(echo "$a" | cut -d' ' -f2-)" ;;
    systemctl)       case "$a" in *daemon-reload*|*" is-"*|*" show "*|*" status "*) ;; *) echo "Service: $(echo "$a" | cut -d' ' -f2-)" ;; esac ;;
    systemd-sysv-install|update-rc.d|invoke-rc.d|deb-systemd-helper|deb-systemd-invoke) ;;
    ubuntu-drivers)  echo "Selecting/installing NVIDIA driver (ubuntu-drivers)" ;;
    nvidia-uninstall) echo "Removing .run NVIDIA driver" ;;
    gpu_burn)        echo "GPU burn-in (gpu_burn)" ;;
    mprime)          echo "CPU stress (mprime)" ;;
    stress-ng)       echo "CPU/memory stress (stress-ng)" ;;
    stressapptest)   echo "Memory stress (stressapptest)" ;;
    memtester)       echo "Memory test (memtester)" ;;
    fio)             echo "Storage test (fio$(echo "$a" | grep -oE -- '--name=[^ ]+' | head -1 | sed 's/--name=/: /'))" ;;
    dcgmi)           case "$a" in *" diag "*) echo "DCGM diagnostic (level $(echo "$a" | grep -oE -- '-r [0-9]+' | grep -oE '[0-9]+'))" ;; *) echo "DCGM: $a" ;; esac ;;
    nvbandwidth)     echo "GPU interconnect bandwidth test (nvbandwidth)" ;;
    matrixMul)       echo "GPU floating-point accuracy test (matrixMul)" ;;
    rvs)             echo "AMD GPU stress (rvs)" ;;
    rocm-bandwidth-test) echo "AMD GPU bandwidth test" ;;
    smartctl)        case "$a" in *" -t "*) echo "SMART self-test: $a" ;; *) ;; esac ;;
    mdadm|graidctl|storcli|storcli64|mkfs.*|blkdiscard|wipefs|parted|sgdisk) echo "Storage setup: $a" ;;
    docker)          case "$a" in *" load"*) echo "Loading Docker image" ;; *" pull "*) echo "Pulling Docker image: ${a##* }" ;; *) echo "Docker: $a" ;; esac ;;
    scp|sftp)        echo "Copying file with QA server: ${a##* }" ;;
    ssh)             case "$a" in *"cat '"*) echo "Streaming from QA server: $(echo "$a" | grep -oE "cat '[^']+'" | sed "s/cat //; s/'//g")" ;; *) ;; esac ;;
    curl|wget)       echo "Downloading: $(echo "$a" | grep -oE 'https?://[^ ]+' | head -1)" ;;
    make|cmake|nvcc|gcc|cc1|cc1plus) echo "Compiling ($bin)" ;;
    git)             echo "git: $(echo "$a" | cut -d' ' -f2-)" ;;
    tar|unzip|zip)   echo "Archive: $a" ;;
    bash|sh|sudo|setsid|nohup|tee|sleep|timeout|awk|sed|grep|cat|head|tail|cut|tr|date|ps|pgrep|xargs|find|sort|wc|basename|dirname|readlink|systemd-run|exx-validation.sh|run-parts|needrestart|dpkg-status|dpkg-trigger|cpio|zstd|gzip|xz|ldconfig|depmod|cp|mv|ln|rm|mkdir|chmod|chown|stat|uname|id|env|flock|lsinitramfs|unmkinitramfs|debconf-communicate|frontend) ;;
    *)               echo "Running: $a" ;;
  esac
}

# Descendants of <pid> as "pid etimes args", parents first.
_status_descendants() {  # _status_descendants <pid>
  ps -e -o pid=,ppid=,etimes=,args= 2>/dev/null | awk -v root="$1" '
    { pid=$1; ppid[pid]=$2; et[pid]=$3; $1=$2=$3=""; sub(/^ +/,""); args[pid]=$0; order[++n]=pid }
    END {
      keep[root]=1
      changed=1
      while (changed) { changed=0; for (i=1;i<=n;i++) { p=order[i]; if (!keep[p] && keep[ppid[p]]) { keep[p]=1; changed=1 } } }
      for (i=1;i<=n;i++) { p=order[i]; if (keep[p] && p!=root) print p, et[p], args[p] }
    }'
}

# Label for an instance of this script from its own command line.
_status_run_kind() {  # _status_run_kind "<args>"
  case "$1" in
    *--detach=*)       echo "background run: $(echo "$1" | grep -oE -- '--detach=[^ ]+' | cut -d= -f2)" ;;
    *__wizard_resume*) echo "provisioning wizard (resumed after reboot)" ;;
    *--noos*)          echo "--noos full validation" ;;
    *)                 echo "interactive menu session" ;;
  esac
}

_status_render() {
  local pids=() p line et args desc any_script="" wiz_phase=""
  local cand=" " a
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # Other --status viewers (and this viewer's own render subshell) are not runs.
    case "$(ps -o args= -p "$p" 2>/dev/null)" in *--status*) continue ;; esac
    cand="$cand$p "
  done < <(_exx_script_pids)
  # One entry per run: skip any candidate with a candidate ancestor (sudo -> script -> its subshells).
  for p in $cand; do
    a=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    while [ -n "$a" ] && [ "$a" -gt 1 ]; do
      case "$cand" in *" $a "*) continue 2 ;; esac
      a=$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' ')
    done
    pids+=("$p")
  done
  echo "exx-validation.sh live status -- $(hostname) -- $(date '+%Y-%m-%d %H:%M:%S')"
  echo "================================================================"
  [ -s "${WIZARD_STATE_FILE:-/nonexistent}" ] && wiz_phase=$(awk -F'\t' '$1=="WIZARD_PHASE"{print $2}' "$WIZARD_STATE_FILE")
  if [ -n "$wiz_phase" ] && [ "$wiz_phase" != "DONE" ]; then
    echo "Provisioning wizard: phase $wiz_phase$(systemctl is-enabled --quiet exx-wizard-resume.service 2>/dev/null && echo ' (auto-resumes on next boot)')"
  fi
  for p in "${pids[@]}"; do
    args=$(ps -o args= -p "$p" 2>/dev/null) || continue
    any_script=1
    et=$(ps -o etimes= -p "$p" | tr -d ' ')
    echo
    echo "[RUNNING] PID $p -- $(_status_run_kind "$args") -- running $(_fmt_secs "$et")"
    local phase_file="${STATE_DIR:-/tmp}/current_phase.txt" shown=""
    if [ -s "$phase_file" ] && [ "$(( $(date +%s) - $(stat -c %Y "$phase_file") ))" -lt $(( et + 5 )) ]; then
      echo "  Test phase: $(_dashboard_phase_label "$(cat "$phase_file")" 2>/dev/null || cat "$phase_file")"
    fi
    local seen="|" nlines=0
    while read -r _pid et line; do
      desc=$(_status_describe "$line")
      [ -z "$desc" ] && continue
      case "$seen" in *"|$desc|"*) continue ;; esac
      seen="$seen$desc|"
      nlines=$((nlines + 1))
      [ "$nlines" -gt 8 ] && break
      desc="  $desc  [$(_fmt_secs "$et")]"
      echo "${desc:0:160}"
      shown=1
    done < <(_status_descendants "$p")
    [ -z "$shown" ] && echo "  (between steps, or waiting for input)"
  done
  # Package-manager work outside this script's tree (a manual apt run, another tool) still blocks installs.
  local pm; pm=$(pgrep -a -x 'apt-get|apt|dnf|dpkg|yum|unattended-upgr' 2>/dev/null | head -3)
  if [ -z "$any_script" ]; then
    echo
    echo "No exx-validation.sh run is active."
    [ -n "$pm" ] && { echo "Package manager busy (not started by this script):"; echo "$pm" | sed 's/^/  /'; }
  fi
  echo
  echo "--- CPU / MEMORY ---"
  uptime
  free -h | awk 'NR<=2'
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "--- GPU (index, util %, temp C, power W, SM MHz) ---"
    nvidia-smi --query-gpu=index,utilization.gpu,temperature.gpu,power.draw,clocks.sm --format=csv,noheader 2>/dev/null
  fi
}

# --status: live view refreshed every 2s on a terminal (Ctrl-C to exit); a single snapshot when piped.
show_status() {
  if [ -t 1 ]; then
    trap 'tput cnorm 2>/dev/null; echo; exit 0' INT TERM
    tput civis 2>/dev/null
    while true; do
      local frame; frame=$(_status_render 2>/dev/null)
      clear
      echo "$frame"
      echo
      echo "(refreshing every 2s -- Ctrl-C to exit)"
      sleep 2
    done
  fi
  _status_render
}

# --help/-h. Same order as the argument parser -- don't let this drift out of sync.
show_help() {
  cat <<EOF
exx-validation.sh (version ${SCRIPT_VERSION})

Usage: sudo ./exx-validation.sh [OPTIONS]

Run with no options to launch the interactive menu (Main Installations /
Validation / Utilities). The options below let you customize behavior
before that menu ever shows up, or skip it entirely for a status check.

  --status
        Live view of what the script is doing right now -- which package is
        installing, which test is running, driver/DKMS builds, downloads --
        read straight from the running processes, so it works for installs
        and the wizard too, no run log needed. Refreshes every 2s until
        Ctrl-C; prints a single snapshot when piped. Safe from any terminal.

  --dcgm=N   (N = 1, 2, 3, or 4)
        Pin the DCGM diagnostic level for this invocation, everywhere it's
        used (the standalone DCGM Health Check menu item, and the DCGM
        pass inside Hardware Validation options 6/7) -- skips the
        interactive "diagnostic level to run" prompt. Useful on hardware
        that's confirmed to fault at a given level (see
        reference_exxact_lab_host_td6000 in the team's notes) so a
        technician doesn't have to remember to answer the prompt safely
        every time.

  --nvbandwidth=0
        Disable DCGM's nvbandwidth test plugin for every diag run this
        invocation, via \`-p "nvbandwidth.is_allowed=false"\`. Confirmed
        2026-09-08: on hardware with a real PCIe fault, this specific
        plugin -- not level 4 as a whole -- is what triggers it; disabling
        just this one plugin recovers full level-4 coverage (pcie/memory/
        power/stress tests all still run) instead of having to cap the
        diag level lower and lose that coverage entirely.

  --concurrent-duration=N   (N = seconds)
        Override the concurrent CPU+Memory+GPU stress duration (default 4h
        / 14400s) for Hardware Validation's Combined options, for this
        invocation only -- the hardcoded default is untouched for every
        other run. For a short demo/smoke-test pass, not a substitute for
        a real 4h validation.

  --phase-duration=N   (N = seconds)
        Override the duration of a single CPU / Memory / GPU test, for this
        invocation only. Mostly passed automatically when one of those is
        detached; you rarely need to type it yourself.

  --detach=<target>
        Internal. How the script re-execs itself detached after you pick
        Background at the monitor-mode prompt. Targets are whitelisted; a
        bad one lists the valid set and exits. Not meant to be typed by hand
        -- use the menu, which collects the prompts first.

  --noos
        For NoOS/PXE-live systems only -- no persistent OS is being
        installed, so there is nothing for Prerequisite/Base/GPU Post
        Install to do. Skips the menu entirely and goes straight into
        Hardware Validation's Combined (Full Validation) run (the same body
        the interactive menu's option 8 and the Automated Provisioning
        Wizard's final phase both call). Still asks the serial number,
        storage setup, and live-vs-background monitor mode up front.
        Because Base Install is skipped, an OS-prep step runs at the start
        of every --noos run: apt update + full-upgrade, install dhclient
        (lease refresh) and the validation toolchain the live image lacks
        (fio, stressapptest, stress-ng, memtester, smartmontools, nvme-cli,
        lm-sensors, cmake) plus the CUDA compiler/dev matching the shipped
        runtime (so gpu_burn builds). All of it is in RAM and gone at
        reboot, hence re-run each time. When validation finishes, every
        test volume/array/pool is torn back down so the system ships blank.

  --kill  (alias: --stop)
        EMERGENCY STOP. Kills every validation/provisioning process this
        suite started -- the wizard's resume service, any other running copy
        of this script, and the workload tools (mprime, gpu_burn,
        stressapptest, stress-ng, fio, dcgmi, nvbandwidth, matrixMul,
        memtester). Run it from a SECOND terminal while a run is in
        progress; it never kills the terminal you typed it into.
        Stops work only: mounts, arrays, pools and partitions are left
        exactly as they stand. Same as User Operations option 12.

  --btt
        Collect diagnostics and exit -- no testing required, nothing is run
        or modified. Gathers a full read-only system inventory for the test
        team, laid out one file per category: System, BMC, BIOS, GPU,
        Networking, Storage, Workload, plus PCIe link state, power/cooling,
        location, and dmesg + journalctl captures. Start at 00_SUMMARY.txt.

        Diagnostics are kept separate from validation test logs, in
        ${EXXACT_ARCHIVE_DIR}/<SN>_validation-logs/diag/ -- one folder per
        collection, left unzipped:
          <SN>_diag/                  the default, overwritten each time
          <SN>_diag_<date>-<time>/    a timestamped keeper
        If a default collection already exists, --btt asks whether to
        overwrite it or keep it and write a timestamped one alongside, so
        Test Engineering can hold several reference points at once while
        troubleshooting. Run non-interactively, it always timestamps rather
        than discard the previous collection.

        Safe to run at any time, including on a system that has never been
        validated. The same bundle is also collected automatically at the
        start of every full validation run -- those always overwrite the
        default collection, unprompted. System Cleanup (menu 10) removes the
        timestamped keepers.

  -h, --help
        Show this message and exit.

Options can be combined, e.g.:
  sudo ./exx-validation.sh --dcgm=4 --nvbandwidth=0
  sudo ./exx-validation.sh --concurrent-duration=1800
  sudo ./exx-validation.sh --noos
  sudo ./exx-validation.sh --btt
  sudo ./exx-validation.sh --kill        # from a second terminal, mid-run
EOF
}

# Defaults to background: surviving a dropped SSH session should be the path of least resistance.
_prompt_monitor_mode() {
  echo
  echo "How would you like to monitor this run?"
  echo "  1. Live       -- stays attached to this terminal; periodic status prints here"
  echo "                   as it runs (you can still work in a DIFFERENT terminal, just"
  echo "                   don't close this one or the run dies with it)."
  echo "  2. Background -- detaches immediately and frees this terminal; survives a"
  echo "                   dropped SSH connection. I'll print the exact command to"
  echo "                   check status anytime, from anywhere."
  local choice
  read -rp "Enter choice [1-2, default 2]: " choice
  case "$choice" in
    1) MONITOR_MODE="live" ;;
    *) MONITOR_MODE="background" ;;
  esac
}

# True when the name is on the EXX_DETACHABLE whitelist. Used by both the launcher and the arg parser.
_is_detachable() {
  local f
  for f in "${EXX_DETACHABLE[@]}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}

# Re-execs detached (setsid, I/O to a log) into the given body, passing active CLI overrides through.
_launch_background() {  # _launch_background <detachable_func> [log_prefix]
  local func_name="$1" tag="${2:-run}"
  if ! _is_detachable "$func_name"; then
    echo "[ERROR] _launch_background: '$func_name' is not in EXX_DETACHABLE"; return 1
  fi
  mkdir -p "$LOG_DIR" 2>/dev/null
  local runlog="$LOG_DIR/unattended_${tag}_$(date +%Y%m%d_%H%M%S).log"
  local dcgm_arg="" nvbw_arg="" durn_arg=""
  [ -n "$DCGM_LEVEL_OVERRIDE" ] && dcgm_arg="--dcgm=$DCGM_LEVEL_OVERRIDE"
  [ "$DCGM_NVBANDWIDTH_DISABLE" = "1" ] && nvbw_arg="--nvbandwidth=0"
  # --concurrent-duration only changes this process -- pass it through or the re-exec runs the full 4h.
  [ "$CONCURRENT_STRESS_DURATION" != 14400 ] && durn_arg="--concurrent-duration=$CONCURRENT_STRESS_DURATION"
  # --noos too: the teardown is gated on it, and a background run would otherwise ship a
  # fully-partitioned system. INTERNAL_DISPATCH is checked first, so this cannot re-enter the
  # flag's own menu-skipping branch.
  local noos_arg=""
  [ -n "$NOOS_MODE" ] && noos_arg="--noos"
  # Single-test duration is prompted before detaching, so carry it or the re-exec uses the default.
  local phase_arg=""
  [ -n "$PHASE_DURATION" ] && phase_arg="--phase-duration=$PHASE_DURATION"
  # Carries the answered structure gate across, so the detached run neither re-asks nor silently skips it.
  local preconf_arg=""
  [ -n "$IE_PLAN_PRECONFIRMED" ] && preconf_arg="--plan-preconfirmed"
  setsid "$SCRIPT_PATH" $dcgm_arg $nvbw_arg $durn_arg $noos_arg $phase_arg $preconf_arg \
    "--detach=$func_name" < /dev/null > "$runlog" 2>&1 &
  disown
  echo
  echo -e "${TXT_GRN}Started in the background -- safe to close this terminal or lose the SSH connection.${RESET}"
  echo "Run/console log: $runlog"
  echo "Check status anytime with:"
  echo "  sudo $SCRIPT_PATH --status"
  echo "Stop it early with:"
  echo "  sudo $SCRIPT_PATH --kill"
}

# Prompt for Live vs Background, then run inline or detach. All input must be collected BEFORE this.
_run_or_detach() {  # _run_or_detach <detachable_func> <log_prefix>
  _prompt_monitor_mode
  if [ "$MONITOR_MODE" = "background" ]; then
    # Exit after handoff -- falling through leaves an orphan blocked on read.
    _launch_background "$1" "$2"
    exit 0
  fi
  run_and_log "$1" "$2"
}

start_temp_monitors() {
  [ "$VAL_INITIALIZED" -eq 1 ] || return
  ( while true; do
      ts=$(date '+%Y-%m-%d %H:%M:%S')
      local sdr_out
      sdr_out=$(ipmitool sdr 2>/dev/null)
      echo "$sdr_out" | grep -i "temp_cpu" | while IFS= read -r line; do
        echo "[$ts] $line" >> "$CPU_TEMP_LOG"
      done
      # Fan health rides the same sdr sample; a gap-fill part can shift thermals enough to stall a fan.
      echo "$sdr_out" | grep -i "fan" | while IFS= read -r line; do
        echo "[$ts] $line" >> "$FAN_LOG"
      done
      # Per-DIMM temp from the same sdr sample. No matching sensors leaves the log empty -- check_temps SKIPs.
      echo "$sdr_out" | grep -i "temp_ddr" | while IFS= read -r line; do
        echo "[$ts] $line" >> "$MEM_TEMP_LOG"
      done
      # CPU power from the sdr sample; clock from /proc/cpuinfo, which IPMI doesn't expose on this board.
      local cpu_pwr cpu_mhz
      cpu_pwr=$(echo "$sdr_out" | grep -oP 'PWR_CPU\d+\s*\|\s*\K[\d.]+' | awk '{s+=$1} END{if (NR>0) printf "%.0f", s}')
      cpu_mhz=$(awk -F: '/cpu MHz/{v=$2+0; if(v>m) m=v} END{if (m>0) printf "%.0f", m}' /proc/cpuinfo 2>/dev/null)
      echo "[$ts] EPOCH=$(date +%s) POWER_W=${cpu_pwr:-0} MAX_MHZ=${cpu_mhz:-0}" >> "$CPU_PWR_LOG"
      # Per-PSU PIN (AC input, true wall draw), discovered dynamically rather than assuming a fixed count.
      local psu_line psu_total
      psu_line=$(echo "$sdr_out" | awk -F'\\|' '
        /^PWR_PSU[0-9]+_PIN/ {
          split($1, a, "PWR_PSU"); split(a[2], b, "_PIN")
          idx = b[1]
          gsub(/^[ \t]+|[ \t]+$/, "", $2)
          split($2, w, " ")
          watts = w[1] + 0
          line = line "PSU" idx "=" watts " "
          total += watts
        }
        END { printf "%sTOTAL_W=%.0f", line, total }
      ')
      psu_total=$(echo "$psu_line" | grep -oP 'TOTAL_W=\K[\d.]+')
      [ -n "$psu_total" ] && echo "[$ts] EPOCH=$(date +%s) $psu_line" >> "$PSU_PWR_LOG"
      sleep $TEMP_INTERVAL
    done ) &
  PID_CPUTEMP=$!
  ( while true; do
      ts=$(date '+%Y-%m-%d %H:%M:%S')
      # Captured under load: links downshift at idle, so a post-run idle query undersells the real Gen.
      nvidia-smi --query-gpu=index,serial,temperature.gpu,clocks.sm,power.draw,pcie.link.gen.current --format=csv,noheader,nounits 2>/dev/null \
        | while IFS= read -r line; do echo "[$ts] $line" >> "$GPU_TEMP_LOG"; done
      sleep $TEMP_INTERVAL
    done ) &
  PID_GPUTEMP=$!
  # Drive presence watcher on its own loop -- unrelated to the ipmitool sdr sampling.
  ( while true; do
      _drive_presence_tick
      sleep $TEMP_INTERVAL
    done ) &
  PID_DRIVEPRESENCE=$!
  MONITORS_RUNNING=1
  vlog "TEMP MONITORS: started (cpu_pid:$PID_CPUTEMP gpu_pid:$PID_GPUTEMP drive_pid:$PID_DRIVEPRESENCE)"
}

stop_temp_monitors() {
  [ "$MONITORS_RUNNING" -eq 1 ] || return
  kill "$PID_CPUTEMP" "$PID_GPUTEMP" "$PID_DRIVEPRESENCE" 2>/dev/null
  pkill -P "$PID_CPUTEMP" 2>/dev/null
  pkill -P "$PID_GPUTEMP" 2>/dev/null
  pkill -P "$PID_DRIVEPRESENCE" 2>/dev/null
  MONITORS_RUNNING=0
}

check_temps() {
  vlog "━━━ TEMPERATURE THRESHOLD CHECK ━━━"
  local cpu_peak cpu_high
  cpu_peak=$(grep -oP '\d+(?= degrees C)' "$CPU_TEMP_LOG" 2>/dev/null | sort -rn | head -1)
  cpu_high=$(echo "$cpu_peak" | awk -v t=$CPU_THRESHOLD '$1+0 > t')
  if [ -z "$cpu_peak" ]; then vrecord "CPU_TEMP" "WARN" "no samples captured"
  elif [ -z "$cpu_high" ]; then vrecord "CPU_TEMP" "PASS" "peak ${cpu_peak}C within ${CPU_THRESHOLD}C"
  else vrecord "CPU_TEMP" "WARN" "peak ${cpu_peak}C exceeded ${CPU_THRESHOLD}C"; fi
  [ -n "$cpu_peak" ] && vrecord_evidence "CPU_TEMP" "$(grep -m1 "${cpu_peak} degrees C" "$CPU_TEMP_LOG" 2>/dev/null)"

  local gpu_peak gpu_high
  gpu_peak=$(awk -F',' '/^\[/{gsub(/ /,"",$3); if ($3+0 > 0) print $3+0}' "$GPU_TEMP_LOG" 2>/dev/null | sort -rn | head -1)
  gpu_high=$(echo "$gpu_peak" | awk -v t=$GPU_THRESHOLD '$1+0 > t')
  if [ -z "$gpu_peak" ]; then vrecord "GPU_TEMP" "WARN" "no samples captured"
  elif [ -z "$gpu_high" ]; then vrecord "GPU_TEMP" "PASS" "peak ${gpu_peak}C within ${GPU_THRESHOLD}C"
  else vrecord "GPU_TEMP" "WARN" "peak ${gpu_peak}C exceeded ${GPU_THRESHOLD}C"; fi

  # Per-DIMM peaks name WHICH slot ran hottest; a pooled max can't point at a marginal module.
  local mem_peaks mem_peak mem_hot_slot mem_high
  mem_peaks=$(_qa_mem_peaks 2>/dev/null)
  if [ -n "$mem_peaks" ]; then
    local mem_hot; mem_hot=$(printf '%s\n' "$mem_peaks" | sort -t$'\t' -k2 -rn | head -1)
    mem_hot_slot=$(printf '%s' "$mem_hot" | cut -f1)
    mem_peak=$(printf '%s' "$mem_hot" | cut -f2)
    mem_high=$(echo "$mem_peak" | awk -v t=$MEM_THRESHOLD '$1+0 > t')
    if [ -z "$mem_high" ]; then
      vrecord "MEM_TEMP" "PASS" "peak ${mem_peak}C (DIMM ${mem_hot_slot}, hottest of $(printf '%s\n' "$mem_peaks" | wc -l) tracked) within ${MEM_THRESHOLD}C -- see $MEM_TEMP_LOG"
    else
      vrecord "MEM_TEMP" "WARN" "peak ${mem_peak}C (DIMM ${mem_hot_slot}) exceeded ${MEM_THRESHOLD}C -- see $MEM_TEMP_LOG"
    fi
    local mem_ev; mem_ev=$(grep -E "_${mem_hot_slot}[[:space:]]*\|" "$MEM_TEMP_LOG" 2>/dev/null | grep -m1 "${mem_peak} degrees C")
    [ -n "$mem_ev" ] && vrecord_evidence "MEM_TEMP" "$mem_ev"
  else
    if ipmitool sdr 2>/dev/null | grep -qi "temp_ddr"; then
      vrecord "MEM_TEMP" "WARN" "DIMM temp sensors exist on this platform but no samples were captured during the run -- see $MEM_TEMP_LOG"
    else
      vrecord "MEM_TEMP" "SKIP" "no per-DIMM IPMI temperature sensors found on this platform"
    fi
  fi
}

# Hard FAIL at 0 RPM per the SOP -- a stalled fan can throttle a healthy part.
check_fans() {
  vlog "━━━ FAN HEALTH CHECK ━━━"
  local rpm_min
  rpm_min=$(grep -oP '\d+(?=\s*RPM)' "$FAN_LOG" 2>/dev/null | sort -n | head -1)
  if [ -z "$rpm_min" ]; then
    vrecord "FAN" "WARN" "no fan RPM samples captured (no ipmitool fan sensors found) -- see $FAN_LOG"
  elif [ "$rpm_min" -eq 0 ]; then
    vrecord "FAN" "FAIL" "at least one fan reported 0 RPM during the run -- see $FAN_LOG"
  else
    vrecord "FAN" "PASS" "lowest RPM observed: ${rpm_min} (no stalled fan detected)"
  fi
}

check_oom() {
  local oom
  oom=$(dmesg 2>/dev/null | grep -i "killed process\|out of memory" | tail -3)
  # Same missing-PASS-branch shape as check_nvrm -- a clean run left OOM unset instead of PASS.
  if [ -n "$oom" ]; then
    vrecord "OOM" "WARN" "OOM events detected during run -- a torture pass may be invalid"
  else
    vrecord "OOM" "PASS" "no OOM events found in dmesg"
  fi
}

# Greps NVIDIA kernel-module (Xid) errors, which gpu-burn and DCGM can both miss.
check_nvrm() {
  local nvrm
  # Matches "Xid" specifically, not any NVRM line -- the latter caught the benign driver-load banner.
  nvrm=$(dmesg 2>/dev/null | grep -i "Xid" | tail -5)
  if [ -n "$nvrm" ]; then
    vrecord "NVRM" "WARN" "Xid (NVIDIA GPU/driver fault code) found in dmesg during run -- review dmesg manually"
    vrecord_evidence "NVRM" "$nvrm"
  else
    vrecord "NVRM" "PASS" "no Xid errors found in dmesg"
  fi
}

# Live ECC counts from EDAC sysfs, cumulative since boot, so reported as a since-boot total.
check_edac() {
  if [ ! -d /sys/devices/system/edac/mc ]; then
    vrecord "EDAC" "SKIP" "no EDAC sysfs interface -- ECC controller driver not loaded/present"
    return
  fi
  local ce_total=0 ue_total=0 f n
  for f in /sys/devices/system/edac/mc/mc*/ce_count; do
    [ -f "$f" ] || continue
    n=$(cat "$f" 2>/dev/null); ce_total=$((ce_total + ${n:-0}))
  done
  for f in /sys/devices/system/edac/mc/mc*/ue_count; do
    [ -f "$f" ] || continue
    n=$(cat "$f" 2>/dev/null); ue_total=$((ue_total + ${n:-0}))
  done
  if [ "$ue_total" -gt 0 ]; then
    vrecord "EDAC" "FAIL" "$ue_total uncorrectable ECC error(s) recorded (cumulative since last boot)"
  elif [ "$ce_total" -gt 0 ]; then
    vrecord "EDAC" "WARN" "$ce_total correctable ECC error(s) recorded (cumulative since last boot)"
  else
    vrecord "EDAC" "PASS" "0 correctable/uncorrectable ECC errors recorded"
  fi
  vrecord_evidence "EDAC" "correctable (ce_count) total: $ce_total   uncorrectable (ue_count) total: $ue_total   -- summed across $(ls -d /sys/devices/system/edac/mc/mc* 2>/dev/null | wc -l) memory controller(s)"
}

# Samples gpu-burn's GFLOPS for a large min-vs-max spread; pooled, so it flags THAT, not which GPU.
check_gpuburn_throttle() {
  local plog="${VAL_LOGDIR:-}/gpuburn.log"
  if [ ! -s "$plog" ]; then
    vrecord "GPU_THROTTLE" "SKIP" "no gpu-burn log to analyze"
    return
  fi
  local vals min max spread_pct
  # The decimal point is OPTIONAL: real output prints whole integers, which a decimal-required pattern missed.
  # Skipping a further 16 values clears gpu-burn's startup ramp, where every GPU briefly reads 0.
  vals=$(grep -oE '[0-9]+(\.[0-9]+)? Gflop/s' "$plog" | grep -oE '^[0-9]+(\.[0-9]+)?' | awk '$1+0 > 0' | tail -n +17)
  if [ -z "$vals" ]; then
    vrecord "GPU_THROTTLE" "SKIP" "no GFLOPS samples found in gpu-burn log -- see $plog"
    return
  fi
  min=$(printf '%s\n' "$vals" | sort -n | head -1)
  max=$(printf '%s\n' "$vals" | sort -n | tail -1)
  spread_pct=$(awk -v mn="$min" -v mx="$max" 'BEGIN{ if (mx>0) printf "%.1f", (mx-mn)/mx*100; else print "0" }')
  if awk -v s="$spread_pct" 'BEGIN{exit !(s>15)}'; then
    vrecord "GPU_THROTTLE" "WARN" "GFLOPS spread ${spread_pct}% over the run, pooled across all GPUs (min ${min}, max ${max}) -- possible throttling/degradation -- see $plog"
  else
    vrecord "GPU_THROTTLE" "PASS" "GFLOPS spread ${spread_pct}% over the run, pooled across all GPUs (min ${min}, max ${max}) -- see $plog"
  fi
  vrecord_evidence "GPU_THROTTLE" "min observed: ${min} Gflop/s   max observed: ${max} Gflop/s   spread: ${spread_pct}%   ($(printf '%s\n' "$vals" | wc -l) samples, pooled across all GPUs, post-ramp-up)"
}

install_mprime() {
  # mprime has no ARM build; stress-ng is the aarch64 substitute, already installed by Base Post Install.
  if [ "$ARCH" = "aarch64" ]; then
    command -v stress-ng >/dev/null 2>&1 || log_failure "stress-ng not found -- should have been installed by Base Post Install (option 2)"
    return
  fi
  if [ ! -f "$MPRIME_DIR/mprime" ]; then
    mkdir -p "$MPRIME_DIR"
    vlog "MPRIME: downloading..."
    wget -q -P "$MPRIME_DIR" "$(curl -s https://api.github.com/repos/shafferjohn/Prime95/releases/latest \
      | grep 'browser_download_url.*linux64' | cut -d '"' -f 4)" >> "$VAL_LOGDIR/mprime_install.log" 2>&1
    tar -xzf "$MPRIME_DIR"/p95v*tar.gz -C "$MPRIME_DIR" >> "$VAL_LOGDIR/mprime_install.log" 2>&1
    vlog "MPRIME: installed"
  else
    vlog "MPRIME: already installed"
  fi
}

# --- CUDA toolkit vs driver: PTX from an nvcc NEWER than the driver's CUDA fails to load ("unsupported
# toolchain") -- seen 2026-09-24: cuda-toolkit resolved to 13.4, driver 610.57 supports 13.3, gpu_burn died.

# Driver's supported CUDA "X.Y" from nvidia-smi; empty when no driver is loaded.
_driver_cuda_version() {
  nvidia-smi 2>/dev/null | grep -oE 'CUDA( UMD)? Version: *[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# nvcc release "X.Y" under a CUDA root; empty if none.
_nvcc_version() { "$1/bin/nvcc" --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+'; }

_ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Prints the CUDA root whose nvcc the loaded driver can run, installing cuda-toolkit-X-Y alongside when
# /usr/local/cuda is newer. stdout is the path ONLY -- every log/install line goes to stderr.
_cuda_root_for_driver() {
  local drv cur root pkg
  drv=$(_driver_cuda_version); cur=$(_nvcc_version /usr/local/cuda)
  if [ -z "$drv" ] || [ -z "$cur" ] || ! _ver_gt "$cur" "$drv"; then
    echo /usr/local/cuda; return 0
  fi
  root="/usr/local/cuda-$drv"
  pkg="cuda-toolkit-${drv/./-}"
  if [ -z "$(_nvcc_version "$root")" ]; then
    vlog "CUDA: toolkit $cur is newer than the driver's CUDA $drv -- installing $pkg alongside." >&2
    . /etc/os-release
    if [ "$ID" = "ubuntu" ]; then install_apt_packages "$pkg" >&2; else install_dnf_packages "$pkg" >&2; fi
  fi
  if [ -n "$(_nvcc_version "$root")" ]; then
    echo "$root"
  else
    vlog "CUDA: $pkg unavailable -- building with $cur; GPU tests may fail to load (unsupported toolchain)." >&2
    echo /usr/local/cuda
  fi
}

install_gpuburn() {
  local cuda_root stamp="$GPUBURN_DIR/.exx_build_cuda"
  cuda_root=$(_cuda_root_for_driver)
  # A binary built by a toolkit the driver can't run loads nothing -- rebuild when the toolkit changed.
  if [ -f "$GPUBURN_DIR/gpu_burn" ] && [ "$(cat "$stamp" 2>/dev/null)" != "$cuda_root $(_nvcc_version "$cuda_root")" ]; then
    vlog "GPU-BURN: built with a different CUDA toolkit than $cuda_root ($(_nvcc_version "$cuda_root")) -- rebuilding."
    (cd "$GPUBURN_DIR" && make clean) >> "$VAL_LOGDIR/gpuburn_install.log" 2>&1
    rm -f "$GPUBURN_DIR/gpu_burn"
  fi
  if [ ! -f "$GPUBURN_DIR/gpu_burn" ]; then
    vlog "GPU-BURN: cloning + building (CUDA $(_nvcc_version "$cuda_root") at $cuda_root)..."
    [ -d "$GPUBURN_DIR/.git" ] || git clone https://github.com/wilicc/gpu-burn "$GPUBURN_DIR" >> "$VAL_LOGDIR/gpuburn_install.log" 2>&1
    if [ "$ARCH" = "aarch64" ]; then
      # Only the Makefile needs ARM changes: COMPUTE=75 (Turing) and lib64, which is "lib" on aarch64.
      sed -i 's/COMPUTE ?= 75/COMPUTE=90/; s#/lib64#/lib#g' "$GPUBURN_DIR/Makefile" 2>/dev/null
      . /etc/os-release
      if [[ "$ID" == "ubuntu" ]]; then
        # Confirmed: gpu-burn's Ubuntu aarch64 build needs these explicitly, not pulled in by base_install.
        install_apt_packages "cuda-nvcc-13-2" "libcublas-dev-13-2"
      else
        # Rocky/dnf aarch64 package names were never verified -- if the build fails there, check here first.
        vlog "GPU-BURN: WARNING -- Rocky/dnf aarch64 build-dependency package names for gpu-burn are unverified. If the build below fails, check for missing CUDA nvcc/cuBLAS-devel packages manually."
      fi
    fi
    if (cd "$GPUBURN_DIR" && make CUDAPATH="$cuda_root") >> "$VAL_LOGDIR/gpuburn_install.log" 2>&1 && [ -f "$GPUBURN_DIR/gpu_burn" ]; then
      echo "$cuda_root $(_nvcc_version "$cuda_root")" > "$stamp"
      vlog "GPU-BURN: built"
    else
      vlog "GPU-BURN: WARNING -- build failed (see $VAL_LOGDIR/gpuburn_install.log). Likely missing CUDA toolkit/cuBLAS dev headers -- run GPU Post Install (option 3) first."
    fi
  else
    vlog "GPU-BURN: already built"
  fi
}

# --- FLOATING POINT ACCURACY: cuda-samples matrixMul, which carries its own host-computed reference comparison. ---
# cmake targets that one sample dir: the top-level CMakeLists pulls in samples needing optional libraries.
install_fp_accuracy_test() {
  if [ -x "$FPACC_DIR/matrixMul" ]; then
    vlog "FP-ACCURACY: already built"
    return
  fi
  vlog "FP-ACCURACY: cloning cuda-samples + building matrixMul..."
  local ilog="$VAL_LOGDIR/fp_accuracy_install.log"
  rm -rf "$FPACC_DIR"
  git clone --depth 1 https://github.com/NVIDIA/cuda-samples "$FPACC_DIR" >> "$ilog" 2>&1

  if ! command -v cmake >/dev/null 2>&1; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then install_apt_packages "cmake"
    else install_dnf_packages "cmake"; fi
  fi

  local sample_dir="$FPACC_DIR/cpp/0_Introduction/matrixMul"
  local build_dir="$sample_dir/build"

  # nvcc isn't on PATH in a sudo/SSH shell; /usr/local/cuda is NVIDIA's maintained fallback.
  # Not `command -v nvcc`: that can be a toolkit newer than the driver (see _cuda_root_for_driver).
  local nvcc_bin; nvcc_bin="$(_cuda_root_for_driver)/bin/nvcc"

  # "native" needs cmake >= 3.24; Ubuntu 22.04 ships 3.22, so fall back to the full architecture list.
  if ! (cmake -S "$sample_dir" -B "$build_dir" -DCMAKE_CUDA_COMPILER="$nvcc_bin" -DCMAKE_CUDA_ARCHITECTURES=native) >> "$ilog" 2>&1; then
    vlog "FP-ACCURACY: 'native' arch detection unavailable (cmake <3.24?) -- retrying with the full supported-architecture list."
    rm -rf "$build_dir"
    cmake -S "$sample_dir" -B "$build_dir" -DCMAKE_CUDA_COMPILER="$nvcc_bin" -DCMAKE_CUDA_ARCHITECTURES="75;80;86;87;89;90;100;103;107;110;120" >> "$ilog" 2>&1
  fi
  cmake --build "$build_dir" -j"$(nproc)" >> "$ilog" 2>&1

  local built_bin
  built_bin=$(find "$build_dir" -type f -name matrixMul -perm -u+x 2>/dev/null | head -1)
  if [ -n "$built_bin" ]; then
    cp "$built_bin" "$FPACC_DIR/matrixMul"
    vlog "FP-ACCURACY: built"
  else
    vlog "FP-ACCURACY: WARNING -- build failed (see $ilog). Requires CUDA toolkit + cmake -- run GPU Post Install (option 3) first."
  fi
}

run_fp_accuracy_test() {
  local plog="$VAL_LOGDIR/fp_accuracy.log"
  vlog "━━━ GPU: FLOATING POINT ACCURACY (matrixMul, per-GPU) ━━━"
  mark_temp "FP-ACCURACY"
  : > "$plog"
  if [ ! -x "$FPACC_DIR/matrixMul" ]; then
    vrecord "FP-ACCURACY" "SKIP" "matrixMul not built -- see $VAL_LOGDIR/fp_accuracy_install.log"
    return
  fi
  local gpu_count; gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
  if [ "$gpu_count" -eq 0 ]; then
    vrecord "FP-ACCURACY" "SKIP" "no NVIDIA GPUs detected"
    return
  fi

  local idx gname size
  for ((idx=0; idx<gpu_count; idx++)); do
    gname=$(nvidia-smi --query-gpu=name --format=csv,noheader -i "$idx" 2>/dev/null)
    for size in "${FP_ACCURACY_SIZES[@]}"; do
      {
        echo "================ GPU $idx ($gname) -- size ${size}x${size} ================"
        "$FPACC_DIR/matrixMul" -device="$idx" -wA="$size" -hA="$size" -wB="$size" -hB="$size"
        echo "RC=$?"
      } >> "$plog" 2>&1
    done
  done

  _fp_accuracy_generate_report "$plog"
  local report="$VAL_LOGDIR/fp_accuracy_report.txt"
  if grep -q "Result = FAIL" "$plog"; then
    vrecord "FP-ACCURACY" "FAIL" "one or more GPU/size combinations failed -- see $report"
    vrecord_evidence "FP-ACCURACY" "$(grep -B2 "Result = FAIL" "$plog" | grep -v '^--$')"
  elif grep -q "Result = PASS" "$plog"; then
    vrecord "FP-ACCURACY" "PASS" "all $gpu_count GPU(s) x ${#FP_ACCURACY_SIZES[@]} size(s) passed -- see $report"
    vrecord_evidence "FP-ACCURACY" "$gpu_count GPU(s) x ${#FP_ACCURACY_SIZES[@]} size(s) = $(grep -c 'Result = PASS' "$plog") 'Result = PASS' matches, 0 'Result = FAIL' matches"
  else
    vrecord "FP-ACCURACY" "WARN" "no explicit PASS/FAIL result found in tool output -- see $report"
  fi
}

# Builds the per-GPU/per-size report from $plog rather than keeping a second source of truth.
_fp_accuracy_generate_report() {
  local plog="$1"
  local report="$VAL_LOGDIR/fp_accuracy_report.txt"
  local total pass fail
  total=$(grep -c "Result = " "$plog" 2>/dev/null)
  pass=$(grep -c "Result = PASS" "$plog" 2>/dev/null)
  fail=$(grep -c "Result = FAIL" "$plog" 2>/dev/null)
  {
    echo "#======================================================================#"
    echo "FLOATING POINT ACCURACY REPORT"
    echo "$(hostname) -- $(date '+%Y-%m-%d %H:%M:%S')"
    echo "#======================================================================#"
    echo "Tool:  NVIDIA cuda-samples 'matrixMul' -- host-vs-device compute compare"
    echo "       per GPU (relative-error tolerance eps=1e-6). Not a stress test --"
    echo "       gpu-burn (see GPU-Burn Test Result) already covers thermal/power"
    echo "       stress; this specifically checks compute correctness."
    echo "Sizes swept per GPU (NxN square matrices): ${FP_ACCURACY_SIZES[*]}"
    echo ""
    echo "--- Per-GPU / per-size summary ---"
    awk '
      /^================ GPU/ { print; next }
      /^Performance=/         { print "  " $0; next }
      /Result = /             { print "  " $0; print ""; next }
    ' "$plog"
    echo "TOTAL RUNS: ${total:-0}   PASS: ${pass:-0}   FAIL: ${fail:-0}"
    echo ""
    echo "--- Full raw tool output (every GPU/size combination) ---"
    cat "$plog"
  } > "$report"
  chown "$REAL_USER:$REAL_USER" "$report" 2>/dev/null
}

list_drives() {
  # Excludes USB devices -- smartctl needs an explicit -d type and would otherwise read as a false failure.
  lsblk -dno NAME,TYPE,TRAN | awk '$2=="disk" && $3!="usb"{print "/dev/"$1}'
}

# --- Drive presence tracking, keyed on SERIAL not path: a dead drive can leave a present node. ---

# Writes one path/serial/model line per present drive, alongside snapshot_smart's own baseline.
_snapshot_drive_inventory() {
  [ -n "${DRIVE_INVENTORY_BASELINE:-}" ] || return
  # Reset the already-alerted marker here -- $STATE_DIR is no longer cleared per run.
  rm -f "$STATE_DIR/.drive_presence_alerted" 2>/dev/null
  : > "$DRIVE_INVENTORY_BASELINE"
  local d
  for d in $(list_drives); do
    get_drive_metadata "$d"
    printf '%s\t%s\t%s\n' "$d" "$DRIVE_SERIAL" "$DRIVE_MODEL" >> "$DRIVE_INVENTORY_BASELINE"
  done
  chown "$REAL_USER:$REAL_USER" "$DRIVE_INVENTORY_BASELINE" 2>/dev/null
}

# One pass confirming every baseline SERIAL is still visible under SOME path; each problem logged once.
_drive_presence_tick() {
  [ -s "${DRIVE_INVENTORY_BASELINE:-}" ] || return
  local alerted="$STATE_DIR/.drive_presence_alerted"
  local -A current_serials=()
  local d
  for d in $(list_drives); do
    get_drive_metadata "$d"
    current_serials["$DRIVE_SERIAL"]="$d"
  done
  local path serial model
  while IFS=$'\t' read -r path serial model; do
    [ -z "$serial" ] && continue
    grep -qxF "$serial" "$alerted" 2>/dev/null && continue
    if [ -z "${current_serials[$serial]+x}" ]; then
      echo "$serial" >> "$alerted"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] DRIVE DROPPED DURING TESTING: $path (original path)  model=$model  serial=$serial  -- serial no longer found under any current /dev path" | tee -a "$DRIVE_PRESENCE_LOG"
    fi
  done < "$DRIVE_INVENTORY_BASELINE"
}

# Final PASS/FAIL from the same check_* chain. SKIP with no baseline is legitimate.
check_drive_presence() {
  vlog "━━━ DRIVE PRESENCE CHECK ━━━"
  if [ ! -s "${DRIVE_INVENTORY_BASELINE:-}" ]; then
    vrecord "DRIVE_PRESENCE" "SKIP" "no drive inventory captured at test start"
    return
  fi
  local total; total=$(wc -l < "$DRIVE_INVENTORY_BASELINE")
  if [ -s "$DRIVE_PRESENCE_LOG" ]; then
    vrecord "DRIVE_PRESENCE" "FAIL" "one or more of the $total drive(s) present at test start went missing during the run -- see $DRIVE_PRESENCE_LOG"
    vrecord_evidence "DRIVE_PRESENCE" "$(cat "$DRIVE_PRESENCE_LOG")"
  else
    vrecord "DRIVE_PRESENCE" "PASS" "all $total drive(s) present at test start (by serial number) were still present throughout the run"
  fi
}

snapshot_smart() {  # snapshot_smart <outfile>
  local out="$1"; : > "$out"
  local d
  for d in $(list_drives); do
    {
      echo "### $d"
      smartctl -A "$d" 2>/dev/null | awk '
        /Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count/ {print $2"="$NF}
        /Media_and_Data_Integrity_Errors|Available_Spare|Percentage_Used|Media and Data Integrity Errors/ {print $0}
      '
    } >> "$out"
  done
}

run_mprime() {
  local plog="$VAL_LOGDIR/mprime.log"
  if [ "$ARCH" = "aarch64" ]; then
    _run_cpu_stress_ng "$plog"
    return
  fi
  vlog "━━━ CPU: MPRIME (${PHASE_DURATION}s) ━━━"
  mark_temp "MPRIME"
  local mem cores threads
  mem=$(free -m | awk -v p=$MEM_PERCENT '/^Mem:/{print int($2 * p / 100)}')
  cores=$(nproc)
  threads=$(awk "BEGIN{print int($cores * 0.95)}")
  cat > "$MPRIME_DIR/prime.txt" << EOF
TortureSubtest=4
TortureFast=1
TortureMem=$mem
TortureTime=6
TortureHyperthreading=1
NumCPUs=$threads
EOF
  rm -f "$MPRIME_DIR/results.txt"
  # Raw output to the log file, never the terminal -- the live dashboard replaces mprime's chatter.
  timeout "$PHASE_DURATION" "$MPRIME_DIR/mprime" -t < /dev/null >> "$plog" 2>&1
  local rc=$?
  # Persisted to disk so a backgrounded subshell caller can recover it -- subshells don't return variables.
  echo "$rc" > "$plog.rc"
  evaluate_mprime "$MPRIME_DIR/results.txt" "$plog" "$rc" "MPRIME"
}

# _run_cpu_stress_ng <plog> -- aarch64 CPU path. stress-ng exits 0 on a clean finish, OPPOSITE polarity from mprime.
# Here rc=124 means stress-ng hung: a FAIL. Do not reuse evaluate_mprime's logic here.
_run_cpu_stress_ng() {  # _run_cpu_stress_ng <plog>
  local plog="$1"
  vlog "━━━ CPU: STRESS-NG (${PHASE_DURATION}s, aarch64 -- mprime has no ARM build) ━━━"
  mark_temp "MPRIME"
  local cores; cores=$(nproc)
  timeout "$((PHASE_DURATION + 30))" stress-ng --cpu "$cores" --matrix "$cores" --verify --metrics-brief --timeout "${PHASE_DURATION}s" > "$plog" 2>&1
  local rc=$?
  echo "$rc" > "$plog.rc"  # see comment in the x86 run_mprime path -- survives backgrounding
  _evaluate_stress_ng "$plog" "$rc" "MPRIME"
}

_evaluate_stress_ng() {  # <plog> <rc> <label>
  local plog="$1" rc="$2" label="$3"
  if grep -qiE "error|fail" "$plog"; then
    vrecord "$label" "FAIL" "stress-ng reported errors -- see $plog"
    vrecord_evidence "$label" "$(grep -iE "error|fail" "$plog" | head -10)"
  elif [ "$rc" -eq 124 ]; then vrecord "$label" "FAIL" "stress-ng hung and had to be force-killed by the outer safety-net timeout (rc=124) -- see $plog"
  elif [ "$rc" -ne 0 ]; then vrecord "$label" "FAIL" "stress-ng exited abnormally (rc=$rc) -- see $plog"
  else
    vrecord "$label" "PASS" "stress-ng completed cleanly, no errors -- see $plog"
    local sng_ev; sng_ev=$(tail -8 "$plog")
    [ -n "$sng_ev" ] && vrecord_evidence "$label" "$sng_ev"
  fi
}

evaluate_mprime() {  # <results.txt> <plog> <rc> <label>
  local results="$1" plog="$2" rc="$3" label="$4"
  local fatal passed
  fatal=$({ cat "$results" "$plog"; } 2>/dev/null | grep -iE "FATAL ERROR|TORTURE TEST FAILED|hardware failure")
  passed=$({ cat "$results" "$plog"; } 2>/dev/null | grep -iE "self-test.*passed|torture test completed|passed" | head -1)
  if [ -n "$fatal" ]; then
    vrecord "$label" "FAIL" "${fatal} -- see $plog"
    vrecord_evidence "$label" "$fatal"
  elif [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then vrecord "$label" "FAIL" "mprime exited abnormally (rc=$rc) -- see $plog"
  elif [ -z "$passed" ]; then vrecord "$label" "WARN" "no explicit pass signal found (rc=$rc) -- see $plog"
  else
    vrecord "$label" "PASS" "no fatal errors, self-tests passed -- see $plog"
    vrecord_evidence "$label" "$passed"
  fi
}

run_gpuburn() {
  local plog="$VAL_LOGDIR/gpuburn.log"
  vlog "━━━ GPU: GPU-BURN (${PHASE_DURATION}s) ━━━"
  mark_temp "GPU-BURN"
  # gpu_burn redraws with \r; tr splits it, and the filter always keeps verdict lines, sampling the rest.
  (cd "$GPUBURN_DIR" && ./gpu_burn "$PHASE_DURATION") 2>&1 \
    | tr '\r' '\n' \
    | awk '/OK$|FAULTY|errors: [1-9]/ || NR % 60 == 0' \
    >> "$plog"
  local rc=${PIPESTATUS[0]}
  echo "$rc" > "$plog.rc"  # see comment in run_mprime -- survives backgrounding
  evaluate_gpuburn "$plog" "$rc" "GPU-BURN"
}

evaluate_gpuburn() {  # <plog> <rc> <label>
  local plog="$1" rc="$2" label="$3"
  if grep -qi "FAULTY" "$plog"; then
    vrecord "$label" "FAIL" "gpu_burn reported a FAULTY GPU -- see $plog"
    vrecord_evidence "$label" "$(grep -i "FAULTY" "$plog" | head -8)"
  elif [ "$rc" -ne 0 ]; then vrecord "$label" "FAIL" "gpu_burn exited non-zero (rc=$rc) -- see $plog"
  elif grep -q "GPU .*: OK" "$plog"; then
    vrecord "$label" "PASS" "all GPUs OK -- see $plog"
    vrecord_evidence "$label" "$(grep "GPU .*: OK" "$plog" | tail -8)"
  else vrecord "$label" "WARN" "no OK verdict found (rc=$rc) -- see $plog"; fi
}

run_memory() {
  vlog "━━━ MEMORY: STRESSAPPTEST (${PHASE_DURATION}s) ━━━"
  mark_temp "MEMORY"
  if ! command -v stressapptest >/dev/null 2>&1; then
    vrecord "MEMORY" "SKIP" "stressapptest not installed"; return
  fi
  local plog="$VAL_LOGDIR/memory.log" mb
  mb=$(free -m | awk -v p=$MEM_PERCENT '/^Mem:/{print int($2 * p / 100)}')
  # Straight to the log file, never the terminal -- same as run_mprime/run_gpuburn.
  stressapptest -M "$mb" -s "$PHASE_DURATION" -W >> "$plog" 2>&1
  local rc=$?
  echo "$rc" > "$plog.rc"  # see comment in run_mprime -- survives backgrounding
  evaluate_memory "$plog" "$rc" "MEMORY"
}

evaluate_memory() {  # <plog> <rc> <label>
  local plog="$1" rc="$2" label="$3"
  if [ "$rc" -eq 0 ] && grep -q "Status: PASS" "$plog"; then
    vrecord "$label" "PASS" "stressapptest clean -- see $plog"
    vrecord_evidence "$label" "$(grep "Status: PASS" "$plog" | tail -1)"
  else
    vrecord "$label" "FAIL" "stressapptest reported errors (rc=$rc) -- see $plog"
    local sat_ev; sat_ev=$(tail -10 "$plog")
    [ -n "$sat_ev" ] && vrecord_evidence "$label" "$sat_ev"
  fi
}

# Runs CPU/Memory/GPU concurrently, each backgrounded; the parent re-runs evaluate_* against their logs.
run_concurrent_stress() {
  local hrs=$((CONCURRENT_STRESS_DURATION / 3600))
  vlog "━━━ CONCURRENT: CPU + MEMORY + GPU, ALL AT ONCE (${CONCURRENT_STRESS_DURATION}s / ${hrs}h) ━━━"
  mark_temp "CONCURRENT-STRESS"
  echo "[INFO] Launching CPU (mprime), Memory (stressapptest), and GPU (gpu-burn) simultaneously for ${hrs} hour(s)."
  echo "       Concurrent-mode memory split: mprime ${CONCURRENT_MPRIME_MEM_PCT}% / stressapptest ${CONCURRENT_STRESSAPP_MEM_PCT}% of RAM."
  echo "       If one test exits or fails early, the others keep running to completion -- failures are logged, not aborted."

  local pids=()

  ( MEM_PERCENT="$CONCURRENT_MPRIME_MEM_PCT" PHASE_DURATION="$CONCURRENT_STRESS_DURATION" run_mprime ) &
  pids+=("$!")

  ( MEM_PERCENT="$CONCURRENT_STRESSAPP_MEM_PCT" PHASE_DURATION="$CONCURRENT_STRESS_DURATION" run_memory ) &
  pids+=("$!")

  ( PHASE_DURATION="$CONCURRENT_STRESS_DURATION" run_gpuburn ) &
  pids+=("$!")

  echo "[INFO] Waiting for all 3 concurrent test(s) to complete (~${hrs} hour(s))..."
  wait "${pids[@]}"

  local mprime_rc memory_rc gpuburn_rc
  mprime_rc=$(cat "$VAL_LOGDIR/mprime.log.rc" 2>/dev/null || echo 1)
  memory_rc=$(cat "$VAL_LOGDIR/memory.log.rc" 2>/dev/null || echo 1)
  gpuburn_rc=$(cat "$VAL_LOGDIR/gpuburn.log.rc" 2>/dev/null || echo 1)

  if [ "$ARCH" = "aarch64" ]; then
    _evaluate_stress_ng "$VAL_LOGDIR/mprime.log" "$mprime_rc" "MPRIME-CONCURRENT"
  else
    evaluate_mprime "$MPRIME_DIR/results.txt" "$VAL_LOGDIR/mprime.log" "$mprime_rc" "MPRIME-CONCURRENT"
  fi
  evaluate_memory "$VAL_LOGDIR/memory.log" "$memory_rc" "MEMORY-CONCURRENT"
  evaluate_gpuburn "$VAL_LOGDIR/gpuburn.log" "$gpuburn_rc" "GPU-BURN-CONCURRENT"
}

# Sequential: DCGM, then CPU+Memory via mprime (its torture test covers memory), then GPU-burn.
run_sequential_validation() {
  mark_temp "DCGM"
  _dcgm_run "${DCGM_LEVEL_OVERRIDE:-4}"
  run_fp_accuracy_test

  PHASE_DURATION="$SEQUENTIAL_TEST_DURATION"
  vlog "━━━ SEQUENTIAL: CPU+MEMORY (mprime, combined, ${SEQUENTIAL_TEST_DURATION}s) ━━━"
  run_mprime
  vlog "━━━ SEQUENTIAL: GPU (gpu-burn, ${SEQUENTIAL_TEST_DURATION}s) ━━━"
  run_gpuburn
}

run_smartctl() {
  local plog="$VAL_LOGDIR/smartctl.log"
  vlog "━━━ SMARTCTL ━━━"
  mark_temp "SMARTCTL"
  local drives; drives=$(list_drives)
  if [ -z "$drives" ]; then vrecord "SMARTCTL" "WARN" "no drives detected (behind RAID/HBA? needs -d)"; return; fi

  local overall="PASS" evidence=""
  for drive in $drives; do
    {
      echo "==================== $drive ===================="
      echo "----- smartctl -x -----"; smartctl -x "$drive" 2>&1
      echo "----- smartctl -H -----"; smartctl -H "$drive" 2>&1
    } >> "$plog"
    local health; health=$(smartctl -H "$drive" 2>&1 | grep -iE "overall-health|SMART Health Status")
    evidence+="$drive: ${health:-no health line}"$'\n'
    if echo "$health" | grep -qiE "PASSED|OK"; then vlog "SMARTCTL: $drive PASS - ${health#*: }"
    else vlog "SMARTCTL: $drive FAIL - ${health:-no health line}"; overall="FAIL"; fi
  done

  snapshot_smart "$SMART_AFTER"
  if [ -s "$SMART_BEFORE" ]; then
    local d; d=$(diff "$SMART_BEFORE" "$SMART_AFTER")
    if [ -n "$d" ]; then
      vlog "SMARTCTL: counters CHANGED during stress"; overall="WARN"
      evidence+="Counter drift vs pre-run baseline:"$'\n'"$d"$'\n'
    else vlog "SMARTCTL: no counter drift vs baseline"; fi
  fi
  vrecord "SMARTCTL" "$overall" "smartctl health check -- see $plog"
  vrecord_evidence "SMARTCTL" "$evidence"
}

print_val_summary() {
  # The clean spec-and-PASS/FAIL artifact behind the SOP's Validation Summary Report; appends across a session.
  local summary_file="${VAL_LOGDIR:-$LOG_DIR}/VALIDATION_SUMMARY.txt"
  local overall="PASS" phase
  for phase in "${!RESULTS[@]}"; do
    case "${RESULTS[$phase]}" in
      FAIL*) overall="FAIL" ;;
      WARN*) [ "$overall" = "PASS" ] && overall="WARN" ;;
    esac
  done
  {
    echo "━━━━━━━━━━━━━━━━━━━━ VALIDATION SUMMARY ━━━━━━━━━━━━━━━━━━━━"
    echo "$(hostname) -- $(date '+%Y-%m-%d %H:%M:%S')"
    for phase in "${!RESULTS[@]}"; do
      printf '  %-16s %s\n' "$phase" "${RESULTS[$phase]}"
    done
    echo "OVERALL: $overall"
  } | tee -a "$summary_file"
}

_prompt_duration() {
  # Only a CLI-supplied duration skips the prompt. Testing PHASE_DURATION itself would make a
  # second Live-mode test in the same session silently reuse the first test's answer.
  [ -n "$PHASE_DURATION_FROM_CLI" ] && return 0
  local d
  read -rp "Duration in seconds [default ${DEFAULT_TEST_DURATION}]: " d
  PHASE_DURATION="${d:-$DEFAULT_TEST_DURATION}"
}

storage_validation_menu() {
  _ensure_system_sn_confirmed
  get_cpu_threads
  verify_environment_templates
  run_storage_topology_menu
}

# Single-test bodies. Self-contained and silent on stdin so they can be detached; duration arrives
# via PHASE_DURATION, set either by _prompt_duration inline or by --phase-duration on a re-exec.
_run_cpu_body() {
  _init_validation_paths
  install_mprime; _start_dashboard "cpu"; run_mprime; _stop_dashboard; print_val_summary
}

_run_mem_body() {
  _init_validation_paths
  _start_dashboard "mem"; run_memory; _stop_dashboard; print_val_summary
}

_run_gpu_body() {
  _init_validation_paths
  install_gpuburn; _start_dashboard "gpu"; run_gpuburn; _stop_dashboard; print_val_summary
}

_run_smart_body() {
  _init_validation_paths
  snapshot_smart "$SMART_BEFORE"; run_smartctl; print_val_summary
}

# Executes an ALREADY-COLLECTED storage plan. Collection prompts, so it must finish before detaching.
_run_storage_plan_body() {
  _init_validation_paths
  get_cpu_threads
  verify_environment_templates
  ie_load_and_execute_plan
  print_val_summary
}

# Self-contained option bodies, callable inline or via detached re-exec with none of the menu's state.
_run_option6_body() {
  _init_validation_paths
  RESULTS=()
  # A full run supersedes everything -- clear the log folder and results state rather than layering.
  rm -rf "${VAL_LOGDIR:?}"/* "$RESULTS_STATE_FILE" 2>/dev/null
  RUN_START_EPOCH=$(date +%s)
  RUN_START_TS=$(date '+%Y-%m-%d %H:%M:%S')
  # NoOS/PXE-live: --noos skipped Base Install, so install the toolchain now (after the rm, so the
  # prep log survives and is archived), before anything below uses fio/stressapptest/nvcc/etc.
  [ -n "$NOOS_MODE" ] && _noos_prepare_os
  # No _prompt_duration -- the concurrent run uses the fixed CONCURRENT_STRESS_DURATION.
  install_mprime; install_gpuburn; install_fp_accuracy_test
  snapshot_smart "$SMART_BEFORE"
  _snapshot_drive_inventory
  # Pre-run reference material, archive-only; a run always overwrites the DEFAULT collection.
  _diag_init_collection default
  collect_system_logs before
  collect_btt_bundle
  # Precondition every plan drive in parallel, up front and ISOLATED from the compute stress that
  # follows (chosen policy): the compute CPU/mem/GPU results stay clean, and the per-volume storage
  # steps later skip straight to the QD sweep + measurement. Bounded by the slowest single drive, not
  # the per-drive sum -- so a 24-drive box preconditions in roughly one drive-fill, not 24.
  _precondition_all_plan_drives
  start_temp_monitors
  _status_ticker "cpu mem gpu" &
  STATUS_TICKER_PID=$!
  run_concurrent_stress
  # Post-hoc GPU health check, level 2: level 3+ triggers this box's confirmed fatal PCIe fault.
  mark_temp "DCGM"
  _dcgm_run "${DCGM_LEVEL_OVERRIDE:-2}"
  run_fp_accuracy_test
  # Kept after the concurrent run -- FIO can't reach rated bandwidth while CPU/memory are loaded.
  ie_load_and_execute_plan
  stop_temp_monitors
  kill "$STATUS_TICKER_PID" 2>/dev/null
  run_smartctl
  # Post-run capture taken before the check_* functions, which do their own live greps regardless.
  collect_system_logs after
  _diag_finalize_run
  check_temps; check_fans; check_oom; check_nvrm; check_edac; check_gpuburn_throttle; check_drive_presence
  # NoOS systems ship blank -- tear every test structure back down before the report is
  # written, so the report itself records that it happened.
  [ -n "$NOOS_MODE" ] && _noos_teardown_storage
  print_val_summary
  generate_qa_report
  mark_temp "COMPLETE"
  write_status
}

_run_option7_body() {
  _init_validation_paths
  RESULTS=()
  # See _run_option6_body -- same "full run replaces everything" rule.
  rm -rf "${VAL_LOGDIR:?}"/* "$RESULTS_STATE_FILE" 2>/dev/null
  RUN_START_EPOCH=$(date +%s)
  RUN_START_TS=$(date '+%Y-%m-%d %H:%M:%S')
  # No _prompt_duration -- each stage runs the fixed SEQUENTIAL_TEST_DURATION.
  install_mprime; install_gpuburn; install_fp_accuracy_test
  snapshot_smart "$SMART_BEFORE"
  _snapshot_drive_inventory
  _diag_init_collection default   # see _run_option6_body -- archive-only,
  collect_system_logs before      # written to the diag tree, not $VAL_LOGDIR
  collect_btt_bundle
  # Precondition every plan drive in parallel, up front and ISOLATED from the compute stress that
  # follows (chosen policy): the compute CPU/mem/GPU results stay clean, and the per-volume storage
  # steps later skip straight to the QD sweep + measurement. Bounded by the slowest single drive, not
  # the per-drive sum -- so a 24-drive box preconditions in roughly one drive-fill, not 24.
  _precondition_all_plan_drives
  start_temp_monitors
  _status_ticker "cpu mem gpu" &
  STATUS_TICKER_PID=$!
  run_sequential_validation
  ie_load_and_execute_plan
  stop_temp_monitors
  kill "$STATUS_TICKER_PID" 2>/dev/null
  run_smartctl
  collect_system_logs after
  _diag_finalize_run
  check_temps; check_fans; check_oom; check_nvrm; check_edac; check_gpuburn_throttle; check_drive_presence
  print_val_summary
  generate_qa_report
  mark_temp "COMPLETE"
  write_status
}

# Combined (Stress Only): the same concurrent load minus DCGM and Floating Point Accuracy.
_run_option8_body() {
  _init_validation_paths
  RESULTS=()
  rm -rf "${VAL_LOGDIR:?}"/* "$RESULTS_STATE_FILE" 2>/dev/null
  RUN_START_EPOCH=$(date +%s)
  RUN_START_TS=$(date '+%Y-%m-%d %H:%M:%S')
  install_mprime; install_gpuburn
  snapshot_smart "$SMART_BEFORE"
  _snapshot_drive_inventory
  _diag_init_collection default   # see _run_option6_body -- archive-only,
  collect_system_logs before      # written to the diag tree, not $VAL_LOGDIR
  collect_btt_bundle
  # Precondition every plan drive in parallel, up front and ISOLATED from the compute stress that
  # follows (chosen policy): the compute CPU/mem/GPU results stay clean, and the per-volume storage
  # steps later skip straight to the QD sweep + measurement. Bounded by the slowest single drive, not
  # the per-drive sum -- so a 24-drive box preconditions in roughly one drive-fill, not 24.
  _precondition_all_plan_drives
  start_temp_monitors
  _status_ticker "cpu mem gpu" &
  STATUS_TICKER_PID=$!
  run_concurrent_stress
  ie_load_and_execute_plan
  stop_temp_monitors
  kill "$STATUS_TICKER_PID" 2>/dev/null
  run_smartctl
  collect_system_logs after
  _diag_finalize_run
  check_temps; check_fans; check_oom; check_nvrm; check_edac; check_gpuburn_throttle; check_drive_presence
  print_val_summary
  generate_qa_report
  mark_temp "COMPLETE"
  write_status
}

# ======================================================================================
# AMD GPU VALIDATION (ROCm) -- IE request #3, "full ROCm parity" with the NVIDIA path.
#   discovery + monitoring : amd-smi (preferred) or rocm-smi
#   burn-in                : ROCm Validation Suite (rvs), GST GPU-stress module  [gpu_burn analog]
#   bandwidth              : rocm-bandwidth-test                                 [nvbandwidth analog]
#
# NOTE (2026-09-22): implemented to AMD's documented tooling but NOT YET RUN on real AMD hardware --
# the lab box (.80) is NVIDIA-only. Treat as untested until validated on an Instinct/Radeon system;
# the most likely breakage points are ROCm repo/package names per distro and the rvs conf schema.
# ======================================================================================

# Detects AMD GPUs without ROCm installed yet: /dev/kfd (amdgpu compute node) AND an AMD PCI display
# device. Either alone can false-positive (kfd on APUs, PCI match on a non-compute part), so require both.
_amd_gpu_present() {
  [ -e /dev/kfd ] || return 1
  lspci -nn 2>/dev/null | grep -Ei 'VGA|Display|3D controller' | grep -Eiq 'Advanced Micro Devices|AMD/ATI'
}

# Echoes the AMD SMI tool to use -- amd-smi (current) preferred over rocm-smi (legacy) when both exist.
_amd_smi_bin() {
  if command -v amd-smi >/dev/null 2>&1; then echo "amd-smi"
  elif command -v rocm-smi >/dev/null 2>&1; then echo "rocm-smi"; fi
}

# Installs the ROCm validation tooling (smi + rvs + bandwidth test) from AMD's repos. Idempotent -- skips
# when rvs and an smi tool are already present. Repo/package names are AMD's documented ones but (see the
# module NOTE) unverified live; if AMD's repo isn't configured it warns and points at rocm.docs.amd.com.
rocm_install() {
  . /etc/os-release
  if command -v rvs >/dev/null 2>&1 && [ -n "$(_amd_smi_bin)" ]; then
    echo "[OK] ROCm validation tooling already present -- skipping install."
    return 0
  fi
  case "$ID" in
    rocky|rhel|almalinux)
      if [ ! -f /etc/yum.repos.d/rocm.repo ] && ! command -v amdgpu-install >/dev/null 2>&1; then
        log_failure "ROCm install: AMD dnf repo not configured and amdgpu-install absent (see rocm.docs.amd.com)."
        echo -e "${TXT_YLW}[WARN] ROCm repo not configured. Set up AMD's amdgpu-install / rocm.repo first (rocm.docs.amd.com), then re-run.${RESET}"
      fi
      install_dnf_packages "amd-smi-lib" "rocm-smi-lib" "rocm-validation-suite" "rocm-bandwidth-test"
      ;;
    ubuntu)
      if [ ! -f /etc/apt/sources.list.d/rocm.list ] && [ ! -f /etc/apt/sources.list.d/amdgpu.list ] \
         && ! command -v amdgpu-install >/dev/null 2>&1; then
        log_failure "ROCm install: AMD apt repo not configured and amdgpu-install absent (see rocm.docs.amd.com)."
        echo -e "${TXT_YLW}[WARN] ROCm apt repo not configured. Set up AMD's amdgpu-install / rocm repo first (rocm.docs.amd.com), then re-run.${RESET}"
      fi
      apt-get update
      install_apt_packages "amd-smi-lib" "rocm-smi-lib" "rocm-validation-suite" "rocm-bandwidth-test"
      ;;
    *)
      log_failure "ROCm install: unsupported OS '$ID $VERSION_ID'."
      echo -e "${TXT_RED}[ERROR] ROCm install: unsupported OS '$ID $VERSION_ID'.${RESET}"
      return 1 ;;
  esac
  # /opt/rocm/bin isn't always on a sudo/SSH PATH -- make the tools reachable for the rest of the run.
  case ":$PATH:" in *":/opt/rocm/bin:"*) ;; *) [ -d /opt/rocm/bin ] && export PATH="$PATH:/opt/rocm/bin" ;; esac
  command -v rvs >/dev/null 2>&1 && [ -n "$(_amd_smi_bin)" ]
}

# Background temp/power/clock sampler (the rocm-smi/amd-smi analog to the nvidia-smi monitor). Writes a
# timestamped log; its PID is tracked in AMD_MONITOR_PID so the orchestrator can stop it.
_amd_gpu_monitor() {
  local smi; smi="$(_amd_smi_bin)"; [ -z "$smi" ] && return 0
  local mlog="$VAL_LOGDIR/amd_gpu_monitor.log"
  ( while true; do
      echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
      if [ "$smi" = "amd-smi" ]; then amd-smi metric 2>/dev/null
      else rocm-smi --showtemp --showpower --showuse --showclocks 2>/dev/null; fi
      sleep 15
    done ) >> "$mlog" 2>&1 &
  AMD_MONITOR_PID=$!
}

# Runs the ROCm Validation Suite GST (GPU stress) module across all GPUs for $PHASE_DURATION -- the
# gpu_burn analog. Verdict mirrors gpu_burn: an explicit gst "pass: FALSE", an [ERROR]/FAILED line, or a
# nonzero exit is a FAIL; clean completion is a PASS. target_stress is modest on purpose -- this is a
# stability burn, not a performance gate, so it should not false-fail an otherwise-healthy GPU.
_amd_gpu_burn() {
  local dur_ms=$(( ${PHASE_DURATION:-14400} * 1000 ))
  local conf="$VAL_LOGDIR/rvs_gst.conf" plog="$VAL_LOGDIR/amd_gpu_burn.log"
  cat > "$conf" <<EOF
actions:
- name: gpu-stress
  device: all
  module: gst
  parallel: true
  count: 1
  duration: $dur_ms
  copy_matrix: false
  target_stress: 3000
  tolerance: 0.1
EOF
  vlog "AMD-GPU-BURN: running rvs GST for ${PHASE_DURATION:-14400}s (see $plog)"
  rvs -c "$conf" 2>&1 | tee "$plog"
  local rc=${PIPESTATUS[0]}
  if grep -qiE 'pass:[[:space:]]*false|\[ERROR\]|\bFAILED\b' "$plog"; then
    vrecord "AMD-GPU-BURN" "FAIL" "rvs GST reported a failure -- see $plog"
    vrecord_evidence "AMD-GPU-BURN" "$(grep -iE 'pass:|error|fail' "$plog" | head -10)"
    return 1
  elif [ "$rc" -ne 0 ]; then
    vrecord "AMD-GPU-BURN" "FAIL" "rvs exited non-zero (rc=$rc) -- see $plog"
    return 1
  fi
  vrecord "AMD-GPU-BURN" "PASS" "rvs GST completed clean -- see $plog"
  return 0
}

# rocm-bandwidth-test (the nvbandwidth analog): host<->device and device<->device bandwidth matrix.
_amd_bandwidth() {
  command -v rocm-bandwidth-test >/dev/null 2>&1 || { vlog "AMD-BW: rocm-bandwidth-test not installed -- skipping"; return 0; }
  local blog="$VAL_LOGDIR/amd_bandwidth.log"
  vlog "AMD-BW: running rocm-bandwidth-test (see $blog)"
  if rocm-bandwidth-test 2>&1 | tee "$blog"; then
    vrecord "AMD-BW" "PASS" "rocm-bandwidth-test completed -- see $blog"
  else
    vrecord "AMD-BW" "WARN" "rocm-bandwidth-test exited non-zero -- see $blog"
  fi
}

# Orchestrator + standalone menu action. Installs ROCm tooling if needed, records GPU discovery, then
# runs the monitored burn-in and bandwidth test. Refuses cleanly on a system with no AMD GPU.
amd_gpu_validation() {
  _init_validation_paths
  write_header "AMD GPU Validation (ROCm)"
  if ! _amd_gpu_present; then
    echo -e "${TXT_YLW}[SKIP] No AMD GPU detected (need /dev/kfd + an AMD PCI display device). Nothing to validate.${RESET}"
    [ "${VAL_INITIALIZED:-0}" -eq 1 ] && vrecord "AMD-GPU" "SKIP" "no AMD GPU present"
    return 0
  fi
  if ! rocm_install; then
    echo -e "${TXT_RED}[ERROR] ROCm validation tooling unavailable -- cannot run AMD GPU validation (see warnings above).${RESET}"
    [ "${VAL_INITIALIZED:-0}" -eq 1 ] && vrecord "AMD-GPU" "FAIL" "ROCm tooling unavailable"
    return 1
  fi
  local smi; smi="$(_amd_smi_bin)"
  { echo "=== AMD GPU discovery ($(date)) ==="; "$smi" list 2>/dev/null || "$smi" 2>/dev/null; } | tee "$VAL_LOGDIR/amd_gpu_discovery.log"
  [ -z "$PHASE_DURATION" ] && PHASE_DURATION=14400
  _amd_gpu_monitor
  _amd_gpu_burn
  [ -n "${AMD_MONITOR_PID:-}" ] && kill "$AMD_MONITOR_PID" 2>/dev/null
  _amd_bandwidth
  print_val_summary
}

validation_menu() {
  while true; do
    clear
    write_header "Hardware Validation"
    echo "1. CPU (mprime)"
    echo "2. Memory (stressapptest)"
    echo "3. GPU (gpu-burn)"
    echo "4. SMART Health Check"
    echo "5. Storage (Single Drive / SW RAID / HW RAID / GRAID / IE Provisioning)"
    echo "6. Sequential: CPU+Memory combined -> GPU-burn -> DCGM (4h fixed per test, except DCGM), then storage plan if any"
    echo "7. Combined (Stress Only) -- CPU+Memory+GPU CONCURRENTLY (4h), no DCGM/FP-Accuracy, then storage plan if any"
    echo "8. Combined (Full Validation) -- CPU+Memory+GPU CONCURRENTLY (4h) + DCGM + FP-Accuracy, then storage plan if any"
    echo "9. AMD GPU Validation (ROCm) -- rvs GPU-stress burn-in + rocm-bandwidth-test (for AMD GPUs)"
    echo "Q. Back to Main Menu"
    _read_choice sel "Enter selection (1-9, or Q to go Back): "
    case "$sel" in [Qq]) ;; *) _ensure_system_sn_confirmed ;; esac
    _init_validation_paths
    # RESULTS is deliberately NOT reset here -- it accumulates for the life of the process.
    case "$sel" in
      1) _prompt_duration; _run_or_detach _run_cpu_body "cpu"; pause ;;
      2) _prompt_duration; _run_or_detach _run_mem_body "memory"; pause ;;
      3) _prompt_duration; _run_or_detach _run_gpu_body "gpu"; pause ;;
      # SMART is seconds long -- detaching it would cost more than it saves.
      4) _run_smart_body; pause ;;
      5) storage_validation_menu ;;
      # Menu numbering does not match the body names -- see each _run_optionN_body definition.
      6) _run_or_detach _run_option7_body "sequential"; pause ;;
      7) _run_or_detach _run_option8_body "combined-stress"; pause ;;
      8) _run_or_detach _run_option6_body "combined-full"; pause ;;
      9) _prompt_duration; _run_or_detach amd_gpu_validation "amd-gpu"; pause ;;
      [Qq]) return ;;
      *) echo "Invalid selection."; pause ;;
    esac
  done
}

# --- 10. AVL GAP-FILL TESTING: qualifies ONE non-AVL component against a validated platform, logging a tracker row. ---
GAPFILL_TRACKER_CSV_HEADER="timestamp,component_type,model_or_part_number,platform_hostname,result,detail,log_path"

# _gap_fill_log_result <type> <model> <result> <detail> <log> -- the record Systems Engineering checks.
_gap_fill_log_result() {
  local component_type="$1" model="$2" result="$3" detail="$4" log_path="$5"
  local csv="$LOG_DIR/AVL_GapFill_Tracker.csv"
  if [ ! -f "$csv" ]; then
    echo "$GAPFILL_TRACKER_CSV_HEADER" > "$csv"
    chown "$REAL_USER:$REAL_USER" "$csv" 2>/dev/null
  fi
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local host; host=$(hostname)
  printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
    "$ts" "$component_type" "$model" "$host" "$result" "$detail" "$log_path" >> "$csv"
  chown "$REAL_USER:$REAL_USER" "$csv" 2>/dev/null
  echo "[INFO] Gap-fill result logged to $csv"
}

_gap_fill_prompt_model() {  # sets GAPFILL_MODEL
  _prompt_confirmed GAPFILL_MODEL "Component model / part number" \
    "Component model / part number being gap-filled (for the AVL tracker): " allow_empty
  [ -z "$GAPFILL_MODEL" ] && GAPFILL_MODEL="unspecified"
}

# PCIe/NUMA and memory-detection have no SOP threshold, so they record INFO -- inert to the rollup.
_gap_fill_pcie_numa_check() {  # _gap_fill_pcie_numa_check <RESULTS key>
  local label="$1"
  vlog "━━━ PCIe MAPPING / NUMA CHECK ━━━"
  local out="$VAL_LOGDIR/pcie_numa_check.log"
  {
    echo "--- GPU PCIe mapping (index, bus_id, link gen/width) ---"
    nvidia-smi --query-gpu=index,pci.bus_id,serial,name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv 2>/dev/null
    echo
    echo "--- NUMA topology ---"
    numactl --hardware 2>/dev/null
    echo
    echo "--- PCIe tree ---"
    lspci -tv 2>/dev/null
  } | tee "$out"
  vrecord "$label" "INFO" "captured for manual review -- see $out"
}

_gap_fill_memory_detect_check() {
  vlog "━━━ MEMORY DETECTION CHECK (capacity/speed/ECC) ━━━"
  local out="$VAL_LOGDIR/memory_detect_check.log"
  {
    echo "--- Total memory ---"
    free -h
    echo
    echo "--- DIMM detail ---"
    dmidecode -t memory 2>/dev/null | grep -E "Size:|Speed:|Type:|Locator:" | grep -v "No Module Installed"
    echo
    echo "--- ECC status ---"
    dmidecode -t memory 2>/dev/null | grep -i "Error Correction Type"
  } | tee "$out"
  vrecord "MEMORY_DETECT" "INFO" "capacity/speed/ECC captured for manual review -- see $out"
}

# Link-state check the menu label always promised but that was never implemented until now.
_gap_fill_nic_link_check() {
  vlog "━━━ NIC LINK-STATE CHECK ━━━"
  local out="$VAL_LOGDIR/nic_link_check.log"
  if command -v ibstat >/dev/null 2>&1; then
    ibstat > "$out" 2>&1
    cat "$out"
    if grep -qi "State: Active" "$out" && grep -qi "Physical state: LinkUp" "$out"; then
      vrecord "NIC_LINK" "PASS" "link Active/LinkUp -- see $out"
    else
      vrecord "NIC_LINK" "FAIL" "link not Active/LinkUp -- see $out"
    fi
  else
    vrecord "NIC_LINK" "WARN" "ibstat not available -- link state not verified"
  fi
}

gap_fill_menu() {
  _ensure_system_sn_confirmed
  while true; do
    clear
    write_header "AVL Gap-Fill Testing"
    echo "Scoped, single-component qualification testing -- runs ONLY the"
    echo "test(s) relevant to the component being gap-filled, not a full"
    echo "system sweep. Use this to add one not-yet-AVL-approved part to an"
    echo "already-validated baseline platform. Run the full Concurrent Stress"
    echo "Test (Option 7 -> 8, Combined Full Validation) only after every gap-item on this build has"
    echo "passed its own scoped test here."
    echo ""
    echo "1. Drive / Storage       -- Single Drive Testing (4-workload fio + SMART + NUMA check)"
    echo "2. GPU                   -- GPU-burn + DCGM + PCIe mapping/NUMA check"
    echo "3. CPU                   -- mprime + PCIe topology/lane re-check"
    echo "4. Memory / DIMM         -- stressapptest + capacity/speed/ECC detection check"
    echo "5. NIC (Mellanox)        -- driver install + link-state check"
    echo "6. HBA / RAID Controller -- HW RAID Testing path (existing VD only)"
    echo "7. PSU                   -- full 4h CPU+GPU+Memory concurrent run (no DCGM)"
    echo "                            + wall-meter power draw reading"
    echo "Q. Back to Main Menu"
    _read_choice sel "Enter selection (1-7, or Q to go Back): "
    _init_validation_paths
    RESULTS=()
    case "$sel" in
      1)
        # The NUMA-placement check already happens inside run_single_drive_testing.
        _gap_fill_prompt_model
        get_cpu_threads; verify_environment_templates
        run_single_drive_testing
        print_val_summary
        _gap_fill_log_result "Drive" "$GAPFILL_MODEL" "${RESULTS[SMARTCTL]:-see console/report}" "single-drive fio suite (NUMA-node placement checked)" "$VAL_LOGDIR"
        pause
        ;;
      2)
        # A gap-item GPU's heat output, and whether the fan curve copes, are unknowns on this platform.
        _gap_fill_prompt_model
        _prompt_duration
        install_gpuburn
        start_temp_monitors
        _start_dashboard "gpu"
        run_gpuburn
        mark_temp "DCGM"
        _dcgm_run "${DCGM_LEVEL_OVERRIDE:-4}"
        _stop_dashboard
        stop_temp_monitors
        check_temps; check_fans; check_oom; check_nvrm; check_edac; check_gpuburn_throttle
        _gap_fill_pcie_numa_check "GPU_PCIE_NUMA"
        print_val_summary
        _gap_fill_log_result "GPU" "$GAPFILL_MODEL" "${RESULTS[GPU-BURN]:-see console}" "gpu-burn + DCGM (temp/fan monitored: ${RESULTS[GPU_TEMP]:-n/a} / ${RESULTS[FAN]:-n/a}; PCIe/NUMA captured)" "$VAL_LOGDIR"
        pause
        ;;
      3)
        # Same thermal rationale as the GPU branch; a new CPU generation can also shift lane allocation.
        _gap_fill_prompt_model
        _prompt_duration
        install_mprime
        start_temp_monitors
        _start_dashboard "cpu"
        run_mprime
        _stop_dashboard
        stop_temp_monitors
        check_temps; check_fans; check_oom; check_nvrm; check_edac; check_gpuburn_throttle
        _gap_fill_pcie_numa_check "CPU_PCIE_TOPOLOGY"
        print_val_summary
        _gap_fill_log_result "CPU" "$GAPFILL_MODEL" "${RESULTS[MPRIME]:-see console}" "mprime torture test (temp/fan monitored: ${RESULTS[CPU_TEMP]:-n/a} / ${RESULTS[FAN]:-n/a}; PCIe/lane topology captured)" "$VAL_LOGDIR"
        pause
        ;;
      4)
        # stressapptest drives the memory controller hard enough that CPU temp and fan health matter here.
        _gap_fill_prompt_model
        _prompt_duration
        start_temp_monitors
        _start_dashboard "mem"
        run_memory
        _stop_dashboard
        stop_temp_monitors
        check_temps; check_fans; check_oom; check_nvrm; check_edac; check_gpuburn_throttle
        _gap_fill_memory_detect_check
        print_val_summary
        _gap_fill_log_result "Memory" "$GAPFILL_MODEL" "${RESULTS[MEMORY]:-see console}" "stressapptest (temp/fan monitored: ${RESULTS[CPU_TEMP]:-n/a} / ${RESULTS[FAN]:-n/a}; capacity/speed/ECC captured)" "$VAL_LOGDIR"
        pause
        ;;
      5)
        # Link-state check -- the menu label promised it long before it was implemented.
        _gap_fill_prompt_model
        run_and_log mlnx_install "gapfill-mlnx-install"
        _gap_fill_nic_link_check
        _gap_fill_log_result "NIC" "$GAPFILL_MODEL" "${RESULTS[NIC_LINK]:-see log}" "mlnx_install + link-state check" "$CURRENT_LOG_FILE"
        pause
        ;;
      6)
        _gap_fill_prompt_model
        get_cpu_threads; verify_environment_templates
        run_hw_raid_testing
        _gap_fill_log_result "HBA/RAID Controller" "$GAPFILL_MODEL" "see fio report" "HW RAID Testing path (unvalidated pipeline)" "$RESULTS_DIR"
        pause
        ;;
      7)
        # Duplicates the 3-way launch rather than calling it: the wall-meter reading must be taken under live load.
        _gap_fill_prompt_model
        echo
        echo "PSU AVL requires a full system-wide load, not just whatever happens"
        echo "to be running -- launching a defined 4-hour CPU+GPU+Memory concurrent"
        echo "run now (DCGM is intentionally skipped for this gap-item type)."
        install_mprime; install_gpuburn
        start_temp_monitors
        mark_temp "PSU-CONCURRENT-STRESS"

        local hrs=$((CONCURRENT_STRESS_DURATION / 3600))
        local pids=()
        ( MEM_PERCENT="$CONCURRENT_MPRIME_MEM_PCT" PHASE_DURATION="$CONCURRENT_STRESS_DURATION" run_mprime ) &
        pids+=("$!")
        ( MEM_PERCENT="$CONCURRENT_STRESSAPP_MEM_PCT" PHASE_DURATION="$CONCURRENT_STRESS_DURATION" run_memory ) &
        pids+=("$!")
        ( PHASE_DURATION="$CONCURRENT_STRESS_DURATION" run_gpuburn ) &
        pids+=("$!")

        echo
        echo "Load launched -- give it a few minutes to reach steady-state, then"
        echo "take your wall-meter reading at the load point(s) defined in Script"
        echo "SOP 2.2.6 (the run itself takes ~${hrs} hour(s); this prompt won't"
        echo "block it)."
        local psu_reading
        _prompt_confirmed psu_reading "Wall-meter reading (W)" \
          "Wall-meter power draw reading (watts), or leave blank if not measured: " allow_empty

        _start_dashboard "cpu mem gpu"
        echo "[INFO] Waiting for the concurrent run to finish (~${hrs} hour(s))..."
        wait "${pids[@]}"
        _stop_dashboard

        local mprime_rc memory_rc gpuburn_rc
        mprime_rc=$(cat "$VAL_LOGDIR/mprime.log.rc" 2>/dev/null || echo 1)
        memory_rc=$(cat "$VAL_LOGDIR/memory.log.rc" 2>/dev/null || echo 1)
        gpuburn_rc=$(cat "$VAL_LOGDIR/gpuburn.log.rc" 2>/dev/null || echo 1)
        if [ "$ARCH" = "aarch64" ]; then
          _evaluate_stress_ng "$VAL_LOGDIR/mprime.log" "$mprime_rc" "MPRIME-CONCURRENT"
        else
          evaluate_mprime "$MPRIME_DIR/results.txt" "$VAL_LOGDIR/mprime.log" "$mprime_rc" "MPRIME-CONCURRENT"
        fi
        evaluate_memory "$VAL_LOGDIR/memory.log" "$memory_rc" "MEMORY-CONCURRENT"
        evaluate_gpuburn "$VAL_LOGDIR/gpuburn.log" "$gpuburn_rc" "GPU-BURN-CONCURRENT"

        stop_temp_monitors
        check_temps; check_fans; check_oom; check_nvrm; check_edac; check_gpuburn_throttle
        print_val_summary

        local psu_note
        if [ -n "$psu_reading" ]; then
          psu_note="wall-meter reading: ${psu_reading}W (during a dedicated 4h CPU+GPU+Memory concurrent run, no DCGM)"
        else
          psu_note="no reading recorded -- concurrent load ran but no wall-meter value entered"
        fi
        _gap_fill_log_result "PSU" "$GAPFILL_MODEL" "${RESULTS[MPRIME-CONCURRENT]:-see console}/${RESULTS[GPU-BURN-CONCURRENT]:-n/a}/${RESULTS[MEMORY-CONCURRENT]:-n/a}" "$psu_note" "$VAL_LOGDIR"
        pause
        ;;
      [Qq]) return ;;
      *) echo "Invalid selection."; pause ;;
    esac
  done
}

# --- 9. STORAGE: Single / MDADM / HW RAID (build untested) / GRAID / ZFS, QD calibration, IE Provisioning. ---
# The 4 fio templates are embedded and byte-verified, so storage testing needs no QA server; QDsweeps still does.
_materialize_fio_templates() {
    mkdir -p "$TEMPLATE_DIR"

    cat > "$TEMPLATE_DIR/random_read.txt" <<'RANDREAD_EOF'
[global]
bs=4K
time_based=1
runtime=300
randrepeat=0
ioengine=libaio
direct=1
random_generator=tausworthe64
group_reporting=1
cpus_allowed_policy=split
numa_mem_policy=local

[randread]
filename=
rw=randread
iodepth=
numjobs=
RANDREAD_EOF

    cat > "$TEMPLATE_DIR/random_write.txt" <<'RANDWRITE_EOF'
[global]
bs=4K
time_based=1
runtime=300
randrepeat=0
ioengine=libaio
direct=1
random_generator=tausworthe64
group_reporting=1
cpus_allowed_policy=split
numa_mem_policy=local

[randwrite]
filename=
rw=randwrite
iodepth=
numjobs=
RANDWRITE_EOF

    cat > "$TEMPLATE_DIR/sequential_read.txt" <<'SEQREAD_EOF'
[global]
bs=128k
time_based=1
runtime=300
randrepeat=0
ioengine=libaio
direct=1
random_generator=tausworthe64
group_reporting=1
cpus_allowed_policy=split
numa_mem_policy=local

[seqread]
filename=
rw=read
iodepth=
numjobs=
SEQREAD_EOF

    cat > "$TEMPLATE_DIR/sequential_write.txt" <<'SEQWRITE_EOF'
[global]
bs=128k
time_based=1
runtime=300
randrepeat=0
ioengine=libaio
direct=1
random_generator=tausworthe64
group_reporting=1
cpus_allowed_policy=split
numa_mem_policy=local

[seqwrite]
filename=
rw=write
iodepth=
numjobs=
SEQWRITE_EOF

    chown "$REAL_USER:$REAL_USER" "$TEMPLATE_DIR"/*.txt 2>/dev/null
}

verify_environment_templates() {
    _ensure_qa_checked
    _materialize_fio_templates
    local missing=()
    for cfg in "${CONFIG_FILES[@]}"; do
        [ ! -f "$TEMPLATE_DIR/$cfg" ] && missing+=("$cfg")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        quit_with_enter "Failed to write FIO job templates to $TEMPLATE_DIR: ${missing[*]}"
    fi
    echo "[SUCCESS] FIO job templates ready in $TEMPLATE_DIR (embedded in script -- no QA server needed)."
}

# Sets global C_SAFE: the usable CPU thread ceiling for fio numjobs, shared by every topology.
get_cpu_threads() {
    local total_cores
    total_cores=$(nproc --all 2>/dev/null \
               || nproc 2>/dev/null \
               || getconf _NPROCESSORS_ONLN 2>/dev/null \
               || grep -c '^processor' /proc/cpuinfo 2>/dev/null \
               || echo 32)
    # Reserve 2 threads for OS overhead; floor at 8 to keep multi-job testing meaningful.
    C_SAFE=$(( total_cores > 2 ? total_cores - 2 : total_cores ))
    [ "$C_SAFE" -lt 8 ] && C_SAFE=8
}

get_drive_metadata() {
    local dev_name=$1
    dev_basename=$(basename "$dev_name")
    if [[ -f "/sys/block/$dev_basename/device/model" ]]; then
        DRIVE_MODEL=$(cat "/sys/block/$dev_basename/device/model" | xargs)
        DRIVE_SERIAL=$(cat "/sys/block/$dev_basename/device/serial" 2>/dev/null | xargs)
        # SATA/SAS usually has no sysfs serial, and preconditioning markers are keyed on it.
        [ -z "$DRIVE_SERIAL" ] && DRIVE_SERIAL=$(lsblk -dno SERIAL "$dev_name" 2>/dev/null | xargs)
        [ -z "$DRIVE_SERIAL" ] && DRIVE_SERIAL=$(udevadm info --query=property --name="$dev_name" 2>/dev/null | grep -m1 "^ID_SERIAL_SHORT=" | cut -d= -f2 | xargs)
    else
        DRIVE_MODEL=$(udevadm info --query=property --name="$dev_name" | grep "ID_MODEL=" | cut -d= -f2 | xargs)
        DRIVE_SERIAL=$(udevadm info --query=property --name="$dev_name" | grep "ID_SERIAL_SHORT=" | cut -d= -f2 | xargs)
    fi
    if [ -z "$DRIVE_MODEL" ]; then DRIVE_MODEL="Unknown_Model"; fi
    if [ -z "$DRIVE_SERIAL" ]; then DRIVE_SERIAL="Unknown_Serial"; fi
    DRIVE_MODEL_TOKEN=$(echo -n "$DRIVE_MODEL" | tr '[:space:]' '_' | tr -cd '[:alnum:]_.-')
}

# calc_rand_qd_params <count> -- sets FINAL_JOBS/FINAL_DEPTH; needs C_SAFE and RAND_TQDpD.
calc_rand_qd_params() {
    local drive_count="$1"
    local total_tqd=$(( drive_count * RAND_TQDpD ))
    local ideal_w=$(( total_tqd / 16 ))
    [ "$ideal_w" -le 0 ] && ideal_w=1
    FINAL_JOBS=$ideal_w
    [ "$C_SAFE" -lt "$FINAL_JOBS" ] && FINAL_JOBS=$C_SAFE
    FINAL_DEPTH=$(awk -v t="$total_tqd" -v j="$FINAL_JOBS" 'BEGIN {print int((t/j) + 0.5)}')
    [ "$FINAL_DEPTH" -lt 1 ] && FINAL_DEPTH=1
}

# _load_qd_profile <token|profile-path> [drive_count] -- the ONLY way to load a QD profile.
# The unset is mandatory, not tidiness: profiles predating the write sweep never set SEQ_WRITE_TQDpD,
# so sourcing over a previous drive's values silently benchmarks at the wrong queue depth.
# With a drive count, also runs calc_rand_qd_params. Never fails: a missing profile degrades to
# default depths and sets QD_UNCALIBRATED, so a test still runs and is flagged for manual review.
# Path of an existing profile for a model token: this run's first, then the legacy persistent
# cache (honoured so an already-swept box is not swept again). Empty if neither has one.
_qd_profile_path() {
    local token="$1"
    [ -n "${QD_RUN_DIR:-}" ] && [ -f "$QD_RUN_DIR/TQDpD_${token}.txt" ] && { printf '%s\n' "$QD_RUN_DIR/TQDpD_${token}.txt"; return 0; }
    [ -f "$SWEEP_DIR/TQDpD_${token}.txt" ] && { printf '%s\n' "$SWEEP_DIR/TQDpD_${token}.txt"; return 0; }
    return 1
}

_load_qd_profile() {
    local ref="$1" count="${2:-}" profile
    case "$ref" in
        */*) profile="$ref" ;;
        *)   profile="$(_qd_profile_path "$ref" || printf '%s\n' "$QD_RUN_DIR/TQDpD_${ref}.txt")" ;;
    esac
    unset SEQ_TQDpD SEQ_WRITE_TQDpD RAND_TQDpD
    if [ -f "$profile" ]; then
        . "$profile"
        QD_UNCALIBRATED=0
    else
        # Never skip the test for a missing profile: an uncalibrated number an engineer can read
        # is worth more than no number at all. The verdict becomes REVIEW instead of PASS/FAIL.
        SEQ_TQDpD="$QD_FALLBACK_SEQ"
        SEQ_WRITE_TQDpD="$QD_FALLBACK_SEQ_WRITE"
        RAND_TQDpD="$QD_FALLBACK_RAND"
        QD_UNCALIBRATED=1
        case " $QD_UNCALIBRATED_MODELS " in
            *" $(basename "$profile" .txt) "*) ;;
            *) QD_UNCALIBRATED_MODELS="$QD_UNCALIBRATED_MODELS $(basename "$profile" .txt)" ;;
        esac
        echo -e "${TXT_YLW}[WARN] No QD profile ($(basename "$profile")) -- running with default depths:${RESET}"
        echo "       seq=$SEQ_TQDpD  seq-write=$SEQ_WRITE_TQDpD  random=$RAND_TQDpD per drive."
        echo "       Results are UNCALIBRATED: no PASS/FAIL is recorded, manual review required."
    fi
    [ -n "$count" ] && calc_rand_qd_params "$count"
    return 0
}

# Divides the CPU thread ceiling across simultaneously-benchmarked targets. Random workloads only.
_apply_concurrent_cpu_budget() {
    local n_concurrent="$1"
    [ "$n_concurrent" -le 1 ] && return 0
    local divided=$(( C_SAFE / n_concurrent ))
    [ "$divided" -lt 1 ] && divided=1
    echo "[INFO] Dividing CPU thread budget across $n_concurrent simultaneous target(s): C_SAFE $C_SAFE -> $divided each"
    C_SAFE=$divided
}

# Lists an md array's members from /proc/mdstat: lsblk makes disks the PARENTS, returning nothing.


# --- STORAGE MODULE (ported verbatim from fio_validation.sh) ---

_mdadm_member_drives() {
    local md_name="$1"
    awk -v m="$md_name" '$1==m {
        for (i=5; i<=NF; i++) {
            tok=$i
            gsub(/\[[0-9]+\].*/, "", tok)
            if (tok != "") print tok
        }
    }' /proc/mdstat
}

# True if no two given md arrays share a physical drive -- sharing splits that drive's throughput.
_md_arrays_are_disjoint() {
    local arrays=("$@")
    local -A seen_drive
    local md child
    for md in "${arrays[@]}"; do
        while IFS= read -r child; do
            [ -z "$child" ] && continue
            if [ -n "${seen_drive[$child]:-}" ]; then
                return 1
            fi
            seen_drive[$child]=1
        done < <(_mdadm_member_drives "$md")
    done
    return 0
}

parse_fio_metrics() {
    local target_log=$1
    local section_header=$2  # e.g. "sequential_read", "sequential_write", "random_read", "random_write"
    local mode=$3             # "read" or "write"

    local section_block
    section_block=$(awk \
        -v hdr="--- FIO Execution Output for ${section_header}.txt ---" '
        index($0, hdr)                      { found=1; next }
        found && /--- FIO Execution Output for / { found=0 }
        found                               { print }
    ' "$target_log")

    if [ -z "$section_block" ]; then
        echo "   - ${mode^} Throughput : N/A (section not found)"
        echo "   - Latency (clat avg) : N/A"
        return
    fi

    local raw_iops
    raw_iops=$(echo "$section_block" | grep -i -E "^\s*${mode}:.*IOPS=" | head -n 1 | sed -E 's/.*IOPS=([^,]+).*/\1/')
    local raw_bw
    raw_bw=$(echo "$section_block" | grep -i -E "^\s*${mode}:.*BW=" | head -n 1 | sed -E 's/.*BW=([^ ]+).*/\1/')
    local clat_line
    clat_line=$(echo "$section_block" | grep -i "clat" | grep -i "avg=" | head -n 1)
    local clat_avg
    clat_avg=$(echo "$clat_line" | sed -E 's/.*avg=([^,]+).*/\1/')
    local time_unit="usec"
    [[ "$clat_line" == *"nsec"* ]] && time_unit="nsec"
    [[ "$clat_line" == *"msec"* ]] && time_unit="msec"

    echo -e "   - ${mode^} Throughput : $raw_bw ($raw_iops IOPS)"
    echo -e "   - Latency (clat avg) : $clat_avg $time_unit"
}

# execute_and_summarize_fio <dev> <id> <jobs> <depth> <raid_type> <parity_fix> -- 4-workload suite, all topologies.
execute_and_summarize_fio() {
    local dev_path=$1
    local array_id=$2
    local final_jobs=$3
    local final_depth=$4
    local raid_type=$5
    local run_parity_write_fix=$6

    local output_summary="fio_${array_id}.txt"
    local tmp_report="fio_${array_id}_raw.tmp"
    rm -f "$tmp_report" "$output_summary"

    echo -e "\n[START] Commencing Test Framework Execution Phase for Target: $dev_path"

    for config in "${CONFIG_FILES[@]}"; do
        local run_jobs=$final_jobs
        local run_depth=$final_depth
        local current_mode="read"

        if [[ "$config" == *"write"* ]]; then
            current_mode="write"
        fi

        if [[ "$config" == *"sequential"* ]]; then
            if [[ "$raid_type" == "SINGLE" || "$raid_type" == "HWRAID" ]]; then
                run_jobs=1
                # Sequential WRITE gets its own queue depth; falls back to SEQ_TQDpD for pre-write-sweep profiles.
                if [ "$current_mode" == "write" ]; then
                    run_depth="${SEQ_WRITE_TQDpD:-$SEQ_TQDpD}"
                else
                    run_depth=$SEQ_TQDpD
                fi
            elif [[ "$raid_type" == "GRAID" ]]; then
                # GRAID translation overhead caps one thread at ~5.5 GiB/s; 4x threads saturates the PCIe switch.
                local seq_multiplier=4
                run_jobs=$((DRIVE_COUNT * seq_multiplier))
                if [ "$run_jobs" -lt 8 ]; then run_jobs=8; fi
                if [ "$run_jobs" -gt "$C_SAFE" ]; then run_jobs=$C_SAFE; fi

                local this_seq_tqdpd="$SEQ_TQDpD"
                if [ "$current_mode" == "write" ]; then
                    this_seq_tqdpd="${SEQ_WRITE_TQDpD:-$SEQ_TQDpD}"
                fi
                local total_seq_qd=$((DRIVE_COUNT * this_seq_tqdpd))
                run_depth=$((total_seq_qd / run_jobs))
                if [ "$run_depth" -lt 1 ]; then run_depth=1; fi
            elif [[ "$raid_type" == "MDADM" ]]; then
                run_jobs=$DRIVE_COUNT
                if [ "$current_mode" == "write" ]; then
                    run_depth="${SEQ_WRITE_TQDpD:-$SEQ_TQDpD}"
                else
                    run_depth=$SEQ_TQDpD
                fi
            fi
        else
            if [ "$current_mode" == "write" ] && [ "$run_parity_write_fix" = true ]; then
                run_jobs=4
                run_depth=$(( (DRIVE_COUNT * RAND_TQDpD) / 4 ))
            fi
        fi

        # Workload-matched preconditioning per Solidigm: sequential preconditioning into a random read overstates steady state.
        if [ "$current_mode" == "read" ]; then
            local precond_rw="write" precond_bs="128k"
            if [[ "$config" == *"random"* ]]; then
                precond_rw="randwrite"
                precond_bs="4k"
            fi
            echo " [PRECOND] Running ${precond_rw} burst (bs=${precond_bs}, numjobs=$run_jobs, iodepth=$run_depth) so this read measurement reflects a realistic drive state..."
            fio --name=precond_burst \
                --filename="$dev_path" \
                --rw="$precond_rw" \
                --bs="$precond_bs" \
                --direct=1 \
                --ioengine=libaio \
                --numjobs="$run_jobs" \
                --iodepth="$run_depth" \
                --norandommap \
                --time_based=1 \
                --runtime=60 \
                --group_reporting=1 \
                --output=/dev/null > /dev/null 2>&1
        fi

        echo " [EXEC] Running: $config (numjobs=$run_jobs, iodepth=$run_depth)..."

        local json_out="fio_${array_id}_${config%.txt}.json"
        local combo_out="fio_${array_id}_combo.tmp"

        echo -e "\n--- FIO Execution Output for $config ---" >> "$tmp_report"

        # --norandommap: fio's default random map is ~1 bit per block of the WHOLE device -- real OOM crashes.
        fio "$TEMPLATE_DIR/$config" \
            --filename="$dev_path" \
            --numjobs="$run_jobs" \
            --iodepth="$run_depth" \
            --norandommap \
            --output-format=normal,json \
            --output="$combo_out" > /tmp/fio_stderr.log 2>&1
        cat /tmp/fio_stderr.log >> "$tmp_report"
        rm -f /tmp/fio_stderr.log

        # JSON block is always the last contiguous section, starting at the first line beginning with '{'.
        local json_start
        json_start=$(grep -n '^{' "$combo_out" | head -n 1 | cut -d: -f1)

        if [ -n "$json_start" ]; then
            local json_end
            json_end=$(awk "NR>=${json_start} && /^\}\$/{print NR; exit}" "$combo_out")

            if [ -n "$json_end" ]; then
                sed -n "${json_start},${json_end}p" "$combo_out" > "$json_out"
                {
                    head -n $((json_start - 1)) "$combo_out"
                    tail -n +"$((json_end + 1))" "$combo_out"
                } >> "$tmp_report"
            else
                tail -n +"$json_start" "$combo_out" > "$json_out"
                head -n $((json_start - 1)) "$combo_out" >> "$tmp_report"
                echo "[WARN] JSON end boundary unclear for $config — text summary may be in json file." >> "$tmp_report"
            fi
        else
            cat "$combo_out" >> "$tmp_report"
            echo "[WARN] No JSON block found for $config — $json_out not created." >> "$tmp_report"
        fi

        rm -f "$combo_out"
    done

    # Generate the Custom Summary Document Header Block
    {
        local report_ts
        report_ts=$(date "+%Y-%m-%d %H:%M:%S %Z")
        local report_host
        report_host=$(hostname -f 2>/dev/null || hostname)
        local report_kernel
        report_kernel=$(uname -r)
        local fio_version
        fio_version=$(fio --version 2>/dev/null | head -n 1)

        echo "====================================================================="
        echo "                EXXACT STORAGE VALIDATION REPORT                     "
        echo "====================================================================="
        echo " Test Timestamp             : $report_ts"
        echo " System Hostname            : $report_host"
        echo " Kernel Version             : $report_kernel"
        echo " FIO Version                : $fio_version"
        if [ "${QD_UNCALIBRATED:-0}" = "1" ]; then
            echo "---------------------------------------------------------------------"
            echo " *** UNCALIBRATED RUN -- MANUAL REVIEW REQUIRED ***"
            echo " No QD profile existed for this model, so default queue depths were used"
            echo " (seq=$SEQ_TQDpD, seq-write=$SEQ_WRITE_TQDpD, random=$RAND_TQDpD per drive)."
            echo " The figures below are real measurements but are NOT a calibrated ceiling."
            echo " No PASS/FAIL is recorded. Run a QD sweep on this model for a scored result."
        fi
        echo "---------------------------------------------------------------------"
        echo " Storage Architecture Style : $raid_type"
        echo " Target Logical Device      : $dev_path"
        echo " Aggregated Component Model : $DRIVE_MODEL"
        echo " Component Serials Evaluated:"
        echo "$DRIVE_SERIAL" | sed 's/^/   - /'
        echo "---------------------------------------------------------------------"
        echo " PERFORMANCE SUMMARY METRICS:"

        echo " [*] 128K Sequential Read:"
        parse_fio_metrics "$tmp_report" "sequential_read" "read"

        echo " [*] 128K Sequential Write:"
        parse_fio_metrics "$tmp_report" "sequential_write" "write"

        echo " [*] 4K Random Read:"
        parse_fio_metrics "$tmp_report" "random_read" "read"

        echo " [*] 4K Random Write:"
        parse_fio_metrics "$tmp_report" "random_write" "write"
        echo "====================================================================="
        echo -e "\n\n=== RAW FIO ENGINE DATA BLOCKS ===\n"
        cat "$tmp_report"
    } > "$output_summary"

    rm -f "$tmp_report"
    echo -e "\n[SUCCESS] Execution Complete. Parsed output summary generated."
    echo "[PATH] Destination: $(pwd)/$output_summary"
}

# --- GRAID Array Lifecycle Helpers (ported from graid_validationWIP6.sh) ---

# _write_timing_log <path> <label> <start_epoch> <end_epoch> [notes] -- timing record to file and stdout.
_write_timing_log() {
    local log_path="$1"
    local operation="$2"
    local start_epoch="$3"
    local end_epoch="$4"
    local notes="${5:-}"

    local elapsed=$(( end_epoch - start_epoch ))
    local hours=$(( elapsed / 3600 ))
    local mins=$(( (elapsed % 3600) / 60 ))
    local secs=$(( elapsed % 60 ))
    local elapsed_str
    elapsed_str=$(printf "%02d:%02d:%02d" "$hours" "$mins" "$secs")

    mkdir -p "$(dirname "$log_path")"
    {
        echo "====================================================================="
        echo " TIMING LOG"
        echo "====================================================================="
        echo " Operation    : $operation"
        echo " Started      : $(date -d "@$start_epoch" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || date -r "$start_epoch" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)"
        echo " Completed    : $(date -d "@$end_epoch"   "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || date -r "$end_epoch"   "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)"
        echo " Elapsed      : $elapsed_str  (${elapsed}s total)"
        [ -n "$notes" ] && echo " Notes        : $notes"
        echo "====================================================================="
    } > "$log_path"
    echo "[TIMING] $operation — elapsed $elapsed_str → $log_path"
}

# _precond_worker <dev> <model> <serial> <status_file> <marker_dir> <log_dir> -- per-drive preconditioning.
_precond_worker() {
    local path="$1"
    local model="$2"
    local serial="$3"
    local status_file="$4"
    local precond_marker_dir="$5"
    local log_subdir="$6"

    local token
    token=$(echo -n "$model" | tr '[:space:]' '_' | tr -cd '[:alnum:]_.-')

    echo "running" > "$status_file"

    local precond_marker="$precond_marker_dir/${serial}.done"
    local needs_precondition=true

    if [ -f "$precond_marker" ]; then
        echo "sanity-check" > "$status_file"
        local sanity_log="$log_subdir/${token}_${serial}_precond_sanity.txt"
        fio --name=sanity \
            --filename="$path" \
            --rw=randread \
            --bs=4k \
            --direct=1 \
            --ioengine=libaio \
            --numjobs=1 \
            --iodepth=1 \
            --io_size=64M \
            --output="$sanity_log" 2>&1

        local sanity_clat sanity_unit sanity_clat_us below_threshold
        sanity_clat=$(grep -E "^\s*clat" "$sanity_log" | head -1 | sed -E 's/.*avg=([0-9.]+).*/\1/')
        sanity_unit=$(grep -E "^\s*clat" "$sanity_log" | head -1 | grep -oE "usec|nsec|msec")
        case "$sanity_unit" in
            nsec) sanity_clat_us=$(awk -v v="$sanity_clat" 'BEGIN{print v/1000}') ;;
            msec) sanity_clat_us=$(awk -v v="$sanity_clat" 'BEGIN{print v*1000}') ;;
            *)    sanity_clat_us="${sanity_clat:-0}" ;;
        esac
        below_threshold=$(awk -v c="${sanity_clat_us:-0}" 'BEGIN{print (c < 5) ? 1 : 0}')

        if [ "$below_threshold" -eq 1 ]; then
            rm -f "$precond_marker"
            echo "stale (${sanity_clat_us}us, re-conditioning)" > "$status_file"
        else
            echo "skipped (valid marker, ${sanity_clat_us}us)" > "$status_file"
            needs_precondition=false
        fi
    fi

    if [ "$needs_precondition" = true ]; then
        # Purge before the write pass per Solidigm: a write pass alone leaves old FTL state. --lbaf preserves the format.
        if command -v nvme &>/dev/null; then
            echo "purging" > "$status_file"
            local lbaf
            lbaf=$(nvme id-ns "$path" 2>/dev/null | grep 'in use' | grep -oE '^lbaf +[0-9]+' | grep -oE '[0-9]+' | head -1)
            [ -z "$lbaf" ] && lbaf=0
            local purge_log="$log_subdir/${token}_${serial}_purge.log"
            if ! nvme format "$path" --lbaf="$lbaf" --ses=1 --force >"$purge_log" 2>&1; then
                echo "[WARN] nvme format (purge) reported an error for $path — continuing with precondition anyway. See $purge_log" >> "$purge_log"
            fi
        else
            echo "[WARN] nvme-cli not found — skipping purge step, preconditioning directly." >> "$log_subdir/${token}_${serial}_precondition.txt"
        fi

        local cap_bytes cap_gb
        cap_bytes=$(blockdev --getsize64 "$path" 2>/dev/null)
        cap_gb=$(( cap_bytes / 1024 / 1024 / 1024 ))
        echo "writing (${cap_gb}GB)" > "$status_file"

        local precond_log="$log_subdir/${token}_${serial}_precondition.txt"
        # One sequential job at QD32 already saturates an SSD's write pipeline (the device is
        # internally parallel), so it fills the whole drive once (1x) using a SINGLE host thread.
        # That is deliberate: preconditioning runs on every drive in parallel, and one thread per
        # drive is the fewest that still saturates it -- so even a 24-drive box does not oversubscribe
        # the CPU. numjobs>1 to the same device only adds threads and, on QLC, slows the fill with
        # scattered writes for no bandwidth gain.
        fio --name=precondition \
            --filename="$path" \
            --rw=write \
            --bs=128k \
            --direct=1 \
            --ioengine=libaio \
            --numjobs=1 \
            --iodepth=32 \
            --output="$precond_log" 2>&1

        if [ $? -ne 0 ]; then
            echo "error (see $precond_log)" > "$status_file"
            return 1
        else
            {
                echo "drive_serial=$serial"
                echo "capacity_bytes=$cap_bytes"
                echo "preconditioned_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            } > "$precond_marker"
            echo "complete" > "$status_file"
        fi
    fi
}

# _precondition_drive_batch <paths> <models> <serials> <status_out> <log_dir> -- parallel workers; returns error count.
_precondition_drive_batch() {
    local -n _pdb_paths="$1"
    local -n _pdb_models="$2"
    local -n _pdb_serials="$3"
    local -n _pdb_out_status="$4"
    local log_subdir="$5"

    mkdir -p "$log_subdir"
    local precond_marker_dir="$SWEEP_DIR/Preconditioned"
    mkdir -p "$precond_marker_dir"
    local status_dir="$log_subdir/precond_status_$$"
    mkdir -p "$status_dir"

    echo ""
    echo "[INFO] Verifying/preconditioning ${#_pdb_paths[@]} drive(s) in parallel"
    echo "       (already-preconditioned drives are detected and skipped"
    echo "       automatically; total time is bounded by the slowest single"
    echo "       drive that needs a fresh write, not the sum of all drives)..."
    echo ""

    local pids=() drive_num=0
    for idx in "${!_pdb_paths[@]}"; do
        drive_num=$((drive_num + 1))
        local status_file="$status_dir/${drive_num}.status"
        echo "queued" > "$status_file"
        _precond_worker "${_pdb_paths[$idx]}" "${_pdb_models[$idx]}" "${_pdb_serials[$idx]}" \
            "$status_file" "$precond_marker_dir" "$log_subdir" &
        pids+=("$!")
    done

    local any_running=true
    while [ "$any_running" = true ]; do
        any_running=false
        for ((i=0; i<${#_pdb_paths[@]}; i++)); do
            local n=$((i + 1))
            local st; st=$(cat "$status_dir/${n}.status" 2>/dev/null || echo "unknown")
            if [ "$st" = "running" ] || [ "$st" = "sanity-check" ] || [[ "$st" == writing* ]] || [ "$st" = "queued" ]; then
                any_running=true
            fi
        done
        [ "$any_running" = true ] && sleep 5
    done

    local failures=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failures=$((failures + 1))
    done

    _pdb_out_status=()
    echo ""
    echo "====================================================================="
    echo " PRECONDITIONING CHECK COMPLETE"
    echo "====================================================================="
    for ((i=0; i<${#_pdb_paths[@]}; i++)); do
        local n=$((i + 1))
        local st; st=$(cat "$status_dir/${n}.status" 2>/dev/null || echo "unknown")
        _pdb_out_status+=("$st")
        printf "  %-20s %s\n" "${_pdb_paths[$i]}" "$st"
    done
    echo "====================================================================="

    rm -rf "$status_dir"

    if [ "$failures" -gt 0 ]; then
        echo "[WARN] $failures drive(s) reported errors during preconditioning."
        echo "       Check the logs in $log_subdir before relying on those drives' results."
    fi
    return "$failures"
}

# NUMA node for a device path or bare name, "?" if undeterminable.
_numa_node_for_drive() {
    local d_name; d_name=$(basename "$1")
    local ctrl_name; ctrl_name=$(echo "$d_name" | grep -oE '^nvme[0-9]+')
    local node=""
    [ -n "$ctrl_name" ] && node=$(cat "/sys/class/nvme/${ctrl_name}/numa_node" 2>/dev/null)
    # SATA/SAS has no /sys/class/nvme entry -- walk up to the first parent publishing a numa_node.
    if [ -z "$node" ]; then
        local p; p=$(readlink -f "/sys/block/$d_name/device" 2>/dev/null)
        while [ -n "$p" ] && [ "$p" != "/" ] && [ "$p" != "/sys" ] && [ "$p" != "/sys/devices" ]; do
            if [ -r "$p/numa_node" ]; then node=$(cat "$p/numa_node" 2>/dev/null); break; fi
            p=$(dirname "$p")
        done
    fi
    # -1 means "no NUMA affinity reported", which is not a node number.
    [ "$node" = "-1" ] && node=""
    echo "${node:-?}"
}

# Media class of one device: "hdd" if the kernel reports it rotational, else "flash" (NVMe or SSD).
# Drives the whole performance-vs-health decision: HDDs get health checks only.
_drive_media_class() {
    local d; d=$(basename "$1")
    case "$d" in nvme*) echo "flash"; return ;; esac
    [ "$(cat "/sys/block/$d/queue/rotational" 2>/dev/null)" = "1" ] && echo "hdd" || echo "flash"
}

# Human label for the discovery listing: NVMe / SSD / HDD.
_drive_media_label() {
    local d; d=$(basename "$1")
    case "$d" in nvme*) echo "NVMe"; return ;; esac
    [ "$(_drive_media_class "$d")" = "hdd" ] && echo "HDD" || echo "SSD"
}

# _check_selection_media <paths-array-name>
# Sets SELECTION_MEDIA to flash|hdd for the whole selection. Rejects a mix: flash and rotational
# drives in one array have incompatible performance envelopes and separate validation paths.
_check_selection_media() {
    local __csm_arr="$1"
    eval "local __csm_paths=(\"\${${__csm_arr}[@]}\")"
    local p flash=() hdd=()
    for p in "${__csm_paths[@]}"; do
        if [ "$(_drive_media_class "$p")" = "hdd" ]; then hdd+=("$p"); else flash+=("$p"); fi
    done
    if [ ${#flash[@]} -gt 0 ] && [ ${#hdd[@]} -gt 0 ]; then
        echo ""
        echo -e "${TXT_RED}[ERROR] Mixed drive types selected -- pick one type only.${RESET}"
        echo "  Flash (NVMe/SSD): ${flash[*]}"
        echo "  Rotational (HDD): ${hdd[*]}"
        echo "  Flash and HDD are validated differently and cannot share an array here."
        SELECTION_MEDIA=""
        return 1
    fi
    [ ${#hdd[@]} -gt 0 ] && SELECTION_MEDIA="hdd" || SELECTION_MEDIA="flash"
    return 0
}

# _hdd_health_validation <label> <paths...>
# The entire HDD validation path: SMART health per drive, a presence/identity snapshot, and a
# recorded verdict. No preconditioning, no QD calibration, no fio -- nobody buys an HDD array for
# throughput, and a full-drive write on a 20TB disk costs a day to prove nothing.
_hdd_health_validation() {
    local label="$1"; shift
    local paths=("$@")
    [ ${#paths[@]} -eq 0 ] && return 0

    [ -z "${VAL_LOGDIR:-}" ] && _init_validation_paths
    local plog="$VAL_LOGDIR/hdd_health_${label}.log"
    mkdir -p "$(dirname "$plog")" 2>/dev/null
    : > "$plog"

    echo ""
    write_header "HDD HEALTH VALIDATION -- $label (${#paths[@]} drive(s))"
    echo "  Rotational media: SMART health and presence only. Performance testing is"
    echo "  deliberately skipped -- see the release notes for why."
    echo ""

    local overall="PASS" evidence="" p health serial model
    for p in "${paths[@]}"; do
        get_drive_metadata "$p"
        serial="$DRIVE_SERIAL"; model="$DRIVE_MODEL"
        {
            echo "==================== $p ($model, serial $serial) ===================="
            echo "----- smartctl -H -----"; smartctl -H "$p" 2>&1
            echo "----- smartctl -A -----"; smartctl -A "$p" 2>&1
        } >> "$plog"
        health=$(smartctl -H "$p" 2>&1 | grep -iE "overall-health|SMART Health Status")
        if echo "$health" | grep -qiE "PASSED|OK"; then
            echo "  [PASS] $p  $model  ${health#*: }"
        else
            echo -e "  ${TXT_RED}[FAIL] $p  $model  ${health:-no health line}${RESET}"
            overall="FAIL"
        fi
        evidence+="$p ($model, $serial): ${health:-no health line}"$'\n'
    done

    _snapshot_drive_inventory
    vrecord "STORAGE-HDD-$label" "$overall" "SMART health on ${#paths[@]} rotational drive(s) -- see $plog"
    vrecord_evidence "STORAGE-HDD-$label" "$evidence"
    echo ""
    echo "  Log: $plog"
    return 0
}

# True when the current selection is rotational. HDD topologies skip preconditioning, QD
# calibration and fio entirely -- none of it is meaningful on a platter, and a full-drive
# precondition write on a 20TB disk costs ~22 hours for no measurable result.
_media_is_hdd() { [ "${SELECTION_MEDIA:-flash}" = "hdd" ]; }

# NVMe/SATA/SAS/USB label -- a SATA drive in a list of NVMe is worth seeing before selection.
_drive_bus_label() {
    local d_name; d_name=$(basename "$1")
    case "$d_name" in nvme*) echo "NVMe"; return ;; esac
    local tran; tran=$(lsblk -dno TRAN "/dev/$d_name" 2>/dev/null | tr -d ' ')
    case "$tran" in
        sata) echo "SATA" ;;
        sas)  echo "SAS" ;;
        usb)  echo "USB" ;;
        "")   echo "unknown-bus" ;;
        *)    echo "$tran" ;;
    esac
}

# Warns if selected drives span NUMA nodes -- measured 3-7x sequential read loss. Returns 1 if declined.
_check_selection_numa_spread() {
    local -n _csns_paths="$1"
    local nodes=() p node unresolved=false
    for p in "${_csns_paths[@]}"; do
        node=$(_numa_node_for_drive "$p")
        if [ "$node" = "?" ]; then
            unresolved=true
            continue
        fi
        nodes+=("$node")
    done

    if [ "$unresolved" = true ]; then
        echo "[INFO] Could not determine NUMA node for one or more selected drives — skipping cross-node check."
        return 0
    fi

    local unique_nodes=() n already
    for n in "${nodes[@]}"; do
        already=false
        for un in "${unique_nodes[@]}"; do [ "$un" = "$n" ] && already=true; done
        $already || unique_nodes+=("$n")
    done

    if [ ${#unique_nodes[@]} -le 1 ]; then
        echo "[INFO] All selected drives are on NUMA node ${unique_nodes[0]:-?} — good, no cross-node traffic."
        return 0
    fi

    echo ""
    echo "====================================================================="
    echo " WARNING: SELECTED DRIVES SPAN MULTIPLE NUMA NODES (${unique_nodes[*]})"
    echo "====================================================================="
    echo " Measured impact on this hardware: mixing NUMA nodes within a single"
    echo " array cut sequential read throughput by 3-7x versus keeping every"
    echo " member drive on one node (confirmed via live testing, not"
    echo " theoretical) -- the single biggest performance factor found in"
    echo " this validation suite's testing to date."
    echo "====================================================================="
    local proceed_anyway
    read -p "Proceed with this cross-NUMA-node selection anyway? (y/n): " proceed_anyway
    [[ "$proceed_anyway" == "y" || "$proceed_anyway" == "Y" ]] && return 0
    return 1
}

# _confirm_drive_selection <title> <indices-array> -- last look at the drives about to be wiped.
_confirm_drive_selection() {
    # Underscored locals: the caller passes an array NAME, and a plain local would shadow it.
    local __cds_title="$1" __cds_arr="$2"
    local __cds_idx __cds_i __cds_ok
    eval "local __cds_list=(\"\${${__cds_arr}[@]}\")"
    echo ""
    write_header "$__cds_title"
    printf '  %-4s %-14s %-26s %-22s %6s %s\n' "#" "DEVICE" "MODEL" "SERIAL" "SIZE" "NUMA"
    for __cds_idx in "${__cds_list[@]}"; do
        __cds_i=$((__cds_idx-1))
        printf '  %-4s %-14s %-26s %-22s %5sG %s\n' "$__cds_idx" \
            "${_DISCOVERED_PATHS[$__cds_i]}" "${_DISCOVERED_MODELS[$__cds_i]}" \
            "${_DISCOVERED_SERIALS[$__cds_i]}" "${_DISCOVERED_CAPACITIES[$__cds_i]}" \
            "${_DISCOVERED_NUMA_NODES[$__cds_i]}"
    done
    echo ""
    echo -e "${TXT_YLW}  Check these against your build paperwork. Everything listed will be wiped.${RESET}"
    echo ""
    _yes_no __cds_ok "Is this drive selection correct? (y = continue, n = reselect): "
    [ "$__cds_ok" = "y" ] && return 0
    return 1
}

# Shows what actually exists on disk now, so a wrong level or missing member is caught here.
_show_drive_structure() {
    local title="${1:-Current Drive Structure}"
    echo ""
    write_header "$title"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null
    if [ -s /proc/mdstat ] && grep -q "^md" /proc/mdstat 2>/dev/null; then
        echo ""
        echo "--- /proc/mdstat ---"
        grep -v "^unused devices" /proc/mdstat
    fi
    command -v graidctl >/dev/null 2>&1 && { echo ""; echo "--- GRAID drive groups / virtual drives ---"; graidctl list dg 2>/dev/null; graidctl list vd 2>/dev/null; }
    echo ""
}


# GB -> the human sizes lsblk prints, so the mockup compares line-for-line with the real thing.
_fmt_gb() {
    local gb="${1:-0}"
    if [ "$gb" -ge 1024 ] 2>/dev/null; then
        awk -v g="$gb" 'BEGIN{ printf "%.1fT", g/1024 }'
    else
        printf '%sG' "$gb"
    fi
}

# Usable capacity of a planned array, mirroring mdadm/GRAID geometry for a paperwork check.
_mock_usable_gb() {
    local level="$1" count="$2" per="$3"
    case "$level" in
        0)  echo $(( per * count )) ;;
        1)  echo "$per" ;;
        5)  echo $(( per * (count - 1) )) ;;
        6)  echo $(( per * (count - 2) )) ;;
        10) echo $(( per * count / 2 )) ;;
        *)  echo $(( per * count )) ;;
    esac
}

# --- Pending structure plan: a build only appends here, so backing out resets a file instead of undoing work. ---
_PENDING_PLAN=()
_pending_plan_file() { printf '%s\n' "$STATE_DIR/pending_structure.plan"; }

_pending_plan_clear() {
    _PENDING_PLAN=()
    rm -f "$(_pending_plan_file)" 2>/dev/null
}

_pending_plan_add() {   # <type> <level> <drives_csv> <fs> <mount>
    _PENDING_PLAN+=("${1}|${2}|${3}|${4}|${5}")
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\n' "${_PENDING_PLAN[@]}" > "$(_pending_plan_file)" 2>/dev/null
    chown "$REAL_USER:$REAL_USER" "$(_pending_plan_file)" 2>/dev/null
}

# printf pads by BYTES and the lsblk branch glyph is 6 bytes but 2 columns -- widen by the overage.
_mock_row() {
    local name="$1" pad=24
    case "$name" in *"└─"*) pad=28 ;; esac
    printf "%-${pad}s %8s %-7s %-7s %s\n" "$name" "$2" "$3" "$4" "$5"
}

# Predicted lsblk view: members as parents with the array as their child, matching real output.
_render_structure_mockup() {
    local entries=("$@")
    local next_md=0 next_gdg=0 entry
    while [ -e "/dev/md${next_md}" ] || grep -q "^md${next_md} " /proc/mdstat 2>/dev/null; do
        next_md=$((next_md + 1))
    done
    while [ -e "/dev/gdg${next_gdg}n1" ]; do next_gdg=$((next_gdg + 1)); done

    echo ""
    write_header "PROJECTED STRUCTURE -- nothing has been created yet"
    _mock_row "NAME" "SIZE" "TYPE" "FSTYPE" "MOUNTPOINT"

    for entry in "${entries[@]}"; do
        local vtype vlevel vdrives_csv vfs vmount
        IFS='|' read -r vtype vlevel vdrives_csv vfs vmount <<< "$entry"
        local drives=() d
        if [ "$vtype" = "zfs" ]; then
            while IFS= read -r d; do [ -n "$d" ] && drives+=("$d"); done < <(_plan_drive_list "$vdrives_csv")
        else
            IFS=',' read -ra drives <<< "$vdrives_csv"
        fi
        local count=${#drives[@]}
        [ "$count" -eq 0 ] && continue

        local per_gb=0 b
        b=$(blockdev --getsize64 "${drives[0]}" 2>/dev/null)
        [ -n "$b" ] && per_gb=$(( b / 1024 / 1024 / 1024 ))

        case "$vtype" in
            single)
                for d in "${drives[@]}"; do
                    _mock_row "$(basename "$d")" "$(_fmt_gb "$per_gb")" "disk" "${vfs:--}" "${vmount:--}"
                done
                ;;
            mdadm)
                local md="md${next_md}"; next_md=$((next_md + 1))
                local usable; usable=$(_mock_usable_gb "$vlevel" "$count" "$per_gb")
                for d in "${drives[@]}"; do
                    _mock_row "$(basename "$d")" "$(_fmt_gb "$per_gb")" "disk" "-" "-"
                    _mock_row "└─$md" "$(_fmt_gb "$usable")" "raid$vlevel" "${vfs:--}" "${vmount:--}"
                done
                ;;
            zfs)
                local vg spare_csv cache_csv vdevs=0 width=0
                while IFS= read -r vg; do
                    [ -z "$vg" ] && continue
                    local vd=() m
                    IFS=',' read -ra vd <<< "$vg"
                    [ "$width" -eq 0 ] && width=${#vd[@]}
                    vdevs=$((vdevs + 1))
                    _mock_row "vdev$vdevs ($vlevel)" "" "" "" ""
                    for m in "${vd[@]}"; do
                        _mock_row "  └─$(basename "$m")" "$(_fmt_gb "$per_gb")" "disk" "-" "-"
                    done
                done < <(_zfs_groups "$vdrives_csv" vdev)
                spare_csv=$(_zfs_groups "$vdrives_csv" spare | head -1)
                cache_csv=$(_zfs_groups "$vdrives_csv" cache | head -1)
                if [ -n "$spare_csv" ]; then
                    local sp=() sd
                    IFS=',' read -ra sp <<< "$spare_csv"
                    for sd in "${sp[@]}"; do
                        _mock_row "  └─$(basename "$sd")" "$(_fmt_gb "$per_gb")" "disk" "-" "(hot spare)"
                    done
                fi
                if [ -n "$cache_csv" ]; then
                    local ca=() cd_
                    IFS=',' read -ra ca <<< "$cache_csv"
                    for cd_ in "${ca[@]}"; do
                        local cgb=0 cb
                        cb=$(blockdev --getsize64 "$cd_" 2>/dev/null); [ -n "$cb" ] && cgb=$(( cb / 1024 / 1024 / 1024 ))
                        _mock_row "  └─$(basename "$cd_")" "$(_fmt_gb "$cgb")" "disk" "-" "(L2ARC cache)"
                    done
                fi
                local zusable; zusable=$(_zfs_usable_gb "$vlevel" "$vdevs" "$width" "$per_gb")
                _mock_row "${vfs:-pool} (pool)" "$(_fmt_gb "$zusable")" "zfs" "zfs" "${vmount:--}"
                ;;
            graid)
                local gdg="gdg${next_gdg}n1"; next_gdg=$((next_gdg + 1))
                local usable; usable=$(_mock_usable_gb "$vlevel" "$count" "$per_gb")
                for d in "${drives[@]}"; do
                    _mock_row "$(basename "$d")" "$(_fmt_gb "$per_gb")" "disk" "-" "(GRAID PD)"
                done
                _mock_row "$gdg" "$(_fmt_gb "$usable")" "raid$vlevel" "${vfs:--}" "${vmount:--}"
                ;;
        esac
    done
    echo ""
    echo "  Device names (md#, gdg#) are the next free numbers and may differ if"
    echo "  something else claims one first. Sizes are pre-filesystem-overhead."
    echo ""
}

# Final gate. Shows the projection, then releases the work or resets the plan file. Returns 0 to proceed.
_confirm_projected_structure() {
    local ok
    _render_structure_mockup "$@"
    echo -e "${TXT_YLW}  This is the LAST checkpoint. Answering y begins wiping the listed drives.${RESET}"
    echo ""
    _yes_no ok "Does this structure match your build paperwork? (y = build it, n = discard the plan): "
    if [ "$ok" = "y" ]; then
        DRIVE_STRUCTURE_CONFIRMED="yes"
        return 0
    fi
    DRIVE_STRUCTURE_CONFIRMED="no"
    _pending_plan_clear
    echo "[INFO] Plan discarded. Nothing was written to any drive."
    return 1
}

# Lists candidate drives and populates _DISCOVERED_PATHS/MODELS/SERIALS/CAPACITIES/NUMA_NODES.
# $1 = "include_graid" to also list drives currently in an array.
_discover_candidate_drives() {
    local include_graid="${1:-}"
    _DISCOVERED_PATHS=()
    _DISCOVERED_MODELS=()
    _DISCOVERED_SERIALS=()
    _DISCOVERED_CAPACITIES=()
    _DISCOVERED_NUMA_NODES=()

    # Every disk root sits on. lsblk -s walks dependencies upward, so root-on-LVM/md reports members too.
    # -r is MANDATORY: without it lsblk draws tree glyphs ("└─sda"), the grep -qx below never matches
    # the parent disk, and the OS drive is offered as a wipe target. Verified broken on 2026-09-18.
    local root_src root_disks=""
    root_src=$(findmnt -no SOURCE / 2>/dev/null)
    [ -n "$root_src" ] && root_disks=$(lsblk -rnso NAME "$root_src" 2>/dev/null | tr -d ' ')
    [ -z "$root_disks" ] && root_disks=$(df / | tail -1 | awk '{print $1}' | grep -oE "(nvme[0-9]+n[0-9]+|sd[a-z]+)")
    # Belt-and-braces: anything holding /boot, /boot/efi or swap is also off-limits.
    local _crit _csrc
    for _crit in /boot /boot/efi; do
        _csrc=$(findmnt -no SOURCE "$_crit" 2>/dev/null) || continue
        [ -n "$_csrc" ] && root_disks="$root_disks"$'\n'"$(lsblk -rnso NAME "$_csrc" 2>/dev/null | tr -d ' ')"
    done
    while read -r _csrc _; do
        [ -b "$_csrc" ] || continue
        root_disks="$root_disks"$'\n'"$(lsblk -rnso NAME "$_csrc" 2>/dev/null | tr -d ' ')"
    done < <(swapon --show=NAME --noheadings 2>/dev/null)

    local precond_marker_dir="$SWEEP_DIR/Preconditioned"

    for drive_path in /sys/block/nvme*n1 /sys/block/sd*; do
        [ -e "$drive_path" ] || continue
        local d_name; d_name=$(basename "$drive_path")
        [[ "$d_name" =~ ^(nvme[0-9]+n[0-9]+|sd[a-z]+)$ ]] || continue
        [ -b "/dev/$d_name" ] || continue
        # Exact line match, not a substring: "sda" is a substring of "sdab".
        printf '%s\n' "$root_disks" | grep -qx "$d_name" && continue

        # Skip USB and removable media -- offering a technician's USB stick is how one gets wiped.
        if [[ "$d_name" == sd* ]]; then
            local tran; tran=$(lsblk -dno TRAN "/dev/$d_name" 2>/dev/null | tr -d ' ')
            case "$tran" in usb|"") [ "$tran" = "usb" ] && continue ;; esac
            [ "$(cat "/sys/block/$d_name/removable" 2>/dev/null)" = "1" ] && continue
            # Virtual/loop/zram never reach here (they are not sd*), but an empty-size device can.
            [ "$(cat "/sys/block/$d_name/size" 2>/dev/null || echo 0)" -gt 0 ] || continue
        fi

        local in_graid=false
        lsblk -no TYPE "/dev/$d_name" 2>/dev/null | grep -q "graid\|md\|raid" && in_graid=true
        [ "$in_graid" = true ] && [ "$include_graid" != "include_graid" ] && continue

        local mounted=false
        lsblk -no MOUNTPOINT "/dev/$d_name" 2>/dev/null | grep -q "\S" && mounted=true

        get_drive_metadata "/dev/$d_name"
        local cap_bytes; cap_bytes=$(blockdev --getsize64 "/dev/$d_name" 2>/dev/null)
        local cap_gb=$(( cap_bytes / 1024 / 1024 / 1024 ))
        local numa_node; numa_node=$(_numa_node_for_drive "$d_name")
        local bus; bus=$(_drive_bus_label "$d_name")
        local media; media=$(_drive_media_label "$d_name")

        _DISCOVERED_PATHS+=("/dev/$d_name")
        _DISCOVERED_MODELS+=("$DRIVE_MODEL")
        _DISCOVERED_SERIALS+=("$DRIVE_SERIAL")
        _DISCOVERED_CAPACITIES+=("$cap_gb")
        _DISCOVERED_NUMA_NODES+=("$numa_node")

        local idx=${#_DISCOVERED_PATHS[@]}
        local notes=""
        [ "$mounted" = true ]  && notes+=" [MOUNTED]"
        [ "$in_graid" = true ] && notes+=" [IN GRAID ARRAY]"
        [ -f "$precond_marker_dir/${DRIVE_SERIAL}.done" ] && notes+=" [preconditioned]"

        echo "  $idx) /dev/$d_name  $DRIVE_MODEL  (${cap_gb}GB, $bus $media, serial $DRIVE_SERIAL)  [NUMA node ${numa_node}]$notes"
    done
}

# _parse_selection_string <input> <out-array> <max> -- parses "1,3,5" / "2-6" / "all" into indices.
_parse_selection_string() {
    local input="$1"
    local -n _pss_out="$2"
    local max_idx="$3"
    _pss_out=()

    if [[ "${input,,}" == "all" ]]; then
        for ((i=1; i<=max_idx; i++)); do _pss_out+=("$i"); done
        return 0
    fi

    local raw=()
    IFS=',' read -ra tokens <<< "$input"
    for token in "${tokens[@]}"; do
        token=$(echo "$token" | tr -d ' ')
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local lo="${BASH_REMATCH[1]}" hi="${BASH_REMATCH[2]}"
            [ "$lo" -gt "$hi" ] && { local tmp=$lo; lo=$hi; hi=$tmp; }
            for ((i=lo; i<=hi; i++)); do
                [ "$i" -ge 1 ] && [ "$i" -le "$max_idx" ] && raw+=("$i")
            done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            [ "$token" -ge 1 ] && [ "$token" -le "$max_idx" ] && raw+=("$token")
        elif [ -n "$token" ]; then
            echo "[WARN] Ignoring invalid token: '$token'"
        fi
    done

    [ ${#raw[@]} -gt 0 ] && \
        mapfile -t _pss_out < <(printf '%s\n' "${raw[@]}" | sort -n | uniq)
}

# Returns 0 if the drive count suits the RAID level; shared so MDADM and GRAID enforce one minimum.
_validate_raid_level_drive_count() {
    local level="$1" count="$2"
    case "$level" in
        0)
            [ "$count" -ge 2 ] && return 0
            echo "[ERROR] RAID 0 requires at least 2 drives (got $count)."
            ;;
        1)
            [ "$count" -eq 2 ] && return 0
            echo "[ERROR] RAID 1 requires exactly 2 drives (got $count)."
            ;;
        5)
            [ "$count" -ge 3 ] && return 0
            echo "[ERROR] RAID 5 requires at least 3 drives (got $count)."
            ;;
        6)
            [ "$count" -ge 4 ] && return 0
            echo "[ERROR] RAID 6 requires at least 4 drives (got $count)."
            ;;
        10)
            if [ "$count" -ge 4 ] && [ $((count % 2)) -eq 0 ]; then return 0; fi
            echo "[ERROR] RAID 10 requires an even number of drives, 4 or more (got $count)."
            ;;
        *)
            echo "[ERROR] Unsupported RAID level: $level (choose 0, 1, 5, 6, or 10)."
            ;;
    esac
    return 1
}

# Prompts for a RAID level valid for the selected drive count. Sets SELECTED_RAID_LEVEL.
_prompt_raid_level() {
    local drive_count="$1"
    echo ""
    echo " Select RAID level for this array ($drive_count drive(s) selected):"
    echo "    0  — RAID 0  (striping, no redundancy)   needs 2+"
    echo "    1  — RAID 1  (mirror)                     needs exactly 2"
    echo "    5  — RAID 5  (single parity)               needs 3+"
    echo "    6  — RAID 6  (dual parity)                  needs 4+"
    echo "   10  — RAID 10 (striped mirrors)              needs 4+, even"
    echo ""
    local choice
    while true; do
        read -p "RAID level (0/1/5/6/10): " choice
        if _validate_raid_level_drive_count "$choice" "$drive_count"; then
            SELECTED_RAID_LEVEL="$choice"
            return 0
        fi
        echo "Choose a different level, or go back and adjust your drive selection."
    done
}

# Drive counts for proportional testing (100/75/50/25%), RAID5 floor of 3. Populates _TIER_SIZES[].

# (_calc_proportional_tiers dropped here -- confirmed dead code from the removed proportional sweep.)

_clear_active_arrays() {
    echo "[INFO] Clearing any active GRAID arrays (VDs + DGs, not PDs)..."

    local gdg_names=()
    while IFS= read -r name; do
        local base; base=$(echo "$name" | grep -oE '^gdg[0-9]+')
        [ -n "$base" ] && gdg_names+=("$base")
    done < <(lsblk -dno NAME 2>/dev/null | grep -E '^gdg')

    for gdg in "${gdg_names[@]}"; do
        echo "    [INFO] Found active array on /dev/${gdg}n1 — destroying..."
        if inspect_vd_for_device "$gdg" 2>/dev/null; then
            destroy_graid_array "$CURRENT_VD_ID" "$CURRENT_DG_ID" || true
        else
            echo "    [WARN] Could not inspect $gdg; will attempt fallback DG deletion below."
        fi
    done

    local remaining_dgs=()
    while IFS= read -r id; do
        [ -n "$id" ] && remaining_dgs+=("$id")
    done < <("$GRAID_CMD" list drive_group 2>/dev/null | awk '
        { gsub(/\033\[[0-9;]*[a-zA-Z]/,""); gsub(/[^\001-\177]/," ")
          gsub(/[[:space:]]+/," "); sub(/^ /,"") }
        $1 ~ /^[0-9]+$/ { print $1 }')

    for id in "${remaining_dgs[@]}"; do
        echo -n "    [INFO] Fallback: deleting remaining DG $id... "
        yes | "$GRAID_CMD" delete drive_group "$id" 2>/tmp/graid_clear_err.log
        # PIPESTATUS[1], not $?: `yes` gets SIGPIPE'd, which under pipefail would mask graidctl success.
        [ "${PIPESTATUS[1]}" -eq 0 ] && echo "OK" || echo "WARN: $(tr -d '\n' < /tmp/graid_clear_err.log)"
    done

    [ ${#gdg_names[@]} -gt 0 ] || [ ${#remaining_dgs[@]} -gt 0 ] && sleep 2 || true
}

# Parses `graidctl list physical_drive` from stdin to PD_ID|DG_ID|DEV_PATH|MODEL|CAPACITY.
_parse_pd_list() {
    awk '
    {
        gsub(/\033\[[0-9;]*[a-zA-Z]/, "")
        gsub(/\033\([a-zA-Z]/, "")
        gsub(/\r/, "")
        gsub(/[^\001-\177]/, " ")
        gsub(/[[:space:]]+/, " ")
        sub(/^ /, "")
        if ($0 == "") next
    }
    $1 ~ /^[0-9]+$/ {
        pd=$1; dg=$2
        dev="?"
        for (i=3; i<=NF; i++) { if ($i ~ /^\/dev\//) { dev=$i; break } }
        nqn_idx=0
        for (i=3; i<=NF; i++) {
            if ($i ~ /^(nqn\.|eui\.)/) { nqn_idx=i; break }
        }
        model=""; cap=""
        start=(nqn_idx>0) ? nqn_idx+1 : 4
        for (i=start; i<=NF; i++) {
            if ($i ~ /^[0-9]+(\.[0-9]+)?$/ && $(i+1) ~ /^(TiB|GiB|MiB|TB|GB|PB)$/) {
                cap=$i " " $(i+1); break
            }
            model=(model=="") ? $i : model " " $i
        }
        print pd "|" dg "|" dev "|" model "|" cap
    }'
}

# Re-queries each PD ID's CURRENT model -- _PD_MODELS[] only covers PDs unconfigured at scan time.
_query_pd_models_by_id() {
    local want_ids=("$@")
    local raw
    raw=$("$GRAID_CMD" list physical_drive 2>/dev/null)
    local pd_id dg_id dev_path model capacity
    while IFS='|' read -r pd_id dg_id dev_path model capacity; do
        local w
        for w in "${want_ids[@]}"; do
            if [ "$pd_id" = "$w" ]; then
                echo "${model:-unknown}"
                break
            fi
        done
    done < <(printf '%s\n' "$raw" | _parse_pd_list)
}

# Lists unconfigured GRAID PDs (DG = N/A). Populates _PD_IDS/_PD_PATHS/_PD_MODELS/_PD_CAPACITIES.
_query_unconfigured_pds() {
    _PD_IDS=(); _PD_PATHS=(); _PD_MODELS=(); _PD_CAPACITIES=()

    local raw
    raw=$("$GRAID_CMD" list physical_drive 2>/dev/null)
    if [ -z "$raw" ]; then
        raw=$("$GRAID_CMD" list physical_drive 2>&1)
    fi
    local raw_lines; raw_lines=$(printf '%s\n' "$raw" | wc -l)

    local pd_lines=0
    while IFS='|' read -r pd_id dg_id dev_path model capacity; do
        pd_lines=$((pd_lines + 1))
        [ "$dg_id" = "N/A" ] || continue
        _PD_IDS+=("$pd_id")
        _PD_PATHS+=("$dev_path")
        _PD_MODELS+=("${model:-unknown}")
        _PD_CAPACITIES+=("${capacity:-?}")
        local idx=${#_PD_IDS[@]}
        printf "  %2d) PD %-4s  %-16s  %-28s  %s\n" \
            "$idx" "$pd_id" "$dev_path" "${model:-unknown}" "${capacity:-?}"
    done < <(printf '%s\n' "$raw" | _parse_pd_list)

    echo "    [INFO] graidctl physical_drive output: ${raw_lines} line(s), ${pd_lines} PD row(s) parsed, ${#_PD_IDS[@]} unconfigured"
    if [ "${#_PD_IDS[@]}" -eq 0 ] && [ "$raw_lines" -gt 3 ]; then
        local first_data_line
        first_data_line=$(printf '%s\n' "$raw" | grep -v '^\s*$' | grep -v 'PD ID\|successfully\|───\|═══' | head -1)
        echo "    [DEBUG] First data line (hex): $(printf '%s' "$first_data_line" | xxd -p | head -c 80)"
        echo "    [DEBUG] After awk strip: $(printf '%s\n' "$first_data_line" | awk '{gsub(/[^\001-\177]/," ");gsub(/[[:space:]]+/," ");sub(/^ /,"");print}')"
    fi
}

# Registers raw NVMe paths as GRAID PDs, polling up to 60s. Populates _NEWLY_REGISTERED_PD_IDS[].
_create_pds_from_nvme() {
    local -n _cpf_paths="$1"
    _NEWLY_REGISTERED_PD_IDS=()

    local pre_ids=()
    while IFS='|' read -r pd_id rest; do pre_ids+=("$pd_id"); done \
        < <("$GRAID_CMD" list physical_drive 2>/dev/null | _parse_pd_list)

    local failures=0
    echo "[INFO] Creating ${#_cpf_paths[@]} physical drive(s) in graidctl..."
    for p in "${_cpf_paths[@]}"; do
        echo -n "  Creating $p ... "
        if "$GRAID_CMD" create physical_drive "$p" 2>/tmp/graid_add_err.log; then
            echo "OK"
        else
            local err; err=$(cat /tmp/graid_add_err.log 2>/dev/null)
            echo "$err" | grep -qi "already\|exist" \
                && echo "already registered (skipped)" \
                || { echo "WARN: $err"; failures=$((failures + 1)); }
        fi
    done
    [ "$failures" -gt 0 ] && echo "[WARN] $failures drive(s) failed to register."

    local expected=$(( ${#_cpf_paths[@]} - failures ))
    local timeout=60 elapsed=0
    echo "[INFO] Waiting for $expected new PD(s) to appear in graidctl..."
    while [ "$elapsed" -lt "$timeout" ]; do
        local new_ids=()
        while IFS='|' read -r pd_id rest; do
            local already=false
            for pre in "${pre_ids[@]}"; do [ "$pre" = "$pd_id" ] && { already=true; break; }; done
            [ "$already" = false ] && new_ids+=("$pd_id")
        done < <("$GRAID_CMD" list physical_drive 2>/dev/null | _parse_pd_list)

        if [ "${#new_ids[@]}" -ge "$expected" ]; then
            echo "[INFO] $expected new PD(s) confirmed: ${new_ids[*]}"
            _NEWLY_REGISTERED_PD_IDS=("${new_ids[@]}")
            return $failures
        fi
        sleep 3; elapsed=$((elapsed + 3))
        echo "    [WAIT] ${elapsed}/${timeout}s — ${#new_ids[@]}/$expected PDs visible..."
    done

    echo "[WARN] Timeout: only ${#new_ids[@]}/$expected PDs appeared after ${timeout}s."
    _NEWLY_REGISTERED_PD_IDS=("${new_ids[@]}")
    return 1
}

init_graid_cmd() {
    if command -v graidctl &>/dev/null; then
        GRAID_CMD="graidctl"
    elif [ -x "/opt/graid/graidctl" ]; then
        GRAID_CMD="/opt/graid/graidctl"
    else
        return 1
    fi
    return 0
}

# Finds the VD and DG for a gdg device. Sets CURRENT_VD_ID, CURRENT_DG_ID.
inspect_vd_for_device() {
    local gdg_name=$1
    local clean_gdg
    clean_gdg=$(echo "$gdg_name" | grep -oE 'gdg[0-9]+')

    local table
    table=$($GRAID_CMD list virtual_drive 2>/dev/null)

    local vd_col=0 dg_col=0 path_col=0
    while IFS= read -r line; do
        if [[ "$line" == *"VD ID"* ]]; then
            vd_col=$(echo "$line" | awk -F '[│|]' '{for(i=1;i<=NF;i++) if(tolower($i) ~ /vd id/) print i}' | head -1)
            dg_col=$(echo "$line" | awk -F '[│|]' '{for(i=1;i<=NF;i++) if(tolower($i) ~ /dg id/) print i}' | head -1)
            path_col=$(echo "$line" | awk -F '[│|]' '{for(i=1;i<=NF;i++) if(tolower($i) ~ /device/) print i}' | head -1)
            continue
        fi
        if [[ "$line" == *"│"* || "$line" == *"|"* ]] && [[ "${path_col:-0}" -gt 0 ]]; then
            local row_path
            row_path=$(echo "$line" | awk -F '[│|]' -v c="$path_col" '{print $c}' | xargs)
            if [[ "$row_path" == *"$clean_gdg"* ]]; then
                CURRENT_VD_ID=$(echo "$line" | awk -F '[│|]' -v c="${vd_col:-1}" '{print $c}' | xargs)
                CURRENT_DG_ID=$(echo "$line" | awk -F '[│|]' -v c="${dg_col:-2}" '{print $c}' | xargs)
                return 0
            fi
        fi
    done <<< "$table"

    CURRENT_VD_ID=""
    CURRENT_DG_ID=""
    return 1
}

# Parses `graidctl list drive_group`. Sets DG_RAID_LEVEL, DG_PD_COUNT.
get_dg_info() {
    local target_dg_id=$1
    DG_RAID_LEVEL=""
    DG_PD_COUNT=""

    local table
    table=$($GRAID_CMD list drive_group 2>/dev/null)
    local dg_col="" mode_col=""

    while IFS= read -r line; do
        if [[ "$line" == *"DG ID"* ]]; then
            dg_col=$(echo "$line" | awk -F '[│|]' \
                '{for(i=1;i<=NF;i++) if(tolower($i) ~ /dg[[:space:]]*id/) print i}' | head -1)
            mode_col=$(echo "$line" | awk -F '[│|]' \
                '{for(i=1;i<=NF;i++) if(tolower($i) ~ /mode|raid.*level|level/) print i}' | head -1)
            continue
        fi
        if [[ "$line" == *"│"* || "$line" == *"|"* ]] && [ -n "$dg_col" ]; then
            local row_dg
            row_dg=$(echo "$line" | awk -F '[│|]' -v c="$dg_col" '{print $c}' | xargs)
            if [[ "$row_dg" == "$target_dg_id" ]]; then
                DG_RAID_LEVEL=$(echo "$line" | \
                    awk -F '[│|]' -v c="${mode_col:-2}" '{print $c}' | xargs)
                break
            fi
        fi
    done <<< "$table"

    local pd_table
    pd_table=$($GRAID_CMD list physical_drive 2>/dev/null)
    local pd_dg_col=""
    local pd_count=0
    while IFS= read -r line; do
        if [[ "$line" == *"PD ID"* && "$line" == *"DG ID"* ]]; then
            pd_dg_col=$(echo "$line" | awk -F '[│|]' \
                '{for(i=1;i<=NF;i++) if(tolower($i) ~ /dg[[:space:]]*id/) print i}' | head -1)
            continue
        fi
        if [[ "$line" == *"│"* || "$line" == *"|"* ]] && [ -n "$pd_dg_col" ]; then
            local row_dg
            row_dg=$(echo "$line" | awk -F '[│|]' -v c="$pd_dg_col" '{print $c}' | xargs)
            [[ "$row_dg" == "$target_dg_id" ]] && pd_count=$((pd_count + 1))
        fi
    done <<< "$pd_table"

    DG_PD_COUNT="$pd_count"
    [ -n "$DG_RAID_LEVEL" ] && return 0 || return 1
}

# Parses PDs for a DG. Populates MASTER_PD_IDS (rebuild) and MASTER_NVME_PATHS (post-teardown access).
get_dg_physical_drives() {
    local target_dg_id=$1
    MASTER_PD_IDS=()
    MASTER_NVME_PATHS=()

    local table
    table=$($GRAID_CMD list physical_drive 2>/dev/null)

    local pd_col=0 dg_col=0 dev_col=0
    while IFS= read -r line; do
        if [[ "$line" == *"PD ID"* && "$line" == *"DG ID"* ]]; then
            pd_col=$(echo "$line" | awk -F '[│|]' '{for(i=1;i<=NF;i++) if(tolower($i) ~ /pd id/) print i}' | head -1)
            dg_col=$(echo "$line" | awk -F '[│|]' '{for(i=1;i<=NF;i++) if(tolower($i) ~ /dg id/) print i}' | head -1)
            dev_col=$(echo "$line" | awk -F '[│|]' '{for(i=1;i<=NF;i++) if(tolower($i) ~ /device/) print i}' | head -1)
            continue
        fi
        if [[ "$line" == *"│"* || "$line" == *"|"* ]] && [[ "${pd_col:-0}" -gt 0 ]]; then
            local row_dg
            row_dg=$(echo "$line" | awk -F '[│|]' -v c="${dg_col:-2}" '{print $c}' | xargs)
            if [[ "$row_dg" == "$target_dg_id" ]]; then
                local pd_id
                pd_id=$(echo "$line" | awk -F '[│|]' -v c="${pd_col:-1}" '{print $c}' | xargs)
                local dev_path
                dev_path=$(echo "$line" | awk -F '[│|]' -v c="${dev_col:-4}" '{print $c}' | xargs)
                [ -n "$pd_id" ] && MASTER_PD_IDS+=("$pd_id")
                if [ -n "$dev_path" ] && [ "$dev_path" != "-" ]; then
                    MASTER_NVME_PATHS+=("$(echo "$dev_path" | sed 's|^/dev/||')")
                fi
            fi
        fi
    done <<< "$table"
}

# Deletes a GRAID Virtual Drive then its parent Drive Group.
destroy_graid_array() {
    local vd_id=$1
    local dg_id=$2

    echo " "
    echo " [REBUILD] Deleting Virtual Drive (VD ID: $vd_id)..."
    yes | $GRAID_CMD delete virtual_drive "$dg_id" "$vd_id" 2>/tmp/graid_err.log
    # PIPESTATUS[1], not $?: `yes` gets SIGPIPE'd, which under pipefail would mask graidctl success.
    if [ "${PIPESTATUS[1]}" -ne 0 ]; then
        echo "[WARN] VD deletion reported: $(cat /tmp/graid_err.log)"
    fi
    sleep 3

    echo " "
    echo " [REBUILD] Deleting Drive Group (DG ID: $dg_id)..."
    yes | $GRAID_CMD delete drive_group "$dg_id" 2>/tmp/graid_err.log
    if [ "${PIPESTATUS[1]}" -ne 0 ]; then
        quit_with_enter "Drive Group deletion failed: $(cat /tmp/graid_err.log). Manual cleanup required."
    fi
    sleep 3

    rm -f /tmp/graid_err.log
    echo " [REBUILD] Array destroyed successfully."
}

# Creates a Drive Group (level $2, default RAID5) from MASTER_PD_IDS, then a VD. Sets NEW_DG_ID/NEW_GDG_DEV/CURRENT_VD_ID.
create_graid_array() {
    local drive_count=$1
    local raid_level="${2:-5}"

    if [ "${#MASTER_PD_IDS[@]}" -lt "$drive_count" ]; then
        quit_with_enter "Only ${#MASTER_PD_IDS[@]} PD IDs available — cannot build a ${drive_count}-drive array."
    fi

    local pd_display="${MASTER_PD_IDS[*]:0:$drive_count}"
    echo " [REBUILD] Preparing ${drive_count}-drive RAID ${raid_level} Drive Group..."
    echo "          PD IDs: $pd_display"

    local pre_dg_ids
    pre_dg_ids=$($GRAID_CMD list drive_group 2>/dev/null \
        | awk -F '│' '/│/ && !/DG ID/ {
            val=$2; gsub(/[[:space:]]/, "", val)
            if (val ~ /^[0-9]+$/) print val
          }' | xargs)

    echo " [REBUILD] Creating Drive Group..."
    if ! $GRAID_CMD create drive_group "RAID${raid_level}" \
         "${MASTER_PD_IDS[@]:0:$drive_count}" 2>/tmp/graid_err.log; then
        quit_with_enter "Drive Group creation failed: $(cat /tmp/graid_err.log)"
    fi
    sleep 3

    NEW_DG_ID=""
    local post_dg_ids
    post_dg_ids=$($GRAID_CMD list drive_group 2>/dev/null \
        | awk -F '│' '/│/ && !/DG ID/ {
            val=$2; gsub(/[[:space:]]/, "", val)
            if (val ~ /^[0-9]+$/) print val
          }' | xargs)

    for candidate in $post_dg_ids; do
        if [[ ! " $pre_dg_ids " =~ " $candidate " ]]; then
            NEW_DG_ID="$candidate"
            break
        fi
    done
    if [ -z "$NEW_DG_ID" ]; then
        NEW_DG_ID=$(echo "$post_dg_ids" | awk '{print $NF}')
        echo "[WARN] Could not isolate new DG ID by diff — using last in list: $NEW_DG_ID"
    fi

    echo " [REBUILD] Drive Group created (DG ID: $NEW_DG_ID). Creating Virtual Drive..."

    local pre_gdg_devs
    pre_gdg_devs=$(ls /dev/gdg*n* 2>/dev/null | xargs)

    if ! $GRAID_CMD create virtual_drive "$NEW_DG_ID" 2>/tmp/graid_err.log; then
        quit_with_enter "Virtual Drive creation failed: $(cat /tmp/graid_err.log)"
    fi

    echo " [REBUILD] Virtual Drive creation issued. Polling for block device..."
    local timeout=120
    local elapsed=0
    NEW_GDG_DEV=""

    while [ $elapsed -lt $timeout ]; do
        local post_gdg_devs
        post_gdg_devs=$(ls /dev/gdg*n* 2>/dev/null | xargs)
        for candidate in $post_gdg_devs; do
            if [[ ! " $pre_gdg_devs " =~ " $candidate " ]]; then
                NEW_GDG_DEV="$candidate"
                break 2
            fi
        done
        sleep 5
        elapsed=$((elapsed + 5))
        echo "    [WAIT] ${elapsed}/${timeout}s — waiting for new gdg block device..."
    done

    if [ -z "$NEW_GDG_DEV" ]; then
        quit_with_enter "New gdg block device did not appear within ${timeout}s. Check: $GRAID_CMD list virtual_drive"
    fi

    local new_gdg_name
    new_gdg_name=$(basename "$NEW_GDG_DEV" | grep -oE 'gdg[0-9]+')
    if inspect_vd_for_device "$new_gdg_name"; then
        echo "    [INFO] Updated VD ID: $CURRENT_VD_ID  |  DG ID: $CURRENT_DG_ID"
    else
        echo "[WARN] Could not re-inspect new VD — using DG $NEW_DG_ID as reference."
        CURRENT_VD_ID="unknown"
        CURRENT_DG_ID="$NEW_DG_ID"
    fi

    rm -f /tmp/graid_err.log
    echo " [REBUILD] Array ready at $NEW_GDG_DEV (DG: $NEW_DG_ID)"
}

# Polls until a gdg VD reaches an optimal/ready operational state.
wait_for_graid_ready() {
    local gdg_dev=$1
    local timeout=180
    local elapsed=0
    local gdg_name
    gdg_name=$(basename "$gdg_dev" | grep -oE 'gdg[0-9]+')

    echo "    [WAIT] Verifying $gdg_dev operational state..."
    while [ $elapsed -lt $timeout ]; do
        if [ -b "$gdg_dev" ]; then
            local vd_state
            vd_state=$($GRAID_CMD list virtual_drive 2>/dev/null \
                | grep -F "$gdg_name" \
                | awk -F '[│|]' '{for(i=1;i<=NF;i++) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i); print $i}}' \
                | grep -iE "^(optimal|healthy|ready|online|normal)$" \
                | head -1)
            if [ -n "$vd_state" ]; then
                echo " [SUCCESS] $gdg_dev is operational (state: $vd_state)"
                return 0
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo "    [WAIT] ${elapsed}/${timeout}s — VD not yet in optimal state..."
    done
    echo "[WARN] $gdg_dev did not reach confirmed optimal state within ${timeout}s."
    echo "       Block device exists — proceeding. Monitor: $GRAID_CMD list virtual_drive"
    return 0
}

# GRAID reports OPTIMAL immediately, but a background parity-init competes for minutes with no progress field.
# Call after every wait_for_graid_ready so fio measures real steady state; detected via a discarded probe.
wait_for_graid_steady_state() {
    local gdg_dev="$1"
    local max_wait="${2:-1500}"
    echo "    [WAIT] Waiting for array background initialization to reach steady state..."

    get_cpu_threads
    local probe_jobs="$C_SAFE"

    local probe_base="/tmp/.graid_steady_state_probe_$$"
    local probe_bwlog="${probe_base}_bw.log"
    local probe_out="${probe_base}.out"
    rm -f "$probe_bwlog" "$probe_out"

    fio --name=steady_state_probe --filename="$gdg_dev" --rw=randwrite --bs=4k \
        --direct=1 --ioengine=libaio --numjobs="$probe_jobs" --iodepth=64 \
        --norandommap --group_reporting=1 --time_based=1 --runtime="$max_wait" \
        --write_bw_log="$probe_base" --log_avg_msec=1000 --per_job_logs=0 \
        --output="$probe_out" >/dev/null 2>&1 &
    local probe_pid=$!

    local elapsed=0 stable_samples=15 cv_max=8 floor_kbps=1000000
    while [ "$elapsed" -lt "$max_wait" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        if ! kill -0 "$probe_pid" 2>/dev/null; then
            echo "    [WARN] Steady-state probe exited early after ${elapsed}s — proceeding anyway."
            rm -f "$probe_bwlog" "$probe_out"
            return 0
        fi
        [ -s "$probe_bwlog" ] || continue

        local result
        result=$(python3 - "$probe_bwlog" "$stable_samples" << 'PYEOF'
import sys
path, n = sys.argv[1], int(sys.argv[2])
buckets = {}
with open(path) as fh:
    for line in fh:
        parts = line.strip().split(',')
        if len(parts) < 2:
            continue
        try:
            sec = int(parts[0]) // 1000
            val = int(parts[1])
        except ValueError:
            continue
        buckets[sec] = buckets.get(sec, 0) + val
secs = sorted(buckets)
secs = secs[:-1] if len(secs) > n else secs
if len(secs) < n:
    print("insufficient")
else:
    last = [buckets[s] for s in secs[-n:]]
    mean = sum(last) / len(last)
    var = sum((x - mean) ** 2 for x in last) / len(last)
    cv = (var ** 0.5) / mean * 100 if mean else 999
    print(f"{mean:.0f}|{cv:.2f}")
PYEOF
)
        [ "$result" = "insufficient" ] && continue
        local mean_kbps cv_pct
        IFS='|' read -r mean_kbps cv_pct <<< "$result"
        echo "    [PROBE] t=${elapsed}s  mean_bw=$(awk -v k="$mean_kbps" 'BEGIN{printf "%.2f", k/1e6}')GB/s  cv=${cv_pct}%"

        if awk -v m="$mean_kbps" -v c="$cv_pct" -v floor="$floor_kbps" -v cvmax="$cv_max" \
            'BEGIN{exit !(m>floor && c<cvmax)}'; then
            echo "    [WAIT] Steady state reached after ${elapsed}s — proceeding to real benchmarks."
            kill -TERM "$probe_pid" 2>/dev/null
            wait "$probe_pid" 2>/dev/null
            rm -f "$probe_bwlog" "$probe_out"
            return 0
        fi
    done

    echo "[WARN] Steady state not confirmed within ${max_wait}s — proceeding anyway (results may still show the effect)."
    echo "[WARN] Probe log preserved for inspection: $probe_bwlog"
    kill -TERM "$probe_pid" 2>/dev/null
    wait "$probe_pid" 2>/dev/null
}

# Removes all MASTER_PD_IDS from the controller, freeing the NVMe drives back to the OS.
release_physical_drives() {
    echo "[TEARDOWN] Releasing all physical drives from GRAID controller..."
    local errors=0
    for pd_id in "${MASTER_PD_IDS[@]}"; do
        echo "[TEARDOWN]   Removing PD ID: $pd_id"
        yes | $GRAID_CMD delete physical_drive "$pd_id" 2>/tmp/graid_pd_err.log
        # PIPESTATUS[1], not $?: `yes` gets SIGPIPE'd, which under pipefail would mask graidctl success.
        if [ "${PIPESTATUS[1]}" -ne 0 ]; then
            echo "[WARN]     PD $pd_id removal reported: $(cat /tmp/graid_pd_err.log)"
            errors=$((errors + 1))
        fi
        sleep 1
    done
    rm -f /tmp/graid_pd_err.log
    if [ "$errors" -gt 0 ]; then
        echo "[WARN] $errors PD removal(s) reported errors. Some drives may still be bound."
    else
        echo " [SUCCESS] All physical drives released from GRAID controller."
    fi
    sleep 3
}

# Waits for an NVMe basename to reappear as a block device after teardown. Returns path in NVMe_DEV.
wait_for_nvme_accessible() {
    local nvme_base=$1
    local timeout=90
    local elapsed=0
    NVMe_DEV=""

    echo "    [WAIT] Polling for /dev/$nvme_base to appear after GRAID release..."
    while [ $elapsed -lt $timeout ]; do
        if [ -b "/dev/$nvme_base" ]; then
            NVMe_DEV="/dev/$nvme_base"
            echo " [SUCCESS] /dev/$nvme_base is accessible."
            return 0
        fi
        [ $((elapsed % 15)) -eq 0 ] && echo 1 > /sys/bus/pci/rescan 2>/dev/null
        sleep 3
        elapsed=$((elapsed + 3))
        echo "    [WAIT] ${elapsed}/${timeout}s — waiting for $nvme_base..."
    done
    return 1
}

# --- Report Helpers ---

# Extracts one performance line from a completed fio summary report.
extract_perf_metric() {
    local report_file=$1
    local after_label=$2
    local metric_keyword=$3

    awk -v lbl="$after_label" -v kw="$metric_keyword" '
        index($0, lbl)           { found=1; next }
        found && index($0, kw)   { gsub(/^[[:space:]]*-[[:space:]]*/, ""); print; found=0 }
        found && /\[\*\]/        { found=0 }
    ' "$report_file" | head -1
}

# --- GRAID empirical pass/fail: marketed spec never matches measured, so compare against prior real runs. ---

# Extracts GiB/s from a fio throughput line, normalizing MiB/s so comparisons use one unit.
_gib_from_throughput_line() {
    local line="$1"
    local val unit
    val=$(echo "$line" | grep -oE '[0-9.]+(GiB|MiB)/s' | grep -oE '^[0-9.]+')
    unit=$(echo "$line" | grep -oE '[0-9.]+(GiB|MiB)/s' | grep -oE 'GiB|MiB')
    if [ -z "$val" ]; then
        echo "0"
        return 1
    fi
    if [ "$unit" = "MiB" ]; then
        awk -v v="$val" 'BEGIN{printf "%.3f", v/1024}'
    else
        awk -v v="$val" 'BEGIN{printf "%.3f", v}'
    fi
}

# Looks up or interpolates expected GiB/s for a drive count; returns 1 if this model has no baseline.
_graid_baseline_lookup() {
    local token="$1" drive_count="$2"
    local -n _gbl_sr="$3" _gbl_sw="$4" _gbl_rr="$5" _gbl_rw="$6"
    local baseline_file="$DRIVE_DATA_DIR/GraidBaseline_${token}.txt"
    [ -f "$baseline_file" ] || return 1

    local rows
    rows=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$baseline_file" | sort -t, -k1,1n)
    [ -z "$rows" ] && return 1

    local exact
    exact=$(echo "$rows" | awk -F, -v d="$drive_count" '$1==d{print; exit}')
    if [ -n "$exact" ]; then
        IFS=',' read -r _ _gbl_sr _gbl_sw _gbl_rr _gbl_rw <<< "$exact"
        return 0
    fi

    local lower="" upper="" d sr sw rr rw
    while IFS=',' read -r d sr sw rr rw; do
        if [ "$d" -lt "$drive_count" ]; then
            lower="$d,$sr,$sw,$rr,$rw"
        elif [ -z "$upper" ] && [ "$d" -gt "$drive_count" ]; then
            upper="$d,$sr,$sw,$rr,$rw"
        fi
    done <<< "$rows"

    if [ -n "$lower" ] && [ -n "$upper" ]; then
        local ld ls1 ls2 ls3 ls4 ud us1 us2 us3 us4 frac
        IFS=',' read -r ld ls1 ls2 ls3 ls4 <<< "$lower"
        IFS=',' read -r ud us1 us2 us3 us4 <<< "$upper"
        frac=$(awk -v d="$drive_count" -v l="$ld" -v u="$ud" 'BEGIN{print (d-l)/(u-l)}')
        _gbl_sr=$(awk -v a="$ls1" -v b="$us1" -v f="$frac" 'BEGIN{printf "%.3f", a+(b-a)*f}')
        _gbl_sw=$(awk -v a="$ls2" -v b="$us2" -v f="$frac" 'BEGIN{printf "%.3f", a+(b-a)*f}')
        _gbl_rr=$(awk -v a="$ls3" -v b="$us3" -v f="$frac" 'BEGIN{printf "%.3f", a+(b-a)*f}')
        _gbl_rw=$(awk -v a="$ls4" -v b="$us4" -v f="$frac" 'BEGIN{printf "%.3f", a+(b-a)*f}')
        echo "[INFO] No exact baseline for $drive_count drives — interpolated between $ld and $ud drives." >&2
        return 0
    elif [ -n "$lower" ]; then
        IFS=',' read -r _ _gbl_sr _gbl_sw _gbl_rr _gbl_rw <<< "$lower"
        echo "[WARN] $drive_count drives exceeds the largest known baseline size — using that size's numbers as a reference point, not a true expectation." >&2
        return 0
    elif [ -n "$upper" ]; then
        IFS=',' read -r _ _gbl_sr _gbl_sw _gbl_rr _gbl_rw <<< "$upper"
        echo "[WARN] $drive_count drives is below the smallest known baseline size — using that size's numbers as a reference point, not a true expectation." >&2
        return 0
    fi
    return 1
}

# Compares measured throughput against the empirical baseline on the SOP's 70%/80% convention.
_graid_check_pass_fail() {
    local model="$1" token="$2" drive_count="$3" report_file="$4"
    [ -f "$report_file" ] || return 1

    if [ "${QD_UNCALIBRATED:-0}" = "1" ]; then
        echo ""
        echo "====================================================================="
        echo " GRAID RESULT — $model, ${drive_count} drives: MANUAL REVIEW REQUIRED"
        echo "====================================================================="
        echo " This run used default queue depths ($model has no calibration profile),"
        echo " so the numbers cannot be compared against the empirical baseline -- and"
        echo " are deliberately NOT saved as one, which would poison future comparisons."
        echo " Review $report_file by hand."
        vrecord "GRAID-$token" "REVIEW" "uncalibrated run (default queue depths) -- manual review of $report_file"
        return 0
    fi

    local seq_read_line seq_write_line rand_read_line rand_write_line
    seq_read_line=$(extract_perf_metric "$report_file" "[*] 128K Sequential Read:" "Throughput")
    seq_write_line=$(extract_perf_metric "$report_file" "[*] 128K Sequential Write:" "Throughput")
    rand_read_line=$(extract_perf_metric "$report_file" "[*] 4K Random Read:" "Throughput")
    rand_write_line=$(extract_perf_metric "$report_file" "[*] 4K Random Write:" "Throughput")

    local m_sr m_sw m_rr m_rw
    m_sr=$(_gib_from_throughput_line "$seq_read_line")
    m_sw=$(_gib_from_throughput_line "$seq_write_line")
    m_rr=$(_gib_from_throughput_line "$rand_read_line")
    m_rw=$(_gib_from_throughput_line "$rand_write_line")

    echo ""
    echo "====================================================================="
    echo " GRAID REAL-WORLD PASS/FAIL — $model, ${drive_count} drives"
    echo " (empirical baseline from prior runs, not datasheet theoretical)"
    echo "====================================================================="

    local b_sr b_sw b_rr b_rw
    if ! _graid_baseline_lookup "$token" "$drive_count" b_sr b_sw b_rr b_rw; then
        echo " [INFO] No empirical baseline exists yet for $model."
        echo "        Measured: SeqRead=${m_sr}GiB/s  SeqWrite=${m_sw}GiB/s  RandRead=${m_rr}GiB/s  RandWrite=${m_rw}GiB/s"
        local save_baseline
        read -p " Save this run as the first baseline data point for $model? (y/n): " save_baseline
        if [[ "$save_baseline" == "y" || "$save_baseline" == "Y" ]]; then
            mkdir -p "$DRIVE_DATA_DIR"
            local baseline_file="$DRIVE_DATA_DIR/GraidBaseline_${token}.txt"
            if [ ! -f "$baseline_file" ]; then
                {
                    echo "# GRAID empirical real-world baseline -- NOT datasheet/theoretical numbers."
                    echo "# Units: GiB/s. Grows over time as new sweeps run for this model."
                    echo "# drives,SeqReadGiBps,SeqWriteGiBps,RandReadGiBps,RandWriteGiBps"
                } > "$baseline_file"
            fi
            echo "${drive_count},${m_sr},${m_sw},${m_rr},${m_rw}" >> "$baseline_file"
            echo " [SUCCESS] Saved to $baseline_file"
        fi
        echo "====================================================================="
        return 0
    fi

    local labels=("Seq Read" "Seq Write" "Rand Read" "Rand Write")
    local measured=("$m_sr" "$m_sw" "$m_rr" "$m_rw")
    local baseline=("$b_sr" "$b_sw" "$b_rr" "$b_rw")
    local overall_fail=false overall_marginal=false
    local i pct verdict pct_sum=0

    for i in 0 1 2 3; do
        pct=$(awk -v m="${measured[$i]}" -v e="${baseline[$i]}" 'BEGIN{printf "%.1f", (e>0)?(m/e)*100:0}')
        pct_sum=$(awk -v s="$pct_sum" -v p="$pct" 'BEGIN{print s+p}')
        # Thresholds are named config vars (GRAID_PASS_PCT/GRAID_MARGINAL_PCT), not magic numbers.
        if awk -v p="$pct" -v t="$GRAID_PASS_PCT" 'BEGIN{exit !(p>=t)}'; then
            verdict="PASS"
        elif awk -v p="$pct" -v t="$GRAID_MARGINAL_PCT" 'BEGIN{exit !(p>=t)}'; then
            verdict="MARGINAL"; overall_marginal=true
        else
            verdict="FAIL"; overall_fail=true
        fi
        printf "   %-11s measured=%-10s baseline=%-10s %6s%%   [%s]\n" \
            "${labels[$i]}" "${measured[$i]}GiB/s" "${baseline[$i]}GiB/s" "$pct" "$verdict"
    done

    echo "====================================================================="
    if [ "$overall_fail" = true ]; then
        echo " OVERALL: FAIL — one or more workloads below ${GRAID_MARGINAL_PCT}% of empirical baseline."
    elif [ "$overall_marginal" = true ]; then
        echo " OVERALL: MARGINAL — one or more workloads between ${GRAID_MARGINAL_PCT}-${GRAID_PASS_PCT}% of baseline."
    else
        echo " OVERALL: PASS — all workloads at or above ${GRAID_PASS_PCT}% of empirical baseline."
    fi
    echo "====================================================================="

    # A degraded first run used to become permanent; offer to update an exact row this run clearly exceeds.
    local avg_pct; avg_pct=$(awk -v s="$pct_sum" 'BEGIN{printf "%.1f", s/4}')
    local baseline_file="$DRIVE_DATA_DIR/GraidBaseline_${token}.txt"
    if awk -v a="$avg_pct" -v t="$GRAID_REBASELINE_TRIGGER_PCT" 'BEGIN{exit !(a>=t)}' \
       && grep -qE "^${drive_count}," "$baseline_file" 2>/dev/null; then
        echo ""
        echo " [INFO] This run exceeded the existing baseline by an average of"
        echo "        ${avg_pct}% across all four workloads -- the saved baseline for"
        echo "        $model at ${drive_count} drives may itself have been a degraded run."
        local update_baseline
        read -p " Update the baseline for $model / ${drive_count} drives to THIS run instead? (y/n): " update_baseline
        if [[ "$update_baseline" == "y" || "$update_baseline" == "Y" ]]; then
            grep -vE "^${drive_count}," "$baseline_file" > "${baseline_file}.tmp"
            echo "${drive_count},${m_sr},${m_sw},${m_rr},${m_rw}" >> "${baseline_file}.tmp"
            sort -t, -k1,1n "${baseline_file}.tmp" -o "${baseline_file}.tmp"
            mv "${baseline_file}.tmp" "$baseline_file"
            echo " [SUCCESS] Baseline updated for $model / ${drive_count} drives."
        fi
    fi
}

# Manual reset for a stale GRAID baseline -- clears one drive-count row or a whole model.
graid_reset_baseline() {
    write_header "Reset GRAID Empirical Baseline"
    local files=("$DRIVE_DATA_DIR"/GraidBaseline_*.txt)
    if [ ! -e "${files[0]}" ]; then
        echo "No GRAID baselines saved yet."
        pause; return
    fi
    echo "Saved baselines:"
    local i=1
    for f in "${files[@]}"; do
        printf "  %d) %s\n" "$i" "$(basename "$f")"
        i=$((i+1))
    done
    read -p "Select a baseline to reset (number), or Q to go back: " sel
    [[ "$sel" =~ ^[Qq]$ ]] && return
    local chosen="${files[$((sel-1))]}"
    [ -f "$chosen" ] || { echo "Invalid selection."; pause; return; }

    echo ""
    echo "1) Delete the entire baseline file (start over from scratch for this model)"
    echo "2) Delete just one drive-count row"
    read -p "Choice: " reset_choice
    case "$reset_choice" in
      1) rm -f "$chosen"; echo "[SUCCESS] Deleted $(basename "$chosen")." ;;
      2)
        read -p "Drive count to remove: " dc
        grep -vE "^${dc}," "$chosen" > "${chosen}.tmp" && mv "${chosen}.tmp" "$chosen"
        echo "[SUCCESS] Removed the ${dc}-drive row from $(basename "$chosen")."
        ;;
      *) echo "Invalid choice, nothing changed." ;;
    esac
    pause
}

# Dynamic comparison across proportional phases. Reads _PHASE_DRIVE_COUNTS[]/_PHASE_REPORT_FILES[].
generate_combined_summary() {
    local output_file=$1
    local drive_model=$2
    local run_ts=$3

    local n_phases=${#_PHASE_DRIVE_COUNTS[@]}
    local tests=(
        "[*] 128K Sequential Read:"
        "[*] 128K Sequential Write:"
        "[*] 4K Random Read:"
        "[*] 4K Random Write:"
    )

    local col_labels=()
    for n in "${_PHASE_DRIVE_COUNTS[@]}"; do
        col_labels+=("${n}-Drive RAID5")
    done

    local col_w=20
    local sep_total=$(( 28 + 1 + n_phases * (col_w + 3) ))

    {
        echo "====================================================================="
        echo "       EXXACT GRAID PLATFORM VALIDATION — COMPARATIVE SUMMARY        "
        echo "====================================================================="
        echo " Run Timestamp : $run_ts"
        echo " Drive Model   : $drive_model"
        echo " System        : $(hostname -f 2>/dev/null || hostname)"
        echo " Kernel        : $(uname -r)"
        echo " FIO Version   : $(fio --version 2>/dev/null | head -n 1)"
        echo "====================================================================="
        echo ""

        printf " %-28s" "Metric"
        for lbl in "${col_labels[@]}"; do printf " | %-${col_w}s" "$lbl"; done
        echo ""
        printf ' %.0s-' $(seq 1 "$sep_total"); echo ""

        for test_label in "${tests[@]}"; do
            local clean_label="${test_label//\[*\] /}"
            clean_label="${clean_label/:/}"
            printf "\n %-28s\n" "[ $clean_label ]"

            printf " %-28s" "  Throughput"
            for i in "${!_PHASE_REPORT_FILES[@]}"; do
                local rpt="${_PHASE_REPORT_FILES[$i]}"
                local val="N/A"
                [ -f "$rpt" ] && val=$(extract_perf_metric "$rpt" "$test_label" "Throughput")
                printf " | %-${col_w}s" "${val:-N/A}"
            done
            echo ""

            printf " %-28s" "  Latency (clat avg)"
            for i in "${!_PHASE_REPORT_FILES[@]}"; do
                local rpt="${_PHASE_REPORT_FILES[$i]}"
                local val="N/A"
                [ -f "$rpt" ] && val=$(extract_perf_metric "$rpt" "$test_label" "Latency")
                printf " | %-${col_w}s" "${val:-N/A}"
            done
            echo ""
        done

        echo ""
        printf ' %.0s-' $(seq 1 "$sep_total"); echo ""
        echo ""
        echo " Phase Reports:"
        for i in "${!_PHASE_REPORT_FILES[@]}"; do
            local n="${_PHASE_DRIVE_COUNTS[$i]}"
            local rpt="${_PHASE_REPORT_FILES[$i]}"
            local phase_num=$((i + 1))
            local lbl
            printf -v lbl "Phase %d  — %2d-drive RAID 5" "$phase_num" "$n"
            echo "   $lbl : $([ -f "$rpt" ] && basename "$rpt" || echo "NOT GENERATED")"
        done
        echo "====================================================================="
    } > "$output_file"
}

# --- QD Sweep core, used inline by Single Drive / MDADM Build / GRAID Build / HW RAID Test ---

# _sweep_single_thread_bw <path> <rw> <bs> <label> <log_subdir> <out_nameref> -- one escalating-depth sweep.
_sweep_single_thread_bw() {
    local path="$1" rw="$2" bs="$3" label="$4" log_subdir="$5"
    local -n _sstb_out="$6"
    local qd_steps=(1 2 4 8 16 32 64 128 256 512)
    local csv="$log_subdir/${label}_sweep.csv"
    echo "qd,bw_raw,clean_bw,pct_gain" > "$csv"

    local prev_qd=1 prev_metric=0 detected=128
    for qd in "${qd_steps[@]}"; do
        local sweep_log="/tmp/sweep_${label}_qd_${qd}.tmp"
        fio --name=sweep --filename="$path" --rw="$rw" --bs="$bs" \
            --direct=1 --ioengine=libaio --numjobs=1 --iodepth="$qd" \
            --time_based=1 --runtime=30 --group_reporting=1 \
            --eta=never --output="$sweep_log"

        local mode="read"; [[ "$rw" == *write* ]] && mode="write"
        local current_bw
        current_bw=$(grep -E "^\s*${mode}:.*BW=" "$sweep_log" | head -n 1 | sed -E 's/.*BW=([^ ,\(]+).*/\1/')
        local raw_bw_num
        raw_bw_num=$(echo "$current_bw" | grep -oE '^[0-9.]+')
        local clean_bw=0
        if [ -n "$raw_bw_num" ]; then
            if [[ "$current_bw" == *"GiB"* || "$current_bw" == *"GB"* ]]; then
                clean_bw=$(awk -v n="$raw_bw_num" 'BEGIN { printf "%d", n * 1024 * 1000 }')
            else
                clean_bw=$(awk -v n="$raw_bw_num" 'BEGIN { printf "%d", n * 1000 }')
            fi
        fi
        [ -z "$clean_bw" ] || [ "$clean_bw" -eq 0 ] 2>/dev/null && clean_bw=0

        local pct_gain="N/A" should_break=false
        if [ "$prev_metric" -ne 0 ] && [ "$clean_bw" -ne 0 ]; then
            pct_gain=$(( (clean_bw - prev_metric) * 100 / prev_metric ))
            if [ "$pct_gain" -lt 5 ]; then detected=$prev_qd; should_break=true; fi
        fi
        echo "${qd},${current_bw},${clean_bw},${pct_gain}" >> "$csv"
        cp "$sweep_log" "$log_subdir/${label}_qd${qd}.txt"
        rm -f "$sweep_log"

        if [ "$clean_bw" -eq 0 ] && [ "$prev_metric" -ne 0 ]; then
            echo "[WARN] QD=$qd returned zero bandwidth — skipping step."
            continue
        fi
        [ "$should_break" = true ] && break
        prev_qd=$qd
        prev_metric=$clean_bw
    done

    _sstb_out=$detected
}

# Full QD-characterization sweep against ONE drive, writing $SWEEP_DIR/TQDpD_<token>.txt.
_run_qd_sweep_for_path() {
    local path="$1" model="$2" token="$3"
    local log_subdir="${4:-$SWEEP_DIR/Logs}"
    mkdir -p "$log_subdir"

    echo "---------------------------------------------------------------------"
    echo ">>> Calibrating Model: $model via Target Node Path: $path"
    echo "---------------------------------------------------------------------"
    local drive_sweep_start=$SECONDS
    # The QD profile is deliberately NOT per-run -- it's a persistent cross-run cache.
    local target_output_file="${QD_RUN_DIR:-$SWEEP_DIR}/TQDpD_${token}.txt"
    mkdir -p "$(dirname "$target_output_file")" 2>/dev/null

    local qd_steps=(1 2 4 8 16 32 64 128 256 512)
    local detected_seq=128
    local detected_seq_write=128
    local detected_rand=512

    # --- Sequential READ sweep ---
    echo "[SWEEP] Running Sequential Read Sweep..."
    _sweep_single_thread_bw "$path" "read" "128K" "${token}_seq" "$log_subdir" detected_seq

    # Applying the READ-derived depth to writes collapsed sequential write throughput ~62%: writes need real depth.
    echo "[SWEEP] Running Sequential Write Sweep..."
    _sweep_single_thread_bw "$path" "write" "128K" "${token}_seqwrite" "$log_subdir" detected_seq_write

    # One fio thread hits a submission ceiling below the drive's real queue limit.
    # Measured on SB5PH27X019T: 1->4 threads scaled near-linearly, 4->8 barely moved. A ladder finds the ceiling.
    local rand_job_steps=(2 4 8 16)
    local job_peak_iops=()
    local job_total_tqd=()

    for rj in "${rand_job_steps[@]}"; do
        echo "[SWEEP] Running Random Read Sweep (numjobs=$rj)..."
        local prev_qd=1
        local prev_metric=0
        local this_job_qd=0
        local this_job_iops=0
        local this_job_csv="$log_subdir/${token}_rand_sweep_j${rj}.csv"
        echo "qd,iops_raw,clean_iops,pct_gain" > "$this_job_csv"

        for qd in "${qd_steps[@]}"; do
            local sweep_log="/tmp/sweep_rand_j${rj}_qd_${qd}.tmp"
            fio --name=sweep --filename="$path" --rw=randread --bs=4K \
                --direct=1 --ioengine=libaio --numjobs="$rj" --iodepth="$qd" \
                --time_based=1 --runtime=30 --group_reporting=1 \
                --eta=never --output="$sweep_log"

            local current_iops
            current_iops=$(grep -E "^\s*read:.*IOPS=" "$sweep_log" | head -n 1 | sed -E 's/.*IOPS=([^ ,\(]+).*/\1/')
            local raw_iops_num
            raw_iops_num=$(echo "$current_iops" | grep -oE '^[0-9.]+')
            local clean_iops=0
            if [ -n "$raw_iops_num" ]; then
                if [[ "$current_iops" == *"k"* || "$current_iops" == *"K"* ]]; then
                    clean_iops=$(awk -v n="$raw_iops_num" 'BEGIN { printf "%d", n * 1000 }')
                elif [[ "$current_iops" == *"m"* || "$current_iops" == *"M"* ]]; then
                    clean_iops=$(awk -v n="$raw_iops_num" 'BEGIN { printf "%d", n * 1000000 }')
                else
                    clean_iops=$(awk -v n="$raw_iops_num" 'BEGIN { printf "%d", n }')
                fi
            fi
            [ -z "$clean_iops" ] || [ "$clean_iops" -eq 0 ] 2>/dev/null && clean_iops=0

            local pct_gain="N/A" should_break=false
            if [ "$prev_metric" -ne 0 ] && [ "$clean_iops" -ne 0 ]; then
                pct_gain=$(( (clean_iops - prev_metric) * 100 / prev_metric ))
                if [ "$pct_gain" -lt 5 ]; then this_job_qd=$prev_qd; this_job_iops=$prev_metric; should_break=true; fi
            fi
            echo "${qd},${current_iops},${clean_iops},${pct_gain}" >> "$this_job_csv"
            cp "$sweep_log" "$log_subdir/${token}_rand_j${rj}_qd${qd}.txt"
            rm -f "$sweep_log"

            if [ "$clean_iops" -eq 0 ] && [ "$prev_metric" -ne 0 ]; then
                echo "[WARN] numjobs=$rj QD=$qd returned zero IOPS — skipping step."
                continue
            fi
            [ "$should_break" = true ] && break
            prev_qd=$qd
            prev_metric=$clean_iops
        done

        if [ "$this_job_qd" -eq 0 ]; then
            this_job_qd=$prev_qd
            this_job_iops=$prev_metric
            echo "[WARN] numjobs=$rj never plateaued within the tested iodepth range — using the highest point reached. Consider extending qd_steps."
        fi

        job_peak_iops+=("$this_job_iops")
        job_total_tqd+=("$((this_job_qd * rj))")
        echo "[SWEEP] numjobs=$rj ceiling: ${this_job_iops} IOPS at total TQD=$((this_job_qd * rj))"
    done

    # Pick the smallest job count already capturing ~the full ceiling -- catches a still-CPU-bound count.
    local global_max_iops=0
    for v in "${job_peak_iops[@]}"; do
        if [ "$v" -gt "$global_max_iops" ]; then global_max_iops=$v; fi
    done

    local last_idx=$((${#rand_job_steps[@]} - 1))
    detected_rand=${job_total_tqd[$last_idx]}

    local scaling_csv="$log_subdir/${token}_rand_scaling_summary.csv"
    echo "numjobs,total_tqd,peak_iops,pct_of_global_max" > "$scaling_csv"
    local idx picked=false
    for idx in "${!rand_job_steps[@]}"; do
        local pk=${job_peak_iops[$idx]}
        local pct_of_max
        pct_of_max=$(awk -v a="$pk" -v b="$global_max_iops" 'BEGIN { printf "%.1f", (b>0)?(a/b)*100:0 }')
        echo "${rand_job_steps[$idx]},${job_total_tqd[$idx]},${pk},${pct_of_max}" >> "$scaling_csv"

        if [ "$picked" = false ]; then
            local within
            within=$(awk -v a="$pk" -v b="$global_max_iops" 'BEGIN { print (a >= b*0.95) ? 1 : 0 }')
            if [ "$within" -eq 1 ]; then
                detected_rand=${job_total_tqd[$idx]}
                picked=true
            fi
        fi
    done

    echo "[DECISION] Selected RAND_TQDpD=$detected_rand from the job-count comparison (global max IOPS observed: $global_max_iops). Full breakdown: $scaling_csv"

    if [ "$detected_rand" -eq "${job_total_tqd[$last_idx]}" ] && [ "${#rand_job_steps[@]}" -gt 1 ]; then
        echo "[WARN] Even the highest tested job count (${rand_job_steps[$last_idx]}) was needed to reach the plateau — the true ceiling may be higher than this ladder could find. Consider adding a higher job count to rand_job_steps."
    fi

    {
        echo "SEQ_TQDpD=$detected_seq"
        echo "SEQ_WRITE_TQDpD=$detected_seq_write"
        echo "RAND_TQDpD=$detected_rand"
    } > "$target_output_file"

    echo "[LOG] Profile Created: $target_output_file [SEQ=$detected_seq, SEQ_WRITE=$detected_seq_write, RAND=$detected_rand]"

    if [ "$QA_AVAILABLE" = true ]; then
        echo "[SYNC] Uploading QD profile to QA server..."
        if sshpass -p "$QA_SSHPASS" scp "${QA_SSH_OPTS[@]}" \
               "$target_output_file" \
               "$QA_SERVER_USER@$QA_SERVER_IP:$QA_PATH/QDsweeps/" 2>/tmp/sync_err.log; then
            echo "[SYNC] Profile upload successful: $(basename "$target_output_file")"
        else
            echo "[WARN] Profile saved locally at $target_output_file — upload manually when connectivity is restored."
        fi
    else
        echo "[INFO] QA server unavailable — profile saved locally only: $target_output_file"
    fi

    local drive_sweep_end=$SECONDS
    local sweep_timing_log="$log_subdir/${token}_sweep_timing.log"
    _write_timing_log "$sweep_timing_log" \
        "QD Sweep — $model ($path)" \
        "$drive_sweep_start" "$drive_sweep_end" \
        "Profile: SEQ_TQDpD=$detected_seq SEQ_WRITE_TQDpD=$detected_seq_write RAND_TQDpD=$detected_rand  Output: $target_output_file"

    _prompt_rated_spec "$model" "$token"
}

# Prompts for datasheet numbers and saves RatedSpec_<token>.txt. Blank records N/A; 'skip' abandons.
_prompt_rated_spec() {
    local model="$1" token="$2"
    local spec_file="$DRIVE_DATA_DIR/RatedSpec_${token}.txt"
    [ -f "$spec_file" ] && return 0

    # Unattended/NoOS/detached: no terminal to prompt on. Skip rather than block -- or, worse,
    # abort the whole run when _review_entries hits EOF and exits. Rated-spec pass/fail is
    # optional; the file can be created by hand later, same as the interactive 'skip' path.
    if [ ! -t 0 ]; then
        echo "[INFO] No rated-spec file for $model and no terminal to prompt on -- skipping"
        echo "       spec-based pass/fail for this model (create $spec_file by hand to enable it)."
        return 1
    fi

    mkdir -p "$DRIVE_DATA_DIR"
    echo ""
    echo "====================================================================="
    echo " No rated-spec file found for $model"
    echo " ($spec_file)"
    echo "====================================================================="
    echo " Enter the manufacturer's datasheet numbers now to enable automated"
    echo " pass/fail against spec for this model. Press Enter with no value"
    echo " to record a field as N/A. Type 'skip' at any prompt to abandon"
    echo " this file entirely -- you can create it by hand later."
    echo "====================================================================="

    local fields=(
        "128kSeqRead:128K Sequential Read (MB/s)"
        "SeqReadLat:Sequential Read Latency (usec)"
        "128kSeqWrite:128K Sequential Write (MB/s)"
        "SeqWriteLat:Sequential Write Latency (usec)"
        "4kRandRead:4K Random Read (IOPS)"
        "RandReadLat:Random Read Latency (usec)"
        "4kRandWrite:4K Random Write (IOPS)"
        "RandWriteLat:Random Write Latency (usec)"
    )
    local values=()
    local entry key label value
    # Reviewed as a block: a datasheet value transcribed into the wrong row is the mistake this catches.
    while true; do
        values=()
        for entry in "${fields[@]}"; do
            IFS=':' read -r key label <<< "$entry"
            read -p "  $label [N/A]: " value
            if [[ "${value,,}" == "skip" ]]; then
                echo "[INFO] Skipped — no rated-spec file created for $model."
                return 1
            fi
            [ -z "$value" ] && value="N/A"
            values+=("$key=$value")
        done
        _review_entries "Review Rated Spec -- $model" "${values[@]}" && break
        echo "Re-entering the datasheet values."
    done

    {
        echo "# 128k/4k performance numbers=MB/s"
        echo "# Latency (Lat)=microseconds"
        printf '%s\n' "${values[@]}"
    } > "$spec_file"
    echo "[SUCCESS] Rated-spec file created: $spec_file"
    return 0
}

# Ensures a QD profile exists for the model. Keyed per MODEL, so one sweep serves every drive of it.
_ensure_qd_profile() {
    local path="$1" model="$2" token="$3"
    if _qd_profile_path "$token" >/dev/null; then
        echo "[INFO] QD profile already exists for $model — skipping calibration sweep."
        return 0
    fi
    echo "[INFO] No QD profile for $model yet — running calibration sweep now (one-time per model)."
    _run_qd_sweep_for_path "$path" "$model" "$token"
}


# --- Option 1: Single Drive Testing ---

run_single_drive_testing() {
    clear
    echo "====================================================================="
    echo "                  OPTION 1: SINGLE DRIVE TESTING                      "
    echo "====================================================================="
    echo ""
    echo " Select drive(s), then preconditioning and QD calibration run"
    echo " automatically for anything that isn't already done before the"
    echo " actual benchmark starts."
    echo ""

    echo "[INFO] Scanning for available raw NVMe drives..."
    _discover_candidate_drives
    local raw_count=${#_DISCOVERED_PATHS[@]}
    if [ "$raw_count" -eq 0 ]; then
        pause_to_menu "No unmounted, non-RAID NVMe drives available to test."
        return
    fi

    echo ""
    echo " Select one or more drives to test. Use numbers, ranges, or 'all'."
    echo " Example: 1-6,8,10-12"
    echo " Multiple drives are tested SIMULTANEOUSLY — independent NVMe devices"
    echo " don't share a compute bottleneck the way GRAID/HW RAID arrays can,"
    echo " so running them at once is safe as long as the CPU thread budget"
    echo " is divided across them (handled automatically below)."
    echo ""
    read -p "Selection: " sel
    local sel_indices=()
    _parse_selection_string "$sel" sel_indices "$raw_count"
    if [ ${#sel_indices[@]} -eq 0 ]; then
        pause_to_menu "No valid drive(s) selected."
        return
    fi

    local sel_paths=() sel_models=() sel_tokens=() sel_serials=()
    for idx in "${sel_indices[@]}"; do
        sel_paths+=("${_DISCOVERED_PATHS[$((idx-1))]}")
        sel_models+=("${_DISCOVERED_MODELS[$((idx-1))]}")
        sel_serials+=("${_DISCOVERED_SERIALS[$((idx-1))]}")
        get_drive_metadata "${_DISCOVERED_PATHS[$((idx-1))]}"
        sel_tokens+=("$DRIVE_MODEL_TOKEN")
    done

    if ! _check_selection_media sel_paths; then
        pause_to_menu "Reselect drives of a single type."
        return
    fi
    # Rotational media: health check only, then done. Nothing below this point applies to a platter.
    if _media_is_hdd; then
        _hdd_health_validation "single" "${sel_paths[@]}"
        pause_to_menu "HDD health validation complete."
        return
    fi

    # Previously had no NUMA warning or destructive confirmation -- preconditioning purges the drive.
    if [ ${#sel_paths[@]} -gt 1 ]; then
        _check_selection_numa_spread sel_paths || { pause_to_menu "Aborted -- re-select drives to avoid the cross-NUMA spread."; return; }
    fi

    echo ""
    echo "====================================================================="
    echo " WARNING: preconditioning will PURGE (secure erase) and overwrite all"
    echo " data on the following drive(s):"
    for p in "${sel_paths[@]}"; do echo "   - $p"; done
    echo "====================================================================="
    local confirm_wipe
    read -p "Type 'YES' to confirm and proceed: " confirm_wipe
    if [ "$confirm_wipe" != "YES" ]; then
        pause_to_menu "Aborted -- no drives were touched."
        return
    fi

    local batch_status=()
    _precondition_drive_batch sel_paths sel_models sel_serials batch_status "$SWEEP_DIR/Logs"

    declare -A ensured_models
    for i in "${!sel_paths[@]}"; do
        local tok="${sel_tokens[$i]}"
        [ -n "${ensured_models[$tok]:-}" ] && continue
        ensured_models[$tok]=1
        _ensure_qd_profile "${sel_paths[$i]}" "${sel_models[$i]}" "$tok"
    done

    get_cpu_threads
    _apply_concurrent_cpu_budget "${#sel_paths[@]}"

    local run_ts; run_ts=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local pids=()
    _PHASE_DRIVE_COUNTS=()
    _PHASE_REPORT_FILES=()

    for i in "${!sel_paths[@]}"; do
        local target_dev="${sel_paths[$i]}" target_model="${sel_models[$i]}" target_token="${sel_tokens[$i]}"
        local target_serial="${sel_serials[$i]}"

        (
            _load_qd_profile "$target_token" 1
            DRIVE_MODEL="$target_model"
            DRIVE_SERIAL="$target_serial"
            DRIVE_COUNT=1
            pushd "$RESULTS_DIR" > /dev/null
            execute_and_summarize_fio "$target_dev" "$(basename "$target_dev")" "$FINAL_JOBS" "$FINAL_DEPTH" "SINGLE" false
            popd > /dev/null
        ) &
        pids+=("$!")
        _PHASE_DRIVE_COUNTS+=(1)
        _PHASE_REPORT_FILES+=("$RESULTS_DIR/fio_$(basename "$target_dev").txt")
    done

    [ ${#pids[@]} -gt 1 ] && echo "" && echo "[INFO] Waiting for all ${#pids[@]} simultaneous drive test(s) to complete..."
    wait "${pids[@]}"

    if [ ${#_PHASE_REPORT_FILES[@]} -gt 1 ]; then
        local summary_file="$RESULTS_DIR/validation_summary_SingleDrive_$(date +%Y%m%d_%H%M%S).txt"
        generate_combined_summary "$summary_file" "Single Drive (mixed selection)" "$run_ts"
        echo ""
        echo " [SUCCESS] Combined summary saved: $summary_file"
    fi

    pause_to_menu "Validation run complete."
}

# --- Option 2: MDADM RAID -- Build creates an array; Test discovers existing ones and can run several. ---

# Waits out any background resync before benchmarking; Ctrl+C cancels only the wait and returns failure.
_wait_for_mdadm_idle() {
    local md_name="$1"
    local status_line
    status_line=$(grep -A2 "^$md_name" /proc/mdstat 2>/dev/null | grep -E "resync|recovery|reshape|check")
    if [ -z "$status_line" ]; then
        # A new array can take a moment to start reporting resync; require "no resync" to hold twice.
        sleep 3
        status_line=$(grep -A2 "^$md_name" /proc/mdstat 2>/dev/null | grep -E "resync|recovery|reshape|check")
        [ -z "$status_line" ] && return 0
    fi

    echo ""
    echo "[INFO] /dev/$md_name is still building/resyncing:"
    echo "       $status_line"
    echo "[INFO] Benchmarking now would contaminate results with resync I/O,"
    echo "       the same class of bug that affected GRAID validation runs"
    echo "       this suite fixed earlier."
    echo "[INFO] Waiting for it to finish — press Ctrl+C to stop waiting and"
    echo "       cancel testing instead."

    local interrupted=false
    trap 'interrupted=true' SIGINT
    while true; do
        status_line=$(grep -A2 "^$md_name" /proc/mdstat 2>/dev/null | grep -E "resync|recovery|reshape|check")
        [ -z "$status_line" ] && break
        echo "    [WAIT] /dev/$md_name: $status_line"
        sleep 10
        [ "$interrupted" = true ] && break
    done
    trap - SIGINT

    if [ "$interrupted" = true ]; then
        echo ""
        echo "[CANCELLED] Wait interrupted — /dev/$md_name may still be building."
        return 1
    fi

    echo " [SUCCESS] /dev/$md_name finished building — proceeding."
    return 0
}

# --- Option 2a: MDADM — Build Array ---
run_mdadm_build_array() {
    clear
    echo "====================================================================="
    echo "              OPTION 2 / BUILD: MDADM ARRAY CREATION                  "
    echo "====================================================================="
    echo ""
    echo " Select raw, unmounted NVMe drives to build a new MDADM software RAID"
    echo " array from (RAID 0/1/5/6/10, chosen after drive selection)."
    echo " Preconditioning and QD calibration run automatically for anything"
    echo " that isn't already done. The array is created and left to resync"
    echo " in the background — use Test Array(s) afterward to benchmark it;"
    echo " it will warn you if resync hasn't finished yet."
    echo ""
    echo " IMPORTANT: strongly prefer drives on the SAME NUMA node (shown next"
    echo " to each drive below) for a single array. Confirmed via live testing"
    echo " that mixing NUMA nodes within one array cut sequential read"
    echo " throughput 3-7x on this hardware -- not a theoretical concern."
    echo ""

    echo "[INFO] Scanning for available raw NVMe drives..."
    _discover_candidate_drives
    local raw_count=${#_DISCOVERED_PATHS[@]}
    if [ "$raw_count" -eq 0 ]; then
        pause_to_menu "No raw, unmounted NVMe drives available to build an array from."
        return 1
    fi

    echo ""
    echo " Select the drives to include. Use numbers, ranges, or 'all'."
    echo " Example: 1-6,8,10-12"
    echo ""
    local sel_indices=()
    while true; do
        read -p "Selection: " drive_sel
        sel_indices=()
        _parse_selection_string "$drive_sel" sel_indices "$raw_count"
        if [ ${#sel_indices[@]} -lt 2 ]; then
            pause_to_menu "MDADM RAID needs at least 2 drives (3+ recommended for RAID5)."
            return 1
        fi
        _confirm_drive_selection "Confirm Drive Selection -- MDADM Array" sel_indices && break
        echo "Reselect the drives."
    done

    local selected_paths=() selected_models=() selected_serials=()
    for idx in "${sel_indices[@]}"; do
        selected_paths+=("${_DISCOVERED_PATHS[$((idx-1))]}")
        selected_models+=("${_DISCOVERED_MODELS[$((idx-1))]}")
        selected_serials+=("${_DISCOVERED_SERIALS[$((idx-1))]}")
    done
    local drive_count=${#selected_paths[@]}

    if ! _check_selection_numa_spread selected_paths; then
        pause_to_menu "Array build cancelled — reselect drives on a single NUMA node, or confirm to proceed anyway."
        return 1
    fi

    # Per-element comparison, not word-split: model strings contain spaces and would falsely read as mixed.
    local unique_models=()
    for m in "${selected_models[@]}"; do
        local already=false
        for um in "${unique_models[@]}"; do [ "$um" = "$m" ] && already=true; done
        $already || unique_models+=("$m")
    done
    if [ ${#unique_models[@]} -ne 1 ]; then
        pause_to_menu "Mixed drive models in selection (${unique_models[*]}). Choose drives of one model."
        return 1
    fi
    if ! _check_selection_media selected_paths; then
        pause_to_menu "Reselect drives of a single type."
        return 1
    fi

    get_drive_metadata "${selected_paths[0]}"
    local build_token="$DRIVE_MODEL_TOKEN"

    _prompt_raid_level "$drive_count"
    local raid_level="$SELECTED_RAID_LEVEL"

    # Plan only. Preconditioning writes the full drive, so it waits behind the projection.
    _pending_plan_clear
    local drives_csv; drives_csv=$(IFS=,; echo "${selected_paths[*]}")
    _pending_plan_add "mdadm" "$raid_level" "$drives_csv" "" ""
    if ! _confirm_projected_structure "${_PENDING_PLAN[@]}"; then
        pause_to_menu "Array build cancelled -- no drive was touched."
        return 1
    fi

    if _media_is_hdd; then
        echo "[INFO] Rotational media -- skipping preconditioning and QD calibration."
        _hdd_health_validation "mdadm-members" "${selected_paths[@]}"
    else
        local batch_status=()
        _precondition_drive_batch selected_paths selected_models selected_serials batch_status "$SWEEP_DIR/Logs"
        _ensure_qd_profile "${selected_paths[0]}" "${unique_models[0]}" "$build_token"
    fi

    if ! _mdadm_build_array_core "$raid_level" "${selected_paths[@]}"; then
        pause_to_menu "$_MDADM_BUILD_ERROR"
        return 1
    fi
    _pending_plan_clear
    echo "[INFO] Test Array(s) will warn you if you try to test before resync finishes."

    _show_drive_structure "Actual Structure After Array Creation -- $_MDADM_BUILT_DEV"
    pause_to_menu "Array build complete: $_MDADM_BUILT_DEV"
    return 0
}

# Non-interactive MDADM creation with busy-retry, device wait and RAID5/6 tuning. Sets _MDADM_BUILT_DEV.
_mdadm_build_array_core() {
    local raid_level="$1"; shift
    local paths=("$@")
    local drive_count=${#paths[@]}
    _MDADM_BUILT_DEV=""
    _MDADM_BUILD_ERROR=""

    local next_md_num=0
    while [ -e "/dev/md${next_md_num}" ] || grep -q "^md${next_md_num} " /proc/mdstat 2>/dev/null; do
        next_md_num=$((next_md_num + 1))
    done
    local target_md="/dev/md${next_md_num}"

    for p in "${paths[@]}"; do
        wipefs -af "$p" &>/dev/null || true
    done

    # Nothing competes for I/O here, and a slow resync only delays testing -- raise the kernel ceiling.
    echo 1000000 > /proc/sys/dev/raid/speed_limit_min 2>/dev/null
    echo 10000000 > /proc/sys/dev/raid/speed_limit_max 2>/dev/null

    echo ""
    echo "[BUILD] Creating $target_md (RAID $raid_level) from ${drive_count} drive(s)..."
    # A just-deleted array's drives can report "busy" for seconds after mdadm --stop returns.
    local create_attempt=1 create_ok=false
    while [ "$create_attempt" -le 5 ]; do
        if mdadm --create "$target_md" --level="$raid_level" \
             --raid-devices="$drive_count" --run "${paths[@]}" 2>/tmp/mdadm_err.log; then
            create_ok=true
            break
        fi
        if [ "$create_attempt" -lt 5 ] && grep -qi "busy" /tmp/mdadm_err.log; then
            echo "[WARN] mdadm --create attempt $create_attempt/5 hit a device-busy race — retrying in 5s..."
            sleep 5
        else
            break
        fi
        create_attempt=$((create_attempt + 1))
    done
    if [ "$create_ok" != true ]; then
        _MDADM_BUILD_ERROR="mdadm --create failed: $(cat /tmp/mdadm_err.log 2>/dev/null)"
        rm -f /tmp/mdadm_err.log
        return 1
    fi
    rm -f /tmp/mdadm_err.log

    echo "[BUILD] $target_md created. Waiting for the block device to settle..."
    local timeout=30 elapsed=0
    while [ ! -b "$target_md" ] && [ "$elapsed" -lt "$timeout" ]; do
        sleep 2; elapsed=$((elapsed + 2))
    done

    if [ ! -b "$target_md" ]; then
        _MDADM_BUILD_ERROR="$target_md did not appear as a block device within ${timeout}s."
        return 1
    fi

    echo " [SUCCESS] $target_md is online."

    # RAID5/6 stripe cache defaults to 256 pages (1MB), a severe bottleneck on fast NVMe.
    if [[ "$raid_level" == "5" || "$raid_level" == "6" ]]; then
        local md_basename; md_basename=$(basename "$target_md")
        local sc_path="/sys/block/${md_basename}/md/stripe_cache_size"
        if [ -w "$sc_path" ]; then
            echo 32768 > "$sc_path" 2>/dev/null
            echo "[INFO] stripe_cache_size raised to 32768 (was 256 default) for RAID $raid_level write performance."
        fi
        # RAID5/6 use one stripe-cache worker by default; 8 threads measured 2.2x/2.5x/3.0x seq read/seq write/random write.
        local gtc_path="/sys/block/${md_basename}/md/group_thread_cnt"
        if [ -w "$gtc_path" ]; then
            echo 8 > "$gtc_path" 2>/dev/null
            echo "[INFO] group_thread_cnt raised to 8 (was 0/single-threaded default) for RAID $raid_level throughput."
        fi
    fi

    local resync_line
    resync_line=$(grep -A2 "^$(basename "$target_md")" /proc/mdstat 2>/dev/null | grep -E "resync|recovery")
    if [ -n "$resync_line" ]; then
        echo "[INFO] Background resync/recovery is running:"
        echo "       $resync_line"
    fi

    _MDADM_BUILT_DEV="$target_md"
    return 0
}

# --- Option 2b: MDADM Delete -- stops the array and zeroes each member's superblock. ---
run_mdadm_delete_array() {
    clear
    echo "====================================================================="
    echo "             OPTION 2 / DELETE: MDADM ARRAY DELETION                 "
    echo "====================================================================="
    echo ""
    echo " Stops the selected array(s) and zeroes each member drive's MDADM"
    echo " superblock, so the underlying drives return as raw, unpartitioned"
    echo " disks."
    echo ""

    # /proc/mdstat, not lsblk -d: some util-linux versions exclude md arrays entirely, finding nothing.
    local md_arrays=($(grep -oE '^md[0-9]+' /proc/mdstat))
    if [ ${#md_arrays[@]} -eq 0 ]; then
        pause_to_menu "No active software MDADM configurations identified on this host node."
        return
    fi

    echo "Select target MDADM array(s) to delete."
    echo "Use numbers, ranges, or 'all'."
    echo ""
    local index=1
    for md in "${md_arrays[@]}"; do
        echo "  $index) /dev/$md"
        index=$((index + 1))
    done
    echo ""
    read -p "Selection (1-$((index-1))): " sel
    local sel_indices=()
    _parse_selection_string "$sel" sel_indices "$((index-1))"
    if [ ${#sel_indices[@]} -eq 0 ]; then
        pause_to_menu "No valid array(s) selected."
        return
    fi

    local target_names=()
    for idx in "${sel_indices[@]}"; do
        target_names+=("${md_arrays[$((idx-1))]}")
    done

    echo ""
    echo "====================================================================="
    echo " ABOUT TO DELETE ${#target_names[@]} ARRAY(S):"
    for md in "${target_names[@]}"; do echo "   - /dev/$md"; done
    echo "====================================================================="
    echo " WARNING: This stops each array and wipes its member drives' RAID"
    echo "          metadata -- they become raw disks again."
    read -p "Type 'YES' to proceed: " confirm
    if [[ "$confirm" != "YES" ]]; then
        pause_to_menu "Deletion cancelled."
        return
    fi

    local failures=0
    for md in "${target_names[@]}"; do
        local target_md="/dev/$md"
        echo ""
        echo "[DELETE] Stopping $target_md..."
        local child_drives=($(_mdadm_member_drives "$md"))

        if ! mdadm --stop "$target_md" 2>/tmp/mdadm_del_err.log; then
            echo "[WARN] mdadm --stop $target_md reported: $(cat /tmp/mdadm_del_err.log)"
            failures=$((failures + 1))
        fi
        rm -f /tmp/mdadm_del_err.log

        # Settle first -- mdadm --stop can return before the kernel releases members.
        sleep 5

        for child in "${child_drives[@]}"; do
            local raw_dev="/dev/$child"
            [ -b "$raw_dev" ] || continue
            mdadm --zero-superblock "$raw_dev" 2>/dev/null || \
                echo "[WARN] Could not zero superblock on $raw_dev — it may still show RAID metadata."
            wipefs -af "$raw_dev" &>/dev/null || true
        done

        echo " [SUCCESS] $target_md deleted — member drives are raw again."
    done

    if [ "$failures" -gt 0 ]; then
        echo ""
        echo "[WARN] $failures array(s) reported errors during deletion. Check 'mdadm --detail' / 'cat /proc/mdstat' manually."
    fi

    pause_to_menu "MDADM array deletion complete."
    return 0
}

# --- Option 2c: MDADM — Test Array(s) ---
run_mdadm_test_arrays() {
    clear
    echo "====================================================================="
    echo "              OPTION 2 / TEST: MDADM ARRAY TESTING                   "
    echo "====================================================================="

    # /proc/mdstat, not lsblk -d: some util-linux versions exclude md arrays entirely, finding nothing.
    local md_arrays=($(grep -oE '^md[0-9]+' /proc/mdstat))
    if [ ${#md_arrays[@]} -eq 0 ]; then
        pause_to_menu "No active software MDADM configurations identified on this host node."
        return
    fi

    echo "Select target MDADM array(s) for validation testing."
    echo "Use numbers, ranges, or 'all' to test multiple arrays in one run."
    echo ""
    local index=1
    for md in "${md_arrays[@]}"; do
        echo "  $index) /dev/$md"
        index=$((index + 1))
    done
    echo ""
    read -p "Selection (1-$((index-1))): " sel
    local sel_indices=()
    _parse_selection_string "$sel" sel_indices "$((index-1))"
    if [ ${#sel_indices[@]} -eq 0 ]; then
        pause_to_menu "No valid array(s) selected."
        return
    fi

    local target_names=()
    for idx in "${sel_indices[@]}"; do
        target_names+=("${md_arrays[$((idx-1))]}")
    done

    for md in "${target_names[@]}"; do
        if ! _wait_for_mdadm_idle "$md"; then
            pause_to_menu "Testing cancelled — /dev/$md may still be building."
            return
        fi
    done

    local run_parallel=false
    if [ ${#target_names[@]} -gt 1 ]; then
        if _md_arrays_are_disjoint "${target_names[@]}"; then
            run_parallel=true
            echo ""
            echo "[INFO] Selected arrays share no underlying drives — testing SIMULTANEOUSLY."
            echo "       CPU thread budget will be divided across the ${#target_names[@]} concurrent runs."
        else
            echo ""
            echo "[WARN] Two or more selected arrays share an underlying physical drive."
            echo "[WARN] Testing SEQUENTIALLY instead — running them at once would make the"
            echo "       shared drive's result meaningless (its I/O can't be attributed to"
            echo "       just one array)."
        fi
    fi

    get_cpu_threads
    [ "$run_parallel" = true ] && _apply_concurrent_cpu_budget "${#target_names[@]}"

    local run_ts; run_ts=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local run_label="MDADM_MultiTest_$(date +%Y%m%d_%H%M%S)"
    local run_dir="$RESULTS_DIR/$run_label"
    mkdir -p "$run_dir"

    _PHASE_DRIVE_COUNTS=()
    _PHASE_REPORT_FILES=()
    local pids=()

    for md in "${target_names[@]}"; do
        local target_md="/dev/$md"
        local child_drives=($(_mdadm_member_drives "$md"))
        if [ ${#child_drives[@]} -eq 0 ]; then
            echo "[WARN] Could not resolve topology for $target_md — skipping."
            continue
        fi

        local models=()
        local serials=()
        for child in "${child_drives[@]}"; do
            local raw_dev="/dev/$child"
            if [ -b "$raw_dev" ]; then
                get_drive_metadata "$raw_dev"
                models+=("$DRIVE_MODEL_TOKEN")
                serials+=("$DRIVE_SERIAL ($raw_dev)")
            fi
        done

        local unique_models=($(echo "${models[@]}" | tr ' ' '\n' | sort -u))
        if [ ${#unique_models[@]} -ne 1 ]; then
            echo "[WARN] $target_md has mixed drive models — skipping (requires homogeneous build)."
            continue
        fi

        local target_token="${unique_models[0]}"
        local drive_count=${#child_drives[@]}

        local member_paths=() _mp
        for _mp in "${child_drives[@]}"; do member_paths+=("/dev/$_mp"); done
        if ! _check_selection_media member_paths; then
            echo "[WARN] $target_md mixes flash and rotational members -- skipping."
            continue
        fi
        if _media_is_hdd; then
            _hdd_health_validation "mdadm-${target_md}" "${member_paths[@]}"
            continue
        fi

        # No profile is no longer a skip -- _load_qd_profile falls back to default depths and
        # flags the run uncalibrated, so the engineer still gets numbers to review.

        (
            _load_qd_profile "$target_token" "$drive_count"
            DRIVE_MODEL=$(cat "/sys/block/${child_drives[0]}/device/model" 2>/dev/null || echo "$target_token")
            DRIVE_SERIAL=$(printf "%s\n" "${serials[@]}")
            DRIVE_COUNT=$drive_count

            local is_parity_array=false
            if grep -A 4 "$md" /proc/mdstat | grep -qE "raid5|raid6"; then
                is_parity_array=true
            fi

            pushd "$run_dir" > /dev/null
            execute_and_summarize_fio "$target_md" "$md" "$FINAL_JOBS" "$FINAL_DEPTH" "MDADM" "$is_parity_array"
            popd > /dev/null
        ) &
        pids+=("$!")
        _PHASE_DRIVE_COUNTS+=("$drive_count")
        _PHASE_REPORT_FILES+=("$run_dir/fio_${md}.txt")

        [ "$run_parallel" = false ] && wait "${pids[-1]}"
    done

    if [ "$run_parallel" = true ] && [ ${#pids[@]} -gt 0 ]; then
        echo ""
        echo "[INFO] Waiting for all ${#pids[@]} simultaneous array test(s) to complete..."
        wait "${pids[@]}"
    fi

    if [ ${#_PHASE_REPORT_FILES[@]} -eq 0 ]; then
        pause_to_menu "No arrays were successfully tested."
        return 1
    fi

    if [ ${#_PHASE_REPORT_FILES[@]} -gt 1 ]; then
        local summary_file="$run_dir/validation_summary_${run_label}.txt"
        generate_combined_summary "$summary_file" "MDADM (mixed arrays)" "$run_ts"
        echo ""
        echo " [SUCCESS] Combined summary saved: $summary_file"
    fi

    echo ""
    echo " Results directory: $run_dir"
    pause_to_menu "MDADM validation routines complete."
}

# --- Option 3: HW RAID Testing ---

# Warns (interactive) or fails (unattended) on a storcli background init -- same contamination rationale.
_check_hwraid_not_initializing() {
    local ctrl="$1" vd="$2"
    local state
    state=$($STORCLI_CMD /c$ctrl/v$vd show all 2>/dev/null | grep -iE "State|Bgi")
    if ! echo "$state" | grep -qi "Bgi.*progress\|Initializing\|In Progress"; then
        return 0
    fi
    echo ""
    echo "[WARN] Controller $ctrl VD $vd reports background initialization in progress:"
    echo "$state" | sed 's/^/       /'
    echo "[WARN] Benchmarking now will contaminate results with background-init I/O,"
    echo "       the same class of bug that affected GRAID validation runs this"
    echo "       suite fixed earlier. Wait for it to finish and re-run."
    read -p "Proceed anyway? (y/n): " proceed_anyway
    [[ "$proceed_anyway" == "y" || "$proceed_anyway" == "Y" ]] && return 0
    return 1
}

run_hw_raid_testing() {
    clear
    echo "====================================================================="
    echo "                   OPTION 3: HW RAID TESTING                         "
    echo "====================================================================="
    echo ""
    echo " Tests an existing Virtual Drive built outside this script (BIOS/"
    echo " storcli). Preconditioning and QD calibration run automatically"
    echo " against the VD's own device path if not already done -- the"
    echo " underlying physical drives aren't separately addressable once"
    echo " the controller assembles them."
    echo ""

    if command -v storcli64 &>/dev/null; then
        STORCLI_CMD="storcli64"
    elif command -v storcli &>/dev/null; then
        STORCLI_CMD="storcli"
    else
        pause_to_menu "StorCLI not found. Install storcli or storcli64 and ensure it is in PATH."
        return
    fi

    echo "[INFO] Querying system for active NVMe hardware RAID virtual disks..."
    local controller_list=($($STORCLI_CMD show all | grep -E "^[0-9]+" | awk '{print $1}'))
    if [ ${#controller_list[@]} -eq 0 ]; then
        pause_to_menu "No compatible hardware RAID controllers found on the host machine."
        return
    fi

    local vd_choices=()
    local index=1

    for ctrl in "${controller_list[@]}"; do
        local vd_lines=($($STORCLI_CMD /c$ctrl/vall show | grep -E "^[0-9]+" | awk '{print $1}'))
        for vd in "${vd_lines[@]}"; do
            local wwn=$($STORCLI_CMD /c$ctrl/v$vd show all 2>/dev/null \
                | grep -i "WWN\|SCSI NAA Id" \
                | awk -F= '{print $2}' \
                | tr -d ' ' \
                | head -n 1 \
                | tr '[:upper:]' '[:lower:]')

            local os_name=""
            if [ -n "$wwn" ]; then
                local id_link=$(ls /dev/disk/by-id/ 2>/dev/null | grep -i "nvme-eui\|nvme-naa" | grep -i "$wwn" | head -n 1)
                if [ -n "$id_link" ]; then
                    os_name=$(readlink -f "/dev/disk/by-id/$id_link" | xargs basename)
                fi
            fi

            if [ -z "$os_name" ]; then
                echo "[WARN] WWN match failed for Controller $ctrl VD $vd — falling back to subsystem scan."
                os_name=$(lsblk -dno NAME,SUBSYSTEMS 2>/dev/null \
                    | grep -v "nvme[0-9]\+n[0-9]\+" \
                    | grep "nvme\|scsi" \
                    | awk 'NR=='"$index"' {print $1}')
            fi

            if [ -z "$os_name" ]; then
                echo "[WARN] Could not resolve OS path for Controller $ctrl VD $vd. Skipping."
                continue
            fi

            vd_choices+=("/dev/$os_name|$ctrl|$vd")
            echo "  $index) Controller $ctrl, Virtual Drive $vd -> OS Path: /dev/$os_name (matched via WWN: ${wwn:-fallback})"
            index=$((index + 1))
        done
    done

    if [ ${#vd_choices[@]} -eq 0 ]; then
        pause_to_menu "No active enterprise Virtual Drives found on the adapter backplanes."
        return
    fi

    read -p "Select a Virtual Drive target (1-$((index-1))): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$index" ]; then
        pause_to_menu "Selection parameters out of bounds."
        return
    fi

    IFS='|' read -r target_vd ctrl vd <<< "${vd_choices[$((choice-1))]}"

    if ! _check_hwraid_not_initializing "$ctrl" "$vd"; then
        pause_to_menu "Aborted — target VD is still background-initializing."
        return
    fi

    local raw_model=$($STORCLI_CMD /c$ctrl/eall/sall show | grep -E "^[0-9]+" | head -n 1 | awk '{print $3}')
    local drive_count=$($STORCLI_CMD /c$ctrl/eall/sall show | grep -E "^[0-9]+" | wc -l)

    if [ -z "$raw_model" ]; then raw_model="HW_NVMe_Drive"; fi
    local target_token=$(echo "$raw_model" | tr '[:space:]' '_' | tr -cd '[:alnum:]_.-')

    DRIVE_MODEL="$raw_model"
    DRIVE_COUNT=$drive_count
    DRIVE_SERIAL=$($STORCLI_CMD /c$ctrl/eall/sall show all | grep "SN =" | awk '{print $3}' | sort -u)

    # HW RAID PDs aren't separately addressable -- precondition against the VD, keyed by a synthetic identity.
    local vd_identity="HWRAID_c${ctrl}_v${vd}"
    local vd_paths=("$target_vd") vd_models=("$raw_model") vd_serials=("$vd_identity")
    local batch_status=()
    _precondition_drive_batch vd_paths vd_models vd_serials batch_status "$SWEEP_DIR/Logs"
    _ensure_qd_profile "$target_vd" "$raw_model" "$target_token"

    local vd_media_paths=("$target_vd")
    _check_selection_media vd_media_paths >/dev/null 2>&1
    if _media_is_hdd; then
        _hdd_health_validation "hwraid-c${ctrl}v${vd}" "$target_vd"
        pause_to_menu "HDD health validation complete."
        return
    fi

    _load_qd_profile "$target_token"

    echo -e "\n[VERIFY] Hardware ASIC Adapter Configuration Topology Analysed:"
    echo "   - Extracted Model Family  : $DRIVE_MODEL"
    echo "   - Internal Drive Elements : $DRIVE_COUNT"
    read -p "Confirm structural configuration details match target build parameters? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        pause_to_menu "Test sequence terminated."
        return
    fi

    get_cpu_threads
    # Adapters cap aggregate queues regardless of RAND_TQDpD, so this ceiling is computed inline.
    local card_max_tqd=512
    local ideal_w=$((card_max_tqd / 16))
    FINAL_JOBS=$ideal_w
    [ "$C_SAFE" -lt "$FINAL_JOBS" ] && FINAL_JOBS=$C_SAFE
    FINAL_DEPTH=$(awk -v t="$card_max_tqd" -v j="$FINAL_JOBS" 'BEGIN {print int((t/j) + 0.5)}')

    execute_and_summarize_fio "$target_vd" "$(basename "$target_vd")" "$FINAL_JOBS" "$FINAL_DEPTH" "HWRAID" false
    pause_to_menu "Hardware validation run loop terminated."
}

# --- Option 4a: GRAID Build -- selection plus one array; repeatable, since discovery excludes claimed drives. ---
run_graid_build_array() {
    clear
    echo "====================================================================="
    echo "              OPTION 4 / BUILD: GRAID ARRAY CREATION                 "
    echo "====================================================================="
    echo ""
    echo " Select drives to build ONE new GRAID array from (RAID 0/1/5/6/10,"
    echo " chosen after drive selection). The array is left running (no test,"
    echo " no teardown) — use Test Array(s) afterward to benchmark it. Run"
    echo " this again with a different drive selection to build additional"
    echo " arrays. Preconditioning and QD calibration run automatically for"
    echo " anything that isn't already done."
    echo ""
    echo " IMPORTANT: strongly prefer drives on the SAME NUMA node (shown next"
    echo " to each drive below) for a single array. Confirmed via live testing"
    echo " that mixing NUMA nodes within one array cut sequential read"
    echo " throughput 3-7x on this hardware -- not a theoretical concern."
    echo ""

    if ! init_graid_cmd; then
        pause_to_menu "graidctl not found. Ensure GRAID software is installed."
        return 1
    fi
    echo "    [INFO] Using GRAID CLI: $GRAID_CMD"

    echo "[INFO] Scanning for available NVMe drives..."
    _discover_candidate_drives
    local raw_count=${#_DISCOVERED_PATHS[@]}

    echo "[INFO] Checking for existing unconfigured GRAID PDs..."
    _query_unconfigured_pds
    local pd_count=${#_PD_IDS[@]}

    if [ "$raw_count" -eq 0 ] && [ "$pd_count" -eq 0 ]; then
        pause_to_menu "No drives available. No raw NVMe devices and no unconfigured GRAID PDs found."
        return 1
    fi

    local selected_raw_paths=() selected_raw_models=() selected_raw_serials=()
    local selected_pd_ids=()

    if [ "$raw_count" -gt 0 ] && [ "$pd_count" -gt 0 ]; then
        echo ""
        echo "====================================================================="
        echo " AVAILABLE RAW NVMe DEVICES (will be created as new GRAID PDs)"
        echo "====================================================================="
        echo " Select numbers or ranges to include, 'all', or 'none'."
        echo " Example: 1-6,8,10-12"
        echo ""
        read -p "Raw NVMe selection: " raw_sel
        if [[ "${raw_sel,,}" != "none" ]] && [ -n "$raw_sel" ]; then
            local raw_indices=()
            _parse_selection_string "$raw_sel" raw_indices "$raw_count"
            for idx in "${raw_indices[@]}"; do
                selected_raw_paths+=("${_DISCOVERED_PATHS[$((idx-1))]}")
                selected_raw_models+=("${_DISCOVERED_MODELS[$((idx-1))]}")
                selected_raw_serials+=("${_DISCOVERED_SERIALS[$((idx-1))]}")
            done
        fi
        echo ""
        echo "====================================================================="
        echo " EXISTING UNCONFIGURED GRAID PDs"
        echo "====================================================================="
        echo " Select numbers or ranges to include, 'all', or 'none'."
        echo " Example: 1-6,8,10-12"
        echo ""
        read -p "Existing PD selection: " pd_sel
        if [[ "${pd_sel,,}" != "none" ]] && [ -n "$pd_sel" ]; then
            local pd_indices=()
            _parse_selection_string "$pd_sel" pd_indices "$pd_count"
            for idx in "${pd_indices[@]}"; do
                selected_pd_ids+=("${_PD_IDS[$((idx-1))]}")
            done
        fi
    elif [ "$raw_count" -gt 0 ]; then
        echo ""
        echo " Select the drives to include in the GRAID array."
        echo " Use numbers, ranges, or 'all'.  Example: 1-6,8,10-12"
        echo ""
        read -p "Selection: " gdg_drive_selection
        local sel_indices=()
        _parse_selection_string "$gdg_drive_selection" sel_indices "$raw_count"
        if [ ${#sel_indices[@]} -eq 0 ]; then
            pause_to_menu "No valid drives selected."
            return 1
        fi
        for idx in "${sel_indices[@]}"; do
            selected_raw_paths+=("${_DISCOVERED_PATHS[$((idx-1))]}")
            selected_raw_models+=("${_DISCOVERED_MODELS[$((idx-1))]}")
            selected_raw_serials+=("${_DISCOVERED_SERIALS[$((idx-1))]}")
        done
    else
        echo ""
        echo " Select the existing PDs to include in the GRAID array."
        echo " Use numbers, ranges, or 'all'.  Example: 1-6,8,10-12"
        echo ""
        read -p "Selection: " pd_sel
        local pd_indices=()
        _parse_selection_string "$pd_sel" pd_indices "$pd_count"
        if [ ${#pd_indices[@]} -eq 0 ]; then
            pause_to_menu "No valid PDs selected."
            return 1
        fi
        for idx in "${pd_indices[@]}"; do
            selected_pd_ids+=("${_PD_IDS[$((idx-1))]}")
        done
    fi

    if [ ${#selected_raw_paths[@]} -gt 0 ]; then
        # Per-element comparison, not word-split -- see the matching comment in run_mdadm_build_array.
        local unique_raw_models=()
        for m in "${selected_raw_models[@]}"; do
            local already=false
            for um in "${unique_raw_models[@]}"; do [ "$um" = "$m" ] && already=true; done
            $already || unique_raw_models+=("$m")
        done
        if [ ${#unique_raw_models[@]} -ne 1 ]; then
            pause_to_menu "Mixed drive models in raw selection (${unique_raw_models[*]}). Choose drives of one model."
            return 1
        fi

        if ! _check_selection_numa_spread selected_raw_paths; then
            pause_to_menu "Array build cancelled — reselect drives on a single NUMA node, or confirm to proceed anyway."
            return 1
        fi

        get_drive_metadata "${selected_raw_paths[0]}"
        local build_token="$DRIVE_MODEL_TOKEN"
    fi

    # Selection review. PD registration, preconditioning and the build all wait behind the projection.
    local _gsel=() _gi
    for _gi in "${!selected_raw_paths[@]}"; do
        _gsel+=("raw NVMe: ${selected_raw_paths[$_gi]}  ${selected_raw_models[$_gi]}  SN ${selected_raw_serials[$_gi]}")
    done
    for _gi in "${selected_pd_ids[@]}"; do _gsel+=("existing PD: $_gi"); done
    [ ${#_gsel[@]} -eq 0 ] && _gsel=("(nothing selected)")
    if [ ${#selected_raw_paths[@]} -gt 0 ]; then
        if ! _check_selection_media selected_raw_paths; then
            pause_to_menu "Reselect drives of a single type."
            return 1
        fi
        if _media_is_hdd; then
            pause_to_menu "GRAID (SupremeRAID) is an NVMe technology -- rotational drives are not supported."
            return 1
        fi
    fi

    if ! _review_entries "Confirm Drive Selection -- GRAID Array" "${_gsel[@]}"; then
        pause_to_menu "Selection not confirmed -- returning to the menu to reselect."
        return 1
    fi

    # Predicted PD count = existing PDs plus raw drives, known before anything is created.
    local n_selected=$(( ${#selected_pd_ids[@]} + ${#selected_raw_paths[@]} ))
    if [ "$n_selected" -lt 2 ]; then
        pause_to_menu "At least 2 drives are needed to build any supported RAID level. Only $n_selected selected."
        return 1
    fi

    _prompt_raid_level "$n_selected"
    local raid_level="$SELECTED_RAID_LEVEL"

    # Projection needs block devices, not PD IDs -- map each existing PD back to its device path.
    local _proj_paths=("${selected_raw_paths[@]}") _pi _pj
    for _pi in "${selected_pd_ids[@]}"; do
        for _pj in "${!_PD_IDS[@]}"; do
            if [ "${_PD_IDS[$_pj]}" = "$_pi" ] && [ -n "${_PD_PATHS[$_pj]}" ]; then
                _proj_paths+=("${_PD_PATHS[$_pj]}"); break
            fi
        done
    done

    _pending_plan_clear
    local _gcsv; _gcsv=$(IFS=,; echo "${_proj_paths[*]}")
    _pending_plan_add "graid" "$raid_level" "$_gcsv" "" ""
    if ! _confirm_projected_structure "${_PENDING_PLAN[@]}"; then
        pause_to_menu "Array build cancelled -- no drive was touched."
        return 1
    fi

    if [ ${#selected_raw_paths[@]} -gt 0 ]; then
        local batch_status=()
        _precondition_drive_batch selected_raw_paths selected_raw_models selected_raw_serials batch_status "$SWEEP_DIR/Logs"
        _ensure_qd_profile "${selected_raw_paths[0]}" "${unique_raw_models[0]}" "$build_token"
    fi

    _NEWLY_REGISTERED_PD_IDS=()
    if [ ${#selected_raw_paths[@]} -gt 0 ]; then
        echo ""
        echo "====================================================================="
        echo " CREATING GRAID PHYSICAL DRIVES FROM RAW NVMe"
        echo "====================================================================="
        _create_pds_from_nvme selected_raw_paths
    fi

    MASTER_PD_IDS=("${selected_pd_ids[@]}" "${_NEWLY_REGISTERED_PD_IDS[@]}")
    n_selected=${#MASTER_PD_IDS[@]}

    echo ""
    echo "[INFO] $n_selected total PD(s) available for array construction: ${MASTER_PD_IDS[*]}"

    if [ "$n_selected" -lt 2 ]; then
        pause_to_menu "At least 2 drives are needed to build any supported RAID level. Only $n_selected registered."
        return 1
    fi

    echo ""
    echo "====================================================================="
    echo " BUILDING GRAID RAID $raid_level ARRAY ($n_selected drives)"
    echo "====================================================================="

    create_graid_array "$n_selected" "$raid_level"
    local active_gdg="$NEW_GDG_DEV"
    wait_for_graid_ready "$active_gdg"

    local active_gdg_name
    active_gdg_name=$(basename "$active_gdg" | grep -oE 'gdg[0-9]+')
    if ! inspect_vd_for_device "$active_gdg_name"; then
        pause_to_menu "Could not inspect VD for $active_gdg. Aborting."
        return 1
    fi
    if ! get_dg_info "$CURRENT_DG_ID"; then
        pause_to_menu "Could not read Drive Group $CURRENT_DG_ID. Aborting."
        return 1
    fi

    echo ""
    echo "====================================================================="
    echo " ARRAY BUILT SUCCESSFULLY"
    echo "====================================================================="
    echo " Device       : $active_gdg"
    echo " DG / VD      : $CURRENT_DG_ID / $CURRENT_VD_ID"
    echo " RAID Level   : $DG_RAID_LEVEL"
    echo " Drive Count  : $DG_PD_COUNT"
    echo "====================================================================="
    echo ""
    echo "[INFO] Background parity initialization may still be running."
    echo "       Test Array(s) waits for steady-state automatically before"
    echo "       benchmarking, so it's safe to move on now."

    _pending_plan_clear
    _show_drive_structure "Actual Structure After GRAID Array Creation"
    pause_to_menu "Array build complete."
    return 0
}

# --- Option 4b: GRAID Delete -- destroys VD + DG and removes PDs, returning drives fully raw. ---
run_graid_delete_arrays() {
    clear
    echo "====================================================================="
    echo "             OPTION 4 / DELETE: GRAID ARRAY DELETION                 "
    echo "====================================================================="
    echo ""
    echo " Destroys the selected array(s) (Virtual Drive + Drive Group) AND"
    echo " removes their Physical Drives from graidctl entirely, so the"
    echo " underlying NVMe drives return to the OS as raw, unconfigured disks."
    echo ""

    if ! init_graid_cmd; then
        pause_to_menu "graidctl not found. Ensure GRAID software is installed."
        return 1
    fi

    local gdg_names=()
    while IFS= read -r name; do
        local base; base=$(echo "$name" | grep -oE '^gdg[0-9]+')
        [ -n "$base" ] && gdg_names+=("$base")
    done < <(lsblk -dno NAME 2>/dev/null | grep -E '^gdg')

    if [ ${#gdg_names[@]} -eq 0 ]; then
        pause_to_menu "No existing GRAID arrays found."
        return 1
    fi

    echo "Select existing GRAID array(s) to delete."
    echo "Use numbers, ranges, or 'all'."
    echo ""
    local index=1
    local gdg_devs=()
    for gdg in "${gdg_names[@]}"; do
        local dev="/dev/${gdg}n1"
        gdg_devs+=("$dev")
        echo "  $index) $dev"
        index=$((index + 1))
    done
    echo ""
    read -p "Selection (1-$((index-1))): " sel
    local sel_indices=()
    _parse_selection_string "$sel" sel_indices "$((index-1))"
    if [ ${#sel_indices[@]} -eq 0 ]; then
        pause_to_menu "No valid array(s) selected."
        return 1
    fi

    echo ""
    echo "====================================================================="
    echo " ABOUT TO DELETE ${#sel_indices[@]} ARRAY(S) AND THEIR PHYSICAL DRIVES:"
    for idx in "${sel_indices[@]}"; do echo "   - ${gdg_devs[$((idx-1))]}"; done
    echo "====================================================================="
    echo " WARNING: This destroys the array's data AND removes its drives from"
    echo "          graidctl -- they become raw disks again."
    read -p "Type 'YES' to proceed: " confirm
    if [[ "$confirm" != "YES" ]]; then
        pause_to_menu "Deletion cancelled."
        return 1
    fi

    local failures=0
    for idx in "${sel_indices[@]}"; do
        local active_gdg="${gdg_devs[$((idx-1))]}"
        local active_gdg_name
        active_gdg_name=$(basename "$active_gdg" | grep -oE 'gdg[0-9]+')

        echo ""
        echo "====================================================================="
        echo " DELETING $active_gdg"
        echo "====================================================================="

        if ! inspect_vd_for_device "$active_gdg_name"; then
            echo "[WARN] Could not inspect VD for $active_gdg — skipping."
            failures=$((failures + 1))
            continue
        fi
        if ! get_dg_info "$CURRENT_DG_ID"; then
            echo "[WARN] Could not read Drive Group $CURRENT_DG_ID — skipping."
            failures=$((failures + 1))
            continue
        fi
        if ! get_dg_physical_drives "$CURRENT_DG_ID"; then
            echo "[WARN] Could not retrieve physical drive list for DG $CURRENT_DG_ID — skipping."
            failures=$((failures + 1))
            continue
        fi

        destroy_graid_array "$CURRENT_VD_ID" "$CURRENT_DG_ID"
        release_physical_drives

        for nvme_path in "${MASTER_NVME_PATHS[@]}"; do
            [[ "$nvme_path" =~ ^gpd ]] && continue
            wait_for_nvme_accessible "$nvme_path" || \
                echo "[WARN] $nvme_path did not reappear as a raw block device within the timeout."
        done

        echo " [SUCCESS] $active_gdg deleted — drives released back to the OS as raw disks."
    done

    if [ "$failures" -gt 0 ]; then
        echo ""
        echo "[WARN] $failures array(s) could not be fully processed. Check graidctl state manually."
    fi

    pause_to_menu "GRAID array deletion complete."
    return 0
}

# --- Option 4c: GRAID Test -- always sequential: one GPU serves every DG, so two arrays would contend. ---
run_graid_test_arrays() {
    clear
    echo "====================================================================="
    echo "              OPTION 4 / TEST: GRAID ARRAY TESTING                   "
    echo "====================================================================="
    echo ""

    if ! init_graid_cmd; then
        pause_to_menu "graidctl not found. Ensure GRAID software is installed."
        return 1
    fi

    local gdg_names=()
    while IFS= read -r name; do
        local base; base=$(echo "$name" | grep -oE '^gdg[0-9]+')
        [ -n "$base" ] && gdg_names+=("$base")
    done < <(lsblk -dno NAME 2>/dev/null | grep -E '^gdg')

    if [ ${#gdg_names[@]} -eq 0 ]; then
        pause_to_menu "No existing GRAID arrays found. Use Build Array first."
        return 1
    fi

    echo "Select existing GRAID array(s) to test."
    echo "Use numbers, ranges, or 'all' to test multiple arrays in one run."
    echo ""
    local index=1
    local gdg_devs=()
    for gdg in "${gdg_names[@]}"; do
        local dev="/dev/${gdg}n1"
        gdg_devs+=("$dev")
        echo "  $index) $dev"
        index=$((index + 1))
    done
    echo ""
    read -p "Selection (1-$((index-1))): " sel
    local sel_indices=()
    _parse_selection_string "$sel" sel_indices "$((index-1))"
    if [ ${#sel_indices[@]} -eq 0 ]; then
        pause_to_menu "No valid array(s) selected."
        return 1
    fi

    if [ ${#sel_indices[@]} -gt 1 ]; then
        echo ""
        echo "[INFO] Multiple GRAID arrays selected — testing SEQUENTIALLY."
        echo "       SupremeRAID offloads parity computation to a single shared"
        echo "       GPU, so two arrays tested at once would contend for that"
        echo "       GPU and neither result would reflect true performance."
    fi

    local run_ts; run_ts=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local run_label="GRAID_MultiTest_$(date +%Y%m%d_%H%M%S)"
    local run_dir="$RESULTS_DIR/$run_label"
    mkdir -p "$run_dir"

    get_cpu_threads
    _PHASE_DRIVE_COUNTS=()
    _PHASE_REPORT_FILES=()

    for idx in "${sel_indices[@]}"; do
        local active_gdg="${gdg_devs[$((idx-1))]}"
        local active_gdg_name
        active_gdg_name=$(basename "$active_gdg" | grep -oE 'gdg[0-9]+')

        echo ""
        echo "====================================================================="
        echo " TESTING $active_gdg"
        echo "====================================================================="

        if ! inspect_vd_for_device "$active_gdg_name"; then
            echo "[WARN] Could not inspect VD for $active_gdg — skipping."
            continue
        fi
        if ! get_dg_info "$CURRENT_DG_ID"; then
            echo "[WARN] Could not read Drive Group $CURRENT_DG_ID — skipping."
            continue
        fi
        if ! get_dg_physical_drives "$CURRENT_DG_ID"; then
            echo "[WARN] Could not retrieve physical drive list for DG $CURRENT_DG_ID — skipping."
            continue
        fi

        local serials_found=() unique_models=()
        local skip_nvme=false
        for p in "${MASTER_NVME_PATHS[@]}"; do
            [[ "$p" =~ ^gpd ]] && { skip_nvme=true; break; }
        done
        if [ "$skip_nvme" = false ]; then
            for nvme_path in "${MASTER_NVME_PATHS[@]}"; do
                [ -e "/dev/$nvme_path" ] || continue
                get_drive_metadata "/dev/$nvme_path"
                [ -z "$DRIVE_MODEL" ] && continue
                serials_found+=("$DRIVE_SERIAL")
                local model_already=false
                for m in "${unique_models[@]}"; do [ "$m" = "$DRIVE_MODEL" ] && model_already=true; done
                $model_already || unique_models+=("$DRIVE_MODEL")
            done
        fi
        if [ ${#unique_models[@]} -eq 0 ] && [ ${#MASTER_PD_IDS[@]} -gt 0 ]; then
            while IFS= read -r m; do
                [ -z "$m" ] && continue
                [ "$m" = "unknown" ] && continue
                local model_already=false
                for um in "${unique_models[@]}"; do [ "$um" = "$m" ] && model_already=true; done
                $model_already || unique_models+=("$m")
            done < <(_query_pd_models_by_id "${MASTER_PD_IDS[@]}")
        fi

        local drive_model="${unique_models[0]:-unknown}"
        local drive_model_token
        drive_model_token=$(echo -n "$drive_model" | tr '[:space:]' '_' | tr -cd '[:alnum:]_.-')
        _load_qd_profile "$drive_model_token"
        DRIVE_MODEL="$drive_model"
        DRIVE_SERIAL=$(printf '%s\n' "${serials_found[@]}")
        DRIVE_COUNT="$DG_PD_COUNT"

        echo "    [INFO] Drive model: $DRIVE_MODEL  |  Drive count: $DRIVE_COUNT"

        wait_for_graid_steady_state "$active_gdg"

        calc_rand_qd_params "$DRIVE_COUNT"

        pushd "$run_dir" > /dev/null
        execute_and_summarize_fio "$active_gdg" "${active_gdg_name}_${drive_model_token}" \
            "$FINAL_JOBS" "$FINAL_DEPTH" "GRAID" false
        popd > /dev/null

        local this_report="$run_dir/fio_${active_gdg_name}_${drive_model_token}.txt"
        _graid_check_pass_fail "$drive_model" "$drive_model_token" "$DRIVE_COUNT" "$this_report"

        _PHASE_DRIVE_COUNTS+=("$DRIVE_COUNT")
        _PHASE_REPORT_FILES+=("$this_report")
    done

    if [ ${#_PHASE_REPORT_FILES[@]} -eq 0 ]; then
        pause_to_menu "No arrays were successfully tested."
        return 1
    fi

    if [ ${#_PHASE_REPORT_FILES[@]} -gt 1 ]; then
        local summary_file="$run_dir/validation_summary_${run_label}.txt"
        generate_combined_summary "$summary_file" "GRAID (mixed arrays)" "$run_ts"
        echo ""
        echo " [SUCCESS] Combined summary saved: $summary_file"
    fi

    echo ""
    echo " Results directory: $run_dir"
    pause_to_menu "GRAID array testing complete."
    return 0
}



# ==============================================================
# --- Option 5: ZFS Pool Validation ---
# (one pool of N same-width vdevs, plus optional hot spares and an L2ARC cache device.
#  Rotational pools are the common case here, so the whole module honours the media gate.)
# ==============================================================

# True if the ZFS userland is present and the kernel module loads.
_zfs_available() {
    command -v zpool >/dev/null 2>&1 || return 1
    zpool list >/dev/null 2>&1 || modprobe zfs 2>/dev/null
    command -v zpool >/dev/null 2>&1
}

# Best-effort ZFS install. OpenZFS is not in RHEL's own repos, so that branch adds the
# OpenZFS release RPM first. Returns 1 if ZFS still isn't usable afterwards.
_zfs_ensure_installed() {
    _zfs_available && return 0
    echo "[INFO] ZFS userland not found -- attempting to install it."
    . /etc/os-release
    case "$ID$VERSION_ID" in
        ubuntu*)
            install_apt_packages "zfsutils-linux"
            ;;
        rocky*|rhel*|almalinux*)
            local major="${VERSION_ID%%.*}"
            dnf install -y "https://zfsonlinux.org/epel/zfs-release-2-3$(rpm --eval "%{dist}").noarch.rpm" 2>/dev/null \
                || echo "[WARN] Could not add the OpenZFS repo automatically."
            dnf install -y epel-release 2>/dev/null
            install_dnf_packages "kernel-devel-$(uname -r)" "zfs"
            modprobe zfs 2>/dev/null
            ;;
        *)
            echo -e "${TXT_RED}[ERROR] No ZFS install path for '$ID $VERSION_ID'.${RESET}"
            return 1
            ;;
    esac
    if ! _zfs_available; then
        echo -e "${TXT_RED}[ERROR] ZFS is still unavailable. Install it manually, then retry.${RESET}"
        echo "        On RHEL this usually means a DKMS build against the running kernel failed."
        return 1
    fi
    echo "[SUCCESS] ZFS is available: $(zfs version 2>/dev/null | head -1)"
    return 0
}

# Usable capacity of one pool layout, in GB. Parity drives per vdev come off the top, and
# spares and cache contribute nothing to usable space.
_zfs_usable_gb() {
    local level="$1" vdev_count="$2" width="$3" per_gb="$4" parity=0
    case "$level" in
        raidz1) parity=1 ;;
        raidz2) parity=2 ;;
        raidz3) parity=3 ;;
        mirror) echo $(( vdev_count * per_gb )); return ;;
        stripe) echo $(( vdev_count * width * per_gb )); return ;;
    esac
    echo $(( vdev_count * (width - parity) * per_gb ))
}

# Minimum drives per vdev for a level, so a 2-drive raidz2 can't be queued.
_zfs_min_width() {
    case "$1" in
        raidz1) echo 3 ;;
        raidz2) echo 4 ;;
        raidz3) echo 5 ;;
        mirror) echo 2 ;;
        *)      echo 1 ;;
    esac
}

# Prompts for the vdev type. Sets ZFS_VDEV_LEVEL.
_zfs_prompt_vdev_level() {
    ZFS_VDEV_LEVEL=""
    while true; do
        echo ""
        echo " vdev type for this pool:"
        echo "   1) raidz1  (single parity, min 3 per vdev)"
        echo "   2) raidz2  (double parity, min 4 per vdev)"
        echo "   3) raidz3  (triple parity, min 5 per vdev)"
        echo "   4) mirror  (min 2 per vdev)"
        echo "   5) stripe  (no redundancy)"
        local c; _read_choice c "Enter selection [1-5]: "
        case "$c" in
            1) ZFS_VDEV_LEVEL="raidz1"; return 0 ;;
            2) ZFS_VDEV_LEVEL="raidz2"; return 0 ;;
            3) ZFS_VDEV_LEVEL="raidz3"; return 0 ;;
            4) ZFS_VDEV_LEVEL="mirror"; return 0 ;;
            5) ZFS_VDEV_LEVEL="stripe"; return 0 ;;
            *) echo "[ERROR] Enter 1-5." ;;
        esac
    done
}

# Builds the plan's grouped drive field: "vdev:a,b,c;vdev:d,e,f;spare:g,h;cache:i".
_zfs_compose_drives_field() {
    local width="$1"; shift
    local spares_csv="$1"; shift
    local cache_csv="$1"; shift
    local drives=("$@")
    local out="" i n=${#drives[@]}
    for ((i=0; i<n; i+=width)); do
        local grp=("${drives[@]:i:width}")
        out+="vdev:$(IFS=,; echo "${grp[*]}");"
    done
    [ -n "$spares_csv" ] && out+="spare:${spares_csv};"
    [ -n "$cache_csv" ]  && out+="cache:${cache_csv};"
    printf '%s\n' "${out%;}"
}

# _zfs_groups <drives_field> <vdev|spare|cache> -- one group per line, drives comma-separated.
_zfs_groups() {
    printf '%s\n' "$1" | tr ';' '\n' | grep "^$2:" | sed "s/^$2://"
}

# Flattens any plan drive field to a plain device list, grouped (ZFS) or not.
_plan_drive_list() {
    printf '%s\n' "$1" | tr ';' '\n' | sed 's/^[a-z][a-z]*://' | tr ',' '\n' | grep -v '^$'
}

# Non-interactive pool creation from a composed drives field. Sets _ZFS_BUILT_POOL on success,
# or _ZFS_BUILD_ERROR (returns 1). Shared by the menu path and IE Provisioning.
_zfs_build_pool_core() {
    local pool="$1" level="$2" drives_field="$3" mountpoint="$4"
    _ZFS_BUILT_POOL=""; _ZFS_BUILD_ERROR=""

    if zpool list "$pool" >/dev/null 2>&1; then
        _ZFS_BUILD_ERROR="A pool named '$pool' already exists. Destroy it first or choose another name."
        return 1
    fi

    local args=() grp
    while IFS= read -r grp; do
        [ -z "$grp" ] && continue
        [ "$level" != "stripe" ] && args+=("$level")
        local d; IFS=',' read -ra d <<< "$grp"
        args+=("${d[@]}")
    done < <(_zfs_groups "$drives_field" vdev)

    if [ ${#args[@]} -eq 0 ]; then
        _ZFS_BUILD_ERROR="No vdevs in the plan for pool '$pool'."
        return 1
    fi

    local sp; sp=$(_zfs_groups "$drives_field" spare | head -1)
    if [ -n "$sp" ]; then
        local s; IFS=',' read -ra s <<< "$sp"
        args+=("spare" "${s[@]}")
    fi
    local ca; ca=$(_zfs_groups "$drives_field" cache | head -1)
    if [ -n "$ca" ]; then
        local c; IFS=',' read -ra c <<< "$ca"
        args+=("cache" "${c[@]}")
    fi

    # Every member is wiped first: a leftover md superblock or partition table makes zpool
    # create refuse, and -f alone does not always clear one.
    local dev
    for dev in $(_plan_drive_list "$drives_field"); do
        wipefs -af "$dev" >/dev/null 2>&1 || true
    done

    echo "[BUILD] zpool create -f -o ashift=12 -m ${mountpoint:-none} $pool ${args[*]}"
    if ! zpool create -f -o ashift=12 -m "${mountpoint:-none}" "$pool" "${args[@]}" 2>/tmp/zpool_err.log; then
        _ZFS_BUILD_ERROR="zpool create failed: $(tr -d '\n' < /tmp/zpool_err.log)"
        return 1
    fi
    _ZFS_BUILT_POOL="$pool"
    return 0
}

# --- Option 5a: ZFS -- Build Pool ---
run_zfs_build_pool() {
    clear
    echo "====================================================================="
    echo "              OPTION 5 / BUILD: ZFS POOL CREATION                    "
    echo "====================================================================="
    echo ""
    echo " Builds one pool from equal-width vdevs, with optional hot spares and"
    echo " an L2ARC cache device. Nothing is written until you confirm the"
    echo " projected structure at the end."
    echo ""

    _zfs_ensure_installed || { pause_to_menu "ZFS is not available on this system."; return 1; }

    echo "[INFO] Scanning for available drives..."
    _discover_candidate_drives
    local raw_count=${#_DISCOVERED_PATHS[@]}
    if [ "$raw_count" -eq 0 ]; then
        pause_to_menu "No raw, unmounted drives available to build a pool from."
        return 1
    fi

    local pool_name
    while true; do
        _prompt_confirmed pool_name "Pool name" "Pool name (e.g. vpool): "
        case "$pool_name" in
            *[!A-Za-z0-9_.-]*) echo "[ERROR] Letters, digits, dot, dash and underscore only." ;;
            [0-9]*)            echo "[ERROR] A pool name cannot start with a digit." ;;
            *)                 break ;;
        esac
    done

    _zfs_prompt_vdev_level
    local level="$ZFS_VDEV_LEVEL"
    local min_width; min_width=$(_zfs_min_width "$level")

    echo ""
    echo " Select the DATA drives for this pool (all vdevs at once)."
    echo " Use numbers, ranges, or 'all'.  Example: 1-56"
    echo ""
    local data_indices=() data_paths=() drive_sel idx
    while true; do
        read -p "Data drive selection: " drive_sel
        data_indices=()
        _parse_selection_string "$drive_sel" data_indices "$raw_count"
        if [ ${#data_indices[@]} -lt "$min_width" ]; then
            echo "[ERROR] $level needs at least $min_width drive(s) per vdev."
            continue
        fi
        data_paths=()
        for idx in "${data_indices[@]}"; do data_paths+=("${_DISCOVERED_PATHS[$((idx-1))]}"); done
        if ! _check_selection_media data_paths; then
            echo "[INFO] Reselect drives of a single type."
            continue
        fi
        _confirm_drive_selection "Confirm Pool Data Drives" data_indices && break
        echo "Reselect the data drives."
    done
    local data_count=${#data_paths[@]}

    local width
    while true; do
        echo ""
        echo " $data_count data drive(s) selected."
        _read_choice width "Drives per vdev (min $min_width): "
        case "$width" in
            ''|*[!0-9]*) echo "[ERROR] Enter a number."; continue ;;
        esac
        if [ "$width" -lt "$min_width" ]; then
            echo "[ERROR] $level needs at least $min_width per vdev."; continue
        fi
        if [ $(( data_count % width )) -ne 0 ]; then
            echo "[ERROR] $data_count is not divisible by $width -- every vdev must be the same width."
            continue
        fi
        break
    done
    local vdev_count=$(( data_count / width ))

    # Spares and cache are optional and drawn from what is left after the data selection.
    local claimed=" ${data_paths[*]} "
    local remaining_idx=() i
    for i in $(seq 1 "$raw_count"); do
        case "$claimed" in *" ${_DISCOVERED_PATHS[$((i-1))]} "*) ;; *) remaining_idx+=("$i") ;; esac
    done

    local spare_paths=() cache_paths=()
    if [ ${#remaining_idx[@]} -gt 0 ]; then
        echo ""
        echo " Unclaimed drives available for hot spares / L2ARC cache:"
        for i in "${remaining_idx[@]}"; do
            echo "  $i) ${_DISCOVERED_PATHS[$((i-1))]}  ${_DISCOVERED_MODELS[$((i-1))]}  (${_DISCOVERED_CAPACITIES[$((i-1))]}GB, $(_drive_media_label "${_DISCOVERED_PATHS[$((i-1))]}"))"
        done
        echo ""
        local sp_sel
        read -p "Hot spare selection (numbers/ranges, blank for none): " sp_sel
        if [ -n "$sp_sel" ]; then
            local sp_idx=()
            _parse_selection_string "$sp_sel" sp_idx "$raw_count"
            for idx in "${sp_idx[@]}"; do
                case "$claimed" in *" ${_DISCOVERED_PATHS[$((idx-1))]} "*) continue ;; esac
                spare_paths+=("${_DISCOVERED_PATHS[$((idx-1))]}")
            done
            claimed+="${spare_paths[*]} "
        fi

        local ch_sel
        read -p "L2ARC cache selection (numbers/ranges, blank for none): " ch_sel
        if [ -n "$ch_sel" ]; then
            local ch_idx=()
            _parse_selection_string "$ch_sel" ch_idx "$raw_count"
            for idx in "${ch_idx[@]}"; do
                case "$claimed" in *" ${_DISCOVERED_PATHS[$((idx-1))]} "*) continue ;; esac
                cache_paths+=("${_DISCOVERED_PATHS[$((idx-1))]}")
            done
        fi
    fi

    local mountpoint
    _prompt_confirmed mountpoint "Mount point" "Mount point for this pool (mounted at root, e.g. /data): "

    local spares_csv="" cache_csv=""
    [ ${#spare_paths[@]} -gt 0 ] && spares_csv=$(IFS=,; echo "${spare_paths[*]}")
    [ ${#cache_paths[@]} -gt 0 ] && cache_csv=$(IFS=,; echo "${cache_paths[*]}")
    local drives_field
    drives_field=$(_zfs_compose_drives_field "$width" "$spares_csv" "$cache_csv" "${data_paths[@]}")

    _pending_plan_clear
    _pending_plan_add "zfs" "$level" "$drives_field" "$pool_name" "$mountpoint"
    if ! _confirm_projected_structure "${_PENDING_PLAN[@]}"; then
        pause_to_menu "Pool creation cancelled -- no drive was touched."
        return 1
    fi

    if _media_is_hdd; then
        echo "[INFO] Rotational media -- skipping preconditioning and QD calibration."
        _hdd_health_validation "zfs-${pool_name}" "${data_paths[@]}" ${spare_paths[@]+"${spare_paths[@]}"}
    else
        local zmodels=() zserials=() zp
        for zp in "${data_paths[@]}"; do
            get_drive_metadata "$zp"; zmodels+=("$DRIVE_MODEL"); zserials+=("$DRIVE_SERIAL")
        done
        local batch_status=()
        _precondition_drive_batch data_paths zmodels zserials batch_status "$SWEEP_DIR/Logs"
        get_drive_metadata "${data_paths[0]}"
        _ensure_qd_profile "${data_paths[0]}" "$DRIVE_MODEL" "$DRIVE_MODEL_TOKEN"
    fi

    if ! _zfs_build_pool_core "$pool_name" "$level" "$drives_field" "$mountpoint"; then
        pause_to_menu "$_ZFS_BUILD_ERROR"
        return 1
    fi
    _pending_plan_clear

    echo ""
    echo "[SUCCESS] Pool '$pool_name' created: $vdev_count x $level vdev(s) of $width drive(s)."
    zpool status "$pool_name" 2>/dev/null
    zpool list "$pool_name" 2>/dev/null
    _show_drive_structure "Actual Structure After ZFS Pool Creation -- $pool_name"
    pause_to_menu "ZFS pool build complete: $pool_name"
    return 0
}

# --- Option 5b: ZFS -- Destroy Pool(s) ---
run_zfs_delete_pools() {
    clear
    echo "====================================================================="
    echo "             OPTION 5 / DESTROY: ZFS POOL DESTRUCTION                "
    echo "====================================================================="
    echo ""
    _zfs_available || { pause_to_menu "ZFS is not installed on this system."; return 1; }

    local pools=()
    while IFS= read -r p; do [ -n "$p" ] && pools+=("$p"); done < <(zpool list -H -o name 2>/dev/null)
    if [ ${#pools[@]} -eq 0 ]; then
        pause_to_menu "No ZFS pools found on this host."
        return 1
    fi

    echo " Select pool(s) to DESTROY. This removes all data on their member drives."
    echo ""
    local index=1 p
    for p in "${pools[@]}"; do
        echo "  $index) $p  ($(zpool list -H -o size,health "$p" 2>/dev/null | tr '\t' ' '))"
        index=$((index + 1))
    done
    echo ""
    read -p "Selection (1-$((index-1))): " sel
    local sel_indices=()
    _parse_selection_string "$sel" sel_indices "$((index-1))"
    if [ ${#sel_indices[@]} -eq 0 ]; then
        pause_to_menu "No valid pool(s) selected."
        return 1
    fi

    local targets=() idx
    for idx in "${sel_indices[@]}"; do targets+=("${pools[$((idx-1))]}"); done

    echo ""
    echo "====================================================================="
    echo " ABOUT TO DESTROY: ${targets[*]}"
    echo "====================================================================="
    echo " WARNING: every dataset and all data in these pools is destroyed."
    local confirm
    read -p "Type 'YES' to proceed: " confirm
    [ "$confirm" != "YES" ] && { pause_to_menu "Pool destruction cancelled."; return 1; }

    local t rc=0
    for t in "${targets[@]}"; do
        if zpool destroy -f "$t" 2>/tmp/zpool_destroy_err.log; then
            echo "[OK] Destroyed $t"
        else
            echo "[FAIL] $t: $(tr -d '\n' < /tmp/zpool_destroy_err.log)"; rc=1
        fi
    done
    _show_drive_structure "Structure After Pool Destruction"
    pause_to_menu "Pool destruction finished."
    return "$rc"
}

# --- Option 5c: ZFS -- Test Pool(s) ---
# Flash pools get the standard fio suite against a file in the pool's mountpoint (ZFS has no raw
# device to target). Rotational pools get member health only.
run_zfs_test_pools() {
    clear
    echo "====================================================================="
    echo "                OPTION 5 / TEST: ZFS POOL VALIDATION                 "
    echo "====================================================================="
    echo ""
    _zfs_available || { pause_to_menu "ZFS is not installed on this system."; return 1; }

    local pools=()
    while IFS= read -r p; do [ -n "$p" ] && pools+=("$p"); done < <(zpool list -H -o name 2>/dev/null)
    if [ ${#pools[@]} -eq 0 ]; then
        pause_to_menu "No ZFS pools found on this host."
        return 1
    fi

    local index=1 p
    for p in "${pools[@]}"; do
        echo "  $index) $p  ($(zpool list -H -o size,health "$p" 2>/dev/null | tr '\t' ' '))"
        index=$((index + 1))
    done
    echo ""
    read -p "Selection (1-$((index-1))): " sel
    local sel_indices=()
    _parse_selection_string "$sel" sel_indices "$((index-1))"
    [ ${#sel_indices[@]} -eq 0 ] && { pause_to_menu "No valid pool(s) selected."; return 1; }

    [ -z "${VAL_LOGDIR:-}" ] && _init_validation_paths
    get_cpu_threads

    local idx
    for idx in "${sel_indices[@]}"; do
        local pool="${pools[$((idx-1))]}"
        echo ""
        write_header "ZFS POOL: $pool"
        zpool status "$pool" 2>/dev/null

        # Pool health is checked for every pool regardless of media.
        local health; health=$(zpool list -H -o health "$pool" 2>/dev/null)
        if [ "$health" = "ONLINE" ]; then
            vrecord "ZFS-$pool" "PASS" "pool health ONLINE"
        else
            vrecord "ZFS-$pool" "FAIL" "pool health is $health -- see zpool status"
        fi
        vrecord_evidence "ZFS-$pool" "$(zpool status "$pool" 2>/dev/null)"

        local members=() m
        while IFS= read -r m; do [ -n "$m" ] && members+=("/dev/$m"); done < <(
            zpool status -P "$pool" 2>/dev/null | grep -oE '/dev/[a-z0-9]+' | sed 's#/dev/##' | sort -u)
        [ ${#members[@]} -eq 0 ] && { echo "[WARN] Could not resolve member devices for $pool."; continue; }

        if ! _check_selection_media members; then
            echo "[WARN] $pool mixes flash and rotational members -- health check only."
            _hdd_health_validation "zfs-${pool}" "${members[@]}"
            continue
        fi
        if _media_is_hdd; then
            echo "[INFO] Rotational pool -- health check only, no performance testing."
            _hdd_health_validation "zfs-${pool}" "${members[@]}"
            continue
        fi

        local mnt; mnt=$(zfs get -H -o value mountpoint "$pool" 2>/dev/null)
        if [ -z "$mnt" ] || [ "$mnt" = "none" ] || [ ! -d "$mnt" ]; then
            echo "[WARN] $pool has no usable mountpoint -- skipping performance test."
            continue
        fi
        echo "[INFO] Flash pool -- running fio against $mnt (ZFS exposes no raw device)."
        get_drive_metadata "${members[0]}"
        DRIVE_COUNT=${#members[@]}
        _load_qd_profile "$DRIVE_MODEL_TOKEN" "$DRIVE_COUNT"
        pushd "$RESULTS_DIR" >/dev/null
        execute_and_summarize_fio "$mnt/exx_zfs_test.dat" "zfs_${pool}" "$FINAL_JOBS" "$FINAL_DEPTH" "ZFS" false
        popd >/dev/null
        rm -f "$mnt/exx_zfs_test.dat" 2>/dev/null
    done

    print_val_summary
    pause_to_menu "ZFS pool testing complete."
    return 0
}

run_zfs_menu() {
    while true; do
        clear
        echo "====================================================================="
        echo "                      OPTION 5: ZFS VALIDATION                       "
        echo "====================================================================="
        echo "  1) Build Pool           — Select drives, choose vdev type"
        echo "                            (raidz1/2/3, mirror, stripe) and width,"
        echo "                            add hot spares and an L2ARC cache"
        echo "  2) Destroy Pool(s)      — Destroy pool(s) and free their drives"
        echo "  3) Test Pool(s)         — Health for every pool; fio performance"
        echo "                            only on flash pools (HDD pools get"
        echo "                            SMART health only)"
        echo "  Q) Back to Storage Menu"
        echo "====================================================================="
        _read_choice sub_input "Enter selection (1-3, or Q): "
        case "$sub_input" in
            1) run_zfs_build_pool ;;
            2) run_zfs_delete_pools ;;
            3) run_zfs_test_pools ;;
            [Qq]) return ;;
            *)
                echo -e "\n[ERROR] Invalid selection."
                read -p "Press [Enter] to try again..."
                ;;
        esac
    done
}

# ==============================================================
# --- NoOS / PXE-live storage handling ---
# (a NoOS system is validated then SHIPPED BLANK, so anything built for testing is torn down
#  again automatically at the end of the run -- there is no operator to ask by then.)
# ==============================================================

# OS prep for a NoOS/PXE-live run, done on EVERY invocation: --noos skips base_install, and the live
# image ships almost none of the validation toolchain. Everything installed here lives only in RAM and
# is gone at the next reboot, so it must be reinstalled each run. Ubuntu only (the live image is Ubuntu).
_noos_prepare_os() {
    . /etc/os-release
    case "$ID" in
        ubuntu) ;;
        *) vlog "NOOS-PREP: non-Ubuntu ($ID $VERSION_ID) -- skipping Ubuntu OS-prep."; return 0 ;;
    esac
    write_header "NoOS OS Preparation"
    echo "  --noos skips Base Install, so the validation toolchain is installed now."
    echo "  This runs every time; it all lives in RAM and is gone at the next reboot."
    export DEBIAN_FRONTEND=noninteractive
    local plog="${VAL_LOGDIR:-/tmp}/noos_prepare.log"; : > "$plog" 2>/dev/null
    local i

    echo "  - Refreshing package lists (apt-get update)..."
    for i in 1 2 3; do
        apt-get update >>"$plog" 2>&1 && break || { echo "nameserver 8.8.8.8" > /etc/resolv.conf; sleep 2; }
    done

    # Hold the running GPU driver across the upgrade: a mid-run driver swap breaks GPU validation and a
    # toram system cannot be rebooted to recover. Released right after.
    local held=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        held=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^(nvidia-|libnvidia-|cuda-drivers)/{print $2}')
        [ -n "$held" ] && apt-mark hold $held >>"$plog" 2>&1 && vlog "NOOS-PREP: held GPU driver packages during upgrade."
    fi

    # Full OS upgrade per operator policy. Non-interactive, keep existing configs; a new kernel only
    # matters after a reboot we never do, so the running session is unaffected.
    echo "  - Upgrading the OS (apt-get full-upgrade -- may take several minutes)..."
    if apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade >>"$plog" 2>&1; then
        echo "    [OK] upgrade complete"
    else
        echo -e "    ${TXT_YLW}[WARN] upgrade reported problems -- see $plog${RESET}"
        log_failure "NoOS OS full-upgrade had problems (see $plog)"
    fi
    [ -n "$held" ] && apt-mark unhold $held >>"$plog" 2>&1

    # dhclient (isc-dhcp-client) so a tech can renew the lease later -- the live image omits it by default.
    # Plus the validation toolchain base_install would normally provide but --noos skips.
    echo "  - Installing dhclient + the validation toolchain..."
    # zip: the run archives its log/results folders at the end; the live image omits zip, so without
    # this the archive step warns and leaves the folders loose (report itself is unaffected).
    install_apt_packages "isc-dhcp-client" "fio" "stressapptest" "stress-ng" "memtester" \
                         "smartmontools" "nvme-cli" "lm-sensors" "cmake" "numactl" "hwloc" "zip"

    # gpu_burn / matrixMul need nvcc + cuBLAS dev headers. The live image ships only the CUDA runtime,
    # so add the compiler + dev libs MATCHING the installed CUDA (token from /usr/local/cuda, e.g. 13-2).
    # This installs NO driver. The CUDA apt repo is already configured on the image.
    if [ -e /usr/local/cuda ] && [ ! -x /usr/local/cuda/bin/nvcc ]; then
        local cver ctok
        cver=$(readlink -f /usr/local/cuda 2>/dev/null | grep -oE 'cuda-[0-9]+(\.[0-9]+)?' | head -1 | sed 's/^cuda-//')
        ctok=$(printf '%s' "$cver" | tr '.' '-')
        if [ -n "$ctok" ]; then
            vlog "NOOS-PREP: installing CUDA compiler/dev matching runtime $cver (cuda-nvcc-$ctok)."
            install_apt_packages "cuda-nvcc-$ctok" "libcublas-dev-$ctok"
        else
            log_failure "NoOS: could not derive CUDA version from /usr/local/cuda -- gpu_burn may fail to build."
        fi
    fi
    # Make CUDA libs discoverable so runtime binaries (gpu_burn) find libcublas without LD_LIBRARY_PATH.
    if [ -d /usr/local/cuda/lib64 ]; then
        echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf; ldconfig 2>>"$plog"
    fi
    echo -e "${TXT_GRN}  [OK] NoOS OS preparation complete.${RESET}"
}

# Builds a plan of one volume per available drive, ext4 at /data1../dataN. Mount names are
# throwaway: nothing survives the teardown, so there is nothing to name meaningfully.
# Populates _IE_PLAN[]. Returns 1 if no drives are available.
# Fills _IE_PLAN with one single-drive ext4 volume per drive -- /data1../dataN -- ordered NVMe first
# (numeric by controller then namespace), then SATA/SAS (natural sd order). Scales to any drive count.
# Silent (drive-scan output suppressed). Returns 1 when no candidate drives are present.
_build_all_drives_data_plan() {
    _IE_PLAN=()
    _discover_candidate_drives >/dev/null
    [ "${#_DISCOVERED_PATHS[@]}" -eq 0 ] && return 1

    # _discover_candidate_drives lists NVMe before SATA/SAS, but in shell-glob (lexical) order, so
    # nvme10n1 would sort before nvme2n1 and sdaa before sdb. Re-key each path into true device order:
    # group (nvme=0, sd=1, other=2), then fixed-width numeric/length keys so a plain string sort of
    # the key is the correct order regardless of drive count.
    local p dev letters key keyed=()
    for p in "${_DISCOVERED_PATHS[@]}"; do
        dev=${p##*/}
        if [[ "$dev" =~ ^nvme([0-9]+)n([0-9]+)$ ]]; then
            printf -v key '0 %010d %010d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        elif [[ "$dev" =~ ^sd([a-z]+)$ ]]; then
            letters="${BASH_REMATCH[1]}"
            printf -v key '1 %02d %s' "${#letters}" "$letters"   # length first: sdz before sdaa
        else
            key="2 00 $dev"
        fi
        keyed+=("$key"$'\t'"$p")
    done

    local idx=1 line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        _IE_PLAN+=("single||${line}|ext4|/data${idx}")
        idx=$((idx + 1))
    done < <(printf '%s\n' "${keyed[@]}" | LC_ALL=C sort -t$'\t' -k1,1 | cut -f2-)
    return 0
}

_noos_auto_storage_plan() {
    echo "[INFO] Scanning for drives to include in the automatic test layout..."
    if ! _build_all_drives_data_plan; then
        echo "[WARN] No raw, unmounted drives found -- storage testing will be skipped."
        return 1
    fi
    local entry dev mp
    for entry in "${_IE_PLAN[@]}"; do
        IFS='|' read -r _ _ dev _ mp <<< "$entry"
        echo "  ${mp}  <- ${dev}  ($(_drive_media_label "$dev"))"
    done
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\n' "${_IE_PLAN[@]}" > "$IE_PLAN_FILE"
    echo "[OK] ${#_IE_PLAN[@]} drive(s) queued for validation, then wiped at the end of the run."
    return 0
}

# Storage question for a NoOS run, asked up front with the serial number so the run itself stays
# unattended. A saved plan from a previous session is offered as-is rather than silently reused.
_noos_storage_setup() {
    echo ""
    write_header "NoOS Storage Setup"
    if [ -s "$IE_PLAN_FILE" ]; then
        echo "A saved storage plan already exists ($(wc -l < "$IE_PLAN_FILE" | tr -d ' ') volume(s))."
        local keep
        _yes_no keep "Use the saved plan for this run? (y/n): "
        [ "$keep" = "y" ] && { echo "[OK] Using the saved plan."; return 0; }
        rm -f "$IE_PLAN_FILE"
    fi

    echo "  1) Automatic  -- every available drive as its own volume, ext4, /data1../dataN"
    echo "  2) Guided     -- choose drives, RAID/ZFS type, filesystem and mount points"
    echo "  3) Skip       -- no storage testing this run"
    echo ""
    local c
    while true; do
        _read_choice c "Enter selection [1-3]: "
        case "$c" in
            1) _noos_auto_storage_plan; return 0 ;;
            2)
                get_cpu_threads
                verify_environment_templates
                _ie_collect_and_save_guided
                return 0 ;;
            3) echo "[INFO] Storage testing skipped."; rm -f "$IE_PLAN_FILE" 2>/dev/null; return 0 ;;
            *) echo "Please enter 1, 2 or 3." ;;
        esac
    done
}

# Returns every mount point this run created: the plan's own, plus any /dataN left behind by an
# earlier run on the same box.
_noos_test_mountpoints() {
    local entry mp
    if [ -s "$IE_PLAN_FILE" ]; then
        while IFS= read -r entry; do
            mp="${entry##*|}"
            [ -n "$mp" ] && [ "$mp" != "none" ] && printf '%s\n' "$mp"
        done < "$IE_PLAN_FILE"
    fi
    local d
    for d in /data[0-9]*; do [ -d "$d" ] && printf '%s\n' "$d"; done
    return 0
}

# Tears every test structure back down so the system ships blank: unmount, drop the fstab entries
# this script added, destroy pools and arrays, then wipe each drive's signatures.
# Deliberately prompt-free -- it only ever runs under --noos, where nobody is watching, and the
# whole point of a NoOS build is that nothing survives to the customer.
_noos_teardown_storage() {
    local log="${VAL_LOGDIR:-/tmp}/noos_teardown.log"
    : > "$log"
    echo ""
    write_header "NoOS TEARDOWN -- returning all drives to blank"
    echo "  This system ships with no OS, so every test volume is destroyed now."
    echo "  Log: $log"
    echo ""

    local removed=0 failed=0

    # 1. Unmount the test mount points, then drop their fstab lines so a later boot can't remount.
    local mp
    while IFS= read -r mp; do
        [ -z "$mp" ] && continue
        if mountpoint -q "$mp" 2>/dev/null || grep -q " $mp " /proc/mounts 2>/dev/null; then
            if umount "$mp" 2>>"$log" || umount -l "$mp" 2>>"$log"; then
                echo "  [OK]   unmounted $mp"
            else
                echo -e "  ${TXT_YLW}[WARN] could not unmount $mp${RESET}"; failed=$((failed+1))
            fi
        fi
        if grep -qE "[[:space:]]${mp}[[:space:]]" /etc/fstab 2>/dev/null; then
            cp /etc/fstab "/etc/fstab.bak_noos_$(date +%Y%m%d_%H%M%S)" 2>/dev/null
            sed -i "\#[[:space:]]${mp}[[:space:]]#d" /etc/fstab 2>>"$log"
            echo "  [OK]   removed fstab entry for $mp"
        fi
        rmdir "$mp" 2>/dev/null
    done < <(_noos_test_mountpoints | sort -u)

    # 2. ZFS pools, before their member drives are wiped out from under them.
    if command -v zpool >/dev/null 2>&1; then
        local pool
        while IFS= read -r pool; do
            [ -z "$pool" ] && continue
            if zpool destroy -f "$pool" 2>>"$log"; then
                echo "  [OK]   destroyed ZFS pool $pool"; removed=$((removed+1))
            else
                echo -e "  ${TXT_YLW}[WARN] could not destroy pool $pool${RESET}"; failed=$((failed+1))
            fi
        done < <(zpool list -H -o name 2>/dev/null)
    fi

    # 3. GRAID virtual drives, drive groups and physical drives, in that dependency order.
    if command -v graidctl >/dev/null 2>&1; then
        local vd dg pd
        for vd in $(graidctl list virtual_drive 2>/dev/null | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+'); do
            graidctl delete virtual_drive "$vd" --confirm-to-delete 2>>"$log" && echo "  [OK]   deleted GRAID VD $vd"
        done
        for dg in $(graidctl list drive_group 2>/dev/null | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+'); do
            graidctl delete drive_group "$dg" --confirm-to-delete 2>>"$log" && echo "  [OK]   deleted GRAID DG $dg"
        done
        for pd in $(graidctl list physical_drive 2>/dev/null | grep -oE '^\| *[0-9]+' | grep -oE '[0-9]+'); do
            graidctl delete physical_drive "$pd" --confirm-to-delete 2>>"$log" && echo "  [OK]   deleted GRAID PD $pd"
        done
    fi

    # 4. MDADM arrays, capturing members first -- /proc/mdstat is empty once the array stops.
    local md members=() m
    for md in $(grep -oE '^md[0-9]+' /proc/mdstat 2>/dev/null); do
        for m in $(_mdadm_member_drives "$md" 2>/dev/null); do members+=("/dev/$m"); done
        if mdadm --stop "/dev/$md" >>"$log" 2>&1; then
            echo "  [OK]   stopped array /dev/$md"; removed=$((removed+1))
        else
            echo -e "  ${TXT_YLW}[WARN] could not stop /dev/$md${RESET}"; failed=$((failed+1))
        fi
    done
    for m in "${members[@]}"; do
        mdadm --zero-superblock "$m" >>"$log" 2>&1 && echo "  [OK]   zeroed md superblock on $m"
    done

    # 5. Wipe signatures off every drive this suite would ever have offered. Scoped to
    #    _discover_candidate_drives, which already excludes root disks, USB and removable media --
    #    never a blanket sweep of /dev.
    sleep 2
    _discover_candidate_drives include_graid >/dev/null
    local d
    for d in "${_DISCOVERED_PATHS[@]}"; do
        if wipefs -af "$d" >>"$log" 2>&1; then
            echo "  [OK]   wiped signatures on $d"; removed=$((removed+1))
        else
            echo -e "  ${TXT_YLW}[WARN] wipefs failed on $d${RESET}"; failed=$((failed+1))
        fi
        # Stripping signatures is not the same as erasing data. Deallocate every block so the drive
        # ships truly blank, not just unrecognized. Fast on NVMe/SSD (TRIM); a device that can't
        # discard just logs a notice and keeps the signature wipe as the result.
        if blkdiscard -f "$d" >>"$log" 2>&1; then
            echo "  [OK]   discarded all blocks on $d"
        else
            echo -e "  ${TXT_YLW}[INFO] $d does not support blkdiscard -- signatures wiped only${RESET}"
        fi
    done
    partprobe >/dev/null 2>&1 || true

    # 6. Prove it, into the log and the report.
    {
        echo "=== lsblk after teardown ==="
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null
        echo ""
        echo "=== /proc/mdstat ==="; cat /proc/mdstat 2>/dev/null
        echo ""
        echo "=== fstab ==="; cat /etc/fstab 2>/dev/null
    } >> "$log"

    echo ""
    _show_drive_structure "Drive Structure After NoOS Teardown"

    if [ "$failed" -eq 0 ]; then
        vrecord "NOOS-TEARDOWN" "PASS" "$removed object(s) removed, all drives returned to blank -- see $log"
    else
        vrecord "NOOS-TEARDOWN" "WARN" "$removed removed, $failed problem(s) -- CHECK MANUALLY before shipping. See $log"
    fi
    vrecord_evidence "NOOS-TEARDOWN" "$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null)"

    # The saved plan describes structures that no longer exist.
    rm -f "$IE_PLAN_FILE" 2>/dev/null
    echo ""
    [ "$failed" -eq 0 ] && echo -e "${TXT_GRN}[SUCCESS] All test storage removed -- system is blank and ready to ship.${RESET}" \
                        || echo -e "${TXT_YLW}[WARN] Teardown finished with $failed problem(s) -- verify manually before shipping.${RESET}"
    return 0
}

# --- Main Menu ---

# --- Option 2 submenu: Build Array / Test Array(s) ---
run_mdadm_raid_menu() {
    while true; do
        clear
        echo "====================================================================="
        echo "                  OPTION 2: SW RAID (MDADM) TESTING                  "
        echo "====================================================================="
        echo "  1) Build Array          — Select drives, choose RAID level"
        echo "                            (0/1/5/6/10), create a new MDADM array"
        echo "  2) Delete Array(s)      — Stop array(s) and zero member drives'"
        echo "                            superblocks; drives become raw again"
        echo "  3) Test Array(s)        — Select one or more existing arrays to"
        echo "                            benchmark (multi-select supported;"
        echo "                            simultaneous when arrays don't share"
        echo "                            drives, sequential when they do)"
        echo "  Q) Back to Main Menu"
        echo "====================================================================="
        _read_choice sub_input "Enter selection (1-3, or Q): "
        case "$sub_input" in
            1) run_mdadm_build_array ;;
            2) run_mdadm_delete_array ;;
            3) run_mdadm_test_arrays ;;
            [Qq]) return ;;
            *)
                echo -e "\n[ERROR] Invalid selection."
                read -p "Press [Enter] to try again..."
                ;;
        esac
    done
}

# --- Option 4 submenu: Build Array / Delete Array(s) / Test Array(s) ---
run_graid_menu() {
    while true; do
        clear
        echo "====================================================================="
        echo "                       OPTION 4: GRAID VALIDATION                    "
        echo "====================================================================="
        echo "  1) Build Array          — Select drives, choose RAID level"
        echo "                            (0/1/5/6/10), create a new GRAID array"
        echo "  2) Delete Array(s)      — Destroy array(s) AND remove their PDs"
        echo "                            from graidctl; drives become raw disks"
        echo "                            again, not just unconfigured PDs"
        echo "  3) Test Array(s)        — Select one or more existing arrays to"
        echo "                            benchmark (multi-select; always runs"
        echo "                            sequentially — SupremeRAID's parity"
        echo "                            offload shares one GPU across every"
        echo "                            array, so concurrent tests would"
        echo "                            contend for it)"
        echo "  4) Reset Empirical Baseline — clear a stale/degraded saved"
        echo "                            baseline for a drive model"
        echo "  Q) Back to Main Menu"
        echo "====================================================================="
        _read_choice sub_input "Enter selection (1-4, or Q): "
        case "$sub_input" in
            1) run_graid_build_array ;;
            2) run_graid_delete_arrays ;;
            3) run_graid_test_arrays ;;
            4) graid_reset_baseline ;;
            [Qq]) return ;;
            *)
                echo -e "\n[ERROR] Invalid selection."
                read -p "Press [Enter] to try again..."
                ;;
        esac
    done
}

# --- IE Provisioning: collects every volume up front, then runs unattended: build -> validate -> format -> mount. ---

# Drives claimed by an earlier queued volume -- still free at OS level, so otherwise offered twice.
_ie_claimed_drives() {
    local claimed=() entry drives_field parts
    for entry in "${_IE_PLAN[@]}"; do
        drives_field=$(echo "$entry" | awk -F'|' '{print $3}')
        while IFS= read -r parts; do [ -n "$parts" ] && claimed+=("$parts"); done < <(_plan_drive_list "$drives_field")
    done
    echo "${claimed[@]}"
}

# Wraps _discover_candidate_drives, filtering claimed drives and renumbering the listing.
_ie_discover_unclaimed_drives() {
    # Discovery echoes its own listing -- suppressed, since everything is renumbered below.
    _discover_candidate_drives >/dev/null
    local claimed=" $(_ie_claimed_drives) "

    local f_paths=() f_models=() f_serials=() f_caps=() f_numas=()
    local i
    for ((i=0; i<${#_DISCOVERED_PATHS[@]}; i++)); do
        local p="${_DISCOVERED_PATHS[$i]}"
        [[ "$claimed" == *" $p "* ]] && continue
        f_paths+=("$p")
        f_models+=("${_DISCOVERED_MODELS[$i]}")
        f_serials+=("${_DISCOVERED_SERIALS[$i]}")
        f_caps+=("${_DISCOVERED_CAPACITIES[$i]}")
        f_numas+=("${_DISCOVERED_NUMA_NODES[$i]}")
    done
    _DISCOVERED_PATHS=("${f_paths[@]}")
    _DISCOVERED_MODELS=("${f_models[@]}")
    _DISCOVERED_SERIALS=("${f_serials[@]}")
    _DISCOVERED_CAPACITIES=("${f_caps[@]}")
    _DISCOVERED_NUMA_NODES=("${f_numas[@]}")

    local precond_marker_dir="$SWEEP_DIR/Preconditioned"
    for ((i=0; i<${#_DISCOVERED_PATHS[@]}; i++)); do
        local notes=""
        [ -f "$precond_marker_dir/${_DISCOVERED_SERIALS[$i]}.done" ] && notes=" [preconditioned]"
        echo "  $((i+1))) ${_DISCOVERED_PATHS[$i]}  ${_DISCOVERED_MODELS[$i]}  (${_DISCOVERED_CAPACITIES[$i]}GB, serial ${_DISCOVERED_SERIALS[$i]})  [NUMA node ${_DISCOVERED_NUMA_NODES[$i]}]${notes}"
    done
}

# Collection loop. Populates _IE_PLAN[]: "type|level|drives,csv|fs|mountpoint". Returns 1 if empty.
_ie_collect_plan() {
    _IE_PLAN=()
    clear
    echo "====================================================================="
    echo "         OPTION 1: IE PROVISIONING — Drive Assignment                "
    echo "====================================================================="
    echo ""
    echo " Assign drives to volumes one group at a time. A single drive just"
    echo " needs a mount point; multiple drives need a RAID type/level too."
    echo " Nothing is touched yet -- you'll see the full plan and confirm it"
    echo " once before anything is built, formatted, or mounted."
    echo " Type 'done' at any drive-selection prompt to stop early (leftover"
    echo " drives are simply left unconfigured)."
    echo ""

    while true; do
        echo "[INFO] Scanning for unassigned drives..."
        _ie_discover_unclaimed_drives
        local raw_count=${#_DISCOVERED_PATHS[@]}

        if [ "$raw_count" -eq 0 ]; then
            echo ""
            echo "[INFO] No unassigned drives remain."
            break
        fi

        echo ""
        echo " Select drive(s) for the next volume. Use numbers, ranges, or 'all'."
        echo " Type 'done' to stop assigning drives."
        read -p "Selection: " sel
        [[ "${sel,,}" == "done" ]] && break

        local sel_indices=()
        _parse_selection_string "$sel" sel_indices "$raw_count"
        if [ ${#sel_indices[@]} -eq 0 ]; then
            echo "[WARN] No valid drive(s) selected — try again."
            echo ""
            continue
        fi

        if ! _confirm_drive_selection "Confirm Drives For This Volume" sel_indices; then
            echo "[INFO] Reselect the drives for this volume."
            echo ""
            continue
        fi

        local sel_paths=() idx
        for idx in "${sel_indices[@]}"; do
            sel_paths+=("${_DISCOVERED_PATHS[$((idx-1))]}")
        done
        local sel_count=${#sel_paths[@]}

        local vol_type="" vol_level="" vol_media="flash" zfs_width="" zfs_pool=""

        if [ "$sel_count" -eq 1 ]; then
            vol_type="single"
            _check_selection_media sel_paths >/dev/null
            vol_media="$SELECTION_MEDIA"
            echo ""
            echo "[INFO] Single drive selected: ${sel_paths[0]} ($(_drive_media_label "${sel_paths[0]}"))"
        else
            local hw_raid_chosen=false rt
            while true; do
                echo ""
                echo " ${sel_count} drives selected. What kind of volume will this be?"
                echo "   1) SW RAID (MDADM)"
                echo "   2) HW RAID"
                echo "   3) GRAID"
                echo "   4) ZFS pool"
                read -p "Selection (1-4): " rt
                case "$rt" in
                    4) vol_type="zfs"; break ;;
                    1) vol_type="mdadm"; break ;;
                    2)
                        echo ""
                        echo "[INFO] HW RAID is test-only in this suite — a Virtual Drive must already"
                        echo "       exist (built externally via BIOS/storcli). It cannot be created"
                        echo "       through IE Provisioning."
                        echo "[INFO] These ${sel_count} drive(s) remain available for a different"
                        echo "       assignment."
                        hw_raid_chosen=true
                        break
                        ;;
                    3) vol_type="graid"; break ;;
                    *) echo "[ERROR] Invalid choice, enter 1, 2, 3 or 4." ;;
                esac
            done
            if $hw_raid_chosen; then
                echo ""
                continue
            fi

            if ! _check_selection_media sel_paths; then
                echo "[INFO] Reselect drives of a single type for this volume."
                echo ""
                continue
            fi
            vol_media="$SELECTION_MEDIA"

            if [ "$vol_media" = "hdd" ] && [ "$vol_type" = "graid" ]; then
                echo "[ERROR] GRAID is NVMe-only -- choose SW RAID (MDADM) or ZFS for rotational drives."
                echo ""
                continue
            fi

            if ! _check_selection_numa_spread sel_paths; then
                echo "[WARN] Selection cancelled — reselect drives on a single NUMA node, or confirm to proceed anyway."
                echo ""
                continue
            fi

            # Per-element comparison, not word-split -- see the matching comment in run_mdadm_build_array.
            local sel_models=() p
            for p in "${sel_paths[@]}"; do
                get_drive_metadata "$p"
                sel_models+=("$DRIVE_MODEL")
            done
            local unique_models=() m um already
            for m in "${sel_models[@]}"; do
                already=false
                for um in "${unique_models[@]}"; do [ "$um" = "$m" ] && already=true; done
                $already || unique_models+=("$m")
            done
            if [ ${#unique_models[@]} -ne 1 ]; then
                echo "[ERROR] Mixed drive models in selection (${unique_models[*]}). Choose drives of one model."
                echo ""
                continue
            fi

            if [ "$vol_type" = "zfs" ]; then
                _zfs_prompt_vdev_level
                vol_level="$ZFS_VDEV_LEVEL"
                local zmin; zmin=$(_zfs_min_width "$vol_level")
                while true; do
                    _read_choice zfs_width "Drives per vdev (min $zmin, must divide $sel_count): "
                    case "$zfs_width" in ''|*[!0-9]*) echo "[ERROR] Enter a number."; continue ;; esac
                    [ "$zfs_width" -lt "$zmin" ] && { echo "[ERROR] $vol_level needs at least $zmin."; continue; }
                    [ $(( sel_count % zfs_width )) -ne 0 ] && { echo "[ERROR] $sel_count is not divisible by $zfs_width."; continue; }
                    break
                done
                _prompt_confirmed zfs_pool "Pool name" "Pool name for this volume (e.g. vpool): "
            else
                _prompt_raid_level "$sel_count"
                vol_level="$SELECTED_RAID_LEVEL"
            fi
        fi

        local vol_fs="zfs"
        if [ "$vol_type" != "zfs" ]; then
            while true; do
                read -p "Filesystem for this volume [ext4]: " vol_fs
                vol_fs="${vol_fs:-ext4}"
                command -v "mkfs.$vol_fs" &>/dev/null && break
                echo "[ERROR] mkfs.$vol_fs not found on this system. Try ext4, xfs, btrfs, ntfs, exfat, or vfat."
            done
        fi

        local vol_mount
        while true; do
            read -p "Mount point for this volume (mounted at root, e.g. /data, /scr): " vol_mount
            if [ -z "$vol_mount" ]; then
                echo "[ERROR] Mount point cannot be empty."
                continue
            fi
            if [[ "$vol_mount" != /* ]]; then
                echo "[ERROR] Mount point must be an absolute path (start with /)."
                continue
            fi
            local dup=false existing
            for existing in "${_IE_PLAN[@]}"; do
                [ "${existing##*|}" = "$vol_mount" ] && dup=true
            done
            if $dup; then
                echo "[ERROR] Mount point $vol_mount is already used earlier in this plan."
                continue
            fi
            break
        done

        # Review before the volume joins the plan; "n" drops back to drive selection only.
        if ! _review_entries "Review This Volume" \
                "Type        : ${vol_type}${vol_level:+ (RAID $vol_level)}" \
                "Drive(s)    : ${sel_paths[*]}" \
                "Filesystem  : $vol_fs" \
                "Mount point : $vol_mount"; then
            echo "[INFO] Volume discarded -- reselect the drives and re-enter it."
            echo ""
            continue
        fi

        local drives_csv
        if [ "$vol_type" = "zfs" ]; then
            drives_csv=$(_zfs_compose_drives_field "$zfs_width" "" "" "${sel_paths[@]}")
            vol_fs="$zfs_pool"
        else
            drives_csv=$(IFS=,; echo "${sel_paths[*]}")
        fi
        _IE_PLAN+=("${vol_type}|${vol_level}|${drives_csv}|${vol_fs}|${vol_mount}")

        echo ""
        echo "[OK] Volume queued: ${vol_type}${vol_level:+ RAID$vol_level} — ${sel_count} drive(s) — ${vol_fs} @ ${vol_mount}"
        echo ""
    done

    if [ ${#_IE_PLAN[@]} -eq 0 ]; then
        echo "[WARN] No volumes were configured."
        return 1
    fi
    return 0
}

# Prints the full plan and requires typing 'YES'. Returns 1 if not confirmed.
_ie_show_plan_preview() {
    echo ""
    echo "====================================================================="
    echo "                    IE PROVISIONING — PLAN PREVIEW                   "
    echo "====================================================================="
    local i=1 entry
    for entry in "${_IE_PLAN[@]}"; do
        local vtype vlevel vdrives_csv vfs vmount
        IFS='|' read -r vtype vlevel vdrives_csv vfs vmount <<< "$entry"
        local ndrives; ndrives=$(_plan_drive_list "$vdrives_csv" | wc -l | tr -d ' ')

        echo ""
        echo " Volume $i:"
        case "$vtype" in
            single) echo "   Type        : Single drive (no RAID)" ;;
            mdadm)  echo "   Type        : SW RAID (MDADM), RAID $vlevel" ;;
            graid)  echo "   Type        : GRAID, RAID $vlevel" ;;
            zfs)
                local zvdevs; zvdevs=$(_zfs_groups "$vdrives_csv" vdev | wc -l | tr -d ' ')
                local zwidth; zwidth=$(_zfs_groups "$vdrives_csv" vdev | head -1 | tr ',' '\n' | wc -l | tr -d ' ')
                echo "   Type        : ZFS pool '$vfs' -- $zvdevs x $vlevel vdev(s) of $zwidth drive(s)"
                ;;
        esac
        echo "   Drive(s)    : $(_plan_drive_list "$vdrives_csv" | tr '\n' ' ')($ndrives drive(s))"
        echo "   Filesystem  : $vfs (no partition table -- filesystem written directly to the device)"
        echo "   Mount point : $vmount"
        if [ "$vtype" = "single" ]; then
            echo "   Will: precondition + fio-validate this drive, then mkfs.$vfs and mount at $vmount"
        else
            echo "   Will: build a new RAID $vlevel array from these drives (DESTROYS existing"
            echo "         data on all of them), fio-validate the array, then mkfs.$vfs and"
            echo "         mount at $vmount"
        fi
        i=$((i+1))
    done
    # The last checkpoint against the paperwork -- nothing in _ie_execute_plan runs until this is accepted.
    _render_structure_mockup "${_IE_PLAN[@]}"

    echo "====================================================================="
    echo " WARNING: this DESTROYS any existing data/partitions on every drive"
    echo "          listed above, for every volume."
    echo "====================================================================="
    read -p "Type 'YES' to confirm and begin unattended provisioning + validation: " confirm
    [[ "$confirm" == "YES" ]]
}

# Shared precondition + QD step. Sets _IE_PRECOND_MODEL/_TOKEN from the first drive; $1 = paths array name.
_ie_precondition_and_qd() {
    local paths_name="$1"
    local -n _ie_paths_ref="$paths_name"

    get_drive_metadata "${_ie_paths_ref[0]}"
    _IE_PRECOND_MODEL="$DRIVE_MODEL"
    _IE_PRECOND_TOKEN="$DRIVE_MODEL_TOKEN"

    local models=() serials=() p
    for p in "${_ie_paths_ref[@]}"; do
        get_drive_metadata "$p"
        models+=("$DRIVE_MODEL")
        serials+=("$DRIVE_SERIAL")
    done

    local batch_status=()
    _precondition_drive_batch "$paths_name" models serials batch_status "$SWEEP_DIR/Logs"
    _ensure_qd_profile "${_ie_paths_ref[0]}" "$_IE_PRECOND_MODEL" "$_IE_PRECOND_TOKEN"
}

# Preconditions EVERY flash drive in the saved plan in ONE parallel batch, up front and isolated from
# the compute-stress phase. Marker-idempotent, so the per-volume _ie_precondition_and_qd calls later
# find each drive already done and skip straight to the QD sweep + fio measurement. This makes
# preconditioning wall-clock ~= the slowest single drive regardless of drive count, instead of the
# per-drive serial sum that could otherwise run for days on a many-drive system. Rotational drives are
# skipped (never preconditioned); HW-RAID volumes have no member drives of their own to precondition.
_precondition_all_plan_drives() {
    [ -s "$IE_PLAN_FILE" ] || return 0

    local -a pp_paths=() pp_models=() pp_serials=()
    local -A pp_seen=()
    local entry vtype vlevel vdrives_csv vfs vmount dev
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        IFS='|' read -r vtype vlevel vdrives_csv vfs vmount <<< "$entry"
        [ "$vtype" = "hwraid" ] && continue
        while IFS= read -r dev; do
            [ -n "$dev" ] || continue
            [ -b "$dev" ] || continue
            [ -n "${pp_seen[$dev]:-}" ] && continue          # a drive can appear in only one volume, but be safe
            [ "$(_drive_media_class "$dev")" = "hdd" ] && continue
            pp_seen[$dev]=1
            get_drive_metadata "$dev"
            pp_paths+=("$dev"); pp_models+=("$DRIVE_MODEL"); pp_serials+=("$DRIVE_SERIAL")
        done < <(_plan_drive_list "$vdrives_csv")
    done < "$IE_PLAN_FILE"

    [ "${#pp_paths[@]}" -eq 0 ] && return 0

    echo ""
    write_header "Storage Preconditioning -- all drives in parallel (isolated)"
    echo "  ${#pp_paths[@]} flash drive(s) preconditioned up front, before the compute stress: one"
    echo "  sequential job each, so they run concurrently without stealing CPU/memory from the compute"
    echo "  tests. Wall-clock is bounded by the slowest single drive, not the per-drive sum."
    mark_temp "PRECONDITION"
    local pp_status=()
    _precondition_drive_batch pp_paths pp_models pp_serials pp_status "$SWEEP_DIR/Logs"
    return 0
}

# Non-interactive GRAID creation: registers PDs, builds DG/VD. Sets _GRAID_BUILT_DEV or _GRAID_BUILD_ERROR.
_graid_build_array_core() {
    local raid_level="$1"; shift
    local paths=("$@")
    local n=${#paths[@]}
    _GRAID_BUILT_DEV=""
    _GRAID_BUILD_ERROR=""

    if ! init_graid_cmd; then
        _GRAID_BUILD_ERROR="graidctl not found. Ensure GRAID software is installed."
        return 1
    fi

    _NEWLY_REGISTERED_PD_IDS=()
    echo "[BUILD] Registering ${n} raw NVMe drive(s) as GRAID physical drives..."
    _create_pds_from_nvme paths

    MASTER_PD_IDS=("${_NEWLY_REGISTERED_PD_IDS[@]}")
    local n_selected=${#MASTER_PD_IDS[@]}
    if [ "$n_selected" -lt 2 ]; then
        _GRAID_BUILD_ERROR="Only $n_selected PD(s) registered from $n drive(s) -- need at least 2."
        return 1
    fi

    echo "[BUILD] Building GRAID RAID $raid_level array ($n_selected drives)..."
    create_graid_array "$n_selected" "$raid_level"
    local active_gdg="$NEW_GDG_DEV"
    wait_for_graid_ready "$active_gdg"

    local active_gdg_name
    active_gdg_name=$(basename "$active_gdg" | grep -oE 'gdg[0-9]+')
    if ! inspect_vd_for_device "$active_gdg_name"; then
        _GRAID_BUILD_ERROR="Could not inspect VD for $active_gdg."
        return 1
    fi
    if ! get_dg_info "$CURRENT_DG_ID"; then
        _GRAID_BUILD_ERROR="Could not read Drive Group $CURRENT_DG_ID."
        return 1
    fi

    echo " [SUCCESS] GRAID array built: $active_gdg (DG $CURRENT_DG_ID / VD $CURRENT_VD_ID, RAID $DG_RAID_LEVEL, $DG_PD_COUNT drives)"
    _GRAID_BUILT_DEV="$active_gdg"
    return 0
}

# Formats and mounts: UUID fstab entry with nofail, timestamped backup, findmnt verification, no partition table.
_ie_format_and_mount() {
    local dev_path="$1" fs_type="$2" mount_point="$3"
    _IE_FORMAT_ERROR=""

    if ! command -v "mkfs.$fs_type" &>/dev/null; then
        _IE_FORMAT_ERROR="mkfs.$fs_type not available on this system."
        return 1
    fi

    echo "[FORMAT] Formatting $dev_path as $fs_type..."
    local mkfs_ok=false
    case "$fs_type" in
        ext4)       mkfs.ext4 -F "$dev_path" && mkfs_ok=true ;;
        xfs)        mkfs.xfs -f "$dev_path" && mkfs_ok=true ;;
        btrfs)      mkfs.btrfs -f "$dev_path" && mkfs_ok=true ;;
        ntfs)       mkfs.ntfs -f -Q "$dev_path" && mkfs_ok=true ;;
        exfat)      mkfs.exfat "$dev_path" && mkfs_ok=true ;;
        vfat|fat32) mkfs.vfat -F 32 "$dev_path" && mkfs_ok=true ;;
        *)
            _IE_FORMAT_ERROR="Unsupported filesystem type: $fs_type"
            return 1
            ;;
    esac
    if [ "$mkfs_ok" != true ]; then
        _IE_FORMAT_ERROR="mkfs.$fs_type failed for $dev_path."
        return 1
    fi

    mkdir -p "$mount_point"

    local uuid; uuid=$(blkid -s UUID -o value "$dev_path")
    if [ -z "$uuid" ]; then
        _IE_FORMAT_ERROR="Could not resolve UUID for $dev_path after formatting."
        return 1
    fi

    local fstab_type="$fs_type" fsck_pass=2
    [ "$fs_type" = "ntfs" ] && fstab_type="ntfs-3g"
    case "$fs_type" in
        ntfs|exfat|vfat|fat32) fsck_pass=0 ;;
    esac

    umount "$dev_path" 2>/dev/null || true
    umount "$mount_point" 2>/dev/null || true

    if [ -n "$NOOS_MODE" ]; then
        # NoOS: the OS lives in a RAM overlay (fstab is discarded at reboot) and every drive is wiped
        # at teardown, so a persistent fstab entry serves no purpose. Worse, if a run is interrupted
        # before teardown, its leftover stale-UUID line makes `mount <mp>` a nofail no-op on the next
        # run (silent Volume-mount failure). Mount the device directly -- this is only a functional
        # "can it be formatted and mounted?" check; the fio validation already ran on the raw device.
        if ! mount "$dev_path" "$mount_point"; then
            _IE_FORMAT_ERROR="mount $dev_path -> $mount_point failed."
            return 1
        fi
    else
        cp /etc/fstab "/etc/fstab.bak_$(date +%Y%m%d_%H%M%S)"
        # Idempotent: drop any prior entry for this mount point or device before appending, so
        # re-provisioning the same mount point can never leave a duplicate or stale line behind.
        local fstab_tmp; fstab_tmp=$(mktemp)
        awk -v mp="$mount_point" -v dev="$dev_path" '$2 != mp && $1 != dev' /etc/fstab > "$fstab_tmp" \
            && cat "$fstab_tmp" > /etc/fstab
        rm -f "$fstab_tmp"
        echo "UUID=$uuid $mount_point $fstab_type defaults,nofail 0 $fsck_pass" >> /etc/fstab
        if ! mount "$mount_point"; then
            _IE_FORMAT_ERROR="mount $mount_point failed after the fstab entry was written -- check /etc/fstab manually."
            return 1
        fi
    fi
    if ! findmnt "$mount_point" &>/dev/null; then
        _IE_FORMAT_ERROR="$mount_point does not show as mounted after mount succeeded -- verify manually."
        return 1
    fi

    echo " [SUCCESS] $dev_path formatted ($fs_type) and mounted at $mount_point (UUID=$uuid)."
    return 0
}

# Executes a confirmed plan with no prompts: build, validate the RAW device (O_DIRECT), format, mount. Returns failures.
_ie_execute_plan() {
    local -n _plan_ref="$1"
    local total=${#_plan_ref[@]}
    local failures=0 vol_num=1

    get_cpu_threads

    local entry
    for entry in "${_plan_ref[@]}"; do
        local vtype vlevel vdrives_csv vfs vmount
        IFS='|' read -r vtype vlevel vdrives_csv vfs vmount <<< "$entry"
        local vdrives=()
        IFS=',' read -ra vdrives <<< "$vdrives_csv"

        echo ""
        echo "====================================================================="
        echo " VOLUME $vol_num/$total — type=$vtype ${vlevel:+RAID$vlevel} drives=${#vdrives[@]} mount=$vmount"
        echo "====================================================================="

        local target_dev="" array_id="" raid_type_for_fio="" is_parity=false

        # Media is derived from the drives at execution time, not stored in the plan -- a saved
        # plan stays valid across a drive swap, and older plans have no media field to read.
        local vol_devs=() _vd
        while IFS= read -r _vd; do [ -n "$_vd" ] && vol_devs+=("$_vd"); done < <(_plan_drive_list "$vdrives_csv")
        if ! _check_selection_media vol_devs; then
            echo "[FAIL] Volume $vol_num: mixes flash and rotational drives."
            failures=$((failures+1)); vol_num=$((vol_num+1)); continue
        fi

        case "$vtype" in
            single)
                target_dev="${vdrives[0]}"
                array_id=$(basename "$target_dev")
                raid_type_for_fio="SINGLE"
                if ! _media_is_hdd; then
                    _ie_precondition_and_qd vdrives
                    _load_qd_profile "$_IE_PRECOND_TOKEN" 1
                    DRIVE_MODEL="$_IE_PRECOND_MODEL"
                fi
                DRIVE_COUNT=1
                ;;
            mdadm)
                _media_is_hdd || _ie_precondition_and_qd vdrives
                if ! _mdadm_build_array_core "$vlevel" "${vdrives[@]}"; then
                    echo "[FAIL] Volume $vol_num: $_MDADM_BUILD_ERROR"
                    failures=$((failures+1)); vol_num=$((vol_num+1)); continue
                fi
                target_dev="$_MDADM_BUILT_DEV"
                array_id=$(basename "$target_dev")
                raid_type_for_fio="MDADM"
                [[ "$vlevel" == "5" || "$vlevel" == "6" ]] && is_parity=true
                _wait_for_mdadm_idle "$array_id"
                DRIVE_MODEL="$_IE_PRECOND_MODEL"
                DRIVE_COUNT=${#vdrives[@]}
                _media_is_hdd || _load_qd_profile "$_IE_PRECOND_TOKEN" "${#vdrives[@]}"
                ;;
            zfs)
                if ! _zfs_ensure_installed; then
                    echo "[FAIL] Volume $vol_num: ZFS is not available on this system."
                    failures=$((failures+1)); vol_num=$((vol_num+1)); continue
                fi
                if ! _media_is_hdd; then
                    _ie_precondition_and_qd vol_devs
                fi
                if ! _zfs_build_pool_core "$vfs" "$vlevel" "$vdrives_csv" "$vmount"; then
                    echo "[FAIL] Volume $vol_num: $_ZFS_BUILD_ERROR"
                    failures=$((failures+1)); vol_num=$((vol_num+1)); continue
                fi
                echo "[OK] Volume $vol_num complete: pool $vfs -> $vmount"
                if _media_is_hdd; then
                    _hdd_health_validation "zfs-${vfs}" "${vol_devs[@]}"
                fi
                _show_drive_structure "Structure After Volume $vol_num (pool $vfs -> $vmount)"
                vol_num=$((vol_num+1)); continue
                ;;
            graid)
                if _media_is_hdd; then
                    echo "[FAIL] Volume $vol_num: GRAID is NVMe-only, but these drives are rotational."
                    failures=$((failures+1)); vol_num=$((vol_num+1)); continue
                fi
                _ie_precondition_and_qd vdrives
                if ! _graid_build_array_core "$vlevel" "${vdrives[@]}"; then
                    echo "[FAIL] Volume $vol_num: $_GRAID_BUILD_ERROR"
                    failures=$((failures+1)); vol_num=$((vol_num+1)); continue
                fi
                target_dev="$_GRAID_BUILT_DEV"
                array_id=$(basename "$target_dev")
                raid_type_for_fio="GRAID"
                DRIVE_MODEL="$_IE_PRECOND_MODEL"
                DRIVE_COUNT=${#vdrives[@]}
                _media_is_hdd || _load_qd_profile "$_IE_PRECOND_TOKEN" "${#vdrives[@]}"
                ;;
        esac

        if _media_is_hdd; then
            echo ""
            echo "[VALIDATE] Rotational media -- SMART health only, no performance test."
            _hdd_health_validation "ie-vol${vol_num}" "${vol_devs[@]}"
        else
            echo ""
            echo "[VALIDATE] Running fio validation against $target_dev..."
            pushd "$RESULTS_DIR" > /dev/null
            execute_and_summarize_fio "$target_dev" "$array_id" "$FINAL_JOBS" "$FINAL_DEPTH" "$raid_type_for_fio" "$is_parity"
            popd > /dev/null
            echo "[VALIDATE] Report: $RESULTS_DIR/fio_${array_id}.txt"
        fi

        echo ""
        echo "[PROVISION] Validation complete — formatting and mounting $target_dev..."
        if ! _ie_format_and_mount "$target_dev" "$vfs" "$vmount"; then
            echo "[FAIL] Volume $vol_num: $_IE_FORMAT_ERROR"
            failures=$((failures+1))
        else
            echo "[OK] Volume $vol_num complete: $target_dev -> $vmount ($vfs)"
            _show_drive_structure "Structure After Volume $vol_num ($target_dev -> $vmount)"
        fi

        vol_num=$((vol_num+1))
    done

    echo ""
    echo "====================================================================="
    echo " IE PROVISIONING COMPLETE — $((total-failures))/$total volume(s) succeeded"
    echo "====================================================================="

    # Informational only -- the structure was confirmed as a projection before any of this ran.
    _show_drive_structure "FINAL — Actual Drive Structure (compare against the projection)"
    return "$failures"
}

# --- IE Provisioning collect-now / execute-later: pipe-delimited plan entries round-trip through a flat file. ---

# Interactive: collect the drive/RAID/filesystem/mount plan and save it WITHOUT executing.
ie_collect_and_save_plan() {
    write_header "Configure Storage (IE Provisioning)"
    echo ""
    echo "  1) Automatic  -- every drive as its own ext4 volume, mounted /data1../dataN"
    echo "                   (NVMe first, then SATA/SAS; scales to any drive count)"
    echo "  2) Guided     -- assign drives to volumes, pick RAID/ZFS, filesystem, mount points"
    echo ""
    local c
    while true; do
        _read_choice c "Enter selection [1-2]: "
        case "$c" in
            1) _ie_save_all_data_plan; return $? ;;
            2) _ie_collect_and_save_guided; return $? ;;
            *) echo "Please enter 1 or 2." ;;
        esac
    done
}

# Automatic layout: one ext4 volume per drive, /data1../dataN in device order, preview, then save.
_ie_save_all_data_plan() {
    echo ""
    echo "[INFO] Scanning for available drives..."
    if ! _build_all_drives_data_plan; then
        echo "[WARN] No raw, unmounted, non-root drives found -- nothing to configure."
        return 1
    fi
    if ! _ie_show_plan_preview; then
        echo ""
        echo "[INFO] Plan not confirmed -- nothing saved."
        [ -f "$IE_PLAN_FILE" ] && echo "       An existing saved plan at $IE_PLAN_FILE was left untouched."
        return 1
    fi
    _ie_save_plan_file
    return 0
}

# Guided layout: the manual, one-volume-at-a-time assignment flow.
_ie_collect_and_save_guided() {
    _IE_PLAN=()
    # Rejecting the preview re-opens collection -- the point of a preview is to lead somewhere.
    local _ie_ok=1
    while _ie_collect_plan; do
        if _ie_show_plan_preview; then _ie_ok=0; break; fi
        echo ""
        echo "[INFO] Plan not confirmed -- starting drive assignment over. Nothing has been touched."
        _IE_PLAN=()
    done
    if [ "$_ie_ok" -eq 0 ]; then
        _ie_save_plan_file
        return 0
    else
        echo ""
        echo "[INFO] No volumes configured or plan not confirmed — nothing saved."
        [ -f "$IE_PLAN_FILE" ] && echo "       An existing saved plan at $IE_PLAN_FILE was left untouched."
        return 1
    fi
}

# Shared save: writes _IE_PLAN to the plan file with the standard success message.
_ie_save_plan_file() {
    mkdir -p "$(dirname "$IE_PLAN_FILE")"
    printf '%s\n' "${_IE_PLAN[@]}" > "$IE_PLAN_FILE"
    chown "$REAL_USER:$REAL_USER" "$IE_PLAN_FILE" 2>/dev/null
    echo ""
    echo "[SUCCESS] Storage plan saved to $IE_PLAN_FILE (${#_IE_PLAN[@]} volume(s))."
    echo "          This will be provisioned automatically the next time"
    echo "          Hardware Validation > 'Combined' or 'Sequential' runs."
}

# Non-interactive: loads a saved plan and executes it. A missing plan file is a normal SKIP.
ie_load_and_execute_plan() {
    if [ ! -s "$IE_PLAN_FILE" ]; then
        vrecord "STORAGE" "SKIP" "no saved storage plan at $IE_PLAN_FILE"
        return 0
    fi
    # Only pay for template verification and thread detection when there is actually a plan.
    get_cpu_threads
    verify_environment_templates
    mapfile -t _IE_PLAN < "$IE_PLAN_FILE"

    # Re-project a saved plan against the drives present now; skipped with no terminal (unattended resume).
    # IE_PLAN_PRECONFIRMED means a detaching caller already asked this while it still had a terminal.
    if [ -t 0 ] && [ -z "$IE_PLAN_PRECONFIRMED" ]; then
        echo ""
        echo "[INFO] A saved storage plan exists and is about to be provisioned."
        if ! _confirm_projected_structure "${_IE_PLAN[@]}"; then
            vrecord "STORAGE" "SKIP" "saved plan not confirmed at run time — no drive was touched"
            return 0
        fi
    fi

    vlog "━━━ STORAGE: build/validate/format/mount (from saved plan, ${#_IE_PLAN[@]} volume(s)) ━━━"
    mark_temp "STORAGE"
    _ie_execute_plan _IE_PLAN
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        vrecord "STORAGE" "FAIL" "$rc volume(s) failed — see $RESULTS_DIR"
    elif [ -n "$QD_UNCALIBRATED_MODELS" ]; then
        vrecord "STORAGE" "REVIEW" "provisioned + tested, but uncalibrated (no QD profile for:$QD_UNCALIBRATED_MODELS) — review $RESULTS_DIR by hand"
    else
        vrecord "STORAGE" "PASS" "all volumes provisioned + validated — see $RESULTS_DIR"
    fi
}

# Executes the in-memory _IE_PLAN[] from the storage menu, as opposed to the saved-to-disk path.
run_fio_ie() {
    vlog "━━━ STORAGE: build/validate/format/mount ━━━"
    mark_temp "STORAGE"
    if [ ${#_IE_PLAN[@]} -eq 0 ]; then
        vrecord "STORAGE" "SKIP" "no provisioning plan available"
        return
    fi
    _ie_execute_plan _IE_PLAN
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        vrecord "STORAGE" "FAIL" "$rc volume(s) failed — see $RESULTS_DIR"
    elif [ -n "$QD_UNCALIBRATED_MODELS" ]; then
        vrecord "STORAGE" "REVIEW" "provisioned + tested, but uncalibrated (no QD profile for:$QD_UNCALIBRATED_MODELS) — review $RESULTS_DIR by hand"
    else
        vrecord "STORAGE" "PASS" "all volumes provisioned + validated — see $RESULTS_DIR"
    fi
}

# Storage topology menu; its 5th entry exposes IE Provisioning standalone, without a full burn-in.
run_storage_topology_menu() {
    while true; do
        clear
        echo "====================================================================="
        echo "                    STORAGE / RAID VALIDATION                        "
        echo "====================================================================="
        echo "  1) Single Drive Testing — Multi-select supported, tested"
        echo "                            simultaneously. Preconditioning and QD"
        echo "                            calibration run automatically."
        echo "  2) SW RAID (MDADM)      — Build Array(s) (choose RAID 0/1/5/6/10)"
        echo "                            / Test Array(s) submenu"
        echo "  3) HW RAID Testing      — Tests an existing VD; preconditioning"
        echo "                            and QD calibration run automatically."
        echo "  4) GRAID Validation     — Build Array(s) (choose RAID 0/1/5/6/10)"
        echo "                            / Test Array(s) submenu"
        echo "  5) ZFS Validation       — Build Pool (raidz1/2/3, mirror, stripe"
        echo "                            + hot spares + L2ARC) / Destroy /"
        echo "                            Test Pool(s) submenu"
        echo "  6) IE Provisioning      — Guided multi-volume drive/RAID/"
        echo "                            filesystem/mount-point setup"
        echo "  Q) Back to Main Menu"
        echo "====================================================================="
        _read_choice menu_input "Enter selection (1-6, or Q to go Back): "

        case "$menu_input" in
            1) run_single_drive_testing ;;
            2) run_mdadm_raid_menu ;;
            3) run_hw_raid_testing ;;
            4) run_graid_menu ;;
            5) run_zfs_menu ;;
            6)
                _IE_PLAN=()
                if _ie_collect_plan && _ie_show_plan_preview; then
                    run_fio_ie
                    pause_to_menu
                else
                    pause_to_menu "No volumes configured or plan not confirmed — nothing provisioned."
                fi
                ;;
            [Qq]) return ;;
            *)
                echo -e "\n[ERROR] Invalid entry choice: Selection parameter error."
                read -p "You can only select options 1-6 or Q to go back. Press [Enter] to try again..."
                ;;
        esac
    done
}

# --- 10. USER OPERATIONS ---

# --- QA Validation Report: identity -> inventory -> RAID/network -> software; absent hardware is omitted entirely. ---

# _qa_result_line <label> <RESULTS-key...> -- first matching entry, colored by verdict, else "not yet tested".
_qa_result_line() {
  local label="$1"; shift
  local key val body logpath
  for key in "$@"; do
    if [ -n "${RESULTS[$key]+x}" ]; then
      val="${RESULTS[$key]}"
      # Every evaluator appends " -- see <path>"; split it back out as its own indented "Log:" line.
      if [[ "$val" == *" -- see "* ]]; then
        body="${val% -- see *}"
        logpath="${val##* -- see }"
      else
        body="$val"
        logpath=""
      fi
      # A report can be a patchwork of sessions, so stamp every line with when it was produced.
      [ -n "${RESULTS_TS[$key]:-}" ] && body="$body  (as of ${RESULTS_TS[$key]})"
      case "$body" in
        PASS*) printf '  %-28s %s%s%s\n' "$label" "$TXT_GRN" "$body" "$RESET" ;;
        WARN*)   printf '  %-28s %s%s%s\n' "$label" "$TXT_YLW" "$body" "$RESET" ;;
        REVIEW*) printf '  %-28s %s%s%s\n' "$label" "$TXT_YLW" "$body" "$RESET" ;;
        FAIL*) printf '  %-28s %s%s%s\n' "$label" "$TXT_RED" "$body" "$RESET" ;;
        *)     printf '  %-28s %s\n' "$label" "$body" ;;
      esac
      # The log excerpt behind this verdict, present only when the check called vrecord_evidence.
      local evidence_file="${VAL_LOGDIR:-}/evidence/${key}.txt"
      if [ -s "$evidence_file" ]; then
        printf '  %-28s\n' "    Evidence:"
        sed 's/^/      /' "$evidence_file"
      fi
      [ -n "$logpath" ] && printf '  %-28s %s\n' "    Log:" "$logpath"
      return 0
    fi
  done
  printf '  %-28s %s(not yet tested)%s\n' "$label" "$TXT_YLW" "$RESET"
  return 1
}

_qa_section() {
  printf '\n%s#=======================================================================#%s\n' "$TXT_BLU" "$RESET"
  printf '%s# %-69s #%s\n' "$TXT_BLU" "$1" "$RESET"
  printf '%s#=======================================================================#%s\n' "$TXT_BLU" "$RESET"
}

# One line per POPULATED DIMM, so empty slots aren't counted; one parse feeds both count and display.
_qa_memory_summary() {
  dmidecode -t memory 2>/dev/null | awk -v RS="" -F"\n" '
    /Memory Device/ {
      size=""; type=""; speed=""; cspeed=""
      for (i=1;i<=NF;i++) {
        line=$i
        if (line ~ /^[ \t]*Size:/)                          { sub(/^[ \t]*Size:[ \t]*/,"",line); size=line }
        else if (line ~ /^[ \t]*Type:/)                      { sub(/^[ \t]*Type:[ \t]*/,"",line); type=line }
        else if (line ~ /^[ \t]*Speed:/)                     { sub(/^[ \t]*Speed:[ \t]*/,"",line); speed=line }
        else if (line ~ /^[ \t]*Configured Memory Speed:/)   { sub(/^[ \t]*Configured Memory Speed:[ \t]*/,"",line); cspeed=line }
      }
      if (size != "" && size !~ /No Module Installed/) print size "\t" type "\t" speed "\t" cspeed
    }
  '
}

# Per-GPU peaks across the whole window, spanning DCGM and gpu-burn: idx, clock, temp, power, PCIe gen.
_qa_gpu_peaks() {
  [ -n "$GPU_TEMP_LOG" ] && [ -s "$GPU_TEMP_LOG" ] || return 1
  grep '^\[' "$GPU_TEMP_LOG" 2>/dev/null | sed 's/^\[[^]]*\] //' | awk -F', *' '
    {
      idx=$1; t=$3+0; c=$4+0; p=$5+0; g=$6+0
      if (!(idx in seen) || t>tmax[idx]) tmax[idx]=t
      if (!(idx in seen) || c>cmax[idx]) cmax[idx]=c
      if (!(idx in seen) || p>pmax[idx]) pmax[idx]=p
      if (!(idx in seen) || g>gmax[idx]) gmax[idx]=g
      seen[idx]=1
    }
    END { for (i in seen) printf "%s\t%s\t%s\t%s\t%s\n", i, cmax[i], tmax[i], pmax[i], gmax[i] }
  ' | sort -n
}

# Per-GPU PCIe WIDTH check, deliberately not generation: speed downshifts at idle and would false-positive.
_qa_gpu_pcie_check() {
  local downtrained="" idx w_cur w_max
  while IFS=',' read -r idx w_cur w_max; do
    idx=$(echo "$idx" | xargs); w_cur=$(echo "$w_cur" | xargs); w_max=$(echo "$w_max" | xargs)
    [ -z "$idx" ] && continue
    [ "$w_cur" != "$w_max" ] && downtrained+="GPU${idx}(x${w_cur} of x${w_max}) "
  done < <(nvidia-smi --query-gpu=index,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits 2>/dev/null)
  if [ -n "$downtrained" ]; then
    vrecord "PCIE_LINK" "WARN" "downtrained PCIe link width: ${downtrained}-- check card seating/riser, or confirm slot is intentionally bifurcated"
    vrecord_evidence "PCIE_LINK" "downtrained: $downtrained"
  else
    vrecord "PCIE_LINK" "PASS" "all GPUs linked at full negotiated PCIe width"
  fi
}

# Peak CPU power (summed across sockets) and peak core clock. Prints "peak<TAB>peak_mhz".
_qa_cpu_peaks() {
  [ -n "$CPU_PWR_LOG" ] && [ -s "$CPU_PWR_LOG" ] || return 1
  local pwr_peak mhz_peak
  pwr_peak=$(grep -oP 'POWER_W=\K[\d.]+' "$CPU_PWR_LOG" 2>/dev/null | sort -rn | head -1)
  mhz_peak=$(grep -oP 'MAX_MHZ=\K[\d.]+' "$CPU_PWR_LOG" 2>/dev/null | sort -rn | head -1)
  [ -z "$pwr_peak" ] && [ -z "$mhz_peak" ] && return 1
  printf '%s\t%s\n' "${pwr_peak:-n/a}" "${mhz_peak:-n/a}"
}

# Peak temp PER DIMM SLOT, not one pooled max, so a specific marginal module is identifiable.
_qa_mem_peaks() {
  [ -n "$MEM_TEMP_LOG" ] && [ -s "$MEM_TEMP_LOG" ] || return 1
  awk -F'\\|' '
    {
      n = split($1, a, "TEMP_DDR")
      if (n < 2) next
      split(a[2], b, "_")
      slot = b[2]
      gsub(/^[ \t]+|[ \t]+$/, "", slot)
      if (slot == "") next
      split($2, w, " ")
      t = w[1] + 0
      if (!(slot in seen) || t > tmax[slot]) tmax[slot] = t
      seen[slot] = 1
    }
    END { for (s in seen) printf "%s\t%s\n", s, tmax[s] }
  ' "$MEM_TEMP_LOG" | sort
}

# POWER SUPPLY section -- CPU/GPU peak power consolidated here, plus system-wide and per-PSU draw.
_qa_power_supply_section() {
  _qa_section "POWER SUPPLY"

  local cpu_peaks cpu_pwr_peak cpu_mhz_peak
  if cpu_peaks=$(_qa_cpu_peaks); then
    IFS=$'\t' read -r cpu_pwr_peak cpu_mhz_peak <<< "$cpu_peaks"
    echo "  CPU Peak Power:   ${cpu_pwr_peak}W"
    echo "  CPU Peak Clock:   ${cpu_mhz_peak} MHz"
  else
    echo "  CPU Peak Power:   (no samples captured)"
  fi

  if _qa_gpu_peaks >/tmp/.qa_pwr_gpu_peaks.$$ 2>/dev/null && [ -s /tmp/.qa_pwr_gpu_peaks.$$ ]; then
    echo "  GPU Peak Power (TDP, per GPU):"
    awk -F'\t' '{printf "    GPU %-2s  Peak Power: %-6s W\n", $1, $4}' /tmp/.qa_pwr_gpu_peaks.$$
  fi
  rm -f /tmp/.qa_pwr_gpu_peaks.$$

  if [ ! -s "$PSU_PWR_LOG" ]; then
    echo "  No PSU power telemetry available on this platform (no IPMI PWR_PSU sensors found -- expected on desktop workstations, which typically have no BMC)."
    return
  fi

  # The single sample with the highest TOTAL_W plus its per-PSU breakdown -- a real snapshot, not maxed columns.
  # Deliberately NOT compared against a rated capacity: that is an engineer's call, and a bottom-up
  # component rollup would mislead anyway (VRM loss, fans, drives and the board draw power no sensor sees).
  local peak_line peak_ts peak_total
  peak_line=$(awk -F'TOTAL_W=' '{printf "%s\t%s\n", $2+0, $0}' "$PSU_PWR_LOG" | sort -rn | head -1 | cut -f2-)
  peak_ts=$(echo "$peak_line" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
  peak_total=$(echo "$peak_line" | grep -oP 'TOTAL_W=\K[\d.]+')
  echo "  System Peak Power (sum of PSU AC input):  ${peak_total:-n/a}W  (at $peak_ts)"
  echo "$peak_line" | grep -oP 'PSU\d+=[\d.]+' | while IFS= read -r p; do
    echo "    $p" | sed 's/PSU/PSU /; s/=/W: /'
  done
  echo "  Full per-tick power log (for manual PSU-max verification):  $PSU_PWR_LOG"
}

generate_qa_report() {
  # Guarantees $VAL_LOGDIR exists and results are loaded even when reached standalone. Idempotent.
  _init_validation_paths
  local host serial report_file report_body
  host=$(hostname)
  # The confirmed SN names the file and fills the report field -- our systems are searched by SN.
  serial="$(_system_sn)"
  # Absolute, not cwd-relative, so the report always lands somewhere known.
  report_file="$REAL_HOME/${serial}_qa-validation.txt"

  report_body=$(
    printf '%s#=======================================================================#%s\n' "$TXT_GRN" "$RESET"
    printf '%sQA VALIDATION REPORT -- %s -- %s%s\n' "$TXT_GRN" "$host" "$(date '+%Y-%m-%d %H:%M:%S')" "$RESET"
    printf '%s#=======================================================================#%s\n' "$TXT_GRN" "$RESET"

    # ============================= SYSTEM SUMMARY =============================
    _qa_section "SYSTEM SUMMARY"
    echo "  Hostname:         $host"
    echo "  Serial Number:    $serial"
    # Trimmed before the emptiness check -- dmidecode returns spaces, not empty, for an unset asset tag.
    local asset_tag; asset_tag=$(dmidecode -s chassis-asset-tag 2>/dev/null | head -1 | sed 's/^[ \t]*//;s/[ \t]*$//')
    [ -n "$asset_tag" ] && [ "$asset_tag" != "Not Specified" ] && echo "  Asset Tag:        $asset_tag"
    # Workstation vs server is a build decision the customer receives -- record what shipped.
    [ -n "$SYSTEM_TYPE" ] && echo "  System Type:      $SYSTEM_TYPE (boots to $(systemctl get-default 2>/dev/null))"
    # OS/Kernel are baseline attributes, not deliberately-installed software.
    ( . /etc/os-release 2>/dev/null; echo "  OS:               ${PRETTY_NAME:-unknown}" )
    echo "  Kernel:           $(uname -r)"
    echo "  Report Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    if [ ${#RESULTS[@]} -gt 0 ]; then
      local overall="PASS" phase
      for phase in "${!RESULTS[@]}"; do
        case "${RESULTS[$phase]}" in
          FAIL*) overall="FAIL" ;;
          WARN*) [ "$overall" = "PASS" ] && overall="CONDITIONAL -- review needed" ;;
        esac
      done
      case "$overall" in
        PASS) printf '  Overall Result:   %sPASS%s\n' "$TXT_GRN" "$RESET" ;;
        FAIL) printf '  Overall Result:   %sFAIL%s\n' "$TXT_RED" "$RESET" ;;
        *)    printf '  Overall Result:   %s%s%s\n' "$TXT_YLW" "$overall" "$RESET" ;;
      esac
      echo "  (Determined from raw PASS/FAIL/WARN results only -- final disposition still requires engineer sign-off)"
    else
      echo "  Overall Result:   (no tests run yet this session)"
    fi

    # Motherboard & BIOS come before BMC/IPMI.
    _qa_section "MOTHERBOARD & BIOS"
    # dmidecode prefixes field lines with a literal TAB -- replace it, don't indent ahead of it.
    dmidecode -t baseboard 2>/dev/null | grep -E 'Manufacturer|Product Name' | sed 's/^\t/  /'
    # Baseboard Version (hardware revision) vs BIOS Version (firmware); baseboard is often blank, so omitted.
    local board_version; board_version=$(dmidecode -t baseboard 2>/dev/null | awk -F': ' '/^[ \t]*Version:/{print $2; exit}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    [ -n "$board_version" ] && [ "$board_version" != "Not Specified" ] && echo "  Board Version:    $board_version"
    dmidecode -t bios 2>/dev/null | grep -E 'Vendor' | sed 's/^\t/  /'
    local bios_version; bios_version=$(dmidecode -t bios 2>/dev/null | awk -F': ' '/^[ \t]*Version:/{print $2; exit}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    [ -n "$bios_version" ] && echo "  BIOS Version:     $bios_version"
    dmidecode -t bios 2>/dev/null | grep -E 'Release Date' | sed 's/^\t/  /'

    # BMC/IPMI -- entire section omitted if no BMC present
    if ipmitool mc info &>/dev/null; then
      _qa_section "BMC / IPMI"
      ipmitool mc info 2>/dev/null | grep -E 'Firmware Revision|IPMI Version' | sed 's/^/  /'
      local ipmi_mac; ipmi_mac=$(ipmitool lan print 2>/dev/null | grep "MAC Address")
      [ -n "$ipmi_mac" ] && echo "  $ipmi_mac"
    fi

    # ======================= HARDWARE DETAILS & PASS/FAIL =======================
    _qa_section "CPU"
    # Anchored to line start: unanchored also matched "BIOS Model name:" and "CPU(s) scaling MHz:".
    lscpu 2>/dev/null | grep -E '^Model name|^Socket|^Thread|^NUMA node|^CPU\(s\):' | sed 's/^/  /'
    _qa_result_line "CPU Test Result:" "MPRIME-CONCURRENT" "MPRIME"
    # check_temps() records this every run but it was never shown in the report.
    _qa_result_line "CPU Temp:" "CPU_TEMP"

    _qa_section "MEMORY"
    local dimm_specs dimm_count
    dimm_specs=$(_qa_memory_summary)
    dimm_count=$(printf '%s\n' "$dimm_specs" | grep -c .)
    echo "  DIMMs Populated:  $dimm_count"
    dmidecode -t memory 2>/dev/null | grep 'Error Correction Type:' | head -1 | sed 's/^\t/  /'
    if [ "$dimm_count" -gt 0 ]; then
      local uniq_specs uniq_count
      uniq_specs=$(printf '%s\n' "$dimm_specs" | sort -u)
      uniq_count=$(printf '%s\n' "$uniq_specs" | grep -c .)
      if [ "$uniq_count" -eq 1 ]; then
        # Identical DIMMs collapse into one block; rated Expected Speed and actual Configured Speed stay separate.
        printf '%s\n' "$uniq_specs" | awk -F'\t' -v n="$dimm_count" '{
          printf "      Size:                     %s  (all %s populated DIMMs)\n", $1, n
          printf "      Type:                     %s\n", $2
          printf "      Expected Speed:           %s\n", $3
          printf "      Configured Memory Speed:  %s\n", $4
        }'
      else
        echo "  DIMMs are not uniform -- per-module breakdown:"
        printf '%s\n' "$dimm_specs" | awk -F'\t' '{printf "      DIMM %02d:  Size=%s  Type=%s  ExpectedSpeed=%s  ConfiguredSpeed=%s\n", NR, $1, $2, $3, $4}'
      fi
    fi
    free -h | grep -i mem | awk '{print "  Total Memory:     "$2}'
    _qa_result_line "Memory Test Result:" "MEMORY-CONCURRENT" "MEMORY"
    # Full per-slot breakdown, so a specific hot module is visible, not just the worst-DIMM figure.
    if _qa_mem_peaks >/tmp/.qa_mem_peaks.$$ 2>/dev/null && [ -s /tmp/.qa_mem_peaks.$$ ]; then
      echo "  DIMM Peak Temps (captured throughout the run):"
      awk -F'\t' '{printf "    DIMM %-4s  Temp Peak: %sC\n", $1, $2}' /tmp/.qa_mem_peaks.$$
    fi
    rm -f /tmp/.qa_mem_peaks.$$
    _qa_result_line "Memory Temp:" "MEM_TEMP"
    check_edac
    _qa_result_line "EDAC ECC Check:" "EDAC"

    # GPU -- entire section omitted if no NVIDIA GPU present
    if command -v nvidia-smi &>/dev/null && [ -n "$(nvidia-smi -L 2>/dev/null)" ]; then
      _qa_section "GPU"
      # The NVIDIA driver belongs with the hardware it drives, not under software installations.
      echo "  NVIDIA Driver:    $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
      # Just enough to answer "which physical GPU is which" -- memory and driver version appear elsewhere.
      echo "  GPU Inventory (ID, Model, Serial Number, PCIe Address):"
      nvidia-smi --query-gpu=index,name,serial,pci.bus_id --format=csv,noheader 2>/dev/null | sed 's/^/  /'
      echo "  --- nvidia-smi ---"
      nvidia-smi 2>/dev/null | sed 's/^/  /'
      local gpu_peaks_file="/tmp/.qa_gpu_peaks.$$"
      if _qa_gpu_peaks > "$gpu_peaks_file" 2>/dev/null && [ -s "$gpu_peaks_file" ]; then
        # Gen Peak lives with the PCIe Width reading below, where it reads more naturally.
        echo "  GPU Peak Clock / Peak Temp (captured across DCGM + GPU-Burn):"
        awk -F'\t' '{printf "    GPU %-2s  Clock Peak: %-6s MHz   Temp Peak: %-3sC\n", $1, $2, $3}' "$gpu_peaks_file" | sed 's/^/  /'
      fi
      # Width from a live query (fixed at link training); Gen is the highest observed DURING the run.
      nvidia-smi --query-gpu=index,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits 2>/dev/null \
        | awk -F', *' -v peaks="$gpu_peaks_file" '
            BEGIN {
              while ((getline line < peaks) > 0) {
                split(line, f, "\t")
                genpeak[f[1]] = f[5]
              }
            }
            {
              idx=$1; wc=$2; wm=$3
              gp = (idx in genpeak) ? genpeak[idx] : "n/a"
              printf "  GPU %-2s  PCIe Width: x%-3s (max x%s)   Gen Peak (under load): %s\n", idx, wc, wm, gp
            }'
      rm -f "$gpu_peaks_file"
      _qa_gpu_pcie_check
      _qa_result_line "PCIe Link Width Check:" "PCIE_LINK"
      _qa_result_line "GPU-Burn Test Result:" "GPU-BURN-CONCURRENT" "GPU-BURN"
      _qa_result_line "GPU Throttle/Stability:" "GPU_THROTTLE"
      _qa_result_line "DCGM Health Check:" "DCGM"
      _qa_result_line "Floating Point Accuracy:" "FP-ACCURACY"
      _qa_result_line "NVRM Driver Check:" "NVRM"
    fi

    _qa_power_supply_section

    _qa_section "STORAGE"
    lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT 2>/dev/null | grep -v "^loop" | sed 's/^/  /'
    _qa_result_line "SMART Health Check:" "SMARTCTL"
    _qa_result_line "Drive Presence Check:" "DRIVE_PRESENCE"
    if [ -f /etc/fstab ]; then
      echo "  Configured Mounts (/etc/fstab):"
      grep -vE '^\s*#|^\s*$' /etc/fstab | sed 's/^/    /'
    fi

    # Software RAID -- only if an array is actually active
    if grep -q "^md.*active" /proc/mdstat 2>/dev/null; then
      _qa_section "SOFTWARE RAID"
      grep "^md" /proc/mdstat | sed 's/^/  /'
    fi

    # Hardware RAID (storcli) -- only if the CLI is present AND reports a controller
    local raid_cmd=""
    if command -v storcli64 &>/dev/null; then raid_cmd="storcli64"
    elif command -v storcli &>/dev/null; then raid_cmd="storcli"; fi
    if [ -n "$raid_cmd" ] && "$raid_cmd" show 2>/dev/null | grep -q "^0 "; then
      _qa_section "HARDWARE RAID"
      "$raid_cmd" /c0 show 2>/dev/null | sed 's/^/  /'
    fi

    # GRAID -- only if graidctl is present AND reports a virtual drive
    local graid_cmd=""
    if command -v graidctl &>/dev/null; then graid_cmd="graidctl"
    elif [ -x /opt/graid/graidctl ]; then graid_cmd="/opt/graid/graidctl"; fi
    if [ -n "$graid_cmd" ] && "$graid_cmd" list virtual_drive &>/dev/null; then
      _qa_section "GRAID"
      "$graid_cmd" list virtual_drive 2>/dev/null | sed 's/^/  /'
    fi

    # Interfaces always shown; the Mellanox/InfiniBand subsection only appears if detected.
    _qa_section "NETWORK"
    find /sys/class/net -mindepth 1 -maxdepth 1 ! -name lo -printf "  %P: " -execdir cat {}/address \; 2>/dev/null
    if lspci 2>/dev/null | grep -qi 'mellanox\|infiniband'; then
      echo "  -- Mellanox / InfiniBand AOC detected --"
      lspci 2>/dev/null | grep -i 'mellanox\|infiniband' | sed 's/^/  /'
      if command -v mstvpd &>/dev/null; then
        for pci in $(lspci 2>/dev/null | grep -i mellanox | awk '{print $1}'); do
          mstvpd "$pci" 2>/dev/null | sed 's/^/  /'
        done
      fi
      # Port state/rate/GUID per HCA. Absent ibstat means OFED never installed -- say so rather than print nothing.
      if command -v ibstat &>/dev/null; then
        echo "  -- Port status (ibstat) --"
        ibstat 2>/dev/null | sed 's/^/  /'
      else
        echo "  -- Port status: ibstat not present (Mellanox OFED not installed) --"
      fi
      # Firmware rev + PSID, the numbers the AOC is actually qualified against.
      if command -v mstflint &>/dev/null; then
        echo "  -- Firmware (mstflint) --"
        for pci in $(lspci 2>/dev/null | grep -i mellanox | awk '{print $1}'); do
          echo "  $pci:"
          mstflint -d "$pci" query 2>/dev/null | sed 's/^/    /'
        done
      fi
      # Link layer is set per port and decides whether the card is an IB or Ethernet AOC.
      if command -v mlxconfig &>/dev/null; then
        echo "  -- Link type / config (mlxconfig) --"
        for pci in $(lspci 2>/dev/null | grep -i mellanox | awk '{print $1}'); do
          echo "  $pci:"
          mlxconfig -d "$pci" -e query 2>/dev/null \
            | grep -iE 'LINK_TYPE|SRIOV_EN|NUM_OF_VFS|Device type|Name' | sed 's/^/    /'
        done
      fi
      command -v ibstatus &>/dev/null && { echo "  -- Port summary (ibstatus) --"; ibstatus 2>/dev/null | sed 's/^/  /'; }
    fi

    # SOFTWARE INSTALLATIONS: general OS software, not the QA toolchain. ALWAYS prints, unlike hardware sections.
    _qa_section "SOFTWARE INSTALLATIONS"
    local _sw_any=""
    if [ -n "$raid_cmd" ]; then
      echo "  $raid_cmd:$( [ "$raid_cmd" = "storcli" ] && echo "         " || echo "       " )installed"; _sw_any=1
    fi
    [ -n "$graid_cmd" ] && { echo "  GRAID:            installed ($graid_cmd)"; _sw_any=1; }
    if _mellanox_present; then
      printf '  %-17s %s\n' "Mellanox OFED:" "$(command -v ofed_info &>/dev/null && ofed_info -s 2>/dev/null | tr -d '\n' || echo 'not installed')"
      printf '  %-17s %s\n' "Mellanox MFT:" "$(command -v mst &>/dev/null && { mst version 2>/dev/null | head -1; } || echo 'not installed')"
      _sw_any=1
    fi
    if command -v docker &>/dev/null; then
      printf '  %-17s %s\n' "Docker:" "$(docker --version 2>/dev/null | sed 's/^Docker version //')"
      printf '  %-17s %s\n' "NVIDIA CTK:" "$(command -v nvidia-ctk &>/dev/null && nvidia-ctk --version 2>/dev/null | head -1 || echo 'not installed')"
      _sw_any=1
    fi
    [ -x /usr/local/anaconda3/bin/conda ] && { printf '  %-17s %s\n' "Anaconda3:" "$(/usr/local/anaconda3/bin/conda --version 2>/dev/null) (/usr/local/anaconda3)"; _sw_any=1; }
    if [ -s "$EMLI_STATE_DIR/result" ]; then
      printf '  %-17s %s\n' "EMLI:" "$(_emli_result_get MODE) install, $(_emli_result_get DATE)"
      printf '  %-17s %s\n' "  Container GPUs:" "$(_emli_result_get CONTAINER_GPU)"
      printf '  %-17s %s\n' "  TensorFlow GPUs:" "$(_emli_result_get TF_GPU)"
      _sw_any=1
    fi
    # Records the branding decision either way -- "skipped" is the expected result on contract-manufacturing builds.
    if _system_is_exxact_branded; then
      printf '  %-17s %s\n' "Exxact MOTD:" "$( [ -s /etc/motd ] && echo 'applied' || echo 'NOT applied (Exxact serial)' )"
    else
      printf '  %-17s %s\n' "Exxact MOTD:" "skipped -- serial is not Exxact format (contract build)"
    fi
    [ -z "$_sw_any" ] && echo "  No additional software installed."

    # VALIDATION TOOLKIT: each tool's real version (git commit for clones) plus an Install Location for removal.
    _qa_toolkit_line() {  # _qa_toolkit_line <label> <version_text> <install_location>
      printf '  %-18s %s\n' "$1:" "$2"
      [ -n "$3" ] && printf '  %-28s %s\n' "    Install Location:" "$3"
    }
    _qa_section "VALIDATION TOOLKIT INSTALLATIONS"
    if [ -x "${MPRIME_DIR:-/nonexistent}/mprime" ]; then
      _qa_toolkit_line "mprime" "$(timeout 5 "$MPRIME_DIR/mprime" -v 2>&1 | head -1)" "$MPRIME_DIR"
    fi
    if [ "$ARCH" = "aarch64" ] && command -v stress-ng &>/dev/null; then
      _qa_toolkit_line "stress-ng" "$(stress-ng --version 2>/dev/null) (ARM CPU-stress substitute for mprime)" "$(command -v stress-ng)"
    fi
    if [ -x "${GPUBURN_DIR:-/nonexistent}/gpu_burn" ]; then
      local gpuburn_ver; gpuburn_ver=$(git -C "$GPUBURN_DIR" log -1 --format="%h (%ad)" --date=short 2>/dev/null)
      _qa_toolkit_line "gpu_burn" "${gpuburn_ver:-installed, commit unknown}" "$GPUBURN_DIR"
    fi
    if command -v stressapptest &>/dev/null; then
      # Sourced locally, not relied on as a leaked global -- this function can run standalone.
      local sat_ver os_id; os_id=$(. /etc/os-release 2>/dev/null; echo "$ID")
      if [[ "$os_id" == "ubuntu" ]]; then
        sat_ver=$(dpkg-query -W -f='${Version}' stressapptest 2>/dev/null)
      else
        sat_ver=$(rpm -q stressapptest 2>/dev/null)
      fi
      _qa_toolkit_line "stressapptest" "${sat_ver:-installed, version unknown}" "$(command -v stressapptest)"
    fi
    command -v smartctl &>/dev/null && _qa_toolkit_line "smartmontools" "$(smartctl --version 2>/dev/null | head -1)" "$(command -v smartctl)"
    # dcgmi --version starts with a blank line, so head -1 printed nothing -- grep the version line.
    command -v dcgmi &>/dev/null && _qa_toolkit_line "DCGM" "$(dcgmi --version 2>/dev/null | grep -m1 'version:' || echo installed)" "$(command -v dcgmi)"
    if [ -x "${FPACC_DIR:-/nonexistent}/matrixMul" ]; then
      local fpacc_ver; fpacc_ver=$(git -C "$FPACC_DIR" log -1 --format="%h (%ad)" --date=short 2>/dev/null)
      _qa_toolkit_line "matrixMul" "${fpacc_ver:-installed, commit unknown} (NVIDIA cuda-samples)" "$FPACC_DIR"
    fi
    command -v fio &>/dev/null && _qa_toolkit_line "fio" "$(fio --version 2>/dev/null)" "$(command -v fio)"

    printf '\n%s#=======================================================================#%s\n' "$TXT_GRN" "$RESET"
    printf '%sEND OF QA VALIDATION REPORT%s\n' "$TXT_GRN" "$RESET"
    printf '%s#=======================================================================#%s\n' "$TXT_GRN" "$RESET"
  )

  # Colorized on screen, ANSI stripped before writing, or the codes show as boxes in a text editor.
  echo "$report_body"
  printf '%s\n' "$report_body" | sed 's/\x1b\[[0-9;]*m//g' > "$report_file"
  chown "$REAL_USER:$REAL_USER" "$report_file" 2>/dev/null

  echo -e "\n${TXT_BLU}Report saved to: $report_file${RESET}"

  _finalize_qa_artifacts "$report_file"
}

# Root of the diagnostics tree for this system: /exxact/<SN>_validation-logs/diag
_diag_root() { printf '%s\n' "$EXXACT_ARCHIVE_DIR/$(_system_sn)_validation-logs/diag"; }

# Per-system folder under /exxact holding the report copy and diag/ -- survives a home-directory wipe.
_exx_sys_dir() { printf '%s\n' "$EXXACT_ARCHIVE_DIR/$(_system_sn)_validation-logs"; }

# Builds <SN>_validation-logs.zip from logs plus diagnostics. $STATE_DIR is deliberately excluded.
_zip_validation_artifacts() {
  command -v zip >/dev/null 2>&1 || return 1
  [ -d "${VAL_LOGDIR:-/nonexistent}" ] || return 1
  local zf="$REAL_HOME/$(_system_sn)_validation-logs.zip" top diag_parent
  top="$(basename "$VAL_LOGDIR")"
  rm -f "$zf"
  (cd "$REAL_HOME" && zip -rq "$zf" "$top") || return 1
  # diag/ lives under /exxact -- added with a matching prefix so it merges into the same tree.
  diag_parent="$(dirname "$(_exx_sys_dir)")"
  if [ -d "$(_diag_root)" ]; then
    (cd "$diag_parent" && zip -rq "$zf" "$top/diag") 2>/dev/null
  fi
  chown "$REAL_USER:$REAL_USER" "$zf" 2>/dev/null
  printf '%s\n' "$zf"
  return 0
}

# Zips and uploads, then removes the LOCAL zip only, so engineers browse folders instead of unzipping.
_upload_validation_archive() {  # _upload_validation_archive [extra_file...]
  local zf; zf=$(_zip_validation_artifacts)
  if [ -z "$zf" ]; then
    echo -e "${TXT_YLW}[WARN] Could not build the archive ('zip' may not be installed) -- folders left as they are.${RESET}"
    return 1
  fi
  _ensure_qa_checked
  if [ "$QA_AVAILABLE" != true ]; then
    echo -e "${TXT_YLW}[WARN] QA server unavailable -- archive kept locally at $zf.${RESET}"
    return 1
  fi
  local remote_dir="/QA/QA-$(date +%Y)-$(date +%m)"
  local files=("$zf" "$@")
  sshpass -p "$QA_SSHPASS" ssh "${QA_SSH_OPTS[@]}" "$QA_SERVER_USER@$QA_SERVER_IP" "mkdir -p $remote_dir" 2>/dev/null
  if sshpass -p "$QA_SSHPASS" scp "${QA_SSH_OPTS[@]}" "${files[@]}" "$QA_SERVER_USER@$QA_SERVER_IP:$remote_dir/" 2>/tmp/qa_upload_err.log; then
    echo "[SUCCESS] Uploaded to QA server: $remote_dir"
    rm -f "$zf"
    echo "[INFO] Local zip removed -- logs stay browsable as folders:"
    echo "         $VAL_LOGDIR"
    echo "         $(_diag_root)"
    rm -f /tmp/qa_upload_err.log
    return 0
  fi
  echo -e "${TXT_YLW}[WARN] QA upload failed: $(cat /tmp/qa_upload_err.log 2>/dev/null) -- archive kept locally at $zf.${RESET}"
  rm -f /tmp/qa_upload_err.log
  return 1
}

# End of a validation run: save a report copy under /exxact, then archive + upload.
_finalize_qa_artifacts() {
  local report_file="$1" sysdir
  chown -R "$REAL_USER:$REAL_USER" "$VAL_LOGDIR" 2>/dev/null
  sysdir="$(_exx_sys_dir)"
  if mkdir -p "$sysdir" 2>/dev/null; then
    cp -f "$report_file" "$sysdir/" 2>/dev/null
    echo "[INFO] Report copy saved to $sysdir (survives cleanup of $REAL_HOME)."
  else
    echo -e "${TXT_YLW}[WARN] Could not create $sysdir -- skipping the extra backup copy there.${RESET}"
  fi
  _upload_validation_archive "$report_file"
}

# --- SYSTEM LOG CAPTURE / BTT DIAGNOSTIC BUNDLE. Both paths are REPORT-FREE reference material for Test Engineering. ---
# collect_system_logs: dmesg + journalctl, once before and once after every full run. collect_btt_bundle: read-only
# inventory per the test team's outline. Every command is read-only and timed out -- a hung BMC can't stall a run.

# Per-command ceiling: 90s, because ipmitool sensor list and sdr elist legitimately take 30-60s.
DIAG_CMD_TIMEOUT=90

_diag_have() { command -v "$1" >/dev/null 2>&1; }

_diag_hdr() { printf '\n===== %s =====\n' "$*"; }

# _diag_cmd <title> <command...> -- runs under a timeout, records missing tools explicitly, always returns 0.
_diag_cmd() {
  local hdr="$1"; shift
  printf '\n===== %s  [$ %s] =====\n' "$hdr" "$*"
  if ! _diag_have "$1"; then
    printf '(not collected -- "%s" is not installed on this system)\n' "$1"
    return 0
  fi
  timeout "$DIAG_CMD_TIMEOUT" "$@" 2>&1 \
    || printf '(output above may be incomplete -- "%s" exited non-zero or hit the %ss timeout)\n' "$1" "$DIAG_CMD_TIMEOUT"
  return 0
}

# Whole physical disks only -- no partitions, no loop/zram devices.
_diag_disks() { lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}'; }

# Real network interfaces, loopback excluded.
_diag_nics() { find /sys/class/net -mindepth 1 -maxdepth 1 ! -name lo -printf '%P\n' 2>/dev/null | sort; }

# _diag_init_collection <default|timestamped> -- call ONCE per run; collectors never clear, so captures accumulate.
_diag_init_collection() {
  local mode="${1:-default}" base
  case "$mode" in
    default)     base="$(_system_sn)_diag" ;;
    timestamped) base="$(_system_sn)_diag_$(date '+%Y%m%d-%H%M%S')" ;;
    *) vlog "_diag_init_collection: unknown mode '$mode'"; return 1 ;;
  esac

  # /exxact may be uncreatable on a read-only root -- fall back to $REAL_HOME and say so.
  local root; root="$(_diag_root)"
  if ! mkdir -p "$root" 2>/dev/null; then
    echo -e "${TXT_YLW}[WARN] Could not create $root -- writing diagnostics to $REAL_HOME instead.${RESET}"
    root="$REAL_HOME/$(_system_sn)_diagnostics"
    if ! mkdir -p "$root" 2>/dev/null; then
      echo -e "${TXT_RED}[ERROR] Could not create $root either -- diagnostic collection skipped.${RESET}"
      DIAG_COLLECTION_DIR=""
      return 1
    fi
  fi

  # A timestamped collection must never land on an existing one -- two in the same second would merge.
  if [ "$mode" = "timestamped" ] && [ -e "$root/$base" ]; then
    local n=2
    while [ -e "$root/${base}_$n" ]; do n=$((n + 1)); done
    base="${base}_$n"
  fi

  DIAG_COLLECTION_DIR="$root/$base"
  [ "$mode" = "default" ] && rm -rf "${DIAG_COLLECTION_DIR:?}" 2>/dev/null
  if ! mkdir -p "$DIAG_COLLECTION_DIR" 2>/dev/null; then
    echo -e "${TXT_RED}[ERROR] Could not create $DIAG_COLLECTION_DIR -- diagnostic collection skipped.${RESET}"
    DIAG_COLLECTION_DIR=""
    return 1
  fi
  return 0
}

# Every collector routes through this; a standalone call falls back to the default collection.
_diag_require_collection() {
  [ -n "$DIAG_COLLECTION_DIR" ] && [ -d "$DIAG_COLLECTION_DIR" ] && return 0
  _diag_init_collection default
}

# collect_system_logs <before|after|btt>
collect_system_logs() {
  local tag="$1"
  case "$tag" in
    before|after|btt) ;;
    *) vlog "collect_system_logs: unknown tag '$tag' -- skipped"; return 1 ;;
  esac
  _diag_require_collection || return 1
  local dir="$DIAG_COLLECTION_DIR/system-logs"
  if ! mkdir -p "$dir" 2>/dev/null; then
    vlog "System log capture ($tag): could not create $dir -- skipped."
    return 1
  fi

  # dmesg -T gives wall-clock timestamps, cross-referenceable against the temp/power logs and BMC SEL.
  if ! dmesg -T >"$dir/dmesg_${tag}.log" 2>/dev/null; then
    dmesg >"$dir/dmesg_${tag}.log" 2>/dev/null \
      || echo "dmesg unavailable at $(date '+%Y-%m-%d %H:%M:%S') (restricted kernel or permission denied)." >"$dir/dmesg_${tag}.log"
  fi

  # --no-pager is mandatory, not cosmetic: journalctl pipes into less, which would block an unattended run.
  # Two files: a capped tail where failures land, plus warning-and-above for the WHOLE boot, uncapped.
  if _diag_have journalctl; then
    local jraw="$dir/.journal_raw.$$" jtotal=0
    if journalctl -b --no-pager >"$jraw" 2>/dev/null || journalctl --no-pager >"$jraw" 2>/dev/null; then
      jtotal=$(wc -l <"$jraw" 2>/dev/null | tr -d ' ')
      {
        if [ "${jtotal:-0}" -gt "$JOURNAL_MAX_LINES" ]; then
          echo "### TRUNCATED: showing the most recent $JOURNAL_MAX_LINES of $jtotal lines in this boot's journal."
          echo "### Earlier lines were dropped to keep the archive shippable. Warning-and-above"
          echo "### events for the ENTIRE boot are in journalctl_${tag}_priority.log, uncapped."
          echo "###"
        else
          echo "### Complete: $jtotal lines, the full journal for this boot (under the $JOURNAL_MAX_LINES-line cap)."
          echo "###"
        fi
        tail -n "$JOURNAL_MAX_LINES" "$jraw"
      } >"$dir/journalctl_${tag}.log"
    else
      echo "journalctl is present but returned no readable output." >"$dir/journalctl_${tag}.log"
    fi
    rm -f "$jraw"
    journalctl -b -p warning --no-pager >"$dir/journalctl_${tag}_priority.log" 2>/dev/null \
      || echo "(warning-and-above journal query failed or returned nothing)" >"$dir/journalctl_${tag}_priority.log"
  else
    echo "journalctl not present on this system (no systemd journal)." >"$dir/journalctl_${tag}.log"
  fi

  # Deltas -- only what appeared DURING the run, so nobody hand-diffs two multi-megabyte captures.
  if [ "$tag" = "after" ]; then
    if [ -s "$dir/dmesg_before.log" ]; then
      diff "$dir/dmesg_before.log" "$dir/dmesg_after.log" 2>/dev/null \
        | sed -n 's/^> //p' >"$dir/dmesg_during-run.log"
    fi
    # Naturally bounded by the run's duration, but capped anyway -- a chatty box over 4 hours adds up.
    if _diag_have journalctl && [ -n "${RUN_START_TS:-}" ]; then
      journalctl --no-pager --since "$RUN_START_TS" 2>/dev/null \
        | tail -n "$JOURNAL_MAX_LINES" >"$dir/journalctl_during-run.log"
    fi
  fi

  chown -R "$REAL_USER:$REAL_USER" "$dir" 2>/dev/null
  vlog "System logs ($tag) captured -- $(du -sh "$dir" 2>/dev/null | cut -f1) in $dir"
  return 0
}

collect_btt_bundle() {
  # $VAL_LOGDIR is still an INPUT here; the bundle's OUTPUT goes to the diagnostics tree.
  [ -z "${VAL_LOGDIR:-}" ] && _init_validation_paths
  _diag_require_collection || return 1
  local d="$DIAG_COLLECTION_DIR"
  # Nothing is cleared here -- that would destroy before-logs a validation run captured into this directory.

  local serial asset sys_mfr sys_prod sys_ver sys_sku sys_uuid
  serial=$(dmidecode -s system-serial-number 2>/dev/null | head -1)
  asset=$(dmidecode -s chassis-asset-tag 2>/dev/null | head -1 | sed 's/^[ \t]*//;s/[ \t]*$//')
  sys_mfr=$(dmidecode -s system-manufacturer 2>/dev/null | head -1)
  sys_prod=$(dmidecode -s system-product-name 2>/dev/null | head -1)
  sys_ver=$(dmidecode -s system-version 2>/dev/null | head -1)
  sys_sku=$(dmidecode -t system 2>/dev/null | awk -F': ' '/SKU Number:/{print $2; exit}')
  sys_uuid=$(dmidecode -s system-uuid 2>/dev/null | head -1)

  # ---------------------------------------------------------------- SUMMARY
  {
    echo "#======================================================================#"
    echo "  EXXACT BTT DIAGNOSTIC COLLECTION"
    echo "#======================================================================#"
    echo "  Collected:          $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "  Collected by:       exx-validation.sh (version $SCRIPT_VERSION)"
    echo "  Operator:           $REAL_USER"
    echo "  Hostname:           $HOST"
    echo "  Collection:         $DIAG_COLLECTION_DIR"
    # Says outright whether this collection survives the next run, rather than leaving it inferred.
    case "$(basename "$DIAG_COLLECTION_DIR")" in
      "$(_system_sn)_diag") echo "                      (DEFAULT collection -- the next validation run, or a --btt overwrite, replaces this)" ;;
      *)              echo "                      (TIMESTAMPED keeper -- nothing overwrites this; delete it by hand when finished with it)" ;;
    esac
    echo "  System Mfr:         ${sys_mfr:-unknown}"
    echo "  System Product:     ${sys_prod:-unknown}"
    [ -n "$sys_ver" ] && [ "$sys_ver" != "Not Specified" ] && echo "  System Version:     $sys_ver"
    [ -n "$sys_sku" ] && [ "$sys_sku" != "Not Specified" ] && echo "  System SKU:         $sys_sku"
    echo "  System Serial:      ${serial:-unknown}"
    [ -n "$asset" ] && [ "$asset" != "Not Specified" ] && echo "  Asset Tag:          $asset"
    echo "  System UUID:        ${sys_uuid:-unknown}"
    ( . /etc/os-release 2>/dev/null; echo "  OS:                 ${PRETTY_NAME:-unknown}" )
    echo "  Kernel:             $(uname -r)  ($(uname -m))"
    echo "  Uptime:             $(uptime -p 2>/dev/null || uptime)"
    echo ""
    echo "  This bundle is a read-only inventory snapshot. It contains no"
    echo "  pass/fail judgement of its own and is not part of the QA validation"
    echo "  report -- it is reference material for the test team."
    echo ""
    echo "  Contents:"
    echo "    01_system.txt          lspci / lscpu / lsmem / lsblk / dmidecode / uname / OS release"
    echo "    02_bmc.txt             SEL + event logs, sensor readings, FRU, BMC firmware + config"
    echo "    03_bios.txt            BIOS version/vendor/date, baseboard + chassis, BIOS event log record"
    echo "    04_gpu.txt             GPU inventory, driver, firmware/VBIOS, health, ECC, Xid, diag results"
    echo "    05_network.txt         NIC/HCA inventory, firmware, link state, stats, error counters, fabric/switch"
    echo "    06_storage.txt         Device inventory, SMART, PCIe link state, controller logs, NVMe errors, I/O results"
    echo "    07_workload.txt        Test name/version, command/config, runtime, failure point, expected vs actual"
    echo "    08_pcie_link_state.txt Every PCIe device's negotiated vs capable gen/width (one table)"
    echo "    09_power_cooling.txt   PSU inventory/status, fan + thermal readings, power caps/governors"
    echo "    10_location.txt        Rack position and site/environment fields"
    echo "    system-logs/           dmesg + journalctl captures (see that folder's own files)"
    echo ""
    echo "  Not machine-discoverable, so not in this bundle unless recorded by"
    echo "  hand: rack position/site (see 10_location.txt for how to record it)"
    echo "  and upstream switch identity beyond whatever LLDP reports."
  } > "$d/00_SUMMARY.txt" 2>/dev/null

  # ----------------------------------------------------------------- SYSTEM
  {
    echo "SYSTEM INVENTORY -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    _diag_cmd "Kernel / architecture" uname -a
    _diag_hdr "OS release  [\$ cat /etc/os-release]"
    cat /etc/os-release 2>/dev/null || echo "(no /etc/os-release)"
    _diag_cmd "Kernel command line" cat /proc/cmdline
    _diag_cmd "Host identity" hostnamectl
    _diag_cmd "Uptime / load" uptime
    _diag_cmd "Failed systemd units" systemctl --failed --no-pager

    _diag_cmd "PCI devices (flat, with vendor/device IDs)" lspci -nn
    _diag_cmd "PCI devices (tree)" lspci -tvnn
    _diag_cmd "PCI devices (verbose -- includes per-device link capability/status)" lspci -vvv

    _diag_cmd "CPU summary" lscpu
    _diag_cmd "CPU per-core topology" lscpu -e
    _diag_hdr "CPU model / stepping / microcode  [\$ /proc/cpuinfo]"
    grep -E 'model name|^model|stepping|microcode|cpu family|flags' /proc/cpuinfo 2>/dev/null | sort -u
    _diag_cmd "CPU DMI records" dmidecode -t processor
    _diag_cmd "NUMA topology" numactl --hardware

    _diag_cmd "Memory blocks / online state" lsmem
    _diag_cmd "Memory totals" free -h
    _diag_cmd "Memory DMI records (per-slot: locator, size, type, speed, manufacturer, part + serial number)" dmidecode -t memory
    _diag_hdr "Kernel memory info  [\$ /proc/meminfo]"
    cat /proc/meminfo 2>/dev/null
    _diag_hdr "EDAC ECC counters  [\$ /sys/devices/system/edac]"
    if compgen -G "/sys/devices/system/edac/mc/mc*" >/dev/null 2>&1; then
      grep -r . /sys/devices/system/edac/mc/mc*/ce_count /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null
      grep -r . /sys/devices/system/edac/mc/mc*/csrow*/ch*_ce_count 2>/dev/null
    else
      echo "(no EDAC memory controllers exposed -- driver not loaded or unsupported platform)"
    fi
    _diag_cmd "RAS / EDAC summary" ras-mc-ctl --summary

    _diag_cmd "Block devices (all columns)" lsblk -O
    _diag_cmd "DMI / SMBIOS full dump" dmidecode
  } > "$d/01_system.txt" 2>/dev/null

  # -------------------------------------------------------------------- BMC
  {
    echo "BMC -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    if ! _diag_have ipmitool; then
      echo ""
      echo "(ipmitool is not installed -- no BMC data collected. Install ipmitool"
      echo " and re-run --btt if this platform has a BMC.)"
    elif ! timeout "$DIAG_CMD_TIMEOUT" ipmitool mc info >/dev/null 2>&1; then
      echo ""
      echo "(ipmitool is installed but no BMC responded over the in-band KCS"
      echo " interface -- expected on desktop/workstation platforms with no BMC.)"
    else
      _diag_cmd "BMC firmware / device info" ipmitool mc info
      _diag_cmd "BMC self-test" ipmitool mc selftest
      _diag_cmd "System Event Log -- capacity/usage" ipmitool sel info
      # The SEL is the highest-value BMC artifact: real faults appear with a timestamp, independent of the OS.
      _diag_cmd "System Event Log -- full extended listing" ipmitool sel elist
      _diag_cmd "Sensor readings (full, with thresholds)" ipmitool sensor list
      _diag_cmd "SDR extended listing" ipmitool sdr elist all
      _diag_cmd "FRU inventory (chassis/board/product part + serial numbers, incl. PSUs)" ipmitool fru print
      _diag_cmd "Chassis status" ipmitool chassis status
      _diag_cmd "Chassis power policy" ipmitool chassis policy list
      _diag_cmd "BMC LAN configuration (channel 1)" ipmitool lan print 1
      _diag_cmd "BMC LAN configuration (channel 8)" ipmitool lan print 8
      _diag_cmd "BMC user list (channel 1)" ipmitool user list 1
      _diag_cmd "BMC channel info" ipmitool channel info 1
      _diag_cmd "DCMI power reading" ipmitool dcmi power reading
    fi
  } > "$d/02_bmc.txt" 2>/dev/null

  # ------------------------------------------------------------------- BIOS
  {
    echo "BIOS -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    _diag_cmd "BIOS DMI record" dmidecode -t bios
    _diag_hdr "BIOS version / vendor / release date  [\$ dmidecode -s]"
    printf '  Vendor:       %s\n' "$(dmidecode -s bios-vendor 2>/dev/null | head -1)"
    printf '  Version:      %s\n' "$(dmidecode -s bios-version 2>/dev/null | head -1)"
    printf '  Release Date: %s\n' "$(dmidecode -s bios-release-date 2>/dev/null | head -1)"
    _diag_cmd "Baseboard (motherboard manufacturer / product / revision / serial)" dmidecode -t baseboard
    _diag_cmd "Chassis" dmidecode -t chassis
    # DMI type 15 is the SMBIOS event log, read with standard dmidecode; the BMC SEL remains authoritative.
    _diag_cmd "BIOS system event log record (DMI type 15)" dmidecode -t 15
    _diag_cmd "OEM strings (DMI type 11 -- some vendors expose build/config codes here)" dmidecode -t 11
    _diag_hdr "Boot mode"
    if [ -d /sys/firmware/efi ]; then echo "  UEFI (/sys/firmware/efi present)"; else echo "  Legacy BIOS (no /sys/firmware/efi)"; fi
    _diag_cmd "UEFI boot entries" efibootmgr -v

    # No BIOS setup export: there is no standard Linux interface, only inconsistent per-vendor utilities.
    _diag_hdr "BIOS configuration / settings"
    echo "  Not collected. BIOS settings are not readable through any standard"
    echo "  Linux interface -- capture them from the BIOS setup screen or the"
    echo "  BMC web UI if a specific setting is in question. BIOS revision is"
    echo "  recorded above; hardware events are in 02_bmc.txt (BMC SEL)."
  } > "$d/03_bios.txt" 2>/dev/null

  # -------------------------------------------------------------------- GPU
  {
    echo "GPU / ACCELERATOR -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    if ! _diag_have nvidia-smi || [ -z "$(nvidia-smi -L 2>/dev/null)" ]; then
      echo ""
      echo "(no NVIDIA GPU detected, or the driver is not loaded.)"
      _diag_hdr "PCI-visible display/3D controllers  [\$ lspci]"
      lspci -nn 2>/dev/null | grep -iE 'VGA|3D controller|Display controller' || echo "(none)"
    else
      _diag_cmd "GPU list" nvidia-smi -L
      _diag_cmd "GPU inventory (index, model, serial, UUID, VBIOS, driver, PCIe address + link)" \
        nvidia-smi --query-gpu=index,name,serial,uuid,vbios_version,driver_version,pci.bus_id,pcie.link.gen.max,pcie.link.gen.current,pcie.link.width.max,pcie.link.width.current --format=csv
      _diag_cmd "GPU status table" nvidia-smi
      # -q is the whole picture: VBIOS/InfoROM, ECC counters, remapped rows, power/clock limits, throttle reasons.
      _diag_cmd "GPU full query (firmware, ECC, clocks, power caps, throttle reasons)" nvidia-smi -q
      _diag_cmd "GPU ECC detail" nvidia-smi -q -d ECC
      _diag_cmd "Row remapper status" nvidia-smi --query-remapped-rows=gpu_bus_id,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure --format=csv
      _diag_cmd "GPU topology matrix" nvidia-smi topo -m
      if _gpu_has_nvlink; then
        _diag_cmd "NVLink status" nvidia-smi nvlink -s
        _diag_cmd "NVLink error counters" nvidia-smi nvlink -e
      fi
      _diag_cmd "Fabric Manager service state" systemctl status nvidia-fabricmanager --no-pager
      _diag_cmd "NVIDIA driver module info" modinfo nvidia
      _diag_cmd "CUDA toolkit version" nvcc --version
      _diag_cmd "DCGM device discovery" dcgmi discovery -l

      _diag_hdr "Xid / NVRM errors in the current boot  [\$ dmesg | grep -i 'xid\|nvrm']"
      dmesg 2>/dev/null | grep -iE 'xid|nvrm' | tail -200 || true
      if ! dmesg 2>/dev/null | grep -qiE 'xid|nvrm'; then echo "(no Xid/NVRM lines in dmesg)"; fi

      _diag_hdr "GPU diagnostic results already on this system"
      local f
      for f in "$VAL_LOGDIR/dcgm_healthcheck.log" "$VAL_LOGDIR/fp_accuracy_report.txt" "$VAL_LOGDIR/gpuburn.log"; do
        if [ -s "$f" ]; then
          echo "  $f  ($(wc -l <"$f") lines, last modified $(date -r "$f" '+%Y-%m-%d %H:%M:%S'))"
        else
          echo "  $(basename "$f"): not present (that test has not been run on this system yet)"
        fi
      done
    fi
  } > "$d/04_gpu.txt" 2>/dev/null

  # --------------------------------------------------------------- NETWORK
  {
    echo "NETWORKING -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    _diag_hdr "NIC / HCA inventory  [\$ lspci]"
    lspci -nn 2>/dev/null | grep -iE 'ethernet|network|infiniband|mellanox' || echo "(no network-class PCI devices found)"
    _diag_cmd "Interface summary (link)" ip -br link
    _diag_cmd "Interface summary (addresses)" ip -br addr
    _diag_cmd "Interface counters (extended, incl. error/drop breakdown)" ip -s -s link
    _diag_cmd "Routing table" ip route

    local n
    for n in $(_diag_nics); do
      _diag_hdr "Interface: $n"
      _diag_cmd "  driver + firmware version" ethtool -i "$n"
      _diag_cmd "  link state / negotiated speed" ethtool "$n"
      _diag_cmd "  NIC statistics + error counters" ethtool -S "$n"
    done

    # Mellanox / InfiniBand firmware and fabric state live in their own toolchain, not in ethtool.
    if lspci 2>/dev/null | grep -qiE 'mellanox|infiniband'; then
      _diag_hdr "Mellanox / InfiniBand adapters detected"
      _diag_cmd "MST device status" mst status -v
      _diag_cmd "OFED version" ofed_info -s
      _diag_cmd "IB device info (verbose)" ibv_devinfo -v
      _diag_cmd "IB port state" ibstat
      _diag_cmd "IB port status summary" ibstatus
      _diag_cmd "Fabric link info" iblinkinfo
      _diag_cmd "Fabric discovery" ibnetdiscover
      _diag_cmd "IB performance / error counters" perfquery
      local pci
      for pci in $(lspci 2>/dev/null | grep -i mellanox | awk '{print $1}'); do
        _diag_cmd "  VPD $pci" mstvpd "$pci"
        _diag_cmd "  firmware query $pci" mstflint -d "$pci" query
      done
      _diag_hdr "IB port counters  [\$ /sys/class/infiniband]"
      grep -r . /sys/class/infiniband/*/ports/*/counters/* 2>/dev/null | tail -300 \
        || echo "(no /sys/class/infiniband counters exposed)"
    fi

    # Upstream switch identity is only knowable via LLDP -- there is no other in-band way to ask.
    _diag_hdr "Upstream switch information (LLDP)"
    if _diag_have lldpctl; then
      timeout "$DIAG_CMD_TIMEOUT" lldpctl 2>&1
    elif _diag_have lldpcli; then
      timeout "$DIAG_CMD_TIMEOUT" lldpcli show neighbors detail 2>&1
    else
      echo "(no LLDP client installed -- upstream switch/port identity not"
      echo " discoverable from this host. Record it manually in 10_location.txt,"
      echo " or install lldpd.)"
    fi
  } > "$d/05_network.txt" 2>/dev/null

  # --------------------------------------------------------------- STORAGE
  {
    echo "STORAGE -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    _diag_cmd "Block device inventory (model, serial, firmware rev, transport)" \
      lsblk -o NAME,SIZE,MODEL,SERIAL,REV,TRAN,ROTA,TYPE,MOUNTPOINT
    _diag_cmd "Block devices (all columns)" lsblk -O
    _diag_cmd "NVMe namespace list (incl. firmware revision)" nvme list
    _diag_cmd "NVMe subsystem topology" nvme list-subsys
    _diag_cmd "Filesystem usage" df -hT
    _diag_cmd "Mounted filesystems" findmnt
    _diag_hdr "Configured mounts  [\$ /etc/fstab]"
    grep -vE '^\s*#|^\s*$' /etc/fstab 2>/dev/null || echo "(no /etc/fstab)"

    local dev
    for dev in $(_diag_disks); do
      _diag_hdr "Device: $dev"
      _diag_cmd "  identity (model / serial / firmware)" smartctl -i "$dev"
      _diag_cmd "  health summary" smartctl -H "$dev"
      _diag_cmd "  SMART attributes + log" smartctl -a "$dev"
      case "$dev" in
        /dev/nvme*)
          _diag_cmd "  NVMe SMART / health log" nvme smart-log "$dev"
          _diag_cmd "  NVMe error log" nvme error-log "$dev"
          _diag_cmd "  NVMe controller identify" nvme id-ctrl "$dev"
          ;;
      esac
    done

    _diag_hdr "Storage device PCIe link state (negotiated vs capable)"
    echo "NOTE: a device can legitimately read below capability while idle"
    echo "(ASPM/power-management downshift). Read this alongside 08_pcie_link_state.txt."
    local slot
    for slot in $(lspci 2>/dev/null | grep -iE 'non-volatile memory|raid bus controller|serial attached scsi|sata controller' | awk '{print $1}'); do
      echo ""
      lspci -s "$slot" -nn 2>/dev/null
      lspci -s "$slot" -vv 2>/dev/null | grep -E 'LnkCap:|LnkSta:' | sed 's/^/    /'
    done

    _diag_hdr "Software RAID  [\$ /proc/mdstat]"
    cat /proc/mdstat 2>/dev/null || echo "(no /proc/mdstat)"
    _diag_cmd "Software RAID detail" mdadm --detail --scan --verbose

    local raid_cmd=""
    if _diag_have storcli64; then raid_cmd="storcli64"; elif _diag_have storcli; then raid_cmd="storcli"; fi
    if [ -n "$raid_cmd" ]; then
      _diag_cmd "HW RAID controller -- full configuration" "$raid_cmd" /c0 show all
      _diag_cmd "HW RAID controller -- event log" "$raid_cmd" /c0 show events type=sincereboot
      _diag_cmd "HW RAID controller -- firmware terminal log" "$raid_cmd" /c0 show termlog
    else
      _diag_hdr "HW RAID controller"
      echo "(no storcli/storcli64 present -- no LSI/Broadcom controller CLI installed)"
    fi

    local graid_cmd=""
    if _diag_have graidctl; then graid_cmd="graidctl"; elif [ -x /opt/graid/graidctl ]; then graid_cmd="/opt/graid/graidctl"; fi
    if [ -n "$graid_cmd" ]; then
      _diag_cmd "GRAID version" "$graid_cmd" version
      _diag_cmd "GRAID physical drives" "$graid_cmd" list physical_drive
      _diag_cmd "GRAID drive groups" "$graid_cmd" list drive_group
      _diag_cmd "GRAID virtual drives" "$graid_cmd" list virtual_drive
    fi

    _diag_hdr "I/O test results already on this system"
    if [ -d "$RESULTS_DIR" ] && [ -n "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
      ls -lh "$RESULTS_DIR" 2>/dev/null
    else
      echo "(no fio validation results in $RESULTS_DIR -- storage testing has not been run)"
    fi
    if [ -s "$IE_PLAN_FILE" ]; then
      echo ""
      echo "Saved storage provisioning plan ($IE_PLAN_FILE):"
      sed 's/^/  /' "$IE_PLAN_FILE"
    fi
  } > "$d/06_storage.txt" 2>/dev/null

  # -------------------------------------------------------------- WORKLOAD
  {
    echo "WORKLOAD / TEST CONTEXT -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    _diag_hdr "Test name / version"
    echo "  Test suite:            exx-validation.sh"
    echo "  Version:               $SCRIPT_VERSION"
    echo "  Invoked as:            $SCRIPT_PATH"
    echo "  Operator:              $REAL_USER"

    _diag_hdr "Command / configuration in effect for this collection"
    echo "  DCGM level override:   ${DCGM_LEVEL_OVERRIDE:-(none -- per-callsite default)}"
    echo "  nvbandwidth plugin:    $([ "$DCGM_NVBANDWIDTH_DISABLE" = "1" ] && echo "disabled (--nvbandwidth=0)" || echo "enabled (default)")"
    echo "  Concurrent stress:     ${CONCURRENT_STRESS_DURATION}s"
    echo "  Sequential per-test:   ${SEQUENTIAL_TEST_DURATION}s"
    echo "  NoOS mode:             $([ -n "$NOOS_MODE" ] && echo yes || echo no)"
    echo "  Thresholds:            CPU ${CPU_THRESHOLD}C / GPU ${GPU_THRESHOLD}C / MEM ${MEM_THRESHOLD}C, memory target ${MEM_PERCENT}%"
    echo "  Concurrent mem split:  mprime ${CONCURRENT_MPRIME_MEM_PCT}% / stressapptest ${CONCURRENT_STRESSAPP_MEM_PCT}%"

    # Collected into one variable so a bare box prints an explicit "nothing installed" line, not an empty section.
    _diag_hdr "Validation toolkit versions"
    local tk; tk=$(
      [ -x "${MPRIME_DIR:-/nonexistent}/mprime" ] && echo "  mprime:        $(timeout 5 "$MPRIME_DIR/mprime" -v 2>&1 | head -1)"
      _diag_have stress-ng && echo "  stress-ng:     $(stress-ng --version 2>/dev/null)"
      [ -x "${GPUBURN_DIR:-/nonexistent}/gpu_burn" ] && echo "  gpu_burn:      $(git -C "$GPUBURN_DIR" log -1 --format='%h (%ad)' --date=short 2>/dev/null)"
      _diag_have stressapptest && echo "  stressapptest: $(command -v stressapptest)"
      _diag_have smartctl && echo "  smartmontools: $(smartctl --version 2>/dev/null | head -1)"
      _diag_have dcgmi && echo "  DCGM:          $(dcgmi --version 2>/dev/null | grep -m1 'version:')"
      [ -x "${FPACC_DIR:-/nonexistent}/matrixMul" ] && echo "  matrixMul:     $(git -C "$FPACC_DIR" log -1 --format='%h (%ad)' --date=short 2>/dev/null)"
      _diag_have fio && echo "  fio:           $(fio --version 2>/dev/null)"
      true
    )
    printf '%s\n' "${tk:-  (none installed on this system yet -- no validation has been run)}"

    _diag_hdr "Runtime / current run status"
    if [ -s "$STATUS_FILE" ]; then
      sed 's/^/  /' "$STATUS_FILE"
    else
      echo "  (no run status recorded -- no validation has been started on this system)"
    fi

    # Failure point and expected-vs-actual from persisted results; a pre-test --btt run says so plainly.
    _diag_hdr "Results recorded so far (expected vs actual, per phase)"
    if [ -s "$RESULTS_STATE_FILE" ]; then
      awk -F'\t' '{printf "  %-24s %s   [recorded %s]\n", $1, $2, $3}' "$RESULTS_STATE_FILE" | sort
      echo ""
      echo "  Failing/warning phases:"
      awk -F'\t' '$2 ~ /^(FAIL|WARN)/ {printf "    %-24s %s\n", $1, $2}' "$RESULTS_STATE_FILE" || true
      grep -qE $'\t'"(FAIL|WARN)" "$RESULTS_STATE_FILE" || echo "    (none)"
    else
      echo "  (no results recorded -- no validation has been run on this system yet)"
    fi

    _diag_hdr "Deciding evidence captured per phase"
    if [ -d "$VAL_LOGDIR/evidence" ] && [ -n "$(ls -A "$VAL_LOGDIR/evidence" 2>/dev/null)" ]; then
      local e
      for e in "$VAL_LOGDIR/evidence"/*.txt; do
        [ -s "$e" ] || continue
        echo "  --- $(basename "$e" .txt) ---"
        sed 's/^/      /' "$e"
      done
    else
      echo "  (none recorded yet)"
    fi

    _diag_hdr "Output / logs present in $VAL_LOGDIR"
    ls -lh "$VAL_LOGDIR" 2>/dev/null | sed 's/^/  /'
  } > "$d/07_workload.txt" 2>/dev/null

  # One PCIe table for every device, so a link training down a generation or half-width is obvious.
  {
    echo "PCIe LINK STATE -- negotiated vs capable, every device"
    echo "Collected $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "IMPORTANT: an idle device may legitimately sit below its capability"
    echo "(ASPM / power-management downshift) and train back up under load."
    echo "Flagged lines are a starting point for investigation, not a verdict."
    echo ""
    lspci -vv 2>/dev/null | awk '
      # Device headers start at column 0, capability lines are indented; the optional leading group is the PCI domain.
      # No {n} intervals, so this parses under both gawk (Rocky) and mawk (Ubuntu).
      /^([0-9a-f]+:)?[0-9a-f]+:[0-9a-f]+\.[0-9a-f]+ / { dev=$0; capspd=""; capw=""; next }
      /LnkCap:/ {
        if (match($0, /Speed [0-9.]+GT\/s/)) capspd=substr($0, RSTART+6, RLENGTH-6)
        if (match($0, /Width x[0-9]+/))      capw=substr($0, RSTART+6, RLENGTH-6)
        next
      }
      /LnkSta:/ {
        staspd=""; staw=""
        if (match($0, /Speed [0-9.]+GT\/s/)) staspd=substr($0, RSTART+6, RLENGTH-6)
        if (match($0, /Width x[0-9]+/))      staw=substr($0, RSTART+6, RLENGTH-6)
        if (dev != "" && capspd != "") {
          flag = ((staspd != capspd) || (staw != capw)) ? "   <-- BELOW CAPABILITY" : ""
          printf "%s\n    capable: %-12s %-5s   current: %-12s %-5s%s\n", dev, capspd, capw, staspd, staw, flag
          dev=""
        }
        next
      }'
  } > "$d/08_pcie_link_state.txt" 2>/dev/null

  # -------------------------------------------------------- POWER + COOLING
  {
    echo "POWER + COOLING CONFIGURATION -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    _diag_hdr "Power supplies (DMI)"
    dmidecode -t 39 2>/dev/null || echo "(no DMI type 39 power supply records)"
    if _diag_have ipmitool && timeout "$DIAG_CMD_TIMEOUT" ipmitool mc info >/dev/null 2>&1; then
      _diag_cmd "PSU sensors" ipmitool sdr type "Power Supply"
      _diag_cmd "Current/voltage sensors" ipmitool sdr type "Current"
      _diag_cmd "Fan sensors (cooling configuration: fan count, zones, live RPM)" ipmitool sdr type "Fan"
      _diag_cmd "Temperature sensors (incl. inlet/ambient where exposed)" ipmitool sdr type "Temperature"
      _diag_cmd "DCMI power reading" ipmitool dcmi power reading
      _diag_cmd "DCMI power capability" ipmitool dcmi power get_limit
    fi
    _diag_cmd "lm_sensors" sensors
    _diag_hdr "Thermal zones  [\$ /sys/class/thermal]"
    grep -r . /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp 2>/dev/null \
      || echo "(no thermal zones exposed)"
    _diag_hdr "Hardware monitoring fans  [\$ /sys/class/hwmon]"
    grep -r . /sys/class/hwmon/hwmon*/fan*_input 2>/dev/null || echo "(no hwmon fan inputs exposed)"
    _diag_hdr "RAPL power domains  [\$ /sys/class/powercap]"
    grep -r . /sys/class/powercap/intel-rapl:*/name /sys/class/powercap/intel-rapl:*/constraint_0_power_limit_uw 2>/dev/null \
      || echo "(no RAPL powercap domains exposed -- expected on AMD/ARM platforms)"
    _diag_cmd "CPU frequency policy / governor" cpupower frequency-info
    _diag_cmd "Tuned profile" tuned-adm active
    if _diag_have nvidia-smi && [ -n "$(nvidia-smi -L 2>/dev/null)" ]; then
      _diag_cmd "GPU power limits" nvidia-smi --query-gpu=index,power.limit,power.default_limit,power.max_limit,enforced.power.limit --format=csv
    fi
    _diag_hdr "Power/cooling telemetry captured during validation runs"
    local pf
    for pf in "$PSU_PWR_LOG" "$CPU_PWR_LOG" "$FAN_LOG" "$CPU_TEMP_LOG" "$GPU_TEMP_LOG" "$MEM_TEMP_LOG"; do
      if [ -s "$pf" ]; then echo "  $(basename "$pf"): $(wc -l <"$pf") samples"; else echo "  $(basename "$pf"): not present (no run yet)"; fi
    done
  } > "$d/09_power_cooling.txt" 2>/dev/null

  # Rack position isn't discoverable from the host: /etc/exxact_location is read if present, else stated as unrecorded.
  {
    echo "LOCATION / TEST ENVIRONMENT -- collected $(date '+%Y-%m-%d %H:%M:%S')"
    _diag_hdr "Recorded location (/etc/exxact_location)"
    if [ -s /etc/exxact_location ]; then
      sed 's/^/  /' /etc/exxact_location
    else
      echo "  NOT RECORDED."
      echo ""
      echo "  Rack position, datacenter/lab, row, U-position, PDU and upstream"
      echo "  switch port cannot be read from the host. To have them appear here"
      echo "  and in every future collection, write them to /etc/exxact_location,"
      echo "  one 'Field: value' per line, e.g.:"
      echo ""
      echo "      Site: Fremont Lab"
      echo "      Row/Rack: R4 / Rack 12"
      echo "      U Position: U18-U21"
      echo "      PDU / Circuit: PDU-B, C13-7"
      echo "      Switch / Port: sw-lab-03 / Eth1/14"
      echo "      Notes: shared 30A circuit with the 4U10G box"
    fi
    _diag_hdr "Discoverable identity for cross-referencing"
    echo "  Hostname:      $HOST"
    echo "  System Serial: ${serial:-unknown}"
    [ -n "$asset" ] && [ "$asset" != "Not Specified" ] && echo "  Asset Tag:     $asset"
    echo "  System UUID:   ${sys_uuid:-unknown}"
    if _diag_have ipmitool; then
      _diag_cmd "BMC network identity (IP/MAC -- maps the box to a switch port)" ipmitool lan print 1
    fi
    _diag_cmd "Host interface MACs" ip -br link
    _diag_cmd "Chassis DMI (type/height/rack-mount flags)" dmidecode -t chassis
    _diag_hdr "Clock / timezone (for correlating logs against site records)"
    timedatectl 2>/dev/null || date
  } > "$d/10_location.txt" 2>/dev/null

  chown -R "$REAL_USER:$REAL_USER" "$d" 2>/dev/null
  return 0
}

# Asks overwrite-vs-timestamp so Test Engineering can hold several reference points. Validation runs never reach this.
_btt_prompt_collection_mode() {
  local existing; existing="$(_diag_root)/$(_system_sn)_diag"
  if [ ! -d "$existing" ]; then
    echo "default"
    return 0
  fi
  # A non-interactive invocation gets the non-destructive answer -- never discard a previous collection unasked.
  if [ ! -t 0 ]; then
    echo "timestamped"
    return 0
  fi
  local age; age=$(date -r "$existing" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  {
    echo ""
    echo "A diagnostic collection already exists:"
    echo "  $existing${age:+   (collected $age)}"
    echo ""
    echo "  1. Overwrite it          -- replace it with this new collection"
    echo "  2. Keep it, timestamp    -- leave it alone, write this one alongside"
    echo "                              as $(_system_sn)_diag_$(date '+%Y%m%d-%H%M%S')"
    echo ""
  } >&2
  local c
  _read_choice c "Enter selection [1-2, default 2]: " >&2
  case "$c" in
    1) echo "default" ;;
    *) echo "timestamped" ;;
  esac
}

# Closes out a run's diagnostics: fix ownership, report where they landed. System Cleanup does the zipping.
_diag_finalize_run() {
  [ -n "$DIAG_COLLECTION_DIR" ] && [ -d "$DIAG_COLLECTION_DIR" ] || return 0
  chown -R "$REAL_USER:$REAL_USER" "$DIAG_COLLECTION_DIR" 2>/dev/null
  echo "[INFO] Diagnostics collected for this run: $DIAG_COLLECTION_DIR"
  return 0
}

# --btt entry point: collect the bundle plus a log snapshot, then stop. No upload, no report.
run_btt_collection() {
  write_header "BTT Diagnostic Collection"
  _ensure_system_sn_confirmed
  _init_validation_paths
  echo "Collecting a full read-only system inventory for the test team."
  echo "No tests are run and nothing is modified. This takes a few seconds"
  echo "(longer on a system with many drives or a slow BMC)."
  local mode; mode=$(_btt_prompt_collection_mode)
  _diag_init_collection "$mode" || return 1
  echo ""
  collect_btt_bundle || return 1
  collect_system_logs btt
  chown -R "$REAL_USER:$REAL_USER" "$DIAG_COLLECTION_DIR" 2>/dev/null
  echo ""
  echo "[SUCCESS] Diagnostics written to: $DIAG_COLLECTION_DIR"
  echo ""
  echo "Start with 00_SUMMARY.txt -- it lists every file and what is in it."
  return 0
}

system_info_flier() {
  write_header "System Info Flier"
  if qa_scp_get "/data/scripts/exx-systeminfo-flier.sh" "."; then
    chmod +x exx-systeminfo-flier.sh
    ./exx-systeminfo-flier.sh
  else
    log_failure "Could not fetch exx-systeminfo-flier.sh from QA server"
  fi
  pause
}

print_qa_file_by_serial() {
  write_header "Print Existing QA Validation File"
  _prompt_confirmed serial_number "Serial number" "Enter the serial number: "
  sshpass -p "$QA_SSHPASS" ssh "${QA_SSH_OPTS[@]}" "$QA_SERVER_USER@$QA_SERVER_IP" <<EOF
cd /QA/
file_names=\$(find . -type f -name "${serial_number}_*_qa_validation.txt")
if [ -z "\$file_names" ]; then
    echo "No file found starting with serial number ${serial_number}."
else
    for file_name in \$file_names; do
        echo "Displaying contents of file: \$file_name"
        cat "\$file_name"
    done
fi
EOF
  pause
}

cryosparc_install() {
  write_header "CryoSparc Install"
  # Legacy exx-cryosparc_preinstall.sh created /scr itself rather than aborting -- matched here.
  if [ ! -d "/scr" ]; then
    echo "Directory /scr does not exist -- creating it (CryoSparc install expects it)."
    mkdir -p /scr/cryosparc_cache
    chmod -R 777 /scr
  fi

  if getent passwd cryosparc_user >/dev/null 2>&1; then
    echo "cryosparc_user already exists."
  else
    echo "Adding cryosparc_user user..."
    useradd -c "CryoSparc User" -d /home/cryosparc_user -s /bin/bash -m cryosparc_user
    echo -e "Password123\nPassword123" | passwd cryosparc_user
  fi

  local file_path="$CRYOSPARC_ACCTINFO_FILE"
  if [ ! -e "$file_path" ]; then
    echo "The file $file_path does not exist. Create it with the following on separate lines:"
    echo "  License ID / Email Address / Last Name / First Name / Install root / SSD cache path"
    pause; return
  fi

  local account_info=()
  while IFS= read -r line; do account_info+=("$line"); done < "$file_path"
  export LICENSE_ID="${account_info[0]}"
  export EMAIL="${account_info[1]}"
  export LASTNAME="${account_info[2]}"
  export FIRSTNAME="${account_info[3]}"
  export USERNAME="$FIRSTNAME $LASTNAME"
  export INSTALLROOT="${account_info[4]}"
  export SSDPATH="${account_info[5]}"

  mkdir -p jobs software/cryosparc
  (
    cd software/cryosparc || exit 1
    curl -L "https://get.cryosparc.com/download/master-latest/$LICENSE_ID" -o cryosparc_master.tar.gz
    curl -L "https://get.cryosparc.com/download/worker-latest/$LICENSE_ID" -o cryosparc_worker.tar.gz
    for archive in *.tar.gz; do tar zxvf "$archive"; done
  )

  echo "License=$LICENSE_ID Email=$EMAIL User=$USERNAME InstallRoot=$INSTALLROOT Cache=$SSDPATH"

  (
    cd "$INSTALLROOT/cryosparc_master" || exit 1
    ./install.sh --standalone --license "$LICENSE_ID" \
      --worker_path "$INSTALLROOT/cryosparc_worker" --ssdpath "$SSDPATH" \
      --initial_email "$EMAIL" --initial_username "$USERNAME" \
      --initial_lastname "$LASTNAME" --initial_firstname "$FIRSTNAME" \
      --initial_password "Password123" | tee -a /home/cryosparc_user/install.log
  )

  echo "export PATH=\"/home/cryosparc_user/software/cryosparc/cryosparc_master/bin:\$PATH\"" >> /home/cryosparc_user/.bashrc
  su - cryosparc_user -c "cryosparcm status"
  local ip; ip=$(hostname -I | awk '{print $1}')
  echo "Installation complete: verify at http://$ip:39000/login"
  pause
}

set_hostname() {
  write_header "Set New Hostname"
  _prompt_confirmed new_hostname "New hostname" "Enter the new hostname: "
  _yes_no confirm "Set hostname to '$new_hostname'? (y/n): "
  if [ "$confirm" == "y" ]; then
    hostnamectl set-hostname "$new_hostname"
    echo "Hostname set. New shells will show it; run 'exec bash' to refresh this one."
  else
    echo "Hostname change aborted."
  fi
  pause
}

# True when the identifier is an Exxact-issued SN. Case-insensitive; caller passes hostname or SN.
_is_exxact_sn() {
  local id; id=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  [ -n "$id" ] && [[ "$id" =~ $EXX_SN_PATTERN ]]
}

# Either identifier matching is enough -- techs sometimes set the hostname before the SN file, or vice versa.
# Same authority the rest of the script names artifacts by: typed SN wins, hostname is only the fallback.
# Deliberately NOT an OR against $HOST -- a leftover Exxact hostname must not brand a contract build.
_system_is_exxact_branded() {
  _is_exxact_sn "$(_system_sn)"
}

# Applies the Exxact MOTD only on Exxact-SN systems. Contract-manufacturing builds must ship unbranded.
install_exx_motd() {
  write_header "Install Exxact MOTD"
  local sn src; sn=$(_system_sn)
  # Says which value was actually tested, so a stale hostname can't be mistaken for the deciding input.
  if [ -s "$SYSTEM_SN_FILE" ] || [ "$sn" != "$HOST" ]; then src="confirmed serial"; else src="hostname (no serial recorded)"; fi
  echo "Hostname:       $HOST"
  echo "Serial:         $sn"
  echo "Decided on:     $src"
  echo "Expected form:  $EXX_SN_PATTERN"
  if ! _system_is_exxact_branded; then
    echo ""
    echo -e "${TXT_YLW}Serial '$sn' does not match the Exxact SN format.${RESET}"
    echo "Treating this as a contract-manufacturing build -- MOTD NOT applied, no Exxact branding."
    vlog "MOTD: skipped -- $src '$sn' does not match $EXX_SN_PATTERN (hostname '$HOST')"
    return 0
  fi
  echo ""
  echo "Exxact serial confirmed -- applying branded MOTD."
  if qa_scp_get "$EXX_MOTD_REMOTE" "/etc/motd"; then
    chmod 644 /etc/motd
    # Ubuntu's update-motd.d runs dynamically and would print above /etc/motd, so drop a static copy there too.
    if [ -d /etc/update-motd.d ]; then
      printf '#!/bin/sh\ncat /etc/motd\n' > /etc/update-motd.d/00-exxact
      chmod +x /etc/update-motd.d/00-exxact
    fi
    vlog "MOTD: applied to /etc/motd for serial $sn"
    echo -e "${TXT_GRN}MOTD applied. Log out and back in to see it.${RESET}"
  else
    log_failure "Could not fetch $EXX_MOTD_REMOTE from QA server -- MOTD not applied."
  fi
}

install_wallpaper() {
  write_header "Install Exxact Wallpaper"
  if qa_scp_get "/data/scripts/exx-wallpaper-generic.sh" "."; then
    chmod +x exx-wallpaper-generic.sh
    ./exx-wallpaper-generic.sh
  else
    log_failure "Could not fetch exx-wallpaper-generic.sh from QA server"
  fi
  pause
}

add_ipmi_user() {
  write_header "Add IPMI User"
  if ipmitool user list 1 | grep -q -w "console"; then
    echo "Username 'console' already exists. Testing IPMI credentials."
  else
    ipmitool user set name 3 "console"
    ipmitool user set password 3 "Password@123"
    ipmitool user enable 3
    ipmitool channel setaccess 1 3 link=on ipmi=on callin=on privilege=4
    echo "Created user 'console' with admin privileges."
  fi
  local test_result; test_result=$(ipmitool user test 3 16 Password@123)
  echo "Testing IPMI Credentials: $test_result"
  pause
}

check_gpu_pcie_mapping() {
  write_header "GPU PCIe Mapping"
  nvidia-smi --query-gpu=index,pci.bus_id,serial,name --format=csv
  pause
}

# Ported from exx-nfs-server.sh. CentOS branch dropped (EOL); Rocky/RHEL/Alma share the nfs-utils name.
setup_nfs_export() {
  write_header "NFS Export Setup"
  _prompt_confirmed export_dir "Export directory" "Directory to export (created if it doesn't exist): "
  if [ -z "$export_dir" ] || [[ "$export_dir" != /* ]]; then
    echo "Directory must be a non-empty absolute path (starting with /). Aborting."
    pause; return
  fi

  . /etc/os-release
  local svc group
  case "$ID" in
    ubuntu)
      apt-get update -y && apt-get install -y nfs-kernel-server
      svc="nfs-kernel-server"; group="nogroup"
      ;;
    rocky|rhel|almalinux)
      dnf install -y nfs-utils
      svc="nfs-server"; group="nobody"
      ;;
    *)
      echo "Unsupported OS ($ID) for NFS export setup -- only Ubuntu/Rocky/RHEL/AlmaLinux are handled."
      pause; return
      ;;
  esac

  mkdir -p "$export_dir"
  chown "nobody:$group" "$export_dir"
  chmod 777 "$export_dir"

  if grep -qF "$export_dir " /etc/exports 2>/dev/null; then
    echo "[INFO] $export_dir is already present in /etc/exports -- not adding a duplicate entry."
  else
    echo "$export_dir *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
  fi

  systemctl enable --now "$svc"
  systemctl restart "$svc"
  exportfs -ra 2>/dev/null

  echo -e "${TXT_GRN}NFS export setup complete -- '$export_dir' is now exported.${RESET}"
  pause
}

user_operations_menu() {
  while true; do
    clear
    write_header "User Operations"
    echo "1. Print System Info Flier"
    echo "2. Print Existing QA Validation File"
    echo "3. Install CryoSparc"
    echo "4. Set New Hostname"
    echo "5. Install Exxact Wallpaper"
    echo "6. Add IPMI User (console/Password@123)"
    echo "7. Check GPU PCIe Mapping"
    echo "8. Configure Storage (IE Provisioning -- drive/RAID/filesystem/mount setup)"
    echo "9. Generate QA Validation Report (colorized, hardware + PASS/FAIL + software)"
    echo "10. AVL Gap-Fill Testing (scoped single-component qualification)"
    echo "11. NFS Export Setup"
    echo "12. EMERGENCY STOP -- kill all running validation/provisioning work"
    echo "13. Install Exxact MOTD (skipped automatically on non-Exxact serials)"
    echo "14. Install DCGMI (NVIDIA Data Center GPU Manager -- install only, no diagnostics)"
    echo "15. Install Slurm (single-node: controller + compute, Rocky/Ubuntu)"
    echo "Q. Back to Main Menu"
    _read_choice sel "Enter selection (1-15, or Q to go Back): "
    case "$sel" in
      1) system_info_flier ;;
      2) print_qa_file_by_serial ;;
      3) cryosparc_install ;;
      4) set_hostname ;;
      5) install_wallpaper ;;
      6) add_ipmi_user ;;
      7) check_gpu_pcie_mapping ;;
      8)
        get_cpu_threads
        verify_environment_templates
        if ie_collect_and_save_plan; then
          read -rp "Provision + validate this storage plan right now (in addition to being saved for later)? (y/n): " run_now
          if [ "$run_now" == "y" ]; then
            # Gate is answered HERE, while a terminal still exists. Detaching first would make
            # ie_load_and_execute_plan's [ -t 0 ] test false and skip it -- partitioning unchecked.
            mapfile -t _IE_PLAN < "$IE_PLAN_FILE"
            if _confirm_projected_structure "${_IE_PLAN[@]}"; then
              IE_PLAN_PRECONFIRMED=1
              _run_or_detach _run_storage_plan_body "storage-plan"
            else
              echo "[INFO] Structure not confirmed -- no drive was touched."
            fi
          fi
        fi
        pause
        ;;
      9) _ensure_system_sn_confirmed; generate_qa_report; pause ;;
      10) gap_fill_menu ;;
      11) setup_nfs_export ;;
      12) stop_all_exx_work ;;
      13) _ensure_system_sn_confirmed; install_exx_motd; pause ;;
      14) dcgm_install_only; pause ;;
      15) slurm_install; pause ;;
      [Qq]) return ;;
      *) echo "Invalid selection."; pause ;;
    esac
  done
}

# --- Emergency stop: kills everything this suite started, from a second terminal ---
# Run when a provisioning or validation run has to be aborted. Deliberately does NOT touch drives
# or undo partitioning -- it stops work, it does not clean up after it.
EXX_WORKLOAD_PROCS=("mprime" "gpu_burn" "stressapptest" "stress-ng" "fio" "memtester"
                    "dcgmi" "nvbandwidth" "matrixMul" "rvs" "rocm-bandwidth-test")

# PIDs of every other instance of this script, this process and its ancestors excluded -- killing
# the terminal you typed the command into is the one outcome nobody wants.
_exx_script_pids() {
    local self=$$ me; me=$(basename "$SCRIPT_PATH")
    local ancestors=" $self " p=$self
    while [ "$p" -gt 1 ]; do
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        [ -z "$p" ] && break
        ancestors="$ancestors $p "
    done
    local pid
    for pid in $(pgrep -f "$me" 2>/dev/null); do
        case "$ancestors" in *" $pid "*) continue ;; esac
        printf '%s\n' "$pid"
    done
}

# $1 = "force" to skip the confirmation (used by --kill).
stop_all_exx_work() {
    local mode="${1:-}"
    write_header "Emergency Stop -- halt all validation/provisioning work"

    local unit_active="" script_pids=() tool_hits=() p t
    systemctl is-active --quiet exx-wizard-resume.service 2>/dev/null && unit_active="yes"
    while IFS= read -r p; do [ -n "$p" ] && script_pids+=("$p"); done < <(_exx_script_pids)
    for t in "${EXX_WORKLOAD_PROCS[@]}"; do
        pgrep -x "$t" >/dev/null 2>&1 && tool_hits+=("$t")
    done

    echo "Found:"
    [ -n "$unit_active" ] && echo "  - wizard resume service (exx-wizard-resume.service) ACTIVE"
    [ ${#script_pids[@]} -gt 0 ] && echo "  - ${#script_pids[@]} other exx-validation.sh process(es): ${script_pids[*]}"
    [ ${#tool_hits[@]} -gt 0 ]   && echo "  - running workload tools: ${tool_hits[*]}"
    if [ -z "$unit_active" ] && [ ${#script_pids[@]} -eq 0 ] && [ ${#tool_hits[@]} -eq 0 ]; then
        echo "  - nothing running."
        [ "$mode" != "force" ] && pause
        return 0
    fi

    echo ""
    echo "This stops all testing immediately. It does NOT unmount, delete arrays or undo"
    echo "partitioning -- anything already built on disk stays exactly as it is."
    if [ "$mode" != "force" ]; then
        local confirm
        read -rp "Type 'STOP' to kill everything above: " confirm
        [ "$confirm" != "STOP" ] && { echo "Aborted -- nothing was killed."; pause; return 1; }
    fi

    # The resume unit first, or systemd restarts what we are about to kill.
    if [ -n "$unit_active" ]; then
        systemctl stop exx-wizard-resume.service 2>/dev/null && echo "  [OK] stopped exx-wizard-resume.service"
    fi

    # TERM first so fio and friends close their files, then KILL what refuses.
    for t in "${EXX_WORKLOAD_PROCS[@]}"; do
        pkill -TERM -x "$t" 2>/dev/null && echo "  [OK] TERM -> $t"
    done
    for p in "${script_pids[@]}"; do
        kill -TERM "$p" 2>/dev/null && echo "  [OK] TERM -> exx-validation.sh pid $p"
    done

    local waited=0
    while [ "$waited" -lt 10 ]; do
        local still=0
        for t in "${EXX_WORKLOAD_PROCS[@]}"; do pgrep -x "$t" >/dev/null 2>&1 && still=1; done
        [ "$still" -eq 0 ] && break
        sleep 1; waited=$((waited + 1))
    done

    for t in "${EXX_WORKLOAD_PROCS[@]}"; do
        pgrep -x "$t" >/dev/null 2>&1 && { pkill -KILL -x "$t" 2>/dev/null; echo "  [OK] KILL -> $t"; }
    done
    for p in "${script_pids[@]}"; do
        kill -0 "$p" 2>/dev/null && { kill -KILL "$p" 2>/dev/null; echo "  [OK] KILL -> pid $p"; }
    done

    # Background helpers this suite forks: dashboards, tickers and the sampling loops.
    pkill -f "nvidia-smi -l" 2>/dev/null
    pkill -f "ipmitool sdr" 2>/dev/null

    echo ""
    local leftover=()
    for t in "${EXX_WORKLOAD_PROCS[@]}"; do pgrep -x "$t" >/dev/null 2>&1 && leftover+=("$t"); done
    while IFS= read -r p; do [ -n "$p" ] && leftover+=("pid $p"); done < <(_exx_script_pids)
    if [ ${#leftover[@]} -eq 0 ]; then
        echo -e "${TXT_GRN}[SUCCESS] All validation/provisioning work stopped.${RESET}"
    else
        echo -e "${TXT_YLW}[WARN] Still running: ${leftover[*]} -- may be in uninterruptible I/O; re-run in a moment.${RESET}"
    fi
    echo ""
    echo "Storage built before the stop is untouched. Use the storage menu's Delete/Destroy"
    echo "options, or System Cleanup, if the system needs returning to raw drives."
    [ "$mode" != "force" ] && pause
    return 0
}

# --- 11. CLEAN UP: array-based globs, and the history wipe is its own explicit confirm. ---
clean_up() {
  write_header "Clean Up Working Directory"
  local patterns=(
    "exx-*" "*_checklist.txt" "burnintest" "storcli*" "emli*" "tensor*"
    "tf*" "stats*.json" "MLNX*" "mlnx*" "cuda*deb" "Stand*"
  )
  echo "Files/patterns that would be removed from the current directory:"
  printf '  %s\n' "${patterns[@]}"
  read -rp "Delete these? (y/n): " confirm
  if [ "$confirm" == "y" ]; then
    rm -rf -- "${patterns[@]}"
    echo "Cleaned up."
  else
    echo "No files deleted."
  fi

  echo "Choose the default boot target:"
  echo "1. Desktop (Graphical)"
  echo "2. Server (Multi-user)"
  read -rp "Enter your choice (1 or 2): " choice
  case "$choice" in
    1) systemctl set-default graphical.target; echo "Default target set to graphical." ;;
    2) systemctl set-default multi-user.target; echo "Default target set to multi-user." ;;
    *) echo "Invalid choice -- leaving boot target unchanged." ;;
  esac

  archive_validation_artifacts

  read -rp "Also wipe this shell's bash history? (y/n): " wipe_hist
  if [ "$wipe_hist" == "y" ]; then
    history -c && history -w
    echo "Shell history wiped."
  fi
  pause
}

# Catch-up archive step: prune timestamped --btt keepers, then re-archive and re-upload.
archive_validation_artifacts() {
  write_header "Archive Validation Artifacts"
  _ensure_system_sn_confirmed
  _init_validation_paths
  if [ ! -d "$VAL_LOGDIR" ]; then
    echo "[INFO] No validation logs found at $VAL_LOGDIR -- nothing to archive."
    return 0
  fi

  local keep extras drop
  keep="$(_diag_root)/$(_system_sn)_diag"
  mapfile -t extras < <(find "$(_diag_root)" -maxdepth 1 -type d -name "$(_system_sn)_diag_*" 2>/dev/null | sort)
  if [ "${#extras[@]}" -gt 0 ]; then
    echo "Timestamped diagnostic collections (kept only while troubleshooting):"
    printf '  %s\n' "${extras[@]}"
    read -rp "Remove these and keep only this run's diagnostics? (y/n): " drop
    if [ "$drop" == "y" ]; then
      rm -rf -- "${extras[@]}"
      echo "Removed ${#extras[@]} timestamped collection(s). Keeping $keep"
    else
      echo "Left in place -- they will be included in the archive below."
    fi
  fi

  local report_file="$REAL_HOME/$(_system_sn)_qa-validation.txt"
  if [ -s "$report_file" ]; then
    _upload_validation_archive "$report_file"
  else
    _upload_validation_archive
  fi
  return 0
}

# --- 12. UPLOAD FILES TO QA SERVER ---
upload_files_qa() {
  write_header "Upload Files to QA Server"
  local host year month
  host=$(hostname); year=$(date +"%Y"); month=$(date +"%m")
  if ! compgen -G "${host}*" > /dev/null; then
    echo "No files starting with '$host' exist in the current directory."
    pause; return
  fi
  read -rp "Upload ${host}* to the QA server? (y/n): " confirm
  if [ "$confirm" == "y" ]; then
    sshpass -p "$QA_SSHPASS" scp "${host}"* "$QA_SERVER_USER@$QA_SERVER_IP:/QA/QA-$year-$month" \
      && echo "Uploaded." || log_failure "Upload failed"
  fi
  pause
}

# --- TOP-LEVEL MENU ---
show_menu() {
  echo " ____ ____ ____ ____ ____"
  echo " E x x a c t   V a l i d a t i o n   S u i t e"
  echo "-------------------------------------------------------------"
  echo "  Main Installations"
  echo "-------------------------------------------------------------"
  echo " 1. Automated Provisioning Wizard (asks setup questions, then runs"
  echo "    everything through to QA -- Run First)"
  echo " 2. Base Post Install"
  echo " 3. Base + GPU Post Install"
  echo " 4. EMLI / EMLI DIY Install (Docker, NGC images, Anaconda)"
  echo " 5. Mellanox Driver + MFT Installation"
  echo " 6. Fabric Manager Installation"
  echo "-------------------------------------------------------------"
  echo "  Validation"
  echo "-------------------------------------------------------------"
  echo " 7. Hardware Validation (CPU / Memory / GPU / SMART / Storage)"
  echo " 8. DCGM GPU Health Check"
  echo "-------------------------------------------------------------"
  echo "  Utilities"
  echo "-------------------------------------------------------------"
  echo " 9. User Operations (incl. AVL Gap-Fill Testing)"
  echo "10. System Cleanup"
  echo "11. Upload Files to QA Server"
  echo " Q. Exit"
  echo ""
  _read_choice c "Enter your choice [1-11 or Q to Exit] "
  case "${c,,}" in
    1) run_and_log run_automated_wizard "wizard" ;;
    # Long package/driver installs -- offer detach so a dropped SSH doesn't abort a half-built driver.
    2) _run_or_detach base_install "base-install" ;;
    3) _run_or_detach gpu_install "gpu-install" ;;
    4)
      # Asked before detaching -- a detached run has no stdin to answer it.
      echo " 1. Full EMLI  (Docker + NGC images + Anaconda + Portainer)"
      echo " 2. EMLI DIY   (Docker + Anaconda, no preloaded images)"
      _read_choice _emli_sel "EMLI type [1-2, default 1]: "
      case "$_emli_sel" in
        2) _run_or_detach emli_diy_install "emli-diy-install" ;;
        *) _run_or_detach emli_install "emli-install" ;;
      esac
      ;;
    5) _run_or_detach mlnx_install "mlnx-install" ;;
    6) _run_or_detach fabric_install "fabric-install" ;;
    7) validation_menu ;;
    8)
      # Level must be asked before detaching -- detached, its own read hits EOF and silently takes 4.
      if [ -z "$DCGM_LEVEL_OVERRIDE" ]; then
        read -rp "DCGM diagnostic level to run [1-4, default 4]: " _dcgm_lvl
        case "${_dcgm_lvl:-4}" in
          1|2|3|4) DCGM_LEVEL_OVERRIDE="${_dcgm_lvl:-4}" ;;
          *) echo "Invalid level '$_dcgm_lvl' -- using 4."; DCGM_LEVEL_OVERRIDE=4 ;;
        esac
      fi
      _run_or_detach dcgm_health_check "dcgm-health-check"
      ;;
    9) user_operations_menu ;;
    10) clean_up ;;
    11) upload_files_qa ;;
    q|quit|exit) echo "Exiting."; exit 0 ;;
    *) echo "Please select 1-11 or Q to exit."; pause ;;
  esac
}

# --- CLI ARGUMENTS / ENTRY POINT. Flag documentation lives in show_help() -- keep the two in sync. ---
# Internal-only tokens, never typed by a user: __run_optionN_body (detached re-exec by _launch_background),
# __wizard_resume (the wizard's systemd resume unit).
INTERNAL_DISPATCH=""
for _arg in "$@"; do
  case "$_arg" in
    -h|--help)
      show_help
      exit 0
      ;;
    --status)
      show_status
      exit $?
      ;;
    --dcgm=*)
      DCGM_LEVEL_OVERRIDE="${_arg#--dcgm=}"
      case "$DCGM_LEVEL_OVERRIDE" in
        1|2|3|4) ;;
        *) echo -e "${TXT_RED}--dcgm must be 1-4, got '$DCGM_LEVEL_OVERRIDE'${RESET}"; exit 1 ;;
      esac
      ;;
    --nvbandwidth=*)
      _nvbw_val="${_arg#--nvbandwidth=}"
      case "$_nvbw_val" in
        0) DCGM_NVBANDWIDTH_DISABLE="1" ;;
        1) DCGM_NVBANDWIDTH_DISABLE="" ;;
        *) echo -e "${TXT_RED}--nvbandwidth must be 0 or 1, got '$_nvbw_val'${RESET}"; exit 1 ;;
      esac
      ;;
    --concurrent-duration=*)
      # Overrides the 4h default for this invocation only, so a customer-facing run can't inherit it.
      CONCURRENT_STRESS_DURATION="${_arg#--concurrent-duration=}"
      case "$CONCURRENT_STRESS_DURATION" in
        ''|*[!0-9]*) echo -e "${TXT_RED}--concurrent-duration must be a positive integer (seconds), got '$CONCURRENT_STRESS_DURATION'${RESET}"; exit 1 ;;
      esac
      ;;
    --noos)
      NOOS_MODE=1
      ;;
    --kill|--stop)
      KILL_MODE=1
      ;;
    --btt)
      BTT_MODE=1
      ;;
    --phase-duration=*)
      PHASE_DURATION="${_arg#--phase-duration=}"
      PHASE_DURATION_FROM_CLI=1
      case "$PHASE_DURATION" in
        ''|*[!0-9]*) echo -e "${TXT_RED}--phase-duration must be a positive integer (seconds), got '$PHASE_DURATION'${RESET}"; exit 1 ;;
      esac
      ;;
    --plan-preconfirmed)
      IE_PLAN_PRECONFIRMED=1
      ;;
    --detach=*)
      # Whitelisted only, so the flag can never be used to invoke an arbitrary function.
      _detach_fn="${_arg#--detach=}"
      if ! _is_detachable "$_detach_fn"; then
        echo -e "${TXT_RED}--detach: '$_detach_fn' is not a detachable target.${RESET}"
        printf '  %s\n' "${EXX_DETACHABLE[@]}"
        exit 1
      fi
      INTERNAL_DISPATCH="$_detach_fn"
      ;;
    # Legacy tokens kept so an in-flight re-exec from an older copy still dispatches.
    __run_option6_body|__run_option7_body|__run_option8_body)
      INTERNAL_DISPATCH="${_arg#_}"
      ;;
    __wizard_resume)
      INTERNAL_DISPATCH="_wizard_resume"
      ;;
  esac
done

if [ -n "$INTERNAL_DISPATCH" ]; then
  "$INTERNAL_DISPATCH"
  exit $?
fi

# --kill: checked first. An abort must never be able to start anything.
if [ -n "$KILL_MODE" ]; then
  stop_all_exx_work force
  exit $?
fi

# --btt: collect-and-exit. Checked before --noos so the two can't fight over one invocation.
if [ -n "$BTT_MODE" ]; then
  run_btt_collection
  exit $?
fi

# --noos: PXE-live systems have no persistent OS, so skip the menu and run Combined directly.
if [ -n "$NOOS_MODE" ]; then
  echo -e "${TXT_GRN}--noos: NoOS/PXE-live system -- skipping installation, going straight to Hardware Validation (Combined, Full Validation).${RESET}"
  echo -e "${TXT_YLW}All test storage is destroyed automatically once validation finishes -- this system ships blank.${RESET}"
  _ensure_system_sn_confirmed
  _noos_storage_setup
  _prompt_monitor_mode
  if [ "$MONITOR_MODE" = "background" ]; then
    _launch_background _run_option6_body
  else
    _run_option6_body
  fi
  exit 0
fi

while true; do
  clear
  show_menu
done
