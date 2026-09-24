# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'query_count_spec' # its fixture and its login; idempotent require

# #596. A movement's page read the lifter's whole completed history of it five times in one
# request: once for the headline max, once for the estimate, once for the chart, once for the
# chart's own max, and once more per block the account had run, for the step line. The count
# never grew with the training, so the query-count spec had nothing to say -- but every one of
# those reads is linear in the history, and a lifter a few years in pays for it five times.
#
# Counted by what the read selects rather than by how many queries the page makes, because
# this is about one statement repeated, not about the total.
class HistoryReads < QueryCount::Tally
  def queries = @statements.count { |statement| statement.include?('"sets"."is_warmup", "workouts"."date"') }
end

describe "a movement's page reads its history once" do
  include Rack::Test::Methods
  include RouteOwnership
  include QueryCount

  before do
    account_id = login
    _sessions, movements = training(account_id, workouts: 6, lifts: 2)
    # Two more blocks behind the fixture's own, so the step line has three to price.
    [49, 70].each { |ago| DB[:programs].insert(account_id:, name: 'Earlier', start_date: Date.today - ago) }
    @movement = movements.first
  end

  it 'however many blocks the step line has to price' do
    tally = HistoryReads.new
    DB.loggers << tally
    get "/exercises/#{@movement}"
    DB.loggers.delete(tally)

    assert_equal 200, last_response.status
    assert_equal 1, tally.queries
  end
end

