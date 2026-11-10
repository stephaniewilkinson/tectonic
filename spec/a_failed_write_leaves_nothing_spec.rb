# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/mcp'
require 'securerandom'

# A write tool that fails partway leaves nothing behind, so its error can truthfully say so.
#
# The crash message promised "made no change" for every tool while only some write tools
# opened a transaction; one that failed after its first insert left that row in place. Every
# write now runs inside one transaction (Tool::Invocation#atomically).
module HalfWrite
  def context(account_id)
    Tectonic::MCP::RequestContext.new(account_id:, email: 'x@example.org', scopes: %w[read write],
                                      application_id: nil)
  end

  # Writes a movement, then fails -- the shape of a tool that breaks after its first write.
  def tool_that(failure)
    Class.new(Tectonic::MCP::Tool) do
      tool_name 'half_write'
      scope :write
      define_singleton_method(:perform) do |context:, arguments:|
        Tectonic::Exercise.create(name: arguments[:name], account_id: context.account_id)
        raise failure
      end
    end
  end

  def account = DB[:accounts].insert(email: "#{SecureRandom.hex}@example.org", password_hash: 'x')
end

describe 'a write tool that fails partway' do
  include HalfWrite

  it 'saves nothing when it crashes, and says so by name' do
    id = account
    response = tool_that(RuntimeError.new('boom')).call(server_context: context(id), name: 'Half Squat')

    assert_predicate response, :error?
    assert_empty DB[:exercises].where(account_id: id, name: 'Half Squat').all
    assert_match(/\Ahalf_write hit an unexpected error and nothing it was doing was saved/,
                 response.content.first[:text])
  end

  it 'saves nothing when it refuses partway, either' do
    id = account
    refusal = Tectonic::MCP::Tool::Refusal.new('That set is already lifted.')
    response = tool_that(refusal).call(server_context: context(id), name: 'Half Bench')

    assert_equal 'That set is already lifted.', response.content.first[:text]
    assert_empty DB[:exercises].where(account_id: id, name: 'Half Bench').all
  end
end

