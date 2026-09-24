# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'workouts'

class Tectonic < Roda
  # A month of training as a grid. The workouts list answers "what have I done" in
  # reverse order; it cannot show the shape of a week, which is what a lifter actually
  # reads a plan by -- three sessions with a rest between them looks nothing like three
  # sessions run together, and both are the same list.
  #
  # The cells speak the vocabulary a workout already has: performed, planned, skipped.
  # Skipped is the one worth drawing. A missed session is invisible in a list, because a
  # list only shows what is there, and the whole use of a calendar is seeing the hole.
  module Calendar
    # Weeks begin on Sunday here and on Monday everywhere that buckets training -- the
    # volume chart, and the Monday a seeded block opens on. They are not the same week. A
    # training week is a unit of work and starts where the block starts; a month grid is
    # read against the calendar already on the wall or the phone.
    #
    # Which day that grid begins on is the account's, since #189 -- most of the world reads
    # a week as starting on Monday and this app had no way to say so. The names are held in
    # Date#wday order and rotated on the way out, because wday is what every date arithmetic
    # here counts in and rewriting the list would mean rewriting that too.
    DAY_NAMES = %w[Sun Mon Tue Wed Thu Fri Sat].freeze
    # The same days spelled out, for the column headers a screen reader reads. #339 is about
    # being able to answer "what am I doing on Thursday" without counting, and "Thu" announced
    # on its own is a step short of that -- some readers spell it, some say "thoo". The
    # abbreviation stays on screen, where a seventh of a phone is not wide enough for more.
    FULL_DAY_NAMES = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze
    # The days a grid may begin on, as Date#wday numbers: Sunday and Monday. Named here
    # because the route and the database constraint have to agree about it, and two places
    # holding the same pair of numbers is one place too many.
    WEEK_STARTS = [0, 1].freeze
    MONTH = /\A(?<year>\d{4})-(?<month>\d{2})\z/
    # A calendar is a way of reading training, not an archive to wander: far enough back
    # to cover any real history, and far enough forward for a written block.
    LIMIT_YEARS = 5

    module_function

    # The month a page was asked for, as its first day, or this month when the request
    # says nothing or says something that is not a month. The value reaches Date.new,
    # so it is matched rather than coerced.
    def month_of(requested, today = Date.today)
      matched = MONTH.match(requested.to_s)
      return first_of(today) unless matched

      asked = Date.new(matched[:year].to_i, matched[:month].to_i, 1)
      in_range?(asked, today) ? asked : first_of(today)
    rescue Date::Error
      first_of(today)
    end

    def in_range?(asked, today)
      months = LIMIT_YEARS * 12
      asked.between?(first_of(today) << months, first_of(today) >> months)
    end

    def first_of(date)
      Date.new(date.year, date.month, 1)
    end

    # The month as whole weeks, so the grid is rectangular and every row has seven days.
    # The first and last rows spill into the neighbouring months, which is what makes a
    # week that straddles a month boundary readable at all.
    # The column headings, beginning on the account's chosen day.
    def day_names(starts_on = 0)
      DAY_NAMES.rotate(starts_on)
    end

    # The columns as [what is drawn, what is read]. One method rather than two rotated
    # separately, because the two lists have to stay in step and rotating them apart is the
    # one way this goes wrong -- a header reading "Thu" and announcing "Friday" is worse than
    # one that only says "Thu".
    def day_columns(starts_on = 0)
      day_names(starts_on).zip(FULL_DAY_NAMES.rotate(starts_on))
    end

    def weeks(account_id, month, today = Date.today, starts_on = 0)
      from, to = bounds(month, starts_on)
      trained = by_day(account_id, from, to)
      (from..to).each_slice(7).map do |week|
        week.map { |date| cell(date, month, today, trained.fetch(date, [])) }
      end
    end

    # Back to the Sunday on or before the first, forward to the Saturday on or after the
    # last, so the grid is rectangular. Date#wday counts from Sunday, so each end is one
    # subtraction; a Monday-first grid had to shift the origin by a modulo at both.
    # Back far enough to reach the account's start-of-week on or before the first, and
    # forward to the day before the next one after the last, so the grid is whole weeks.
    #
    # Both ends were a plain subtraction while the week always began on Sunday, because
    # Date#wday counts from Sunday and the arithmetic came out for free. The modulo is what
    # that subtraction becomes once the starting day is a choice: `(wday - starts_on) % 7`
    # is how far into the week a date sits, whichever day the week opens on, and Ruby's %
    # returns a non-negative result for a positive divisor, so the wrap needs no special
    # case for a Sunday in a week that begins on Monday.
    def bounds(month, starts_on = 0)
      last = Date.new(month.year, month.month, -1)
      [month - ((month.wday - starts_on) % 7), last + ((starts_on + 6 - last.wday) % 7)]
    end

    def cell(date, month, today, workouts)
      { date:, workouts:, in_month: date.month == month.month, today: date == today }
    end

    # Every workout in the grid in one query, keyed by the day it falls on. The
    # performance flag rides along so no cell asks the database whether it was lifted.
    #
    # **Keyed by the day it was trained, not the day it was written for.** #479.
    #
    # `workouts.date` is a plan. For a generated block it is made weeks ahead, and training
    # does not keep to it -- on the reporting account five sessions were trained up to three
    # days from the date they carry, and every one was drawn on the planned day. A session
    # lifted on Monday appeared on Thursday, and Monday looked like a rest day. A calendar
    # that reports the plan is a calendar that cannot answer "when did I actually train",
    # which is the only question a diary is for.
    #
    # `Workout#performed_or_planned_on` is where that decision lives; this just groups by it.
    # It was called `on_calendar` until #572 -- named for this caller, which is how it came to
    # have only this caller while six other pages went on printing the plan. Same rule, same
    # fallback, a name that says what it answers rather than who asks.
    #
    # eager(:program_day) is #593, and this grid is the half of that issue nobody was looking
    # at: `entries` below reads `label` on every session it draws, `label` is
    # `name || program_day&.focus`, and `program_day` is a many_to_one. So a month of a
    # four-day block was sixteen `SELECT * FROM program_days WHERE id = N` after this query --
    # and spec/query_count_spec.rb, which exists to catch exactly that, did not measure the
    # front page at all. It does now. One further query whatever the month holds.
    def by_day(account_id, from, to)
      Workout.where(account_id:).where(within(from, to))
             .with_performed_on.eager(:program_day).order(:date, :id).all
             .group_by(&:performed_or_planned_on)
    end

    # A session belongs in this grid if *either* of its dates falls in it, and both halves
    # are load-bearing.
    #
    # Fetching by the stored date alone loses a session written for the 1st of next month and
    # trained on the 30th of this one -- it would be drawn on neither page. Fetching by the
    # performed date alone loses every session that has not been trained yet, which is the
    # whole forward half of a plan.
    #
    # A lookup of the trained sessions rather than a widened window, because the drift has no
    # bound: it is however far a lifter moved a session, and a margin chosen here would be a
    # guess that silently drops anything past it.
    #
    # Neither half makes Postgres read every session the account has (#599). The planned date
    # is compared as a half-open range of timestamps rather than cast to a day, which is the
    # same rows and lets `workouts_account_id_date_index` seek on it. The trained half asks
    # which sessions have *any* set completed in the grid, which 054 indexes, rather than
    # working out each session's first completion to compare it. Any is looser than first --
    # a session begun on the 31st and finished on the 1st is in both -- and that is fine here
    # because it only fetches: `by_day` keys each session by `performed_or_planned_on`, which
    # is still the first completion, and a session keyed outside the grid is drawn nowhere.
    def within(from, to)
      Sequel.|({ date: from...(to + 1) }, { id: Workout.completed_between(from, to) })
    end

    # How a session is written in a cell. The words differ from the status names in one
    # place: a performed session reads "trained", because a cell is read as a diary
    # rather than as a field on a row.
    WORDS = { performed: 'trained', planned: 'planned', skipped: 'missed' }.freeze
    STYLES = { performed: 'bg-lime-100 text-lime-800 hover:bg-lime-200',
               planned: 'bg-sky-100 text-sky-800 hover:bg-sky-200',
               skipped: 'bg-rose-100 text-rose-800 hover:bg-rose-200' }.freeze

    # A day's sessions as the view draws them. The mapping from status to word and
    # colour lives here rather than in the template, which would otherwise have to hold
    # a local across ERB tags to do it.
    # `label` rides along because a cell holding two workouts drew the same word twice
    # with nothing between them: performed, performed. The word says what happened to a
    # session and the label says which session it was, and a day with two of them needs
    # both. Nil for a workout that has neither a name nor a program day behind it, which
    # is every session anybody logged before #143 and is why the view has to handle its
    # absence rather than assume one.
    def entries(workouts, today = Date.today)
      workouts.map do |workout|
        status = workout.status(today)
        { id: workout.id, status:, word: WORDS[status], style: STYLES[status], label: workout.label }
      end
    end

    # What a month contained, for a line of prose above the grid. Counted from the same
    # rows the cells are drawn from rather than queried again.
    def tally(weeks, today = Date.today)
      workouts = weeks.flatten.select { |cell| cell[:in_month] }.flat_map { |cell| cell[:workouts] }
      workouts.group_by { |workout| workout.status(today) }.transform_values(&:count)
    end
  end
end

