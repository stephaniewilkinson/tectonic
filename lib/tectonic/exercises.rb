# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'measured'
require_relative 'oauth_application'
require_relative 'one_rep_max'
require_relative 'sets'
require_relative 'workouts'

class Tectonic < Roda
  class Exercise < Sequel::Model
    # The usual way this movement is counted, as a symbol.
    def default_measure
      Measured.cast(super)
    end

    one_to_many :sets
    # The OAuth client (LLM) that created this row, or nil for a human-made one.
    # Provenance is displayed only when this resolves, so the web UI's rows stay
    # unadorned.
    many_to_one :created_by_oauth_application, class: 'Tectonic::OAuthApplication',
                                               key: :created_by_oauth_application_id

    # Rows an account may select or view: its own plus the shared library, whose
    # account_id is nil. account_id IN (nil, id) can't stand in for this -- SQL's
    # IN never matches NULL, so it would silently drop the entire library.
    def self.visible_to(account_id)
      where(account_id:).or(account_id: nil)
    end

    # A nil account_id marks a shared library exercise, visible to everyone; any
    # other value is a single account's own.
    def library?
      account_id.nil?
    end

    # The best estimated max an account's completed sets of this movement support as of a
    # date, or nil while nothing has been lifted that the chart can read. Answering as of
    # a date rather than only for today is the point: asked at the end of each week, it is
    # the curve a training block is actually judged by.
    def estimated_max(account_id:, on: Date.today)
      OneRepMax.best_of(lifted_sets(account_id, on))
    end

    # An account's own completed sets of this movement, up to and including a date. Scoped
    # through the workouts rather than the sets alone, because a library movement is
    # shared and the work done on it is not: another account's lifting must never reach
    # this number.
    def lifted_sets(account_id, on)
      mine = Workout.where(account_id:).where { date < (on + 1) }.select(:id)
      Set.where(exercise_id: id, workout_id: mine, is_completed: true).select(:weight, :reps, :rpe).all
    end
  end
end

