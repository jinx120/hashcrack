#!/bin/bash
# ================================================================
#  hashcrack.sh  —  Hashcat TUI Wrapper
#  WPA2 cracking toolkit with fluxion-style interface
# ================================================================

# ── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m';    LRED='\033[1;31m'
GREEN='\033[0;32m';  LGREEN='\033[1;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m';   LCYAN='\033[1;36m'
MAGENTA='\033[0;35m';WHITE='\033[1;37m'
BOLD='\033[1m';      DIM='\033[2m';      RESET='\033[0m'

# ── Config ───────────────────────────────────────────────────────
WORDLIST_DIR="${HOME}/wordlists"
RULES_DIR="${HOME}/wordlists/rules"
HASHCAT_BIN=$(which hashcat 2>/dev/null || echo "hashcat")

# ── State ────────────────────────────────────────────────────────
HASH_FILE=""
WORDLIST=""
RULES_FILE=""
HASH_MODE="22000"
MASK=""
WORKLOAD=3
OPTIMIZED="-O"
EXTRA_FLAGS=""
CMD=""

# ── UI Primitives ─────────────────────────────────────────────────
banner() {
    clear
    echo -e "${LCYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║                                                          ║
  ║    _  _   __   ____  _  _   ___  ____  __   ___  _  _  ║
  ║   | || | / _\ / ___)| || | / __)(  _ \/ _\ / __|| || | ║
  ║   | __ |/    \\___ \| __ || (__  )   /\    ( (__ | /\ | ║
  ║   |_||_|\_/\_/(____/|_||_| \___)(__\_) \/\_/\___||_||_| ║
  ║                                                          ║
  ║            WPA2  ·  Hashcat Cracking Suite               ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${RESET}"

    # GPU detection
    local gpu
    gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    [[ -z "$gpu" ]] && gpu=$(lspci 2>/dev/null | grep -i 'vga\|3d' | head -1 | sed 's/.*: //')
    [[ -z "$gpu" ]] && gpu="Not detected"

    echo -e "  ${DIM}GPU: ${YELLOW}${gpu}${DIM}  |  hashcat: ${YELLOW}$(${HASHCAT_BIN} --version 2>/dev/null || echo 'not found')${RESET}"
    echo ""
}

sep()      { echo -e "  ${DIM}${CYAN}──────────────────────────────────────────────────────${RESET}"; }
sep_thin() { echo -e "  ${DIM}────────────────────────────────────────────────────${RESET}"; }

section() {
    echo ""
    echo -e "  ${YELLOW}┌─ ${WHITE}${BOLD}$1${RESET}"
    sep
}

ok()   { echo -e "  ${LGREEN}[✔]${RESET} $1"; }
err()  { echo -e "  ${LRED}[✘]${RESET} $1"; }
info() { echo -e "  ${LCYAN}[i]${RESET} $1"; }
warn() { echo -e "  ${YELLOW}[!]${RESET} $1"; }
ask()  { echo -en "  ${LCYAN}[>]${RESET} ${1}: "; }

pause() {
    echo ""
    ask "Press Enter to continue"
    read -r
}

# ── Status Bar ───────────────────────────────────────────────────
status_bar() {
    local hf="${HASH_FILE:-${DIM}not set${RESET}}"
    local wl="${WORDLIST:+$(basename "$WORDLIST")}"; wl="${wl:-${DIM}not set${RESET}}"
    local rl="${RULES_FILE:+$(basename "$RULES_FILE")}"; rl="${rl:-${DIM}none${RESET}}"
    local opt="${OPTIMIZED:+${OPTIMIZED} }"; [[ -z "$OPTIMIZED" ]] && opt="${DIM}no -O${RESET} "

    echo -e "  ${DIM}┌─────────────────────────────────────────────────────┐${RESET}"
    printf "  ${DIM}│${RESET}  ${DIM}Hash File :${RESET} ${YELLOW}%-43s${RESET}${DIM}│${RESET}\n" "$(basename "${HASH_FILE:-not set}")"
    printf "  ${DIM}│${RESET}  ${DIM}Wordlist  :${RESET} ${YELLOW}%-43s${RESET}${DIM}│${RESET}\n" "${wl}"
    printf "  ${DIM}│${RESET}  ${DIM}Rules     :${RESET} ${YELLOW}%-43s${RESET}${DIM}│${RESET}\n" "${rl}"
    printf "  ${DIM}│${RESET}  ${DIM}Mode/Work :${RESET} ${YELLOW}-m ${HASH_MODE}  -w ${WORKLOAD}  ${opt}%-30s${RESET}${DIM}│${RESET}\n" ""
    echo -e "  ${DIM}└─────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

# ── Hash File Picker ──────────────────────────────────────────────
pick_hash_file() {
    banner
    section "Select Hash File  (.hc22000 / .hccapx / .cap / .pcapng)"
    echo ""

    local files=()
    local i=1
    local search_dirs=("$(pwd)" "${HOME}" "${HOME}/captures" "${HOME}/Desktop")

    for d in "${search_dirs[@]}"; do
        [[ ! -d "$d" ]] && continue
        while IFS= read -r f; do
            files+=("$f")
            local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
            printf "  ${CYAN}[%2d]${RESET}  %-52s ${DIM}%s${RESET}\n" "$i" "$f" "$size"
            ((i++))
        done < <(find "$d" -maxdepth 2 -type f \
            \( -name "*.hc22000" -o -name "*.hccapx" \
            -o -name "*.cap"     -o -name "*.pcap"   \
            -o -name "*.pcapng" \) 2>/dev/null | sort)
    done

    if [[ ${#files[@]} -eq 0 ]]; then
        warn "No capture files found automatically — use manual entry"
    fi

    echo ""
    echo -e "  ${CYAN}[ m]${RESET}  Enter path manually"
    echo -e "  ${CYAN}[ 0]${RESET}  Back"
    echo ""
    ask "Select"
    read -r choice

    case "$choice" in
        0) return 1 ;;
        m) ask "Full path to hash file"; read -r HASH_FILE ;;
        ''|*[!0-9]*)
            err "Invalid selection"; sleep 1; return 1 ;;
        *)
            if (( choice >= 1 && choice <= ${#files[@]} )); then
                HASH_FILE="${files[$((choice-1))]}"
            else
                err "Out of range"; sleep 1; return 1
            fi ;;
    esac

    if [[ -f "$HASH_FILE" ]]; then
        ok "Hash file set: $HASH_FILE"
        sleep 0.6
    else
        err "File not found: $HASH_FILE"
        HASH_FILE=""
        sleep 1.5
        return 1
    fi
}

# ── Wordlist Picker ───────────────────────────────────────────────
pick_wordlist() {
    banner
    section "Select Wordlist"
    echo ""

    local files=()
    local i=1

    while IFS= read -r f; do
        # Skip non-wordlist txts
        [[ "$f" == *"magnet"* || "$f" == *"tracker"* ]] && continue
        files+=("$f")
        local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
        printf "  ${CYAN}[%2d]${RESET}  %-44s ${DIM}%s${RESET}\n" "$i" "$(basename "$f")" "$size"
        ((i++))
    done < <(find "$WORDLIST_DIR" -maxdepth 1 -type f -name "*.txt" 2>/dev/null | sort -V)

    # Also check /usr/share/wordlists
    if [[ -d /usr/share/wordlists ]]; then
        echo ""
        echo -e "  ${DIM}  /usr/share/wordlists:${RESET}"
        while IFS= read -r f; do
            files+=("$f")
            local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
            printf "  ${CYAN}[%2d]${RESET}  %-44s ${DIM}%s${RESET}\n" "$i" "$f" "$size"
            ((i++))
        done < <(find /usr/share/wordlists -maxdepth 1 -type f -name "*.txt" 2>/dev/null | sort)
    fi

    echo ""
    echo -e "  ${CYAN}[ m]${RESET}  Enter path manually"
    echo -e "  ${CYAN}[ 0]${RESET}  Back"
    echo ""
    ask "Select"
    read -r choice

    case "$choice" in
        0) return 1 ;;
        m) ask "Full path to wordlist"; read -r WORDLIST ;;
        ''|*[!0-9]*)
            err "Invalid selection"; sleep 1; return 1 ;;
        *)
            if (( choice >= 1 && choice <= ${#files[@]} )); then
                WORDLIST="${files[$((choice-1))]}"
            else
                err "Out of range"; sleep 1; return 1
            fi ;;
    esac

    if [[ -f "$WORDLIST" ]]; then
        ok "Wordlist set: $(basename "$WORDLIST")"
        sleep 0.6
    else
        err "File not found: $WORDLIST"
        WORDLIST=""
        sleep 1.5
        return 1
    fi
}

# ── Rules Picker ──────────────────────────────────────────────────
pick_rules() {
    banner
    section "Select Rules File  (optional)"
    echo ""

    local files=()
    local i=1

    while IFS= read -r f; do
        files+=("$f")
        local lines; lines=$(wc -l < "$f" 2>/dev/null)
        printf "  ${CYAN}[%2d]${RESET}  %-44s ${DIM}%s rules${RESET}\n" "$i" "$(basename "$f")" "$lines"
        ((i++))
    done < <(find "$RULES_DIR" "$WORDLIST_DIR" /usr/share/hashcat/rules \
        -maxdepth 2 -type f -name "*.rule" 2>/dev/null | sort | uniq)

    echo ""
    echo -e "  ${CYAN}[ m]${RESET}  Enter path manually"
    echo -e "  ${CYAN}[ n]${RESET}  ${DIM}No rules — straight wordlist${RESET}"
    echo -e "  ${CYAN}[ 0]${RESET}  Back"
    echo ""
    ask "Select"
    read -r choice

    case "$choice" in
        0) return 1 ;;
        n) RULES_FILE=""; info "No rules — straight attack"; sleep 0.6; return 0 ;;
        m) ask "Full path to rules file"; read -r RULES_FILE ;;
        ''|*[!0-9]*)
            err "Invalid selection"; sleep 1; return 1 ;;
        *)
            if (( choice >= 1 && choice <= ${#files[@]} )); then
                RULES_FILE="${files[$((choice-1))]}"
            else
                err "Out of range"; sleep 1; return 1
            fi ;;
    esac

    if [[ -f "$RULES_FILE" ]]; then
        ok "Rules set: $(basename "$RULES_FILE")"
        sleep 0.6
    else
        err "File not found: $RULES_FILE"
        RULES_FILE=""
        sleep 1.5
        return 1
    fi
}

# ── Hash Mode Picker ──────────────────────────────────────────────
pick_hash_mode() {
    banner
    section "Select Hash Mode"
    echo ""
    echo -e "  ${CYAN}[1]${RESET}  ${GREEN}22000${RESET}  WPA-PBKDF2-PMKID+EAPOL   ${DIM}← WPA2 recommended${RESET}"
    echo -e "  ${CYAN}[2]${RESET}  ${GREEN}2500${RESET}   WPA-EAPOL-PBKDF2          ${DIM}legacy .hccapx${RESET}"
    echo -e "  ${CYAN}[3]${RESET}  ${GREEN}2501${RESET}   WPA-PMKID-PMK             ${DIM}PMKID only${RESET}"
    echo -e "  ${CYAN}[4]${RESET}  ${GREEN}0${RESET}      MD5"
    echo -e "  ${CYAN}[5]${RESET}  ${GREEN}100${RESET}    SHA1"
    echo -e "  ${CYAN}[6]${RESET}  ${GREEN}1000${RESET}   NTLM"
    echo -e "  ${CYAN}[7]${RESET}  ${GREEN}1800${RESET}   sha512crypt  ${DIM}Linux /etc/shadow${RESET}"
    echo -e "  ${CYAN}[8]${RESET}  ${GREEN}3200${RESET}   bcrypt"
    echo -e "  ${CYAN}[m]${RESET}  Manual — enter any mode number"
    echo ""
    ask "Select [Enter = keep current: ${YELLOW}${HASH_MODE}${RESET}]"
    read -r choice

    case "$choice" in
        1|"") HASH_MODE=22000 ;;
        2)    HASH_MODE=2500  ;;
        3)    HASH_MODE=2501  ;;
        4)    HASH_MODE=0     ;;
        5)    HASH_MODE=100   ;;
        6)    HASH_MODE=1000  ;;
        7)    HASH_MODE=1800  ;;
        8)    HASH_MODE=3200  ;;
        m)    ask "Mode number"; read -r HASH_MODE ;;
        *)    warn "Keeping: -m $HASH_MODE" ;;
    esac

    ok "Hash mode: -m $HASH_MODE"
    sleep 0.6
}

# ── Mask Builder ──────────────────────────────────────────────────
build_mask() {
    banner
    section "Mask Builder"
    echo ""
    echo -e "  ${YELLOW}Charset tokens:${RESET}"
    echo -e "  ${CYAN}?l${RESET} lowercase    ${CYAN}?u${RESET} uppercase   ${CYAN}?d${RESET} digit"
    echo -e "  ${CYAN}?s${RESET} symbol       ${CYAN}?a${RESET} all printable"
    echo ""
    sep_thin
    echo ""
    echo -e "  ${YELLOW}Presets:${RESET}"
    echo -e "  ${CYAN}[1]${RESET}  ${GREEN}?u?l?l?l?l?d?d?d?s${RESET}       ${DIM}Word007!  style${RESET}"
    echo -e "  ${CYAN}[2]${RESET}  ${GREEN}?u?l?l?l?l?l?d?d?d?d${RESET}     ${DIM}Pass2024  style${RESET}"
    echo -e "  ${CYAN}[3]${RESET}  ${GREEN}?u?l?l?l?d?d?d?d${RESET}          ${DIM}John1994  style${RESET}"
    echo -e "  ${CYAN}[4]${RESET}  ${GREEN}?l?l?l?l?l?l?l?l${RESET}          ${DIM}8 lowercase${RESET}"
    echo -e "  ${CYAN}[5]${RESET}  ${GREEN}?a?a?a?a?a?a?a?a${RESET}          ${DIM}8 any character${RESET}"
    echo -e "  ${CYAN}[6]${RESET}  ${GREEN}?d?d?d?d?d?d?d?d${RESET}          ${DIM}8 digits only${RESET}"
    echo -e "  ${CYAN}[7]${RESET}  ${GREEN}?u?l?l?l?l?l?l?d?d?d?s${RESET}   ${DIM}Word1234! 12-char${RESET}"
    echo -e "  ${CYAN}[8]${RESET}  ${GREEN}?d?d?d?s${RESET}                  ${DIM}Suffix only (for hybrid)${RESET}"
    echo -e "  ${CYAN}[9]${RESET}  ${GREEN}?d?d?d?d?s${RESET}                ${DIM}Suffix 4-digit + symbol${RESET}"
    echo -e "  ${CYAN}[m]${RESET}  Enter custom mask"
    echo ""
    ask "Select"
    read -r choice

    case "$choice" in
        1) MASK="?u?l?l?l?l?d?d?d?s" ;;
        2) MASK="?u?l?l?l?l?l?d?d?d?d" ;;
        3) MASK="?u?l?l?l?d?d?d?d" ;;
        4) MASK="?l?l?l?l?l?l?l?l" ;;
        5) MASK="?a?a?a?a?a?a?a?a" ;;
        6) MASK="?d?d?d?d?d?d?d?d" ;;
        7) MASK="?u?l?l?l?l?l?l?d?d?d?s" ;;
        8) MASK="?d?d?d?s" ;;
        9) MASK="?d?d?d?d?s" ;;
        m) ask "Enter mask"; read -r MASK ;;
        *) err "Invalid"; sleep 1; return 1 ;;
    esac

    ok "Mask: ${MASK}"
    sleep 0.6
}

# ── Command Builder ───────────────────────────────────────────────
build_cmd() {
    local mode="$1"    # hashcat -a mode
    local mask="$2"

    CMD="${HASHCAT_BIN} -m ${HASH_MODE} -a ${mode}"

    case "$mode" in
        0)
            CMD+=" \"${HASH_FILE}\" \"${WORDLIST}\""
            [[ -n "$RULES_FILE" ]] && CMD+=" -r \"${RULES_FILE}\""
            ;;
        3)
            CMD+=" \"${HASH_FILE}\" ${mask}"
            ;;
        6)
            CMD+=" \"${HASH_FILE}\" \"${WORDLIST}\" ${mask}"
            ;;
        7)
            CMD+=" \"${HASH_FILE}\" ${mask} \"${WORDLIST}\""
            ;;
    esac

    CMD+=" -w ${WORKLOAD}"
    [[ -n "$OPTIMIZED" ]] && CMD+=" ${OPTIMIZED}"
    [[ -n "$EXTRA_FLAGS" ]] && CMD+=" ${EXTRA_FLAGS}"
}

show_cmd_preview() {
    echo ""
    sep
    echo -e "  ${YELLOW}${BOLD} Command Preview${RESET}"
    sep
    echo ""
    echo -e "  ${LGREEN}${BOLD}${CMD}${RESET}"
    echo ""
    sep
    echo ""
}

confirm_run() {
    ask "${YELLOW}Run this command? [Y/n]${RESET}"
    read -r yn
    [[ "$yn" =~ ^[Nn]$ ]] && return 1
    return 0
}

run_hashcat() {
    echo ""
    info "Launching hashcat..."
    echo ""
    sep
    echo ""
    eval "${CMD}"
    local code=$?
    echo ""
    sep
    if [[ $code -eq 0 ]]; then
        ok "Hashcat completed (exit 0)"
    else
        warn "Hashcat exited with code ${code}"
        [[ $code -eq 1 ]] && info "Exit 1 = exhausted / no crack found"
    fi
    pause
}

# ── Convert Capture ───────────────────────────────────────────────
convert_capture() {
    banner
    section "Convert Capture File → hc22000"
    echo ""
    info "Uses hcxpcapngtool from hcxtools"
    echo ""

    if ! which hcxpcapngtool &>/dev/null; then
        warn "hcxpcapngtool not found"
        ask "Install hcxtools now? [y/N]"
        read -r yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            sudo apt-get install -y hcxtools 2>&1 | grep -E 'install|error'
        else
            return
        fi
    fi

    ask "Path to .cap / .pcapng file"
    read -r cap_file
    cap_file="${cap_file//\"/}"

    if [[ ! -f "$cap_file" ]]; then
        err "File not found: $cap_file"
        pause
        return
    fi

    local out="${cap_file%.*}.hc22000"
    echo ""
    info "Running: hcxpcapngtool -o $out $cap_file"
    echo ""
    hcxpcapngtool -o "$out" "$cap_file"

    if [[ -f "$out" ]]; then
        ok "Output: $out"
        ask "Set as active hash file? [Y/n]"
        read -r yn
        if [[ ! "$yn" =~ ^[Nn]$ ]]; then
            HASH_FILE="$out"
            ok "Hash file set to: $out"
        fi
    else
        err "Conversion failed — check file is a valid WPA capture"
    fi
    pause
}

# ── Show Cracked ──────────────────────────────────────────────────
show_cracked() {
    banner
    section "Show Cracked Passwords"
    echo ""

    if [[ -z "$HASH_FILE" ]]; then
        pick_hash_file || return
    fi

    local cmd="${HASHCAT_BIN} -m ${HASH_MODE} \"${HASH_FILE}\" --show"
    echo -e "  ${LGREEN}${BOLD}${cmd}${RESET}"
    echo ""
    sep
    echo ""
    eval "$cmd"
    pause
}

# ── Settings ──────────────────────────────────────────────────────
settings_menu() {
    while true; do
        banner
        section "Settings"
        echo ""
        echo -e "  ${DIM}Current:${RESET}"
        echo -e "  ${CYAN}[1]${RESET}  Workload profile  : ${YELLOW}-w ${WORKLOAD}${RESET}  ${DIM}(1=low 2=med 3=high 4=nightmare)${RESET}"
        echo -e "  ${CYAN}[2]${RESET}  Optimized kernels : ${YELLOW}$([[ -n "$OPTIMIZED" ]] && echo "ON  (-O)" || echo "OFF")${RESET}"
        echo -e "  ${CYAN}[3]${RESET}  Extra flags       : ${YELLOW}${EXTRA_FLAGS:-none}${RESET}"
        echo -e "  ${CYAN}[4]${RESET}  Hash mode         : ${YELLOW}-m ${HASH_MODE}${RESET}"
        echo ""
        sep
        echo -e "  ${CYAN}[0]${RESET}  Back"
        echo ""
        ask "Select"
        read -r choice

        case "$choice" in
            1) ask "Workload [1-4]"; read -r WORKLOAD ;;
            2) [[ -n "$OPTIMIZED" ]] && OPTIMIZED="" || OPTIMIZED="-O"
               ok "Optimized kernels: $([[ -n "$OPTIMIZED" ]] && echo ON || echo OFF)"
               sleep 1 ;;
            3) ask "Extra flags (e.g. --force --potfile-disable)"; read -r EXTRA_FLAGS ;;
            4) pick_hash_mode ;;
            0) return ;;
        esac
    done
}

# ── Attack Flows ──────────────────────────────────────────────────

# 1 — Quick Strike
attack_quick() {
    HASH_MODE=22000
    [[ -z "$HASH_FILE" ]] && { pick_hash_file || return; }

    # Best available wordlist
    local wl_order=(
        "${WORDLIST_DIR}/kaonashiWPA100M.txt"
        "${WORDLIST_DIR}/kaonashi14M.txt"
        "${WORDLIST_DIR}/rockyou.txt"
    )
    WORDLIST=""
    for f in "${wl_order[@]}"; do
        [[ -f "$f" ]] && { WORDLIST="$f"; break; }
    done

    # Best available rule
    local rl_order=(
        "${RULES_DIR}/OneRuleToRuleThemStill.rule"
        "${RULES_DIR}/OneRuleToRuleThemAll.rule"
        "/usr/share/hashcat/rules/best64.rule"
    )
    RULES_FILE=""
    for f in "${rl_order[@]}"; do
        [[ -f "$f" ]] && { RULES_FILE="$f"; break; }
    done

    if [[ -z "$WORDLIST" ]]; then
        err "No wordlist found in ${WORDLIST_DIR}"
        pause; return
    fi

    build_cmd 0 ""
    banner
    section "Quick Strike  —  Auto Best Wordlist + Rules"
    echo ""
    info "Wordlist : $(basename "$WORDLIST")  ($(du -sh "$WORDLIST" | cut -f1))"
    info "Rules    : $(basename "${RULES_FILE:-none}")"
    show_cmd_preview
    confirm_run && run_hashcat
}

# 2 — Dictionary
attack_dictionary() {
    [[ -z "$HASH_FILE" ]] && { pick_hash_file || return; }
    pick_hash_mode
    pick_wordlist || return
    pick_rules
    build_cmd 0 ""
    banner
    section "Dictionary Attack"
    show_cmd_preview
    confirm_run && run_hashcat
}

# 3 — Hybrid Append  (wordlist + ?mask appended)
attack_hybrid_append() {
    [[ -z "$HASH_FILE" ]] && { pick_hash_file || return; }
    pick_hash_mode
    pick_wordlist || return
    build_mask || return
    build_cmd 6 "$MASK"
    banner
    section "Hybrid Attack  —  Wordlist + Appended Mask"
    info "Each word from the list gets \$MASK appended"
    info "e.g. password → password007!"
    show_cmd_preview
    confirm_run && run_hashcat
}

# 4 — Hybrid Prepend  (mask + wordlist)
attack_hybrid_prepend() {
    [[ -z "$HASH_FILE" ]] && { pick_hash_file || return; }
    pick_hash_mode
    pick_wordlist || return
    build_mask || return
    build_cmd 7 "$MASK"
    banner
    section "Hybrid Attack  —  Prepended Mask + Wordlist"
    info "Each word from the list gets MASK prepended"
    info "e.g. password → 007!password"
    show_cmd_preview
    confirm_run && run_hashcat
}

# 5 — Mask / Brute Force
attack_mask() {
    [[ -z "$HASH_FILE" ]] && { pick_hash_file || return; }
    pick_hash_mode
    build_mask || return
    build_cmd 3 "$MASK"
    banner
    section "Mask / Brute Force Attack"
    show_cmd_preview
    confirm_run && run_hashcat
}

# ── Main Menu ─────────────────────────────────────────────────────
main_menu() {
    while true; do
        banner
        status_bar
        sep
        echo ""
        echo -e "  ${WHITE}${BOLD}  Attack Modes${RESET}"
        echo ""
        echo -e "  ${CYAN}[1]${RESET}  ${LGREEN}${BOLD}Quick Strike${RESET}          ${DIM}Auto-selects best wordlist + rules  (WPA2)${RESET}"
        echo -e "  ${CYAN}[2]${RESET}  Dictionary Attack      ${DIM}Any wordlist, optional rules${RESET}"
        echo -e "  ${CYAN}[3]${RESET}  Hybrid › Append        ${DIM}Wordlist + mask suffix  (word → word007!)${RESET}"
        echo -e "  ${CYAN}[4]${RESET}  Hybrid › Prepend       ${DIM}Mask prefix + wordlist  (word → 007!word)${RESET}"
        echo -e "  ${CYAN}[5]${RESET}  Mask / Brute Force     ${DIM}Pattern only, no wordlist${RESET}"
        echo ""
        sep
        echo ""
        echo -e "  ${WHITE}${BOLD}  Tools${RESET}"
        echo ""
        echo -e "  ${CYAN}[6]${RESET}  Convert .cap → hc22000 ${DIM}(hcxpcapngtool)${RESET}"
        echo -e "  ${CYAN}[7]${RESET}  Show Cracked Passwords"
        echo -e "  ${CYAN}[8]${RESET}  Settings"
        echo ""
        sep
        echo ""
        echo -e "  ${CYAN}[0]${RESET}  ${RED}Exit${RESET}"
        echo ""
        ask "Select"
        read -r choice

        case "$choice" in
            1) attack_quick ;;
            2) attack_dictionary ;;
            3) attack_hybrid_append ;;
            4) attack_hybrid_prepend ;;
            5) attack_mask ;;
            6) convert_capture ;;
            7) show_cracked ;;
            8) settings_menu ;;
            0) clear; echo -e "${LCYAN}Goodbye.${RESET}"; echo ""; exit 0 ;;
            *) err "Invalid option — use 0-8"; sleep 0.6 ;;
        esac
    done
}

# ── Dependency Check ──────────────────────────────────────────────
if ! which hashcat &>/dev/null; then
    echo -e "${LRED}[✘] hashcat not found in PATH${RESET}"
    echo -e "    Install: ${YELLOW}sudo apt-get install hashcat${RESET}"
    exit 1
fi

main_menu
