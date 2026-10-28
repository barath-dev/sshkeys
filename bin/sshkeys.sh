#!/usr/bin/env bash
#
# sshkeys - lightweight interactive terminal tool to view and manage the SSH
# keys in ~/.ssh: create, inspect, rename, re-comment, change passphrase,
# load into the agent, test against hosts and delete (to a trash folder).
# Every key is shown next to the ~/.ssh/config hosts that use it, so you can
# see what a key is for before touching it.
#
# Works with the stock /bin/bash shipped on macOS (3.2) - no bash4+
# features (no associative arrays, no mapfile) are used on purpose.

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SSH_DIR="${SSHKEYS_DIR:-$HOME/.ssh}"
SSH_CONFIG="$SSH_DIR/config"
STATE_DIR="$SSH_DIR/.sshkeys"   # config backups and deleted keys live here

ORIG_STTY=""
CURSOR=0
OFFSET=0
STATUS=""
STATUS_COLOR=""
HOSTMAP=""    # "IdentityFile<TAB>Host patterns" lines read from ssh config

IS_MAC=0
[[ "$(uname)" == "Darwin" ]] && IS_MAC=1

# Parallel arrays describing the current list of keys.
NAMES=()      # private key file name inside SSH_DIR
TYPES=()      # ED25519, RSA, ...
BITS=()
FPRINTS=()    # SHA256:...
COMMENTS=()
PASSES=()     # yes / no / ? (? = permissions too open to tell)
AGENTS=()     # yes / no
HOSTS=()      # space separated ssh config Host patterns using the key
HASPUB=()     # 1/0 - does <name>.pub exist

# ---------------------------------------------------------------------------
# Terminal helpers
# ---------------------------------------------------------------------------

supports_color() {
    [[ -t 1 ]] && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]
}

if supports_color; then
    C_RESET=$(tput sgr0)
    C_BOLD=$(tput bold)
    C_DIM=$(tput dim)
    C_REV=$(tput rev)
    C_GREEN=$(tput setaf 2)
    C_CYAN=$(tput setaf 6)
    C_YELLOW=$(tput setaf 3)
    C_RED=$(tput setaf 1)
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_REV=""; C_GREEN=""; C_CYAN=""; C_YELLOW=""; C_RED=""
fi

cleanup() {
    [[ -n "$ORIG_STTY" ]] && stty "$ORIG_STTY" 2>/dev/null
    tput cnorm 2>/dev/null   # show cursor
    tput sgr0 2>/dev/null
    printf '\n'
}

ok()   { STATUS="$1"; STATUS_COLOR="$C_GREEN"; }
fail() { STATUS="$1"; STATUS_COLOR="$C_RED"; }

rule() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 60)
    printf '%s%s%s\n' "$C_DIM" "$(printf '%*s' "$((cols>0?cols:60))" '' | tr ' ' '-')" "$C_RESET"
}

raw_mode() {
    stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null
    tput civis >/dev/tty
}

cooked_mode() {
    stty "$ORIG_STTY" </dev/tty 2>/dev/null
    tput cnorm >/dev/tty
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

# Resolve an IdentityFile value the way ssh does for the common forms:
# ~/x, %d/x (home dir), absolute, or relative to the home dir.
expand_path() {
    local p="$1"
    case "$p" in
        "~/"*)  printf '%s' "$HOME/${p#\~/}" ;;
        "%d/"*) printf '%s' "$HOME/${p#%d/}" ;;
        /*)     printf '%s' "$p" ;;
        *)      printf '%s' "$HOME/$p" ;;
    esac
}

display_path() {
    case "$1" in
        "$HOME"/*) printf '~/%s' "${1#$HOME/}" ;;
        *)         printf '%s' "$1" ;;
    esac
}

file_mode() {
    if (( IS_MAC )); then stat -f '%Lp' "$1" 2>/dev/null; else stat -c '%a' "$1" 2>/dev/null; fi
}

file_date() {
    date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null
}

valid_name() {
    local re='^[A-Za-z0-9._-]+$'
    [[ "$1" =~ $re ]] && [[ "$1" != *.pub ]] && [[ "$1" != .* ]]
}

key_exists() {
    [[ -e "$SSH_DIR/$1" || -e "$SSH_DIR/$1.pub" ]]
}

copy_to_clipboard() {
    if command -v pbcopy >/dev/null 2>&1; then pbcopy
    elif command -v wl-copy >/dev/null 2>&1; then wl-copy
    elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard
    else cat >/dev/null; return 1
    fi
}

select_by_name() {
    local i
    for ((i = 0; i < ${#NAMES[@]}; i++)); do
        [[ "${NAMES[$i]}" == "$1" ]] && { CURSOR=$i; return; }
    done
}

need_key() {
    (( ${#NAMES[@]} > 0 )) && return 0
    fail "No keys - press c to create one."
    return 1
}

# Host patterns of a key that can actually be connected to (no wildcards,
# no Match blocks).
testable_hosts() {
    local h out=""
    for h in ${HOSTS[$1]}; do
        case "$h" in *[\*\?\!]*|"(global)"|"(match)") continue ;; esac
        out="${out:+$out }$h"
    done
    printf '%s' "$out"
}

# "user hostname port" that ssh would use for a destination.
resolve_host() {
    local -a cfg=()
    [[ -f "$SSH_CONFIG" ]] && cfg=(-F "$SSH_CONFIG")
    ssh "${cfg[@]}" -G "$1" 2>/dev/null | awk '
        $1 == "user"     { u = $2 }
        $1 == "hostname" { h = $2 }
        $1 == "port"     { p = $2 }
        END { print u, h, p }'
}

# ---------------------------------------------------------------------------
# ssh config
# ---------------------------------------------------------------------------

gather_host_map() {
    HOSTMAP=""
    [[ -f "$SSH_CONFIG" ]] || return
    HOSTMAP=$(awk '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            key = line; sub(/[ \t=].*/, "", key); key = tolower(key)
            val = line; sub(/^[^ \t=]+[ \t]*=?[ \t]*/, "", val); sub(/[ \t]+$/, "", val)
        }
        key == "host"  { host = val; next }
        key == "match" { host = "(match)"; next }
        key == "identityfile" {
            gsub(/"/, "", val)
            print val "\t" (host == "" ? "(global)" : host)
        }' "$SSH_CONFIG")
}

hosts_for() {
    local target="$1" out="" file hosts
    while IFS=$'\t' read -r file hosts; do
        [[ -z "$file" ]] && continue
        [[ "$(expand_path "$file")" == "$target" ]] || continue
        out="${out:+$out }$hosts"
    done <<< "$HOSTMAP"
    printf '%s' "$out"
}

host_defined() {
    [[ -f "$SSH_CONFIG" ]] || return 1
    awk -v want="$1" '
        { line = $0; sub(/^[ \t]+/, "", line); n = split(line, w, /[ \t=]+/) }
        tolower(w[1]) == "host" { for (i = 2; i <= n; i++) if (w[i] == want) found = 1 }
        END { exit !found }' "$SSH_CONFIG"
}

backup_config() {
    [[ -f "$SSH_CONFIG" ]] || return 0
    mkdir -p "$STATE_DIR/backups" && chmod 700 "$STATE_DIR" "$STATE_DIR/backups"
    cp -p "$SSH_CONFIG" "$STATE_DIR/backups/config.$(date +%Y%m%d-%H%M%S)"
}

# Point every IdentityFile line that resolves to $1 at $2 instead.
# Prints the number of lines changed; backs the config up first if any.
rewrite_identity() {
    local old="$1" new tmp changed
    new=$(display_path "$2")
    [[ -f "$SSH_CONFIG" ]] || { printf '0'; return; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/sshkeys.XXXXXX") || { printf '0'; return; }
    awk -v old="$old" -v new="$new" -v home="$HOME" '
        {
            line = $0
            key = line; sub(/^[ \t]+/, "", key); sub(/[ \t=].*/, "", key)
            if (tolower(key) == "identityfile") {
                val = line; sub(/^[ \t]*[^ \t=]+[ \t]*=?[ \t]*/, "", val)
                gsub(/"/, "", val); sub(/[ \t]+$/, "", val)
                p = val
                if (substr(p, 1, 2) == "~/")      p = home substr(p, 2)
                else if (substr(p, 1, 3) == "%d/") p = home substr(p, 3)
                else if (substr(p, 1, 1) != "/")  p = home "/" p
                if (p == old) {
                    indent = line; sub(/[^ \t].*/, "", indent)
                    print indent "IdentityFile " new
                    next
                }
            }
            print
        }' "$SSH_CONFIG" > "$tmp"
    changed=$(diff "$SSH_CONFIG" "$tmp" | grep -c '^>')
    if (( changed > 0 )); then
        backup_config
        cat "$tmp" > "$SSH_CONFIG"   # cat, not mv: keeps the config's mode
    fi
    rm -f "$tmp"
    printf '%s' "$changed"
}

# ---------------------------------------------------------------------------
# Data gathering
# ---------------------------------------------------------------------------

gather_keys() {
    NAMES=(); TYPES=(); BITS=(); FPRINTS=(); COMMENTS=(); PASSES=(); AGENTS=(); HOSTS=(); HASPUB=()
    gather_host_map

    local agent_fps
    agent_fps=$(ssh-add -l 2>/dev/null | awk '{print $2}')

    local f name info rest type fp mode
    for f in "$SSH_DIR"/*; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        case "$name" in *.pub|config|known_hosts*|authorized_keys*) continue ;; esac
        head -1 "$f" 2>/dev/null | grep -q -- '-----BEGIN .*PRIVATE KEY-----' || continue

        NAMES+=("$name")
        if [[ -f "$f.pub" ]]; then
            info=$(ssh-keygen -lf "$f.pub" 2>/dev/null); HASPUB+=(1)
        else
            info=$(ssh-keygen -lf "$f" 2>/dev/null); HASPUB+=(0)
        fi

        # "256 SHA256:abc... some comment (ED25519)"
        if [[ -n "$info" ]]; then
            BITS+=("${info%% *}")
            rest="${info#* }"
            fp="${rest%% *}"
            rest="${rest#* }"
            type="${rest##*\(}"
            TYPES+=("${type%)}")
            COMMENTS+=("${rest% \(*}")
        else
            fp="?"
            BITS+=("?"); TYPES+=("?"); COMMENTS+=("")
        fi
        FPRINTS+=("$fp")

        # ssh refuses private keys readable by others, so ssh-keygen -y
        # would fail for that reason rather than a passphrase.
        mode=$(file_mode "$f")
        if [[ -n "$mode" ]] && (( 8#$mode & 077 )); then
            PASSES+=("?")
        elif ssh-keygen -y -P "" -f "$f" >/dev/null 2>&1; then
            PASSES+=("no")
        else
            PASSES+=("yes")
        fi

        if [[ "$fp" != "?" ]] && grep -qxF -- "$fp" <<< "$agent_fps"; then
            AGENTS+=("yes")
        else
            AGENTS+=("no")
        fi

        HOSTS+=("$(hosts_for "$f")")
    done

    (( CURSOR >= ${#NAMES[@]} )) && CURSOR=$(( ${#NAMES[@]} > 0 ? ${#NAMES[@]} - 1 : 0 ))
    OFFSET=0
}

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

draw() {
    local rows cols viewport count i
    rows=$(tput lines)
    cols=$(tput cols)
    count=${#NAMES[@]}

    tput cup 0 0
    tput ed

    printf '%s%ssshkeys%s %s- SSH keys in %s%s\n' \
        "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$(display_path "$SSH_DIR")" "$C_RESET"
    printf '%s  %-24s %-8s %-5s %-5s %-24s %-s%s\n' \
        "$C_BOLD" "NAME" "TYPE" "PASS" "AGENT" "USED BY (ssh config)" "COMMENT" "$C_RESET"
    rule

    viewport=$(( rows - 9 ))
    (( viewport < 1 )) && viewport=1

    if (( count == 0 )); then
        printf '\n  %sNo SSH keys found. Press c to create one.%s\n' "$C_DIM" "$C_RESET"
    else
        (( CURSOR < OFFSET )) && OFFSET=$CURSOR
        (( CURSOR >= OFFSET + viewport )) && OFFSET=$(( CURSOR - viewport + 1 ))
        (( OFFSET < 0 )) && OFFSET=0

        for ((i = OFFSET; i < count && i < OFFSET + viewport; i++)); do
            local name="${NAMES[$i]}"
            (( ${#name} > 24 )) && name="${name:0:21}..."
            local hosts="${HOSTS[$i]:--}"
            (( ${#hosts} > 24 )) && hosts="${hosts:0:21}..."
            local comment="${COMMENTS[$i]}"
            local room=$(( cols - 74 ))
            if (( room < 4 )); then
                comment=""
            elif (( ${#comment} > room )); then
                comment="${comment:0:$((room-3))}..."
            fi

            if (( i == CURSOR )); then
                printf '%s> %-24s %-8s %-5s %-5s %-24s %-s%s\n' \
                    "$C_REV" "$name" "${TYPES[$i]}" "${PASSES[$i]}" "${AGENTS[$i]}" "$hosts" "$comment" "$C_RESET"
            else
                local pass_c="$C_GREEN" agent_c="$C_DIM" hosts_c="$C_CYAN"
                [[ "${PASSES[$i]}" == "no" ]] && pass_c="$C_YELLOW"
                [[ "${PASSES[$i]}" == "?" ]] && pass_c="$C_RED"
                [[ "${AGENTS[$i]}" == "yes" ]] && agent_c="$C_GREEN"
                [[ -z "${HOSTS[$i]}" ]] && hosts_c="$C_DIM"
                printf '  %-24s %-8s %s%-5s%s %s%-5s%s %s%-24s%s %s%-s%s\n' \
                    "$name" "${TYPES[$i]}" \
                    "$pass_c" "${PASSES[$i]}" "$C_RESET" \
                    "$agent_c" "${AGENTS[$i]}" "$C_RESET" \
                    "$hosts_c" "$hosts" "$C_RESET" \
                    "$C_DIM" "$comment" "$C_RESET"
            fi
        done
    fi

    printf '\n'
    rule
    printf '%s j/k move  enter details  y copy pubkey  t test  + agent  r refresh  q quit%s\n' "$C_DIM" "$C_RESET"
    printf '%s c create  m rename  e comment  p passphrase  d delete%s\n' "$C_DIM" "$C_RESET"
    if (( count > 0 )); then
        printf ' %s%d/%d keys%s' "$C_DIM" "$((CURSOR+1))" "$count" "$C_RESET"
    fi
    if [[ -n "$STATUS" ]]; then
        printf '   %s%s%s' "$STATUS_COLOR" "$STATUS" "$C_RESET"
    fi
    printf '\n'
}

field() {
    printf '  %s%-12s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"
}

show_details() {
    need_key || return
    local i=$CURSOR name f mode pass hosts h resolved key
    name="${NAMES[$i]}"
    f="$SSH_DIR/$name"
    mode=$(file_mode "$f")

    tput cup 0 0
    tput ed
    printf '%s%s%s%s\n' "$C_BOLD" "$C_CYAN" "$name" "$C_RESET"
    rule
    field "Private key" "$(display_path "$f")  (mode $mode)"
    if [[ -f "$f.pub" ]]; then
        field "Public key" "$(display_path "$f.pub")"
    else
        field "Public key" "${C_YELLOW}missing - recreate: ssh-keygen -y -f $(display_path "$f") > $(display_path "$f").pub${C_RESET}"
    fi
    field "Type" "${TYPES[$i]}, ${BITS[$i]} bits"
    field "Fingerprint" "${FPRINTS[$i]}"
    field "Comment" "${COMMENTS[$i]}"
    case "${PASSES[$i]}" in
        yes) pass="yes" ;;
        no)  pass="${C_YELLOW}no - anyone with the file can use it (p to add one)${C_RESET}" ;;
        *)   pass="${C_RED}unknown - permissions too open, ssh will refuse it: chmod 600 $(display_path "$f")${C_RESET}" ;;
    esac
    field "Passphrase" "$pass"
    field "In agent" "${AGENTS[$i]}"
    field "Modified" "$(file_date "$f")"
    if [[ -z "${HOSTS[$i]}" ]]; then
        field "Used by" "${C_DIM}not referenced in $(display_path "$SSH_CONFIG")${C_RESET}"
    else
        field "Used by" "${HOSTS[$i]}"
        hosts=$(testable_hosts "$i")
        for h in $hosts; do
            resolved=$(resolve_host "$h")
            set -- $resolved
            field "" "$h -> $1@$2:$3"
        done
    fi

    if [[ -f "$f.pub" ]]; then
        printf '\n%sPublic key:%s\n%s\n' "$C_BOLD" "$C_RESET" "$(cat "$f.pub")"
    fi

    printf '\n'
    rule
    printf '%s y copy pubkey  t test  any other key back%s\n' "$C_DIM" "$C_RESET"
    key=$(read_key)
    case "$key" in
        y|Y) copy_pubkey ;;
        t|T) test_key ;;
    esac
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

prompt_line() {
    # Print a prompt on its own clean line at the bottom and read one line.
    # Everything visible is written straight to /dev/tty, never to stdout -
    # this function is called as `reply=$(prompt_line ...)`, and any printf
    # to stdout here would be captured into $reply instead of shown.
    local prompt="$1" reply
    cooked_mode
    printf '\n%s%s%s' "$C_YELLOW" "$prompt" "$C_RESET" >/dev/tty
    read -r reply </dev/tty
    raw_mode
    printf '%s' "$reply"
}

pause() {
    printf '\n%s%s%s' "$C_DIM" "${1:-Press any key to return...}" "$C_RESET"
    raw_mode
    read_key >/dev/null
}

# Hand the terminal back in normal mode and run "$@" - for ssh-keygen and
# ssh-add, which read passphrases from the tty. Pauses only on failure so
# the error stays readable.
run_interactive() {
    local rc
    cooked_mode
    tput clear
    printf '%s$ %s%s\n\n' "$C_DIM" "$*" "$C_RESET"
    "$@"
    rc=$?
    if (( rc != 0 )); then
        pause "${C_RED}Command failed (exit $rc).${C_RESET}${C_DIM} Press any key to return...${C_RESET}"
    fi
    raw_mode
    return $rc
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

copy_pubkey() {
    need_key || return
    local name="${NAMES[$CURSOR]}"
    if [[ ! -f "$SSH_DIR/$name.pub" ]]; then
        fail "No ${name}.pub - see details (enter) for how to recreate it."
    elif copy_to_clipboard < "$SSH_DIR/$name.pub"; then
        ok "Copied ${name}.pub to clipboard."
    else
        fail "No clipboard tool found (pbcopy / wl-copy / xclip)."
    fi
}

create_key() {
    local type purpose name f comment default_comment alias hn user extra_msg=""
    local -a bits_opt=()

    type=$(prompt_line "Key type [ed25519] / rsa / ecdsa: ")
    type=${type:-ed25519}
    case "$type" in
        ed25519|ecdsa) ;;
        rsa) bits_opt=(-b 4096) ;;
        *) fail "Unsupported key type: $type"; return ;;
    esac

    purpose=$(prompt_line "What is it for? (e.g. github, ktt_qa) - file becomes id_${type}_<this>: ")
    [[ -z "$purpose" ]] && { fail "Cancelled."; return; }
    case "$purpose" in
        id_*) name="$purpose" ;;
        *)    name="id_${type}_${purpose}" ;;
    esac
    valid_name "$name" || { fail "Invalid name '${name}': use letters, digits, . _ -"; return; }
    key_exists "$name" && { fail "${name} already exists - refusing to overwrite it."; return; }
    f="$SSH_DIR/$name"

    default_comment="$(git config --global user.email 2>/dev/null || echo "$(whoami)@$(hostname -s)") ${purpose}"
    comment=$(prompt_line "Comment [${default_comment}]: ")
    comment=${comment:-$default_comment}

    run_interactive ssh-keygen -t "$type" "${bits_opt[@]}" -C "$comment" -f "$f" || {
        fail "ssh-keygen failed - no key created."
        gather_keys
        return
    }

    alias=$(prompt_line "Add a Host entry to $(display_path "$SSH_CONFIG")? Host alias (blank to skip): ")
    if [[ -n "$alias" ]]; then
        if host_defined "$alias"; then
            extra_msg=" Host ${alias} already exists in config - point its IdentityFile at ${name} yourself."
        else
            hn=$(prompt_line "HostName [${alias}]: ")
            hn=${hn:-$alias}
            user=$(prompt_line "User (blank for default): ")
            backup_config
            [[ -f "$SSH_CONFIG" ]] || { : > "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"; }
            {
                printf '\nHost %s\n  HostName %s\n' "$alias" "$hn"
                [[ -n "$user" ]] && printf '  User %s\n' "$user"
                printf '  IdentityFile %s\n' "$(display_path "$f")"
            } >> "$SSH_CONFIG"
            extra_msg=" Added Host ${alias} to config."
        fi
    fi

    gather_keys
    select_by_name "$name"
    if [[ -f "$f.pub" ]] && copy_to_clipboard < "$f.pub"; then
        ok "Created ${name}; public key copied to clipboard.${extra_msg}"
    else
        ok "Created ${name}.${extra_msg}"
    fi
}

rename_key() {
    need_key || return
    local old="${NAMES[$CURSOR]}" new n
    new=$(prompt_line "Rename ${old} to: ")
    [[ -z "$new" || "$new" == "$old" ]] && { fail "Cancelled."; return; }
    valid_name "$new" || { fail "Invalid name '${new}': use letters, digits, . _ -"; return; }
    key_exists "$new" && { fail "${new} already exists - refusing to overwrite it."; return; }

    mv "$SSH_DIR/$old" "$SSH_DIR/$new" || { fail "Rename failed."; return; }
    [[ -f "$SSH_DIR/$old.pub" ]] && mv "$SSH_DIR/$old.pub" "$SSH_DIR/$new.pub"
    n=$(rewrite_identity "$SSH_DIR/$old" "$SSH_DIR/$new")

    gather_keys
    select_by_name "$new"
    if (( n > 0 )); then
        ok "Renamed ${old} -> ${new}; updated ${n} IdentityFile line(s) (config backup in $(display_path "$STATE_DIR")/backups)."
    else
        ok "Renamed ${old} -> ${new}."
    fi
}

edit_comment() {
    need_key || return
    local name="${NAMES[$CURSOR]}" c
    c=$(prompt_line "New comment for ${name} [${COMMENTS[$CURSOR]}]: ")
    [[ -z "$c" ]] && { fail "Cancelled."; return; }
    if run_interactive ssh-keygen -c -C "$c" -f "$SSH_DIR/$name"; then
        ok "Comment updated."
    else
        fail "Comment not changed."
    fi
    gather_keys
    select_by_name "$name"
}

change_passphrase() {
    need_key || return
    local name="${NAMES[$CURSOR]}"
    if run_interactive ssh-keygen -p -f "$SSH_DIR/$name"; then
        ok "Passphrase updated for ${name}."
    else
        fail "Passphrase not changed."
    fi
    gather_keys
    select_by_name "$name"
}

toggle_agent() {
    need_key || return
    local name="${NAMES[$CURSOR]}" f="$SSH_DIR/${NAMES[$CURSOR]}"
    ssh-add -l >/dev/null 2>&1
    if (( $? == 2 )); then
        fail "No ssh-agent is running."
        return
    fi
    if [[ "${AGENTS[$CURSOR]}" == "yes" ]]; then
        run_interactive ssh-add -d "$f" && ok "Removed ${name} from the agent." || fail "Could not remove ${name} from the agent."
    elif (( IS_MAC )); then
        run_interactive ssh-add --apple-use-keychain "$f" && ok "Added ${name} to the agent (passphrase saved in Keychain)." || fail "Could not add ${name}."
    else
        run_interactive ssh-add "$f" && ok "Added ${name} to the agent." || fail "Could not add ${name}."
    fi
    gather_keys
    select_by_name "$name"
}

test_key() {
    need_key || return
    local i=$CURSOR name="${NAMES[$CURSOR]}" f="$SSH_DIR/${NAMES[$CURSOR]}"
    local targets t resolved user host port out rc
    local -a remote_cmd

    targets=$(testable_hosts "$i")
    if [[ -z "$targets" ]]; then
        t=$(prompt_line "No ssh config host uses ${name}. Test against [git@github.com]: ")
        targets=${t:-git@github.com}
    fi

    cooked_mode
    tput clear
    printf '%sTesting %s%s %s(%s)%s\n\n' "$C_BOLD" "$name" "$C_RESET" "$C_DIM" "${FPRINTS[$i]}" "$C_RESET"

    for t in $targets; do
        resolved=$(resolve_host "$t")
        set -- $resolved
        user=$1; host=$2; port=$3
        printf '  %s -> %s@%s:%s ... ' "$t" "$user" "$host" "$port"

        # Git hosts reject commands but still say who you are; servers
        # get a no-op command so a shell login doesn't open.
        case "$host" in
            github.com|ssh.github.com|gitlab.com|bitbucket.org) remote_cmd=() ;;
            *) remote_cmd=(exit 0) ;;
        esac
        # -F /dev/null + IdentitiesOnly: offer this key and nothing else,
        # so a different key in the config or agent can't mask a failure.
        out=$(ssh -F /dev/null -T -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes \
                  -i "$f" -p "$port" "$user@$host" "${remote_cmd[@]}" 2>&1 </dev/null)
        rc=$?
        if (( rc == 0 )) || grep -qiE 'successfully authenticated|welcome to gitlab|authenticated via' <<< "$out"; then
            printf '%sOK%s\n' "$C_GREEN" "$C_RESET"
        else
            printf '%sFAILED%s\n' "$C_RED" "$C_RESET"
        fi
        [[ -n "$out" ]] && printf '     %s%s%s\n' "$C_DIM" "$(printf '%s' "$out" | tail -1)" "$C_RESET"
    done

    if [[ "${PASSES[$i]}" == "yes" && "${AGENTS[$i]}" == "no" ]]; then
        printf '\n  %sThis key has a passphrase and is not in the agent, so the test could not unlock it.\n  Press + to load it into the agent, then test again.%s\n' "$C_YELLOW" "$C_RESET"
    fi
    pause
    STATUS=""
}

delete_key() {
    need_key || return
    local i=$CURSOR name="${NAMES[$CURSOR]}" reply dest
    printf '\n%sAbout to delete:%s %s%s%s  %s %s\n' \
        "$C_RED" "$C_RESET" "$C_BOLD" "$name" "$C_RESET" "${TYPES[$i]}" "${FPRINTS[$i]}"
    if [[ -n "${HOSTS[$i]}" ]]; then
        printf '   %sUsed by ssh config hosts: %s - those logins will stop working.%s\n' \
            "$C_YELLOW" "${HOSTS[$i]}" "$C_RESET"
    fi
    printf '   %sFiles are moved to %s/trash, not erased. Remember to also remove\n   the public key from GitHub / servers it was registered on.%s\n' \
        "$C_DIM" "$(display_path "$STATE_DIR")" "$C_RESET"

    reply=$(prompt_line "Type the key name to confirm: ")
    printf '\n'
    if [[ "$reply" != "$name" ]]; then
        fail "Cancelled (name did not match)."
        return
    fi

    dest="$STATE_DIR/trash/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dest" && chmod 700 "$STATE_DIR" "$STATE_DIR/trash" "$dest"
    if [[ "${AGENTS[$i]}" == "yes" && "${HASPUB[$i]}" == "1" ]]; then
        ssh-add -d "$SSH_DIR/$name" >/dev/null 2>&1 </dev/null
    fi
    mv "$SSH_DIR/$name" "$dest/" || { fail "Delete failed."; return; }
    [[ -f "$SSH_DIR/$name.pub" ]] && mv "$SSH_DIR/$name.pub" "$dest/"

    gather_keys
    ok "Moved ${name} to $(display_path "$dest") (mv it back to restore)."
}

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

read_key() {
    local key rest
    IFS= read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.02 rest
        key="${key}${rest}"
    fi
    printf '%s' "$key"
}

main_loop() {
    local key
    while true; do
        draw
        key=$(read_key)
        STATUS=""
        case "$key" in
            $'\x1b[A'|k|K) (( CURSOR > 0 )) && CURSOR=$((CURSOR - 1)) ;;
            $'\x1b[B'|j|J) (( CURSOR < ${#NAMES[@]} - 1 )) && CURSOR=$((CURSOR + 1)) ;;
            ''|$'\n'|$'\r') show_details ;;
            y|Y) copy_pubkey ;;
            t|T) test_key ;;
            +|a|A) toggle_agent ;;
            c|C) create_key ;;
            m|M) rename_key ;;
            e|E) edit_comment ;;
            p|P) change_passphrase ;;
            d|D) delete_key ;;
            r|R)
                gather_keys
                ok "Refreshed."
                ;;
            q|Q|$'\x1b')
                break
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Non-interactive listing
# ---------------------------------------------------------------------------

print_list() {
    gather_keys
    local i
    printf '%-24s %-8s %-5s %-5s %-51s %-28s %s\n' "NAME" "TYPE" "PASS" "AGENT" "FINGERPRINT" "USED BY" "COMMENT"
    for ((i = 0; i < ${#NAMES[@]}; i++)); do
        printf '%-24s %-8s %-5s %-5s %-51s %-28s %s\n' \
            "${NAMES[$i]}" "${TYPES[$i]}" "${PASSES[$i]}" "${AGENTS[$i]}" \
            "${FPRINTS[$i]}" "${HOSTS[$i]:--}" "${COMMENTS[$i]}"
    done
}

usage() {
    cat <<EOF
sshkeys - view and manage the SSH keys in $(display_path "$SSH_DIR")

Usage:
  sshkeys          Interactive view (create, rename, comment, passphrase,
                   agent, test, delete)
  sshkeys ls       Plain list, for scripts and quick checks
  sshkeys help     Show this help

Set SSHKEYS_DIR to manage a directory other than ~/.ssh.
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "sshkeys: this tool requires 'ssh-keygen', which was not found on PATH." >&2
    exit 1
fi
if [[ ! -d "$SSH_DIR" ]]; then
    echo "sshkeys: $SSH_DIR does not exist." >&2
    exit 1
fi

case "${1:-}" in
    "") ;;
    ls|list) print_list; exit 0 ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if [[ ! -t 0 || ! -t 1 ]]; then
    echo "sshkeys: interactive mode needs a terminal - use 'sshkeys ls' instead." >&2
    exit 1
fi

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

ORIG_STTY=$(stty -g)
tput civis
stty -echo -icanon min 1 time 0

gather_keys
main_loop
