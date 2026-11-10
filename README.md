# tyim-ch-guard

Local macOS workaround for ChatGPT Computer History leaving Traditional Chinese IME candidate bars on screen. Current version: **1.1.1**.

Tracked upstream: [openai/codex#42181](https://github.com/openai/codex/issues/42181).

Computer History stays enabled. The guard detects candidate-like windows and sends `TERM` to `TYIM_Extension`; it does not change ChatGPT or its recorder. This is recovery after the underlying bug occurs, not an upstream fix.

## Install or upgrade

Requires macOS, the Xcode Command Line Tools (`swiftc`), and the built-in signing tools.

```bash
git clone https://github.com/Ken-Mok/tyim-ch-guard.git
cd tyim-ch-guard
./scripts/install.sh
```

For an existing checkout, run `git pull --ff-only`, then `./scripts/install.sh`.

The installer builds before stopping the running service, backs up the installed source, executable, and LaunchAgent, then replaces the executable and restarts the service. Existing login settings are preserved. If replacement or startup fails, it attempts to restore the previous installation. The backup path is printed.

## Accessibility permission is required again after some upgrades

**A running LaunchAgent does not prove that punctuation recovery is enabled.** macOS can stop trusting a replaced ad-hoc-signed executable, even when its path and name are unchanged.

Open **System Settings → Privacy & Security → Accessibility** and turn `tyim-ch-guard` off and on. If it is still untrusted, remove the old entry and add this executable again:

```text
~/Library/Application Support/tyim-ch-guard/tyim-ch-guard
```

Check the installed executable from a normal Terminal:

```bash
"$HOME/Library/Application Support/tyim-ch-guard/tyim-ch-guard" --status
```

- `accessibility_granted: false`: the guard cannot enable punctuation monitoring. Reauthorize it in Accessibility.
- `window_list_available: false`: this execution environment could not enumerate on-screen windows. A candidate count of zero is not proof that a stuck bar is absent.
- The daemon log should show `event tap listening` once monitoring starts.

Without Accessibility, multiple-window, focus-change, and input-source-change recovery can still operate. A single candidate while ChatGPT and TYIM remain active is deliberately left alone: there is no unconditional 20-second reset.

## An existing bar did not disappear after upgrading

Reauthorizing the listener does not itself dismiss a bar left behind before the upgrade. After committing or canceling any text you want to keep, explicitly clear matching bars once:

```bash
"$HOME/Library/Application Support/tyim-ch-guard/tyim-ch-guard" --once
```

The command reports whether matching windows were found and whether the restart command succeeded. Success reports a restart request, not visual proof that the bar disappeared.

## Recovery rules

Matching windows have owner `ChatGPT`, layer `20`, no available title, height 20–40, and width 80–900. The reported upstream example is approximately `397 × 28`.

The guard polls every 0.2 seconds and may restart TYIM when:

1. Two or more matching windows exist.
2. The same matching window remains after leaving ChatGPT for about 0.6 seconds.
3. A window present while TYIM was active remains about 0.4 seconds after leaving that input method.
4. About 1.5 seconds after startup, a matching window exists outside an active ChatGPT/TYIM composition.
5. An authorized punctuation event (`;`, `'`, `/`, `,`, or `.`) leaves its original window visible after about 0.2 seconds.

Punctuation recovery only arms inside ChatGPT with TYIM active and a recent matching window. Command, Control, and Option shortcuts do not arm it. Further typing or a focus/input-source change cancels pending punctuation cleanup. Actual recovery latency includes the polling interval; restarts are limited to at most one every two seconds.

A stationary candidate alone is not considered stale. This protects normal compositions that remain open while the user is thinking.

## Logs and version

```bash
"$HOME/Library/Application Support/tyim-ch-guard/tyim-ch-guard" --version
tail -n 30 "$HOME/Library/Logs/tyim-ch-guard.log"
```

Logs include recovery attempts, permission/listener state, and observer-state changes, plus a 60-second heartbeat. They do not contain typed text or window contents.

## Tests

```bash
./scripts/test.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

The Swift checks exercise the recovery policy without observing windows or restarting a live input method. Installer tests use a temporary fixture root and fake system commands, without changing the user's real service or settings. These checks do not replace a live Chinese-input regression test.

## Stop or uninstall

Stop for the current login session:

```bash
launchctl bootout "gui/$(id -u)/com.ken.tyim-ch-guard"
```

Remove the installed service, executable, source, and backups:

```bash
./scripts/uninstall.sh
```

## Limitations

Window geometry is a heuristic and cannot prove that a candidate is stale. Restarting TYIM affects the whole input-method process and can discard uncommitted text, including a composition in another app. Keep important drafts before explicit cleanup. Other input methods or candidate-window layouts may not match these rules.

See [CHANGELOG.md](CHANGELOG.md) for version details.

