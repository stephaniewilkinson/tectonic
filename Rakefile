# frozen_string_literal: true

require 'rake/testtask'
require 'dotenv/load'
require_relative '.env'

task default: :test

Rake::TestTask.new do |test|
  test.pattern = 'spec/**/*_spec.rb'
  test.warning = false
end

namespace :db do
  task :create_user do
    sh 'createuser -U postgres tectonic || true'
  end

  desc 'Setup development and test databases'
  task create: %i[create_user] do
    sh 'createdb -U postgres -O tectonic tectonic_development'
    sh 'createdb -U postgres -O tectonic tectonic_test'
  end

  desc 'Drop the development and test databases'
  task :drop do
    sh 'dropdb tectonic_development'
    sh 'dropdb tectonic_test'
  end

  desc 'Migrate development and test databases'
  task :migrate do
    Dir['migrate/*'].sort.each do |migration|
      sh "ruby #{migration}"
    end
  end
end
