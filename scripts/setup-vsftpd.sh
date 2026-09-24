#!/usr/bin/env bash
#
# setup-vsftpd.sh - Install vsftpd and set up an FTP server interactively.
#
# Asks where the FTP root lives and how users get in:
#   - create a dedicated FTP-only user (no shell login)
#   - grant an existing system user access (read-write or read-only)
#   - anonymous read-only downloads
# and configures chroot jails, the passive port range, optional TLS,
# the firewall and SELinux.
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
FTP_ROOT="${FTP_ROOT:-}"
ACCESS_MODE="${ACCESS_MODE:-}"      # new-user | existing-user | anonymous
FTP_USER="${FTP_USER:-}"            # name of a new or existing user
FTP_PASSWORD="${FTP_PASSWORD:-}"    # password for a new user (env only)
USER_PERM="${USER_PERM:-}"          # rw | ro
USER_LANDING="${USER_LANDING:-}"    # ftp-root | home   (existing users)
CHROOT_USERS="${CHROOT_USERS:-}"    # y | n
PASV_RANGE="${PASV_RANGE:-}"        # e.g. 40000-40100
ENABLE_TLS="${ENABLE_TLS:-}"        # y | n
USERLIST_ONLY="${USERLIST_ONLY:-}"  # y | n

FTP_GROUP_MARKER="# Managed by setup-vsftpd.sh"
CONFIGURED_USERS=()
GENERATED_PASSWORDS=()

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Install vsftpd and configure an FTP server. Anything not given as an option
is asked interactively (or defaulted with --yes).

Options:
  --ftp-root DIR          FTP root directory (default: /srv/ftp)
  --mode MODE             new-user | existing-user | anonymous
  --user NAME             User to create (new-user) or grant (existing-user)
  --perm rw|ro            Permission the user gets on the FTP root (default: rw)
  --landing ftp-root|home Where an existing user lands after login (default: ftp-root)
  --chroot | --no-chroot  Jail users to their FTP directory (default: yes)
  --pasv-range MIN-MAX    Passive port range (default: 40000-40100)
  --tls | --no-tls        Enable explicit FTPS with a self-signed cert (default: no)
  --userlist | --no-userlist
                          Only allow the configured users to log in (default: yes)
  -y, --yes               Non-interactive: accept defaults for anything not given
  -n, --dry-run           Print the commands without changing the system
  -h, --help              Show this help

Environment:
  FTP_PASSWORD            Password for a new user (generated if unset with --yes)

Examples:
  sudo $0
  sudo FTP_PASSWORD='S3cret!' $0 --yes --mode new-user --user ftpuser --ftp-root /srv/ftp
  sudo $0 --yes --mode existing-user --user alice --perm ro --tls
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ftp-root) FTP_ROOT=${2:?--ftp-root needs a value}; shift ;;
            --mode) ACCESS_MODE=${2:?--mode needs a value}; shift ;;
            --user) FTP_USER=${2:?--user needs a value}; shift ;;
            --perm) USER_PERM=${2:?--perm needs a value}; shift ;;
            --landing) USER_LANDING=${2:?--landing needs a value}; shift ;;
            --chroot) CHROOT_USERS=y ;;
            --no-chroot) CHROOT_USERS=n ;;
            --pasv-range) PASV_RANGE=${2:?--pasv-range needs a value}; shift ;;
            --tls) ENABLE_TLS=y ;;
            --no-tls) ENABLE_TLS=n ;;
            --userlist) USERLIST_ONLY=y ;;
            --no-userlist) USERLIST_ONLY=n ;;
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
            PACKAGES=(vsftpd acl)
            VSFTPD_CONF=/etc/vsftpd/vsftpd.conf
            USERLIST_FILE=/etc/vsftpd/user_list
            NOLOGIN_SHELL=/sbin/nologin
            SECURE_CHROOT_DIR=""
            ;;
        debian)
            PACKAGES=(vsftpd acl)
            VSFTPD_CONF=/etc/vsftpd.conf
            USERLIST_FILE=/etc/vsftpd.user_list
            NOLOGIN_SHELL=/usr/sbin/nologin
            SECURE_CHROOT_DIR=/var/run/vsftpd/empty
            ;;
    esac
    USER_CONF_DIR=/etc/vsftpd/user_conf
    TLS_PEM=/etc/vsftpd/vsftpd.pem
    SERVICE=vsftpd
}

# grant_acl USER PERM DIR  Give USER rw or ro access to DIR, including new files.
grant_acl() {
    local user=$1 perm=$2 dir=$3 bits=rwX
    [[ "$perm" == ro ]] && bits=r-X
    log_info "Granting ${user} ${perm} access to ${dir} (ACL)"
    run setfacl -R -m "u:${user}:${bits}" -m "d:u:${user}:${bits}" "$dir"
}

setup_new_user() {
    ask "Name of the new FTP user" "ftpuser" FTP_USER
    if user_exists "$FTP_USER"; then
        log_warn "User '${FTP_USER}' already exists - granting access instead of creating it"
        setup_existing_user
        return 0
    fi
    ask_secret "Password for ${FTP_USER}" FTP_PASSWORD gen
    ask_choice "Permission for ${FTP_USER} on ${FTP_ROOT}:" USER_PERM \
        "rw:Read-write (upload, delete)" \
        "ro:Read-only (download only)"

    log_info "Creating FTP-only user ${FTP_USER} (home ${FTP_ROOT}, no shell)"
    # nologin must be listed in /etc/shells or PAM (pam_shells) rejects the login.
    append_line_once /etc/shells "$NOLOGIN_SHELL"
    run useradd --home-dir "$FTP_ROOT" --no-create-home --shell "$NOLOGIN_SHELL" \
        --comment "FTP user" "$FTP_USER"
    set_user_password "$FTP_USER" "$FTP_PASSWORD"
    grant_acl "$FTP_USER" "$USER_PERM" "$FTP_ROOT"
    CONFIGURED_USERS+=("$FTP_USER (new, ${USER_PERM}, lands in ${FTP_ROOT})")
    if ((ASK_SECRET_GENERATED)); then
        GENERATED_PASSWORDS+=("${FTP_USER}: ${FTP_PASSWORD}")
    fi
}

setup_existing_user() {
    if [[ -z "$FTP_USER" ]]; then
        [[ "$NONINTERACTIVE" != 1 ]] || die "--user is required with --mode existing-user in non-interactive mode"
        local -a users=() options=()
        mapfile -t users < <(list_regular_users)
        [[ ${#users[@]} -gt 0 ]] || die "No regular users (UID >= 1000) found - use the new-user mode"
        local u
        for u in "${users[@]}"; do options+=("${u}:${u}"); done
        ask_choice "Which existing user should get FTP access?" FTP_USER "${options[@]}"
    fi
    user_exists "$FTP_USER" || die "User '${FTP_USER}' does not exist"

    ask_choice "Where should ${FTP_USER} land after logging in?" USER_LANDING \
        "ftp-root:The FTP root (${FTP_ROOT})" \
        "home:Their own home directory"

    if [[ "$USER_LANDING" == ftp-root ]]; then
        ask_choice "Permission for ${FTP_USER} on ${FTP_ROOT}:" USER_PERM \
            "rw:Read-write (upload, delete)" \
            "ro:Read-only (download only)"
        grant_acl "$FTP_USER" "$USER_PERM" "$FTP_ROOT"
        run mkdir -p "$USER_CONF_DIR"
        write_file "${USER_CONF_DIR}/${FTP_USER}" <<EOF
local_root=${FTP_ROOT}
EOF
        CONFIGURED_USERS+=("$FTP_USER (existing, ${USER_PERM}, lands in ${FTP_ROOT})")
    else
        if [[ -f "${USER_CONF_DIR}/${FTP_USER}" ]]; then
            backup_file "${USER_CONF_DIR}/${FTP_USER}"
            run rm -f "${USER_CONF_DIR}/${FTP_USER}"
        fi
        CONFIGURED_USERS+=("$FTP_USER (existing, lands in home $(getent passwd "$FTP_USER" | cut -d: -f6))")
    fi
}

# Start a fresh allow-list the first time (distro defaults list system accounts
# meant to be *denied*), then append entries on later runs.
prepare_userlist() {
    if [[ -f "$USERLIST_FILE" ]] && grep -qxF "$FTP_GROUP_MARKER" "$USERLIST_FILE"; then
        return 0
    fi
    write_file "$USERLIST_FILE" 0600 <<EOF
${FTP_GROUP_MARKER}
# Users allowed to log in (userlist_deny=NO)
EOF
}

write_vsftpd_conf() {
    local anon=NO local_enable=YES
    if [[ "$ACCESS_MODE" == anonymous ]]; then
        anon=YES
        local_enable=NO
    fi
    local pasv_min=${PASV_RANGE%-*} pasv_max=${PASV_RANGE#*-}

    write_file "$VSFTPD_CONF" 0600 <<EOF
${FTP_GROUP_MARKER} on $(date '+%F %T')
# Previous versions are kept as ${VSFTPD_CONF}.bak.<timestamp>

# --- listener ---
listen=YES
listen_ipv6=NO
pam_service_name=vsftpd
use_localtime=YES
connect_from_port_20=YES
dirmessage_enable=YES
xferlog_enable=YES
xferlog_std_format=YES
$(if [[ -n "$SECURE_CHROOT_DIR" ]]; then echo "secure_chroot_dir=${SECURE_CHROOT_DIR}"; fi)

# --- anonymous access ---
anonymous_enable=${anon}
$( if [[ "$anon" == YES ]]; then
    printf '%s\n' "anon_root=${FTP_ROOT}" "no_anon_password=YES" \
        "anon_upload_enable=NO" "anon_mkdir_write_enable=NO" "hide_ids=YES"
fi)

# --- local users ---
local_enable=${local_enable}
write_enable=YES
local_umask=022
user_config_dir=${USER_CONF_DIR}
chroot_local_user=$(is_yes "$CHROOT_USERS" && echo YES || echo NO)
allow_writeable_chroot=YES

# --- allow-list ---
userlist_enable=$(is_yes "$USERLIST_ONLY" && echo YES || echo NO)
userlist_file=${USERLIST_FILE}
userlist_deny=NO

# --- passive mode ---
pasv_enable=YES
pasv_min_port=${pasv_min}
pasv_max_port=${pasv_max}

# --- TLS (explicit FTPS) ---
$( if is_yes "$ENABLE_TLS"; then
    printf '%s\n' "ssl_enable=YES" "rsa_cert_file=${TLS_PEM}" "rsa_private_key_file=${TLS_PEM}" \
        "allow_anon_ssl=NO" "force_local_logins_ssl=YES" "force_local_data_ssl=YES" \
        "require_ssl_reuse=NO" "ssl_ciphers=HIGH"
else
    echo "ssl_enable=NO"
fi)
EOF
}

create_tls_cert() {
    if [[ -f "$TLS_PEM" ]]; then
        log_info "TLS certificate ${TLS_PEM} already exists - reusing it"
        return 0
    fi
    log_info "Creating self-signed certificate ${TLS_PEM} (valid 10 years)"
    run mkdir -p "$(dirname "$TLS_PEM")"
    run openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$TLS_PEM" -out "$TLS_PEM" -subj "/CN=$(hostname -f 2>/dev/null || hostname)"
    run chmod 0600 "$TLS_PEM"
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

    log_step "FTP setup options"
    ask "FTP root directory" "/srv/ftp" FTP_ROOT
    FTP_ROOT=${FTP_ROOT%/}
    ask_choice "How should users access FTP?" ACCESS_MODE \
        "new-user:Create a dedicated FTP-only user (no shell login)" \
        "existing-user:Grant an existing system user access" \
        "anonymous:Anonymous read-only downloads"
    ask "Passive port range" "40000-40100" PASV_RANGE
    [[ "$PASV_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]] || die "Passive range must look like 40000-40100"
    local pasv_min=$((10#${BASH_REMATCH[1]})) pasv_max=$((10#${BASH_REMATCH[2]}))
    ((pasv_min >= 1024 && pasv_max <= 65535 && pasv_min <= pasv_max)) ||
        die "Passive range must be MIN-MAX within 1024-65535 with MIN <= MAX (got ${PASV_RANGE})"
    PASV_RANGE="${pasv_min}-${pasv_max}"
    ask_yn "Enable TLS (FTPS) with a self-signed certificate?" n ENABLE_TLS
    if [[ "$ACCESS_MODE" != anonymous ]]; then
        ask_yn "Jail (chroot) users to their FTP directory?" y CHROOT_USERS
        ask_yn "Only allow the users configured here to log in (allow-list)?" y USERLIST_ONLY
    else
        CHROOT_USERS=n
        USERLIST_ONLY=n
    fi

    log_step "Preparing ${FTP_ROOT}"
    if [[ ! -d "$FTP_ROOT" ]]; then
        run mkdir -p "$FTP_ROOT"
        run chmod 0755 "$FTP_ROOT"
    fi
    if [[ "$ACCESS_MODE" == anonymous ]]; then
        # vsftpd refuses an anonymous root that is writable; files go in pub/.
        run chown root:root "$FTP_ROOT"
        run chmod 0755 "$FTP_ROOT"
        run mkdir -p "${FTP_ROOT}/pub"
    fi

    if [[ "$ACCESS_MODE" != anonymous ]]; then
        log_step "Configuring FTP users"
        if is_yes "$USERLIST_ONLY"; then prepare_userlist; fi
        local more=y
        while is_yes "$more"; do
            case "$ACCESS_MODE" in
                new-user) setup_new_user ;;
                existing-user) setup_existing_user ;;
            esac
            if is_yes "$USERLIST_ONLY"; then append_line_once "$USERLIST_FILE" "$FTP_USER"; fi
            more=""
            ask_yn "Configure another FTP user?" n more
            if is_yes "$more"; then
                FTP_USER="" FTP_PASSWORD="" USER_PERM="" USER_LANDING="" ACCESS_MODE=""
                ask_choice "How should this user access FTP?" ACCESS_MODE \
                    "new-user:Create a dedicated FTP-only user" \
                    "existing-user:Grant an existing system user access"
            fi
        done
    fi

    log_step "Writing ${VSFTPD_CONF}"
    if is_yes "$ENABLE_TLS"; then
        pkg_install openssl
        create_tls_cert
    fi
    write_vsftpd_conf

    log_step "Firewall and SELinux"
    fw_allow_service ftp 21/tcp
    fw_allow_port "${PASV_RANGE}/tcp"
    fw_reload
    selinux_bool ftpd_full_access on
    if [[ "$ACCESS_MODE" == anonymous ]]; then
        selinux_fcontext public_content_t "$FTP_ROOT"
    else
        selinux_fcontext public_content_rw_t "$FTP_ROOT"
    fi

    log_step "Starting ${SERVICE}"
    svc_enable_now "$SERVICE"
    svc_restart "$SERVICE"

    log_step "Done"
    local ip u
    ip=$(primary_ip)
    printf '  Server      : ftp://%s:21  (passive %s)\n' "${ip:-<server-ip>}" "$PASV_RANGE"
    printf '  FTP root    : %s\n' "$FTP_ROOT"
    printf '  TLS         : %s\n' "$(is_yes "$ENABLE_TLS" && echo "required (explicit FTPS)" || echo off)"
    printf '  Config      : %s\n' "$VSFTPD_CONF"
    if [[ "$ACCESS_MODE" == anonymous ]]; then
        printf '  Access      : anonymous, read-only (put files in %s/pub)\n' "$FTP_ROOT"
        printf '  Test        : curl ftp://%s/pub/\n' "${ip:-localhost}"
    else
        for u in "${CONFIGURED_USERS[@]}"; do printf '  User        : %s\n' "$u"; done
        for u in "${GENERATED_PASSWORDS[@]}"; do printf '  Password    : %s\n' "$u"; done
        local tls_flags=""
        if is_yes "$ENABLE_TLS"; then tls_flags="--ssl-reqd -k "; fi
        printf '  Test        : curl %s-u USER:PASS ftp://%s/\n' "$tls_flags" "${ip:-localhost}"
    fi
}

main "$@"
