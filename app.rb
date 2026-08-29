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
require_relative 'lib/tectonic/calendar'
require_relative 'lib/tectonic/program_editor'
require_relative 'lib/tectonic/program_generator'
require_relative 'lib/tectonic/training_max'
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
    enable :login, :logout, :create_account, :remember, :json,
           :oauth_authorization_code_grant, :oauth_pkce,
           :oauth_client_credentials_grant, :oauth_jwt,
           :oauth_resource_indicators, :oauth_dynamic_client_registration,
           :oauth_token_introspection, :oauth_token_revocation
    # Sign-up asks for the address once and the password once. Rodauth defaults both of
    # these to true and enforces them on the post rather than in the template, so deleting
    # the two confirmation boxes from views/create-account.erb without turning these off
    # leaves every sign-up rejected for disagreeing with a parameter the form no longer
    # sends -- and the message names a field that is not on the page.
    #
    # What the password confirmation was buying is a typo nobody can see, and it is not
    # bought anywhere else: reset_password is not in the enable list above and there is no
    # mailer in this app, so an account created under a mistyped password is gone. The
    # remaining box says autocomplete="new-password", which asks a password manager to
    # generate and keep the credential instead of leaving a human to type it twice; that
    # is the whole of the mitigation, and it is worth reading the note in
    # views/create-account.erb before removing it.
    require_login_confirmation? false
    require_password_confirmation? false
    after_login do
      remember_login
    end
    # Signing in lands on whatever there is to do rather than on the calendar; where that
    # is is decided in login_destination below.
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
    login_redirect { scope.login_destination(account_id) }
    create_account_redirect { scope.login_destination(account_id) }

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
    # The first thing an account with nothing logged sees. A calendar of an empty month
    # is a true answer to "what have I trained" and a useless one to "what do I do now",
    # which is the only question a new account has. It stays reachable at its own address
    # rather than only through the login redirect, so it can be linked to and so someone
    # who has trained for a year can still come back and read what a block is.
    r.get('start') do
      rodauth.require_login
      view('start')
    end
    # GET /
    r.root do
      r.redirect '/welcome' unless rodauth.logged_in?
      @account_id = rodauth.account_from_session[:id]
      @month = Calendar.month_of(r.params['month'])
      @previous = @month << 1
      @following = @month >> 1
      @week_starts_on = week_starts_on(@account_id)
      @weeks = Calendar.weeks(@account_id, @month, Date.today, @week_starts_on)
      @tally = Calendar.tally(@weeks)
      view('home')
    end

    # Training blocks: what is written, and turning a week of it into real sessions. The
    # common act is adjusting one lift between weeks, so that is a form on the block page
    # rather than a page of its own; authoring a block from nothing is rarer and is a
    # week copied and then edited, which is how a block actually gets written.
    r.on 'programs' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]
      @editor = ProgramEditor.new(@account_id)

      r.on String do |program_id|
        @program = @editor.program(program_id)
        r.redirect '/programs' unless @program

        r.post('weeks') { program_action(r) { @editor.add_week(@program, copy_from: r.params['copy_from']) } }
        r.post('days') { program_action(r) { add_program_day(r) } }
        r.post('lifts') { program_action(r) { add_program_lift(r) } }
        r.post('generate') { program_action(r) { generate_program_week(r) } }

        r.on 'lifts', String do |lift_id|
          @lift = @editor.lift(@program, lift_id)
          r.redirect "/programs/#{@program.id}" unless @lift

          r.post('delete') { program_action(r) { @editor.remove_lift(@lift) } }
          r.post { program_action(r) { @editor.update_lift(@lift, r.params.slice(*LIFT_FIELDS)) } }
        end

        r.get { program_view }
      end

      r.post do
        check_csrf!
        program = @editor.create_program(name: r.params['name'], start_date: r.params['start_date'])
        r.redirect "/programs/#{program.id}"
      end

      r.get do
        @programs = @editor.programs
        view('programs/index')
      end
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
        r.redirect '/settings'
      end

      r.post do
        check_csrf!
        Equipment.replace(@account_id, bar_weight: r.params['bar_weight'],
                                       plates: r.params['plates'])
        r.redirect '/settings'
      end

      r.get do
        @week_starts_on = week_starts_on(@account_id)
        @equipment = Equipment.for_account(@account_id)
        view('settings')
      end
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
        # icon_url is deliberately not read here. #199 took the field off the form -- every
        # library movement draws a shipped icon since #171, so the field was a way to point
        # every visitor's browser at a third party to override a working default. The column
        # stays, and the MCP tools still write it, which is why this must not pass the param
        # through: the form no longer sends one, so reading it would set the column to nil
        # and quietly erase an icon an assistant had chosen every time somebody used the
        # browser to fix a typo in the name.
        if r.params['id'].empty?
          exercise_id = Exercise.insert(name: r.params['name'], account_id: @account_id,
                                        is_barbell:, default_is_per_side:, note:)
          r.redirect "/exercises/#{exercise_id}/"
        else
          # Only the owner may update; library rows (nil account) and other
          # accounts' rows don't match, so the edit is refused. The note is on the same
          # side of that line as the name, and has to be: a library movement sits on every
          # account's page, so a note written to one is a value one account wrote and
          # everybody else reads.
          @exercise = Exercise.owned_by(@account_id).where(id: r.params['id']).first
          r.redirect '/exercises' unless @exercise
          @exercise.update(name: r.params['name'], is_barbell:, default_is_per_side:, note:)
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
          TrainingMax.replace(@account_id, @exercise.id, r.params['pounds'])
          r.redirect "/exercises/#{@exercise.id}/"
        end
        r.get do
          # Only the viewer's own sets for this movement, so a shared library
          # exercise never surfaces another account's logged sets.
          my_workouts = Workout.where(account_id: @account_id).select(:id)
          mine = WorkoutSet.where(exercise_id: @exercise.id, workout_id: my_workouts)
          @sets = mine.all
          @heaviest_by_day = heaviest_by_day(mine)
          # Whatever a percentage of this movement would resolve against today, and which
          # of the two answers that is. Nil when there is neither, which is the state the
          # page has to say something about: it is the one that makes a percentage lift
          # refuse to generate.
          @training_max = TrainingMax.for(account_id: @account_id, exercise: @exercise)
          view('exercises/show')
        end
      end
      r.get do
        @exercises = Exercise.visible_to(@account_id).order(:id)
        view 'exercises/index'
      end
    end

    r.on 'workouts' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]
      r.get('new') { view('workouts/new') }
      r.on String do |workout_id|
        @workout = Workout[workout_id]
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
          @exercises = Exercise.visible_to(@account_id).order(:id)
          r.get('new') { view('sets/new') }

          # The movement has to be one this account may select. The barbell flag was
          # already read through visible_exercise, but the id itself went in unchecked,
          # so a guessed id attached a stranger's private movement to a set and rendered
          # its name back wherever that set appeared.
          r.post 'new' do
            check_csrf!
            exercise = visible_exercise(r.params['exercise_id'])
            r.redirect "/workouts/#{workout_id}/sets/new" unless exercise
            # required on the input is the browser's rule and stops at the browser. A post
            # with no rep count in it reaches here, and sets_measures_one_way refuses a row
            # measured in reps that has none -- unrescued, so a 500 rather than a refusal.
            # Every set this form makes is measured in reps, which is the column default.
            r.redirect "/workouts/#{workout_id}/sets/new" if r.params['reps'].to_s.strip.empty?

            set_id = WorkoutSet.insert(weight: r.params['weight'], reps: r.params['reps'],
                                       exercise_id: exercise.id, is_warmup: r.params['is_warmup'] || false,
                                       is_completed: r.params['is_completed'] || false, workout_id:,
                                       is_barbell: exercise.barbell?)
            r.redirect "/workouts/#{workout_id}/sets/#{set_id}/"
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
              # No parameters is the primary tap, which toggles, so a mis-tap is undone by
              # tapping again. A rating completes: choosing an RPE is saying you lifted it,
              # and there is nothing else an RPE could be about.
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
              # Through WorkoutSet.completion so the stamp and the flag are written together
              # (#281). The empty branch is the one that matters: a correction changes
              # neither, so it must not touch the stamp either -- fixing a weight two reps
              # into a set is not doing the set, and re-stamping it would move a turnaround
              # the lifter never took.
              completion = if revised.empty?
                             WorkoutSet.completion(!set.is_completed)
                           elsif revised.key?(:rpe)
                             WorkoutSet.completion(true)
                           else
                             {}
                           end
              set.update(**revised, **completion)
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
              set.update(weight: r.params['weight'],
                         is_warmup: r.params['is_warmup'] || false,
                         **WorkoutSet.completion(!r.params['is_completed'].nil?),
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
          r.post 'finish' do
            check_csrf!
            Workout.where(id: workout_id).update(finished_at: Time.now)
            r.redirect "/workouts/#{workout_id}"
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
        r.get('edit') { view('workouts/edit') }
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
          @exercises = Exercise.visible_to(@account_id).as_hash(:id)
          # How long it took, off the rows already loaded (#281). No query of its own: the
          # stamps are columns on the sets this page has just fetched, which is the whole
          # reason the timing lives on the set rather than in a table beside it.
          @timing = Timing.session(@workout, @sets.map(&:values))
          view 'workouts/show'
        end
      end
      r.get do
        # Sessions still to train are read forwards and training already done is read
        # backwards, so both lists open on the workout nearest today. with_performance
        # answers "has anything been lifted here" for the whole page in the query that
        # fetches it, which is what keeps the split off the sets table.
        planned, history = Workout.where(account_id: @account_id).with_performance.with_set_count
                                  .reverse(:date).all.partition { |workout| workout.status == :planned }
        @upcoming = planned.reverse
        @workouts = history
        view 'workouts/index'
      end
      r.post do
        check_csrf!
        id = r.params['id']
        # Blank is stored as null rather than as '', so "unnamed" has one spelling. It
        # also means clearing the field on an edit puts a generated session back to
        # reading its program day's focus rather than pinning it to an empty string.
        name = Workout.clean_name(r.params['name'])
        if id.empty?
          workout_id = Workout.insert(account_id: @account_id, date: r.params['date'], name:)
          r.redirect "/workouts/#{workout_id}/"
        else
          # Rescheduling is owner-only. This route sits outside the nested ownership
          # gate, so without the account in the filter any id would match and any
          # account's workout could be moved to a new date.
          @workout = Workout.where(id:, account_id: @account_id).first
          r.redirect '/workouts' unless @workout
          @workout.update(date: r.params['date'], name:)
          r.redirect "/workouts/#{@workout.id}/"
        end
      end
    end
  end

  # Where a login lands, in the order a lifter would ask for it: a session written for
  # today, failing that the form for writing one, failing that the first-run page.
  #
  # Today's session opens on the gym floor screen rather than on the record page. Someone
  # opening the app on a day they have training written is about to lift, and the session
  # screen is the one that ticks a set off with a thumb; the record page reads a session
  # back afterwards and is a tap away from the session anyway. A session already finished
  # is not treated as a different case: "fully completed" is a guess about intent -- a set
  # can still be added, corrected or rated, and all three happen on that same screen --
  # and second-guessing it would mean asking the sets table on every login to arrive
  # somewhere a lifter can reach in one tap regardless.
  #
  # `date` is a timestamp, so the day is compared on the cast the way Calendar.by_day
  # does. An equality against a Time would match nothing but a session written at exactly
  # midnight. Two sessions may share a day and nothing forbids it, so the lowest id wins:
  # the one written first.
  #
  # Two queries rather than one. One could answer both by ordering on "is this dated
  # today", but no index covers that expression, so it would sort every workout the
  # account owns; these are both a LIMIT 1 lookup and the second only runs on the days
  # the first finds nothing.
  def login_destination(account_id)
    mine = Workout.where(account_id:)
    today = mine.where(Sequel.cast(:date, :date) => Date.today).order(:id).first
    return "/workouts/#{today.id}/session" if today
    return '/workouts/new' unless mine.empty?

    '/start'
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
  # Read straight off the table rather than through a model, because there is no Account
  # model in this app -- Rodauth owns that table and works it as a dataset -- and inventing
  # one for a single integer would be a larger thing than the integer. The fallback is
  # belt and braces: the column is NOT NULL with a default, so a row without one cannot
  # exist, and a reader that assumes so anyway costs nothing.
  def week_starts_on(account_id)
    DB[:accounts].where(id: account_id).get(:week_starts_on) || 0
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
    panels.join + render('workouts/_progress', locals: { oob: true }) + session_poll(workout_id, fingerprint)
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
    position = session_lifts.index { |lift| lift.any? { |set| set[:id] == set_id.to_i } } || 0
    render('workouts/_lift_panel', locals: { lift: session_lifts[position], position: }) +
      render('workouts/_progress', locals: { oob: true }) +
      # Re-armed with what this tap just made true. Without it the poller would still be
      # asking about the digest the page loaded with, find it changed -- by the lifter, a
      # second ago -- and swap every panel back over the top of their own tap. #249.
      session_poll(workout_id)
  end

  # Everything the session screen renders from, which is the same two reads whether the
  # whole page is being drawn, one panel is coming back after a tap, or the poll has found
  # something moved. Insertion order is program order: warmups then working sets, lift by
  # lift in the position the program gave them.
  def load_session(workout_id)
    @sets = WorkoutSet.where(workout_id:).order(:id).all
    @exercises = Exercise.visible_to(@account_id).as_hash(:id)
    # How long this has been going, worked out from rows already in hand (#281). Set here
    # rather than in the session route because all three render paths go through this one --
    # the first paint, the panel a tap sends back, and the poll -- and the progress header
    # is rendered by every one of them. Set in the route instead, a tap would render a
    # header with no clock on it and the number would vanish on the first Done.
    @timing = Timing.session(@workout, @sets.map(&:values))
  end

  # The session's sets grouped into the lifts they belong to. Insertion order is program
  # order, so consecutive sets of one movement are one lift and a movement that comes
  # round twice in a session is two.
  #
  # It lives here rather than in the template it serves because the panel row asks for it
  # three times over -- once to walk it, then inside every panel to number that panel and
  # to draw a dot per lift -- and a local assigned in one ERB tag and read in the next is
  # an offence to erb_lint, which hands each tag to rubocop as a program of its own.
  def session_lifts
    @session_lifts ||= @sets.chunk_while { |before, after| before[:exercise_id] == after[:exercise_id] }.to_a
  end

  # A set is only reachable through a workout the logged in account owns, so a set
  # id belonging to someone else's workout does not resolve.
  def own_set(set_id, workout_id)
    return nil unless @workout && @workout.account_id == @account_id

    WorkoutSet.where(id: set_id, workout_id:).first
  end

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

  # The fields a lift edit may set. Named rather than taken wholesale so a form cannot
  # reach a column it has no business in, and so the pricing rule sees both prices when
  # one is being swapped for the other.
  LIFT_FIELDS = %w[sets reps top_weight percent_of_max target_rpe note].freeze

  # Every programme write is the same shape: check the token, try it, and come back to the
  # block with either nothing to say or the writer's own refusal to show. The refusal is
  # stashed in the session because the answer is a redirect -- a lifter who reloads after
  # a bad edit should not be asked to resubmit it.
  def program_action(request, &)
    check_csrf!
    ok, message = @editor.attempt(&)
    session['program.error'] = message unless ok
    request.redirect "/programs/#{@program.id}"
  end

  def program_view
    @error = session.delete('program.error')
    @equipment = Equipment.for_account(@account_id)
    @exercises = Exercise.visible_to(@account_id).order(:name)
    view('programs/show')
  end

  def add_program_day(request)
    week = @program.week(request.params['week'].to_i)
    raise MCP::Tool::Refusal, 'That week is not part of this block.' unless week

    @editor.add_day(week, weekday: request.params['weekday'], focus: request.params['focus'])
  end

  def add_program_lift(request)
    day = ProgramDay.where(id: request.params['day_id'],
                           program_week_id: @program.program_weeks_dataset.select(:id)).first
    raise MCP::Tool::Refusal, 'That day is not part of this block.' unless day

    @editor.add_lift(day, request.params.slice('exercise', *LIFT_FIELDS))
  end

  # Writing a week into real workouts is the point of a programme, and it is idempotent:
  # running it twice reuses the sessions rather than doubling them.
  def generate_program_week(request)
    ProgramGenerator.new(@program).generate(request.params['week'].to_i)
  rescue ArgumentError => e
    raise MCP::Tool::Refusal, e.message
  end

  # The rack the signed-in account lifts on, read once per request: the session view asks
  # for a plate breakdown per set, and every one of them wants the same inventory.
  def equipment
    @equipment ||= Equipment.for_account(@account_id)
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
  def plate_label(set)
    return '' unless set[:is_barbell]

    breakdown = equipment.per_side(set[:weight])
    return Plates.label(breakdown) if breakdown

    weight, nearest = equipment.closest(set[:weight])
    return "closest #{weight}: #{Plates.label(nearest)}" if nearest

    "lighter than your #{weight_label(equipment.bar_weight)} lb bar"
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
  def load_label(set)
    "#{"#{weight_label(set[:weight])} lb × " if set[:weight]}#{quantity_label(set)}#{' per side' if set[:is_per_side]}"
  end

  # What the sheet said, in the same words as what was lifted. The two sit one line apart
  # on a changed set -- "75 lb × 5" over "planned 95 × 5" -- and a unit on only one of them
  # reads as two different kinds of number rather than as the same number twice. #280.
  def planned_label(set)
    "#{"#{weight_label(set[:planned_weight])} lb × " if set[:planned_weight]}#{set[:planned_reps]}"
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

  # What a set counts. Seconds read as a duration rather than as a rep count, because
  # "60 reps" of a plank is not what anybody held.
  def quantity_label(set)
    return "#{set[:duration_seconds]}s" if set[:duration_seconds]

    set[:weight] ? set[:reps].to_s : "#{set[:reps]} reps"
  end

  # The heaviest a lift was taken on each day it was recorded, oldest day first, which
  # is the line the exercise page draws. Warmups are left out: on any normal day the top
  # set is heavier than the ramp-up and the answer is the same either way, but a day of
  # warmups alone should leave a gap in the line rather than a dip that reads as a light
  # session. The maximum is taken in the database, since the alternative is dragging
  # every set a lift has ever had into Ruby to fold it back down to one number a day.
  # The date belongs to the workout rather than the set and is stored as a timestamp, so
  # it is cast to a day the way the MCP tools cast it when they match one. Each day is
  # labelled rather than dated: the chart plots these as categories, evenly spaced, so
  # the label is the only calendar left on the axis and it carries the year, there being
  # nothing else to tell one March from another.
  def heaviest_by_day(sets)
    recorded = Sequel.cast(Sequel[:workouts][:date], :date)
    heaviest = Sequel.function(:max, Sequel[:sets][:weight])
    sets.exclude(is_warmup: true).join(:workouts, id: :workout_id).group(recorded).order(recorded)
        .select_map([Sequel.as(recorded, :day), Sequel.as(heaviest, :heaviest)])
        .map { |day, weight| [day.strftime('%b %-d, %Y'), weight_label(weight)] }
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
  def field_style
    'rounded-md border-0 shadow-sm ring-1 ring-inset ring-gray-300 ' \
      'focus:ring-2 focus:ring-inset focus:ring-lime-500'
  end

  # A nav link, which appeared ten times written out in full. What differs between them is
  # only whether the link is the one you are on -- colour, hover, and a transparent bottom
  # border -- so that stays at the call site and the rest is here.
  def nav_link_style
    'brand inline-flex min-h-11 shrink-0 items-center border-b-2 px-1 text-base font-medium sm:text-xl'
  end

  def button_style
    'rounded-md shadow-sm focus-visible:outline focus-visible:outline-2 ' \
      'focus-visible:outline-offset-2 focus-visible:outline-lime-500'
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

