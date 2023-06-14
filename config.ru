# frozen_string_literal: true

require 'dotenv/load'
require 'http'
require 'rack'
require 'roda'
require 'tilt'
require_relative 'lib/db'
require_relative 'lib/exercises'
require_relative 'lib/xsets'
require_relative 'lib/workouts'

class App < Roda
  ACCOUNTS = ::DB[:accounts]
  SESSION_SECRET = ENV.fetch 'SESSION_SECRET'

  plugin :assets, css: 'tailwind.css'
  plugin :default_headers, 'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains'
  plugin :head
  plugin :public, root: 'assets'
  plugin :render
  plugin :route_csrf
  plugin :sessions, secret: SESSION_SECRET
  plugin :slash_path_empty
  plugin :rodauth do
    account_password_hash_column :password_hash
    enable :login, :logout, :create_account
  end

  route do |r|
    r.assets
    r.public
    r.rodauth

    # GET /
    r.root { view('welcome') }

    r.get('home') { view('home') }

    r.on 'workouts' do
      rodauth.require_login

      r.get('new') { view('workouts/new') }
      r.on String do |workout_id|
        @workout = Workout[workout_id]
        r.on 'exercises' do
          r.get('new') { view('exercises/new') }
          r.post 'new' do
            @exercise = Exercise.new(name: r.params['name'], goal_weight: r.params['goal_weight'])
            @exercise.save
            r.redirect "/workouts/#{workout_id}/exercises/#{@exercise[:id]}/"
          end
          r.on String do |exercise_id|
            @exercise = Exercise[exercise_id]
            r.on 'sets' do
              r.get('new') { view('sets/new') }

              r.post 'new' do
                SETS.insert(weight: r.params['weight'], reps: r.params['reps'], exercise_id:)
                @exercise = Exercise[exercise_id]
                r.redirect "/workouts/#{workout_id}/exercises/#{@exercise[:id]}/"
              end

              r.on String do |set_id|
                r.get 'edit' do
                  @set = SETS[id: set_id]
                  view 'sets/edit'
                end
                r.get do
                  @set = SETS[id: set_id]
                  view 'sets/show'
                end
                r.post do
                  SETS.where(id: set_id).update(exercise_id:, weight: r.params['weight'], reps: r.params['reps'],
                                                is_completed: r.params['is_completed'])
                  r.redirect "/workouts/#{workout_id}/exercises/#{exercise_id}"
                end
              end
              r.get do
                view 'sets/index'
              end
            end

            r.get do
              @sets = SETS.where(exercise_id: @exercise[:id])
              view 'exercises/show'
            end
          end

          r.get do
            @exercises = Exercise.all
            view 'exercises/index'
          end
        end

        r.on 'edit' do
          view 'workouts/edit'
        end
        r.is do
          @workout = Workout[workout_id]
          binding.irb
          @sets = @workout.xsets
          view 'workouts/show'
        end
      end
      r.get do
        @workouts = Workout.all
        view 'workouts/index'
      end
      r.post do
        @workout = Workout.new(account_id: 1, date: Time.now.utc).save
        workout_id = @workout.id
        r.redirect "/workouts/#{workout_id}/"
      end
    end
  end
end

run App.freeze.app
