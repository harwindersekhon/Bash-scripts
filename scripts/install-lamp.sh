#!/usr/bin/env bash
#
# install-lamp.sh - Install Apache, MariaDB and PHP (LAMP) and set up a site.
#
# Asks whether to use the default site or create a name-based virtual host
# (with its own document root and file owner), which extra PHP modules to add,
# the MariaDB root password, an optional application database/user,
# phpMyAdmin and a phpinfo() test page. MariaDB is hardened the same way
# mariadb-secure-installation does it, without prompts.
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
    printf '%s\n' "$line" >>"$file"
}

# --- prompts ------------------------------------------------------------------
# Every prompt is skipped when its variable is already set (from a flag or the
# environment). With NONINTERACTIVE=1 the default is taken silently.

# ask "Question" "default" VAR
ask() {
    local _q=$1 _def=$2 _var=$3 _reply
    if [[ -n "${!_var:-}" ]]; then return 0; fi
    if [[ "$NONINTERACTIVE" == 1 ]]; then
        [[ -n "$_def" ]] || die "No value for '${_q}' - pass it as a flag in non-interactive mode"
        printf -v "$_var" '%s' "$_def"
        return 0
    fi
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
    dev=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
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
SITE_MODE="${SITE_MODE:-}"               # default | vhost
VHOST_DOMAIN="${VHOST_DOMAIN:-}"
DOC_ROOT="${DOC_ROOT:-}"
SITE_OWNER_MODE="${SITE_OWNER_MODE:-}"   # webserver | existing-user
SITE_OWNER="${SITE_OWNER:-}"
DOCROOT_WRITABLE="${DOCROOT_WRITABLE:-}" # y | n
PHP_MODULES="${PHP_MODULES:-}"           # comma separated, or "none"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}" # env only
CREATE_APP_DB="${CREATE_APP_DB:-}"       # y | n
APP_DB_NAME="${APP_DB_NAME:-}"
APP_DB_USER="${APP_DB_USER:-}"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-}"   # env only
INSTALL_PMA="${INSTALL_PMA:-}"           # y | n
DEPLOY_INFO="${DEPLOY_INFO:-}"           # y | n

GENERATED_PASSWORDS=()
MYSQL_AUTH_FILE=""

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Install Apache, MariaDB and PHP and set up a website. Anything not given as an
option is asked interactively (or defaulted with --yes).

Options:
  --site default|vhost    Use the default site or create a name-based vhost
  --domain NAME           Domain for the vhost (e.g. example.com)
  --docroot DIR           Document root (default: /var/www/html or /var/www/<domain>)
  --owner USER            Existing user who owns the site files (default: web server user)
  --writable              Let the web app write to the document root
  --php-modules LIST      Extra PHP modules, comma separated, or "none"
                          (default: gd,mbstring,xml,curl,zip,intl)
  --app-db NAME           Create an application database with this name
  --app-user NAME         Database user for the app DB (default: <db name>)
  --no-app-db             Don't create an application database
  --phpmyadmin | --no-phpmyadmin
                          Install phpMyAdmin (default: no)
  --info | --no-info      Deploy info.php (phpinfo) to the document root (default: no)
  -y, --yes               Non-interactive: accept defaults for anything not given
  -n, --dry-run           Print the commands without changing the system
  -h, --help              Show this help

Environment:
  DB_ROOT_PASSWORD        MariaDB root password (generated if unset with --yes)
  APP_DB_PASSWORD         Password for the app DB user (generated if unset with --yes)

Examples:
  sudo $0
  sudo $0 --yes --site vhost --domain example.com --app-db wordpress --info
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --site) SITE_MODE=${2:?--site needs a value}; shift ;;
            --domain) VHOST_DOMAIN=${2:?--domain needs a value}; SITE_MODE=${SITE_MODE:-vhost}; shift ;;
            --docroot) DOC_ROOT=${2:?--docroot needs a value}; shift ;;
            --owner) SITE_OWNER=${2:?--owner needs a value}; SITE_OWNER_MODE=existing-user; shift ;;
            --writable) DOCROOT_WRITABLE=y ;;
            --php-modules) PHP_MODULES=${2:?--php-modules needs a value}; shift ;;
            --app-db) APP_DB_NAME=${2:?--app-db needs a value}; CREATE_APP_DB=y; shift ;;
            --app-user) APP_DB_USER=${2:?--app-user needs a value}; shift ;;
            --no-app-db) CREATE_APP_DB=n ;;
            --phpmyadmin) INSTALL_PMA=y ;;
            --no-phpmyadmin) INSTALL_PMA=n ;;
            --info) DEPLOY_INFO=y ;;
            --no-info) DEPLOY_INFO=n ;;
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
            PACKAGES=(httpd mariadb-server mariadb php php-cli php-fpm php-mysqlnd php-opcache)
            SERVICES=(mariadb php-fpm httpd)
            APACHE_SERVICE=httpd
            APACHE_USER=apache
            VHOST_FILE_DIR=/etc/httpd/conf.d
            APACHE_LOG_PREFIX=logs
            DEFAULT_DOCROOT=/var/www/html
            ;;
        debian)
            PACKAGES=(apache2 mariadb-server mariadb-client php php-cli libapache2-mod-php php-mysql)
            SERVICES=(mariadb apache2)
            APACHE_SERVICE=apache2
            APACHE_USER=www-data
            VHOST_FILE_DIR=/etc/apache2/sites-available
            # Written literally into the vhost; Apache expands it.
            # shellcheck disable=SC2016
            APACHE_LOG_PREFIX='${APACHE_LOG_DIR}'
            DEFAULT_DOCROOT=/var/www/html
            ;;
    esac
}

# php_packages "gd,mbstring,..."  Print distro package names for PHP modules.
php_packages() {
    local mod
    local -a mods
    IFS=', ' read -r -a mods <<<"$1"
    for mod in "${mods[@]}"; do
        [[ -n "$mod" && "$mod" != none ]] || continue
        case "${OS_FAMILY}:${mod}" in
            rhel:curl) ;; # built into php-common on the RHEL family
            rhel:zip) echo php-pecl-zip ;;
            *) echo "php-${mod}" ;;
        esac
    done
}

# sql_escape STRING  Escape a value for use inside single quotes in SQL.
sql_escape() {
    local s=${1//\\/\\\\}
    printf '%s' "${s//\'/\\\'}"
}

# Work out how to log in to MariaDB as root: unix socket (fresh install) or
# with DB_ROOT_PASSWORD (already secured by a previous run).
prepare_mysql_auth() {
    if [[ "$DRY_RUN" == 1 ]] || mysql -u root -e 'SELECT 1' >/dev/null 2>&1; then
        return 0
    fi
    [[ -n "$DB_ROOT_PASSWORD" ]] || die "Cannot log in to MariaDB as root via socket; set DB_ROOT_PASSWORD"
    MYSQL_AUTH_FILE=$(mktemp)
    chmod 0600 "$MYSQL_AUTH_FILE"
    printf '[client]\nuser=root\npassword=%s\n' "$DB_ROOT_PASSWORD" >"$MYSQL_AUTH_FILE"
    trap 'rm -f "$MYSQL_AUTH_FILE"' EXIT
    mysql --defaults-extra-file="$MYSQL_AUTH_FILE" -e 'SELECT 1' >/dev/null 2>&1 ||
        die "MariaDB root login failed with the given DB_ROOT_PASSWORD"
}

# mysql_root <<SQL  Run SQL from stdin as the MariaDB root user.
mysql_root() {
    if [[ -n "$MYSQL_AUTH_FILE" ]]; then
        run mysql --defaults-extra-file="$MYSQL_AUTH_FILE"
    else
        run mysql -u root
    fi
}

secure_mariadb() {
    local pw
    pw=$(sql_escape "$DB_ROOT_PASSWORD")
    log_info "Securing MariaDB (root password, anonymous users, test DB, remote root)"
    # Root keeps unix-socket login (sudo mysql) and also accepts the password.
    mysql_root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${pw}') OR unix_socket;
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
}

create_app_db() {
    local pw
    pw=$(sql_escape "$APP_DB_PASSWORD")
    log_info "Creating database ${APP_DB_NAME} and user ${APP_DB_USER}@localhost"
    mysql_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${APP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'localhost' IDENTIFIED BY '${pw}';
ALTER USER '${APP_DB_USER}'@'localhost' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${APP_DB_NAME}\`.* TO '${APP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

write_vhost() {
    local conf="${VHOST_FILE_DIR}/${VHOST_DOMAIN}.conf"
    write_file "$conf" <<EOF
# Managed by install-lamp.sh on $(date '+%F %T')
<VirtualHost *:80>
    ServerName ${VHOST_DOMAIN}
    ServerAlias www.${VHOST_DOMAIN}
    DocumentRoot ${DOC_ROOT}

    <Directory ${DOC_ROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_PREFIX}/${VHOST_DOMAIN}-error.log
    CustomLog ${APACHE_LOG_PREFIX}/${VHOST_DOMAIN}-access.log combined
</VirtualHost>
EOF
    if [[ "$OS_FAMILY" == debian ]]; then
        run a2enmod rewrite
        run a2ensite "${VHOST_DOMAIN}.conf"
    fi
}

install_phpmyadmin() {
    if [[ "$OS_FAMILY" == debian ]]; then
        # Preseed debconf so the package configures itself without prompts.
        local pma_pw
        pma_pw=$(gen_password 24)
        run debconf-set-selections <<EOF
phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
phpmyadmin phpmyadmin/mysql/app-pass password ${pma_pw}
phpmyadmin phpmyadmin/app-password-confirm password ${pma_pw}
EOF
        pkg_install phpmyadmin
        PMA_NOTE="http://<server>/phpmyadmin"
    else
        # phpMyAdmin comes from EPEL on the RHEL family.
        if pkg_install phpMyAdmin; then
            PMA_NOTE="http://localhost/phpMyAdmin (local access only by default - edit ${VHOST_FILE_DIR}/phpMyAdmin.conf)"
        else
            log_warn "phpMyAdmin is not available for ${OS_PRETTY} - skipping"
            PMA_NOTE="not installed (package unavailable)"
        fi
    fi
}

main() {
    parse_args "$@"
    require_root
    init_log
    detect_os
    ensure_epel
    set_os_vars

    log_step "Installing Apache, MariaDB and PHP"
    pkg_install "${PACKAGES[@]}"

    log_step "Website setup options"
    ask_choice "Which site should be set up?" SITE_MODE \
        "default:Default site (${DEFAULT_DOCROOT})" \
        "vhost:Name-based virtual host with its own document root"
    if [[ "$SITE_MODE" == vhost ]]; then
        ask "Domain name for the virtual host" "" VHOST_DOMAIN
        [[ "$VHOST_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid domain name: ${VHOST_DOMAIN}"
        ask "Document root" "/var/www/${VHOST_DOMAIN}" DOC_ROOT
    else
        if [[ -n "$DOC_ROOT" && "${DOC_ROOT%/}" != "$DEFAULT_DOCROOT" ]]; then
            log_warn "The default site always serves ${DEFAULT_DOCROOT}; use --site vhost for a custom document root"
        fi
        DOC_ROOT=$DEFAULT_DOCROOT
    fi
    DOC_ROOT=${DOC_ROOT%/}
    ask_choice "Who should own the site files?" SITE_OWNER_MODE \
        "webserver:The web server user (${APACHE_USER})" \
        "existing-user:An existing user (e.g. a developer who deploys the site)"
    if [[ "$SITE_OWNER_MODE" == existing-user ]]; then
        if [[ -z "$SITE_OWNER" ]]; then
            [[ "$NONINTERACTIVE" != 1 ]] || die "--owner is required for an existing-user owner in non-interactive mode"
            local -a users=() options=()
            local u
            mapfile -t users < <(list_regular_users)
            [[ ${#users[@]} -gt 0 ]] || die "No regular users (UID >= 1000) found"
            for u in "${users[@]}"; do options+=("${u}:${u}"); done
            ask_choice "Which user owns the site files?" SITE_OWNER "${options[@]}"
        fi
        user_exists "$SITE_OWNER" || die "User '${SITE_OWNER}' does not exist"
    else
        SITE_OWNER=$APACHE_USER
    fi
    ask_yn "Should the web app be able to write to ${DOC_ROOT} (uploads, caches)?" n DOCROOT_WRITABLE
    ask "Extra PHP modules (comma separated, or 'none')" "gd,mbstring,xml,curl,zip,intl" PHP_MODULES
    ask_yn "Deploy info.php (phpinfo page) for testing?" n DEPLOY_INFO

    log_step "Database setup options"
    ask_secret "MariaDB root password" DB_ROOT_PASSWORD gen
    if ((ASK_SECRET_GENERATED)); then GENERATED_PASSWORDS+=("MariaDB root: ${DB_ROOT_PASSWORD}"); fi
    ask_yn "Create a database and user for your application?" n CREATE_APP_DB
    if is_yes "$CREATE_APP_DB"; then
        ask "Database name" "appdb" APP_DB_NAME
        ask "Database user" "$APP_DB_NAME" APP_DB_USER
        [[ "$APP_DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "Database name may only contain letters, digits and _"
        [[ "$APP_DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "Database user may only contain letters, digits and _"
        ask_secret "Password for database user ${APP_DB_USER}" APP_DB_PASSWORD gen
        if ((ASK_SECRET_GENERATED)); then GENERATED_PASSWORDS+=("DB user ${APP_DB_USER}: ${APP_DB_PASSWORD}"); fi
    fi
    ask_yn "Install phpMyAdmin?" n INSTALL_PMA

    local -a php_extra=()
    mapfile -t php_extra < <(php_packages "$PHP_MODULES")
    if [[ ${#php_extra[@]} -gt 0 ]]; then
        log_step "Installing PHP modules"
        pkg_install "${php_extra[@]}"
    fi

    log_step "Starting services"
    svc_enable_now "${SERVICES[@]}"

    log_step "Configuring MariaDB"
    prepare_mysql_auth
    secure_mariadb
    if is_yes "$CREATE_APP_DB"; then create_app_db; fi

    log_step "Configuring the website"
    run mkdir -p "$DOC_ROOT"
    # Owner deploys files; the web server group can read them (and write if allowed).
    local web_group
    web_group=$(id -gn "$APACHE_USER" 2>/dev/null || echo "$APACHE_USER")
    run chown -R "${SITE_OWNER}:${web_group}" "$DOC_ROOT"
    if is_yes "$DOCROOT_WRITABLE"; then
        run chmod -R u=rwX,g=rwX,o=rX "$DOC_ROOT"
    else
        run chmod -R u=rwX,g=rX,o=rX "$DOC_ROOT"
    fi
    run find "$DOC_ROOT" -type d -exec chmod g+s {} +
    if [[ "$SITE_MODE" == vhost ]]; then
        write_vhost
        if [[ ! -e "${DOC_ROOT}/index.html" && ! -e "${DOC_ROOT}/index.php" ]]; then
            write_file "${DOC_ROOT}/index.html" <<EOF
<!doctype html>
<title>${VHOST_DOMAIN}</title>
<h1>${VHOST_DOMAIN} is working</h1>
EOF
            run chown "${SITE_OWNER}:${web_group}" "${DOC_ROOT}/index.html"
        fi
    fi
    if is_yes "$DEPLOY_INFO"; then
        write_file "${DOC_ROOT}/info.php" <<'EOF'
<?php phpinfo();
EOF
        run chown "${SITE_OWNER}:${web_group}" "${DOC_ROOT}/info.php"
    fi

    PMA_NOTE=""
    if is_yes "$INSTALL_PMA"; then
        log_step "Installing phpMyAdmin"
        install_phpmyadmin
    fi

    log_step "Firewall and SELinux"
    fw_allow_service http 80/tcp
    fw_allow_service https 443/tcp
    fw_reload
    if is_yes "$DOCROOT_WRITABLE"; then
        selinux_fcontext httpd_sys_rw_content_t "$DOC_ROOT"
    elif [[ "$DOC_ROOT" != /var/www/* ]]; then
        selinux_fcontext httpd_sys_content_t "$DOC_ROOT"
    fi

    log_step "Restarting Apache"
    run apachectl configtest
    svc_restart "$APACHE_SERVICE"

    log_step "Done"
    local ip url p
    ip=$(primary_ip)
    if [[ "$SITE_MODE" == vhost ]]; then url="http://${VHOST_DOMAIN}/"; else url="http://${ip:-localhost}/"; fi
    printf '  Site        : %s\n' "$url"
    printf '  Doc root    : %s (owner %s:%s%s)\n' "$DOC_ROOT" "$SITE_OWNER" "$web_group" \
        "$(if is_yes "$DOCROOT_WRITABLE"; then echo ", writable by web server"; fi)"
    if [[ "$SITE_MODE" == vhost ]]; then
        printf '  Vhost       : %s/%s.conf\n' "$VHOST_FILE_DIR" "$VHOST_DOMAIN"
        printf '  Note        : point DNS (or /etc/hosts) for %s at %s\n' "$VHOST_DOMAIN" "${ip:-this server}"
    fi
    if is_yes "$DEPLOY_INFO"; then
        printf '  PHP info    : %sinfo.php  (remove it when done testing!)\n' "$url"
    fi
    printf '  MariaDB     : root via "sudo mysql" or the root password\n'
    if is_yes "$CREATE_APP_DB"; then
        printf '  App DB      : %s (user %s@localhost)\n' "$APP_DB_NAME" "$APP_DB_USER"
    fi
    if [[ -n "$PMA_NOTE" ]]; then printf '  phpMyAdmin  : %s\n' "$PMA_NOTE"; fi
    for p in "${GENERATED_PASSWORDS[@]}"; do printf '  Password    : %s\n' "$p"; done
}

main "$@"
