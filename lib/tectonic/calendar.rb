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
    def by_day(account_id, from, to)
      Workout.where(account_id:)
             .where(Sequel.cast(:date, :date) => from..to)
             .with_performance.order(:date, :id).all
             .group_by { |workout| workout.date.to_date }
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

