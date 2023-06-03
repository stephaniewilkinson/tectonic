# frozen_string_literal: true

require 'dotenv/load'
require 'http'
require 'rack'
require 'roda'
require 'tilt'
require_relative 'lib/db'
require_relative 'lib/workouts'

class App < Roda
  ACCOUNTS = ::DB[:accounts]
  SESSION_SECRET = ENV.fetch 'SESSION_SECRET'
  SETS = ::DB[:sets]

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
    r.root do
      view 'welcome'
    end

    r.get 'home' do
      view 'home'
    end

    r.on 'workouts' do
      rodauth.require_login
      r.on 'new' do
        view 'workouts/new'
      end
      r.on String do |workout_id|
        @workout = Workout[workout_id]
        r.on 'exercises' do
          r.get 'new' do
            view 'exercises/new'
          end
          r.post do
            @exercise = Exercise.new(name: r.params['name'], goal_weight: r.params['goal_weight'])
            @exercise.add_workout(@workout).save_changes
            r.redirect "/workouts/#{workout_id}/exercises/#{@exercise[:id]}/"
          end
          r.on String do |exercise_id|
            @exercise = Exercise[exercise_id]
            r.on 'sets' do
              r.on 'new' do
                r.get do
                  view 'sets/new'
                end
                r.post do
                  set_id = SETS.insert(weight: r.params['weight'], reps: r.params['reps'], exercise_id:)
                  @exercise = Exercise[exercise_id]
                  @exercise.add_workout(@workout)
                  @set = SETS[id: set_id]
                  r.redirect "/workouts/#{workout_id}/exercises/#{exercise_id}/sets/#{set_id}/"
                end
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
                  r.redirect "/workouts/#{workout_id}/exercises/#{exercise_id}/sets/#{set_id}/"
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
          @exercises = @workout.exercises
          @exercises_and_sets = @exercises.map do |exercise|
            [exercise, SETS.where(exercise_id: exercise[:id])]
          end
          view 'workouts/show'
        end
      end
      r.get do
        @workouts = Workout.all
        view 'workouts/index'
      end
      r.post do
        if r.params['type'] == 'A'
          squat_weight = 150
          benchpress_weight = 60
          row_weight = 90
          workout_id = Workout.create_workout_a 1, squat_weight, benchpress_weight, row_weight # hardcoding user_id to be 1 here
        elsif r.params['type'] == 'B'
          deadlift_weight = 150
          ohp_weight = 60
          pulldown_weight = 90
          workout_id = Workout.create_workout_b 1, deadlift_weight, ohp_weight, pulldown_weight # hardcoding user_id to be 1 here
        else
          @workout = Workout.new(account_id: 1, date: Time.now.utc).save_changes
          workout_id = @workout.id
        end

        # can we do a guid instead of a sequential id?
        r.redirect "workouts/#{workout_id}/"
      end
    end
  end
end

run App.freeze.app
