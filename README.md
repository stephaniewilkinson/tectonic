# Linting
```
erblint views/*/*
erblint views/*

# Resources
example uploader to s3 https://pastebin.com/DtPJnbn3

downloading chartsjs as image https://stackoverflow.com/questions/20206038/converting-chart-js-canvas-chart-to-image-using-todataurl-results-in-blank-im


Resource for downloading charts as gifs: https://wpdatatables.com/animated-charts/

resource for tableau charts as gifs https://towardsdatascience.com/how-to-render-your-tableau-viz-as-a-gif-file-b0a11ed6acf9

Rodauth methods: https://rodauth.jeremyevans.net/rdoc/files/README_rdoc.html#label-rodauth+Methods

rodauth login view: rodauth.login_view

how to replace tailwind patterns: https://lorisleiva.com/replacing-tailwind-ui-hero-patterns

# Rodauth
```
rodauth.login_view

```

Here's how to pull HTML from erb templates:
```
ERB.new(File.read 'views/rodauth/login.erb').result

```

# Rodauth migrations
https://github.com/jeremyevans/rodauth#label-Creating+tables


## Rodauth templates
app/views/rodauth/_login_form.html.erb
app/views/rodauth/_login_form_footer.html.erb
app/views/rodauth/_login_form_header.html.erb
app/views/rodauth/login.html.erb
app/views/rodauth/multi_phase_login.html.erb
app/views/rodauth/create_account.html.erb
app/views/rodauth/verify_account_resend.html.erb
app/views/rodauth/verify_account.html.erb
app/views/rodauth/logout.html.erb
app/views/rodauth/remember.html.erb
app/views/rodauth/reset_password_request.html.erb
app/views/rodauth/reset_password.html.erb
app/views/rodauth/change_password.html.erb
app/views/rodauth/change_login.html.erb
app/views/rodauth/verify_login_change.html.erb
app/views/rodauth/close_account.html.erb

# Logo options
https://thenounproject.com/icon/earth-4510372/

https://thenounproject.com/icon/earth-4511315/

https://thenounproject.com/icon/barbell-plate-4397088/

https://thenounproject.com/icon/barbell-plate-490489/

https://thenounproject.com/icon/barbell-plates-1174446/

https://thenounproject.com/icon/barbell-plate-4802392/

 # Start command
 bundle exec rackup config.ru -p $PORT

# MCP server

Tectonic exposes a [Model Context Protocol](https://modelcontextprotocol.io) endpoint
so an LLM client can act on an account's data through audited, per-account tools. This
is the *infrastructure* — transport, auth, scoping, auditing, guardrails — plus one
proof tool, `whoami`. Adding real tools later is meant to be cheap; see "Adding a tool".

The endpoint is a plain Rack app mounted at `/mcp` in `config.ru`, entirely outside
Roda's sessions, CSRF, and assets. It uses the `mcp` gem (pinned to `1.2.0`) and is
constructed **stateless** (`stateless: true`): each POST is self-contained, no session
or SSE state is held in memory, so there is **no single-process constraint** — it scales
horizontally like any other request.

## Minting a token

Access is by bearer token. Only the SHA-256 digest is stored; the raw value is printed
once at creation and is unrecoverable afterward.

```
# read-only token for the only account (or pass ACCOUNT_ID when several exist)
bundle exec rake 'mcp:token:mint[read]' ACCOUNT_ID=1 NAME=laptop

# read + write, expiring in 30 days
bundle exec rake 'mcp:token:mint[read,write]' ACCOUNT_ID=1 NAME=laptop EXPIRES_IN_DAYS=30

bundle exec rake mcp:token:list          # digest only, never the raw value
bundle exec rake 'mcp:token:revoke[3]'   # soft-revoke by id
```

## The endpoint

- URL: `https://<host>/mcp` (locally `http://localhost:9292/mcp`).
- Every request needs `Authorization: Bearer <token>`. Missing, malformed, unknown,
  expired, or revoked tokens are rejected with `401` before the request reaches the
  transport.
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

## Connecting it as a custom connector

In a client that supports remote MCP servers (e.g. Claude), add a custom connector:

- Type: HTTP / "Streamable HTTP" MCP server.
- URL: `https://<host>/mcp`.
- Authentication: Bearer token — paste the raw value from `mcp:token:mint`.

Or point any MCP-capable client at the URL with that `Authorization` header. A quick
check with curl:

```
curl -sX POST https://<host>/mcp \
  -H 'authorization: Bearer <token>' \
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

