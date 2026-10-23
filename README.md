# Pinger

Plays an alert sound when your name or one of your own trigger words appears in RuneScape chat. Each trigger has its own game sound, on/off switch, channel filter (public, private, friends chat, clan, guest clan, group, trade/requests) and whole-word or contains matching. Ignore your own messages, per-trigger cooldown, audio bus picker. Read-only: never changes or sends chat.

Current version: 0.1.3

- Needs the optional `chatAccess` permission to see chat. In the developer client: `ppr pinger`, `ppe pinger chatAccess`, then `prl pinger`.
- mod.io page: not published yet.

## Report a bug or request a feature

Open an issue: https://github.com/MAX-Q00/pinger/issues/new/choose

For a bug, please include the plugin version, what happened, what you expected, steps to reproduce, a screenshot if you can, and your game resolution and UI scale.

Contact: Dylan@quspace.agency

## EULA

This Plugin uses software licensed by Jagex to the developer under the terms of the Jagex End User Licence Agreement (EULA) found at https://legal.jagex.com/docs/terms/eula (and all terms incorporated into it by reference). The development and any use of the Plugin is at all times subject to the Jagex EULA.

By submitting a Plugin (as defined in Schedule 4 of the EULA), you acknowledge that you agree to the terms of the Jagex End User License Agreement (EULA) found at https://legal.jagex.com/docs/terms/eula (and all terms incorporated into it be reference) and acknowledge that such terms are legally binding on you. If you do not agree to the terms of the EULA, you must not submit a Plugin or use the Plugin functionality anyway. In such circumstances, Jagex does not licence the software to you, or grant you any of the relevant rights relating to the submission of Plugins set out in the EULA and you will not be permitted to access or use the Plugin functionality in any way whatsoever.

---

Not affiliated with or endorsed by Jagex. RuneScape is a trademark of Jagex Ltd.

## Chat access

Pinger declares `chatAccess` as required (and optional, because the client does not apply required permissions yet). If chat access is missing when Pinger loads, it runs `ppr pinger` and `ppe pinger chatAccess` once through `ExecuteConsoleCommand` and starts listening as soon as access is granted. If it is still off, the panel shows the steps: `ppr pinger`, `ppe pinger chatAccess`, `prl pinger`.
