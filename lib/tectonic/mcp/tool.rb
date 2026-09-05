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

        # Declares that this tool removes something a person would miss. #354.
        #
        # Only the four tools that genuinely destroy say it, which is what makes the word
        # mean something where it appears: `delete_set`, `delete_workout`, `delete_program`
        # and `delete_program_lift`. Everything else derives `destructive_hint: false` from
        # its scope without restating it.
        def destroys
          @destroys = true
        end

        def destroys?
          @destroys || false
        end

        # Opts a read tool into audit logging. Writes are always audited; a read is
        # logged only when its tool declares `audit_reads`.
        def audit_reads
          @audit_reads = true
        end

        def audit_reads?
          @audit_reads || false
        end

        # The annotations a directory listing and a permission prompt read, derived here
        # rather than declared per tool. #354.
        #
        # Both Anthropic's and OpenAI's review criteria require a title and the applicable
        # readOnlyHint or destructiveHint, and none of the thirty-five tools carried any.
        # The obvious fix is the wrong one, because of where the gem's defaults sit:
        # `Annotations#initialize` defaults `destructive_hint` and `open_world_hint` to
        # **true**, so a tool that declared `annotations(read_only_hint: true)` would go on
        # announcing itself as destructive and as reaching outside this app. Today nothing
        # is emitted at all, so that failure does not exist yet -- it would be introduced by
        # the naive fix, thirty-five times, and be wrong in the direction that makes a
        # client warn about a read.
        #
        # So it is computed from `scope`, which every tool already declares and which
        # already encodes most of the answer. The two cannot drift, and a new tool is
        # annotated correctly by declaring the scope it had to declare anyway.
        #
        # `open_world_hint` is false everywhere and not derived from anything: every tool
        # here reads and writes this app's own Postgres and nothing outside it, which is
        # exactly what that hint is for.
        #
        # `idempotent_hint` follows the scope too. A read repeated is the same read; a write
        # is not promised to be, and several here plainly are not -- create_set logs a
        # second set. Claiming otherwise would be a worse error than saying nothing, since
        # it is the hint a client would use to decide a retry is safe.
        #
        # An explicit `annotations` declaration still wins, since this only fills in what
        # nothing set. Nothing uses that today; it is left open because a tool with a
        # genuinely unusual shape should be able to say so at its own call site.
        def annotations_value
          super || ::MCP::Tool::Annotations.new(
            title: title_value, read_only_hint: scope == :read, destructive_hint: destroys?,
            idempotent_hint: scope == :read, open_world_hint: false
          )
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

