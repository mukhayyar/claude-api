#!/usr/bin/env pwsh
# Run Claude Code against a non-subscription API model on Windows via psmux.
# Mirrors claude-api (bash) for PowerShell 7+ on Windows.
#
#   claude-api.ps1                 -> lists profiles
#   claude-api.ps1 mimo            -> attach/create psmux session for 'mimo'
#   claude-api.ps1 mimo --main     -> use ~/.claude config (resume default session with -r)
#   claude-api.ps1 mimo -- -p      -> args after -- are passed straight to claude
#
# Requires: PowerShell 7+, psmux (winget install psmux), claude, node (for local proxy).
# Add a model: drop $env:USERPROFILE\.claude-api\profiles\<name>.env (copy an .example).
Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

$ROOT = Join-Path $env:USERPROFILE ".claude-api"
$MAIN_SETTINGS = Join-Path $env:USERPROFILE ".claude\settings.json"

function Test-Command($cmd) {
  return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Ensure-Deps {
  if (-not (Test-Command "psmux")) {
    Write-Host "psmux not found. Install it with: winget install psmux" -ForegroundColor Red
    exit 1
  }
  if (-not (Test-Command "claude")) {
    Write-Host "claude not found. Install it with: npm install -g @anthropic-ai/claude-code" -ForegroundColor Red
    exit 1
  }
}

function Get-PluginDirs {
  $cache = Join-Path $env:USERPROFILE ".claude\plugins\cache"
  $flags = @()
  if (Test-Path $cache) {
    Get-ChildItem -Path $cache -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $versions = Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name
        $latest = $versions | Select-Object -Last 1
        if ($latest) {
          $flags += "--plugin-dir `"$($latest.FullName)`""
        }
      }
    }
  }
  return $flags -join " "
}

function Test-ProxyRunning($port) {
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("localhost", $port)
    $tcp.Close()
    return $true
  }
  catch {
    return $false
  }
}

function Start-Proxy($port) {
  if ([string]::IsNullOrWhiteSpace($port)) { return }
  if (Test-ProxyRunning $port) { return }

  Write-Host "starting llama proxy on port $port ..." -ForegroundColor Cyan
  $proxyLog = Join-Path $ROOT "proxy\$PROFILE.log"
  $proxyJs = Join-Path $ROOT "proxy\proxy.js"
  $null = Start-Process -FilePath "node" -ArgumentList "`"$proxyJs`"" `
    -RedirectStandardOutput $proxyLog -RedirectStandardError $proxyLog -WindowStyle Hidden

  for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 100
    if (Test-ProxyRunning $port) { return }
  }

  Write-Host "proxy failed to start. logs:" -ForegroundColor Red
  Get-Content $proxyLog -Tail 20 -ErrorAction SilentlyContinue
  exit 1
}

function Get-SessionName($profile, $useMain) {
  $base = Split-Path -Leaf (Get-Location)
  $hash = (Get-Location).Path.GetHashCode()
  $suffix = if ($useMain) { "-main" } else { "" }
  return "capi-$profile$suffix-$base-$hash"
}

function Invoke-SourceEnv($path) {
  Get-Content $path -ErrorAction Stop | ForEach-Object {
    $line = $_.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { return }
    if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      $name = $matches[1]
      $value = $matches[2]
      # Strip surrounding quotes if present
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
          ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
  }
}

$PROFILE_NAME = $args[0]

if ($PROFILE_NAME -eq "doctor") {
  Ensure-Deps
  Write-Host "ok: claude + psmux present."
  exit 0
}

if ([string]::IsNullOrWhiteSpace($PROFILE_NAME)) {
  Write-Host "profiles:"
  $profiles = Get-ChildItem -Path (Join-Path $ROOT "profiles") -Filter "*.env" -ErrorAction SilentlyContinue
  if ($profiles) {
    $profiles | ForEach-Object { Write-Host "  $($_.BaseName)" }
  }
  else {
    Write-Host "  (none)"
  }
  Write-Host "usage: claude-api.ps1 <profile> [--main] [-- <claude args>]"
  exit 0
}

$ENV_FILE = Join-Path $ROOT "profiles\$PROFILE_NAME.env"
if (-not (Test-Path $ENV_FILE)) {
  Write-Host "no such profile: $PROFILE_NAME ($ENV_FILE)" -ForegroundColor Red
  exit 1
}

Ensure-Deps

# Parse optional --main and -- separator
$remaining = $args | Select-Object -Skip 1
$USE_MAIN = $false
if ($remaining -and $remaining[0] -eq "--main") {
  $USE_MAIN = $true
  $remaining = $remaining | Select-Object -Skip 1
}
if ($remaining -and $remaining[0] -eq "--") {
  $remaining = $remaining | Select-Object -Skip 1
}

$CLAUDE_ARGS = $remaining -join " "

if ($USE_MAIN) {
  $CFG = Join-Path $env:USERPROFILE ".claude"
  New-Item -ItemType Directory -Force -Path $CFG | Out-Null
}
else {
  $CFG = Join-Path $ROOT "configs\$PROFILE_NAME"
  New-Item -ItemType Directory -Force -Path $CFG | Out-Null
  $claudeJson = Join-Path $CFG ".claude.json"
  if (-not (Test-Path $claudeJson)) {
    '{"hasCompletedOnboarding":true}' | Set-Content $claudeJson
  }
  # Seed settings from main config
  $settings = Join-Path $CFG "settings.json"
  if (-not (Test-Path $settings)) {
    if (Test-Path $MAIN_SETTINGS) {
      Copy-Item $MAIN_SETTINGS $settings
    }
    else {
      '{"includeCoAuthoredBy":false,"attribution":{"commit":"empty","pr":"empty"}}' | Set-Content $settings
    }
  }
}

# Load profile env
Invoke-SourceEnv $ENV_FILE

# Auto-start local llama proxy if configured
$proxyPort = [Environment]::GetEnvironmentVariable("LLAMA_PROXY_PORT", "Process")
if (-not [string]::IsNullOrWhiteSpace($proxyPort)) {
  Start-Proxy $proxyPort
}

# Permission prompts: skip by default for isolated configs; keep for --main
$skip = "--dangerously-skip-permissions"
if ($USE_MAIN -or $env:CLAUDE_API_SAFE -eq "1") {
  $skip = ""
}

$pluginFlags = Get-PluginDirs
$sessionName = Get-SessionName $PROFILE_NAME $USE_MAIN

$env:CLAUDE_CONFIG_DIR = $CFG

$hasSession = $false
& psmux has-session -t $sessionName 2>$null
if ($LASTEXITCODE -eq 0) { $hasSession = $true }

if (-not $hasSession) {
  $cmd = "claude $skip $pluginFlags $CLAUDE_ARGS"
  # Use Invoke-Expression so the psmux command sees a single string
  $pwdPath = (Get-Location).Path
  & psmux new-session -d -s $sessionName -c $pwdPath $cmd
}

& psmux attach -t $sessionName
