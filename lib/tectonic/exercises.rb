# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  class Exercise < Sequel::Model
    one_to_many :sets
  end
end
