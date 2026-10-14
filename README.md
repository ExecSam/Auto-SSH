# AutoSSH

Give AI agents SSH access to a machine in one step. You run a script on the target. It prints a
bundle, you paste the bundle to your agent, and the agent can then `ssh <alias>` to pull, redeploy,
restart and debug.

```
target machine                          your agent (Claude Code, Codex, ...)
--------------                          ------------------------------------
autossh.sh / autossh.ps1                pastes the bundle's install block
  - asks for the SSH address              - ~/.ssh/autossh/<alias>.key / .conf / .known_hosts
  - creates `claude` (sudo / admin)       - "Include autossh/*.conf" in ~/.ssh/config
  - authorises a fresh ed25519 key        - installs cloudflared if needed
  - prints the Cloudflare route  ---->    - ssh <alias> whoami
  - prints the agent bundle               - saves a capability note to memory
```

## Quick start

**Linux target**, as root or with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/autossh.sh | sudo bash
```

**Windows target**, from an elevated PowerShell:

```powershell
irm https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/autossh.ps1 | iex
```

The script asks for the SSH address first and changes nothing until you confirm the plan. After that:

1. **Add the Cloudflare route it prints** in Zero Trust: Networks > Tunnels > *tunnel* > Published application routes. It looks like `ssh-cerebro.rifts.cc` > SSH > `localhost:22`.
2. **Paste the bundle to your agent.** The bundle contains the private key, so treat it like a password. It is the only copy. If you lose it, re-run the script, which rotates the key.

To save just the bundle on Linux, redirect it: `... | sudo bash > cerebro.md`. All other output goes to stderr.

## Addresses and Cloudflare Tunnels

A tunnel routes SSH by **hostname only**. Typing `ssh.rifts.cc/cerebro` or `ssh.rifts.cc:2222` can't
select a machine: SSH has no URL path, and the agent's `cloudflared` always connects on port 443.
So each machine gets its own hostname with its own published route. Type the path or port form anyway
and the script converts it: `ssh.rifts.cc/cerebro` becomes `ssh-cerebro.rifts.cc`.

- **Use `ssh-cerebro.rifts.cc`, not `cerebro.ssh.rifts.cc`.** Cloudflare's free Universal SSL only covers one subdomain level.
- **The route points at sshd on the target.** If `cloudflared` runs on the target, that's `localhost:22`. If the connector runs on another LAN box, it's `<target-ip>:22`.
- **Agents need `cloudflared` locally.** It runs as the `ProxyCommand`. The bundle's install block installs it if it's missing: winget on Windows, brew on macOS, or a user-local binary on Linux.
- **Optional hardening:**
  1. Put the hostnames behind a Cloudflare Access application with a *Service Auth* policy.
  2. Create one service token for your agents.
  3. Re-run the script with `--token-id` / `--token-secret`. The token is written into the agent's `ProxyCommand`, so without it nobody can even reach sshd.

`--direct` skips the tunnel entirely. Use it for an IP or `host:port` on your LAN or VPN.

## Agent-first enrolment: `/autossh new`

`skills/autossh/SKILL.md` is a Claude Code skill. Install it:

```powershell
# Windows
New-Item -ItemType Directory -Force ~/.claude/skills/autossh | Out-Null
irm https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/skills/autossh/SKILL.md -OutFile ~/.claude/skills/autossh/SKILL.md
```
```bash
# macOS / Linux
mkdir -p ~/.claude/skills/autossh && curl -fsSL https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/skills/autossh/SKILL.md -o ~/.claude/skills/autossh/SKILL.md
```

| Command | What it does |
|---|---|
| `/autossh new ssh.rifts.cc/cerebro` | Generates the key **on the agent's machine**, writes the config, and gives you a one-liner (`--pubkey ...`) to paste on the target. The private key never travels. |
| `/autossh add <bundle>` | Installs a bundle produced by the target script. |
| `/autossh list` | Lists the known hosts. |
| `/autossh test [alias]` | Checks connectivity and fills in OS details. |
| `/autossh remove <alias>` | Removes a host. |

The skill also tells Claude how to work on hosts: non-interactive commands, verify deploys, confirm
before destructive actions. It discovers hosts from `~/.ssh/autossh/*.conf`, so new hosts need no
extra memory edits.

## Options

| Linux (`autossh.sh`) | Windows (`autossh.ps1`) | |
|---|---|---|
| `-a, --address` | `-Address` | Tunnel hostname, or `host[:port]` with `--direct` |
| `--alias` | `-Alias` | Name agents use (`ssh <alias>`). Defaults to the address. |
| `-u, --user` | `-User` | Account agents use. Default `claude`. `root` is allowed on Linux. |
| `--direct` / `--tunnel` | `-Direct` / `-Tunnel` | Force the connection mode. Otherwise it's inferred or asked. |
| `--pubkey 'KEY'` | `-PubKey 'KEY'` | Authorise an agent's existing key instead of generating one |
| `--token-id`, `--token-secret` | `-TokenId`, `-TokenSecret` | Cloudflare Access service token |
| `--no-sudo` | | Create the account without passwordless sudo |
| `-y, --yes` | `-Yes` | Never prompt |

Re-running is safe. It replaces only the key with the same tag (`autossh:<alias>:<origin>`) and leaves everything else alone.

## What it changes on the target

**Linux:**
- Installs and starts `openssh-server` and `git` if they're missing. Supports apt, dnf/yum, zypper, pacman and apk, with systemd, OpenRC or no init.
- Creates `claude` with no password. Key login only.
- Adds `/etc/sudoers.d/autossh-claude` (NOPASSWD) and adds `claude` to the `docker` group if that group exists.
- Edits `sshd_config` only when it would otherwise block the login: an existing `AllowUsers` list, or `PermitRootLogin no` when you chose root. It backs up the file first and validates with `sshd -t`.

**Windows:**
- Installs OpenSSH Server if it's missing, and sets `sshd` to start automatically.
- Creates `claude` as a local administrator with a random, never-shown password, hidden from the sign-in screen.
- Adds the key to `C:\ProgramData\ssh\administrators_authorized_keys` with the correct ACL.
- Sets the SSH default shell to PowerShell, unless one is already configured.

## Design choices

**Why a dedicated `claude` user rather than root:**
- The agent's access is one account and one key, revocable without touching yours.
- Its actions show up as `claude` + `sudo` in the logs.
- It works where root SSH is disabled.

Passwordless sudo keeps it fully capable for deploys. Pass `--user root` if you really want root.

**Why a skill, not an MCP server:** agents that have a shell already have `ssh`. An MCP server
would only wrap `ssh` behind another process you'd have to run and maintain. The skill gives you
`/autossh new` and teaches the agent the hosts and the rules, with nothing running. An MCP would only
earn its keep for shell-less clients such as Claude Desktop chat.

## Revoking access

On the target, delete the `authorized_keys` line ending in `autossh:<alias>:...`. To remove the
account entirely, run `sudo userdel -r claude` on Linux or `Remove-LocalUser claude` on Windows.
On the agent, run `/autossh remove <alias>` or delete `~/.ssh/autossh/<alias>.*`.
