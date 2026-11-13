<#
.SYNOPSIS
    One Jira Notify check: fetch my tickets, compare with the last check, show a toast if needed.

.DESCRIPTION
    Run by the "JiraNotify" scheduled task (every few minutes, at logon, on unlock) and by the
    "Check Jira now" shortcut (-Manual). Settings come from config.json in the data folder.

    Toast rules:
      - automatic check : only when a ticket entered a group since the last check
      - morning reminder: once a day after MorningReminder, if the list is not empty
      - -Manual         : always (the current summary, or "nothing to do")

.PARAMETER Manual
    Always answer with a toast and ignore the locked-screen check.

.PARAMETER SinceDate
    Overrides SinceDate from config.json for this run (yyyy-MM-dd). Handy for trying it out.
#>
param(
    [switch]$Manual,
    [string]$SinceDate
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JiraNotify.psm1') -Force

$context = Get-JiraNotifyContext
New-Item -ItemType Directory -Path $context.DataDir -Force | Out-Null

function Show-SummaryToast($Issues, $LineIssues, $Config, $Query, [string]$TitlePrefix)
{
    $staging = @($Issues | Where-Object { $_.fields.status.name -eq $Config.StagingStatus }).Count
    $todo = @($Issues).Count - $staging

    $buttons = [ordered]@{}
    if ($todo -gt 0)
    {
        $buttons["To do ($todo)"] = Get-JiraSearchUrl $Config.JiraBaseUrl $Query.Todo
    }
    if ($staging -gt 0)
    {
        $buttons["Ready for Staging ($staging)"] = Get-JiraSearchUrl $Config.JiraBaseUrl $Query.StagingView
        $buttons['Ignore...'] = '{0}:ignore' -f $context.ProtocolName
    }

    $summary = Get-CountSummary $Issues $Config
    $lines = Get-ToastLines $LineIssues $Config.StagingStatus
    Show-JiraNotifyToast "${TitlePrefix}Jira: $summary" $lines (Get-JiraSearchUrl $Config.JiraBaseUrl $Query.AllView) 'summary' $buttons
    Write-JiraNotifyLog ('Toast: {0}{1} | listed: {2}' -f $TitlePrefix, $summary, ((@($LineIssues) | ForEach-Object { $_.key }) -join ', '))
}

function Show-NothingToast($Config)
{
    $url = "$($Config.JiraBaseUrl)/jira/your-work"
    $line = 'No {0} or {1} tickets since {2}.' -f ($Config.TodoStatuses -join ' / '), $Config.StagingStatus, $Config.SinceDate
    Show-JiraNotifyToast 'Jira: nothing to do' @($line) $url 'summary' ([ordered]@{ 'Open Jira' = $url })
    Write-JiraNotifyLog 'Toast: nothing (manual check)'
}

function Show-FailureToast([string]$Category, [string]$Message, [int]$FailCount, $Config)
{
    switch ($Category)
    {
        'auth'
        {
            Show-JiraNotifyToast 'Jira Notify: API token expired or invalid' @('Create a new token, then run Install.ps1 again.') $context.TokenUrl 'error' ([ordered]@{ 'Create token' = $context.TokenUrl })
        }
        'config'
        {
            Show-JiraNotifyToast 'Jira Notify: config.json has a problem' @($Message, $context.Config) $null 'error' ([ordered]@{})
        }
        default
        {
            $url = $null
            $buttons = [ordered]@{}
            if ($Config)
            {
                $url = "$($Config.JiraBaseUrl)/jira/your-work"
                $buttons['Open Jira'] = $url
            }
            Show-JiraNotifyToast 'Jira Notify cannot reach Jira' @(('Failed {0} time(s) in a row. Check network / VPN.' -f $FailCount), $Message) $url 'error' $buttons
        }
    }
}

$config = $null
try
{
    $overrides = @{}
    if ($SinceDate)
    {
        $overrides.SinceDate = $SinceDate
    }
    $config = Read-JiraNotifyConfig $context.Config $overrides

    # Locked screen: skip quietly. The task re-runs on unlock, and the state diff catches up.
    if ($config.SkipWhenLocked -and -not $Manual -and (Test-WorkstationLocked))
    {
        exit 0
    }

    Register-JiraNotifyToastApp
    Register-JiraNotifyProtocol (Join-Path $PSScriptRoot 'Show-IgnoreWindow.ps1')

    $headers = New-JiraAuthHeader (Get-JiraCredential $context.Credential)
    [void](Get-JiraIdentity $config.JiraBaseUrl $headers)

    $ignoredKeys = Read-IgnoredKeys $context.Ignored
    $query = New-JiraNotifyQuery $config $ignoredKeys
    $fetched = @(Find-JiraIssues $config.JiraBaseUrl $headers $query.All)
    Save-IssueCache $fetched $config.StagingStatus $context.Cache

    # @() at every call site: PS 5.1 unrolls a 1-item array to a single [pscustomobject],
    # which has no .Count there.
    $issues = @(Select-NotIgnoredIssues $fetched $ignoredKeys $config.StagingStatus)
    $seenState = Read-SeenState $context.State
    $isFirstRun = $null -eq $seenState
    $newIssues = @(Select-NewIssues $issues $seenState)
    $newKeys = @($newIssues | ForEach-Object { $_.key })
    # New tickets first, so they are the ones spelled out in the toast.
    $orderedIssues = @($newIssues) + @($issues | Where-Object { $newKeys -notcontains $_.key })

    if ($isFirstRun)
    {
        Write-JiraNotifyLog ('First run since {0}: {1}' -f $config.SinceDate, (Get-CountSummary $issues $config))
    }

    $now = Get-Date
    $isReminder = (-not $Manual) -and (Test-ReminderDue $config $now (Read-LastReminderDate $context.Reminder))
    if ($Manual)
    {
        if ($issues.Count -gt 0)
        {
            Show-SummaryToast $issues $orderedIssues $config $query ''
        }
        else
        {
            Show-NothingToast $config
        }
    }
    elseif ($isReminder -and $issues.Count -gt 0)
    {
        Show-SummaryToast $issues $orderedIssues $config $query 'Morning reminder - '
    }
    elseif ($newIssues.Count -gt 0)
    {
        Show-SummaryToast $issues $newIssues $config $query ''
    }

    # Replace (not merge) so a ticket that leaves a group and comes back is announced again.
    Save-SeenState @($issues | ForEach-Object { Get-IssueStateKey $_ }) $context.State
    if ($isReminder)
    {
        Save-LastReminderDate $context.Reminder $now
    }

    if (Test-Path $context.FailureState)
    {
        Remove-Item $context.FailureState -Force
        Write-JiraNotifyLog 'Recovered from previous error'
    }
}
catch
{
    $message = $_.Exception.Message
    $category = Get-FailureCategory $_.Exception (Get-HttpStatus $_)
    $failure = Read-FailureState $context.FailureState
    $failCount = $failure.Count + 1
    Write-JiraNotifyLog ('ERROR #{0} ({1}): {2}' -f $failCount, $category, $message)

    $threshold = 3
    if ($config)
    {
        $threshold = $config.FailuresBeforeToast
    }

    $notified = $failure.Notified
    if (Test-ShouldToastFailure $category $failCount $failure.Notified $threshold $Manual.IsPresent)
    {
        try
        {
            Show-FailureToast $category $message $failCount $config
            $notified = $true
        }
        catch
        {
            Write-JiraNotifyLog "ERROR showing toast: $($_.Exception.Message)"
        }
    }
    Save-FailureState $context.FailureState $failCount $notified
    exit 1
}
