# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  class Program < Sequel::Model
    one_to_many :program_days
  end
end

