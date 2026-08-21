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
  # API client the account, and the only script it needs is the stylesheet CDN the site
  # is written against, so everything else is denied outright rather than left open the
  # way the site-wide policy has to leave it. form-action is deliberately absent: the
  # consent POST is answered with a 302 to the client's callback, and browsers disagree
  # about whether form-action applies across a redirect, so naming it would risk
  # breaking the exchange it is supposed to protect.
  CONSENT_SECURITY_POLICY = "default-src 'none'; script-src https://cdn.tailwindcss.com; " \
                            "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; " \
                            "frame-ancestors 'none'; base-uri 'self'; object-src 'none'"

  include Chartkick::Helper

  # Every chart on the site is styled here rather than at each call site: lime because
  # that is the app's colour everywhere else, and whole numbers on the count axis
  # because Chart.js otherwise labels the gridlines in halves, and half a set is not a
  # thing anyone lifted.
  Chartkick.options = { colors: ['#84cc16'], height: '260px',
                        library: { scales: { y: { ticks: { precision: 0 } } } } }

  plugin :assets, css: ['tailwind.css', 'styles.css']
  # frame-ancestors keeps every page out of a third party's iframe, the OAuth consent
  # screen most of all: it is the one page where a click grants an API client access to
  # the account, so it is the one worth framing over a decoy. base-uri and object-src
  # close the two injection sinks that cost nothing to shut. Script and style sources are
  # deliberately left open because the site loads a JIT stylesheet CDN and renders inline
  # chart scripts, so naming them would be a policy this app does not yet satisfy.
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
  plugin :render
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
    after_login do
      remember_login
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
    # analytics pixel, two charting libraries, a date bundle, and htmx -- five third-party
    # scripts, none of them subresource-pinned -- and any one of them could rewrite the
    # form that grants an API client the account. None of them has anything to do with
    # this page, so it loads none of them, and the policy above says so.
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
    # GET /
    r.root do
      r.redirect '/welcome' unless rodauth.logged_in?
      view('home')
    end

    # The bar and plates this account lifts on. Everything the app calculates rounds to
    # what this rack can load, so it is the one setting that changes the numbers.
    r.on 'equipment' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]

      r.post do
        check_csrf!
        Equipment.replace(@account_id, bar_weight: r.params['bar_weight'],
                                       plates: r.params['plates'])
        r.redirect '/equipment'
      end

      r.get do
        @equipment = Equipment.for_account(@account_id)
        view('equipment')
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
      r.post do
        check_csrf!
        # Whether the movement is loaded on a bar is asked outright here and the answer
        # is taken as given, ticked or not: a person looking at the checkbox knows their
        # own variation better than a name ever says. The paths with nobody to ask fall
        # back to the library name instead.
        is_barbell = !r.params['is_barbell'].nil?
        if r.params['id'].empty?
          exercise_id = Exercise.insert(name: r.params['name'], icon_url: r.params['icon_url'],
                                        account_id: @account_id, is_barbell:)
          r.redirect "/exercises/#{exercise_id}/"
        else
          # Only the owner may update; library rows (nil account) and other
          # accounts' rows don't match, so the edit is refused.
          @exercise = Exercise.where(id: r.params['id'], account_id: @account_id).first
          r.redirect '/exercises' unless @exercise
          @exercise.update(name: r.params['name'], icon_url: r.params['icon_url'], is_barbell:)
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
        r.get do
          # Only the viewer's own sets for this movement, so a shared library
          # exercise never surfaces another account's logged sets.
          my_workouts = Workout.where(account_id: @account_id).select(:id)
          mine = Set.where(exercise_id: @exercise.id, workout_id: my_workouts)
          @sets = mine.all
          @heaviest_by_day = heaviest_by_day(mine)
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
            Set.where(workout_id:).delete
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

            set_id = Set.insert(weight: r.params['weight'], reps: r.params['reps'],
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
              # No revision means the primary tap, which toggles so a mis-tap is
              # undone by tapping again. A revision always completes the set, and a
              # rating counts as one: rating a set is saying you lifted it.
              set.update(**revised, is_completed: revised.empty? ? !set.is_completed : true)
              r.env['HTTP_HX_REQUEST'] ? session_body(workout_id) : r.redirect("/workouts/#{workout_id}/session")
            end
            # Every route below resolves the set through own_set, which scopes it to
            # this workout -- and the workout is already gated to the account above. A
            # bare `Set[id]` would match any set in the database, so a set id from
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

              set.update(weight: r.params['weight'], reps: r.params['reps'],
                         is_warmup: r.params['is_warmup'] || false,
                         is_completed: r.params['is_completed'] || false,
                         **substitution(set, r.params['exercise_id']))
              r.redirect "/workouts/#{workout_id}"
            end
          end
          r.get do
            view 'sets/index'
          end
        end
        # The gym floor view of a workout, as distinct from workouts/show, which
        # stays the record of one. Ownership is already guaranteed by the gate above.
        r.on 'session' do
          r.post do
            check_csrf!
            Workout.where(id: workout_id).update(rpe: r.params['rpe'])
            @workout = Workout[workout_id]
            r.env['HTTP_HX_REQUEST'] ? session_body(workout_id) : r.redirect("/workouts/#{workout_id}/session")
          end
          r.get do
            # Insertion order is program order: warmups then working sets, lift by
            # lift in the position the program gave them.
            @sets = Set.where(workout_id:).order(:id).all
            @exercises = Exercise.visible_to(@account_id).as_hash(:id)
            view 'workouts/session'
          end
        end
        r.get('edit') { view('workouts/edit') }
        r.is do
          @sets = Set.where(workout_id:).order(:exercise_id)
          @array_of_exercise_ids = @sets.map(:exercise_id).uniq
          view 'workouts/show'
        end
      end
      r.get do
        # Sessions still to train are read forwards and training already done is read
        # backwards, so both lists open on the workout nearest today. with_performance
        # answers "has anything been lifted here" for the whole page in the query that
        # fetches it, which is what keeps the split off the sets table.
        planned, history = Workout.where(account_id: @account_id).with_performance
                                  .reverse(:date).all.partition { |workout| workout.status == :planned }
        @upcoming = planned.reverse
        @workouts = history
        view 'workouts/index'
      end
      r.post do
        check_csrf!
        id = r.params['id']
        if id.empty?
          workout_id = Workout.insert(account_id: @account_id, date: r.params['date'])
          r.redirect "/workouts/#{workout_id}/"
        else
          # Rescheduling is owner-only. This route sits outside the nested ownership
          # gate, so without the account in the filter any id would match and any
          # account's workout could be moved to a new date.
          @workout = Workout.where(id:, account_id: @account_id).first
          r.redirect '/workouts' unless @workout
          @workout.update(date: r.params['date'])
          r.redirect "/workouts/#{@workout.id}/"
        end
      end
    end
  end

  # The swappable core of the session view -- progress, every lift, and the RPE
  # buttons -- rendered without the layout so htmx can drop it into #session-body
  # after each tap. Without JS the routes redirect and the full page reloads.
  def session_body(workout_id)
    @sets = Set.where(workout_id:).order(:id).all
    @exercises = Exercise.visible_to(@account_id).as_hash(:id)
    render('workouts/_session_body')
  end

  # A set is only reachable through a workout the logged in account owns, so a set
  # id belonging to someone else's workout does not resolve.
  def own_set(set_id, workout_id)
    return nil unless @workout && @workout.account_id == @account_id

    Set.where(id: set_id, workout_id:).first
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

  # The rack the signed-in account lifts on, read once per request: the session view asks
  # for a plate breakdown per set, and every one of them wants the same inventory.
  def equipment
    @equipment ||= Equipment.for_account(@account_id)
  end

  # Per-side plate breakdown for the session view, blank for anything not loaded
  # on a bar and for weights this rack cannot make.
  def plate_label(set)
    return '' unless set[:is_barbell]

    equipment.label(set[:weight])
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
        .map { |day, weight| [day.strftime('%b %-d, %Y'), weight] }
  end

  # Fill for one of the RPE buttons, highlighting the current rating. Session and set
  # both keep their rating in an rpe column, and the two rows of buttons ask the same
  # question at different scopes, so one helper answers for either.
  def rpe_style(rated, rpe)
    rated[:rpe] == rpe ? 'bg-lime-500 text-white' : 'bg-white text-gray-700'
  end

  # Border and fill for a set row: still to do, done as written, or done
  # differently, which has to read differently from done as planned.
  def row_style(set)
    return 'border-gray-200 bg-white' unless set[:is_completed]

    changed_from_plan?(set) ? 'border-amber-300 bg-amber-50' : 'border-lime-300 bg-lime-50'
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

