# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  # A registered OAuth client -- the LLM that connects to the MCP endpoint. Provenance
  # points here ("which LLM created this object"), so it names the stable client rather
  # than a single access token, and a human-made row's FK is simply null. Reopened as a
  # plain Sequel model on rodauth-oauth's oauth_applications table.
  class OAuthApplication < Sequel::Model(:oauth_applications)
  end
end

