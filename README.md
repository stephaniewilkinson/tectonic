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
so an LLM client can act on an account's data through audited, per-account tools:
`create_exercise`/`create_workout`/`create_set`, `list_exercises`/`list_workouts`,
`search`/`fetch` (the ChatGPT connector contract), and `whoami`. The framework around
them — transport, auth, scoping, auditing, guardrails — makes adding a tool cheap; see
"Adding a tool".

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

