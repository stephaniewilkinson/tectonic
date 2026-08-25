# Tectonic

Tectonic is a barbell strength-training tracker. An account logs workouts; a workout
holds sets of an exercise at a weight and a rep count, in the order they are lifted. All
weights are integer pounds.

What makes it more than a list is that a session is written before it is lifted. A
program expands into ordinary set rows — warmup ramp included, every weight rounded to
something a bar can actually be loaded to — so lifting is tapping through a list that
already knows what comes next, and each row keeps the prescription beside what was
actually done. An MCP endpoint exposes the same data to an LLM as a connector, which is
the second half of this file.

The stack is Roda and Sequel on Postgres, with Rodauth for accounts and `rodauth-oauth`
for the OAuth 2.1 authorization server the MCP endpoint authenticates against. Views are
ERB with Tailwind from a CDN, and htmx for the parts of the session screen that have to
change without a page load. It deploys to Render.

## What it does

- **Session view** (`/workouts/:id/session`) — the gym-floor screen, as distinct from
  `/workouts/:id`, which is the record of one. A progress bar across the top, sets grouped
  by lift with warmups dimmed, the per-side plate breakdown under each weight ("per side
  1×25 1×10"), and a Done button per set that toggles, so a mis-tap is undone by tapping
  again. A set lifted differently is entered inline and the row turns amber rather than
  lime, because done-as-written and done-differently have to read differently. The whole
  session gets an RPE rating, with a bar-speed guide for choosing one.
- **Exercises** — 54 built-in barbell movements shared by every account, plus any you add
  yourself. A built-in exercise is visible to everyone but the sets shown under it are
  only ever your own.
- **Workouts** — list, record view, reschedule, delete.
- **Programs** — the engine below. Authored in Ruby and run from rake; there is no UI for
  editing one yet.
- **Accounts** — Rodauth login, account creation, logout, remember-me.
- **MCP** — audited, per-account tools over an OAuth 2.1-authenticated endpoint at `/mcp`.

## Getting started

You need Ruby at the version in `.ruby-version` (the `Gemfile` reads the same file, so the
two cannot drift), a local Postgres, and — only for the browser specs — Firefox with
geckodriver.

```
bundle install
```

### Environment

`dotenv` loads `.env` when the app is required, and `.env-example` is a file to copy:
`cp .env-example .env` gives a working development setup, pointed at the
`tectonic_development` database `rake db:create` makes below. The keys that are secrets in
a deployment are commented out there rather than left blank, each with the command that
generates it, because a blank is worse than an absence here — dotenv sets the name to the
empty string, every fallback in this project tests for nil, and an empty `DATABASE_URL`
reaches `Sequel.connect` and raises rather than falling back to a default.

| Variable | Required | Notes |
| --- | --- | --- |
| `DATABASE_URL` | yes | `app.rb` connects at require time, so nothing loads without it. `.env.rb`, which only the `Rakefile` reads, defaults it from `RACK_ENV` to `postgres:///tectonic_development` or `postgres:///tectonic_test`, but it defaults with `||=`, so a value in `.env` wins and that default never fires. A test run is the exception: `spec_helper` names its own database whatever the environment already held, so a `.env` cannot reach the suite. |
| `SESSION_SECRET` | yes | **At least 64 bytes.** Roda's sessions plugin refuses a shorter one, and `app.rb` builds the app at require time, so a short or missing secret raises before a single route is reached. `.env-example` carries one that is long enough and says in its own text that it is for development; generate a real one with `ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'` for anything deployed. |
| `RACK_ENV` | no | `development` unless set, and `development` is the only value that turns Sequel's query log on; `production` and `staging` initialise Sentry and require real OAuth keys. |
| `DB_LOG` | no | Attaches Sequel's query log to stdout whatever `RACK_ENV` says — set it to anything non-empty to trace queries against a deployment, and unset it again afterwards. Sequel logs statements with their bound values, so those lines carry email addresses and everybody's weights and reps, which is why nothing but development logs by default. |
| `SENTRY_DSN` | no | The Sentry project DSN, read only when `RACK_ENV` is `production` or `staging`. Without it — unset or empty — the app boots and serves with error reporting switched off and says so once on stderr: losing error reporting is not a reason to refuse to start, which is why this behaves unlike `OAUTH_JWT_PRIVATE_KEY`. |
| `RACK_TIMEOUT_SERVICE_TIMEOUT` | no | Seconds a request may hold a thread before `rack-timeout` raises inside it, `20` unless set, `0` to switch it off — which is what you want locally the moment you stop in a debugger. Read only by `config.ru`, so the suite never sees it. It covers both legs of the URLMap, MCP included; the MCP endpoint's long-lived `subscriptions/listen` streams are unaffected either way, because rack-timeout times `app.call` and a streaming body is written after that has returned. |

The MCP and OAuth variables are all optional in development and are documented in the
table further down.

### Database

```
bundle exec rake db:create          # createuser tectonic, then the development and test databases
bundle exec rake db:migrate         # applies migrate/001_schema.rb against DATABASE_URL
bundle exec rake library:exercises  # loads the 54 built-in movements, idempotent on name
```

`db:create` shells out to `createuser -U postgres` and `createdb -U postgres -O tectonic`,
so it assumes a superuser role named `postgres` and gives the databases to a `tectonic`
role. If your Postgres has neither, `createdb tectonic_development` by hand and go
straight to `db:migrate`, which only needs `DATABASE_URL` to point somewhere it can
connect.

The schema is one squashed baseline. `db:migrate` stamps a database that already carries
the tables rather than trying to rebuild or roll it back, so an existing database from
before the squash adopts the baseline instead of breaking on it.

### Running it

```
bundle exec rackup config.ru        # http://localhost:9292
```

`config.ru` mounts two apps side by side under `Rack::URLMap`: the MCP endpoint at `/mcp`,
which has its own bearer-token auth and never touches Roda's sessions or CSRF, and the
Roda app at everything else. `/` redirects to `/welcome` until you are logged in, so start
by signing up at `/create-account`.

## Running the tests

```
bundle exec rake test                            # the whole suite
bundle exec ruby -Ispec spec/set_scheme_spec.rb  # one file
```

Neither variable has to be passed in. `spec_helper` sets `RACK_ENV` and then names the
database itself — `TEST_DATABASE_URL` when a run wants one of its own, and
`postgres:///tectonic_test` otherwise — whatever the shell, a `.env` or the `Rakefile` had
already chosen. That matters more than it looks: `spec_helper` empties every table after
every test, so a suite pointed at your development database would not seed it, it would
clear it. The built-in exercise library is the one thing kept, because a deployed database
holds it before anybody signs up. `rake 'db:reset[name]'` still rebuilds a database whose
schema has gone wrong, but a run no longer leaves rows behind for it to clear away.

Two prerequisites, neither obvious from the failure you get without them:

- **Postgres, migrated.** `app.rb` connects at require time, so even the pure unit specs
  need a live database as soon as `spec_helper` loads the app.
- **A real Firefox.** `spec/exercises_spec.rb`, `route_ownership_spec.rb`,
  `session_spec.rb`, `system_spec.rb` and `workouts_spec.rb` drive a browser through
  Capybara and selenium, on a Puma server bound to port 9292. `MOZ_HEADLESS=1` keeps
  windows from opening; CI sets it for the same reason.

The linters, both of which CI runs:

```
bundle exec rubocop
bundle exec erblint views/*/* views/*
```

## The program engine

A program is a plan; workouts and sets are what it produces. Four tables hold the plan —
`programs`, `program_weeks`, `program_days`, `program_lifts` — and generating a week turns
them into ordinary `workouts` and `sets` rows with `is_completed` false. A planned session is not a
separate kind of record: lifting a set as written only flips `is_completed`, while lifting
it differently changes `weight` or `reps` and leaves `planned_weight` and `planned_reps`
behind as the record of what was asked for.

- **`programs`** — the block: a name, a `start_date`, and two preferences the maths below
  reads: `preferred_reps` (the rep count main work should be expressed at) and
  `is_ascending` (whether working sets climb to the top weight or sit flat).
- **`program_weeks`** — a numbered week of the block, and `is_deload`. Dates are derived
  rather than stored: a week opens seven days after the one before it, counted from the
  block's start.
- **`program_days`** — a weekday, in Ruby's numbering where 1 is Monday, and a focus such
  as "Squat". A day is a weekday rather than a date, so the week it belongs to decides
  when it actually falls.
- **`program_lifts`** — an exercise at a position within the day, with `sets`, `reps`,
  `is_barbell` (whether it warms up off a bar and shows plate maths), `is_main` (whether
  the rep-count preference applies to it) and a `progression` rule with the load it reads:
  `top_weight` for `fixed` and `linear`, `percent_of_max` for `percent`. Position is the
  order it was written, which is the order it is generated and the order it appears in the
  session.

`Tectonic::ProgramSeed` (`lib/tectonic/program_seed.rb`) is a program written as a frozen
Ruby hash, until there is a UI for editing one. It creates the program, its weeks, days
and lifts, reusing any movement the account can already see — its own or a library one —
and creating only a name nothing answers to. It is idempotent on account, name and block,
so reseeding returns the existing program untouched.

`Tectonic::ProgramGenerator` (`lib/tectonic/program_generator.rb`) expands one week of a
program into workouts. It is idempotent on account, program day and date, so regenerating
a week never duplicates sets and never overwrites what was actually lifted.

The maths it generates through is the interesting part of the app, and each piece is
specced on its own:

- **`SetScheme`** (`set_scheme.rb`) — how many working sets, at what load, for how many
  reps. It converts the prescription to the program's preferred rep count through the
  RPE-8 percentage chart, so 4×5 at 155 becomes 4×3 at 165: fewer reps is more weight for
  the same effort. Conversion only ever goes down, only between rep counts the chart
  covers, and only for a lift marked `is_main`, so an accessory prescribed at 8 keeps its
  8. Earlier sets then sit 3% below the top per step when the program ascends.
- **`Warmup`** (`warmup.rb`) — the ramp from the empty 45 lb bar to just under the working
  weight, in tiers, because a lighter lift needs less of a ramp to get there and reps
  descend as the weight climbs. Barbell work only: bodyweight, banded and machine lifts
  ramp differently, if at all. Where rounding would put two ramp steps on the same weight,
  the repeat is dropped — lifting the same bar twice is not a ramp.
- **`Plates`** (`plates.rb`) — the per-side breakdown for a loaded bar, searched depth
  first with the heaviest plate first, so the first exact match is also the one using the
  fewest plates. It backtracks rather than giving up, so an awkward rack still loads
  weights a purely greedy walk would call impossible, and returns nil for a weight the
  rack genuinely cannot make, which the session view renders as nothing at all.
- **`Progression`** (`progression.rb`) — what the next prescription of a lift should be,
  read off the last one and what was actually done against it. A `linear` lift that was
  lifted as written gains five pounds; one whose working sets went uncompleted, or came in
  under the prescription, loses ten; one nobody trained at all repeats. The step down is
  twice the step up because adding is a guess that costs a session when it is wrong, while
  subtracting is a response to evidence, and coming back at the weight that just failed
  wastes the week. A session nobody trained moves nothing in either direction: a missed
  week is an absence of evidence, and treating it as failure would compound a fortnight
  away into a load far under what the lifter can do. A `is_deload` week takes a tenth off
  whatever the rule arrived at, and is not itself progressed from, so a block resumes its
  climb rather than ratcheting down each time it recovers.
- **`Rounding`** (`rounding.rb`) — every calculated weight lands on a multiple of 5 before
  it is written, because 2.5s on each side is the smallest change you can actually load.

Today the engine is reachable only from two rake tasks:

```
bundle exec rake program:seed                     # ACCOUNT_ID=1, or the only account
bundle exec rake 'program:generate[1]' PROGRAM_ID=1   # week 1; the current week by default
```

Which, from the seeded block 0, writes a Monday whose first lift reads: 45×5, 95×5, 115×3
and 135×2 as the warmup ramp, then 150, 155, 160 and 165 for 3 — the 4×5 at 155 the
program asked for, converted and ascended.

Block 0 is four weeks, the last of them a deload, and only week one is written at a load.
Lift week one as prescribed and week two generates at 170 for 3, week three at 175; fall
short in week three and the deload comes out at 150 rather than 160. Generate each week
when you reach it: the load is computed when the week is written and then left alone, so
regenerating never rewrites a session you have already trained.

## Deployment

`render.yaml` is the checked-in Render blueprint: `bundle install` to build, `bundle exec
rake db:migrate && bundle exec rake library:exercises` as the pre-deploy command, and
`bundle exec rackup config.ru -p $PORT` to start. Secrets are marked `sync: false` so the
values already set in the dashboard are left alone — regenerating `SESSION_SECRET` would
log everyone out, and regenerating `OAUTH_JWT_PRIVATE_KEY` would stop every issued access
token from verifying.

# MCP server

Tectonic exposes a [Model Context Protocol](https://modelcontextprotocol.io) endpoint
so an LLM client can act on an account's data through audited, per-account tools. The
framework around them — transport, auth, scoping, auditing, guardrails — makes adding a
tool cheap; see "Adding a tool".

| What it is for | Tools |
| --- | --- |
| Logging training | `create_exercise`, `create_workout`, `create_set`, `complete_set`, `update_set`, `delete_set`, `rate_workout` |
| Reading it back | `list_exercises`, `list_workouts`, `get_workout`, `exercise_history` |
| Writing a plan | `list_programs`, `get_program`, `create_program`, `add_program_week`, `add_program_day`, `update_program_day`, `add_program_lift`, `update_program_lift`, `delete_program_lift`, `generate_program_week` |
| The connector contract | `search`, `fetch` (handles are `exercise:`, `workout:`, `program:`) |
| Who am I | `whoami` |

The program tools are the ones that make "plan my training" possible rather than "log
what I did". `create_program` writes a whole block — weeks, days, lifts — in one call,
because a block composed one lift at a time is dozens of round trips that can fail
half-written. Everything after that is per-object, because revising a plan is: change
this lift, move that day, add a week like the last one. `generate_program_week` turns a
written week into real sessions with their warmup ramps, and is idempotent on the
program day, so running it twice changes nothing.

The endpoint is a plain Rack app mounted at `/mcp` in `config.ru`, entirely outside
Roda's sessions, CSRF, and assets. It uses the `mcp` gem (pinned to `1.2.0`) and is
constructed **stateless** (`stateless: true`): each POST is self-contained, no session
or SSE state is held in memory, so there is **no single-process constraint** — it scales
horizontally like any other request.

## Authentication (OAuth 2.1)

Access is by OAuth 2.1, served by Rodauth (`rodauth-oauth`) in the same app. An LLM
client (Claude, ChatGPT, …) connects to the MCP URL, registers itself via Dynamic
Client Registration, and the user authorizes it on the consent page. Access tokens are
short-lived **RS256 JWTs** the MCP endpoint verifies locally — signature, expiry, and
audience (RFC 8707) — with no database lookup. There is nothing to mint or paste.

Discovery lives at the root, per the MCP authorization spec:

- `/.well-known/oauth-protected-resource` — RFC 9728; names this resource and its
  authorization server.
- `/.well-known/oauth-authorization-server` — RFC 8414; the authorize/token/register
  endpoints, scopes, and S256 PKCE.

For a **headless** caller (a script or CLI), register a confidential client and use the
client-credentials grant:

```
# registers a client bound to an account; prints client_id + client_secret once
bundle exec rake 'oauth:client:register[My Script]' ACCOUNT_ID=1
# then exchange them at POST /token (grant_type=client_credentials) for a JWT
```

## The endpoint

- URL: `https://<host>/mcp` (locally `http://localhost:9292/mcp`).
- Every request needs `Authorization: Bearer <jwt>`. Missing, malformed, expired,
  wrong-audience, or badly signed tokens are rejected with `401` — carrying a
  `WWW-Authenticate` challenge that points at the protected-resource metadata — before
  the request reaches the transport.
- DNS-rebinding protection is on. Loopback hosts are always allowed; a deployed host
  must be listed in `MCP_ALLOWED_HOSTS` (and browser origins in `MCP_ALLOWED_ORIGINS`).

Configuration (all read from the environment):

| Variable | Default | Meaning |
| --- | --- | --- |
| `MCP_ENDPOINT_PATH` | `/mcp` | Mount path. |
| `MCP_WRITES_ENABLED` | on | Global kill switch; a falsey value makes every write tool refuse while reads keep working. |
| `MCP_ALLOWED_HOSTS` | — | Extra Host values (comma/space separated) beyond loopback. |
| `MCP_ALLOWED_ORIGINS` | — | Extra browser Origin values. |
| `MCP_AUDIT_READS` | off | Also audit read tools (writes are always audited). |
| `MCP_SCOPES` | `read write` | Scopes the server recognizes. |
| `MCP_PUBLIC_BASE_URL` | — | Public https origin, for the token audience and discovery URLs. Required in production. |
| `OAUTH_JWT_PRIVATE_KEY` | — | RSA private key (PEM) signing access tokens; the public half is derived. Required in production; an ephemeral pair is generated otherwise. |
| `OAUTH_REDIRECT_URI_ALLOWLIST` | Claude, ChatGPT, loopback | The callbacks a client may register (comma/space separated), replacing the defaults rather than adding to them. An entry ending in `/` matches any path under it; a loopback entry matches any port. |

## Connecting it as a custom connector

In a client that supports remote MCP servers (Claude, ChatGPT), add a custom connector:

- Type: HTTP / "Streamable HTTP" MCP server.
- URL: `https://<host>/mcp`.
- Authentication: **OAuth** — the client discovers the authorization server from the
  URL and walks you through the consent page; there is no token to paste. ChatGPT's
  standard connector additionally requires `search`/`fetch` tools, which the server
  exposes.

Or point any MCP-capable client at the URL. A quick check with curl, using a JWT
obtained from the OAuth flow (or the client-credentials grant above):

```
curl -sX POST https://<host>/mcp \
  -H 'authorization: Bearer <jwt>' \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whoami","arguments":{}}}'
```

## Adding a tool

This is the point of the whole setup. Auth, per-account scoping, argument validation,
the write kill switch, refuse-and-explain errors, and audit logging all live in the base
class, so a new tool is: **subclass, name it, declare a schema, declare a scope, write
`perform`, register it.** `whoami` is the worked example
(`lib/tectonic/mcp/tools/whoami.rb`):

```ruby
class Tectonic < Roda
  module MCP
    module Tools
      class Whoami < Tool
        tool_name 'whoami'
        description 'Report the authenticated account id, email, and granted scopes.'
        scope :read                                  # :read or :write, enforced before perform
        input_schema(type: 'object', properties: {}, additionalProperties: false)

        def self.perform(context:, **)               # context is the resolved account
          ok(
            "You are account #{context.account_id} (#{context.email}). " \
            "Granted scopes: #{context.scopes.join(', ')}.",
            structured: { account_id: context.account_id, email: context.email, scopes: context.scopes }
          )
        end
      end
    end
  end
end
```

Then register it in `lib/tectonic/mcp/server.rb`:

```ruby
TOOLS = [Tools::Whoami, Tools::YourNewTool].freeze
```

What you get for free:

- **`context` is account-scoped.** It exposes only that account's datasets —
  `context.workouts`, `context.exercises`, `context.sets` — each already filtered to the
  authenticated account. There is no `account_id` setter and no accessor that returns an
  unscoped model, so a cross-account query is *unexpressible* through the context. A tool
  must never accept an `account_id` argument or reach for a global model constant.
- **Scope enforcement.** A token lacking the tool's declared scope is refused before
  `perform` runs.
- **Argument validation.** The gem validates the incoming arguments against your
  `input_schema` and returns a readable error the model can correct from.
- **Refuse and explain.** Return `refuse('...')` (or raise `Tool::Refusal`) with a
  message written for a model to read and act on — never a stack trace. Domain rules
  (weight sanity bounds, refusing to touch completed work, date idempotency) belong in
  the tool body via this path.
- **Auditing.** Every write lands an `mcp_audit_log` row on success *and* failure. Reads
  are audited only if the tool declares `audit_reads`.
- **The kill switch.** A write tool automatically refuses when `MCP_WRITES_ENABLED` is
  off.

Return results with `ok(text, structured: {...})` for success or `refuse(message)` for a
handled failure. A write tool declares `scope :write`; reads declare `scope :read`.

