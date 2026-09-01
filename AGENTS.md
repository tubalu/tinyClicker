# tinyClicker — Repo Rules

## Versioning (MANDATORY on every commit)

Every commit MUST bump the version and ship a matching git tag. Do this as part of the commit, never as a separate afterthought.

1. **Bump the version** in `Resources/Info.plist`:
   - Increment `CFBundleShortVersionString` by one patch level by default (e.g. `0.1.3` → `0.1.4`). Use a minor/major bump only when the change clearly warrants it (new feature set → minor; breaking change → major).
   - Increment the integer `CFBundleVersion` (build number) by 1 every time (e.g. `4` → `5`).
2. **Include the bumped `Info.plist` in the same commit** as the change it describes.
3. **Tag the commit** with `v<CFBundleShortVersionString>` (e.g. `v0.1.4`) and push both the branch and the tag:
   ```sh
   git push origin <branch>
   git push origin v<version>
   ```
   Pushing a `v*` tag triggers `.github/workflows/release.yml`, which builds the universal `.app` and publishes a GitHub Release — so each tag must be a buildable, releasable state.

The single source of truth for the app version is `Resources/Info.plist`. The git tag must always match `CFBundleShortVersionString`.
