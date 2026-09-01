# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Corrects the session itself: its date, its name, its note. #319.
      #
      # `create_workout` is idempotent *on* a date, so calling it with the corrected day
      # opened a second session rather than moving the first, and `update_set` reached
      # weight, reps, rating, warmup and movement while nothing reached the workout's own
      # columns. Twelve completed sets filed a day early could only be fixed by re-entering
      # all of them.
      #
      # **The browser has been able to do this all along**, which makes the gap sharper
      # rather than softer: `POST /workouts` with an id updates date, name and note. So an
      # assistant was the only caller that could not fix a mistake an assistant is the most
      # likely to make -- it is the path that writes a session ahead of time, under a date
      # taken from a model's idea of today.
      #
      # **Two sessions on a date is a feature and not a collision**, which is what settles
      # the shape of this. #89 asked for it, `workouts.name` exists to tell the two apart,
      # `Calendar.by_day` groups a day's rows rather than taking one, and the index on
      # (account_id, date) is non-unique on purpose. So a move onto an occupied day is not
      # refused, and it does not merge -- merging would delete a row from a tool called
      # "update", and destroy the exact arrangement two_a_day_spec exists to protect.
      #
      # **What is reported instead is the day.** The thing worth surfacing was never the two
      # rows; it is that `Resolver.workout` and `find_workout` both take `order(:id).first`,
      # so after a move every date-keyed call silently resolves to whichever session is
      # older. Naming the sessions now on that date, and which id a date-keyed call will
      # hand back, surfaces that at the moment it is created -- and leaves the assistant to
      # judge whether two was what the user meant, which is the split #263 drew.
      class UpdateWorkout < Tool
        tool_name 'update_workout'
        description 'Correct a session: its date, its name, or its note. Moving a session ' \
                    'to another date is how a workout logged under the wrong day is fixed, ' \
                    'since create_workout would open a second one. Send only what changes; ' \
                    'send name or note as an empty string to clear it. A day may hold more ' \
                    'than one session, so this never refuses a move -- it reports every ' \
                    'session on the day afterwards, and which one a call by date resolves to.'
        scope :write
        input_schema(
          type: 'object',
          properties: { workout_id: { type: 'integer' }, date: { type: 'string' },
                        name: { type: 'string' }, note: { type: 'string' } },
          required: ['workout_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          workout = find(context, arguments[:workout_id])
          changed = Changes.apply(workout, attributes(arguments))
          day = sharing(context, workout.refresh)
          ok(sentence(workout, changed, day),
             structured: Presenter.view_workout(workout).merge(changed:, day_holds: day))
        end

        # `key?` rather than a nil check on the two text columns, so "leave it alone" and
        # "empty it" stay different requests -- the rule `create_workout` already follows,
        # and the reason a note can be cleared at all.
        #
        # The date is parsed through the same Resolver every other tool uses, so 'today' and
        # an ISO day mean here what they mean there, and an unparseable one is refused in
        # one voice rather than in a second one written here.
        def self.attributes(arguments)
          fields = {}
          fields[:date] = Resolver.parse_date(arguments[:date]) if arguments[:date]
          fields[:name] = Workout.clean_name(arguments[:name]) if arguments.key?(:name)
          fields[:note] = Workout.clean_note(arguments[:note]) if arguments.key?(:note)
          fields
        end

        # By id, scoped to the account, which is what makes another account's session
        # unreachable rather than merely unlikely.
        def self.find(context, id)
          context.workouts.where(id:).first ||
            (raise Tool::Refusal, "No workout with id #{id.inspect} on this account.")
        end

        # Every session on the day this one is now on, oldest first -- which is the order
        # `Resolver.workout` resolves in, so the first of these is the one a later call by
        # date will hand back. Read after the move rather than before it, because the
        # question is what the day looks like now.
        #
        # `resolves` marks the row `order(:id).first` picks and *not* the row that just
        # moved, which is the whole point of reporting this: a session moved onto an
        # occupied day is usually the newer of the two, so the one a date-keyed call finds
        # is the other one. Flagging the moved session would tell the caller the opposite of
        # what is true.
        def self.sharing(context, workout)
          context.workouts.where(Sequel.cast(:date, :date) => workout.date.to_date).order(:id).all
                 .each_with_index
                 .map { |other, index| { id: other.id, label: other.label, resolves: index.zero? } }
        end

        # Silent about the day where there is only this session on it, which is nearly every
        # call: a tool that appended "1 session on that date" to every response would train
        # a reader to skip the line that matters on the one call where two share a day.
        def self.sentence(workout, changed, day)
          moved = "Workout #{workout.id} on #{workout.date.strftime('%Y-%m-%d')}: #{Changes.describe(changed)}."
          return moved if day.length < 2

          "#{moved} That date now holds #{day.length} sessions (#{day.map { |o| label_of(o) }.join(', ')}); " \
            "a call by date resolves to #{day.first[:id]}."
        end

        def self.label_of(other)
          "#{other[:id]}#{" #{other[:label]}" if other[:label]}"
        end
      end
    end
  end
end

