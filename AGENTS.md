# Tectonic — agent notes

## Fathom Analytics

The API token lives at `~/.config/fathom/token` (mode 600, outside every repo).
It is one **account-wide** token covering Tectonic, Launchpad and Yonderbook, so
it is deliberately not duplicated into any `.env` — one file, one rotation point,
and no chance of committing it. Note this repo already has both `.env` and
`.env.rb`; the token belongs in neither.

Read it as a bare value, stripping whitespace:

```bash
TOKEN=$(tr -d '[:space:]' < ~/.config/fathom/token)
curl -s -H "Authorization: Bearer $TOKEN" https://api.usefathom.com/v1/sites
```

**This project's site ID is `VXQDPBHH`.** Confirmed against the API on
2026-08-28. It has not been checked against whatever `data-site` attribute this
app actually renders — worth verifying, since a tracking snippet pointing at the
wrong site collects nothing and looks identical to one that works.

Aggregations, e.g. pageviews since a date:

```bash
curl -s -G https://api.usefathom.com/v1/aggregations \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "entity=pageview" \
  --data-urlencode "entity_id=VXQDPBHH" \
  --data-urlencode "aggregates=pageviews,visits,uniques" \
  --data-urlencode "date_from=2026-08-01"
```

Do not echo the token, paste it into a conversation, or write it into a file
inside this repo. It is account-wide: a leak exposes all three projects'
analytics and, depending on scope, site management.
