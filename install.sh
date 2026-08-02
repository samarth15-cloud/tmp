#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  Minecraft Deployment Utility — Enterprise Installer
#  Single-file, zero-dependency (beyond apt) production installer.
#  Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12
# ══════════════════════════════════════════════════════════════════════════
set -Eeuo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────
#  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly MC_ROOT="/opt/minecraft"
readonly MC_USER="minecraft"
readonly MC_GROUP="minecraft"
readonly SERVICE_NAME="minecraft"
readonly INSTALLER_UA="BulkNodes-MC-Installer/${SCRIPT_VERSION} (https://bulknodes.com)"
# UPDATE THIS URL to point to wherever you host the script on GitHub:
readonly INSTALLER_SCRIPT_URL="https://raw.githubusercontent.com/samarth15-cloud/tmp/main/install.sh"

# These will be set based on environment (Termux vs VPS)
LOG_DIR=""
LOG_FILE=""
LOCK_FILE=""
TMP_ROOT=""
OLD_TTY_SETTINGS=""

LOG_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly LOG_TIMESTAMP

STATE_FILE="${MC_ROOT}/config/.installer-state"

MODE="install"
UNATTENDED=0
SERVER_TYPE=""
SERVER_VERSION="latest"
RAM_ALLOC=""
INSTALL_PLAYIT=""
INSTALL_GEYSER=""
CRACKED_MODE=""
EULA_ACCEPT=""
INSTALL_SHELL=""
SSH_LINK_RAW=""
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PORT="22"

# ─────────────────────────────────────────────────────────────────────────
#  COLORS & GLYPHS (minimal palette, no rainbow, no emoji)
# ─────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_WHITE=$'\033[1;37m'
  readonly C_GRAY=$'\033[0;90m'
  readonly C_BLUE=$'\033[0;34m'
  readonly C_CYAN=$'\033[0;36m'
  readonly C_GREEN=$'\033[0;32m'
  readonly C_RED=$'\033[0;31m'
  readonly C_YELLOW=$'\033[0;33m'
  readonly C_BOLD=$'\033[1m'
else
  readonly C_RESET="" C_WHITE="" C_GRAY="" C_BLUE="" C_CYAN="" C_GREEN="" C_RED="" C_YELLOW="" C_BOLD=""
fi

readonly GLYPH_OK="✓"
readonly GLYPH_FAIL="✗"
readonly GLYPH_WARN="!"
readonly GLYPH_INFO="i"
readonly GLYPH_ARROW="→"

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: LOGGING & OUTPUT UTILITIES
# ═════════════════════════════════════════════════════════════════════════

log_init() {
  [[ -z "$LOG_DIR" ]] && return  # Skip if logging not yet initialized
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  [[ -f "$LOG_FILE" ]] && chmod 640 "$LOG_FILE" 2>/dev/null || true
  {
    echo "════════════════════════════════════════════════════════════"
    echo " Minecraft Installer v${SCRIPT_VERSION} — Log started $(date -Iseconds)"
    echo "════════════════════════════════════════════════════════════"
  } >> "$LOG_FILE" 2>/dev/null || true
}

log_line() {
  # Raw log write, timestamped. Never echoes to stdout.
  # Safe no-op if logging not initialized yet.
  [[ -n "${LOG_FILE:-}" ]] && printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

ui_rule() {
  local width=64
  printf '%s' "$C_GRAY"
  printf '─%.0s' $(seq 1 "$width")
  printf '%s\n' "$C_RESET"
}

ui_box_top() {
  printf '%s╔%s╗%s\n' "$C_CYAN" "$(printf '═%.0s' $(seq 1 62))" "$C_RESET"
}
ui_box_bottom() {
  printf '%s╚%s╝%s\n' "$C_CYAN" "$(printf '═%.0s' $(seq 1 62))" "$C_RESET"
}
ui_box_line() {
  local text="$1"
  local pad=$(( (62 - ${#text}) / 2 ))
  local rpad=$(( 62 - ${#text} - pad ))
  printf '%s║%s%*s%s%*s%s║%s\n' "$C_CYAN" "$C_RESET" "$pad" "" "${C_WHITE}${text}${C_RESET}" "$rpad" "" "$C_CYAN" "$C_RESET"
}

ui_banner() {
  echo
  ui_box_top
  ui_box_line "Minecraft Deployment Utility"
  ui_box_line "Enterprise Installer v${SCRIPT_VERSION}"
  ui_box_bottom
  echo
}

say_ok()    { printf '  %s%s%s %s\n' "$C_GREEN" "$GLYPH_OK" "$C_RESET" "$1"; log_line "OK: $1"; }
say_fail()  { printf '  %s%s%s %s\n' "$C_RED" "$GLYPH_FAIL" "$C_RESET" "$1"; log_line "FAIL: $1"; }
say_warn()  { printf '  %s%s%s %s\n' "$C_YELLOW" "$GLYPH_WARN" "$C_RESET" "$1"; log_line "WARN: $1"; }
say_info()  { printf '  %s%s%s %s\n' "$C_BLUE" "$GLYPH_INFO" "$C_RESET" "$1"; log_line "INFO: $1"; }
say_step()  { printf '\n%s%s %s%s\n' "$C_WHITE$C_BOLD" "$GLYPH_ARROW" "$1" "$C_RESET"; log_line "STEP: $1"; }

section() {
  echo
  printf '%s%s%s\n' "$C_WHITE$C_BOLD" "$1" "$C_RESET"
  ui_rule
  log_line "SECTION: $1"
}

# Spinner for background operations. Usage: spinner_run "message" cmd args...
spinner_run() {
  local msg="$1"; shift
  local logf="${TMP_ROOT}/spinner-$$.log"
  ( "$@" ) >"$logf" 2>&1 &
  local pid=$!
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      i=$(( (i+1) % ${#frames} ))
      printf '\r  %s%s%s %s' "$C_CYAN" "${frames:$i:1}" "$C_RESET" "$msg"
      sleep 0.1
    done
  fi
  wait "$pid"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '\r  %s%s%s %s%-20s%s\n' "$C_GREEN" "$GLYPH_OK" "$C_RESET" "$msg" "" "$C_RESET"
    log_line "OK: $msg"
  else
    printf '\r  %s%s%s %s%-20s%s\n' "$C_RED" "$GLYPH_FAIL" "$C_RESET" "$msg" "" "$C_RESET"
    log_line "FAIL: $msg (exit $rc) — see $logf"
    cat "$logf" >> "$LOG_FILE"
    return $rc
  fi
}

progress_bar() {
  # progress_bar current total label
  local current=$1 total=$2 label=$3
  local width=36
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local pct=$(( current * 100 / total ))
  local filled_bar="" empty_bar=""
  if (( filled > 0 )); then filled_bar="$(printf '█%.0s' $(seq 1 "$filled"))"; fi
  if (( empty > 0 )); then empty_bar="$(printf '░%.0s' $(seq 1 "$empty"))"; fi
  printf '\r  %s[%s%s%s%s]%s %3d%% %s' \
    "$C_GRAY" "$C_CYAN" "$filled_bar" \
    "$C_GRAY" "$empty_bar" "$C_RESET" "$pct" "$label"
  if [[ $current -eq $total ]]; then echo; fi
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: ERROR HANDLING / CLEANUP / TRAPS
# ═════════════════════════════════════════════════════════════════════════

CURRENT_STEP="initialization"

on_error() {
  local exit_code=$?
  local line_no=$1
  printf '\n%s%s%s ' "$C_RED$C_BOLD" "$GLYPH_FAIL" "$C_RESET"
  printf '%sInstaller failed%s during step: %s%s%s\n' "$C_RED" "$C_RESET" "$C_WHITE" "$CURRENT_STEP" "$C_RESET"
  printf '  Line %s exited with code %s\n' "$line_no" "$exit_code"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '  Full log: %s%s%s\n\n' "$C_CYAN" "$LOG_FILE" "$C_RESET"
  fi
  log_line "FATAL: exit $exit_code at line $line_no during '$CURRENT_STEP'"
  cleanup_tmp
  exit "$exit_code"
}

cleanup_tmp() {
  [[ -d "${TMP_ROOT:-}" ]] && rm -rf "$TMP_ROOT" 2>/dev/null || true
  [[ -f "${LOCK_FILE:-}" ]] && rm -f "$LOCK_FILE" 2>/dev/null || true
  if [[ -n "${OLD_TTY_SETTINGS:-}" ]]; then
    stty "$OLD_TTY_SETTINGS" 2>/dev/null || true
    OLD_TTY_SETTINGS=""
  fi
}

on_exit() {
  cleanup_tmp
}

trap 'on_error $LINENO' ERR
trap on_exit EXIT
trap 'echo; say_warn "Interrupted by user."; exit 130' INT TERM

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo '')"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      say_warn "Another instance of this installer is already running (PID ${lock_pid})."
      if confirm "Force stop the old instance and continue?"; then
        say_info "Terminating PID ${lock_pid}..."
        kill -9 "$lock_pid" 2>/dev/null || true
        rm -f "$LOCK_FILE" 2>/dev/null || true
      else
        say_fail "Aborted. Another instance of this installer is running."
        exit 1
      fi
    fi
  fi
  echo $$ > "$LOCK_FILE"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: RETRY / NETWORK HELPERS
# ═════════════════════════════════════════════════════════════════════════

retry() {
  # retry <max_attempts> <delay_seconds> -- cmd args...
  local max=$1 delay=$2
  shift 2
  local attempt=1
  until "$@"; do
    if (( attempt >= max )); then
      log_line "RETRY EXHAUSTED: $* after $attempt attempts"
      return 1
    fi
    log_line "RETRY $attempt/$max failed: $*"
    sleep "$delay"
    ((attempt++))
  done
}

fetch_url() {
  # fetch_url <url> <output_path>
  local url="$1" out="$2"
  retry 4 3 curl -fsSL --retry 3 --retry-delay 2 \
    -H "User-Agent: ${INSTALLER_UA}" -o "$out" "$url"
}

fetch_json() {
  # fetch_json <url>  -> prints body to stdout
  local url="$1"
  retry 4 3 curl -fsSL --retry 3 --retry-delay 2 \
    -H "User-Agent: ${INSTALLER_UA}" "$url"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: PRE-FLIGHT CHECKS
# ═════════════════════════════════════════════════════════════════════════

check_root() {
  CURRENT_STEP="verify root privileges"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    say_fail "This installer must run as root. Try: sudo bash install.sh"
    exit 1
  fi
  say_ok "Running as root"
}

detect_os() {
  CURRENT_STEP="detect operating system"
  if [[ ! -f /etc/os-release ]]; then
    say_fail "Cannot detect operating system (/etc/os-release missing)."
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"

  case "$OS_ID" in
    ubuntu)
      case "$OS_VERSION" in
        20.04|22.04|24.04) : ;;
        *) say_warn "Ubuntu ${OS_VERSION} is not officially validated. Continuing anyway." ;;
      esac
      ;;
    debian)
      case "$OS_VERSION" in
        11|12) : ;;
        *) say_warn "Debian ${OS_VERSION} is not officially validated. Continuing anyway." ;;
      esac
      ;;
    *)
      say_fail "Unsupported operating system: ${PRETTY_NAME:-$OS_ID}. This installer supports Ubuntu 20.04/22.04/24.04 and Debian 11/12."
      exit 1
      ;;
  esac
  say_ok "Detected ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
}

detect_arch() {
  CURRENT_STEP="detect CPU architecture"
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      say_fail "Unsupported architecture: ${ARCH_RAW}. Only x86_64 and aarch64 are supported."
      exit 1
      ;;
  esac
  say_ok "Architecture: ${ARCH_RAW} (${ARCH})"
}

detect_virt() {
  CURRENT_STEP="detect virtualization"
  VIRT_TYPE="unknown"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  fi
  say_info "Virtualization: ${VIRT_TYPE}"
}

detect_resources() {
  CURRENT_STEP="detect system resources"
  TOTAL_RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
  CPU_CORES=$(nproc)
  DISK_AVAIL_MB=$(( $(df --output=avail -m "$(dirname "$MC_ROOT")" 2>/dev/null | tail -1 || df --output=avail -m / | tail -1) ))

  say_ok "CPU cores: ${CPU_CORES}"
  say_ok "Total RAM: ${TOTAL_RAM_MB} MB"
  say_ok "Free disk (target volume): ${DISK_AVAIL_MB} MB"

  if (( TOTAL_RAM_MB < 1024 )); then
    say_warn "Detected less than 1 GB of RAM. Minecraft servers are memory-hungry;"
    say_warn "performance will be poor and crashes are likely."
    if [[ "$UNATTENDED" -eq 0 ]]; then
      confirm "Continue anyway?" || { say_info "Installation cancelled by user."; exit 0; }
    else
      say_warn "Unattended mode: continuing despite low RAM."
    fi
  fi

  if (( DISK_AVAIL_MB < 2048 )); then
    say_fail "Less than 2 GB of free disk space available. Aborting."
    exit 1
  fi
}

check_internet() {
  CURRENT_STEP="verify internet connectivity"
  if ! curl -fsSL --max-time 8 -o /dev/null https://fill.papermc.io 2>/dev/null; then
    if ! curl -fsSL --max-time 8 -o /dev/null https://1.1.1.1 2>/dev/null; then
      say_fail "No internet connectivity detected. This installer requires internet access."
      exit 1
    fi
  fi
  say_ok "Internet connectivity confirmed"
}

check_apt() {
  CURRENT_STEP="verify apt package manager"
  if ! command -v apt-get >/dev/null 2>&1; then
    say_fail "apt-get not found. This installer only supports apt-based systems."
    exit 1
  fi
  say_ok "apt package manager available"
}

confirm() {
  # confirm "question" -> returns 0 for yes
  local prompt="$1"
  if [[ "$UNATTENDED" -eq 1 ]]; then
    return 0
  fi
  local ans
  read -r -p "  ${C_WHITE}${prompt}${C_RESET} [y/N]: " ans < /dev/tty || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

ask() {
  # ask "prompt" "default" -> echoes answer
  local prompt="$1" default="$2" ans
  if [[ "$UNATTENDED" -eq 1 ]]; then
    echo "$default"
    return
  fi
  read -r -p "  ${C_WHITE}${prompt}${C_RESET} [${C_GRAY}${default}${C_RESET}]: " ans < /dev/tty || true
  echo "${ans:-$default}"
}

ask_choice() {
  # ask_choice "prompt" default opt1 opt2 opt3...
  local prompt="$1" default="$2"; shift 2
  local opts=("$@")
  if [[ "$UNATTENDED" -eq 1 ]]; then
    echo "$default"
    return
  fi
  echo "  ${C_WHITE}${prompt}${C_RESET}"
  local i=1
  for o in "${opts[@]}"; do
    printf '    %s%d)%s %s\n' "$C_CYAN" "$i" "$C_RESET" "$o"
    ((i++))
  done
  local ans
  read -r -p "  Choice [${C_GRAY}${default}${C_RESET}]: " ans < /dev/tty || true
  ans="${ans:-$default}"
  echo "$ans"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: ENVIRONMENT DETECTION (Termux launcher vs. VPS target)
# ═════════════════════════════════════════════════════════════════════════
#
#  This single script has two personalities:
#
#    1. LAUNCHER MODE — detected when running inside Termux on Android.
#       There is no server to install here. Instead it installs an SSH
#       client locally, asks the user to paste the SSH link their hosting
#       bot gave them, connects to the real VPS, and re-runs this exact
#       script (via curl | bash) on the remote machine.
#
#    2. TARGET MODE — detected when running as root on a real Linux VPS.
#       This is the full Minecraft installer flow that already exists
#       below (packages, Java, server download, systemd, Playit, etc).
#
#  Nothing here changes TARGET MODE behavior; it only decides which path
#  runs first.

is_termux_environment() {
  [[ -n "${TERMUX_VERSION:-}" ]] && return 0
  [[ -d "/data/data/com.termux" ]] && return 0
  [[ "${PREFIX:-}" == *"com.termux"* ]] && return 0
  return 1
}

setup_temp_dir() {
  # Create a temp directory that works on both Termux and normal Linux.
  # Termux doesn't have /tmp, so we use $HOME/.cache or $TMPDIR if available.
  local tmpbase
  if is_termux_environment; then
    tmpbase="${TMPDIR:-${HOME}/.cache/mc-installer-tmp}"
    mkdir -p "$tmpbase"
  else
    tmpbase="/tmp"
  fi
  
  TMP_ROOT="$(mktemp -d "${tmpbase}/mc-installer.XXXXXX" 2>/dev/null)" || {
    # Fallback: create directly if mktemp fails
    TMP_ROOT="${tmpbase}/mc-installer-$$-$RANDOM"
    mkdir -p "$TMP_ROOT"
  }
  
  if [[ ! -d "$TMP_ROOT" ]]; then
    printf 'FATAL: Could not create temporary directory. Checked: %s\n' "$tmpbase" >&2
    exit 1
  fi
}

setup_logging_and_locks() {
  # Initialize logging and lock file paths based on environment.
  # On Termux, use home-based paths. On VPS, use /var.
  if is_termux_environment; then
    LOG_DIR="${HOME}/.cache/mc-installer-logs"
    LOCK_FILE="${HOME}/.cache/mc-installer.lock"
  else
    LOG_DIR="/var/log/minecraft-installer"
    LOCK_FILE="/var/lock/minecraft-installer.lock"
  fi
  
  readonly LOG_DIR LOCK_FILE
  LOG_FILE="${LOG_DIR}/install-${LOG_TIMESTAMP}.log"
  readonly LOG_FILE
  
  log_init
}

# ─────────────────────────────────────────────────────────────────────────
#  SSH link parsing
# ─────────────────────────────────────────────────────────────────────────
#  Accepts messy pasted input like:
#    ```ssh UUuMnyapjnMFFUFrwF8PxL9d7@lon1.tmate.io```
#    `ssh someuser@1.2.3.4 -p 2222`
#    ssh root@203.0.113.5
#  Strips backticks, code-fence markers, and stray whitespace, then pulls
#  out user, host, and port (defaulting to 22).

parse_ssh_link() {
  local raw="$1"
  local cleaned

  # Strip markdown code fences / backticks / quotes and collapse whitespace.
  cleaned="$(printf '%s' "$raw" \
    | sed -e 's/```[a-zA-Z]*//g' -e 's/```//g' -e "s/[\`'\"]//g" \
    | tr -s '[:space:]' ' ' \
    | sed -e 's/^ *//' -e 's/ *$//')"

  if [[ -z "$cleaned" ]]; then
    return 1
  fi

  # Extract an explicit -p PORT if present.
  if [[ "$cleaned" =~ -p[[:space:]]+([0-9]+) ]]; then
    REMOTE_PORT="${BASH_REMATCH[1]}"
  fi

  # Extract user@host from anywhere in the string.
  if [[ "$cleaned" =~ ([A-Za-z0-9_.-]+)@([A-Za-z0-9_.-]+) ]]; then
    REMOTE_USER="${BASH_REMATCH[1]}"
    REMOTE_HOST="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  return 0
}

ask_for_ssh_link() {
  local attempts=0
  while (( attempts < 5 )); do
    echo
    say_step "Paste the SSH connection link your hosting bot gave you"
    say_info "Example: ssh UUuMnyapjnMFFUFrwF8PxL9d7@lon1.tmate.io"
    say_info "Backticks and extra formatting are fine — they'll be stripped automatically."
    local input
    read -r -p "  ${C_WHITE}SSH link:${C_RESET} " input < /dev/tty || true
    if parse_ssh_link "$input"; then
      say_ok "Parsed target: ${REMOTE_USER}@${REMOTE_HOST} (port ${REMOTE_PORT})"
      return 0
    else
      say_warn "Couldn't find a valid 'user@host' in that. Try pasting it again."
      attempts=$((attempts + 1))
    fi
  done
  say_fail "Too many failed attempts to parse the SSH link. Aborting."
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────
#  Termux launcher flow
# ─────────────────────────────────────────────────────────────────────────

termux_install_prereqs() {
  section "Termux Setup"

  # Suppress ALL interactive prompts from dpkg/apt.
  # Without this, `pkg upgrade` hangs on the ncurses config-file dialog
  # that `yes` piping can't navigate.
  export DEBIAN_FRONTEND=noninteractive

  # Only run update/upgrade if needed — skip if openssh + curl are already present.
  local needs_install=0
  for cmd in ssh curl wget git; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      needs_install=1
      break
    fi
  done

  if [[ "$needs_install" -eq 1 ]]; then
    say_step "Updating Termux package index"
    say_info "(this may take a minute on first run)"
    apt-get update -y 2>&1 | tee -a "$LOG_FILE" || true

    say_step "Upgrading installed packages"
    apt-get upgrade -y \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      2>&1 | tee -a "$LOG_FILE" || true

    say_step "Installing SSH client and tools"
    apt-get install -y \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      openssh curl wget git 2>&1 | tee -a "$LOG_FILE"
    say_ok "openssh installed in Termux"
  else
    say_ok "SSH client and tools already installed — skipping"
  fi

  if confirm "Install a nicer-looking terminal (zsh + Starship prompt) in Termux too?"; then
    termux_install_shell_experience
  fi
}

termux_install_shell_experience() {
  say_step "Installing zsh and Starship for Termux"
  apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    zsh 2>&1 | tee -a "$LOG_FILE"

  if ! command -v starship >/dev/null 2>&1; then
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >>"$LOG_FILE" 2>&1 || \
      pkg install -y starship >>"$LOG_FILE" 2>&1 || true
  fi

  local zshrc="${HOME}/.zshrc"
  if ! grep -q "starship init zsh" "$zshrc" 2>/dev/null; then
    {
      echo ''
      echo '# --- Minecraft Deployment Utility: shell setup ---'
      echo 'eval "$(starship init zsh)"'
    } >> "$zshrc"
  fi

  chsh -s zsh >>"$LOG_FILE" 2>&1 || true
  say_ok "zsh + Starship installed. Restart Termux to see the new prompt."
}

termux_launcher_flow() {
  ui_banner
  section "Android Launcher Mode"
  say_info "Termux detected — this device is being used to reach your VPS,"
  say_info "not to host the Minecraft server itself."

  termux_install_prereqs

  if [[ -n "$SSH_LINK_RAW" ]] && parse_ssh_link "$SSH_LINK_RAW"; then
    say_ok "Parsed target: ${REMOTE_USER}@${REMOTE_HOST} (port ${REMOTE_PORT})"
  else
    ask_for_ssh_link
  fi

  # We need a local copy of this script to transfer to the VPS.
  # When run via `curl | bash`, $0 is "bash" (or /usr/bin/bash) — not our script.
  # Check that $0 is a real file AND actually contains our script signature,
  # not just a shell binary that happens to be a readable file.
  local self_script="$0"
  local script_file=""

  if [[ -f "$self_script" && -r "$self_script" ]] \
     && grep -q 'SCRIPT_VERSION=' "$self_script" 2>/dev/null \
     && grep -q 'Minecraft Deployment Utility' "$self_script" 2>/dev/null; then
    # Script was run as `bash install.sh` — real script file on disk.
    script_file="$self_script"
  else
    # Script was piped in via `curl | bash` — no usable file on disk.
    # Download a fresh copy to a temp file so we can SCP it to the VPS.
    say_step "Downloading installer script for VPS transfer"
    script_file="${TMP_ROOT}/install.sh"
    if ! curl -fsSL -H "User-Agent: ${INSTALLER_UA}" \
         -o "$script_file" "${INSTALLER_SCRIPT_URL}"; then
      say_fail "Could not download the installer script for VPS transfer."
      say_info "Try running: curl -fsSL ${INSTALLER_SCRIPT_URL} -o install.sh && bash install.sh"
      exit 1
    fi
    chmod +x "$script_file"
    say_ok "Installer script cached for transfer"
  fi

  section "Connecting to VPS"
  say_step "Opening connection to ${REMOTE_USER}@${REMOTE_HOST}"
  echo

  # Use StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null so the user
  # is never prompted to type 'yes' to confirm the host key.
  local ssh_opts=(
    -p "$REMOTE_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
  )

  # Because the remote target is a tmate sharing session, we cannot use SCP
  # (tmate does not support file transfer, and trying to scp will dump binary
  # protocol data directly into the active tmux terminal, causing massive keyboard loops
  # and spamming 'y' / other keys).
  #
  # Instead, we force PTY allocation with -tt and pipe a tiny one-line loader
  # that tells the VPS to download and run the script directly from GitHub,
  # followed by `cat < /dev/tty` to pipe the user's terminal keyboard input
  # so they can interact with the script prompts.
  # Save original TTY settings and enable raw mode.
  # This makes 'cat < /dev/tty' forward keypresses (like 'q' or arrow keys)
  # character-by-character immediately to the remote PTY instead of buffering
  # line-by-line in cooked mode, and lets Ctrl+C pass to the remote host.
  OLD_TTY_SETTINGS="$(stty -g 2>/dev/null || echo "")"
  if [[ -n "$OLD_TTY_SETTINGS" ]]; then
    stty raw -echo 2>/dev/null
  fi

  if ! {
    sleep 2
    # Auto-bypass the tmate welcome/sharing screen:
    # If the screen is active, 'q' closes it.
    # If not active, 'q' is typed into the shell, but the Ctrl+C (\x03)
    # immediately cancels it, and \r submits a clean line.
    printf 'q\x03\r'
    sleep 1
    printf "curl -fsSL ${INSTALLER_SCRIPT_URL} | bash\r"
    cat < /dev/tty
  } | ssh -tt "${ssh_opts[@]}" "${REMOTE_USER}@${REMOTE_HOST}"; then
    if [[ -n "$OLD_TTY_SETTINGS" ]]; then
      stty "$OLD_TTY_SETTINGS" 2>/dev/null || true
      OLD_TTY_SETTINGS=""
    fi
    say_fail "Remote session ended with an error, or the connection dropped."
    say_info "You can retry by running this installer again."
    exit 1
  fi

  # Restore terminal settings
  if [[ -n "$OLD_TTY_SETTINGS" ]]; then
    stty "$OLD_TTY_SETTINGS" 2>/dev/null || true
    OLD_TTY_SETTINGS=""
  fi

  say_ok "Remote session finished."
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: PACKAGE INSTALLATION
# ═════════════════════════════════════════════════════════════════════════

install_packages() {
  CURRENT_STEP="install system packages"
  section "Package Installation"

  export DEBIAN_FRONTEND=noninteractive

  spinner_run "Updating package index" apt-get update -y
  spinner_run "Upgrading existing packages" apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

  local pkgs=(
    curl wget screen tmux git unzip tar jq ca-certificates openssl gnupg
    software-properties-common ufw nano htop zip xz-utils procps net-tools
    apt-transport-https lsb-release cron
  )

  spinner_run "Installing core utilities" apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "${pkgs[@]}"

  install_java
}

install_java() {
  CURRENT_STEP="install Java runtime"
  section "Java Runtime"

  if command -v java >/dev/null 2>&1; then
    local current_ver
    current_ver="$(java -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"' || echo 0)"
    if [[ "$current_ver" -ge 21 ]] 2>/dev/null; then
      say_ok "Java ${current_ver} already installed"
      return
    fi
  fi

  spinner_run "Installing OpenJDK 21" apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    openjdk-21-jre-headless

  if ! command -v java >/dev/null 2>&1; then
    say_fail "Java installation failed verification."
    exit 1
  fi

  local jv
  jv="$(java -version 2>&1 | head -1)"
  say_ok "Java installed: ${jv}"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: SYSTEM USER & DIRECTORY STRUCTURE
# ═════════════════════════════════════════════════════════════════════════

create_system_user() {
  CURRENT_STEP="create system user"
  section "System User"

  if id "$MC_USER" &>/dev/null; then
    say_ok "User '${MC_USER}' already exists"
  else
    useradd --system --create-home --home-dir "$MC_ROOT" --shell /usr/sbin/nologin "$MC_USER"
    say_ok "Created system user '${MC_USER}' (no login shell)"
  fi
}

create_directory_structure() {
  CURRENT_STEP="create directory structure"
  section "Directory Structure"

  local dirs=(
    "$MC_ROOT"
    "$MC_ROOT/logs"
    "$MC_ROOT/plugins"
    "$MC_ROOT/backups"
    "$MC_ROOT/cache"
    "$MC_ROOT/downloads"
    "$MC_ROOT/tmp"
    "$MC_ROOT/config"
  )

  for d in "${dirs[@]}"; do
    mkdir -p "$d"
  done

  chown -R "${MC_USER}:${MC_GROUP}" "$MC_ROOT"
  chmod -R 750 "$MC_ROOT"

  say_ok "Created ${#dirs[@]} directories under ${MC_ROOT}"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: SERVER TYPE SELECTION & DOWNLOAD
# ═════════════════════════════════════════════════════════════════════════

select_server_type() {
  CURRENT_STEP="select server software"
  section "Server Software"

  if [[ -z "$SERVER_TYPE" ]]; then
    local choice
    choice="$(ask_choice "Select server software:" "1" \
      "Paper (recommended — plugins, best performance)" \
      "Purpur (Paper fork, extra features)" \
      "Fabric (mod support)" \
      "Vanilla (official Mojang, no plugins/mods)" \
      "Velocity (proxy)" \
      "Waterfall (proxy, BungeeCord fork)" \
      "BungeeCord (proxy)")"
    case "$choice" in
      1) SERVER_TYPE="paper" ;;
      2) SERVER_TYPE="purpur" ;;
      3) SERVER_TYPE="fabric" ;;
      4) SERVER_TYPE="vanilla" ;;
      5) SERVER_TYPE="velocity" ;;
      6) SERVER_TYPE="waterfall" ;;
      7) SERVER_TYPE="bungeecord" ;;
      *) SERVER_TYPE="paper" ;;
    esac
  fi
  say_ok "Server software: ${SERVER_TYPE}"
}

select_server_version() {
  CURRENT_STEP="select server version"
  if [[ "$UNATTENDED" -eq 0 && "$SERVER_VERSION" == "latest" ]]; then
    SERVER_VERSION="$(ask "Minecraft version (or 'latest')" "latest")"
  fi
  say_ok "Target version: ${SERVER_VERSION}"
}

download_paper_family() {
  # Handles paper, purpur, velocity, waterfall via their respective APIs.
  #
  # Paper/Velocity/Waterfall use the Fill v3 API (fill.papermc.io/v3).
  #   - api.papermc.io/v2 is SUNSET and no longer available.
  #   - All requests require a non-generic User-Agent header.
  #   - Versions are grouped by major version in the project response.
  #   - Builds endpoint returns a flat array; filter by channel=STABLE.
  #   - Download URL lives at .downloads."server:default".url
  #   - Actual file is served from fill-data.papermc.io
  #
  # Purpur uses its own v2 API (api.purpurmc.org/v2) which is still live.
  #
  local project="$1"
  local jar_url=""
  local resolved_version="$SERVER_VERSION"

  case "$project" in
    paper|velocity|waterfall)
      local fill_base="https://fill.papermc.io/v3/projects/${project}"

      if [[ "$resolved_version" == "latest" ]]; then
        # The Fill v3 /projects/<project> response groups versions by major.
        # Structure: { "versions": { "26.2": ["26.2", ...], "1.21": ["1.21.11", ...], ... } }
        # We grab the first sub-version of the first major group (newest).
        resolved_version="$(
          fetch_json "${fill_base}" \
          | jq -r '[.versions | to_entries[] | .value[]] | map(select(test("^[0-9]+(\\.[0-9]+)*$"))) | first'
        )"
        if [[ -z "$resolved_version" || "$resolved_version" == "null" ]]; then
          say_fail "Could not resolve latest version for ${project} from Fill API."
          exit 1
        fi
      fi

      # Get builds for this version, pick the latest STABLE one.
      # Builds endpoint returns a flat JSON array of build objects.
      local builds_json
      builds_json="$(fetch_json "${fill_base}/versions/${resolved_version}/builds")"

      local jar_url_resolved
      jar_url_resolved="$(
        echo "$builds_json" \
        | jq -r '[
            .[] | select(.channel == "STABLE")
          ] | if length > 0 then .[-1] else empty end
            | .downloads."server:default".url'
      )"

      # Fallback: if no STABLE build, take the latest of any channel
      if [[ -z "$jar_url_resolved" || "$jar_url_resolved" == "null" ]]; then
        jar_url_resolved="$(
          echo "$builds_json" \
          | jq -r '.[-1].downloads."server:default".url'
        )"
      fi

      if [[ -z "$jar_url_resolved" || "$jar_url_resolved" == "null" ]]; then
        say_fail "Could not resolve a download URL for ${project} ${resolved_version}."
        say_fail "The Fill API returned no builds with a 'server:default' download."
        exit 1
      fi

      jar_url="$jar_url_resolved"
      ;;

    purpur)
      # Purpur's own API v2 is still live and working.
      local purpur_base="https://api.purpurmc.org/v2/purpur"
      if [[ "$resolved_version" == "latest" ]]; then
        resolved_version="$(fetch_json "${purpur_base}" | jq -r '.versions[-1]')"
      fi
      local latest_build
      latest_build="$(fetch_json "${purpur_base}/${resolved_version}" | jq -r '.builds.latest')"
      jar_url="${purpur_base}/${resolved_version}/${latest_build}/download"
      ;;
  esac

  SERVER_VERSION="$resolved_version"
  fetch_url "$jar_url" "$MC_ROOT/server.jar"
}

download_vanilla() {
  local manifest_url="https://launchermeta.mojang.com/mc/game/version_manifest_v2.json"
  local manifest
  manifest="$(fetch_json "$manifest_url")"

  local resolved_version="$SERVER_VERSION"
  if [[ "$resolved_version" == "latest" ]]; then
    resolved_version="$(echo "$manifest" | jq -r '.latest.release')"
  fi

  local version_url
  version_url="$(echo "$manifest" | jq -r --arg v "$resolved_version" '.versions[] | select(.id==$v) | .url')"
  if [[ -z "$version_url" || "$version_url" == "null" ]]; then
    say_fail "Could not find vanilla Minecraft version '${resolved_version}'."
    exit 1
  fi

  local server_jar_url
  server_jar_url="$(fetch_json "$version_url" | jq -r '.downloads.server.url')"

  SERVER_VERSION="$resolved_version"
  fetch_url "$server_jar_url" "$MC_ROOT/server.jar"
}

download_fabric() {
  local installer_meta="https://meta.fabricmc.net/v2/versions/installer"
  local installer_ver
  installer_ver="$(fetch_json "$installer_meta" | jq -r '.[0].version')"

  local mc_ver="$SERVER_VERSION"
  if [[ "$mc_ver" == "latest" ]]; then
    mc_ver="$(fetch_json "https://meta.fabricmc.net/v2/versions/game" | jq -r '[.[] | select(.stable==true)][0].version')"
  fi

  local loader_ver
  loader_ver="$(fetch_json "https://meta.fabricmc.net/v2/versions/loader/${mc_ver}" | jq -r '[.[] | select(.loader.stable==true)][0].loader.version')"

  local installer_jar_url="https://meta.fabricmc.net/v2/versions/loader/${mc_ver}/${loader_ver}/${installer_ver}/server/jar"

  SERVER_VERSION="$mc_ver"
  fetch_url "$installer_jar_url" "$MC_ROOT/server.jar"
}

download_bungeecord() {
  local jar_url="https://ci.md-5.net/job/BungeeCord/lastSuccessfulBuild/artifact/bootstrap/target/BungeeCord.jar"
  fetch_url "$jar_url" "$MC_ROOT/server.jar"
  SERVER_VERSION="latest-ci"
}

download_server() {
  CURRENT_STEP="download server software"
  section "Server Download"

  case "$SERVER_TYPE" in
    paper|velocity|waterfall) spinner_run "Downloading ${SERVER_TYPE} (${SERVER_VERSION})" download_paper_family "$SERVER_TYPE" ;;
    purpur)                   spinner_run "Downloading purpur (${SERVER_VERSION})" download_paper_family "purpur" ;;
    vanilla)                  spinner_run "Downloading vanilla server (${SERVER_VERSION})" download_vanilla ;;
    fabric)                   spinner_run "Downloading fabric server (${SERVER_VERSION})" download_fabric ;;
    bungeecord)                spinner_run "Downloading BungeeCord (latest CI)" download_bungeecord ;;
    *) say_fail "Unknown server type: ${SERVER_TYPE}"; exit 1 ;;
  esac

  if [[ ! -s "$MC_ROOT/server.jar" ]]; then
    say_fail "Downloaded server jar is missing or empty."
    exit 1
  fi

  chown "${MC_USER}:${MC_GROUP}" "$MC_ROOT/server.jar"
  say_ok "Server jar ready: $(du -h "$MC_ROOT/server.jar" | cut -f1) — version ${SERVER_VERSION}"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: JVM FLAGS (RAM-AWARE, AIKAR-STYLE)
# ═════════════════════════════════════════════════════════════════════════

select_ram_allocation() {
  CURRENT_STEP="select RAM allocation"
  section "Memory Allocation"

  local max_safe_mb=$(( TOTAL_RAM_MB - 512 ))
  if (( max_safe_mb < 512 )); then max_safe_mb=512; fi

  if [[ -z "$RAM_ALLOC" ]]; then
    local suggested
    if   (( TOTAL_RAM_MB >= 65536 )); then suggested="32G"
    elif (( TOTAL_RAM_MB >= 32768 )); then suggested="16G"
    elif (( TOTAL_RAM_MB >= 16384 )); then suggested="8G"
    elif (( TOTAL_RAM_MB >= 8192 ));  then suggested="4G"
    elif (( TOTAL_RAM_MB >= 4096 ));  then suggested="2G"
    else suggested="1G"
    fi
    RAM_ALLOC="$(ask "RAM to allocate to the server (e.g. 4G) — max safe: ${max_safe_mb}M" "$suggested")"
  fi

  local ram_mb
  ram_mb="$(normalize_ram_to_mb "$RAM_ALLOC")"
  if (( ram_mb > max_safe_mb )); then
    say_warn "Requested ${RAM_ALLOC} exceeds safe headroom. Capping to ${max_safe_mb}M to avoid OOM."
    RAM_ALLOC="${max_safe_mb}M"
  fi

  say_ok "Allocated RAM: ${RAM_ALLOC}"
}

normalize_ram_to_mb() {
  local val="$1"
  if [[ "$val" =~ ^([0-9]+)[Gg]$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$val" =~ ^([0-9]+)[Mm]$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "2048"
  fi
}

generate_jvm_flags() {
  CURRENT_STEP="generate JVM flags"
  local ram_mb
  ram_mb="$(normalize_ram_to_mb "$RAM_ALLOC")"

  # Aikar's flags — proven G1GC tuning for Minecraft server workloads.
  JVM_FLAGS="-Xms${RAM_ALLOC} -Xmx${RAM_ALLOC} \
-XX:+UseG1GC \
-XX:+ParallelRefProcEnabled \
-XX:MaxGCPauseMillis=200 \
-XX:+UnlockExperimentalVMOptions \
-XX:+DisableExplicitGC \
-XX:+AlwaysPreTouch \
-XX:G1NewSizePercent=30 \
-XX:G1MaxNewSizePercent=40 \
-XX:G1HeapRegionSize=8M \
-XX:G1ReservePercent=20 \
-XX:G1HeapWastePercent=5 \
-XX:G1MixedGCCountTarget=4 \
-XX:InitiatingHeapOccupancyPercent=15 \
-XX:G1MixedGCLiveThresholdPercent=90 \
-XX:G1RSetUpdatingPauseTimePercent=5 \
-XX:SurvivorRatio=32 \
-XX:+PerfDisableSharedMem \
-XX:MaxTenuringThreshold=1 \
-Dusing.aikars.flags=https://mcflags.emc.gs \
-Daikars.new.flags=true"

  # Small-heap systems don't benefit from (and can be hurt by) some G1 tuning.
  if (( ram_mb < 2048 )); then
    JVM_FLAGS="-Xms${RAM_ALLOC} -Xmx${RAM_ALLOC} -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
  fi

  say_ok "JVM flags generated for ${RAM_ALLOC} heap"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: SERVER CONFIGURATION (server.properties, eula.txt)
# ═════════════════════════════════════════════════════════════════════════

configure_server_properties() {
  CURRENT_STEP="configure server.properties"
  section "Server Configuration"

  local srv_name motd difficulty gamemode online_mode max_players
  local view_dist sim_dist pvp spawn_protect whitelist nether end cmdblocks

  srv_name="$(ask "Server name" "My Minecraft Server")"
  motd="$(ask "MOTD (message of the day)" "A Minecraft Server")"
  difficulty="$(ask_choice "Difficulty" "3" "peaceful" "easy" "normal" "hard")"
  case "$difficulty" in 1) difficulty="peaceful";; 2) difficulty="easy";; 3) difficulty="normal";; 4) difficulty="hard";; esac

  gamemode="$(ask_choice "Default gamemode" "1" "survival" "creative" "adventure" "spectator")"
  case "$gamemode" in 1) gamemode="survival";; 2) gamemode="creative";; 3) gamemode="adventure";; 4) gamemode="spectator";; esac

  if [[ -n "$CRACKED_MODE" ]]; then
    if [[ "$CRACKED_MODE" == "yes" ]]; then online_mode="false"; else online_mode="true"; fi
  else
    if confirm "Allow cracked / non-premium (offline-mode) clients to join?"; then
      online_mode="false"
    else
      online_mode="true"
    fi
  fi

  max_players="$(ask "Max players" "20")"
  view_dist="$(ask "View distance (chunks)" "10")"
  sim_dist="$(ask "Simulation distance (chunks)" "10")"
  pvp="$(confirm "Enable PVP?" && echo true || echo true)"
  spawn_protect="$(ask "Spawn protection radius" "0")"
  whitelist="$(confirm "Enable whitelist?" && echo true || echo false)"
  nether="$(confirm "Allow the Nether?" && echo true || echo true)"
  end="true"
  cmdblocks="$(confirm "Enable command blocks?" && echo true || echo false)"

  cat > "$MC_ROOT/server.properties" <<EOF
# Generated by Minecraft Deployment Utility on $(date -Iseconds)
server-name=${srv_name}
motd=${motd}
difficulty=${difficulty}
gamemode=${gamemode}
online-mode=${online_mode}
max-players=${max_players}
view-distance=${view_dist}
simulation-distance=${sim_dist}
pvp=${pvp}
spawn-protection=${spawn_protect}
white-list=${whitelist}
allow-nether=${nether}
allow-end=${end}
enable-command-block=${cmdblocks}
server-port=25565
enable-rcon=false
level-name=world
resource-pack=
require-resource-pack=false
enforce-secure-profile=$( [[ "$online_mode" == "false" ]] && echo "false" || echo "true" )
EOF

  chown "${MC_USER}:${MC_GROUP}" "$MC_ROOT/server.properties"
  say_ok "server.properties written (online-mode=${online_mode})"

  if [[ "$online_mode" == "false" ]]; then
    say_info "Cracked/offline-mode clients are permitted to join this server."
  fi
}

accept_eula() {
  CURRENT_STEP="accept Minecraft EULA"
  section "Minecraft EULA"

  echo "  Running a Minecraft server requires accepting Mojang's End User"
  echo "  License Agreement: ${C_CYAN}https://aka.ms/MinecraftEULA${C_RESET}"
  echo

  local accepted="$EULA_ACCEPT"
  if [[ -z "$accepted" ]]; then
    if confirm "Do you accept the Minecraft EULA?"; then
      accepted="true"
    else
      accepted="false"
    fi
  fi

  if [[ "$accepted" != "true" ]]; then
    say_fail "EULA not accepted. The server cannot legally run without this. Aborting."
    exit 1
  fi

  echo "eula=true" > "$MC_ROOT/eula.txt"
  chown "${MC_USER}:${MC_GROUP}" "$MC_ROOT/eula.txt"
  say_ok "EULA accepted and recorded"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: GEYSER (BEDROCK CROSS-PLAY)
# ═════════════════════════════════════════════════════════════════════════

install_geyser() {
  CURRENT_STEP="install Geyser"
  section "Geyser (Bedrock Cross-Play)"

  if [[ "$SERVER_TYPE" != "paper" && "$SERVER_TYPE" != "purpur" ]]; then
    say_warn "Geyser plugin install is only automated for Paper/Purpur. Skipping."
    return
  fi

  mkdir -p "$MC_ROOT/plugins"
  local geyser_url="https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot"
  local floodgate_url="https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot"

  spinner_run "Downloading Geyser (Spigot/Paper build)" fetch_url "$geyser_url" "$MC_ROOT/plugins/Geyser-Spigot.jar"

  local install_floodgate="no"
  if [[ "$INSTALL_GEYSER" == "geyser+floodgate" ]]; then
    install_floodgate="yes"
  elif [[ "$UNATTENDED" -eq 0 && -z "$INSTALL_GEYSER" ]]; then
    if confirm "Also install Floodgate (lets Bedrock players join without a linked Java account, works well with cracked mode)?"; then
      install_floodgate="yes"
    fi
  fi

  if [[ "$install_floodgate" == "yes" ]]; then
    spinner_run "Downloading Floodgate (Spigot/Paper build)" fetch_url "$floodgate_url" "$MC_ROOT/plugins/floodgate-spigot.jar"
  fi

  chown -R "${MC_USER}:${MC_GROUP}" "$MC_ROOT/plugins"
  say_ok "Geyser installed — Bedrock clients can connect on UDP port 19132"
  say_info "Bedrock port 19132/udp will be opened in the firewall step."
  GEYSER_INSTALLED=1
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: FIREWALL
# ═════════════════════════════════════════════════════════════════════════

configure_firewall() {
  CURRENT_STEP="configure firewall"
  section "Firewall"

  if ! command -v ufw >/dev/null 2>&1; then
    say_warn "ufw not available, skipping firewall configuration."
    return
  fi

  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  say_ok "Allowed SSH (22/tcp)"

  local mc_port=25565
  ufw allow "${mc_port}/tcp" >/dev/null 2>&1
  say_ok "Allowed Minecraft Java port (${mc_port}/tcp)"

  if [[ "${GEYSER_INSTALLED:-0}" -eq 1 ]]; then
    ufw allow 19132/udp >/dev/null 2>&1
    say_ok "Allowed Geyser Bedrock port (19132/udp)"
  fi

  if ufw status | grep -q "Status: active"; then
    say_ok "Firewall already active"
  else
    ufw --force enable >/dev/null 2>&1
    say_ok "Firewall enabled"
  fi
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: SYSTEMD SERVICE (MINECRAFT)
# ═════════════════════════════════════════════════════════════════════════

create_start_script() {
  CURRENT_STEP="create start script"

  cat > "$MC_ROOT/start.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${MC_ROOT}"
exec java ${JVM_FLAGS} -jar server.jar --nogui
EOF
  chmod 750 "$MC_ROOT/start.sh"
  chown "${MC_USER}:${MC_GROUP}" "$MC_ROOT/start.sh"
  say_ok "Start script written to ${MC_ROOT}/start.sh"
}

create_systemd_service() {
  CURRENT_STEP="create systemd service"
  section "Systemd Service"

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Minecraft Server (${SERVER_TYPE})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${MC_USER}
Group=${MC_GROUP}
WorkingDirectory=${MC_ROOT}
ExecStart=${MC_ROOT}/start.sh
Restart=always
RestartSec=10
TimeoutStopSec=60
KillMode=mixed
KillSignal=SIGTERM
SendSIGKILL=yes

# Resource / security hardening
Nice=-2
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${MC_ROOT}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1
  say_ok "Systemd service '${SERVICE_NAME}' created and enabled on boot"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: ONE-WORD COMMANDS (mcstart, mcstop, mcrestart, mcstatus, ...)
# ═════════════════════════════════════════════════════════════════════════

install_one_word_commands() {
  CURRENT_STEP="install one-word commands"
  section "Quick Commands"

  local bin_dir="/usr/local/bin"

  cat > "${bin_dir}/mcstart" <<EOF
#!/usr/bin/env bash
sudo systemctl start ${SERVICE_NAME}
echo "Server starting. Check status with: mcstatus"
EOF

  cat > "${bin_dir}/mcstop" <<EOF
#!/usr/bin/env bash
sudo systemctl stop ${SERVICE_NAME}
echo "Server stopped."
EOF

  cat > "${bin_dir}/mcrestart" <<EOF
#!/usr/bin/env bash
sudo systemctl restart ${SERVICE_NAME}
echo "Server restarting. Check status with: mcstatus"
EOF

  cat > "${bin_dir}/mcstatus" <<EOF
#!/usr/bin/env bash
sudo systemctl status ${SERVICE_NAME} --no-pager
EOF

  cat > "${bin_dir}/mcconsole" <<EOF
#!/usr/bin/env bash
echo "Attached to live server output. Press Ctrl+C to detach (server keeps running)."
sudo -u ${MC_USER} tail -f ${MC_ROOT}/logs/latest.log
EOF

  cat > "${bin_dir}/mclogs" <<EOF
#!/usr/bin/env bash
sudo journalctl -u ${SERVICE_NAME} -f --no-pager
EOF

  cat > "${bin_dir}/mcbackup" <<EOF
#!/usr/bin/env bash
sudo -u ${MC_USER} ${MC_ROOT}/backup.sh
EOF

  chmod 755 "${bin_dir}/mcstart" "${bin_dir}/mcstop" "${bin_dir}/mcrestart" \
    "${bin_dir}/mcstatus" "${bin_dir}/mcconsole" "${bin_dir}/mclogs" "${bin_dir}/mcbackup"

  say_ok "Installed commands: mcstart, mcstop, mcrestart, mcstatus, mcconsole, mclogs, mcbackup"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: SHELL EXPERIENCE (zsh + Starship on the VPS)
# ═════════════════════════════════════════════════════════════════════════

install_shell_experience() {
  CURRENT_STEP="install zsh and Starship"
  section "Terminal Experience"

  local want_shell="$INSTALL_SHELL"
  if [[ -z "$want_shell" ]]; then
    if confirm "Install zsh + Starship prompt for a nicer-looking terminal on this VPS?"; then
      want_shell="yes"
    else
      want_shell="no"
    fi
  fi

  if [[ "$want_shell" != "yes" ]]; then
    say_info "Skipping shell customization."
    return
  fi

  spinner_run "Installing zsh" apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    zsh

  if ! command -v starship >/dev/null 2>&1; then
    spinner_run "Installing Starship prompt" bash -c 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y'
  fi

  spinner_run "Installing zsh-autosuggestions" git clone --depth=1 \
    https://github.com/zsh-users/zsh-autosuggestions \
    "${HOME}/.zsh-autosuggestions" 2>/dev/null || true

  spinner_run "Installing zsh-syntax-highlighting" git clone --depth=1 \
    https://github.com/zsh-users/zsh-syntax-highlighting \
    "${HOME}/.zsh-syntax-highlighting" 2>/dev/null || true

  local target_user="${SUDO_USER:-root}"
  local target_home
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  target_home="${target_home:-/root}"

  local zshrc="${target_home}/.zshrc"
  touch "$zshrc"

  if ! grep -q "starship init zsh" "$zshrc" 2>/dev/null; then
    {
      echo ''
      echo '# --- Minecraft Deployment Utility: shell setup ---'
      echo '[[ -f ~/.zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source ~/.zsh-autosuggestions/zsh-autosuggestions.zsh'
      echo '[[ -f ~/.zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source ~/.zsh-syntax-highlighting/zsh-syntax-highlighting.zsh'
      echo 'eval "$(starship init zsh)"'
      echo 'alias ll="ls -lah"'
    } >> "$zshrc"
  fi

  mkdir -p "${target_home}/.config"
  cat > "${target_home}/.config/starship.toml" <<'EOF'
# Minecraft Deployment Utility — Starship prompt
add_newline = true

[character]
success_symbol = "[➜](bold green)"
error_symbol = "[➜](bold red)"

[directory]
truncation_length = 3
style = "bold cyan"

[git_branch]
symbol = " "
style = "bold purple"

[cmd_duration]
min_time = 2000
format = "took [$duration](yellow) "
EOF

  chown -R "${target_user}:${target_user}" "${target_home}/.zsh-autosuggestions" \
    "${target_home}/.zsh-syntax-highlighting" "${target_home}/.config/starship.toml" "$zshrc" 2>/dev/null || true

  chsh -s "$(command -v zsh)" "$target_user" >/dev/null 2>&1 || true

  say_ok "zsh + Starship installed for user '${target_user}'"
  say_info "Log out and back in (or run 'zsh') to see the new prompt."
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: PLAYIT.GG TUNNEL
# ═════════════════════════════════════════════════════════════════════════

install_playit() {
  CURRENT_STEP="install Playit.gg"
  section "Playit.gg Tunnel"

  local do_install="$INSTALL_PLAYIT"
  if [[ -z "$do_install" ]]; then
    if confirm "Install Playit.gg to expose your server to the internet without port forwarding?"; then
      do_install="yes"
    else
      do_install="no"
    fi
  fi

  if [[ "$do_install" != "yes" ]]; then
    say_info "Skipping Playit.gg."
    return
  fi

  spinner_run "Adding Playit.gg apt repository" bash -c '
    curl -SsL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/playit.gpg
    echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" > /etc/apt/sources.list.d/playit-cloud.list
    apt-get update -y
  '

  spinner_run "Installing playit package" apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    playit

  systemctl enable playit >/dev/null 2>&1 || true
  systemctl restart playit >/dev/null 2>&1 || systemctl start playit >/dev/null 2>&1 || true

  section "Playit.gg — Link This Agent"
  echo "  Playit needs to be linked to your playit.gg account before it can"
  echo "  create a tunnel. This installer will now watch the agent's log for"
  echo "  a claim link. When it appears:"
  echo
  echo "    1. Open the ${C_CYAN}claim URL${C_RESET} shown below in any browser"
  echo "       (on your phone, PC — doesn't need to be this machine)"
  echo "    2. Log in or create a free playit.gg account"
  echo "    3. On the account setup page, choose ${C_WHITE}\"Your Computer\"${C_RESET} as the"
  echo "       integration type — this Linux server is treated as a computer"
  echo "    4. If asked for a claim code directly, enter the code segment"
  echo "       from the same URL (the part after ${C_GRAY}/claim/${C_RESET})"
  echo "    5. Approve the agent and select a Minecraft Java tunnel pointing"
  echo "       at ${C_WHITE}127.0.0.1:25565${C_RESET} (defaults are already correct)"
  echo

  local claim_line=""
  local waited=0
  local max_wait=180
  say_step "Waiting for claim URL from the playit agent..."
  while (( waited < max_wait )); do
    claim_line="$(journalctl -u playit -n 50 --no-pager 2>/dev/null | grep -Eo 'https://playit\.gg/claim/[A-Za-z0-9_-]+' | tail -1 || true)"
    if [[ -n "$claim_line" ]]; then
      break
    fi
    sleep 2
    waited=$(( waited + 2 ))
    printf '\r  %swaiting...%s (%ds)' "$C_GRAY" "$C_RESET" "$waited"
  done
  echo

  if [[ -n "$claim_line" ]]; then
    local claim_code="${claim_line##*/}"
    ui_rule
    printf '  %sCLAIM URL:%s    %s%s%s\n' "$C_WHITE$C_BOLD" "$C_RESET" "$C_CYAN$C_BOLD" "$claim_line" "$C_RESET"
    printf '  %sCLAIM CODE:%s   %s%s%s\n' "$C_WHITE$C_BOLD" "$C_RESET" "$C_YELLOW$C_BOLD" "$claim_code" "$C_RESET"
    # Print an OSC 8 hyperlink so Termux users can just tap it to open the browser
    printf '  %sLINK (TAP ME):%s \e]8;;%s\a%s\e]8;;\a\n' "$C_WHITE$C_BOLD" "$C_RESET" "$claim_line" "Link Playit.gg Account"
    ui_rule
    say_info "Open the URL (or tap the link), enter the claim code if asked, and approve the agent."
  else
    say_warn "Could not automatically detect the claim URL within ${max_wait}s."
    say_warn "Run 'sudo journalctl -u playit -f' manually to find it, or run 'sudo playit setup'."
  fi

  if [[ "$UNATTENDED" -eq 0 ]]; then
    read -r -p "  Press Enter once you've approved the agent in your browser (or skip)... " < /dev/tty || true
  fi

  say_ok "Playit.gg agent installed and running as a systemd service"
  say_info "Manage it with: systemctl status playit | systemctl restart playit"
  PLAYIT_INSTALLED=1
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: BACKUPS
# ═════════════════════════════════════════════════════════════════════════

install_backup_system() {
  CURRENT_STEP="install backup system"
  section "Backup System"

  cat > "$MC_ROOT/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MC_ROOT="/opt/minecraft"
BACKUP_DIR="${MC_ROOT}/backups"
RETENTION_DAYS=7
TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/world-backup-${TS}.tar.gz"

mkdir -p "$BACKUP_DIR"
tar -czf "$ARCHIVE" -C "$MC_ROOT" world world_nether world_the_end server.properties 2>/dev/null || \
  tar -czf "$ARCHIVE" -C "$MC_ROOT" world 2>/dev/null || true

find "$BACKUP_DIR" -name 'world-backup-*.tar.gz' -mtime "+${RETENTION_DAYS}" -delete

echo "Backup complete: ${ARCHIVE}"
EOF

  chmod 750 "$MC_ROOT/backup.sh"
  chown "${MC_USER}:${MC_GROUP}" "$MC_ROOT/backup.sh"

  # Nightly backup at 4 AM via cron, run as the minecraft user.
  local cron_line="0 4 * * * ${MC_USER} ${MC_ROOT}/backup.sh >> ${MC_ROOT}/logs/backup.log 2>&1"
  local cron_file="/etc/cron.d/minecraft-backup"
  echo "$cron_line" > "$cron_file"
  chmod 644 "$cron_file"

  say_ok "Backup script installed at ${MC_ROOT}/backup.sh"
  say_ok "Nightly backup scheduled for 04:00 (7-day retention)"
  say_info "Run a manual backup anytime: sudo -u ${MC_USER} ${MC_ROOT}/backup.sh"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: STATE PERSISTENCE (for update/repair/uninstall modes)
# ═════════════════════════════════════════════════════════════════════════

save_state() {
  cat > "$STATE_FILE" <<EOF
SERVER_TYPE=${SERVER_TYPE}
SERVER_VERSION=${SERVER_VERSION}
RAM_ALLOC=${RAM_ALLOC}
PLAYIT_INSTALLED=${PLAYIT_INSTALLED:-0}
GEYSER_INSTALLED=${GEYSER_INSTALLED:-0}
INSTALL_DATE=$(date -Iseconds)
EOF
  chown "${MC_USER}:${MC_GROUP}" "$STATE_FILE" 2>/dev/null || true
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    say_fail "No existing installation state found at ${STATE_FILE}."
    say_fail "Run a fresh install first."
    exit 1
  fi
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: FIRST START & VERIFICATION
# ═════════════════════════════════════════════════════════════════════════

start_server_first_time() {
  CURRENT_STEP="start Minecraft server"
  section "Starting Server"

  systemctl restart "${SERVICE_NAME}.service"

  local waited=0 max_wait=90 up=0
  say_step "Waiting for server to come online..."
  while (( waited < max_wait )); do
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
      if grep -q "Done" "$MC_ROOT/logs/latest.log" 2>/dev/null; then
        up=1
        break
      fi
    else
      break
    fi
    sleep 2
    waited=$(( waited + 2 ))
    printf '\r  %swaiting...%s (%ds)' "$C_GRAY" "$C_RESET" "$waited"
  done
  echo

  if [[ "$up" -eq 1 ]]; then
    say_ok "Server started successfully"
  elif systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    say_warn "Server process is running but startup completion wasn't confirmed in logs yet."
    say_info "Check status: systemctl status ${SERVICE_NAME}"
  else
    say_fail "Server failed to start. Check logs: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
    exit 1
  fi
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: FINAL SUMMARY SCREEN
# ═════════════════════════════════════════════════════════════════════════

print_final_summary() {
  local ip_addr
  ip_addr="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")"

  echo
  ui_box_top
  ui_box_line "Installation Complete"
  ui_box_bottom
  echo
  say_ok "Server software : ${SERVER_TYPE} (${SERVER_VERSION})"
  say_ok "Install path    : ${MC_ROOT}"
  say_ok "RAM allocated   : ${RAM_ALLOC}"
  say_ok "Java version    : $(java -version 2>&1 | head -1)"
  say_ok "Systemd service : ${SERVICE_NAME}.service (enabled on boot)"
  say_ok "Direct connect  : ${ip_addr}:25565"

  if [[ "${GEYSER_INSTALLED:-0}" -eq 1 ]]; then
    say_ok "Bedrock connect : ${ip_addr}:19132 (via Geyser)"
  fi

  if [[ "${PLAYIT_INSTALLED:-0}" -eq 1 ]]; then
    say_ok "Playit.gg       : installed — check your playit.gg dashboard for your public address"
  fi

  echo
  section "Useful Commands"
  echo "  Start server      : sudo systemctl start ${SERVICE_NAME}"
  echo "  Stop server       : sudo systemctl stop ${SERVICE_NAME}"
  echo "  Restart server    : sudo systemctl restart ${SERVICE_NAME}"
  echo "  Live status       : sudo systemctl status ${SERVICE_NAME}"
  echo "  Live logs         : sudo journalctl -u ${SERVICE_NAME} -f"
  echo "  Manual backup     : sudo -u ${MC_USER} ${MC_ROOT}/backup.sh"
  echo "  Attach console    : sudo -u ${MC_USER} tail -f ${MC_ROOT}/logs/latest.log"
  echo "  Update server     : sudo bash install.sh --update"
  echo "  Repair install    : sudo bash install.sh --repair"
  echo "  Uninstall         : sudo bash install.sh --uninstall"
  echo
  say_info "Full installer log saved to: ${LOG_FILE}"
  echo
  echo "  Thanks for using the Minecraft Deployment Utility. Have fun."
  echo
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: UPDATE MODE
# ═════════════════════════════════════════════════════════════════════════

run_update_mode() {
  ui_banner
  section "Update Mode"
  load_state
  check_root
  detect_resources

  say_info "Current: ${SERVER_TYPE} ${SERVER_VERSION}"
  systemctl stop "${SERVICE_NAME}.service" || true

  cp "$MC_ROOT/server.jar" "$MC_ROOT/backups/server.jar.pre-update.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

  SERVER_VERSION="latest"
  download_server

  systemctl start "${SERVICE_NAME}.service"
  save_state
  say_ok "Update complete. Server restarted on ${SERVER_TYPE} ${SERVER_VERSION}."
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: REPAIR MODE
# ═════════════════════════════════════════════════════════════════════════

run_repair_mode() {
  ui_banner
  section "Repair Mode"
  check_root
  load_state

  say_step "Repairing file permissions"
  chown -R "${MC_USER}:${MC_GROUP}" "$MC_ROOT"
  chmod -R 750 "$MC_ROOT"
  say_ok "Permissions restored"

  say_step "Repairing Java installation"
  install_java

  say_step "Repairing systemd service"
  create_start_script
  RAM_ALLOC="${RAM_ALLOC:-2G}"
  generate_jvm_flags
  create_start_script
  create_systemd_service

  if systemctl list-unit-files | grep -q '^playit.service'; then
    say_step "Repairing Playit.gg service"
    systemctl restart playit 2>/dev/null || systemctl start playit 2>/dev/null || true
    say_ok "Playit.gg service restarted"
  fi

  systemctl daemon-reload
  say_ok "Repair complete. Try: sudo systemctl restart ${SERVICE_NAME}"
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: UNINSTALL MODE
# ═════════════════════════════════════════════════════════════════════════

run_uninstall_mode() {
  ui_banner
  section "Uninstall Mode"
  check_root

  confirm "This will stop and remove the Minecraft systemd service. Continue?" || { say_info "Cancelled."; exit 0; }

  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  say_ok "Removed systemd service"

  if confirm "Delete the server directory and all world data (${MC_ROOT})?"; then
    rm -rf "$MC_ROOT"
    say_ok "Deleted ${MC_ROOT}"
  else
    say_info "Kept ${MC_ROOT}"
  fi

  if systemctl list-unit-files | grep -q '^playit.service'; then
    if confirm "Remove Playit.gg as well?"; then
      systemctl stop playit 2>/dev/null || true
      systemctl disable playit 2>/dev/null || true
      apt-get remove -y playit >/dev/null 2>&1 || true
      rm -f /etc/apt/sources.list.d/playit-cloud.list /etc/apt/trusted.gpg.d/playit.gpg
      say_ok "Removed Playit.gg"
    fi
  fi

  if confirm "Remove Java (openjdk-21-jre-headless)?"; then
    apt-get remove -y openjdk-21-jre-headless >/dev/null 2>&1 || true
    say_ok "Removed Java"
  fi

  if confirm "Remove the '${MC_USER}' system user?"; then
    userdel "$MC_USER" 2>/dev/null || true
    say_ok "Removed user ${MC_USER}"
  fi

  say_ok "Uninstall complete."
}

# ═════════════════════════════════════════════════════════════════════════
#  SECTION: ARGUMENT PARSING
# ═════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Minecraft Deployment Utility v${SCRIPT_VERSION}

Usage:
  install.sh [options]
  install.sh --update
  install.sh --repair
  install.sh --uninstall

Options:
  --unattended              Run non-interactively using defaults/flags below
  --server-type=TYPE        paper|purpur|fabric|vanilla|velocity|waterfall|bungeecord
  --server-version=VER      Minecraft version, or "latest"
  --ram=SIZE                e.g. 4G, 8G, 2048M
  --playit=yes|no           Install Playit.gg tunnel
  --geyser=yes|no|geyser+floodgate   Install Geyser (Bedrock cross-play)
  --cracked=yes|no          Allow offline-mode (cracked) clients
  --shell=yes|no             Install zsh + Starship terminal prompt
  --accept-eula              Accept the Minecraft EULA non-interactively
  --ssh-link=STRING          (Termux only) SSH link to the VPS, skips the prompt
  --update                  Update existing installation to latest version
  --repair                  Repair permissions/services/Java/Playit
  --uninstall                Remove the installation
  -h, --help                 Show this help text

Notes:
  Running this script inside Termux on Android automatically switches to
  launcher mode: it installs an SSH client locally, connects to your VPS
  using the link you paste (or --ssh-link), and re-runs itself on the VPS.
EOF
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --unattended) UNATTENDED=1 ;;
      --server-type=*) SERVER_TYPE="${arg#*=}" ;;
      --server-version=*) SERVER_VERSION="${arg#*=}" ;;
      --ram=*) RAM_ALLOC="${arg#*=}" ;;
      --playit=*) INSTALL_PLAYIT="${arg#*=}" ;;
      --geyser=*) INSTALL_GEYSER="${arg#*=}" ;;
      --cracked=*) CRACKED_MODE="${arg#*=}" ;;
      --shell=*) INSTALL_SHELL="${arg#*=}" ;;
      --accept-eula) EULA_ACCEPT="true" ;;
      --ssh-link=*) SSH_LINK_RAW="${arg#*=}" ;;
      --update) MODE="update" ;;
      --repair) MODE="repair" ;;
      --uninstall) MODE="uninstall" ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
  done
}

# ═════════════════════════════════════════════════════════════════════════
#  MAIN INSTALL FLOW
# ═════════════════════════════════════════════════════════════════════════

run_install_mode() {
  ui_banner
  log_init
  acquire_lock

  section "Pre-Flight Checks"
  check_root
  detect_os
  detect_arch
  detect_virt
  check_apt
  check_internet
  detect_resources

  install_packages
  create_system_user
  create_directory_structure

  select_server_type
  select_server_version
  download_server

  select_ram_allocation
  generate_jvm_flags

  configure_server_properties
  accept_eula

  if [[ "$SERVER_TYPE" == "paper" || "$SERVER_TYPE" == "purpur" ]]; then
    local want_geyser="$INSTALL_GEYSER"
    if [[ -z "$want_geyser" ]]; then
      if confirm "Install Geyser for Bedrock Edition cross-play support?"; then
        want_geyser="yes"
      else
        want_geyser="no"
      fi
    fi
    if [[ "$want_geyser" == "yes" || "$want_geyser" == "geyser+floodgate" ]]; then
      install_geyser
    fi
  fi

  create_start_script
  create_systemd_service
  install_one_word_commands
  configure_firewall
  install_backup_system

  install_playit
  install_shell_experience

  start_server_first_time
  save_state
  print_final_summary
}

# ═════════════════════════════════════════════════════════════════════════
#  ENTRYPOINT
# ═════════════════════════════════════════════════════════════════════════

main() {
  parse_args "$@"
  setup_temp_dir
  setup_logging_and_locks

  if is_termux_environment && [[ "$MODE" == "install" ]]; then
    termux_launcher_flow
    exit 0
  fi

  case "$MODE" in
    install)   run_install_mode ;;
    update)    run_update_mode ;;
    repair)    run_repair_mode ;;
    uninstall) run_uninstall_mode ;;
    *) echo "Unknown mode: $MODE"; exit 1 ;;
  esac
}

main "$@"
