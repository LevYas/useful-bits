# Porting guide: update-nuget-packages

Instructions for the agent installing this skill into a new repository. The skill itself is `SKILL.md` plus four
PowerShell scripts; this file is not part of it.

Outcome of the port:

- `SKILL.md` has no `{{...}}` placeholders left and states this repo's facts directly: a conditional such as "if
  `global.json` pins the SDK" becomes either the rule itself or nothing
- every step in `SKILL.md` refers to scripts, files and tools that exist in this repo
- the user has approved the policy and every change to their repo configuration
- the user has the port report from step 8

How to work: investigate first (steps 1–4) without changing anything, then ask the user everything in one message
(step 5), then apply (step 6). The answers interact, e.g. a shell port changes which files the scratch-folder edits
touch, and one round trip respects the user's time.

## 1. Read

Read `SKILL.md` and all scripts in full. Read the repo's agent instructions (`AGENTS.md`, `CLAUDE.md`,
`.github/copilot-instructions.md` or similar), CI workflows and `README`: most placeholder values are there.

## 2. Check prerequisites

Note each missing prerequisite and its options for step 5: configure it, or remove or replace the functionality that
depends on it.

| Prerequisite | Check | Why the skill needs it |
|---|---|---|
| Git repo | `git rev-parse --show-toplevel` | Scripts run from the repo root (found with `git rev-parse`) and read tracked files with `git ls-files` / `git show HEAD:` |
| PowerShell 7+ | `pwsh --version` | Script language. See step 3 for a shell port |
| .NET SDK | `dotnet --version` | Restore, build, vulnerability scan |
| GitHub CLI, authenticated | `gh auth status` | Repo identity check (renamed/transferred repos), GitHub releases, Microsoft release notes |
| Gitignored scratch folder `.tmp/` | `git check-ignore -q .tmp/probe` | `packages.json` hands data from `Get-PackageUpdates.ps1` to `Get-ReleaseDiff.ps1`; reports must never be committed |
| Central Package Management | tracked `Directory.Packages.props` with `ManagePackageVersionsCentrally` | Discovery reads versions from it; SKILL.md step 6 edits it; families stay on one version |
| Committed lockfiles | tracked `packages.lock.json`, `RestorePackagesWithLockFile` | Transitive graph review (SKILL.md step 7), `--locked-mode` check (SKILL.md step 8) |
| Package sources | `nuget.config` files in the repo, `dotnet nuget list source` | `NuGetApi.ps1` queries nuget.org only |
| Web fetch tool | agent tool list | Project site ownership check in SKILL.md step 3. Optional |

Options per prerequisite:

- **GitHub CLI.** Recommend installing and `gh auth login`. Removal: drop the `GitHub repository identity` and
  `GitHub releases` sections of `Get-ReleaseDiff.ps1` and the `gh api` commands in SKILL.md step 4, and have the agent
  read release pages with its web fetch tool. This loses the rename/transfer detection, one of the supply-chain signals.
- **Scratch folder.** Recommend adding `.tmp/` to `.gitignore`. If the repo already has an ignored scratch folder,
  use it instead: replace `.tmp/` in `SKILL.md` (Get-PackageUpdates description, step 9),
  `Get-PackageUpdates.ps1` (two places) and `Get-ReleaseDiff.ps1` (`packages.json` path).
- **Central Package Management.** Recommend migrating: one `Directory.Packages.props` at the root with
  `ManagePackageVersionsCentrally`, a `PackageVersion` per package, `Version` removed from every `PackageReference`;
  build to confirm, and commit it before the first run, since the scripts read tracked files only. Removal: rewrite
  discovery in `Get-PackageUpdates.ps1` to read `PackageReference` versions from tracked `*.csproj` / `*.props`
  files (one id with different versions across projects is a finding to report), and SKILL.md step 6 and the
  "never pin a transitive package" rule to talk about project files.
- **Lockfiles.** Recommend enabling `RestorePackagesWithLockFile` (in `Directory.Build.props`, or at least in shipped
  projects), restoring, committing the lockfiles, and adding `dotnet restore --locked-mode` to CI so the committed
  graph is enforced. Removal: replace `Compare-LockFiles.ps1` with a before/after snapshot of
  `dotnet list <solution> package --include-transitive --format json` (taken before SKILL.md step 6, diffed after its step 7, same
  `+ - ~` output), and drop the `--locked-mode` line in SKILL.md step 8.
- **Package sources.** Packages from nuget.org, or from a feed that mirrors it as an upstream, need no change. For
  packages that only exist on another feed: resolve the feed's resources from its v3 service index
  (`RegistrationsBaseUrl`, `PackageBaseAddress`, `SearchQueryService`), add authentication, and route each package to
  its feed (follow `packageSourceMapping` if `nuget.config` has it). Most private feeds don't expose owners: ask the
  user how to treat the organization's own packages (e.g. trusted like Microsoft packages, no age gate, no review).

## 3. Script language

Look at the scripts the repo already has: tracked `*.sh` vs `*.ps1`, the shells CI steps use, the OS the team works
on. If shell scripts clearly dominate, plan a shell port; if unclear, include the choice in step 5. A team that
doesn't read PowerShell can't review or fix the scripts, which matters for code that gates its supply chain.

A shell port:

- follows the repo's existing script conventions (shebang, `set -euo pipefail`, function and file naming, helper
  libraries), and passes ShellCheck
- uses `curl`, `jq`, `unzip`, `git`, `gh`; check them like the prerequisites in step 2
- keeps the parameters, output sections, `!!` markers and the `packages.json` handoff, so SKILL.md keeps working
- keeps these behaviors, which are easy to lose: registration order is version order (never sort versions as
  strings); package age is floored (a 6.5-day-old release must not pass a 7-day gate); package ids are lowercased in
  flat-container URLs; `git --author` matching uses fixed strings; nothing from a cloned repository is ever executed
- updates SKILL.md: script names, "Run them with PowerShell 7", the `powershell` code blocks, the
  `Select-Object -First` note in SKILL.md step 7 (the shell equivalent is `head`)

## 4. Find the placeholder values

| Placeholder | Where in SKILL.md | What to put | Where to look |
|---|---|---|---|
| `{{SKILL_DIR}}` | Steps 2, 3, 7 | Path of this skill's folder as the agent invokes the scripts from the repo root: repo-relative with `./` (e.g. `./.github/skills/update-nuget-packages`) or absolute for a user-level install | Where your agent loads skills from. An agent without a skills mechanism: keep the folder in the repo and reference `SKILL.md` from the agent's instruction file. If your agent's skill format needs other metadata than `name` and `description`, adapt the frontmatter |
| `{{SOLUTION}}` | Steps 7, 8 | Solution file covering every project, e.g. `src/App.sln` | Tracked `*.sln` / `*.slnx`, the CI restore step. Several solutions: the one CI restores |
| `{{BUILD_COMMAND}}` | Step 8 | Full build without restore, e.g. `dotnet build src/App.sln --no-restore`, plus a comment on errors that are expected (projects `dotnet` cannot build, such as `.wapproj`) | CI, agent instructions, README |
| `{{TEST_COMMANDS}}` | Step 8 | Commands for every test suite an update can break, including integration tests; the repo's test wrapper script if it has one, with any environment the tests need | Agent instructions, CI, scripts folder |
| `{{SOURCE_DIRS}}` | Step 5 | Folders with the repo's own code, e.g. `` `src/` and `tests/` `` | Repo layout |
| `{{SHIPPED_PROJECTS}}` | Step 7 | List of projects whose output reaches users (apps, services, published packages), or a rule that identifies them, e.g. "non-test projects with a committed lockfile". Step 8 scans each for vulnerabilities | `OutputType`, `IsPackable`, publish profiles, installer projects, CI publish steps |
| `{{HELD_PACKAGES}}` | Policy | Table rows `` | `Id` | reason | `` for packages the user won't update without a migration. None: replace the table with "None yet" | Ask the user; propose currently deprecated packages and pending majors with known migrations |
| `{{SDK_PRECONDITION}}` | Step 1 | Bullets about the SDK, see below. Nothing applies: remove the line | `global.json`, `SelfContained`, `PublishAot`, publish profiles, Docker base images |

`{{SDK_PRECONDITION}}` cases, combine those that apply:

- `global.json` pins the SDK with `rollForward: disable` (or `patch`): "`dotnet --version` must equal `global.json`'s
  `sdk.version`; otherwise no `dotnet` command runs. IDE updates replace the SDK patch silently. Ask the user to
  update the pin." Add who may edit `global.json` if the agent instructions say so.
- Self-contained or NativeAOT apps: "Shipped apps are self-contained, so the SDK's runtime patch is what customers
  get: mention its security fixes in the report." For NativeAOT: "An SDK change moves the NativeAOT lockfiles
  (ILCompiler/ILLink) in step 7."

## 5. Ask the user

One message, each item with your recommendation and its reason:

- each missing prerequisite: why the skill needs it, configure or remove, and what removal loses. Changes to
  `.gitignore`, project files, CI or `nuget.config` affect the whole team and its builds, so they need the user's
  approval even when the fix is obvious
- the script language, if step 3 left it open
- placeholder values you couldn't find, and the held packages
- the policy below, in plain words with the reason for each rule from SKILL.md Policy, asking whether to keep it or
  change anything. It decides which updates the agent takes without asking, so the user should own it:
  1. Microsoft packages (owners in `$microsoftOwners`) are trusted: newest stable version, no age gate, no code review
  2. Third-party packages: newest stable version at least 7 days old, plus a supply-chain and code review
  3. Prerelease versions only when the current version is a prerelease
  4. Packages of one family move together; if one can't move, the family is held
  5. Transitive packages are never pinned to clear an advisory
  6. Commercial use is assumed: a license change away from permissive (MIT, Apache-2.0, BSD) holds the family
  7. Only advisories that reach a shipped project are reported
  8. The agent never commits

Wait for the answers.

## 6. Apply

- Fill the placeholders.
- Apply the prerequisite decisions. When functionality is removed, also remove or rewrite every SKILL.md instruction
  that relies on it: an instruction to run a missing script or read a missing section sends the agent searching for
  something that isn't there.
- Do the shell port, if chosen.
- Apply policy changes in both scripts and SKILL.md: age gate in `Get-PackageUpdates.ps1` (`$minAgeDays`) and
  SKILL.md (Policy, step 2); prerelease rule in `Get-PackageUpdates.ps1` (`$takePrerelease`) and SKILL.md Policy;
  Microsoft owners in `Get-PackageUpdates.ps1` (`$microsoftOwners`); license rule in SKILL.md step 3.
- If the repo's agent instructions require extra steps for code changes (review files, formatting, staging or commit
  rules), add them to SKILL.md step 1 or 9: editing package versions is a code change.
- Leave the examples (Dapper, Polly, OpenTelemetry, AngleSharp, FluentAssertions): they illustrate the rules.

## 7. Verify

- No `{{` left in `SKILL.md`
- Read `SKILL.md` top to bottom as an agent on its first run would: every command, path, script and section it names
  exists
- `Get-PackageUpdates.ps1` runs without errors and writes `.tmp/nuget-update/packages.json`; an empty list is fine
  when every package is current
- `Get-ReleaseDiff.ps1` completes for one third-party package: a `Target` from that list, or `-From`/`-To` with an
  older version of a package the repo references
- `Compare-LockFiles.ps1` (or its replacement) prints nothing on a clean tree

Then offer the user a full dry run: ask the agent to "check NuGet packages". In check mode the skill stops after
its step 5 and edits nothing, so it exercises discovery, review and impact search safely.

## 8. Report

Print in the chat:

```markdown
## Placeholders
| Placeholder | Value | Source |
|---|---|---|
<one row each; source is a file and line, a command, "user answer" or "assumed">

## Prerequisites
<each: present · configured (what changed) · removed (what the skill no longer does)>

## Policy
<kept, or each change>

## Other changes
<shell port, package feeds, agent-instruction steps. Omit when empty>

## Verification
<result of each check in step 7>

## To confirm
<assumptions the user should check. Omit when empty>
```

Then offer to delete this file: the skill doesn't use it.
