# CI/CD setup

The workflows in this directory are inert until the repository is configured to
match them. Everything below has to be done once, in the GitHub UI or with `gh`.

## 1. Branches

`develop` is the trunk: feature branches open pull requests into it, and a push
to it cuts a release. `main` is a mirror of the latest release and is written
only by the release job.

- Set `develop` as the **default branch** (Settings → General).

## 2. Secrets

Settings → Secrets and variables → Actions.

| Secret | Used by | How to get it |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | `ai-review.yml`, the summary step in `release.yml` | `claude setup-token` |
| `COCOAPODS_TRUNK_TOKEN` | the trunk push in `release.yml` | the `token` line in `~/.netrc` under `machine trunk.cocoapods.org`, after `pod trunk register` |

To bill the Claude API instead of a subscription, add `ANTHROPIC_API_KEY` and
change the `claude_code_oauth_token:` lines in both workflows to
`anthropic_api_key:`.

Neither workflow fails hard on a missing Claude credential — the review skips
with a warning and the release ships notes without the summary paragraph.

## 3. Merge strategy

Settings → General → Pull Requests:

- Allow **squash merging** only. Disable merge commits and rebase merging.
- Set the squash commit message to **"Default to pull request title"**.

This is not cosmetic. The release job derives the next version from the commit
subjects on `develop`, and squash-with-PR-title is what guarantees each of those
subjects is the one the `pr-title` check already validated. Under a merge commit
or a rebase, unreviewed subjects reach `develop` and the version calculation
reads them.

## 4. Ruleset on `develop`

Settings → Rules → Rulesets → New branch ruleset, targeting `develop`:

- **Require a pull request before merging.**
- **Require status checks to pass**, and add exactly these four:

  ```
  pr-title
  build
  test
  podspec
  spm
  ```

  These are the `name:` values in `ci.yml`. Renaming a job there without
  updating this list silently removes the gate.

- Do **not** add `ai-review`. It is advisory by design; see the header comment
  in `ai-review.yml` for how to promote it later.
- **Block force pushes.**

### The bypass that the release job needs

The release job pushes the version-bump commit straight to `develop`, which the
"require a pull request" rule rejects by default. Grant a bypass, or the first
release will fail at the push step with `GH006: Protected branch update failed`.

Under **Bypass list**, add either:

- **Repository admin** / **Maintain** role, and accept that the same bypass
  applies to people, or
- a **GitHub App** — create one with `contents: write`, add its ID and private
  key as secrets, mint a token in the workflow and pass it to
  `actions/checkout`. Narrower, and the option to prefer if this repository ever
  has more than one committer.

The default `GITHUB_TOKEN` does not trigger workflows on push, so the bump
commit cannot cause a second release run. `release.yml` also guards on the
`chore(release):` subject, which is what keeps that true if the token is ever
swapped for a PAT or an App token.

## 5. Ruleset on `main`

Targeting `main`:

- **Block force pushes.**
- Same bypass as above, so the release job can fast-forward the mirror.
- No required checks. The commit being mirrored was already gated on `develop`,
  and the mirror push runs no workflows because it is made with `GITHUB_TOKEN`.

## 6. Distribution channels

The same sources ship three ways, and all three are validated by CI:

| Channel | Declared in | Consumer gets it by |
| --- | --- | --- |
| Xcode framework | `CoreDataDB.xcodeproj` | building the project directly |
| CocoaPods | `CoreDataDB.podspec` | `pod 'CoreDataDB'` — published by `release.yml` |
| Swift Package Manager | `Package.swift` | pointing at the repo URL and a version tag |

SPM needs no publishing step: it resolves straight from the git tags the release
job already creates. Because those tags are bare `X.Y.Z` with no `v` prefix, a
consumer writes:

```swift
.package(url: "https://github.com/ilyaSoftDev/CoreDataDB.git", from: "1.0.0")
```

The deployment floor is declared in all three files. `check-platform-sync.sh`,
run by the `spm` job, fails the build if they ever disagree.

## 7. Commit grammar

The version bump reads [Conventional Commits](https://www.conventionalcommits.org):

| Subject | Release |
| --- | --- |
| `feat!: …`, or any commit with a `BREAKING CHANGE:` footer | major — `2.0.0` |
| `feat: …` / `feat(scope): …` | minor — `1.1.0` |
| `fix: …` / `fix(scope): …` | patch — `1.0.1` |
| `docs:`, `chore:`, `ci:`, … alone | **no release** |

Precedence is major > minor > patch. A range with nothing releasable in it ends
the release job quietly rather than inventing a patch bump.

Check a subject before opening the PR:

```bash
.github/scripts/check-subject.sh "feat(combine): add live observation publishers"
```

## 8. First run

1. Open a pull request into `develop` with a conventional title.
2. Confirm five checks report, and that the merge button is blocked while any is red.
3. Confirm `ai-review` comments but does not gate.
4. Squash-merge. The release job should tag, release, mirror `main`, and publish.
5. `pod trunk info CoreDataDB` should show the new version.

If the trunk push fails after the tag exists, the tag and GitHub release are
already correct — retry just the publish locally:

```bash
git checkout <version> && pod trunk push CoreDataDB.podspec
```
