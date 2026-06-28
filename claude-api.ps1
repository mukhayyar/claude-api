#!/usr/bin/env pwsh
# Run Claude Code against a non-subscription API model on Windows via psmux.
# Mirrors claude-api (bash) for PowerShell 7+ on Windows.
#
#   claude-api.ps1                 -> lists profiles
#   claude-api.ps1 mimo            -> attach/create psmux session for 'mimo'
#   claude-api.ps1 mimo --main     -> use ~/.claude config (resume default session with -r)
#   claude-api.ps1 mimo -- -p      -> args after -- are passed straight to claude
#   claude-api.ps1 create-profile  -> interactively create a new profile
#
# Requires: PowerShell 7+, psmux (winget install psmux), claude, node (for local proxy).
# Add a model: drop $env:USERPROFILE\.claude-api\profiles\<name>.env (copy an .example).
Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

$ROOT = Join-Path $env:USERPROFILE ".claude-api"
$MAIN_SETTINGS = Join-Path $env:USERPROFILE ".claude\settings.json"

function Print-Banner {
  Write-Host @"
   _____ _                 _         _      _____ _   _ _____
  /  __ \ |               | |       | |    |_   _| \ | |  __ \
  | /  \/ | __ _ _ __ ___ | |    ___| |_     | | |  \| | |  \/
  | |   | |/ _` | '_ ` _ \| |   / _ \ __|    | | | . ` | | __
  | \__/\ | (_| | | | | | | |__|  __/ |_    _| |_| |\  | |_\ \
   \____/_|\__,_|_| |_| |_|_____\___|\__|   \___/\_| \__/____/

"@
  Write-Host "  Claude Code, any API. Stay in Claude no matter which model you use."
  Write-Host
}

function Print-Help {
  Print-Banner
  Write-Host @"
USAGE
  claude-api.ps1 <profile> [--main] [-- <claude args>]
  claude-api.ps1 create-profile
  claude-api.ps1 doctor
  claude-api.ps1 --help | -h

COMMANDS
  <profile>        Launch a profile in an isolated psmux session.
  create-profile   Interactively create a new `$env:USERPROFILE\.claude-api\profiles\*.env file.
  doctor           Check that claude and psmux are installed.
  --help, -h       Show this help message.

FLAGS
  --main           Use your default `$env:USERPROFILE\.claude config dir instead of an isolated
                   one. This lets <profile> use the profile's API while letting
                   <claude args> like -r resume your main subscription sessions.
  --               Everything after -- is passed straight to claude.

EXAMPLES
  claude-api.ps1 deepseek
  claude-api.ps1 kimi -- -p "hi"
  claude-api.ps1 kimi --main -- -r
  claude-api.ps1 create-profile

ENVIRONMENT
  `$env:CLAUDE_API_SAFE = "1"   Keep normal permission prompts in isolated profiles.

PROFILES
  Real profiles live in `$env:USERPROFILE\.claude-api\profiles\*.env and are gitignored.
  Example templates are in `$env:USERPROFILE\.claude-api\profiles\*.env.example.
"@
}

function Test-Command($cmd) {
  return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Prompt-Input($msg, $default = $null) {
  if ($default) {
    $in = Read-Host "$msg [$default]"
    if ([string]::IsNullOrWhiteSpace($in)) { return $default }
    return $in
  }
  return Read-Host "$msg"
}

function Prompt-Secret($msg) {
  return Read-Host -AsSecureString "$msg" | ConvertFrom-SecureString -AsPlainText
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
  $proxyLog = Join-Path $ROOT "proxy\$PROFILE_NAME.log"
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
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
          ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
  }
}

function New-InteractiveProfile {
  Print-Banner
  Write-Host "Create a new claude-api profile"
  Write-Host

  $name = Prompt-Input "Profile name (e.g. deepseek, kimi, my-mimo)"
  if ([string]::IsNullOrWhiteSpace($name)) {
    Write-Host "Profile name is required." -ForegroundColor Red
    exit 1
  }

  $profilePath = Join-Path $ROOT "profiles\$name.env"
  if (Test-Path $profilePath) {
    $overwrite = Read-Host "Profile '$name' already exists. Overwrite? [y/N]"
    if ($overwrite -notmatch '^[Yy]$') {
      Write-Host "Aborted."
      exit 0
    }
  }

  Write-Host
  Write-Host "Choose a provider template:"
  Write-Host "  1) DeepSeek"
  Write-Host "  2) Moonshot Kimi"
  Write-Host "  3) Xiaomi MiMo"
  Write-Host "  4) Local llama.cpp (via proxy)"
  Write-Host "  5) Custom"
  $choice = Prompt-Input "Provider" "5"

  switch ($choice) {
    "1" { $baseUrl = "https://api.deepseek.com/anthropic"; $model = "deepseek-v4-pro[1m]" }
    "2" { $baseUrl = "https://api.moonshot.ai/anthropic"; $model = "kimi-k2.7-code" }
    "3" { $baseUrl = "https://api.example-mimo.com"; $model = "mimo-v2.5-pro[1m]" }
    "4" { $baseUrl = "http://localhost:4000"; $model = "claude-sonnet-4-6" }
    default {
      $baseUrl = Prompt-Input "Anthropic-compatible base URL"
      $model = Prompt-Input "Model name"
    }
  }

  if ($choice -eq "4") {
    $authToken = "no-key"
  }
  else {
    $authToken = Prompt-Secret "API key"
  }

  New-Item -ItemType Directory -Force -Path (Join-Path $ROOT "profiles") | Out-Null
  $content = @"
# claude-api profile: $name
ANTHROPIC_AUTH_TOKEN=$authToken
ANTHROPIC_BASE_URL=$baseUrl
ANTHROPIC_MODEL=$model
ANTHROPIC_DEFAULT_SONNET_MODEL=$model
ANTHROPIC_DEFAULT_OPUS_MODEL=$model
ANTHROPIC_DEFAULT_HAIKU_MODEL=$model
CLAUDE_CODE_SUBAGENT_MODEL=$model
"@

  if ($choice -eq "4") {
    $content += @"

# Proxy configuration
LLAMA_PROXY_PORT=4000
LLAMA_OPENAI_BASE_URL=http://localhost:8081/v1
LLAMA_OPENAI_MODEL=Qwen3.5-0.8B-Q5_K_M
LLAMA_OPENAI_API_KEY=no-key
"@
  }

  $content | Set-Content $profilePath
  Write-Host
  Write-Host "Created profile: $profilePath"
  Write-Host "Launch it with: claude-api.ps1 $name"
}

$PROFILE_NAME = $args[0]

if ([string]::IsNullOrWhiteSpace($PROFILE_NAME) -or $PROFILE_NAME -eq "--help" -or $PROFILE_NAME -eq "-h") {
  Print-Help
  exit 0
}

if ($PROFILE_NAME -eq "doctor") {
  Ensure-Deps
  Write-Host "ok: claude + psmux present."
  exit 0
}

if ($PROFILE_NAME -eq "create-profile") {
  New-InteractiveProfile
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
  $pwdPath = (Get-Location).Path
  & psmux new-session -d -s $sessionName -c $pwdPath $cmd
}

& psmux attach -t $sessionName
