# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'plates'

class Tectonic < Roda
  # The number a percentage is taken of, and where it came from. #264.
  #
  # There are two answers to "what is this account's max on this movement" and they are not
  # interchangeable. One is stated: somebody typed 315 because they know what they lift. The
  # other is derived: `Exercise#estimated_max` reads the completed sets through the RPE chart
  # and says what they imply. The stated one wins where it exists, and the derived one is the
  # fallback -- so the honest default stays for everybody who has not said anything, and the
  # override exists for the two cases derivation cannot reach.
  #
  # This class exists so that rule is written once. Three callers ask the question -- the
  # generator resolving a percentage lift, the movement's own page, and the MCP history tool
  # -- and a fallback re-implemented at three call sites is a fallback that disagrees with
  # itself at two of them. Every one of them goes through `for`.
  #
  # It answers with an object rather than a number because *which* answer it gave is part of
  # the answer. "315 lb" and "315 lb, which we worked out from your lifting" are different
  # claims, and a page that shows the second as the first is telling somebody they set a
  # number they never set. `source` is what lets a caller say which without asking again.
  class TrainingMax
    # Stated by the lifter, and the reason this table exists.
    STATED = :stated
    # Read out of completed sets by OneRepMax, which is what the app did before and still
    # does for anybody who has not stated one.
    DERIVED = :derived

    attr_reader :pounds, :source

    def initialize(pounds:, source:)
      @pounds = pounds
      @source = source
    end

    # The max to generate against, or nil when there is neither a stated one nor enough
    # lifting to derive one -- which is the case ProgramGenerator refuses a week over, and
    # it stays a refusal rather than becoming a guess.
    #
    # `on` is passed through to the derivation and not to the lookup, deliberately. A
    # derived max is a reading of history and therefore has a date: asked at the end of a
    # block it should answer what was true then. A stated one is a standing instruction with
    # no history to be as-of, so it is the answer whatever date is asked about.
    def self.for(account_id:, exercise:, on: Date.today)
      stated = stated_pounds(account_id, exercise.id)
      return new(pounds: stated, source: STATED) if stated

      derived = exercise.estimated_max(account_id:, on:)
      derived && new(pounds: derived, source: DERIVED)
    end

    # The stored number as something the arithmetic can use. The column is numeric, so
    # Sequel hands back a BigDecimal, and the loads it feeds are multiplied by a percentage
    # and then rounded to the rack -- Plates.numeric is the same conversion Equipment does
    # on plate denominations, and for the same reason: 315 should come back as 315 and not
    # as a decimal that prints with a trailing zero everywhere it is displayed.
    def self.stated_pounds(account_id, exercise_id)
      stored = DB[:account_training_maxes].where(account_id:, exercise_id:).get(:pounds)
      stored && Plates.numeric(stored.to_r)
    end

    # Saves what a lifter typed, or clears it when they typed nothing.
    #
    # Blank clears rather than storing zero, which is the difference between "I have not
    # said" and "I have said nothing" -- the first has to leave the derived max in charge,
    # and the constraint refuses the second outright. That makes the form's empty box the
    # way back to the estimate, which is the only way back there would otherwise be.
    #
    # An upsert rather than an insert, because the unique index is on the pair: a lifter who
    # corrects 315 to 325 is answering the same question again, not asking a second one.
    # Anything unparseable is dropped rather than guessed at, the same as Equipment.owned
    # does with a denomination, and a non-positive number is refused before it reaches the
    # constraint so the caller is not handed a database error to render.
    def self.replace(account_id, exercise_id, pounds)
      number = Float(pounds.to_s, exception: false)
      return clear(account_id, exercise_id) unless number&.positive?

      DB[:account_training_maxes]
        .insert_conflict(target: %i[account_id exercise_id], update: { pounds: number })
        .insert(account_id:, exercise_id:, pounds: number)
    end

    def self.clear(account_id, exercise_id)
      DB[:account_training_maxes].where(account_id:, exercise_id:).delete
    end

    def stated? = source == STATED

    def derived? = source == DERIVED

    # How the number should be introduced wherever it is shown beside a percentage. The two
    # readings are far enough apart to be worth a sentence rather than a word: a stated max
    # is a fact about the lifter, and a derived one is an inference the app is making and
    # should be seen to be making.
    def explanation
      return 'the max you set' if stated?

      'estimated from your completed sets'
    end
  end
end

