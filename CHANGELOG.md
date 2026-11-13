# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-12

### Added
- One summary toast when a ticket enters **To do** (Open / Reopened, assigned to you) or **Ready for Staging** (a ticket you worked on).
- Buttons on the toast for each group, plus an **Ignore...** window for Ready for Staging tickets that need no prod script. The window shows the RFS date, and a double-click opens the ticket.
- **Check Jira now** shortcut, morning reminder, and a check 15 s after unlocking. Checks are skipped while the screen is locked.
- `config.json` settings with validation and clear error toasts.
- Error policy: auth and config problems are reported at once, network problems after N failures in a row, with one toast per outage.
- Token check through `/myself`, because `/search/jql` answers an invalid token with 0 tickets instead of an error.
- Installer with `-TaskOnly` and `-Uninstall`. The token is stored with Windows DPAPI.
- Pester tests and a GitHub Actions workflow on Windows PowerShell 5.1.
