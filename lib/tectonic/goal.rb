# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'plates'

class Tectonic < Roda
  # What a lifter is aiming at on a movement, and when they want it by. #308.
  #
  # "Am I on pace" was unanswerable, and not for want of data: `list_programs` shows blocks,
  # `account_training_maxes` says what each was generated against, and #291 made "the max
  # this block opened at" a well-defined quantity. What was missing is the thing pace is
  # measured *against* -- a number and a date -- so the app could show a trend and could not
  # say whether it was enough.
  #
  # **On the account rather than on a block**, which is the decision worth recording. A block
  # already states its own aim: the generator writes `planned_weight` on every set, so the
  # heaviest planned load per movement is what this cycle is reaching for, stored and
  # readable today. The standing goal is the one with nowhere to live -- it outlives the
  # block, and it belongs beside `account_plates` and `account_training_maxes` the way
  # `bar_weight` and `week_starts_on` sit beside the account.
  #
  # **A date per goal**, because a meet has a date and so does "405 before the summer", and a
  # lifter aiming at a total is aiming at three numbers on one day and possibly a fourth on
  # another. One date on the account expresses one of those and quietly mis-files the rest.
  #
  # **Nothing here computes "behind schedule".** The goal, its date and what each block opened
  # at are reported, and the assistant judges -- which is the same split #263 settled, and it
  # matters more here than it did there. Pace on a barbell is not linear, a peaking block
  # moves a max in a way a hypertrophy block deliberately does not, and an app dividing
  # pounds by weeks would call a correctly-run offseason a failure every time.
  class Goal
    # What a plausible goal weighs, matching TrainingMax::PLAUSIBLE and Bounds::WEIGHT, so a
    # number is refused the same way wherever it is typed.
    PLAUSIBLE = (0..2000)

    attr_reader :pounds, :by_date, :set_at, :exercise_id

    def initialize(pounds:, by_date: nil, set_at: nil, exercise_id: nil)
      @pounds = pounds
      @by_date = by_date
      @set_at = set_at
      @exercise_id = exercise_id
    end

    # This account's goal on a movement, or nil where none has been set. Nil rather than a
    # zero-valued object, because "no goal" is a state the readers have to say something
    # different about -- a page showing "0 lb by nothing" would be worse than a page silent.
    def self.for(account_id:, exercise_id:)
      row = DB[:account_goals].where(account_id:, exercise_id:).first
      row && from_row(row)
    end

    # Every goal this account holds, keyed by movement, for the read that shows them all at
    # once. One query rather than one per movement, which is what a block of six lifts would
    # otherwise cost.
    def self.all_for(account_id)
      DB[:account_goals].where(account_id:).to_h { |row| [row[:exercise_id], from_row(row)] }
    end

    def self.from_row(row)
      new(pounds: Plates.numeric(row[:pounds].to_r), by_date: row[:by_date],
          set_at: row[:set_at], exercise_id: row[:exercise_id])
    end

    # Saves what a lifter typed, or clears it when they typed nothing.
    #
    # The rules are TrainingMax.replace's, deliberately, because this is the same kind of box
    # holding the same kind of number and two per-movement weights that disagreed about what
    # a blank means would be a trap: blank clears rather than storing zero, anything
    # unparseable is dropped rather than guessed at, and an implausible number leaves the
    # stored value alone -- storing it writes nonsense, and clearing would let a typo delete
    # a goal somebody set, so leaving it is the only outcome that loses nothing.
    #
    # An upsert on the pair, since a lifter who moves a target from 405 to 425 is answering
    # the same question again rather than asking a second one.
    def self.replace(account_id, exercise_id, pounds, by_date: nil)
      number = Float(pounds.to_s, exception: false)
      return clear(account_id, exercise_id) unless number&.positive?
      return unless PLAUSIBLE.cover?(number)

      DB[:account_goals]
        .insert_conflict(target: %i[account_id exercise_id],
                         update: { pounds: number, by_date: parse_date(by_date),
                                   set_at: Sequel::CURRENT_TIMESTAMP })
        .insert(account_id:, exercise_id:, pounds: number, by_date: parse_date(by_date))
    end

    def self.clear(account_id, exercise_id)
      DB[:account_goals].where(account_id:, exercise_id:).delete
    end

    # A date or nothing at all. Unparseable is nil rather than an error, on the same terms as
    # an unparseable weight: a goal with a bad date is still a goal, and refusing the whole
    # save over the optional half of it would lose the number the lifter came to type.
    def self.parse_date(raw)
      return raw if raw.is_a?(Date)
      return nil if raw.nil? || raw.to_s.strip.empty?

      Date.parse(raw.to_s)
    rescue Date::Error
      nil
    end

    # How far there is to go from a max, in pounds. Negative where the goal has been passed,
    # which is worth saying as a number rather than clamping to zero: a lifter 15 lb past a
    # target set in January wants to see that, and a floor at zero would read as having only
    # just arrived.
    def remaining_from(pounds)
      return nil if pounds.nil?

      Plates.numeric((@pounds - pounds).to_r)
    end

    # Days from a date to the deadline, or nil where there is no deadline to count to.
    # Negative once the date has passed, for the same reason the pounds are: a goal whose day
    # has been and gone is a fact the reader needs, not one to round away.
    def days_from(today = Date.today)
      return nil unless by_date

      (by_date - today).to_i
    end

    # The date as a reader sees it, or nil where there is none. The same format
    # TrainingMax#since uses, so two dates on one page agree about shape.
    def by_phrase
      by_date&.strftime('%b %-d, %Y')
    end

    # The three sentences a page says about a goal, here rather than in the template for
    # TrainingMax#stated_phrase's reason: a view choosing between two phrasings and then
    # appending a third is three decisions inside a tag, and erb_lint is right to dislike it.
    # Each returns the empty string rather than nil where there is nothing to say, so a
    # template interpolates it with no conditional around the punctuation.
    def deadline_phrase
      by_date ? " by #{by_phrase}" : ''
    end

    # How far there is to go, or how far past it you are. Both worth saying: a lifter 15 lb
    # beyond a target set in January wants to see that rather than a gap rounded to nothing.
    def gap_phrase(pounds_now)
      gap = remaining_from(pounds_now)
      return '' if gap.nil?
      return "You are #{Plates.numeric(-gap)} lb past it." if gap.negative?
      return 'You are there.' if gap.zero?

      "That is #{gap} lb from what percentages are worked out from today."
    end

    # The deadline as a countdown, and nothing more. No "you need 5 lb a week": pace on a
    # barbell is not linear, and an app doing that arithmetic would call a correctly-run
    # offseason a failure every time. See the note on the class.
    def days_phrase(today = Date.today)
      days = days_from(today)
      return '' if days.nil?
      return "That date passed #{-days} day(s) ago." if days.negative?
      return 'That is today.' if days.zero?

      "#{days} day(s) to go."
    end
  end
end

