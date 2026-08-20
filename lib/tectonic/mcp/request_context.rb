# frozen_string_literal: true

require_relative '../workouts'
require_relative '../exercises'
require_relative '../sets'
require_relative '../oauth_application'
require_relative '../program_days'
require_relative '../program_lifts'
require_relative '../program_weeks'
require_relative '../programs'

class Tectonic < Roda
  module MCP
    # The single object a tool is handed for a request. It carries the resolved
    # account and its granted scopes and exposes only datasets already filtered to
    # that account. A tool cannot widen the account: there is no account_id setter and
    # no accessor that hands back an unscoped model, so a cross-account query is
    # unexpressible through the context rather than merely discouraged. Tools receive
    # this (never a raw model, never an account_id argument), which is the scoping
    # guarantee every future tool inherits for free.
    class RequestContext
      attr_reader :account_id, :email, :scopes, :application_id

      # Builds a context from a verified access token's JWT claims: `sub` is the
      # account (the resource owner for the authorization-code grant), `client_id`
      # identifies the OAuth application (the LLM, for provenance and audit), and
      # `scope` is the space-separated grant. A client-credentials token carries the
      # client_id in `sub`, so the account falls back to the application's owner.
      def self.from_claims(claims)
        application = OAuthApplication.where(client_id: claims['client_id']).first
        account_id = account_id_from(claims, application)
        account = account_id && DB[:accounts].where(id: account_id).first
        new(account_id:, email: account && account[:email],
            scopes: claims['scope'].to_s.split, application_id: application&.id)
      end

      # The account a token acts on: the numeric `sub` of a user grant, else the owner
      # of the client (a client-credentials grant carries no resource owner).
      def self.account_id_from(claims, application)
        sub = claims['sub'].to_s
        sub.match?(/\A\d+\z/) ? sub.to_i : application&.account_id
      end

      def initialize(account_id:, email:, scopes:, application_id:)
        @account_id = account_id
        @email = email
        @scopes = scopes.map(&:to_s).freeze
        @application_id = application_id
      end

      # The account's workouts, and nothing else's.
      def workouts
        Workout.where(account_id: @account_id)
      end

      # Exercises the account may see: its own plus the shared library, reusing the
      # existing visibility scope so the two never drift apart.
      def exercises
        Exercise.visible_to(@account_id)
      end

      # Sets belonging to the account, reached only through its own workouts.
      def sets
        Set.where(workout_id: workouts.select(:id))
      end

      # The account's training blocks, and the three tables hanging off them. Each is
      # reached through the one above rather than by its own account column, because
      # only `programs` carries one -- a lift is the account's because its day is,
      # because its week is, because its block is. Written as nested subqueries so the
      # chain is enforced by the database on every read, which keeps the guarantee at
      # the top of this file true for programs too: there is no accessor here that can
      # be widened to another account's plan.
      def programs
        Program.where(account_id: @account_id)
      end

      def program_weeks
        ProgramWeek.where(program_id: programs.select(:id))
      end

      def program_days
        ProgramDay.where(program_week_id: program_weeks.select(:id))
      end

      def program_lifts
        ProgramLift.where(program_day_id: program_days.select(:id))
      end

      # Whether the token carries a given scope; the tool base class checks this before
      # a tool body runs.
      def scope?(name)
        @scopes.include?(name.to_s)
      end

      # Returns self so the tool base class can unwrap an MCP::ServerContext (which
      # delegates unknown methods here) to the raw context uniformly.
      def unwrap
        self
      end
    end
  end
end

