# frozen_string_literal: true

require_relative 'db'

class Exercise < Sequel::Model
  one_to_many :sets
end
