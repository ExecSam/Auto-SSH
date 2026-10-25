---
name: autossh
description: SSH access to the user's machines (servers, home lab, Macs, Windows boxes) for pulling code, redeploying sites, restarting services, reading logs and other remote work. Use whenever a task touches a remote machine or a deployment, or when the user runs /autossh (add | new | list | test | remove) or pastes an "AutoSSH bundle".
---

# AutoSSH

Every host lives in `~/.ssh/autossh/`: `<alias>.conf`, `<alias>.key` and `<alias>.known_hosts`.
`~/.ssh/config` pulls them in with `Include autossh/*.conf` on its first line. The first line of
each `.conf` holds the metadata:

```
# autossh: alias=cerebro os="Ubuntu 24.04.1 LTS" arch=x86_64 user=claude access="passwordless sudo" shell=bash via=cloudflare-tunnel added=2026-10-14
```

Hosts reached `via=cloudflare-tunnel` connect through a `ProxyCommand cloudflared access ssh ...`.
That needs `cloudflared` installed locally, but nothing else.

## Working on a host

- **Find hosts:** `grep -h '^# autossh:' ~/.ssh/autossh/*.conf`. In PowerShell use `Get-Content ~/.ssh/autossh/*.conf | Select-String '^# autossh:'`.
- **Run commands:** use `ssh <alias> '<command>'`. The config already sets the key, user, proxy, `BatchMode` and a pinned host key. Never add `-o StrictHostKeyChecking=no` or similar. A host key mismatch is a real problem to report, not to bypass.
- **Linux and macOS hosts:** the shell is bash and `sudo` needs no password. For multi-line work use `ssh <alias> 'bash -s' <<'EOF' ... EOF`.
- **macOS hosts:** `ssh <alias> '<command>'` gets a minimal PATH, so call Homebrew tools by full path (`/opt/homebrew/bin` or `/usr/local/bin`).
- **Windows hosts:** commands run in PowerShell, so use Windows paths and separate statements with `;`. For anything long, `scp` a `.ps1` over and run it.
- **Files:** use `scp file <alias>:path`, or `rsync -az -e ssh dir/ <alias>:path/` where rsync exists on both ends.
- **Long-running processes** belong under systemd (launchd on macOS), docker or `nohup`, never in an open SSH session.
- **Deploying a site:**
  1. Look first: `git status`, `git log -1`, and how the site actually runs (systemd unit, docker compose, pm2, IIS).
  2. Pull, build and restart.
  3. Verify with curl on the site or its health endpoint, and check the service logs.
  4. Report what changed.
- **Git credentials:** if a pull needs credentials the host doesn't have, ask the user for a deploy key or token. Don't copy your own keys to the host.
- **Confirm first** with the user before destructive or irreversible actions: deleting data, dropping databases, force-pushing, rebooting a production host.

## /autossh commands

`$ARGUMENTS` holds the subcommand and its arguments.

### add `<bundle>`

The user pasted a bundle produced by `autossh.sh` or `autossh.ps1` on a target machine.
1. Run the bundle's install block for this OS. On Windows that is the **PowerShell** block, even when your shell is Git Bash.
2. The block ends with `ssh <alias> whoami`, which must print the remote user.
3. The bundle contains a private key, so don't echo it back or save it anywhere except the files the block writes.

### new `<address> [alias] [--token-id ID --token-secret SECRET]`

Enrol a machine *agent-first*: the key is generated here and the private key never leaves this machine.

1. **Normalise the address.** Cloudflare Tunnels route SSH by hostname only.
   - `ssh.rifts.cc/cerebro` and `ssh.rifts.cc:cerebro` both become `ssh-cerebro.rifts.cc`: join the first label and the name with `-`, then add the rest of the domain.
   - A hostname with no IP and no numeric port is a tunnel host.
   - An IP or `host:port` is direct SSH.
   - The alias defaults to the hostname's first label minus a leading `ssh-`.
   - If the hostname is a 2nd-level subdomain like `cerebro.ssh.rifts.cc`, warn the user. Cloudflare's free Universal SSL won't cover it.
2. **Generate the key.** Do this in PowerShell on Windows, so file ACLs suit Windows OpenSSH.
   - bash:
     ```bash
     mkdir -p ~/.ssh/autossh && chmod 700 ~/.ssh ~/.ssh/autossh
     ssh-keygen -q -t ed25519 -N '' -C "autossh:<alias>:$(hostname -s)" -f ~/.ssh/autossh/<alias>.key
     ```
   - PowerShell:
     ```powershell
     $d = "$HOME\.ssh\autossh"; New-Item -ItemType Directory -Force $d | Out-Null
     Start-Process ssh-keygen -ArgumentList "-q -t ed25519 -N `"`" -C autossh:<alias>:$env:COMPUTERNAME -f `"$d\<alias>.key`"" -Wait -NoNewWindow
     ```
     `Start-Process` keeps the empty passphrase intact. Don't pass `-N ""` directly from PowerShell.
3. **Write `~/.ssh/autossh/<alias>.conf`.**
   - Use UTF-8 without a BOM and LF line endings. In PowerShell that means `[IO.File]::WriteAllText`.
   - Leave out the `ProxyCommand` line for direct hosts. Add `Port N` for a direct host on a non-22 port.
   - For `CLOUDFLARED`, use the full path of `cloudflared`. On Windows, wrap it in double quotes and use forward slashes, e.g. `"C:/Program Files (x86)/cloudflared/cloudflared.exe"`. If `cloudflared` is missing, install it: `winget install --id Cloudflare.cloudflared -e`, `brew install cloudflared`, or the Linux binary from the GitHub releases.
   ```
   # autossh: alias=<alias> os=unknown user=claude via=cloudflare-tunnel added=<YYYY-MM-DD>
   Host <alias>
     HostName <hostname>
     User claude
     IdentityFile ~/.ssh/autossh/<alias>.key
     IdentitiesOnly yes
     HostKeyAlias <alias>
     UserKnownHostsFile ~/.ssh/autossh/<alias>.known_hosts
     StrictHostKeyChecking accept-new
     BatchMode yes
     ConnectTimeout 30
     ServerAliveInterval 30
     ProxyCommand CLOUDFLARED access ssh --hostname %h [--id ID --secret SECRET]
   ```
4. **Add the include line.** Make sure `~/.ssh/config` starts with `Include autossh/*.conf`. Prepend it if it's missing, and keep the rest of the file untouched.
5. **Give the user the command to run on the target.** Fill in the public key from `<alias>.key.pub`. Add `--tunnel` / `-Tunnel` for tunnel hosts and `--direct` / `-Direct` for direct ones.
   - Linux or macOS target:
     ```
     curl -fsSL https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/autossh.sh | sudo bash -s -- --address <hostname> --alias <alias> --tunnel --pubkey '<public key line>'
     ```
   - Windows target, from an elevated PowerShell:
     ```
     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/autossh.ps1))) -Address <hostname> -Alias <alias> -Tunnel -PubKey '<public key line>'
     ```
   - For tunnel hosts, the target prints the Cloudflare route the user needs to add.
6. **When the user says it's done, run `test <alias>`.** If they paste the target's known_hosts lines, write those to `<alias>.known_hosts` first.

### list

Print one line per host from the metadata lines: alias, OS, user, via, added.

### test `[alias]`

Leave out the alias to test every host. For each one:
1. Run `ssh <alias> whoami`.
2. If the metadata says `os=unknown`, look the OS up and rewrite the metadata line. On Linux run `ssh <alias> '. /etc/os-release; echo "$PRETTY_NAME|$(uname -m)|$SHELL"'`. On macOS (`ssh <alias> uname -s` prints `Darwin`) run `ssh <alias> 'echo "macOS $(sw_vers -productVersion)|$(uname -m)|$SHELL"'`. On Windows run `ssh <alias> '(Get-CimInstance Win32_OperatingSystem).Caption'`.
3. Read failures from `ssh -v <alias> whoami`:
   - `websocket: bad handshake` or `dial tcp` means a Cloudflare route or DNS problem.
   - `Permission denied (publickey)` means the key isn't authorised on the target.
   - `REMOTE HOST IDENTIFICATION HAS CHANGED` means stop and tell the user.

### remove `<alias>`

1. Delete `~/.ssh/autossh/<alias>.*`.
2. Tell the user to revoke the key on the target: delete the `authorized_keys` line ending in `autossh:<alias>:...`. On Windows that line is in `C:\ProgramData\ssh\administrators_authorized_keys`.
3. To drop the account entirely: `sudo userdel -r claude` on Linux, `sudo dscl . -delete /Users/claude && sudo rm -rf /Users/claude` on macOS, `Remove-LocalUser claude` on Windows.
