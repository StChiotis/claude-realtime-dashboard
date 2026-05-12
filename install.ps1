#Requires -Version 5.1
<#
.SYNOPSIS
  Installs Claude Realtime Dashboard as the Claude Code statusline.

.DESCRIPTION
  - Copies statusline.ps1 to ~/.claude/statusline.ps1
  - Merges the statusLine block into ~/.claude/settings.json
    (preserves all other settings; backs up the file before modifying)
  - Prints "restart Claude Code" guidance when done

.NOTES
  Run from the repo root:  .\install.ps1
  If execution policy blocks it:  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>

$ErrorActionPreference = 'Stop'

# --- Paths ---
$ScriptDir = $PSScriptRoot
$Source    = Join-Path $ScriptDir 'statusline.ps1'
$Claude    = Join-Path $env:USERPROFILE '.claude'
$Dest      = Join-Path $Claude 'statusline.ps1'
$Settings  = Join-Path $Claude 'settings.json'

Write-Host ''
Write-Host 'Claude Realtime Dashboard installer' -ForegroundColor Cyan
Write-Host '===================================' -ForegroundColor Cyan

# --- Sanity check: the script we're installing must exist next to install.ps1 ---
if (-not (Test-Path $Source)) {
    Write-Host "ERROR: statusline.ps1 not found at $Source" -ForegroundColor Red
    Write-Host 'Run install.ps1 from the repo root (where statusline.ps1 lives).' -ForegroundColor Red
    exit 1
}

# --- Ensure ~/.claude/ exists ---
if (-not (Test-Path $Claude)) {
    New-Item -Path $Claude -ItemType Directory -Force | Out-Null
    Write-Host "Created  $Claude" -ForegroundColor Green
}

# --- Back up + copy statusline.ps1 ---
if (Test-Path $Dest) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$Dest.backup-$stamp"
    Copy-Item $Dest $backup -Force
    Write-Host "Backup   $backup" -ForegroundColor Yellow
}
Copy-Item $Source $Dest -Force
Write-Host "Copied   $Dest" -ForegroundColor Green

# --- Build the statusLine block ---
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Dest`""
$statusLineBlock = [PSCustomObject]@{
    type    = 'command'
    command = $cmd
}

# --- Read existing settings.json (or start fresh) ---
$settings = $null
if (Test-Path $Settings) {
    try {
        $settings = Get-Content $Settings -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "ERROR: $Settings is not valid JSON. Fix or remove it, then re-run." -ForegroundColor Red
        Write-Host "  Parse error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$Settings.backup-$stamp"
    Copy-Item $Settings $backup -Force
    Write-Host "Backup   $backup" -ForegroundColor Yellow
} else {
    $settings = [PSCustomObject]@{}
}

# --- Add or replace the statusLine property without clobbering other settings ---
if ($settings.PSObject.Properties.Name -contains 'statusLine') {
    $settings.statusLine = $statusLineBlock
} else {
    $settings | Add-Member -MemberType NoteProperty -Name 'statusLine' -Value $statusLineBlock
}

# --- Write back as UTF-8 no BOM (Claude Code reads UTF-8; BOM trips some parsers) ---
$json     = $settings | ConvertTo-Json -Depth 10
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($Settings, $json, $utf8NoBom)
Write-Host "Updated  $Settings" -ForegroundColor Green

Write-Host ''
Write-Host 'Install complete.' -ForegroundColor Cyan
Write-Host 'Restart Claude Code (close all sessions, then reopen) to see the dashboard.' -ForegroundColor Cyan
Write-Host ''
