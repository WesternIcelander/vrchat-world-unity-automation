# TestingAutomation.md

This project's settings for the vrchat-world-unity-automation skill. Not in git (listed in `.git/info/exclude`).

## Play Mode tests

- **Done texts** (what `play` waits for, `|`-separated): e.g. `[MyTest] done`
- **Most seconds to wait:** e.g. 600
- **Before a run:** e.g. menu items that rebuild test objects, or none

## Production

- **Test instance URL:** `vrchat://launch?id=wrld_…:<instance>~…`
- **Profiles to launch:** e.g. 0, 2 (accounts in the skill's `developer.md`)
- **Done texts on each client:** e.g. the same as Play Mode
- **Expected failures on some clients:** e.g. none

## Reminders

Anything else to keep in mind when testing this project.
