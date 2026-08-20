# frozen_string_literal: true

require 'mcp'
require_relative 'config'
require_relative 'logging'
require_relative 'request_context'
require_relative '../mcp_audit_log'

class Tectonic < Roda
  module MCP
    # Base class for every Tectonic MCP tool. A subclass declares a scope and a JSON
    # schema and implements `perform`; this class owns everything around the body:
    # scope enforcement, the write kill switch, refuse-and-explain errors, and audit
    # logging. Argument validation against the declared schema is done by the mcp gem
    # before `call` is reached, and its failure is already the refuse-and-explain shape.
    # Adding a tool is therefore: subclass, declare a schema, declare a scope, write
    # `perform`. Nothing else.
    class Tool < ::MCP::Tool
      # A refuse-and-explain failure a tool body may raise. The message is meant for a
      # model to read and correct from; it is audited and returned as an error result,
      # never as a stack trace.
      class Refusal < StandardError; end

      class << self
        # Declares the scope a token must carry to call this tool. Required; a tool that
        # declares none refuses to run.
        def scope(value = nil)
          @scope = value.to_sym if value
          @scope || raise("#{name} must declare `scope :read` or `scope :write`")
        end

        # Opts a read tool into audit logging. Writes are always audited; a read is
        # logged only when its tool declares `audit_reads`.
        def audit_reads
          @audit_reads = true
        end

        def audit_reads?
          @audit_reads || false
        end

        # Entry point the mcp gem invokes. Unwraps the account context and runs the
        # guarded invocation; the gem has already validated `arguments` against the
        # declared schema.
        def call(server_context:, **arguments)
          Invocation.new(self, unwrap(server_context), arguments).run
        end

        # A model-readable success result. `structured` rides along as structuredContent
        # for clients that read it.
        def ok(text, structured: nil)
          ::MCP::Tool::Response.new([{ type: 'text', text: text }], structured_content: structured)
        end

        # The refuse-and-explain error result.
        def refuse(message)
          ::MCP::Tool::Response.new([{ type: 'text', text: message }], error: true)
        end

        # Subclass hook. Receives the account-scoped context and the validated
        # arguments and returns an ::MCP::Tool::Response (via `ok` or `refuse`).
        def perform(context:, arguments:)
          raise NotImplementedError, "#{name} must implement `perform`"
        end

        # Unwraps an MCP::ServerContext to the RequestContext it delegates to, so a tool
        # sees the raw context whether it is called through the gem or directly.
        def unwrap(server_context)
          server_context.respond_to?(:unwrap) ? server_context.unwrap : server_context
        end
      end

      # Runs one tool call: the scope gate, the kill switch, the body, and the audit
      # row. One instance per call keeps per-request state off the shared tool class.
      class Invocation
        def initialize(tool, context, arguments)
          @tool = tool
          @context = context
          @arguments = arguments
          @clock = now
        end

        def run
          reason = gate
          return refuse(reason) if reason

          finish(@tool.perform(context: @context, arguments: @arguments))
        rescue Refusal => e
          refuse(e.message)
        rescue StandardError => e
          crash(e)
        end

        private

        # The reason to refuse before the body runs, or nil to proceed.
        def gate
          return "This tool needs the '#{@tool.scope}' scope; this token grants: #{granted}." unless authorized?
          return 'Writes are disabled on this server right now, so nothing was changed.' if writes_blocked?

          nil
        end

        def authorized?
          @context.scope?(@tool.scope)
        end

        def writes_blocked?
          @tool.scope == :write && !Config.writes_enabled?
        end

        def granted
          @context.scopes.empty? ? 'none' : @context.scopes.join(', ')
        end

        # A body result: audit success or the tool's own error, then return it.
        def finish(response)
          status = response.error? ? 'error' : 'success'
          settle(status, response.error? ? text_of(response) : nil)
          response
        end

        # A pre-body refusal: audited and logged as refused, returned as an error result.
        def refuse(message)
          settle('refused', message)
          @tool.refuse(message)
        end

        # An unexpected exception: audit the real cause, but return a generic message so
        # no internals leak to the client.
        def crash(exception)
          settle('error', exception.message)
          @tool.refuse('The tool failed unexpectedly and made no change. Please try again.')
        end

        # Writes the audit row (structurally, not per tool) and the structured log line.
        def settle(status, error)
          audit(status, error)
          MCP.log_call(tool: @tool.tool_name, account: @context.account_id,
                       status: status, duration_ms: elapsed_ms)
        end

        # Every write is audited, on success and failure alike; a read only when its tool
        # opted in or the operator turned reads on for the whole server.
        def audit(status, error)
          return unless @tool.scope == :write || @tool.audit_reads? || Config.audit_reads?

          McpAuditLog.record(context: @context, tool_name: @tool.tool_name,
                             arguments: @arguments, status: status, error: error)
        end

        def text_of(response)
          first = response.content.is_a?(Array) ? response.content.first : nil
          first.is_a?(Hash) ? first[:text] : nil
        end

        def elapsed_ms
          ((now - @clock) * 1000).round
        end

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

