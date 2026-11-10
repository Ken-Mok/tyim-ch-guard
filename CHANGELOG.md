# Changelog

## 1.2.0

- Fix the reported six missed Microsoft Teams windows: recognize Teams as well as ChatGPT and include the observed 52-point-wide pill.
- Keep strict owner, layer-20, untitled, and height checks; exclude Window Server, Control Center, and normal app main windows.
- Track focus, punctuation, and cleanup policy separately for each owner while sharing a global restart cooldown.
- Verify the original window IDs after restarting TYIM. Log surviving windows or unavailable enumeration, and back off unsuccessful owners for 15 seconds.
- Make `--once` return a nonzero status when original windows remain or cleanup cannot be verified.
- Report candidate counts by owner and compare legacy versus 1.2 matching in read-only diagnostics.

## 1.1.1

- Add a standalone read-only window diagnostic for narrow pills and other owners that the guard excludes, with explicit exclusion reasons and no window-title or candidate text.
- Add `--status` so installation can report missing Accessibility permission, input-source state, candidate counts, and unavailable window enumeration without restarting the IME.
- Report failed one-shot restarts and no matching windows instead of silently returning.
- Log observer state changes and a 60-second heartbeat without recording typed text or window contents.
- Explain that replacing an ad-hoc-signed executable can require Accessibility permission again. Installation success does not mean punctuation recovery is authorized.
- Stage compilation before replacing the running executable and retain installation backups.

## 1.1.0

- Keep the input-source departure timer across polls and track only its original candidate windows.
- Remove the unconditional 20-second stationary-window reset, which can interrupt a legitimate composition.
- Restrict punctuation recovery to TYIM input inside ChatGPT, ignore shortcuts, and cancel pending cleanup when typing continues or focus/input source changes.
- Re-enable disabled keyboard event taps and throttle event-tap creation retries.
- Use monotonic timing, retain the restart cooldown, and protect an active single candidate during startup.
- Add deterministic regression checks that do not interact with live input methods.
