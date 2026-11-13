# Jira Notify

[![tests](../../actions/workflows/tests.yml/badge.svg)](../../actions/workflows/tests.yml)
[Tiếng Việt](README.vi.md)

Windows desktop notifications for the Jira tickets that need you, so you never miss one:

- **To do**: a ticket assigned to you that is **Open** or **Reopened**, so you can start it.
- **Ready for Staging (RFS)**: a ticket you worked on that reached **Ready for Staging**, so you can check whether it needs a prod script or deploy step before release.

It checks Jira every few minutes. When something new appears it shows **one summary toast**; otherwise it stays quiet.

```
Jira Notify
Jira: 1 Open, 2 Ready for Staging
PROJ-128 (RFS) [Billing] Rounding error on invoices over 10,000...
PROJ-131 (Open) [Search] Add filter by warehouse  +1 more
[ To do (1) ]  [ Ready for Staging (2) ]  [ Ignore... ]  [ Dismiss ]
```

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Daily use](#daily-use)
- [Which tickets are notified](#which-tickets-are-notified)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Privacy and security](#privacy-and-security)
- [Verify it yourself](#verify-it-yourself)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

## Requirements

- Windows 10 or 11 with **Windows PowerShell 5.1**, which is built in. Nothing else to install.
- **Jira Cloud** (`*.atlassian.net`) and an **API token** for your own Atlassian account.
- Your Jira workflow has the statuses you want to watch. The defaults are `Open`, `Reopened` and `Ready for Staging`, and all three can be changed.

## Install

1. Get the code, either `git clone https://github.com/toaihoang/jira-notify.git` or **Code > Download ZIP** and unzip it. Keep the folder where it is: the scheduled task runs the scripts from there.
2. Create an API token at <https://id.atlassian.com/manage-profile/security/api-tokens>.
3. Open **PowerShell** in the folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install.ps1
   ```

4. Answer the three questions: your Jira site (e.g. `https://your-company.atlassian.net`), your Atlassian email, and the token. The token is not shown while you type.

The installer:
- checks the token against Jira and stores it encrypted for your Windows user;
- writes your settings to `%LOCALAPPDATA%\JiraNotify\config.json`, with `SinceDate` set to **today**;
- registers the `JiraNotify` scheduled task, which runs every 5 minutes, at logon and 15 seconds after you unlock the screen;
- creates a **Check Jira now** shortcut on the Desktop and in the Start Menu;
- runs a first check.

### Update, move or re-apply settings

After a `git pull`, after moving the folder, or after changing `IntervalMinutes`, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -TaskOnly
```

This keeps the stored token and settings and re-creates the task, the shortcuts and the registrations.

> If the task was first created from an **administrator** PowerShell, Windows only lets an administrator PowerShell update it. The installer tells you when that happens.

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
```

This removes the task, the shortcuts, both registry registrations and `%LOCALAPPDATA%\JiraNotify` (token, settings, ignored list, log). Then delete the folder.

## Daily use

### The toast

- **Title**: how many tickets are in each status, e.g. `Jira: 1 Open, 2 Ready for Staging`.
- **Body**: the new tickets, with key, status and summary. If more than two are new, the rest are shown as `+N more`.
- **Click the toast**: opens Jira with all the listed tickets.
- **To do (n)** / **Ready for Staging (n)**: opens Jira with just that group.
- **Ignore...**: opens the [Ignore window](#ignore-tickets-that-need-no-prod-script) (only shown when there are RFS tickets).

A ticket is announced **once**, when it enters a group. It is not announced again every few minutes. Missed toasts stay in the Notification Center (`Win + N`).

### Check Jira now

Double-click the **Check Jira now** shortcut to see the current summary at once. It always answers, with `Jira: nothing to do` when nothing matches.

### Morning reminder

On weekdays at **08:30**, if there are still tickets in the list, you get a `Morning reminder - Jira: ...` toast. If the PC is locked or off at that time, the reminder comes at the first check after it. There is one reminder per day.

### Ignore tickets that need no prod script

1. Click **Ignore...** on the toast. The window lists every RFS ticket with the date it entered RFS, newest first.
2. **Double-click** a row to open the ticket in Jira.
3. Tick the tickets that need no prod script and click **Save**.

Ignored tickets:
- are left out of new toasts, the morning reminder, the counts and the Jira links;
- are hidden **only while they stay in Ready for Staging**. If one goes back to Open or Reopened, you are notified again.

To be notified about a ticket again, untick it, or delete its line from `%LOCALAPPDATA%\JiraNotify\ignored.txt`.

### Locked screen

While the screen is locked, checks are skipped, so Jira is not called. The task runs again 15 seconds after you unlock. Nothing is lost, because every check compares against the previous one.

## Which tickets are notified

| Group | Rule |
|---|---|
| To do | Assigned to you **now**, in one of `TodoStatuses`, and since `SinceDate` it was created, assigned to you, or moved back to that status. |
| Ready for Staging | Assigned to you **at any time**, and moved to `StagingStatus` since `SinceDate`. QA often reassigns tickets on the way to RFS, so "at any time" is needed. |

Tickets that have sat in these statuses since before `SinceDate` are ignored, so an old backlog does not flood you on day one.

## Configuration

Settings live in `%LOCALAPPDATA%\JiraNotify\config.json` (an example is in [`config.example.json`](config.example.json)). Changes apply at the next check, except `IntervalMinutes`, which needs `Install.ps1 -TaskOnly`.

| Key | Default | Meaning |
|---|---|---|
| `JiraBaseUrl` | asked at install | Your Jira Cloud site, `https://...` with no path. |
| `TodoStatuses` | `["Open", "Reopened"]` | Statuses that count as work to start. |
| `StagingStatus` | `"Ready for Staging"` | The release-ready status, spelled exactly as in Jira. |
| `SinceDate` | install date | Only activity on or after this date counts (`yyyy-MM-dd`). |
| `IntervalMinutes` | `5` | How often the task runs (1 to 1440). |
| `FailuresBeforeToast` | `3` | Network failures in a row before an error toast. |
| `MorningReminder` | `"08:30"` | Time of the daily reminder (`HH:mm`). Use `""` to turn it off. |
| `MorningReminderWeekdaysOnly` | `true` | Skip the reminder on Saturday and Sunday. |
| `SkipWhenLocked` | `true` | Do not check while the screen is locked. |

If `config.json` has a mistake, you get one toast naming it, for example `MorningReminder must look like 08:30`.

## How it works

Plain PowerShell: no compiled code, no external modules, no downloads. It talks to nothing but your Jira site.

```
 Task Scheduler (every N min / logon / unlock)        "Check Jira now" shortcut
              |                                                |  (-Manual)
              v                                                v
 +------------------------------ src/Invoke-JiraCheck.ps1 -------------------------------+
 | 1. read config.json          4. GET /rest/api/3/myself      (is the token valid?)     |
 | 2. screen locked? -> stop    5. GET /rest/api/3/search/jql  (your tickets)            |
 | 3. decrypt token (DPAPI)     6. drop ignored RFS tickets    7. compare with last check|
 |                              8. show a toast if needed      9. save state, log        |
 +-----------------------------------------+---------------------------------------------+
                                           | toast buttons
             +-----------------------------+------------------------------+
             v                                                            v
  open a Jira page in your browser               "Ignore..." -> src/Show-IgnoreWindow.ps1
  (no script runs)                               (local window, writes ignored.txt)
```

### One check, step by step

1. **Read and validate settings.** A bad value stops the check with a clear toast.
2. **Skip if the screen is locked.** When `LogonUI.exe` is running in your session, the check ends here and Jira is not called.
3. **Decrypt the token.** Only your Windows user can do this.
4. **Verify the token** with `GET /rest/api/3/myself`. This step matters: with an invalid token, Jira's search returns *0 tickets* instead of an error. Without this check, an expired token would look like "nothing to do".
5. **Fetch tickets** with `GET /rest/api/3/search/jql`, asking only for `summary`, `status` and `statuscategorychangedate`. With the default settings, the query is:

   ```
   (assignee = currentUser() AND status in ("Open", "Reopened")
     AND (created >= "<SinceDate> 00:00"
          OR assignee changed to currentUser() after "<SinceDate> 00:00"
          OR status changed to "Open" after "<SinceDate> 00:00"
          OR status changed to "Reopened" after "<SinceDate> 00:00"))
   OR
   (assignee was currentUser() AND status = "Ready for Staging"
     AND status changed to "Ready for Staging" after "<SinceDate> 00:00")
   ```

   The query uses `"<date> 00:00"` and not just `"<date>"`, because `changed ... after "<date>"` would leave out that whole day.
6. **Apply the ignore list.** Listed RFS tickets are removed. To do tickets are never removed.
7. **Compare with the last check.** The tool remembers `KEY|Status` pairs. A ticket is *new* if its pair was not there last time, so a ticket that changes status (In QA → Ready for Staging) is new again. This is why each ticket is announced once and nothing is lost while the PC is off or locked.
8. **Decide on a toast**:
   - **Check Jira now**: always.
   - **First check after the reminder time**: if the list is not empty.
   - **Otherwise**: only if something is new.
9. **Save** the state and the ticket cache, and log what happened.

### When something goes wrong

| Problem | Behaviour |
|---|---|
| Token invalid, expired or missing | Toast at once, with a **Create token** button. |
| Bad `config.json` | Toast at once, naming the wrong value. |
| Network or VPN down | Logged. A toast appears only after `FailuresBeforeToast` failures in a row. |
| Any of the above | One toast per outage, never one every few minutes. The next successful check clears it. |

## Privacy and security

### Network

- **Only HTTPS requests to `JiraBaseUrl`**: two read-only `GET` calls per check, plus one more for every additional 100 tickets.
- **No writes to Jira.** The tool never creates, edits, transitions or comments on tickets.
- **No telemetry**, no third-party services, no auto-update.
- **Nothing is sent while the screen is locked.**

### What is stored on your PC

Everything is in `%LOCALAPPDATA%\JiraNotify\`:

| File | Content |
|---|---|
| `credential.xml` | Your Atlassian email and API token, encrypted with Windows DPAPI. Only your Windows user on this PC can decrypt it. Copying the file to another user or PC does not work. |
| `config.json` | Your settings. |
| `ignored.txt` | RFS tickets you chose to ignore. |
| `seen-v2.json` | `KEY\|Status` pairs from the last check. |
| `last-issues.json` | Key, status, summary and RFS date of the last fetched tickets (for the Ignore window). |
| `last-error.txt` | Count of failures in a row. It exists only while there is a problem. |
| `last-reminder.txt` | Date of the last morning reminder. |
| `jira-notify.log` | What happened and when. It never contains the token, and it is trimmed after 1 MB. |
| `icon-v2.png`, `icon-v2.ico` | The blue **J** icon, drawn locally. |

### What is changed in Windows

All changes are **per user** and need no administrator rights:

| Item | Purpose |
|---|---|
| Scheduled task `JiraNotify` | Runs the check as **you**, with normal (limited) rights, only while you are signed in. It runs through `conhost --headless`, so no window flashes. |
| `HKCU\Software\Classes\AppUserModelId\JiraNotify` | Name and icon shown on the toasts. It also adds **Jira Notify** to Settings > Notifications, so you can mute it there. |
| `HKCU\Software\Classes\jiranotify` | Lets the **Ignore...** button open the Ignore window. |
| `Check Jira now.lnk` | The shortcuts on the Desktop and in the Start Menu. |

`Install.ps1 -Uninstall` removes every item above and the whole data folder.

## Verify it yourself

You do not have to take this README's word for it:

- **Read the code.** Every network call is an `Invoke-RestMethod`. Search for it and you will find only `/myself` and `/search/jql`:

  ```powershell
  Select-String -Path .\Install.ps1, .\src\* -Pattern 'Invoke-RestMethod|Invoke-WebRequest'
  ```

- **Watch it run.** Read the log, or check the task's last result:

  ```powershell
  Get-Content "$env:LOCALAPPDATA\JiraNotify\jira-notify.log" -Tail 20
  Get-ScheduledTaskInfo -TaskName JiraNotify
  ```

- **Run one check by hand** and see the toast:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\src\Invoke-JiraCheck.ps1 -Manual
  ```

- **Compare with Jira.** The toast buttons open the same query in Jira, so you can check the counts.
- **Revoke access at any time** by deleting the API token at <https://id.atlassian.com/manage-profile/security/api-tokens>. The tool then shows the "token invalid" toast and stops reading Jira.

## Troubleshooting

| Symptom | What to do |
|---|---|
| No toasts at all | Turn off Do Not Disturb or Focus. Check **Settings > System > Notifications > Jira Notify** is on. Look at the log. |
| `API token expired or invalid` | Create a new token (the toast has a button for it), then run `Install.ps1` **without** `-TaskOnly`. |
| `cannot reach Jira` | Check your network or VPN. It clears by itself after the next successful check. |
| `config.json has a problem` | Fix the value named in the toast. |
| Header icon is not the blue **J** | Windows caches that icon. Sign out and back in. |
| `Windows denied updating the 'JiraNotify' task` | Run the command from an administrator PowerShell. |
| Nothing after moving the folder | Run `Install.ps1 -TaskOnly` from the new place. |
| Scripts blocked after a ZIP download | `Get-ChildItem -Recurse \| Unblock-File` in the folder. |

## Development

```
jira-notify/
├─ Install.ps1                 install / -TaskOnly / -Uninstall
├─ src/
│  ├─ JiraNotify.psm1          shared code: config, JQL, Jira API, state, formatting, toasts
│  ├─ Invoke-JiraCheck.ps1     one check (scheduled task and "Check Jira now")
│  └─ Show-IgnoreWindow.ps1    the Ignore window (WinForms)
├─ tests/JiraNotify.Tests.ps1  Pester 5, offline
├─ config.example.json
└─ .github/workflows/tests.yml runs the tests on Windows PowerShell 5.1
```

Run the tests:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck   # once
Invoke-Pester -Path .\tests -Output Detailed
```

Rules for contributions:
- **Windows PowerShell 5.1 compatible.** No PowerShell 7-only syntax (`??`, `?.`, ternary, `-Parallel`).
- **ASCII-only `.ps1` / `.psm1` files.** Windows PowerShell 5.1 reads BOM-less files as ANSI, and a test enforces this.
- **Keep the logic pure.** Put decisions in functions that take their inputs as parameters (see the tests), and keep the Jira, file, registry and toast calls thin.
- **Read-only against Jira.** Do not add endpoints that change data.
- **Label hand-fired test toasts** (e.g. `[TEST] ...`): they look exactly like real ones.

Three Windows PowerShell 5.1 pitfalls are already handled in the code:
- `ConvertFrom-Json` returns a JSON array as one object, so unroll it before use.
- A 1-item array returned from a function becomes a single `[pscustomobject]`, which has no `.Count`, so wrap call sites in `@()`.
- `[bool]"false"` is `$true`.

## License

[MIT](LICENSE)
