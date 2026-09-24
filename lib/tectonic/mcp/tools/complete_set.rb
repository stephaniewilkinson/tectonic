# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Marks a written set as lifted, optionally recording what was actually done.
      #
      # The prescription is left alone. planned_weight and planned_reps stay exactly as
      # the program wrote them, so a set lifted heavier or lighter than planned still
      # reads as a deviation afterwards -- which is the signal the session view colours
      # amber and the one a coach reads a week by. Logging a replacement set instead, the
      # only thing that was possible before, threw that away and left the planned row
      # sitting there uncompleted.
      class CompleteSet < Tool
        tool_name 'complete_set'
        title 'Mark a set as lifted'
        description 'Mark a set as lifted. Pass weight, reps or rpe to record what was ' \
                    'actually done, which leaves what was prescribed intact for comparison. ' \
                    'Pass completed false to undo.'
        scope :write
        input_schema(
          type: 'object',
          properties: { set_id: { type: 'integer' }, weight: { type: 'number' },
                        reps: { type: 'integer' }, rpe: { type: 'integer' },
                        completed: { type: 'boolean' } },
          required: ['set_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          set = Resolver.find_set(context, arguments[:set_id])
          changed = Changes.apply(set, attributes(set, arguments))
          ok("#{set.exercise.name} #{Presenter.load_phrase(set)}: #{Changes.describe(changed)}.",
             structured: Presenter.view_set(set.refresh).merge(changed:))
        end

        def self.attributes(set, arguments)
          lifted = arguments.slice(:weight, :reps, :rpe)
          check(lifted)
          Bounds.rating_fits!(lifted[:rpe], warmup: set.is_warmup, timed: set.timed?)
          # Through completion_to so the stamp travels with the flag (#281) and so a set
          # already in the state being asked for keeps the stamp it has (#542). This is the
          # other path that can un-complete a set, and the one most easily forgotten -- the
          # session screen's Done is the obvious one and this is the quiet one.
          #
          # The no-op matters more here than on the screen, because nothing is watching. An
          # assistant retrying a call it is not sure landed is the ordinary shape of a retry,
          # and until #542 the second one moved completed_at to whenever the retry happened --
          # rewriting when a set was lifted, in a session the lifter finished hours ago, and
          # reporting the move back to them as a change they had asked for. Now there is
          # nothing to change, and Changes.describe says exactly that.
          lifted.merge(set.completion_to(arguments.fetch(:completed, true)))
        end

        def self.check(lifted)
          Bounds.check(Bounds::WEIGHT, lifted[:weight], 'Weight', unit: ' lb')
          Bounds.check(Bounds::REPS, lifted[:reps], 'Reps')
          Bounds.check(Bounds::RPE, lifted[:rpe], 'RPE')
        end
      end
    end
  end
end

