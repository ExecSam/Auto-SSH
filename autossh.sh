#!/usr/bin/env bash
# AutoSSH (Linux / macOS target) - give AI agents SSH access to this machine.
#
# Creates/uses an agent account, authorises a key, and prints a bundle you paste
# to an agent so it can install the key + ssh config and start using the host.
#
#   curl -fsSL https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/autossh.sh | sudo bash
#   sudo bash autossh.sh --address ssh-cerebro.rifts.cc        (all options: --help)
#
# The bundle goes to stdout and everything else to stderr, so
# `sudo bash autossh.sh > cerebro.md` saves just the bundle.
# Keep it working on bash 3.2 (macOS's /bin/bash): no ${x,,}, no heredocs inside $(...).
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

ADDRESS='' ALIAS='' SSH_USER='' MODE='' PUBKEY='' TOKEN_ID='' TOKEN_SECRET='' YES=0 SUDO=1

usage() {
  cat <<'EOF'
Usage: sudo bash autossh.sh [options]
  -a, --address HOST     Tunnel hostname (ssh-cerebro.rifts.cc), or host[:port] with --direct
      --alias NAME       Name agents use: ssh NAME                (default: from address)
  -u, --user NAME        Account agents log in as                 (default: claude; root allowed)
      --direct           Plain SSH to the address, no Cloudflare Tunnel
      --pubkey 'KEY'     Authorise an agent's existing public key (from /autossh new)
                         instead of generating a keypair here
      --token-id ID      Cloudflare Access service token, if the hostname is behind Access
      --token-secret S
      --no-sudo          Don't grant passwordless sudo
  -y, --yes              Never prompt; defaults for anything not given
EOF
}

die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mNote:\033[0m %s\n' "$*" >&2; }
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'; }

have_tty() { { : </dev/tty; } 2>/dev/null; }

# ask VAR "prompt" [default] [secret]
ask() {
  local __ans='' __def=${3-}
  if [[ $YES -eq 0 ]]; then
    have_tty || die "No terminal to prompt on - pass options instead (see --help)."
    local __p="$2"; [[ -n $__def ]] && __p+=" [$__def]"
    if [[ ${4-} == secret ]]; then read -rs -p "$__p: " __ans </dev/tty; echo >&2
    else read -r -p "$__p: " __ans </dev/tty; fi
  fi
  printf -v "$1" '%s' "${__ans:-$__def}"
}

# yesno "question" default(y|n) -> 0 for yes
yesno() {
  local a; ask a "$1 [$( [[ $2 == y ]] && echo Y/n || echo y/N )]" ''
  a=${a:-$2}; [[ $a == [yY]* ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -a|--address)   ADDRESS=${2:?$1 needs a value}; shift 2 ;;
      --alias)        ALIAS=${2:?$1 needs a value}; shift 2 ;;
      -u|--user)      SSH_USER=${2:?$1 needs a value}; shift 2 ;;
      --direct)       MODE=direct; shift ;;
      --tunnel)       MODE=tunnel; shift ;;
      --pubkey)       PUBKEY=${2:?$1 needs a value}; shift 2 ;;
      --token-id)     TOKEN_ID=${2:?$1 needs a value}; shift 2 ;;
      --token-secret) TOKEN_SECRET=${2:?$1 needs a value}; shift 2 ;;
      --no-sudo)      SUDO=0; shift ;;
      -y|--yes)       YES=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

detect_platform() {
  OS=$(uname -s)
  [[ $OS == Linux || $OS == Darwin ]] || die "This is the Linux / macOS script. On Windows run autossh.ps1."
  [[ $EUID -eq 0 ]] || die "Run as root, e.g.  curl -fsSL <url>/autossh.sh | sudo bash"
  OS_NAME=Linux
  if [[ $OS == Darwin ]]; then OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || true)"
  elif [[ -r /etc/os-release ]]; then OS_NAME=$(. /etc/os-release; echo "${PRETTY_NAME:-$NAME}"); fi
  OS_NAME=$(printf '%s' "$OS_NAME" | tr -d '"$`\\')
  ARCH=$(uname -m)
  MACHINE=$(scutil --get LocalHostName 2>/dev/null || hostname 2>/dev/null || uname -n); MACHINE=$(slug "${MACHINE%%.*}")
  PM=''
  for p in apt-get dnf yum zypper pacman apk; do
    if command -v "$p" >/dev/null 2>&1; then PM=$p; break; fi
  done
  INIT=none
  if [[ $OS == Darwin ]]; then INIT=launchd
  elif [[ -d /run/systemd/system ]]; then INIT=systemd
  elif command -v rc-service >/dev/null 2>&1; then INIT=openrc; fi
}

# macOS keeps accounts in Directory Services, not /etc/passwd or /etc/group, and has no getent.
# passwd_field USER home|shell
passwd_field() {
  if [[ $OS == Darwin ]]; then
    local k=NFSHomeDirectory; [[ $2 == shell ]] && k=UserShell
    dscl . -read "/Users/$1" "$k" 2>/dev/null | sed -n "s/^$k: //p; s/^ //p"
  else
    local f=6; [[ $2 == shell ]] && f=7
    (getent passwd "$1" 2>/dev/null || grep "^$1:" /etc/passwd) | cut -d: -f"$f"
  fi
}

group_exists() {
  if [[ $OS == Darwin ]]; then dscl . -read "/Groups/$1" >/dev/null 2>&1; else grep -q "^$1:" /etc/group; fi
}

# add_to_group USER GROUP
add_to_group() {
  if [[ $OS == Darwin ]]; then dseditgroup -o edit -a "$1" -t user "$2"
  elif command -v usermod >/dev/null 2>&1; then usermod -aG "$2" "$1"
  else addgroup "$1" "$2"; fi
}

remote_login_on() { launchctl print system/com.openssh.sshd >/dev/null 2>&1; }

pkg_install() {
  info "Installing $*"
  case $PM in
    apt-get) export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq "$@" >/dev/null ;;
    dnf|yum) "$PM" install -y -q "$@" >/dev/null ;;
    zypper)  zypper -q -n install "$@" >/dev/null ;;
    pacman)  pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
    apk)     apk add -q "$@" >/dev/null ;;
    *)       die "No supported package manager found - install $* manually and re-run." ;;
  esac
}

collect_inputs() {
  if [[ -z $ADDRESS ]]; then
    printf '\nAutoSSH - %s (%s)\n\n' "$MACHINE" "$OS_NAME" >&2
    ask ADDRESS "SSH address agents will use (e.g. ssh-$MACHINE.rifts.cc)"
  fi
  [[ -n $ADDRESS ]] || die "An SSH address is required."

  local a host name='' port=''
  a=$(printf '%s' "$ADDRESS" | tr '[:upper:]' '[:lower:]')
  a=${a#ssh://}; a=${a#https://}; a=${a#http://}; a=${a#*@}; a=${a%/}
  host=$a
  if [[ $host == */* ]]; then name=${host#*/}; name=${name%%/*}; host=${host%%/*}; fi
  if [[ $host =~ ^(.+):([^:]+)$ ]]; then
    host=${BASH_REMATCH[1]}; local suffix=${BASH_REMATCH[2]}
    if [[ $suffix =~ ^[0-9]+$ ]]; then port=$suffix; else name=$suffix; fi
  fi
  local is_ip=0; [[ $host =~ ^[0-9.]+$ ]] && is_ip=1

  if [[ -z $MODE ]]; then
    if [[ -n $name ]]; then MODE=tunnel
    elif [[ $is_ip -eq 1 ]]; then MODE=direct
    elif yesno "Is $host reached through a Cloudflare Tunnel?" y; then MODE=tunnel
    else MODE=direct; fi
  fi

  if [[ $MODE == tunnel ]]; then
    [[ $is_ip -eq 0 ]] || die "A Cloudflare Tunnel needs a hostname, not an IP. Use --direct for IPs."
    if [[ -n $name || -n $port ]]; then
      name=$(slug "${name:-$MACHINE}")
      local suggested labels
      IFS=. read -ra labels <<<"$host"
      if (( ${#labels[@]} >= 3 )); then suggested="${labels[0]}-$name.${host#*.}"
      else suggested="ssh-$name.$host"; fi
      warn "A Cloudflare Tunnel routes SSH by hostname only - a URL path or port can't pick a machine,"
      warn "so each machine gets its own hostname (one published application route each)."
      ask host "Tunnel hostname for this machine" "$suggested"
      host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    fi
    port=''
    [[ $host =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "'$host' isn't a full hostname (e.g. ssh-$MACHINE.rifts.cc)."
    local n; n=$(awk -F. '{print NF}' <<<"$host")
    if (( n >= 4 )); then
      warn "$host is a 2nd-level subdomain. Cloudflare's free Universal SSL only covers *.${host#*.*.};"
      warn "unless you have Advanced Certificate Manager, use something like ssh-${host%%.*}.${host#*.*.} instead."
    fi
  fi
  HOST=$host PORT=$port

  if [[ -z $ALIAS ]]; then
    local def=$MACHINE
    if [[ $is_ip -eq 0 ]]; then
      def=${HOST%%.*}; def=${def#ssh-}; def=${def%-ssh}
      [[ $def == ssh || -z $def ]] && def=$MACHINE
    fi
    ask ALIAS "Alias agents will use (ssh <alias>)" "$(slug "$def")"
  fi
  ALIAS=$(slug "$ALIAS"); [[ -n $ALIAS ]] || die "Invalid alias."

  [[ -n $SSH_USER ]] || ask SSH_USER "Account agents log in as (claude recommended, or root)" claude
  [[ $SSH_USER =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "Invalid user name: $SSH_USER"

  if [[ $MODE == tunnel && -z $TOKEN_ID && -z $PUBKEY && $YES -eq 0 ]]; then
    ask TOKEN_ID "Cloudflare Access service token ID, if the hostname is behind Access (Enter to skip)"
  fi
  if [[ -n $TOKEN_ID && -z $TOKEN_SECRET ]]; then ask TOKEN_SECRET "Service token secret" '' secret; fi
  [[ -z $TOKEN_ID || -n $TOKEN_SECRET ]] || die "--token-id needs --token-secret."

  if [[ -n $PUBKEY ]]; then
    read -r PK_TYPE PK_BLOB PK_COMMENT <<<"$PUBKEY"
    [[ ${PK_TYPE:-} =~ ^(ssh-|ecdsa-|sk-) && -n ${PK_BLOB:-} ]] || die "--pubkey doesn't look like an OpenSSH public key."
    if [[ ${PK_COMMENT:-} == autossh:* ]]; then TAG=$PK_COMMENT; else TAG="autossh:$ALIAS:${PK_COMMENT:-agent}"; fi
    TAG=${TAG%% *}
  else
    TAG="autossh:$ALIAS:target"
  fi
}

confirm_plan() {
  local acct key via
  if [[ $SSH_USER == root ]]; then acct="root"
  elif id -u "$SSH_USER" >/dev/null 2>&1; then acct="$SSH_USER (existing)"
  else acct="$SSH_USER (new)"; fi
  [[ $SSH_USER != root && $SUDO -eq 1 ]] && acct+=", passwordless sudo"
  if [[ -n $PUBKEY ]]; then key="authorise the agent's key ($TAG)"; else key="generate a new ed25519 key ($TAG)"; fi
  if [[ $MODE == tunnel ]]; then via="$HOST via Cloudflare Tunnel"; else via="$HOST${PORT:+:$PORT} (direct)"; fi
  cat >&2 <<EOF

  Machine   $MACHINE - $OS_NAME ($ARCH)
  Address   $via
  Alias     ssh $ALIAS
  Account   $acct
  Key       $key

EOF
  if [[ $YES -eq 0 ]]; then yesno "Proceed?" y || die "Aborted - nothing was changed."; fi
}

ensure_sshd() {
  SSHD=$(command -v sshd || echo /usr/sbin/sshd)
  if [[ ! -x $SSHD ]]; then
    if [[ $PM == pacman ]]; then pkg_install openssh; else pkg_install openssh-server; fi
    SSHD=$(command -v sshd || echo /usr/sbin/sshd)
    [[ -x $SSHD ]] || die "sshd still not found after install."
  fi
  if [[ -z $PUBKEY ]] && ! command -v ssh-keygen >/dev/null 2>&1; then
    case $PM in apk) pkg_install openssh-keygen ;; apt-get) pkg_install openssh-client ;; *) pkg_install openssh-clients ;; esac
  fi
  if ! command -v git >/dev/null 2>&1 && [[ -n $PM ]]; then pkg_install git || warn "Couldn't install git."; fi
  if [[ $OS == Linux ]]; then mkdir -p /run/sshd && chmod 755 /run/sshd; fi   # privsep dir; sshd -t/-T refuse to run without it
  ssh-keygen -A >/dev/null 2>&1 || true

  case $INIT in
    launchd)
      # Remote Login. systemsetup needs Full Disk Access on newer macOS, so fall back to launchctl.
      if ! remote_login_on; then
        info "Turning on Remote Login (sshd)"
        systemsetup -setremotelogin on </dev/null >/dev/null 2>&1 || true
        remote_login_on || launchctl load -w /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1 || true
        remote_login_on || die "Couldn't turn on Remote Login - switch it on in System Settings > General > Sharing, then re-run."
      fi
      warn "Over SSH, macOS blocks Desktop, Documents, Downloads etc. unless Remote Login's"
      warn "'Allow full disk access for remote users' is on (System Settings > General > Sharing)." ;;
    systemd)
      SVC=sshd
      if [[ -n $(systemctl list-unit-files ssh.service --no-legend 2>/dev/null || true) ]]; then SVC=ssh; fi
      if ! systemctl is-active --quiet "$SVC" && ! systemctl is-active --quiet ssh.socket; then
        info "Enabling and starting $SVC"; systemctl enable --now "$SVC" >/dev/null 2>&1 || die "Couldn't start $SVC."
      fi ;;
    openrc)
      rc-update add sshd default >/dev/null 2>&1 || true
      rc-service sshd status >/dev/null 2>&1 || { info "Starting sshd"; rc-service sshd start >/dev/null; } ;;
    none)
      if [[ ! -s /run/sshd.pid && ! -s /var/run/sshd.pid ]]; then
        info "No service manager - starting sshd directly"; "$SSHD" || die "Couldn't start sshd."
        warn "Make sure sshd starts on boot on this machine."
      fi ;;
  esac
  SSHD_PORT=$("$SSHD" -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true); SSHD_PORT=${SSHD_PORT:-22}
}

ensure_user() {
  if [[ $SSH_USER != root ]] && ! id -u "$SSH_USER" >/dev/null 2>&1; then
    info "Creating user $SSH_USER"
    if [[ $OS == Darwin ]]; then
      # Next free UID from 501, where macOS starts regular accounts. Password '*' means no password
      # login, but keys still work. IsHidden keeps it off the login window and Users & Groups.
      local uid kv
      uid=$(dscl . -list /Users UniqueID | awk 'BEGIN {m = 500} $2 > m && $2 < 60000 {m = $2} END {print m + 1}')
      dscl . -create "/Users/$SSH_USER"
      for kv in "UniqueID $uid" "PrimaryGroupID 20" "UserShell /bin/bash" "RealName AutoSSH agent account" \
                "NFSHomeDirectory /Users/$SSH_USER" "Password *" "IsHidden 1"; do
        dscl . -create "/Users/$SSH_USER" "${kv%% *}" "${kv#* }"
      done
      createhomedir -c -u "$SSH_USER" >/dev/null 2>&1 || true
      if [[ ! -d /Users/$SSH_USER ]]; then mkdir -p "/Users/$SSH_USER"; chown "$SSH_USER:staff" "/Users/$SSH_USER"; fi
    else
      local sh; sh=$(command -v bash)
      if command -v useradd >/dev/null 2>&1; then useradd -m -s "$sh" -c "AutoSSH agent account" "$SSH_USER"
      else adduser -D -s "$sh" -g "AutoSSH agent account" "$SSH_USER"; fi
      # No password, but not "locked" either: a leading '!' blocks key logins when sshd has UsePAM no.
      sed -i "s/^$SSH_USER:![^:]*:/$SSH_USER:*:/" /etc/shadow
    fi
  fi
  USER_HOME=$(passwd_field "$SSH_USER" home)
  USER_GROUP=$(id -gn "$SSH_USER")
  [[ -d $USER_HOME ]] || die "Home directory for $SSH_USER not found."

  EXTRA=''
  if [[ $SSH_USER != root ]]; then
    if [[ $SUDO -eq 1 ]]; then
      command -v sudo >/dev/null 2>&1 || pkg_install sudo
      local f="/etc/sudoers.d/autossh-${SSH_USER//./_}"
      printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SSH_USER" >"$f.tmp"; chmod 440 "$f.tmp"
      visudo -cf "$f.tmp" >/dev/null || { rm -f "$f.tmp"; die "sudoers rule failed validation."; }
      mv "$f.tmp" "$f"
      if ! grep -Eq '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers.d' /etc/sudoers; then
        cp -p /etc/sudoers /etc/sudoers.autossh.bak
        echo '@includedir /etc/sudoers.d' >>/etc/sudoers
        visudo -c >/dev/null || { cp -p /etc/sudoers.autossh.bak /etc/sudoers; die "Couldn't enable /etc/sudoers.d."; }
      fi
      EXTRA="passwordless sudo"
    fi
    if group_exists docker && ! id -nG "$SSH_USER" | tr ' ' '\n' | grep -qx docker; then
      add_to_group "$SSH_USER" docker
      EXTRA+="${EXTRA:+, }docker group"
    fi
  fi
}

# Insert a directive at the very top of sshd_config (before any Include/Match, so it wins).
SSHD_CHANGED=0
sshd_prepend() {
  local cfg=/etc/ssh/sshd_config
  [[ -e $cfg.autossh.bak ]] || cp -p "$cfg" "$cfg.autossh.bak"
  cp -p "$cfg" "$TMPD/sshd_config"
  { printf '# Added by AutoSSH\n%s\n\n' "$1"; cat "$TMPD/sshd_config"; } >"$cfg"
  if ! "$SSHD" -t 2>/dev/null; then cp -p "$TMPD/sshd_config" "$cfg"; die "sshd rejected '$1' - reverted sshd_config."; fi
  info "sshd_config: added '$1' (backup: $cfg.autossh.bak)"
  SSHD_CHANGED=1
}

effective() { { "$SSHD" -T -C "user=$SSH_USER,host=localhost,addr=127.0.0.1" 2>/dev/null || true; } | awk -v k="$1" '$1==k{$1=""; print}' | xargs; }

check_sshd_access() {
  local allow groups prl
  allow=$(effective allowusers)
  if [[ -n $allow ]] && ! tr ' ' '\n' <<<"$allow" | grep -Eqx "($SSH_USER|\\*)(@.*)?"; then
    sshd_prepend "AllowUsers $SSH_USER"
  fi
  groups=$(effective allowgroups)
  if [[ -n $groups ]] && ! id -nG "$SSH_USER" | tr ' ' '\n' | grep -qxF -f <(tr ' ' '\n' <<<"$groups"); then
    local g=${groups%% *}
    if group_exists "$g"; then
      info "Adding $SSH_USER to '$g' (sshd AllowGroups)"
      add_to_group "$SSH_USER" "$g"
    else warn "sshd AllowGroups ($groups) may block $SSH_USER - check /etc/ssh/sshd_config."; fi
  fi
  if tr ' ' '\n' <<<"$(effective denyusers)" | grep -qx "$SSH_USER"; then
    warn "sshd DenyUsers lists $SSH_USER - remove it from /etc/ssh/sshd_config."
  fi
  [[ $(effective pubkeyauthentication) == no ]] && warn "sshd has PubkeyAuthentication no - key logins will fail."
  # Remote Login set to "Only these users" is enforced through this group.
  if [[ $OS == Darwin ]] && group_exists com.apple.access_ssh \
     && ! dseditgroup -o checkmember -m "$SSH_USER" com.apple.access_ssh >/dev/null 2>&1; then
    info "Adding $SSH_USER to Remote Login's allowed users"
    add_to_group "$SSH_USER" com.apple.access_ssh
  fi
  if [[ $SSH_USER == root ]]; then
    prl=$(effective permitrootlogin)
    if [[ $prl == no || $prl == forced-commands-only ]]; then sshd_prepend "PermitRootLogin prohibit-password"; fi
  fi
  if [[ $SSHD_CHANGED -eq 1 ]]; then
    case $INIT in
      systemd) systemctl reload "$SVC" 2>/dev/null || systemctl restart "$SVC" ;;
      openrc)  rc-service sshd reload >/dev/null 2>&1 || rc-service sshd restart >/dev/null ;;
      launchd) ;;   # launchd starts sshd per connection, so the next login reads the new config
      none)    kill -HUP "$(cat /run/sshd.pid 2>/dev/null || cat /var/run/sshd.pid)" 2>/dev/null || warn "Restart sshd to apply the change." ;;
    esac
  fi
}

install_key() {
  local akf ak
  akf=$(effective authorizedkeysfile); akf=${akf%% *}
  akf=${akf:-.ssh/authorized_keys}
  akf=${akf//%h/$USER_HOME}; akf=${akf//%u/$SSH_USER}; akf=${akf//%%/%}
  [[ $akf == /* ]] || akf="$USER_HOME/$akf"
  ak=$akf
  AK_PATH=$ak

  if [[ -n $PUBKEY ]]; then
    PUBLINE="$PK_TYPE $PK_BLOB $TAG"
    PRIVKEY=''
    printf '%s\n' "$PUBLINE" >"$TMPD/key.pub"
  else
    ssh-keygen -q -t ed25519 -N '' -C "$TAG" -f "$TMPD/key"
    PUBLINE=$(cat "$TMPD/key.pub"); PRIVKEY=$(cat "$TMPD/key")
  fi
  local fp; fp=$(ssh-keygen -lf "$TMPD/key.pub" 2>/dev/null) || die "Public key is not valid."
  FINGERPRINT=$(awk '{print $2}' <<<"$fp")

  local d; d=$(dirname "$ak")
  if [[ ! -d $d ]]; then mkdir -p "$d"; [[ $d == "$USER_HOME/.ssh" ]] && chown "$SSH_USER:$USER_GROUP" "$d"; fi
  [[ $d == "$USER_HOME/.ssh" ]] && chmod 700 "$d"
  touch "$ak"
  local before after
  before=$(wc -l <"$ak")
  awk -v t="$TAG" 'NF && $NF != t' "$ak" >"$ak.autossh.tmp"
  after=$(wc -l <"$ak.autossh.tmp")
  printf '%s\n' "$PUBLINE" >>"$ak.autossh.tmp"
  cat "$ak.autossh.tmp" >"$ak"; rm -f "$ak.autossh.tmp"
  chmod 600 "$ak"; chown "$SSH_USER:$USER_GROUP" "$ak"
  (( before > after )) && info "Replaced $((before - after)) earlier key(s) tagged $TAG"
  info "Authorised key $FINGERPRINT for $SSH_USER"
  if command -v restorecon >/dev/null 2>&1; then restorecon -R "$d" 2>/dev/null || true; fi
}

host_keys() {
  local f
  for f in $("$SSHD" -T 2>/dev/null | awk '$1=="hostkey"{print $2}' || true); do
    if [[ -r $f.pub ]]; then awk -v a="$ALIAS" '{print a" "$1" "$2}' "$f.pub"; fi
  done
}

lan_ip() {
  { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
    hostname -I 2>/dev/null | awk '{print $1}'
    ipconfig getifaddr "$(route -n get default 2>/dev/null | awk '$1=="interface:"{print $2; exit}')" 2>/dev/null; } | grep -m1 . || true
}

print_cloudflare() {
  local ip local_cf=0
  ip=$(lan_ip); ip=${ip:-"<LAN IP of this machine>"}
  if command -v cloudflared >/dev/null 2>&1 || pgrep -x cloudflared >/dev/null 2>&1; then local_cf=1; fi
  cat >&2 <<EOF

------------------------------------------------------------------------------
 Cloudflare Tunnel route  (Zero Trust > Networks > Tunnels > your tunnel >
                           Published application routes > Add)
   Hostname : $HOST
EOF
  if [[ $local_cf -eq 1 ]]; then
    printf '   Service  : SSH  localhost:%s      (cloudflared is on this machine)\n' "$SSHD_PORT" >&2
  else
    printf '   Service  : SSH  %s:%s   (from whichever machine runs the connector)\n' "$ip" "$SSHD_PORT" >&2
  fi
  if [[ -z $TOKEN_ID ]]; then
    cat >&2 <<'EOF'
   Optional : put the hostname behind a Cloudflare Access app with a Service Auth
              policy, then re-run with --token-id/--token-secret so only agents
              holding the token can even reach sshd.
EOF
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active' && [[ $local_cf -eq 0 ]]; then
    printf '   Firewall : ufw is active - allow port %s from the connector machine.\n' "$SSHD_PORT" >&2
  fi
  echo '------------------------------------------------------------------------------' >&2
}

render_bundle() {
  local via proxy='' portline='' shell_desc sudo_desc today
  today=$(date +%F)
  if [[ $MODE == tunnel ]]; then
    via="cloudflare-tunnel"
    proxy="  ProxyCommand CLOUDFLARED_BIN access ssh --hostname %h${TOKEN_ID:+ --id $TOKEN_ID --secret $TOKEN_SECRET}"
  else
    via="direct"
    local p=${PORT:-$SSHD_PORT}; [[ $p != 22 ]] && portline="  Port $p"
  fi
  shell_desc=$(basename "$(passwd_field "$SSH_USER" shell)")
  if [[ $SSH_USER == root ]]; then sudo_desc="root"; else sudo_desc=${EXTRA:-no sudo}; fi

  CONF="# autossh: alias=$ALIAS os=\"$OS_NAME\" arch=$ARCH user=$SSH_USER access=\"$sudo_desc\" shell=$shell_desc via=$via added=$today
Host $ALIAS
  HostName $HOST"
  [[ -n $portline ]] && CONF+=$'\n'"$portline"
  CONF+="
  User $SSH_USER
  IdentityFile ~/.ssh/autossh/$ALIAS.key
  IdentitiesOnly yes
  HostKeyAlias $ALIAS
  UserKnownHostsFile ~/.ssh/autossh/$ALIAS.known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
  ConnectTimeout 30
  ServerAliveInterval 30"
  [[ -n $proxy ]] && CONF+=$'\n'"$proxy"
  KNOWN=$(host_keys)

  local addr_desc note
  if [[ $MODE == tunnel ]]; then addr_desc="\`$HOST\` via Cloudflare Tunnel (\`cloudflared\` is installed by the block below if missing)"
  else addr_desc="\`$HOST${PORT:+:$PORT}\` (direct SSH)"; fi
  note="**SSH host \`$ALIAS\`** - $OS_NAME, remote shell $shell_desc, user \`$SSH_USER\` ($sudo_desc). Run commands with \`ssh $ALIAS '<command>'\` (config: ~/.ssh/autossh/$ALIAS.conf). Use it to pull, build, redeploy and inspect sites/services on this machine. Work non-interactively, check \`git status\` before pulling, verify deploys (e.g. curl the site) and confirm with the user before destructive or irreversible actions (deleting data, dropping databases, rebooting)."
  if [[ $OS == Darwin ]]; then note+=" It's a Mac: \`ssh $ALIAS '<command>'\` gets a minimal PATH, so call Homebrew tools by full path (/opt/homebrew/bin or /usr/local/bin)."; fi

  local cf_sh='' cf_ps=''
  if [[ $MODE == tunnel ]]; then
    cf_sh='cf=$(command -v cloudflared || true)
if [ -z "$cf" ]; then
  if command -v brew >/dev/null 2>&1; then brew install cloudflared >/dev/null && cf=$(command -v cloudflared)
  elif [ "$(uname -s)" = Linux ]; then
    case $(uname -m) in x86_64) a=amd64;; aarch64|arm64) a=arm64;; arm*) a=arm;; *) a=386;; esac
    mkdir -p "$HOME/.local/bin"; cf="$HOME/.local/bin/cloudflared"
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a" -o "$cf" && chmod 755 "$cf"
  fi
fi
[ -x "$cf" ] || { echo "Install cloudflared, then re-run: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"; exit 1; }'
    cf_ps='$cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cf) { $cf = "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe" }
if (-not (Test-Path $cf)) { winget install --id Cloudflare.cloudflared -e --silent --accept-source-agreements --accept-package-agreements | Out-Null }
if (-not (Test-Path $cf)) { throw "Install cloudflared (winget install Cloudflare.cloudflared), then re-run." }'
  else
    cf_sh='cf=unused'
    cf_ps='$cf = "unused"'
  fi

  # read -d '', not t=$(cat <<...): bash 3.2 can't parse unbalanced ( or ' in a heredoc inside $(...).
  local t
  IFS= read -r -d '' t <<'TEMPLATE' || true
<!-- AutoSSH bundle - contains a private key. Treat this whole message as a secret. -->
# SSH access: @@ALIAS@@

You (the agent) are being given SSH access to a machine. Run the install block for
your OS, check it prints the remote user, then save the note in step 3 to your memory.

- **Alias:** `@@ALIAS@@`  (`ssh @@ALIAS@@ '<command>'`)
- **Address:** @@ADDR@@
- **User:** `@@USER@@` (@@SUDO@@)
- **OS:** @@OS@@ (@@ARCH@@), remote shell: @@SHELL@@
- **Key:** ed25519 @@FP@@, host key pinned (no first-connect prompt)

## 1. Install

### Linux / macOS
```bash
( set -e; umask 077
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "On Windows use the PowerShell block."; exit 1;; esac
d="$HOME/.ssh/autossh"; mkdir -p "$d"; chmod 700 "$HOME/.ssh" "$d"
cat > "$d/@@ALIAS@@.key" <<'AUTOSSH_KEY'
@@PRIVKEY@@
AUTOSSH_KEY
cat > "$d/@@ALIAS@@.known_hosts" <<'AUTOSSH_KH'
@@KNOWN@@
AUTOSSH_KH
@@CF_SH@@
sed "s#CLOUDFLARED_BIN#$cf#" > "$d/@@ALIAS@@.conf" <<'AUTOSSH_CONF'
@@CONF@@
AUTOSSH_CONF
c="$HOME/.ssh/config"; touch "$c"; chmod 600 "$c"
grep -qxF 'Include autossh/*.conf' "$c" || { { printf 'Include autossh/*.conf\n\n'; cat "$c"; } > "$c.autossh" && cat "$c.autossh" > "$c" && rm -f "$c.autossh"; }
ssh @@ALIAS@@ whoami )
```

### Windows (PowerShell - also use this if your shell is Git Bash)
```powershell
& { $ErrorActionPreference = 'Stop'
$d = Join-Path $HOME '.ssh\autossh'; New-Item -ItemType Directory -Force $d | Out-Null
function Save($n, $t) { $p = Join-Path $d $n; [IO.File]::WriteAllText($p, ($t -replace "`r", '').Trim() + "`n"); $p }
$key = Save '@@ALIAS@@.key' @'
@@PRIVKEY@@
'@
icacls $key /inheritance:r /grant:r "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):F" | Out-Null
Save '@@ALIAS@@.known_hosts' @'
@@KNOWN@@
'@ | Out-Null
@@CF_PS@@
Save '@@ALIAS@@.conf' (@'
@@CONF@@
'@).Replace('CLOUDFLARED_BIN', '"' + ($cf -replace '\\', '/') + '"') | Out-Null
$c = Join-Path $HOME '.ssh\config'; $old = if (Test-Path $c) { [IO.File]::ReadAllText($c) } else { '' }
if ($old -notmatch '(?m)^Include autossh/\*\.conf') { [IO.File]::WriteAllText($c, "Include autossh/*.conf`n`n" + $old) }
ssh @@ALIAS@@ whoami }
```

## 2. Verify
The block ends by running `ssh @@ALIAS@@ whoami`; it should print `@@USER@@`.
If it doesn't, `ssh -v @@ALIAS@@ whoami` shows where it stops.

## 3. Remember this capability
Save this note to your persistent memory / instructions (CLAUDE.md, AGENTS.md, memory file).
Claude Code with the `autossh` skill installed finds hosts in ~/.ssh/autossh automatically.

> @@NOTE@@
TEMPLATE
  if [[ -z $PRIVKEY ]]; then
    # --pubkey mode: the agent already holds the private key; give it just the pin + note.
    IFS= read -r -d '' t <<'TEMPLATE' || true
# AutoSSH: @@ALIAS@@ is ready

Your key (@@FP@@) is authorised for `@@USER@@` on @@OS@@. To pin this machine's host key, write
these lines to `~/.ssh/autossh/@@ALIAS@@.known_hosts` (replacing any existing ones):

```
@@KNOWN@@
```

Then run `ssh @@ALIAS@@ whoami` (or `/autossh test @@ALIAS@@`). Capability note to remember:

> @@NOTE@@
TEMPLATE
  fi
  t=${t%$'\n'}
  t=${t//@@PRIVKEY@@/$PRIVKEY}; t=${t//@@KNOWN@@/$KNOWN}; t=${t//@@CONF@@/$CONF}
  t=${t//@@CF_SH@@/$cf_sh};     t=${t//@@CF_PS@@/$cf_ps}; t=${t//@@NOTE@@/$note}
  t=${t//@@ADDR@@/$addr_desc};  t=${t//@@USER@@/$SSH_USER}; t=${t//@@SUDO@@/$sudo_desc}
  t=${t//@@OS@@/$OS_NAME};      t=${t//@@ARCH@@/$ARCH};    t=${t//@@SHELL@@/$shell_desc}
  t=${t//@@FP@@/$FINGERPRINT};  t=${t//@@ALIAS@@/$ALIAS}
  printf '%s\n' "$t"
}

main() {
  parse_args "$@"
  detect_platform
  TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
  collect_inputs
  confirm_plan
  ensure_sshd
  ensure_user
  check_sshd_access
  install_key
  [[ $MODE == tunnel ]] && print_cloudflare
  if [[ -n $PRIVKEY ]]; then
    printf '\n\033[1mPaste everything below to your agent (it contains a private key - this is the only copy):\033[0m\n\n' >&2
  fi
  render_bundle
  printf '\n\033[2mRevoke later: delete the line ending in "%s" from %s\033[0m\n' "$TAG" "$AK_PATH" >&2
}

main "$@"
