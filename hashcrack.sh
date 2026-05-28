#!/usr/bin/env bash
# ==================================================================
#  hashcrack.sh  —  Hashcat TUI Wrapper
#  WPA2 / hash cracking toolkit with a fluxion-style interface
#
#  Features : guided attack modes, file/wordlist/rule pickers,
#             auto dependency install, persistent config,
#             keyspace estimation, session restore.
#  Repo     : https://github.com/jinx120/hashcrack
# ==================================================================

set -o pipefail
VERSION="1.1.0"

# ── Colors ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[0;31m';    LRED=$'\033[1;31m'
    GREEN=$'\033[0;32m';  LGREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m';   LCYAN=$'\033[1;36m'
    MAGENTA=$'\033[0;35m';WHITE=$'\033[1;37m'
    BOLD=$'\033[1m';      DIM=$'\033[2m';      RESET=$'\033[0m'
else
    RED=; LRED=; GREEN=; LGREEN=; YELLOW=; BLUE=; CYAN=; LCYAN=
    MAGENTA=; WHITE=; BOLD=; DIM=; RESET=
fi

# ── Defaults (overridden by config file) ───────────────────────────
WORDLIST_DIR="${HOME}/wordlists"
RULES_DIR="${HOME}/wordlists/rules"
HASH_MODE="22000"
WORKLOAD=3
OPTIMIZED="-O"
TEMP_ABORT=90
STATUS_TIMER=10
POTFILE="on"
SESSION="hashcrack"
EXTRA_FLAGS=""

CONFIG_DIR="${HOME}/.config/hashcrack"
CONFIG_FILE="${CONFIG_DIR}/config"

# ── Runtime state (not persisted) ──────────────────────────────────
HASH_FILE=""
WORDLIST=""
RULES_FILE=""
MASK=""
CMD=""
KS_CMD=""
HASHCAT_BIN=$(command -v hashcat 2>/dev/null || echo "hashcat")

# ── Layout ─────────────────────────────────────────────────────────
INNER_W=56                 # status-box inner content width
BOX_W=60                   # banner inner width

# ── UI primitives ──────────────────────────────────────────────────
hr()  { printf "  ${DIM}${CYAN}%s${RESET}\n" "────────────────────────────────────────────────────────"; }

repeat() { local n=$1 c=$2; local s=""; while (( n-- > 0 )); do s+="$c"; done; printf '%s' "$s"; }

banner() {
    clear
    local b="$LCYAN"
    printf "  %s╔%s╗%s\n" "$b" "$(repeat $BOX_W ═)" "$RESET"
    box_center ""
    box_center "H A S H C R A C K"
    box_center "WPA2 · Hashcat Cracking Suite   v${VERSION}"
    box_center ""
    printf "  %s╚%s╝%s\n" "$b" "$(repeat $BOX_W ═)" "$RESET"

    local gpu hcver
    gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    [[ -z "$gpu" ]] && gpu=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed 's/.*: //;s/ (rev.*//')
    [[ -z "$gpu" ]] && gpu="none detected"
    hcver=$(${HASHCAT_BIN} --version 2>/dev/null || echo "missing")
    printf "  ${DIM}GPU ${RESET}${YELLOW}%s${RESET}  ${DIM}·  hashcat ${RESET}${YELLOW}%s${RESET}\n" "$gpu" "$hcver"
    echo ""
}

box_center() {                       # centered line inside banner box
    local text="$1" len=${#1}
    local total=$(( BOX_W - len ))
    (( total < 0 )) && total=0
    local left=$(( total / 2 )) right=$(( total - total/2 ))
    printf "  ${LCYAN}║${RESET}%s${BOLD}${WHITE}%s${RESET}%s${LCYAN}║${RESET}\n" \
        "$(repeat $left ' ')" "$text" "$(repeat $right ' ')"
}

section() { echo ""; printf "  ${YELLOW}┌─ ${WHITE}${BOLD}%s${RESET}\n" "$1"; hr; }

ok()   { printf "  ${LGREEN}[✔]${RESET} %s\n" "$1"; }
err()  { printf "  ${LRED}[✘]${RESET} %s\n" "$1"; }
info() { printf "  ${LCYAN}[i]${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}[!]${RESET} %s\n" "$1"; }
ask()  { printf "  ${LCYAN}[>]${RESET} %s: " "$1"; }
pause(){ echo ""; printf "  ${DIM}Press Enter to continue…${RESET}"; read -r; }

# Status box ─ width-aware so colors never break alignment
box_top() { printf "  ${DIM}┌%s┐${RESET}\n" "$(repeat $((INNER_W+2)) ─)"; }
box_bot() { printf "  ${DIM}└%s┘${RESET}\n" "$(repeat $((INNER_W+2)) ─)"; }
kv_row() {                           # key, value, value-color
    local key="$1" val="$2" vc="${3:-$YELLOW}"
    local prefix; prefix=$(printf "%-11s : " "$key")        # 14 visible chars
    local maxval=$(( INNER_W - ${#prefix} ))
    (( ${#val} > maxval )) && val="${val:0:$((maxval-2))}.."
    local pad=$(( INNER_W - ${#prefix} - ${#val} ))
    (( pad < 0 )) && pad=0
    printf "  ${DIM}│ %s${RESET}${vc}%s${RESET}%s${DIM} │${RESET}\n" \
        "$prefix" "$val" "$(repeat $pad ' ')"
}

status_bar() {
    box_top
    kv_row "Hash file" "$([[ -n $HASH_FILE ]] && basename "$HASH_FILE" || echo 'not set')" \
        "$([[ -n $HASH_FILE ]] && echo "$YELLOW" || echo "$DIM")"
    kv_row "Wordlist"  "$([[ -n $WORDLIST ]] && basename "$WORDLIST" || echo 'not set')" \
        "$([[ -n $WORDLIST ]] && echo "$YELLOW" || echo "$DIM")"
    kv_row "Rules"     "$([[ -n $RULES_FILE ]] && basename "$RULES_FILE" || echo 'none')" \
        "$([[ -n $RULES_FILE ]] && echo "$YELLOW" || echo "$DIM")"
    kv_row "Mode"      "-m ${HASH_MODE}   -w ${WORKLOAD}   $([[ -n $OPTIMIZED ]] && echo '-O' || echo 'no-O')"
    box_bot
    echo ""
}

# ── Config persistence ─────────────────────────────────────────────
load_config() { [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null; }
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# hashcrack.sh config — auto-generated $(date)
WORDLIST_DIR="${WORDLIST_DIR}"
RULES_DIR="${RULES_DIR}"
HASH_MODE="${HASH_MODE}"
WORKLOAD="${WORKLOAD}"
OPTIMIZED="${OPTIMIZED}"
TEMP_ABORT="${TEMP_ABORT}"
STATUS_TIMER="${STATUS_TIMER}"
POTFILE="${POTFILE}"
SESSION="${SESSION}"
EXTRA_FLAGS="${EXTRA_FLAGS}"
EOF
}

# ── Dependencies ───────────────────────────────────────────────────
pkg_mgr() {
    if   command -v apt-get &>/dev/null; then echo apt
    elif command -v pacman  &>/dev/null; then echo pacman
    elif command -v dnf     &>/dev/null; then echo dnf
    else echo unknown; fi
}

# command -> package name for the active manager
pkg_for() {
    local cmd="$1" mgr; mgr=$(pkg_mgr)
    case "$cmd" in
        hashcat)        echo hashcat ;;
        hcxpcapngtool)  [[ $mgr == pacman ]] && echo hcxtools || echo hcxtools ;;
        7z)             case $mgr in apt) echo p7zip-full;; pacman) echo p7zip;; dnf) echo p7zip;; *) echo p7zip;; esac ;;
        curl)           echo curl ;;
        git)            echo git ;;
        *)              echo "$cmd" ;;
    esac
}

install_pkgs() {                     # install given package names
    local mgr; mgr=$(pkg_mgr)
    [[ $# -eq 0 ]] && return 0
    case "$mgr" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y "$@" ;;
        pacman) sudo pacman -Sy --noconfirm "$@" ;;
        dnf)    sudo dnf install -y "$@" ;;
        *)      err "Unknown package manager — install manually: $*"; return 1 ;;
    esac
}

check_deps() {
    banner
    section "Dependency Check  (manager: $(pkg_mgr))"
    echo ""
    local required=(hashcat)
    local optional=(hcxpcapngtool 7z curl)
    local missing_req=() missing_opt=()

    for c in "${required[@]}"; do
        if command -v "$c" &>/dev/null; then
            ok "$(printf '%-16s' "$c") required   $(command -v "$c")"
        else
            err "$(printf '%-16s' "$c") required   MISSING"
            missing_req+=("$(pkg_for "$c")")
        fi
    done
    echo ""
    for c in "${optional[@]}"; do
        if command -v "$c" &>/dev/null; then
            ok "$(printf '%-16s' "$c") optional   $(command -v "$c")"
        else
            warn "$(printf '%-16s' "$c") optional   missing"
            missing_opt+=("$(pkg_for "$c")")
        fi
    done

    local to_install=("${missing_req[@]}" "${missing_opt[@]}")
    if [[ ${#to_install[@]} -eq 0 ]]; then
        echo ""; ok "All dependencies satisfied."
        return 0
    fi

    echo ""
    info "Missing packages: ${to_install[*]}"
    ask "Install them now? [Y/n]"
    read -r yn
    if [[ ! "$yn" =~ ^[Nn]$ ]]; then
        echo ""
        install_pkgs "${to_install[@]}"
        HASHCAT_BIN=$(command -v hashcat 2>/dev/null || echo "hashcat")
        echo ""
        ok "Install step finished."
    fi
}

# Hard gate at startup: hashcat must exist
ensure_hashcat() {
    command -v hashcat &>/dev/null && return 0
    banner
    err "hashcat not found in PATH."
    echo ""
    ask "Install hashcat now? [Y/n]"
    read -r yn
    if [[ ! "$yn" =~ ^[Nn]$ ]]; then
        install_pkgs "$(pkg_for hashcat)"
        HASHCAT_BIN=$(command -v hashcat 2>/dev/null || echo "hashcat")
    fi
    if ! command -v hashcat &>/dev/null; then
        err "hashcat still unavailable — cannot continue."
        exit 1
    fi
}

# ── Generic file picker ────────────────────────────────────────────
#  $1 = title  $2 = "extra menu lines"  $3.. = find results captured by caller
PICK_RESULT=""
generic_pick() {
    local title="$1"; shift
    local allow_none="$1"; shift     # "none" to show a no-selection option
    local -a files=("$@")
    PICK_RESULT=""

    local i=1
    for f in "${files[@]}"; do
        local size
        if [[ -f "$f" ]]; then size=$(du -sh "$f" 2>/dev/null | cut -f1); else size="?"; fi
        printf "  ${CYAN}[%2d]${RESET}  %-46s ${DIM}%s${RESET}\n" "$i" "$(basename "$f")" "$size"
        ((i++))
    done
    [[ ${#files[@]} -eq 0 ]] && warn "Nothing found automatically — use manual entry."

    echo ""
    [[ "$allow_none" == "none" ]] && printf "  ${CYAN}[ n]${RESET}  ${DIM}none / skip${RESET}\n"
    printf "  ${CYAN}[ m]${RESET}  Enter path manually\n"
    printf "  ${CYAN}[ 0]${RESET}  Back\n\n"
    ask "Select"; read -r choice

    case "$choice" in
        0) return 1 ;;
        n) [[ "$allow_none" == "none" ]] && { PICK_RESULT=""; return 0; }; return 1 ;;
        m) ask "Full path"; read -r PICK_RESULT; PICK_RESULT="${PICK_RESULT/#\~/$HOME}" ;;
        ''|*[!0-9]*) err "Invalid selection"; sleep 1; return 1 ;;
        *)  if (( choice >= 1 && choice <= ${#files[@]} )); then
                PICK_RESULT="${files[$((choice-1))]}"
            else err "Out of range"; sleep 1; return 1; fi ;;
    esac
    return 0
}

pick_hash_file() {
    banner
    section "Select Hash / Capture File"
    info ".hc22000 · .hccapx · .cap · .pcap · .pcapng · hash lists"
    echo ""
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$(pwd)" "$HOME" "$HOME/captures" "$HOME/Desktop" "$WORDLIST_DIR" \
            -maxdepth 2 -type f \
            \( -name "*.hc22000" -o -name "*.hccapx" -o -name "*.cap" \
               -o -name "*.pcap" -o -name "*.pcapng" -o -name "*.hash" \) \
            2>/dev/null | sort -u)
    generic_pick "hash" "no" "${files[@]}" || return 1
    if [[ -f "$PICK_RESULT" ]]; then
        HASH_FILE="$PICK_RESULT"; ok "Hash file: $(basename "$HASH_FILE")"; sleep 0.5
    else err "File not found: $PICK_RESULT"; sleep 1.5; return 1; fi
}

pick_wordlist() {
    banner
    section "Select Wordlist"
    echo ""
    local files=()
    while IFS= read -r f; do
        [[ "$f" == *magnet* || "$f" == *tracker* ]] && continue
        files+=("$f")
    done < <(find "$WORDLIST_DIR" /usr/share/wordlists -maxdepth 1 -type f \
                  \( -name "*.txt" -o -name "*.lst" -o -name "*.dict" \) 2>/dev/null | sort -V -u)
    generic_pick "wordlist" "no" "${files[@]}" || return 1
    if [[ -f "$PICK_RESULT" ]]; then
        WORDLIST="$PICK_RESULT"; ok "Wordlist: $(basename "$WORDLIST")"; sleep 0.5
    else err "File not found: $PICK_RESULT"; sleep 1.5; return 1; fi
}

pick_rules() {
    banner
    section "Select Rules File  (optional)"
    echo ""
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$RULES_DIR" "$WORDLIST_DIR" /usr/share/hashcat/rules \
            -maxdepth 2 -type f -name "*.rule" 2>/dev/null | sort -u)
    generic_pick "rules" "none" "${files[@]}"
    local rc=$?
    [[ $rc -ne 0 ]] && return 1
    if [[ -z "$PICK_RESULT" ]]; then
        RULES_FILE=""; info "No rules — straight wordlist."; sleep 0.5; return 0
    fi
    if [[ -f "$PICK_RESULT" ]]; then
        RULES_FILE="$PICK_RESULT"; ok "Rules: $(basename "$RULES_FILE")"; sleep 0.5
    else err "File not found: $PICK_RESULT"; sleep 1.5; return 1; fi
}

pick_hash_mode() {
    banner
    section "Select Hash Mode"
    echo ""
    printf "  ${CYAN}[1]${RESET}  ${GREEN}22000${RESET}  WPA-PBKDF2-PMKID+EAPOL   ${DIM}← WPA2 recommended${RESET}\n"
    printf "  ${CYAN}[2]${RESET}  ${GREEN}2500${RESET}   WPA-EAPOL-PBKDF2          ${DIM}legacy .hccapx${RESET}\n"
    printf "  ${CYAN}[3]${RESET}  ${GREEN}16800${RESET}  WPA-PMKID-PBKDF2          ${DIM}PMKID only${RESET}\n"
    printf "  ${CYAN}[4]${RESET}  ${GREEN}0${RESET}      MD5\n"
    printf "  ${CYAN}[5]${RESET}  ${GREEN}100${RESET}    SHA1\n"
    printf "  ${CYAN}[6]${RESET}  ${GREEN}1000${RESET}   NTLM\n"
    printf "  ${CYAN}[7]${RESET}  ${GREEN}1800${RESET}   sha512crypt   ${DIM}Linux /etc/shadow${RESET}\n"
    printf "  ${CYAN}[8]${RESET}  ${GREEN}3200${RESET}   bcrypt\n"
    printf "  ${CYAN}[m]${RESET}  Manual mode number\n\n"
    ask "Select [Enter keeps ${YELLOW}${HASH_MODE}${RESET}]"; read -r choice
    case "$choice" in
        1) HASH_MODE=22000 ;; 2) HASH_MODE=2500 ;; 3) HASH_MODE=16800 ;;
        4) HASH_MODE=0 ;; 5) HASH_MODE=100 ;; 6) HASH_MODE=1000 ;;
        7) HASH_MODE=1800 ;; 8) HASH_MODE=3200 ;;
        m) ask "Mode number"; read -r HASH_MODE ;;
        "") : ;; *) warn "Keeping -m $HASH_MODE" ;;
    esac
    ok "Hash mode: -m $HASH_MODE"; sleep 0.5
}

build_mask() {
    banner
    section "Mask Builder"
    echo ""
    printf "  ${YELLOW}Tokens:${RESET}  ${CYAN}?l${RESET} lower  ${CYAN}?u${RESET} upper  ${CYAN}?d${RESET} digit  ${CYAN}?s${RESET} symbol  ${CYAN}?a${RESET} any\n"
    echo ""; hr; echo ""
    printf "  ${YELLOW}Presets:${RESET}\n"
    printf "  ${CYAN}[1]${RESET}  ${GREEN}%-22s${RESET} ${DIM}Word007!  style${RESET}\n" "?u?l?l?l?l?d?d?d?s"
    printf "  ${CYAN}[2]${RESET}  ${GREEN}%-22s${RESET} ${DIM}Pass2024  style${RESET}\n" "?u?l?l?l?l?l?d?d?d?d"
    printf "  ${CYAN}[3]${RESET}  ${GREEN}%-22s${RESET} ${DIM}John1994  style${RESET}\n" "?u?l?l?l?d?d?d?d"
    printf "  ${CYAN}[4]${RESET}  ${GREEN}%-22s${RESET} ${DIM}8 lowercase${RESET}\n" "?l?l?l?l?l?l?l?l"
    printf "  ${CYAN}[5]${RESET}  ${GREEN}%-22s${RESET} ${DIM}8 any character${RESET}\n" "?a?a?a?a?a?a?a?a"
    printf "  ${CYAN}[6]${RESET}  ${GREEN}%-22s${RESET} ${DIM}8 digits${RESET}\n" "?d?d?d?d?d?d?d?d"
    printf "  ${CYAN}[7]${RESET}  ${GREEN}%-22s${RESET} ${DIM}12-char Word1234!${RESET}\n" "?u?l?l?l?l?l?l?d?d?d?s"
    printf "  ${CYAN}[8]${RESET}  ${GREEN}%-22s${RESET} ${DIM}suffix 3-digit+sym (hybrid)${RESET}\n" "?d?d?d?s"
    printf "  ${CYAN}[9]${RESET}  ${GREEN}%-22s${RESET} ${DIM}suffix 4-digit+sym (hybrid)${RESET}\n" "?d?d?d?d?s"
    printf "  ${CYAN}[m]${RESET}  Custom mask\n\n"
    ask "Select"; read -r choice
    case "$choice" in
        1) MASK="?u?l?l?l?l?d?d?d?s" ;;      2) MASK="?u?l?l?l?l?l?d?d?d?d" ;;
        3) MASK="?u?l?l?l?d?d?d?d" ;;        4) MASK="?l?l?l?l?l?l?l?l" ;;
        5) MASK="?a?a?a?a?a?a?a?a" ;;        6) MASK="?d?d?d?d?d?d?d?d" ;;
        7) MASK="?u?l?l?l?l?l?l?d?d?d?s" ;;  8) MASK="?d?d?d?s" ;;
        9) MASK="?d?d?d?d?s" ;;              m) ask "Mask"; read -r MASK ;;
        *) err "Invalid"; sleep 1; return 1 ;;
    esac
    ok "Mask: ${MASK}"; sleep 0.5
}

# ── Command assembly ───────────────────────────────────────────────
common_flags() {
    local f="-w ${WORKLOAD}"
    [[ -n "$OPTIMIZED" ]] && f+=" -O"
    [[ "$TEMP_ABORT" =~ ^[0-9]+$ ]] && f+=" --hwmon-temp-abort=${TEMP_ABORT}"
    [[ "$STATUS_TIMER" =~ ^[0-9]+$ ]] && (( STATUS_TIMER > 0 )) && f+=" --status --status-timer=${STATUS_TIMER}"
    [[ "$POTFILE" == "off" ]] && f+=" --potfile-disable"
    [[ -n "$SESSION" ]] && f+=" --session ${SESSION}"
    [[ -n "$EXTRA_FLAGS" ]] && f+=" ${EXTRA_FLAGS}"
    printf '%s' "$f"
}

build_cmd() {                        # $1 = attack mode (-a)  $2 = mask
    local a="$1" mask="$2"
    CMD="${HASHCAT_BIN} -m ${HASH_MODE} -a ${a}"
    KS_CMD="${HASHCAT_BIN} -m ${HASH_MODE} -a ${a}"
    case "$a" in
        0) CMD+=" \"${HASH_FILE}\" \"${WORDLIST}\""
           KS_CMD+=" \"${WORDLIST}\""
           if [[ -n "$RULES_FILE" ]]; then CMD+=" -r \"${RULES_FILE}\""; KS_CMD+=" -r \"${RULES_FILE}\""; fi ;;
        3) CMD+=" \"${HASH_FILE}\" ${mask}";        KS_CMD+=" ${mask}" ;;
        6) CMD+=" \"${HASH_FILE}\" \"${WORDLIST}\" ${mask}"; KS_CMD+=" \"${WORDLIST}\" ${mask}" ;;
        7) CMD+=" \"${HASH_FILE}\" ${mask} \"${WORDLIST}\""; KS_CMD+=" ${mask} \"${WORDLIST}\"" ;;
    esac
    CMD+=" $(common_flags)"
    KS_CMD+=" --keyspace"
}

show_cmd_preview() {
    echo ""; hr
    printf "  ${YELLOW}${BOLD}Command Preview${RESET}\n"; hr; echo ""
    printf "  ${LGREEN}${BOLD}%s${RESET}\n" "$CMD"
    echo ""; hr
}

estimate_keyspace() {
    echo ""; info "Calculating keyspace…"
    local ks; ks=$(eval "$KS_CMD" 2>/dev/null | tail -1)
    if [[ "$ks" =~ ^[0-9]+$ ]]; then
        printf "  ${LCYAN}[i]${RESET} Keyspace: ${YELLOW}%s${RESET} candidates\n" "$(printf "%'d" "$ks")"
    else
        warn "Could not determine keyspace."
    fi
}

confirm_run() {
    while true; do
        ask "${YELLOW}Run? [Y/n]${RESET}  ${DIM}(e = estimate keyspace)${RESET}"
        read -r yn
        case "$yn" in
            ''|[Yy]) return 0 ;;
            [Nn])    return 1 ;;
            [Ee])    estimate_keyspace ;;
            *)       : ;;
        esac
    done
}

run_hashcat() {
    [[ -z "$HASH_FILE" || ! -f "$HASH_FILE" ]] && { err "Hash file invalid."; pause; return; }
    echo ""; info "Launching hashcat — press 'q' inside hashcat to quit, 's' for status."
    echo ""; hr; echo ""
    eval "$CMD"; local code=$?
    echo ""; hr
    case $code in
        0) ok "Completed — hash(es) cracked or already in potfile." ;;
        1) warn "Exhausted — no crack found in this keyspace." ;;
        2) warn "Aborted by user." ;;
        *) warn "hashcat exited with code ${code}." ;;
    esac
    pause
}

# ── Tools ──────────────────────────────────────────────────────────
convert_capture() {
    banner
    section "Convert Capture → hc22000"
    echo ""
    if ! command -v hcxpcapngtool &>/dev/null; then
        warn "hcxpcapngtool not installed."
        ask "Install hcxtools now? [Y/n]"; read -r yn
        [[ "$yn" =~ ^[Nn]$ ]] && return
        install_pkgs "$(pkg_for hcxpcapngtool)"
        command -v hcxpcapngtool &>/dev/null || { err "Install failed."; pause; return; }
    fi
    ask "Path to .cap / .pcapng"; read -r cap; cap="${cap//\"/}"; cap="${cap/#\~/$HOME}"
    [[ ! -f "$cap" ]] && { err "Not found: $cap"; pause; return; }
    local out="${cap%.*}.hc22000"
    echo ""; info "hcxpcapngtool -o $out $cap"; echo ""
    hcxpcapngtool -o "$out" "$cap"
    if [[ -s "$out" ]]; then
        ok "Wrote $out"
        ask "Set as active hash file? [Y/n]"; read -r yn
        [[ ! "$yn" =~ ^[Nn]$ ]] && { HASH_FILE="$out"; ok "Active hash file set."; }
    else
        err "No valid handshake/PMKID extracted."
    fi
    pause
}

show_cracked() {
    banner
    section "Show Cracked Passwords"
    [[ -z "$HASH_FILE" ]] && { pick_hash_file || { pause; return; }; }
    echo ""
    local c="${HASHCAT_BIN} -m ${HASH_MODE} \"${HASH_FILE}\" --show"
    printf "  ${LGREEN}%s${RESET}\n\n" "$c"; hr; echo ""
    eval "$c" || info "Nothing cracked yet for this hash."
    pause
}

restore_session() {
    banner
    section "Restore Previous Session"
    echo ""
    info "Resumes the last run saved under session: ${YELLOW}${SESSION}${RESET}"
    local c="${HASHCAT_BIN} --session ${SESSION} --restore"
    printf "\n  ${LGREEN}%s${RESET}\n\n" "$c"
    ask "Restore now? [Y/n]"; read -r yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    echo ""; hr; echo ""
    eval "$c"; pause
}

run_benchmark() {
    banner
    section "Benchmark  (-m ${HASH_MODE})"
    echo ""
    info "Measures raw hashes/sec for the current mode on your GPU."
    ask "Run benchmark? [Y/n]"; read -r yn
    [[ "$yn" =~ ^[Nn]$ ]] && return
    echo ""; hr; echo ""
    eval "${HASHCAT_BIN} -b -m ${HASH_MODE} $([[ -n $OPTIMIZED ]] && echo -O) -w ${WORKLOAD}"
    pause
}

# ── Settings ───────────────────────────────────────────────────────
settings_menu() {
    while true; do
        banner
        section "Settings  ${DIM}(saved to ${CONFIG_FILE/#$HOME/\~})${RESET}"
        echo ""
        printf "  ${CYAN}[1]${RESET}  Workload profile   : ${YELLOW}-w %s${RESET}  ${DIM}1 low · 2 med · 3 high · 4 nightmare${RESET}\n" "$WORKLOAD"
        printf "  ${CYAN}[2]${RESET}  Optimized kernels  : ${YELLOW}%s${RESET}  ${DIM}-O · faster, caps password length${RESET}\n" "$([[ -n $OPTIMIZED ]] && echo ON || echo OFF)"
        printf "  ${CYAN}[3]${RESET}  Temp abort (°C)    : ${YELLOW}%s${RESET}  ${DIM}--hwmon-temp-abort, GPU safety${RESET}\n" "${TEMP_ABORT:-off}"
        printf "  ${CYAN}[4]${RESET}  Status timer (s)   : ${YELLOW}%s${RESET}  ${DIM}periodic progress print${RESET}\n" "${STATUS_TIMER:-off}"
        printf "  ${CYAN}[5]${RESET}  Potfile            : ${YELLOW}%s${RESET}  ${DIM}off = always re-crack${RESET}\n" "$POTFILE"
        printf "  ${CYAN}[6]${RESET}  Session name       : ${YELLOW}%s${RESET}  ${DIM}used for --restore${RESET}\n" "$SESSION"
        printf "  ${CYAN}[7]${RESET}  Default hash mode  : ${YELLOW}-m %s${RESET}\n" "$HASH_MODE"
        printf "  ${CYAN}[8]${RESET}  Wordlist directory : ${YELLOW}%s${RESET}\n" "$WORDLIST_DIR"
        printf "  ${CYAN}[9]${RESET}  Rules directory    : ${YELLOW}%s${RESET}\n" "$RULES_DIR"
        printf "  ${CYAN}[x]${RESET}  Extra flags        : ${YELLOW}%s${RESET}\n" "${EXTRA_FLAGS:-none}"
        echo ""; hr
        printf "  ${CYAN}[r]${RESET}  Reset to defaults\n"
        printf "  ${CYAN}[0]${RESET}  Back  ${DIM}(auto-saves)${RESET}\n\n"
        ask "Select"; read -r c
        case "$c" in
            1) ask "Workload [1-4]"; read -r v; [[ "$v" =~ ^[1-4]$ ]] && WORKLOAD=$v || warn "1-4 only" ;;
            2) [[ -n "$OPTIMIZED" ]] && OPTIMIZED="" || OPTIMIZED="-O" ;;
            3) ask "Temp abort °C (blank=off)"; read -r v; TEMP_ABORT="$v" ;;
            4) ask "Status timer secs (0=off)"; read -r v; STATUS_TIMER="$v" ;;
            5) [[ "$POTFILE" == "on" ]] && POTFILE="off" || POTFILE="on" ;;
            6) ask "Session name"; read -r v; [[ -n "$v" ]] && SESSION="$v" ;;
            7) pick_hash_mode ;;
            8) ask "Wordlist dir"; read -r v; v="${v/#\~/$HOME}"; [[ -d "$v" ]] && WORDLIST_DIR="$v" || warn "No such dir" ;;
            9) ask "Rules dir"; read -r v; v="${v/#\~/$HOME}"; [[ -d "$v" ]] && RULES_DIR="$v" || warn "No such dir" ;;
            x) ask "Extra flags (e.g. --force)"; read -r EXTRA_FLAGS ;;
            r) WORDLIST_DIR="${HOME}/wordlists"; RULES_DIR="${HOME}/wordlists/rules"
               HASH_MODE=22000; WORKLOAD=3; OPTIMIZED="-O"; TEMP_ABORT=90
               STATUS_TIMER=10; POTFILE="on"; SESSION="hashcrack"; EXTRA_FLAGS=""
               ok "Reset."; sleep 0.6 ;;
            0) save_config; return ;;
            *) : ;;
        esac
        save_config
    done
}

# ── Attack flows ───────────────────────────────────────────────────
need_hash() { [[ -z "$HASH_FILE" ]] && { pick_hash_file || return 1; }; return 0; }

attack_quick() {
    HASH_MODE=22000
    need_hash || return
    local wl_order=("${WORDLIST_DIR}/kaonashiWPA100M.txt" "${WORDLIST_DIR}/kaonashi14M.txt" "${WORDLIST_DIR}/rockyou.txt" "/usr/share/wordlists/rockyou.txt")
    local rl_order=("${RULES_DIR}/OneRuleToRuleThemStill.rule" "${RULES_DIR}/OneRuleToRuleThemAll.rule" "/usr/share/hashcat/rules/best64.rule")
    WORDLIST=""; for f in "${wl_order[@]}"; do [[ -f "$f" ]] && { WORDLIST="$f"; break; }; done
    RULES_FILE=""; for f in "${rl_order[@]}"; do [[ -f "$f" ]] && { RULES_FILE="$f"; break; }; done
    [[ -z "$WORDLIST" ]] && { err "No wordlist found in $WORDLIST_DIR"; pause; return; }
    build_cmd 0 ""
    banner; section "Quick Strike — auto best wordlist + rules"; echo ""
    info "Wordlist : $(basename "$WORDLIST")  ($(du -sh "$WORDLIST" 2>/dev/null | cut -f1))"
    info "Rules    : $(basename "${RULES_FILE:-none}")"
    show_cmd_preview
    confirm_run && run_hashcat
}

attack_dictionary() {
    need_hash || return
    pick_hash_mode
    pick_wordlist || return
    pick_rules
    build_cmd 0 ""
    banner; section "Dictionary Attack"; show_cmd_preview
    confirm_run && run_hashcat
}

attack_hybrid_append() {
    need_hash || return
    pick_hash_mode
    pick_wordlist || return
    build_mask || return
    build_cmd 6 "$MASK"
    banner; section "Hybrid — Wordlist + Appended Mask"
    info "word → word${MASK//\?/}"
    show_cmd_preview
    confirm_run && run_hashcat
}

attack_hybrid_prepend() {
    need_hash || return
    pick_hash_mode
    pick_wordlist || return
    build_mask || return
    build_cmd 7 "$MASK"
    banner; section "Hybrid — Prepended Mask + Wordlist"
    show_cmd_preview
    confirm_run && run_hashcat
}

attack_mask() {
    need_hash || return
    pick_hash_mode
    build_mask || return
    build_cmd 3 "$MASK"
    banner; section "Mask / Brute Force Attack"; show_cmd_preview
    confirm_run && run_hashcat
}

# ── Main menu ──────────────────────────────────────────────────────
main_menu() {
    while true; do
        banner
        status_bar
        printf "  ${WHITE}${BOLD}Attack Modes${RESET}\n\n"
        printf "  ${CYAN}[1]${RESET}  ${LGREEN}${BOLD}Quick Strike${RESET}      ${DIM}auto best wordlist + rules (WPA2)${RESET}\n"
        printf "  ${CYAN}[2]${RESET}  Dictionary         ${DIM}any wordlist, optional rules${RESET}\n"
        printf "  ${CYAN}[3]${RESET}  Hybrid › Append    ${DIM}wordlist + mask  (word → word007!)${RESET}\n"
        printf "  ${CYAN}[4]${RESET}  Hybrid › Prepend   ${DIM}mask + wordlist  (word → 007!word)${RESET}\n"
        printf "  ${CYAN}[5]${RESET}  Mask / Brute       ${DIM}pattern only, no wordlist${RESET}\n"
        echo ""; hr
        printf "  ${WHITE}${BOLD}Tools${RESET}\n\n"
        printf "  ${CYAN}[6]${RESET}  Convert .cap → hc22000\n"
        printf "  ${CYAN}[7]${RESET}  Show cracked passwords\n"
        printf "  ${CYAN}[8]${RESET}  Restore previous session\n"
        printf "  ${CYAN}[9]${RESET}  Benchmark current mode\n"
        echo ""; hr
        printf "  ${CYAN}[s]${RESET}  Settings        ${CYAN}[d]${RESET}  Dependencies        ${CYAN}[0]${RESET}  ${RED}Exit${RESET}\n\n"
        ask "Select"; read -r choice
        case "$choice" in
            1) attack_quick ;;          2) attack_dictionary ;;
            3) attack_hybrid_append ;;  4) attack_hybrid_prepend ;;
            5) attack_mask ;;           6) convert_capture ;;
            7) show_cracked ;;          8) restore_session ;;
            9) run_benchmark ;;
            s|S) settings_menu ;;       d|D) check_deps; pause ;;
            0) save_config; clear; printf "${LCYAN}Stay legal. Goodbye.${RESET}\n\n"; exit 0 ;;
            *) err "Invalid — use the listed keys."; sleep 0.6 ;;
        esac
    done
}

# ── Boot ───────────────────────────────────────────────────────────
trap 'echo; save_config 2>/dev/null; printf "${LCYAN}\nInterrupted — config saved.${RESET}\n"; exit 130' INT

load_config
ensure_hashcat
main_menu
