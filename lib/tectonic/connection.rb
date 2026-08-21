# frozen_string_literal: true

require_relative 'db'
require_relative 'oauth_application'

class Tectonic < Roda
  # An assistant an account has connected, seen from the account's side rather than the
  # authorization server's. rodauth-oauth records a row per grant -- one per authorization,
  # and a client that reconnects gets another -- so a lifter who has authorized Claude
  # three times has three rows and one connection. This folds them back into the thing
  # they would recognise: an assistant, when it was first let in, and what it may do.
  class Connection
    # A grant is live while it has not been revoked and its refresh window is still open.
    # rodauth-oauth measures that window from the access token's expiry rather than from
    # the grant's creation, which is why the sum appears here rather than a single column.
    REFRESH_WINDOW = 60 * 60 * 24 * 360

    attr_reader :application, :scopes, :connected_at, :grant_ids

    def initialize(application:, scopes:, connected_at:, grant_ids:)
      @application = application
      @scopes = scopes
      @connected_at = connected_at
      @grant_ids = grant_ids
    end

    # Every assistant with a live grant for this account, most recently connected first.
    def self.for_account(account_id)
      live_grants(account_id).group_by { |grant| grant[:oauth_application_id] }
                             .filter_map { |application_id, grants| build(application_id, grants) }
                             .sort_by(&:connected_at).reverse
    end

    def self.live_grants(account_id)
      DB[:oauth_grants].where(account_id:, revoked_at: nil)
                       .where { expires_in > Sequel.date_sub(Sequel::CURRENT_TIMESTAMP, seconds: REFRESH_WINDOW) }
                       .order(:created_at).all
    end

    def self.build(application_id, grants)
      application = OAuthApplication[application_id]
      return unless application

      new(application:, scopes: scopes_across(grants), connected_at: grants.first[:created_at],
          grant_ids: grants.map { |grant| grant[:id] })
    end

    # What the assistant may do, across every grant it holds: authorizing a second time
    # with narrower scopes does not take away what the first authorization gave.
    def self.scopes_across(grants)
      grants.flat_map { |grant| grant[:scopes].to_s.split }.uniq.sort
    end

    # Cuts the assistant off. Every grant goes at once, because a lifter revoking Claude
    # means Claude, not the particular authorization they happen to be looking at -- and
    # leaving one live would let it mint a fresh token straight after being told it could
    # not. Soft, so the audit trail and provenance keep pointing at something.
    def self.revoke(account_id, application_id)
      DB[:oauth_grants].where(account_id:, oauth_application_id: application_id, revoked_at: nil)
                       .update(revoked_at: Sequel::CURRENT_TIMESTAMP)
    end

    def name
      application[:name]
    end

    def id
      application[:id]
    end
  end
end

