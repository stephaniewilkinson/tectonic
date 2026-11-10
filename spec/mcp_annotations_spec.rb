# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/mcp'

# #354: not one registered tool carried a title or an annotation, which both directory
# listings reject outright. Anthropic's criteria: "All tools must include a `title` and the
# applicable `readOnlyHint` or `destructiveHint`."
#
# The annotations are derived from `scope` in Tool rather than declared per tool, so most of
# what is asserted here is that the derivation reaches every tool -- and, more importantly,
# that the gem's defaults never do. Those default `destructive_hint` and `open_world_hint`
# to **true**, so the naive fix (declare `annotations(read_only_hint: true)` on each tool)
# would have left thirty-odd tools announcing themselves as destructive and as reaching
# outside this app. That is the failure this spec is really watching for.
module Annotated
  TOOLS = Tectonic::MCP::ServerFactory::TOOLS

  # The four that genuinely remove something a person would miss.
  DESTROYS = %w[delete_set delete_workout delete_program delete_program_lift].freeze

  # The writes that only insert new rows, and so are the only writes not marked destructive.
  ADDS_ONLY = %w[create_set create_program add_program_day add_program_lift add_program_week].freeze

  # The tools that call Withings while they run.
  REACHES_OUT = %w[health_readings body_composition bodyweight_trend].freeze

  # Methods rather than bare constant references in the describes: a constant defined in a
  # module is not resolved lexically from inside a block that merely includes it.
  def all_tools = TOOLS

  def destroying = DESTROYS

  def adds_only = ADDS_ONLY

  def reaching_out = REACHES_OUT

  def annotations_of(tool) = tool.to_h[:annotations]

  def reads = TOOLS.select { |tool| tool.scope == :read }

  def writes = TOOLS.select { |tool| tool.scope == :write }
end

describe 'every tool a client is offered' do
  include Annotated

  it 'has a title' do
    missing = all_tools.reject { |tool| tool.to_h[:title] }

    assert_empty missing.map(&:tool_name), 'these tools have no title'
  end

  # Human-facing, so it is a phrase rather than the identifier. A card in a directory and a
  # permission prompt both show this, and "list_workouts" in a sentence asking someone to
  # grant access reads as a leak of the implementation.
  it 'has a title that is not just the tool name' do
    echoed = all_tools.select { |tool| tool.to_h[:title].to_s.include?('_') }

    assert_empty echoed.map(&:tool_name), 'these titles are the identifier rather than a phrase'
  end

  it 'has annotations at all' do
    missing = all_tools.reject { |tool| annotations_of(tool) }

    assert_empty missing.map(&:tool_name), 'these tools emit no annotations'
  end

  # Only the health reads reach outside this app, to Withings, and the gem defaults the hint
  # to true for everything -- so both directions are asserted.
  it 'says it reaches outside this app only when it calls Withings' do
    open_world = all_tools.select { |tool| annotations_of(tool)[:openWorldHint] }.map(&:tool_name)

    assert_equal reaching_out.sort, open_world.sort
  end
end

describe 'what a read tool says about itself' do
  include Annotated

  it 'is marked read-only' do
    wrong = reads.reject { |tool| annotations_of(tool)[:readOnlyHint] }

    assert_empty wrong.map(&:tool_name)
  end

  # The gem's default, and the one that would have been wrong on every read tool.
  it 'is never marked destructive' do
    wrong = reads.select { |tool| annotations_of(tool)[:destructiveHint] }

    assert_empty wrong.map(&:tool_name), 'a read cannot destroy anything'
  end

  it 'is marked idempotent, since a read repeated is the same read' do
    wrong = reads.reject { |tool| annotations_of(tool)[:idempotentHint] }

    assert_empty wrong.map(&:tool_name)
  end
end

describe 'what a write tool says about itself' do
  include Annotated

  it 'is never marked read-only' do
    wrong = writes.select { |tool| annotations_of(tool)[:readOnlyHint] }

    assert_empty wrong.map(&:tool_name)
  end

  # Not promised, and several plainly are not -- create_set logs a second set. This is the
  # hint a client would use to decide a retry is safe, so claiming it falsely is worse than
  # saying nothing.
  it 'is not marked idempotent' do
    wrong = writes.select { |tool| annotations_of(tool)[:idempotentHint] }

    assert_empty wrong.map(&:tool_name)
  end

  # Anthropic's criteria: destructiveHint for "tools that modify or delete data". So every
  # write that can change or remove what is already there says it, and only the writes that
  # purely add do not -- which keeps logging a new set from asking permission every time.
  it 'is marked destructive unless it only ever adds' do
    unmarked = writes.reject { |tool| annotations_of(tool)[:destructiveHint] }.map(&:tool_name)

    assert_equal adds_only.sort, unmarked.sort
  end

  it 'includes every tool that removes something among the destructive ones' do
    marked = writes.select { |tool| annotations_of(tool)[:destructiveHint] }.map(&:tool_name)

    assert_empty destroying - marked
  end
end

# The derivation is the point of #354: a tool annotated by hand is a tool that can disagree
# with what it actually does, and thirty-five of them restating four booleans is where that
# goes wrong once and nobody notices.
describe 'a tool that declares nothing but its scope' do
  it 'is annotated correctly anyway' do
    read = Class.new(Tectonic::MCP::Tool) { scope :read }
    write = Class.new(Tectonic::MCP::Tool) { scope :write }

    assert_equal({ destructiveHint: false, idempotentHint: true, openWorldHint: false, readOnlyHint: true },
                 read.annotations_value.to_h)
    assert_equal({ destructiveHint: true, idempotentHint: false, openWorldHint: false, readOnlyHint: false },
                 write.annotations_value.to_h)
  end

  it 'says it is destructive once it declares that it destroys' do
    tool = Class.new(Tectonic::MCP::Tool) do
      scope :write
      destroys
    end

    assert tool.annotations_value.to_h[:destructiveHint]
  end

  # An explicit declaration still wins, so a tool with a genuinely unusual shape can say so
  # at its own call site rather than arguing with the derivation.
  it 'lets a tool override the derivation outright' do
    tool = Class.new(Tectonic::MCP::Tool) do
      scope :write
      annotations(read_only_hint: true, destructive_hint: false, open_world_hint: false)
    end

    assert tool.annotations_value.to_h[:readOnlyHint]
  end
end

