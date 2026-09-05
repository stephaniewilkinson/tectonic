# Privacy Policy — DRAFT, NOT PUBLISHED

> Placeholders in `[BRACKETS]` are decisions. Unlike `terms.md`, most of this is a factual
> description of what the app does, and every fact below was checked against the code rather
> than taken from a template — see `legal/README.md` for where each was verified. That also
> means it goes stale the moment the behaviour changes.

**Last updated: [DATE]**

## Who we are

tectonic plates is operated by **[LEGAL ENTITY]**, of **[ADDRESS]**. For anything in this
policy, including a request to see or delete your data, write to **[SUPPORT EMAIL]**.

## What we store

**Your account.** An email address and a bcrypt hash of your password. We never store the
password itself and cannot recover it — only reset it.

**Your training.** Sessions, sets, exercises, loads, rep counts, RPE ratings, training maxes,
goals, your plate inventory and bar weight, and any free-text notes you write on a session or
a movement. This is the substance of the service and it is the reason to have an account.

**Assistant activity.** If you connect an AI assistant, we record each tool call it makes on
your behalf — which tool, when, whether it succeeded, **and the arguments it was given**.
That last part means the contents of a write (a weight, a rep count, a note) appear in that
log. It exists so that a change you did not expect can be traced to the call that made it.

**Nothing else.** We do not ask for your name, your date of birth, your bodyweight, your
location or your payment details, and we have no field to put them in.

## What we do not do

- We do not sell your data.
- We do not use your training data to train machine-learning models.
- We do not share it with advertisers, and there is no advertising on the service.

## Cookies

One session cookie, so that being logged in survives loading the next page, and an optional
"remember me" token if you ask to stay signed in. That is all.

**There is no consent banner because there is nothing to consent to** — see analytics below.

## Third parties

| Who | What they get | Why |
| --- | --- | --- |
| **Render** (United States, Oregon) | Everything above — they host the app and the database | Hosting |
| **Fathom Analytics** | Page views and referrers, aggregated | Knowing which pages are used |
| **Sentry** | Error reports: the exception, and where in the code it happened | Finding crashes |
| **[EMAIL PROVIDER]** | Your email address, when we send you a password reset | Sending that email |
| **Your AI assistant's operator** | Whatever you say to it, and whatever it reads from your account | Only if you connect one |

Two of those are worth stating precisely, because the usual version of this sentence is
vague and ours does not have to be:

**Fathom** is cookieless and builds no cross-site profile of you. It was chosen for that
reason, and it is why this app has no consent banner and no tracking pixel.

**Sentry** is configured with `send_default_pii` off, which is its default and which we have
deliberately not changed. That means error reports do **not** carry request headers or IP
addresses. An exception message could in principle contain a value you entered; we do not
send them on purpose and we do not look for them.

**Your AI assistant is not us.** If you connect one, your conversation with it is governed by
whoever operates it, under their privacy policy. We see the tool calls it makes, not what you
said to it.

## How long we keep it

For as long as you have an account. Delete your account and your training data goes with it.

Assistant activity logs are kept **[RETENTION PERIOD — decide; 90 days is a reasonable
default for an audit log of this kind]**.

## Your rights

Whatever your jurisdiction gives you, and at minimum: you can ask for a copy of everything we
hold about you, ask for it to be corrected, or ask for it to be deleted. Write to
**[SUPPORT EMAIL]**. We will respond within **[30 days]**.

If you are in the UK or EU, the lawful basis for storing your training data is performance of
the contract between us — the service does not work without it — and for analytics and error
reporting, our legitimate interest in the service functioning and being improved.

## Where your data lives

On servers in the **United States** (Oregon). If you are outside the US, using the service
means your data is transferred there.

## Security

Passwords are hashed with bcrypt. Traffic is served over HTTPS. Access to your account is
either your password or a token you granted to an assistant, and you can revoke any of those
at any time from your connections page.

We are a small operation and cannot promise a breach will never happen. If one does, we will
tell affected people by email.

## Changes

If this policy changes materially, we will email the address on your account before the
change takes effect.
