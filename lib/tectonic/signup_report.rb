# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  # How many people signed up each week, and how many of them did anything. #684.
  #
  # Every channel in #685 is a bet, and a bet is only worth placing if somebody can see what
  # it did. Two columns already record what that needs -- `accounts.created_at` since #580 and
  # `accounts.signed_up_connecting_id` since #628 -- and nothing read either of them, so the
  # only way to answer "did that post bring anyone?" was hand-written SQL against production.
  #
  # Counts only, and read-only: no email address leaves the database, so it is safe to run
  # against production from a laptop.
  #
  # The two activity columns are what tell people from bots. #343 found 404 accounts with
  # nothing in them at all, and a weekly signup count that cannot tell those apart from
  # lifters is a number that flatters whichever channel happened to attract the spam.
  module SignupReport
    Row = Struct.new(:week, :signups, :via_assistant, :logged_a_set, :connected, keyword_init: true)

    HEADINGS = ['week', 'signups', 'came via an assistant', 'logged a set', 'connected an assistant'].freeze

    # Accounts created before #580 have no date and are deliberately left that way, so they
    # are one row of their own rather than smeared across weeks they may not belong to.
    UNDATED = 'before records'

    module_function

    # One Row per week with a signup in it, oldest first, with the undated accounts first of
    # all. `excluding` is a list of email addresses: the owner's account and the reviewer's,
    # which would otherwise read as a lifter and a signup.
    def rows(excluding: [])
      week = Sequel.function(:date_trunc, 'week', :created_at).cast(Date)
      DB[:accounts].exclude(email: excluding)
                   .select_group(Sequel.as(week, :week))
                   .select_append(*counts)
                   .order(Sequel.asc(:week, nulls: :first))
                   .map { |row| Row.new(**row) }
    end

    def counts
      everyone = Sequel.function(:count).*
      [everyone.as(:signups),
       Sequel.function(:count, :signed_up_connecting_id).as(:via_assistant),
       everyone.filter(lifted).as(:logged_a_set),
       everyone.filter(connected).as(:connected)]
    end

    def lifted
      DB[:sets].join(:workouts, id: :workout_id)
               .where(Sequel[:workouts][:account_id] => Sequel[:accounts][:id]).exists
    end

    # A grant of any kind, revoked or not: the question is whether they ever got as far as
    # connecting, and somebody who connected and then disconnected did.
    def connected
      DB[:oauth_grants].where(Sequel[:oauth_grants][:account_id] => Sequel[:accounts][:id]).exists
    end

    # A plain fixed-width table, for a terminal.
    def format(rows)
      lines = [HEADINGS] + rows.map { |row| cells(row) }
      widths = HEADINGS.each_index.map { |column| lines.map { |line| line[column].length }.max }
      lines.map { |line| aligned(line, widths) }.join("\n")
    end

    def cells(row)
      [row.week&.iso8601 || UNDATED, row.signups, row.via_assistant, row.logged_a_set, row.connected].map(&:to_s)
    end

    def aligned(line, widths)
      line.each_with_index.map { |cell, column| cell.ljust(widths[column]) }.join('  ').rstrip
    end
  end
end

