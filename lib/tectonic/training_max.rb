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
    #
    # These two are not the same *kind* of number, and that is worth saying here rather than
    # discovering downstream. A derived answer is an estimated one-rep max: OneRepMax reads
    # SetScheme::RPE8_PERCENTS backwards, so it is an estimate of a single. A stated answer
    # is whatever the lifter typed into a box headed "training max", and in 5/3/1 and its
    # descendants a training max is deliberately about 90% of a one-rep max.
    #
    # So two lifters of identical strength can get loads about 10% apart depending only on
    # which branch answered. Nothing here corrects for that, and nothing should: applying a
    # coefficient would be the app choosing 0.85 or 0.90 on the lifter's behalf, and would
    # silently move every existing account's loads the day it shipped. What is done instead
    # is to say which number this is, everywhere it is shown, and to tell the lifter and the
    # assistant what scale the box is on -- so the two answers can be made to agree by the
    # person who knows which convention they train on.
    DERIVED = :derived

    # What a plausible max weighs, matching Bounds::WEIGHT, which every other load written
    # through MCP is checked against. Here as well as there because the two write paths were
    # not equally guarded: set_training_max refuses an out-of-range number by name, and the
    # browser form called `replace` directly -- so a fat-fingered 100000 went past numeric(7,2)
    # as an unhandled Sequel error, which reaches a person as a 500 and a lost edit. That is
    # #213's failure shape, and this is #211's answer to it: the rule sits where every caller
    # lands rather than on the one path that remembered it.
    PLAUSIBLE = (0..2000)

    # The day this number is as of, and both kinds have one (#293). For a stated max it is
    # when it was said; for a derived one it is when the set behind it was lifted.
    #
    # One accessor rather than two, because every reader asks the same question -- "how old
    # is this" -- and a caller that had to pick between stated_at and something else would be
    # re-deriving `source` to do it. `explanation` is where the two readings are told apart.
    attr_reader :pounds, :source, :as_of

    def initialize(pounds:, source:, as_of: nil)
      @pounds = pounds
      @source = source
      @as_of = as_of
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
      stated = DB[:account_training_maxes].where(account_id:, exercise_id: exercise.id).first
      return from_row(stated) if stated

      derived = exercise.estimated_reading(account_id:, on:)
      derived && new(pounds: derived[:pounds], source: DERIVED, as_of: derived[:on])
    end

    # The stored row as the object every caller reads. The column is numeric, so Sequel hands
    # back a BigDecimal, and the loads it feeds are multiplied by a percentage and rounded to
    # the rack -- Plates.numeric is the same conversion Equipment does on plate denominations,
    # and for the same reason: 315 should come back as 315 rather than as a decimal that
    # prints with a trailing zero everywhere it is displayed.
    def self.from_row(row)
      new(pounds: Plates.numeric(row[:pounds].to_r), source: STATED, as_of: row[:stated_at])
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
    # An implausible number is left alone rather than stored or cleared, and that is the
    # third answer rather than a missing one: storing it writes a block of nonsense loads,
    # and clearing it would let a typo silently delete a max somebody had set. Leaving the
    # stored value is the only outcome that loses nothing. The form carries min and max so a
    # browser refuses it first, and set_training_max refuses it by name; this is what holds
    # if anything reaches here without either.
    def self.replace(account_id, exercise_id, pounds)
      number = Float(pounds.to_s, exception: false)
      return clear(account_id, exercise_id) unless number&.positive?
      return unless PLAUSIBLE.cover?(number)

      DB[:account_training_maxes]
        .insert_conflict(target: %i[account_id exercise_id],
                         update: { pounds: number, stated_at: Sequel::CURRENT_TIMESTAMP })
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
    # should be seen to be making -- and, since it is an estimated *single* standing in for a
    # training max, an inference on a different scale from the one the box asks for.
    def explanation
      return 'the max you set' if stated?

      'an estimated one-rep max from your completed sets, since you have not set one'
    end

    # The date as a reader sees it, or nil where there is none to show. Nil is reachable on a
    # derived max whose set predates the join that carries the date, and on any caller that
    # built one by hand, so every display of this is guarded rather than assumed.
    def on_date
      as_of&.to_date
    end

    # The date as a clause, with its own leading space and its own preposition -- " on Aug 29,
    # 2026", or nothing at all where there is no date.
    #
    # Here rather than in the view because a view interpolating a strftime behind a guard is a
    # long line doing two jobs, and both places that show this had grown one. Returning the
    # empty string rather than nil is what lets a template interpolate it with no conditional
    # around the punctuation that follows.
    def since(preposition = 'on')
      return '' unless on_date

      " #{preposition} #{on_date.strftime('%b %-d, %Y')}"
    end
  end
end

