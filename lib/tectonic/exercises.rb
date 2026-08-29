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

    one_to_many :sets, class: 'Tectonic::WorkoutSet'
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

    # Rows an account may write to: its own, and never a library row. Reads go through
    # visible_to, which folds the shared library in, and a write cannot -- a library row
    # is on every account's page, so a value written to one is a value one account wrote
    # and every other account reads. The IS NOT NULL is not redundant beside the
    # equality: a nil account_id arriving here, from a token that resolved no account,
    # would otherwise mean where(account_id: nil), which is the entire library, handed
    # back as writable. That is precisely the thing this method exists to refuse.
    def self.owned_by(account_id)
      where(account_id:).exclude(account_id: nil)
    end

    # A nil account_id marks a shared library exercise, visible to everyone; any
    # other value is a single account's own.
    def library?
      account_id.nil?
    end

    # A note as it should be stored: nil when there is nothing in it. The textarea is
    # posted whether or not anyone typed in it, so "left blank" arrives as an empty
    # string, and the two spellings read differently afterwards -- '' is truthy, so a
    # blank note would draw its own empty paragraph above the chart forever. Stripping
    # first means a note of nothing but whitespace does not count as one either.
    def self.clean_note(raw)
      text = raw.to_s.strip
      text.empty? ? nil : text
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
    # planned_rpe joins the select with #294: it is what the chart reads a set at when the
    # lifter did not rate it, and it was sitting on the row unread since #265.
    def lifted_sets(account_id, on)
      mine = Workout.where(account_id:).where { date < (on + 1) }.select(:id)
      WorkoutSet.where(exercise_id: id, workout_id: mine, is_completed: true)
                .select(:weight, :reps, :rpe, :planned_rpe).all
    end
  end
end

