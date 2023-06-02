# frozen_string_literal: true

require 'dotenv/load'
require 'http'
require 'rack'
require 'rack/auth/basic'
require 'roda'
require 'tilt'
require_relative 'lib/db'
require_relative 'lib/workouts'

class App < Roda
  ACCOUNTS = ::DB[:accounts]
  EXERCISES = ::DB[:exercises]
  SESSION_SECRET = ENV.fetch 'SESSION_SECRET'
  SETS = ::DB[:sets]
  USERNAME = ENV.fetch 'USERNAME'
  WORKOUTS = ::DB[:workouts]

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

      r.on String do |workout_id|
        @workout = WORKOUTS[id: workout_id]
        r.on 'exercises' do
          r.on String do |exercise_id|
            @exercise = EXERCISES[id: exercise_id]
            r.on 'sets' do
              r.on 'new' do
                r.get do
                  view 'sets/new'
                end
                r.post do
                  set_id = SETS.insert(weight: r.params['weight'], reps: r.params['reps'], exercise_id:)
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
                  set_id = SETS.where(id: set_id).update(weight: r.params['weight'], reps: r.params['reps'])
                  @set = SETS[id: set_id]
                  view 'sets/show'
                end
              end
            end

            r.get do
              @sets = SETS.where(exercise_id: @exercise[:id])
              view 'exercises/show'
            end
          end
        end

        r.is do
          @workout = WORKOUTS.where(id: workout_id).first
          @exercises = EXERCISES.where(workout_id:)
          @exercises_and_sets = @exercises.map do |exercise|
            [exercise, SETS.where(exercise_id: exercise[:id])]
          end
          view 'workouts/show'
        end
      end
      r.get do
        @workouts = WORKOUTS.all
        view 'workouts/index'
      end
      r.post do
        if r.params['type'] == 'A'
          squat_weight = 150
          benchpress_weight = 60
          row_weight = 90
          workout_id = Workouts.create_workout_a 1, squat_weight, benchpress_weight, row_weight # hardcoding user_id to be 1 here
        end

        if r.params['type'] == 'B'
          deadlift_weight = 150
          ohp_weight = 60
          pulldown_weight = 90
          workout_id = Workouts.create_workout_b 1, deadlift_weight, ohp_weight, pulldown_weight # hardcoding user_id to be 1 here
        end

        # can we do a guid instead of a sequential id?
        r.redirect "workouts/#{workout_id}/"
      end
    end
  end
end

run App.freeze.app
