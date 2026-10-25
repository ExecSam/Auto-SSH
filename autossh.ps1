<#
AutoSSH (Windows target) - give AI agents SSH access to this machine.

Installs/starts OpenSSH Server, creates/uses an agent account, authorises a key,
and prints a bundle you paste to an agent so it can install the key + ssh config.

Run from an elevated PowerShell (Windows PowerShell 5.1 or PowerShell 7):
  irm https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/autossh.ps1 | iex
With options:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ExecSam/Auto-SSH/main/autossh.ps1))) -Address ssh-cerebro.rifts.cc

  -Address    Tunnel hostname (ssh-cerebro.rifts.cc), or host[:port] with -Direct
  -Alias      Name agents use: ssh NAME                    (default: from address)
  -User       Account agents log in as                     (default: claude, local admin)
  -Direct     Plain SSH to the address, no Cloudflare Tunnel
  -PubKey     Authorise an agent's existing public key (from /autossh new) instead of generating one
  -TokenId / -TokenSecret   Cloudflare Access service token, if the hostname is behind Access
  -Yes        Never prompt; defaults for anything not given
#>
param(
    [string]$Address, [string]$Alias, [string]$User, [switch]$Direct, [switch]$Tunnel,
    [string]$PubKey, [string]$TokenId, [string]$TokenSecret, [switch]$Yes
)

& {
$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "Note: $m" -ForegroundColor Yellow }
function Slug($s) { (($s.ToLower() -replace '[^a-z0-9-]', '-') -replace '-+', '-').Trim('-') }
function Ask($prompt, $default = '') {
    if ($Yes) { return $default }
    $p = if ($default) { "$prompt [$default]" } else { $prompt }
    $a = Read-Host $p
    if ([string]::IsNullOrWhiteSpace($a)) { $default } else { $a.Trim() }
}
function YesNo($q, $def = $true) {
    $a = Ask "$q [$(if ($def) { 'Y/n' } else { 'y/N' })]"
    if (-not $a) { return $def }
    $a -match '^y'
}

# --- Platform -----------------------------------------------------------------
if ($env:OS -ne 'Windows_NT') { throw 'This is the Windows script. On Linux or macOS run autossh.sh.' }
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (Run as administrator).'
}
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$OsName = $cv.ProductName
if ([int]$cv.CurrentBuild -ge 22000) { $OsName = $OsName -replace 'Windows 10', 'Windows 11' }   # ProductName still says 10 on 11
if ($cv.DisplayVersion) { $OsName += " $($cv.DisplayVersion)" }
$Arch = $env:PROCESSOR_ARCHITECTURE
$Machine = Slug $env:COMPUTERNAME

# --- Inputs (nothing is changed until the plan is confirmed) -----------------
if (-not $Address) {
    Write-Host "`nAutoSSH - $Machine ($OsName)`n"
    $Address = Ask "SSH address agents will use (e.g. ssh-$Machine.rifts.cc)"
}
if (-not $Address) { throw 'An SSH address is required.' }

$a = $Address.Trim().ToLower() -replace '^(ssh|https?)://', '' -replace '^[^@/]*@', '' -replace '/$', ''
$HostName = $a; $name = ''; $port = ''
if ($HostName -match '^([^/]+)/([^/]+)') { $HostName = $Matches[1]; $name = $Matches[2] }
if ($HostName -match '^(.+):([^:]+)$') {
    $HostName = $Matches[1]; $suffix = $Matches[2]
    if ($suffix -match '^\d+$') { $port = $suffix } else { $name = $suffix }
}
$isIp = $HostName -match '^[\d.]+$'

$Mode = if ($Direct) { 'direct' } elseif ($Tunnel) { 'tunnel' } elseif ($name) { 'tunnel' } elseif ($isIp) { 'direct' }
        elseif (YesNo "Is $HostName reached through a Cloudflare Tunnel?") { 'tunnel' } else { 'direct' }

if ($Mode -eq 'tunnel') {
    if ($isIp) { throw 'A Cloudflare Tunnel needs a hostname, not an IP. Use -Direct for IPs.' }
    if ($name -or $port) {
        $n = Slug $(if ($name) { $name } else { $Machine })
        $labels = $HostName.Split('.')
        $suggested = if ($labels.Count -ge 3) { "$($labels[0])-$n." + ($labels[1..($labels.Count - 1)] -join '.') } else { "ssh-$n.$HostName" }
        Note "A Cloudflare Tunnel routes SSH by hostname only - a URL path or port can't pick a machine,"
        Note "so each machine gets its own hostname (one published application route each)."
        $HostName = (Ask 'Tunnel hostname for this machine' $suggested).ToLower()
    }
    $port = ''
    if ($HostName -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { throw "'$HostName' isn't a full hostname (e.g. ssh-$Machine.rifts.cc)." }
    $labels = $HostName.Split('.')
    if ($labels.Count -ge 4) {
        $base = $labels[2..($labels.Count - 1)] -join '.'
        Note "$HostName is a 2nd-level subdomain. Cloudflare's free Universal SSL only covers *.$base;"
        Note "unless you have Advanced Certificate Manager, use something like ssh-$($labels[0]).$base instead."
    }
}

if (-not $Alias) {
    $def = $Machine
    if (-not $isIp) {
        $def = ($HostName.Split('.')[0] -replace '^ssh-', '') -replace '-ssh$', ''
        if (-not $def -or $def -eq 'ssh') { $def = $Machine }
    }
    $Alias = Ask 'Alias agents will use (ssh <alias>)' (Slug $def)
}
$Alias = Slug $Alias
if (-not $Alias) { throw 'Invalid alias.' }

if (-not $User) { $User = Ask 'Account agents log in as (claude recommended)' 'claude' }
if ($User -eq 'root') { Note "Windows has no root - using a local administrator account named 'claude'."; $User = 'claude' }
if ($User -notmatch '^[A-Za-z0-9_.-]{1,20}$') { throw "Invalid user name: $User" }

if ($Mode -eq 'tunnel' -and -not $TokenId -and -not $PubKey -and -not $Yes) {
    $TokenId = Ask 'Cloudflare Access service token ID, if the hostname is behind Access (Enter to skip)'
}
if ($TokenId -and -not $TokenSecret) {
    $ss = Read-Host 'Service token secret' -AsSecureString
    $TokenSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
}
if ($TokenId -and -not $TokenSecret) { throw '-TokenId needs -TokenSecret.' }

if ($PubKey) {
    $pk = $PubKey.Trim() -split '\s+'
    if ($pk.Count -lt 2 -or $pk[0] -notmatch '^(ssh-|ecdsa-|sk-)') { throw "-PubKey doesn't look like an OpenSSH public key." }
    $comment = if ($pk.Count -ge 3) { $pk[2] } else { '' }
    $Tag = if ($comment -like 'autossh:*') { $comment } else { "autossh:${Alias}:$(if ($comment) { $comment } else { 'agent' })" }
} else {
    $Tag = "autossh:${Alias}:target"
}

$adminsName = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
$userExists = try { [ADSI]::Exists("WinNT://$env:COMPUTERNAME/$User,user") } catch { $false }   # throws when missing
$acct = if ($userExists) { "$User (existing)" } else { "$User (new, local administrator, hidden from sign-in screen)" }
$keyDesc = if ($PubKey) { "authorise the agent's key ($Tag)" } else { "generate a new ed25519 key ($Tag)" }
$via = if ($Mode -eq 'tunnel') { "$HostName via Cloudflare Tunnel" } else { "$HostName$(if ($port) { ":$port" }) (direct)" }
Write-Host @"

  Machine   $Machine - $OsName ($Arch)
  Address   $via
  Alias     ssh $Alias
  Account   $acct
  Key       $keyDesc

"@
if (-not $Yes -and -not (YesNo 'Proceed?')) { throw 'Aborted - nothing was changed.' }

# --- OpenSSH Server -----------------------------------------------------------
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) {
    Info 'Installing OpenSSH Server (Windows optional feature - can take a few minutes)'
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if (-not $cap) { throw 'OpenSSH Server is not available on this Windows build.' }
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    $svc = Get-Service sshd
}
if ($svc.StartType -ne 'Automatic') { Set-Service sshd -StartupType Automatic }
if ($svc.Status -ne 'Running') { Info 'Starting sshd'; Start-Service sshd }

$sshdExe = [Environment]::ExpandEnvironmentVariables(((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd').ImagePath -replace '"', '').Trim())
$sshDir = Split-Path $sshdExe
$keygen = Join-Path $sshDir 'ssh-keygen.exe'
$sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
$SshdPort = 22
$portLine = if (Test-Path $sshdConfig) { Select-String -Path $sshdConfig -Pattern '^\s*Port\s+(\d+)' | Select-Object -First 1 }
if ($portLine) { $SshdPort = [int]$portLine.Matches[0].Groups[1].Value }

# Agents expect a real shell, not cmd.exe. Only set if nobody chose one already.
$shellKey = 'HKLM:\SOFTWARE\OpenSSH'
$shell = (Get-ItemProperty $shellKey -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
if (-not $shell) {
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $shell = if (Test-Path $pwsh) { $pwsh } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    if (-not (Test-Path $shellKey)) { New-Item $shellKey -Force | Out-Null }
    New-ItemProperty $shellKey -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
    Info "SSH sessions now start in $shell"
}
$ShellDesc = switch -Regex ($shell) { 'pwsh' { 'PowerShell 7' } 'powershell' { 'Windows PowerShell' } 'bash' { 'bash' } default { 'cmd' } }

# --- Account ------------------------------------------------------------------
$adminsGroup = [ADSI]"WinNT://$env:COMPUTERNAME/$adminsName,group"
if (-not $userExists) {
    Info "Creating local administrator $User"
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?@'
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })) + 'Aa1!'   # never shown; logins are key-only
    $u = ([ADSI]"WinNT://$env:COMPUTERNAME,computer").Create('User', $User)
    $u.SetPassword($pw)
    $u.SetInfo()
    $u = [ADSI]"WinNT://$env:COMPUTERNAME/$User,user"
    $u.Put('Description', 'AutoSSH agent account')
    $u.UserFlags.Value = $u.UserFlags.Value -bor 0x10000   # password never expires
    $u.CommitChanges()
    $adminsGroup.Add("WinNT://$env:COMPUTERNAME/$User,user")
    $hide = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (-not (Test-Path $hide)) { New-Item $hide -Force | Out-Null }
    New-ItemProperty $hide -Name $User -Value 0 -PropertyType DWord -Force | Out-Null
}
$members = @($adminsGroup.psbase.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
$isAdmin = $members -contains $User
$Access = if ($isAdmin) { 'local administrator' } else { 'standard user' }

# Admins' keys live in administrators_authorized_keys while the stock "Match Group administrators" block is in place.
$adminMatch = (Test-Path $sshdConfig) -and (Select-String -Path $sshdConfig -Pattern '^\s*Match\s+Group\s+administrators' -Quiet)
if ($isAdmin -and $adminMatch) {
    $ak = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
} else {
    $sid = (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value
    $prof = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $prof) { throw "$User has never signed in, so has no profile folder yet. Sign in once as $User, then re-run." }
    $ak = Join-Path $prof '.ssh\authorized_keys'
    New-Item -ItemType Directory -Force (Split-Path $ak) | Out-Null
}

# --- Key ----------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('autossh-' + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
try {
    if ($PubKey) {
        $PubLine = "$($pk[0]) $($pk[1]) $Tag"; $PrivKey = ''
        [IO.File]::WriteAllText("$tmp\key.pub", "$PubLine`n")
    } else {
        # Start-Process passes the string verbatim, so -N "" survives as an empty passphrase on PS 5.1 and 7.
        $p = Start-Process -FilePath $keygen -ArgumentList "-q -t ed25519 -N `"`" -C $Tag -f `"$tmp\key`"" -Wait -NoNewWindow -PassThru
        if ($p.ExitCode -ne 0) { throw 'ssh-keygen failed.' }
        $PrivKey = ([IO.File]::ReadAllText("$tmp\key")).Trim()
        $PubLine = ([IO.File]::ReadAllText("$tmp\key.pub")).Trim()
    }
    $fp = & $keygen -lf "$tmp\key.pub"
    if ($LASTEXITCODE -ne 0) { throw 'Public key is not valid.' }
    $Fingerprint = ($fp -split '\s+')[1]
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$old = @(if (Test-Path $ak) { Get-Content $ak | Where-Object { $_.Trim() } })
$keep = @($old | Where-Object { ($_.Trim() -split '\s+')[-1] -ne $Tag })
[IO.File]::WriteAllText($ak, ((@($keep) + $PubLine) -join "`n") + "`n")
if ($ak -like "$env:ProgramData*") {
    icacls $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
} else {
    icacls $ak /inheritance:r /grant "${User}:F" /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F' | Out-Null
}
if ($old.Count -gt $keep.Count) { Info "Replaced $($old.Count - $keep.Count) earlier key(s) tagged $Tag" }
Info "Authorised key $Fingerprint for $User"

# --- Network --------------------------------------------------------------------
$localCf = ([bool](Get-Service cloudflared -ErrorAction SilentlyContinue)) -or ([bool](Get-Command cloudflared -ErrorAction SilentlyContinue))
if (-not ($Mode -eq 'tunnel' -and $localCf)) {
    try {
        if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound `
                -Protocol TCP -Action Allow -LocalPort $SshdPort | Out-Null
            Info "Opened TCP $SshdPort in Windows Firewall"
        }
    } catch { Note "Couldn't check the firewall rule for sshd - make sure TCP $SshdPort is reachable from the tunnel connector." }
}

if ($Mode -eq 'tunnel') {
    $ip = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.GetIPProperties().GatewayAddresses.Count } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses.Address } |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 | ForEach-Object { $_.IPAddressToString }
    if (-not $ip) { $ip = '<LAN IP of this machine>' }
    $svcLine = if ($localCf) { "SSH  localhost:$SshdPort      (cloudflared is on this machine)" } else { "SSH  ${ip}:$SshdPort   (from whichever machine runs the connector)" }
    Write-Host @"

------------------------------------------------------------------------------
 Cloudflare Tunnel route  (Zero Trust > Networks > Tunnels > your tunnel >
                           Published application routes > Add)
   Hostname : $HostName
   Service  : $svcLine
"@
    if (-not $TokenId) {
        Write-Host @"
   Optional : put the hostname behind a Cloudflare Access app with a Service Auth
              policy, then re-run with -TokenId/-TokenSecret so only agents
              holding the token can even reach sshd.
"@
    }
    Write-Host '------------------------------------------------------------------------------'
}

# --- Bundle ---------------------------------------------------------------------
$today = Get-Date -Format 'yyyy-MM-dd'
$confLines = @(
    "# autossh: alias=$Alias os=`"$OsName`" arch=$Arch user=$User access=`"$Access`" shell=`"$ShellDesc`" via=$(if ($Mode -eq 'tunnel') { 'cloudflare-tunnel' } else { 'direct' }) added=$today"
    "Host $Alias"
    "  HostName $HostName"
)
$p2 = if ($port) { $port } else { $SshdPort }
if ($Mode -eq 'direct' -and $p2 -ne 22) { $confLines += "  Port $p2" }
$confLines += @(
    "  User $User"
    "  IdentityFile ~/.ssh/autossh/$Alias.key"
    '  IdentitiesOnly yes'
    "  HostKeyAlias $Alias"
    "  UserKnownHostsFile ~/.ssh/autossh/$Alias.known_hosts"
    '  StrictHostKeyChecking yes'
    '  BatchMode yes'
    '  ConnectTimeout 30'
    '  ServerAliveInterval 30'
)
if ($Mode -eq 'tunnel') {
    $confLines += "  ProxyCommand CLOUDFLARED_BIN access ssh --hostname %h$(if ($TokenId) { " --id $TokenId --secret $TokenSecret" })"
}
$Conf = $confLines -join "`n"
$Known = (Get-ChildItem (Join-Path $env:ProgramData 'ssh') -Filter 'ssh_host_*_key.pub' | ForEach-Object {
    $f = ([IO.File]::ReadAllText($_.FullName)).Trim() -split '\s+'; "$Alias $($f[0]) $($f[1])"
}) -join "`n"

$addrDesc = if ($Mode -eq 'tunnel') { "``$HostName`` via Cloudflare Tunnel (``cloudflared`` is installed by the block below if missing)" } else { "``$HostName$(if ($port) { ":$port" })`` (direct SSH)" }
$noteText = "**SSH host ``$Alias``** - $OsName, remote shell $ShellDesc (commands run in PowerShell, Windows paths), user ``$User`` ($Access). Run commands with ``ssh $Alias '<command>'`` (config: ~/.ssh/autossh/$Alias.conf). Use it to pull, build, redeploy and inspect sites/services on this machine. Work non-interactively, check ``git status`` before pulling, verify deploys (e.g. curl the site) and confirm with the user before destructive or irreversible actions (deleting data, dropping databases, rebooting)."

if ($Mode -eq 'tunnel') {
    $cfSh = @'
cf=$(command -v cloudflared || true)
if [ -z "$cf" ]; then
  if command -v brew >/dev/null 2>&1; then brew install cloudflared >/dev/null && cf=$(command -v cloudflared)
  elif [ "$(uname -s)" = Linux ]; then
    case $(uname -m) in x86_64) a=amd64;; aarch64|arm64) a=arm64;; arm*) a=arm;; *) a=386;; esac
    mkdir -p "$HOME/.local/bin"; cf="$HOME/.local/bin/cloudflared"
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a" -o "$cf" && chmod 755 "$cf"
  fi
fi
[ -x "$cf" ] || { echo "Install cloudflared, then re-run: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"; exit 1; }
'@
    $cfPs = @'
$cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cf) { $cf = "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe" }
if (-not (Test-Path $cf)) { winget install --id Cloudflare.cloudflared -e --silent --accept-source-agreements --accept-package-agreements | Out-Null }
if (-not (Test-Path $cf)) { throw "Install cloudflared (winget install Cloudflare.cloudflared), then re-run." }
'@
} else {
    $cfSh = 'cf=unused'
    $cfPs = '$cf = "unused"'
}

# @@HSEND@@ stands in for the closing '@ of the agent's PowerShell here-strings.
if ($PrivKey) {
    $t = @'
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
@@HSEND@@
icacls $key /inheritance:r /grant:r "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):F" | Out-Null
Save '@@ALIAS@@.known_hosts' @'
@@KNOWN@@
@@HSEND@@ | Out-Null
@@CF_PS@@
Save '@@ALIAS@@.conf' (@'
@@CONF@@
@@HSEND@@).Replace('CLOUDFLARED_BIN', '"' + ($cf -replace '\\', '/') + '"') | Out-Null
$c = Join-Path $HOME '.ssh\config'; $old = if (Test-Path $c) { [IO.File]::ReadAllText($c) } else { '' }
if ($old -notmatch '(?m)^Include autossh/\*\.conf') { [IO.File]::WriteAllText($c, "Include autossh/*.conf`n`n" + $old) }
ssh @@ALIAS@@ whoami }
```

## 2. Verify
The block ends by running `ssh @@ALIAS@@ whoami`; it should print the remote user (`@@USER@@`).
If it doesn't, `ssh -v @@ALIAS@@ whoami` shows where it stops.

## 3. Remember this capability
Save this note to your persistent memory / instructions (CLAUDE.md, AGENTS.md, memory file).
Claude Code with the `autossh` skill installed finds hosts in ~/.ssh/autossh automatically.

> @@NOTE@@
'@
} else {
    $t = @'
# AutoSSH: @@ALIAS@@ is ready

Your key (@@FP@@) is authorised for `@@USER@@` on @@OS@@. To pin this machine's host key, write
these lines to `~/.ssh/autossh/@@ALIAS@@.known_hosts` (replacing any existing ones):

```
@@KNOWN@@
```

Then run `ssh @@ALIAS@@ whoami` (or `/autossh test @@ALIAS@@`). Capability note to remember:

> @@NOTE@@
'@
}
$subs = [ordered]@{
    '@@PRIVKEY@@' = $PrivKey; '@@KNOWN@@' = $Known; '@@CONF@@' = $Conf; '@@CF_SH@@' = $cfSh.Trim(); '@@CF_PS@@' = $cfPs.Trim()
    '@@NOTE@@' = $noteText; '@@ADDR@@' = $addrDesc; '@@USER@@' = $User; '@@SUDO@@' = $Access; '@@OS@@' = $OsName
    '@@ARCH@@' = $Arch; '@@SHELL@@' = $ShellDesc; '@@FP@@' = $Fingerprint; '@@HSEND@@' = "'@"; '@@ALIAS@@' = $Alias
}
foreach ($k in $subs.Keys) { $t = $t.Replace($k, [string]$subs[$k]) }
$t = $t -replace "`r", ''

if ($PrivKey) {
    Write-Host "`nPaste everything below to your agent (it contains a private key - this is the only copy):`n" -ForegroundColor White
}
Write-Output $t
Write-Host "`nRevoke later: delete the line ending in `"$Tag`" from $ak" -ForegroundColor DarkGray
}
