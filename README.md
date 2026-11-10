# tyim-ch-guard

Local macOS workaround for a ChatGPT Desktop / Computer History bug that leaves Traditional Chinese IME candidate bars stuck on screen.

Tracked upstream: [openai/codex#42181](https://github.com/openai/codex/issues/42181)

## What it fixes

When ChatGPT Computer History is running and you type with Apple Traditional Chinese Quick / Sucheng / Cangjie (`TYIM_Extension`), committing with punctuation can leave a ChatGPT-owned candidate bar behind:

- owner: `ChatGPT`
- layer: `20`
- roughly `397 x 28`
- untitled, draggable, stays above other apps

This tool does **not** patch ChatGPT or `SkyComputerUseService`. Those binaries are signed and closed source. Instead it watches for the stuck window and clears it by sending `TERM` to `TYIM_Extension`, which is the known recovery path from the bug report.

## Install

```bash
git clone https://github.com/Ken-Mok/tyim-ch-guard.git
cd tyim-ch-guard
./scripts/install.sh
```

Then enable **Accessibility** for `tyim-ch-guard` in:

System Settings → Privacy & Security → Accessibility

Without Accessibility, the guard still clears stuck windows after focus / IME changes, multiple bars, or a 20s timeout. With Accessibility, it also listens for punctuation keys and clears within about 0.2s when the candidate bar fails to dismiss.

## Uninstall

```bash
./scripts/uninstall.sh
```

Or:

```bash
launchctl bootout gui/$(id -u)/com.ken.tyim-ch-guard
```

## One-shot clear

```bash
~/Library/Application\ Support/tyim-ch-guard/tyim-ch-guard --once
```

## Logs

```text
~/Library/Logs/tyim-ch-guard.log
```

## Clear triggers

1. Two or more matching ChatGPT layer-20 candidate bars
2. Leave ChatGPT while a candidate bar remains (~0.6s)
3. Leave TYIM input source while a candidate bar remains (~0.4s)
4. Same candidate bar stays put for ~20s
5. Startup cleanup after ~1.5s
6. Punctuation keys `;` `'` `/` `,` `.` when Accessibility is granted

## Notes

- Computer History can stay enabled.
- This is a local mitigation until OpenAI fixes the recorder / IME interaction.
- Do not reverse-engineer or resign `SkyComputerUseService`; the service authenticates the sender and Hardened Runtime / Developer ID sealing will reject unsigned local patches.
