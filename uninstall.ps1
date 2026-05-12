#Requires -Version 5.1
<#
.SYNOPSIS
  Removes Claude Realtime Dashboard from your Claude Code config.

.DESCRIPTION
  - Removes the statusLine block from ~/.claude/settings.json
    (backs up the file before modifying; preserves all other settings)
  - Deletes ~/.claude/statusline.ps1

.NOTES
  Run from the repo root:  .\uninstall.ps1
  If execution policy blocks it:  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>

$ErrorActionPreference = 'Stop'

$Claude   = Join-Path $env:USERPROFILE '.claude'
$Dest     = Join-Path $Claude 'statusline.ps1'
$Settings = Join-Path $Claude 'settings.json'

Write-Host ''
Write-Host 'Claude Realtime Dashboard uninstaller' -ForegroundColor Cyan
Write-Host '=====================================' -ForegroundColor Cyan

# --- Remove the script ---
if (Test-Path $Dest) {
    Remove-Item $Dest -Force
    Write-Host "Removed  $Dest" -ForegroundColor Green
} else {
    Write-Host "Skipped  $Dest (not present)" -ForegroundColor DarkGray
}

# --- Strip statusLine out of settings.json (preserve everything else) ---
if (Test-Path $Settings) {
    try {
        $settings = Get-Content $Settings -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "WARN: $Settings is not valid JSON; leaving it alone." -ForegroundColor Yellow
        Write-Host "  Parse error: $($_.Exception.Message)" -ForegroundColor Yellow
        exit 1
    }

    if ($settings.PSObject.Properties.Name -contains 'statusLine') {
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$Settings.backup-$stamp"
        Copy-Item $Settings $backup -Force
        Write-Host "Backup   $backup" -ForegroundColor Yellow

        $settings.PSObject.Properties.Remove('statusLine')

        $json     = $settings | ConvertTo-Json -Depth 10
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Settings, $json, $utf8NoBom)
        Write-Host "Updated  $Settings (statusLine removed)" -ForegroundColor Green
    } else {
        Write-Host "Skipped  $Settings (no statusLine block found)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "Skipped  $Settings (not present)" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Uninstall complete.' -ForegroundColor Cyan
Write-Host 'Restart Claude Code for the change to take effect.' -ForegroundColor Cyan
Write-Host ''
