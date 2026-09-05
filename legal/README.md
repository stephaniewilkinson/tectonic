# Draft legal text — not published, not reviewed

These are drafts for #346. **Nothing here is live**, and nothing here is wired into the app:
there is no route serving them and no link to them. Publishing is a separate, deliberate act
and it is Steph's, not a side effect of the text existing.

## Why they are drafts and not pages

#346 says it itself:

> Effort: an afternoon of writing from templates, plus a lawyer's read of the injury clause
> specifically — that one clause is the part a template can't safely generate.

The afternoon of writing is done and is in this directory. The lawyer's read is not, and the
clause in question is the one that decides whether this app has any exposure when somebody
gets hurt doing a lift it prescribed. Publishing an unreviewed assumption-of-risk clause is
worse than publishing none, because a clause that does not hold is still a representation you
made.

The rest — the privacy policy in particular — is much closer to ready, because most of it is
a factual description of what this app actually does, and those facts were checked against
the code rather than taken from a template. See the notes in each file.

## What needs a decision before any of it ships

1. **A lawyer on `terms.md`, section 6 (assumption of risk).** The one thing a template
   cannot safely generate. Everything else in that file is ordinary.
2. **A business name and address.** Every file has `[LEGAL ENTITY]` and `[ADDRESS]` in it.
   Stripe will not activate live payments without real business contact details, and a
   consumer-facing terms page normally has to say who is on the other side of the contract.
   This is not a thing to invent.
3. **A governing-law jurisdiction.** `[JURISDICTION]` throughout. Depends on where the entity
   in (2) is.
4. **Whether there is anything to refund.** `refunds.md` is written for a paid subscription
   that does not exist yet — pricing was closed for now in #355. It is here because Stripe
   requires a published refund policy before it activates live payments, so it will be needed
   the moment that changes, and writing it now costs nothing.
5. **A licence for the repository.** #346 notes there is no `LICENSE` file carrying an "AS IS"
   disclaimer. Deliberately not added here: this repository is public and the app is intended
   to be sold, so choosing MIT would let anyone run a copy of the product. That is a business
   decision rather than a liability checkbox, and the AS IS protection it was wanted for is
   better placed in `terms.md` where it applies to the *service*, which is what people
   actually use.

## What was checked rather than assumed

The privacy policy describes real behaviour, verified in the code:

- **Fathom Analytics** (`views/layout.erb`) — cookieless, no cross-site profile, which is why
  the app has no consent banner. That was #185's decision and the policy now says so out loud.
- **Sentry** (`config.ru`) — `send_default_pii` is left at its default of off, so request
  headers and IP addresses are not sent. The policy says this because it is a meaningful
  promise and it is one the code currently keeps.
- **What is stored** — `accounts` holds an email and a bcrypt hash and nothing else
  identifying; the training data is workouts, sets, loads, reps, RPE and free-text notes;
  `mcp_audit_log` records assistant tool calls **including their arguments**, which is the
  one storage fact most likely to surprise somebody and so is named explicitly.
- **Where it lives** — Render, Oregon, United States.

If any of those change, the policy is wrong, which is the usual way privacy policies become
false. `analytics_spec.rb` already pins the Fathom half.
