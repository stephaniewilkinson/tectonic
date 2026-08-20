# frozen_string_literal: true

require 'dotenv/load'
require 'http'
require 'rack'
require 'roda'
require 'tilt'
require 'chartkick'
require_relative 'lib/tectonic/db'
require_relative 'lib/tectonic/exercises'
require_relative 'lib/tectonic/plates'
require_relative 'lib/tectonic/sets'
require_relative 'lib/tectonic/workouts'
require_relative 'lib/tectonic/oauth_keys'
require_relative 'lib/tectonic/oauth/refresh_token_reuse'
require_relative 'lib/tectonic/mcp/config'

class Tectonic < Roda
  SESSION_SECRET = ENV.fetch 'SESSION_SECRET'

  include Chartkick::Helper

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
    # prior account -- the user is bound later, at the consent step. A registered client
    # can do nothing until a logged-in user authorizes it, so registration stays open.
    before_register do
      # No account to authorize against, and nothing else to gate: registration is open.
    end
    # Refresh tokens rotate on use, which detects a stolen token being replayed but
    # leaves the grant behind it alive; this revokes that grant, as RFC 9700 section
    # 4.14.2 requires. Prepended so it sits in front of the feature methods it extends.
    auth_class_eval { prepend OAuth::RefreshTokenReuse }
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
    r.on 'exercises' do
      rodauth.require_login
      @account_id = rodauth.account_from_session[:id]
      r.get('new') { view('exercises/new') }
      r.post do
        if r.params['id'].empty?
          exercise_id = Exercise.insert(name: r.params['name'], icon_url: r.params['icon_url'], account_id: @account_id)
          r.redirect "/exercises/#{exercise_id}/"
        else
          # Only the owner may update; library rows (nil account) and other
          # accounts' rows don't match, so the edit is refused.
          @exercise = Exercise.where(id: r.params['id'], account_id: @account_id).first
          r.redirect '/exercises' unless @exercise
          @exercise.update(name: r.params['name'], icon_url: r.params['icon_url'])
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
          @sets = Set.where(exercise_id: @exercise.id, workout_id: my_workouts).all
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

          r.post 'new' do
            set_id = Set.insert(weight: r.params['weight'], reps: r.params['reps'],
                                exercise_id: r.params['exercise_id'], is_warmup: r.params['is_warmup'] || false,
                                is_completed: r.params['is_completed'] || false, workout_id:)
            r.redirect "/workouts/#{workout_id}/sets/#{set_id}/"
          end

          r.on String do |set_id|
            # Marks a set done from the session view. Must come before the bare
            # r.post below, which matches any remaining path.
            r.post 'complete' do
              check_csrf!
              set = own_set(set_id, workout_id)
              r.redirect "/workouts/#{workout_id}/session" unless set

              revised = { weight: r.params['weight'], reps: r.params['reps'] }
              revised = revised.reject { |_, value| value.to_s.empty? }
              # No revision means the primary tap, which toggles so a mis-tap is
              # undone by tapping again. A revision always completes the set.
              set.update(**revised, is_completed: revised.empty? ? !set.is_completed : true)
              r.env['HTTP_HX_REQUEST'] ? session_body(workout_id) : r.redirect("/workouts/#{workout_id}/session")
            end
            r.get 'edit' do
              @set = Set[id: set_id]
              view 'sets/edit'
            end
            r.get do
              @set = Set[id: set_id]
              view 'sets/show'
            end
            r.post do
              Set.where(id: set_id).update(weight: r.params['weight'], reps: r.params['reps'],
                                           is_warmup: r.params['is_warmup'] || false,
                                           is_completed: r.params['is_completed'] || false)
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
        @workouts = Workout.order_by(:date).where(account_id: @account_id).reverse
        view 'workouts/index'
      end
      r.post do
        id = r.params['id']
        if id.empty?
          workout_id = Workout.insert(account_id: @account_id, date: r.params['date'])
          r.redirect "/workouts/#{workout_id}/"
        else
          Workout.where(id: r.params['id']).update(date: r.params['date'])
          @workout = Workout[id]
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

  # Per-side plate breakdown for the session view, blank for anything not loaded
  # on a bar and for weights this rack cannot make.
  def plate_label(set)
    return '' unless set[:is_barbell]

    Plates.label(Plates.per_side(set[:weight]))
  end

  # Fill for one of the session RPE buttons, highlighting the current rating.
  def rpe_style(workout, rpe)
    workout[:rpe] == rpe ? 'bg-lime-500 text-white' : 'bg-white text-gray-700'
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

