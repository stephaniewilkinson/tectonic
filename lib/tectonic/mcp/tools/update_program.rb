# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Changes a block's own settings, which nothing could do until #260.
      #
      # There was update_program_day and update_program_lift and no update_program, so the
      # five fields that describe the block rather than the work in it were immutable once
      # written. Two of them shape generation -- is_ascending and preferred_reps -- so
      # switching a block from ascending to flat sets could only be done by editing every
      # generated set one at a time, which fixes the weeks already written and leaves the
      # ungenerated ones to come out the old way. The block ends up half one thing and half
      # the other, and the fix is at the wrong level entirely.
      #
      # The web editor cannot reach them either (program_editor hard-codes preferred_reps to
      # nil, and is_ascending appears in views once as a read-only label), so this was a gap
      # in the product rather than only in the API.
      class UpdateProgram < Tool
        # Nullable on purpose: notes, block and preferred_reps are all "not set" as much as
        # they are a value, and clearing one has to be expressible. name and start_date are
        # NOT NULL in the schema and are refused below rather than passed through to a
        # constraint violation.
        NUMBER_OR_NULL = { type: %w[integer null] }.freeze

        tool_name 'update_program'

        title 'Edit a training block'
        description "Change a training block's own settings: its name, block number, " \
                    'notes, start date, whether working sets ascend to the top weight, ' \
                    'and the rep count main work is converted to. Send only what changes. ' \
                    'is_ascending and preferred_reps take effect on weeks generated after ' \
                    'this; weeks already generated are not rewritten.'
        scope :write
        input_schema(
          type: 'object',
          properties: {
            program_id: { type: 'integer' }, name: { type: 'string' },
            block: NUMBER_OR_NULL, notes: { type: %w[string null] },
            start_date: { type: 'string' }, is_ascending: { type: 'boolean' },
            preferred_reps: NUMBER_OR_NULL
          },
          required: ['program_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          program = ProgramFinder.program(context, arguments[:program_id])
          changed = Changes.apply(program, fields(arguments))
          ok("#{program.name}: #{Changes.describe(changed)}.#{regeneration(changed)}",
             structured: ProgramView.program(program.refresh).merge(changed:))
        end

        # Deliberately not rewriting the sessions a block has already generated, which is
        # the opposite of what update_program_lift does, and for a reason: a lift edit
        # changes one movement's prescription, and a block setting changes how every set in
        # every generated week was laid out. Silently rewriting a fortnight of sessions --
        # including today's, which somebody may be halfway through -- is not a thing to do
        # on the way past. Said out loud instead, so a model can offer to regenerate.
        def self.regeneration(changed)
          return '' unless changed.key?(:is_ascending) || changed.key?(:preferred_reps)

          ' Weeks already generated keep the sets they were written with; ' \
            'regenerate a week to lay it out the new way.'
        end

        def self.fields(arguments)
          attributes = arguments.slice(:name, :block, :notes, :is_ascending, :preferred_reps)
          check(attributes)
          return attributes unless arguments.key?(:start_date)

          attributes.merge(start_date: Resolver.parse_date(arguments[:start_date]))
        end

        # A name is NOT NULL and a blank one leaves a block nothing to be called in any
        # list it appears in, so it is refused here by name rather than reaching the
        # constraint as a 500. preferred_reps has the same bound the writer applies
        # everywhere else a rep count is written.
        def self.check(attributes)
          raise Tool::Refusal, 'A block needs a name.' if attributes.key?(:name) && attributes[:name].to_s.strip.empty?

          Bounds.check(Bounds::REPS, attributes[:preferred_reps], 'preferred_reps')
        end
      end
    end
  end
end

