# frozen_string_literal: true

require_relative '../workouts'
require_relative '../exercises'
require_relative '../sets'
require_relative '../api_token'

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
      attr_reader :account_id, :email, :scopes, :token_id

      # Builds a context from a verified ApiToken, reading identity straight off the
      # account row so a tool never has to name an account itself.
      def self.from_token(token)
        account = token.db[:accounts].where(id: token.account_id).first
        new(account_id: token.account_id, email: account && account[:email],
            scopes: token.scope_list, token_id: token.id)
      end

      def initialize(account_id:, email:, scopes:, token_id:)
        @account_id = account_id
        @email = email
        @scopes = scopes.map(&:to_s).freeze
        @token_id = token_id
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

