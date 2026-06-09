---
description: Cut a RoosterX fork release — build images, tag with the roosterx-v<version>-<date> convention, push to the roosterx remote, and optionally create a GitHub release.
argument-hint: "[--build] [--gh] [extra release notes]"
allowed-tools: Bash, Read
---

# Create RoosterX Release

Cut a release of the RoosterX fork on the `roosterx` remote
(`github.com/ed-thuando/roosterx-vexa`). The fork tracks upstream Vexa via
`origin` (`Vexa-ai/vexa`); this command tags the *fork's* mainline so releases
are name-differentiated from upstream.

Arguments: `$ARGUMENTS`
- `--build` → rebuild images first (`make build` + `make build-dashboard`).
- `--gh` → also create a GitHub Release on the roosterx repo via `gh`.
- any remaining text → appended to the tag/release notes.

## Naming convention

```
roosterx-v<UPSTREAM_VERSION>-<YYMMDD>
```
e.g. `roosterx-v0.10.6.3.14-260609`. `<UPSTREAM_VERSION>` = contents of the
`VERSION` file (the upstream base this fork is built on). The `roosterx-v`
prefix is what differentiates fork releases from upstream Vexa tags.

## Steps

1. **Preconditions** — verify, abort with a clear message if any fail:
   - `git remote get-url roosterx` resolves (the fork remote exists).
   - Working tree is clean (`git status --porcelain` empty). If dirty, list the
     files and stop — do not tag a dirty tree.
   - Current branch is `main` (or confirm with the user if not).
   - `roosterx/main` is an ancestor of `HEAD` (fast-forward push is safe). If
     not, stop and report the divergence — never force-push the fork main.

2. **Optional build** (`--build`): from `deploy/compose/`, run `make build`
   then `make build-dashboard`. Report the resulting tag from `.last-tag`.

3. **Compute tag**:
   - `VERSION=$(cat VERSION)`, `DATE=$(date +%y%m%d)`.
   - `TAG="roosterx-v${VERSION}-${DATE}"`.
   - If that tag already exists locally or on the remote, append `-N` (next
     free integer) so re-cuts on the same day don't collide.

4. **Changelog**: list commits since the previous `roosterx-v*` tag
   (`git describe --tags --match 'roosterx-v*' --abbrev=0` → `git log <prev>..HEAD --oneline`).
   If no prior tag, list commits since `origin/main` (the upstream base) to show
   what the fork adds.

5. **Push mainline**: fast-forward push `HEAD` to the fork main —
   `git push roosterx HEAD:main`.

6. **Create + push annotated tag**:
   ```
   git tag -a "$TAG" -m "RoosterX Vexa release $TAG

   Fork of upstream Vexa v<VERSION> + RoosterX audio-only stack.

   <changelog from step 4>
   <extra notes from $ARGUMENTS>

   Built image tag: $(cat deploy/compose/.last-tag 2>/dev/null)"
   git push roosterx "$TAG"
   ```

7. **Optional GitHub Release** (`--gh`): `gh release create "$TAG"
   --repo ed-thuando/roosterx-vexa --title "$TAG" --notes "<changelog + notes>"`.
   (Requires `gh` authenticated for the roosterx repo.)

8. **Report**: print the tag name, the commit it points at, the fork-vs-upstream
   delta (`git rev-list --count origin/main..HEAD`), and the release URL if
   `--gh` was used.

## Notes
- Push targets are **outward** (the user's repo). Confirm before pushing if the
  invocation context is ambiguous.
- This tags the fork, not upstream. Never push tags to `origin` (Vexa).
- To pull upstream updates before releasing: `git fetch origin && git merge origin/main`.
