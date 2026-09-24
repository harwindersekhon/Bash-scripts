#!/usr/bin/env bash
#
# setup-samba.sh - Install Samba and create a file share interactively.
#
# Asks for the share name and path, and how people get in:
#   - create a new Samba-only user (no shell login)
#   - give an existing system user access
#   - guest (public) share, no password
# then sets directory ownership/permissions, the firewall and SELinux.
# Each share is written to /etc/samba/shares.d/<name>.conf and included from
# smb.conf, so existing shares are never touched.
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
SHARE_NAME="${SHARE_NAME:-}"
SHARE_PATH="${SHARE_PATH:-}"
ACCESS_MODE="${ACCESS_MODE:-}"     # new-user | existing-user | guest
SMB_USER="${SMB_USER:-}"
SMB_PASSWORD="${SMB_PASSWORD:-}"   # env only
SHARE_PERM="${SHARE_PERM:-}"       # rw | ro
WORKGROUP="${WORKGROUP:-}"
LIMIT_SUBNET="${LIMIT_SUBNET:-}"   # y | n
ALLOWED_HOSTS="${ALLOWED_HOSTS:-}" # e.g. "192.168.1.0/24"

SMB_CONF=/etc/samba/smb.conf
SHARES_DIR=/etc/samba/shares.d
CONFIGURED_USERS=()
GENERATED_PASSWORDS=()

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Install Samba and create a share. Anything not given as an option is asked
interactively (or defaulted with --yes).

Options:
  --share NAME            Share name (default: shared)
  --path DIR              Directory to share (default: /srv/samba/<name>)
  --mode MODE             new-user | existing-user | guest
  --user NAME             User to create (new-user) or grant (existing-user)
  --perm rw|ro            Read-write or read-only share (default: rw)
  --workgroup NAME        Windows workgroup (default: WORKGROUP)
  --allow CIDR            Only allow these hosts/networks (default: local subnet)
  --no-limit              Allow connections from any network
  -y, --yes               Non-interactive: accept defaults for anything not given
  -n, --dry-run           Print the commands without changing the system
  -h, --help              Show this help

Environment:
  SMB_PASSWORD            Samba password for the user (generated if unset with --yes)

Examples:
  sudo $0
  sudo SMB_PASSWORD='S3cret!' $0 --yes --share docs --mode new-user --user docs
  sudo $0 --yes --share public --mode guest --perm ro --path /srv/public
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --share) SHARE_NAME=${2:?--share needs a value}; shift ;;
            --path) SHARE_PATH=${2:?--path needs a value}; shift ;;
            --mode) ACCESS_MODE=${2:?--mode needs a value}; shift ;;
            --user) SMB_USER=${2:?--user needs a value}; shift ;;
            --perm) SHARE_PERM=${2:?--perm needs a value}; shift ;;
            --workgroup) WORKGROUP=${2:?--workgroup needs a value}; shift ;;
            --allow) ALLOWED_HOSTS=${2:?--allow needs a value}; LIMIT_SUBNET=y; shift ;;
            --no-limit) LIMIT_SUBNET=n ;;
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
            PACKAGES=(samba samba-client samba-common-tools acl)
            SERVICES=(smb nmb)
            NOLOGIN_SHELL=/sbin/nologin
            NOBODY_GROUP=nobody
            ;;
        debian)
            PACKAGES=(samba smbclient acl)
            SERVICES=(smbd nmbd)
            NOLOGIN_SHELL=/usr/sbin/nologin
            NOBODY_GROUP=nogroup
            ;;
    esac
}

samba_user_exists() {
    local list
    list=$(pdbedit -L 2>/dev/null || true)
    grep -q "^${1}:" <<<"$list"
}

# set_samba_password USER PASSWORD
set_samba_password() {
    log_info "Setting Samba password for $1"
    run smbpasswd -s -a "$1" <<<"$2"$'\n'"$2"
    run smbpasswd -e "$1"
}

setup_new_user() {
    ask "Name of the new Samba user" "$SHARE_NAME" SMB_USER
    if user_exists "$SMB_USER"; then
        log_warn "User '${SMB_USER}' already exists - granting access instead of creating it"
        setup_existing_user
        return 0
    fi
    ask_secret "Samba password for ${SMB_USER}" SMB_PASSWORD gen
    log_info "Creating Samba-only user ${SMB_USER} (no home, no shell login)"
    run useradd --no-create-home --shell "$NOLOGIN_SHELL" --comment "Samba user" "$SMB_USER"
    run usermod -aG "$SHARE_GROUP" "$SMB_USER"
    set_samba_password "$SMB_USER" "$SMB_PASSWORD"
    CONFIGURED_USERS+=("${SMB_USER} (new)")
    if ((ASK_SECRET_GENERATED)); then
        GENERATED_PASSWORDS+=("${SMB_USER}: ${SMB_PASSWORD}")
    fi
}

setup_existing_user() {
    if [[ -z "$SMB_USER" ]]; then
        [[ "$NONINTERACTIVE" != 1 ]] || die "--user is required with --mode existing-user in non-interactive mode"
        local -a users=() options=()
        local u
        mapfile -t users < <(list_regular_users)
        [[ ${#users[@]} -gt 0 ]] || die "No regular users (UID >= 1000) found - use the new-user mode"
        for u in "${users[@]}"; do options+=("${u}:${u}"); done
        ask_choice "Which existing user should get access to [${SHARE_NAME}]?" SMB_USER "${options[@]}"
    fi
    user_exists "$SMB_USER" || die "User '${SMB_USER}' does not exist"
    log_info "Adding ${SMB_USER} to group ${SHARE_GROUP}"
    run usermod -aG "$SHARE_GROUP" "$SMB_USER"

    local set_pw=y
    if samba_user_exists "$SMB_USER"; then
        set_pw=""
        ask_yn "${SMB_USER} already has a Samba password. Reset it?" n set_pw
    fi
    if is_yes "$set_pw"; then
        ask_secret "Samba password for ${SMB_USER}" SMB_PASSWORD gen
        set_samba_password "$SMB_USER" "$SMB_PASSWORD"
        if ((ASK_SECRET_GENERATED)); then
            GENERATED_PASSWORDS+=("${SMB_USER}: ${SMB_PASSWORD}")
        fi
    fi
    CONFIGURED_USERS+=("${SMB_USER} (existing)")
}

write_share_conf() {
    local read_only=no hosts_line=""
    [[ "$SHARE_PERM" == ro ]] && read_only=yes
    if is_yes "$LIMIT_SUBNET"; then
        hosts_line="   hosts allow = 127.0.0.1 ${ALLOWED_HOSTS//,/ }"
    fi

    if [[ "$ACCESS_MODE" == guest ]]; then
        write_file "${SHARES_DIR}/${SHARE_NAME}.conf" <<EOF
# Managed by setup-samba.sh on $(date '+%F %T')
[${SHARE_NAME}]
   comment = ${SHARE_NAME} (guest share)
   path = ${SHARE_PATH}
   browseable = yes
   read only = ${read_only}
   guest ok = yes
   guest only = yes
   force user = nobody
   force group = ${NOBODY_GROUP}
   create mask = 0664
   directory mask = 0775
${hosts_line}
EOF
    else
        write_file "${SHARES_DIR}/${SHARE_NAME}.conf" <<EOF
# Managed by setup-samba.sh on $(date '+%F %T')
[${SHARE_NAME}]
   comment = ${SHARE_NAME}
   path = ${SHARE_PATH}
   browseable = yes
   read only = ${read_only}
   guest ok = no
   valid users = @${SHARE_GROUP}
   force group = ${SHARE_GROUP}
   create mask = 0660
   directory mask = 2770
${hosts_line}
EOF
    fi
}

update_global_conf() {
    backup_file "$SMB_CONF"
    if [[ ! -f "$SMB_CONF" ]]; then
        write_file "$SMB_CONF" <<EOF
[global]
   workgroup = ${WORKGROUP}
   server string = Samba %v
   security = user
   map to guest = Bad User
EOF
    else
        if grep -qiE '^[[:space:]]*workgroup[[:space:]]*=' "$SMB_CONF"; then
            run sed -i -E "s/^([[:space:]]*workgroup[[:space:]]*=).*/\\1 ${WORKGROUP}/I" "$SMB_CONF"
        else
            run sed -i "/^\\[global\\]/a\\   workgroup = ${WORKGROUP}" "$SMB_CONF"
        fi
        if [[ "$ACCESS_MODE" == guest ]] && ! grep -qiE '^[[:space:]]*map to guest' "$SMB_CONF"; then
            run sed -i "/^\\[global\\]/a\\   map to guest = Bad User" "$SMB_CONF"
        fi
    fi
    append_line_once "$SMB_CONF" "include = ${SHARES_DIR}/${SHARE_NAME}.conf"
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

    log_step "Share setup options"
    ask "Share name" "shared" SHARE_NAME
    [[ "$SHARE_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Share name may only contain letters, digits, _ . -"
    ask "Directory to share" "/srv/samba/${SHARE_NAME}" SHARE_PATH
    SHARE_PATH=${SHARE_PATH%/}
    ask_choice "Who can access [${SHARE_NAME}]?" ACCESS_MODE \
        "new-user:Create a new Samba-only user (no shell login)" \
        "existing-user:Give an existing system user access" \
        "guest:Guest / public share (no password)"
    ask_choice "Share permission:" SHARE_PERM \
        "rw:Read-write" \
        "ro:Read-only"
    ask "Windows workgroup" "WORKGROUP" WORKGROUP
    [[ "$WORKGROUP" =~ ^[A-Za-z0-9_-]+$ ]] || die "Workgroup may only contain letters, digits, _ -"
    local subnet
    subnet=$(primary_subnet)
    ask_yn "Limit access to specific networks${subnet:+ (default ${subnet})}?" y LIMIT_SUBNET
    if is_yes "$LIMIT_SUBNET"; then
        ask "Allowed hosts/networks (comma separated)" "${subnet:-192.168.0.0/16}" ALLOWED_HOSTS
    fi

    # Group that owns the share; members get access.
    SHARE_GROUP="smb_${SHARE_NAME,,}"
    SHARE_GROUP=${SHARE_GROUP//[^a-z0-9_]/_}

    log_step "Preparing ${SHARE_PATH}"
    # A new directory gets owner/mode set; an existing one keeps them and only
    # gains ACL entries, so sharing e.g. a home directory doesn't break it.
    local new_dir=n bits=rwX
    [[ "$SHARE_PERM" == ro ]] && bits=r-X
    if [[ ! -d "$SHARE_PATH" ]]; then
        new_dir=y
        run mkdir -p "$SHARE_PATH"
    fi
    if [[ "$ACCESS_MODE" == guest ]]; then
        if is_yes "$new_dir"; then
            run chown nobody:"$NOBODY_GROUP" "$SHARE_PATH"
            run chmod 0775 "$SHARE_PATH"
        else
            run setfacl -R -m "u:nobody:${bits}" -m "d:u:nobody:${bits}" "$SHARE_PATH"
        fi
    else
        if ! getent group "$SHARE_GROUP" >/dev/null; then
            run groupadd "$SHARE_GROUP"
        fi
        if is_yes "$new_dir"; then
            run chgrp "$SHARE_GROUP" "$SHARE_PATH"
            run chmod 2770 "$SHARE_PATH"
        fi
        # Default ACL keeps files created outside Samba group-accessible too.
        run setfacl -R -m "g:${SHARE_GROUP}:${bits}" -m "d:g:${SHARE_GROUP}:${bits}" "$SHARE_PATH"

        log_step "Configuring share users"
        local more=y
        while is_yes "$more"; do
            case "$ACCESS_MODE" in
                new-user) setup_new_user ;;
                existing-user) setup_existing_user ;;
            esac
            more=""
            ask_yn "Add another user to [${SHARE_NAME}]?" n more
            if is_yes "$more"; then
                SMB_USER="" SMB_PASSWORD="" ACCESS_MODE=""
                ask_choice "How should this user be added?" ACCESS_MODE \
                    "new-user:Create a new Samba-only user" \
                    "existing-user:Give an existing system user access"
            fi
        done
    fi

    log_step "Writing Samba configuration"
    run mkdir -p "$SHARES_DIR"
    write_share_conf
    update_global_conf
    log_info "Validating configuration with testparm"
    run testparm -s "$SMB_CONF" >/dev/null

    log_step "Firewall and SELinux"
    fw_allow_service samba 137/udp 138/udp 139/tcp 445/tcp
    fw_reload
    if [[ "$SHARE_PATH" == /home/* ]]; then
        # Don't relabel home directories; let Samba read them via the boolean.
        selinux_bool samba_enable_home_dirs on
    else
        selinux_fcontext samba_share_t "$SHARE_PATH"
    fi

    log_step "Starting Samba"
    svc_enable_now "${SERVICES[@]}"
    svc_restart "${SERVICES[@]}"

    log_step "Done"
    local ip u
    ip=$(primary_ip)
    printf '  Share       : \\\\%s\\%s   (smb://%s/%s)\n' "${ip:-server}" "$SHARE_NAME" "${ip:-server}" "$SHARE_NAME"
    printf '  Path        : %s (%s)\n' "$SHARE_PATH" "$SHARE_PERM"
    printf '  Config      : %s\n' "${SHARES_DIR}/${SHARE_NAME}.conf"
    if is_yes "$LIMIT_SUBNET"; then printf '  Allowed     : %s\n' "$ALLOWED_HOSTS"; fi
    if [[ "${ACCESS_MODE:-}" == guest ]]; then
        printf '  Access      : guest (no password)\n'
        printf '  Test        : smbclient -N //%s/%s -c ls\n' "${ip:-localhost}" "$SHARE_NAME"
    else
        printf '  Group       : %s (add users: usermod -aG %s USER && smbpasswd -a USER)\n' "$SHARE_GROUP" "$SHARE_GROUP"
        for u in "${CONFIGURED_USERS[@]}"; do printf '  User        : %s\n' "$u"; done
        for u in "${GENERATED_PASSWORDS[@]}"; do printf '  Password    : %s\n' "$u"; done
        printf '  Test        : smbclient //%s/%s -U USER -c ls\n' "${ip:-localhost}" "$SHARE_NAME"
    fi
}

main "$@"
