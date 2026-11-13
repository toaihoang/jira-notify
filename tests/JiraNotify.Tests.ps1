# Pester 5 tests for the pure logic in src/JiraNotify.psm1.
# Offline: no Jira calls, no registry, no toasts. The data folder points at $TestDrive.
#   Invoke-Pester -Path .\tests -Output Detailed

BeforeAll {
    $env:JIRANOTIFY_DATA_DIR = Join-Path $TestDrive 'data'
    Import-Module (Join-Path $PSScriptRoot '..\src\JiraNotify.psm1') -Force

    function New-TestIssue([string]$Key, [string]$Status, [string]$Summary = 'Summary', [string]$CategoryChanged = '')
    {
        [pscustomobject]@{
            key    = $Key
            fields = [pscustomobject]@{
                summary                  = $Summary
                status                   = [pscustomobject]@{ name = $Status }
                statuscategorychangedate = $CategoryChanged
            }
        }
    }

    function New-TestConfig([hashtable]$Overrides = @{})
    {
        $source = @{ JiraBaseUrl = 'https://example.atlassian.net'; SinceDate = '2026-01-15' }
        ConvertTo-JiraNotifyConfig $source $Overrides
    }
}

AfterAll {
    Remove-Item Env:\JIRANOTIFY_DATA_DIR -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-JiraNotifyConfig' {
    It 'fills defaults around the required site' {
        $config = New-TestConfig
        $config.TodoStatuses | Should -Be @('Open', 'Reopened')
        $config.StagingStatus | Should -Be 'Ready for Staging'
        $config.IntervalMinutes | Should -Be 5
        $config.SkipWhenLocked | Should -BeTrue
    }

    It 'trims a trailing slash from the site' {
        (New-TestConfig @{ JiraBaseUrl = 'https://example.atlassian.net/' }).JiraBaseUrl | Should -Be 'https://example.atlassian.net'
    }

    It 'lets overrides win over the source' {
        (New-TestConfig @{ SinceDate = '2026-02-01' }).SinceDate | Should -Be '2026-02-01'
    }

    It 'accepts a PSCustomObject from ConvertFrom-Json' {
        $json = '{ "JiraBaseUrl": "https://example.atlassian.net", "TodoStatuses": ["To Do"], "MorningReminder": "" }' | ConvertFrom-Json
        $config = ConvertTo-JiraNotifyConfig $json
        $config.TodoStatuses | Should -Be @('To Do')
        $config.MorningReminder | Should -Be ''
    }

    It 'reads "false" as false, not as a non-empty string' {
        (New-TestConfig @{ SkipWhenLocked = 'false' }).SkipWhenLocked | Should -BeFalse
    }

    It 'rejects <Name> = <Value>' -TestCases @(
        @{ Name = 'JiraBaseUrl'; Value = '' }
        @{ Name = 'JiraBaseUrl'; Value = 'http://example.atlassian.net' }
        @{ Name = 'JiraBaseUrl'; Value = 'https://example.atlassian.net/jira' }
        @{ Name = 'SinceDate'; Value = '15/01/2026' }
        @{ Name = 'MorningReminder'; Value = '8h30' }
        @{ Name = 'IntervalMinutes'; Value = 0 }
        @{ Name = 'IntervalMinutes'; Value = 'five' }
        @{ Name = 'FailuresBeforeToast'; Value = 0 }
        @{ Name = 'StagingStatus'; Value = 'Ready "for" Staging' }
        @{ Name = 'SkipWhenLocked'; Value = 'maybe' }
    ) {
        param($Name, $Value)
        { New-TestConfig @{ $Name = $Value } } | Should -Throw -ExceptionType ([System.IO.InvalidDataException])
    }

    It 'rejects an empty TodoStatuses list' {
        { New-TestConfig @{ TodoStatuses = @() } } | Should -Throw -ExceptionType ([System.IO.InvalidDataException])
    }
}

Describe 'Save-JiraNotifyConfig / Read-JiraNotifyConfig' {
    It 'round-trips every setting' {
        $path = Join-Path $TestDrive 'config.json'
        $config = New-TestConfig @{ TodoStatuses = @('Open'); MorningReminder = ''; IntervalMinutes = 10 }
        Save-JiraNotifyConfig $config $path
        $read = Read-JiraNotifyConfig $path
        foreach ($name in (Get-JiraNotifyDefaultConfig).Keys)
        {
            $read[$name] | Should -Be $config[$name] -Because $name
        }
    }

    It 'explains a missing file' {
        { Read-JiraNotifyConfig (Join-Path $TestDrive 'missing.json') } | Should -Throw '*Install.ps1*'
    }

    It 'explains invalid JSON' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -Path $path -Value '{ "JiraBaseUrl": ' -Encoding UTF8
        { Read-JiraNotifyConfig $path } | Should -Throw '*not valid JSON*'
    }
}

Describe 'New-JiraNotifyQuery' {
    BeforeAll {
        $config = New-TestConfig
    }

    It 'uses "yyyy-MM-dd 00:00" so changes on SinceDate itself count' {
        $query = New-JiraNotifyQuery $config @()
        $query.All | Should -Match '"2026-01-15 00:00"'
        $query.All | Should -Not -Match '"2026-01-15"'
    }

    It 'adds one "status changed to" per to-do status' {
        $query = New-JiraNotifyQuery $config @()
        $query.Todo | Should -Match 'status in \("Open", "Reopened"\)'
        $query.Todo | Should -Match 'status changed to "Open" after'
        $query.Todo | Should -Match 'status changed to "Reopened" after'
        $query.Todo | Should -Match '^assignee = currentUser\(\)'
    }

    It 'uses "assignee was" for Ready for Staging' {
        (New-JiraNotifyQuery $config @()).Staging | Should -Match '^assignee was currentUser\(\) AND status = "Ready for Staging"'
    }

    It 'leaves ignored keys out of the view queries only' {
        $query = New-JiraNotifyQuery $config @('PROJ-1', 'PROJ-2')
        $query.StagingView | Should -Match 'key not in \(PROJ-1, PROJ-2\)'
        $query.AllView | Should -Match 'key not in'
        $query.All | Should -Not -Match 'key not in'
    }

    It 'never puts something that is not a key into JQL' {
        (New-JiraNotifyQuery $config @('PROJ-1) OR (1=1')).StagingView | Should -Not -Match 'key not in'
    }
}

Describe 'ConvertFrom-IgnoreList' {
    It 'keeps only Jira keys, upper-cased and unique' {
        $keys = ConvertFrom-IgnoreList @('# comment', '', '  proj-12  ', 'PROJ-12', 'not a key', 'AB2-7')
        $keys | Should -Be @('PROJ-12', 'AB2-7')
    }

    It 'round-trips through Save-IgnoredKeys / Read-IgnoredKeys' {
        $path = Join-Path $TestDrive 'ignored.txt'
        Save-IgnoredKeys @('PROJ-2', 'proj-1') $path
        Read-IgnoredKeys $path | Should -Be @('PROJ-1', 'PROJ-2')
        (Get-Content $path)[0] | Should -Match '^#'
    }

    It 'returns nothing when the file does not exist' {
        @(Read-IgnoredKeys (Join-Path $TestDrive 'none.txt')).Count | Should -Be 0
    }
}

Describe 'Select-NewIssues' {
    It 'treats every ticket as new on the first run' {
        @(Select-NewIssues @((New-TestIssue 'PROJ-1' 'Open')) $null).Count | Should -Be 1
    }

    It 'does not announce a ticket twice' {
        $issue = New-TestIssue 'PROJ-1' 'Open'
        @(Select-NewIssues @($issue) @('PROJ-1|Open')).Count | Should -Be 0
    }

    It 'announces a ticket again when its status changed' {
        $issue = New-TestIssue 'PROJ-1' 'Ready for Staging'
        @(Select-NewIssues @($issue) @('PROJ-1|In QA')).Count | Should -Be 1
    }
}

Describe 'Read-SeenState / Save-SeenState' {
    It 'returns $null before the first save' {
        Read-SeenState (Join-Path $TestDrive 'no-state.json') | Should -BeNullOrEmpty
        $null -eq (Read-SeenState (Join-Path $TestDrive 'no-state.json')) | Should -BeTrue
    }

    It 'round-trips a single entry as an array (PS 5.1 ConvertFrom-Json unrolling)' {
        $path = Join-Path $TestDrive 'state.json'
        Save-SeenState @('PROJ-1|Open') $path
        $state = Read-SeenState $path
        , $state | Should -BeOfType [object[]]
        $state | Should -Be @('PROJ-1|Open')
    }

    It 'round-trips an empty state as empty, not as $null' {
        $path = Join-Path $TestDrive 'empty-state.json'
        Save-SeenState @() $path
        $state = Read-SeenState $path
        $null -eq $state | Should -BeFalse
        $state.Count | Should -Be 0
    }
}

Describe 'Select-NotIgnoredIssues' {
    It 'drops an ignored ticket only while it is in Ready for Staging' {
        $issues = @(
            (New-TestIssue 'PROJ-1' 'Ready for Staging'),
            (New-TestIssue 'PROJ-2' 'Reopened'),
            (New-TestIssue 'PROJ-3' 'Ready for Staging')
        )
        $kept = Select-NotIgnoredIssues $issues @('PROJ-1', 'PROJ-2') 'Ready for Staging'
        @($kept | ForEach-Object { $_.key }) | Should -Be @('PROJ-2', 'PROJ-3')
    }
}

Describe 'Formatting' {
    It 'labels Ready for Staging as RFS' {
        Format-IssueLine (New-TestIssue 'PROJ-1' 'Ready for Staging' 'Fix it') 'Ready for Staging' | Should -Be 'PROJ-1 (RFS) Fix it'
    }

    It 'shortens long summaries with an ellipsis' {
        $line = Format-IssueLine (New-TestIssue 'PROJ-1' 'Open' ('x' * 100)) 'Ready for Staging' 20
        $line | Should -Be ('PROJ-1 (Open) ' + ('x' * 17) + '...')
    }

    It 'counts per status and leaves zero counts out' {
        $config = New-TestConfig
        $issues = @((New-TestIssue 'PROJ-1' 'Open'), (New-TestIssue 'PROJ-2' 'Ready for Staging'), (New-TestIssue 'PROJ-3' 'Ready for Staging'))
        Get-CountSummary $issues $config | Should -Be '1 Open, 2 Ready for Staging'
        Get-CountSummary @() $config | Should -Be 'nothing'
    }

    It 'shows <Count> ticket(s) in at most two lines' -TestCases @(
        @{ Count = 1; Lines = 1; More = $null }
        @{ Count = 2; Lines = 2; More = $null }
        @{ Count = 5; Lines = 2; More = '+3 more' }
    ) {
        param($Count, $Lines, $More)
        $issues = @(1..$Count | ForEach-Object { New-TestIssue "PROJ-$_" 'Open' })
        $result = @(Get-ToastLines $issues 'Ready for Staging')
        $result.Count | Should -Be $Lines
        if ($More)
        {
            $result[1] | Should -BeLike "*$More"
        }
    }
}

Describe 'Get-StagingSince' {
    It 'converts the Jira timestamp (+0700) to local time' {
        $issue = New-TestIssue 'PROJ-1' 'Ready for Staging' 'x' '2026-01-15T17:04:29.022+0700'
        $expected = [DateTimeOffset]::Parse('2026-01-15T17:04:29.022+07:00').LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        Get-StagingSince $issue 'Ready for Staging' | Should -Be $expected
    }

    It 'is empty for tickets that are not in Ready for Staging' {
        $issue = New-TestIssue 'PROJ-1' 'Open' 'x' '2026-01-15T17:04:29.022+0700'
        Get-StagingSince $issue 'Ready for Staging' | Should -Be ''
    }
}

Describe 'Test-ReminderDue' {
    BeforeAll {
        $config = New-TestConfig
        $wednesday = [datetime]'2026-01-14'
    }

    It 'is due after the reminder time on a weekday' {
        Test-ReminderDue $config $wednesday.AddHours(9) '' | Should -BeTrue
    }

    It 'is not due before the reminder time' {
        Test-ReminderDue $config $wednesday.AddHours(8) '' | Should -BeFalse
    }

    It 'is not due twice on the same day' {
        Test-ReminderDue $config $wednesday.AddHours(9) '2026-01-14' | Should -BeFalse
    }

    It 'skips weekends unless told otherwise' {
        $saturday = [datetime]'2026-01-17 09:00'
        Test-ReminderDue $config $saturday '' | Should -BeFalse
        Test-ReminderDue (New-TestConfig @{ MorningReminderWeekdaysOnly = $false }) $saturday '' | Should -BeTrue
    }

    It 'can be turned off' {
        Test-ReminderDue (New-TestConfig @{ MorningReminder = '' }) $wednesday.AddHours(9) '' | Should -BeFalse
    }
}

Describe 'Failure policy' {
    It 'classifies <Expected>' -TestCases @(
        @{ Exception = (New-Object System.IO.InvalidDataException 'x'); Status = 0; Expected = 'config' }
        @{ Exception = (New-Object System.UnauthorizedAccessException 'x'); Status = 0; Expected = 'auth' }
        @{ Exception = (New-Object System.Exception 'x'); Status = 401; Expected = 'auth' }
        @{ Exception = (New-Object System.Exception 'x'); Status = 403; Expected = 'auth' }
        @{ Exception = (New-Object System.Net.WebException 'x'); Status = 0; Expected = 'network' }
        @{ Exception = (New-Object System.Exception 'x'); Status = 500; Expected = 'network' }
    ) {
        param($Exception, $Status, $Expected)
        Get-FailureCategory $Exception $Status | Should -Be $Expected
    }

    It 'reports auth and config problems at once, once' {
        Test-ShouldToastFailure 'auth' 1 $false 3 $false | Should -BeTrue
        Test-ShouldToastFailure 'config' 1 $false 3 $false | Should -BeTrue
        Test-ShouldToastFailure 'auth' 2 $true 3 $false | Should -BeFalse
    }

    It 'waits for <Threshold> network failures in a row' -TestCases @(@{ Threshold = 3 }) {
        param($Threshold)
        Test-ShouldToastFailure 'network' ($Threshold - 1) $false $Threshold $false | Should -BeFalse
        Test-ShouldToastFailure 'network' $Threshold $false $Threshold $false | Should -BeTrue
        Test-ShouldToastFailure 'network' ($Threshold + 1) $true $Threshold $false | Should -BeFalse
    }

    It 'always answers a manual check' {
        Test-ShouldToastFailure 'network' 1 $true 3 $true | Should -BeTrue
    }

    It 'round-trips the failure state, tolerating the old one-line format' {
        $path = Join-Path $TestDrive 'last-error.txt'
        Save-FailureState $path 2 $true
        $state = Read-FailureState $path
        $state.Count | Should -Be 2
        $state.Notified | Should -BeTrue

        Set-Content -Path $path -Value 'The remote name could not be resolved'
        (Read-FailureState $path).Count | Should -Be 0
    }
}

Describe 'Source files' {
    It '<Name> is ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI)' -TestCases @(
        Get-ChildItem (Join-Path $PSScriptRoot '..') -Recurse -Include '*.ps1', '*.psm1' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        param($Name, $Path)
        @([IO.File]::ReadAllBytes($Path) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It '<Name> parses without errors' -TestCases @(
        Get-ChildItem (Join-Path $PSScriptRoot '..') -Recurse -Include '*.ps1', '*.psm1' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        param($Name, $Path)
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
