# Backups and restoring

For a training log the history *is* the product, so this is the one failure that cannot be
apologised for. #348 opened with "there are no database backups"; that turned out to be
half right, and the half that was wrong matters as much as the half that was right.

## What actually exists

`tectonic_production` is a Render Postgres instance on the **starter** plan, Postgres 15,
in Oregon. Render's backup policy goes by tier, and starter is above the line:

| | free | starter (this one) | pro and above |
| --- | --- | --- | --- |
| point-in-time recovery | none | **past 3 days** | past 7 days |
| logical backups (exports) | none | **kept 7 days after they are taken** | kept 7 days |

So the sentence in #348 — "everything anyone ever logged is gone, permanently" — was not
true of an accidental delete or a bad migration. Three days of PITR covers those, and it is
the mechanism that recovers the most recent data.

**What it does not cover is the case #348 actually describes: a billing lapse.** A suspended
instance stops being a thing Render is keeping recovery data for, and three days is not long
enough to notice a failed payment. That is the gap an off-Render copy closes, and it is the
reason to take one even though PITR exists.

The plan is declared in `render.yaml` for exactly this reason. Dropping the instance to free
would remove every backup this app has and nothing would announce it.

## Taking a copy

`render psql` gives a session; for a dump, get the external connection string from the
instance's dashboard page and use `pg_dump` directly:

```sh
pg_dump -Fc -f "tectonic-$(date +%F).dump" "$EXTERNAL_DATABASE_URL"
```

`-Fc` (custom format) rather than plain SQL: it restores with `pg_restore`, which can be
told `--no-owner --no-privileges`. A plain dump carries the Render role names, and restoring
one onto a laptop fails on roles that do not exist there — noisily, and in the middle of the
one situation where noise is least welcome.

**Never with `-s`.** That takes the schema and none of the rows, restores without error, and
gives back an app where every account has vanished. The drill below refuses that case by
name because it is the most convincing way to be wrong.

## Rehearsing the restore

A backup nobody has restored is a belief, not a backup. The ways it fails are quiet: the
wrong `--format`, an extension the target lacks, a role the dump references. None announce
themselves until the day they matter, which is the day nothing else is going well either.

```sh
rake 'backup:drill[tectonic-2026-09-05.dump]'
```

It drops and recreates `tectonic_restore_drill`, loads the dump — `pg_restore` or `psql`
depending on the extension, so nobody has to remember which — and then asks the restored
copy questions rather than trusting the exit code:

```
  schema version 27 (this checkout expects 27)
  17 tables, 1 accounts, 1 workouts, 1 sets
PASSED: tectonic_restore_drill is a working copy.
```

It fails, loudly and differently, on each of the ways a restore is wrong while appearing to
work:

- **nothing loaded** — no tables at all
- **schema-only dump** — tables present, no rows, which is the `-s` mistake above
- **wrong era** — restored at a migration version this checkout does not expect; the data is
  intact and the app would need migrating before it could serve it
- **schema and version but no accounts**

The scratch database is dropped at the start of every run, so a drill cannot pass by finding
what a previous run left behind. That is the failure mode of every restore test that reuses
its target.

Clean up with `dropdb tectonic_restore_drill`.

## What is still not done

- **No nightly off-Render copy.** The dump above is manual. Automating it needs somewhere to
  put it (object storage) and a credential to put it there, which is a decision about where
  this app's data is allowed to live rather than a script.
- **The drill has not been run against a production dump.** It has been run against a full
  local dump, a schema-only dump and an empty file, and behaves correctly on all three — but
  the rehearsal #348 asks for is one against the real thing, and that needs someone who can
  reach the production instance.
