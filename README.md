# Claude Account Switcher

**A native macOS menu bar app for switching between multiple Claude Code accounts.** It shows the usage limits of every account and renews every login once a day.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

[Tiếng Việt](README.vi.md)

<p align="center">
  <img src="docs/images/menu-panel.png" alt="Claude Account Switcher menu bar panel showing the account in use, its 5-hour and weekly usage, and other Claude accounts to switch to" width="360">
  &nbsp;
  <img src="docs/images/manage-window.png" alt="Claude Account Switcher window listing several Claude Code accounts with login status and usage bars" width="520">
</p>

## Why

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) keeps a single login per Mac. If you have more than one Claude subscription, such as a work account and a personal one, changing accounts has three problems:

- You have to run `/login` again every time, and sign in through the browser.
- You can't see which account still has room in its 5-hour and weekly limits.
- An account you haven't used for a while can be logged out right when you need it.

Claude Account Switcher keeps every account you've logged in to and switches between them in one click. It shows each account's usage, and it renews every login in the background.

## Features

- **One-click account switching** from the menu bar. Your `~/.claude` settings, plugins, MCP servers and memory stay shared across accounts.
- **Usage for every account:** the 5-hour session, the weekly limit and per-model weekly limits, with reset times. The app reads them with Claude Code's own `/usage`, which uses no messages.
- **Switch suggestions:** when the account in use passes 80%, the app suggests the account with the most room left.
- **Daily renewal:** every logged-in account is renewed at least once a day, the one in use included, so its token stays fresh.
- **Never interrupts running agents:** usage reads and renewals for idle accounts run in an isolated profile, and the live login is never switched behind your back.
- **1-year backup token:** store a `claude setup-token` for each account. If a regular login expires, the app moves Claude Code onto that token automatically.
- **Add accounts in a private window:** sign in to a second account in a Brave, Chrome, Edge, Vivaldi, Opera or Firefox private window, without logging out of the claude.ai session in your main browser. No Terminal needed.
- **Stale-session protection:** if a session that is still running writes an old account's token back, the app saves that token for the right account and puts your choice back.
- **Light on resources:** about 0.1% CPU when idle. All keychain and file work runs off the main thread.
- **English and Vietnamese UI**, switchable at runtime.

## How it works

| Piece | What the app does |
|---|---|
| **Switching** | Claude Code keeps its login in the keychain item `Claude Code-credentials` and the account in `~/.claude.json` → `oauthAccount`. The app keeps a copy of each account in its own keychain items and writes the chosen one into both places. |
| **Isolated profiles** | Idle accounts run with `CLAUDE_CONFIG_DIR=~/Library/Application Support/ClaudeSwitcher/profiles/<id>`. Claude Code then uses a separate keychain item, so the live login is never touched. Refreshed tokens are copied back. |
| **Daily renewal** | Every 24 hours, once the ~8-hour access token has expired, the app runs `/usage` (free), so Claude Code refreshes the token. Only if the tokens didn't change does it send one tiny `haiku` message. A refresh Claude Code already did that day counts. |
| **Backup token** | A `claude setup-token` token (about 1 year) goes into `~/.claude/settings.json` → `env.CLAUDE_CODE_OAUTH_TOKEN` only while the regular login can't be used, and is removed when it can be used again. |
| **Usage** | `claude -p /usage --no-session-persistence` for every account. The account in use is read when you open the panel, and every 15 minutes in the background at low priority. |
| **Sign-in** | `claude auth login` runs in the background with `$BROWSER` pointing at a small script that captures the sign-in link. The link opens where you choose, and the localhost callback finishes the login. |

## Requirements

- macOS 15 Sequoia or later (Apple silicon or Intel)
- Xcode 16+ / Swift 6 toolchain, to build from source
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed (`~/.local/bin/claude`, Homebrew or `/usr/local/bin`)

## Install

### Download

Get the latest `ClaudeSwitcher-<version>.zip` from [Releases](https://github.com/ChisThanh/claude-account-switcher/releases/latest). It is a universal build for Apple silicon and Intel. Unzip it and move `ClaudeSwitcher.app` to `/Applications`.

The app is ad-hoc signed, not notarized by Apple, so macOS blocks it the first time. Allow it in **System Settings → Privacy & Security → Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/ClaudeSwitcher.app
```

### Build from source

```sh
git clone https://github.com/ChisThanh/claude-account-switcher.git
cd claude-account-switcher
./scripts/build-app.sh --install    # builds, copies to ~/Applications and opens it
```

Building needs no Apple Developer ID. The app runs from the menu bar (✦ plus the account name). Opening it again from Finder or Spotlight brings up the window.

## Getting started

1. **Add your accounts.** Click **Add account** and pick **Private window** to sign in to an account other than the one in your main browser. The app picks the account up in a few seconds. Repeat for each account.
2. **Switch.** Open the ✦ menu and click **Switch** next to an account. New `claude` sessions use it right away. Sessions that were already open keep the old account until you restart them (`/exit`, then `claude`), and the app tells you how many there are.
3. **Add a backup token (recommended).** Click **Manage… → 1-year backup token → Open Terminal and create a token**, sign in as that account, then save the token. The app picks it up from the clipboard.
4. **Optional:** turn on **Open at login** in ⚙, and pick the language there too.

## FAQ

**Will my logins never expire?**
Tokens are refreshed every day. But on 23 Oct 2026 a refresh did **not** extend the login's own expiry, which is about 30 days after signing in. So for an account to keep working with no gaps, give it a backup token or log in again before the end. The app warns you 5 days ahead.

**Does reading usage or renewing use up my limits?**
`/usage` is a local command, so it uses no model turns. A renewal only sends one tiny `haiku` message when `/usage` didn't refresh the token.

**Does it work with the Claude Code extension in VS Code and JetBrains?**
Yes. The extension uses the same login. Restart its Claude panel after switching.

**Where are my tokens stored?**
In the macOS Keychain, through `/usr/bin/security`, the same tool Claude Code uses. Non-secret state (emails, expiry dates, usage) is in `~/Library/Application Support/ClaudeSwitcher/state.json`. Nothing is sent anywhere except by the `claude` CLI itself.

**Safari private windows?**
Safari can't be told to open a private window from the command line. Pick **Copy sign-in link only** and paste the link into a private window yourself (⇧⌘N).

## Project structure

```
Sources/ClaudeSwitcher/
  AccountStore.swift   state, sync with Claude Code, switching, renewal, usage
  Profile.swift        isolated CLAUDE_CONFIG_DIR profiles for idle accounts
  Login.swift          background `claude auth login`, private-window browsers
  Keychain.swift       keychain through /usr/bin/security
  ClaudeFiles.swift    ~/.claude.json and settings.json edits
  Usage.swift          `/usage` parsing
  MenuPanel.swift, ManageView.swift, Components.swift   SwiftUI views
  L10n.swift           English / Vietnamese strings
scripts/build-app.sh   builds the .app (--install, --universal, --version, --zip)
.github/workflows/     pushing a v* tag builds and publishes a release
```

To try the UI without touching real accounts, run `ClaudeSwitcher --demo`. It uses made-up `example.com` accounts and never reads or writes the keychain or Claude's files.

## Contributing

Issues and pull requests are welcome. Please keep the app dependency-free (Swift and SwiftUI only), and write every user-facing string in both languages with `L("tiếng Việt", "English")`.

## Disclaimer

This is an independent, unofficial project, not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic. Use it only with accounts you own: sharing an account with other people goes against Anthropic's terms.

## License

[MIT](LICENSE)
