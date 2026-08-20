# frozen_string_literal: true

require 'roda'
require_relative '../db'

class Tectonic < Roda
  module OAuth
    # What may be deleted from the OAuth tables, and when. Registration is open, so
    # every client that ever connected leaves an application row and a grant row per
    # authorization, and nothing here ever removed either -- an anonymous caller can
    # grow both tables for as long as they care to.
    #
    # The rule that matters is what stays. A grant is kept while it can still be used,
    # which is longer than its access token lives: the refresh token outlasts it by
    # nearly a year, and a client presenting one expects its grant to be there. An
    # application is kept while anything at all still points at it -- a grant of any
    # kind, an audit row, an object it created -- so a client whose token is still
    # valid keeps its row, and the provenance line under an object an LLM made keeps
    # naming the client that made it.
    module Retention
      # rodauth-oauth's defaults, which this app does not override: an access token
      # lasts an hour, and its grant stays refreshable until a year past that. A grant
      # is only spent once its expiry is that far behind. Changing either setting means
      # changing this.
      REFRESH_WINDOW = (60 * 60 * 24 * 360) - (60 * 60)
      DEFAULT_DAYS = 30
      # Everything that can point at an application, and would be orphaned by deleting
      # one. All three provenance columns are usually null, so the null rows have to be
      # excluded from the subquery or NOT IN answers null for every application and
      # nothing is ever collected.
      REFERENCES = {
        oauth_grants: :oauth_application_id,
        mcp_audit_log: :oauth_application_id,
        exercises: :created_by_oauth_application_id,
        workouts: :created_by_oauth_application_id,
        sets: :created_by_oauth_application_id
      }.freeze

      module_function

      # Deletes spent grants and the applications left with nothing pointing at them,
      # in that order, so a client is collected in the same pass as its last grant.
      # `days` is the grace period: nothing that stopped being usable more recently
      # than that is touched.
      def prune(days: DEFAULT_DAYS)
        cutoff = Time.now - (days * 60 * 60 * 24)
        DB.transaction do
          { grants: spent_grants(cutoff).delete, applications: abandoned_applications(cutoff).delete }
        end
      end

      # Revoked, or expired so long ago that even its refresh token is past presenting.
      # A live grant has a null revoked_at, which compares false either way.
      def spent_grants(cutoff)
        refresh_deadline = cutoff - REFRESH_WINDOW
        DB[:oauth_grants].where { (revoked_at < cutoff) | (expires_in < refresh_deadline) }
      end

      # Registered itself, has been around longer than the grace period, and is named
      # by nothing. A client provisioned by hand belongs to an account and is never
      # collected: it may be waiting to be used for the first time.
      def abandoned_applications(cutoff)
        REFERENCES.inject(unowned_applications(cutoff)) do |scope, (table, column)|
          scope.exclude(id: DB[table].exclude(column => nil).select(column))
        end
      end

      def unowned_applications(cutoff)
        DB[:oauth_applications].where(account_id: nil).where { created_at < cutoff }
      end
    end
  end
end

