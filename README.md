# tyim-ch-guard

Local macOS workaround for ChatGPT Computer History leaving Chinese IME candidate bars on screen. Current version: **1.3.0**.

Tracked upstream: [openai/codex#42181](https://github.com/openai/codex/issues/42181).

Computer History stays enabled. ChatGPT and Microsoft Teams are supported owners. The guard detects candidate-like windows and sends `TERM` to the selected Chinese input-method extension; it does not change ChatGPT or its recorder. This is recovery after the underlying bug occurs, not an upstream fix.

## Supported Chinese keyboard input methods

- **TCIM**: Traditional Chinese — Cangjie, Sucheng, Pinyin, Shuangpin, Stroke, and Zhuyin.
- **TYIM**: Cantonese — Cangjie, Sucheng, Stroke, and Phonetic.
- **SCIM**: Simplified Chinese — Pinyin, Shuangpin, Stroke, and Wubi.

All modes in the exact `com.apple.inputmethod.TCIM`, `.TYIM`, and `.SCIM` namespaces are recognized. Handwriting, Japanese, Korean, and third-party input methods are outside this version's scope. Window matching still covers ChatGPT and Microsoft Teams with the existing geometry heuristic; supporting an engine does not guarantee every candidate layout matches.

Recovery runs only when exactly one supported Chinese engine is running for the current user. If a Chinese source is active, it must match that sole engine; a plain keyboard such as ABC also permits recovery. Multiple running engines, an unknown source, or a different unsupported input method cause cleanup to be skipped and logged as `no-unambiguous-target`. The current source alone cannot identify which engine produced an old bar, so the guard never chooses between multiple engines or broadcasts TERM to them. Logs name the selected process. The status command lists supported input-method namespaces and the active engine.

## Install or upgrade

Requires macOS, the Xcode Command Line Tools (`swiftc`), and the built-in signing tools.

```bash
git clone https://github.com/Ken-Mok/tyim-ch-guard.git
cd tyim-ch-guard
./scripts/install.sh
```

For an existing clean checkout, run `git pull --ff-only`, then `./scripts/install.sh`.

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
- `matching_candidates_by_owner` shows which app owns the recognized bars.
- The daemon log should show `event tap listening` once monitoring starts. Multiple-bar recovery does not require this listener.
- After cleanup, `verification owner=... result=removed` confirms that the original matching window IDs disappeared.

Without Accessibility, multiple-window, focus-change, and input-source-change recovery can still operate. A single candidate while its owning app and a supported Chinese input method remain active is deliberately left alone: there is no unconditional 20-second reset.

## An existing bar did not disappear after upgrading

Reauthorizing the listener does not itself dismiss a bar left behind before the upgrade. After committing or canceling any text you want to keep, explicitly clear matching bars once:

```bash
"$HOME/Library/Application Support/tyim-ch-guard/tyim-ch-guard" --once
```

The command reports whether matching windows were found and whether the restart command succeeded. After a successful restart command, it waits 0.8 seconds and checks whether the original window IDs disappeared. Exit status 2 means original windows remain; status 3 means enumeration is unavailable, so cleanup cannot be verified.

## Recovery rules

If several visible bars survive a successful input-method restart, collect their actual window metadata before changing matching rules:

```bash
./scripts/diagnose.sh
```

Run this from a normal Terminal while the bars remain visible. It makes no changes and reports small floating windows from all owners, comparing the legacy 1.1 matcher with the 1.2 matcher. It omits window titles, candidate text, keystrokes, and screenshots. If `window_list_available` is false, that environment cannot provide the evidence needed to identify the bars; a zero match count does not mean they were cleared. The input-source field describes Terminal at collection time, not the earlier ChatGPT composition.

Matching windows have owner `ChatGPT` or `Microsoft Teams`, layer `20`, no available title, height 20–40, and width 40–900. The 40-point lower limit includes the observed 52-point Teams pill. Window Server and Control Center windows remain excluded. The original upstream example is approximately `397 × 28`; a later user report identified five Teams-owned `397 × 28` bars and one `52 × 28` pill, all excluded by the old ChatGPT-only rule.

The guard polls every 0.2 seconds and may restart the selected Chinese input method when:

1. Two or more matching windows exist for the same owner. One bar in each of two apps is not counted as multiple bars for a single owner.
2. The same matching window remains after leaving its owning app for about 0.6 seconds.
3. A window present while a supported Chinese input method was active remains about 0.4 seconds after switching to a plain keyboard such as ABC. Switching between Chinese families does not itself trigger departure cleanup; engine attribution is ambiguous.
4. About 1.5 seconds after startup, a matching window exists outside an active supported-owner/Chinese-input-method composition.
5. An authorized punctuation event (`;`, `'`, `/`, `,`, or `.`) leaves its original window visible after about 0.2 seconds.

Punctuation recovery only arms inside the candidate window’s owning app with a supported Chinese input method active and a recent matching window. Command, Control, and Option shortcuts do not arm it. Further typing or a focus/input-source change cancels pending punctuation cleanup. Actual recovery latency includes the polling interval; restarts are limited to at most one every two seconds.

Recovery policies are kept separately for each owner, with one global restart cooldown. After an automatic restart, the guard checks original window IDs after 0.8 seconds. Logs report `removed`, `remaining(n)`, or `unavailable`. If windows remain or cannot be checked, the owner backs off for 15 seconds before another attempt. A successful TERM exit alone is not treated as a successful cleanup.

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

Window geometry is a heuristic and cannot prove that a candidate is stale. Restarting an input method affects the whole input-method process and can discard uncommitted text, including a composition in another app. Keep important drafts before explicit cleanup. Other input methods or candidate-window layouts may not match these rules.

See [CHANGELOG.md](CHANGELOG.md) for version details.

