# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/signup_report'
require 'securerandom'

# The weekly signup count, and whether the people behind it did anything. #684.
module SignupRows
  def account(created_at: Time.utc(2026, 11, 4, 12), email: "#{SecureRandom.hex}@example.com", **rest)
    DB[:accounts].insert(email:, password_hash: 'x', created_at:, **rest)
  end

  def lift(account_id)
    workout = DB[:workouts].insert(account_id:, date: Time.utc(2026, 11, 5))
    exercise = DB[:exercises].insert(name: "Move #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id: workout, exercise_id: exercise, reps: 5, weight: 100)
  end

  def connect(account_id)
    application = Tectonic::OAuthApplication.create(name: 'Claude', client_id: SecureRandom.uuid,
                                                    client_secret: SecureRandom.hex,
                                                    redirect_uri: 'https://e/cb', scopes: 'read')
    DB[:oauth_grants].insert(account_id:, oauth_application_id: application.id, scopes: 'read',
                             expires_in: Time.now + 3600)
    application.id
  end

  def report(**) = Tectonic::SignupReport.rows(**)
end

describe 'the signup report, counting' do
  include SignupRows

  it 'counts a week by its Monday, and tells signups from lifters from connections' do
    lift(account)
    connect(account)
    account

    week = report.first
    assert_equal Date.new(2026, 11, 2), week.week
    assert_equal [3, 1, 1], [week.signups, week.logged_a_set, week.connected]
  end

  it 'counts somebody who signed up on the way to connecting an assistant' do
    account(signed_up_connecting_id: connect(account(created_at: Time.utc(2026, 1, 5))))

    assert_equal 1, report.last.via_assistant
  end

  it "leaves out the addresses it is told to, so the owner and the reviewer aren't counted" do
    account(email: 'me@example.com')
    account

    assert_equal 1, report(excluding: ['me@example.com']).sum(&:signups)
  end
end

describe 'the signup report, printed' do
  include SignupRows

  # Before #580 there was no date to record, and inventing one is what #574 refused to do.
  it 'keeps the accounts from before signups were dated in a row of their own, first' do
    account(created_at: nil)
    account

    weeks = report
    assert_nil weeks.first.week
    assert_match(/\Abefore records\s+1/, Tectonic::SignupReport.format(weeks).lines[1])
  end

  it 'prints a header and one line a week' do
    account
    table = Tectonic::SignupReport.format(report)

    assert_match(/\Aweek\s+signups\s+came via an assistant\s+logged a set\s+connected an assistant\n/, table)
    assert_match(/^2026-11-02\s+1\s+0\s+0\s+0$/, table)
  end
end

