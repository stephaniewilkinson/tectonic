# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  class ProgramLift < Sequel::Model
    many_to_one :program_day
    many_to_one :exercise
  end
end