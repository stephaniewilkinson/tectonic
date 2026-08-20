# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  # A day of one written week: a weekday rather than a date, so the week it belongs to
  # is what decides when it actually falls.
  class ProgramDay < Sequel::Model
    many_to_one :program_week
    one_to_many :program_lifts
  end
end

