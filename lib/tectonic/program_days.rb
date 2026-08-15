# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  class ProgramDay < Sequel::Model
    many_to_one :program
    one_to_many :program_lifts
  end
end

