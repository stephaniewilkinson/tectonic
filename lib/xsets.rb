# frozen_string_literal: true

require_relative 'db'

class Xset < Sequel::Model
  many_to_one :exercise
  many_to_one :workout
end
