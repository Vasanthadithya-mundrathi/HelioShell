#!/usr/bin/env bash
set -o pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "HeliOShell requires bash 4.0 or higher." >&2; exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "HeliOShell requires python3." >&2; exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "HeliOShell requires curl." >&2; exit 1
fi

readonly HELIO_VERSION="1.2.0"
readonly HELIO_AUTHORS="Yedla Sai Geethika & Vasanthadithya"
readonly HELIO_DIR="${HOME}/.config/helioshell"
readonly ENV_FILE="${HELIO_DIR}/.env"
readonly SAVE_DIR="${HOME}/helioshell_saves"
readonly HISTORY_FILE="${HELIO_DIR}/history.sh"
readonly RL_HISTORY_FILE="${HELIO_DIR}/readline_history"
readonly MAX_HISTORY=10
readonly API_TIMEOUT=20

PROVIDER=""
API_KEY=""
CURRENT_MODE="default"
CONVERSATION='[]'
AVAILABLE_TOOLS=""
SESSION_SAVE_COUNT=0
HELIO_PROMPT=""

DESTRUCTIVE_PATTERNS=(
    "rm -rf" "rm -fr" "rm -r /" "dd if=" "mkfs" "format" "shutdown"
    "reboot" "> /dev/sd" "wipefs" "fdisk" "parted" "chmod -R 777 /"
    "chown -R" "userdel" "groupdel" "systemctl stop" "kill -9 1"
    ":(){:|:&};:" "truncate -s 0" "docker system prune -a"
)

# Use printf subshells so variables contain actual ESC bytes (not literal \033)
if [[ -t 1 ]]; then
    RED=$(printf '\033[0;31m');    GREEN=$(printf '\033[0;32m')
    YELLOW=$(printf '\033[1;33m'); CYAN=$(printf '\033[0;36m')
    BLUE=$(printf '\033[0;34m');   MAGENTA=$(printf '\033[0;35m')
    WHITE=$(printf '\033[1;37m');  DIM=$(printf '\033[2m')
    ORANGE=$(printf '\033[0;33m'); PINK=$(printf '\033[1;35m')
    RESET=$(printf '\033[0m');     BOLD=$(printf '\033[1m')
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
    WHITE=''; DIM=''; ORANGE=''; PINK=''; RESET=''; BOLD=''
fi

mask_key() {
    local key="$1" len=${#1}
    if (( len <= 12 )); then printf '****\n'; return; fi
    printf '%s...%s\n' "${key:0:8}" "${key: -4}"
}

divider()     { printf '%s  ─────────────────────────────────────────────────────────%s\n' "$DIM" "$RESET"; }
status_ok()   { printf '%s  ✓ %s%s\n' "$GREEN"  "$1" "$RESET"; }
status_err()  { printf '%s  ✗ %s%s\n' "$RED"    "$1" "$RESET" >&2; }
status_warn() { printf '%s  ⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }
status_info() { printf '%s  ℹ %s%s\n' "$CYAN"   "$1" "$RESET"; }
clear_line()  { printf '\r\033[2K'; }

print_banner() {
    clear 2>/dev/null || true
    printf '%s' "$CYAN"
    cat <<'BANNER'
  ██╗  ██╗███████╗██╗     ██╗ ██████╗ ███████╗██╗  ██╗███████╗██╗     ██╗
  ██║  ██║██╔════╝██║     ██║██╔═══██╗██╔════╝██║  ██║██╔════╝██║     ██║
  ███████║█████╗  ██║     ██║██║   ██║███████╗███████║█████╗  ██║     ██║
  ██╔══██║██╔══╝  ██║     ██║██║   ██║╚════██║██╔══██║██╔══╝  ██║     ██║
  ██║  ██║███████╗███████╗██║╚██████╔╝███████║██║  ██║███████╗███████╗███████╗
  ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝
BANNER
    printf '%s\n' "$RESET"
    divider
    printf '%s  ⚡ HeliOShell v%s — AI-Powered Terminal Intelligence%s\n' "$WHITE" "$HELIO_VERSION" "$RESET"
    printf '%s  ✦ Authors: %s%s\n' "$DIM" "$HELIO_AUTHORS" "$RESET"
    printf '%s  ✦ Providers: Cerebras · Google Gemini%s\n' "$DIM" "$RESET"
    divider
    echo
}

print_mini_banner() {
    printf '%s⚡ HeliOShell%s %sv%s%s\n' "$CYAN" "$RESET" "$DIM" "$HELIO_VERSION" "$RESET"
}

validate_provider() {
    case "$1" in
        cerebras|gemini) return 0 ;;
        *) status_err "Unknown provider '$1'. Supported: cerebras, gemini"; return 1 ;;
    esac
}

load_env() {
    [[ -f "$ENV_FILE" ]] || return
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    PROVIDER="${HELIO_PROVIDER:-}"
    API_KEY="${HELIO_API_KEY:-}"
}

save_env() {
    local provider="$1" key="$2"
    mkdir -p "$HELIO_DIR" || { status_err "Cannot create config dir: $HELIO_DIR"; return 1; }
    { echo "# HeliOShell configuration"
      printf 'HELIO_PROVIDER=%q\n' "$provider"
      printf 'HELIO_API_KEY=%q\n'  "$key"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    PROVIDER="$provider"; API_KEY="$key"
    status_ok "Provider '$provider' configured."
    status_ok "API key saved: $(mask_key "$key")"
    status_ok "Config stored at: $ENV_FILE"
}

detect_tools() {
    local found=()
    local tools=(
        nmap masscan arp-scan netdiscover ping ping6 traceroute tracepath mtr
        dig nslookup host whois curl wget nc netcat socat ss netstat lsof
        nikto gobuster dirb dirsearch wfuzz ffuf sqlmap msfconsole msfvenom
        searchsploit hydra medusa john hashcat aircrack-ng airodump-ng aireplay-ng
        tshark tcpdump xxd hexdump strings file binwalk openssl gpg base64
        python3 python ruby perl php gcc g++ make cmake git docker kubectl
        strace ltrace gdb ssh scp sftp ftp telnet grep sed awk jq find
        xargs tar unzip zip ps top journalctl systemctl ip ifconfig
    )
    for t in "${tools[@]}"; do
        command -v "$t" >/dev/null 2>&1 && found+=("$t")
    done
    AVAILABLE_TOOLS="${found[*]}"
}

mode_description() {
    case "$1" in
        default) echo 'Smart intent detection for mixed requests.' ;;
        shell)   echo 'Precise bash and Linux command generation.' ;;
        recon)   echo 'Passive-first recon for domains, IPs, and usernames.' ;;
        exploit) echo 'Authorized security testing with safety warnings.' ;;
        chat)    echo 'Concept explanations; commands only when asked.' ;;
        code)    echo 'Code writing, debugging, refactoring, and run commands.' ;;
        *)       echo 'Unknown mode.' ;;
    esac
}

show_modes() {
    printf '%sAvailable modes%s\n' "$WHITE" "$RESET"
    divider
    printf '  %sdefault%s  — %s\n' "$CYAN"    "$RESET" "$(mode_description default)"
    printf '  %sshell%s    — %s\n' "$GREEN"   "$RESET" "$(mode_description shell)"
    printf '  %srecon%s    — %s\n' "$ORANGE"  "$RESET" "$(mode_description recon)"
    printf '  %sexploit%s  — %s\n' "$RED"     "$RESET" "$(mode_description exploit)"
    printf '  %schat%s     — %s\n' "$BLUE"    "$RESET" "$(mode_description chat)"
    printf '  %scode%s     — %s\n' "$YELLOW"  "$RESET" "$(mode_description code)"
    echo
    printf '%sSwitch:      %s use shell / use recon / use code\n' "$DIM" "$RESET"
    printf '%sOne-shot:    %s heliorecon find MX records for example.com\n' "$DIM" "$RESET"
    printf '%s             %s heliocode debug this Python traceback\n'       "$DIM" "$RESET"
    echo
}

mode_prompt_fragment() {
    case "$1" in
        shell)
cat <<'EOF'
MODE: SHELL
- Generate exact bash commands, copy-pasteable and producing visible output.
- Prefer one-liners. Use safe flags where reasonable.
- Suppress interactive prompts when running non-interactively.
EOF
            ;;
        recon)
cat <<'EOF'
MODE: RECON
- Passive recon before active scanning.
- PERSON → social/OSINT tools (sherlock, etc.), NOT whois.
- DOMAIN → dig, host, nslookup, whois, curl, cert transparency.
- IP     → ping, traceroute, nmap (service scan), whois, geolocation.
EOF
            ;;
        exploit)
cat <<'EOF'
MODE: EXPLOIT
- Authorized security testing only — always note this in warnings.
- Steps must be reproducible and minimally destructive.
- Metasploit: msfconsole -q -x "use ...; set RHOSTS ...; run; exit"
- Prefer searchsploit CVE lookup before msfconsole.
EOF
            ;;
        chat)
cat <<'EOF'
MODE: CHAT
- Prefer explanation over commands.
- Return empty commands array unless a command is explicitly useful.
- Keep responses friendly, clear, and educational.
EOF
            ;;
        code)
cat <<'EOF'
MODE: CODE
- Focus on writing, fixing, or explaining code.
- Put runnable shell commands (compile, run, test) in commands array.
- For bugs: explain the root cause, not just the fix.
EOF
            ;;
        *)
cat <<'EOF'
MODE: DEFAULT
- Infer intent from the request.
- Question words → explanation (empty commands). Action verbs → shell commands.
- Choose the simplest correct command sequence.
EOF
            ;;
    esac
}

build_system_prompt() {
    local mode="$1"
    cat <<EOF
You are HeliOShell, an AI assistant embedded in a bash terminal.

SYSTEM:
  OS: $(uname -s) $(uname -r)
  Mode: ${mode}
  Installed tools: ${AVAILABLE_TOOLS:-none detected}

OUTPUT CONTRACT — return ONLY valid JSON, no markdown, no code fences:
{
  "explanation": "1-3 concise sentences",
  "commands": ["cmd1", "cmd2"],
  "warning": "string or null"
}

Rules:
1. Use only tools from the installed list above.
2. Each command must be valid bash producing visible output.
3. Empty array when no shell command is appropriate.
4. No unexpanded placeholders like <target> unless user omitted the value.
5. Flag risky actions in warning field.
6. Order commands exactly as they should run.
7. explanation must always be populated.

$(mode_prompt_fragment "$mode")
EOF
}

trim_conversation() {
    CONVERSATION=$(python3 - "$CONVERSATION" "$MAX_HISTORY" <<'PY'
import json,sys
c=json.loads(sys.argv[1]); m=int(sys.argv[2])*2
print(json.dumps(c[-m:] if len(c)>m else c))
PY
)
}

call_cerebras() {
    local sys="$1" conv="$2"
    local payload
    payload=$(python3 - "$sys" "$conv" <<'PY'
import json,sys
s=sys.argv[1]; c=json.loads(sys.argv[2])
msgs=[{"role":"system","content":s}]+c
print(json.dumps({"model":"llama3.1-8b","messages":msgs,
    "max_completion_tokens":1024,"temperature":0.15,"top_p":1,"stream":False}))
PY
)
    local resp
    resp=$(curl -sS --max-time "$API_TIMEOUT" \
        https://api.cerebras.ai/v1/chat/completions \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    [[ -z "$resp" ]] && printf '{"explanation":"Timeout or empty response.","commands":[],"warning":"Check network/key."}\n' && return
    python3 - "$resp" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
    if "error" in d:
        print(json.dumps({"explanation":f"Cerebras error: {d['error'].get('message',str(d['error']))}","commands":[],"warning":None}))
    else:
        print(d["choices"][0]["message"]["content"])
except Exception as e:
    print(json.dumps({"explanation":f"Parse error: {e}","commands":[],"warning":None}))
PY
}

call_gemini() {
    local sys="$1" conv="$2"
    local payload
    payload=$(python3 - "$sys" "$conv" <<'PY'
import json,sys
s=sys.argv[1]; c=json.loads(sys.argv[2])
contents=[{"role":"user" if m["role"]=="user" else "model","parts":[{"text":m.get("content","")}]} for m in c]
if not contents: contents=[{"role":"user","parts":[{"text":"Hello"}]}]
print(json.dumps({"systemInstruction":{"parts":[{"text":s}]},"contents":contents,
    "generationConfig":{"temperature":0.15,"maxOutputTokens":1024,"topP":1.0}}))
PY
)
    local resp
    resp=$(curl -sS --max-time "$API_TIMEOUT" \
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    [[ -z "$resp" ]] && printf '{"explanation":"Timeout or empty response.","commands":[],"warning":"Check network/key."}\n' && return
    python3 - "$resp" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
    if "error" in d:
        print(json.dumps({"explanation":f"Gemini error: {d['error'].get('message',str(d['error']))}","commands":[],"warning":None}))
    else:
        parts=d["candidates"][0]["content"]["parts"]
        print("".join(p.get("text","") for p in parts))
except Exception as e:
    print(json.dumps({"explanation":f"Parse error: {e}","commands":[],"warning":None}))
PY
}

call_ai() {
    local input="$1"
    CONVERSATION=$(python3 - "$CONVERSATION" "$input" <<'PY'
import json,sys; c=json.loads(sys.argv[1]); c.append({"role":"user","content":sys.argv[2]}); print(json.dumps(c))
PY
)
    trim_conversation
    local sys_prompt ai_resp
    sys_prompt=$(build_system_prompt "$CURRENT_MODE")
    case "$PROVIDER" in
        cerebras) ai_resp=$(call_cerebras "$sys_prompt" "$CONVERSATION") ;;
        gemini)   ai_resp=$(call_gemini   "$sys_prompt" "$CONVERSATION") ;;
        *)        ai_resp='{"explanation":"No provider configured.","commands":[],"warning":null}' ;;
    esac
    CONVERSATION=$(python3 - "$CONVERSATION" "$ai_resp" <<'PY'
import json,sys; c=json.loads(sys.argv[1]); c.append({"role":"assistant","content":sys.argv[2]}); print(json.dumps(c))
PY
)
    trim_conversation
    printf '%s\n' "$ai_resp"
}

parse_ai_response() {
    local raw="$1"
    local tmp; tmp=$(mktemp)
    python3 - "$raw" "$tmp" <<'PY'
import json,sys,re,base64
raw=sys.argv[1].strip()
raw=re.sub(r'^```(?:json)?\s*','',raw,flags=re.MULTILINE)
raw=re.sub(r'```\s*$','',raw,flags=re.MULTILINE).strip()
try:    data=json.loads(raw)
except: data={"explanation":raw,"commands":[],"warning":None}
explanation=str(data.get("explanation") or "")
warning=data.get("warning")
if warning in ("null","None","",None): warning=None
commands=[]
if isinstance(data.get("commands"),list):
    commands=[str(c) for c in data["commands"] if str(c).strip() and str(c) not in ("null","None")]
elif data.get("command") not in (None,"","null","None"):
    commands=[str(data["command"])]
with open(sys.argv[2],'w') as f:
    f.write(base64.b64encode(explanation.encode()).decode()+"\n")
    f.write(base64.b64encode((warning or '').encode()).decode()+"\n")
    f.write(str(len(commands))+"\n")
    for cmd in commands:
        f.write(base64.b64encode(cmd.encode()).decode()+"\n")
PY
    local b64e b64w n
    { IFS= read -r b64e; IFS= read -r b64w; IFS= read -r n; } < "$tmp"
    HELIO_EXPLAIN=$(python3 -c 'import base64,sys;print(base64.b64decode(sys.argv[1]).decode("utf-8","replace"))' "$b64e" 2>/dev/null)
    HELIO_WARNING=$(python3 -c 'import base64,sys;print(base64.b64decode(sys.argv[1]).decode("utf-8","replace"))' "$b64w" 2>/dev/null)
    HELIO_COMMANDS=()
    if [[ -n "$n" && "$n" -gt 0 ]]; then
        while IFS= read -r b64c; do
            HELIO_COMMANDS+=("$(python3 -c 'import base64,sys;print(base64.b64decode(sys.argv[1]).decode("utf-8","replace"))' "$b64c" 2>/dev/null)")
        done < <(tail -n +4 "$tmp")
    fi
    rm -f "$tmp"
}

is_destructive() {
    local cmd="$1" p
    for p in "${DESTRUCTIVE_PATTERNS[@]}"; do [[ "$cmd" == *"$p"* ]] && return 0; done
    return 1
}

execute_single_command() {
    local cmd="$1"
    if [[ "$cmd" =~ ^[[:space:]]*(cd|export|unset|alias|unalias|source|\.)[[:space:]] ]]; then
        eval "$cmd"; return $?
    fi
    bash -lc "$cmd"; return $?
}

save_commands() {
    mkdir -p "$SAVE_DIR" "$HELIO_DIR"
    SESSION_SAVE_COUNT=$((SESSION_SAVE_COUNT+1))
    local fname="$SAVE_DIR/helio_$(date +%Y%m%d_%H%M%S)_${SESSION_SAVE_COUNT}.sh"
    { echo '#!/usr/bin/env bash'
      printf '# Saved by HeliOShell %s  mode=%s  provider=%s\n' "$(date)" "$CURRENT_MODE" "$PROVIDER"
      echo
      for cmd in "${HELIO_COMMANDS[@]}"; do echo "$cmd"; done
    } > "$fname"
    chmod +x "$fname"
    { printf '[%s] mode=%s provider=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$CURRENT_MODE" "$PROVIDER"
      for cmd in "${HELIO_COMMANDS[@]}"; do printf '  %s\n' "$cmd"; done
      echo
    } >> "$HISTORY_FILE"
    status_ok "Script saved: $fname"
    status_ok "History appended: $HISTORY_FILE"
}

handle_action() {
    local action
    echo
    printf '  %s[%sx%s] execute  [%ss%s] save  [%sq%s] dismiss%s\n' \
        "$DIM" "$GREEN" "$DIM" "$YELLOW" "$DIM" "$RED" "$DIM" "$RESET"
    printf '  %saction>%s ' "$BOLD" "$RESET"
    read -r -n1 action; echo
    case "$action" in
        x|X)
            local cmd rc
            for cmd in "${HELIO_COMMANDS[@]}"; do
                if is_destructive "$cmd"; then
                    echo
                    status_warn "DESTRUCTIVE OPERATION DETECTED"
                    printf '  %sCommand:%s %s\n' "$YELLOW" "$RESET" "$cmd"
                    printf '  %sType YES to proceed:%s ' "$RED" "$RESET"
                    local confirm; read -r confirm
                    [[ "$confirm" == "YES" ]] || { status_info "Cancelled."; return; }
                fi
                echo
                printf '  %s▶ Executing:%s %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$cmd" "$RESET"
                divider
                execute_single_command "$cmd"; rc=$?
                divider
                if [[ $rc -eq 0 ]]; then status_ok "Completed (exit 0)."
                else status_warn "Exited with code $rc."; fi
            done
            ;;
        s|S) save_commands ;;
        q|Q|'') status_info "Dismissed." ;;
        *) status_warn "Unknown key '$action'. Use x, s, or q." ;;
    esac
}

init_readline() {
    mkdir -p "$HELIO_DIR"
    touch "$RL_HISTORY_FILE"
    history -r "$RL_HISTORY_FILE" 2>/dev/null || true
    set +o vi 2>/dev/null || true
    bind 'set editing-mode emacs'        2>/dev/null || true
    bind 'set show-all-if-ambiguous on'  2>/dev/null || true
    bind 'set completion-ignore-case on' 2>/dev/null || true
    bind 'set bell-style none'           2>/dev/null || true
    bind '"\e[A": previous-history'      2>/dev/null || true
    bind '"\e[B": next-history'          2>/dev/null || true
    bind '"\e[C": forward-char'          2>/dev/null || true
    bind '"\e[D": backward-char'         2>/dev/null || true
    bind '"\e[1~": beginning-of-line'    2>/dev/null || true
    bind '"\e[4~": end-of-line'          2>/dev/null || true
    bind '"\e[H":  beginning-of-line'    2>/dev/null || true
    bind '"\e[F":  end-of-line'          2>/dev/null || true
    bind '"\C-a": beginning-of-line'     2>/dev/null || true
    bind '"\C-e": end-of-line'           2>/dev/null || true
    bind '"\e[3~": delete-char'          2>/dev/null || true
    bind 'TAB:menu-complete'             2>/dev/null || true
}

build_readline_prompt() {
    # \001 and \002 tell readline not to count color bytes in line length
    local O=$'\001' C=$'\002'
    if [[ "$CURRENT_MODE" == "default" ]]; then
        HELIO_PROMPT="${O}${CYAN}${C}helio${O}${RESET}${C}${O}${BOLD}${C}> ${O}${RESET}${C}"
    else
        HELIO_PROMPT="${O}${CYAN}${C}helio${O}${RESET}${C}${O}${MAGENTA}${C}[${CURRENT_MODE}]${O}${RESET}${C}${O}${BOLD}${C}> ${O}${RESET}${C}"
    fi
}

normalize_prefixed_mode() {
    local i="$1"
    case "$i" in
        helioshell\ *)   CURRENT_MODE="shell";   printf '%s\n' "${i#helioshell }" ;;
        heliorecon\ *)   CURRENT_MODE="recon";   printf '%s\n' "${i#heliorecon }" ;;
        helioexploit\ *) CURRENT_MODE="exploit"; printf '%s\n' "${i#helioexploit }" ;;
        heliochat\ *)    CURRENT_MODE="chat";    printf '%s\n' "${i#heliochat }" ;;
        heliocode\ *)    CURRENT_MODE="code";    printf '%s\n' "${i#heliocode }" ;;
        *)               printf '%s\n' "$i" ;;
    esac
}

show_help() {
    print_banner
    printf '%sDESCRIPTION%s\n' "$WHITE" "$RESET"
    echo "  Converts natural language into terminal-safe command suggestions."
    echo
    printf '%sUSAGE%s\n' "$WHITE" "$RESET"
    printf '  %shelio%s\n' "$CYAN" "$RESET"
    printf '  %shelio --provider cerebras --api KEY%s\n' "$CYAN" "$RESET"
    printf '  %shelio --provider gemini   --api KEY%s\n' "$CYAN" "$RESET"
    printf '  %shelio --help | --version%s\n' "$CYAN" "$RESET"
    echo
    printf '%sMODES%s\n' "$WHITE" "$RESET"
    show_modes
    printf '%sBUILT-INS%s\n' "$WHITE" "$RESET"
    echo "  help  modes  history  reset  clear  provider  tools  exit"
    echo
    printf '%sEDITOR KEYS%s\n' "$WHITE" "$RESET"
    echo "  ↑ ↓  history   ← →  cursor   Home/End or Ctrl+A/E  line boundaries"
    echo
    printf '%sSECURITY%s\n' "$WHITE" "$RESET"
    echo "  Config stored chmod 600. Destructive commands require typed YES."
    divider
}

install_manpage() {
    local dir="${HOME}/.local/share/man/man1"
    mkdir -p "$dir"
    cat > "$dir/helio.1" <<'MAN'
.TH HELIO 1 "2026-04-24" "HeliOShell 1.2.0" "User Commands"
.SH NAME
helio \- AI-powered terminal intelligence shell
.SH SYNOPSIS
.B helio
.RI [ --provider " name" ] [ --api " key" ] [ --help ] [ --version ]
.SH DESCRIPTION
HeliOShell converts natural language into shell-ready commands and short explanations,
with support for multiple AI providers and operating modes.
.SH OPTIONS
.TP
.B \-\-provider NAME \-\-api KEY
Configure a provider (cerebras or gemini).
.TP
.B \-\-help
Show help and exit.
.TP
.B \-\-version
Show version and exit.
.TP
.B \-\-install\-man
Install man page to ~/.local/share/man/man1.
.TP
.B \-\-reset\-config
Remove saved provider config.
.SH MODES
default, shell, recon, exploit, chat, code.
Switch with: use MODE
.SH INTERACTIVE COMMANDS
use MODE, modes, tools, history, reset, provider, clear, exit
.SH EDITING
Arrow keys navigate history and the current line.
Home/End and Ctrl+A/Ctrl+E jump to line boundaries.
.SH FILES
.I ~/.config/helioshell/.env
.br
.I ~/.config/helioshell/history.sh
.br
.I ~/helioshell_saves/
.SH AUTHORS
Yedla Sai Geethika and Vasanthadithya
MAN
    command -v mandb      >/dev/null 2>&1 && mandb -q      "$dir" 2>/dev/null || true
    command -v makewhatis >/dev/null 2>&1 && makewhatis    "$dir" 2>/dev/null || true
}

run_shell() {
    if [[ -z "$PROVIDER" || -z "$API_KEY" ]]; then
        status_warn "No provider configured."
        echo
        printf '  Configure one:\n'
        printf '    %shelio --provider cerebras --api YOUR_KEY%s\n' "$CYAN" "$RESET"
        printf '    %shelio --provider gemini   --api YOUR_KEY%s\n' "$CYAN" "$RESET"
        echo
        return 1
    fi

    init_readline
    detect_tools
    print_banner
    printf '  %sProvider :%s %s  %sKey:%s %s\n' "$DIM" "$RESET" "$PROVIDER" "$DIM" "$RESET" "$(mask_key "$API_KEY")"
    printf '  %sOS       :%s %s %s\n' "$DIM" "$RESET" "$(uname -s)" "$(uname -r)"
    printf '  %sModes    :%s default  shell  recon  exploit  chat  code\n' "$DIM" "$RESET"
    printf '  %sBuilt-ins:%s help  modes  history  reset  clear  provider  tools  exit\n' "$DIM" "$RESET"
    divider

    while true; do
        build_readline_prompt
        read -e -r -p "$HELIO_PROMPT" user_input || { echo; break; }
        [[ -z "$user_input" ]] && continue
        history -s "$user_input"
        history -a "$RL_HISTORY_FILE"

        user_input=$(normalize_prefixed_mode "$user_input")

        case "$user_input" in
            exit|quit|bye)
                echo; status_ok "Goodbye!"; echo; break ;;
            clear)
                print_banner ;;
            reset)
                CONVERSATION='[]'; status_ok "Context cleared."; echo ;;
            history)
                echo
                if [[ -f "$HISTORY_FILE" && -s "$HISTORY_FILE" ]]; then
                    printf '%sSaved command history%s\n' "$WHITE" "$RESET"; divider; cat "$HISTORY_FILE"
                else status_info "No saved history yet."; fi
                echo ;;
            modes)  echo; show_modes ;;
            tools)
                echo
                printf '%sDetected system tools%s\n' "$WHITE" "$RESET"; divider
                printf '  %s\n\n' "${AVAILABLE_TOOLS:-none detected}" ;;
            provider)
                echo
                printf '  %sProvider:%s %s  %sKey:%s %s\n\n' \
                    "$DIM" "$RESET" "$PROVIDER" "$DIM" "$RESET" "$(mask_key "$API_KEY")" ;;
            help|--help|-h)
                show_help ;;
            use\ *)
                local m="${user_input#use }"; m="${m## }"
                case "$m" in
                    default|shell|recon|exploit|chat|code)
                        CURRENT_MODE="$m"
                        status_ok "Mode: ${BOLD}$CURRENT_MODE${RESET}"
                        printf '  %s%s%s\n\n' "$DIM" "$(mode_description "$CURRENT_MODE")" "$RESET" ;;
                    *) status_warn "Unknown mode '$m'. Valid: default shell recon exploit chat code" ;;
                esac ;;
            *)
                printf '  %sThinking...%s' "$DIM" "$RESET"
                local raw
                raw=$(call_ai "$user_input")
                clear_line
                parse_ai_response "$raw"
                echo
                [[ -n "$HELIO_EXPLAIN"  ]] && printf '  %s%s%s\n' "$WHITE" "$HELIO_EXPLAIN" "$RESET"
                [[ -n "$HELIO_WARNING"  ]] && status_warn "$HELIO_WARNING"
                if (( ${#HELIO_COMMANDS[@]} > 0 )); then
                    echo
                    printf '  %sGenerated command(s):%s\n' "$DIM" "$RESET"
                    local i=0 cmd
                    for cmd in "${HELIO_COMMANDS[@]}"; do
                        i=$((i+1))
                        printf '    %s%d.%s %s%s%s\n' "$GREEN" "$i" "$RESET" "$BOLD" "$cmd" "$RESET"
                    done
                    handle_action
                fi
                echo ;;
        esac
    done
}

main() {
    local manpage="${HOME}/.local/share/man/man1/helio.1"
    [[ -f "$manpage" ]] || install_manpage >/dev/null 2>&1 || true

    local arg_provider="" arg_api=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)       show_help; exit 0 ;;
            --provider|-p)   shift; arg_provider="${1:-}" ;;
            --api|-k)        shift; arg_api="${1:-}" ;;
            --version|-v)    print_mini_banner; printf 'version %s\n' "$HELIO_VERSION"; exit 0 ;;
            --install-man)   install_manpage; status_ok "Man page installed."; exit 0 ;;
            --reset-config)  rm -f "$ENV_FILE"; status_ok "Config cleared."; exit 0 ;;
            *) status_err "Unknown argument: $1"; echo "  Run: helio --help"; exit 1 ;;
        esac
        shift
    done

    if [[ -n "$arg_provider" || -n "$arg_api" ]]; then
        [[ -n "$arg_provider" ]] || { status_err "--provider required with --api"; exit 1; }
        [[ -n "$arg_api"      ]] || { status_err "--api required with --provider"; exit 1; }
        validate_provider "$arg_provider" || exit 1
        print_mini_banner; echo
        save_env "$arg_provider" "$arg_api"
        exit 0
    fi

    load_env
    run_shell
}

main "$@"
