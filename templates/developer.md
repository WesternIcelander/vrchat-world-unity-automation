# developer.md

The developer's own settings for the vrchat-world-unity-automation skill, the same for every project. Kept next to `SKILL.md` and never shared (the skill's `.gitignore` lists it). Anything here overrides the defaults in `SKILL.md`.

## Accounts and VRChat profiles

Each VRChat profile (`--profile=N`) is logged in to its own account. List them with their roles in tests:

- 0 = `<display name>`: e.g. the first joiner and instance master
- 1 = `<display name>`: e.g. a second player

## Hardware

- **VR headsets:** e.g. 1 (at most this many clients in VR at once)
- **VRChat launcher:** only if not the default Steam install, e.g. `D:\SteamLibrary\steamapps\common\VRChat\launch.exe`

## How I work

- **Asking before production runs:** e.g. the default (Do it now / Later), or "always ask, even when I request a run directly"
- **Away from the computer:** e.g. "I may steer the session remotely; then plan nothing that needs me at the PC"
- Anything else Claude should keep in mind when testing.
