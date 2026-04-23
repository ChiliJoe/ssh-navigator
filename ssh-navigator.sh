#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"

# ╔═════════════════════════════════════════════════════════════════════════╗
# ║  EMBEDDED CONFIGURATION — edit here or press 'e' inside the TUI       ║
# ╚═════════════════════════════════════════════════════════════════════════╝
# The launch command template. Available placeholders:
#   $H  = Host alias       $HN = HostName/IP      $U  = User
#   $P  = Port             $K  = IdentityFile      $PJ = ProxyJump
# Examples:
#   ssh $H                     (default — connect by alias)
#   ssh-vault $HN              (custom tool using IP)
#   mosh $U@$HN               (mosh instead of ssh)
#   ssh -i $K $U@$HN -p $P    (explicit identity and port)
#::LAUNCH_CMD_BEGIN
EMBEDDED_CMD='ssh $H'
#::LAUNCH_CMD_END

# Resolution order: --cmd flag > SSH_NAV_CMD env var > embedded value above
LAUNCH_CMD="${SSH_NAV_CMD:-$EMBEDDED_CMD}"
SCRIPT_PATH=""

# --- Parsed host data (parallel arrays) ---
declare -a HOST_NAMES=()
declare -a HOST_IPS=()
declare -a HOST_USERS=()
declare -a HOST_PORTS=()
declare -a HOST_KEYS=()
declare -a HOST_PROXIES=()
declare -a HOST_SECTIONS=()
declare -a HOST_IDENTONLY=()
declare -a HOST_ALIASES=()
declare -a HOST_SEARCH_STR=()
HOST_COUNT=0

# --- UI state ---
CURSOR_POS=0
SCROLL_OFFSET=0
SEARCH_TERM=""
SEARCH_MODE=0
CURRENT_VIEW="list"
NEEDS_REDRAW=1
TERM_ROWS=0
TERM_COLS=0
LIST_ROWS=0
HEADER_ROWS=4
FOOTER_ROWS=2

# --- Filtered view ---
declare -a FILTERED_INDICES=()
FILTERED_COUNT=0

# --- Terminal state tracking ---
TERMINAL_INITIALIZED=0
OLD_STTY=""

# --- Performance: ANSI constants (eliminates tput forks in hot paths) ---
ESC=$'\e'
CSI="${ESC}["
SEP_LINE=""         # Pre-computed separator line of dashes
KEY_RESULT=""       # read_key writes here (avoids subshell on every keypress)
RENDER_BUF=""       # Frame buffer — single write per render cycle
SEC_COL_W=0         # Cached section column width (recomputed on resize only)
SEARCH_TERM_LC=""   # Pre-lowercased search term (avoids per-host conversion)
WINCH_FIRED=0       # Set by WINCH trap — skip resize poll when no signal

# ============================================================================
# Argument parsing
# ============================================================================

show_help() {
    cat <<'HELPEOF'
SSH Navigator v1.0.0 - Commander-like TUI for SSH config hosts

Usage: ssh-navigator.sh [OPTIONS]

Options:
  -h, --help          Show this help message
  -v, --version       Show version
  -c, --config PATH   Path to SSH config file (default: ~/.ssh/config)
      --cmd TEMPLATE  Launch command template (default: "ssh $H")

Launch command placeholders:
  $H   Host alias        (e.g., idm-db-dev)
  $HN  HostName/IP       (e.g., 203.0.113.42)
  $U   User              (e.g., admin)
  $P   Port              (e.g., 22)
  $K   IdentityFile      (e.g., ~/.sshkeys/mykey)
  $PJ  ProxyJump         (e.g., bastion-host)

Environment variables:
  SSH_CONFIG     Path to SSH config (same as --config)
  SSH_NAV_CMD    Launch command template (same as --cmd)

Keybindings:
  Up/Down        Navigate host list
  PgUp/PgDn      Scroll by page
  Home/End        Jump to first/last host
  /              Enter search mode
  Enter          Connect to selected host
  v              View host details
  a              Add new host
  e              Edit launch command
  q              Quit (or go back from sub-views)

Examples:
  ssh-navigator.sh
  ssh-navigator.sh --cmd "ssh-vault \$HN"
  SSH_NAV_CMD="mosh \$U@\$HN" ssh-navigator.sh
HELPEOF
}

CMD_FROM_FLAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)    show_help; exit 0 ;;
        -v|--version) echo "ssh-navigator $VERSION"; exit 0 ;;
        -c|--config)  SSH_CONFIG="$2"; shift 2 ;;
        --cmd)        CMD_FROM_FLAG="$2"; LAUNCH_CMD="$2"; shift 2 ;;
        *)            echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Resolve the absolute path to this script so we can write back to it
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "$SSH_CONFIG" ]]; then
    echo "Error: SSH config file not found: $SSH_CONFIG"
    exit 1
fi

# ============================================================================
# SSH Config Parsing
# ============================================================================

parse_ssh_config() {
    HOST_COUNT=0
    HOST_NAMES=()
    HOST_IPS=()
    HOST_USERS=()
    HOST_PORTS=()
    HOST_KEYS=()
    HOST_PROXIES=()
    HOST_SECTIONS=()
    HOST_IDENTONLY=()
    HOST_ALIASES=()
    HOST_SEARCH_STR=()

    while IFS=$'\x1e' read -r section host hostname user port keyfile proxy identonly aliases; do
        HOST_NAMES[$HOST_COUNT]="$host"
        HOST_IPS[$HOST_COUNT]="$hostname"
        HOST_USERS[$HOST_COUNT]="$user"
        HOST_PORTS[$HOST_COUNT]="${port:-22}"
        HOST_KEYS[$HOST_COUNT]="$keyfile"
        HOST_PROXIES[$HOST_COUNT]="$proxy"
        HOST_SECTIONS[$HOST_COUNT]="$section"
        HOST_IDENTONLY[$HOST_COUNT]="$identonly"
        HOST_ALIASES[$HOST_COUNT]="$aliases"
        ((++HOST_COUNT))
    done < <(awk '
        /^###/ {
            section = $0
            gsub(/^###[[:space:]]*/, "", section)
            gsub(/[[:space:]]*###[[:space:]]*$/, "", section)
            next
        }
        /^[Hh]ost[[:space:]]+/ && !/^[Hh]ost[[:space:]]+\*/ {
            if (alias_count > 0) {
                for (a = 1; a <= alias_count; a++) {
                    printf "%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\n", sect, aliases[a], hostname, user, port, keyfile, proxy, identonly, all_aliases
                }
            }
            # Collect all aliases from the Host line
            alias_count = 0
            all_aliases = ""
            for (i = 2; i <= NF; i++) {
                alias_count++
                aliases[alias_count] = $i
                all_aliases = (all_aliases == "" ? $i : all_aliases " " $i)
            }
            sect = section
            hostname = ""; user = ""; port = ""; keyfile = ""; proxy = ""; identonly = ""
            next
        }
        alias_count > 0 && /^[[:space:]]+[^#]/ {
            line = $0
            gsub(/^[[:space:]]+/, "", line)
            gsub(/[[:space:]]+$/, "", line)

            key = tolower(line)
            sub(/[[:space:]].*/, "", key)

            val = line
            sub(/^[^[:space:]]+[[:space:]]+/, "", val)

            if (key == "hostname")       hostname = val
            else if (key == "user")      user = val
            else if (key == "port")      port = val
            else if (key == "identityfile") keyfile = val
            else if (key == "proxyjump") proxy = val
            else if (key == "identitiesonly") identonly = val
        }
        END {
            if (alias_count > 0) {
                for (a = 1; a <= alias_count; a++) {
                    printf "%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\n", sect, aliases[a], hostname, user, port, keyfile, proxy, identonly, all_aliases
                }
            }
        }
    ' "$SSH_CONFIG")
}

build_search_index() {
    local i
    for ((i = 0; i < HOST_COUNT; i++)); do
        local str="${HOST_NAMES[$i]} ${HOST_ALIASES[$i]} ${HOST_IPS[$i]} ${HOST_USERS[$i]} ${HOST_SECTIONS[$i]}"
        HOST_SEARCH_STR[$i]="${str,,}"
    done
}

# ============================================================================
# Terminal Management (OPTIMIZED: ANSI escapes, single stty fork)
# ============================================================================

detect_size() {
    # 1 fork (stty) replaces 2 forks (tput lines + tput cols)
    local size
    size=$(stty size 2>/dev/null) || size="24 80"
    TERM_ROWS="${size%% *}"
    TERM_COLS="${size#* }"
    LIST_ROWS=$((TERM_ROWS - HEADER_ROWS - FOOTER_ROWS))
    if ((LIST_ROWS < 1)); then LIST_ROWS=1; fi
    # Pre-compute separator line (eliminates tr pipe per render)
    printf -v SEP_LINE '%*s' "$TERM_COLS" ''
    SEP_LINE="${SEP_LINE// /-}"
    # Cache section column width (eliminates arithmetic in render loop)
    SEC_COL_W=$((TERM_COLS - 25 - 22 - 14 - 6))
    if ((SEC_COL_W < 8)); then SEC_COL_W=8; fi
}

init_terminal() {
    OLD_STTY=$(stty -g 2>/dev/null || true)
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    # ANSI: alt screen + hide cursor + disable wrap (replaces 2 tput forks)
    printf '%s' "${CSI}?1049h${CSI}?25l${CSI}?7l"
    TERMINAL_INITIALIZED=1
    detect_size
}

cleanup() {
    if ((TERMINAL_INITIALIZED)); then
        # ANSI: enable wrap + show cursor + exit alt screen + reset attrs
        printf '%s' "${CSI}?7h${CSI}?25h${CSI}?1049l${CSI}0m"
        if [[ -n "$OLD_STTY" ]]; then
            stty "$OLD_STTY" 2>/dev/null || true
        else
            stty sane 2>/dev/null || true
        fi
        TERMINAL_INITIALIZED=0
    fi
}

trap cleanup EXIT
trap 'WINCH_FIRED=1; detect_size; NEEDS_REDRAW=1' WINCH 2>/dev/null || true

# ============================================================================
# Color/Style Setup (OPTIMIZED: direct ANSI 256-color — zero tput forks)
# ============================================================================

setup_colors() {
    C_RESET="${CSI}0m"
    C_BOLD="${CSI}1m"
    # Header/footer: bold white on dark blue (fg=15 bg=24)
    C_HEADER="${CSI}1;38;5;15;48;5;24m"
    # Selected row: bold white on medium blue (fg=15 bg=31)
    C_SELECTED="${CSI}1;38;5;15;48;5;31m"
    # Normal row (fg=252)
    C_NORMAL="${CSI}38;5;252m"
    # Section text dim (fg=245)
    C_DIM="${CSI}38;5;245m"
    # Search text bold orange (fg=214)
    C_SEARCH="${CSI}1;38;5;214m"
    # Success bold green (fg=46)
    C_SUCCESS="${CSI}1;38;5;46m"
    # Error bold red (fg=196)
    C_ERROR="${CSI}1;38;5;196m"
    # Column header bold light blue (fg=75)
    C_COLHDR="${CSI}1;38;5;75m"
    # Detail label bold light blue (fg=75)
    C_LABEL="${CSI}1;38;5;75m"
    # Detail value (fg=255)
    C_VALUE="${CSI}38;5;255m"
    # Box drawing (fg=67)
    C_BOX="${CSI}38;5;67m"
}

# ============================================================================
# Keyboard Input (OPTIMIZED: writes to KEY_RESULT global — no subshell)
# ============================================================================

read_key() {
    local key rc=0
    IFS= read -rsn1 -t 0.5 key 2>/dev/null || rc=$?

    if [[ -z "$key" ]]; then
        # Distinguish Enter (rc=0, newline consumed as delimiter) from timeout (rc>128)
        if ((rc > 0)); then
            KEY_RESULT="TIMEOUT"
        else
            KEY_RESULT="ENTER"
        fi
        return
    fi

    if [[ "$key" == $'\x1b' ]]; then
        local seq=""
        IFS= read -rsn1 -t 0.05 seq 2>/dev/null || true
        if [[ "$seq" == "[" ]]; then
            IFS= read -rsn1 -t 0.05 seq 2>/dev/null || true
            case "$seq" in
                A) KEY_RESULT="UP"; return ;;
                B) KEY_RESULT="DOWN"; return ;;
                C) KEY_RESULT="RIGHT"; return ;;
                D) KEY_RESULT="LEFT"; return ;;
                H) KEY_RESULT="HOME"; return ;;
                F) KEY_RESULT="END"; return ;;
                5) IFS= read -rsn1 -t 0.05 _ 2>/dev/null || true; KEY_RESULT="PGUP"; return ;;
                6) IFS= read -rsn1 -t 0.05 _ 2>/dev/null || true; KEY_RESULT="PGDN"; return ;;
                *) KEY_RESULT="UNKNOWN"; return ;;
            esac
        elif [[ "$seq" == "O" ]]; then
            IFS= read -rsn1 -t 0.05 seq 2>/dev/null || true
            case "$seq" in
                H) KEY_RESULT="HOME"; return ;;
                F) KEY_RESULT="END"; return ;;
                *) KEY_RESULT="UNKNOWN"; return ;;
            esac
        fi
        KEY_RESULT="ESC"
        return
    fi

    case "$key" in
        $'\n'|$'\r'|"") KEY_RESULT="ENTER" ;;
        $'\x7f'|$'\x08') KEY_RESULT="BACKSPACE" ;;
        $'\t') KEY_RESULT="TAB" ;;
        *) KEY_RESULT="CHAR:$key" ;;
    esac
}

# ============================================================================
# Filtering
# ============================================================================

apply_filter() {
    FILTERED_INDICES=()
    FILTERED_COUNT=0

    if [[ -z "$SEARCH_TERM" ]]; then
        for ((i = 0; i < HOST_COUNT; i++)); do
            FILTERED_INDICES[$FILTERED_COUNT]=$i
            ((++FILTERED_COUNT))
        done
    else
        for ((i = 0; i < HOST_COUNT; i++)); do
            if [[ "${HOST_SEARCH_STR[$i]}" == *"$SEARCH_TERM_LC"* ]]; then
                FILTERED_INDICES[$FILTERED_COUNT]=$i
                ((++FILTERED_COUNT))
            fi
        done
    fi

    CURSOR_POS=0
    SCROLL_OFFSET=0
}

# ============================================================================
# Navigation (OPTIMIZED: incremental rendering on cursor move)
# ============================================================================

ensure_cursor_visible() {
    if ((CURSOR_POS < SCROLL_OFFSET)); then
        SCROLL_OFFSET=$CURSOR_POS
    elif ((CURSOR_POS >= SCROLL_OFFSET + LIST_ROWS)); then
        SCROLL_OFFSET=$((CURSOR_POS - LIST_ROWS + 1))
    fi
}

move_cursor() {
    local dir=$1
    local old_pos=$CURSOR_POS
    local old_scroll=$SCROLL_OFFSET
    CURSOR_POS=$((CURSOR_POS + dir))
    if ((CURSOR_POS < 0)); then
        CURSOR_POS=0
    elif ((CURSOR_POS >= FILTERED_COUNT)); then
        CURSOR_POS=$((FILTERED_COUNT > 0 ? FILTERED_COUNT - 1 : 0))
    fi
    ensure_cursor_visible
    if ((SCROLL_OFFSET == old_scroll && CURSOR_POS != old_pos)); then
        # No scroll change — fast incremental repaint (2 rows vs full redraw)
        render_cursor_move "$old_pos" "$CURSOR_POS"
    else
        NEEDS_REDRAW=1
    fi
}

page_up() {
    CURSOR_POS=$((CURSOR_POS - LIST_ROWS))
    if ((CURSOR_POS < 0)); then CURSOR_POS=0; fi
    ensure_cursor_visible
    NEEDS_REDRAW=1
}

page_down() {
    CURSOR_POS=$((CURSOR_POS + LIST_ROWS))
    if ((CURSOR_POS >= FILTERED_COUNT)); then
        CURSOR_POS=$((FILTERED_COUNT > 0 ? FILTERED_COUNT - 1 : 0))
    fi
    ensure_cursor_visible
    NEEDS_REDRAW=1
}

go_home() {
    CURSOR_POS=0
    SCROLL_OFFSET=0
    NEEDS_REDRAW=1
}

go_end() {
    CURSOR_POS=$((FILTERED_COUNT > 0 ? FILTERED_COUNT - 1 : 0))
    ensure_cursor_visible
    NEEDS_REDRAW=1
}

# ============================================================================
# Launch Command
# ============================================================================

build_launch_cmd() {
    local idx=$1
    local cmd="$LAUNCH_CMD"
    local h="${HOST_NAMES[$idx]}"
    local hn="${HOST_IPS[$idx]}"
    local u="${HOST_USERS[$idx]}"
    local p="${HOST_PORTS[$idx]}"
    local k="${HOST_KEYS[$idx]}"
    local pj="${HOST_PROXIES[$idx]}"

    cmd="${cmd//\$HN/$hn}"
    cmd="${cmd//\$H/$h}"
    cmd="${cmd//\$U/$u}"
    cmd="${cmd//\$P/$p}"
    cmd="${cmd//\$K/$k}"
    cmd="${cmd//\$PJ/$pj}"

    echo "$cmd"
}

# ============================================================================
# Rendering (OPTIMIZED: buffered output, inline pad/trim, ANSI escapes)
#
# Before: ~170 process forks per render (tput cup/el + pad_or_trim subshells)
# After:  0 forks per render — pure string ops + single printf
# ============================================================================

# Appends one row to RENDER_BUF with inline pad_or_trim (no subshells)
_render_row_buf() {
    local screen_row=$1 data_idx=$2 is_selected=$3
    local name="${HOST_NAMES[$data_idx]}"
    local ip="${HOST_IPS[$data_idx]:-"--"}"
    local user="${HOST_USERS[$data_idx]:-"--"}"
    local section="${HOST_SECTIONS[$data_idx]:-""}"

    # Inline pad_or_trim: printf -v writes to variable (zero forks, was 4 subshells/row)
    local col1 col2 col3 col4
    if ((${#name} > 25)); then col1="${name:0:23}.."; else printf -v col1 "%-25s" "$name"; fi
    if ((${#ip} > 22)); then col2="${ip:0:20}.."; else printf -v col2 "%-22s" "$ip"; fi
    if ((${#user} > 14)); then col3="${user:0:12}.."; else printf -v col3 "%-14s" "$user"; fi
    if ((${#section} > SEC_COL_W)); then col4="${section:0:$((SEC_COL_W-2))}.."; else printf -v col4 "%-${SEC_COL_W}s" "$section"; fi

    RENDER_BUF+="${CSI}$((screen_row+1));1H"
    if ((is_selected)); then
        RENDER_BUF+="${C_SELECTED} > ${col1} ${col2} ${col3} ${col4} ${C_RESET}${CSI}K"
    else
        RENDER_BUF+="${C_NORMAL}   ${col1} ${col2} ${C_DIM}${col3} ${col4}${C_RESET}${CSI}K"
    fi
}

render_header() {
    local filter_info=""
    if [[ -n "$SEARCH_TERM" ]]; then
        filter_info="Filter: $SEARCH_TERM"
    fi

    # Row 0: Title bar
    RENDER_BUF+="${CSI}1;1H${C_HEADER}"
    local title=" SSH Navigator"
    local host_info="${FILTERED_COUNT}/${HOST_COUNT} hosts"
    local cmd_info="cmd: ${LAUNCH_CMD}"
    local right_part="$host_info | $cmd_info"
    if [[ -n "$filter_info" ]]; then
        right_part="$filter_info | $host_info"
    fi
    local max_right=$((TERM_COLS - ${#title} - 4))
    if ((${#right_part} > max_right)); then
        right_part="${right_part:0:$((max_right - 2))}.."
    fi
    local pad=$((TERM_COLS - ${#title} - ${#right_part} - 2))
    if ((pad < 1)); then pad=1; fi
    local pad_str
    printf -v pad_str '%*s' "$pad" ''
    RENDER_BUF+="${title}${pad_str}${right_part} ${C_RESET}${CSI}K"

    # Row 1: Search bar
    RENDER_BUF+="${CSI}2;1H"
    if ((SEARCH_MODE)); then
        RENDER_BUF+=" ${C_SEARCH}Search: ${SEARCH_TERM}${C_RESET}_"
    else
        if [[ -n "$SEARCH_TERM" ]]; then
            RENDER_BUF+=" ${C_DIM}Search: ${C_SEARCH}${SEARCH_TERM}${C_RESET}"
        else
            RENDER_BUF+=" ${C_DIM}Press / to search${C_RESET}"
        fi
    fi
    RENDER_BUF+="${CSI}K"

    # Row 2: Separator (pre-computed, no tr pipe)
    RENDER_BUF+="${CSI}3;1H${C_BOX}${SEP_LINE}${C_RESET}"

    # Row 3: Column headers
    RENDER_BUF+="${CSI}4;1H"
    local col_host col_ip col_user col_section
    printf -v col_host "%-25s" "HOST"
    printf -v col_ip "%-22s" "HOSTNAME/IP"
    printf -v col_user "%-14s" "USER"
    printf -v col_section "%-${SEC_COL_W}s" "SECTION"
    RENDER_BUF+=" ${C_COLHDR}  ${col_host} ${col_ip} ${col_user} ${col_section}${C_RESET}${CSI}K"
}

render_list() {
    local row=$HEADER_ROWS
    local end=$((SCROLL_OFFSET + LIST_ROWS))
    if ((end > FILTERED_COUNT)); then
        end=$FILTERED_COUNT
    fi

    local i
    for ((i = SCROLL_OFFSET; i < end; i++)); do
        local data_idx=${FILTERED_INDICES[$i]}
        local selected=0
        if ((i == CURSOR_POS)); then selected=1; fi
        _render_row_buf "$row" "$data_idx" "$selected"
        ((row++))
    done

    # Clear remaining rows
    while ((row < HEADER_ROWS + LIST_ROWS)); do
        RENDER_BUF+="${CSI}$((row+1));1H${CSI}K"
        ((row++))
    done
}

render_footer() {
    local sep_row=$((TERM_ROWS - 2))
    local help_row=$((TERM_ROWS - 1))

    # Separator (pre-computed, no tr pipe)
    RENDER_BUF+="${CSI}$((sep_row+1));1H${C_BOX}${SEP_LINE}${C_RESET}"

    # Help bar
    RENDER_BUF+="${CSI}$((help_row+1));1H${C_HEADER}"
    local help_text
    if ((SEARCH_MODE)); then
        help_text=" Type to filter | Enter:Keep filter | Esc:Clear"
    else
        help_text=" Up/Dn:Nav  PgUp/Dn:Page  Enter:Connect  v:View  a:Add  e:Cmd  /:Search  q:Quit"
    fi
    local pad=$((TERM_COLS - ${#help_text}))
    if ((pad < 0)); then pad=0; fi
    local pad_str
    printf -v pad_str '%*s' "$pad" ''
    RENDER_BUF+="${help_text}${pad_str}${C_RESET}"
}

render() {
    if ((! NEEDS_REDRAW)); then return; fi
    NEEDS_REDRAW=0
    RENDER_BUF=""
    render_header
    render_list
    render_footer
    printf '%s' "$RENDER_BUF"
}

# Incremental render: repaint only old + new cursor rows (2 rows vs full redraw)
render_cursor_move() {
    local old_pos=$1 new_pos=$2
    RENDER_BUF=""

    # Deselect old row
    if ((old_pos >= SCROLL_OFFSET && old_pos < SCROLL_OFFSET + LIST_ROWS)); then
        local screen_row=$((HEADER_ROWS + old_pos - SCROLL_OFFSET))
        local data_idx=${FILTERED_INDICES[$old_pos]}
        _render_row_buf "$screen_row" "$data_idx" 0
    fi

    # Select new row
    if ((new_pos >= SCROLL_OFFSET && new_pos < SCROLL_OFFSET + LIST_ROWS)); then
        local screen_row=$((HEADER_ROWS + new_pos - SCROLL_OFFSET))
        local data_idx=${FILTERED_INDICES[$new_pos]}
        _render_row_buf "$screen_row" "$data_idx" 1
    fi

    printf '%s' "$RENDER_BUF"
}

# ============================================================================
# Detail View (OPTIMIZED: ANSI escapes, buffered)
# ============================================================================

render_detail() {
    local idx=$1
    local buf=""

    # Clear screen
    buf+="${CSI}2J${CSI}H"

    local name="${HOST_NAMES[$idx]}"
    local aliases="${HOST_ALIASES[$idx]}"
    local ip="${HOST_IPS[$idx]:-"(not set)"}"
    local user="${HOST_USERS[$idx]:-"(not set)"}"
    local port="${HOST_PORTS[$idx]:-"22"}"
    local key="${HOST_KEYS[$idx]:-"(not set)"}"
    local proxy="${HOST_PROXIES[$idx]:-"(not set)"}"
    local section="${HOST_SECTIONS[$idx]:-"(none)"}"
    local identonly="${HOST_IDENTONLY[$idx]:-"(not set)"}"
    local cmd
    cmd=$(build_launch_cmd "$idx")

    # Title
    buf+="${CSI}2;3H${C_HEADER}  Host Details  ${C_RESET}"

    # Box
    local row=3
    local label_w=18
    local box_w=$((TERM_COLS - 4))

    # Pre-compute box separator
    local box_sep
    printf -v box_sep '%*s' "$box_w" ''
    box_sep="${box_sep// /-}"

    buf+="${CSI}$((row+1));3H${C_BOX}+${box_sep}+${C_RESET}"
    ((row++))

    # Helper to append a detail line
    _detail_line() {
        local lbl="$1" val="$2"
        local formatted_lbl
        printf -v formatted_lbl "%-${label_w}s" "$lbl"
        buf+="${CSI}$((row+1));3H${C_BOX}|${C_RESET} ${C_LABEL}${formatted_lbl}${C_RESET}${C_VALUE}${val}${C_RESET}${CSI}K"
        local end_col=$((box_w + 3))
        buf+="${CSI}$((row+1));${end_col}H${C_BOX}|${C_RESET}"
        ((row++))
    }

    _detail_sep() {
        buf+="${CSI}$((row+1));3H${C_BOX}+${box_sep}+${C_RESET}"
        ((row++))
    }

    _detail_line "Host:" "$name"
    if [[ "$aliases" != "$name" && -n "$aliases" ]]; then
        _detail_line "Aliases:" "$aliases"
    fi
    _detail_line "Section:" "$section"
    _detail_sep
    _detail_line "HostName:" "$ip"
    _detail_line "User:" "$user"
    _detail_line "Port:" "$port"
    _detail_line "IdentityFile:" "$key"
    _detail_line "ProxyJump:" "$proxy"
    _detail_line "IdentitiesOnly:" "$identonly"
    _detail_sep
    _detail_line "Launch cmd:" "$cmd"

    # Bottom border
    buf+="${CSI}$((row+1));3H${C_BOX}+${box_sep}+${C_RESET}"
    ((row += 2))

    # Actions
    buf+="${CSI}$((row+1));5H${C_COLHDR}[c]${C_RESET} Connect    ${C_COLHDR}[e]${C_RESET} Edit Cmd    ${C_COLHDR}[q/Esc]${C_RESET} Back"

    printf '%s' "$buf"
}

handle_detail_view() {
    local idx=$1
    CURRENT_VIEW="detail"
    render_detail "$idx"

    while true; do
        read_key
        case "$KEY_RESULT" in
            "CHAR:c"|"ENTER")
                action_connect "$idx"
                render_detail "$idx"
                ;;
            "CHAR:e"|"CHAR:E")
                handle_edit_cmd_view
                CURRENT_VIEW="detail"
                render_detail "$idx"
                ;;
            "CHAR:q"|"ESC")
                CURRENT_VIEW="list"
                NEEDS_REDRAW=1
                return
                ;;
            "TIMEOUT") ;;
        esac
    done
}

# ============================================================================
# Connect Action (OPTIMIZED: ANSI escapes for TUI exit/re-enter)
# ============================================================================

action_connect() {
    local idx=$1
    local cmd
    cmd=$(build_launch_cmd "$idx")

    # Exit TUI mode (ANSI escapes replace tput forks)
    printf '%s' "${CSI}?7h${CSI}?25h${CSI}?1049l${CSI}0m"
    if [[ -n "$OLD_STTY" ]]; then
        stty "$OLD_STTY" 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi

    echo ""
    echo "Launching: $cmd"
    echo "---"
    eval "$cmd" || true
    echo ""
    echo "--- Session ended. Press any key to return to SSH Navigator ---"
    read -rsn1 _ 2>/dev/null || true

    # Re-enter TUI mode (ANSI escapes replace tput forks)
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    printf '%s' "${CSI}?1049h${CSI}?25l${CSI}?7l"
    detect_size
    NEEDS_REDRAW=1
}

# ============================================================================
# Edit Launch Command (OPTIMIZED: ANSI escapes, buffered)
# ============================================================================

EDIT_CMD_VALUE=""
EDIT_CMD_STATUS=""

render_edit_cmd() {
    local buf=""

    # Clear screen
    buf+="${CSI}2J${CSI}H"

    # Title
    buf+="${CSI}2;3H${C_HEADER}  Edit Launch Command  ${C_RESET}"

    local row=3
    local box_w=$((TERM_COLS - 4))

    # Pre-compute box separator
    local box_sep
    printf -v box_sep '%*s' "$box_w" ''
    box_sep="${box_sep// /-}"

    buf+="${CSI}$((row+1));3H${C_BOX}+${box_sep}+${C_RESET}"
    ((row++))

    local source_hint="(embedded)"
    if [[ -n "$CMD_FROM_FLAG" ]]; then
        source_hint="(--cmd flag)"
    elif [[ -n "${SSH_NAV_CMD:-}" ]]; then
        source_hint="(SSH_NAV_CMD env)"
    fi
    buf+="${CSI}$((row+1));3H${C_BOX}|${C_RESET} ${C_LABEL}Current:${C_RESET}  ${C_DIM}${LAUNCH_CMD}  ${source_hint}${C_RESET}${CSI}K"
    local end_col=$((box_w + 3))
    buf+="${CSI}$((row+1));${end_col}H${C_BOX}|${C_RESET}"
    ((row++))

    buf+="${CSI}$((row+1));3H${C_BOX}+${box_sep}+${C_RESET}"
    ((row++))

    buf+="${CSI}$((row+1));3H${C_BOX}|${C_RESET} ${C_SEARCH}New cmd:${C_RESET}  ${C_VALUE}${EDIT_CMD_VALUE}${C_RESET}${C_SEARCH}_${C_RESET}${CSI}K"
    buf+="${CSI}$((row+1));${end_col}H${C_BOX}|${C_RESET}"
    ((row++))

    buf+="${CSI}$((row+1));3H${C_BOX}+${box_sep}+${C_RESET}"
    ((row += 2))

    # Placeholder reference
    buf+="${CSI}$((row+1));5H${C_COLHDR}Available placeholders:${C_RESET}"
    ((row++))
    buf+="${CSI}$((row+1));7H${C_LABEL}\$H${C_RESET}  = Host alias   ${C_LABEL}\$HN${C_RESET} = HostName/IP   ${C_LABEL}\$U${C_RESET} = User"
    ((row++))
    buf+="${CSI}$((row+1));7H${C_LABEL}\$P${C_RESET}  = Port         ${C_LABEL}\$K${C_RESET}  = IdentityFile  ${C_LABEL}\$PJ${C_RESET} = ProxyJump"
    ((row += 2))

    buf+="${CSI}$((row+1));5H${C_DIM}Examples: ssh \$H  |  ssh-vault \$HN  |  mosh \$U@\$HN  |  ssh -i \$K \$U@\$HN -p \$P${C_RESET}"
    ((row += 2))

    buf+="${CSI}$((row+1));5H${C_DIM}Saving writes the command into the script so it persists when distributed.${C_RESET}"
    ((row++))

    if [[ -n "$EDIT_CMD_STATUS" ]]; then
        buf+="${CSI}$((row+1));5H${EDIT_CMD_STATUS}"
        ((row += 2))
    fi

    # Footer
    local help_text=" Type new command | Enter:Save | Esc:Cancel"
    local pad=$((TERM_COLS - ${#help_text}))
    if ((pad < 0)); then pad=0; fi
    local pad_str
    printf -v pad_str '%*s' "$pad" ''
    buf+="${CSI}${TERM_ROWS};1H${C_HEADER}${help_text}${pad_str}${C_RESET}"

    printf '%s' "$buf"
}

save_embedded_cmd() {
    local new_cmd="$1"
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        return 1
    fi
    local escaped="${new_cmd//\'/\'\\\'\'}"
    sed -i "/^#::LAUNCH_CMD_BEGIN$/,/^#::LAUNCH_CMD_END$/{
        /^EMBEDDED_CMD=/c\\EMBEDDED_CMD='${escaped}'
    }" "$SCRIPT_PATH"
}

handle_edit_cmd_view() {
    CURRENT_VIEW="editcmd"
    EDIT_CMD_VALUE="$LAUNCH_CMD"
    EDIT_CMD_STATUS=""
    render_edit_cmd

    while true; do
        read_key
        case "$KEY_RESULT" in
            "ENTER")
                if [[ -n "$EDIT_CMD_VALUE" ]]; then
                    LAUNCH_CMD="$EDIT_CMD_VALUE"
                    if save_embedded_cmd "$EDIT_CMD_VALUE"; then
                        EDIT_CMD_STATUS="${C_SUCCESS}Launch command saved to script!${C_RESET}"
                    else
                        EDIT_CMD_STATUS="${C_SUCCESS}Updated for this session (could not write to script)${C_RESET}"
                    fi
                    render_edit_cmd
                    sleep 1.5
                    CURRENT_VIEW="list"
                    NEEDS_REDRAW=1
                    return
                else
                    EDIT_CMD_STATUS="${C_ERROR}Command cannot be empty${C_RESET}"
                    render_edit_cmd
                fi
                ;;
            "ESC")
                CURRENT_VIEW="list"
                NEEDS_REDRAW=1
                return
                ;;
            "BACKSPACE")
                if [[ -n "$EDIT_CMD_VALUE" ]]; then
                    EDIT_CMD_VALUE="${EDIT_CMD_VALUE%?}"
                fi
                render_edit_cmd
                ;;
            CHAR:*)
                local ch="${KEY_RESULT#CHAR:}"
                EDIT_CMD_VALUE+="$ch"
                render_edit_cmd
                ;;
            "TIMEOUT") ;;
        esac
    done
}

# ============================================================================
# Add Host Form (OPTIMIZED: ANSI escapes, buffered)
# ============================================================================

declare -a ADD_FIELDS=("Host" "HostName" "User" "Port" "IdentityFile" "ProxyJump" "Section")
declare -a ADD_VALUES=()
ADD_FIELD_IDX=0
ADD_STATUS_MSG=""

init_add_form() {
    ADD_VALUES=("" "" "" "22" "" "" "")
    ADD_FIELD_IDX=0
    ADD_STATUS_MSG=""
}

render_add_form() {
    local buf=""

    # Clear screen
    buf+="${CSI}2J${CSI}H"

    # Title
    buf+="${CSI}2;3H${C_HEADER}  Add New Host  ${C_RESET}"

    local row=3
    local box_w=$((TERM_COLS - 4))

    # Pre-compute box separator
    local box_sep
    printf -v box_sep '%*s' "$box_w" ''
    box_sep="${box_sep// /-}"

    buf+="${CSI}$((row+1));3H${C_BOX}+${box_sep}+${C_RESET}"
    ((row++))

    local i
    local end_col=$((box_w + 3))
    for ((i = 0; i < ${#ADD_FIELDS[@]}; i++)); do
        local label="${ADD_FIELDS[$i]}:"
        local value="${ADD_VALUES[$i]}"
        local formatted_lbl
        printf -v formatted_lbl "%-15s" "$label"

        buf+="${CSI}$((row+1));3H${C_BOX}|${C_RESET} "

        if ((i == ADD_FIELD_IDX)); then
            buf+="${C_SEARCH}> ${formatted_lbl}${C_RESET}${C_VALUE}${value}${C_RESET}${C_SEARCH}_${C_RESET}"
        else
            buf+="  ${C_LABEL}${formatted_lbl}${C_RESET}${C_DIM}${value}${C_RESET}"
        fi
        buf+="${CSI}K"
        buf+="${CSI}$((row+1));${end_col}H${C_BOX}|${C_RESET}"
        ((row++))
    done

    buf+="${CSI}$((row+1));3H${C_BOX}+${box_sep}+${C_RESET}"
    ((row += 2))

    # Required fields note
    buf+="${CSI}$((row+1));5H${C_DIM}* Host and HostName are required${C_RESET}"
    ((row += 2))

    # Status message
    if [[ -n "$ADD_STATUS_MSG" ]]; then
        buf+="${CSI}$((row+1));5H${ADD_STATUS_MSG}"
        ((row += 2))
    fi

    # Actions
    local help_text=" Up/Dn/Tab:Navigate fields | Type to edit | Enter:Save | Esc:Cancel"
    local pad=$((TERM_COLS - ${#help_text}))
    if ((pad < 0)); then pad=0; fi
    local pad_str
    printf -v pad_str '%*s' "$pad" ''
    buf+="${CSI}${TERM_ROWS};1H${C_HEADER}${help_text}${pad_str}${C_RESET}"

    printf '%s' "$buf"
}

validate_new_host() {
    local host="${ADD_VALUES[0]}"
    local hostname="${ADD_VALUES[1]}"

    if [[ -z "$host" ]]; then
        ADD_STATUS_MSG="${C_ERROR}Error: Host alias is required${C_RESET}"
        return 1
    fi

    if [[ -z "$hostname" ]]; then
        ADD_STATUS_MSG="${C_ERROR}Error: HostName/IP is required${C_RESET}"
        return 1
    fi

    # Check for duplicate
    local i
    for ((i = 0; i < HOST_COUNT; i++)); do
        if [[ "${HOST_NAMES[$i]}" == "$host" ]]; then
            ADD_STATUS_MSG="${C_ERROR}Error: Host '$host' already exists${C_RESET}"
            return 1
        fi
    done

    return 0
}

save_new_host() {
    local host="${ADD_VALUES[0]}"
    local hostname="${ADD_VALUES[1]}"
    local user="${ADD_VALUES[2]}"
    local port="${ADD_VALUES[3]}"
    local keyfile="${ADD_VALUES[4]}"
    local proxy="${ADD_VALUES[5]}"
    local section="${ADD_VALUES[6]}"

    # Create backup
    local backup="${SSH_CONFIG}.bak.$(date +%s)"
    cp "$SSH_CONFIG" "$backup"

    # Build the host entry
    local entry=""
    entry+="Host ${host}"$'\n'
    entry+="    HostName ${hostname}"$'\n'
    if [[ -n "$user" ]]; then
        entry+="    User ${user}"$'\n'
    fi
    if [[ -n "$port" && "$port" != "22" ]]; then
        entry+="    Port ${port}"$'\n'
    fi
    if [[ -n "$keyfile" ]]; then
        entry+="    IdentityFile ${keyfile}"$'\n'
    fi
    if [[ -n "$proxy" ]]; then
        entry+="    ProxyJump ${proxy}"$'\n'
    fi

    # Append to file
    if [[ -n "$section" ]]; then
        if grep -q "^### ${section}" "$SSH_CONFIG" 2>/dev/null; then
            printf '\n%s\n' "$entry" >> "$SSH_CONFIG"
        else
            printf '\n### %s ###\n%s\n' "$section" "$entry" >> "$SSH_CONFIG"
        fi
    else
        printf '\n%s\n' "$entry" >> "$SSH_CONFIG"
    fi

    # Re-parse
    parse_ssh_config
    build_search_index
    apply_filter

    ADD_STATUS_MSG="${C_SUCCESS}Host '$host' added! (backup: $backup)${C_RESET}"
}

handle_add_view() {
    CURRENT_VIEW="add"
    init_add_form
    render_add_form

    while true; do
        read_key
        case "$KEY_RESULT" in
            "UP")
                ((ADD_FIELD_IDX > 0)) && ((ADD_FIELD_IDX--))
                render_add_form
                ;;
            "DOWN"|"TAB")
                ((ADD_FIELD_IDX < ${#ADD_FIELDS[@]} - 1)) && ((++ADD_FIELD_IDX))
                render_add_form
                ;;
            "ENTER")
                if validate_new_host; then
                    save_new_host
                    render_add_form
                    sleep 1.5
                    CURRENT_VIEW="list"
                    NEEDS_REDRAW=1
                    return
                else
                    render_add_form
                fi
                ;;
            "ESC")
                CURRENT_VIEW="list"
                NEEDS_REDRAW=1
                return
                ;;
            "BACKSPACE")
                local val="${ADD_VALUES[$ADD_FIELD_IDX]}"
                if [[ -n "$val" ]]; then
                    ADD_VALUES[$ADD_FIELD_IDX]="${val%?}"
                fi
                render_add_form
                ;;
            CHAR:*)
                local ch="${KEY_RESULT#CHAR:}"
                ADD_VALUES[$ADD_FIELD_IDX]+="$ch"
                render_add_form
                ;;
            "TIMEOUT") ;;
        esac
    done
}

# ============================================================================
# Search Mode
# ============================================================================

handle_search_input() {
    local key="$1"
    case "$key" in
        "ENTER")
            SEARCH_MODE=0
            NEEDS_REDRAW=1
            ;;
        "ESC")
            SEARCH_MODE=0
            SEARCH_TERM=""
            SEARCH_TERM_LC=""
            apply_filter
            NEEDS_REDRAW=1
            ;;
        "BACKSPACE")
            if [[ -n "$SEARCH_TERM" ]]; then
                SEARCH_TERM="${SEARCH_TERM%?}"
                SEARCH_TERM_LC="${SEARCH_TERM,,}"
                apply_filter
                NEEDS_REDRAW=1
            fi
            ;;
        CHAR:*)
            local ch="${key#CHAR:}"
            SEARCH_TERM+="$ch"
            SEARCH_TERM_LC="${SEARCH_TERM,,}"
            apply_filter
            NEEDS_REDRAW=1
            ;;
        "UP")
            SEARCH_MODE=0
            move_cursor -1
            ;;
        "DOWN")
            SEARCH_MODE=0
            move_cursor 1
            ;;
    esac
}

# ============================================================================
# Main List Key Handler
# ============================================================================

handle_list_key() {
    local key="$1"

    if ((SEARCH_MODE)); then
        handle_search_input "$key"
        return
    fi

    case "$key" in
        "UP")    move_cursor -1 ;;
        "DOWN")  move_cursor 1 ;;
        "PGUP")  page_up ;;
        "PGDN")  page_down ;;
        "HOME")  go_home ;;
        "END")   go_end ;;
        "ENTER")
            if ((FILTERED_COUNT > 0)); then
                local idx=${FILTERED_INDICES[$CURSOR_POS]}
                action_connect "$idx"
            fi
            ;;
        "CHAR:v"|"CHAR:V")
            if ((FILTERED_COUNT > 0)); then
                local idx=${FILTERED_INDICES[$CURSOR_POS]}
                handle_detail_view "$idx"
            fi
            ;;
        "CHAR:a"|"CHAR:A")
            handle_add_view
            ;;
        "CHAR:e"|"CHAR:E")
            handle_edit_cmd_view
            ;;
        "CHAR:/")
            SEARCH_MODE=1
            NEEDS_REDRAW=1
            ;;
        "CHAR:q"|"CHAR:Q")
            cleanup
            exit 0
            ;;
        CHAR:*)
            local ch="${key#CHAR:}"
            SEARCH_MODE=1
            SEARCH_TERM="$ch"
            SEARCH_TERM_LC="${SEARCH_TERM,,}"
            apply_filter
            NEEDS_REDRAW=1
            ;;
        "TIMEOUT")
            # Only check resize if WINCH fired (0 forks idle, was 2 forks/500ms)
            if ((WINCH_FIRED)); then
                WINCH_FIRED=0
                ensure_cursor_visible
                NEEDS_REDRAW=1
            fi
            ;;
    esac
}

# ============================================================================
# Main Loop (OPTIMIZED: read_key writes global — no subshell per iteration)
# ============================================================================

main_loop() {
    while true; do
        if [[ "$CURRENT_VIEW" == "list" ]]; then
            render
            read_key
            handle_list_key "$KEY_RESULT"
        fi
    done
}

# ============================================================================
# Entry Point
# ============================================================================

main() {
    parse_ssh_config
    if ((HOST_COUNT == 0)); then
        echo "No hosts found in $SSH_CONFIG"
        exit 1
    fi
    build_search_index
    apply_filter

    setup_colors
    init_terminal
    NEEDS_REDRAW=1
    main_loop
}

main
