#!/usr/bin/env bash
#
# setup-nfs-server.sh - Install an NFS server and export directories interactively.
#
# For each export, asks for the directory, which clients may mount it,
# read-write or read-only, sync or async, root squashing, and who should own
# the directory (nobody, an existing user, or a new user with a fixed UID
# that matches your clients). Then updates /etc/exports, the firewall and
# SELinux. Can loop to add several exports in one run.
#
# Supported: RHEL family (RHEL, Rocky, Alma, CentOS Stream, Fedora)
#            Debian family (Debian, Ubuntu)
#
set -Eeuo pipefail

# ===== BEGIN COMMON HELPERS (keep in sync with templates/script-skeleton.sh) =====
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_DIR="/var/log/bash-scripts"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
DRY_RUN="${DRY_RUN:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
OS_ID=""
OS_VERSION_MAJOR=""
OS_FAMILY=""
OS_PRETTY=""
FW_BACKEND=""
PKG_UPDATED=0
ASK_SECRET_GENERATED=0 # set to 1 by ask_secret when it generated the password

if [[ -t 2 ]]; then
    C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_BLU=$'\e[34m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
else
    C_RED="" C_GRN="" C_YLW="" C_BLU="" C_BLD="" C_RST=""
fi

# --- logging ----------------------------------------------------------------
_log() {
    local level=$1 color=$2
    shift 2
    printf '%s[%s]%s %s\n' "$color" "$level" "$C_RST" "$*" >&2
    if [[ -w "$LOG_DIR" ]]; then
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE"
    fi
}
log_info() { _log INFO "$C_GRN" "$@"; }
log_warn() { _log WARN "$C_YLW" "$@"; }
log_error() { _log ERROR "$C_RED" "$@"; }
log_step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST" >&2; }
die() {
    log_error "$@"
    exit 1
}
trap 'log_error "Command failed (exit $?) at line ${LINENO}: ${BASH_COMMAND}"' ERR

init_log() {
    if [[ $EUID -eq 0 && "$DRY_RUN" != 1 ]]; then
        mkdir -p "$LOG_DIR"
        chmod 0750 "$LOG_DIR"
        log_info "Logging to ${LOG_FILE}"
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        if [[ "$DRY_RUN" == 1 ]]; then
            log_warn "Not running as root - continuing only because this is a dry run"
        else
            die "This script must be run as root (try: sudo $0)"
        fi
    fi
}

# --- command execution --------------------------------------------------------
# run CMD...  Execute a command, or just print it when DRY_RUN=1.
# Never pipe into run or redirect its output to a file; use here-strings for
# stdin and write_file/append_line_once for files.
run() {
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '%s[dry-run]%s' "$C_BLU" "$C_RST" >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        return 0
    fi
    if [[ -w "$LOG_DIR" ]]; then
        printf '%s [RUN] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
    fi
    "$@"
}

# backup_file PATH  Copy PATH to PATH.bak.<timestamp> if it exists.
backup_file() {
    local path=$1
    if [[ -e "$path" ]]; then
        run cp -a "$path" "${path}.bak.$(date +%Y%m%d%H%M%S)"
    fi
}

# write_file PATH [MODE] <<EOF ... EOF  Back up PATH, then write stdin to it.
write_file() {
    local path=$1 mode=${2:-0644} content
    content="$(cat)"
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '%s[dry-run]%s write %s (mode %s):\n' "$C_BLU" "$C_RST" "$path" "$mode" >&2
        printf '%s\n' "$content" | sed 's/^/    | /' >&2
        return 0
    fi
    backup_file "$path"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" >"$path"
    chmod "$mode" "$path"
    log_info "Wrote ${path}"
}

# append_line_once FILE LINE  Append LINE to FILE unless an identical line exists.
append_line_once() {
    local file=$1 line=$2
    if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
        return 0
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '%s[dry-run]%s append to %s: %s\n' "$C_BLU" "$C_RST" "$file" "$line" >&2
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    # Hand-edited files often lack a final newline; don't glue onto the last line.
    if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
        printf '\n' >>"$file"
    fi
    printf '%s\n' "$line" >>"$file"
}

# --- prompts ------------------------------------------------------------------
# Every prompt is skipped when its variable is already set (from a flag or the
# environment). With NONINTERACTIVE=1 the default is taken silently.

# require_tty "Question"  Die with a clear message when there is no terminal to
# prompt on (ssh without -t, cron, CI) instead of failing inside read.
require_tty() {
    if ! { true </dev/tty; } 2>/dev/null; then
        die "No terminal to ask '${1}' - use --yes and pass the value as a flag or environment variable"
    fi
}

# ask "Question" "default" VAR
ask() {
    local _q=$1 _def=$2 _var=$3 _reply
    if [[ -n "${!_var:-}" ]]; then return 0; fi
    if [[ "$NONINTERACTIVE" == 1 ]]; then
        [[ -n "$_def" ]] || die "No value for '${_q}' - pass it as a flag in non-interactive mode"
        printf -v "$_var" '%s' "$_def"
        return 0
    fi
    require_tty "$_q"
    while true; do
        if [[ -n "$_def" ]]; then
            read -r -p "${_q} [${_def}]: " _reply </dev/tty
        else
            read -r -p "${_q}: " _reply </dev/tty
        fi
        _reply=${_reply:-$_def}
        if [[ -n "$_reply" ]]; then break; fi
        printf 'A value is required.\n' >&2
    done
    printf -v "$_var" '%s' "$_reply"
}

# ask_yn "Question" y|n VAR  Sets VAR to "y" or "n".
ask_yn() {
    local _q=$1 _def=$2 _var=$3 _reply _hint="y/N"
    [[ "$_def" == y ]] && _hint="Y/n"
    if [[ -n "${!_var:-}" ]]; then
        _reply=${!_var}
    elif [[ "$NONINTERACTIVE" == 1 ]]; then
        _reply=$_def
    else
        require_tty "$_q"
        while true; do
            read -r -p "${_q} [${_hint}]: " _reply </dev/tty
            _reply=${_reply:-$_def}
            case "${_reply,,}" in
                y | yes | n | no) break ;;
                *) printf 'Please answer y or n.\n' >&2 ;;
            esac
        done
    fi
    case "${_reply,,}" in
        y | yes | true | 1) printf -v "$_var" 'y' ;;
        *) printf -v "$_var" 'n' ;;
    esac
}
is_yes() { [[ "${1:-}" == y ]]; }

# ask_choice "Question" VAR "key:Description" ...  Sets VAR to the chosen key.
# The first option is the default.
ask_choice() {
    local _q=$1 _var=$2 _opt _reply _i
    shift 2
    local -a _keys=() _descs=()
    for _opt in "$@"; do
        _keys+=("${_opt%%:*}")
        _descs+=("${_opt#*:}")
    done
    if [[ -n "${!_var:-}" ]]; then
        for _opt in "${_keys[@]}"; do
            if [[ "$_opt" == "${!_var}" ]]; then return 0; fi
        done
        die "Invalid value '${!_var}' for '${_q}'. Valid values: ${_keys[*]}"
    fi
    if [[ "$NONINTERACTIVE" == 1 ]]; then
        printf -v "$_var" '%s' "${_keys[0]}"
        return 0
    fi
    require_tty "$_q"
    printf '%s\n' "$_q" >&2
    for _i in "${!_keys[@]}"; do
        printf '  %d) %s\n' "$((_i + 1))" "${_descs[_i]}" >&2
    done
    while true; do
        read -r -p "Choose [1-${#_keys[@]}] (default 1): " _reply </dev/tty
        _reply=${_reply:-1}
        if [[ "$_reply" =~ ^[0-9]+$ ]] && ((_reply >= 1 && _reply <= ${#_keys[@]})); then
            printf -v "$_var" '%s' "${_keys[_reply - 1]}"
            return 0
        fi
        printf 'Invalid choice.\n' >&2
    done
}

# gen_password [LENGTH]  Print a random alphanumeric password.
gen_password() {
    local len=${1:-20} pw
    pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len" || true)
    printf '%s' "$pw"
}

# ask_secret "Question" VAR [gen]  Hidden input, asked twice. With "gen", an
# empty answer (or non-interactive mode) generates a random password.
# shellcheck disable=SC2034  # ASK_SECRET_GENERATED is read by the calling script
ask_secret() {
    local _q=$1 _var=$2 _gen=${3:-} _p1 _p2
    ASK_SECRET_GENERATED=0
    if [[ -n "${!_var:-}" ]]; then return 0; fi
    if [[ "$NONINTERACTIVE" == 1 ]]; then
        [[ "$_gen" == gen ]] || die "No value for '${_q}' - set it via the environment in non-interactive mode"
        printf -v "$_var" '%s' "$(gen_password 20)"
        ASK_SECRET_GENERATED=1
        return 0
    fi
    require_tty "$_q"
    while true; do
        if [[ "$_gen" == gen ]]; then
            read -r -s -p "${_q} (empty = generate): " _p1 </dev/tty
        else
            read -r -s -p "${_q}: " _p1 </dev/tty
        fi
        printf '\n' >&2
        if [[ -z "$_p1" ]]; then
            if [[ "$_gen" == gen ]]; then
                _p1=$(gen_password 20)
                ASK_SECRET_GENERATED=1
                log_info "Generated a random password (shown in the summary)"
                break
            fi
            printf 'A password is required.\n' >&2
            continue
        fi
        read -r -s -p "Confirm: " _p2 </dev/tty
        printf '\n' >&2
        if [[ "$_p1" == "$_p2" ]]; then break; fi
        printf 'Passwords do not match, try again.\n' >&2
    done
    printf -v "$_var" '%s' "$_p1"
}

# --- OS detection & packages -----------------------------------------------
detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
    local info like version
    # Read in a subshell so os-release variables don't leak into this script.
    info=$(
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s|%s|%s|%s' "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}"
    )
    IFS='|' read -r OS_ID like version OS_PRETTY <<<"$info"
    OS_ID=${OS_ID,,}
    OS_VERSION_MAJOR=${version%%.*}
    case " ${OS_ID} ${like,,} " in
        *" rhel "* | *" fedora "* | *" centos "*) OS_FAMILY=rhel ;;
        *" debian "* | *" ubuntu "*) OS_FAMILY=debian ;;
        *) die "Unsupported OS: ${OS_PRETTY:-$OS_ID}" ;;
    esac
    log_info "Detected ${OS_PRETTY:-$OS_ID} (family: ${OS_FAMILY})"
}

# ensure_epel  On the RHEL family, enable EPEL (and CRB, which EPEL needs) if missing.
ensure_epel() {
    if [[ "$OS_FAMILY" != rhel ]]; then return 0; fi
    if [[ "$OS_ID" == fedora ]]; then
        log_info "Fedora does not use EPEL - skipping"
        return 0
    fi
    local repos crb_repo=crb
    repos=$(dnf -q repolist --enabled 2>/dev/null || true)
    if grep -qiE '^epel([[:space:]]|$)' <<<"$repos"; then
        log_info "EPEL repository is already enabled"
        return 0
    fi
    log_step "EPEL is not enabled - enabling it"
    [[ "$OS_VERSION_MAJOR" == 8 ]] && crb_repo=powertools
    if [[ "$OS_ID" == rhel ]]; then
        run dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_VERSION_MAJOR}.noarch.rpm"
        if command -v subscription-manager >/dev/null 2>&1; then
            run subscription-manager repos --enable "codeready-builder-for-rhel-${OS_VERSION_MAJOR}-$(uname -m)-rpms" ||
                log_warn "Could not enable the CodeReady Builder repo; some EPEL packages may fail to install"
        fi
    else
        run dnf install -y epel-release dnf-plugins-core
        run dnf config-manager --set-enabled "$crb_repo" ||
            run dnf config-manager setopt "${crb_repo}.enabled=1" ||
            log_warn "Could not enable the ${crb_repo} repo; some EPEL packages may fail to install"
    fi
    log_info "EPEL enabled"
}

pkg_update_once() {
    if ((PKG_UPDATED)); then return 0; fi
    case "$OS_FAMILY" in
        rhel) run dnf -y makecache ;;
        debian) run env DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
    esac
    PKG_UPDATED=1
}

# pkg_install PKG...
pkg_install() {
    pkg_update_once
    log_info "Installing: $*"
    case "$OS_FAMILY" in
        rhel) run dnf install -y "$@" ;;
        debian) run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    esac
}

# --- users --------------------------------------------------------------------
user_exists() { id -u "$1" >/dev/null 2>&1; }

# list_regular_users  Print login users with UID >= 1000 (excluding nobody).
list_regular_users() {
    getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }'
}

# set_user_password USER PASSWORD
set_user_password() {
    log_info "Setting system password for $1"
    run chpasswd <<<"$1:$2"
}

# --- services -----------------------------------------------------------------
svc_enable_now() {
    local s
    for s in "$@"; do run systemctl enable --now "$s"; done
}
svc_restart() {
    local s
    for s in "$@"; do run systemctl restart "$s"; done
}

# --- firewall -----------------------------------------------------------------
detect_firewall() {
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        FW_BACKEND=firewalld
    elif command -v ufw >/dev/null 2>&1 && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
        FW_BACKEND=ufw
    else
        FW_BACKEND=none
    fi
}

# fw_allow_service FIREWALLD_SERVICE PORT/PROTO...  (ports are used for ufw)
fw_allow_service() {
    local svc=$1 p
    shift
    [[ -n "$FW_BACKEND" ]] || detect_firewall
    case "$FW_BACKEND" in
        firewalld) run firewall-cmd --permanent --add-service="$svc" ;;
        ufw) for p in "$@"; do run ufw allow "$p"; done ;;
        *) log_warn "No active firewall (firewalld/ufw) - skipping rule for ${svc}" ;;
    esac
}

# fw_allow_port PORT[-PORT]/PROTO
fw_allow_port() {
    [[ -n "$FW_BACKEND" ]] || detect_firewall
    case "$FW_BACKEND" in
        firewalld) run firewall-cmd --permanent --add-port="$1" ;;
        ufw) run ufw allow "${1/-/:}" ;;
        *) log_warn "No active firewall (firewalld/ufw) - skipping rule for $1" ;;
    esac
}

fw_reload() {
    if [[ "$FW_BACKEND" == firewalld ]]; then run firewall-cmd --reload; fi
}

# --- SELinux ------------------------------------------------------------------
selinux_on() {
    command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != Disabled ]]
}

# selinux_bool NAME [on|off]
selinux_bool() {
    if ! selinux_on; then return 0; fi
    run setsebool -P "$1" "${2:-on}"
}

# selinux_fcontext TYPE PATH  Persistently label PATH (recursively) with TYPE.
selinux_fcontext() {
    if ! selinux_on; then return 0; fi
    local type=$1 path=${2%/} spec existing
    spec="${path}(/.*)?"
    if ! command -v semanage >/dev/null 2>&1; then
        pkg_install policycoreutils-python-utils
    fi
    existing=$(semanage fcontext -l -C 2>/dev/null || true)
    if grep -qF -- "${spec} " <<<"$existing"; then
        run semanage fcontext -m -t "$type" "$spec"
    else
        run semanage fcontext -a -t "$type" "$spec"
    fi
    run restorecon -R "$path"
}

# --- misc ---------------------------------------------------------------------
# primary_subnet  Print the CIDR of the interface holding the default route.
primary_subnet() {
    local dev cidr
    # "default via GW dev X ..." or "default dev X ..." (point-to-point links)
    dev=$(ip -o route show default 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    [[ -n "$dev" ]] || return 0
    cidr=$(ip -o -f inet addr show "$dev" 2>/dev/null | awk '{print $4; exit}')
    [[ -n "$cidr" ]] || return 0
    # Convert host address/prefix to network/prefix, e.g. 192.168.1.23/24 -> 192.168.1.0/24
    local ip=${cidr%/*} prefix=${cidr#*/} a b c d mask net
    IFS=. read -r a b c d <<<"$ip"
    mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    net=$((((a << 24) | (b << 16) | (c << 8) | d) & mask))
    printf '%d.%d.%d.%d/%d\n' $((net >> 24 & 255)) $((net >> 16 & 255)) $((net >> 8 & 255)) $((net & 255)) "$prefix"
}

primary_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}
# ===== END COMMON HELPERS =====

# ---------------------------------------------------------------------------
# Settings - every variable can come from a flag, the environment, or a prompt
# ---------------------------------------------------------------------------
EXPORT_PATH="${EXPORT_PATH:-}"
EXPORT_CLIENTS="${EXPORT_CLIENTS:-}"   # CIDR/host list, comma separated
EXPORT_ACCESS="${EXPORT_ACCESS:-}"     # rw | ro
EXPORT_SYNC="${EXPORT_SYNC:-}"         # sync | async
EXPORT_SQUASH="${EXPORT_SQUASH:-}"     # root_squash | no_root_squash | all_squash
OWNER_MODE="${OWNER_MODE:-}"           # nobody | existing-user | new-user
OWNER_USER="${OWNER_USER:-}"
OWNER_UID="${OWNER_UID:-}"             # for new-user; "auto" = next free UID
REPLACE_EXISTING="${REPLACE_EXISTING:-}"

EXPORTS_FILE=/etc/exports
CONFIGURED_EXPORTS=()
ANY_RW=n

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Install an NFS server and export a directory. Anything not given as an option
is asked interactively (or defaulted with --yes).

Options:
  --path DIR              Directory to export (default: /srv/nfs/share)
  --clients LIST          Allowed clients, comma separated CIDRs/hosts
                          (default: local subnet)
  --access rw|ro          Read-write or read-only (default: rw)
  --sync | --async        Write mode (default: sync)
  --squash MODE           root_squash | no_root_squash | all_squash (default: root_squash)
  --owner-mode MODE       nobody | existing-user | new-user (default: nobody)
  --owner USER            Owner user for existing-user / new-user
  --uid UID               UID for a new owner user (default: auto)
  --replace               Replace an existing /etc/exports entry for the path
  -y, --yes               Non-interactive: accept defaults for anything not given
  -n, --dry-run           Print the commands without changing the system
  -h, --help              Show this help

Examples:
  sudo $0
  sudo $0 --yes --path /srv/nfs/data --clients 192.168.1.0/24 --access rw
  sudo $0 --yes --path /srv/nfs/home --squash all_squash --owner-mode new-user --owner nfsdata --uid 5000
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path) EXPORT_PATH=${2:?--path needs a value}; shift ;;
            --clients) EXPORT_CLIENTS=${2:?--clients needs a value}; shift ;;
            --access) EXPORT_ACCESS=${2:?--access needs a value}; shift ;;
            --sync) EXPORT_SYNC=sync ;;
            --async) EXPORT_SYNC=async ;;
            --squash) EXPORT_SQUASH=${2:?--squash needs a value}; shift ;;
            --owner-mode) OWNER_MODE=${2:?--owner-mode needs a value}; shift ;;
            --owner) OWNER_USER=${2:?--owner needs a value}; shift ;;
            --uid) OWNER_UID=${2:?--uid needs a value}; shift ;;
            --replace) REPLACE_EXISTING=y ;;
            -y | --yes) NONINTERACTIVE=1 ;;
            -n | --dry-run) DRY_RUN=1 ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done
}

set_os_vars() {
    case "$OS_FAMILY" in
        rhel)
            PACKAGES=(nfs-utils)
            SERVICE=nfs-server
            NOLOGIN_SHELL=/sbin/nologin
            NOBODY_GROUP=nobody
            ;;
        debian)
            PACKAGES=(nfs-kernel-server)
            SERVICE=nfs-kernel-server
            NOLOGIN_SHELL=/usr/sbin/nologin
            NOBODY_GROUP=nogroup
            ;;
    esac
}

# exported_already PATH  True if /etc/exports has an entry for PATH.
exported_already() {
    [[ -f "$EXPORTS_FILE" ]] || return 1
    awk -v p="$1" '$1 == p { found = 1 } END { exit !found }' "$EXPORTS_FILE"
}

# remove_export PATH  Drop PATH's entry from /etc/exports (after a backup).
remove_export() {
    local kept
    kept=$(awk -v p="$1" '$1 != p' "$EXPORTS_FILE")
    write_file "$EXPORTS_FILE" <<<"$kept"
}

choose_owner() {
    ask_choice "Who should own ${EXPORT_PATH}?" OWNER_MODE \
        "nobody:nobody (anonymous; typical with root_squash / all_squash)" \
        "existing-user:An existing user (UID must match on the clients)" \
        "new-user:Create a new user with a fixed UID to match on the clients"

    case "$OWNER_MODE" in
        nobody)
            OWNER_USER=nobody
            OWNER_GROUP=$NOBODY_GROUP
            ;;
        existing-user)
            if [[ -z "$OWNER_USER" ]]; then
                [[ "$NONINTERACTIVE" != 1 ]] || die "--owner is required with --owner-mode existing-user in non-interactive mode"
                local -a users=() options=()
                local u
                mapfile -t users < <(list_regular_users)
                [[ ${#users[@]} -gt 0 ]] || die "No regular users (UID >= 1000) found - use the new-user mode"
                for u in "${users[@]}"; do options+=("${u}:${u} (UID $(id -u "$u"))"); done
                ask_choice "Which user should own ${EXPORT_PATH}?" OWNER_USER "${options[@]}"
            fi
            user_exists "$OWNER_USER" || die "User '${OWNER_USER}' does not exist"
            OWNER_GROUP=$(id -gn "$OWNER_USER")
            ;;
        new-user)
            ask "Name of the new owner user" "nfsuser" OWNER_USER
            if user_exists "$OWNER_USER"; then
                log_warn "User '${OWNER_USER}' already exists - using it as the owner"
            else
                ask "UID for ${OWNER_USER} (use the same UID on clients, or 'auto')" "auto" OWNER_UID
                local -a uid_opt=()
                if [[ "$OWNER_UID" != auto ]]; then
                    [[ "$OWNER_UID" =~ ^[0-9]+$ ]] || die "UID must be a number"
                    if getent passwd "$OWNER_UID" >/dev/null; then die "UID ${OWNER_UID} is already in use"; fi
                    uid_opt=(--uid "$OWNER_UID")
                fi
                run useradd "${uid_opt[@]}" --no-create-home --shell "$NOLOGIN_SHELL" \
                    --comment "NFS data owner" "$OWNER_USER"
            fi
            OWNER_GROUP=$OWNER_USER
            if user_exists "$OWNER_USER"; then OWNER_GROUP=$(id -gn "$OWNER_USER"); fi
            ;;
    esac
}

setup_export() {
    ask "Directory to export" "/srv/nfs/share" EXPORT_PATH
    EXPORT_PATH=${EXPORT_PATH%/}
    [[ "$EXPORT_PATH" == /* ]] || die "Export path must be absolute"

    if exported_already "$EXPORT_PATH"; then
        ask_yn "${EXPORT_PATH} is already in ${EXPORTS_FILE}. Replace its entry?" n REPLACE_EXISTING
        if ! is_yes "$REPLACE_EXISTING"; then
            log_warn "Keeping the existing entry for ${EXPORT_PATH}"
            return 0
        fi
    fi

    local subnet
    subnet=$(primary_subnet)
    ask "Clients allowed to mount (comma separated CIDRs/hosts, * = anyone)" "${subnet:-*}" EXPORT_CLIENTS
    ask_choice "Access for clients:" EXPORT_ACCESS \
        "rw:Read-write" \
        "ro:Read-only"
    ask_choice "Write mode:" EXPORT_SYNC \
        "sync:sync  (safe - server confirms writes after they hit disk)" \
        "async:async (faster - risk of data loss if the server crashes)"
    ask_choice "How should client users be mapped?" EXPORT_SQUASH \
        "root_squash:root_squash    - client root becomes nobody (recommended)" \
        "no_root_squash:no_root_squash - client root stays root (trusted clients only)" \
        "all_squash:all_squash     - every client user becomes the directory owner"
    choose_owner

    log_info "Preparing ${EXPORT_PATH}"
    run mkdir -p "$EXPORT_PATH"
    run chown "${OWNER_USER}:${OWNER_GROUP}" "$EXPORT_PATH"
    run chmod 0775 "$EXPORT_PATH"

    local opts="${EXPORT_ACCESS},${EXPORT_SYNC},no_subtree_check,${EXPORT_SQUASH}"
    if [[ "$EXPORT_SQUASH" == all_squash && "$OWNER_MODE" != nobody ]]; then
        # Map every client user to the owner, so files stay owned by it.
        if [[ "$DRY_RUN" == 1 ]] && ! user_exists "$OWNER_USER"; then
            opts+=",anonuid=<uid of ${OWNER_USER}>,anongid=<gid>"
        else
            opts+=",anonuid=$(id -u "$OWNER_USER"),anongid=$(getent group "$OWNER_GROUP" | cut -d: -f3)"
        fi
    fi

    local client line=""
    local -a clients
    IFS=', ' read -r -a clients <<<"$EXPORT_CLIENTS"
    [[ ${#clients[@]} -gt 0 ]] || die "At least one client is required"
    for client in "${clients[@]}"; do
        line+=" ${client}(${opts})"
    done
    line="${EXPORT_PATH}${line}"

    if exported_already "$EXPORT_PATH"; then
        remove_export "$EXPORT_PATH" # backs up the file before rewriting it
    else
        backup_file "$EXPORTS_FILE"
    fi
    append_line_once "$EXPORTS_FILE" "$line"
    CONFIGURED_EXPORTS+=("$line")
    if [[ "$EXPORT_ACCESS" == rw ]]; then ANY_RW=y; fi
}

main() {
    parse_args "$@"
    require_root
    init_log
    detect_os
    ensure_epel
    set_os_vars

    log_step "Installing packages"
    pkg_install "${PACKAGES[@]}"

    log_step "Export setup options"
    if [[ ! -f "$EXPORTS_FILE" ]]; then
        write_file "$EXPORTS_FILE" <<<"# /etc/exports - see exports(5)"
    fi
    local more=y
    while is_yes "$more"; do
        setup_export
        more=""
        ask_yn "Add another export?" n more
        if is_yes "$more"; then
            EXPORT_PATH="" EXPORT_CLIENTS="" EXPORT_ACCESS="" EXPORT_SYNC="" EXPORT_SQUASH=""
            OWNER_MODE="" OWNER_USER="" OWNER_UID="" REPLACE_EXISTING=""
        fi
    done

    log_step "Starting NFS server"
    svc_enable_now "$SERVICE"
    run exportfs -ra

    log_step "Firewall and SELinux"
    fw_allow_service nfs 2049/tcp
    fw_allow_service rpc-bind 111/tcp 111/udp
    fw_allow_service mountd 20048/tcp 20048/udp
    fw_reload
    if is_yes "$ANY_RW"; then
        selinux_bool nfs_export_all_rw on
    fi
    selinux_bool nfs_export_all_ro on

    log_step "Done"
    local ip e
    ip=$(primary_ip)
    if [[ ${#CONFIGURED_EXPORTS[@]} -eq 0 ]]; then
        printf '  No exports were changed.\n'
    fi
    for e in "${CONFIGURED_EXPORTS[@]}"; do printf '  Export      : %s\n' "$e"; done
    printf '  Config      : %s\n' "$EXPORTS_FILE"
    printf '  Check       : exportfs -v   |   showmount -e %s\n' "${ip:-localhost}"
    printf '  Client      : sudo mount -t nfs %s:<export path> /mnt\n' "${ip:-<server-ip>}"
    printf '                (or run setup-nfs-client.sh on the client)\n'
    if [[ "$OS_FAMILY" == debian && "$FW_BACKEND" == ufw ]]; then
        printf '  Note        : NFSv3 mountd uses a dynamic port on Debian/Ubuntu; NFSv4 only needs 2049\n'
    fi
}

main "$@"
