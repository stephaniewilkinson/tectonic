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
    # Weeks begin on Monday, as they do everywhere else that buckets training.
    DAY_NAMES = %w[Mon Tue Wed Thu Fri Sat Sun].freeze
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
    def weeks(account_id, month, today = Date.today)
      from, to = bounds(month)
      trained = by_day(account_id, from, to)
      (from..to).each_slice(7).map do |week|
        week.map { |date| cell(date, month, today, trained.fetch(date, [])) }
      end
    end

    # Back to the Monday on or before the first, forward to the Sunday on or after the
    # last, so the grid is rectangular.
    def bounds(month)
      last = Date.new(month.year, month.month, -1)
      [month - ((month.wday - 1) % 7), last + ((7 - last.wday) % 7)]
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
    def entries(workouts, today = Date.today)
      workouts.map do |workout|
        status = workout.status(today)
        { id: workout.id, status:, word: WORDS[status], style: STYLES[status] }
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

