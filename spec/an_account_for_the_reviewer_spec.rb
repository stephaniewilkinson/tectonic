# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/reviewer_account'
require_relative '../lib/tectonic/exercise_library'

# The account handed to a directory reviewer. #683.
module ReviewerFixture
  PASSWORD = 'a-long-enough-password'
  TODAY = Date.new(2026, 11, 11) # a Wednesday

  def reset
    Tectonic::Exercise.load_library
    Tectonic::ReviewerAccount.reset!(password: PASSWORD, today: TODAY)
  end

  def sets_of(id) = DB[:sets].join(:workouts, id: :workout_id).where(Sequel[:workouts][:account_id] => id)

  # Every kind of row the reset rebuilds, counted, so two resets can be compared whole.
  def training(id)
    owned = %i[workouts programs account_training_maxes account_goals account_plates exercises]
    owned.to_h { |table| [table, DB[table].where(account_id: id).count] }.merge(sets: sets_of(id).count)
  end
end

describe 'the reviewer account, filled' do
  include ReviewerFixture

  it 'is a verified account that signs in with the password it was given' do
    row = DB[:accounts].where(id: reset).first

    assert_equal Tectonic::ReviewerAccount::EMAIL, row[:email]
    assert_equal 2, row[:status_id]
    assert BCrypt::Password.new(row[:password_hash]) == ReviewerFixture::PASSWORD
  end

  it 'has three weeks of history, a block under way, maxes, a goal and a rack' do
    filled = training(reset)

    assert_operator filled[:sets], :>=, 50
    assert_equal [1, 4, 1], filled.values_at(:programs, :account_training_maxes, :account_goals)
    assert_operator filled[:account_plates], :>, 0
    assert_operator filled[:workouts], :>, 9, "nine logged sessions, plus this week's from the block"
  end

  it 'logs the three shapes of set: loaded, bodyweight and timed' do
    sets = sets_of(reset)

    assert_predicate sets.exclude(weight: nil), :any?
    assert_predicate sets.where(weight: nil).exclude(reps: nil), :any?
    assert_predicate sets.exclude(duration_seconds: nil), :any?
  end
end

describe 'the reviewer account, over time' do
  include ReviewerFixture

  it 'climbs week on week, so a history question has a trend to describe' do
    sets = sets_of(reset)
    squat = DB[:exercises].where(name: 'Back Squat', account_id: nil).get(:id)

    # The three history weeks only: this week's block session is lifted too, ramp and all.
    history = sets.where(exercise_id: squat, reps: 5, is_completed: true, is_warmup: false)
                  .where { date < Date.new(2026, 11, 9) }
    assert_equal [225, 235, 245], history.order(:date).select_map(:weight).uniq
  end
end

describe 'the reviewer account, reset' do
  include ReviewerFixture

  # Reviewers write to it, so the reset is the way back -- and it must not keep what they wrote,
  # or lose the account they are connected through.
  it 'comes back to the same state however many times it is reset, keeping the account' do
    first = reset
    before = training(first)
    DB[:workouts].insert(account_id: first, date: Time.utc(2026, 11, 9))

    assert_equal first, reset
    assert_equal before, training(first)
  end

  it 'refuses a short password rather than setting one' do
    assert_raises(ArgumentError) do
      Tectonic::ReviewerAccount.reset!(password: 'short', today: ReviewerFixture::TODAY)
    end
    assert_equal 0, DB[:accounts].where(email: Tectonic::ReviewerAccount::EMAIL).count
  end
end

describe 'the reviewer account, and its body' do
  include ReviewerFixture

  # So the three health tools have four weeks to answer a reviewer with, not an empty account.
  it 'has four weeks of weigh-ins and sleep, and weekly body composition' do
    id = reset
    metrics = DB[:health_metrics].where(account_id: id).group_and_count(:metric).to_h do |row|
      row.values_at(:metric, :count)
    end

    assert_equal 28, metrics['weight']
    assert_equal 28, metrics['sleep_hours']
    assert_equal 4, metrics['fat_mass']
    assert_operator metrics.keys.size, :>=, 6
  end
end

# Rows existing is not the claim; a reviewer asking the health tools and getting an answer is.
describe 'the reviewer account, asked about its body' do
  include ReviewerFixture

  def ask(tool, **arguments)
    context = Tectonic::MCP::RequestContext.new(account_id: reset, email: Tectonic::ReviewerAccount::EMAIL,
                                                scopes: %w[read], application_id: nil, time_zone: 'UTC')
    tool.call(server_context: context, **arguments)
  end

  it 'answers each of the three health tools with readings, not an empty account' do
    from = (ReviewerFixture::TODAY - 30).iso8601
    responses = { 'body_composition' => ask(Tectonic::MCP::Tools::BodyComposition, days: 28),
                  'bodyweight_trend' => ask(Tectonic::MCP::Tools::BodyweightTrend, from:),
                  'health_readings' => ask(Tectonic::MCP::Tools::HealthReadings, metric: 'sleep_hours', from:) }

    responses.each do |name, response|
      refute_predicate response, :error?, "#{name}: #{response.content.first[:text]}"
      refute_match(/no (readings|weigh-ins?|data)/i, response.content.first[:text], name)
    end
  end
end

# What a reviewer sees in the list: sessions trained on their own days, none skipped.
describe 'the reviewer account, as its workouts list reads' do
  include ReviewerFixture

  it 'has every past session trained on the day it was for, and none skipped' do
    id = reset
    past = DB[:workouts].where(account_id: id).where { date < ReviewerFixture::TODAY }.select_map(%i[id date])

    refute_empty past
    past.each do |workout, date|
      days = DB[:sets].where(workout_id: workout).select_map(Sequel.cast(:completed_at, Date)).uniq
      assert_equal [date.to_date], days, "workout #{workout} reads as trained on #{days.inspect}"
    end
  end
end

