# frozen_string_literal: true

require 'mcp'
require_relative 'applications'
require_relative 'config'
require_relative 'logging'
require_relative 'request_context'
require_relative '../mcp_audit_log'
require_relative '../error_reporting'

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

      # Every id and count here is a Postgres integer; see Invocation#out_of_range.
      INTEGER_RANGE = (-2_147_483_648..2_147_483_647)

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

        # The writes that only ever insert new rows: they can add to an account but cannot
        # change or remove anything already in it. Every other write is marked destructive.
        #
        # Anthropic's directory criteria: "`destructiveHint: true` for tools that modify or
        # delete data". This used to be true only of the four delete tools, which left
        # update_set, update_exercise and the rest -- tools that rewrite logged history --
        # announcing themselves as harmless. Destructive tools always ask before running, so
        # the line is drawn at the data rather than at the word "delete": logging a new set
        # by conversation stays a single step, and anything that can change what is already
        # there asks first.
        #
        # Listed by name rather than declared in each tool so the whole policy reads in one
        # place, and so a new write tool is destructive until somebody decides otherwise.
        # create_program is here because it refuses rather than touching a block that exists;
        # create_exercise and create_workout are not, because each can rewrite an existing
        # row's note, and generate_program_week is not, because it replaces unlifted sets.
        ADDS_ONLY = %w[create_set create_program add_program_day add_program_lift add_program_week].freeze

        # The tools that reach outside this app while they run: the three health reads check
        # Withings for anything newer before answering (Freshness). Everything else touches
        # this app's own Postgres and nothing else.
        REACHES_OUT = %w[health_readings body_composition bodyweight_trend].freeze

        def modifies_existing?
          destroys? || (scope == :write && !ADDS_ONLY.include?(tool_name))
        end

        def reaches_out? = REACHES_OUT.include?(tool_name)

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
        # `open_world_hint` is true only for the tools in REACHES_OUT, which call Withings
        # mid-read. It was false everywhere until a review noticed they do.
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
            title: title_value, read_only_hint: scope == :read, destructive_hint: modifies_existing?,
            idempotent_hint: scope == :read, open_world_hint: reaches_out?
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

        # Applications.during wraps the body rather than the whole method, because the gate
        # and the audit row below it name no creator and a refusal should not read a table to
        # say no. See lib/tectonic/mcp/applications.rb for what it is and why the binding is
        # opened here: this is the one place every tool body runs inside, and per-call state
        # is what this object already exists to hold.
        def run
          reason = gate
          return refuse(reason) if reason

          finish(Applications.during { atomically { @tool.perform(context: @context, arguments: @arguments) } })
        rescue Refusal => e
          refuse(e.message)
        rescue StandardError => e
          crash(e)
        end

        private

        # A write runs as one transaction, so a tool that fails halfway leaves nothing behind.
        # Before this, only some write tools opened a transaction of their own, and the crash
        # message below promised "made no change" for all of them -- untrue for create_set or
        # update_exercise failing after their first write. A refusal raised mid-body rolls
        # back too, which is what a refusal means. Reads are left alone: they write nothing,
        # and the health reads call Withings, which should not hold a transaction open.
        def atomically(&)
          @tool.scope == :write ? DB.transaction(&) : yield
        end

        # The reason to refuse before the body runs, or nil to proceed.
        def gate
          return "This tool needs the '#{@tool.scope}' scope; this token grants: #{granted}." unless authorized?
          return 'Writes are disabled on this server right now, so nothing was changed.' if writes_blocked?

          out_of_range
        end

        # Every id and count here is a Postgres integer. A bigger one -- get_program with
        # program_id 99999999999, a week numbered the same -- passed the JSON schema, reached the
        # database, and came back as a crash. Refused here instead, once for every tool.
        def out_of_range
          key, = @arguments.find { |_, value| value.is_a?(Integer) && !Tool::INTEGER_RANGE.cover?(value) }
          "#{key} is out of range: no #{key} that large exists." if key
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
        #
        # A refusal is never reported. It is the tool declining on purpose -- the designed
        # outcome of a bad request, not a fault -- and reporting it would bury the crashes
        # under noise. It does leave a breadcrumb, so that when a crash does arrive the report
        # shows what the assistant was refused just before it, which is often the whole story:
        # a model that has been told twice it lacks a scope and then hits an exception was
        # probably doing something the app has never been driven through.
        #
        # The refusal *message* is deliberately left out of the breadcrumb. Several are built
        # from what the caller sent -- "No exercise named ..." carries a movement name -- and
        # that is a lifter's data, on the same reasoning that sends argument keys rather than
        # argument values from `report` below.
        def refuse(message)
          leave_breadcrumb
          settle('refused', message)
          @tool.refuse(message)
        end

        def leave_breadcrumb
          return unless ErrorReporting.on?

          Sentry.add_breadcrumb(
            Sentry::Breadcrumb.new(category: 'mcp', level: 'info',
                                   message: "refused #{@tool.tool_name}")
          )
        rescue StandardError
          # A breadcrumb is a nicety; losing one must not turn a refusal into a failure.
        end

        # An unexpected exception: audit the real cause, but return a generic message so
        # no internals leak to the client.
        #
        # **Reported before it is answered.** #384. This rescue is the last thing between the
        # failure and a well-formed MCP response, so nothing propagates out to
        # Sentry::Rack::CaptureExceptions in config.ru and every unexpected failure in every
        # tool was invisible in Sentry by construction. Two things made that the worst place
        # in the app for it to be true: nobody watches this traffic -- an LLM drives the
        # endpoint, and one told "please try again" will retry, apologise to the lifter, and
        # never mention it -- and `exception.message` is the least useful part of an
        # exception. `undefined method 'each' for nil` was the whole artifact; the class, the
        # backtrace, the cause, the tool and the arguments were all present at the raise site
        # and none of them kept.
        #
        # Capturing first and answering second is the order that matters: the report exists
        # whether or not the response after it is well formed.
        def crash(exception)
          report(exception)
          settle('error', exception.message)
          @tool.refuse(crash_message)
        end

        # Specific and true. A write was rolled back by `atomically`, so it can say nothing was
        # saved and that a retry cannot double anything; a read changed nothing to begin with.
        def crash_message
          name = @tool.tool_name
          if @tool.scope == :write
            "#{name} hit an unexpected error and nothing it was doing was saved. It has been reported; " \
              'calling it again with the same arguments is safe.'
          else
            "#{name} hit an unexpected error and could not answer. It has been reported; nothing was changed."
          end
        end

        # What Sentry is told about a crash, and what it is deliberately not told.
        #
        # `argument_keys` rather than `arguments`: the values are a lifter's training data and
        # send_default_pii is off on purpose in config.ru, so shipping them would undo that
        # decision from a different file. The keys are enough to tell "create_set blew up with
        # a weight given" from "create_set blew up without one", which is the diagnostic
        # question, and they are the tool's own schema rather than anybody's data.
        #
        # Rescued because a reporting failure must not become the lifter's failure: the
        # response below is well formed and the audit row still gets written whatever happens
        # here. That is the same rule ErrorReporting.capture_task_failure follows for rake.
        def report(exception)
          return unless ErrorReporting.on?

          Sentry.capture_exception(exception, tags: { surface: 'mcp', tool: @tool.tool_name },
                                              extra: { account_id: @context.account_id,
                                                       argument_keys: @arguments.keys })
        rescue StandardError => e
          MCP.log_call(tool: @tool.tool_name, account: @context.account_id,
                       status: "report-failed:#{e.class}", duration_ms: elapsed_ms)
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
                             arguments: storable(@arguments), status: status, error: storable(error))
        rescue StandardError => e
          # An audit row that cannot be written must not become the caller's error. It was
          # possible: a NUL in any argument is valid JSON and invalid jsonb, so Postgres refused
          # the row, the exception escaped this rescue-of-a-rescue, and the client got the
          # gem's bare "Internal error" -- the generic message the directory criteria reject.
          MCP.log_call(tool: @tool.tool_name, account: @context.account_id,
                       status: "audit-failed:#{e.class}", duration_ms: elapsed_ms)
        end

        # Postgres text and jsonb refuse NUL; nothing a lifter means contains one.
        def storable(value)
          case value
          when String then value.delete("\u0000")
          when Hash then value.to_h { |key, inner| [key, storable(inner)] }
          when Array then value.map { |inner| storable(inner) }
          else value
          end
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

