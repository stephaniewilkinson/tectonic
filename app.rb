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

class Tectonic < Roda
  SESSION_SECRET = ENV.fetch 'SESSION_SECRET'

  include Chartkick::Helper

  plugin :assets, css: ['tailwind.css', 'styles.css']
  plugin :default_headers, 'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains'
  plugin :head
  plugin :public, root: 'assets'
  plugin :render
  plugin :route_csrf
  plugin :sessions, secret: SESSION_SECRET
  plugin :slash_path_empty
  plugin :rodauth do
    account_password_hash_column :password_hash
    enable :login, :logout, :create_account, :remember
    after_login do
      remember_login
    end
  end

  route do |r|
    r.assets
    r.public
    r.rodauth

    r.get('welcome') { view('welcome') }
    r.get('about') { view('about') }
    # GET /
    r.root do
      r.redirect '/welcome' unless rodauth.logged_in?
      rodauth.login_redirect
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
    token = record.created_by_token
    return unless token && record.created_at

    "Created by #{token.name || 'an API token'} on #{record.created_at.strftime('%b %-d, %Y')}"
  end
end

