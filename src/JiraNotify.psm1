# JiraNotify.psm1 - shared code for Jira Notify.
#
# Pure functions (config, JQL, state diff, formatting, reminder, failure policy) take every
# input as a parameter so they can be unit-tested; the functions that touch Jira, the file
# system, the registry or the notification system are kept thin.
#
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only: 5.1 reads BOM-less files as ANSI.

#region Context

# Identifiers and file locations. Set $env:JIRANOTIFY_DATA_DIR to use another data folder
# (the tests do this).
function Get-JiraNotifyContext
{
    $dataDir = $env:JIRANOTIFY_DATA_DIR
    if (-not $dataDir)
    {
        $dataDir = Join-Path $env:LOCALAPPDATA 'JiraNotify'
    }

    return [pscustomobject]@{
        AppId        = 'JiraNotify'
        AppName      = 'Jira Notify'
        ProtocolName = 'jiranotify'
        TaskName     = 'JiraNotify'
        ToastGroup   = 'JiraNotify'
        TokenUrl     = 'https://id.atlassian.com/manage-profile/security/api-tokens'
        DataDir      = $dataDir
        Config       = Join-Path $dataDir 'config.json'
        Ignored      = Join-Path $dataDir 'ignored.txt'
        Credential   = Join-Path $dataDir 'credential.xml'
        State        = Join-Path $dataDir 'seen-v2.json'
        Cache        = Join-Path $dataDir 'last-issues.json'
        FailureState = Join-Path $dataDir 'last-error.txt'
        Reminder     = Join-Path $dataDir 'last-reminder.txt'
        Log          = Join-Path $dataDir 'jira-notify.log'
        # Bump the file names whenever the icon changes: Windows caches the toast icon per path.
        IconPng      = Join-Path $dataDir 'icon-v2.png'
        IconIco      = Join-Path $dataDir 'icon-v2.ico'
    }
}

function Write-JiraNotifyLog([string]$Message)
{
    $context = Get-JiraNotifyContext
    New-Item -ItemType Directory -Path $context.DataDir -Force | Out-Null

    # Keep the log small: start over once it passes 1 MB, keeping one old copy.
    if ((Test-Path $context.Log) -and (Get-Item $context.Log).Length -gt 1MB)
    {
        Move-Item $context.Log "$($context.Log).old" -Force
    }

    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Add-Content -Path $context.Log -Value $line -Encoding UTF8
}

#endregion

#region Config

function Get-JiraNotifyDefaultConfig
{
    return [ordered]@{
        JiraBaseUrl                 = ''
        TodoStatuses                = @('Open', 'Reopened')
        StagingStatus               = 'Ready for Staging'
        SinceDate                   = (Get-Date -Format 'yyyy-MM-dd')
        IntervalMinutes             = 5
        FailuresBeforeToast         = 3
        MorningReminder             = '08:30'
        MorningReminderWeekdaysOnly = $true
        SkipWhenLocked              = $true
    }
}

function New-JiraNotifyConfigException([string]$Message)
{
    return New-Object System.IO.InvalidDataException "config.json: $Message"
}

function Test-ExactDateFormat([string]$Value, [string]$Format)
{
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact($Value, $Format, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)
}

# Name -> value pairs from a hashtable or from the PSCustomObject that ConvertFrom-Json returns.
function Get-SettingPairs($Source)
{
    if ($null -eq $Source)
    {
        return @()
    }
    if ($Source -is [System.Collections.IDictionary])
    {
        return @($Source.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Source[$_] } })
    }
    return @($Source.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
}

# Defaults <- $Source (config.json) <- $Overrides (command line), then validated and normalised.
# Throws InvalidDataException with a readable message on any bad value.
function ConvertTo-JiraNotifyConfig($Source, [hashtable]$Overrides)
{
    $config = @{}
    $defaults = Get-JiraNotifyDefaultConfig
    foreach ($name in $defaults.Keys)
    {
        $config[$name] = $defaults[$name]
    }
    foreach ($pair in @(Get-SettingPairs $Source) + @(Get-SettingPairs $Overrides))
    {
        if ($config.ContainsKey($pair.Name) -and $null -ne $pair.Value)
        {
            $config[$pair.Name] = $pair.Value
        }
    }

    $config.JiraBaseUrl = ([string]$config.JiraBaseUrl).Trim().TrimEnd('/')
    if ($config.JiraBaseUrl -notmatch '^https://[^/\s]+$')
    {
        throw (New-JiraNotifyConfigException "JiraBaseUrl must look like https://your-company.atlassian.net (got '$($config.JiraBaseUrl)')")
    }

    $config.TodoStatuses = @($config.TodoStatuses | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $config.StagingStatus = ([string]$config.StagingStatus).Trim()
    if ($config.TodoStatuses.Count -eq 0)
    {
        throw (New-JiraNotifyConfigException 'TodoStatuses needs at least one status')
    }
    if (-not $config.StagingStatus)
    {
        throw (New-JiraNotifyConfigException 'StagingStatus is empty')
    }
    foreach ($status in @($config.TodoStatuses) + @($config.StagingStatus))
    {
        if ($status.Contains('"'))
        {
            throw (New-JiraNotifyConfigException "status names cannot contain double quotes (got '$status')")
        }
    }

    $config.SinceDate = [string]$config.SinceDate
    if (-not (Test-ExactDateFormat $config.SinceDate 'yyyy-MM-dd'))
    {
        throw (New-JiraNotifyConfigException "SinceDate must look like 2026-01-31 (got '$($config.SinceDate)')")
    }

    $config.MorningReminder = [string]$config.MorningReminder
    if ($config.MorningReminder -and -not (Test-ExactDateFormat $config.MorningReminder 'HH:mm'))
    {
        throw (New-JiraNotifyConfigException "MorningReminder must look like 08:30, or be empty to turn it off (got '$($config.MorningReminder)')")
    }

    $interval = 0
    if (-not [int]::TryParse([string]$config.IntervalMinutes, [ref]$interval) -or $interval -lt 1 -or $interval -gt 1440)
    {
        throw (New-JiraNotifyConfigException "IntervalMinutes must be a whole number from 1 to 1440 (got '$($config.IntervalMinutes)')")
    }
    $config.IntervalMinutes = $interval

    $failures = 0
    if (-not [int]::TryParse([string]$config.FailuresBeforeToast, [ref]$failures) -or $failures -lt 1)
    {
        throw (New-JiraNotifyConfigException "FailuresBeforeToast must be a whole number of 1 or more (got '$($config.FailuresBeforeToast)')")
    }
    $config.FailuresBeforeToast = $failures

    foreach ($name in 'MorningReminderWeekdaysOnly', 'SkipWhenLocked')
    {
        $config[$name] = ConvertTo-SettingBool $config[$name] $name
    }
    return $config
}

# [bool]"false" is $true in PowerShell, so accept real booleans and the strings "true"/"false".
function ConvertTo-SettingBool($Value, [string]$Name)
{
    if ($Value -is [bool])
    {
        return $Value
    }
    switch -Regex ([string]$Value)
    {
        '^\s*true\s*$' { return $true }
        '^\s*false\s*$' { return $false }
    }
    throw (New-JiraNotifyConfigException "$Name must be true or false (got '$Value')")
}

function Read-JiraNotifyConfig([string]$Path, [hashtable]$Overrides)
{
    if (-not (Test-Path $Path))
    {
        throw (New-JiraNotifyConfigException "not found at $Path - run Install.ps1 first")
    }

    try
    {
        $json = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch
    {
        throw (New-JiraNotifyConfigException "not valid JSON - $($_.Exception.Message)")
    }
    return ConvertTo-JiraNotifyConfig $json $Overrides
}

# Writes the keys in the documented order, one per line (PS 5.1 ConvertTo-Json output is hard to read).
function Save-JiraNotifyConfig($Config, [string]$Path)
{
    $lines = foreach ($name in (Get-JiraNotifyDefaultConfig).Keys)
    {
        '    "{0}": {1}' -f $name, (ConvertTo-Json -InputObject $Config[$name] -Compress)
    }
    $json = "{`r`n" + ($lines -join ",`r`n") + "`r`n}"
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

#endregion

#region JQL

# Builds the queries for the two groups:
#   To do             : assigned to me now, in a TodoStatus, and created / assigned to me /
#                       moved back to that status since SinceDate
#   Ready for Staging : assigned to me at any time (QA reassigns tickets on the way to RFS),
#                       and moved to RFS since SinceDate
# *View queries leave the ignored RFS tickets out; they are only used for the Jira links.
function New-JiraNotifyQuery($Config, [string[]]$IgnoredKeys)
{
    # CHANGED ... AFTER "2026-01-31" excludes that whole day; "2026-01-31 00:00" includes it.
    $since = '{0} 00:00' -f $Config.SinceDate

    $todoIn = ($Config.TodoStatuses | ForEach-Object { '"{0}"' -f $_ }) -join ', '
    $todoChanged = ($Config.TodoStatuses | ForEach-Object { 'status changed to "{0}" after "{1}"' -f $_, $since }) -join ' OR '
    $todo = 'assignee = currentUser() AND status in ({0}) AND (created >= "{1}" OR assignee changed to currentUser() after "{1}" OR {2})' -f $todoIn, $since, $todoChanged
    $staging = 'assignee was currentUser() AND status = "{0}" AND status changed to "{0}" after "{1}"' -f $Config.StagingStatus, $since

    $stagingView = $staging
    $keys = @($IgnoredKeys | Where-Object { $_ -match '^[A-Z][A-Z0-9]*-\d+$' })
    if ($keys.Count -gt 0)
    {
        $stagingView = '{0} AND key not in ({1})' -f $staging, ($keys -join ', ')
    }

    return [pscustomobject]@{
        Todo        = $todo
        Staging     = $staging
        StagingView = $stagingView
        All         = '({0}) OR ({1}) ORDER BY updated DESC' -f $todo, $staging
        AllView     = '({0}) OR ({1}) ORDER BY updated DESC' -f $todo, $stagingView
    }
}

function Get-JiraSearchUrl([string]$BaseUrl, [string]$Jql)
{
    return '{0}/issues/?jql={1}' -f $BaseUrl, [Uri]::EscapeDataString($Jql)
}

#endregion

#region Jira API (read-only: GET /myself and GET /search/jql only)

function Get-JiraCredential([string]$Path)
{
    if (-not (Test-Path $Path))
    {
        throw (New-Object System.UnauthorizedAccessException "API token not found at $Path - run Install.ps1")
    }
    # PSCredential exported with Export-Clixml is DPAPI-encrypted for this Windows user.
    return Import-Clixml -Path $Path
}

function New-JiraAuthHeader([System.Management.Automation.PSCredential]$Credential)
{
    $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    return @{ Authorization = "Basic $token"; Accept = 'application/json' }
}

# A bad or expired token is NOT rejected by /search/jql: Jira treats it as anonymous and returns
# 200 with 0 issues, which would silently look like "nothing to do". /myself returns 401.
function Get-JiraIdentity([string]$BaseUrl, [hashtable]$Headers)
{
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $me = Invoke-RestMethod -Method Get -Uri "$BaseUrl/rest/api/3/myself" -Headers $Headers -TimeoutSec 30
    if (-not $me.accountId)
    {
        throw (New-Object System.UnauthorizedAccessException 'Jira did not recognise the API token (anonymous session)')
    }
    return $me
}

function Find-JiraIssues([string]$BaseUrl, [hashtable]$Headers, [string]$Jql)
{
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $issues = @()
    $nextPageToken = $null
    do
    {
        $query = 'jql={0}&fields=summary,status,statuscategorychangedate&maxResults=100' -f [Uri]::EscapeDataString($Jql)
        if ($nextPageToken)
        {
            $query += '&nextPageToken=' + [Uri]::EscapeDataString($nextPageToken)
        }

        $response = Invoke-RestMethod -Method Get -Uri "$BaseUrl/rest/api/3/search/jql?$query" -Headers $Headers -TimeoutSec 30
        $issues += @($response.issues)
        $nextPageToken = $response.nextPageToken
    }
    while ($nextPageToken -and -not $response.isLast)

    return $issues
}

#endregion

#region Ignore list

# Keys from the lines of ignored.txt: trimmed, upper-cased, de-duplicated; comments, blank
# lines and anything that is not a Jira key are skipped.
function ConvertFrom-IgnoreList([string[]]$Lines)
{
    return @($Lines |
        ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } |
        Where-Object { $_ -match '^[A-Z][A-Z0-9]*-\d+$' } |
        Select-Object -Unique)
}

function Read-IgnoredKeys([string]$Path)
{
    if (-not (Test-Path $Path))
    {
        return @()
    }
    return ConvertFrom-IgnoreList @(Get-Content -Path $Path -Encoding UTF8)
}

function Save-IgnoredKeys([string[]]$Keys, [string]$Path)
{
    $lines = @(
        '# Jira Notify - tickets to stay quiet about while they are in Ready for Staging.',
        '# One key per line. Remove a line (or untick it in the Ignore window) to be notified again.'
    ) + @(ConvertFrom-IgnoreList $Keys | Sort-Object)
    Set-Content -Path $Path -Value $lines -Encoding UTF8
}

#endregion

#region Issues: state diff, filtering, formatting

# "KEY|Status": a status change (e.g. In QA -> Ready for Staging) makes the ticket new again.
function Get-IssueStateKey($Issue)
{
    return '{0}|{1}' -f $Issue.key, $Issue.fields.status.name
}

function Select-NewIssues($Issues, [string[]]$SeenState)
{
    return @($Issues | Where-Object { @($SeenState) -notcontains (Get-IssueStateKey $_) })
}

# Ignored tickets are dropped only while in Ready for Staging; reopened ones show up again.
function Select-NotIgnoredIssues($Issues, [string[]]$IgnoredKeys, [string]$StagingStatus)
{
    return @($Issues | Where-Object { -not (($_.fields.status.name -eq $StagingStatus) -and (@($IgnoredKeys) -contains $_.key)) })
}

function Read-SeenState([string]$Path)
{
    if (-not (Test-Path $Path))
    {
        return $null
    }
    # PS 5.1 emits a JSON array from ConvertFrom-Json as ONE object; ForEach-Object unrolls it,
    # otherwise @() wraps it into a 1-item array and every issue looks new on every run.
    # (Unroll first, then cast: casting the whole array to [string] would join it into one string.)
    return , @(Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object { [string]$_ })
}

function Save-SeenState([string[]]$StateKeys, [string]$Path)
{
    ConvertTo-Json -InputObject @($StateKeys) -Compress | Set-Content -Path $Path -Encoding UTF8
}

# When the ticket entered Ready for Staging, as local "yyyy-MM-dd HH:mm". RFS is the only watched
# status in the Done category, so the status-category change date is the RFS date.
function Get-StagingSince($Issue, [string]$StagingStatus)
{
    $raw = [string]$Issue.fields.statuscategorychangedate
    if (($Issue.fields.status.name -ne $StagingStatus) -or -not $raw)
    {
        return ''
    }

    # Jira sends "+0700"; DateTimeOffset wants "+07:00".
    $iso = $raw -replace '([+-]\d{2})(\d{2})$', '$1:$2'
    return [DateTimeOffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
}

function Format-IssueLine($Issue, [string]$StagingStatus, [int]$MaxLength = 70)
{
    $status = [string]$Issue.fields.status.name
    if ($status -eq $StagingStatus)
    {
        $status = 'RFS'
    }

    $summary = [string]$Issue.fields.summary
    if ($summary.Length -gt $MaxLength)
    {
        $summary = $summary.Substring(0, $MaxLength - 3).TrimEnd() + '...'
    }
    return '{0} ({1}) {2}' -f $Issue.key, $status, $summary
}

# "2 Open, 1 Reopened, 3 Ready for Staging" - zero counts are left out.
function Get-CountSummary($Issues, $Config)
{
    $parts = @()
    foreach ($status in @($Config.TodoStatuses) + @($Config.StagingStatus))
    {
        $count = @($Issues | Where-Object { $_.fields.status.name -eq $status }).Count
        if ($count -gt 0)
        {
            $parts += '{0} {1}' -f $count, $status
        }
    }

    if ($parts.Count -eq 0)
    {
        return 'nothing'
    }
    return $parts -join ', '
}

# A toast fits two body lines: the first ticket, then the second one or "<second>  +N more".
function Get-ToastLines($LineIssues, [string]$StagingStatus)
{
    $LineIssues = @($LineIssues)
    if ($LineIssues.Count -eq 0)
    {
        return @()
    }

    $lines = @(Format-IssueLine $LineIssues[0] $StagingStatus)
    if ($LineIssues.Count -eq 2)
    {
        $lines += Format-IssueLine $LineIssues[1] $StagingStatus
    }
    elseif ($LineIssues.Count -gt 2)
    {
        $lines += '{0}  +{1} more' -f (Format-IssueLine $LineIssues[1] $StagingStatus 45), ($LineIssues.Count - 2)
    }
    return $lines
}

# Last fetched tickets (ignored ones too), so the Ignore window can list them without calling Jira.
function Save-IssueCache($Issues, [string]$StagingStatus, [string]$Path)
{
    $rows = @($Issues | ForEach-Object {
        [pscustomobject]@{
            key          = $_.key
            status       = $_.fields.status.name
            summary      = $_.fields.summary
            stagingSince = (Get-StagingSince $_ $StagingStatus)
        }
    })
    ConvertTo-Json -InputObject $rows | Set-Content -Path $Path -Encoding UTF8
}

function Read-IssueCache([string]$Path)
{
    if (-not (Test-Path $Path))
    {
        return @()
    }
    return @(Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
}

#endregion

#region Morning reminder

# Once a day, at the first check after MorningReminder (so a late start still gets it).
function Test-ReminderDue($Config, [datetime]$Now, [string]$LastReminderDate)
{
    if (-not $Config.MorningReminder)
    {
        return $false
    }
    if ($Config.MorningReminderWeekdaysOnly -and ($Now.DayOfWeek -eq [DayOfWeek]::Saturday -or $Now.DayOfWeek -eq [DayOfWeek]::Sunday))
    {
        return $false
    }

    $time = [datetime]::ParseExact($Config.MorningReminder, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture).TimeOfDay
    if ($Now -lt $Now.Date.Add($time))
    {
        return $false
    }
    return $LastReminderDate -ne $Now.ToString('yyyy-MM-dd')
}

function Read-LastReminderDate([string]$Path)
{
    if (-not (Test-Path $Path))
    {
        return ''
    }
    return ([string](Get-Content -Path $Path -Raw)).Trim()
}

function Save-LastReminderDate([string]$Path, [datetime]$Date)
{
    Set-Content -Path $Path -Value $Date.ToString('yyyy-MM-dd') -Encoding ASCII
}

#endregion

#region Failure policy

function Get-HttpStatus($ErrorRecord)
{
    try
    {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch
    {
        return 0
    }
}

# 'config' and 'auth' never fix themselves; anything else is treated as a network blip.
function Get-FailureCategory([Exception]$Exception, [int]$HttpStatus)
{
    if ($Exception -is [System.IO.InvalidDataException])
    {
        return 'config'
    }
    if (($HttpStatus -eq 401) -or ($HttpStatus -eq 403) -or ($Exception -is [System.UnauthorizedAccessException]))
    {
        return 'auth'
    }
    return 'network'
}

# One toast per outage: auth/config at once, network after $Threshold failures in a row.
# A manual check always answers.
function Test-ShouldToastFailure([string]$Category, [int]$FailCount, [bool]$AlreadyNotified, [int]$Threshold, [bool]$Manual)
{
    if ($Manual)
    {
        return $true
    }
    if ($AlreadyNotified)
    {
        return $false
    }
    return ($Category -ne 'network') -or ($FailCount -ge [Math]::Max(1, $Threshold))
}

function Read-FailureState([string]$Path)
{
    $state = [pscustomobject]@{ Count = 0; Notified = $false }
    if (Test-Path $Path)
    {
        $saved = @(Get-Content -Path $Path)
        $count = 0
        [void][int]::TryParse([string]$saved[0], [ref]$count)
        $state.Count = $count
        $state.Notified = ($saved.Count -gt 1) -and ($saved[1] -eq 'notified')
    }
    return $state
}

function Save-FailureState([string]$Path, [int]$Count, [bool]$Notified)
{
    Set-Content -Path $Path -Value @($Count, $(if ($Notified) { 'notified' } else { '' })) -Encoding UTF8
}

#endregion

#region Windows integration

# The lock screen runs LogonUI.exe in our session; it exits again once you unlock.
function Test-WorkstationLocked
{
    $session = (Get-Process -Id $PID).SessionId
    return [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
}

# Draws the blue "J" icon as PNG (toasts) and ICO (shortcuts, window).
function New-JiraNotifyIcon([string]$PngPath, [string]$IcoPath)
{
    Add-Type -AssemblyName System.Drawing
    $size = 128
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try
    {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)

        $radius = [int]($size * 0.22)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $radius * 2, $radius * 2, 180, 90)
        $path.AddArc($size - $radius * 2 - 1, 0, $radius * 2, $radius * 2, 270, 90)
        $path.AddArc($size - $radius * 2 - 1, $size - $radius * 2 - 1, $radius * 2, $radius * 2, 0, 90)
        $path.AddArc(0, $size - $radius * 2 - 1, $radius * 2, $radius * 2, 90, 90)
        $path.CloseFigure()
        $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 101, 255))), $path)

        $font = New-Object System.Drawing.Font 'Segoe UI', ([int]($size * 0.56)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString('J', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, ($size * 0.03), $size, $size), $format)

        $bmp.Save($PngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally
    {
        $g.Dispose()
        $bmp.Dispose()
    }

    # PNG-in-ICO (Vista+): a 22-byte header followed by the PNG bytes.
    $png = [IO.File]::ReadAllBytes($PngPath)
    $stream = New-Object IO.MemoryStream
    $writer = New-Object IO.BinaryWriter $stream
    $writer.Write([UInt16]0)                # reserved
    $writer.Write([UInt16]1)                # type: icon
    $writer.Write([UInt16]1)                # image count
    $writer.Write([byte]($size % 256))      # width (0 means 256)
    $writer.Write([byte]($size % 256))      # height
    $writer.Write([byte]0)                  # palette size
    $writer.Write([byte]0)                  # reserved
    $writer.Write([UInt16]1)                # color planes
    $writer.Write([UInt16]32)               # bits per pixel
    $writer.Write([UInt32]$png.Length)
    $writer.Write([UInt32]22)               # offset = 6 (header) + 16 (entry)
    $writer.Write($png)
    $writer.Flush()
    [IO.File]::WriteAllBytes($IcoPath, $stream.ToArray())
    $writer.Dispose()
}

# Registers "Jira Notify" (name + icon) as the toast sender instead of "Windows PowerShell".
# Per-user registry, no admin needed. Also lets the user mute it in Settings > Notifications.
function Register-JiraNotifyToastApp
{
    $context = Get-JiraNotifyContext
    $key = "HKCU:\Software\Classes\AppUserModelId\$($context.AppId)"
    $registeredIcon = (Get-ItemProperty -Path $key -Name IconUri -ErrorAction SilentlyContinue).IconUri
    if ((Test-Path $context.IconPng) -and (Test-Path $context.IconIco) -and ($registeredIcon -eq $context.IconPng))
    {
        return
    }

    New-Item -ItemType Directory -Path $context.DataDir -Force | Out-Null
    New-JiraNotifyIcon $context.IconPng $context.IconIco
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name DisplayName -Value $context.AppName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name IconUri -Value $context.IconPng -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name IconBackgroundColor -Value 'FF0065FF' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name ShowInSettings -Value 1 -PropertyType DWord -Force | Out-Null
    Write-JiraNotifyLog "Registered toast app '$($context.AppName)'"
}

# "jiranotify:ignore" (toast button) opens the Ignore window. Per-user registry, no admin.
function Register-JiraNotifyProtocol([string]$IgnoreWindowScript)
{
    $context = Get-JiraNotifyContext
    $key = "HKCU:\Software\Classes\$($context.ProtocolName)"
    $command = '"{0}" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "{1}" "%1"' -f (Join-Path $env:SystemRoot 'System32\conhost.exe'), $IgnoreWindowScript
    $registered = (Get-ItemProperty -Path "$key\shell\open\command" -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
    if ($registered -eq $command)
    {
        return
    }

    New-Item -Path "$key\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path $key -Name '(default)' -Value 'URL:Jira Notify'
    New-ItemProperty -Path $key -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    Set-ItemProperty -Path "$key\shell\open\command" -Name '(default)' -Value $command
    Write-JiraNotifyLog "Registered protocol '$($context.ProtocolName):'"
}

# $Lines: up to 2 body lines. $Buttons: ordered hashtable label -> URL (max 4); $null = a single
# "Open" button for $Url, empty = only "Dismiss". $Url $null = clicking the body does nothing.
# The same $Tag replaces the previous toast in the Notification Center instead of stacking.
function Show-JiraNotifyToast([string]$Title, [string[]]$Lines, [string]$Url, [string]$Tag, [System.Collections.IDictionary]$Buttons)
{
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $context = Get-JiraNotifyContext
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    if ($null -eq $Buttons)
    {
        $Buttons = [ordered]@{ 'Open' = $Url }
    }

    $launch = ''
    if ($Url)
    {
        $launch = ' activationType="protocol" launch="{0}"' -f (& $esc $Url)
    }
    $texts = (@($Title) + @($Lines | Select-Object -First 2) | ForEach-Object {
        '      <text>{0}</text>' -f (& $esc $_)
    }) -join [Environment]::NewLine
    $actions = ($Buttons.GetEnumerator() | ForEach-Object {
        '    <action content="{0}" activationType="protocol" arguments="{1}" />' -f (& $esc $_.Key), (& $esc $_.Value)
    }) -join [Environment]::NewLine

    $xml = @"
<toast$launch scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
$texts
    </binding>
  </visual>
  <actions>
$actions
    <action content="Dismiss" activationType="system" arguments="dismiss" />
  </actions>
</toast>
"@

    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
    if ($Tag)
    {
        $toast.Tag = $Tag
        $toast.Group = $context.ToastGroup
    }
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($context.AppId).Show($toast)
}

function Remove-JiraNotifyToast([string]$Tag)
{
    $context = Get-JiraNotifyContext
    try
    {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($Tag, $context.ToastGroup, $context.AppId)
    }
    catch
    {
        Write-JiraNotifyLog "Could not remove toast '$Tag': $($_.Exception.Message)"
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-JiraNotifyContext', 'Write-JiraNotifyLog',
    'Get-JiraNotifyDefaultConfig', 'ConvertTo-JiraNotifyConfig', 'Read-JiraNotifyConfig', 'Save-JiraNotifyConfig',
    'New-JiraNotifyQuery', 'Get-JiraSearchUrl',
    'Get-JiraCredential', 'New-JiraAuthHeader', 'Get-JiraIdentity', 'Find-JiraIssues',
    'ConvertFrom-IgnoreList', 'Read-IgnoredKeys', 'Save-IgnoredKeys',
    'Get-IssueStateKey', 'Select-NewIssues', 'Select-NotIgnoredIssues', 'Read-SeenState', 'Save-SeenState',
    'Get-StagingSince', 'Format-IssueLine', 'Get-CountSummary', 'Get-ToastLines', 'Save-IssueCache', 'Read-IssueCache',
    'Test-ReminderDue', 'Read-LastReminderDate', 'Save-LastReminderDate',
    'Get-HttpStatus', 'Get-FailureCategory', 'Test-ShouldToastFailure', 'Read-FailureState', 'Save-FailureState',
    'Test-WorkstationLocked', 'New-JiraNotifyIcon', 'Register-JiraNotifyToastApp', 'Register-JiraNotifyProtocol',
    'Show-JiraNotifyToast', 'Remove-JiraNotifyToast'
)
