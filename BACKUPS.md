# Backups and restoring

For a training log the history *is* the product, so this is the one failure that cannot be
apologised for. #348 opened with "there are no database backups"; that turned out to be
half right, and the half that was wrong matters as much as the half that was right.

## What actually exists

`tectonic_production` is a Render Postgres instance on the **`0.1c-256mb`** plan, Postgres 15,
in Oregon. That is the plan formerly called **starter** and it is a rename rather than a
resize: Render refuses the legacy names for a blueprint outright — *"Legacy Postgres plans,
including 'starter', are no longer supported for new databases"* — and 256 MB is the same
256 MB this instance has always had. `render.yaml` carries the current name and the story.

Two different plans decide two different things here, and conflating them is how this file was
wrong before. **The compute plan decides whether there is any backup at all. The workspace
plan decides how far back point-in-time recovery reaches.**

| | free compute | paid compute (this one) |
| --- | --- | --- |
| point-in-time recovery | none | yes — window set by the *workspace* plan, below |
| logical backups (exports) | none | on demand, kept **7 days**, whatever the workspace plan |

| workspace plan | recovery window |
| --- | --- |
| Hobby | past 3 days |
| Pro or higher | past 7 days |

Both tables are Render's own, read off `render.com/docs/postgresql-backups` on 2026-09-24.
**Which workspace plan this is has not been checked** — it is on the billing page and nowhere
in the CLI — so read the smaller number as the one in force until somebody looks.

Two things about PITR that are easy to assume and are not so. It is **not** an export sitting
somewhere: triggering it spins up a *new* instance alongside the old one, which you then
validate and switch to. And **the recovery instance copies the IP allow list from the
original**, so with the list closed, a recovery instance is a database you cannot connect to
from your laptop either — which is worth knowing before the afternoon you need one.

Render does **not** create logical exports on a schedule. They are on demand, so "Render has a
backup" is only ever true of PITR.

So the sentence in #348 — "everything anyone ever logged is gone, permanently" — was not
true of an accidental delete or a bad migration. Three days of PITR covers those, and it is
the mechanism that recovers the most recent data.

**What it does not cover is the case #348 actually describes: a billing lapse.** A suspended
instance stops being a thing Render is keeping recovery data for, and three days is not long
enough to notice a failed payment. That is the gap an off-Render copy closes, and it is the
reason to take one even though PITR exists.

The plan is declared in `render.yaml` for exactly this reason. Dropping the instance to free
would remove every backup this app has and nothing would announce it.

## The allow list, and what it costs

The database currently admits `0.0.0.0/0`. #559 closes that, and the thing to know before it
happens is that **closing it costs more than it looks like it costs**, because the tools that
appear to go through Render do not.

`render psql` does not tunnel. Its CLI asks the API for the database's *external* connection
string, hands it to a local `psql`, and before that it looks up your public address and
refuses outright if it is not on the list — `IP address (x.x.x.x) not in allow list for
tectonic_production`. `render pgcli` is the same code, and the Render MCP server's "query my
database" tool connects the same way. So an empty allow list costs `pg_dump`, `render psql`,
`render pgcli`, the MCP query tool and every GUI client at once. Afterwards, an interactive
session means a shell inside Render, or re-opening the list to a single address for as long as
the session lasts.

What it does not cost is the backup below, because that never opens a socket to the database.

## Taking a copy

```sh
bin/backup
```

That is the whole of it. It asks **Render** to take the `pg_dump`, server-side, over its
public API — `POST /v1/postgres/{id}/export` to start one, `GET` on the same path to find it
and its download URL — then downloads the result, checks that what arrived is a dump with rows
in it, and deletes copies that have outlived their retention. An API call is not a database
connection, so none of it notices the allow list, and every part of it is included in the plan
already being paid for.

It is Ruby, it is `lib/tectonic/backup.rb` and `lib/tectonic/backup/render_export.rb`, and it
needs **no gem and no service**: standard library only, no `bundle exec`, no database. That is
deliberate — the day you need this is a day when other things are broken, and a backup tool
that a dependency resolution can stop has a second way to fail at the worst moment.

It prints something like:

```
4 copies here; the newest is 7.1 days old (tectonic-2026-09-17T09-02Z.dir.tar.gz).
Asked Render for an export; waiting up to 20 minutes.
Wrote tectonic-2026-09-24T09-14Z.dir.tar.gz (311.4 KB).
  190 entries, 23 tables, 23 of them carrying rows.
  retention: deleting tectonic-2026-08-20T09-01Z.dir.tar.gz (35 days old)
PASSED: tectonic-2026-09-24T09-14Z.dir.tar.gz is a readable dump with rows in it.
```

The first line is the part worth reading even when the rest goes well: it says how long it has
been since anyone did this.

**Everything short of that is a non-zero exit and a sentence.** No key, no such database, two
databases with that name, Render refusing the export, Render never finishing it, a download
that is an error page, a tarball with no dump inside, a dump with a schema and no rows — each
of those stops the run and says which it was. There is no warning level, because a run that
did not produce a backup did not produce one.

By hand, if the script is not to hand or you want to see it in the dashboard: the database's
Recovery page has **Create export**, and the download link appears there when it is ready. It
is the same file by the same mechanism. Note that Render will not start an export while
another is in progress for the same database, which is the one refusal that means "wait".

### The key

The Render API key lives at **`~/.config/render/api-key`**, mode 600, outside every repo, read
as a bare value — the same rule `AGENTS.md` sets for the Fathom token, for the same reason:
this repository is public, it already has both `.env` and `.env.rb`, and a credential that
never enters the tree cannot be committed by an editor that was being helpful.

```sh
mkdir -p ~/.config/render
printf %s 'rnd_...' > ~/.config/render/api-key && chmod 600 ~/.config/render/api-key
```

`RENDER_API_KEY` is read first if it is set, as an override rather than the habit — it is the
seam anything scheduled would use later. It is deliberately **not** read out of
`~/.render/cli.yaml`, which is sitting right there with an `api.key` in it: that is the CLI's
*session* token, with an `expires_at` and a refresh token beside it, and a backup built on a
thing that expires works right up until the day it does not.

Make the key at `dashboard.render.com/settings#api-keys`. It can read and change every service
in the workspace, so it is a credential in the same class as the database password.

### Where the copies live, and for how long

`~/backups/tectonic`, which is not inside any repository — `bin/backup` refuses a directory
that is, walking up the tree to check, because `~/repos/tectonic/backups` is inside one and
does not look it. A dump is every account's training history and every email address in the
database; a file committed to git history is not deleted by deleting it, and this repository
is public.

**Retention is 30 days**, and the newest three copies survive it however old they are — the
case that matters more than the policy is nobody having run this since July, where obeying the
policy literally would delete the lot. Deletions are printed one per line.

Thirty days is a compromise with a sentence in `legal/privacy.md`: *"Delete your account and
your training data goes with it."* A retained backup makes that quietly untrue until the copy
is gone, so the window is the shortest one that still covers the failure this file exists for
— a billing lapse, which takes longer than three days of PITR to notice and not much longer
than a month. **If that sentence is published, it needs a clause saying backups are kept for
up to 30 days.**

On encryption: not for a copy that stays on a FileVault laptop, which is already encrypted at
rest, and where a second layer means a second key to lose — and a backup you cannot open is
not a backup. **Any copy that leaves that laptop must be encrypted**, and that is the line
this change deliberately does not cross: nothing here uploads anything anywhere.

### Checking that it is still happening

```sh
bin/backup --check
```

Takes nothing, touches nothing, and prints the age of the newest copy — then **exits non-zero
if it is more than 8 days old**. Eight, because Render keeps its own exports for seven days:
past that there is no twin left on Render either, and the only copy of anything since then is
the live database.

This is the honest answer to the failure mode this whole file is about. Nothing can make a
backup *run* — the run is a person, and a person forgets — but a missing run can be made to
say so out loud when asked. It is also the seam to hang a scheduled alert on later, and it is
what the automated version would run first.

## Rehearsing the restore

A backup nobody has restored is a belief, not a backup. The ways it fails are quiet: the
wrong `--format`, an extension the target lacks, a role the dump references. None announce
themselves until the day they matter, which is the day nothing else is going well either.

Render's export is a **directory-format dump inside a `.dir.tar.gz`**, so there is one step
before the drill: untar it, and hand the drill the *directory* that comes out.

```sh
tar xzf ~/backups/tectonic/tectonic-2026-09-24T09-14Z.dir.tar.gz -C /tmp
rake 'backup:drill[/tmp/tectonic_production_7oho]'
```

The name of the directory inside the tarball is Render's, not ours — `tar tzf` shows it, and a
successful `bin/backup` run prints the exact two commands with it filled in. Delete it when
the drill is done: it is a second unencrypted copy of everybody's training log.

Handing the drill the tarball itself fails, loudly, which is the acceptable kind of wrong:

```
pg_restore: error: input file does not appear to be a valid archive
rake aborted!
```

The drill drops and recreates `tectonic_restore_drill`, loads the dump — `pg_restore` or
`psql` depending on the extension, so nobody has to remember which — and then asks the
restored copy questions rather than trusting the exit code:

```
  schema version 50 (this checkout expects 50)
  23 tables, 1 accounts, 1 workouts, 1 sets
PASSED: tectonic_restore_drill is a working copy.
```

It fails, loudly and differently, on each of the ways a restore is wrong while appearing to
work:

- **nothing loaded** — no tables at all
- **schema-only dump** — tables present, no rows, which is the `pg_dump -s` mistake; never
  take a dump that way, it restores without error and gives back an app where every account
  has vanished
- **wrong era** — restored at a migration version this checkout does not expect; the data is
  intact and the app would need migrating before it could serve it
- **schema and version but no accounts**

The scratch database is dropped at the start of every run, so a drill cannot pass by finding
what a previous run left behind. That is the failure mode of every restore test that reuses
its target.

Clean up with `dropdb tectonic_restore_drill`.

`bin/backup` runs a cheaper version of the same suspicion on every copy it takes: it reads the
dump's table of contents with `pg_restore --list` and refuses one that has tables and no
`TABLE DATA`. That needs no database and takes a second, so it can happen every time — but it
is a table of contents, not a restore, which is why a successful run ends by printing the
drill command rather than a clean bill of health.

## What is still not done

- **No nightly off-Render copy.** `bin/backup` is still something a person runs. What has
  changed is the reason it stayed manual: automating it no longer needs object storage or a
  credential held by a third party, because the export API needs neither. The next step, when
  this has proved itself by hand, is a scheduled run in a *private* repository holding the API
  key as a secret, encrypting the dump to a public key the owner holds and attaching it to a
  dated release — and that job's first act should be `--check`, so the alarm comes from
  something that ran rather than from something that did not.
- **The drill has not been run against a production dump.** What it *has* now been run against
  is a directory-format dump inside a `.dir.tar.gz` — the exact shape Render's export arrives
  in — produced from a local database migrated to this checkout's schema: the drill passes on
  the untarred directory and fails on the tarball with the error quoted above. That proves the
  shape and the extra step. It does not prove anything about the production database, which
  still needs somebody to run `bin/backup` for real.
- **Nothing here has been run against Render.** #588 says not to take an export of production
  to find out whether the code works, so the ask-wait-download-check loop was rehearsed against
  a stub of Render's API on localhost instead — `RENDER_API_BASE` exists for that and for
  nothing else. That covers the shape of the conversation, the poll that waits for an export
  without a URL yet, the redirect to storage, and the fact that the API key is not forwarded
  across it. What it cannot cover is Render's actual answers, so the first real run is also the
  first test of them: expect to find out there, and not before, whether the download URL wants
  the key — the code tries it both ways for that reason.
