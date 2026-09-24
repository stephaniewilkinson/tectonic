# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'query_count_spec' # its fixture and its login; idempotent require

# #603. Rodauth loads the signed-in account's whole row to find out who is asking, and that
# row carries every per-account setting a page reads -- zone, week start, time budget, bar.
# Four helpers then went back for it a column at a time: /settings fetched the one row five
# times in a request, the front page and the exercise page three, by primary key each time.
#
# Nothing else in the suite could see it. The count is constant, so the query-count spec is
# satisfied; it is simply more than one.
# Statements that read the accounts table itself, rather than a table whose name begins with
# it -- account_plates is read on the same pages and is a different question.
class AccountReads < QueryCount::Tally
  def queries = @statements.count { |statement| statement.match?(/SELECT .* FROM "accounts"/) }
end

describe 'a page reads the signed-in account once' do
  include Rack::Test::Methods
  include RouteOwnership
  include QueryCount

  def account_reads(path)
    tally = AccountReads.new
    DB.loggers << tally
    get path
    DB.loggers.delete(tally)
    tally.queries
  end

  before do
    account_id = login
    sessions, movements = training(account_id, workouts: 3, lifts: 2)
    @pages = ['/', '/settings', '/workouts', "/workouts/#{sessions.first}/session",
              "/exercises/#{movements.first}"]
  end

  it 'on every page that reads a setting off it' do
    reads = @pages.to_h { |page| [page, account_reads(page)] }

    assert_equal(@pages.to_h { |page| [page, 1] }, reads)
  end
end

