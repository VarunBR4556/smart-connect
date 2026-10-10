#!/usr/bin/env pwsh
# Smart Connect - single entry point for the whole project (Windows).
#
# The OS is auto-detected: this script handles Windows 10/11, and points you
# to the Bash entry point (./run) when it is run on Linux.
#
# Usage: .\run.ps1 <command>   (PowerShell - ./run <command> also works)
#   gui      Open the web console (no typing - works in your browser)
#   setup    Initial setup: install SSH server and connect Tailscale
#   start    Start SSH and bring Tailscale up (aliases: up)
#   stop     Stop SSH and Tailscale completely (aliases: down)
#   update   Update SSH & Tailscale and keep the services running
#   status   Show SSH + Tailscale status and your Tailscale IP
#   ip       Print your Tailscale IPv4 and the phone SSH command
#   help     Show this help
#
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Windows PowerShell 5.1 may default to TLS 1.0, which modern servers reject.
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$Self = 'run.ps1'

# --- Output helpers -----------------------------------------------------
function Write-Log { param([string]$Message) Write-Host $Message }
function Write-Err { param([string]$Message) [Console]::Error.WriteLine($Message) }

function Show-Usage {
  $text = @"
Smart Connect - reach this laptop's terminal from your phone (Tailscale + SSH)

Usage: .\$Self <command>

Commands:
  gui      Open the web console (no typing - works in your browser)
  setup    Initial setup: install SSH server and connect Tailscale
  start    Start SSH and bring Tailscale up (aliases: up)
  stop     Stop SSH and Tailscale completely (aliases: down)
  update   Update SSH & Tailscale and keep the services running
  status   Show SSH + Tailscale status and your Tailscale IP
  ip       Print your Tailscale IPv4 and the phone SSH command
  check    Verify this system meets all version requirements
  sos      Self-destruct: remove SSH, Tailscale and every project file
  help     Show this help

No command? The web console opens automatically.

First time? Run: .\$Self setup
"@
  Write-Host $text
}

# Runs a native command safely: captures merged output and exit code without
# letting stderr trip $ErrorActionPreference (Windows PowerShell 5.1 quirk).
function Invoke-Native {
  param([string]$FilePath, [string[]]$ArgumentList = @())

  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $lines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
    return @{ Output = $lines; ExitCode = $LASTEXITCODE }
  } finally {
    $ErrorActionPreference = $previousPreference
  }
}

# Runs a native command with a hard time limit and finally kills it if it does
# not finish. Used for commands that can block forever on user input (e.g.
# "tailscale up" waits for the browser login to complete).
function Invoke-NativeBounded {
  param([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSeconds = 180)

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = (($ArgumentList | ForEach-Object { '"{0}"' -f ($_ -replace '"', '\"') }) -join ' ')
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = $null
  try { $process = [System.Diagnostics.Process]::Start($startInfo) } catch {
    return @{ Code = 127; Output = @("could not start $FilePath"); TimedOut = $false }
  }

  $outTask = $process.StandardOutput.ReadToEndAsync()
  $errTask = $process.StandardError.ReadToEndAsync()

  $timedOut = $false
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    $timedOut = $true
    try { $process.Kill() } catch { }
    try { $process.WaitForExit(5000) | Out-Null } catch { }
  }

  $merged = @()
  try {
    $merged = @(($outTask.Result + "`n" + $errTask.Result) -split "`r?`n" | Where-Object { $_.Trim() })
  } catch { }

  return @{ Code = $process.ExitCode; Output = $merged; TimedOut = $timedOut }
}

# --- Platform detection -------------------------------------------------
function Test-WindowsOs {
  if ($PSVersionTable.PSEdition -eq 'Core') {
    return ((Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
  }
  return $true   # Windows PowerShell (5.1) always runs on Windows
}

function Test-IsAdministrator {
  $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
  param([string[]]$Argv)

  Write-Log ''
  Write-Log 'Requesting administrator privileges (UAC prompt)...'
  $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
  foreach ($item in $Argv) { $argumentList += ('"{0}"' -f $item) }

  try {
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList -Wait -PassThru
    exit $process.ExitCode
  } catch {
    Write-Err 'Root privileges are required. Approve the UAC prompt or run PowerShell as Administrator.'
    exit 1
  }
}

# --- Helpers ------------------------------------------------------------
function Get-PackageManager {
  foreach ($tool in 'winget', 'choco', 'scoop') {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { return $tool }
  }
  return 'none'
}

function Get-SshServiceName {
  foreach ($name in 'sshd', 'ssh') {
    if (Get-Service -Name $name -ErrorAction SilentlyContinue) { return $name }
  }
  return ''
}

function Test-SshInstalled {
  if (Get-SshServiceName) { return $true }
  if (Test-Path (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe')) { return $true }
  if (Get-Command sshd -ErrorAction SilentlyContinue) { return $true }
  foreach ($candidate in @('OpenSSH-Win64\sshd.exe', 'OpenSSH\sshd.exe', 'OpenSSH-Win32\sshd.exe')) {
    $path = Join-Path $env:ProgramFiles $candidate
    if (Test-Path $path) { return $true }
  }
  return $false
}

function Get-OpenSshCapability {
  try {
    return (Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop |
            Where-Object { $_.Name -like 'OpenSSH.Server*' } |
            Select-Object -First 1)
  } catch {
    return $null
  }
}

function Stop-ServiceSafe {
  param([string]$Name, [switch]$Manual)

  $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if (-not $service) { return }
  if ($service.Status -ne 'Stopped') {
    try {
      $service.Stop()
      $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
    } catch { }
  }
  if ($Manual) {
    try { Set-Service -Name $Name -StartupType Manual -ErrorAction SilentlyContinue } catch { }
  }
}

function Get-TailscaleExe {
  $command = Get-Command tailscale -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }

  $candidates = @()
  if ($env:ProgramFiles)        { $candidates += (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe') }
  if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe') }
  foreach ($path in $candidates) {
    if ($path -and (Test-Path $path)) { return $path }
  }
  return $null
}

# On Windows the tailscaled daemon runs as a service named "Tailscale"
# (not "tailscaled" as on Linux). Accept either name to stay robust.
function Get-TailscaleServiceName {
  foreach ($name in 'Tailscale', 'tailscaled') {
    if (Get-Service -Name $name -ErrorAction SilentlyContinue) { return $name }
  }
  return ''
}

function Install-TailscaleFromMsi {
  $arch  = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
  $url   = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-$arch.msi"
  $setup = Join-Path $env:TEMP 'tailscale-setup.msi'

  Write-Log "Downloading $url ..."
  try {
    Invoke-WebRequest -Uri $url -OutFile $setup -UseBasicParsing
  } catch {
    Write-Err "Download failed: $($_.Exception.Message)"
    Write-Err 'Download Tailscale manually from https://tailscale.com/download'
    return $false
  }

  $process = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @('/i', ('"{0}"' -f $setup), '/qn', '/norestart')
  if ($process.ExitCode -ne 0) {
    Write-Err "Tailscale installer failed (exit code $($process.ExitCode))."
    return $false
  }
  return [bool](Get-TailscaleExe)
}

# Add a Windows optional capability through DISM with a hard time limit.
# Add-WindowsCapability can sit for a very long time (or stall) on Windows 11,
# so we run the underlying dism.exe ourselves: the console shows live progress
# lines, and if it does not finish in time we kill it and callers fall back to
# winget instead of hanging forever.
function Invoke-CapabilityInstall {
  param([string]$Name, [int]$TimeoutSeconds = 300)

  $exe = Join-Path $env:SystemRoot 'System32\dism.exe'
  if (-not (Test-Path $exe)) { return @{ Code = -1; TimedOut = $false; Message = "dism.exe not found at $exe" } }

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $exe
  $startInfo.Arguments = '/online /add-capability /capabilityname:"{0}" /norestart' -f $Name
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.RedirectStandardInput = $true

  $process = $null
  try { $process = [System.Diagnostics.Process]::Start($startInfo) } catch {
    return @{ Code = -1; TimedOut = $false; Message = $_.Exception.Message }
  }

  Write-Host 'This can take a few minutes the first time. Progress is shown below.'
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $timedOut = $false
  $stdout = $process.StandardOutput.ReadLineAsync()
  $stderr = $process.StandardError.ReadLineAsync()

  while (-not $process.HasExited -or -not $stdout.IsCompleted -or -not $stderr.IsCompleted) {
    if (-not $timedOut -and (Get-Date) -gt $deadline) {
      $timedOut = $true
      try { $process.Kill() } catch { }
      Write-Host ('[timeout] the Windows installer did not finish within {0} seconds - aborting it.' -f $TimeoutSeconds)
    }
    if (-not $stdout.IsCompleted -and $stdout.Wait(200)) {
      $line = $null
      try { $line = $stdout.Result } catch { }
      if ($null -ne $line) {
        if ($line.Trim()) { Write-Host $line }
        $stdout = $process.StandardOutput.ReadLineAsync()
      }
    }
    if (-not $stderr.IsCompleted -and $stderr.Wait(0)) {
      $line = $null
      try { $line = $stderr.Result } catch { }
      if ($null -ne $line) {
        if ($line.Trim()) { Write-Err $line }
        $stderr = $process.StandardError.ReadLineAsync()
      }
    }
    if ($timedOut) {
      $stdout.Wait(1000) | Out-Null
      $stderr.Wait(500) | Out-Null
      Start-Sleep -Milliseconds 300
      break
    }
  }
  try { $process.WaitForExit() } catch { }
  return @{ Code = $process.ExitCode; TimedOut = $timedOut }
}

function Install-SshServer {
  if (Test-SshInstalled) {
    Write-Log 'OpenSSH server already installed.'
    return $true
  }

  Write-Log 'Installing OpenSSH server (Windows optional feature)...'
  $capability = Get-OpenSshCapability
  if (-not $capability) {
    Write-Err 'The OpenSSH Server capability was not found on this system.'
    return $false
  }

  if ($capability.State -ne 'Installed') {
    $result = Invoke-CapabilityInstall -Name $capability.Name -TimeoutSeconds 300
    if ($result.TimedOut) {
      Write-Err 'The Windows optional-feature installer timed out.'
    } elseif ($result.Message) {
      Write-Err "Could not start the installer: $($result.Message)"
    } elseif ($result.Code -eq 0 -or $result.Code -eq 3010) {
      Write-Log 'OpenSSH server capability added successfully.'
    } else {
      Write-Err "Windows could not install the OpenSSH feature (exit code $($result.Code))."
    }
  } else {
    Write-Log 'OpenSSH server capability is already installed.'
  }

  # If the optional-feature route failed or stalled, fall back to winget so
  # the user is never left without a working SSH server.
  if (-not (Test-SshInstalled)) {
    if ((Get-PackageManager) -eq 'winget') {
      Write-Log 'Falling back to winget (Microsoft.OpenSSH.Preview)...'
      $winget = Invoke-Native -FilePath 'winget' -ArgumentList @('install', '--id', 'Microsoft.OpenSSH.Preview', '-e', '--accept-package-agreements', '--accept-source-agreements')
      $winget.Output | ForEach-Object { Write-Host $_ }
      if ($winget.ExitCode -ne 0) {
        Write-Err 'Get the installer from https://github.com/PowerShell/Win32-OpenSSH/releases'
        return $false
      }
    } else {
      Write-Err 'Install it manually: Settings > Apps > Optional features > OpenSSH Server'
      return $false
    }
  }

  if (-not (Test-SshInstalled)) {
    Write-Err 'OpenSSH server installation did not complete. Check the messages above.'
    return $false
  }
  return $true
}

function Start-SshServer {
  $unit = Get-SshServiceName
  if (-not $unit) {
    Write-Err 'Could not detect the SSH service. Start it manually in services.msc.'
    return $false
  }

  try {
    Start-Service -Name $unit -ErrorAction Stop
  } catch {
    Write-Err "Could not start the SSH service: $($_.Exception.Message)"
    return $false
  }
  return $true
}

function Stop-SshServer {
  $unit = Get-SshServiceName
  if ($unit) {
    # Linux parity: `stop` disables the sockets so nothing respawns or boots back up.
    Stop-ServiceSafe -Name $unit -Manual
  }

  Start-Sleep -Milliseconds 300
  if (Get-Process -Name sshd -ErrorAction SilentlyContinue) {
    Write-Err 'sshd is still running. Stop it manually in services.msc.'
    return $false
  }
  return $true
}

function Install-Tailscale {
  if (Get-TailscaleExe) {
    Write-Log 'Tailscale already installed.'
    return $true
  }

  $packageManager = Get-PackageManager
  if ($packageManager -eq 'winget') {
    Write-Log 'Installing Tailscale (winget)...'
    $result = Invoke-Native -FilePath 'winget' -ArgumentList @('install', '--id', 'Tailscale.Tailscale', '-e', '--accept-package-agreements', '--accept-source-agreements')
    $result.Output | ForEach-Object { Write-Host $_ }
    if ($result.ExitCode -eq 0 -and (Get-TailscaleExe)) { return $true }
    Write-Err 'winget install failed; trying the official installer instead.'
  } elseif ($packageManager -eq 'choco') {
    Write-Log 'Installing Tailscale (chocolatey)...'
    $result = Invoke-Native -FilePath 'choco' -ArgumentList @('install', 'tailscale', '-y')
    $result.Output | ForEach-Object { Write-Host $_ }
    if ($result.ExitCode -eq 0 -and (Get-TailscaleExe)) { return $true }
    Write-Err 'choco install failed; trying the official installer instead.'
  } elseif ($packageManager -eq 'scoop') {
    Write-Log 'Installing Tailscale (scoop)...'
    $result = Invoke-Native -FilePath 'scoop' -ArgumentList @('install', 'tailscale')
    $result.Output | ForEach-Object { Write-Host $_ }
    if ($result.ExitCode -eq 0 -and (Get-TailscaleExe)) { return $true }
    Write-Err 'scoop install failed; trying the official installer instead.'
  } else {
    Write-Log 'No package manager found - using the official installer.'
  }

  return (Install-TailscaleFromMsi)
}

function Update-Tailscale {
  if (-not (Get-TailscaleExe)) { return (Install-Tailscale) }

  Write-Log 'Updating Tailscale...'
  $packageManager = Get-PackageManager
  switch ($packageManager) {
    'winget' {
      $result = Invoke-Native -FilePath 'winget' -ArgumentList @('upgrade', '--id', 'Tailscale.Tailscale', '-e', '--accept-package-agreements', '--accept-source-agreements')
      $result.Output | ForEach-Object { Write-Host $_ }
      if ($result.ExitCode -ne 0) { Write-Log 'winget: no upgrade available or upgrade failed (continuing).' }
    }
    'choco' {
      $result = Invoke-Native -FilePath 'choco' -ArgumentList @('upgrade', 'tailscale', '-y')
      $result.Output | ForEach-Object { Write-Host $_ }
      if ($result.ExitCode -ne 0) { Write-Log 'choco: upgrade reported an error (continuing).' }
    }
    'scoop' {
      $result = Invoke-Native -FilePath 'scoop' -ArgumentList @('update', 'tailscale')
      $result.Output | ForEach-Object { Write-Host $_ }
      if ($result.ExitCode -ne 0) { Write-Log 'scoop: upgrade reported an error (continuing).' }
    }
    default {
      Write-Log 'No package manager found - reinstalling the latest installer (upgrade in place).'
      return (Install-TailscaleFromMsi)
    }
  }
  return $true
}

function Test-TailscaleConnected {
  $tailscale = Get-TailscaleExe
  if (-not $tailscale) { return $false }
  $st = Invoke-NativeBounded -FilePath $tailscale -ArgumentList @('status') -TimeoutSeconds 8
  return (-not $st.TimedOut -and $st.Code -eq 0)
}

function Invoke-TailscaleUp {
  $tailscale = Get-TailscaleExe
  if (-not $tailscale) {
    Write-Err "Tailscale is not installed. Run: .\$Self setup"
    return $false
  }

  if (Test-TailscaleConnected) {
    Write-Log 'Tailscale is already connected.'
    return $true
  }

  # One bounded status call tells us everything: connected, needs login, or
  # logged-in-but-stopped. When the machine is merely logged out, "tailscale up"
  # cannot help (login on Windows happens in the Tailscale app), so say so
  # immediately instead of waiting out a timeout.
  $st = Invoke-NativeBounded -FilePath $tailscale -ArgumentList @('status') -TimeoutSeconds 8
  if (-not $st.TimedOut -and $st.Code -ne 0) {
    $stOut = ($st.Output -join "`n")
    if ($stOut -match '(?i)logged\s*out|need[s]?\s*login|login\s*required|not logged') {
      Write-Log 'Tailscale is not logged in.'
      Write-Log 'Open the Tailscale window on this computer (or the icon near the clock)'
      Write-Log 'and log in, then click Start again.'
      return $false
    }
  }

  $serviceName = Get-TailscaleServiceName
  $service = if ($serviceName) { Get-Service -Name $serviceName -ErrorAction SilentlyContinue } else { $null }
  if ($service -and $service.Status -ne 'Running') {
    Write-Log 'Starting the Tailscale service...'
    try { Start-Service -Name $service.Name -ErrorAction Stop } catch {
      Write-Err "Could not start the Tailscale service: $($_.Exception.Message)"
      return $false
    }
    Start-Sleep -Seconds 2
  }

  Write-Log 'Bringing Tailscale up - a login URL may appear below. Open it in your browser.'
  $result = Invoke-NativeBounded -FilePath $tailscale -ArgumentList @('up') -TimeoutSeconds 20
  $output = ($result.Output -join "`n")

  if ($result.TimedOut) {
    if ($output) { Write-Host $output }
    Write-Log ''
    Write-Log 'Tailscale is still waiting for you to log in.'
    if ($output -match 'https?://') { Write-Log 'Open the link above in your browser and sign in.' }
    Write-Log 'A Tailscale window may have opened on this computer - sign in there.'
    Write-Log 'After logging in, click Start again (or run: .\run.ps1 start).'
    return $false
  }

  if ($output) { Write-Host $output }

  if ($result.Code -ne 0 -and $output -match 'non-default flags') {
    if ($output -match 'tailscale up\s+[^\r\n]+') {
      $retry = $Matches[0]
      $flags = @('up') + @($retry -replace '^.*?tailscale up\s+', '' -split '\s+' | Where-Object { $_ })
      Write-Log ''
      Write-Log "Existing settings detected; re-running: $retry"
      $retryResult = Invoke-NativeBounded -FilePath $tailscale -ArgumentList $flags -TimeoutSeconds 20
      $retryResult.Output | ForEach-Object { Write-Host $_ }
      if ($retryResult.TimedOut) {
        Write-Log 'Still waiting for login. Open the URL shown above, log in, then click Start again.'
        return $false
      }
      return ($retryResult.Code -eq 0)
    }
    Write-Err 'Re-run manually with the flags shown above.'
    return $false
  } elseif ($result.Code -ne 0) {
    Write-Err 'Tailscale did not come up. See the message above.'
    return $false
  }
  return $true
}

function Show-PrintIp {
  $tailscale = Get-TailscaleExe
  if (-not $tailscale) {
    Write-Err "Tailscale is not installed. Run: .\$Self setup"
    return $false
  }

  $result = Invoke-Native -FilePath $tailscale -ArgumentList @('ip', '-4')
  $tailscaleIp = ''
  if ($result.ExitCode -eq 0 -and $result.Output.Count -gt 0) {
    $tailscaleIp = ($result.Output | Select-Object -First 1).Trim()
  }

  if ($tailscaleIp) {
    Write-Log "Tailscale IPv4: $tailscaleIp"
    Write-Log "Connect from your phone: ssh $($env:USERNAME)@$tailscaleIp"
    return $true
  }

  Write-Err "No Tailscale IP yet. Run: .\$Self setup"
  return $false
}

# --- Commands -----------------------------------------------------------
function Invoke-Setup {
  Write-Log '=== Smart Connect - Setup ==='
  Write-Log ''

  Write-Log '--- SSH server ---'
  if (-not (Install-SshServer)) { exit 1 }
  if (Start-SshServer) { Write-Log 'SSH server is running.' }

  Write-Log ''
  Write-Log '--- Tailscale ---'
  if (-not (Install-Tailscale)) { exit 1 }
  if (-not (Invoke-TailscaleUp)) { exit 1 }

  Write-Log ''
  Write-Log '=== Done ==='
  Show-PrintIp | Out-Null
}

function Invoke-Update {
  Write-Log '=== Smart Connect - Update ==='
  Write-Log ''

  Write-Log '--- Refreshing package lists ---'
  switch (Get-PackageManager) {
    'winget' {
      $result = Invoke-Native -FilePath 'winget' -ArgumentList @('source', 'update')
      if ($result.ExitCode -ne 0) { Write-Log 'winget: source update skipped.' }
    }
    'choco' {
      $result = Invoke-Native -FilePath 'choco' -ArgumentList @('upgrade', 'all', '-y')
      if ($result.ExitCode -ne 0) { Write-Log 'choco: nothing to upgrade.' }
    }
    'scoop' {
      $result = Invoke-Native -FilePath 'scoop' -ArgumentList @('update')
      if ($result.ExitCode -ne 0) { Write-Log 'scoop: nothing to upgrade.' }
    }
    default  { Write-Log 'Unsupported package manager; skipping package updates.' }
  }

  Write-Log ''
  Write-Log '--- SSH server ---'
  if (Test-SshInstalled) {
    Write-Log 'OpenSSH server is up to date (updated through Windows Update).'
  } else {
    if (-not (Install-SshServer)) { exit 1 }
  }
  if (Start-SshServer) { Write-Log 'SSH server is running.' }

  Write-Log ''
  Write-Log '--- Tailscale ---'
  if (-not (Update-Tailscale)) { exit 1 }
  if (-not (Invoke-TailscaleUp)) { exit 1 }

  Write-Log ''
  Write-Log '=== Done ==='
  Show-PrintIp | Out-Null
}

function Invoke-Status {
  Write-Log '=== Smart Connect - Status ==='
  Write-Log ''

  Write-Log '--- SSH server ---'
  if (-not (Test-SshInstalled)) {
    Write-Log "OpenSSH server is NOT installed. Run: .\$Self setup"
  } else {
    $unit = Get-SshServiceName
    if ($unit) {
      $service = Get-Service -Name $unit
      Write-Log "$unit - $($service.DisplayName)"
      Write-Log "   Status:  $($service.Status)"
      Write-Log "   Startup: $($service.StartType)"
      if ($service.Status -ne 'Running') {
        Write-Log "   Start it with: .\$Self start"
      }
    } else {
      Write-Log 'Could not detect the SSH service. Check with: Get-Process sshd'
    }
  }

  Write-Log ''
  Write-Log '--- Tailscale ---'
  $tailscale = Get-TailscaleExe
  if ($tailscale) {
    $result = Invoke-NativeBounded -FilePath $tailscale -ArgumentList @('status') -TimeoutSeconds 8
    $result.Output | ForEach-Object { Write-Host $_ }
    if ($result.TimedOut -or $result.Code -ne 0) { Write-Log '(tailscaled is not running or is logged out)' }
  } else {
    Write-Log 'Tailscale is NOT installed. Run: .\run.ps1 setup'
  }

  Write-Log ''
  Show-PrintIp | Out-Null
}

function Invoke-Start {
  Write-Log '=== Smart Connect - Start ==='
  Write-Log ''

  Write-Log '--- SSH server ---'
  if (Test-SshInstalled) {
    if (Start-SshServer) { Write-Log 'SSH server is running.' }
  } else {
    Write-Err "OpenSSH server is not installed. Run: .\$Self setup"
  }

  Write-Log ''
  Write-Log '--- Tailscale ---'
  if (Get-TailscaleExe) {
    if (-not (Invoke-TailscaleUp)) { exit 1 }
  } else {
    Write-Err "Tailscale is not installed. Run: .\$Self setup"
  }

  Write-Log ''
  Show-PrintIp | Out-Null
}

function Invoke-Stop {
  Write-Log '=== Smart Connect - Stop ==='
  Write-Log ''

  Write-Log '--- SSH server ---'
  if (Test-SshInstalled) {
    if (Stop-SshServer) { Write-Log 'SSH server stopped.' }
  } else {
    Write-Log 'OpenSSH server is not installed.'
  }

  Write-Log ''
  Write-Log '--- Tailscale ---'
  $tailscale = Get-TailscaleExe
  if ($tailscale) {
    if (Test-TailscaleConnected) {
      $result = Invoke-Native -FilePath $tailscale -ArgumentList @('down')
      if ($result.ExitCode -eq 0) { Write-Log 'Tailscale disconnected.' } else { Write-Err 'tailscale down reported an error.' }
    } else {
      Write-Log 'Tailscale is already disconnected.'
    }
    $serviceName = Get-TailscaleServiceName
    $service = if ($serviceName) { Get-Service -Name $serviceName -ErrorAction SilentlyContinue } else { $null }
    if ($service -and $service.Status -ne 'Stopped') {
      Stop-ServiceSafe -Name $service.Name
      Write-Log 'Tailscale service stopped.'
    }
  } else {
    Write-Log 'Tailscale is not installed.'
  }

  Write-Log ''
  Write-Log "Stopped. Bring it back with: .\$Self start"
}

# --- Self-destruct (SOS) ------------------------------------------------
# Removes everything this project created: the OpenSSH server, Tailscale
# (logged out and uninstalled) and the project folder itself. Triggered by
# the "SOS" button in the web console, or manually: .\run.ps1 sos
function Invoke-Sos {
  $root = $PSScriptRoot
  Write-Log 'SOS - removing Smart Connect and everything it installed.'
  Write-Log ''

  Write-Log '[1/4] Stopping and removing the SSH server...'
  if (Test-SshInstalled) { Stop-SshServer | Out-Null }
  $capability = Get-OpenSshCapability
  if ($capability -and $capability.State -eq 'Installed') {
    try { Remove-WindowsCapability -Online -Name $capability.Name -ErrorAction Stop | Out-Null } catch { }
  }
  $pm = Get-PackageManager
  if ($pm -eq 'winget') {
    Invoke-Native -FilePath 'winget' -ArgumentList @('uninstall', '--id', 'Microsoft.OpenSSH.Preview', '-e', '--silent') | Out-Null
    Invoke-Native -FilePath 'winget' -ArgumentList @('uninstall', '--id', 'Microsoft.OpenSSH', '-e', '--silent') | Out-Null
  } elseif ($pm -eq 'choco') {
    Invoke-Native -FilePath 'choco' -ArgumentList @('uninstall', 'openssh', '-y') | Out-Null
  }

  Write-Log '[2/4] Disconnecting and removing Tailscale...'
  $tailscale = Get-TailscaleExe
  if ($tailscale) {
    Invoke-Native -FilePath $tailscale -ArgumentList @('down') | Out-Null
    Invoke-Native -FilePath $tailscale -ArgumentList @('logout') | Out-Null
  }
  $tsService = Get-TailscaleServiceName
  if ($tsService) { Stop-ServiceSafe -Name $tsService }
  if ($pm -eq 'winget') {
    Invoke-Native -FilePath 'winget' -ArgumentList @('uninstall', '--id', 'Tailscale.Tailscale', '-e', '--silent') | Out-Null
  } elseif ($pm -eq 'choco') {
    Invoke-Native -FilePath 'choco' -ArgumentList @('uninstall', 'tailscale', '-y') | Out-Null
  } elseif ($pm -eq 'scoop') {
    Invoke-Native -FilePath 'scoop' -ArgumentList @('uninstall', 'tailscale') | Out-Null
  } else {
    $uninstaller = Join-Path $env:ProgramFiles 'Tailscale\uninstall.exe'
    if (Test-Path $uninstaller) { Start-Process -FilePath $uninstaller -ArgumentList '/quiet' -Wait }
  }

  Write-Log '[3/4] Stopping the web console...'
  # The console runs inside run.ps1 (gui) now; also catch a legacy server.ps1.
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine -like '*run.ps1*gui*' -or $_.CommandLine -like '*server.ps1*') } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }

  Write-Log "[4/4] Deleting $root ..."
  # Deferred so this script (and the console) can exit before the folder goes.
  Start-Process -FilePath 'cmd.exe' -WindowStyle Hidden -ArgumentList @(
    '/c', ('ping -n 3 127.0.0.1 >nul & rmdir /s /q "{0}"' -f $root)
  ) | Out-Null

  Write-Log ''
  Write-Log 'SOS complete. Smart Connect has been removed from this machine.'
}

# --- Machine-readable status (used by the web console) ------------------
function Get-WindowsDisplayName {
  $key = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
  if ($key) {
    $product = [string]$key.ProductName
    # Windows 11 still reports ProductName = "Windows 10 ..." in the registry;
    # correct it for builds 22000 and up so the console shows Windows 11.
    $build = [System.Environment]::OSVersion.Version.Build
    if ($build -ge 22000 -and $product -like 'Windows 10*') {
      $product = $product -replace '^Windows 10', 'Windows 11'
    }
    $name = '{0} {1}' -f $product, $key.DisplayVersion
    return $name.Trim()
  }
  return [System.Environment]::OSVersion.VersionString
}

function Invoke-StatusJson {
  $tailscale = Get-TailscaleExe
  $unit      = Get-SshServiceName

  $sshActive = $false
  if ($unit) {
    $service = Get-Service -Name $unit -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') { $sshActive = $true }
  }

  # Everything here is safe to run in the console process (no exit, no slow
  # DISM queries). Tailscale calls are bounded so a broken daemon can never
  # freeze the console's request loop.
  $connected = $false
  $ip = ''
  if ($tailscale) {
    $connected = Test-TailscaleConnected
    if ($connected) {
      $result = Invoke-NativeBounded -FilePath $tailscale -ArgumentList @('ip', '-4') -TimeoutSeconds 8
      if ($result.Code -eq 0 -and $result.Output.Count -gt 0) { $ip = ($result.Output | Select-Object -First 1).Trim() }
    }
  }

  $payload = [ordered]@{
    platform             = 'windows'
    os                   = (Get-WindowsDisplayName)
    user                 = $env:USERNAME
    ssh_installed        = [bool](Test-SshInstalled)
    ssh_service          = $unit
    ssh_active           = $sshActive
    tailscale_installed  = [bool]$tailscale
    tailscale_connected  = $connected
    ip                   = $ip
  }
  $payload | ConvertTo-Json -Compress
}

# --- Version compatibility report ---------------------------------------
function Test-VersionAtLeast {
  param([string]$Have, [string]$Need)

  $haveParts = @($Have.TrimStart('v') -split '[.]' | ForEach-Object { if ($_ -match '^\d+') { [int]$Matches[0] } else { 0 } })
  $needParts = @($Need -split '[.]'       | ForEach-Object { if ($_ -match '^\d+') { [int]$Matches[0] } else { 0 } })
  for ($i = 0; $i -lt $needParts.Count; $i++) {
    $h = if ($i -lt $haveParts.Count) { $haveParts[$i] } else { 0 }
    if ($h -gt $needParts[$i]) { return $true }
    if ($h -lt $needParts[$i]) { return $false }
  }
  return $true
}

function Write-CheckRow {
  param([string]$Label, [string]$Value, [string]$Verdict, [string]$Note = '')
  $suffix = ''
  if ($Note) { $suffix = "  ($Note)" }
  Write-Log ('  {0,-14} {1,-38} {2}{3}' -f $Label, $Value, $Verdict, $suffix)
}

function Invoke-Check {
  $failed = $false

  Write-Log '=== Smart Connect - Compatibility check ==='
  Write-Log ''

  Write-Log '--- Platform ---'
  $build     = [System.Environment]::OSVersion.Version.Build
  $psVersion = $PSVersionTable.PSVersion.ToString()
  Write-CheckRow 'OS:' (Get-WindowsDisplayName) 'OK'
  if ($build -ge 17763) { Write-CheckRow 'Build:' $build 'OK' 'needs 17763+' } else { Write-CheckRow 'Build:' $build 'FAIL' 'needs 17763+'; $failed = $true }
  if (Test-VersionAtLeast -Have $psVersion -Need '5.1') {
    Write-CheckRow 'PowerShell:' $psVersion 'OK' 'needs 5.1+'
  } else {
    Write-CheckRow 'PowerShell:' $psVersion 'FAIL' 'needs 5.1+'; $failed = $true
  }
  $pm = Get-PackageManager
  if ($pm -ne 'none') {
    $pmVersion = ''
    if ($pm -eq 'winget') { $pmVersion = (Invoke-Native -FilePath 'winget' -ArgumentList @('--version')).Output | Select-Object -First 1 }
    Write-CheckRow 'Package mgr:' ("{0} {1}" -f $pm, $pmVersion).Trim() 'OK'
  } else {
    Write-CheckRow 'Package mgr:' 'none detected' 'WARN' 'official installers will be used'
  }
  Write-Log ''

  Write-Log '--- SSH ---'
  $unit = Get-SshServiceName
  if ($unit) {
    $service = Get-Service -Name $unit -ErrorAction SilentlyContinue
    Write-CheckRow 'Capability:' 'OpenSSH.Server (built-in)' 'OK' 'installed with Windows'
    Write-CheckRow 'sshd service:' ('{0} ({1})' -f $unit, $service.Status) 'OK' 'detected'
  } else {
    # The DISM/CBS capability query is slow (tens of seconds); it is only needed
    # to confirm the feature can be installed, so only run it when no sshd
    # service exists yet.
    $capability = Get-OpenSshCapability
    if ($capability) {
      Write-CheckRow 'Capability:' ("OpenSSH.Server ({0})" -f $capability.State) 'OK' 'built-in on Windows 10 1809+'
    } else {
      Write-CheckRow 'Capability:' 'not installed' 'WARN' "run: .\$Self setup"
    }
    Write-CheckRow 'sshd service:' 'not detected' 'WARN' "run: .\$Self setup"
  }
  Write-Log ''

  Write-Log '--- Tailscale ---'
  $tailscale = Get-TailscaleExe
  if ($tailscale) {
    $tsVersion = ((Invoke-Native -FilePath $tailscale -ArgumentList @('version')).Output | Select-Object -First 1).Trim()
    if (Test-VersionAtLeast -Have $tsVersion -Need '1.30') {
      Write-CheckRow 'Tailscale:' $tsVersion 'OK' 'needs 1.30+'
    } else {
      Write-CheckRow 'Tailscale:' $tsVersion 'WARN' "1.30+ recommended; run .\$Self update"
    }
  } else {
    Write-CheckRow 'Tailscale:' 'not installed' 'WARN' "run: .\$Self setup"
  }
  $tsServiceName = Get-TailscaleServiceName
  $tsService = if ($tsServiceName) { Get-Service -Name $tsServiceName -ErrorAction SilentlyContinue } else { $null }
  if ($tsService) {
    Write-CheckRow "$tsServiceName`:" $tsService.Status.ToString() 'OK' 'service found'
    if ($tsService.Status -ne 'Running') { Write-CheckRow 'Hint:' "run .\$Self start" 'INFO' }
  } else {
    Write-CheckRow 'tailscaled:' 'service not found' 'WARN' "run: .\$Self setup"
  }
  Write-Log ''

  Write-Log '--- Web console (.\run.ps1 gui) ---'
  Write-CheckRow 'HTTP server:' 'built-in (.NET HttpListener)' 'OK'
  Write-CheckRow 'Browser:'     'default browser' 'OK'
  Write-Log ''

  if (-not $failed) {
    Write-Log 'Result: this system meets every requirement.'
  } else {
    Write-Err 'Result: some requirements are not met (see FAIL rows above).'
    exit 1
  }
}

# --- Web console --------------------------------------------------------
# The whole console backend lives inside run.ps1 now (it used to be
# server.ps1) so the project ships as a single Windows entry point.
function Start-Console {
  $Root    = $PSScriptRoot
  if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
  $HtmlPath = Join-Path $Root 'gui.html'
  $RunPs1   = Join-Path $Root 'run.ps1'
  $Allowed  = @('setup', 'start', 'stop', 'update', 'status', 'ip', 'check')
  $JobLimitMs = 1200000
  $MaxShellLen = 8192
  $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path $PowerShellExe)) { $PowerShellExe = (Get-Process -Id $PID).Path }

  # Mutable state kept in a hashtable so the nested helpers share it.
  $console = @{ Jobs = @{}; Seq = 0 }

  # --- Session token ----------------------------------------------------
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $tokenBytes = New-Object byte[] 24
  $rng.GetBytes($tokenBytes)
  $Token = [Convert]::ToBase64String($tokenBytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')

  # --- Background jobs (live streaming output) --------------------------
  function Start-RunJob {
    param([string[]]$RunArguments, [string]$ShellCommand)

    $console.Seq++
    $id = [string]$console.Seq

    if ($RunArguments) {
      $job = Start-Job -ScriptBlock {
        param($Exe, $Root, $a)
        & $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'run.ps1') @a 2>&1
        "__SC_EXIT__:$LASTEXITCODE"
      } -ArgumentList $PowerShellExe, $Root, $RunArguments
    } else {
      $job = Start-Job -ScriptBlock {
        param($Exe, $Command)
        $tmpScript = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.ps1')
        # Windows PowerShell 5.1 reads .ps1 files as ANSI unless they carry a BOM,
        # so write UTF-8 *with* a BOM to keep non-ASCII commands intact.
        [System.IO.File]::WriteAllText($tmpScript, $Command, (New-Object System.Text.UTF8Encoding($true)))
        try {
          & $Exe -NoProfile -ExecutionPolicy Bypass -File $tmpScript 2>&1
          "__SC_EXIT__:$LASTEXITCODE"
        } finally {
          Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
        }
      } -ArgumentList $PowerShellExe, $ShellCommand
    }

    $console.Jobs[$id] = @{ Id = $id; Job = $job; Running = $true; Code = $null; Output = ''; Started = [DateTime]::UtcNow }
    return $id
  }

  function Get-RunJobState {
    param([string]$Id)

    $record = $console.Jobs[$Id]
    if (-not $record) { return $null }

    if ($record.Running) {
      # Watchdog: never let a button or terminal command pin the console forever.
      if (([DateTime]::UtcNow - $record.Started).TotalMilliseconds -gt $JobLimitMs) {
        Stop-Job -Job $record.Job -ErrorAction SilentlyContinue
        foreach ($item in (Receive-Job -Job $record.Job -ErrorAction SilentlyContinue)) {
          $record.Output += "$item`n"
        }
        Remove-Job -Job $record.Job -Force -ErrorAction SilentlyContinue
        $record.Running = $false
        $record.Code = 124
        $record.Output += "[timed out after $([int]($JobLimitMs / 1000)) seconds]`n"
      } else {
        $received = Receive-Job -Job $record.Job -ErrorAction SilentlyContinue
        foreach ($item in $received) {
          $line = "$item"
          if ($line -match '^__SC_EXIT__:(-?\d+)$') { $record.Code = [int]$Matches[1]; continue }
          $record.Output += $line + "`n"
        }
        if ($record.Job.State -in @('Completed', 'Failed', 'Stopped')) {
          $record.Running = $false
          if ($null -eq $record.Code) {
            $record.Code = if ($record.Job.State -eq 'Completed') { 0 } else { 1 }
          }
          Remove-Job -Job $record.Job -Force -ErrorAction SilentlyContinue
        }
      }
    }

    return @{ id = $record.Id; running = [bool]$record.Running; code = $record.Code; output = $record.Output }
  }

  # --- Security helpers -------------------------------------------------
  function Test-TokenEqual {
    param([string]$Supplied, [string]$Expected)
    if (-not $Supplied -or -not $Expected) { return $false }
    if ($Supplied.Length -ne $Expected.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $Expected.Length; $i++) {
      $diff = $diff -bor ([int][char]$Supplied[$i] -bxor [int][char]$Expected[$i])
    }
    return ($diff -eq 0)
  }

  function Test-HostHeader {
    param($Request)
    $port = $Request.Url.Port
    $hostHeader = [string]$Request.Headers['Host']
    return ($hostHeader -eq "127.0.0.1:$port" -or $hostHeader -eq "localhost:$port")
  }

  function Test-OriginHeader {
    param($Request)
    $origin = [string]$Request.Headers['Origin']
    if (-not $origin) { return $true }  # same-origin GETs may omit Origin; token is still required
    try { $uri = [System.Uri]$origin } catch { return $false }
    return (($uri.Host -eq '127.0.0.1' -or $uri.Host -eq 'localhost') -and ($uri.Port -eq $Request.Url.Port))
  }

  function Test-Authorized {
    param($Request)
    $supplied = [string]$Request.Headers['X-Smart-Token']
    if (-not $supplied) { $supplied = [string]$Request.QueryString['t'] }
    return ((Test-HostHeader $Request) -and (Test-OriginHeader $Request) -and (Test-TokenEqual $supplied $Token))
  }

  function Start-SosRun {
    # Launch run.ps1 sos detached so the wipe survives this process and the
    # project folder being deleted.
    $hostExe = (Get-Process -Id $PID).Path
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostExe
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" sos' -f $RunPs1
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    [System.Diagnostics.Process]::Start($startInfo) | Out-Null
  }

  # --- HTTP responses ---------------------------------------------------
  function Write-Response {
    param($Response, [int]$StatusCode, [string]$Body, [string]$ContentType)

    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.ContentLength64 = $buffer.Length
    if ($buffer.Length -gt 0) { $Response.OutputStream.Write($buffer, 0, $buffer.Length) }
  }

  function Write-Json {
    param($Response, [int]$StatusCode, $Object)
    Write-Response $Response $StatusCode (($Object | ConvertTo-Json -Compress -Depth 5)) 'application/json; charset=utf-8'
  }

  # --- Request handling -------------------------------------------------
  function Handle-Request {
    param($Context)

    $request  = $Context.Request
    $response = $Context.Response
    try {
      $path = $request.Url.AbsolutePath

      if ($request.HttpMethod -eq 'GET' -and $path -eq '/') {
        if (-not (Test-Path $HtmlPath)) {
          Write-Response $response 500 'gui.html is missing from the Smart Connect folder.' 'text/plain; charset=utf-8'
          return
        }
        Write-Response $response 200 ([System.IO.File]::ReadAllText($HtmlPath)) 'text/html; charset=utf-8'
        return
      }

      if ($path -eq '/favicon.ico') {
        Write-Response $response 204 '' 'image/x-icon'
        return
      }

      if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/status') {
        if (-not (Test-Authorized $request)) { Write-Json $response 401 @{ error = 'unauthorized' }; return }
        # Status is computed in-process (all helpers are loaded in this process),
        # so the console's 4-second poll never pays for a full PowerShell child.
        try {
          Write-Response $response 200 (Invoke-StatusJson) 'application/json; charset=utf-8'
        } catch {
          Write-Json $response 500 @{ error = 'status failed'; raw = $_.Exception.Message }
        }
        return
      }

      if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/job') {
        if (-not (Test-Authorized $request)) { Write-Json $response 401 @{ error = 'unauthorized' }; return }
        $jobState = Get-RunJobState -Id ([string]$request.QueryString['id'])
        if (-not $jobState) { Write-Json $response 404 @{ error = 'unknown job' }; return }
        Write-Json $response 200 $jobState
        return
      }

      if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/sos') {
        if (-not (Test-Authorized $request)) { Write-Json $response 401 @{ error = 'unauthorized' }; return }

        $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
        try { $body = $reader.ReadToEnd() } finally { $reader.Close() }
        try { $payload = $body | ConvertFrom-Json } catch { Write-Json $response 400 @{ error = 'invalid JSON body' }; return }
        if ([string]$payload.confirm -ne 'SOS') { Write-Json $response 400 @{ error = 'confirmation required' }; return }

        Start-SosRun
        Write-Json $response 200 @{ ok = $true }
        return
      }

      if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/run') {
        if (-not (Test-Authorized $request)) { Write-Json $response 401 @{ error = 'unauthorized' }; return }

        $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
        try { $body = $reader.ReadToEnd() } finally { $reader.Close() }
        try { $payload = $body | ConvertFrom-Json } catch { Write-Json $response 400 @{ error = 'invalid JSON body' }; return }

        $jobId = $null
        if ($null -ne $payload.cmd) {
          $cmd = [string]$payload.cmd
          if ($Allowed -notcontains $cmd) { Write-Json $response 400 @{ error = 'unknown command' }; return }
          $jobId = Start-RunJob -RunArguments @($cmd)
        } elseif ($null -ne $payload.shell) {
          $command = ([string]$payload.shell).Trim()
          if (-not $command) { Write-Json $response 400 @{ error = 'empty command' }; return }
          if ($command.Length -gt $MaxShellLen) { Write-Json $response 400 @{ error = 'command too long' }; return }
          $jobId = Start-RunJob -ShellCommand $command
        } else {
          Write-Json $response 400 @{ error = 'missing cmd or shell' }; return
        }

        Write-Json $response 200 @{ job = $jobId }
        return
      }

      Write-Json $response 404 @{ error = 'not found' }
    } catch {
      try { Write-Json $response 500 @{ error = $_.Exception.Message } } catch { }
    } finally {
      $response.Close()
    }
  }

  # --- Main -------------------------------------------------------------
  if (-not (Test-Path $HtmlPath)) {
    Write-Host 'gui.html not found next to run.ps1. Re-clone the repository.'
    exit 1
  }

  $listener = $null
  $chosenPort = 0
  foreach ($attempt in 1..25) {
    $port = Get-Random -Minimum 8300 -Maximum 8999
    $candidate = New-Object System.Net.HttpListener
    $candidate.Prefixes.Add("http://127.0.0.1:$port/")
    try {
      $candidate.Start()
      $listener = $candidate
      $chosenPort = $port
      break
    } catch {
      $candidate.Close()
    }
  }

  if (-not $listener) {
    Write-Host 'Could not find a free port for the console (8300-8998).'
    Write-Host 'If you are not running as Administrator, launch it via: .\run.ps1 gui'
    exit 1
  }

  $url = "http://127.0.0.1:$chosenPort/?t=$Token"

  Write-Host 'Smart Connect web console'
  Write-Host ''
  Write-Host "  $url"
  Write-Host ''
  Write-Host 'Leave this window open; press Ctrl+C to stop.'
  try { Start-Process $url } catch { }

  try {
    while ($listener.IsListening) {
      $context = $listener.GetContext()
      Handle-Request -Context $context
    }
  } finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
  }
}

function Invoke-Gui {
  if (-not (Test-Path (Join-Path $PSScriptRoot 'gui.html'))) {
    Write-Err 'gui.html not found next to run.ps1. Re-clone the repository.'
    exit 1
  }
  Write-Log 'Starting the Smart Connect web console...'
  Write-Log 'Close this window or press Ctrl+C to stop it.'
  Write-Log ''
  Start-Console
}

# --- Dispatch -----------------------------------------------------------
$HasCommand = ($args.Count -ge 1)
$Name = 'help'
if ($HasCommand) { $Name = [string]$args[0] }

$Command = ''
switch -CaseSensitive ($Name) {
  'gui'      { $Command = 'gui' }
  'setup'    { $Command = 'setup' }
  'start'    { $Command = 'start' }
  'up'       { $Command = 'start' }
  'stop'     { $Command = 'stop' }
  'down'     { $Command = 'stop' }
  'update'   { $Command = 'update' }
  'status'   { if ($args.Count -ge 2 -and [string]$args[1] -eq '--json') { $Command = 'status-json' } else { $Command = 'status' } }
  'ip'       { $Command = 'ip' }
  'check'    { $Command = 'check' }
  'sos'      { $Command = 'sos' }
  'help'     { $Command = 'help' }
  '-h'       { $Command = 'help' }
  '--help'   { $Command = 'help' }
  default    {
    Write-Err "Unknown command: $Name"
    Write-Log ''
    Show-Usage
    exit 1
  }
}

if ($Command -eq 'help') {
  Show-Usage
  exit 0
}

if (-not (Test-WindowsOs)) {
  Write-Err 'Linux detected - this PowerShell entry point does not run on Linux.'
  [Console]::Error.WriteLine('')
  [Console]::Error.WriteLine('Use the Bash entry point instead (same commands):')
  [Console]::Error.WriteLine('')
  [Console]::Error.WriteLine('  ./run setup')
  [Console]::Error.WriteLine('')
  exit 1
}

if (-not $HasCommand) {
  # No command: open the web console when possible, otherwise show usage.
  if (Test-Path (Join-Path $PSScriptRoot 'gui.html')) { $Command = 'gui' } else { Show-Usage; exit 0 }
}

$NeedsAdministrator = @('gui', 'setup', 'start', 'stop', 'update', 'sos')
if ($NeedsAdministrator -contains $Command -and -not (Test-IsAdministrator)) {
  Invoke-ElevatedSelf -Argv @($Name)
}

switch ($Command) {
  'gui'         { Invoke-Gui }
  'setup'       { Invoke-Setup }
  'start'       { Invoke-Start }
  'stop'        { Invoke-Stop }
  'update'      { Invoke-Update }
  'status'      { Invoke-Status }
  'status-json' { Invoke-StatusJson }
  'ip'          { if (-not (Show-PrintIp)) { exit 1 } }
  'check'       { Invoke-Check }
  'sos'         { Invoke-Sos }
}

exit 0
