# Going to market

An assessment of how close Tectonic is to earning revenue, written against the tree at
`cc20f3c`. Every claim below was read out of the code rather than assumed, and where a
thing is a guess it says so.

## The short answer

Nothing here needs to be redesigned. Several things need to be typed.

That is the whole finding, and the asymmetry it describes is the interesting part: the
craft in this repository is well above its commercial readiness. The hard, structural work
— the part that usually turns a two-week estimate into six months — is done and running in
production. What is missing is not architecture. It is a mail provider, a unique index, a
page of legal boilerplate, and a column called `plan`.

Call it **four to five weeks of focused work to be *able* to take a payment.** How long to
a first paying *stranger* is not a code number, and this document will not invent one:
there is no acquisition channel in the repository at all.

## What is already built

These are assets, and they are worth naming before the list of gaps, because the gaps are
long and the assets are what make the gaps worth closing.

**The connector is live, standards-correct, and rare.** `https://tectonicplates.app` serves
`/welcome` and its OAuth authorization-server metadata resolves. Behind it is OAuth 2.1
with dynamic client registration, S256-only PKCE, RS256 JWTs, resource indicators, and a
per-request `revoked_at` check on the grant (`lib/tectonic/mcp/access_token.rb:40`), plus a
working revocation UI at `views/connections.erb`. Claude or ChatGPT adds this as a custom
connector with no token to paste. Most people trying to sell an MCP-connected product have
not built this, and it is the single thing here that Hevy, Strong and Boostcamp do not have.

**The schema has a real structural edge.** The prescription and the performance live on the
same row — `weight` and `reps` beside `planned_weight` and `planned_reps`
(`migrate/001_schema.rb:120-133`). "What did I ask for versus what happened" is one read.
That is exactly the shape a model needs to write next week, and retrofitting it into a
competitor's logger is a schema migration over years of data.

**Account scoping is systematic, so a paywall has somewhere to sit.** The MCP side has a
single choke point at `lib/tectonic/mcp/auth.rb:53`, one line after `RequestContext.from_claims`,
which gates all 25 tools including reads. The web side has seven identical
`require_login` + `@account_id` pairs wanting one shared helper. The exercise-ownership
split (`lib/tectonic/exercises.rb:27-40`) separates `visible_to` from `owned_by` precisely
so a nil `account_id` cannot hand back the shared library as writable — the obvious
multi-tenant data bug is not there.

**The tests gate deploys.** 516 runs, 1318 assertions, zero failures, one
environment-conditional skip, across 49 spec files and about 105 seconds, ten of them
driving a real browser. Branch protection applies to admins. Nothing reaches Render without
a green suite.

**Marginal cost per user is effectively zero.** Tectonic never calls a model API — the user
brings their own LLM subscription. Against products that pay for inference, that is a
structural advantage, and it is the strongest unit-economics fact in the project.

**Plate math is genuinely good.** Depth-first subset-sum with backtracking against a finite,
user-declared rack, returning nil rather than a lie for a weight the rack cannot make. It is
the app's namesake and it is correct.

## What stands between here and a first dollar

Five things are hard blockers in the sense that a stranger's money should not be taken until
they are fixed. None of them is difficult.

### 1. There is no email, so there is no account recovery

`app.rb:117` enables exactly `:login, :logout, :create_account, :remember, :json` plus the
OAuth features. No `reset_password`, no `verify_account`, no `change_password`, no
`close_account`. There is no mail gem, no SMTP configuration, no mailer anywhere in the
tree. Both the account identifier and the credential are frozen permanently at whatever was
typed at signup.

A paying customer who forgets their password loses the account, forever, with no self-serve
path and nobody to email. That converts directly into refunds and chargebacks. It also means
Stripe receipts, dunning, and cancellation notices have no delivery channel.

The tree is honest about this. `views/login.erb:27` carries a comment explaining that the
dead "Forgot password?" link was removed rather than left promising a way back in — and it
says the link belongs there again "once `reset_password` is enabled and a mail provider is
wired up, and not before." That is the right call and it is already made.

One detail cuts the estimate down: `require 'http'` at `app.rb:4` has **zero call sites**.
The HTTP client needed to POST to Postmark or Resend is already in the Gemfile and already
loaded. The long pole here is not integration, it is SPF/DKIM/DMARC on the domain and
letting deliverability warm up.

*Two to three days, most of it DNS.*

### 2. One email address can create two accounts, and the second is unloginable

`migrate/001_schema.rb:29` declares `String :email, null: false` with no unique index.
Rodauth's only defence against a duplicate login is catching a database uniqueness
violation, which cannot fire when there is no constraint to violate. Two signups with the
same address both succeed; Rodauth then resolves login to the first matching row, so the
second person gets 401 forever — and, per the finding above, has no reset path to escape
with.

This is a genuine data-integrity bug rather than an omission of style: `oauth_applications`,
`oauth_grants`, `exercises` and `account_equipment` all carry the unique indexes they need
(`migrate/001_schema.rb:58,59,84,85,86,100`). `accounts.email` was simply missed.

The migration is an afternoon. What it costs depends entirely on whether production already
holds duplicates, because nothing in the repository decides which row wins. **Run
`select email, count(*) from accounts group by 1 having count(*) > 1` before estimating
this.**

*An afternoon, or two days with a data review.*

### 3. There is no legal surface, on a product that tells people what to load

No `/terms`, no `/privacy`, no refund policy, no pricing page, and — specific to this
product — no injury or medical disclaimer on an app whose core value proposition is
prescribing a bar weight and estimating a one-rep max. `views/about.erb` is two paragraphs:
"Hi! I made an app... find me on twitter" and a Noun Project acknowledgement.

Stripe activation and card-network rules require published terms, a refund policy, and
business contact details before live payments. This is a serial dependency ahead of code —
the writing is an afternoon, the activation review is however long it takes.

It is also worse than a future problem. `views/layout.erb:30` already loads a third-party
analytics pixel on every authenticated page, sending URLs and IPs to a processor that no
policy names, because there is no policy. That exposure exists **today**, before any
payment.

There is no `LICENSE` file either, so the public repo is all-rights-reserved by default.
That protects the code, but it removes the one place a solo project normally puts its
"AS IS, no warranty" disclaimer — which, with no ToS, means a paid product would ship with
no warranty disclaimer of any kind. The assumption-of-risk clause is the one thing here a
template genuinely cannot generate; budget a lawyer read for that clause alone.

*An afternoon of writing. Unknown days of waiting.*

### 4. There is no entitlement concept anywhere

The `accounts` table is six columns and none is commercial (`migrate/001_schema.rb:26-32`,
plus `bar_weight` from `migrate/007`). No plan, no status, no customer id, no subscriptions
table, no webhook idempotency table. A repo-wide grep for `entitle|tier|premium|quota|paywall|subscri|billing|stripe`
returns `Warmup::TIERS` and two prose comments.

The only write gate that exists is `MCP_WRITES_ENABLED` (`lib/tectonic/mcp/config.rb:53`),
which is process-wide — it switches everyone off at once. A per-account cutoff *does* exist,
though: revoking a grant from `/connections` takes effect on the very next MCP request. It
is a kill switch, not a plan gate.

This is missing rather than broken, and because the choke points are already singular it is
the smallest of the five. One column, one migration, one condition at `auth.rb:53`.

*A week, including Checkout and the webhook.*

### 5. Nothing says what happens if the database is lost

There is not one line in the repository about backups, and `render.yaml` does not describe
the Postgres instance at all — only the web service. If the database goes, nothing in the
tree tells you what you had.

For a training log this is the unrecoverable failure. A lifter's history is the entire
product; there is no re-deriving it. Losing a paying customer's years of data is not a
refund, it is the end of the thing.

*A day: declare the database in the blueprint, add a Render cron running nightly `pg_dump`
to object storage, and do one actual restore drill.*

## The one nobody owns: the app does not know what day it is for the lifter

This falls between every category above, which is why it is easy to miss, and it is the only
item in this document that is *broken* rather than *missing*.

No timezone is set anywhere — not in `render.yaml`, not in `lib/tectonic/db.rb`, not as a
column on `accounts`. The app runs on two server clocks, neither of them the user's:
Postgres `CURRENT_TIMESTAMP` for the `workouts.date` default
(`migrate/001_schema.rb:109`, a `timestamp without time zone`), and Ruby `Date.today` for
every query and every generation decision — thirteen call sites across `app.rb` and `lib/`.

A lifter in New York opens the app at 20:30 on Monday. The server, on UTC, is already at
Tuesday:

- `login_destination` (`app.rb:605`) looks for a workout dated today, finds Tuesday, finds
  nothing, and sends them to `/workouts/new` — which is a three-line stub whose visible
  content is the string "make a new workout". Their own scheduled Monday session is
  invisible on the page they were told to open.
- MCP `create_workout` with `'today'` opens a **second, empty** workout rather than
  resolving Monday's. That tool's own description promises it reuses an existing workout on
  that day instead of creating a duplicate. For any US evening session, that promise is
  false.
- `Workout#status` (`lib/tectonic/workouts.rb:50`) marks an unlifted, in-progress Monday
  session `:skipped` at 20:00 Eastern.

CI is green on all of this because the specs use the same `Date.today` on both sides of the
assertion, so the bug is invisible to the suite by construction.

This matters more than its size suggests. It fires in the pounds-only US market that is
currently the only market the app supports, during the evening hours when most people lift,
and it happens without the customer doing anything wrong. It is the shape of defect that
produces a refund request on day two — arguably worse for a paying user than the missing
password reset, which at least requires them to forget something first.

*Two to three days: an account timezone column and thirteen call sites.*

## Where the price goes

Ranked by what the code actually supports.

### Strongest: the connector is the paid tier

Charge for MCP access; keep the tracker free. Roughly $5–8/month, though that figure is an
anchor rather than a researched price.

What supports it: the buyer is pre-qualified as someone already paying an LLM vendor — the
codebase says so twice (`app.rb:177`, `spec/oauth_spec.rb:176`) and the redirect allow-list
names exactly three vendor callbacks. Marginal cost is zero. The gate is one line at
`auth.rb:53`. And the upsell surface is already built and working: `views/connections.erb`
shows what is connected, hands over the URL, and revokes.

Better still, `views/authorize.erb` is the right place to show a price. It is 49 lines, it
reads the client name from the row, it renders per-scope checkboxes in plain English, and it
is the only screen in the entire OAuth flow where a *human* is present.

There is also an accident of history that already argues for this split. The README is stale
where it says programs are "authored in Ruby and run from rake" with "no UI for editing one
yet" — a full web program editor shipped in #70 (`app.rb:257-292`, `views/programs/*`,
`lib/tectonic/program_editor.rb`, covered by 336 lines of `spec/program_ui_spec.rb`). But
the *flagship* behaviours are not reachable from it: `preferred_reps` is hard-coded to nil
at `program_editor.rb:78`, `is_main` is never passed through `LIFT_FIELDS` (`app.rb:652`),
and `is_deload` and `is_ascending` appear in `views/` exactly once, as a read-only label.
MCP exposes all four (`create_program.rb:61-62`, `add_program_week.rb:25`,
`add_program_lift.rb:32`). So the worked example in README:202 — 4×5 at 155 converting to
4×3 at 165 — cannot be produced from a browser today, only from an assistant.

That is currently a bug in the funnel: the differentiated engine is accidentally gated
behind owning an LLM subscription, and nobody decided that. It is four form fields to fix.
But it also means the product has already, unintentionally, run the experiment of putting
its best behaviour behind the connector — and that is precisely the line a paid tier would
draw deliberately.

What undermines it: one fact cuts both ways. Anthropic's documentation currently indicates
custom connectors are available on Free as well as paid tiers (sources are inconsistent;
some archived versions say Pro and up). If Free works, the audience is larger than assumed
*and* the "they already pay for software" pre-qualification — the load-bearing half of the
price anchor — weakens.

### Second: coach seats

The highest price-per-user thesis, and cheaper than it first appears.

An earlier read of this suggested multi-athlete tooling was contradicted by the codebase's
central authorization invariant and would need an auth redesign. That is wrong, and the file
it cited disproves it: `RequestContext` takes an arbitrary `account_id` at construction
(`lib/tectonic/mcp/request_context.rb:29-33`, and `program_editor.rb:34` already does this).
The work is a membership table plus an authorization check at context construction. All 25
tools are untouched by design.

Weeks of product work, not a month of auth work. But it is genuinely absent from schema and
UI today, and it is a different business — sold to a different person, through a different
channel.

### Weakest: selling programs as content

There is no template, no publish, no cross-account copy, and the repository's entire
programming content is one hardcoded four-week block with a single training day. It is also
self-defeating: the headline feature is the substitute for buying a program.

### On the engine as a moat

It is not one. The encoded strength-training knowledge is a five-row RPE chart, a three-tier
warmup table, a 3% ascending step, a three-branch linear progression with a two-strike stall
rule, and a 10% deload. That is a weekend of reading for anyone who has been through
*Practical Programming* and Tuchscherer. The engineering around the domain content is better
than the domain content in it — which is a compliment to the engineering and a warning
against pricing the engine.

The wedge has to be the connector.

### The timing risk

The MCP layer was built between 2026-08-16 and 2026-08-22 — a seven-day burst, on a codebase
otherwise dormant since 2024-08 — and it is 2,651 lines of well-made glue over a Postgres
schema. A motivated incumbent with an existing REST API could ship an equivalent connector
in a sprint. The lead is months, not years, and that argues for moving now rather than
deepening the engine.

## What it costs to run

About **$14.50/month**, assuming a Render starter web service and a small Postgres. Two to
four subscribers at any plausible price covers it. Marginal cost per user is effectively
zero.

Infrastructure is not what stands between this app and revenue, and no time should be spent
there. Two caveats worth an afternoon each:

- `sets.workout_id`, `sets.exercise_id`, `workouts.account_id`, `exercises.account_id` and
  `programs.account_id` are unindexed, so the session view and volume queries sequential-scan
  the whole `sets` table. Invisible at today's row counts; the first thing to break as it
  grows. Note that `CREATE INDEX CONCURRENTLY` cannot run inside the transaction
  `Sequel::Migrator` wraps each file in — `migrate/003_workout_program_day.rb:14` already
  anticipates exactly this.
- Puma defaults to 5 threads and Sequel to a 4-connection pool, neither configured anywhere.
  The pool is the narrower resource under sustained concurrency.

The N+1 queries you would expect on the hot paths are not there — they were deliberately
avoided. Sessions are in signed cookies and the MCP transport is genuinely stateless, so
there is no single-process constraint blocking a second instance.

## The thing to do first

**Before writing any code: grep the production log stream for `mcp tool=`, and run the
duplicate-email query.**

Not the unique index, which is the obvious answer. Two reasons.

The first is that the usage question everyone assumes is unanswerable already has an answer.
`lib/tectonic/mcp/logging.rb:11` writes `mcp tool=X account=N status=S duration_ms=D` to
stdout at INFO in production, for **every** tool call — reads included, carrying the account
id. The `mcp_audit_log` table does not record reads, which is why this looks like a dead end
from the schema. It is not. Whether a single stranger has ever connected an assistant to
this is sitting in Render's log search, and finding out takes ten minutes.

The second is that the answer branches the next month into two disjoint plans. If strangers
are connecting: build billing, put a price on `views/authorize.erb` and `views/connections.erb`,
write the terms. If nobody is: none of that matters, and the month goes to the timezone bug,
a starter block picker, and finding a distribution channel — because a paywall on zero
traffic converts zero.

The duplicate-email query belongs in the same ten minutes because it is a prerequisite for
estimating the index migration honestly.

## The honest bottom line

**Able to take a payment: four to five weeks.** Email and reset (2–3 days, mostly DNS); the
unique index and any dedupe (1–2 days); terms, privacy, refund policy and Stripe activation
(1 day of writing, unknown waiting); a `plan` column, Checkout, and a webhook mounted in the
`config.ru` URLMap rather than inside Roda — Roda's `json_parser` consumes the body without
rewinding under Rack 3, so a webhook inside the Roda app receives an empty payload for
signature verification (~1 week); the timezone fix (2–3 days); export and `close_account`
(2 days); nightly `pg_dump` and a restore drill (1 day); the two missing indexes (half a
day).

**A first paying stranger: unknown, and not a code estimate.** There is no acquisition
channel here. The landing page names no price, the nav links no marketing page, `/robots.txt`
and `/sitemap.xml` both 404, and the only indexed page is the nine-line `/about` — which
competes in search against plate-tectonics software of the same name. `views/layout.erb:19,27`
still point the social preview image at the pre-domain `tectonic.onrender.com` hostname.

The realistic distribution bet is placement in Anthropic's or OpenAI's connector directory —
the one channel where the differentiator is the thing being browsed for. Terms and a privacy
policy are on the critical path for that listing, which is a reason to write them early
rather than late.

**Realistic ceiling — speculating, from the code's constraints rather than market data.**
Pounds only, everywhere, and not as a display-layer concern: increments, rounding and the
plate inventory are all lb-native (`lib/tectonic/rounding.rb:10`, `warmup.rb:9`,
`equipment.rb:20-26`). Barbell only, 54 library movements. One account per row throughout.
Solo maintainer, one starter instance, no support address. A good outcome for this shape of
thing is low hundreds of subscribers at $5–10/month — **$1–3k MRR**: an excellent side
income and a genuinely respectable piece of software, not a company. Directory placement is
the one thing that could exceed it. That is a lottery ticket, but a real one, and an
afternoon of legal boilerplate buys the ticket.

**The risk is not any of the above.** Every gap in this document is a build estimate. The
thing that is not a build estimate is that nothing in this repository establishes that a
single stranger has ever used it. That is knowable today, in ten minutes, and it should be
known before the next line of code is written.
