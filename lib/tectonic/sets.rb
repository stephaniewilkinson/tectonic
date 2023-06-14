# frozen_string_literal: true

require_relative 'db'
class Tectonic < Roda
  class Set < Sequel::Model
    many_to_one :exercise
    many_to_one :workout
  end
end
