# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require

# How many queries a page costs, and whether that number grows with what is on it. #234.
#
# Three pages issued one query per row. Measured on twelve workouts of twenty sets each:
# /workouts took 14, the workout record 13, and the set list 23. Each grew linearly, so a
# year of training on /workouts was a query per session.
#
# Nothing failed while that was true. Every page rendered, every assertion passed, and the
# suite has no other way to notice -- which is why this asserts the shape rather than a
# number. A page is rendered at two sizes and the counts must match: what matters is not
# that /workouts costs two queries but that it costs the same two when the account has
# trained for a year.
module QueryCount
  def app = Tectonic.app

  # A logger that keeps what it is told. Sequel wants the rest of the Logger interface and
  # never calls any of it here, which is what method_missing is for.
  class Tally
    STATEMENT = /SELECT|INSERT|UPDATE|DELETE/

    def initialize = @statements = []

    def info(message) = @statements << message

    def queries = @statements.count { |statement| statement.match?(STATEMENT) }

    def method_missing(_name, *_args) = nil

    def respond_to_missing?(*) = true
  end

  # Counts what reaches the database while the block runs. Sequel logs every statement it
  # executes, so this counts what was actually sent rather than what the code looks like it
  # should send -- which is the whole point, since an N+1 reads perfectly innocently at the
  # call site.
  def queries_while
    tally = Tally.new
    DB.loggers << tally
    yield
    DB.loggers.delete(tally)
    tally.queries
  end

  # A session of `lifts` movements, four sets apiece, on its own workout.
  def training(account_id, workouts:, lifts:)
    movements = Array.new(lifts) { DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:) }
    Array.new(workouts) { |day| a_session(account_id, movements, day) }
  end

  def a_session(account_id, movements, day)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now - (day * 86_400))
    movements.each do |exercise_id|
      4.times do
        DB[:sets].insert(workout_id:, exercise_id:, weight: 135, reps: 5,
                         is_warmup: false, is_completed: true, is_barbell: true)
      end
    end
    workout_id
  end

  def cost_of(path)
    queries_while { get path }
  end

  # A fresh account for each size, rather than one that grows: the small case must not be
  # measured against a query plan cache the large case warmed.
  def costs_for(workouts:, lifts:)
    account_id = login
    workout = training(account_id, workouts:, lifts:).first
    { '/workouts' => cost_of('/workouts'),
      'record' => cost_of("/workouts/#{workout}"),
      'sets' => cost_of("/workouts/#{workout}/sets"),
      'session' => cost_of("/workouts/#{workout}/session") }
  end
end

describe 'what a page costs to render' do
  include Rack::Test::Methods
  include RouteOwnership
  include QueryCount

  # Two accounts, one with five times the training of the other. Separate accounts rather
  # than one that grows, so the small case cannot be measured against a warm query cache the
  # large case filled.
  before do
    @small_costs = costs_for(workouts: 2, lifts: 2)
    @large_costs = costs_for(workouts: 10, lifts: 10)
  end

  # The assertion that matters, and the one a fixed number would not make: five times the
  # training must not cost five times the queries.
  it 'does not grow with the amount of training on the page' do
    @small_costs.each_key do |page|
      assert_equal @small_costs[page], @large_costs[page],
                   "#{page} costs #{@large_costs[page]} queries on a large account and " \
                   "#{@small_costs[page]} on a small one, so it is querying per row"
    end
  end

  # A ceiling as well, so that "constant" cannot be satisfied by a page that is constantly
  # expensive. Generous on purpose: this is a guard against a per-row query coming back, not
  # a budget anybody should be tuning against.
  it 'stays in single figures' do
    @large_costs.each { |page, cost| assert_operator cost, :<, 10, "#{page} costs #{cost} queries" }
  end
end

