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

    # What fraction of a stated number a lifter actually trains off, bounded the way the
    # column is (#292). A training max above the max it is a percentage of is not a thing,
    # and neither is one at twenty percent; both are typos.
    TRAIN_AT = (50..100)
    # Training off the whole number, which is what a competition-max convention says and
    # what every row written before #292 means.
    WHOLE = 100

    # The day this number is as of, and both kinds have one (#293). For a stated max it is
    # when it was said; for a derived one it is when the set behind it was lifted.
    #
    # One accessor rather than two, because every reader asks the same question -- "how old
    # is this" -- and a caller that had to pick between stated_at and something else would be
    # re-deriving `source` to do it. `explanation` is where the two readings are told apart.
    # `pounds` is what percentages are taken of, which since #292 is not always what the
    # lifter typed: `stated_pounds` is the number they entered and `train_at_percent` is the
    # fraction of it they train off, and `pounds` is those two multiplied out. Every caller
    # doing arithmetic wants the product; the two parts are for showing the working.
    attr_reader :pounds, :source, :as_of, :stated_pounds, :train_at_percent

    def initialize(pounds:, source:, as_of: nil, stated_pounds: nil, train_at_percent: WHOLE)
      @pounds = pounds
      @source = source
      @as_of = as_of
      @stated_pounds = stated_pounds || pounds
      @train_at_percent = train_at_percent
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

      derived(account_id:, exercise:, on:)
    end

    # What this max was on a date that has passed, for reporting and for nothing else. #308.
    #
    # `for` answers "what is the max" -- a standing instruction with no history to be as-of,
    # which is why it passes `on` to the derivation and not to the stated lookup. That is the
    # right answer to that question and it is unchanged. But it makes a second question
    # unanswerable: "what did the block I ran in March actually open at". Since #291 a block
    # fixes its denominator at its start date, so that is a well-defined quantity, and for a
    # stated max the current row could not produce it -- restating 315 as 325 left nothing
    # behind saying it was ever 315.
    #
    # **This resolves and nothing generates off it.** One rule decides what to lift and it is
    # `for`; this reads a log of what was said and when. Two rules for one question is what
    # this class exists to prevent, and these are two questions -- keeping them in separate
    # methods with the boundary named is the only way to have the second without losing the
    # first. In particular #291's escape hatch survives: restating a max still moves the
    # block you are in when you regenerate it, because regeneration goes through `for`.
    #
    # Falling through to the derived reading where no statement is old enough is not a gap,
    # it is the truth: before a lifter stated anything, the app was generating against the
    # estimate, so that is what that block opened at.
    def self.as_of(account_id:, exercise:, on:)
      said = statement(account_id, exercise.id, on)
      return from_row(said) if said && said[:pounds]

      derived(account_id:, exercise:, on:)
    end

    # The last thing said about this movement on or before a date, or nil if nothing had been
    # said yet. A row whose pounds are null is a lifter who cleared their max, and it is a
    # statement like any other -- it is what stops a block run after a clear from reporting
    # the number that was stated before it.
    def self.statement(account_id, exercise_id, on)
      DB[:account_training_max_statements]
        .where(account_id:, exercise_id:)
        .where { stated_at < (on + 1) }
        .order(Sequel.desc(:stated_at), Sequel.desc(:id)).first
    end

    def self.derived(account_id:, exercise:, on:)
      reading = exercise.estimated_reading(account_id:, on:)
      reading && new(pounds: reading[:pounds], source: DERIVED, as_of: reading[:on])
    end

    # The stored row as the object every caller reads. The column is numeric, so Sequel hands
    # back a BigDecimal, and the loads it feeds are multiplied by a percentage and rounded to
    # the rack -- Plates.numeric is the same conversion Equipment does on plate denominations,
    # and for the same reason: 315 should come back as 315 rather than as a decimal that
    # prints with a trailing zero everywhere it is displayed.
    # `pounds` is the product rather than the column, which is the whole of #292: a lifter
    # who says "my squat is 500 and I train off 90%" is generated against 450, and both
    # halves survive so the page can show the arithmetic that produced it. A row written
    # before #292 carries 100 and multiplies out to itself.
    def self.from_row(row)
      stated = Plates.numeric(row[:pounds].to_r)
      percent = row[:train_at_percent] || WHOLE
      new(pounds: Plates.numeric((stated * percent / 100.0).to_r), source: STATED,
          as_of: row[:stated_at], stated_pounds: stated, train_at_percent: percent)
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
    #
    # `train_at` is the fraction of that number the lifter trains off (#292), defaulting to
    # the whole of it. Out of range is ignored the same way an implausible weight is, and for
    # the same reason: the stored value is the only outcome that loses nothing.
    def self.replace(account_id, exercise_id, pounds, train_at: WHOLE)
      number = Float(pounds.to_s, exception: false)
      return clear(account_id, exercise_id) unless number&.positive?
      return unless PLAUSIBLE.cover?(number)

      store(account_id, exercise_id, number, fraction(train_at))
    end

    # The current answer and the record of having given it, written together (#308).
    #
    # The upsert is the answer to "what is my max" and there is one row of it per movement.
    # The log below cannot be an upsert -- repetition is the whole point of it, since a lifter
    # who restates 315 as 325 has said two things and a block ran against each. In one
    # transaction because a current row with no statement behind it would make a block report
    # whatever could still be derived for it, which is a quieter wrong answer than an error.
    def self.store(account_id, exercise_id, pounds, percent)
      DB.transaction do
        DB[:account_training_maxes]
          .insert_conflict(target: %i[account_id exercise_id],
                           update: { pounds:, train_at_percent: percent,
                                     stated_at: Sequel::CURRENT_TIMESTAMP })
          .insert(account_id:, exercise_id:, pounds:, train_at_percent: percent)
        DB[:account_training_max_statements]
          .insert(account_id:, exercise_id:, pounds:, train_at_percent: percent)
      end
    end

    # A percentage as it should be stored: the whole number where nothing usable was given,
    # so a blank box means "off the number I typed" rather than refusing the save.
    def self.fraction(train_at)
      number = Integer(train_at.to_s, 10, exception: false)
      number && TRAIN_AT.cover?(number) ? number : WHOLE
    end

    # Emptying the box hands the movement back to the derived estimate, and that is logged
    # too (#308) -- as a statement carrying no pounds, which is what "I no longer state one"
    # looks like. Without it, `as_of` reading a block run after a clear would find the
    # statement *before* the clear and report a number the block was never generated
    # against, which is worse than reporting nothing.
    #
    # Only where there was something to clear. Saving an empty box on a movement that never
    # had a stated max is not a statement about anything, and a log full of those would put
    # a null in front of every honest number behind it.
    def self.clear(account_id, exercise_id)
      DB.transaction do
        removed = DB[:account_training_maxes].where(account_id:, exercise_id:).delete
        DB[:account_training_max_statements].insert(account_id:, exercise_id:) if removed.positive?
        removed
      end
    end

    def stated? = source == STATED

    def derived? = source == DERIVED

    # How the number should be introduced wherever it is shown beside a percentage. The two
    # readings are far enough apart to be worth a sentence rather than a word: a stated max
    # is a fact about the lifter, and a derived one is an inference the app is making and
    # should be seen to be making -- and, since it is an estimated *single* standing in for a
    # training max, an inference on a different scale from the one the box asks for.
    # Whether the stated number and the number trained off are different, which is when the
    # arithmetic is worth showing. False for a competition-max convention, and for every row
    # written before #292.
    def discounted?
      stated? && train_at_percent != WHOLE
    end

    # "500 lb x 90%", for a page that wants to show its working. Nil where there is none to
    # show, so a caller guards on the value rather than on the convention.
    def working
      return nil unless discounted?

      "#{Plates.numeric(stated_pounds)} lb \u00d7 #{train_at_percent}%"
    end

    # How a stated max introduces itself on its own page: what it is, and when it was said.
    # One method rather than a conditional in the template, which erb_lint is right to
    # dislike -- a view choosing between two phrasings and then appending a third is three
    # decisions in a tag, and the tag has to be split across lines to fit.
    def stated_phrase
      "#{discounted? ? "which is #{working}" : 'which you set'}#{since}"
    end

    def explanation
      return "#{train_at_percent}% of the #{Plates.numeric(stated_pounds)} lb max you set" if discounted?
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

