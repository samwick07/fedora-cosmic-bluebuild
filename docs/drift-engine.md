# Drift engine (`cosmic-drift`) — design

**Status: proposed, 2026-10-04.** Replaces the report-only drift step (spec O1) once approved.
Spec rows: O2 (new, replaces O1) and F11 (new) in `docs/end-state.md`, both `proposed`.

## 1. Purpose

The machine must stay rebuildable from its declarations: the image, the dotfiles, the
spec. Today the nightly job only *reports* what differs. A report is easy to ignore, and
the reason behind a change is lost by the next day.

The engine turns every difference into a decision that is recorded:

- **Detect** every difference between the machine and its declarations, automatically.
- **Capture intent**, while you still remember it when possible.
- **Force a verdict** on each difference (adopt, revert, except, propose) without much
  friction. A change that is never decided fails acceptance after a short grace period.
- **Keep it declarative:** an adopted change becomes a line in a declaration file,
  committed with its reason. The ledger and `git log` answer "why is this here?"

Success looks like this:

- Every item `cosmic-drift scan` finds is declared, excepted with a live reason, proposed
  for the image, or still inside its grace period.
- Adopting a CLI tool costs one typed sentence.
- Acceptance and the nightly report say so when drift goes undefended.

## 2. Prior art (surveyed 2026-10-04)

| Tool | What it covers | Why it is not used |
| --- | --- | --- |
| [metapac](https://github.com/ripytide/metapac) | Declarative package lists for 20 backends (brew, dnf, flatpak, apt…); `unmanaged`, `sync`, `clean`; per-host groups | Reconciles but records no intent, exceptions or expiry. No `/etc`, dotfiles or units. It would add a third declaration format beside the Brewfile and `distrobox.ini`, and its dnf backend has no meaning on an Atomic host |
| [homebrew-file](https://github.com/rcmdnk/homebrew-file) (`brew-wrap`) | Rewrites the Brewfile after every `brew install`; git sync | Homebrew only, no reason captured. It writes the rendered `~/.config/homebrew/Brewfile`, not the chezmoi source, which would create drift of its own |
| [aconfmgr](https://github.com/CyberShadow/aconfmgr) | Closest in spirit: `save` writes undeclared packages and `/etc` changes into the config, `apply` does the reverse; explicit installs only | Arch / pacman only |
| [home-manager](https://github.com/nix-community/home-manager) (Nix) | User environment declarative by construction | A lane change: it would replace Homebrew and chezmoi (spec C1, D-rows). It covers neither `/etc` on ostree, nor the boxes, nor intent |

Ideas taken over: "explicitly installed packages only, ignore dependencies"
(aconfmgr) and per-machine lists (metapac; here, `.chezmoidata/machines.yaml`).

## 3. Concepts

### 3.1 Items

An **item** is one difference between the machine and its declarations. Its ID is
`<source>:<key>` and stays the same across scans, so a decision sticks to it.

| Source | ID | Change | Declared in | Lane |
| --- | --- | --- | --- | --- |
| Homebrew | `brew:<formula>` | extra / missing | the Brewfile; `brew_extra` in `machines.yaml` | dotfiles |
| Box packages | `box:<box>:<pkg>` | added / removed | creation baseline + that box's `additional_packages` in `distrobox.ini` | dotfiles |
| chezmoi | `chezmoi:<target path>` | modified / missing | the chezmoi source | dotfiles |
| User units | `unit-user:<unit>` | enabled / disabled, not declared | an enable link (`symlink_` in `.config/systemd/user/*.wants/`) or unit file that chezmoi manages | dotfiles |
| `/etc` | `etc:<path>` | added / modified / deleted vs the image | the image | image |
| Layered packages | `layered:<pkg>` | layered / overridden / removed | the image | image |
| Flatpaks | `flatpak:<app id>` | extra / missing (system); any user flatpak | the image's `flatpaks.list` | image |

Notes:

- **System units are not a separate source.** Enabling one writes a symlink under
  `/etc/systemd/system/`, which the `/etc` source reports. Review labels those items as
  units.
- **`/etc` items carry a content hash.** An exception covers that content only; editing
  the file again brings it back up.
- **Box packages are explicit installs only:** `dnf repoquery --userinstalled` (Fedora
  boxes), `apt-mark showmanual` (Ubuntu boxes). Dependencies never appear. The rootful
  `net` box stays image-managed and is not scanned for package drift.

### 3.2 Verdicts

| Verdict | Meaning | Lanes |
| --- | --- | --- |
| **adopt** | Make it declared: the engine edits the declaration and commits | dotfiles |
| **revert** | Undo it with the source's own tool, after showing the command | all |
| **except** | Keep it undeclared for now: a reason and an expiry (default 30 days, at most 365). Expired means back in the queue | all |
| **propose** | Ask for the image to declare it: a leak-checked GitHub issue on this repo, or a saved draft | image |

### 3.3 Item states

| State | Meaning |
| --- | --- |
| `undecided` | No ledger entry |
| `excepted` | Exception or posted proposal, not expired |
| `draft` | Proposal saved but not posted (offline, no `gh`); counts as defended for 7 days |
| `expired` | The exception or proposal ran out |
| `pending-apply` | Adopted, but the machine does not match yet (e.g. `chezmoi apply` not run) |
| `unknown` | Its collector could not run; never treated as clean |

`first_seen` is carried forward between scans, so grace periods count from when a change
first appeared.

### 3.4 Lists versus lanes (new spec F11)

The spec decides **lanes and capabilities**. The declaration files hold the **lists**:
the Brewfile, each box's `additional_packages`, `flatpaks.list`. Adding another formula
or another package to `dev` needs a ledger reason, not a spec row.

A spec change is needed only when an item fits no existing row: a new box, a new lane, a
host service, a new capability. Adopting such an item proposes a `spec:` issue instead.

## 4. The ledger

`.drift/ledger.toml` lives in the dotfiles repo and is listed in `.chezmoiignore`, so it
never lands in `~`. It holds one `[[entry]]` per ID and machine, sorted by ID.
`cosmic-drift` writes it; hand edits are fine.

```toml
# Why this machine differs from its declarations, or was changed to match them.
[[entry]]
id = "brew:ripgrep"
verdict = "adopt"
why = "fast search through the agent logs"
machine = "all"          # all | frmwrk | dsktp
date = 2026-10-05

[[entry]]
id = "etc:/etc/example.conf"
verdict = "except"
why = "temporary while the VPN trial runs"
machine = "frmwrk"
date = 2026-10-05
expires = 2026-11-04
hash = "sha256:…"        # /etc items only

[[entry]]
id = "layered:htop"
verdict = "propose"
why = "needed on the host before any box exists"
machine = "frmwrk"
date = 2026-10-05
expires = 2026-11-04
ref = "fedora-cosmic-bluebuild#42"   # or the draft path while unposted
```

Each verdict is also one commit in the dotfiles. The commit contains the ledger entry and
any declaration edit, and carries these trailers:

```
drift: adopt brew:ripgrep

Why: fast search through the agent logs
Drift-Id: brew:ripgrep
Drift-Verdict: adopt
Drift-Machine: all
```

`git log --grep 'Drift-Id: brew:ripgrep'` is the history; `cosmic-drift why <id>` shows
the entry and that history together.

Python's `tomllib` reads the ledger. `cosmic-drift` writes it with a small serializer for
this fixed schema (strings, dates, the fields above), so no third-party module is needed.

## 5. Detection

### 5.1 The nightly scan (the authority)

`cosmic-drift scan` replaces `drift()` as step 2 of the nightly job, running as root:

1. Run every collector. Collectors that need the user (Homebrew, boxes, chezmoi, user
   units) run as the user, as the job already does.
2. Read the ledger from `$UHOME/.local/share/chezmoi/.drift/ledger.toml` as **data
   only**. Nothing in the user's home is executed (this keeps J1's rule).
3. Classify each item (3.3), carrying `first_seen` forward from the previous scan.
4. Write `/var/lib/cosmic-nightly/drift.json` (0644) and the human-readable `drift.txt`
   for the nightly report.

`drift-ignore.regex` (generic `/etc` noise, public) stays in the image. Personal noise
is handled with ledger exceptions.

`drift.json` holds:

- `scanned` (a timestamp);
- `sources`: per source, `ok` or `unknown` with the error;
- `items`: each with `id`, `source`, `lane`, `change`, `detail`, `first_seen`, `state`,
  and `entry` (the ledger entry, if any).

### 5.2 The live rescan

`cosmic-drift review` and `list` rescan the user-lane sources live, with no sudo. For the
image-lane sources they use the last nightly result and show its age. `sudo cosmic-drift
scan` refreshes everything on demand.

### 5.3 Shell wrappers (intent at the moment)

`~/.config/bash/drift.bash` (dotfiles, sourced by `.bashrc`) defines wrappers in
**interactive shells only**. Scripts and agents never see them.

| Command | Caught as |
| --- | --- |
| `brew install` / `uninstall` / `tap` / `untap` | `brew:<formula>` |
| `flatpak install` / `uninstall` | `flatpak:<id>` |
| `systemctl --user enable` / `disable` | `unit-user:<unit>` |
| `rpm-ostree install` / `uninstall` / `override` | `layered:<pkg>` |
| inside a box: `sudo dnf install` / `remove`, `sudo apt install` / `remove` | `box:<box>:<pkg>` (a `sudo` wrapper; every other `sudo` command passes straight through) |

The real command runs first. Only if it succeeds does one prompt appear:

```
brew: ripgrep installed.  Why? (Enter = later, e = except)  › fast search through the agent logs
✓ adopted into the Brewfile (all machines) — committed, pushing in background
```

The prompt's answers:

- **A typed reason adopts.** For an image-lane item it starts a proposal instead, and the
  issue text is shown before anything is posted.
- **`e`** asks for a reason and an expiry.
- **A bare Enter** leaves the item for review. The command line is saved to
  `~/.local/state/cosmic-drift/notes.jsonl`, so review can say what caused it.

The wrappers capture intent conveniently. They are not the authority: `command brew …`,
agent installs, GUI installs and `/etc` edits are all found by the scan.

## 6. Review and the command line

`cosmic-drift review` (alias `drift`) shows the items needing a decision:

- **Order:** expiring exceptions first, then oldest undecided, grouped by source.
- **Each item shows:** what changed, when it was first seen, the command that caused it
  (from the notes), and any saved reason.

Keys:

| Key | Action |
| --- | --- |
| `a` | adopt |
| `r` | revert |
| `e` | except |
| `p` | propose |
| `d` | diff (`/etc` against `/usr/etc`; `chezmoi diff`) |
| `s` | skip |
| `q` | quit |

A capital letter applies the verdict, with one reason, to every item in the current group.

Every action also has a non-interactive form, so nothing depends on the screen or on an
AI session:

```
cosmic-drift scan [--json]                     # root; the nightly job runs it
cosmic-drift status [--short]                  # counts and the oldest item; used by notify and acceptance
cosmic-drift list [--all]
cosmic-drift adopt|revert|except|propose <id>... --why "…" [--days N] [--machine all|<name>]
cosmic-drift why <id>
```

`--machine` defaults to `all` for adopt (review asks) and to this machine for except and
propose.

## 7. Verdict mechanics

All dotfiles edits go to the chezmoi source (`chezmoi source-path`). Each verdict then
runs:

1. `git pull --rebase` (stop on a real conflict);
2. the edit, plus `chezmoi apply <that path>`;
3. the collector again, as a check;
4. a commit of the touched paths only;
5. `git push` in the background.

**If the check still sees the item, the edit is rolled back** (`git checkout -- <paths>`)
and the reason is printed. Nothing is ever half-adopted.

### 7.1 Adopt

| Item | Edit |
| --- | --- |
| `brew:` extra | Add `brew "<f>"` to the Brewfile template, or to `brew_extra` for this machine only |
| `brew:` missing | Remove its line |
| `box:` added | Add `additional_packages="<pkg>"` under that box in `distrobox.ini` |
| `box:` removed | Remove the name from that box's lines |
| `chezmoi:` modified | `chezmoi re-add <path>`. Templates: open the source in `$EDITOR`, then check |
| `unit-user:` | Add the enable link to the chezmoi source (`symlink_` entry), plus the unit file if it is your own and unmanaged |
| image lane | Not possible; use **propose** |
| new capability (F11) | Not possible; **propose** a `spec:` issue |

### 7.2 Revert

Revert always shows the exact command and waits for `y`.

| Item | Command |
| --- | --- |
| `brew:` | `brew uninstall <f>`, or `brew bundle install` for missing ones |
| `box:` | `distrobox enter <box> -- sudo dnf remove` / `sudo apt remove` (or install, for removed) |
| `chezmoi:` | `chezmoi apply --force <path>` |
| `unit-user:` | `systemctl --user disable` / `enable` |
| `flatpak:` | `flatpak uninstall` / `install` |
| `layered:` | `sudo rpm-ostree uninstall` / `override reset` (staged; applies at your next reboot) |
| `etc:` modified / deleted | show the diff, then `sudo cp -a /usr/etc/<path> /etc/<path>` |
| `etc:` added | show it, then `sudo rm` |

### 7.3 Propose

1. Compose an issue: title `drift: propose <id> for the image` (or `spec: …`); the body
   holds the change, the scrubbed detail and the reason. Open it in `$EDITOR`.
2. **Leak check** before posting:
   - mask `$HOME`, the user name (`$SITE_USER`), the hostname, the tailnet name (from
     `tailscale status --json`), UUIDs and IP addresses;
   - refuse to post while any `/home/<name>`, `/var/home/<name>` or `/run/media/<name>`
     pattern remains (as `scripts/check-leaks.sh` does).
3. Post with `gh issue create --repo samwick07/fedora-cosmic-bluebuild --label drift`.
   The ledger entry gets `ref` and a 30-day expiry. When it expires, check the issue: if
   the image now declares the item, the item is gone anyway; if not, decide again.
4. **Offline, or `gh` not signed in:** save the draft to `.drift/drafts/<id>.md` in the
   dotfiles. The item becomes `draft` (7 days). The draft can be pasted into GitHub's web
   form by hand.

## 8. Enforcement and integration

**Acceptance check O2** (`cosmic-acceptance`, run nightly by J1):

| Result | When |
| --- | --- |
| PASS | Nothing open |
| WAIT | Every open item is inside its grace period: "2 to decide, oldest 1 day: run `drift`" |
| FAIL | Any `undecided`, `expired` or `unknown` item older than 3 days; any `draft` older than 7 days; any `pending-apply` older than 1 day; an unreadable ledger |

A FAIL makes acceptance incomplete. So the known-good pin (L3) does not move forward, and
the nightly report lists it first. Nothing is blocked.

Elsewhere:

- **Login notification:** the first line becomes "Drift: N to decide, oldest D days, M
  exceptions expiring this week".
- **Monthly box rebuild (O1 today):** unchanged, with "a box without changes" meaning a
  box with no open or excepted `box:` items.
- **Manifest and backups (R1):** unchanged. The ledger is part of the dotfiles and of
  `$HOME`.

## 9. Privilege and privacy boundaries

- `scan` runs as root. It **parses** the ledger and the notes and never executes
  anything from the user's home.
- `review` and the verdict commands run as the user. `sudo` is used only for a revert
  you confirm (`layered:`, `etc:`).
- The ledger, notes and drafts are private (the dotfiles repo). Only a proposal you have
  seen and that passed the leak check reaches the public repo.
- The wrappers never change what the wrapped command does. They only prompt after it
  succeeds.

## 10. Failure handling

| Failure | Behaviour |
| --- | --- |
| Ledger unreadable | One item with the line number. Every other item counts as undecided, not clean. Verdict commands refuse to write until it is fixed |
| A collector fails (podman down, chezmoi missing) | That source is `unknown` (FAIL after 3 days) |
| Push fails | The commit stays local; `status`, review and the report show "N commits not pushed" |
| Unrelated changes in the dotfiles | Only the paths the verdict touched are committed |
| Concurrent edits from dsktp | `git pull --rebase` first; one block per ID keeps conflicts rare and readable; a real conflict stops with a message |
| Adopt check fails | Roll back the edit, print why, leave the item open |

## 11. Layout

| Where | What |
| --- | --- |
| image `files/scripts/cosmic-drift.py` → `/usr/bin/cosmic-drift` | the engine (Python 3, standard library only) |
| image `files/scripts/cosmic-nightly.sh` | step 2 calls `cosmic-drift scan`; `drift()` retires |
| image `files/scripts/cosmic-acceptance.sh` | O2 check from `cosmic-drift status --json` |
| image `files/scripts/cosmic-nightly-notify.sh` | the drift line |
| image `files/share/drift-ignore.regex` | unchanged |
| repo `tests/drift/` | unit tests and fixtures |
| dotfiles `.drift/ledger.toml`, `.drift/drafts/` | the ledger and unposted proposals (in `.chezmoiignore`) |
| dotfiles `dot_config/bash/drift.bash` | the wrappers, sourced by `.bashrc` |

## 12. Testing

Python `unittest` in `tests/drift/`, run in CI before the image build:

- **Collectors:** fed recorded output of `brew bundle check` / `cleanup`, `dnf repoquery
  --userinstalled`, `apt-mark showmanual`, `ostree admin config-diff`, `rpm-ostree status
  --json`, `flatpak list`, `chezmoi status`, `systemctl --user list-unit-files`.
- **Ledger:** read and write round trip; malformed input reported with its line.
- **States:** with a fixed clock (grace, expiry, draft, `pending-apply`, `unknown`).
- **Adopt edits:** against reference Brewfile, `distrobox.ini` and `machines.yaml`
  files (golden output).
- **Leak scrubber:** masking cases, plus cases that must be refused.
- **Wrappers:** in bash with stub commands (the real command's exit status decides
  whether the prompt appears; non-interactive shells are untouched).

On hardware, `cosmic-acceptance --exercise` adds a drift trial:

1. a harmless formula installed through the wrapper with a reason produces an adopt
   commit;
2. a `command brew install` of another is found by the next scan;
3. reverting it removes it;
4. the trial's commits are reverted at the end.

## 13. Rollout

1. Approve this design. O2 and F11 become `confirmed` and O1 is folded into O2; J1 step 2,
   L5 and section 6 are updated in the implementation PR.
2. Build after the 2TB **user-layer** step passes. The current O1 report covers the gap.
3. Test on the 2TB during the migration step. Tune the noise filters and collector rules
   against a real machine.
4. The 4TB install gets the finished image with no changes (F6).

## 14. Out of scope (v1)

- Automatic reverts of any kind.
- A GUI.
- Language-level global installs (`uv tool`, `npm -g` in `dev`): a later collector if
  they turn out to matter.
- Bottles prefixes and the Win11 VM's guest.
- dsktp-specific sources (it inherits the engine when its spec section is written).
