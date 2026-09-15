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

    # Sets already logged, brought into line when the movement's own answer changes. #392.
    #
    # A set carries its own is_per_side, copied from the movement when it was written, and
    # that copy is right: a set records how it was done, the way planned_weight records what
    # was asked for. Changing a movement must not reach back and rewrite training.
    #
    # Except that this particular flag is not a choice somebody made per set. It is a fact
    # about the movement -- a split squat is done one leg at a time and always was -- and the
    # only reason a logged set says otherwise is that the app did not know yet. Marking the
    # clamshell per side and finding yesterday's session still counting both legs as one is
    # #392, and the volume on that session is out by half until this runs.
    #
    # **Only the sets still carrying the old answer move.** A set an assistant set explicitly
    # against the default was a decision about that set, and this is not entitled to overrule
    # it. So the update is scoped to rows whose flag equals what the movement used to say,
    # which is exactly the set of rows that were following the movement rather than differing
    # from it.
    #
    # Scoped through the account's own workouts as well as by exercise. It cannot matter today
    # -- only a private movement is editable, so every set of it is the owner's -- but the
    # scope is what keeps that true if a library movement ever becomes editable, and an
    # unscoped UPDATE on a shared row would rewrite every account's training at once.
    def self.align_sets_per_side(exercise, account_id, was:)
      WorkoutSet.where(exercise_id: exercise.id, is_per_side: was)
                .where(workout_id: Workout.where(account_id:).select(:id))
                .update(is_per_side: !was)
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

    # How many dumbbells, off a form. #439.
    #
    # Blank stays null, because "not said" is a real answer and the column exists to keep it
    # distinguishable from a deliberate two -- that difference is what makes it possible to
    # ask which movements still want one. Anything that is not 1 or 2 becomes null as well:
    # the check constraint would otherwise refuse the write and surface as a 500 on a Save
    # button, and there is no third answer a lifter could have meant.
    def self.clean_dumbbell_count(raw)
      count = raw.to_s.strip.to_i
      [1, 2].include?(count) ? count : nil
    end

    # The best estimated max an account's completed sets of this movement support as of a
    # date, or nil while nothing has been lifted that the chart can read. Answering as of
    # a date rather than only for today is the point: asked at the end of each week, it is
    # the curve a training block is actually judged by.
    def estimated_max(account_id:, on: Date.today)
      OneRepMax.best_of(lifted_sets(account_id, on))
    end

    # The same estimate with the day the set behind it was lifted, for the callers that
    # report it rather than only calculate with it. #293.
    #
    # A separate method rather than a wider return from estimated_max, because three callers
    # want the number alone and changing what they get would be churn for nothing. Both read
    # the same rows through the same scope, so the two cannot disagree.
    def estimated_reading(account_id:, on: Date.today)
      OneRepMax.best_reading(lifted_sets(account_id, on))
    end

    # The same, restricted to readings the chart is sure enough of to let stand on their own.
    #
    # This is what a training max derives from, and the pair is the point: `estimated_reading`
    # above is the best estimate there is and gets drawn, this is the best one allowed to
    # become a number the app then prescribes against. A movement trained in eights has the
    # first and not the second.
    def confident_reading(account_id:, on: Date.today)
      OneRepMax.best_confident_reading(lifted_sets(account_id, on))
    end

    # What recent training implies, as against what has ever been demonstrated. #307, and
    # the windowed companion #293 named and deliberately left unbuilt.
    #
    # `estimated_reading` above answers "the most that has been demonstrated", which is the
    # right meaning for a max and is also the one that goes quietly stale: there is no lower
    # bound on it, so a number earned on a single three years ago outranks everything since
    # and nothing about the number says so. #293 answered half of that by carrying the date.
    # This answers the other half, by saying what the last twelve, twenty-six and fifty-two
    # weeks each support on their own.
    #
    # **It does not replace the lifetime best and must not.** Nothing here decays, expires or
    # discounts anything -- a window is a second reading beside the first, and the gap between
    # them is information rather than a correction. A lifetime best of 315 from 2023 next to a
    # twelve-week best of 290 is a lifter who has not been near their best recently; the same
    # 315 next to a twelve-week 315 is a lifter who is there now. Collapsing the two would
    # throw away exactly the distinction the reader is reaching for. Which of them to open a
    # block at is a judgement, and this app does not make judgements -- it reports both and
    # leaves the arguing to somebody who can be argued with.
    #
    # **One query, not one per window.** The widest window is read once and the narrower ones
    # are taken from those rows in memory. Three queries for three answers about the same
    # movement would be three round trips on a read that already makes several, and they
    # could disagree at a date boundary if a set landed between them.
    #
    # `sets` rides along with each reading because a number off one set and a number off forty
    # are not the same claim, and the caller cannot tell them apart from the pounds alone.
    def recent_readings(account_id:, windows:, on: Date.today)
      rows = lifted_sets(account_id, on, since: on - (windows.max * 7))
      windows.map { |weeks| window_reading(rows, weeks, on) }
    end

    # One window's worth of those rows. Nil pounds rather than an absent entry where the
    # window holds nothing readable, so a caller gets the same three windows every time and
    # "nothing in the last twelve weeks" is itself an answer -- which on a movement somebody
    # has stopped training is the most useful thing this can say.
    def window_reading(rows, weeks, on)
      since = on - (weeks * 7)
      inside = rows.select { |row| row[:date].to_date >= since }
      { weeks:, sets: inside.length, pounds: nil, on: nil }
        .merge(OneRepMax.best_reading(inside) || {})
    end

    # An account's own completed sets of this movement, up to and including a date. Scoped
    # through the workouts rather than the sets alone, because a library movement is
    # shared and the work done on it is not: another account's lifting must never reach
    # this number.
    # planned_rpe joins the select with #294: it is what the chart reads a set at when the
    # lifter did not rate it, and it was sitting on the row unread since #265. The session's
    # date joins it with #293, which is what lets a reader say when a max was earned -- from
    # a join rather than a second query, so the number and its date cannot disagree.
    # `since` is the lower bound #307 needed and this never had: every caller before it
    # wanted everything up to a date, which is what a lifetime best means. Absent, it still
    # does, so the three existing callers are untouched.
    def lifted_sets(account_id, on, since: nil)
      mine = Workout.where(account_id:).where { date < (on + 1) }
      mine = mine.where { date >= since } if since
      WorkoutSet.where(exercise_id: id, workout_id: mine.select(:id), is_completed: true)
                .join(:workouts, id: :workout_id).select(*READ_COLUMNS).all
    end

    # Qualified because `date` is on workouts while the rest are on sets, and unqualified it
    # is ambiguous the moment the two tables meet.
    READ_COLUMNS = [
      Sequel[:sets][:weight], Sequel[:sets][:reps], Sequel[:sets][:rpe],
      Sequel[:sets][:planned_rpe], Sequel[:workouts][:date]
    ].freeze
  end
end

