# PromptQy

**English** · [简体中文](README.zh-CN.md)

> A menu-bar-resident, always-on-top composer that gathers selected text, file paths and screenshots into one floating editor and sends them — with a single keystroke — to Claude Code running in your terminal.

When you drive Claude Code from the terminal, you constantly feed it file paths, code snippets, error messages and screenshots — copy, switch window, paste, repeat. This little tool collapses those steps into an always-on-top editor you summon with a double-tap.

> ⚠️ Personal tool, not an Anthropic product. Targets **Terminal.app** and **iTerm2** (pick one or auto in Settings).

## Features

- **Menu-bar resident**, no Dock icon (`LSUIElement`)
- **Always-on-top editor**: floats above every app, visible across Spaces / full-screen; draggable, resizable, remembers its frame
- **Double-tap Control to summon**: inserts the frontmost app's selection (Accessibility API first, falls back to a synthesized ⌘C)
- **Drag files in** to insert their paths
- **Double-tap Option** to insert the current Finder selection's paths
- **Double-tap Command** to open the current Finder selection in Sublime Text
- **Screenshot auto-insert**: after ⌘⇧4, the new screenshot's path is inserted (menu → *Insert screenshots immediately* disables macOS's floating thumbnail so captures save — and insert — with no ~5s delay)
- **One-key send**: ⌘↵ → if several terminal windows/tabs exist, pick one by title → text is pasted into Claude and submitted; the editor clears
- **Terminal.app & iTerm2**: send to either (or auto-detect); choose the target in Settings
- **History** of sent messages in the menu; click to reload into the editor
- **Customizable**: the three double-tap modifiers, target terminal, history size, menu label width (menu → Settings…)

## Gestures

| Action | Effect |
|---|---|
| Double-tap **Control** | Summon the editor; insert the selection if any |
| Double-tap **Option** | Insert the current Finder selection's paths |
| Double-tap **Command** | Open the current Finder selection in Sublime Text |
| Drag a file into the editor | Insert its path |
| ⌘⇧4 screenshot | Insert the new screenshot's path |
| **⌘↵** | Send to the terminal (pick a window/tab if several) |
| **Esc** / **⌘W** | Hide the editor |
| ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z | Standard editing inside the editor |

Every inserted path / selection is followed by a newline, so items stack on their own lines.

## Install

### Option A — Homebrew (recommended)

```bash
brew install --cask DoAutumn/tap/prompt-qy
```

To update: `brew upgrade --cask prompt-qy`.
To remove it and its preferences: `brew uninstall --zap --cask prompt-qy`.

### Option B — one-line install

```bash
curl -L -o /tmp/prompt-qy.zip \
  https://github.com/DoAutumn/prompt-qy/releases/latest/download/PromptQy.app.zip \
  && unzip -oq /tmp/prompt-qy.zip -d /Applications/ \
  && xattr -dr com.apple.quarantine "/Applications/PromptQy.app" \
  && rm /tmp/prompt-qy.zip \
  && open "/Applications/PromptQy.app"
```

What it does: pull the latest release → unzip into `/Applications/` → strip quarantine (bypass Gatekeeper, since the app is unsigned/unnotarized) → launch.

Manual (if you'd rather not run a script): grab `PromptQy.app.zip` from [Releases](https://github.com/DoAutumn/prompt-qy/releases/latest), unzip and drag it to `/Applications`, then **right-click → Open → click Open again in the dialog** (only once) to get past Gatekeeper.

### Option C — build from source

Requires the Xcode Command Line Tools (`swiftc`); no Xcode project needed.

```bash
git clone https://github.com/DoAutumn/prompt-qy.git
cd prompt-qy
./build_app.sh                                 # output: dist/PromptQy.app

open "dist/PromptQy.app"             # first run
cp -R "dist/PromptQy.app" /Applications/   # install to Applications
```

Building locally means the app has **no quarantine flag**, so Gatekeeper won't block it.

## Permissions

First use will prompt for (grant each once):

- **Accessibility** — global key monitoring (double-tap summon), reading the selection, synthesizing keys
- **Automation** — controlling Finder, Terminal.app and/or iTerm2 (enumerating windows/tabs, sending text)
- **Desktop folder** — watching the screenshot directory

If you hit "granted but still not working", it's usually a stale grant. Reindex the app and reset the service so it prompts again:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/PromptQy.app"
tccutil reset AppleEvents io.github.promptqy
```

## Files

| File | Purpose |
|---|---|
| `command_bar.swift` | All logic (single file) |
| `build_app.sh` | Compile + bundle + sign into `.app` |
| `make_zip.sh` | Zip the built app into a Releases artifact |
| `release.sh` | Bump `VERSION`, publish a release, update the Homebrew cask |
| `generate_icon.swift` | Draws the app icon |
| `setup_signing.sh` | Optional dev helper (see below) |

> **Rebuilding often?** `swiftc` output has no stable code signature, so macOS's privacy system (TCC) re-asks for Accessibility/Automation after every rebuild. Run `./setup_signing.sh` once to create a dedicated self-signed identity (in its own keychain — it does *not* touch your login keychain); `build_app.sh` then signs with it so grants survive rebuilds. End users installing a release never need this.

## License

[MIT](LICENSE)
