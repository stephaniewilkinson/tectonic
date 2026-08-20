# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/oauth/retention'
require 'securerandom'

# Fixtures for the prune policy. Everything is placed far enough in the past that a
# run with the default grace period touches only these rows, so a suite running
# against the same database at the same time is left alone.
module Retained
  DAY = 60 * 60 * 24
  LONG_AGO = Time.now - (400 * DAY)

  def register(account_id: nil, created_at: LONG_AGO)
    DB[:oauth_applications].insert(name: 'Pruned client', scopes: 'read write', account_id:, created_at:,
                                   client_id: SecureRandom.uuid, client_secret: SecureRandom.uuid)
  end

  def grant(application_id, expires_in:, revoked_at: nil)
    DB[:oauth_grants].insert(oauth_application_id: application_id, scopes: 'read write',
                             expires_in:, revoked_at:, created_at: Retained::LONG_AGO)
  end

  def account
    DB[:accounts].insert(email: "#{SecureRandom.hex}@example.com", password_hash: 'x', created_on: Time.now)
  end

  def prune
    Tectonic::OAuth::Retention.prune
  end

  def applications = DB[:oauth_applications]

  def grants = DB[:oauth_grants]
end

describe 'pruning spent OAuth grants' do
  include Retained

  it 'deletes a grant revoked before the grace period' do
    spent = grant(register, expires_in: Time.now + 3600, revoked_at: Retained::LONG_AGO)
    prune

    assert_nil grants[id: spent]
  end

  it 'deletes a grant whose refresh token expired long ago' do
    spent = grant(register, expires_in: Time.now - (500 * Retained::DAY))
    prune

    assert_nil grants[id: spent]
  end

  # The rule that matters: a client presenting a refresh token expects its grant to
  # still be there, and that is nearly a year after the access token stopped working.
  it 'keeps a live grant, and one whose access token expired but is still refreshable' do
    live = grant(register, expires_in: Time.now + 3600)
    refreshable = grant(register, expires_in: Time.now - (60 * Retained::DAY))
    prune

    refute_nil grants[id: live]
    refute_nil grants[id: refreshable]
  end

  it 'keeps a grant revoked inside the grace period' do
    recent = grant(register, expires_in: Time.now + 3600, revoked_at: Time.now - Retained::DAY)
    prune

    refute_nil grants[id: recent]
  end
end

describe 'pruning abandoned OAuth clients' do
  include Retained

  it 'deletes a self-registered client nothing points at any more' do
    abandoned = register
    grant(abandoned, expires_in: Time.now + 3600, revoked_at: Retained::LONG_AGO)
    prune

    assert_nil applications[id: abandoned]
  end

  it 'keeps a client whose grant is still live' do
    connected = register
    grant(connected, expires_in: Time.now + 3600)
    prune

    refute_nil applications[id: connected]
  end

  it 'keeps a client registered inside the grace period' do
    fresh = register(created_at: Time.now)
    prune

    refute_nil applications[id: fresh]
  end
end

describe 'the OAuth clients a prune leaves alone' do
  include Retained

  # A client provisioned by hand may be waiting to be used for the first time, so
  # having no grant yet is not evidence of anything.
  it 'keeps a client that belongs to an account' do
    provisioned = register(account_id: account)
    prune

    refute_nil applications[id: provisioned]
  end

  # Deleting these would take the audit trail and the "created by" line with them, and
  # the foreign keys would refuse anyway.
  it 'keeps a client an audit row still names' do
    audited = register
    DB[:mcp_audit_log].insert(account_id: account, oauth_application_id: audited, tool_name: 'list_workouts',
                              result_status: 'success')
    prune

    refute_nil applications[id: audited]
  end

  it 'keeps a client an object it created still names' do
    creator = register
    DB[:workouts].insert(account_id: account, date: Date.today, created_by_oauth_application_id: creator)
    prune

    refute_nil applications[id: creator]
  end
end

