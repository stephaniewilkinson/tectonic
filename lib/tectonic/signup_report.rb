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
    def format(rows) = table(HEADINGS, rows.map { |row| cells(row) })

    def cells(row)
      [row.week&.iso8601 || UNDATED, row.signups, row.via_assistant, row.logged_a_set, row.connected]
    end

    def table(headings, rows)
      lines = [headings, *rows].map { |line| line.map(&:to_s) }
      widths = lines.transpose.map { |column| column.map(&:length).max }
      lines.map { |line| aligned(line, widths) }.join("\n")
    end

    def aligned(line, widths) = line.zip(widths).map { |cell, width| cell.ljust(width) }.join('  ').rstrip

    # Where signups came from. #691.
    #
    # A `ref` or `utm_source` on the first page wins outright and is shown as written: it is
    # the one signal nothing strips, and a link posted as `?ref=r-weightroom` should be
    # counted as exactly that. Otherwise the referring host is sorted into a channel, with the
    # raw hosts in a table of their own so a new one is never hidden under "other site".
    #
    # "assistant" undercounts, and cannot help it: assistants' apps often send no referrer,
    # and those signups land in "none". The came-via-an-assistant column above counts the
    # connect flow, which is the other half of that answer.
    CHANNELS = {
      'assistant' => %w[chatgpt.com chat.openai.com claude.ai perplexity.ai www.perplexity.ai gemini.google.com
                        copilot.microsoft.com],
      'reddit' => %w[reddit.com www.reddit.com old.reddit.com out.reddit.com],
      'hacker news' => %w[news.ycombinator.com],
      'search' => %w[www.google.com google.com www.bing.com bing.com duckduckgo.com search.brave.com
                     search.yahoo.com www.ecosia.org kagi.com]
    }.freeze
    NOT_RECORDED = 'not recorded'
    NO_SOURCE = 'none'
    OTHER = 'other site'
    SOURCE_HEADINGS = ['week', 'source', 'signups', 'logged a set'].freeze
    HOST_HEADINGS = ['referring site', 'signups'].freeze

    def source(ref:, host:, landing:)
      return NOT_RECORDED if landing.nil?
      return ref if ref
      return NO_SOURCE if host.nil?

      CHANNELS.find { |_, hosts| hosts.include?(host) }&.first || OTHER
    end

    # Dated signups only: the undated ones predate #580 and so predate this by two months.
    def signups(excluding: [])
      DB[:accounts].exclude(email: excluding).exclude(created_at: nil)
                   .select(Sequel.function(:date_trunc, 'week', :created_at).cast(Date).as(:week),
                           :signup_ref, :signup_referrer_host, :signup_landing_path,
                           Sequel.as(lifted, :lifted))
                   .all
    end

    # One line per week and source, newest week first, busiest source first within it.
    def sources(excluding: [])
      signups(excluding:).group_by { |row| [row[:week], source_of(row)] }
                         .map { |(week, from), rows| [week, from, rows.size, rows.count { |row| row[:lifted] }] }
                         .sort_by { |week, _, count, _| [-week.jd, -count] }
    end

    def hosts(excluding: [])
      signups(excluding:).filter_map { |row| row[:signup_referrer_host] }.tally.sort_by { |host, count| [-count, host] }
    end

    def source_of(row)
      source(ref: row[:signup_ref], host: row[:signup_referrer_host], landing: row[:signup_landing_path])
    end

    def format_sources(lines) = table(SOURCE_HEADINGS, lines.map { |week, *rest| [week.iso8601, *rest] })

    def format_hosts(lines) = table(HOST_HEADINGS, lines)
  end
end

