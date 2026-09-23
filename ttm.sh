#!/usr/bin/env bash
#
#   ████████╗████████╗███╗   ███╗
#   ╚══██╔══╝╚══██╔══╝████╗ ████║   TrustTunnel Manager
#      ██║      ██║   ██╔████╔██║   Install & manage a TrustTunnel VPN endpoint
#      ██║      ██║   ██║╚██╔╝██║   https://github.com/TrustTunnel/TrustTunnel
#      ██║      ██║   ██║ ╚═╝ ██║
#      ╚═╝      ╚═╝   ╚═╝     ╚═╝
#
#   Run as root (no sudo needed):
#   First run:   bash ttm.sh               (interactive menu, offers install)
#   Afterwards:  ttm                        (menu)   |   ttm help   (CLI)
#
#   Supported:   Linux x86_64 / aarch64 with systemd
#                (Debian, Ubuntu, RHEL/Alma/Rocky, Fedora, openSUSE, Arch)
#
set -o pipefail -o nounset
umask 077
# Debian's plain `su` (without "-") drops the sbin dirs from PATH; make sure they are there.
for _d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    case ":${PATH:-}:" in *":$_d:"*) ;; *) PATH="${PATH:+$PATH:}$_d" ;; esac
done
export PATH; unset _d

readonly TTM_VERSION="1.1.0"
readonly REPO="TrustTunnel/TrustTunnel"
readonly FALLBACK_VERSION="1.1.0"   # used only if GitHub's "latest" lookup fails

TT_DIR="${TT_DIR:-/opt/trusttunnel}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/ttm}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-trusttunnel.conf}"
LOCK_FILE="${LOCK_FILE:-/run/ttm.lock}"

readonly SERVICE="trusttunnel"
readonly RENEW_UNIT="trusttunnel-cert-renew"

CONF="$TT_DIR/ttm.conf"
VPN_TOML="$TT_DIR/vpn.toml"
HOSTS_TOML="$TT_DIR/hosts.toml"
BACKUP_DIR="$TT_DIR/backups"
CLIENTS_DIR="$TT_DIR/clients"
ENDPOINT="$TT_DIR/trusttunnel_endpoint"
WIZARD="$TT_DIR/setup_wizard"

ASSUME_YES=0
TMP_PATHS=()
CONF_KEYS=(PUBLIC_ADDR TLS_HOST CERT_TYPE ACME_EMAIL SERVER_NAME DNS_UPSTREAMS LOG_LEVEL)
U_NAMES=()
U_PASS=()

# ─────────────────────────────────────────────────────────────────────────────
#  Output / UI helpers
# ─────────────────────────────────────────────────────────────────────────────
setup_colors() {
    C_RST="" C_BOLD="" C_DIM="" C_RED="" C_GRN="" C_YLW="" C_BLU="" C_MAG="" C_CYN=""
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        C_RST=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
        C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m'
        C_BLU=$'\e[34m' C_MAG=$'\e[35m' C_CYN=$'\e[36m'
    fi
    local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    if [[ "$loc" == *[Uu][Tt][Ff]-8* || "$loc" == *[Uu][Tt][Ff]8* ]]; then
        G_OK="✔" G_ERR="✖" G_WARN="!" G_ARR="➜" G_DOT="●" G_H="─" G_Q="?"
    else
        G_OK="+" G_ERR="x" G_WARN="!" G_ARR=">" G_DOT="*" G_H="-" G_Q="?"
    fi
}

info()  { printf '%s%s%s %s\n' "$C_BLU" "$G_ARR" "$C_RST" "$*"; }
ok()    { printf '%s%s%s %s\n' "$C_GRN" "$G_OK" "$C_RST" "$*"; }
warn()  { printf '%s%s%s %s\n' "$C_YLW" "$G_WARN" "$C_RST" "$*" >&2; }
err()   { printf '%s%s%s %s\n' "$C_RED" "$G_ERR" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }

repeat_char() { local i out=""; for ((i = 0; i < $2; i++)); do out+="$1"; done; printf '%s' "$out"; }

section() {
    local t=" $1 " w=56
    local n=$((w - ${#t} - 2)); ((n < 2)) && n=2
    printf '\n%s%s%s%s%s%s\n' "$C_MAG" "$C_BOLD" "$(repeat_char "$G_H" 2)" "$t" "$(repeat_char "$G_H" "$n")" "$C_RST"
}

kv() { printf '  %s%-13s%s %s\n' "$C_DIM" "$1" "$C_RST" "$2"; }

banner() {
    local line; line=$(repeat_char "$G_H" 52)
    printf '%s%s%s\n' "$C_CYN" "$line" "$C_RST"
    printf '  %s%sTrustTunnel Manager%s  %sv%s%s\n' "$C_BOLD" "$C_CYN" "$C_RST" "$C_DIM" "$TTM_VERSION" "$C_RST"
    printf '%s%s%s\n' "$C_CYN" "$line" "$C_RST"
}

# Read from the terminal even when the script itself arrives on stdin (curl | bash).
TTY_IN=/dev/stdin
init_tty() {
    if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then TTY_IN=/dev/tty; fi
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ask VAR "Prompt" [default]
ask() {
    local _ask_var="$1" _ask_prompt="$2" _ask_def="${3-}" _ask_ans=""
    if ((ASSUME_YES)); then
        if [[ -n "$_ask_def" ]]; then
            printf '%s%s%s %s: %s\n' "$C_CYN" "$G_Q" "$C_RST" "$_ask_prompt" "$_ask_def"
            printf -v "$_ask_var" '%s' "$_ask_def"
            return 0
        fi
        err "No value for '$_ask_prompt' in non-interactive (-y) mode."
        return 1
    fi
    if [[ -n "$_ask_def" ]]; then
        printf '%s%s%s %s %s[%s]%s: ' "$C_CYN" "$G_Q" "$C_RST" "$_ask_prompt" "$C_DIM" "$_ask_def" "$C_RST"
    else
        printf '%s%s%s %s: ' "$C_CYN" "$G_Q" "$C_RST" "$_ask_prompt"
    fi
    if ! IFS= read -r _ask_ans <"$TTY_IN"; then echo; return 1; fi
    _ask_ans=$(trim "$_ask_ans")
    [[ -z "$_ask_ans" ]] && _ask_ans="$_ask_def"
    printf -v "$_ask_var" '%s' "$_ask_ans"
}

# ask_secret VAR "Prompt"  (input hidden)
ask_secret() {
    local _ask_var="$1" _ask_ans=""
    printf '%s%s%s %s: ' "$C_CYN" "$G_Q" "$C_RST" "$2"
    if ! IFS= read -rs _ask_ans <"$TTY_IN"; then echo; return 1; fi
    echo
    printf -v "$_ask_var" '%s' "$_ask_ans"
}

# ask_yn "Question" [Y|N]  -> 0 for yes
ask_yn() {
    local q="$1" def="${2:-N}" a hint
    ((ASSUME_YES)) && return 0
    [[ "$def" == "Y" ]] && hint="Y/n" || hint="y/N"
    while true; do
        printf '%s%s%s %s %s[%s]%s: ' "$C_CYN" "$G_Q" "$C_RST" "$q" "$C_DIM" "$hint" "$C_RST"
        if ! IFS= read -r a <"$TTY_IN"; then echo; return 1; fi
        a=$(trim "$a"); a="${a:-$def}"
        case "$a" in
            [Yy] | [Yy][Ee][Ss]) return 0 ;;
            [Nn] | [Nn][Oo]) return 1 ;;
        esac
    done
}

pause() {
    [[ -t 1 ]] || return 0
    printf '\n%sPress Enter to continue…%s' "$C_DIM" "$C_RST"
    IFS= read -r _ <"$TTY_IN" || true
}

cleanup() {
    local p
    for p in "${TMP_PATHS[@]+"${TMP_PATHS[@]}"}"; do
        [[ -n "$p" && "$p" != "/" ]] && rm -rf -- "$p"
    done
}
trap cleanup EXIT

mktempdir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/ttm.XXXXXX") || return 1
    TMP_PATHS+=("$d")
    printf '%s' "$d"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Validation
# ─────────────────────────────────────────────────────────────────────────────
is_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$ ]] && ((${#1} <= 253))
}
is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
valid_username() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,31}$ ]]; }
valid_password() {
    local p="$1"
    ((${#p} >= 8 && ${#p} <= 128)) || return 1
    [[ "$p" =~ ^[[:graph:]]+$ ]] || return 1
    local bs=$'\\' dq='"'
    [[ "$p" != *"$dq"* && "$p" != *"$bs"* ]]
}
# host, host:port, IPv4, IPv4:port
valid_public_addr() {
    local a="$1" h p
    if [[ "$a" == *:* ]]; then h="${a%:*}" p="${a##*:}"; is_port "$p" || return 1; else h="$a"; fi
    is_ipv4 "$h" || is_domain "$h"
}
valid_dns_list() {
    local re='^[][A-Za-z0-9.:/_@%+-]+$' d
    for d in $1; do [[ "$d" =~ $re ]] || return 1; done
}

randpass() {
    local n="${1:-20}" p=""
    while ((${#p} < n)); do
        p+=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 512 /dev/urandom))
    done
    printf '%s' "${p:0:n}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  System checks & dependencies
# ─────────────────────────────────────────────────────────────────────────────
require_root() { [[ $EUID -eq 0 ]] || die "Run as root: switch with 'su -' (or use sudo if installed), then run ttm."; }

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) return 1 ;;
    esac
}

check_system() {
    [[ "$(uname -s)" == "Linux" ]] || die "Only Linux is supported."
    detect_arch >/dev/null || die "Unsupported CPU architecture: $(uname -m) (TrustTunnel ships x86_64 and aarch64 builds only)."
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] ||
        die "systemd is required (this system is not running systemd)."
}

pkg_manager() {
    local m
    for m in apt-get dnf yum zypper pacman; do
        command -v "$m" >/dev/null 2>&1 && { echo "$m"; return 0; }
    done
    return 1
}

pkg_name_for() { # command manager -> package name
    case "$1" in
        ss) case "$2" in dnf | yum) echo iproute ;; *) echo iproute2 ;; esac ;;
        ip) case "$2" in dnf | yum) echo iproute ;; *) echo iproute2 ;; esac ;;
        flock) echo util-linux ;;
        awk) case "$2" in apt-get) echo gawk ;; *) echo gawk ;; esac ;;
        getent) case "$2" in apt-get) echo libc-bin ;; *) echo glibc ;; esac ;;
        *) echo "$1" ;;
    esac
}

pkg_install() {
    local mgr="$1"; shift
    (($#)) || return 0
    case "$mgr" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        dnf) dnf install -y -q "$@" >/dev/null 2>&1 ;;
        yum) yum install -y -q "$@" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive --quiet install "$@" >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ensure_deps() {
    local mgr need=() c
    mgr=$(pkg_manager) || mgr=""
    local p
    for c in curl tar gzip openssl awk ss ip flock getent; do
        command -v "$c" >/dev/null 2>&1 && continue
        p=$(pkg_name_for "$c" "$mgr")
        [[ " ${need[*]-} " == *" $p "* ]] || need+=("$p")
    done
    if ((${#need[@]})); then
        [[ -n "$mgr" ]] || die "Missing tools (${need[*]}) and no supported package manager found."
        info "Installing dependencies: ${need[*]}"
        # shellcheck disable=SC2046
        pkg_install "$mgr" "${need[@]}" ca-certificates || true
        for c in curl tar gzip openssl awk; do
            command -v "$c" >/dev/null 2>&1 || die "Required tool '$c' could not be installed."
        done
    fi
    if ! command -v qrencode >/dev/null 2>&1 && [[ -n "$mgr" ]]; then
        info "Installing qrencode (terminal QR codes)…"
        pkg_install "$mgr" qrencode || warn "qrencode not available — QR codes will be shown as a web link instead."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Manager settings (ttm.conf) — parsed, never sourced
# ─────────────────────────────────────────────────────────────────────────────
conf_defaults() {
    PUBLIC_ADDR="" TLS_HOST="" CERT_TYPE="" ACME_EMAIL=""
    SERVER_NAME="TrustTunnel" DNS_UPSTREAMS="" LOG_LEVEL="info"
}

conf_load() {
    conf_defaults
    [[ -r "$CONF" ]] || return 0
    local line k v
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
        case " ${CONF_KEYS[*]} " in *" $k "*) printf -v "$k" '%s' "$v" ;; esac
    done <"$CONF"
    case "$LOG_LEVEL" in info | debug | trace) ;; *) LOG_LEVEL=info ;; esac
}

conf_save() {
    local tmp k
    tmp=$(mktemp "$TT_DIR/.ttm.conf.XXXXXX") || return 1
    {
        echo "# TrustTunnel Manager settings — managed by ttm, edit via 'ttm settings'"
        for k in "${CONF_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k//$'\n'/}"; done
    } >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CONF"
}

# ─────────────────────────────────────────────────────────────────────────────
#  TOML helpers (limited to the simple layout TrustTunnel generates)
# ─────────────────────────────────────────────────────────────────────────────
ensure_trailing_newline() { [[ -s "$1" && -n "$(tail -c1 "$1")" ]] && echo >>"$1"; return 0; }

# toml_get KEY FILE  — top-level key only (before first [table])
toml_get() {
    awk -v k="$1" '
        /^[[:space:]]*\[/ { exit }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
            if (v ~ /^"/) { v = substr(v, 2); sub(/".*$/, "", v) }
            else { sub(/[[:space:]]*#.*$/, "", v); sub(/[[:space:]]+$/, "", v) }
            print v; exit
        }' "$2"
}

# toml_set KEY RAW_VALUE FILE — replaces/inserts a top-level key
toml_set() {
    local key="$1" val="$2" file="$3" tmp
    tmp=$(mktemp "$file.XXXXXX") || return 1
    TTM_V="$val" awk -v k="$key" '
        BEGIN { v = ENVIRON["TTM_V"]; done = 0; intable = 0 }
        /^[[:space:]]*\[/ { if (!done && !intable) { print k " = " v; print ""; done = 1 } intable = 1 }
        !intable && !done && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k " = " v; done = 1; next }
        { print }
        END { if (!done) print k " = " v }' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$file" "$tmp" 2>/dev/null
    mv -f "$tmp" "$file"
}

# First [[main_hosts]] field value from hosts.toml
hosts_main_field() {
    local file="${2:-$HOSTS_TOML}"
    [[ -r "$file" ]] || return 1
    awk -v f="$1" '
        /^[[:space:]]*\[\[[[:space:]]*main_hosts[[:space:]]*\]\]/ { m = 1; next }
        /^[[:space:]]*\[/ { if (m) exit }
        m && $0 ~ "^[[:space:]]*" f "[[:space:]]*=" {
            v = $0; sub(/^[^=]*=[[:space:]]*"/, "", v); sub(/".*$/, "", v); print v; exit
        }' "$file"
}

resolve_path() { # path relative to a base dir (default TT_DIR)
    local p="$1" base="${2:-$TT_DIR}"
    [[ "$p" == /* ]] && printf '%s' "$p" || printf '%s/%s' "$base" "$p"
}

creds_file() {
    local f
    f=$(toml_get credentials_file "$VPN_TOML" 2>/dev/null)
    resolve_path "${f:-credentials.toml}"
}

listen_address() { toml_get listen_address "$VPN_TOML"; }
listen_port() { local a; a=$(listen_address); printf '%s' "${a##*:}"; }

# ─────────────────────────────────────────────────────────────────────────────
#  Users (credentials.toml) — edited in place so unknown keys/comments survive
# ─────────────────────────────────────────────────────────────────────────────
# Shared awk: tstr() returns the raw (TOML-escaped) content of a string value.
readonly AWK_TSTR='
function tstr(s,    q, i, c, out) {
    sub(/^[^=]*=[[:space:]]*/, "", s)
    q = substr(s, 1, 1); out = ""
    if (q == SQ) {
        for (i = 2; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == SQ) break
            if (c == "\\" || c == "\"") out = out "\\"
            out = out c
        }
        return out
    }
    if (q != "\"") return ""
    for (i = 2; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
        if (c == "\"") break
        out = out c
    }
    return out
}
function is_client_hdr(l) { return l ~ /^[[:space:]]*\[\[[[:space:]]*client[[:space:]]*\]\]/ }
function is_hdr(l)        { return l ~ /^[[:space:]]*\[/ }
function is_key(l, k)     { return l ~ ("^[[:space:]]*" k "[[:space:]]*=") }
'

users_load() {
    U_NAMES=() U_PASS=()
    local f u p
    f=$(creds_file)
    [[ -r "$f" ]] || return 0
    while IFS=$'\037' read -r u p; do
        [[ -n "$u" ]] || continue
        U_NAMES+=("$u") U_PASS+=("$p")
    done < <(awk -v SQ="'" "$AWK_TSTR"'
        function flush() { if (inb && u != "") printf "%s\037%s\n", u, p; inb = 0; u = ""; p = "" }
        is_client_hdr($0) { flush(); inb = 1; next }
        is_hdr($0)        { flush(); next }
        inb && is_key($0, "username") { u = tstr($0); next }
        inb && is_key($0, "password") { p = tstr($0); next }
        END { flush() }' "$f")
}

user_exists() {
    local n
    for n in "${U_NAMES[@]+"${U_NAMES[@]}"}"; do [[ "$n" == "$1" ]] && return 0; done
    return 1
}

# creds_edit MODE USER [NEWPASS]   MODE = remove | setpass
creds_edit() {
    local mode="$1" user="$2" f tmp
    f=$(creds_file)
    tmp=$(mktemp "$f.XXXXXX") || return 1
    TTM_USER="$user" TTM_PASS="${3-}" awk -v SQ="'" -v MODE="$mode" "$AWK_TSTR"'
        BEGIN { T = ENVIRON["TTM_USER"]; NP = ENVIRON["TTM_PASS"]; n = 0; inb = 0 }
        function flush(   i, match_) {
            if (!inb) return
            match_ = (u == T)
            for (i = 1; i <= n; i++) {
                if (match_ && MODE == "remove") continue
                if (match_ && MODE == "setpass" && is_key(buf[i], "password")) { print "password = \"" NP "\""; continue }
                print buf[i]
            }
            n = 0; inb = 0; u = ""
        }
        is_client_hdr($0) { flush(); inb = 1; buf[++n] = $0; next }
        is_hdr($0)        { flush(); print; next }
        inb { buf[++n] = $0; if (is_key($0, "username")) u = tstr($0); next }
        { print }
        END { flush() }' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

creds_append() {
    local f
    f=$(creds_file)
    [[ -e "$f" ]] || : >"$f"
    ensure_trailing_newline "$f"
    printf '\n[[client]]\nusername = "%s"\npassword = "%s"\n' "$1" "$2" >>"$f"
    chmod 600 "$f"
}

# Remove exported client files of users that no longer exist.
prune_clients() {
    local f n
    users_load
    for f in "$CLIENTS_DIR"/*.toml "$CLIENTS_DIR"/*.link; do
        [[ -e "$f" ]] || continue
        n=$(basename "$f"); n="${n%.*}"
        user_exists "$n" || rm -f -- "$f"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  Snapshots / backups
# ─────────────────────────────────────────────────────────────────────────────
SNAP_ITEMS=(vpn.toml hosts.toml credentials.toml rules.toml certs ttm.conf)

snapshot_create() { # snapshot_create PREFIX -> prints archive path
    local prefix="${1:-auto}" items=() i out
    install -d -m 700 "$BACKUP_DIR"
    for i in "${SNAP_ITEMS[@]}" ${2:+clients}; do [[ -e "$TT_DIR/$i" ]] && items+=("$i"); done
    ((${#items[@]})) || return 1
    out="$BACKUP_DIR/$prefix-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
    tar -czf "$out" -C "$TT_DIR" "${items[@]}" 2>/dev/null || { rm -f "$out"; return 1; }
    chmod 600 "$out"
    # keep the 20 newest automatic snapshots
    find "$BACKUP_DIR" -maxdepth 1 -name 'auto-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | tail -n +21 | cut -d' ' -f2- | xargs -r rm -f --
    printf '%s' "$out"
}

snapshot_restore() {
    [[ -f "$1" ]] || { err "Snapshot not found: $1"; return 1; }
    tar -xzf "$1" -C "$TT_DIR" || { err "Failed to restore snapshot $1"; return 1; }
    conf_load
}

# ─────────────────────────────────────────────────────────────────────────────
#  Service helpers
# ─────────────────────────────────────────────────────────────────────────────
is_installed() { [[ -x "$ENDPOINT" && -f "$VPN_TOML" && -f "$HOSTS_TOML" ]]; }
need_installed() { is_installed || { err "TrustTunnel is not installed. Run: ttm install"; return 1; }; }

svc_active() { systemctl is-active --quiet "$SERVICE" 2>/dev/null; }
svc_enabled() { systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; }

svc_journal() {
    command -v journalctl >/dev/null 2>&1 || return 0
    printf '%s  Last log lines:%s\n' "$C_DIM" "$C_RST" >&2
    journalctl -u "$SERVICE" -n "${1:-15}" --no-pager -o cat 2>/dev/null | sed 's/^/    /' >&2
}

# The service must still be up after a few seconds (catches crash loops).
wait_active() {
    local i
    for i in 1 2; do
        sleep 2
        svc_active || return 1
    done
    return 0
}

svc_restart_checked() {
    systemctl restart "$SERVICE" 2>/dev/null
    wait_active
}

# Parse all config files by asking the endpoint to export a client config.
validate_config() {
    local u="${1:-}" out msg
    if [[ -z "$u" ]]; then users_load; u="${U_NAMES[0]:-}"; fi
    if [[ -z "$u" ]]; then
        err "No users configured — the endpoint cannot start without at least one user."
        return 1
    fi
    if ! out=$(cd "$TT_DIR" && "$ENDPOINT" vpn.toml hosts.toml -c "$u" -a 127.0.0.1 2>&1 >/dev/null); then
        err "Configuration check failed:"
        msg=$(printf '%s\n' "$out" | grep -o 'message: "[^"]*"' | head -1)
        [[ -z "$msg" ]] && msg=$(printf '%s\n' "$out" | awk '/panicked at/ { getline; print; exit }')
        [[ -z "$msg" ]] && msg=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -3)
        printf '    %s\n' "${msg:0:400}" >&2
        return 1
    fi
}

# apply_changes SNAPSHOT [USER]: validate -> restart -> roll back on failure
apply_changes() {
    local snap="${1:-}" user="${2:-}"
    if ! validate_config "$user"; then
        if [[ -n "$snap" ]]; then warn "Rolling back to previous configuration."; snapshot_restore "$snap"; fi
        return 1
    fi
    if svc_active; then
        info "Restarting TrustTunnel…"
        if svc_restart_checked; then
            ok "Service restarted with the new configuration."
        else
            err "Service failed to start with the new configuration."
            svc_journal 10
            if [[ -n "$snap" ]]; then
                warn "Rolling back to previous configuration."
                snapshot_restore "$snap"
                systemctl restart "$SERVICE" 2>/dev/null
                wait_active && ok "Previous configuration restored, service is running." || err "Service is still failing — check: ttm logs"
            fi
            return 1
        fi
    else
        warn "Service is not running — changes will apply on next start (ttm start)."
    fi
}

write_unit() {
    local f="$SYSTEMD_DIR/$SERVICE.service"
    cat >"$f.tmp" <<EOF
# Managed by ttm (TrustTunnel Manager). Regenerated on changes — edit via 'ttm settings'.
[Unit]
Description=TrustTunnel VPN endpoint
Documentation=https://github.com/TrustTunnel/TrustTunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
WorkingDirectory=$TT_DIR
ExecStart=$ENDPOINT --loglvl $LOG_LEVEL vpn.toml hosts.toml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ProtectControlGroups=true
ProtectKernelModules=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$f.tmp" && mv -f "$f.tmp" "$f"
    systemctl daemon-reload
}

write_renew_units() {
    cat >"$SYSTEMD_DIR/$RENEW_UNIT.service" <<EOF
# Managed by ttm (TrustTunnel Manager)
[Unit]
Description=Renew TrustTunnel Let's Encrypt certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_PATH renew-cert --auto
EOF
    cat >"$SYSTEMD_DIR/$RENEW_UNIT.timer" <<EOF
# Managed by ttm (TrustTunnel Manager)
[Unit]
Description=Daily TrustTunnel certificate renewal check

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$SYSTEMD_DIR/$RENEW_UNIT.service" "$SYSTEMD_DIR/$RENEW_UNIT.timer"
    systemctl daemon-reload
}

renew_timer_enabled() { systemctl is-enabled --quiet "$RENEW_UNIT.timer" 2>/dev/null; }

renew_timer_enable() {
    [[ -x "$BIN_PATH" ]] || { err "$BIN_PATH is missing — reinstall the manager first."; return 1; }
    write_renew_units
    systemctl enable --now "$RENEW_UNIT.timer" >/dev/null 2>&1 &&
        ok "Automatic certificate renewal enabled (daily check, renews 30 days before expiry)."
}

renew_timer_disable() {
    systemctl disable --now "$RENEW_UNIT.timer" >/dev/null 2>&1
    ok "Automatic certificate renewal disabled."
}

# ─────────────────────────────────────────────────────────────────────────────
#  Network helpers
# ─────────────────────────────────────────────────────────────────────────────
detect_public_ip() {
    local u ip
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
        is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    done
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    return 1
}

default_iface() {
    ip -o -4 route show to default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

port_busy() { # port [tcp|udp]
    command -v ss >/dev/null 2>&1 || return 1
    local flag="-Hltn"; [[ "${2:-tcp}" == udp ]] && flag="-Hlun"
    [[ -n "$(ss "$flag" "sport = :$1" 2>/dev/null)" ]]
}

port_owner() {
    command -v ss >/dev/null 2>&1 || return 0
    ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2
}

fw_kind() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo ufw
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        echo firewalld
    else
        echo none
    fi
}

fw_is_open() { # port proto
    case "$(fw_kind)" in
        ufw) ufw status 2>/dev/null | grep -qE "^$1/$2[[:space:]]+ALLOW" ;;
        firewalld) firewall-cmd -q --query-port="$1/$2" 2>/dev/null ;;
        *) return 0 ;;
    esac
}

fw_open() { # port proto...
    local port="$1" kind p; shift
    kind=$(fw_kind)
    case "$kind" in
        ufw) for p in "$@"; do ufw allow "$port/$p" >/dev/null 2>&1; done ;;
        firewalld)
            for p in "$@"; do firewall-cmd -q --permanent --add-port="$port/$p" 2>/dev/null; done
            firewall-cmd -q --reload 2>/dev/null ;;
        *) return 0 ;;
    esac
    ok "Firewall ($kind): opened port $port ($(IFS=/; printf '%s' "$*"))"
}

fw_close() { # port proto...
    local port="$1" kind p; shift
    kind=$(fw_kind)
    case "$kind" in
        ufw) for p in "$@"; do ufw delete allow "$port/$p" >/dev/null 2>&1; done ;;
        firewalld)
            for p in "$@"; do firewall-cmd -q --permanent --remove-port="$port/$p" 2>/dev/null; done
            firewall-cmd -q --reload 2>/dev/null ;;
        *) return 0 ;;
    esac
    ok "Firewall ($kind): closed port $port ($(IFS=/; printf '%s' "$*"))"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Release download
# ─────────────────────────────────────────────────────────────────────────────
installed_version() { [[ -x "$ENDPOINT" ]] && "$ENDPOINT" --version 2>/dev/null | awk 'NF { print $NF; exit }'; }

latest_version() {
    local url v=""
    url=$(curl -fsSLI --max-time 20 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null) || url=""
    [[ "$url" == */tag/* ]] && { v="${url##*/tag/}"; v="${v#v}"; }
    if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        v=$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
            grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
    fi
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$ ]] || return 1
    printf '%s' "$v"
}

# Version to install: explicit > latest > pinned fallback
install_version() {
    local v
    if [[ -n "${1:-}" ]]; then printf '%s' "$1"; return 0; fi
    if v=$(latest_version); then printf '%s' "$v"; return 0; fi
    warn "Could not query the latest release from GitHub — installing known-good v$FALLBACK_VERSION." >&2
    printf '%s' "$FALLBACK_VERSION"
}

# fetch_release VERSION — installs binaries into TT_DIR (configs untouched)
fetch_release() {
    local ver="$1" arch tmp name url src f
    arch=$(detect_arch) || { err "Unsupported architecture."; return 1; }
    name="trusttunnel-v${ver}-linux-${arch}"
    url="https://github.com/$REPO/releases/download/v${ver}/${name}.tar.gz"
    tmp=$(mktempdir) || return 1
    info "Downloading TrustTunnel ${C_BOLD}v$ver${C_RST} ($arch)…"
    local progress=(-sS); [[ -t 2 ]] && progress=(--progress-bar)
    if ! curl -fL --retry 3 --connect-timeout 15 "${progress[@]}" -o "$tmp/pkg.tar.gz" "$url"; then
        err "Download failed: $url"; return 1
    fi
    tar -tzf "$tmp/pkg.tar.gz" >/dev/null 2>&1 || { err "Downloaded archive is corrupted."; return 1; }
    tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" || { err "Failed to unpack archive."; return 1; }
    src="$tmp/$name"
    [[ -d "$src" ]] || src=$(find "$tmp" -maxdepth 3 -type f -name trusttunnel_endpoint -printf '%h\n' | head -1)
    [[ -n "$src" && -f "$src/trusttunnel_endpoint" && -f "$src/setup_wizard" ]] ||
        { err "Unexpected archive layout."; return 1; }
    chmod 755 "$src/trusttunnel_endpoint" "$src/setup_wizard"
    "$src/trusttunnel_endpoint" --version >/dev/null 2>&1 ||
        { err "The downloaded binary does not run on this system."; return 1; }
    install -d -m 755 "$TT_DIR"
    for f in trusttunnel_endpoint setup_wizard; do
        install -m 755 "$src/$f" "$TT_DIR/.$f.new" && mv -f "$TT_DIR/.$f.new" "$TT_DIR/$f" ||
            { err "Failed to install $f"; return 1; }
    done
    for f in LICENSE trusttunnel.service.template; do
        [[ -f "$src/$f" ]] && install -m 644 "$src/$f" "$TT_DIR/$f"
    done
    ok "TrustTunnel v$(installed_version) installed to $TT_DIR"
}

self_install() {
    local src
    src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || src=""
    if [[ -f "$src" && "$src" != "$(readlink -f "$BIN_PATH" 2>/dev/null)" ]]; then
        install -D -m 755 "$src" "$BIN_PATH" && ok "Manager installed: run ${C_BOLD}ttm${C_RST} any time."
    elif [[ ! -x "$BIN_PATH" ]]; then
        warn "Could not install the 'ttm' command (script was not run from a file). Save it and run as root: bash ttm.sh"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Certificates
# ─────────────────────────────────────────────────────────────────────────────
cert_path() { local c; c=$(hosts_main_field cert_chain_path) || return 1; [[ -n "$c" ]] && resolve_path "$c"; }
key_path() { local k; k=$(hosts_main_field private_key_path) || return 1; [[ -n "$k" ]] && resolve_path "$k"; }

cert_enddate() { openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2; }

cert_days_left() {
    local c end end_s
    c=$(cert_path) || return 1
    [[ -r "$c" ]] || return 1
    end=$(cert_enddate "$c") && [[ -n "$end" ]] || return 1
    end_s=$(date -d "$end" +%s 2>/dev/null) || return 1
    printf '%s' $(((end_s - $(date +%s)) / 86400))
}

cert_key_match() { # cert key
    local a b
    a=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)
    b=$(openssl pkey -in "$2" -pubout 2>/dev/null | openssl sha256 2>/dev/null)
    [[ -n "$a" && "$a" == "$b" ]]
}

# Set a string field of the first [[main_hosts]] entry in hosts.toml
hosts_set_main() { # key value
    local tmp
    tmp=$(mktemp "$HOSTS_TOML.XXXXXX") || return 1
    TTM_K="$1" TTM_V="$2" awk '
        BEGIN { k = ENVIRON["TTM_K"]; v = ENVIRON["TTM_V"]; n = 0; m = 0; done = 0 }
        /^[[:space:]]*\[\[[[:space:]]*main_hosts[[:space:]]*\]\]/ { n++; m = (n == 1); print; next }
        /^[[:space:]]*\[/ { if (m && !done) { print k " = \"" v "\""; done = 1 } m = 0 }
        m && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k " = \"" v "\""; done = 1; next }
        { print }
        END { if (m && !done) print k " = \"" v "\"" }' "$HOSTS_TOML" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" && mv -f "$tmp" "$HOSTS_TOML"
}

hosts_use_cert() { # chain key
    hosts_set_main cert_chain_path "$1" && hosts_set_main private_key_path "$2"
}

# Copy user-provided cert files into $TT_DIR/certs and point hosts.toml at them
install_cert_files() { # chain key
    install -d -m 700 "$TT_DIR/certs"
    install -m 644 "$1" "$TT_DIR/certs/cert.pem.new" && install -m 600 "$2" "$TT_DIR/certs/key.pem.new" || return 1
    mv -f "$TT_DIR/certs/cert.pem.new" "$TT_DIR/certs/cert.pem" && mv -f "$TT_DIR/certs/key.pem.new" "$TT_DIR/certs/key.pem"
    hosts_use_cert "certs/cert.pem" "certs/key.pem"
}

# ── Let's Encrypt via certbot ────────────────────────────────────────────────
le_live_dir() { printf '/etc/letsencrypt/live/%s' "$1"; }
readonly LE_HOOK="/etc/letsencrypt/renewal-hooks/deploy/trusttunnel.sh"

ensure_certbot() {
    command -v certbot >/dev/null 2>&1 && return 0
    local mgr
    mgr=$(pkg_manager) || { err "certbot is not installed and no package manager was found."; return 1; }
    info "Installing certbot…"
    case "$mgr" in
        dnf | yum) pkg_install "$mgr" epel-release; pkg_install "$mgr" certbot ;;
        zypper) pkg_install "$mgr" python3-certbot || pkg_install "$mgr" certbot ;;
        *) pkg_install "$mgr" certbot ;;
    esac
    command -v certbot >/dev/null 2>&1 || { err "certbot could not be installed."; return 1; }
}

# Checks that commonly make Let's Encrypt fail or hang. Returns 1 on a blocking problem.
le_preflight() { # domain [server_ip]
    local d="$1" ip="${2:-}" v4 v6
    info "Checking $d for Let's Encrypt…"
    v4=$(getent ahostsv4 "$d" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')
    v4="${v4% }"
    if [[ -z "$v4" ]]; then
        err "$d has no DNS A record yet — create one pointing to ${ip:-this server} and wait a few minutes."
        return 1
    fi
    if [[ -n "$ip" && " $v4 " != *" $ip "* ]]; then
        err "$d points to $v4, not to this server ($ip)."
        ask_yn "Try anyway?" N || return 1
    else
        ok "DNS: $d → $v4"
    fi
    v6=$(getent ahostsv6 "$d" 2>/dev/null | awk '$1 !~ /^::ffff:/ { print $1 }' | sort -u | head -1)
    if [[ -n "$v6" ]] && ! ip -6 addr show scope global 2>/dev/null | grep -qiF "$v6"; then
        warn "$d also has an IPv6 (AAAA) record $v6 that is not on this server."
        warn "Let's Encrypt prefers IPv6, so validation will likely fail — remove that AAAA record."
        ask_yn "Try anyway?" N || return 1
    fi
    if port_busy 80; then
        err "Port 80 is in use by '$(port_owner 80)' — it must be free for the HTTP-01 check."
        return 1
    fi
    return 0
}

le_install_hook() {
    install -d -m 755 "$(dirname "$LE_HOOK")"
    cat >"$LE_HOOK" <<EOF
#!/bin/sh
# Managed by ttm (TrustTunnel Manager): make TrustTunnel pick up renewed certificates.
if [ -x "$BIN_PATH" ]; then exec "$BIN_PATH" cert-reload; fi
systemctl restart $SERVICE
EOF
    chmod 755 "$LE_HOOK"
}

# Run certbot with port 80 temporarily opened; shows certbot output, with a hard timeout.
certbot_run() {
    local opened=0 rc
    if ! fw_is_open 80 tcp; then fw_open 80 tcp >/dev/null && opened=1; fi
    timeout 180 certbot "$@" 2>&1 | sed -u 's/^/    /'
    rc=${PIPESTATUS[0]}
    ((opened)) && fw_close 80 tcp >/dev/null
    if ((rc == 124)); then
        err "certbot timed out after 3 minutes."
        return 124
    fi
    return "$rc"
}

le_issue() { # domain email
    local d="$1" e="$2"
    ensure_certbot || return 1
    info "Requesting a Let's Encrypt certificate for ${C_BOLD}$d${C_RST} (HTTP-01 check on port 80, up to 3 min)…"
    if ! certbot_run certonly --standalone --non-interactive --agree-tos -m "$e" -d "$d" \
        --cert-name "$d" --preferred-challenges http --keep-until-expiring; then
        err "Let's Encrypt did not issue the certificate. Usual causes:"
        printf '    - the domain does not point to this server (A record), or has a stray AAAA record\n' >&2
        printf '    - port 80/TCP is blocked by the hosting provider'"'"'s firewall / security group\n' >&2
        printf '    - too many attempts: Let'"'"'s Encrypt rate limits (wait an hour)\n' >&2
        return 1
    fi
    [[ -s "$(le_live_dir "$d")/fullchain.pem" && -s "$(le_live_dir "$d")/privkey.pem" ]] ||
        { err "certbot finished but no certificate was found in $(le_live_dir "$d")."; return 1; }
    le_install_hook
    ok "Let's Encrypt certificate issued for $d."
}

# Reload TLS settings (SIGHUP) and verify the new certificate is served; restart if not.
cert_reload() {
    local port host served file_end c
    svc_active || return 0
    port=$(listen_port); host=$(hosts_main_field hostname); c=$(cert_path) || return 1
    systemctl reload "$SERVICE" 2>/dev/null
    sleep 2
    served=$(echo | timeout 10 openssl s_client -connect "127.0.0.1:$port" -servername "$host" 2>/dev/null |
        openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    file_end=$(cert_enddate "$c")
    if [[ -z "$served" || "$served" != "$file_end" ]]; then
        svc_restart_checked || { err "Service failed after certificate update."; svc_journal; return 1; }
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  Client config export
# ─────────────────────────────────────────────────────────────────────────────
export_args() { # user -> fills EXPORT_ARGS
    local d addr
    addr="${PUBLIC_ADDR:-}"
    [[ -n "$addr" ]] || addr=$(detect_public_ip) || addr=""
    [[ -n "$addr" ]] || { err "Public address unknown — set it in Settings."; return 1; }
    EXPORT_ARGS=(vpn.toml hosts.toml -c "$1" -a "$addr")
    [[ -n "${SERVER_NAME:-}" ]] && EXPORT_ARGS+=(-n "$SERVER_NAME")
    for d in ${DNS_UPSTREAMS:-}; do EXPORT_ARGS+=(-d "$d"); done
    return 0
}

show_user_config() {
    local u="$1" out link qrlink toml_out
    conf_load
    users_load
    user_exists "$u" || { err "User '$u' not found."; return 1; }
    export_args "$u" || return 1
    if ! out=$(cd "$TT_DIR" && "$ENDPOINT" "${EXPORT_ARGS[@]}" -f deeplink 2>/dev/null); then
        err "Failed to export the client configuration."; validate_config "$u"; return 1
    fi
    link=$(grep -m1 -o 'tt://[^[:space:]]*' <<<"$out")
    qrlink=$(grep -m1 -o 'https://[^[:space:]]*qr[^[:space:]]*' <<<"$out")
    [[ -n "$link" ]] || { err "Export produced no tt:// link."; return 1; }

    install -d -m 700 "$CLIENTS_DIR"
    toml_out="$CLIENTS_DIR/$u.toml"
    if (cd "$TT_DIR" && "$ENDPOINT" "${EXPORT_ARGS[@]}" -f toml >"$toml_out.tmp" 2>/dev/null); then
        chmod 600 "$toml_out.tmp" && mv -f "$toml_out.tmp" "$toml_out"
    else
        rm -f "$toml_out.tmp"; toml_out=""
    fi
    printf '%s\n' "$link" >"$CLIENTS_DIR/$u.link" && chmod 600 "$CLIENTS_DIR/$u.link"

    section "Client config: $u"
    kv "Server" "${EXPORT_ARGS[5]}  (port $(listen_port))"
    kv "TLS host" "$(hosts_main_field hostname)"
    [[ -n "$toml_out" ]] && kv "CLI config" "$toml_out"
    printf '\n  %sDeep link%s (paste or import into the TrustTunnel app):\n\n' "$C_BOLD" "$C_RST"
    printf '%s%s%s\n' "$C_GRN" "$link" "$C_RST"
    if command -v qrencode >/dev/null 2>&1 && [[ -t 1 ]]; then
        local qr_w cols
        qr_w=$(qrencode -t UTF8 -m 2 -l L "$link" 2>/dev/null | head -1 | LC_ALL=C.UTF-8 wc -m)
        cols=$(tput cols 2>/dev/null || echo "${COLUMNS:-80}")
        if [[ "$qr_w" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]] && ((qr_w - 1 > cols)); then
            printf '\n  %sQR code needs a terminal %d columns wide (yours: %d) — widen the window or use the link below.%s\n' \
                "$C_YLW" "$((qr_w - 1))" "$cols" "$C_RST"
        else
            printf '\n  %sScan with the TrustTunnel mobile app:%s\n' "$C_BOLD" "$C_RST"
            qrencode -t ANSIUTF8 -m 2 -l L "$link" 2>/dev/null || qrencode -t UTF8 -m 2 -l L "$link" 2>/dev/null
        fi
    fi
    if [[ -n "$qrlink" ]]; then
        printf '\n  %sQR code in a browser%s (data stays in the #fragment, not sent to the server):\n  %s\n' \
            "$C_DIM" "$C_RST" "$qrlink"
    fi
    if [[ -n "$toml_out" ]]; then
        printf '\n  %sCLI client:%s ./setup_wizard --mode non-interactive --endpoint_config %s.toml --settings trusttunnel_client.toml\n' \
            "$C_DIM" "$C_RST" "$u"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Commands: install
# ─────────────────────────────────────────────────────────────────────────────
# setup_wizard is used only in self-signed mode: its non-interactive "letsencrypt" and
# "provided" modes hang forever (deadlock) in v1.1.0. Real certificates are applied afterwards.
run_wizard() { # user pass port host
    local user="$1" pass="$2" port="$3" host="$4" log="$TT_DIR/setup_wizard.log" rc
    info "Generating configuration…"
    (cd "$TT_DIR" && timeout 90 "$WIZARD" -m non-interactive -a "0.0.0.0:$port" -c "$user:$pass" -n "$host" \
        --lib-settings vpn.toml --hosts-settings hosts.toml --cert-type self-signed </dev/null >"$log" 2>&1)
    rc=$?
    chmod 600 "$log" 2>/dev/null
    ((rc == 0)) && [[ -s "$TT_DIR/hosts.toml" ]] && return 0
    ((rc == 124)) && err "Setup wizard hung (killed after 90s)." || err "Setup wizard failed."
    printf '  %sLast lines of %s:%s\n' "$C_DIM" "$log" "$C_RST" >&2
    tail -n 15 "$log" | sed 's/\x1b\][^\x1b]*\x1b\\//g; s/\x1b\[[0-9;]*m//g; s/^/    /' >&2
    return 1
}

cmd_install() {
    local o_sni="" o_domain="" o_ip="" o_email="" o_port="" o_user="" o_pass="" o_cert="" o_cf="" o_kf="" o_name="" o_dns="" o_ver=""
    while (($#)); do
        case "$1" in
            --domain) o_domain="${2:-}"; shift ;;
            --sni) o_sni="${2:-}"; shift ;;
            --ip) o_ip="${2:-}"; shift ;;
            --email) o_email="${2:-}"; shift ;;
            --port) o_port="${2:-}"; shift ;;
            --user) o_user="${2:-}"; shift ;;
            --password) o_pass="${2:-}"; shift ;;
            --cert) o_cert="${2:-}"; shift ;;
            --cert-file) o_cf="${2:-}"; shift ;;
            --key-file) o_kf="${2:-}"; shift ;;
            --name) o_name="${2:-}"; shift ;;
            --dns) o_dns="${2:-}"; shift ;;
            --version) o_ver="${2#v}"; shift ;;
            *) err "Unknown option for install: $1"; return 1 ;;
        esac
        shift
    done

    check_system
    section "Install TrustTunnel"

    if is_installed; then
        conf_load
        warn "TrustTunnel is already configured in $TT_DIR (v$(installed_version))."
        echo "   1) Reinstall binaries + service only (keep settings and users)"
        echo "   2) Wipe configuration and set up from scratch (a backup is kept)"
        echo "   0) Cancel"
        local c; ask c "Choose" "0" || return 1
        case "$c" in
            1)
                ensure_deps
                local v; v=$(install_version "$o_ver")
                fetch_release "$v" || return 1
                validate_config || return 1
                write_unit
                systemctl enable "$SERVICE" >/dev/null 2>&1
                if svc_restart_checked; then ok "TrustTunnel reinstalled and running."; else err "Service failed to start."; svc_journal; return 1; fi
                self_install
                return 0 ;;
            2)
                local snap old_port; snap=$(snapshot_create manual clients) && ok "Backup saved: $snap"
                old_port=$(listen_port)
                systemctl stop "$SERVICE" 2>/dev/null
                is_port "$old_port" && fw_close "$old_port" tcp udp
                (cd "$TT_DIR" && rm -rf -- vpn.toml hosts.toml credentials.toml rules.toml certs clients ttm.conf)
                ;;
            *) info "Cancelled."; return 0 ;;
        esac
    fi

    ensure_deps

    # ── server address
    section "Server address"
    local ip domain="" tls_host="" ctype="" email="" port user pass name cf="" kf=""
    if [[ -n "$o_ip" ]]; then
        ip="$o_ip"
    else
        info "Detecting public IPv4 address…"
        ip=$(detect_public_ip) || ip=""
    fi
    [[ -z "$o_ip" && -n "$ip" ]] && ok "Detected public IP: ${C_BOLD}$ip${C_RST}"
    if [[ -z "$o_ip" ]]; then
        ask ip "Public IPv4 address of this server" "$ip" || return 1
    fi
    while ! is_ipv4 "$ip"; do
        err "Invalid IPv4 address: '$ip'"
        ask ip "Public IPv4 address of this server" "" || return 1
    done

    if [[ -n "$o_domain" ]]; then
        domain="${o_domain,,}"
    elif [[ "$o_cert" != "self-signed" ]] && ! ((ASSUME_YES)); then
        printf '  %sA domain lets you use a trusted Let'"'"'s Encrypt certificate (recommended).%s\n' "$C_DIM" "$C_RST"
        ask domain "Domain pointing to this server (empty = use IP only)" "" || return 1
        domain="${domain,,}"
    fi
    while [[ -n "$domain" ]] && ! is_domain "$domain"; do
        err "Invalid domain name: '$domain'"
        ask domain "Domain (empty = use IP only)" "" || return 1
        domain="${domain,,}"
    done

    # ── certificate
    section "TLS certificate"
    if [[ -n "$o_cert" ]]; then
        ctype="$o_cert"
    elif [[ -n "$domain" ]]; then
        echo "   1) Let's Encrypt (free, trusted — recommended)"
        echo "   2) Self-signed"
        echo "   3) Use existing certificate files"
        local c
        while true; do
            ask c "Choose" "1" || return 1
            case "$c" in 1) ctype=letsencrypt; break ;; 2) ctype=self-signed; break ;; 3) ctype=provided; break ;; esac
        done
    else
        ctype=self-signed
        info "No domain — a self-signed certificate will be generated; clients connect to $ip."
        printf '  %sThe certificate is embedded in each client link. It still needs a hostname: it is sent as TLS SNI\n  (an IP cannot be used there). Any name works, e.g. the default below.%s\n' "$C_DIM" "$C_RST"
    fi
    if [[ -n "$domain" ]]; then
        tls_host="$domain"
    else
        tls_host="${o_sni,,}"
        while ! is_domain "$tls_host"; do
            [[ -n "$tls_host" ]] && err "Invalid hostname: '$tls_host' (must be a name like vpn.example.com, not an IP)."
            ask tls_host "TLS hostname (SNI) for the certificate" "vpn.internal" || return 1
            tls_host="${tls_host,,}"
        done
    fi
    case "$ctype" in
        letsencrypt | self-signed | provided) ;;
        *) err "Unknown certificate type '$ctype' (use letsencrypt, self-signed or provided)."; return 1 ;;
    esac
    if [[ "$ctype" != self-signed && -z "$domain" ]]; then err "A domain is required for $ctype certificates."; return 1; fi

    if [[ "$ctype" == letsencrypt ]]; then
        email="$o_email"
        while ! is_email "$email"; do
            [[ -n "$email" ]] && err "Invalid email: '$email'"
            ask email "Email for Let's Encrypt notices" "" || return 1
        done
        if ! le_preflight "$domain" "$ip"; then
            if ask_yn "Use a self-signed certificate instead? (you can switch later: Settings → TLS certificate)" Y; then
                ctype=self-signed
            else
                return 1
            fi
        fi
    elif [[ "$ctype" == provided ]]; then
        cf="$o_cf" kf="$o_kf"
        while [[ ! -r "$cf" ]]; do [[ -n "$cf" ]] && err "Not readable: $cf"; ask cf "Path to certificate chain (PEM)" "" || return 1; done
        while [[ ! -r "$kf" ]]; do [[ -n "$kf" ]] && err "Not readable: $kf"; ask kf "Path to private key (PEM)" "" || return 1; done
        cf=$(readlink -f "$cf") kf=$(readlink -f "$kf")
        cert_key_match "$cf" "$kf" || { err "Certificate and private key do not match."; return 1; }
        openssl x509 -in "$cf" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match' ||
            warn "The certificate does not appear to cover $domain."
    fi

    # ── port
    section "Listening port"
    port="$o_port"
    while true; do
        [[ -z "$port" ]] && { ask port "Port (TCP + UDP)" "443" || return 1; }
        if ! is_port "$port"; then err "Invalid port: '$port'"; port=""; continue; fi
        port=$((10#$port))
        if [[ "$ctype" == letsencrypt && "$port" == 80 ]]; then err "Port 80 is needed for Let's Encrypt."; port=""; continue; fi
        if port_busy "$port" tcp || port_busy "$port" udp; then
            warn "Port $port is already in use${C_DIM} ($(port_owner "$port"))${C_RST}."
            if ! ask_yn "Use it anyway?" N; then port=""; continue; fi
        fi
        break
    done

    # ── first user
    section "First VPN user"
    user="$o_user"
    while ! valid_username "$user"; do
        [[ -n "$user" ]] && err "Username: 1-32 chars, letters/digits/._@- , must start with a letter or digit."
        ask user "Username" "user1" || return 1
    done
    pass="$o_pass"
    if [[ -n "$pass" ]] && ! valid_password "$pass"; then err "Invalid --password (8-128 chars, no spaces, quotes or backslashes)."; return 1; fi
    [[ -z "$pass" ]] && pass=$(randpass 20)
    name="${o_name:-}"
    [[ -z "$name" ]] && { ask name "Server name shown in client apps" "TrustTunnel" || return 1; }
    name="${name//\"/}"

    section "Summary"
    kv "Address" "${domain:-$ip}"
    kv "TLS host" "$tls_host"
    kv "Port" "$port (TCP + UDP)"
    kv "Certificate" "$ctype"
    [[ -n "$email" ]] && kv "ACME email" "$email"
    kv "User" "$user"
    kv "Install dir" "$TT_DIR"
    echo
    ask_yn "Proceed with installation?" Y || { info "Cancelled."; return 0; }

    # ── binaries
    local ver
    ver=$(install_version "$o_ver")
    fetch_release "$ver" || return 1

    # ── config (always generated with a self-signed cert, then upgraded)
    run_wizard "$user" "$pass" "$port" "$tls_host" || return 1
    ok "Configuration generated."
    case "$ctype" in
        letsencrypt)
            if le_issue "$domain" "$email"; then
                hosts_use_cert "$(le_live_dir "$domain")/fullchain.pem" "$(le_live_dir "$domain")/privkey.pem" || return 1
            elif ask_yn "Continue with a self-signed certificate for now? (switch later: Settings → TLS certificate)" Y; then
                ctype=self-signed email=""
            else
                return 1
            fi ;;
        provided) install_cert_files "$cf" "$kf" || return 1 ;;
    esac

    install -d -m 700 "$BACKUP_DIR" "$CLIENTS_DIR"
    chmod 600 "$TT_DIR"/*.toml 2>/dev/null
    local k; k=$(key_path) && [[ -f "$k" ]] && chmod 600 "$k"

    conf_defaults
    PUBLIC_ADDR="${domain:-$ip}" TLS_HOST="$tls_host" CERT_TYPE="$ctype" ACME_EMAIL="$email" SERVER_NAME="$name"
    if [[ -n "$o_dns" ]]; then
        if valid_dns_list "$o_dns"; then DNS_UPSTREAMS="$o_dns"; else warn "Ignoring invalid --dns value."; fi
    fi
    conf_save || { err "Failed to save $CONF"; return 1; }

    validate_config "$user" || return 1

    # ── service
    write_unit
    systemctl enable "$SERVICE" >/dev/null 2>&1
    info "Starting TrustTunnel…"
    if svc_restart_checked; then
        ok "Service ${C_BOLD}$SERVICE${C_RST} is running and enabled at boot."
    else
        err "Service failed to start."; svc_journal; return 1
    fi
    fw_open "$port" tcp udp
    self_install

    if [[ "$ctype" == letsencrypt ]]; then
        ask_yn "Enable automatic certificate renewal?" Y && renew_timer_enable
    fi

    section "Done"
    ok "${C_BOLD}TrustTunnel is up.${C_RST}"
    printf '  %sIf your provider has an external firewall/security group, allow TCP and UDP port %s there too.%s\n' "$C_DIM" "$port" "$C_RST"
    show_user_config "$user"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Commands: users
# ─────────────────────────────────────────────────────────────────────────────
pick_user() { # pick_user VAR "prompt"
    local _pu_var="$1" _pu_ans i
    users_load
    ((${#U_NAMES[@]})) || { err "No users."; return 1; }
    list_users_table 0
    ask _pu_ans "$2 (number or name)" "" || return 1
    [[ -z "$_pu_ans" ]] && return 1
    if [[ "$_pu_ans" =~ ^[0-9]{1,6}$ ]] && ((10#$_pu_ans >= 1 && 10#$_pu_ans <= ${#U_NAMES[@]})); then
        _pu_ans="${U_NAMES[10#$_pu_ans - 1]}"
    fi
    for i in "${U_NAMES[@]}"; do
        [[ "$i" == "$_pu_ans" ]] && { printf -v "$_pu_var" '%s' "$_pu_ans"; return 0; }
    done
    err "User '$_pu_ans' not found."
    return 1
}

list_users_table() {
    local show_pw="${1:-0}" i n
    n=${#U_NAMES[@]}
    if ((n == 0)); then warn "No users configured."; return 0; fi
    if ((show_pw)); then
        printf '\n  %s%-4s %-34s %s%s\n' "$C_BOLD" "#" "USERNAME" "PASSWORD" "$C_RST"
    else
        printf '\n  %s%-4s %-34s %s%s\n' "$C_BOLD" "#" "USERNAME" "CLIENT FILE" "$C_RST"
    fi
    for ((i = 0; i < n; i++)); do
        if ((show_pw)); then
            printf '  %s%-4s%s %-34s %s\n' "$C_CYN" "$((i + 1))" "$C_RST" "${U_NAMES[i]}" "${U_PASS[i]}"
        else
            local f="-"; [[ -f "$CLIENTS_DIR/${U_NAMES[i]}.toml" ]] && f="clients/${U_NAMES[i]}.toml"
            printf '  %s%-4s%s %-34s %s%s%s\n' "$C_CYN" "$((i + 1))" "$C_RST" "${U_NAMES[i]}" "$C_DIM" "$f" "$C_RST"
        fi
    done
    printf '\n  %sTotal: %d user(s)%s\n' "$C_DIM" "$n" "$C_RST"
}

cmd_list() {
    need_installed || return 1
    local show=0
    [[ "${1:-}" == "--passwords" || "${1:-}" == "-p" ]] && show=1
    users_load
    section "Users"
    list_users_table "$show"
}

cmd_add() {
    need_installed || return 1
    local user="" pass="" snap
    while (($#)); do
        case "$1" in
            --password | -p) pass="${2:-}"; shift ;;
            -*) err "Unknown option: $1"; return 1 ;;
            *) user="$1" ;;
        esac
        shift
    done
    users_load
    section "Add user"
    while true; do
        if [[ -z "$user" ]]; then ask user "New username" "" || return 1; fi
        if ! valid_username "$user"; then
            err "Username: 1-32 chars, letters/digits/._@- , must start with a letter or digit."; user=""; continue
        fi
        if user_exists "$user"; then err "User '$user' already exists."; user=""; continue; fi
        break
    done
    if [[ -z "$pass" ]]; then
        if [[ -t 0 || "$TTY_IN" == /dev/tty ]] && ! ((ASSUME_YES)) && ask_yn "Set a custom password? (No = generate a strong one)" N; then
            while true; do
                ask_secret pass "Password (8-128 chars, no spaces/quotes/backslashes)" || return 1
                valid_password "$pass" || { err "Invalid password."; continue; }
                local p2; ask_secret p2 "Repeat password" || return 1
                [[ "$pass" == "$p2" ]] && break
                err "Passwords do not match."
            done
        else
            pass=$(randpass 20)
        fi
    elif ! valid_password "$pass"; then
        err "Invalid password (8-128 chars, no spaces, quotes or backslashes)."; return 1
    fi

    snap=$(snapshot_create auto) || { err "Could not create a safety snapshot."; return 1; }
    creds_append "$user" "$pass" || { err "Failed to write credentials."; return 1; }
    apply_changes "$snap" "$user" || return 1
    ok "User ${C_BOLD}$user${C_RST} added."
    show_user_config "$user"
}

cmd_revoke() {
    need_installed || return 1
    local user="${1:-}" snap
    users_load
    section "Revoke user"
    if [[ -z "$user" ]]; then pick_user user "User to revoke" || return 1; fi
    user_exists "$user" || { err "User '$user' not found."; return 1; }
    if ((${#U_NAMES[@]} <= 1)); then
        err "'$user' is the last user. TrustTunnel refuses to start with zero users."
        info "Add another user first, or stop the service: ttm stop"
        return 1
    fi
    ask_yn "Revoke '${user}'? Their devices will be disconnected" N || { info "Cancelled."; return 0; }
    snap=$(snapshot_create auto) || { err "Could not create a safety snapshot."; return 1; }
    creds_edit remove "$user" || { err "Failed to update credentials."; return 1; }
    users_load
    if user_exists "$user"; then err "Removal failed (user still present)."; snapshot_restore "$snap"; return 1; fi
    apply_changes "$snap" || return 1
    prune_clients
    ok "User ${C_BOLD}$user${C_RST} revoked. Active sessions were dropped by the restart."
}

cmd_passwd() {
    need_installed || return 1
    local user="${1:-}" pass="${2:-}" snap
    users_load
    section "Reset password"
    if [[ -z "$user" ]]; then pick_user user "User" || return 1; fi
    user_exists "$user" || { err "User '$user' not found."; return 1; }
    if [[ -n "$pass" ]]; then
        valid_password "$pass" || { err "Invalid password (8-128 chars, no spaces, quotes or backslashes)."; return 1; }
    else
        pass=$(randpass 20)
    fi
    ask_yn "Set a new password for '$user'? Old configs stop working" Y || { info "Cancelled."; return 0; }
    snap=$(snapshot_create auto) || { err "Could not create a safety snapshot."; return 1; }
    creds_edit setpass "$user" "$pass" || { err "Failed to update credentials."; return 1; }
    apply_changes "$snap" "$user" || return 1
    ok "Password for ${C_BOLD}$user${C_RST} changed."
    show_user_config "$user"
}

cmd_show() {
    need_installed || return 1
    local user="${1:-}"
    if [[ -z "$user" ]]; then section "Show client config"; pick_user user "User" || return 1; fi
    show_user_config "$user"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Commands: status / service / logs
# ─────────────────────────────────────────────────────────────────────────────
status_line() {
    local st
    if ! is_installed; then printf '%s%s not installed%s' "$C_DIM" "$G_DOT" "$C_RST"; return; fi
    st=$(systemctl is-active "$SERVICE" 2>/dev/null)
    case "$st" in
        active) printf '%s%s running%s' "$C_GRN" "$G_DOT" "$C_RST" ;;
        activating) printf '%s%s starting/restarting%s' "$C_YLW" "$G_DOT" "$C_RST" ;;
        failed) printf '%s%s failed%s' "$C_RED" "$G_DOT" "$C_RST" ;;
        *) printf '%s%s stopped%s' "$C_RED" "$G_DOT" "$C_RST" ;;
    esac
}

cmd_status() {
    need_installed || return 1
    conf_load
    users_load
    local port since mem days cert end fwk fwtxt="" bbr en
    port=$(listen_port)
    section "TrustTunnel status"
    en=$(svc_enabled && echo "enabled at boot" || echo "not enabled at boot")
    kv "Service" "$(status_line)  ${C_DIM}($en)${C_RST}"
    if svc_active; then
        since=$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE" 2>/dev/null)
        [[ -n "$since" ]] && kv "Since" "$since"
        mem=$(systemctl show -p MemoryCurrent --value "$SERVICE" 2>/dev/null)
        [[ "$mem" =~ ^[0-9]+$ ]] && kv "Memory" "$(awk -v b="$mem" 'BEGIN { printf "%.1f MiB", b / 1048576 }')"
    fi
    kv "Version" "$(installed_version)"
    kv "Listen" "$(listen_address) (TCP + UDP)"
    kv "Address" "${PUBLIC_ADDR:-?}"
    kv "TLS host" "$(hosts_main_field hostname)"
    cert=$(cert_path) || cert=""
    if [[ -n "$cert" && -r "$cert" ]]; then
        end=$(cert_enddate "$cert"); days=$(cert_days_left) || days="?"
        local col="$C_GRN"
        [[ "$days" =~ ^-?[0-9]+$ ]] && { ((days < 30)) && col="$C_YLW"; ((days < 7)) && col="$C_RED"; }
        kv "Certificate" "${CERT_TYPE:-?}, expires ${end:-?} ${col}(${days} days)${C_RST}"
        [[ "$CERT_TYPE" == letsencrypt ]] &&
            kv "Auto-renew" "$(renew_timer_enabled && echo "${C_GRN}on${C_RST}" || echo "${C_YLW}off${C_RST}")"
    else
        kv "Certificate" "${C_RED}missing ($cert)${C_RST}"
    fi
    kv "Users" "${#U_NAMES[@]}"
    kv "IPv6 routing" "$(toml_get ipv6_available "$VPN_TOML")"
    kv "Private nets" "$(toml_get allow_private_network_connections "$VPN_TOML")"
    kv "ICMP" "$(icmp_enabled && echo enabled || echo disabled)"
    kv "DNS (clients)" "${DNS_UPSTREAMS:-client default}"
    kv "Log level" "$LOG_LEVEL"
    fwk=$(fw_kind)
    if [[ "$fwk" != none ]]; then
        local p
        for p in tcp udp; do
            fw_is_open "$port" "$p" && fwtxt+="${C_GRN}$port/$p${C_RST} " || fwtxt+="${C_RED}$port/$p closed${C_RST} "
        done
        kv "Firewall" "$fwk: $fwtxt"
    else
        kv "Firewall" "${C_DIM}no ufw/firewalld detected${C_RST}"
    fi
    bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    kv "TCP cong." "${bbr:-?}"
    echo
    selftest || { svc_active || svc_journal 8; }
}

# Live self-test against the local endpoint: TLS handshake + auth accept/reject.
auth_probe() { # host port creds -> prints CONNECT status code
    env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
        curl -sk -o /dev/null -w '%{http_connect}' --max-time 8 --proxytunnel \
        --proxy "https://$1:$2" --resolve "$1:$2:127.0.0.1" --proxy-insecure \
        --proxy-user "$3" "https://example.com/" 2>/dev/null
}

selftest() {
    local port host bad=0 code
    port=$(listen_port); host=$(hosts_main_field hostname)
    users_load
    if ! svc_active; then kv "Self-test" "${C_RED}service is not running${C_RST}"; return 1; fi
    if is_ipv4 "$host"; then
        kv "Self-test" "${C_RED}TLS hostname is an IP ($host) — clients cannot connect (IP is not valid SNI).${C_RST}"
        kv "" "Fix: 'ttm install' → reconfigure, and give a hostname."
        return 1
    fi
    if echo | timeout 8 openssl s_client -connect "127.0.0.1:$port" -servername "$host" 2>/dev/null |
        openssl x509 -noout 2>/dev/null; then
        kv "TLS check" "${C_GRN}$G_OK handshake OK${C_RST} (SNI $host)"
    else
        kv "TLS check" "${C_RED}$G_ERR handshake failed${C_RST} on 127.0.0.1:$port (SNI $host)"
        return 1
    fi
    code=$(auth_probe "$host" "$port" "ttm-selftest-$(randpass 6):$(randpass 12)")
    if [[ "$code" == 407 ]]; then
        kv "Auth check" "${C_GRN}$G_OK wrong password rejected${C_RST}"
    else
        kv "Auth check" "${C_RED}$G_ERR wrong password not rejected (got ${code:-none})${C_RST}"; bad=1
    fi
    if ((${#U_NAMES[@]})); then
        code=$(auth_probe "$host" "$port" "${U_NAMES[0]}:${U_PASS[0]}")
        if [[ "$code" =~ ^[0-9]+$ && "$code" != 407 && "$code" != 000 ]]; then
            kv "" "${C_GRN}$G_OK user '${U_NAMES[0]}' accepted${C_RST}"
        else
            kv "" "${C_RED}$G_ERR user '${U_NAMES[0]}' not accepted (got ${code:-none})${C_RST}"; bad=1
        fi
    fi
    return "$bad"
}

cmd_check() {
    need_installed || return 1
    section "Self-test"
    if selftest; then ok "Endpoint is working."; else err "Self-test found problems (see above, and: ttm logs)."; return 1; fi
}

cmd_service() { # start|stop|restart|enable|disable
    need_installed || return 1
    case "$1" in
        start | restart)
            validate_config || return 1
            if svc_restart_checked; then ok "TrustTunnel is running."; else err "TrustTunnel failed to start."; svc_journal; return 1; fi ;;
        stop) systemctl stop "$SERVICE" && ok "TrustTunnel stopped." ;;
        enable) systemctl enable "$SERVICE" >/dev/null 2>&1 && ok "Autostart at boot enabled." ;;
        disable) systemctl disable "$SERVICE" >/dev/null 2>&1 && ok "Autostart at boot disabled." ;;
    esac
}

cmd_logs() {
    command -v journalctl >/dev/null 2>&1 || { err "journalctl not available."; return 1; }
    if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]] || [[ -z "${1:-}" && -t 1 ]]; then
        info "Following logs — press Ctrl+C to stop."
        trap 'true' INT
        journalctl -u "$SERVICE" -n 50 -f --no-pager
        trap - INT
        echo
    else
        journalctl -u "$SERVICE" -n "${1:-100}" --no-pager
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Commands: settings
# ─────────────────────────────────────────────────────────────────────────────
icmp_enabled() { grep -qE '^[[:space:]]*\[icmp\]' "$VPN_TOML" 2>/dev/null; }

toggle_bool_setting() { # key label
    local key="$1" label="$2" cur new snap
    cur=$(toml_get "$key" "$VPN_TOML")
    [[ "$cur" == true ]] && new=false || new=true
    ask_yn "$label is '${cur:-unset}'. Change to '$new'?" Y || return 0
    snap=$(snapshot_create auto) || return 1
    toml_set "$key" "$new" "$VPN_TOML" || { err "Failed to update $VPN_TOML"; return 1; }
    apply_changes "$snap" && ok "$label: $new"
}

set_port() {
    local cur_addr cur_port host port snap
    cur_addr=$(listen_address); cur_port="${cur_addr##*:}"; host="${cur_addr%:*}"
    [[ -z "$host" ]] && host="0.0.0.0"
    ask port "New port" "$cur_port" || return 1
    is_port "$port" || { err "Invalid port."; return 1; }
    port=$((10#$port))
    [[ "$port" == "$cur_port" ]] && { info "Port unchanged."; return 0; }
    if port_busy "$port" tcp || port_busy "$port" udp; then
        warn "Port $port is in use ($(port_owner "$port"))."
        ask_yn "Use it anyway?" N || return 1
    fi
    snap=$(snapshot_create auto) || return 1
    toml_set listen_address "\"$host:$port\"" "$VPN_TOML" || return 1
    fw_open "$port" tcp udp
    if apply_changes "$snap"; then
        fw_close "$cur_port" tcp udp
        ok "Listening on port $port."
        if [[ "$PUBLIC_ADDR" == *:* ]]; then
            warn "Public address '$PUBLIC_ADDR' includes an explicit port — update it in Settings if needed."
        fi
        warn "Existing client links contain the old port — re-share them (ttm show <user>)."
    else
        fw_close "$port" tcp udp
        return 1
    fi
}

set_public_addr() {
    conf_load
    local a
    printf '  %sHost or IP clients connect to (optionally host:port if behind port forwarding).%s\n' "$C_DIM" "$C_RST"
    ask a "Public address" "${PUBLIC_ADDR:-$(detect_public_ip)}" || return 1
    valid_public_addr "$a" || { err "Invalid address."; return 1; }
    PUBLIC_ADDR="$a"
    conf_save && ok "Public address set to $a. Re-share client links to apply."
}

set_server_name() {
    conf_load
    local n
    ask n "Server name shown in client apps" "$SERVER_NAME" || return 1
    n="${n//\"/}"
    [[ -z "$n" ]] && { err "Name cannot be empty."; return 1; }
    SERVER_NAME="$n"
    conf_save && ok "Server name set. Re-share client links to apply."
}

set_dns() {
    conf_load
    local d
    printf '  %sSpace-separated. Examples: 1.1.1.1  tls://dns.google  https://dns.adguard-dns.com/dns-query%s\n' "$C_DIM" "$C_RST"
    printf '  %sEnter "-" to clear (clients use their default).%s\n' "$C_DIM" "$C_RST"
    ask d "DNS upstreams for client configs" "${DNS_UPSTREAMS:--}" || return 1
    [[ "$d" == "-" ]] && d=""
    valid_dns_list "$d" || { err "Invalid DNS list."; return 1; }
    DNS_UPSTREAMS="$d"
    conf_save && ok "DNS upstreams: ${d:-client default}. Re-share client links to apply."
}

toggle_icmp() {
    local snap iface
    snap=$(snapshot_create auto) || return 1
    if icmp_enabled; then
        if ! grep -q '^# >>> ttm:icmp' "$VPN_TOML"; then
            err "[icmp] was added manually — edit vpn.toml to remove it."; return 1
        fi
        ask_yn "Disable ICMP (ping) forwarding?" Y || return 0
        sed -i '/^# >>> ttm:icmp/,/^# <<< ttm:icmp/d' "$VPN_TOML"
    else
        iface=$(default_iface); iface="${iface:-eth0}"
        ask iface "Outbound network interface" "$iface" || return 1
        [[ "$iface" =~ ^[A-Za-z0-9._@-]{1,15}$ ]] || { err "Invalid interface name."; return 1; }
        ensure_trailing_newline "$VPN_TOML"
        printf '\n# >>> ttm:icmp\n[icmp]\ninterface_name = "%s"\nrequest_timeout_secs = 3\nrecv_message_queue_capacity = 256\n# <<< ttm:icmp\n' \
            "$iface" >>"$VPN_TOML"
    fi
    apply_changes "$snap" && ok "ICMP forwarding: $(icmp_enabled && echo enabled || echo disabled)"
}

set_log_level() {
    conf_load
    local l
    ask l "Log level (info / debug / trace)" "$LOG_LEVEL" || return 1
    case "$l" in info | debug | trace) ;; *) err "Invalid level."; return 1 ;; esac
    LOG_LEVEL="$l"
    conf_save && write_unit
    if svc_active && ! svc_restart_checked; then err "Restart failed."; svc_journal; return 1; fi
    ok "Log level: $l"
}

toggle_bbr() {
    local cur
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ -f "$SYSCTL_FILE" ]]; then
        ask_yn "Network tuning is enabled (current: ${cur:-?}). Remove it?" N || return 0
        rm -f "$SYSCTL_FILE"
        sysctl --system >/dev/null 2>&1
        ok "Tuning file removed (takes full effect after reboot)."
        return 0
    fi
    ask_yn "Enable BBR congestion control + larger UDP buffers for QUIC?" Y || return 0
    modprobe tcp_bbr 2>/dev/null
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        err "This kernel does not support BBR."; return 1
    fi
    cat >"$SYSCTL_FILE" <<'EOF'
# Managed by ttm (TrustTunnel Manager)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
EOF
    chmod 644 "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "Some values could not be applied now (container/VPS limits?)."
    ok "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

cert_menu() {
    conf_load
    local days c
    days=$(cert_days_left) || days="?"
    section "TLS certificate"
    kv "Type" "${CERT_TYPE:-?}"
    kv "Host" "$(hosts_main_field hostname)"
    kv "File" "$(cert_path)"
    kv "Days left" "$days"
    echo
    menu_item 1 "Renew Let's Encrypt certificate now"
    menu_item 2 "Switch to a Let's Encrypt certificate (needs a domain)"
    menu_item 3 "Automatic renewal: $(renew_timer_enabled && echo on || echo off) (toggle)"
    menu_item 4 "Use my own certificate files"
    menu_item 0 "Back"
    ask c "Choose" "0" || return 1
    case "$c" in
        1) cmd_renew_cert --force ;;
        2) switch_to_le ;;
        3)
            if renew_timer_enabled; then renew_timer_disable
            elif [[ "$CERT_TYPE" == letsencrypt ]]; then renew_timer_enable
            else err "Automatic renewal is only for Let's Encrypt certificates."; fi ;;
        4) replace_cert ;;
    esac
}

replace_cert() {
    local cf kf snap host
    ask cf "Path to certificate chain (PEM)" "" || return 1
    ask kf "Path to private key (PEM)" "" || return 1
    [[ -r "$cf" && -r "$kf" ]] || { err "Files not readable."; return 1; }
    openssl x509 -in "$cf" -noout 2>/dev/null || { err "Not a valid PEM certificate."; return 1; }
    cert_key_match "$cf" "$kf" || { err "Certificate and key do not match."; return 1; }
    host=$(hosts_main_field hostname)
    openssl x509 -in "$cf" -noout -checkhost "$host" 2>/dev/null | grep -q 'does match' ||
        warn "The certificate does not appear to cover the TLS hostname '$host'."
    snap=$(snapshot_create auto) || return 1
    install_cert_files "$cf" "$kf" || { snapshot_restore "$snap"; return 1; }
    conf_load; CERT_TYPE=provided; conf_save
    renew_timer_enabled && renew_timer_disable
    apply_changes "$snap" && ok "Certificate replaced. Valid for $(cert_days_left) days."
}

edit_file() {
    local c f editor snap
    echo "   1) vpn.toml    (main settings)"
    echo "   2) hosts.toml  (TLS hosts)"
    echo "   3) rules.toml  (connection filtering)"
    ask c "File" "1" || return 1
    case "$c" in 1) f="$VPN_TOML" ;; 2) f="$HOSTS_TOML" ;; 3) f="$TT_DIR/rules.toml" ;; *) return 0 ;; esac
    editor="${VISUAL:-${EDITOR:-}}"
    if [[ -z "$editor" ]]; then
        editor=$(command -v nano || command -v vim || command -v vi) || { err "No editor found (set \$EDITOR)."; return 1; }
    fi
    snap=$(snapshot_create auto) || return 1
    [[ -e "$f" ]] || : >"$f"
    $editor "$f" <"$TTY_IN"
    if tar -xOzf "$snap" "$(basename "$f")" 2>/dev/null | cmp -s - "$f"; then info "No changes."; return 0; fi
    apply_changes "$snap" && ok "Changes applied."
}

cmd_settings() {
    need_installed || return 1
    local c
    while true; do
        conf_load
        clear_screen
        banner
        section "Settings"
        printf '   %s1)%s Listening port              %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$(listen_port)" "$C_RST"
        printf '   %s2)%s Public address (in links)   %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "${PUBLIC_ADDR:-?}" "$C_RST"
        printf '   %s3)%s Server display name         %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$SERVER_NAME" "$C_RST"
        printf '   %s4)%s DNS upstreams for clients   %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "${DNS_UPSTREAMS:-default}" "$C_RST"
        printf '   %s5)%s IPv6 routing                %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$(toml_get ipv6_available "$VPN_TOML")" "$C_RST"
        printf '   %s6)%s Access to server LAN        %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$(toml_get allow_private_network_connections "$VPN_TOML")" "$C_RST"
        printf '   %s7)%s ICMP (ping) forwarding      %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$(icmp_enabled && echo on || echo off)" "$C_RST"
        printf '   %s8)%s Log level                   %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$LOG_LEVEL" "$C_RST"
        printf '   %s9)%s TLS certificate             %s%s, %s days%s\n' "$C_CYN" "$C_RST" "$C_DIM" "${CERT_TYPE:-?}" "$(cert_days_left || echo '?')" "$C_RST"
        printf '  %s10)%s Network tuning (BBR)        %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" "$C_RST"
        printf '  %s11)%s Edit config files manually\n' "$C_CYN" "$C_RST"
        printf '   %s0)%s Back\n\n' "$C_CYN" "$C_RST"
        ask c "Choose" "0" || return 0
        case "$c" in
            1) set_port ;;
            2) set_public_addr ;;
            3) set_server_name ;;
            4) set_dns ;;
            5) toggle_bool_setting ipv6_available "IPv6 routing" ;;
            6)
                warn "Allowing this lets VPN users reach the server's private/local networks (127.0.0.1, 10.x, 192.168.x…)."
                toggle_bool_setting allow_private_network_connections "Private network access" ;;
            7) toggle_icmp ;;
            8) set_log_level ;;
            9) cert_menu ;;
            10) toggle_bbr ;;
            11) edit_file ;;
            0 | q | Q) return 0 ;;
            *) err "Invalid choice." ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  Commands: certificate renewal
# ─────────────────────────────────────────────────────────────────────────────
cmd_renew_cert() {
    need_installed || return 1
    local auto=0 force=0 args
    while (($#)); do
        case "$1" in --auto) auto=1 ;; --force) force=1 ;; esac
        shift
    done
    conf_load
    [[ "$CERT_TYPE" == letsencrypt ]] || { err "Certificate is not from Let's Encrypt (type: ${CERT_TYPE:-unknown})."; return 1; }
    is_domain "$TLS_HOST" || { err "No domain recorded in $CONF."; return 1; }
    ensure_certbot || return 1
    if port_busy 80; then err "Port 80 is busy ($(port_owner 80)) — cannot run the HTTP-01 check."; return 1; fi
    args=(renew --cert-name "$TLS_HOST" --non-interactive)
    ((force)) && args+=(--force-renewal)
    ((auto)) && args+=(--quiet)
    ((auto)) || info "Checking/renewing the certificate for $TLS_HOST…"
    certbot_run "${args[@]}" || { err "Renewal failed (see output above)."; return 1; }
    cert_reload || return 1
    ((auto)) || ok "Certificate valid for $(cert_days_left) more days."
}

switch_to_le() {
    conf_load
    local d e ip snap live
    ip="$PUBLIC_ADDR"; is_ipv4 "$ip" || ip=$(detect_public_ip) || ip=""
    ask d "Domain pointing to this server" "" || return 1
    d="${d,,}"
    is_domain "$d" || { err "Invalid domain."; return 1; }
    ask e "Email for Let's Encrypt notices" "$ACME_EMAIL" || return 1
    is_email "$e" || { err "Invalid email."; return 1; }
    le_preflight "$d" "$ip" || return 1
    le_issue "$d" "$e" || return 1
    live=$(le_live_dir "$d")
    snap=$(snapshot_create auto) || return 1
    hosts_set_main hostname "$d" && hosts_use_cert "$live/fullchain.pem" "$live/privkey.pem" || { snapshot_restore "$snap"; return 1; }
    PUBLIC_ADDR="$d" TLS_HOST="$d" CERT_TYPE=letsencrypt ACME_EMAIL="$e"
    conf_save
    apply_changes "$snap" || return 1
    renew_timer_enable
    ok "Now using a Let's Encrypt certificate for $d."
    warn "Server address changed to $d — every user needs a new link: ttm show <user>"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Commands: update / backup / restore / uninstall
# ─────────────────────────────────────────────────────────────────────────────
cmd_update() {
    need_installed || return 1
    local force=0 cur latest="" rb was_active=0 f
    while (($#)); do
        case "$1" in
            --force) force=1 ;;
            --version) latest="${2#v}"; force=1; shift ;;
            *) err "Unknown option: $1"; return 1 ;;
        esac
        shift
    done
    ensure_deps
    cur=$(installed_version)
    if [[ -z "$latest" ]]; then
        info "Checking for updates…"
        latest=$(latest_version) || { err "Could not reach GitHub to check the latest version (try: ttm update --version X.Y.Z)."; return 1; }
    fi
    [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { err "Invalid version: $latest"; return 1; }
    if [[ "$cur" == "$latest" ]] && ((!force)); then ok "Already up to date (v$cur)."; return 0; fi
    ask_yn "Update TrustTunnel v$cur → v$latest?" Y || return 0
    rb=$(mktempdir) || return 1
    for f in trusttunnel_endpoint setup_wizard; do cp -p "$TT_DIR/$f" "$rb/$f"; done
    svc_active && was_active=1
    if ! fetch_release "$latest"; then return 1; fi
    if ! validate_config; then
        err "New version rejects the current config — rolling back."
        for f in trusttunnel_endpoint setup_wizard; do install -m 755 "$rb/$f" "$TT_DIR/$f"; done
        return 1
    fi
    if ((was_active)); then
        if ! svc_restart_checked; then
            err "New version failed to start — rolling back to v$cur."
            svc_journal 10
            for f in trusttunnel_endpoint setup_wizard; do install -m 755 "$rb/$f" "$TT_DIR/$f"; done
            svc_restart_checked && ok "Rolled back to v$cur." || err "Rollback failed — check ttm logs."
            return 1
        fi
    fi
    ok "Now running TrustTunnel v$(installed_version)."
    self_install >/dev/null 2>&1 || true
}

cmd_backup() {
    need_installed || return 1
    local out
    out=$(snapshot_create manual clients) || { err "Backup failed."; return 1; }
    ok "Backup created: ${C_BOLD}$out${C_RST}"
    printf '  %sContains configs, users, certificates. Keep it private.%s\n' "$C_DIM" "$C_RST"
}

cmd_restore() {
    need_installed || return 1
    local files=() f i c snap
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2- | head -n 20)
    if [[ -n "${1:-}" ]]; then
        f="$1"
    else
        ((${#files[@]})) || { warn "No backups found in $BACKUP_DIR."; return 1; }
        section "Restore backup"
        for i in "${!files[@]}"; do
            printf '  %s%2d)%s %s %s(%s)%s\n' "$C_CYN" "$((i + 1))" "$C_RST" "$(basename "${files[i]}")" \
                "$C_DIM" "$(date -r "${files[i]}" '+%F %T')" "$C_RST"
        done
        ask c "Backup to restore (0 = cancel)" "0" || return 1
        [[ "$c" =~ ^[0-9]{1,6}$ ]] && ((10#$c >= 1 && 10#$c <= ${#files[@]})) || { info "Cancelled."; return 0; }
        f="${files[10#$c - 1]}"
    fi
    [[ -f "$f" ]] || { err "Not found: $f"; return 1; }
    tar -tzf "$f" >/dev/null 2>&1 || { err "Backup archive is corrupted."; return 1; }
    ask_yn "Restore $(basename "$f")? Current config is snapshotted first" Y || return 0
    snap=$(snapshot_create auto) || return 1
    snapshot_restore "$f" || return 1
    apply_changes "$snap" || return 1
    prune_clients
    ok "Backup restored."
}

cmd_uninstall() {
    local port confirm keep=""
    section "Uninstall TrustTunnel"
    warn "This removes the service, binaries, configuration and ALL users from $TT_DIR."
    if ((!ASSUME_YES)); then
        ask confirm "Type 'yes' to continue" "" || return 1
        [[ "$confirm" == yes ]] || { info "Cancelled."; return 0; }
    fi
    if is_installed; then
        port=$(listen_port)
        if ask_yn "Save a final backup to /root first?" Y; then
            keep=$(snapshot_create manual clients) && install -m 600 "$keep" "/root/trusttunnel-$(basename "$keep")" &&
                ok "Backup saved: /root/trusttunnel-$(basename "$keep")"
        fi
    fi
    systemctl disable --now "$RENEW_UNIT.timer" >/dev/null 2>&1
    systemctl disable --now "$SERVICE" >/dev/null 2>&1
    rm -f "$SYSTEMD_DIR/$SERVICE.service" "$SYSTEMD_DIR/$RENEW_UNIT.service" "$SYSTEMD_DIR/$RENEW_UNIT.timer" "$LE_HOOK"
    systemctl daemon-reload 2>/dev/null
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1
    ok "Service removed."
    [[ -n "${port:-}" ]] && fw_close "$port" tcp udp
    if [[ -n "$TT_DIR" && "$TT_DIR" != "/" && -e "$TT_DIR/trusttunnel_endpoint" ]]; then
        rm -rf -- "$TT_DIR" && ok "Removed $TT_DIR"
    elif [[ -d "$TT_DIR" ]]; then
        warn "Left $TT_DIR in place (does not look like a TrustTunnel install)."
    fi
    if [[ -f "$SYSCTL_FILE" ]] && ask_yn "Remove network tuning (BBR) settings too?" N; then
        rm -f "$SYSCTL_FILE" && sysctl --system >/dev/null 2>&1
    fi
    rm -f "$BIN_PATH"
    ok "${C_BOLD}TrustTunnel uninstalled.${C_RST}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Interactive menu
# ─────────────────────────────────────────────────────────────────────────────
clear_screen() { [[ -t 1 ]] && printf '\e[H\e[2J'; return 0; }

menu_header() {
    clear_screen
    banner
    if is_installed; then
        conf_load; users_load
        printf '  %s   %sv%s%s   port %s%s%s   %s%d user(s)%s   %s%s%s\n' \
            "$(status_line)" "$C_DIM" "$(installed_version)" "$C_RST" \
            "$C_BOLD" "$(listen_port)" "$C_RST" "$C_BOLD" "${#U_NAMES[@]}" "$C_RST" \
            "$C_DIM" "${PUBLIC_ADDR:-}" "$C_RST"
    else
        printf '  %s\n' "$(status_line)"
    fi
}

menu_item() { printf '  %s%3s)%s %s\n' "$C_CYN" "$1" "$C_RST" "$2"; }

service_menu() {
    local c
    section "Service control"
    menu_item 1 "Start"
    menu_item 2 "Stop"
    menu_item 3 "Restart"
    menu_item 4 "Enable autostart at boot"
    menu_item 5 "Disable autostart at boot"
    menu_item 0 "Back"
    ask c "Choose" "0" || return 0
    case "$c" in
        1) cmd_service start ;; 2) cmd_service stop ;; 3) cmd_service restart ;;
        4) cmd_service enable ;; 5) cmd_service disable ;;
    esac
}

backup_menu() {
    local c
    section "Backup / Restore"
    menu_item 1 "Create backup"
    menu_item 2 "Restore from backup"
    menu_item 0 "Back"
    ask c "Choose" "0" || return 0
    case "$c" in 1) cmd_backup ;; 2) cmd_restore ;; esac
}

main_menu() {
    local c
    while true; do
        menu_header
        echo
        if ! is_installed; then
            menu_item 1 "Install TrustTunnel"
            menu_item 0 "Exit"
            echo
            ask c "Choose" "1" || exit 0
            case "$c" in
                1) cmd_install; pause ;;
                0 | q | Q) exit 0 ;;
            esac
            continue
        fi
        printf '  %sUsers%s\n' "$C_BOLD" "$C_RST"
        menu_item 1 "Add user"
        menu_item 2 "Revoke user"
        menu_item 3 "List users"
        menu_item 4 "Show user link / QR code"
        menu_item 5 "Reset user password"
        printf '  %sServer%s\n' "$C_BOLD" "$C_RST"
        menu_item 6 "Status"
        menu_item 7 "Start / stop / restart"
        menu_item 8 "Logs"
        menu_item 9 "Settings"
        menu_item 10 "Update TrustTunnel"
        menu_item 11 "Backup / restore"
        menu_item 12 "Reinstall / reconfigure"
        menu_item 13 "${C_RED}Uninstall${C_RST}"
        menu_item 0 "Exit"
        echo
        ask c "Choose" "" || exit 0
        case "$c" in
            1) cmd_add ;;
            2) cmd_revoke ;;
            3) cmd_list ;;
            4) cmd_show ;;
            5) cmd_passwd ;;
            6) cmd_status ;;
            7) service_menu ;;
            8) cmd_logs -f; continue ;;
            9) cmd_settings; continue ;;
            10) cmd_update ;;
            11) backup_menu ;;
            12) cmd_install ;;
            13) cmd_uninstall; is_installed || exit 0 ;;
            0 | q | Q) exit 0 ;;
            "") continue ;;
            *) err "Invalid choice." ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLI
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${C_BOLD}TrustTunnel Manager${C_RST} v$TTM_VERSION

${C_BOLD}Usage:${C_RST} ttm [command] [options]      (no command = interactive menu)

${C_BOLD}Setup${C_RST}
  install [opts]            Install & configure. Options:
                              --domain D  --email E  --cert letsencrypt|self-signed|provided
                              --cert-file F --key-file K  --port P  --ip IP
                              --sni NAME (TLS hostname when no domain; default vpn.internal)
                              --user U  --password P  --name N  --dns "1.1.1.1 tls://…"
                              --version X.Y.Z  -y
  update [--force]          Update TrustTunnel to the latest release (auto-rollback)
         [--version X.Y.Z]  …or install a specific version
  uninstall                 Remove everything (offers a final backup)

${C_BOLD}Users${C_RST}
  add [user] [-p pass]      Add a user and print their link + QR code
  revoke <user>             Remove a user (alias: del, remove)
  passwd <user> [pass]      Reset a user's password
  list [-p]                 List users (-p shows passwords)
  show <user>               Show a user's tt:// link, QR code and CLI config

${C_BOLD}Server${C_RST}
  status                    Service, certificate, firewall overview + self-test
  check                     Live self-test: TLS handshake + password accept/reject
  start | stop | restart    Control the service
  logs [-f | N]             Follow logs, or print the last N lines
  settings                  Interactive settings menu
  renew-cert [--force]      Renew the Let's Encrypt certificate
  backup | restore [file]   Backup / restore configuration and users

Global: -y / --yes  answer yes to confirmations,  NO_COLOR=1  disable colors
EOF
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$LOCK_FILE" || return 0
    flock -w "${1:-0}" 9 || die "Another ttm instance is running."
}

main() {
    setup_colors
    init_tty
    local args=() a
    for a in "$@"; do
        case "$a" in -y | --yes) ASSUME_YES=1 ;; *) args+=("$a") ;; esac
    done
    set -- "${args[@]+"${args[@]}"}"
    local cmd="${1:-menu}"
    (($#)) && shift

    case "$cmd" in
        help | -h | --help) usage; return 0 ;;
        version | -v | --version) echo "ttm $TTM_VERSION"; is_installed && echo "trusttunnel $(installed_version)"; return 0 ;;
    esac
    require_root
    case "$cmd" in
        menu)
            [[ -t 1 ]] || { usage; return 1; }
            acquire_lock
            main_menu ;;
        install) acquire_lock; cmd_install "$@" ;;
        add | add-user | useradd) acquire_lock; cmd_add "$@" ;;
        revoke | del | delete | remove | rm) acquire_lock; cmd_revoke "$@" ;;
        passwd | password | reset) acquire_lock; cmd_passwd "$@" ;;
        list | ls | users) cmd_list "$@" ;;
        show | link | qr | config) cmd_show "$@" ;;
        status | st) cmd_status ;;
        check | test | doctor) cmd_check ;;
        start | stop | restart | enable | disable) acquire_lock; cmd_service "$cmd" ;;
        logs | log) cmd_logs "$@" ;;
        settings) acquire_lock; cmd_settings ;;
        renew-cert | renew) acquire_lock 120; cmd_renew_cert "$@" ;;
        cert-reload) need_installed && cert_reload ;;
        update | upgrade) acquire_lock; cmd_update "$@" ;;
        backup) acquire_lock; cmd_backup ;;
        restore) acquire_lock; cmd_restore "$@" ;;
        uninstall) acquire_lock; cmd_uninstall ;;
        *) err "Unknown command: $cmd"; echo; usage; return 1 ;;
    esac
}

main "$@"
