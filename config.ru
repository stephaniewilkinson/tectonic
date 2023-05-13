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
  PASSWORD = ENV.fetch 'PASSWORD'
  USERNAME = ENV.fetch 'USERNAME'
  USERS = ::DB[:users]
  WORKOUTS = ::DB[:workouts]
  EXERCISES = ::DB[:exercises]
  SETS = ::DB[:sets]

  plugin :assets, css: 'tailwind.css'
  plugin :default_headers, 'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains'
  plugin :head
  plugin :http_auth
  plugin :public, root: 'assets'
  plugin :render
  plugin :route_csrf
  plugin :slash_path_empty

  route do |r|
    r.assets
    r.public
    
    # GET /
    r.root do
      view 'welcome'
    end

    r.get 'home' do
      http_auth do |username, password|
        username == USERNAME && password == PASSWORD
      end
      view 'home'
    end
    
    r.on 'workouts' do
      r.post do
        if r.params['type'] == 'A'
          squat_weight = 150
          benchpress_weight = 60
          row_weight = 90
          workout_id = Workouts.create_workout_a 1, squat_weight, benchpress_weight, row_weight # hardcoding user_id to be 1 here
        end
        
        # can we do a guid instead of a sequential id?
        r.redirect "workouts/#{workout_id}"
      end
      r.get String do | workout_id |
       
        @workout = WORKOUTS.where(id: workout_id).first
        @exercises = EXERCISES.where(workout_id: workout_id)
        # @sets = for exercise in @exercises do
        #   binding.irb
        #   SETS.where(exercise_id = exercise[:id])
        # end
        
        view 'workouts/show'
      end
    end
  end
end

run App.freeze.app
