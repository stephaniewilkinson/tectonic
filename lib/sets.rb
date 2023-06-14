# frozen_string_literal: true

require_relative 'workouts'
require_relative 'db'

class Set < Sequel::Model
  many_to_one :exercise
  many_to_one :workout
end
