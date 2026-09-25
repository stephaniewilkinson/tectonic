# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Removes a prescribed lift from a day.
      #
      # A real delete. A program lift is a plan, not a record of training: nothing points
      # at it, the workouts it has already produced are ordinary set rows that stand on
      # their own, and a lift kept as a tombstone would have to be filtered out of every
      # read of the plan for no gain. What it was is returned, so a model that has just
      # deleted the wrong one can put it straight back with add_program_lift.
      class DeleteProgramLift < Tool
        tool_name 'delete_program_lift'
        title 'Remove a lift from a day'
        description 'Remove a lift from a training day. Returns what was removed, so it ' \
                    'can be added back if it was the wrong one. Sessions already generated ' \
                    'from this day are rewritten around any sets already lifted. Send ' \
                    'every_week true to remove the same lift from that day in every week of ' \
                    'the block in one call.'
        scope :write
        destroys
        input_schema(
          type: 'object',
          properties: { program_lift_id: { type: 'integer' }, every_week: { type: 'boolean' } },
          required: ['program_lift_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          lift = ProgramFinder.lift(context, arguments[:program_lift_id])
          removals = remove(arguments[:every_week] ? ProgramFinder.counterparts(lift) : [lift])
          arguments[:every_week] ? across_weeks(removals) : one(removals.first)
        end

        # One transaction however many weeks, so a block is never left with the lift gone from
        # some weeks and not others; each day's sessions are refreshed once it has.
        def self.remove(lifts)
          removals = lifts.map { |row| Removal.new(ProgramView.lift(row), row.program_day, nil) }
          DB.transaction { lifts.each { |row| close_gap(row, row.program_day) } }
          removals.each { |removal| removal.refresh = SessionRefresh.apply(removal.day) }
        end

        Removal = Struct.new(:lift, :day, :refresh)

        def self.one(removal)
          lift = removal.lift
          ok("Removed #{lift[:exercise]} #{lift[:sets]}x#{lift[:reps]} from #{Date::DAYNAMES[removal.day.weekday]}." \
             "#{SessionRefresh.sentence(removal.refresh, removal.day)}",
             structured: { removed: lift, session: removal.refresh.to_s })
        end

        # Every week's copy is returned, since they can differ -- a deload week's lighter load
        # is exactly what somebody putting one back would need.
        def self.across_weeks(removals)
          first = removals.first
          sessions = removals.map { |removal| SessionRefresh.sentence(removal.refresh, removal.day) }.join
          ok("Removed #{first.lift[:exercise]} from #{Date::DAYNAMES[first.day.weekday]} in " \
             "#{removals.length} #{removals.length == 1 ? 'week' : 'weeks'}.#{sessions}",
             structured: { removed: removals.map(&:lift) })
        end

        # Read back from the table rather than the day's loaded lifts: a day found through
        # `counterparts` has its lifts in memory already, deleted one included.
        def self.close_gap(lift, day)
          lift.delete
          day.program_lifts_dataset.order(:position, :id).all.each_with_index do |row, index|
            row.update(position: index) if row.position != index
          end
        end
      end
    end
  end
end

