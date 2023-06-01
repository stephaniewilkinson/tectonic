# frozen_string_literal: true

require 'rake/testtask'
require 'dotenv/load'
require_relative '.env'
require_relative 'lib/db'

task default: :test

Rake::TestTask.new do |test|
  test.pattern = 'spec/**/*_spec.rb'
  test.warning = false
end

namespace :db do
  task :seed do
    user_id = DB[:users].insert
    workout_id = DB[:workouts].insert(user_id:, date: Time.now.utc)
    exercise_id = DB[:exercises].insert(workout_id:, goal_weight: 40, name: 'Benchpress')
    DB[:sets].insert(exercise_id:, weight: 40, reps: 8)
    DB[:sets].insert(exercise_id:, weight: 40, reps: 8)
    DB[:sets].insert(exercise_id:, weight: 40, reps: 8)
    exercise_id = DB[:exercises].insert(workout_id:, goal_weight: 90, name: 'Squat')
    DB[:sets].insert(exercise_id:, weight: 90, reps: 5)
    DB[:sets].insert(exercise_id:, weight: 90, reps: 5)
    DB[:sets].insert(exercise_id:, weight: 90, reps: 5)
  end

  task :create_user do
    sh 'createuser -U postgres liftoff || true'
  end

  desc 'Setup development and test databases'
  task create: %i[create_user] do
    sh 'createdb -U postgres -O liftoff liftoff_development'
    sh 'createdb -U postgres -O liftoff liftoff_test'
  end

  desc 'Drop the development and test databases'
  task :drop do
    sh 'dropdb liftoff_development'
    sh 'dropdb liftoff_test'
  end

  desc 'Migrate development and test databases'
  task :migrate do
    Dir['migrate/*'].sort.each do |migration|
      sh "ruby #{migration}"
    end
  end
end
