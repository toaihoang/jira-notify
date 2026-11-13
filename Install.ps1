<#
.SYNOPSIS
    Installs, updates or removes Jira Notify for the current Windows user.

.DESCRIPTION
    - Creates config.json in %LOCALAPPDATA%\JiraNotify on first install (asks for the Jira site;
      SinceDate = today), stores the Jira API token DPAPI-encrypted for this Windows user.
    - Registers the "JiraNotify" scheduled task: every IntervalMinutes, at logon, and 15 s after
      unlocking the screen.
    - Creates the "Check Jira now" shortcuts (Desktop + Start Menu) and runs a first check.

.PARAMETER TaskOnly
    Keep the stored token; only re-create the task, shortcuts and registrations
    (e.g. after changing IntervalMinutes in config.json, or after moving the scripts).

.PARAMETER Uninstall
    Remove the task, shortcuts, registrations and the whole data folder.

.PARAMETER JiraBaseUrl
    Jira Cloud site, e.g. https://your-company.atlassian.net. Asked for when missing.

.PARAMETER IntervalMinutes
    How often to check. Saved to config.json.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -TaskOnly
#>
param(
    [switch]$TaskOnly,
    [switch]$Uninstall,
    [string]$JiraBaseUrl,
    [int]$IntervalMinutes
)

$ErrorActionPreference = 'Stop'
$SrcDir = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $SrcDir 'JiraNotify.psm1') -Force

$context = Get-JiraNotifyContext
$CheckScript = Join-Path $SrcDir 'Invoke-JiraCheck.ps1'
$IgnoreScript = Join-Path $SrcDir 'Show-IgnoreWindow.ps1'
$ShortcutName = 'Check Jira now.lnk'
$ShortcutPaths = @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) $ShortcutName),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName)
)

function Write-Step([string]$Message)
{
    Write-Host $Message -ForegroundColor Green
}

function Uninstall-JiraNotify
{
    Unregister-ScheduledTask -TaskName $context.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $ShortcutPaths | Where-Object { Test-Path $_ } | Remove-Item -Force
    Remove-Item -Path "HKCU:\Software\Classes\AppUserModelId\$($context.AppId)" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Classes\$($context.ProtocolName)" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $context.DataDir)
    {
        Remove-Item $context.DataDir -Recurse -Force
    }
    Write-Step "Removed the task, shortcuts, registrations and $($context.DataDir)."
}

# Creates config.json on first install; applies -JiraBaseUrl / -IntervalMinutes when given.
function Initialize-Config
{
    $settings = Get-JiraNotifyDefaultConfig
    if (Test-Path $context.Config)
    {
        $existing = Read-JiraNotifyConfig $context.Config
        foreach ($name in @($settings.Keys))
        {
            $settings[$name] = $existing[$name]
        }
    }

    if ($JiraBaseUrl)
    {
        $settings.JiraBaseUrl = $JiraBaseUrl
    }
    if ($IntervalMinutes -gt 0)
    {
        $settings.IntervalMinutes = $IntervalMinutes
    }
    while (-not $settings.JiraBaseUrl)
    {
        $settings.JiraBaseUrl = Read-Host 'Jira Cloud site (e.g. https://your-company.atlassian.net)'
    }

    $config = ConvertTo-JiraNotifyConfig $settings
    Save-JiraNotifyConfig $config $context.Config
    Write-Step "Settings: $($context.Config)"
    return $config
}

function Initialize-Credential($Config)
{
    if ($TaskOnly)
    {
        if (-not (Test-Path $context.Credential))
        {
            throw 'No stored API token yet - run Install.ps1 once without -TaskOnly.'
        }
        Write-Step 'Keeping the stored API token.'
        return
    }

    Write-Host "Create an API token at $($context.TokenUrl)"
    $email = Read-Host 'Atlassian account email'
    $token = Read-Host 'Jira API token' -AsSecureString
    $credential = New-Object System.Management.Automation.PSCredential ($email, $token)

    $me = Get-JiraIdentity $Config.JiraBaseUrl (New-JiraAuthHeader $credential)
    Write-Step "Authenticated as $($me.displayName)."
    $credential | Export-Clixml -Path $context.Credential
    Remove-Item $context.FailureState -Force -ErrorAction SilentlyContinue
}

function Register-CheckTask($Config)
{
    # conhost --headless keeps a console window from flashing on every run.
    $arguments = '--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $CheckScript
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments
    $user = "$env:USERDOMAIN\$env:USERNAME"

    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $Config.IntervalMinutes)
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $user

    # Checks are skipped while the screen is locked, so check right after unlocking.
    $unlockClass = Get-CimClass -ClassName MSFT_TaskSessionStateChangeTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $unlock = New-CimInstance -CimClass $unlockClass -ClientOnly
    $unlock.StateChange = 8         # TASK_SESSION_UNLOCK
    $unlock.UserId = $user
    $unlock.Delay = 'PT15S'         # give the lock screen time to close
    $unlock.Enabled = $true

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    # Interactive logon: runs as you, only while you are signed in, which is what a toast needs.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

    try
    {
        Register-ScheduledTask -TaskName $context.TaskName -Action $action -Trigger @($repeat, $logon, $unlock) -Settings $settings `
            -Principal $principal -Description 'Jira Notify: toast for Jira tickets to start or to prepare for release' -Force | Out-Null
    }
    catch [Microsoft.Management.Infrastructure.CimException]
    {
        if ($_.Exception.Message -match 'Access is denied')
        {
            throw "Windows denied updating the '$($context.TaskName)' task. It was probably created from an administrator PowerShell - run this command from an administrator PowerShell too."
        }
        throw
    }
    Write-Step "Scheduled task '$($context.TaskName)': every $($Config.IntervalMinutes) min, at logon, on unlock."
}

function New-CheckShortcuts
{
    $arguments = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Manual' -f $CheckScript
    $shell = New-Object -ComObject WScript.Shell
    foreach ($path in $ShortcutPaths)
    {
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $SrcDir
        $shortcut.Description = 'Show my Jira tickets to start or to prepare for release'
        $shortcut.WindowStyle = 7
        if (Test-Path $context.IconIco)
        {
            $shortcut.IconLocation = "$($context.IconIco),0"
        }
        $shortcut.Save()
    }
    Write-Step ('Shortcuts: {0}' -f ($ShortcutPaths -join ', '))
}

if ($Uninstall)
{
    Uninstall-JiraNotify
    return
}

New-Item -ItemType Directory -Path $context.DataDir -Force | Out-Null
$config = Initialize-Config
Initialize-Credential $config
Register-JiraNotifyToastApp
Register-JiraNotifyProtocol $IgnoreScript
Register-CheckTask $config
New-CheckShortcuts

# First check: records the current tickets; shows a toast only if something matches.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CheckScript
Write-Step "Done. Log: $($context.Log)"
