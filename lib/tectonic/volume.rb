# frozen_string_literal: true

require 'date'
require_relative 'db'

class Tectonic < Roda
  # What a block actually contained, folded into weeks. Every other view in the app is a
  # list of rows -- a table of sets, a table of dates -- which answers "what did I do on
  # Tuesday" and cannot answer "is my volume going up".
  #
  # Two definitions do most of the work here, and both are narrower than they look.
  #
  # A warmup is not training. Counting the ramp would let somebody add tonnage by warming
  # up more carefully, which is the opposite of what the number is for.
  #
  # An uncompleted set is a plan, not work. The generator writes a whole session ahead of
  # time with `is_completed` false, so counting rows rather than completions would credit
  # a lifter for a session they have not done yet -- and the further ahead a block is
  # written, the more it would flatter them. `is_completed` is nullable, and a null is
  # not a completion; `where(is_completed: true)` renders as IS TRUE, so nulls are out.
  module Volume
    # Postgres truncates to a Monday, which is the week a training block is written in.
    WEEK = Sequel.function(:date_trunc, 'week', Sequel[:workouts][:date])
    # The columns these aggregates read. Named once because every query below qualifies
    # the same handful across a three-table join, and spelled-out qualification is what
    # made these chains unreadable.
    ACCOUNT = Sequel[:workouts][:account_id]
    TRAINED_ON = Sequel[:workouts][:date]
    WARMUP = Sequel[:sets][:is_warmup]
    COMPLETED = Sequel[:sets][:is_completed]
    LIFT = Sequel[:sets][:exercise_id]
    NAME = Sequel[:exercises][:name]
    COUNTED = Sequel.as(Sequel.function(:count, Sequel.lit('*')), :sets)
    REPPED = Sequel.as(Sequel.function(:sum, Sequel[:sets][:reps]), :reps)
    LIFTED = Sequel.as(Sequel.function(:sum, Sequel[:sets][:weight] * Sequel[:sets][:reps]), :tonnage)
    HEAVIEST = Sequel.as(Sequel.function(:max, Sequel[:sets][:weight]), :heaviest)
    # The windows worth offering: a block, a half year, a year.
    WINDOWS = [12, 26, 52].freeze
    DEFAULT_WEEKS = 12
    # How many lifts the intensity chart draws before it stops being readable. The rest
    # are counted and named in prose rather than silently dropped.
    SERIES = 5

    module_function

    # The sets that count as work: this account's, not warmups, actually done.
    def working_sets(account_id, exercise_id: nil, weeks: DEFAULT_WEEKS)
      # An endless range rather than a where block: a block is instance-evalled against
      # a virtual row, where `window_start(weeks)` would be read as the name of a SQL
      # function rather than called, and the comparison has to be written backwards to
      # keep it out of the block's way.
      sets = DB[:sets].join(:workouts, id: :workout_id)
                      .where(ACCOUNT => account_id).exclude(WARMUP => true)
                      .where(COMPLETED => true).where(TRAINED_ON => window_start(weeks)..)
      exercise_id ? sets.where(LIFT => exercise_id) : sets
    end

    # Weekly sets, reps and tonnage, oldest first, with untrained weeks filled in as
    # zero. The gap is the point: a week off is really no volume, and the question this
    # page exists to answer -- did adherence fall away in week three -- is invisible if
    # the empty weeks simply close up and leave a line that never dips.
    def weekly(account_id, exercise_id: nil, weeks: DEFAULT_WEEKS)
      recorded = totals(account_id, exercise_id:, weeks:)
      return [] if recorded.empty?

      span(recorded.first[:week], weeks).map do |week|
        recorded.find { |row| row[:week] == week } || { week:, sets: 0, reps: 0, tonnage: 0 }
      end
    end

    # One row per week that has any work in it. Summed in the database rather than in
    # Ruby, because the alternative is loading every set of every session to fold it
    # back down to three numbers a week.
    def totals(account_id, exercise_id: nil, weeks: DEFAULT_WEEKS)
      working_sets(account_id, exercise_id:, weeks:)
        .group(WEEK).order(WEEK).select(Sequel.as(WEEK, :week), COUNTED, REPPED, LIFTED)
        .all.map { |row| row.merge(week: to_date(row[:week])) }
    end

    # The heaviest completed set of each lift in each week, as one series per lift, and
    # only for the weeks that lift was actually trained.
    #
    # Volume fills its gaps and intensity does not, which looks inconsistent until you
    # read the axis: an untrained week is genuinely zero tonnage, but it is not a top set
    # of zero. Filling it would draw a line collapsing to the floor and climbing back,
    # which reads as a deload nobody did. A lifter can go months between squat sessions,
    # so the line simply steps over the months they did not.
    def top_sets(account_id, exercise_id: nil, weeks: DEFAULT_WEEKS)
      series(named(working_sets(account_id, exercise_id:, weeks:))
               .group(WEEK, NAME).order(WEEK)
               .select(Sequel.as(WEEK, :week), Sequel.as(NAME, :name), HEAVIEST, COUNTED).all)
    end

    # Total sets per lift across the window, most-trained first. This is the "how many
    # hard sets did squat get versus bench" question, which is a bar chart rather than
    # a trend.
    def by_exercise(account_id, weeks: DEFAULT_WEEKS)
      named(working_sets(account_id, weeks:))
        .group(NAME).select(Sequel.as(NAME, :name), COUNTED)
        .all.sort_by { |row| -row[:sets] }.map { |row| [row[:name], row[:sets]] }
    end

    def named(sets)
      sets.join(:exercises, id: LIFT)
    end

    # The lifts worth offering in the filter: the ones with work in the window, as
    # [id, name] by name.
    #
    # Not every exercise the account can see. The library ships dozens of movements
    # nobody here has trained, and a filter mostly made of lifts that draw an empty page
    # is not a filter. Worse, a personal lift may share its name with a library one, and
    # two identical options with different ids give no way to tell which is which -- so
    # picking "Back Squat" could quietly select the one with no sets against it.
    def lifts(account_id, weeks: DEFAULT_WEEKS)
      named(working_sets(account_id, weeks:))
        .distinct.order(NAME).select_map([LIFT, NAME])
    end

    # Lift name to its week-by-week top set, the most-trained lift first, so taking the
    # first few for a chart takes the ones the block was actually about.
    def series(rows)
      rows.group_by { |row| row[:name] }
          .sort_by { |_name, weeks| -weeks.sum { |row| row[:sets] } }
          .map { |name, weeks| [name, weeks.to_h { |row| [label(to_date(row[:week])), row[:heaviest]] }] }
    end

    # Every Monday from the first week with work in it to this one. Bounded below by the
    # window as well, so asking for twelve weeks cannot draw a year because one old
    # session survived the filter.
    def span(first, weeks)
      ([first, monday(window_start(weeks))].max..monday(Date.today)).step(7).to_a
    end

    def window_start(weeks)
      monday(Date.today) - ((weeks - 1) * 7)
    end

    def monday(date)
      date - ((date.wday - 1) % 7)
    end

    # date_trunc hands back a timestamp; the rest of this works in days.
    def to_date(value)
      value.respond_to?(:to_date) ? value.to_date : value
    end

    # Weeks are consecutive and drawn in order, so unlike a chart of scattered days this
    # one does not need the year to tell one March from another -- its neighbours do.
    def label(week)
      week.strftime('%b %-d')
    end

    # Chart data is a label to a number; the label is the Monday the week began.
    def chart(rows, field)
      rows.to_h { |row| [label(row[:week]), row[field]] }
    end

    # The headline numbers for the window, for a page that should say what it means
    # before it draws anything.
    def summary(rows)
      { sets: rows.sum { |row| row[:sets] }, reps: rows.sum { |row| row[:reps] },
        tonnage: rows.sum { |row| row[:tonnage] }, weeks: rows.count { |row| row[:sets].positive? } }
    end
  end
end

