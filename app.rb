# frozen_string_literal: true

require 'dotenv/load'
require 'http'
require 'rack'
require 'roda'
require 'tilt'
require 'chartkick'
require_relative 'lib/tectonic/db'
require_relative 'lib/tectonic/exercises'
# Not just the rake loader's list: it is also what tells a set whether it is loaded
# on a bar, so the web process needs it too.
require_relative 'lib/tectonic/exercise_library'
require_relative 'lib/tectonic/plates'
require_relative 'lib/tectonic/sets'
require_relative 'lib/tectonic/workouts'
require_relative 'lib/tectonic/connection'
require_relative 'lib/tectonic/equipment'
require_relative 'lib/tectonic/volume'
require_relative 'lib/tectonic/timing'
require_relative 'lib/tectonic/session_length'
require_relative 'lib/tectonic/session_diagnosis'
require_relative 'lib/tectonic/session_close'
require_relative 'lib/tectonic/session_summary'
require_relative 'lib/tectonic/turnarounds'
require_relative 'lib/tectonic/calendar'
require_relative 'lib/tectonic/clock'
require_relative 'lib/tectonic/program_schedule'
require_relative 'lib/tectonic/program_generator'
require_relative 'lib/tectonic/rack_change'
require_relative 'lib/tectonic/training_max'
require_relative 'lib/tectonic/goal'
require_relative 'lib/tectonic/rests'
require_relative 'lib/tectonic/withings'
require_relative 'lib/tectonic/withings_connection'
require_relative 'lib/tectonic/withings_measures'
require_relative 'lib/tectonic/withings_workouts'
require_relative 'lib/tectonic/withings_answers'
require_relative 'lib/tectonic/session_stream'
require_relative 'lib/tectonic/heart_rates'
# The proposals a backfill left, which this app reads. #534.
require_relative 'lib/tectonic/withings_proposals'
# And the walk that makes them, which this app now reaches in one place and one shape only:
# `WithingsBackfill.slice`, one year per press, from the settings page. #558.
#
# The old note here said nothing in the app required this module, and the reason it gave
# still holds for everything but the slice: walking years of history at ten seconds a call
# is not something to do inside a Puma thread, so `run` -- the whole-history walk the rake
# task drives -- is still unreachable from a request and must stay that way. What changed is
# that "a decade in one request" and "one year in one request" were being treated as the
# same objection, and only the first of them is true. See the module's own notes.
require_relative 'lib/tectonic/withings_backfill'
require_relative 'lib/tectonic/progress_chart'
require_relative 'lib/tectonic/mailer'
require_relative 'lib/tectonic/oauth_keys'
require_relative 'lib/tectonic/oauth/redirect_uri'
require_relative 'lib/tectonic/oauth/grant_bound_tokens'
require_relative 'lib/tectonic/oauth/refresh_token_reuse'
require_relative 'lib/tectonic/mcp/config'

class Tectonic < Roda
  SESSION_SECRET = ENV.fetch 'SESSION_SECRET'
  # The most a client registration may weigh. Registration metadata is a few hundred
  # bytes; this leaves room for a long client name and a jwks document and nothing more.
  REGISTRATION_BODY_LIMIT = 16 * 1024
  # The consent screen's own policy. It is the one page where a single click hands an
  # API client the account, so everything is denied outright rather than left open the way
  # the site-wide policy has to leave it.
  #
  # It ran one script until #142: the stylesheet was https://cdn.tailwindcss.com, a
  # compiler shipped to the browser, and it had to be named here for the page to have any
  # layout at all. The stylesheet is a stylesheet now, so this page runs no script from
  # anywhere -- script-src is gone and default-src 'none' covers it, which is the strictest
  # this can be said. That is the whole of what #142 unblocks on this page; the rest of the
  # site still renders inline chart scripts and cannot say the same yet.
  #
  # form-action is deliberately absent: the consent POST is answered with a 302 to the
  # client's callback, and browsers disagree about whether form-action applies across a
  # redirect, so naming it would risk breaking the exchange it is supposed to protect.
  CONSENT_SECURITY_POLICY = "default-src 'none'; " \
                            "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; " \
                            "frame-ancestors 'none'; base-uri 'self'; object-src 'none'"
  # The one origin this app calls itself by, and the fix for two places disagreeing about
  # it. Every share card told the platform to fetch its image from tectonic.onrender.com,
  # the Render subdomain the app lived at before tectonicplates.app, while the canonical
  # URL beside it named the new domain. A card is fetched once and cached for a long time,
  # so that broke in the way that is hardest to notice: the person sharing sees the card
  # the platform cached months ago and the recipient sees a blank one, and nobody ever
  # sees both halves.
  #
  # render.yaml still allows the old host, so every page really is reachable at two
  # domains. That is the duplicate-content split rel=canonical is for, and this is the
  # value it names. Read from the environment so a preview deploy can say what it is,
  # defaulted so a checkout and the suite have an answer without configuring anything.
  CANONICAL_ORIGIN = ENV.fetch('CANONICAL_ORIGIN', 'https://tectonicplates.app')

  include Chartkick::Helper

  # Every chart on the site is styled here rather than at each call site: lime because
  # that is the app's colour everywhere else, and whole numbers on the count axis
  # because Chart.js otherwise labels the gridlines in halves, and half a set is not a
  # thing anyone lifted.
  #
  # The palette is for charts that draw more than one series, and is asked for by those
  # charts rather than set here. Chart.js gives every series past the end of the colour
  # list its own grey, so a lone lime drew two lifts the same shade and the legend
  # stopped telling them apart -- but a list of colours applied globally is worse: it
  # colours each bar of a single-series chart differently, which reads as though the
  # colours mean something. One colour is the right default; a chart comparing lifts
  # passes this instead.
  CHART_COLORS = ['#84cc16', '#0369a1', '#f59e0b', '#8b5cf6', '#e11d48'].freeze
  Chartkick.options = { colors: [CHART_COLORS.first], height: '260px',
                        library: { scales: { y: { ticks: { precision: 0 } } } } }

  # Only the app's own styles. A full, unpurged Tailwind v2 build used to sit beside them
  # -- 3.82 MB, uncompressed, on every page load -- while the v3 CDN below did the actual
  # layout. It was not even a fallback: utilities the views rely on, min-h-20 among them,
  # do not exist in v2, so the page was already depending on the CDN. Two major versions
  # of the same framework, and the larger one styling nothing.
  plugin :assets, css: ['styles.css']
  # frame-ancestors keeps every page out of a third party's iframe, the OAuth consent
  # screen most of all: it is the one page where a click grants an API client access to
  # the account, so it is the one worth framing over a decoy. base-uri and object-src
  # close the two injection sinks that cost nothing to shut. Script and style sources are
  # deliberately left open because the site renders chart scripts inline, so naming them
  # would be a policy this app does not yet satisfy.
  #
  # This said "loads a JIT stylesheet CDN" until #252, which was two versions stale --
  # #142 compiled the stylesheet and served it from this origin. Worth correcting rather
  # than leaving, because a comment about the CSP is exactly what somebody reads when
  # working out whether the CSP can be tightened, and this one named a reason that had
  # stopped being true. The remaining one is real: inline scripts need 'unsafe-inline'
  # or a nonce, and the third-party origin list is now one entry long (Fathom).
  plugin :default_headers,
         'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains',
         'X-Content-Type-Options' => 'nosniff',
         'Referrer-Policy' => 'strict-origin-when-cross-origin',
         'Content-Security-Policy' => "frame-ancestors 'none'; base-uri 'self'; object-src 'none'"
  plugin :h
  plugin :head
  # Rodauth's json feature (OAuth token/registration endpoints speak JSON) calls back
  # into Roda's json plugin to serialize responses; json_parser merges a JSON request
  # body into request.params so dynamic client registration can read it.
  plugin :json
  plugin :json_parser
  plugin :public, root: 'assets'
  # Escaping is the default and markup is the exception that has to say so. Roda's render
  # plugin leaves `<%= %>` raw unless told otherwise, which made every safe view look
  # exactly like an unsafe one and rested the whole of this app's HTML safety on somebody
  # remembering `h()` at each of a hundred-odd sites. Seventeen of them had not, two inside
  # a `value="..."`, where a name holding a double quote leaves the attribute, and five
  # behind a helper that reads as text at its call sites but interpolates a client-supplied
  # name. That last one is the argument for the default rather than for seventeen fixes: a
  # site can be safe on the day it is written and stop being safe when a helper changes
  # under it, and nothing about the call site would show it.
  # Inverted, a forgotten call is no longer a hole, and the places that genuinely emit
  # markup -- the layout's asset tags, every partial and `yield`, the CSRF tags, the chart
  # helpers, `ticked` -- are written `<%==`, which can be grepped for in a way that the
  # absence of a call never could.
  plugin :render, escape: true
  # A failed CSRF check is a refusal, not a crash: Roda's default raises, which reaches
  # the client as a 500 and reads like a server fault rather than the rejection it is.
  # This matters most on the OAuth authorize POST, the one form here whose forgery is
  # worth attempting -- submitting it grants a client access to the account.
  plugin :route_csrf do |_r|
    response.status = 403
    'That request could not be verified. Reload the page and try again.'
  end
  plugin :sessions, secret: SESSION_SECRET
  plugin :slash_path_empty
  plugin :rodauth do
    account_password_hash_column :password_hash
    # User login plus the OAuth 2.1 authorization server that issues the tokens every
    # MCP client authenticates with. All auth -- web sessions and machine access --
    # runs through this one Rodauth config rather than any hand-rolled path.
    enable :login, :logout, :create_account, :remember, :json, :reset_password,
           :verify_account,
           :oauth_authorization_code_grant, :oauth_pkce,
           :oauth_client_credentials_grant, :oauth_jwt,
           :oauth_resource_indicators, :oauth_dynamic_client_registration,
           :oauth_token_introspection, :oauth_token_revocation
    # Each of the two things a person types is typed once. Rodauth defaults both of these to
    # true and enforces them on the post rather than in the template, so deleting the
    # confirmation boxes from a form without turning these off leaves every submission
    # rejected for disagreeing with a parameter the form no longer sends -- and the message
    # names a field that is not on the page.
    #
    # Since #575 they govern two different pages. The address is typed on
    # views/create-account.erb and the password on views/verify-account.erb, so
    # require_login_confirmation? is about the first and require_password_confirmation? about
    # the second -- and about views/reset-password.erb, which has been a single box since #344
    # for the same reason. `verify_account` happens to force the first of them false itself
    # (`verify_account.rb:161-163`); it is still written out, because a line that is load-
    # bearing for the reset and sign-up forms should not silently depend on a feature that
    # has nothing to do with either.
    #
    # What the password confirmation was buying is a typo nobody can see. That used to be
    # unrecoverable -- reset_password was not enabled and there was no mailer, so an account
    # created under a mistyped password was gone. #344 changed that: a typo now costs a reset
    # email rather than the account, which is what made leaving these off defensible rather
    # than merely convenient.
    #
    # The remaining password box still says autocomplete="new-password", asking a manager to
    # generate and keep the credential instead of leaving a human to type it twice. That
    # matters more than it did and lands less often than it did, both because of where the box
    # now is; the #575 note further down has that argument.
    require_login_confirmation? false
    require_password_confirmation? false
    # Losing a password no longer loses the account. #344.
    #
    # This app had no reset flow at all, and said so in two places -- views/create-account.erb
    # warns that "an account created under a mistyped password is gone", and the note below on
    # require_password_confirmation? gives that as the reason the second password box was
    # worth arguing about. Both described a hole rather than a decision.
    #
    # #345 made it worse before this made it better: one email is now one account, so somebody
    # who has lost their password can no longer sign up again with the same address and start
    # over. The two are only both right together.
    #
    # **The same page is shown whether or not the address has an account**, which is Rodauth's
    # default and is kept deliberately. A form that says "no such account" is a form that
    # tells anybody which of a list of addresses lift here, and this app's whole subject is
    # something people are entitled to keep private.
    # An address with no account is answered exactly as one with an account, which Rodauth
    # does not do by default: it refuses with a 401 and "no matching login", and that turns
    # the form into an oracle for which addresses have accounts here. On an app whose whole
    # subject is what somebody lifts, that is a worse leak than it looks -- it is not "is
    # this address registered", it is "does this person train, and where".
    #
    # So a miss takes the same redirect and the same flash as a hit, and writes nothing. The
    # cost is that somebody who mistypes their own address is told an email is on the way and
    # never gets one; the reset page says "if there is an account" rather than "we have sent
    # you an email" so that the sentence stays true in both cases.
    before_reset_password_request_route do
      next unless request.post?
      next if account_from_login(param(login_param).to_s)

      set_notice_flash reset_password_email_sent_notice_flash
      redirect reset_password_email_sent_redirect
    end
    reset_password_email_sent_redirect { '/login' }
    reset_password_redirect { '/' }
    # Rodauth builds a Mail object by default and expects an SMTP setup this app does not
    # have. One override sends it through Resend's HTTP API instead -- see lib/tectonic/mailer,
    # including why a delivery failure is logged rather than raised into the request.
    send_reset_password_email do
      Mailer.deliver(to: account[login_column], subject: 'Reset your tectonic plates password',
                     text: scope.reset_password_body(reset_password_email_link))
    end

    # An address has to be proved before the account is worth anything. #575.
    #
    # 410 accounts, 409 of which have never logged a set: 274 gmail and 99 yahoo with a tail
    # of throwaway-mail domains, 90 of the local parts carrying four or more consecutive
    # digits, and all of them arriving between 9 and 23 September. That is a form being found
    # and submitted by a bot, and the cost is not clutter. `reset_password` above really
    # sends, so every one of those addresses -- most belonging to people who never signed up
    # here -- can be made to receive mail from this domain by anybody who knows it. A sending
    # reputation is the kind of thing that is cheap to keep and very expensive to get back.
    #
    # ## The address is confirmed and the password is chosen on the same page
    #
    # Which is Rodauth's own default and is left alone here, so there is no line to point at:
    # `verify_account_set_password?` is true, which turns `create_account_set_password?` off
    # (`verify_account.rb:222-225`), so the sign-up form asks for an address and nothing else
    # and the emailed link leads to the page that takes the password.
    #
    # It is the flow that makes the feature mean the most. A sign-up form that takes a
    # password leaves a complete account sitting in the table that only a status column is
    # keeping shut; this way the row genuinely has no credential until somebody has read mail
    # at that address. For the four hundred and nine rows that prompted this, the difference
    # is between "an account nobody can open" and "not an account".
    #
    # **And it closes a hole the other order leaves open**, which is the argument that settles
    # it rather than merely favours it. Taking the password at sign-up means a bot that types
    # somebody else's address has already chosen the credential. Everything then rests on the
    # real owner of that mailbox not clicking the link -- and the link arrives looking exactly
    # like an ordinary confirmation, so one curious click hands the bot a working, confirmed
    # account under that person's address, with their mailbox as the recovery route. #575
    # exists because four hundred and nine accounts were made this way against what the domain
    # spread says are mostly real mailboxes, so that is not a hypothetical population. With the
    # password chosen after the link, the bot never holds a credential and no click by anybody
    # can create one: whoever opens the link is the person who sets the password, and that is
    # the person who reads the mail.
    #
    # **It costs `password_hash` its NOT NULL constraint**, and migrate/051 is where that is
    # argued -- including why the column stays on `accounts` rather than moving to Rodauth's
    # separate hash table, and why a null hash is safe rather than merely tolerable.
    #
    # **And it costs the password manager, which is the real price.** The sign-up form now has
    # nothing on it worth saving, so nothing offers to generate a credential there. The
    # password is instead chosen on a page reached from an email -- frequently in a different
    # browser from the one the form was filled in, or on a phone, without whichever manager
    # would have saved it. That is a worse moment to create a credential than the sign-up form
    # was, and it is the answer to "why is the password form over here": not an oversight, a
    # trade taken deliberately for the paragraph above. views/verify-account.erb keeps
    # `autocomplete="new-password"` on the box so that whatever manager *is* present still
    # offers; that is the whole of what can be done about it from here.
    # Sign-up no longer logs anybody in, so it can no longer redirect anywhere that needs a
    # session -- and the old value here was `login_destination(account_id)`, which runs
    # `ProgramSchedule.ensure_ahead` and `SessionClose.sweep` and then sends the browser to a
    # page behind `require_login`. After this change that is a redirect straight into the
    # login screen, with the sign-up's notice flash consumed on the way past.
    #
    # Not /login, which it was until #633. The argument was that /login is the page you come
    # back to once the email has been read -- but the emailed link signs you in by itself, so
    # nobody ever came back to it. It was only ever seen while waiting, and what it showed a
    # person with no password was a form asking for one. /check-your-email is the page for
    # waiting: it names the address, says where the password is chosen, and can send again.
    create_account_redirect { '/check-your-email' }
    # The zone question, moved here from `create_account_redirect` one flow later. #349, #575.
    #
    # It is asked at the first moment there is a session to ask it in, and that moment used
    # to be the sign-up redirect. Verification moves it, because `verify_account_autologin?`
    # is Rodauth's default and stays on: the person who clicks the link in the email is
    # logged in by `autologin_session('verify_account')` (`verify_account.rb:148-150`), and
    # that is now the first session a new account has.
    #
    # The ordering trap that made the old note worth writing is unchanged, and this is still
    # the only place the question can be asked from. `autologin_session` calls
    # `login_session`, which clears the session against fixation and then sets it again, so
    # anything an `after_create_account` or `after_verify_account` hook puts in the session is
    # wiped a few lines later, silently. A redirect block runs after all of that. The original
    # was found by a browser that detected its zone correctly, posted nothing, and left no
    # trace of why -- which is the only way this kind of ordering shows itself, and the reason
    # this comment is longer than the code.
    #
    # `login_destination` is right here for the same reason it was right there: a brand new
    # account is exactly the case the first-run page was written for.
    # Where the page that asked for a sign-in was saved -- the consent screen, most of all --
    # it wins here as it does at login (#628). An account signing up to connect an assistant
    # has that screen in its session, and the emailed link opened in the same browser
    # carries it through; opened anywhere else it has nothing, and /start says why.
    #
    # Read before the account is verified rather than in the redirect, because verifying signs
    # the account in and signing in starts a fresh session: by the time the redirect runs, the
    # saved page has gone with the old one.
    before_verify_account do
      @requested_before_sign_up = session[login_redirect_session_key]
    end
    verify_account_redirect do
      scope.ask_the_browser_for_the_zone(account_id)
      @requested_before_sign_up || scope.login_destination(account_id)
    end
    # The same saved page, read at sign-up, to note which assistant this account came here to
    # connect. See migrate/056. The session value is left where it is for the redirect above.
    after_create_account do
      scope.remember_the_connection(account_id, session[login_redirect_session_key])
      # The address this browser just signed up with, for /check-your-email to name (#633). In
      # this browser's own session, so the page tells nobody anything they did not type.
      session['signed_up_as'] = account[login_column]
    end
    # A resend from the browser that signed up goes back to the waiting page it came from;
    # anybody else's resend -- from a failed sign-in, say -- goes to /login as before.
    verify_account_email_sent_redirect { session['signed_up_as'] ? '/check-your-email' : '/login' }
    # Two flashes where Rodauth uses one. `verify_account_email_sent_notice_flash` is the
    # answer to *both* the sign-up form and the resend form (`verify_account.rb:185-187`),
    # and those two need different sentences, because only one of them knows an email was
    # sent. The resend form is answered identically for an address with no account -- see the
    # hook below -- so its wording has to stay true when nothing was sent at all, the same
    # way views/reset-password-request.erb's does. Sign-up does know, and gets to say so.
    # Nothing, since #633: /check-your-email says it at length, and a flash above it repeating
    # the headline would be the same sentence twice.
    create_account_notice_flash nil
    verify_account_email_sent_notice_flash \
      'If that address has an account waiting to be confirmed, a new link is on its way to it'
    verify_account_notice_flash 'Your address is confirmed. Welcome to tectonic plates'
    # And the two refusals, which Rodauth words for a developer reading a log rather than for
    # the person reading the page: "The account you tried to login with is currently awaiting
    # verification" names the mechanism and not the way out. Both of these are shown above the
    # resend form, so they have one job -- to explain why that form is what somebody is
    # looking at -- and the form underneath says what to do next.
    attempt_to_login_to_unverified_account_error_flash \
      'That address has not been confirmed yet, so there is nothing to sign in to'
    attempt_to_create_unverified_account_error_flash \
      'That address is already waiting to be confirmed, so there is nothing to sign up for again'
    # Through Resend rather than Rodauth's Mail object, mirroring send_reset_password_email
    # above -- including why a delivery failure is logged rather than raised into the request.
    #
    # `require_mail?` is deliberately left alone. Turning it off would stop Rodauth checking
    # that a mailer exists, and the check costs nothing while this override is what actually
    # sends; the day somebody deletes the override, the refusal to boot is the cheapest place
    # to find out.
    send_verify_account_email do
      Mailer.deliver(to: account[login_column], subject: 'Confirm your tectonic plates address',
                     text: scope.verify_account_body(verify_account_email_link))
    end
    # The reset form must go on answering a stranger exactly the way it answers a member,
    # which is the policy argued at length above -- and verification breaks it if nothing is
    # done. `_account_from_login` stops filtering on status once `skip_status_checks?` is
    # false (`base.rb:837`) and now matches unverified accounts too, so the existing
    # `before_reset_password_request_route` hook waves them through; the route then reaches
    # `reset_password_request_for_unverified_account` (`reset_password.rb:79`) and answers 403
    # "awaiting verification" where a stranger gets a 302 and a notice.
    #
    # That is a brand new oracle on the one form this app has written a policy for, so it is
    # the one of the three that gets an override. The other two -- login and sign-up -- are
    # answered in the PR: both were already oracles before this change, and both are where a
    # real person who never got the email has to be told something.
    #
    # The cost is that an unverified account asking for a reset is told nothing and gets no
    # email. That is the right trade here because it is not the way out: a person in that
    # state has a password, they chose it on the sign-up form, and what they are missing is
    # the confirmation. Trying to log in lands them on the resend page, which is the route
    # that fixes it.
    reset_password_request_for_unverified_account do
      set_notice_flash reset_password_email_sent_notice_flash
      redirect reset_password_email_sent_redirect
    end
    # And the fourth oracle, which is the resend form itself and is not in the issue.
    #
    # `/verify-account-resend` is an unauthenticated form that takes an address and sends
    # mail to it -- the same shape as the reset form, and it answers a hit with a notice and
    # a miss with a 401 and an error flash (`verify_account.rb:75-93`). It also answers "sent
    # one in the last five minutes" differently again. Left alone it would be a better
    # enumeration oracle than the reset form ever was, and it would be one on the very change
    # whose purpose is to stop this app mailing addresses it has no relationship with.
    #
    # So the same hook, in the same shape, for the same reason: anything that is not an
    # unverified account due another email is answered with the notice and writes nothing.
    # Collapsing the throttled case in here too is deliberate -- if a recent send were the one
    # case that came back differently, the form would still answer the question, just more
    # slowly.
    before_verify_account_resend_route do
      next unless request.post?
      next if account_from_login(param(login_param).to_s) && allow_resending_verify_account_email? &&
              !verify_account_email_recently_sent?

      set_notice_flash verify_account_email_sent_notice_flash
      redirect verify_account_email_sent_redirect
    end

    # What a second signup on one address is told. #345.
    #
    # Until the unique index in 027 there was nothing to say, because the second signup
    # succeeded: two rows, and login resolving forever to the first, so the person who
    # signed up twice got "wrong password" on an account they had just created and -- with
    # no reset flow in this app -- no way out of it.
    #
    # The refusal names the way out rather than only the problem. Rodauth's default is
    # "there is already an account with this login", which is true and leaves a person on a
    # signup form with nothing to do next; the address they typed is the address they want,
    # so the answer is almost always to log in with it.
    # Lower case and no full stop at the front: Rodauth renders this after its own generic
    # reason, so the pair has to read as one sentence. views/_form_error.erb raises the
    # first letter of whichever sentence it ends up showing.
    already_an_account_with_this_login_message \
      'an account with this email address already exists. Log in instead, or use another address'
    after_login do
      remember_login
      scope.ask_the_browser_for_the_zone(account_id)
    end
    # Signing in lands on whatever there is to do -- today's session if there is one, the
    # calendar if not; login_destination below decides.
    #
    # Creating an account is set separately because Rodauth keeps a second default for it
    # and never consults this one. A brand new account is exactly the case the first-run
    # page was written for, so leaving that unset is how the page would never be seen by
    # the only person it is for. account_id rather than a fresh lookup: both routes have
    # already loaded the account by the time they redirect.
    #
    # Neither hook overrides a deep link. Rodauth saves the path of a page that demanded a
    # login and prefers it, so someone who followed a link to a workout, or to the OAuth
    # consent screen, still arrives where they were going.
    #
    # That was the claim, and it was not true until #628: Rodauth only saves the page when
    # `login_return_to_requested_location?` is on, and it defaults to off. So somebody pressing
    # Connect in Claude while signed out signed in and landed on /start, and the assistant
    # waited for a consent that never came. It is on now.
    #
    # Only for a page somebody navigated to. A background request that finds the session gone
    # -- the session screen's poll, its doorbell -- would otherwise save a fragment or an event
    # stream as the place to return to, and the next sign-in would land on a scrap of HTML.
    login_return_to_requested_location? true
    login_return_to_requested_location_path do
      navigated = request.get? && !request.env['HTTP_HX_REQUEST'] &&
                  !request.env['HTTP_ACCEPT'].to_s.include?('text/event-stream')
      request.fullpath if navigated
    end
    login_redirect { scope.login_destination(account_id) }
    # The same question is asked of a brand new account -- which has no zone by definition --
    # from `verify_account_redirect` above, and the note there is the one that explains why a
    # redirect block is the only place it can be asked from. It sat here, on
    # `create_account_redirect`, until #575 moved it: sign-up no longer opens a session, so
    # there is nothing here to put a zone request into.

    # A background request cannot be answered with a redirect to the login page: the
    # browser follows it inside the fetch, so what htmx receives is the sign-in markup
    # with a 200 on it, and it splices that into whatever target the request named --
    # the middle of a workout, in #341's screenshot, via the session poll. htmx reads
    # this header before it considers swapping, so a signed-out answer to any htmx
    # request walks the whole tab to the login screen instead.
    login_required do
      if request.env['HTTP_HX_REQUEST']
        response['HX-Redirect'] = login_path
        response.status = 401
        request.halt
      end
      super()
    end

    # The scopes an LLM can be granted, and the RSA keypair that signs (private) and
    # verifies (public) the JWT access tokens the resource server checks locally.
    oauth_application_scopes %w[read write]
    oauth_jwt_keys OAuthKeys.signing_keys
    oauth_jwt_public_keys OAuthKeys.verification_keys
    # OAuth 2.1 / MCP: PKCE is already required; refuse the weak "plain" challenge so
    # only S256 is accepted.
    oauth_pkce_allow_plain_method false
    # Public clients (claude.ai registers via DCR with no secret, relying on PKCE) use
    # token_endpoint_auth_method "none", so accept it alongside the secret methods.
    oauth_token_endpoint_auth_methods_supported %w[client_secret_basic client_secret_post none]
    # Open dynamic client registration (RFC 7591): an LLM registers itself with no
    # prior account -- the user is bound later, at the consent step. Registration stays
    # open because a registered client can do nothing until a logged-in user authorizes
    # it, but where the authorization code may be delivered is not open: rodauth-oauth
    # asks only whether the redirect_uri parses, and a callback pointing anywhere turns
    # one careless approval on the consent screen into a stolen code.
    # POST /register is unauthenticated by design, which also means an anonymous caller
    # decides how much this process allocates: nothing else caps a request body, and the
    # JSON parser builds whatever it is handed. The size is checked before the body is
    # read, and the refusal is the RFC 7591 error shape rather than a 413, which a
    # client reads as a transport failure rather than as a registration it can fix.
    before_register_route do
      next unless request.content_length.to_i > REGISTRATION_BODY_LIMIT

      register_throw_json_response_error('invalid_client_metadata', 'The registration request is too large.')
    end
    before_register do
      registered = @oauth_application_params[oauth_applications_redirect_uri_column].to_s.split
      refused = registered.reject { |uri| OAuth::RedirectUri.allowed?(uri) }
      next if refused.empty?

      # A refusal used to leave no trace: the caller got the RFC 7591 error and the
      # server kept nothing. That is the wrong shape for this particular failure --
      # the allow-list is a standing guess about what a vendor's connector will
      # present, and being wrong shows up as somebody reporting that it would not
      # connect, with no way to find out what was attempted. Reproducing it needs
      # whatever subscription exposes that connector, so the one chance to see the
      # cause is the moment it happens. One line on stderr, which the platform log
      # keeps, is the whole fix.
      warn "refused redirect_uri at registration: #{OAuth::RedirectUri.describe(refused.first)} " \
           "(#{refused.length} of #{registered.length} refused)"
      register_throw_json_response_error('invalid_redirect_uri', register_invalid_uri_message(refused.first))
    end
    # A native client's callback is a loopback address, which is necessarily http
    # (RFC 8252 section 7.3), and rodauth-oauth accepts https alone. Admitting http is
    # what makes a loopback callback registrable at all; the allow-list above is what
    # keeps http from meaning anything but loopback.
    oauth_valid_uri_schemes %w[https http]
    # Refresh tokens rotate on use, which detects a stolen token being replayed but
    # leaves the grant behind it alive; this revokes that grant, as RFC 9700 section
    # 4.14.2 requires. Prepended so it sits in front of the feature methods it extends.
    auth_class_eval { prepend OAuth::RefreshTokenReuse }
    # Revoking a grant has to reach the access tokens it already issued, not just the
    # ones it would go on to issue. A JWT is verified by signature alone, so it needs to
    # name its grant for the resource server to check; this puts that name in the claims.
    auth_class_eval { prepend OAuth::GrantBoundTokens }
    # The consent screen renders through a layout of its own. The site layout carries an
    # analytics script, and conditionally two charting libraries and htmx, none of them
    # subresource-pinned -- and any one of them could rewrite the form that grants an API
    # client the account. None of them has anything to do with this page, so it loads none
    # of them, and the policy above says so.
    authorize_view do
      scope.response['Content-Security-Policy'] = CONSENT_SECURITY_POLICY
      scope.view('authorize', layout: 'oauth_layout')
    end
    # Standard authorization-code default: redirect back with ?code=... rather than
    # rodauth-oauth's form_post default, which is what MCP clients like claude.ai expect
    # when they omit response_mode. (form_post is still offered for clients that ask.)
    oauth_response_mode 'query'
  end

  route do |r|
    # Who is asking and what they asked for, attached before anything can fail. #385.
    #
    # Before r.assets and r.public rather than after, so a failure serving an asset is
    # described too -- and because this is the only point every request passes through.
    #
    # `rodauth.session_value` rather than `account_from_session[:id]`, which is what the rest
    # of this file uses: that one loads the account row, and this needs the id alone on every
    # request including the ones that never touch an account. session_value reads the session
    # and is nil when nobody is logged in.
    #
    # It is a no-op wherever reporting is off, which is every local run and the whole suite.
    ErrorReporting.describe_request(path: r.path, account_id: rodauth.session_value)
    r.assets
    r.public
    r.rodauth
    # RFC 9728 protected-resource metadata: rodauth-oauth does not ship it, and MCP
    # clients require it to discover the authorization server. It lives at the root
    # (the /mcp resource server is mounted separately), so Roda serves it -- and it must
    # be matched before the AS metadata route below, which consumes the shared
    # `.well-known` segment.
    r.get('.well-known/oauth-protected-resource') do
      response['content-type'] = 'application/json'
      MCP::Config.protected_resource_metadata.to_json
    end
    # rodauth-oauth serves RFC 8414 authorization-server metadata from its own method
    # rather than a registered route, so it has to be invoked here; it only fires for
    # GET /.well-known/oauth-authorization-server and otherwise falls through.
    rodauth.load_oauth_server_metadata_route

    r.get('welcome') { view('welcome') }
    r.get('about') { view('about') }
    # The connector's documentation, and the fifth public page. #359.
    #
    # Public and unauthenticated, because it is what a directory submission points at and what
    # somebody reads before deciding whether to connect an app to their assistant at all --
    # both of which happen before there is an account to sign in to.
    r.get('docs') do
      @page_title = 'Connect tectonic plates to Claude or ChatGPT'
      @page_description = 'Add the tectonic plates connector to Claude or ChatGPT: plan a ' \
                          'whole barbell block in conversation, have it written into real ' \
                          'sessions, and log every set against it.'
      view('docs')
    end
    # The first thing an account with nothing logged sees. A calendar of an empty month
    # is a true answer to "what have I trained" and a useless one to "what do I do now",
    # which is the only question a new account has. It stays reachable at its own address
    # rather than only through the login redirect, so it can be linked to and so someone
    # who has trained for a year can still come back and read what a block is.
    # Waiting for the confirmation email. #633. Only for the browser that signed up -- it names
    # the address from that browser's own session -- and anybody else is sent to sign in.
    r.get('check-your-email') do
      @address = session['signed_up_as']
      r.redirect '/login' unless @address
      view('check-your-email')
    end
    r.get('start') do
      rodauth.require_login
      @connecting = connecting_to(rodauth.account_from_session[:id])
      view('start')
    end
    # GET /
    r.root do
      r.redirect '/welcome' unless rodauth.logged_in?
      @account_id = rodauth.account_from_session[:id]
      # The lifter's today throughout, not the server's (#349). Read once and passed down
      # rather than asked for four times, so the month, the grid and the tally cannot land on
      # different sides of midnight -- which is the third failure that issue names: a Monday
      # evening session marked missed on the calendar while it was being lifted.
      today = Clock.today(account_row[:time_zone])
      # And here, because a session signed in once and left open for a fortnight would
      # otherwise never pass the hook above again -- and this is the page somebody lands on to
      # ask what they are doing this week.
      ProgramSchedule.ensure_ahead(@account_id, today)
      # And here for the same reason, which is sharper for this one: a session left open two
      # weeks ago is a cell on this very grid, and it would be drawn as 24h of training.
      SessionClose.sweep(@account_id)
      @month = Calendar.month_of(r.params['month'], today)
      @previous = @month << 1
      @following = @month >> 1
      @week_starts_on = week_starts_on
      @weeks = Calendar.weeks(@account_id, @month, today, @week_starts_on)
      @tally = Calendar.tally(@weeks, today)
      # Whether there is anything at all, in any month. A new account's empty month and a
      # quiet month on a year-old account need different sentences (#636).
      @anything = !Workout.where(account_id: @account_id).empty?
      view('home')
    end

    # Training blocks: what is written, and turning a week of it into real sessions. The
    # common act is adjusting one lift between weeks, so that is a form on the block page
    # rather than a page of its own; authoring a block from nothing is rarer and is a
    # week copied and then edited, which is how a block actually gets written.
    # /programs is gone. #411.
    #
    # The programme object exists so that something can generate sessions from it; the lifter
    # experiences training as workouts. Those are different audiences and only one of them is
    # human, and a full authoring interface -- create block, add week, add day, reorder lifts,
    # edit percentages -- was a large surface for something that takes about thirty seconds
    # conversationally, maintained as a second way to do a job the clicking one did worse.
    #
    # Kept rather than deleted outright, for a bookmark or a browser that remembers: the same
    # treatment /equipment got when it became /settings. Workouts is where the training is.
    r.on 'programs' do
      rodauth.require_login
      r.redirect '/workouts'
    end

    # The bar and plates this account lifts on. Everything the app calculates rounds to
    # what this rack can load, so it is the one setting that changes the numbers.
    # Where /equipment used to be. Every link in the app points at /settings now, and this
    # is here for a bookmark or a browser that remembers the old one. #189.
    r.on 'equipment' do
      rodauth.require_login
      r.redirect '/settings'
    end
    # What this account has asked the app to do differently: which day a week starts on,
    # and what is on the rack. Two forms rather than one, because they are two unrelated
    # answers and a single Save would make changing either mean re-submitting both.
    #
    # The plate inventory moved here from a page of its own, which is the scope #189 added:
    # it is the same kind of thing as the week start -- a per-account preference about how
    # the app should behave -- and splitting "what I lift with" from "how I read a week"
    # across two pages put settings in two places.
    #
    # Units are deliberately not here. That was the largest part of the issue and it was
    # dropped: pounds everywhere, no kg, so there is nothing to choose.
    #
    # Grouped into five named sections since #529 -- weight plates, wearables, AI agents, time
    # and week, session length -- with a fragment each. That is a change to the template and
    # to where these redirects land, and to nothing else: every form below still posts what it
    # posted, to the address it posted to. The fragments are why the redirects carry one; the
    # argument for anchors over routes or disclosures is at the top of views/settings.erb.
    r.on 'settings' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]

      r.post 'week' do
        check_csrf!
        # Checked here as well as in the database, and not for belt and braces: a check
        # constraint refuses the write by raising, and an unrescued Sequel exception reaches
        # a person as a 500 rather than as a refusal. That is #213's bug in a new place, so
        # this is #211's answer to it -- the route refuses by name and the constraint stays
        # as the backstop for anything that never comes through here.
        #
        # The two are the only days a calendar grid can honestly begin on. A week starting
        # on Wednesday is not a preference anybody has, and accepting one would mean every
        # reader handling a value nobody will ever choose.
        chosen = r.params['week_starts_on'].to_i
        DB[:accounts].where(id: @account_id).update(week_starts_on: chosen) if Calendar::WEEK_STARTS.include?(chosen)
        # Back to the section it was saved in rather than to the top of the page. #529.
        #
        # The page is five sections deep now and a save that landed at the top would undo the
        # one thing the section index buys: a lifter who aimed at Time and week, changed the
        # day and pressed Save would be put back above Weight plates and have to aim again.
        # A fragment on a redirect is not sent to the server, so this changes where the browser
        # stops scrolling and nothing else about the request.
        r.redirect '/settings#time-and-week'
      end

      # How long a session should take. #446.
      #
      # The column has lived on `programs` since 032 and no block ever carried one, so the
      # warning at generation and the comparison in SessionLength were built and never ran.
      # #458 is why that is a wrong-object problem rather than a missing screen: it asks for no
      # CRUD interface and names the exception -- "one number per movement and one editable
      # field" -- which is exactly this.
      #
      # "I have an hour to train" is a fact about a lifter's week rather than about a block. It
      # is the same next block and the one after, and asking it again on every block written is
      # how it comes to be asked never. The block keeps its own column and still wins where it
      # says something, because a peaking block really can be longer.
      #
      # Refused by name rather than clamped, the same way the zone below is: a check constraint
      # refusing the write raises, and an unrescued Sequel exception reaches a person as a 500
      # rather than as a refusal. Blank clears it, which is how the warning is turned off.
      r.post 'budget' do
        check_csrf!
        DB[:accounts].where(id: @account_id).update(time_budget_minutes: clean_budget(r.params['minutes']))
        r.redirect '/settings#session-length'
      end

      # Handing Withings permission to be read. #472.
      #
      # Under /settings because that is where the other facts about this lifter live, and
      # because connecting is a preference rather than a thing you do to a workout.
      #
      # `state` is stored in the session and compared on the way back. It is the only thing
      # tying the callback to the browser that began the flow: without it, anyone can send a
      # logged-in lifter to the callback with a code of their own and attach *their* Withings
      # account to this one. Deleted on use, so a code cannot be replayed against it.
      r.post 'withings/connect' do
        check_csrf!
        r.redirect '/settings' unless Withings.configured?

        state = Withings.new_state
        session['withings.state'] = state
        r.redirect Withings.authorize_url(withings_redirect_uri, state)
      end

      # Importing one year of history, which is the whole of #558. A press, a year, a report.
      #
      # ## Why this may sit on the request path at all
      #
      # Everything about this integration that says "not in a Puma thread" is an argument
      # about a *decade*: `Withings::TIMEOUT` is ten seconds a call, and a walk from today
      # back to a lifter's first session is a hundred of them with pauses in between. One
      # year is one call in the ordinary case -- `Withings.workouts` follows `more`/`offset`
      # within the year, and a year of lifting is one page -- so the request this makes is
      # the same shape as the one the record page has made on every view of a fresh session
      # since #520. What is bounded is not the wait but the work: the year is fetched, stored,
      # paired and reported, and the years before it are left for the next press.
      #
      # The budget it is bounded against is `RACK_TIMEOUT_SERVICE_TIMEOUT`, twenty seconds,
      # which config.ru puts around every request in this app. A year is one page for any
      # plausible amount of training and `Withings.workouts` sleeps a second between pages, so
      # an ordinary press is a second or two and a year busy enough to page a dozen times is
      # the only thing that could reach the ceiling. If it ever does, the failure is the safe
      # one by construction: the store happens after the whole year has answered, so a press
      # cut off mid-walk has written nothing and moved no cursor, and the same press can
      # simply be made again. The alternative -- dropping the pause to fit more pages in --
      # trades a slow press for status 601, which is the one failure this app cannot see.
      #
      # The two alternatives #558 lists were both refused here. A guarded background thread
      # is real concurrency in a process that has none, and the failure it introduces -- a
      # deploy killing a run mid-walk -- is invisible from the page that started it. A slice
      # on an arbitrary page view is smaller still and makes somebody's workouts list pay for
      # a decade they did not ask to import, silently, with no way to tell a slow page from a
      # slow phone. A press is the one shape where the person waiting is the person who asked.
      #
      # ## Post, redirect, get, and the report carried across it
      #
      # The same shape as every other save on this page, so a reload cannot re-import a year.
      # The report rides in the session the way the connect/disconnect notice does -- there is
      # no flash here but Rodauth's -- and it is written with string keys on purpose: the
      # session's serializer is JSON, so symbols go in and strings come out, and a view
      # comparing `report[:state]` against a symbol would silently render nothing at all.
      r.post 'withings/import' do
        check_csrf!
        session['withings.import'] = carried(WithingsBackfill.slice(account_id: @account_id))
        # To the section, not the top of the page: what the lifter is waiting to read is the
        # report next to the button they pressed. #529's argument for the four saves, and the
        # opposite of the disconnect below, whose whole news is the notice at the top.
        r.redirect '/settings#wearables'
      end

      # Disconnecting forgets the tokens and keeps the measurements: they are a record of what
      # the lifter weighed, which stays true whether or not the app may still ask for more.
      r.post 'withings/disconnect' do
        check_csrf!
        WithingsConnection.forget(@account_id)
        session['settings.notice'] = 'Withings disconnected. Your measurements are still here.'
        # No fragment on this one, unlike the four saves. What the lifter needs to read is the
        # notice, and the notice is at the top of the page above the section index -- because
        # it is the answer to the last thing asked rather than a fact about one section, and
        # because the Withings callback lands here with the same kind of sentence. A redirect
        # that jumped to #wearables would scroll straight past the only new thing on the page.
        r.redirect '/settings'
      end

      # Where this account is, which decides what day it is for them (#349). Refused by name
      # rather than written and ignored: a zone nothing can resolve would be stored happily
      # and then read as UTC by every caller, which is the failure this exists to end.
      #
      # Blank is a real answer and means UTC -- the behaviour every account had before this
      # column existed -- so it is written rather than refused.
      r.post 'zone' do
        check_csrf!
        chosen = r.params['time_zone'].to_s.strip
        if chosen.empty? || Clock.zone?(chosen)
          DB[:accounts].where(id: @account_id).update(time_zone: chosen.empty? ? nil : chosen)
        end
        session.delete('zone.detect')
        r.redirect '/settings#time-and-week'
      end

      # What the browser says the zone is. #349.
      #
      # Posted once after a sign-in by the script in the layout, and answered with 204: nothing
      # on the page changes, and a redirect would be a navigation nobody asked for in the
      # middle of reading a session.
      #
      # **It fills a blank and never overrules an answer.** The write is conditional on the
      # column still being null, in the query rather than in a read-then-write, so two tabs
      # racing cannot have the second overwrite a zone the first just set. Somebody who chose
      # their home zone deliberately and is signing in from an airport keeps the one they chose.
      #
      # Validated like any other input, because it is one: this arrives from a browser and a
      # name nothing can resolve would be stored and then read as UTC by every caller, which is
      # the failure the whole of #349 exists to end.
      #
      # The flag is cleared whatever happens, including on a name that is refused. A browser
      # that cannot answer this will not answer it better on the next page load, and a detector
      # that reposts on every page for the rest of the session is worse than not detecting.
      r.post 'zone/detected' do
        check_csrf!
        detected = r.params['time_zone'].to_s.strip
        DB[:accounts].where(id: @account_id, time_zone: nil).update(time_zone: detected) if Clock.zone?(detected)
        session.delete('zone.detect')
        response.status = 204
        ''
      end

      r.post do
        check_csrf!
        # Both racks in one post, because the form is one form and the rack is one fact --
        # which is the argument Equipment.replace already made about the plates alone. #369
        # separated them on the page rather than into two submissions: a lifter changing their
        # bar and their dumbbell handle in one sitting should not have to save twice.
        Equipment.replace(@account_id, bar_weight: r.params['bar_weight'],
                                       plates: r.params['plates'],
                                       dumbbell_handle_weight: r.params['dumbbell_handle_weight'],
                                       dumbbell_plates: r.params['dumbbell_plates'])
        # And the sessions the old rack wrote are brought up to date with the new one. #439.
        #
        # Saving the rack used to change only what the *next* generation would do, so a block
        # already written kept whatever the app had believed about the plates on the day it was
        # generated. That is how the reporting account ended up prescribing the same movement
        # at 44 in one week and 45 in the next, 45 being a dumbbell a 4 lb handle cannot build.
        #
        # Completed sets are safe because refresh never touches them, so this cannot rewrite
        # training that has already happened -- see RackChange.
        moved = RackChange.reround(@account_id, today: Clock.today(account_row[:time_zone]))
        # The fragment goes after the query string, which is the order a URL is written in and
        # not a detail a browser is forgiving about: everything after the first `#` is the
        # fragment, so `/settings#weight-plates?rerounded=2` would be a fragment nothing on the
        # page has an id for and a count the route never sees.
        r.redirect(moved.positive? ? "/settings?rerounded=#{moved}#weight-plates" : '/settings#weight-plates')
      end

      r.get do
        # How many upcoming sessions the save just moved, carried in the query string rather
        # than a flash because this app has no flash of its own -- the only one in it belongs
        # to Rodauth. `to_i` floors anything else to zero, so a hand-typed value can say
        # nothing worse than nothing.
        @rerounded = r.params['rerounded'].to_i
        @time_budget_minutes = account_row[:time_budget_minutes]
        @week_starts_on = week_starts_on
        @equipment = equipment
        @time_zone = account_row[:time_zone]
        @today = Clock.today(@time_zone)
        # Whether Withings is connected, and whether the connection still works -- three
        # states rather than two, because a grant revoked from Withings' own app leaves a row
        # here that no longer buys anything. #472.
        @withings = WithingsConnection.status(@account_id)
        @withings_configured = Withings.configured?
        # And how many matches are waiting on an answer, which is what makes the review list
        # findable by somebody who did not just run a rake task. #534.
        #
        # Here rather than in the nav, because this is the screen's *permanent* address and a
        # permanent address must not move: the Withings block is where a lifter already comes
        # to reason about the watch, and a link that sits inside it is in the same place
        # whether or not there is anything behind it. The timely prompt -- the one that
        # catches somebody who was not looking for it -- is on /workouts.
        #
        # Asked only where the block will render a link, which is only where there is a
        # connection. An account that has never connected a watch is told nothing about
        # Withings on this page beyond how to start, and should not pay a query to be told
        # nothing.
        @withings_waiting = WithingsProposals.waiting_count(@account_id) unless @withings[:state] == :absent
        # What a press of Import would read next, and what the last press found. #558.
        #
        # Asked before the button is drawn rather than after it is pressed, because a control
        # that spends a minute talking to somebody else's server has to say what it is going
        # to do first: "Import" that silently reads a year is worse than a sentence naming the
        # year. Two reads of one connection row and one aggregate over the lifter's sets,
        # which is what it costs to be able to say "2023 next, four years to go".
        #
        # Paid only where the control will render, which is where the connection is live: a
        # permission that has expired has a Reconnect in front of it and nothing to import
        # through until somebody uses it, and an account with no connection at all is told how
        # to start and nothing else.
        @withings_import = WithingsReadRange.pending(@account_id) if @withings[:state] == :live
        # Taken out of the session as it is read, the same as the notice below, so a reload
        # does not re-announce a year imported ten minutes ago as though it had just happened.
        @withings_imported = session.delete('withings.import')
        # And how many assistants this account has let in, for the AI agents section. #529.
        #
        # The section is a signpost to /connections rather than a second copy of it, so this is
        # the only thing it needs to know: a count lets somebody decide the link is not worth
        # following, which is the same job the sentence above does for the review list. Asked
        # unconditionally, because unlike Withings there is no state in which the section is
        # absent -- "nothing is connected yet" is the answer most accounts get and it is worth
        # a query to be able to say it.
        @assistants = Connection.count_for_account(@account_id)
        # Read once and taken out of the session, the same shape the exercise page uses, so a
        # reload does not re-announce a connection made ten minutes ago.
        @notice = session.delete('settings.notice')
        view('settings')
      end
    end

    # Where Withings sends the lifter back. #472.
    #
    # Outside the /settings block on purpose: Withings redirects a browser here with query
    # parameters and no CSRF token of ours, so it cannot sit behind check_csrf! -- and the
    # `state` comparison below is what does that job instead, which is the whole reason OAuth
    # specifies it.
    #
    # A GET that writes, which is unusual here and is not a choice: the authorization-code
    # flow is defined as a redirect, and a redirect is a GET. It is made safe by the state
    # being single-use.
    r.on 'withings' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]

      r.get 'callback' do
        expected = session.delete('withings.state')
        # Three ways this is not a real callback, and none of them should say the same thing
        # as success. A mismatched state is the attack; a missing code is Withings refusing
        # or the lifter pressing cancel.
        next settings_with('That Withings link did not match this browser. Try connecting again.') \
          if expected.nil? || r.params['state'].to_s.empty? || r.params['state'] != expected

        next settings_with('Withings did not grant access. Nothing has changed.') if r.params['code'].to_s.empty?

        tokens = Withings.exchange(r.params['code'], withings_redirect_uri)
        next settings_with('Withings could not be reached just now. Nothing has changed.') unless tokens

        WithingsConnection.store(@account_id, tokens)
        settings_with('Withings connected.')
      end

      r.redirect '/settings'
    end

    # What the training actually contained, folded into weeks. Every other view lists
    # rows and so can only answer what happened on a given day; this one answers whether
    # the volume is going up, which is the question a block is judged by.
    r.on 'volume' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]

      r.get do
        @weeks = volume_window(r.params['weeks'])
        @lifts = Volume.lifts(@account_id, weeks: @weeks)
        @lift = @lifts.find { |id, _name| id.to_s == r.params['exercise_id'].to_s }
        @rows = Volume.weekly(@account_id, exercise_id: @lift&.first, weeks: @weeks)
        @summary = Volume.summary(@rows)
        # Only so many lines stay readable at once; the rest are counted so the page can
        # say what it left out rather than quietly drawing a partial picture.
        trends = Volume.top_sets(@account_id, exercise_id: @lift&.first, weeks: @weeks)
        @top_sets = trends.first(Volume::SERIES)
        @withheld = trends.length - @top_sets.length
        @by_exercise = Volume.by_exercise(@account_id, weeks: @weeks) unless @lift
        view('volume')
      end
    end

    # The assistants this account has connected, and how to connect another. The app has
    # advertised "connect your LLM over MCP" on two pages since before there was anywhere
    # to do it, and until now nothing showed what was already connected or took it away.
    r.on 'connections' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]

      r.post String do |application_id|
        check_csrf!
        Connection.revoke(@account_id, application_id.to_i)
        r.redirect '/connections'
      end

      r.get do
        @connections = Connection.for_account(@account_id)
        # Without MCP_PUBLIC_BASE_URL the resource URL is a bare path, which is not an
        # address anyone can paste into an assistant. Say so rather than render half of
        # one: a lifter who copies "/mcp" gets an error from their assistant and no idea
        # that this deployment is misconfigured.
        @resource_url = MCP::Config.resource_url unless MCP::Config.public_base_url.to_s.empty?
        view('connections')
      end
    end
    r.on 'exercises' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]
      r.get('new') { view('exercises/new') }
      # `r.post(true)` rather than a bare `r.post`, which matches a POST to anything under
      # /exercises and so is terminal for every one of them. That was harmless while this
      # was the only POST here -- views/exercises/_form.erb posts to /exercises exactly, and
      # nothing else did -- and it stops being harmless the moment a second one exists:
      # #264 adds POST /exercises/:id/training-max below, and a bare matcher here would
      # swallow it and run the create-or-update branch against a form that sent no name.
      # The terminal matcher says what this route always meant, which is /exercises itself.
      r.post(true) do
        check_csrf!
        # Whether the movement is loaded on a bar is asked outright here and the answer
        # is taken as given, ticked or not: a person looking at the checkbox knows their
        # own variation better than a name ever says. The paths with nobody to ask fall
        # back to the library name instead.
        is_barbell = !r.params['is_barbell'].nil?
        # And whether it is counted one limb at a time, on the same terms (#279). Every
        # other write path could set this and the form could not, so a split squat added
        # in the browser counted half the volume it should have and nothing said so.
        default_is_per_side = !r.params['default_is_per_side'].nil?
        # The textarea is posted whether or not anyone typed in it, so a blank one has to
        # become a null rather than an empty string; clean_note is where that is decided
        # for every write path, this one and the MCP tools alike.
        note = Exercise.clean_note(r.params['note'])
        # And how many dumbbells it is done with, which decides which weights exist for it at
        # all (#439). Blank stays null so "not said" remains distinguishable from a deliberate
        # two -- see Exercise.clean_dumbbell_count.
        dumbbell_count = Exercise.clean_dumbbell_count(r.params['dumbbell_count'])
        # And how long it is rested, which is the one field here that makes a noise (#456).
        # Named by the lifter, which is what lets the session timer ring on it: a countdown
        # that rings unasked is the app interrupting a session, and #263 settled that the app
        # does not decide how long anybody rests.
        #
        # Written after the row rather than with it since 039, because it no longer lives on
        # the row: a rest is a fact about the lifter and the movement together, so a library
        # Back Squat can carry one per account instead of none at all.
        rest = r.params['default_rest_seconds']
        # icon_url is deliberately not read here. #199 took the field off the form -- every
        # library movement draws a shipped icon since #171, so the field was a way to point
        # every visitor's browser at a third party to override a working default. The column
        # stays, and the MCP tools still write it, which is why this must not pass the param
        # through: the form no longer sends one, so reading it would set the column to nil
        # and quietly erase an icon an assistant had chosen every time somebody used the
        # browser to fix a typo in the name.
        if r.params['id'].empty?
          # The movement this name already is, if it is one. #474: matched on the folded name,
          # so "Benchpress" finds "Bench Press" instead of making a second row beside it.
          existing = Exercise.matching(@account_id, r.params['name'])
          next r.redirect "/exercises/#{existing.id}/" if existing

          # And the ones it might be under another name. #478: fifteen movements here have
          # "squat" in the name and none of them folds to "Squat", so nothing above catches a
          # sixteenth being written. Asked rather than refused, because there is a person at
          # this end who can answer -- the form comes back with the candidates on it, and
          # confirming posts the same fields again with the question answered.
          @similar = Exercise.similar_to(@account_id, r.params['name'])
          if @similar.any? && r.params['new_exercise'].nil?
            @exercise = Exercise.new(name: r.params['name'], is_barbell:, default_is_per_side:,
                                     note:, dumbbell_count:)
            # The typed rest survives the round trip through the confirmation, which the row
            # above no longer carries it for. Losing it would make confirming a near-duplicate
            # silently drop the one field on this form that makes a noise.
            @rest = Rest.clean(rest)
            next view('exercises/new')
          end
          exercise_id = Exercise.insert(name: r.params['name'], account_id: @account_id,
                                        is_barbell:, default_is_per_side:, note:, dumbbell_count:)
          Rest.replace(@account_id, exercise_id, rest)
          r.redirect "/exercises/#{exercise_id}/"
        else
          # Only the owner may update; library rows (nil account) and other
          # accounts' rows don't match, so the edit is refused. The note is on the same
          # side of that line as the name, and has to be: a library movement sits on every
          # account's page, so a note written to one is a value one account wrote and
          # everybody else reads.
          @exercise = Exercise.owned_by(@account_id).where(id: r.params['id']).first
          r.redirect '/exercises' unless @exercise
          # Read before the update, because it is the *change* that has to reach the sets and
          # afterwards there is nothing left to compare against. #392.
          was_per_side = @exercise.default_is_per_side
          was_dumbbells = @exercise.dumbbells
          @exercise.update(name: r.params['name'], is_barbell:, default_is_per_side:, note:,
                           dumbbell_count:)
          Rest.replace(@account_id, @exercise.id, rest)
          # Saying a movement is counted per side is a statement about the movement, not about
          # today, so the sets that were following the old answer follow the new one. Silently
          # would be wrong -- this rewrites logged training -- so the page says how many moved.
          if default_is_per_side != was_per_side
            moved = Exercise.align_sets_per_side(@exercise, @account_id, was: was_per_side)
            session['exercise.notice'] = per_side_notice(moved, default_is_per_side) if moved.positive?
          end
          # Saying how many dumbbells changes which weights exist for this movement, so the
          # sessions already written against the old answer are brought onto the new one --
          # the same reround a rack change does, for the same reason, since the pair of facts
          # decides one list between them. Compared on `dumbbells` rather than on the column
          # so that filling in a blank as two, which is what the app was already assuming,
          # correctly counts as no change and reports nothing. #439.
          if @exercise.dumbbells != was_dumbbells
            rerounded = RackChange.reround(@account_id, today: Clock.today(account_row[:time_zone]))
            session['exercise.notice'] = dumbbell_notice(rerounded, @exercise.dumbbells) if rerounded.positive?
          end
          r.redirect "/exercises/#{@exercise.id}/"
        end
      end
      r.on String do |exercise_id|
        # Library exercises (nil account) are visible to everyone, private ones
        # only to their owner; another account's private exercise won't load.
        @exercise = Exercise.visible_to(@account_id).where(id: exercise_id).first
        r.redirect '/exercises' unless @exercise
        r.get('edit') do
          # Editing is owner-only; library and others' rows fall back to show.
          r.redirect "/exercises/#{@exercise.id}/" unless @exercise.account_id == @account_id
          # The rest is no longer on the row, so the form has to be handed it (039). Owner-only
          # here, which is fine: a library movement has no edit page and answers the same
          # question through its own page's field instead.
          @rest = Rest.for(account_id: @account_id, exercise_id: @exercise.id)
          view('exercises/edit')
        end
        # The max this account takes percentages of, stated rather than derived. #264.
        #
        # Deliberately not behind the owner-only gate the edit above sits behind, and this
        # is the point of keying it on the pair rather than putting a column on exercises:
        # a training max is not a property of the movement, it is a property of this account
        # *on* the movement. A shared Back Squat is on everybody's page, and everybody has a
        # different one -- so the row is private by construction and there is nothing here
        # for the library rule to protect.
        #
        # Blank clears, which is how somebody hands the question back to the estimate. See
        # TrainingMax.replace, which is where that decision is made for every write path.
        r.post 'training-max' do
          check_csrf!
          TrainingMax.replace(@account_id, @exercise.id, r.params['pounds'],
                              train_at: r.params['train_at_percent'])
          r.redirect "/exercises/#{@exercise.id}/"
        end
        # How long you rest on this movement. #456, and here for the training max's reason
        # rather than on the edit form.
        #
        # The edit form is `Exercise.owned_by` and has to be: a name, a note and a barbell flag
        # written to a library row are one account's answers on everybody's page. A rest is not
        # that kind of fact. It is a fact about the lifter *and* the movement, so 039 keyed it
        # on the pair the way 020 keyed the training max, and it is private by construction.
        #
        # Which is what makes this route the whole of the fix. Nine of the movements the
        # reporting account trains are library rows -- Back Squat and Bench Press among them --
        # and the owner-only form meant the bell could be switched on for accessories and never
        # for the lifts where three minutes matters.
        #
        # Blank clears, which is the way back from having named a rest. See Rest.replace.
        r.post 'rest' do
          check_csrf!
          Rest.replace(@account_id, @exercise.id, r.params['seconds'])
          r.redirect "/exercises/#{@exercise.id}/"
        end
        # What you are aiming at on this movement, and when by. #308.
        #
        # Here rather than on /settings, which was the other candidate. A goal is a
        # per-movement number of exactly the kind the training max above is, and putting it
        # on a settings page would mean a movement picker to say which lift it is about --
        # a control this page does not need, because the page *is* the answer. It also puts
        # the target one paragraph from the number it is a target for, which is the
        # comparison anybody setting one is making.
        #
        # Blank clears, on the same terms as the max. See Goal.replace.
        r.post 'goal' do
          check_csrf!
          Goal.replace(@account_id, @exercise.id, r.params['pounds'], by_date: r.params['by_date'])
          r.redirect "/exercises/#{@exercise.id}/"
        end
        r.get do
          # Only the viewer's own sets for this movement, so a shared library
          # exercise never surfaces another account's logged sets.
          my_workouts = Workout.where(account_id: @account_id).select(:id)
          mine = WorkoutSet.where(exercise_id: @exercise.id, workout_id: my_workouts)
          # Eager, and eager through `with_performed_on`, because the history table below dates
          # every row by the session it came from. #572, #234.
          #
          # The table used to walk `set.workout` per row, which is a query a set -- a hundred
          # for a lifter with a hundred squat sets on record, and it grew every session. That
          # was already true before #572 and nothing noticed, because a page that is slow is
          # still a page that renders. Eager loading collapses it to one further query for
          # every session those sets belong to, however many sets that is.
          #
          # The block is what makes the second half free. #572 dates each row by
          # `performed_or_planned_on`, which reads `performed_on`, which falls back to its own
          # query when the dataset did not ask -- so a plain `eager(:workout)` would have
          # traded a query per set for a query per session and called it a fix. Asking for the
          # stamp in the eager load itself means the whole table is two queries whatever a year
          # of training put in it, which is what spec/query_count_spec.rb pins.
          #
          # The value is what Sequel hands the eager load's own dataset through before it runs,
          # so this is `with_performed_on` applied to "the workouts these sets belong to".
          @sets = mine.eager(workout: lambda(&:with_performed_on)).all
          # The completed history every number below is read from, once (#596). The headline
          # max, the estimate and the chart each used to read it for themselves -- five times a
          # request, more for a lifter with several blocks behind them -- and each on its own
          # idea of today: the first two on the server's, the chart on the lifter's. One read on
          # the lifter's today is one set of rows and one date for all of them.
          today = Clock.today(account_row[:time_zone])
          lifted = @exercise.lifted_sets(@account_id, today)
          # Whatever a percentage of this movement would resolve against today, and which
          # of the two answers that is. Nil when there is neither, which is the state the
          # page has to say something about: it is the one that makes a percentage lift
          # refuse to generate.
          @training_max = TrainingMax.for(account_id: @account_id, exercise: @exercise, on: today, lifted:)
          # The best estimate there is, which is not always one that may set a max. Since the
          # chart was extended to ten reps a movement trained in eights has a number, and that
          # number is still too far from a single to become the denominator on its own -- so
          # the page reports it and says why it is not being used, rather than behaving as
          # though it did not exist.
          @estimate = @exercise.estimated_reading(account_id: @account_id, on: today, lifted:)
          # What this movement is aiming at, if anything (#308). Nil is a state the page has
          # to say something different about rather than a number to default.
          @goal = Goal.for(account_id: @account_id, exercise_id: @exercise.id)
          # And how long this lifter rests on it, which since 039 is a fact about the pair
          # rather than about the movement -- so a library Back Squat can carry one. #456.
          @rest = Rest.for(account_id: @account_id, exercise_id: @exercise.id)
          # Everything that belongs on one axis for this lift: what was lifted, what each
          # block opened at, what the sessions imply, the goal, and the even-pace line to it
          # (#434). Built here rather than in the template because it asks the database
          # several questions and a view that queries is a view nobody can read.
          @progress = ProgressChart.of(account_id: @account_id, exercise: @exercise, today:, lifted:,
                                       max: @training_max)
          # What the last edit did to sets already logged, read once and taken out of the
          # session (#392). Delete rather than read, so a reload does not re-announce an edit
          # made ten minutes ago -- the same shape program_action uses for its refusals.
          @notice = session.delete('exercise.notice')
          view('exercises/show')
        end
      end
      r.get do
        # The same order the set form's picker is in, and for the same reason (#551): this is
        # the other screen that is a list of every movement, and a table somebody scrolls to
        # find `Overhead Press` in is no better served by insertion order than a menu is. The
        # Source column is where the library/own split shows here, which is what makes the
        # library sitting above the account's own readable rather than arbitrary.
        #
        # eager for the same reason the workouts list has one (#593): the Source column prints
        # `provenance(exercise)`, which walks `created_by_oauth_application` per row. Production
        # has 28 of 84 movements created by an assistant, so this was 28 primary-key lookups on
        # a page that is otherwise a handful. It is one query now whatever the library holds.
        # `.all` and not only `.eager`: Sequel applies an eager load in `all`, and a dataset
        # handed to a template to enumerate never reaches it -- the page would read exactly as
        # it does now and go on issuing the query per row. That is the whole failure mode this
        # file is about, so it is worth the six characters and this sentence.
        @exercises = Exercise.visible_to(@account_id).library_first_by_name
                             .eager(:created_by_oauth_application).all
        # The stated maxes, in one query rather than one per row. #411 keeps the training
        # maxes visible when the programme screens go, on the grounds that "squat at 80%" is
        # only meaningful beside "squat max 191, set 31 Aug" -- and this is the page every
        # movement is already listed on.
        #
        # Stated only, not TrainingMax.for. That one falls back to a derived reading, which
        # would be a query per movement across a library of fifty-odd, to print a number
        # nobody typed for movements nobody has trained. The stated one is the standing
        # instruction and the thing worth correcting by hand after a good session.
        @stated_maxes = DB[:account_training_maxes].where(account_id: @account_id).to_hash(:exercise_id)
        # And the rests, on the same terms and in the same one query. #456.
        @rests = Rest.all_for(@account_id)
        view 'exercises/index'
      end
    end

    r.on 'workouts' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]
      # Through workout_form rather than view, which is what carries a refused save's reason
      # onto the page. New as well as edit: a date the app cannot read is declined the same
      # way on both, and the one that silently said nothing would be the worse of the two.
      r.get('new') { workout_form('workouts/new') }
      # Every proposal the backfill left, in one column. #520, reversed.
      #
      # Above `r.on String` because that one matches any remaining segment and would take
      # "withings" for a workout id, redirect to /workouts, and leave this route dead with
      # nothing to say why.
      #
      # It reads rows the backfill already wrote and asks Withings nothing, which is the
      # property that makes it safe to open: a review screen that fetched would be one page
      # view standing on a hundred API calls.
      r.get('withings') do
        @proposals = WithingsProposals.waiting(@account_id)
        view('workouts/withings')
      end
      r.on String do |workout_id|
        # `with_performed_on` rather than a bare `Workout[workout_id]`, because three of the
        # pages under here -- the record, the gym floor screen and the set list -- now head
        # themselves with the day the session was trained rather than the day it was written
        # for (#572). That reading is `performed_on`, which answers from the row where the
        # query asked for it and otherwise goes and fetches it, so leaving this alone would
        # have added a second query to every one of those pages to learn something the query
        # that fetched the workout could have selected. One row, two correlated subqueries,
        # still one query -- and `performed?` on the record page stops issuing its own EXISTS
        # into the bargain.
        @workout = Workout.where(id: workout_id).with_performed_on.first
        # One ownership gate for every nested workout route: a workout that does
        # not exist or belongs to another account never resolves, so show, edit,
        # sets, session, and delete are all closed to a guessed id.
        r.redirect '/workouts' unless @workout && @workout.account_id == @account_id

        # Delete a workout and its sets. sets.workout_id is a non-null foreign key
        # with no cascade, so the sets have to go first. htmx swaps the row out in
        # place; without JS the plain form post redirects back to the refreshed
        # list.
        r.post 'delete' do
          check_csrf!
          Workout.db.transaction do
            WorkoutSet.where(workout_id:).delete
            @workout.delete
          end
          r.env['HTTP_HX_REQUEST'] ? '' : r.redirect('/workouts')
        end

        r.on 'sets' do
          # The list the picker is built out of, in the order #551 argues for on the model.
          # Worth knowing at this call site: the first row is what an untouched new-set form
          # posts, so this line chooses the default as well as the order.
          @exercises = Exercise.visible_to(@account_id).library_first_by_name
          # Which screen this form was opened from, so that it can put the lifter back on it.
          # #578, and `back_to_session?` carries the argument.
          r.get('new') do
            @return_to_session = back_to_session?(r)
            @just_saved = saved_set(workout_id)
            @prefill = new_set_prefill(workout_id)
            @set_notice = session.delete('set.notice')
            view('sets/new')
          end

          # The movement has to be one this account may select. The barbell flag was
          # already read through visible_exercise, but the id itself went in unchecked,
          # so a guessed id attached a stranger's private movement to a set and rendered
          # its name back wherever that set appeared.
          r.post 'new' do
            check_csrf!
            # The two redirects below used to name the form's own path and nothing else, which
            # is right for a form opened from the record page and loses the way home for one
            # opened from the gym floor screen (#578). A refusal has to bounce back to the form
            # *as it was opened* -- a mistyped rep count should not also cost the lifter the
            # link back to the session they are standing in the middle of.
            form = "/workouts/#{workout_id}/sets/new"
            form += '?return_to=session' if back_to_session?(r)
            exercise = visible_exercise(r.params['exercise_id'])
            # Said rather than silent since #631, now that the movement box can start empty: a
            # lifter who pressed Save without choosing one is told what is missing.
            unless exercise
              session['set.notice'] = 'Choose a movement for the set, then save it again.'
              r.redirect form
            end
            # required on the input is the browser's rule and stops at the browser. A post
            # with no rep count in it reaches here, and sets_measures_one_way refuses a row
            # measured in reps that has none -- unrescued, so a 500 rather than a refusal.
            # Every set this form makes is measured in reps, which is the column default.
            r.redirect form if r.params['reps'].to_s.strip.empty?

            # No timed guard on is_commanded here, unlike the edit form: every set this form
            # makes is counted in reps, which is the column default and is the same reason
            # the comment above gives for not asking about a duration.
            set_id = WorkoutSet.insert(weight: r.params['weight'], reps: r.params['reps'],
                                       exercise_id: exercise.id, is_warmup: r.params['is_warmup'] || false,
                                       is_commanded: !r.params['is_commanded'].nil?,
                                       is_completed: r.params['is_completed'] || false, workout_id:,
                                       is_barbell: exercise.barbell?)
            # Back to the gym floor screen where the form was opened from it, and to the set
            # otherwise. The set page is the right landing for a form opened from the record --
            # it is a confirmation of what was just written, and the record is one tap away --
            # and it is the wrong one for a lifter who is mid-session: its only way onwards is
            # the record, which is two taps from the session. #578.
            r.redirect "/workouts/#{workout_id}/session" if back_to_session?(r)
            # Back to the form, not to the set's own page, since #631. That page is a read-only
            # list with nowhere to go but back, so logging a 3 x 5 was three round trips through
            # it. The form comes back saying what was saved, on the same movement with the same
            # numbers, so the next set of five is one Save; and a link back to the workout for
            # when the session is all in.
            session['set.saved'] = set_id
            r.redirect form
          end

          r.on String do |set_id|
            # Marks a set done from the session view. Must come before the bare
            # r.post below, which matches any remaining path.
            r.post 'complete' do
              check_csrf!
              set = own_set(set_id, workout_id)
              r.redirect "/workouts/#{workout_id}/session" unless set

              revised = { weight: r.params['weight'], reps: r.params['reps'], rpe: r.params['rpe'] }
              revised = revised.reject { |_, value| value.to_s.empty? }
              # Three ways in, and they do not all mean the same thing.
              #
              # The primary tap is the Done button, and **it says which state it is asking
              # for** rather than asking for a flip. That is #542's stage zero, and the
              # reason is that a flip cannot be sent twice: a tap held on a phone with no
              # signal and replayed when it comes back may arrive at a server that already
              # recorded it -- the request reached the database and the response was what the
              # network ate -- and "flip it" would then un-do the set it had just saved, long
              # after the lifter stopped looking. A queue of toggles is worse still, being a
              # list of instructions whose meaning depends on the state at the moment they
              # land, which by then the poll or an assistant writing over MCP may have moved.
              # `asked_state` and `completion_to` between them make a completion a statement
              # about where the set should end up, and repeating a statement is free.
              #
              # A tap that says nothing still toggles, and that is the no-JS fallback rather
              # than a leftover: with JavaScript off there is no htmx either, Done is a plain
              # form post, and a hand-made post carries whatever it carries. The button's own
              # word for what it does is the honest reading of a request that names no state.
              #
              # A rating completes: choosing an RPE is saying you lifted it, and there is
              # nothing else an RPE could be about. That path was already absolute; what it
              # lacked was the no-op, so rating a set that was already done re-stamped the
              # completion. See completion_to.
              #
              # A corrected weight or rep count does neither. It used to complete the set,
              # which is what #215 is about: "the bar actually had 145 on it" and "I have
              # finished this set" are different statements, and the form that makes the
              # first was making the second on your behalf. That cost you the ability to fix
              # a number part-way through a lift -- correcting the load between the second
              # and third rep marked the set done and put Undo where Done had been -- and it
              # meant a mis-typed weight could only be corrected by completing the set and
              # then un-completing it. Saving a correction now leaves is_completed exactly
              # as it was, done or not, and Done stays the only thing that says done.
              #
              # Nothing here asks whether the set is a warmup, and that stays deliberate now
              # that the session screen lets a warmup be revised too. A ramp step lifted
              # differently is the same fact as a working set lifted differently -- the
              # generator writes planned_weight and planned_reps for both -- and a second
              # branch here would be two ways of recording one thing.
              # Through completion_to so the stamp and the flag are written together (#281)
              # and so a state the set is already in writes neither (#542). The empty branch
              # is the one that matters: a correction changes neither, so it must not touch
              # the stamp either -- fixing a weight two reps into a set is not doing the set,
              # and re-stamping it would move a turnaround the lifter never took.
              completion = if revised.empty?
                             set.completion_to(asked_state(r.params, set), at: asked_stamp(r.params))
                           elsif revised.key?(:rpe)
                             set.completion_to(true, at: asked_stamp(r.params))
                           else
                             {}
                           end
              # Nothing at all where nothing is being asked for, which is what a replayed tap
              # on a set the server already recorded amounts to: no columns to write, so no
              # UPDATE and no row touched. Guarded rather than left to Sequel, which raises
              # on `update()` with no arguments -- and the screen below still re-renders, so
              # the response is the panel as it stands, which is the right answer to a tap
              # asking for what is already true.
              set.update(**revised, **completion) unless revised.empty? && completion.empty?
              if r.env['HTTP_HX_REQUEST']
                session_body(workout_id, set_id)
              else
                r.redirect("/workouts/#{workout_id}/session")
              end
            end
            # Every route below resolves the set through own_set, which scopes it to
            # this workout -- and the workout is already gated to the account above. A
            # bare `WorkoutSet[id]` would match any set in the database, so a set id from
            # another account's workout would load and save here despite that gate.
            r.get 'edit' do
              @set = own_set(set_id, workout_id)
              r.redirect "/workouts/#{workout_id}" unless @set
              view 'sets/edit'
            end
            r.get do
              @set = own_set(set_id, workout_id)
              r.redirect "/workouts/#{workout_id}" unless @set
              view 'sets/show'
            end
            r.post do
              check_csrf!
              set = own_set(set_id, workout_id)
              r.redirect "/workouts/#{workout_id}" unless set

              # A set counts in reps or in seconds, never in both, and the database says so
              # outright: sets_measures_one_way refuses a row that has a rep count under
              # measure 'time' or none under measure 'reps'. This form used to post reps
              # whatever the set was measured in, so both halves of that constraint were
              # reachable from it and neither was handled -- the violation came back as an
              # unrescued exception, which is a 500 page and a lost edit. That is #213.
              #
              # A blank quantity is refused here rather than written, because a set that
              # counts nothing is not a set. It returns to the form rather than to the
              # record: the edit failed, and the place to say so is the page holding what
              # was typed.
              quantity = quantity_from(set, r.params)
              r.redirect "/workouts/#{workout_id}/sets/#{set_id}/edit" unless quantity

              # The completion goes through the helper here too (#281). This form is the one
              # place a set can be un-completed by a checkbox rather than by a tap, and a
              # cleared box that left completed_at behind would violate
              # sets_completed_at_needs_a_completion -- which reaches a person as a 500 and
              # a lost edit, which is the failure #213 was about.
              # `completion_to` rather than `completion` since #542, which fixes something
              # this form was doing quietly: saving any edit with the box left ticked
              # re-stamped completed_at, so correcting a weight an hour afterwards moved when
              # the set was lifted. A box that was ticked and stayed ticked is not a
              # completion, it is a completion being left alone.
              # `commanded?` rather than the bare parameter the two flags above use,
              # because sets_commanded_reps_are_counted refuses one on a set held for time.
              # The form does not draw the box on a timed set, so the browser cannot send
              # one -- but a post is a post, and a hand-made one landing here would violate
              # the constraint and reach a person as a 500 and a lost edit, which is #213.
              set.update(weight: r.params['weight'],
                         is_warmup: r.params['is_warmup'] || false,
                         is_commanded: commanded?(set, r.params),
                         **set.completion_to(!r.params['is_completed'].nil?),
                         **quantity,
                         **substitution(set, r.params['exercise_id']))
              r.redirect "/workouts/#{workout_id}"
            end
          end
          r.get do
            # eager rather than letting the view walk set.exercise per row, which was a
            # query a set -- twenty-three for a page of twenty. Sequel fetches the sets and
            # then every movement they point at in one further query, so the page is two
            # regardless of how long the session was. #234.
            @sets = @workout.sets_dataset.eager(:exercise).all
            view 'sets/index'
          end
        end
        # The gym floor view of a workout, as distinct from workouts/show, which
        # stays the record of one. Ownership is already guaranteed by the gate above.
        r.on 'session' do
          # Saying the session is over. The link at the top of the session screen has read
          # "finish workout" since #216 and until now only navigated to the record, which is
          # a control whose words promised the one thing this app could not do -- #218.
          #
          # Stamped rather than toggled, and it does not lock anything. Finishing is a
          # statement about the session, not a gate on editing it: a set corrected
          # afterwards is a correction to a finished session, which is ordinary. Posting
          # twice re-stamps, which is the honest answer to "I meant that time, not this one"
          # and cheaper than a confirmation nobody wants mid-gym.
          #
          # Sets left undone stay undone. That is the whole point: deciding to stop with
          # three of ten done is a thing that happens, and the record should say so rather
          # than ask whether you are sure.
          # `at=last` is the nudge answering rather than the control at the top of the screen
          # being tapped, and the difference is the whole of #410's first half. A prompt seen
          # an hour later must not add that hour to how long the session took -- which is the
          # 24h 46m reading this issue exists to fix, so producing a new version of it would
          # be a poor joke. The bare post keeps stamping now, because tapping finish is a
          # lifter standing in the gym saying they are done.
          #
          # It falls back to now where there is nothing lifted to stamp instead: a session
          # somebody opened, did nothing in, and closed is finished at the moment they closed
          # it, which is the only honest answer available.
          r.post 'finish' do
            check_csrf!
            Workout.where(id: workout_id).update(finished_at: finish_stamp(workout_id, r.params['at']))
            r.redirect "/workouts/#{workout_id}"
          end
          # How it went, written where it happened. #452.
          #
          # `workouts.note` has existed since #310 and the only way to write one was the
          # workout edit form -- a different page, reached by leaving the session. So the note
          # this column exists for, *"bar felt slow today, slept badly"*, had to survive the
          # walk to another screen and a lifter remembering to take it. It is the context that
          # explains an RPE three weeks later, and it is worth nothing if it is not written
          # within about a minute of the set that prompted it.
          #
          # Its own route rather than a field on one of the set forms, because it is about the
          # session and not about any set in it, and because those forms post on every tap.
          #
          # Answers with the note block alone rather than the whole session body: nothing else
          # on the screen changed, and re-rendering the panels would close a <details> the
          # lifter had open and scroll the horizontal lift strip back to the start.
          # One more set of a movement already in this session. #496.
          #
          # The screenshot on that issue is the last lift of a session with both sets done and
          # nowhere to put a third. "Add a set" has existed since the beginning on the workout
          # record and the set list -- two pages away from the one a lifter is holding -- so
          # deciding to do another set of skull crushers meant leaving the session, adding it,
          # and coming back. That is the same shape of friction as #365's swap, and it is worse
          # here because the decision is made between two sets rather than before them.
          #
          # **Copied from the last set of that movement rather than blank.** A third set is
          # almost always like the second: same weight, same reps, same per-side and barbell
          # flags. A blank form on a phone mid-session is five fields to fill in with chalk on,
          # and the numbers are already on the screen above it. Anything actually different is
          # then corrected with the revision box the panel already carries, which is one edit
          # rather than five.
          #
          # Not completed. The set is a plan until somebody taps Done, which is what every
          # other set on this screen means by being there, and a set that arrived already
          # ticked would make "11 of 16" a count of things nobody did.
          r.post 'add' do
            check_csrf!
            added = add_set_to_session(r.params['exercise_id'])
            next r.redirect("/workouts/#{workout_id}/session") unless added && r.env['HTTP_HX_REQUEST']

            session_changes(workout_id, @workout.session_fingerprint)
          end
          r.post 'note' do
            check_csrf!
            @workout.update(note: Workout.clean_note(r.params['note']))
            next r.redirect("/workouts/#{workout_id}/session") unless r.env['HTTP_HX_REQUEST']

            @saved = true
            render('workouts/_session_note')
          end
          # Swapping the movement a whole lift is on, in one tap. #365.
          #
          # The decision this serves is made standing at the rack: the sheet says dumbbell
          # overhead press, the dumbbells are taken, the barbell is free. Before this it
          # cost one edit per set through the set editor -- three for three sets, six on a
          # lift with a ramp -- so on 2026-09-01 three sets went into the log as the wrong
          # movement, because logging the wrong one was quicker than correcting it.
          #
          # The whole set of panels comes back rather than the one that was swapped, because
          # a swap can change the grouping: session_lifts groups consecutive sets of one
          # movement into a lift, so moving a lift onto the movement its neighbour is on
          # merges two panels into one and every position after it shifts. Re-rendering the
          # panel that was posted from would leave the rest of the screen describing a
          # session that no longer exists.
          r.post 'swap' do
            check_csrf!
            swap_session_exercise(r)
            next r.redirect("/workouts/#{workout_id}/session") unless r.env['HTTP_HX_REQUEST']

            session_changes(workout_id, @workout.session_fingerprint)
          end
          # What the screen asks every fifteen seconds: has anything changed under me.
          # #249, and the answer is usually no.
          #
          # 204 for no, which htmx reads as "do not swap" -- so the ordinary case costs one
          # small request and touches nothing on the page. That is what makes polling the
          # right shape here rather than merely the cheap one: a re-render on a timer would
          # close every open <details> and could land between a thumb and a Done button,
          # fifteen seconds after the last one, forever.
          #
          # For yes, the panels come back for #lift-panels' innerHTML -- which keeps the
          # scroller element itself, and therefore its scrollLeft -- with the progress
          # header and the poller beside them out of band. The poller has to come back
          # because it carries the digest it asked about, and one still asking about the
          # old digest would go on reporting the same news every fifteen seconds.
          # The doorbell for the poll above: open for a while, and says `changed` the moment
          # the sets differ from `since`. lib/tectonic/session_stream.rb carries the argument,
          # including why it carries no markup and why it cannot hold a thread for long. #592.
          r.get 'stream' do
            unless SessionStream.claim
              response.status = 204
              next ''
            end

            r.halt [200, { 'content-type' => 'text/event-stream', 'cache-control' => 'no-cache',
                           'x-accel-buffering' => 'no' },
                    SessionStream::Body.new(@workout, r.params['since'].to_s)]
          end
          r.get 'changes' do
            fresh = @workout.session_fingerprint
            if r.params['since'] == fresh
              response.status = 204
              ''
            else
              session_changes(workout_id, fresh)
            end
          end
          r.get do
            load_session(workout_id)
            @fingerprint = @workout.session_fingerprint
            view 'workouts/session'
          end
        end
        # Answering the proposal the record page made. #520.
        #
        # Two routes because they are two different statements, and the app must be able to
        # tell them apart forever: yes is a link between a session and a recording of it,
        # and no is a standing instruction to stop asking about this session. Neither is a
        # write to Withings -- the app reads, and the watch is the instrument.
        #
        # On the record rather than on the session screen, which is where #520 puts the
        # whole flow: the session screen is for lifting, and by the time there is anything
        # to match the lifting is done. It also means the question survives a lifter who
        # taps finish and pockets the phone, because it is on a page they come back to.
        r.on 'withings' do
          # **A yes that changed no row is not a yes**, and this used to redirect as though
          # it were. #555: `confirm` answers with how many rows it linked and the answer can
          # be nought -- a session matched from somewhere else while this page sat open, a
          # form naming an activity that has since been claimed or refused -- and throwing
          # that number away made every one of those look exactly like a success. On the
          # review list it looked like one twice over, because a queue with one fewer row on
          # it reads the same whether the answer took or whether the question went away.
          #
          # So a yes that linked something goes back where it was given, which for a sitting
          # at /workouts/withings is the list, and a yes that linked nothing goes to the
          # session's own record. That is not a punishment and it is not an error page: it is
          # the one page that can render what actually happened to this session, whether that
          # is the match somebody else made -- "Matched to your watch", with the numbers -- or
          # a question still standing because nothing has answered it. An error would claim
          # something went wrong, and nothing did; the question was simply already answered.
          r.post 'match' do
            check_csrf!
            linked = WithingsAnswers.confirm(account_id: @account_id, workout_id: @workout.id,
                                             external_id: r.params['activity'].to_s)
            # And the heart rate the watch recorded over the session, read now rather than left
            # behind a button (#656): the match is the moment it is known to be this session's.
            # One request, after the answer is saved, so a slow or silent Withings delays the
            # redirect and never the match.
            read_heart_rate(workout_id) if linked.positive?
            r.redirect(linked.positive? ? answered_from(workout_id, r.params['back']) : "/workouts/#{workout_id}")
          end
          r.post 'dismiss' do
            check_csrf!
            WithingsAnswers.dismiss(account_id: @account_id, workout_id: @workout.id,
                                    external_id: r.params['activity'].to_s)
            r.redirect answered_from(workout_id, r.params['back'])
          end
          # Asking Withings, because the lifter asked. #560.
          #
          # **The only thing in this app that calls Withings from a record page.** Until now
          # `proposal` fetched on every view inside a 24-hour window, so an ordinary page
          # render waited on somebody else's service with a ten-second timeout, and the app
          # made a request every time a session was looked at. The box said "check back in a
          # minute" and offered no control, which is #560's actual complaint: the re-fetch
          # was real and invisible, so the only button on screen was the irreversible one.
          #
          # A post rather than a get, and behind check_csrf! with the two answers above,
          # because it writes -- what Withings sends is stored -- and because a get would put
          # an API call behind a link a browser may prefetch.
          #
          # It redirects rather than rendering, which is the pattern the two answers beside
          # it already take: the record page is the address of this question, and a lifter
          # who reloads after pressing check should reload a page rather than re-ask
          # Withings. What came back is carried in the query string, the same way #529's
          # rerounded count is and for the same reason -- this app has no flash of its own.
          # It is only an outcome and never content: the page re-derives what to say from the
          # rows the fetch has just stored, so a bookmarked `?checked=answered` can claim
          # nothing that is not independently true.
          # Reading the watch's heart rate over this session's own window. #656. A post behind a
          # button for the reasons `check` below is: it calls Withings and writes what comes
          # back, and a page view must do neither (#560).
          # The one more try, for a recording whose heart rate was never read: matched before
          # reads happened on matching, or matched while Withings was not answering. #656.
          r.post 'heart-rate' do
            check_csrf!
            outcome = read_heart_rate(workout_id)&.outcome || :none
            r.redirect "/workouts/#{workout_id}?heart=#{outcome}"
          end
          r.post 'check' do
            check_csrf!
            timing = Timing.session(@workout, WorkoutSet.where(workout_id:).order(:id).all.map(&:values))
            outcome = WithingsWorkouts.check(account_id: @account_id, workout: @workout, timing:)
            r.redirect "/workouts/#{workout_id}?checked=#{outcome}"
          end
        end
        r.get('edit') { workout_form('workouts/edit') }
        r.is do
          # By id, which is the order the session was trained in, rather than by
          # exercise_id, which was the order the movements happen to sit in the exercises
          # table. Sorting by exercise_id put a workout's cards in library-id order: a
          # session written as squat, bench, row came back in whatever order those three
          # rows were created in, the same wrong order every time, and a movement the
          # account added itself sorted after every library movement no matter when it
          # was lifted.
          #
          # It also had no tiebreaker, and the view re-queries per card with the same
          # non-unique key, so the rows inside a card were unordered outright -- warmups
          # and working sets interleaved however Postgres felt, and free to change after
          # any UPDATE. uniq below keeps first-occurrence order, so the cards now come
          # out in the order the lifts were first performed.
          # Loaded once and grouped in Ruby, rather than fetched once and then re-queried
          # per card. The view used to call @sets.where(exercise_id:) inside the card loop,
          # which re-issues the query for every movement in the session, and Exercise[] for
          # the movement's own row on top of that -- thirteen queries for a session of five
          # lifts. #234.
          #
          # group_by keeps first-occurrence order, which is the same guarantee uniq gave
          # @array_of_exercise_ids, so the cards still come out in the order the lifts were
          # first performed and the rows inside each card still come out in the order #217
          # settled. The movements come as a hash, which is what the session screen has
          # always done for the same reason.
          @sets = WorkoutSet.where(workout_id:).order(:id).all
          @lifts = @sets.group_by { |set| set[:exercise_id] }
          # Ordered before it is keyed, because a Ruby hash keeps the order it was filled in
          # and the panel's "lifted a different movement" menu is drawn by walking these
          # values. It is the fourth list of movements a lifter picks from and the one they
          # are holding mid-session, so leaving it in insertion order while the set forms went
          # alphabetical (#551) would be the same complaint on the screen it matters most on.
          # An ORDER BY over eighty-odd rows costs nothing the page can measure.
          @exercises = Exercise.visible_to(@account_id).library_first_by_name.as_hash(:id)
          # How long it took, off the rows already loaded (#281). No query of its own: the
          # stamps are columns on the sets this page has just fetched, which is the whole
          # reason the timing lives on the set rather than in a table beside it.
          @timing = Timing.session(@workout, @sets.map(&:values))
          # And what the watch says about the same session, if anything (#520, #560).
          #
          # Read from rows already stored, in one indexed query, with no request to Withings
          # at all. It used to fetch here -- the upload a watch starts when a workout is
          # closed reaches their servers seconds to minutes later, so a page that asked once
          # at finish would be asking too early -- and #560 settled that lateness is a reason
          # to offer a control, not a reason to put a ten-second timeout in front of every
          # view of every session. The control is the post above.
          #
          # It answers nil for a session there is nothing to say about, which is most of
          # them, and the page draws nothing at all in that case.
          @withings = WithingsWorkouts.proposal(account_id: @account_id, workout: @workout,
                                                timing: @timing)
          # And whether the lifter has just pressed check, which is the one thing about this
          # box the stored rows cannot say. A press that Withings never answered leaves the
          # database exactly as it was, so without this the page after it would be identical
          # to the page before it -- somebody asking a question and being handed back the
          # same screen, which is the silence #560 objects to in its other half.
          #
          # Read against a fixed set rather than printed, so the only thing a hand-typed
          # value can do is say nothing.
          @withings_checked = CHECK_OUTCOMES.include?(r.params['checked']) ? r.params['checked'] : nil
          # The heart rate stored for this session's window, and what it says per set. #656.
          # Read from rows, never from Withings: the post above is how rows arrive.
          @heart = heart_for(@sets, @timing)
          @heart_read = HEART_OUTCOMES.include?(r.params['heart']) ? r.params['heart'] : nil
          view 'workouts/show'
        end
      end
      r.get do
        # Sessions still to train are read forwards and training already done is read
        # backwards, so both lists open on the workout nearest today. with_performed_on
        # answers "has anything been lifted here" *and* "when" for the whole page in the query
        # that fetches it, which is what keeps the split off the sets table.
        #
        # with_performed_on rather than with_performance since #572, and the extra column is
        # not decoration: the rows print a date apiece, and since #572 that date is the day the
        # session was trained rather than the day it was written for. Left at with_performance
        # the date would still be right and `performed_on` would fall back to a query per
        # workout to get it -- fifty sessions, fifty queries, the #234 shape arriving by the
        # back door and with nothing failing to say so. with_performed_on is with_performance
        # plus one correlated subquery, so this is the same one query it always was.
        # Read once rather than per workout: this is a query, and asking it inside the
        # partition would ask it once per row of the list it is partitioning.
        #
        # The two eager loads are #593, and they are the same mistake twice on one page. Each
        # row prints `workout.label`, which is `name || program_day&.focus`, and each row prints
        # `provenance(workout)`, which is `created_by_oauth_application&.name`. Both are
        # many_to_one walks, so both were a query per row of the list -- and a nil key answers
        # nil without asking, which is why the version of this page a lifter sees and the
        # version spec/query_count_spec.rb measured were not the same page. The fixture wrote
        # sessions with neither column set. Production has 32 of 54 carrying a program day and
        # no name, so the list cost about 36 queries against a ceiling of 10 and nothing failed.
        #
        # Two further queries whatever the list holds, and nothing about what either field means
        # changes: the focus is still read through the day, so renaming a programme day still
        # renames every session it wrote.
        @today = Clock.today(account_row[:time_zone])
        planned, history = Workout.where(account_id: @account_id).with_performed_on.with_set_count
                                  .eager(:program_day, :created_by_oauth_application)
                                  .reverse(:date).all
                                  .partition { |workout| workout.status(@today) == :planned }
        @upcoming = planned.reverse
        @workouts = history
        # And whether a backfill left questions nobody has answered. #534.
        #
        # This is the doorway to /workouts/withings, and it is here rather than in the nav on
        # purpose. The nav is seven links, deliberately, and it already wraps to two rows
        # between 640 and 840px -- an eighth pointing at a screen that is empty except for the
        # few days after a backfill would be paid for on every page by every lifter, including
        # the ones who own no watch. A link that appeared and vanished from the nav would be
        # worse again: people learn where things are by position, and an entry that comes and
        # goes moves every entry after it.
        #
        # This page is where the questions' own subject matter lives -- they are all about
        # sessions in the list below -- and it is where somebody goes on a Sunday to deal with
        # their training. A line at the top of a page's own content appearing and disappearing
        # costs nobody their bearings, because nothing else moves relative to anything a
        # lifter navigates by.
        #
        # A count rather than the list: see `waiting_count`, and 044 for the index that makes
        # it one read of a tiny partial index rather than a scan of every activity the account
        # owns. That cost matters precisely because this page has nothing to do with Withings.
        @withings_waiting = WithingsProposals.waiting_count(@account_id)
        view 'workouts/index'
      end
      r.post do
        check_csrf!
        id = r.params['id']
        # Blank is stored as null rather than as '', so "unnamed" has one spelling. It
        # also means clearing the field on an edit puts a generated session back to
        # reading its program day's focus rather than pinning it to an empty string.
        name = Workout.clean_name(r.params['name'])
        # And how it went, on the same terms (#310). Blank clears, so a note written after a
        # bad day can be taken back off without leaving an empty paragraph behind.
        note = Workout.clean_note(r.params['note'])
        # And the date, read with the format the form wrote it in rather than handed to
        # Sequel to guess at. #440, #524.
        #
        # The form posts ISO since #524, because the field is a `type="date"` input, so the
        # guess and the parse would now land on the same day. They did not before: the form
        # rendered `%m/%d/%Y` for a US reader, a string bound to a date column is typecast by
        # `Date.parse`, which reads a slashed date day-first, and a session trained on
        # 2 September posted `09/02/2026` and was stored as 9 February, dragging its completed
        # sets with it -- silently, and only when both halves are <= 12, so on the first twelve
        # days of a month and not the rest of it.
        #
        # Read through the constant rather than left to the typecast anyway. What arrives here
        # is whatever was posted, and a hand-made post or a browser with no date input owes us
        # nothing; `Date.parse` is the thing that took a string it could not read as intended
        # and returned a confident answer, and it is no safer for the form having improved.
        #
        # Refused rather than stored as something else, on the same terms as the time zone on
        # the settings form: a value the app cannot read is a reason to decline the save and
        # say so, not a reason to write a different date and let every reader afterwards
        # believe it. Refused rather than raised, too -- an unrescued typecast reaches a lifter
        # as a 500, which reads as the server having fallen over rather than as the app
        # declining what was typed.
        date = Workout.date_from_form(r.params['date'])
        if id.empty?
          back_to_the_form('/workouts/new') unless date
          workout_id = Workout.insert(account_id: @account_id, date:, name:, note:)
          r.redirect "/workouts/#{workout_id}/"
        else
          # Rescheduling is owner-only. This route sits outside the nested ownership
          # gate, so without the account in the filter any id would match and any
          # account's workout could be moved to a new date.
          @workout = Workout.where(id:, account_id: @account_id).first
          r.redirect '/workouts' unless @workout
          # After the ownership gate, and sent back by the session's own id rather than by the
          # one that was posted: the refusal names a page, and a page named out of raw params
          # is a redirect somebody else writes.
          back_to_the_form("/workouts/#{@workout.id}/edit") unless date
          @workout.update(date:, name:, note:)
          r.redirect "/workouts/#{@workout.id}/"
        end
      end
    end
  end

  # Where a login lands, in the order a lifter would ask for it: a session written for today
  # and not yet finished, failing that the record of the one that was, failing that the
  # calendar, failing that the first-run page.
  #
  # The calendar on a day with nothing written, since #635. It was the new-workout form, which
  # is #92's rule ("if you have done a workout, show you the form for a new one") from before
  # sessions were written ahead. Now an assistant writes a block and the week's sessions exist
  # before anybody lifts, so on a rest day the useful answer is the week -- what was trained,
  # what is coming and when -- and a blank form was a question nobody had asked. Logging an
  # unplanned session is still one tap from the calendar. An account with nothing at all still
  # lands on /start, which is what it is for.
  #
  # A session still to do opens on the gym floor screen rather than on the record page.
  # Someone opening the app on a day they have training written is about to lift, and the
  # session screen is the one that ticks a set off with a thumb; the record page reads a
  # session back afterwards and is a tap away from the session anyway. That argument covers
  # a session nobody has started and a session halfway through alike, which is why neither
  # is asked anything further here: a plan written for this evening and a session with four
  # of ten sets ticked are both somebody about to lift.
  #
  # A session the lifter has *finished* is the one case it does not cover, and #523 is what
  # that cost. Train in the morning, tap finish, come back at nine at night, and the app put
  # you back on the gym floor -- where the nudge, finding a session that last moved eleven
  # hours ago, asks whether you are still training. Every login, for the rest of the day.
  # That bar is silenced in `quiet_cue` below, which is the half that put the words on the
  # screen; this is the half that took you to the screen, and it is wrong on its own terms
  # too -- a page whose whole job is ticking sets off with a thumb is the wrong answer to
  # "show me the day I have already trained".
  #
  # This used to say that a finished session "is not treated as a different case", because
  # "fully completed" is a guess about intent -- a set can still be added, corrected or
  # rated -- and answering it would mean asking the sets table on every login. Both halves
  # of that are still true and neither is what is asked here. `finished_at` is not a count
  # of ticked sets; it is the lifter saying they were done, through the control at the top
  # of the session screen (#218), through the nudge, or through SessionClose.sweep on the
  # line above -- which has already backfilled the sessions they walked away from by the
  # time this line chooses. It is a column on a row already in hand, so nothing is being
  # second-guessed and no second table is being asked. And the record page is still one tap
  # from the session screen, so adding, correcting or rating a set afterwards costs exactly
  # the tap the old note was protecting.
  #
  # Two sessions may share a day and nothing forbids it, so an unfinished one wins over a
  # finished one whatever their ids: a lifter who trained this morning and has an evening
  # session written is coming back for the evening session, not for the morning's record.
  # Where two are unfinished the lowest id wins, the one written first, which is the order
  # a day is written in. Where every one is finished the last to be finished wins -- the
  # session they have just come out of, rather than whichever was typed first.
  #
  # `date` is a timestamp, so the day is compared on the cast the way Calendar.by_day does.
  # An equality against a Time would match nothing but a session written at exactly midnight.
  #
  # The day's sessions are fetched rather than picked by a LIMIT 1, because the rule above
  # reads all of them and a day holds one or two; two LIMIT 1 lookups would be two round
  # trips to answer a question one row set answers. `mine.empty?` is still a query of its
  # own and still only runs on the days the first comes back with nothing: one query could
  # answer both by ordering on "is this dated today", but no index covers that expression,
  # so it would sort every workout the account owns.
  # Whether to ask the browser where this account is, decided once at sign-in. #349.
  #
  # The browser knows the answer exactly -- `Intl.DateTimeFormat().resolvedOptions().timeZone`
  # returns an IANA name, which is precisely what the column stores -- and the lifter does not
  # have to be asked a question they did not come here to answer. A settings page that opens on
  # a dropdown of forty zones is a worse first impression than one that is already right.
  #
  # A session flag rather than a check on every request: the layout renders the detector when
  # this is set, and the endpoint clears it. That is one query per sign-in instead of one per
  # page, and it fires exactly once.
  #
  # Only when nothing is set. Detection fills a blank; it never overrules an answer somebody
  # gave, because the case for that is somebody who set their home zone deliberately and is now
  # signing in from an airport.
  def ask_the_browser_for_the_zone(account_id)
    session['zone.detect'] = true unless Clock.zone_of(account_id)
  end

  # Whether a new set starts out ticked as done. #630.
  #
  # The first thing /start recommends is logging a session already trained, and the box came up
  # clear -- so a lifter recorded a real session, #304's rule filed it as planned (or, dated
  # yesterday, missed), and no chart appeared. The rule stays; what the form suggests changes.
  # A set on a session dated today or earlier, on the lifter's own calendar, is most likely one
  # being recorded after the fact, so the box starts ticked, and a future date is a plan and
  # starts clear. Either way it is a box they can see and untick.
  #
  # Not from the session screen, which has its own way of saying a set is done -- the Done
  # button, tapped at the rack -- and where a set added mid-session has not been lifted yet.
  def lifted_by_default?
    return false if @return_to_session || !@workout

    @workout[:date].to_date <= Clock.today(account_row[:time_zone])
  end

  # Where Cancel on the consent screen sends the browser: back to the assistant, saying no.
  #
  # It dropped `state`, which RFC 6749 §4.1.2.1 requires on an error response whenever the
  # request carried one. A client that checks it -- the point of state is to tie a response to
  # the request that asked for it -- has to treat an answer without it as a forgery and show
  # its own error, so pressing Cancel read as the connection breaking rather than as a no. The
  # description and the state are rodauth-oauth's own template's, and the query is joined
  # rather than appended so a redirect URI that already has one stays well-formed.
  def consent_cancel_url
    uri = URI(rodauth.redirect_uri)
    answer = { 'error' => 'access_denied',
               'error_description' => 'The resource owner or authorization server denied the request' }
    state = rodauth.param_or_nil('state')
    answer['state'] = state if state
    uri.query = [uri.query, URI.encode_www_form(answer)].compact.join('&')
    uri.to_s
  end

  # Which assistant an account signed up to connect, from the consent screen it was sent to
  # sign in for (#628). Nothing where the saved page was anything else, or there was none.
  def remember_the_connection(account_id, saved)
    return unless saved.to_s.start_with?('/authorize')

    client_id = Rack::Utils.parse_query(URI(saved).query.to_s)['client_id']
    application_id = client_id && DB[:oauth_applications].where(client_id:).get(:id)
    DB[:accounts].where(id: account_id).update(signed_up_connecting_id: application_id) if application_id
  end

  # The assistant's name, while the connection it came here for has still not been made: the
  # note on /start is for somebody who confirmed their address somewhere the consent screen
  # could not follow, and it has nothing to say once they have connected.
  def connecting_to(account_id)
    application_id = DB[:accounts].where(id: account_id).get(:signed_up_connecting_id)
    return nil unless application_id
    return nil unless DB[:oauth_grants].where(account_id:, oauth_application_id: application_id).empty?

    DB[:oauth_applications].where(id: application_id).get(:name)
  end

  # `today` is the lifter's, not the server's (#349). This is the first of the three failures
  # that issue names and the one it leads with: on the server's clock a lifter in New York at
  # 8:30pm Monday is already on Tuesday, so this missed Monday's session and dropped them on
  # the new-workout stub instead of the session they had come back to finish.
  def login_destination(account_id)
    on = Clock.today_for(account_id)
    # Sessions exist without anybody asking (#411). Here because this runs on the way in, and
    # "there is no session for today" is a thing to find out never rather than on a Monday
    # morning. Idempotent and cheap once a week has been written, and it cannot raise.
    ProgramSchedule.ensure_ahead(account_id, on)
    # And nothing closes a session (#410). Beside the line above because it is the same kind of
    # housekeeping and runs in the same two places: a session left open from an afternoon
    # nobody came back to gets the ending it should have had, stamped at its own last set
    # rather than at this moment. Like the line above, it cannot raise into the request.
    SessionClose.sweep(account_id)
    mine = Workout.where(account_id:)
    today = mine.where(Sequel.cast(:date, :date) => on).order(:id).all
    return todays_screen(today) if today.any?
    return '/' unless mine.empty?

    '/start'
  end

  # Which of today's sessions a login opens, and on which screen. Its own method because it is
  # the one judgement on this path -- everything around it is housekeeping and fallbacks -- and
  # because the argument for it is the long comment above rather than these four lines.
  def todays_screen(sessions)
    unfinished = sessions.find { |workout| !workout.finished? }
    return "/workouts/#{unfinished.id}/session" if unfinished

    "/workouts/#{sessions.max_by(&:finished_at).id}"
  end

  # Where the connector actually is, built from the two values the app is served under rather
  # than written out. #359: a documentation page naming an endpoint by hand is a page that goes
  # quietly wrong the day either moves, and the address is the one thing on it that has to be
  # exactly right.
  # `resource_url` rather than the two halves joined again: that is already the canonical
  # address of this MCP resource -- the value an access token must carry in `aud` and the one
  # the discovery document advertises -- so a page telling a reader where to point their client
  # is naming the same thing, and joining the halves a second time is how the two come to
  # differ. It falls back to the canonical origin where MCP_PUBLIC_BASE_URL is unset, which is
  # every environment except production and none where anybody is reading this page.
  def mcp_endpoint_url
    MCP::Config.public_base_url ? MCP::Config.resource_url : "#{CANONICAL_ORIGIN}#{MCP::Config.endpoint_path}"
  end

  # The one-click add link, which until a directory listing exists is the whole of this app's
  # distribution (#359). It opens Claude's add-connector dialog prefilled, needs no listing and
  # no review, works on every plan including Free, and works signed out -- the reader signs in
  # and lands back on the dialog.
  def claude_connector_url
    'https://claude.ai/customize/connectors?modal=add-custom-connector' \
      "&connectorName=#{CGI.escape('tectonic plates')}&connectorUrl=#{CGI.escape(mcp_endpoint_url)}"
  end

  # This page's address on the canonical origin, which is what rel=canonical wants and
  # what the share cards should have been naming all along.
  #
  # The path and not the query string. The four pages reachable without a login --
  # /welcome, /about, /login, /create-account -- take no parameters, and every page that
  # does take them is behind one, so a query string here could only ever be something a
  # crawler appended. A trailing slash is dropped for the same reason the domain is
  # settled: slash_path_empty means /welcome and /welcome/ are the same page, and a
  # canonical that says otherwise is the split it exists to close.
  def canonical_url
    path = request.path.chomp('/')
    "#{CANONICAL_ORIGIN}#{path.empty? ? '/' : path}"
  end

  # Which day this account's week begins on, as a Date#wday number. #189.
  #
  # Read off the account row rather than through a model, because there is no Account model
  # in this app -- Rodauth owns that table and works it as a dataset -- and inventing one for
  # a single integer would be a larger thing than the integer. The fallback is
  # belt and braces: the column is NOT NULL with a default, so a row without one cannot
  # exist, and a reader that assumes so anyway costs nothing.
  def week_starts_on
    account_row[:week_starts_on] || 0
  end

  # The signed-in account's row, which rodauth already loaded to find @account_id and which
  # carries every per-account setting a page reads: zone, week start, time budget, bar. #603
  # measured /settings fetching that one row five times in a request, a column at a time by
  # primary key, one helper after another. Read off what is already in hand instead.
  #
  # Every route that writes to the row redirects rather than rendering, so there is no request
  # in which this could be read after a change it predates. The lookup is for a caller that set
  # @account_id without going through rodauth's session.
  def account_row
    @account_row ||= rodauth.account || DB[:accounts].where(id: @account_id).first || {}
  end

  # What comes back from a tap: the panel of the lift that was tapped, and the progress
  # header beside it, out of band.
  #
  # This used to be the whole of #session-body -- every panel, every row, every form --
  # which on a five-lift session was 127KB, 96% of the page, to tint one row and fill one
  # slice of the bar. #235.
  #
  # Two fragments rather than one because a tap changes exactly two things, and they are
  # not adjacent: the row is inside a panel and the bar is in the sticky header above the
  # scroller. hx-swap-oob is what lets one response carry both -- htmx puts the panel where
  # the form aimed it and finds the header by its id. Sending only the panel would leave the
  # bar disagreeing with the rows underneath it, which is worse than sending too much.
  #
  # The panel is the unit rather than the row, and that is a deliberate stopping point. It
  # is already a thing in the markup with an id and a partial; the row is not, and the
  # warmup and working-set rows are still two templates that differ in more than the RPE
  # form. Splitting those is a design change about what a row is, and folding it into a
  # payload fix would be smuggling one thing inside another. This is where the structural
  # win is anyway: the scroller survives the swap, so the offset restore in session.erb goes.
  # What comes back when the poll finds the session has moved: every lift panel, for
  # #lift-panels' innerHTML, with the progress header and a re-armed poller beside them out
  # of band. #249.
  #
  # Every panel rather than the one that changed, because unlike a tap this does not know
  # which one did -- and a set an assistant deleted can take a whole lift off the screen,
  # which no per-panel swap could express. Rendering the lot is what the first paint does
  # anyway, and it happens only when something actually changed.
  def session_changes(workout_id, fingerprint)
    load_session(workout_id)
    panels = session_lifts.each_with_index.map do |lift, position|
      render('workouts/_lift_panel', locals: { lift:, position: })
    end
    # "Session updated" rather than a set sentence: the poll fires because something moved
    # elsewhere -- an assistant's write, or another tab -- and which row it was is not
    # something this response knows. The count is the part that is always true and always
    # useful. #336.
    panels.join + render('workouts/_progress', locals: { oob: true }) +
      announce("Session updated. #{session_count_phrase}") + session_poll(workout_id, fingerprint)
  end

  # The poller, re-armed with what the session now is. Every response that changes this
  # screen ends with one, because the digest it was rendered with is stale the moment
  # anything lands -- and a poller still asking about the old digest would find it changed
  # on every poll from then on and swap the panels every fifteen seconds forever. #249.
  #
  # The fingerprint is a parameter because the changes route has already worked it out and
  # a tap has not.
  def session_poll(workout_id, fingerprint = @workout.session_fingerprint)
    render('workouts/_session_poll', locals: { workout_id:, fingerprint:, oob: true })
  end

  def session_body(workout_id, set_id)
    load_session(workout_id)
    tapped = @sets.find { |set| set[:id] == set_id.to_i }
    session_panel(tapped) +
      render('workouts/_progress', locals: { oob: true }) +
      announce(tap_sentence(set_id)) +
      # What the rest timer offers, for the set this tap just finished (#281). Out of band
      # like the progress header, and for the same reason: the timer lives outside the
      # swapped region so a countdown survives the next poll, and this is how the server
      # tells it a set was finished and what this lifter usually takes after one.
      rest_cue(tapped) +
      # And when the session last did anything, which is what decides whether to ask if it is
      # over (#410). Unlike the rest cue this is about the session rather than the tap, so it
      # is sent on every tap including an un-complete -- taking a mis-tap back is still the
      # session moving, and the quiet has to restart from it.
      quiet_cue(oob: true) +
      # Re-armed with what this tap just made true. Without it the poller would still be
      # asking about the digest the page loaded with, find it changed -- by the lifter, a
      # second ago -- and swap every panel back over the top of their own tap. #249.
      session_poll(workout_id)
  end

  # The one lift panel a tap changes, which is the panel holding the set that was tapped.
  # Position zero where the set cannot be found, which is what the fallback always meant:
  # render something coherent rather than raise on a row that has gone.
  def session_panel(tapped)
    id = tapped && tapped[:id]
    position = session_lifts.index { |lift| lift.any? { |set| set[:id] == id } } || 0
    render('workouts/_lift_panel', locals: { lift: session_lifts[position], position: })
  end

  # What this lifter usually takes between sets of one movement, asked once per movement per
  # request. #281, and the query itself moved to Tectonic::Turnarounds by #408 when the
  # generation-time budget check -- which is outside the web app entirely -- became its second
  # caller.
  #
  # The rest timer needs this for the one set a tap just finished; the session estimate needs
  # it for every unlifted set on the page, which on a five-movement day is the same query five
  # times over and once more on every Done. The cache belongs to the lambda, so it is per
  # request, and it is cleared with the rest of the session in load_session.
  def usual_turnaround(exercise_id)
    @turnarounds ||= Turnarounds.lookup(@account_id)
    @turnarounds.call(exercise_id)
  end

  # How long the rest of this session should take, or nil when there is none of it left.
  # #408.
  #
  # What remains rather than the whole session, which is the number a lifter mid-session
  # actually wants: the elapsed clock beside it already says how long they have been here,
  # and the two together answer "am I going to make it". At the start of a session nothing
  # is completed, so this is the whole day's estimate, which is what the issue asks for.
  #
  # Nil on a finished session, where an estimate of nothing left would be a zero on the line
  # rather than the absence of a question.
  def remaining_estimate
    @remaining_estimate ||= begin
      pending = @sets.reject { |set| set[:is_completed] }
      pending.empty? ? :none : SessionLength.estimate(pending.map(&:values), turnaround: method(:usual_turnaround))
    end
    @remaining_estimate == :none ? nil : @remaining_estimate
  end

  # Why this session ran the way it did, or nil on one with nothing to explain. #409.
  #
  # Memoised for the same reason the estimate above is: the record page asks once, but asking
  # is a handful of turnaround lookups and there is no reason to do them twice if the template
  # grows a second reader.
  #
  # The active span comes from @timing rather than being worked out again here, so the line
  # that says why a session ran long and the line above it that says how long it ran cannot
  # come to different conclusions about the same session.
  def session_diagnosis
    return nil unless @timing && @timing[:overall]

    @session_diagnosis ||= SessionDiagnosis.of(@sets.map(&:values), turnaround: method(:usual_turnaround),
                                                                    active_seconds: @timing[:active])
  end

  # When this session last did anything, and how long to leave it before asking whether it is
  # over. #410. Both computed server-side off the rows already in hand, so the browser is
  # told a fact rather than asked to work one out.
  #
  # Silent on a session the lifter has already finished, which is the half of #523 that puts
  # the words in the issue's title on the screen. The cue is filled in on first paint on
  # purpose -- a session left open this morning should be asked about the moment it is opened
  # rather than twenty minutes later -- but that stamp is read by a clock that only knows how
  # long ago the last set was, so a session finished at nine in the morning and looked at
  # again that evening raised the bar the instant it painted: "Nothing logged for 11h. Still
  # training?" There is nothing to ask. `finished_at` is the lifter having already answered
  # this exact question, by the control at the top of the screen, by this very bar, or by
  # SessionClose.sweep answering on their behalf six hours after they left -- and a question
  # re-asked after it has been answered reads as an app that was not listening.
  #
  # Empty rather than unrendered, and the same emptiness a session with nothing lifted gets:
  # the script reads the cue on every swap and draws nothing when it carries no stamp, so one
  # shape of "there is no quiet to measure here" covers both without the bar's markup or its
  # clock having to learn a second case.
  #
  # It stays silent for the rest of that session, including after a correction tapped into a
  # finished session -- which is deliberate. The bar exists to close sessions nobody closed;
  # this one is closed. A lifter who carries on training says so with the finish control at
  # the top of the screen, which re-stamps, and that is a statement rather than a guess.
  def quiet_cue(oob: false)
    rows = @sets.map(&:values)
    last_at = (SessionClose.ends_at(rows)&.to_f unless @workout.finished?)
    render('workouts/_quiet_cue',
           locals: { oob:, last_at:, quiet_after: SessionClose.quiet_after(rows) })
  end

  # Where the nudge sits: above the rest timer, because the two are true at once. A rest that
  # ran to twenty minutes is exactly when this fires, and covering the countdown at that moment
  # would hide the one thing on screen explaining why it is asking.
  def nudge_offset
    return 'bottom-[calc(2.75rem+3.5rem+env(safe-area-inset-bottom))]' if @sets.any?(&:ratable?)

    'bottom-[calc(3.5rem+env(safe-area-inset-bottom))]'
  end

  # When a session ended, according to who is saying so. #410.
  #
  # The nudge answers with the last set that was ticked off, because the lifter is answering a
  # question about a silence rather than reporting where they are standing. The control at the
  # top of the screen answers with now, because tapping it is a statement made in the gym.
  #
  # Now is also the fallback for a session with nothing lifted in it: opened, nothing done,
  # closed. There is no last set to reach for and the moment of closing is the only honest
  # answer left.
  def finish_stamp(workout_id, asked)
    return Time.now unless asked == 'last'

    rows = WorkoutSet.where(workout_id:).select(:is_completed, :completed_at).all.map(&:values)
    SessionClose.ends_at(rows) || Time.now
  end

  # What went well in this session, named specifically. #410, the second half.
  #
  # Only on a finished session, which is what the first half of that issue exists to produce:
  # "on finish, lead with what went well" is a sentence about a moment, and until something
  # closed a session there was no moment to lead with.
  #
  # Memoised like the diagnosis above it, and for a sharper reason: this asks the database once
  # per movement in the session, which is worth doing once and not twice.
  def session_summary
    return [] unless @workout.finished?

    @session_summary ||= SessionSummary.of(@workout, @sets.map(&:values), @timing)
  end

  # What a press of check is allowed to have concluded. #560.
  #
  # The outcome travels back from the post in the query string, so the value reaching the
  # record page is whatever is in a URL -- a hand-typed one, a stale bookmark, a link
  # somebody was sent. Matched against this rather than rendered, so the worst an invented
  # value can do is leave the line off. `nothing_to_ask` is absent on purpose: it is a real
  # outcome of `WithingsWorkouts.check` and it has nothing to report, so it falls through to
  # the same silence as a value nobody recognises.
  CHECK_OUTCOMES = %w[answered unreachable].freeze
  HEART_OUTCOMES = %w[stored none unreachable absent].freeze

  # Read the watch's heart rate for a session whose recording has just been matched. #656.
  def read_heart_rate(workout_id)
    timing = Timing.session(@workout, WorkoutSet.where(workout_id:).order(:id).all.map(&:values))
    HeartRates.read_for_match(@account_id, workout_id, WithingsWorkouts.interval(timing))
  end

  # Whether any set on the record page has a heart rate figure, which is what decides whether
  # the column is drawn at all. #656.
  def heart_figures?
    @heart && @heart[:per_set].values.any? { |figure| figure[:peak] }
  end

  # "142, down to 108": the peak around a set and the lowest point before the next. Blank where
  # the set has no reading near it, and only the peak for the last set, which has no next.
  #
  # A peak off one or two readings -- a set in the stretch before the watch noticed the workout
  # -- says how many, so it does not pass for one measured every few seconds.
  def heart_label(set_id)
    figure = @heart[:per_set][set_id]
    return '' unless figure&.dig(:peak)

    peak = figure[:peak].to_s
    peak += " (#{readings_phrase(figure[:peak_readings])})" if figure[:peak_readings] < 3
    figure[:low_before_next] ? "#{peak}, down to #{figure[:low_before_next]}" : peak
  end

  def readings_phrase(count) = "#{count} reading#{'s' unless count == 1}"

  # What the record page shows about heart rate: the readings' dense stretch and the figures
  # per set, or nil where there is no window or nothing stored and no connection to ask. #656.
  def heart_for(sets, timing)
    window = WithingsWorkouts.interval(timing)
    return nil unless window

    readings = HeartRates.within(@account_id, window)
    # Offered only where a matched recording's read is still owed; a session with no match has
    # no recording to read, and the ordinary match has already been read.
    owed = WithingsConnection.connected?(@account_id) && HeartRates.still_to_read?(@workout[:id])
    return nil if readings.empty? && !owed

    { readings: readings.length, dense: HeartRates.dense_stretch(readings), session: window,
      per_set: HeartRates.per_set(sets, readings), owed: }
  end

  # Where an answer about a session sends the lifter next.
  #
  # Back to the record by default, which is where the question was asked and where the
  # matched numbers now are. The one exception is the review list, which exists to answer a
  # backfill's worth of proposals in a sitting: sending somebody to a record page after each
  # one would make a hundred answers into a hundred trips back.
  #
  # A fixed pair of destinations and never the parameter itself, because a redirect that
  # echoed a value from a form is an open redirect -- a link that posts here with a back of
  # `https://elsewhere.example` would bounce the lifter off the app, still logged in.
  def answered_from(workout_id, back)
    back.to_s == 'proposals' ? '/workouts/withings' : "/workouts/#{workout_id}"
  end

  # How many other sessions are waiting on the same question. #534.
  #
  # The record page's prompt and the review list are one queue seen from two angles, and
  # until this line nothing on either side said so. A lifter answering a backfilled session
  # from its record had no way to know that ninety more were waiting somewhere else, so the
  # obvious reading of the prompt -- one stray question about one old Tuesday -- was wrong in
  # a way the page itself made plausible.
  #
  # Called from the proposal branch of the partial and nowhere else, which is what keeps it
  # off the record pages that have nothing to ask: most of them. A memo rather than a
  # variable set in the route for the same reason -- the route would pay for it on every view
  # of every session, to answer a question the page usually does not put.
  #
  # `except` is the session on screen. Its own proposal is in the waiting set when a backfill
  # left it, so counting it would say "1 other" to somebody looking at the only one left.
  def questions_elsewhere
    @questions_elsewhere ||= WithingsProposals.waiting_count(@account_id, except: @workout[:id])
  end

  # The Withings activity this session has been matched to, or nil. #520.
  #
  # One reading of `@withings[:state]`, in one place, because more than one thing on the
  # record page asks it and two copies of `@withings && @withings[:state] == :matched` is two
  # places for one of them to drift and start reporting the watch's numbers under the app's
  # labels.
  #
  # It used to be asked in four spots -- the length, the two ends, the block under them, and
  # whether to say "from your taps" -- and since #571 the first, second and fourth of those
  # no longer ask at all: the session's length and its two ends are the lifter's own taps
  # whether or not a match exists, so the lines that draw them have nothing to decide. What
  # is left is the block that reports what only the watch knows, which is the whole of what a
  # confirmed match is worth now. Keeping the reader here rather than folding it back into
  # that one branch costs nothing and leaves the state read in one spelling.
  def matched_activity
    return nil unless @withings && @withings[:state] == :matched

    @withings[:activity]
  end

  # How long the watch's own recording ran. Not how long the session took. #571.
  #
  # That distinction is the whole of #571 and it used to be the opposite. This number was
  # printed as the session's length, on #520's rule that "where the two disagree about how
  # long a session took, the watch is right and the app should say so rather than quietly
  # keeping its own figure". The reporting account's own data is the counter-example: the
  # watch began six minutes after their first completed set and kept recording for
  # twenty-five minutes after their last, and on the following morning bracketed a shorter,
  # later window than the session entirely. Both rows carry `attrib = 7`, which is Withings'
  # own code for a detected activity a lifter later confirmed rather than one they started on
  # the watch deliberately. So this answers a question about the watch, and the question about
  # the session is answered by Timing, matched or not.
  #
  # #571 read a second tell beside that one -- that neither row came back with an
  # `effduration` -- and **that half was wrong**, though it pointed the same way. #586
  # established against Withings' own OpenAPI document that there is no such field and never
  # was: the name appears nowhere in it, and `Withings::WORKOUT_FIELDS` no longer asks for it.
  # An absence nobody could have filled is not evidence about a watch. `attrib` is, it is
  # documented, and it is the one this paragraph now rests on.
  #
  # Still the wall-clock span, and now for a simpler reason than the one that used to sit
  # here. The old argument was about comparability -- this figure stood beside the app's
  # overall span and had to mean the same thing, and a second vendor's opinion about what
  # counted as work would have put two unexplained trims on one line. It no longer stands
  # beside anything, and there is no such opinion on offer anyway. What is left is that the
  # two ends are what the page prints either side of this number and what the overlap was
  # computed from, so the span between them is the only figure a reader can check.
  def watch_seconds
    activity = matched_activity
    return nil unless activity

    (activity[:ended_at] - activity[:started_at]).to_i
  end

  # What the watch's heart rate sensor saw, as a phrase, or nil where it saw nothing. #571.
  #
  # **The average, and the range around it.** Two sessions can both average 128 bpm and be
  # nothing alike: one that ran 61 to 164 was intervals with real recoveries between them,
  # one that ran 120 to 136 was a grind that never let go. The average alone cannot tell them
  # apart and all three numbers have been stored since 042. Until #571 the low was written on
  # every fetch and shown on no page, which is the cheapest kind of waste -- and heart rate is
  # now the entire case for confirming a match at all, so this is the place to spend the line.
  #
  # **Absent rather than zero, at every level.** A watch with no optical sensor, or one worn
  # loosely over a sleeve, reports no heart rate whatever, and "0 bpm average" under a session
  # would be a reading where there is a gap. The range hangs off both ends being present for
  # the same reason: a range with one end is not a range, and a low on its own is a number
  # nobody asked for. A max with no min keeps the older wording, because a peak is a claim
  # that stands up by itself.
  #
  # A phrase rather than the three numbers and the branching inline in the view, because this
  # is three conditions deep and an ERB tag that deep is one nobody will read before changing.
  def watch_heart_rate
    activity = matched_activity
    average = activity && activity[:hr_average]
    return nil unless average

    low = activity[:hr_min]
    high = activity[:hr_max]
    return "#{average} bpm average, #{low} to #{high}" if low && high

    high ? "#{average} bpm average, #{high} peak" : "#{average} bpm average"
  end

  # A cue with nothing in it, which is what a tap that did not finish a set sends. Named
  # rather than written inline so the two branches below are plainly the same element.
  NO_REST_CUE = { oob: true, set_id: nil, at: nil, seconds: nil, kind: nil, movement: nil }.freeze

  # What the timer should count, and where the number came from. #281.
  #
  # **A rest somebody named, or nothing.** The block's own rest wins, then the movement's; a
  # set with neither offers the plain durations and no suggestion at all.
  #
  # The measured median used to sit underneath as a third answer, labelled "your usual", and
  # it is gone. It was standing in for a prescription in an app that had no way to write one
  # -- #456 gave movements their own rest, and once a lifter can say "three minutes on squats"
  # the app describing their habit back to them is a worse answer to the same question. It also
  # described the habit including the sessions where they rushed it: the 632s, 9s and 343s
  # between working bench sets on 2026-09-01 average to a number nobody should train to.
  #
  # `usual_turnaround` is untouched, because the timer was never its only caller: the session
  # time estimate (#408) reads it for every unlifted set on the page, and how long a session
  # will take is a question about the habit, which is exactly what a median is good for.
  #
  # The kind still travels with the number, because a suggestion that ring itself has to say
  # it came from the programme rather than from the app. There is only one kind now, and
  # keeping the pair means the button and the timer go on agreeing about what may ring.
  #
  # **The movement's rest counts as prescribed** (#456) rather than as a kind of its own. The
  # rule for what may ring is "a length somebody named", and this one is named by the lifter on
  # the movement's own page. That is the same sort of claim as a block writing five minutes
  # between singles, and it was the median that was the different sort.
  #
  # Below the block's own rest because a block is more specific than a movement: a week of
  # heavy singles may want five minutes on the squat a lifter usually rests three for, and the
  # session being run is the better answer to what this set wants.
  #
  # Read here rather than copied onto sets at generation, which is what makes it reach the
  # sessions already written instead of only the ones written next.
  def rest_suggestion(set)
    prescribed = set[:planned_rest_seconds] || movement_rest(set[:exercise_id])
    prescribed ? [prescribed, 'prescribed'] : [nil, nil]
  end

  # The rest this lifter takes on this movement, as its own page says.
  #
  # Off @rests since 039, which the session route loads in one query beside @exercises, so a
  # dozen set rows still ask the database nothing. It moved off the movement because a library
  # Back Squat sits on every account's page and could therefore hold nobody's rest -- see
  # lib/tectonic/rests.rb.
  def movement_rest(exercise_id)
    @rests[exercise_id]
  end

  # The out-of-band element that tells the rest timer a set was just finished. Rendered on
  # every tap, carrying nothing when the tap un-completed a set or only corrected one --
  # taking a mis-tap back is not the end of a set, and neither is fixing the weight two reps
  # in, so neither may offer a rest.
  #
  # The set as well as the stamp, because the stamp alone is not identity. Two sets finished
  # inside the same second -- a superset tapped off in one motion, or an assistant writing
  # both -- carry the same whole second, and a timer keyed on that would ignore the second
  # tap and go on counting the first set's rest. Sub-second precision for the matching
  # reason: a set un-completed and re-completed straight away is the same set with a new
  # stamp, and that is a new rest.
  def rest_cue(set)
    return render('workouts/_rest_cue', locals: NO_REST_CUE) unless set && set[:is_completed] && set[:completed_at]

    seconds, kind = rest_suggestion(set)
    render('workouts/_rest_cue', locals: {
             oob: true, set_id: set[:id], at: set[:completed_at].to_f,
             seconds:, kind:, movement: @exercises[set[:exercise_id]]&.name
           })
  end

  # Where the rest timer sits, which depends on whether the RPE footer is under it. Both are
  # fixed to the bottom of the screen, so the timer has to clear the footer's collapsed
  # height -- min-h-11, 2.75rem -- plus whatever the phone's home indicator takes.
  #
  # A helper rather than a local assigned in the template, because erb_lint hands each ERB
  # tag to rubocop as a program of its own and a local set in one tag and read in the next
  # is an undefined variable to it. The same reason session_lifts lives here.
  def rest_timer_offset
    return 'bottom-[calc(2.75rem+env(safe-area-inset-bottom))]' if @sets.any?(&:ratable?)

    'bottom-[env(safe-area-inset-bottom)]'
  end

  # The live region, sent back beside whatever else a response is swapping. #336.
  def announce(message)
    render('workouts/_announcement', locals: { message:, oob: true })
  end

  # What a tap did, in the order the screen says it visually: what was acted on, what it
  # now is, and where that leaves the session. "Back Squat, 225 lb x 5. Done. 3 of 12 sets."
  #
  # Read back off the row after the write rather than assembled from what was posted, so a
  # correction saved without completing announces the new load and still says "not done" --
  # which is #215's distinction, and the one a lifter most needs confirmed without looking.
  def tap_sentence(set_id)
    set = @sets.find { |row| row[:id] == set_id.to_i }
    return session_count_phrase unless set

    "#{accessible_name(set)}. #{set[:is_completed] ? 'Done' : 'Not done'}. #{session_count_phrase}"
  end

  def session_count_phrase
    "#{@sets.count { |set| set[:is_completed] }} of #{@sets.length} sets."
  end

  # A set named the way a screen reader has to hear it: which movement, and what is on the
  # bar. #338 -- a twelve-set session carries twelve buttons whose accessible name is "Done"
  # and up to sixty whose name is a single digit, with nothing in any of them saying which
  # set they act on. The visible text stays one word or one digit, which is what makes the
  # screen usable with chalk on; only the announced name grows.
  #
  # Not named set_description: rubocop reads a set_ prefix as a writer for `description`.
  def accessible_name(set)
    "#{@exercises[set[:exercise_id]]&.name}, #{load_label(set)}"
  end

  # Everything the session screen renders from, which is the same two reads whether the
  # whole page is being drawn, one panel is coming back after a tap, or the poll has found
  # something moved. Insertion order is program order: warmups then working sets, lift by
  # lift in the position the program gave them.
  # Every set of one movement in this session moved onto another. #365.
  #
  # Sets already marked as lifted stay exactly where they are, which is #364's rule reaching
  # the browser: a completed set records a movement that was performed, and a swap says a
  # different one was. The same line update_workout_exercise draws over MCP, drawn here in
  # the WHERE clause -- so the two paths cannot come to disagree about what a swap may
  # touch.
  #
  # The movement has to be one this account may select, through visible_exercise, for the
  # reason the new-set form already goes through it: an id posted by hand would otherwise
  # attach a stranger's private movement to a set and render its name back.
  #
  # A post naming nothing usable changes nothing and is not an error. The form cannot
  # produce one, the screen is re-rendered either way, and a session mid-lift is the wrong
  # place to answer a malformed post with a page about it.
  def swap_session_exercise(request)
    from = request.params['from_exercise_id'].to_s
    into = visible_exercise(request.params['exercise_id'])
    return if from.empty? || into.nil? || from == into.id.to_s

    # Through WorkoutSet.moved_to, so this and the two MCP paths cannot come to different
    # conclusions about what moving a set means (#406). The new movement's barbell flag comes
    # with it; the old movement's prescription does not, because a planned weight belonging to
    # a lift this row is no longer is worse than no prescription at all.
    WorkoutSet.where(workout_id: @workout.id, exercise_id: from, is_completed: false)
              .update(**WorkoutSet.moved_to(into))
  end

  # One more set of a movement already in this session, copied from the last one of it. #496.
  #
  # Scoped to sets already in this workout rather than to any movement the account can see.
  # This is "another set of *that*", reached from a panel that is already on the screen, and a
  # set of something not in the session is what the movement swap and the record page are for.
  # It also means the row being copied always exists.
  #
  # The last one rather than the heaviest or the first: a lifter adding a set is continuing
  # from where they are, and the numbers they are looking at are the ones just tapped.
  #
  # Nil where there is nothing to copy, which the route reads as "do nothing and reload" --
  # an exercise_id that is not in this session is a stale panel or a hand-made request, and
  # neither should be answered with a set.
  def add_set_to_session(exercise_id)
    last = WorkoutSet.where(workout_id: @workout.id, exercise_id:, is_warmup: false)
                     .order(:id).last
    return nil unless last

    WorkoutSet.create(workout_id: @workout.id, exercise_id: last.exercise_id,
                      weight: last.weight, reps: last.reps, measure: last.values[:measure],
                      duration_seconds: last.duration_seconds, is_warmup: false,
                      is_barbell: last.is_barbell, is_per_side: last.is_per_side,
                      is_commanded: last.is_commanded, is_completed: false)
  end

  def load_session(workout_id)
    @sets = WorkoutSet.where(workout_id:).order(:id).all
    # Ordered for the same reason the route above orders it: the swap menu in each panel is
    # this hash walked in order, and #551 is about which order that is.
    @exercises = Exercise.visible_to(@account_id).library_first_by_name.as_hash(:id)
    # The rests this lifter has named, in one query beside the movements, on the same argument
    # #234 makes for loading those once: a set row asks for its rest and a session has a dozen
    # of them. Keyed by movement, which is what movement_rest reads (#456, 039).
    @rests = Rest.all_for(@account_id)
    # Both memos below are answers *about* @sets, so they are wrong the moment it is
    # reloaded. A tap loads the session again after applying itself, and an estimate left
    # over from before would still be counting the set that was just ticked off (#408).
    @remaining_estimate = nil
    @turnarounds = nil
    # How long this has been going, worked out from rows already in hand (#281). Set here
    # rather than in the session route because all three render paths go through this one --
    # the first paint, the panel a tap sends back, and the poll -- and the progress header
    # is rendered by every one of them. Set in the route instead, a tap would render a
    # header with no clock on it and the number would vanish on the first Done.
    @timing = Timing.session(@workout, @sets.map(&:values))
  end

  # The sets of a lift nobody has lifted yet, which is exactly what a swap may move (#365)
  # and therefore what the swap control counts and hides itself over.
  #
  # A helper rather than a local in the template, for the reason session_lifts below is one:
  # erb_lint hands each ERB tag to rubocop as a program of its own, so a local assigned in
  # one tag and read in the next reads as a useless assignment. The panel asks three times
  # over -- once to decide whether to draw the control, once for the count, once for the
  # plural -- which is a reject over a handful of rows already in memory.
  def unlifted(lift)
    lift.reject { |set| set[:is_completed] }
  end

  # The session's sets grouped into the lifts they belong to. Insertion order is program
  # order, so consecutive sets of one movement are one lift and a movement that comes
  # round twice in a session is two.
  #
  # **Except a set added afterwards**, which joins the lift its movement already has. A set
  # appended to a session lands at the end by id, so without this a third clamshell logged
  # over MCP -- or "Add a set" pressed on any panel but the last -- opened a second panel
  # of the same movement after unrelated ones, and the lifter saw clamshells in two places
  # with "6 of 7" counted against neither (the issues list, item 3). What tells the two
  # cases apart is the plan: the generator writes planned_weight or planned_reps onto every
  # set it prescribes, and a set added afterwards carries neither. So a run of sets with no
  # plan on any of them folds into the last earlier lift of the same movement, and a movement
  # the programme itself lists twice -- heavy bench, then back-off bench -- stays two.
  #
  # It lives here rather than in the template it serves because the panel row asks for it
  # three times over -- once to walk it, then inside every panel to number that panel and
  # to draw a dot per lift -- and a local assigned in one ERB tag and read in the next is
  # an offence to erb_lint, which hands each tag to rubocop as a program of its own.
  def session_lifts
    @session_lifts ||= @sets.chunk_while { |before, after| before[:exercise_id] == after[:exercise_id] }
                            .each_with_object([]) { |run, lifts| place_run(lifts, run) }
  end

  # Where one run of consecutive sets goes: onto the end of an earlier lift of the same movement
  # where the run carries no plan, and into a lift of its own otherwise. See session_lifts.
  def place_run(lifts, run)
    unplanned = run.none? { |set| set[:planned_weight] || set[:planned_reps] }
    home = unplanned && lifts.rfind { |lift| lift.first[:exercise_id] == run.first[:exercise_id] }
    home ? home.concat(run) : lifts << run
  end

  # A set is only reachable through a workout the logged in account owns, so a set
  # id belonging to someone else's workout does not resolve.
  def own_set(set_id, workout_id)
    return nil unless @workout && @workout.account_id == @account_id

    WorkoutSet.where(id: set_id, workout_id:).first
  end

  # Whether the new-set form was opened from the gym floor screen, and should therefore put
  # the lifter back on it. #578.
  #
  # **A fixed word rather than a path, and that is the whole of the design.** The obvious
  # shape for this is a `return` parameter carrying where to go, and the obvious shape is an
  # open redirect: a link mailed to somebody, or a form posted from another origin, would then
  # choose which page this app sends them to after a write it performed on their behalf. There
  # is exactly one screen that needs bringing back to, so the parameter names it rather than
  # describes it, and anything else the request says is ignored rather than followed.
  #
  # Read from params rather than from the referrer, which is the other obvious shape and is
  # worse in a quieter way: a browser that suppresses Referer -- a privacy setting, a
  # redirect chain, an iOS reader mode -- would silently land the lifter somewhere else, and
  # the failure would look like the app forgetting rather than like a header not arriving.
  def back_to_session?(request) = request.params['return_to'].to_s == 'session'

  # The movement a form asked for, looked up only among the ones this account may
  # select -- its own and the shared library -- so a set can never be pointed at a
  # stranger's private exercise. nil when the id is absent, not a number, or not
  # visible, which every caller reads as "no movement was chosen". Base ten because
  # Integer() would otherwise read a zero-padded id as octal and reject "08".
  def visible_exercise(exercise_id)
    id = Integer(exercise_id.to_s, 10, exception: false)
    Exercise.visible_to(@account_id).where(id:).first if id
  end

  # The exercise change a set edit is asking for, as attributes to merge into the
  # update, or nothing when the movement is unchanged or is not one this account may
  # choose. A substituted set takes the new movement's barbell flag with it, because
  # plate math left behind by the lift that was swapped out is worse than none; an
  # unchanged movement keeps the flag it has, so a program's per-lift override -- a
  # machine variation of a barbell movement, say -- survives an edit to the weight.
  def substitution(set, exercise_id)
    exercise = visible_exercise(exercise_id)
    return {} if exercise.nil? || exercise.id == set.exercise_id

    { exercise_id: exercise.id, is_barbell: exercise.barbell? }
  end

  # What a set counts, as the pair of columns it is stored in, or nil when the form left it
  # blank. A set measured in seconds writes duration_seconds and a null reps; one measured
  # in reps writes reps and a null duration_seconds. Both columns are always named, so
  # neither can keep a stale value from the measure the set used to be in.
  #
  # The measure is the set's own rather than anything the form sends. It is a property of
  # the movement -- a plank is held and a squat is repped -- so it is not a thing an edit to
  # the weight is allowed to change, and taking it from the row means a posted field cannot
  # push a set into a state its exercise disagrees with.
  def quantity_from(set, params)
    typed = set.timed? ? params['duration_seconds'] : params['reps']
    return nil if typed.to_s.strip.empty?

    set.timed? ? { duration_seconds: typed, reps: nil } : { reps: typed, duration_seconds: nil }
  end

  # Which state a Done tap is asking the set to end up in. #542.
  #
  # The session screen's form is rendered from the row, so it already knows whether its
  # button says Done or Undo, and this is that word said out loud in a hidden field. It is
  # the shape the set edit form has always used -- #516 found the fix twelve lines below the
  # bug -- and bringing the two into agreement is the whole change rather than an invention.
  #
  # A request that says nothing falls back to the toggle, which is the no-JS path and the
  # hand-made post. So does a request carrying a word this does not know: choosing between
  # "done" and "not done" on the strength of a string nobody defined is how a set comes to be
  # un-done by a typo, and the toggle is at least the behaviour the button's own word
  # describes. Only the two exact spellings the form sends are read as a statement.
  #
  # `on` is deliberately not among them, though that is what the edit form's checkbox sends.
  # A checkbox says true by being present and false by being absent, and absence is already
  # spoken for here -- it is the toggle -- so this field cannot be a checkbox and must not
  # pretend to be one.
  def asked_state(params, set)
    { 'true' => true, 'false' => false }.fetch(params['is_completed'].to_s) { !set.is_completed }
  end

  # When a completion says it happened, which is not always when it arrives. #542.
  #
  # A tap made at 18:04 in a basement and flushed at 18:40 on the street happened at 18:04,
  # and stamping it on arrival would record the phone finding signal rather than the lifter
  # finishing a set. That is exactly the distinction health data draws between measured_at
  # and created_at, and getting it wrong here is quieter: every turnaround Timing computes
  # from these stamps would describe the outage.
  #
  # Milliseconds since the epoch, because that is what `Date.now()` hands the script on the
  # phone and it carries no timezone to be read wrongly. An ISO string would arrive with the
  # phone's offset on it, or without one, and the difference between those two is hours.
  #
  # **The server's own clock wins wherever the offered one is not believable**, and the
  # window is a day. A phone's clock is wrong more often than anybody expects -- a dead
  # battery, a timezone typed in by hand -- and the two implausible readings fail in
  # different ways: a stamp from the future sorts above every honest set and hands Timing a
  # negative rest to explain, and one from last year would file a set into a session that
  # ended months ago. Falling back rather than clamping is what create_set already says about
  # a session typed up in the evening: where we cannot know when it was lifted, the honest
  # thing to record is when we heard about it, and to say so.
  #
  # A day rather than an hour because the queue survives the tab being closed, so a session
  # that lost signal at the end and was reopened the next morning still replays with the
  # right stamps. Beyond that, a tap is no longer something anybody is standing in the
  # middle of.
  STAMP_REACH = 24 * 60 * 60
  def asked_stamp(params, now: Time.now)
    offered = Float(params['completed_at'].to_s, exception: false)
    return now unless offered

    at = Time.at(offered / 1000)
    at.between?(now - STAMP_REACH, now) ? at : now
  end

  # Whether the set edit form is saying this set was done under meet commands. #311.
  #
  # The `timed?` half is the whole reason this is a method rather than the `params['x'] ||
  # false` that is_warmup gets one line above. Commands bracket a rep -- start, press, rack
  # -- so a movement held for time has no rep for them to bracket, and
  # sets_commanded_reps_are_counted refuses the row outright. The form already declines to
  # draw the box on a timed set, so no browser can produce this; a hand-made post can, and
  # the violation would arrive as an unrescued exception, which is a 500 page and a lost
  # edit. Refusing it here costs one `&&` and turns it into the box being ignored.
  def commanded?(set, params)
    !params['is_commanded'].nil? && !set.timed?
  end

  # The rack the signed-in account lifts on, read once per request: the session view asks
  # for a plate breakdown per set, and every one of them wants the same inventory.
  def equipment
    @equipment ||= Equipment.for_account(@account_id, account: account_row)
  end

  # What to hang on each side of the bar, as plain text. Blank only for work that is not
  # on a bar at all, where there are no plates to talk about.
  #
  # A weight the rack cannot make used to come back blank too, and blank is the one thing
  # this line must never be. A lifter reads no plate math as nothing to put on, which on a
  # 124 lb prescription is both wrong and dangerous, and it goes silent at exactly the
  # moment the arithmetic is hardest -- mid-session, one-handed, with a rack that does not
  # divide evenly. So a weight that will not load names the nearest one that will, and a
  # weight under the bar, which no plates can reach downwards, says that in words.
  #
  # The text is plain on purpose: no markup and no entities, so the caller can escape it.
  #
  # "each side" after a breakdown, since #638: "2×45" on a 225 set is two 45s on each side,
  # and read as two in total it is 135 -- which a lifter at their first session, phone in one
  # hand, had nothing but arithmetic to settle. Not "per side", which this screen already spends
  # on a rep count taken one limb at a time (#502); two meanings for one phrase a line apart is
  # the confusion this was meant to end.
  def plate_label(set)
    return '' unless set[:is_barbell]

    breakdown = equipment.per_side(set[:weight])
    return each_side(breakdown) if breakdown

    weight, nearest = equipment.closest(set[:weight])
    return "closest #{weight}: #{each_side(nearest)}" if nearest

    "lighter than your #{weight_label(equipment.bar_weight)} lb bar"
  end

  def each_side(breakdown)
    breakdown.empty? ? Plates.label(breakdown) : "#{Plates.label(breakdown)} each side"
  end

  # The set this form just saved, for the line that says so, or nil. Taken out of the session
  # so a reload does not announce it again. Scoped to the workout the form is for. #631.
  def saved_set(workout_id)
    id = session.delete('set.saved')
    id && WorkoutSet.where(id:, workout_id:).first
  end

  # What a new set's form starts on. #631.
  #
  # The movement box had nothing marked, so the browser showed the first option -- Anderson
  # Squat, alphabetically -- and a lifter who typed a weight and saved had logged it. It starts
  # on the movement last logged in this session now, with that set's weight and reps, which is
  # the next set of a 3 x 5 before anything is typed. A session with nothing in it yet starts on
  # the lifter's most recent movement from any session, with no numbers; and an account that
  # has never logged a set starts on nothing, which the form marks as a choice still to make.
  def new_set_prefill(workout_id)
    last = WorkoutSet.where(workout_id:).order(:id).last
    return { exercise_id: last.exercise_id, weight: last.weight, reps: last.reps } if last

    recent = WorkoutSet.where(workout_id: Workout.where(account_id: @account_id).select(:id))
                       .order(Sequel.desc(:id)).get(:exercise_id)
    { exercise_id: recent }
  end

  # What the number on a dumbbell row is the weight *of*. #502.
  #
  # A stored dumbbell weight is one dumbbell: `dumbbell_totals` stands the handle where a bar
  # stands and loads both its ends, so a movement done with a pair is two of that number in
  # hand. The row never said so, which left "39 lb × 8 per side" to be read as the pair, as
  # one hand, or as a total divided between the legs -- three readings, two of them wrong by
  # exactly 2x, and nothing on the screen to settle it.
  #
  # Only where the movement has been *told* how many. `is_barbell` being false is not the
  # same claim as "this is a dumbbell" -- a cable stack, a machine and a weighted pull-up are
  # all on that side of the line -- and "two dumbbells" on a lat pulldown would be a new wrong
  # answer in place of a silence. An unanswered movement is assumed to be a pair for the plate
  # math (Equipment::DEFAULT_DUMBBELLS) and stays quiet here, because an assumption made to
  # keep a prescription loadable is not a fact to read back to the lifter at the rack.
  #
  # Said on a single too, though "one at 39 lb" looks like it adds nothing: it is the answer
  # to the same question, and a line that appears only on pairs would leave every single-arm
  # row ambiguous in precisely the way this is here to fix.
  def dumbbell_label(set)
    return nil if set[:is_barbell] || !loaded?(set[:weight])

    count = @exercises[set[:exercise_id]]&.dumbbell_count
    return nil unless count

    "#{count == 1 ? 'one' : 'two'} at #{weight_label(set[:weight])} lb"
  end

  # A yes-or-no fact about a set, as a box that is ticked or left empty. Three screens
  # show the same two facts -- the workout record and the set list in a pair of columns,
  # the set detail in a definition list -- and each had answered in a vocabulary of its
  # own: "Warmup set" against "No", `Warmup` against an em dash, `Yes` against `No`. None
  # of those can be scanned down a column the way boxes can, an em dash reads as "not
  # applicable" rather than as no, and none says which state is the plain one.
  #
  # The glyph is hidden from a screen reader and the answer spelled out beside it: an
  # empty box means nothing read aloud on its own, and "ballot box" is what a reader
  # otherwise announces for the one that matters least.
  #
  # The word is the caller's rather than this helper's, so that what is read aloud
  # answers the heading it sits under: `completed` where a column is headed Completed,
  # `done` where the set list heads the same column Done to fit a phone.
  #
  # This is one of the few things here that really is markup, so its call sites are
  # `<%==`. The question is escaped on the way in, since a caller could one day pass one
  # that came from an account rather than from the literals its call sites hold today.
  def ticked(flag, question)
    "<span aria-hidden=\"true\">#{flag ? '&#9745;' : '&#9744;'}</span>" \
      "<span class=\"sr-only\">#{h(flag ? question : "not #{question}")}</span>"
  end

  # A set's prescription, as one phrase. Work carrying no external load has no weight
  # rather than a weight of zero, so there is nothing to put before the reps: "0 × 10" was
  # the workaround this replaced and read as a mistake, and an empty cell where a number
  # belongs reads as missing data rather than as the movement being the load.
  #
  # The times sign is the character and not `&times;`, because this phrase is a value that
  # a template escapes rather than markup a template trusts. An entity written here would
  # arrive on the page spelled out rather than drawn.
  # The unit is said out loud, which is #280. This read "20 × 8", and in a gym "20 x 8" is
  # a notation people already use for something else: twenty sets of eight is nonsense, but
  # "3 x 8" means three sets of eight everywhere lifting is written down, so a reader
  # arriving at a two-number phrase reaches for sets-and-reps first. On a heavy barbell
  # lift the size of the number settles it -- nobody does 225 sets -- and on the accessory
  # work where the first number is small, nothing did.
  #
  # "lb" on the load rather than "reps" on the count, because it disambiguates with three
  # characters on the number that is already the largest thing on the row, and because it
  # is the half a lifter is reading at arm's length. Unweighted work still says "8 reps" in
  # full, since there is no load in front of it to make the count obvious.
  #
  # `positive?` rather than truthiness, which is #321: **zero is truthy in Ruby**, so a set
  # whose weight was stored as 0 took the weighted branch and printed "0 lb × 10" -- a load
  # nobody is being asked to lift, on the row a lifter reads at arm's length. 025 nulls the
  # zeros and `create_set` no longer writes one, so this guard is the belt to that braces:
  # a zero arriving from anywhere reads as the absence it means.
  # "commanded" rides on the end of the phrase rather than sitting in a badge of its own,
  # for the reason "per side" does: it is part of what the set *is*, and a lifter reading
  # the row at arm's length is reading one line rather than scanning for markers. It is also
  # what keeps the screen and the connector saying the same thing -- MCP's `load_phrase`
  # builds the same sentence, and a session described one way by the app and another way by
  # an assistant is the mismatch #306 and #320 were both about. #311.
  def load_label(set)
    "#{"#{weight_label(set[:weight])} lb × " if loaded?(set[:weight])}" \
      "#{quantity_label(set)}#{' per side' if set[:is_per_side]}" \
      "#{' commanded' if set[:is_commanded]}"
  end

  # What the sheet said, in the same words as what was lifted. The two sit one line apart
  # on a changed set -- "75 lb × 5" over "planned 95 × 5" -- and a unit on only one of them
  # reads as two different kinds of number rather than as the same number twice. #280.
  def planned_label(set)
    "#{"#{weight_label(set[:planned_weight])} lb × " if loaded?(set[:planned_weight])}#{set[:planned_reps]}"
  end

  # Whether there is a load to name. One predicate rather than the same guard spelled three
  # times, because the three labels differing about what counts as a weight is exactly how
  # "0 lb × 10" got onto a row whose own quantity method would have said "10 reps".
  def loaded?(weight)
    !weight.nil? && weight.positive?
  end

  # A weight as somebody would write it on a sheet: 225 rather than 225.0, and 137.5 as
  # itself. #141 widened the three weight columns to numeric(7, 2), so Sequel hands back a
  # BigDecimal, and every site that printed the value raw would otherwise show 0.225e3 --
  # which is the correct rendering of a BigDecimal and no use at all to a lifter.
  #
  # Plates.numeric rather than a format string, because it is already the answer to this
  # exact question for the plate breakdown and gives the same 2.5 in both places. It reads
  # the denominator, which BigDecimal, Float, Integer and Rational all answer.
  def weight_label(weight)
    weight && Plates.numeric(weight)
  end

  # Where Withings sends a browser back, which has to be the same string in the redirect out
  # and in the exchange afterwards -- the provider compares them and refuses a mismatch.
  #
  # Built from MCP_PUBLIC_BASE_URL because that is where the app already keeps its own public
  # address, rather than from the incoming request: a request arriving on a preview host would
  # otherwise ask Withings to redirect somewhere the registration does not list. #472.
  def withings_redirect_uri
    "#{MCP::Config.public_base_url}/withings/callback"
  end

  # An import report, in the shape that survives the round trip through the session. #558.
  #
  # The session's serializer is JSON, so a hash of symbols goes in and a hash of strings
  # comes out -- `{ state: :refused }` is read back as `{ 'state' => 'refused' }`. A view
  # written against the symbols would compare a string to a symbol, find nothing equal, and
  # render the branch for a state that never happened: no error, no missing page, just a
  # press that says nothing. So the conversion happens here, once, where the report is
  # written, rather than being a rule every reader has to remember.
  #
  # Nils are dropped: `more` is nil when there is no more history to fetch, and a key whose
  # value is nil is the same to the view as a key that is absent, while carrying it costs a
  # cookie four bytes it has no use for.
  def carried(report)
    report.compact.to_h { |key, value| [key.to_s, value.is_a?(Symbol) ? value.to_s : value] }
  end

  # Back to settings with something to say. The callback has four outcomes a lifter can tell
  # apart -- connected, refused, unreachable, and a state that did not match -- and saying
  # them out loud is the difference between a page that worked and a page that silently did
  # nothing. #472.
  def settings_with(notice)
    session['settings.notice'] = notice
    request.redirect '/settings'
  end

  # The New workout and Edit workout pages, which are the same form twice and now have the
  # same thing to say when a save is declined. #440.
  #
  # The notice is read out of the session and deleted in the same breath, which is the shape
  # the exercise page settled on: a refusal is about the save that just happened, and one
  # still on the page after a reload describes nothing the lifter can see.
  def workout_form(page)
    @notice = session.delete('workout.notice')
    view(page)
  end

  # Declining a save and sending the lifter back to the form holding it. #440.
  #
  # Only a date reaches here, and only a date nothing can read as one -- the input is
  # `required` and is a native date control since #524, which posts ISO or posts nothing, so
  # in practice this is a hand-made post, an autofill, or a browser old enough to have
  # rendered that input as a text box and let somebody type into it in their own locale. That
  # last one is exactly the case worth refusing out loud rather than guessing at, because
  # guessing is what put sessions seven months from where they were trained.
  #
  # A redirect rather than a re-render, which costs the name and the note that were typed
  # alongside the bad date. Re-rendering would keep them, at the price of the form learning to
  # read its values back out of params -- a second source for every field on it, to save
  # retyping on a path a lifter whose browser draws the picker cannot reach. The same trade
  # the settings form makes, and `settings_with` above is the same three lines.
  #
  # The sentence names the order the app reads rather than the order the box shows, and those
  # are two different things now: a `type="date"` input displays in the device's locale, so
  # telling somebody what their own phone is already drawing would be no help to the one
  # person who can see this -- whose browser is not drawing it.
  def back_to_the_form(page)
    session['workout.notice'] =
      'That date could not be read, so nothing was saved. Dates go in as year-month-day, ' \
      "like #{Date.today.strftime(Workout::FORM_DATE)}."
    request.redirect page
  end

  # A session-length budget off a form, or nothing. #446.
  #
  # The range is Bounds::BUDGET_MINUTES, which the MCP tools already hold this to -- the two
  # describe the same quantity and a bound that differed between them is a bound somebody
  # eventually crosses.
  #
  # Out of range becomes nil rather than being clamped, on the same terms as the per-movement
  # rest: clamping 600 to 300 would store a number nobody typed and then judge every session
  # against it. Blank is how the warning is turned off and stays sayable.
  def clean_budget(raw)
    minutes = raw.to_s.strip
    return nil if minutes.empty?

    MCP::Tools::Bounds::BUDGET_MINUTES.cover?(minutes.to_i) ? minutes.to_i : nil
  end

  # What a rack actually builds, said back to the lifter. #439.
  #
  # The issue asks for "the entered value echoed back as a sentence the lifter can check",
  # because every number on that form is ambiguous in the same way -- a handle weight could be
  # one or the pair, and "four 2.5 lb plates" could be four plates or four pairs. The two
  # readings differ by a factor of two, which is enough to make every generated weight wrong,
  # and nothing on the page would have looked any different.
  #
  # A range rather than a restatement of what was typed, which is the stronger check: it is
  # derived through the same enumeration the generator prescribes from, so a lifter who
  # misread "pairs" sees a top end twice what their rack can do. Restating the input would
  # only prove the app can echo.
  def loadable_range(totals)
    return nil if totals.empty?

    "#{weight_label(totals.min)} lb to #{weight_label(totals.max)} lb"
  end

  # The same for the dumbbells, which have to say it twice since #439 gave a movement a
  # count: one handle reaches up the whole shelf and a matched pair reaches half as far,
  # because every plate size has to go on both ends of both handles. Seeing the two numbers
  # side by side is the quickest way to understand why a dumbbell bench is prescribed lighter
  # than a single-arm row off the same plates.
  def dumbbell_ranges(equipment)
    return nil unless equipment.adjustable_dumbbells?

    { one: loadable_range(equipment.dumbbell_totals(1)),
      pair: loadable_range(equipment.dumbbell_totals(2)) }
  end

  # What assuming a pair costs a movement nobody has said the count for. #439.
  #
  # `dumbbell_count` shipped with a deliberate default -- two, because every weight loadable
  # on a pair is loadable on a single, so an unanswered movement comes out a little light
  # rather than impossible. That is still the right way to break the tie, and it is also
  # silent, and on a real rack the silence has a ceiling: a 4 lb handle with pairs of 10, 5
  # and 2.5 reaches 79 lb as a single and stops at 39 as a pair, every size having to go on
  # both ends of both handles.
  #
  # So a movement parked at the top of that shelf is not necessarily at the lifter's limit.
  # It may be at the top of a range that exists only because a question went unanswered --
  # which is invisible from the session screen, where the prescription simply stops moving.
  #
  # Reported rather than guessed at. Which hand the dumbbell is in is a fact only the lifter
  # has, and the app's job is to make the cost of not saying visible, not to pick (#263).
  #
  # Nothing to say for a fixed rack: `dumbbell_totals` is empty there, both counts fall back
  # to the same assumed increment, and answering would move no weight at all.
  #
  # And nothing to say until the ceiling is actually reached, which is what keeps this from
  # being a prompt on every movement that is not on a bar. `is_barbell` being false is not the
  # same claim as "this is a dumbbell" -- a cable stack, a machine and a weighted pull-up are
  # all on that side of the line, and there are 29 such movements on one account here. Asking
  # a lat pulldown how many dumbbells it takes is the same kind of wrong answer the session row
  # refuses to give, and it would bury the one page where the question matters.
  #
  # Reaching the top of the pair's shelf is the signal, because it is the moment the assumption
  # starts costing something. Below it both answers prescribe the same weights and the question
  # is idle; at it, the number stops moving and looks from the session screen exactly like a
  # movement that has stopped progressing.
  #
  # **Measured on what was prescribed rather than on what was lifted**, which is the correction
  # this needed. Read off `weight` it fired on a lat pulldown carrying 85 lb -- a machine, on
  # the wrong side of `is_barbell` like every cable, with twelve hand-logged sets, *no* generated
  # sets and no program lift anywhere. Telling it nothing above 39 lb can be prescribed is true
  # only in the sense that nothing is prescribed for it at all, which makes it noise on a page
  # where the question cannot arise.
  #
  # `planned_weight` is the generator's own handwriting: it is set on a row this app wrote and
  # nil on one a person typed. So the note now appears exactly where the ceiling is binding on
  # something the app is actually choosing a number for, and stays quiet on the movements a
  # lifter only records.
  #
  # Off @sets, which the route has already loaded, so this costs no query.
  def unanswered_dumbbells(exercise)
    return nil unless exercise.unanswered_dumbbells?
    return nil unless (ranges = dumbbell_ranges(equipment))

    ceiling = equipment.dumbbell_totals(2).max
    prescribed = @sets.filter_map { |set| set[:planned_weight] }.max
    return nil unless prescribed && prescribed >= ceiling

    ranges.merge(ceiling: weight_label(ceiling))
  end

  # What a set counts. Seconds read as a duration rather than as a rep count, because
  # "60 reps" of a plank is not what anybody held.
  #
  # The count says "reps" out loud where something follows it, which is #502. "per side" at
  # the end of "39 lb × 8" postmodifies the whole phrase, so it reads as the weight being
  # per side as well as the count -- and on a pair of dumbbells that misreading is *nearly*
  # right, which is what makes it hard to catch: 39 lb really is what one hand holds, and
  # the pair is 78. Naming the unit binds the qualifier to the number it belongs to, and
  # every number in the phrase then wears one: lb on the load, reps on the count.
  def quantity_label(set)
    return "#{set[:duration_seconds]}s" if set[:duration_seconds]
    return "#{set[:reps]} reps" if set[:is_per_side] || !loaded?(set[:weight])

    set[:reps].to_s
  end

  # The window the volume page is asked for, or a block's worth. Only the offered
  # windows are honoured: the number reaches a date subtraction, and a query string is
  # not a place to let someone choose how many weeks of anybody's training to sum.
  def volume_window(requested)
    window = requested.to_i
    Volume::WINDOWS.include?(window) ? window : Volume::DEFAULT_WEEKS
  end

  # The shape an action button is drawn in: one corner radius, one shadow, one keyboard
  # ring. Written out by hand it came to three radii, two shadow states and two focus
  # rings across two dozen sites -- and thirteen of those buttons named no focus style at
  # all, so tabbing onto one drew Firefox's own blue ring on a lime button, blue being a
  # colour this brand does not otherwise contain. rounded-md and shadow-sm are what the
  # majority already had; outline-lime-500 is what ten of the twelve that named a ring at
  # all had already chosen, the other two being welcome.erb's, a step darker at lime-600
  # for no reason anyone wrote down. One of the odd ones out was not even a decision:
  # `shadow-ss`, which Tailwind does not define and therefore silently ignored, left the
  # Save on the exercise form flat while every other Save in the app was raised.
  #
  # Shape only. Fill stays at the call site because lime and sky mean different things
  # there, and so does padding, because several of these were sized for a thumb on
  # purpose and folding them in here would quietly undo that. The white secondary button
  # is left alone: it is already the same at all seven of its sites, which is what this
  # is trying to make the primary one.
  # The shape of a text input, on the same terms button_style settles a button: one radius,
  # one border treatment, one ring, one focus ring, and nothing about size or colour. #239.
  #
  # Fifteen distinct input class strings were written out across views/, and two of them
  # were the same control at two radii -- rounded-md on four fields and rounded-lg on three
  # more that differ from those four in nothing else. Nobody chose that. It is the drift
  # button_style was introduced to stop, whose own note records "the rounded-lg both copies
  # carried was one of the three radii that helper exists to settle".
  #
  # rounded-md rather than rounded-lg, and that is a real decision rather than a coin toss:
  # button_style is rounded-md, so a field and the button under it now share one radius
  # instead of disagreeing by two pixels. Eleven call sites move, which is visible if you
  # look for it and is the point.
  #
  # Size and padding stay at the call site, exactly as they do for buttons. Several of these
  # inputs are 44px tall for a thumb and several are w-14 because a rep count is two digits
  # wide, and folding either in here would quietly undo a decision somebody made on purpose.
  # sky-800 rather than lime-500, which is #333. A focus indicator is the only thing telling
  # a keyboard user where they are on the page, and lime-500 is 1.98:1 on white where WCAG
  # asks 3:1 -- a pale halo you have to look for. sky-800 is 7.56:1, and it is the colour
  # this app already reaches for when something has to be seen: the Done button, the focus
  # ring below, and every Save.
  #
  # ring-inset stays. On a field the ring is the field's own border thickening, which is
  # what a text input is expected to do; #333's offset note is about buttons, where the ring
  # has to clear a filled edge, and button_style already carries it.
  # The reset email, in plain text. #344.
  #
  # Plain text and not HTML, because the whole message is one link and a sentence saying what
  # it does. An HTML mail would need a second copy of the same words for clients that do not
  # render it, and two copies of a security-relevant sentence is two things to keep in step.
  #
  # It says how long the link lasts and what to do if it was not you, which are the two
  # questions somebody receiving an unexpected one actually has. It does not say "ignore this
  # email" and stop there: a reset request nobody made is worth knowing about, so the last
  # line names the address it was requested for.
  def reset_password_body(link)
    <<~TEXT
      Somebody asked to reset the password for your tectonic plates account.

      Open this link to choose a new one:

      #{link}

      The link works once and expires in 24 hours.

      If this was not you, nothing has changed and you can ignore this message -- your
      current password still works. Somebody typed your address into the reset form.
    TEXT
  end

  # The confirmation email, beside the one above and in the same shape. #575.
  #
  # Plain text for the same reason, and it answers the same two questions -- what the link
  # does, and what to do if it was not you -- because this message reaches a strictly wider
  # audience than the reset one does. The whole point of the feature is that anybody can type
  # anybody's address into the sign-up form, so a good number of the people reading this never
  # asked for it, and the last line is written for them rather than as an afterthought.
  #
  # It says nothing about expiry, because the link does not expire: migrate/051 gives the key
  # table no deadline column, and the note there says why. Promising "24 hours" here the way
  # the reset email does would be a sentence that goes quietly wrong.
  #
  # It does say that the link is where the password is chosen, and that has to be said here
  # rather than only on the page: this message is the *only* thing standing between a sign-up
  # and an account, so somebody who reads it as "confirm your address" and files it away has
  # lost the account without being told they were halfway through making one.
  #
  # "Confirm" rather than "verify" throughout, here and on both pages. Verification is
  # Rodauth's word for the mechanism and it is the word in the route; what a person is being
  # asked to do is confirm that an address is theirs.
  def verify_account_body(link)
    <<~TEXT
      Somebody started creating a tectonic plates account with this address.

      Open this link to confirm the address is yours and choose a password:

      #{link}

      There is no account until that is done. Nothing has been created that can be signed
      in to, and nothing can be logged against this address.

      If this was not you, there is nothing to do. Ignore this message and nothing comes of
      it; no account exists, nobody can make one from this, and you will not hear from us
      again about it.
    TEXT
  end

  # Why a sign-in or sign-up was refused, or nil where nothing was. #345.
  #
  # The field error is preferred over the flash because it is the specific one: Rodauth's
  # create-account flash reads "There was an error creating your account" whatever went
  # wrong, while the field error names which thing. The flash is the fallback for a refusal
  # that belongs to no single input.
  #
  # A helper rather than a local in the partial, for the reason `unlifted` is one: erb_lint
  # hands each ERB tag to rubocop as a program of its own, so a local assigned in one tag
  # and read in the next reads as a useless assignment.
  def form_error
    rodauth.field_error(rodauth.login_param) || rodauth.field_error(rodauth.password_param) ||
      flash['error']
  end

  # px-3 is here rather than at each call site, which is #368. Most fields carried a py-*
  # and no horizontal padding at all, so the text a person typed sat flush against the left
  # edge of its own box -- readable, but it looks like a rendering fault, and on a number
  # box being read at arm's length it costs a moment every time.
  #
  # Tailwind emits pl-* and pr-* after px-*, so a field that wants an asymmetric inset --
  # a select with a chevron, the search box with an icon -- still overrides one side by
  # naming it, and only the redundant symmetric copies came out of the call sites.
  def field_style
    'rounded-md border-0 px-3 shadow-sm ring-1 ring-inset ring-gray-300 ' \
      'focus:ring-2 focus:ring-inset focus:ring-sky-800'
  end

  # A nav link, which appeared ten times written out in full. What differs between them is
  # only whether the link is the one you are on -- colour, hover, and a transparent bottom
  # border -- so that stays at the call site and the rest is here.
  def nav_link_style
    'brand inline-flex min-h-11 shrink-0 items-center border-b-2 px-1 text-base font-medium sm:text-xl'
  end

  # The same correction as field_style, and the case that made #333 urgent: the ring was
  # lime-500 and the primary button is a lime-500 fill, so tabbing onto Save drew lime on
  # lime -- 1:1, literally invisible, on the most-tapped control in the app. Not a faint
  # ring; no ring. sky-800 is 7.56:1 on white and 4.6:1 against the lime button, so it is
  # visible wherever a button sits.
  #
  # outline-offset-2 was already here and is what keeps the ring clear of a filled edge.
  def button_style
    'rounded-md shadow-sm focus-visible:outline focus-visible:outline-2 ' \
      'focus-visible:outline-offset-2 focus-visible:outline-sky-800'
  end

  # Fill for one of the RPE buttons, highlighting the current rating. Session and set
  # both keep their rating in an rpe column, and the two rows of buttons ask the same
  # question at different scopes, so one helper answers for either.
  #
  # Neutral rather than coloured. The selected rating is a third kind of fact, neither the
  # state the row tint carries nor the action complete_style offers, and it used to be the
  # very same lime-500 as the Done button beside it -- so one lime meant "tap me" and the
  # other "already chosen". Black says only "this is the number on record": 17.74:1 on
  # white, where white on lime-500 was 1.98:1.
  def rpe_style(rated, rpe)
    rated[:rpe] == rpe ? 'bg-gray-900 text-white' : 'bg-white text-gray-700'
  end

  # Which part of the scale this set's buttons cover. #442.
  #
  # The screen offered 6 to 10 and the prescription side allows 1 to 10, which migration 019
  # named as a gap at the time it opened it: *"speed work and deload weeks are written at 5
  # and 6, and a column refusing a 5 would make a real prescription unwritable while sets.rpe
  # cheerfully stored the answer to it."* The generator duly wrote them, and the screen had no
  # button to answer with. On the reporting account 1 set of the 30 prescribed at RPE 4 to 6
  # carries a rating, against 14 of the 36 prescribed at 7 and 8 -- the autoregulation loop
  # going dark on exactly the weeks it was told to back off.
  #
  # **It always reaches 10, whatever was asked for.** A window centred on the target would be
  # narrower and tidier, and it would refuse the most useful thing a lifter can say about a
  # deload: that the light one was hard anyway. A prescription is a plan and the rating is
  # what happened, so the answer may sit anywhere on the scale no matter where the question
  # did.
  #
  # **And it widens only when the prescription asks it to.** Five buttons was a real decision
  # about a thumb on a phone with chalk on, not an oversight, so a set at RPE 8 or one with no
  # target draws exactly the row it always drew. Only a set actually written below 6 gets a
  # sixth button, and the row wraps rather than shrinking, so the targets never narrow.
  RPE_TOP = 10
  RPE_USUAL_FLOOR = 6

  def rpe_choices(set)
    [set[:planned_rpe] || RPE_USUAL_FLOOR, RPE_USUAL_FLOOR].min..RPE_TOP
  end

  # Fill for the button that completes a set or takes it back. The row tint already says
  # which state the set is in, so this says what tapping will do rather than repeating the
  # answer: filled for the action on offer, outlined for the one that reverses it.
  #
  # Sky and not lime, though a green Done is the obvious choice, because lime is already
  # spoken for on this screen -- it is the completed state, in the progress bar and in
  # row_style -- and a lime button sits only on rows that are not done yet. That was the
  # whole of the muddle: the same green meaning "done" as a tint and "not done" as a
  # button. One hue for state, one for action, and neither borrows the other's.
  #
  # Both states carry a border so the two are the same size and a row does not shift under
  # the thumb as it toggles. White on sky-800 is 7.56:1 and sky-900 on white is 9.46:1;
  # the white on lime-500 this replaces was 1.98:1, and the grey it replaces on warmups
  # was the disabled look worn by an enabled button.
  def complete_style(set)
    return 'border-sky-800 bg-white text-sky-900 hover:bg-sky-50' if set[:is_completed]

    'border-sky-800 bg-sky-800 text-white hover:bg-sky-900'
  end

  # Border and fill for a set row: done, or still to do. Two states and no third.
  #
  # There used to be an amber one for a set lifted differently from the way it was
  # written, on the reasoning that done-but-changed had to read differently from
  # done-as-planned. #214 settled that it does not. Amber is the colour this app uses
  # for a warning, and lifting 145 when the sheet said 150 is not one -- it is a set
  # that got done. Reading a session is counting what is finished, and a colour that
  # means "done, but" makes that count take two passes instead of one.
  #
  # What was changed is still said, by the "planned 150 x 5" line under the row. That
  # is the honest place for it: a fact in words, under the row it belongs to, rather
  # than a tint over the whole row that has to be learnt before it says anything.
  def row_style(set)
    set[:is_completed] ? 'border-lime-300 bg-lime-50' : 'border-gray-200 bg-white'
  end

  # The progress series as Chartkick wants them, with the drawing decisions attached. #434.
  #
  # The styling lives here rather than in ProgressChart because that module answers what is
  # true and this answers what it should look like -- and because a `borderDash` in a file
  # that reads the database is a file doing two jobs.
  #
  # Chartkick merges a per-series `dataset:` into the Chart.js dataset, which is what makes a
  # step line and a dashed line possible without dropping to raw Chart.js and losing the
  # palette every other chart in this app is drawn with.
  #
  # **Lifted and the goal are points with no line through them.** Joining sessions with a line
  # would draw a slope between two Tuesdays that nothing happened between, and the goal is one
  # point by definition -- a line from it would go nowhere.
  #
  # **`stepped: "after"` on the two that step.** A training max in this app changes when a
  # block opens and at no other time, so the flat run and the vertical jump are the shape of
  # the quantity rather than a style applied to it.
  #
  # **The pace line is grey and dashed and is never coloured as pass or fail.** #263 and #308
  # are emphatic that the app does not judge whether progress is enough, and a red line under
  # a blue one would be that judgement made in CSS.
  # **`spanGaps` is the one that is not cosmetic, and it was invisible until somebody looked.**
  #
  # Chartkick merges every series onto one shared axis -- the union of all their dates -- and
  # pads each with nulls where it has no value there. So the training max, which has a point at
  # each block opening and one for today, arrives as a five-point array that is null on the
  # three session dates in between. Chart.js does not join a line across a null, and with
  # `pointRadius: 0` the surviving points draw nothing at all: the legend showed "Training max"
  # and the canvas showed no line.
  #
  # No assertion caught it. The series had the right points, the dataset was in the payload,
  # Chart.js reported it visible, and it was not on the screen. A screenshot found it.
  #
  # `spanGaps: true` is also the truthful answer rather than a workaround. A training max of
  # 277 in February and 314 in May was 277 for the whole of the time between -- the null on a
  # session date is not a gap in the quantity, it is a date some other series put on the axis.
  STYLES = {
    ProgressChart::LIFTED => { showLine: false, pointRadius: 4 },
    ProgressChart::ESTIMATED => { borderDash: [2, 3], pointRadius: 0, tension: 0, spanGaps: true },
    ProgressChart::TRAINING_MAX => { stepped: 'after', pointRadius: 0, spanGaps: true },
    ProgressChart::GOAL => { showLine: false, pointRadius: 7, pointStyle: 'rectRot' },
    ProgressChart::PROJECTION => { stepped: 'after', borderDash: [6, 4], pointRadius: 0,
                                   spanGaps: true, borderColor: '#9ca3af', borderWidth: 2 }
  }.freeze

  def progress_series
    @progress.map { |name, points| { name:, data: points, dataset: STYLES.fetch(name, {}) } }
  end

  # Completed sets of this movement that count their reps the other way from the movement
  # itself. #392, the half that was never surfaced.
  #
  # `align_sets_per_side` brings the logged sets into line when the movement's answer
  # *changes*, and that is the only moment anything checks. A movement whose answer was right
  # all along, with sets written before it was given, has nothing to trigger the repair and
  # nothing to report the drift -- so it sits there halving a number quietly.
  #
  # It is not a small number when it happens. On the reporting account the clamshell carried
  # four completed sets counting one leg where the movement says two, the split squat carried
  # two, and the hip thrust's own default contradicted its own note -- 87 reps of work counted
  # as half, found only by going looking.
  #
  # **Completed sets only**, which is what makes this worth showing rather than noise. Volume
  # counts nothing else (see Volume::COMPLETED), so a written-and-never-lifted set disagreeing
  # is a disagreement about a plan and cannot be miscounting anything. The same movement's
  # fourteen unperformed rows would otherwise shout about a number nothing reads.
  #
  # **Reported and not offered as a one-tap fix**, deliberately. The change-triggered repair can
  # tell a stale set from a deliberate one because it has the old answer to compare against; a
  # standing repair has no such discriminator, and a lifter who really did both legs at once on
  # a machine is entitled to have said so. So the app says what it sees and the correction is a
  # decision, which is #263's line.
  #
  # Off @sets, which the route has already loaded and scopes to this account, so no query.
  def per_side_disagreement(exercise)
    @sets.count { |set| set[:is_completed] && set[:is_per_side] != exercise.default_is_per_side }
  end

  # How many completed working sets this movement has, for the page that has to tell "nothing
  # logged" apart from "logged, and the estimate cannot read it".
  #
  # Off @sets, which the route has already loaded, so this costs no query.
  def logged_working_sets
    @sets.count { |set| set[:is_completed] && !set[:is_warmup] }
  end

  # Sets on this movement that were logged and never ticked off.
  #
  # The state nothing in the app used to have a word for, and the one the "nothing has been
  # lifted here" complaint was actually about: thirteen squat sets from 2023 to 2025, every one
  # of them `is_completed = false`, listed on the page in a table while the paragraph above
  # them said nothing had been logged.
  #
  # They are not a mistake in the data so much as a mistake in what the page then says about
  # it. A set written and not ticked is, by this app's model, training that was planned and not
  # performed -- which is a real distinction and the right one. What is wrong is answering it
  # with "nothing has been logged".
  def unfinished_sets
    @sets.count { |set| !set[:is_completed] }
  end

  # A number as a chart table should print it. #337, and #256 underneath it.
  #
  # Tonnage and every weight column are numeric(7,2), so Sequel hands back a BigDecimal and
  # printing one raw gives 0.125e4 -- the correct rendering of a BigDecimal and no use at all
  # to a lifter. The charts escaped this because Chartkick serialises to JSON; a table does
  # not, which is how adding the text alternative surfaced it in two more places.
  #
  # Through Plates.numeric, which is what weight_label already uses and which reads the
  # denominator, so BigDecimal, Float, Integer and Rational all come out the way somebody
  # would write them. Named for the job rather than reusing weight_label, because half of
  # what goes through it is a set count.
  def chart_number(value)
    value && Plates.numeric(value)
  end

  # The week columns for the table beside the top-set chart, in the order the chart draws
  # them. #337.
  #
  # Off the weekly rows rather than off the series, for two reasons. The chart plots a line
  # per lift and each line skips the weeks that lift was not trained, so no single series
  # carries the full set of columns -- and collecting them from every series gives a set with
  # no order in it.
  #
  # Sorting that set would not fix it either, which is the trap: the labels are "%b %-d", so
  # "Sep 10" sorts before "Sep 2" and December sorts before February. The rows are already in
  # week order and Volume.chart keys off the same labels the chart's axis uses, so this is
  # both chronological and guaranteed to match what is drawn.
  def chart_weeks(rows)
    Volume.chart(rows, :sets).keys
  end

  # What changing a movement's per-side answer did to the training already logged. #392.
  #
  # Said out loud rather than done quietly, because it rewrites sets somebody has already
  # lifted and it moves the volume on those sessions by half. A lifter who marks the clamshell
  # per side and sees nothing happen cannot tell this from the bug they were hitting; one who
  # sees "12 logged sets now count per side" knows exactly what it did and can undo it by
  # unticking the box.
  #
  # The count is the whole of the message. Naming the sessions would be a list that grows
  # without bound on a movement trained for a year, and "which ones" is answerable by looking
  # at them.
  def per_side_notice(moved, per_side)
    sets = moved == 1 ? '1 logged set' : "#{moved} logged sets"
    "#{sets} of this movement now count #{per_side ? 'per side' : 'both sides together'}."
  end

  # What saying how many dumbbells did to the sessions already written. #439.
  #
  # Two dumbbells need each plate size twice over, so the answer decides which weights exist
  # for this movement at all -- and the upcoming sessions were written against whichever
  # answer was in force when they were generated. Moving them silently would leave a lifter
  # to discover a different number on Monday, which is the failure #441 was about.
  def dumbbell_notice(rerounded, dumbbells)
    sessions = rerounded == 1 ? '1 upcoming session was' : "#{rerounded} upcoming sessions were"
    "#{sessions} rewritten onto weights #{dumbbells == 1 ? 'one dumbbell' : 'a pair'} can load."
  end

  # A set lifted differently from the way it was written. Sets entered by hand
  # never had a plan, so they can never read as changed.
  def changed_from_plan?(set)
    return false unless set[:planned_weight] && set[:planned_reps]

    set[:weight] != set[:planned_weight] || set[:reps] != set[:planned_reps]
  end

  # A line naming the API token that created a row and when, shown only for
  # objects an LLM made through the MCP endpoint; nil for anything a human made
  # in the UI, so the two are always distinguishable at a glance.
  def provenance(record)
    application = record.created_by_oauth_application
    return unless application && record.created_at

    "Created by #{application.name || 'an LLM'} on #{record.created_at.strftime('%b %-d, %Y')}"
  end
end

