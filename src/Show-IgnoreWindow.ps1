<#
.SYNOPSIS
    Jira Notify - pick the Ready for Staging tickets you do not want to be notified about.

.DESCRIPTION
    Opened by the "Ignore..." toast button through the jiranotify: protocol (or run directly).
    Lists the RFS tickets from the last check (no Jira call), newest first, with the date they
    entered RFS. Double-click a row to open the ticket in Jira. Saves ignored.txt in the data folder.

.PARAMETER Uri
    The jiranotify: URI that launched the window. Not used; accepted so the protocol handler works.
#>
param(
    [string]$Uri
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JiraNotify.psm1') -Force

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$context = Get-JiraNotifyContext

# Rows: Key, Since ("yyyy-MM-dd HH:mm" or ''), Text, Ignored.
# Returns the ticked keys, or $null on Cancel.
function Show-IgnoreWindow($Rows, [string]$JiraBaseUrl)
{
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Jira Notify - Ready for Staging tickets'
    $form.ClientSize = New-Object System.Drawing.Size 780, 420
    $form.MinimumSize = New-Object System.Drawing.Size 560, 300
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Font = New-Object System.Drawing.Font 'Segoe UI', 9
    if (Test-Path $context.IconIco)
    {
        $form.Icon = New-Object System.Drawing.Icon $context.IconIco
    }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Tick the tickets that need no prod script - they are not notified while they stay in Ready for Staging (untick to be notified again).`r`nDouble-click a row to open the ticket in Jira."
    $label.Location = New-Object System.Drawing.Point 12, 10
    $label.Size = New-Object System.Drawing.Size 756, 36
    $label.Anchor = 'Top, Left, Right'

    $list = New-Object System.Windows.Forms.ListView
    $list.View = [System.Windows.Forms.View]::Details
    $list.CheckBoxes = $true
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.ShowItemToolTips = $true
    $list.Location = New-Object System.Drawing.Point 12, 52
    $list.Size = New-Object System.Drawing.Size 756, 316
    $list.Anchor = 'Top, Bottom, Left, Right'
    [void]$list.Columns.Add('Ticket', 100)
    [void]$list.Columns.Add('In RFS since', 120)
    [void]$list.Columns.Add('Summary', 510)

    foreach ($row in $Rows)
    {
        $item = New-Object System.Windows.Forms.ListViewItem $row.Key
        [void]$item.SubItems.Add($row.Since)
        [void]$item.SubItems.Add($row.Text)
        $item.Checked = $row.Ignored
        $item.Tag = $row.Key
        $item.ToolTipText = $row.Text
        [void]$list.Items.Add($item)
    }

    # A ListView with checkboxes toggles the tick on double-click; here double-click means
    # "open in Jira", so cancel that toggle.
    $script:IgnoreUi = @{ SuppressCheck = $false }
    $list.Add_MouseDown({ param($sender, $e) $script:IgnoreUi.SuppressCheck = ($e.Clicks -gt 1) })
    $list.Add_MouseUp({ $script:IgnoreUi.SuppressCheck = $false })
    $list.Add_ItemCheck({
        param($sender, $e)
        if ($script:IgnoreUi.SuppressCheck)
        {
            $e.NewValue = $e.CurrentValue
        }
    })
    $list.Add_MouseDoubleClick({
        param($sender, $e)
        $hit = $sender.HitTest($e.Location).Item
        if ($hit)
        {
            Start-Process ('{0}/browse/{1}' -f $JiraBaseUrl, $hit.Tag)
        }
    }.GetNewClosure())

    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save'
    $save.Location = New-Object System.Drawing.Point 592, 380
    $save.Size = New-Object System.Drawing.Size 85, 30
    $save.Anchor = 'Bottom, Right'
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point 683, 380
    $cancel.Size = New-Object System.Drawing.Size 85, 30
    $cancel.Anchor = 'Bottom, Right'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.Controls.AddRange(@($label, $list, $save, $cancel))
    $form.AcceptButton = $save
    $form.CancelButton = $cancel

    try
    {
        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK)
        {
            return $null
        }
        # Leading comma: keep an empty selection as an empty array (untick all = save empty),
        # otherwise PowerShell unrolls it to $null, which means Cancel.
        return , @($list.CheckedItems | ForEach-Object { [string]$_.Tag })
    }
    finally
    {
        $form.Dispose()
    }
}

try
{
    $config = Read-JiraNotifyConfig $context.Config
    $ignored = @(Read-IgnoredKeys $context.Ignored)
    $staging = @(Read-IssueCache $context.Cache | Where-Object { $_.status -eq $config.StagingStatus })

    # Current RFS tickets, newest first; then ignored ones that are no longer there (so they can
    # still be unticked).
    $rows = @($staging | ForEach-Object {
        [pscustomobject]@{ Key = [string]$_.key; Since = [string]$_.stagingSince; Text = [string]$_.summary; Ignored = ($ignored -contains $_.key) }
    } | Sort-Object -Property Since -Descending)
    $listedKeys = @($rows | ForEach-Object { $_.Key })
    $rows += @($ignored | Where-Object { $listedKeys -notcontains $_ } | ForEach-Object {
        [pscustomobject]@{ Key = $_; Since = ''; Text = '(not in Ready for Staging at the last check)'; Ignored = $true }
    })

    if ($rows.Count -eq 0)
    {
        [void][System.Windows.Forms.MessageBox]::Show('There are no Ready for Staging tickets right now.', 'Jira Notify', 'OK', 'Information')
        return
    }

    $checkedKeys = Show-IgnoreWindow $rows $config.JiraBaseUrl
    if ($null -eq $checkedKeys)
    {
        return
    }

    Save-IgnoredKeys $checkedKeys $context.Ignored
    Write-JiraNotifyLog ('Ignored list saved: {0}' -f $(if ($checkedKeys.Count -gt 0) { $checkedKeys -join ', ' } else { '(empty)' }))

    # The summary toast still lists the ticket that was just ignored, so take it down.
    if (@($checkedKeys | Where-Object { $ignored -notcontains $_ }).Count -gt 0)
    {
        Remove-JiraNotifyToast 'summary'
    }
}
catch
{
    Write-JiraNotifyLog "ERROR (Ignore window): $($_.Exception.Message)"
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Jira Notify', 'OK', 'Error')
    exit 1
}
