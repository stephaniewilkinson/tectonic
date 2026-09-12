# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # token minting and call_tool
require 'securerandom'

# Every MCP tool crash used to be invisible in Sentry, by construction. #384.
#
# `Invocation#run` ends with `rescue StandardError => e; crash(e)`, and that rescue is the last
# thing between the failure and a well-formed MCP response -- so nothing propagates out to
# `Sentry::Rack::CaptureExceptions` in config.ru. Two things made this the worst place in the
# app for that to be true:
#
#   * Nobody watches this traffic. An LLM drives the endpoint, not a person. A human hitting a
#     500 on /workouts will eventually say so; an assistant told "please try again" will
#     retry, apologise to the lifter, and never mention it.
#   * `exception.message` was the only artifact kept, and it is the least useful part of an
#     exception. A NoMethodError stored "undefined method 'each' for nil". Which tool, which
#     line, which account, which arguments -- all present at the raise site, none of it kept.
#
# The suite has no DSN, so what is asserted here is the contract around the capture rather
# than the network call: that the crash path still answers the client the same way, that
# reporting cannot become the lifter's failure, and that a refusal is not reported.
module Crashing
  # A tool that blows up in its body, registered for the length of one example. Subclassing
  # the real Tool is the point -- what is under test is Invocation's rescue, so the failure
  # has to arrive the way a genuine bug would.
  def crashing_tool(&body)
    Class.new(Tectonic::MCP::Tool) do
      tool_name "crash_probe_#{SecureRandom.hex(4)}"
      title 'Crash probe'
      description 'Raises, for testing the crash path.'
      # A write, so that every call lands an audit row -- reads only audit when the tool
      # opts in or the operator turns them on, and the audit row is half of what is asserted.
      scope :write
      input_schema(type: 'object', properties: {}, additionalProperties: false)
      define_singleton_method(:perform) { |context:, arguments:| body.call(context, arguments) }
    end
  end

  def invoke(tool, context: nil, arguments: {})
    Tectonic::MCP::Tool::Invocation.new(tool, context || fake_context, arguments).run
  end

  # Enough of a RequestContext for the crash path: a scope to pass the gate, an account to
  # name in the report, and the application the audit row hangs the call off. A real account
  # id, because mcp_audit_log.account_id is a foreign key and a made-up one would fail the
  # insert for a reason that has nothing to do with what is being tested.
  def fake_context
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    Struct.new(:account_id, :scopes, :application_id) do
      def scope?(_wanted) = true
    end.new(account_id, [:write], nil)
  end

  def text_of(response)
    response.to_h[:content].first[:text]
  end
end

describe 'a tool that blows up' do
  include Crashing

  before do
    @tool = crashing_tool { raise NoMethodError, "undefined method 'each' for nil" }
  end

  # The client-facing half is unchanged, and has to be: no internals leak to the model.
  it 'still answers a generic refusal rather than the exception' do
    response = invoke(@tool)

    assert_includes text_of(response), 'failed unexpectedly'
    refute_includes text_of(response), 'undefined method'
  end

  it 'still audits the real cause where the client is told nothing' do
    invoke(@tool)
    row = DB[:mcp_audit_log].order(:id).last

    assert_equal 'error', row[:result_status]
    assert_includes row[:error_message], 'undefined method'
  end
end

# Reporting is an addition to a failure, never a cause of a different one. If the capture
# raises -- a broken DSN, a network down, a Sentry outage -- the lifter must still get a
# well-formed answer and the audit row must still be written.
describe 'a crash whose report fails' do
  include Crashing

  # Reporting is switched on while Sentry itself is not loaded -- the suite never requires it
  # -- so `Sentry.capture_exception` raises NameError inside `report`. That is a real failure
  # arriving at the real rescue, rather than a stub standing in for the thing under test.
  before do
    @tool = crashing_tool { raise 'the original failure' }
    Tectonic::ErrorReporting.singleton_class.alias_method(:real_on?, :on?)
    Tectonic::ErrorReporting.singleton_class.define_method(:on?) { true }
  end

  after do
    Tectonic::ErrorReporting.singleton_class.alias_method(:on?, :real_on?)
  end

  it 'is not what the client hears about' do
    response = invoke(@tool)

    assert_includes text_of(response), 'failed unexpectedly'
  end

  it 'audits the original failure, not the reporting one' do
    invoke(@tool)

    assert_includes DB[:mcp_audit_log].order(:id).last[:error_message], 'the original failure'
  end

  # The refusal path takes the same treatment: a breadcrumb is a nicety, and losing one must
  # not turn a refusal into a failure.
  it 'leaves a refusal working when the breadcrumb cannot be left' do
    tool = crashing_tool { raise Tectonic::MCP::Tool::Refusal, 'that movement is not yours' }

    assert_includes text_of(invoke(tool)), 'not yours'
  end
end

# A refusal is the tool declining on purpose -- the designed outcome of a bad request -- so it
# is audited as refused and never reported. Reporting refusals would bury the crashes.
describe 'a tool that refuses on purpose' do
  include Crashing

  it 'is audited as refused rather than as an error' do
    tool = crashing_tool { raise Tectonic::MCP::Tool::Refusal, 'that movement is not yours' }
    invoke(tool)
    row = DB[:mcp_audit_log].order(:id).last

    assert_equal 'refused', row[:result_status]
  end

  # The refusal reaches the model, because it is written for a model to correct from.
  it 'tells the model what it was' do
    tool = crashing_tool { raise Tectonic::MCP::Tool::Refusal, 'that movement is not yours' }

    assert_includes text_of(invoke(tool)), 'not yours'
  end
end

# Nothing here talks to Sentry, and these are the paths that prove it cannot: reporting is off
# in the suite, so every hook is a no-op and none of them may raise.
describe 'the crash path with reporting switched off' do
  include Crashing

  it 'reports nothing, because there is nowhere to report to' do
    refute Tectonic::ErrorReporting.on?
  end

  it 'runs the whole crash path without raising' do
    invoke(crashing_tool { raise 'boom' })
  end

  it 'runs the whole refusal path without raising' do
    invoke(crashing_tool { raise Tectonic::MCP::Tool::Refusal, 'no' })
  end
end

