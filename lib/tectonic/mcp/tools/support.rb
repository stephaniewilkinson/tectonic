# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative '../../exercises'
# Exercise.barbell_by_name?, the default the resolver gives a movement it has to create.
require_relative '../../exercise_library'
require_relative '../../workouts'
require_relative '../../sets'

class Tectonic < Roda
  module MCP
    module Tools
      # The ranges every tool that writes a number checks its arguments against. They
      # live here rather than on the tool that first needed them because a weight means
      # the same thing whether it is being logged, revised or prescribed, and because a
      # refusal a model can act on is one that reads identically wherever it came from.
      # The check is in the body rather than the schema on purpose: a schema violation
      # comes back as a validation error, while this names the bound that was crossed.
      module Bounds
        WEIGHT = (0..2000)
        REPS = (1..100)
        RPE = (1..10)
        SETS = (1..20)
        PERCENT = (1..200)
        # A held position measured in seconds, up to an hour, which covers a plank at one
        # end and a walk or a bike interval at the other.
        SECONDS = (1..3600)

        module_function

        # Checks one optional value. Nil passes: a schema marks what is required, and an
        # argument that was not supplied has no bound to cross.
        def check(range, value, name, unit: '')
          return if value.nil? || range.cover?(value)

          raise Tool::Refusal, "#{name} #{value} is out of range; use #{range.first}-#{range.last}#{unit}."
        end

        # Where a rating may sit at all, as against how large it may be. #211: RPE is reps
        # in reserve, so it applies only to a working set counted in reps -- a warmup is
        # submaximal by definition and a held position has no reps for any to be spare of.
        #
        # Refused here by name rather than left to sets_rpe_only_on_working_reps, which
        # enforces the same rule. A constraint violation reaches a client as a database
        # error and reads as the tool being broken; this says which set and why, which is
        # something a model can act on.
        #
        # Takes the shape the set will have *after* the write rather than the shape it has
        # now, because update_set can move a set onto is_warmup in the same call that
        # carries a rating.
        def rating_fits!(rpe, warmup:, timed:)
          return if rpe.nil? || !(warmup || timed)

          kind = warmup ? 'a warmup' : 'a set counted in seconds'
          raise Tool::Refusal, "RPE is reps in reserve, so it does not apply to #{kind}. " \
                               'Leave rpe out, or clear is_warmup first.'
        end
      end

      # What a write actually changed, as field => from/to. An edit tool hands this back
      # so a model can tell the user exactly what moved -- "top weight 155 to 175" --
      # without having read the row beforehand and diffed it itself, which is the version
      # of this that quietly invents changes that did not happen. A field set to the value
      # it already held is not a change and does not appear.
      module Changes
        module_function

        def apply(row, attributes)
          moved = attributes.reject { |field, value| row[field] == value }
          record = moved.to_h { |field, value| [field, { from: plain(row[field]), to: value }] }
          row.update(moved) unless moved.empty?
          record
        end

        # A numeric column hands back a BigDecimal, which reports as "0.155e3" and reads
        # to an assistant as a string rather than as the weight it moved from. The
        # comparison above is left alone: BigDecimal(155) == 155 already, so a field set to
        # the value it held is still not a change.
        def plain(value)
          value.is_a?(BigDecimal) ? Plates.numeric(value) : value
        end

        def describe(record)
          return 'nothing to change' if record.empty?

          record.map { |field, move| "#{field} #{move[:from].inspect} to #{move[:to].inspect}" }.join(', ')
        end
      end

      # Find-or-create by natural key, shared by every write tool so the three never
      # diverge in how they resolve an exercise or workout or stamp provenance. Each
      # method works only through the request's account-scoped datasets, so a resolved
      # row is always the caller's own (or the shared library) and never another
      # account's -- a cross-account write is unexpressible here, not merely avoided.
      module Resolver
        module_function

        # An exercise the account already has (its own or a library one) by name, or a
        # new private one stamped with the calling token. A new one is a barbell movement
        # when the caller says so and otherwise when its name is one the library knows:
        # there is no user at the other end of this to ask, and a set that arrives without
        # the flag loses the plate math this app is named for.
        def exercise(context, name:, icon_url: nil, is_barbell: nil)
          clean = name.to_s.strip
          raise Tool::Refusal, 'An exercise needs a non-empty name.' if clean.empty?

          context.exercises.where(name: clean).order(:id).first ||
            Exercise.create(name: clean, icon_url:, account_id: context.account_id,
                            is_barbell: is_barbell.nil? ? Exercise.barbell_by_name?(clean) : is_barbell,
                            created_by_oauth_application_id: context.application_id, created_at: Time.now)
        end

        # The account's workout on a calendar date, or a new one stamped with the
        # calling token. Matching casts the timestamp to a date so it is idempotent
        # on the day regardless of the stored time-of-day.
        def workout(context, date:)
          day = date.is_a?(Date) ? date : parse_date(date)
          context.workouts.where(Sequel.cast(:date, :date) => day).order(:id).first ||
            Workout.create(account_id: context.account_id, date: day,
                           created_by_oauth_application_id: context.application_id, created_at: Time.now)
        end

        # The account's workout on a date without opening one, for the read and edit
        # tools: a question about a day that was never trained has to be answerable as
        # "nothing there" rather than by quietly creating an empty session to answer it.
        def find_workout(context, date:)
          day = date.is_a?(Date) ? date : parse_date(date)
          context.workouts.where(Sequel.cast(:date, :date) => day).order(:id).first
        end

        # One of the account's sets by id, refusing rather than returning nil: a set id
        # that belongs to someone else does not resolve here, and a model handed a silent
        # nil would report success for an edit that never touched anything.
        def find_set(context, id)
          context.sets.where(id:).first ||
            (raise Tool::Refusal, "No set with id #{id.inspect} on this account.")
        end

        # 'today' or nil for the current day, an ISO YYYY-MM-DD otherwise; anything
        # else refuses with a message a model can correct from.
        def parse_date(raw)
          text = raw.to_s.strip
          return Date.today if text.empty? || text.casecmp('today').zero?

          Date.iso8601(text)
        rescue ArgumentError
          raise Tool::Refusal, "Couldn't read #{raw.inspect} as a date; use 'today' or YYYY-MM-DD."
        end
      end

      # Turns a model row into the hash a tool returns, so a read tool and a write
      # tool describe the same object identically. Every view carries provenance.
      module Presenter
        module_function

        def view_exercise(exercise)
          { id: exercise.id, name: exercise.name, library: exercise.library? }
            .merge(provenance(exercise))
        end

        # `name` is what the row carries and `label` is what a reader would call it, which
        # differ for a generated session: that one is named by its program day's focus and
        # has no name of its own. An assistant asked to "add a set to the evening walk"
        # needs the second to match on, and an assistant asked to rename one needs the
        # first to know whether there is anything there to replace.
        # `completed` and `finished` are both here because neither answers for the other,
        # and a list that carries only `status` answers neither. #218: an assistant reading
        # a history saw `performed` -- which is true of a session with one warmup ticked --
        # over sets that were not all done, and called a finished day one still in progress.
        #
        # `completed` is the count, so a list says three-of-ten without a second call per
        # session; it used to take a get_workout each, and nothing told a reader it needed
        # one. `finished` is the lifter's own word for it, and is the only one of the two
        # that settles the question: three of ten is "I stopped early" and "I am between
        # sets" written the same way, so the count narrows it and the flag closes it.
        #
        # No extra query for either. `sets` was already being counted through the
        # association, which loads the rows, so the completed ones are counted from what is
        # in hand.
        def view_workout(workout)
          sets = workout.sets
          { id: workout.id, date: workout.date.strftime('%Y-%m-%d'), name: workout.name,
            label: workout.label, sets: sets.count, completed: sets.count(&:is_completed),
            finished: workout.finished? }
            .merge(provenance(workout))
        end

        # planned_weight and planned_reps ride along with what was lifted, because the
        # difference between them is the signal: a set written by a program and lifted
        # exactly as written reads the same as one lifted heavier unless both are here.
        # The weights go out as plain numbers rather than as the BigDecimal the numeric
        # column hands back, which would serialise as "0.1375e3" and reach an assistant as a
        # string it has to parse. Plates.numeric gives 225 back as an Integer and 137.5 as a
        # Float, which is what JSON wants of each.
        def view_set(set)
          { id: set.id, exercise: set.exercise.name, weight: weight(set.weight), reps: set.reps,
            rpe: set.rpe, is_warmup: set.is_warmup, is_completed: set.is_completed,
            planned_weight: weight(set.planned_weight), planned_reps: set.planned_reps }
            .merge(provenance(set))
        end

        def weight(value)
          value && Plates.numeric(value)
        end

        # A workout with its sets in the order they are meant to be lifted, and where it
        # stands. `status` and the program day behind it are what separate a session that
        # was written from one that was trained, which is the question every "how did last
        # week go" starts from.
        #
        # No session rating: #209 removed it. A rating per set survives and is on view_set,
        # which is the finer-grained answer to the same question and the one the session
        # screen actually collects.
        def view_workout_detail(workout)
          view_workout(workout).merge(
            status: workout.status.to_s, program_day_id: workout.program_day_id,
            sets: workout.sets_dataset.order(:id).all.map { |set| view_set(set) }
          )
        end

        # Who and when, both nil for a human-made row so a client can tell the two apart.
        def provenance(record)
          { created_by: record.created_by_oauth_application&.name, created_at: record.created_at&.iso8601 }
        end
      end

      # The read side of ChatGPT's connector contract: a `search` that returns
      # id/title/url rows and a `fetch` that returns one object by the id search handed
      # out. Ids are "type:id" handles so a single fetch resolves either kind, always
      # through the account-scoped datasets (so a search never leaks another account).
      module Locator
        module_function

        HANDLE = /\A(?<type>exercise|workout|program):(?<id>\d+)\z/

        # Up to 20 matches each across the account's exercises (by name), workouts (by
        # date) and programs (by name), as the id/title/url rows the connector expects.
        def search(context, query)
          like = "%#{query.to_s.strip}%"
          found_exercises(context, like).map { |e| exercise_result(e) } +
            found_workouts(context, like).map { |w| workout_result(w) } +
            found_programs(context, like).map { |p| program_result(p) }
        end

        def found_exercises(context, like)
          context.exercises.where(Sequel.ilike(:name, like)).limit(20).all
        end

        def found_workouts(context, like)
          context.workouts.where(Sequel.ilike(Sequel.cast(:date, :text), like)).limit(20).all
        end

        def found_programs(context, like)
          context.programs.where(Sequel.ilike(:name, like)).limit(20).all
        end

        # The full document for a "type:id" handle, or nil when the handle is unknown or
        # the row is not the account's.
        def fetch(context, handle)
          match = HANDLE.match(handle)
          return unless match

          document(context, match[:type], match[:id])
        end

        def document(context, type, id)
          case type
          when 'exercise' then exercise_document(context, context.exercises.where(id:).first)
          when 'program' then program_document(context.programs.where(id:).first)
          else workout_document(context.workouts.where(id:).first)
          end
        end

        def exercise_result(exercise)
          { id: "exercise:#{exercise.id}", title: exercise.name, url: url('exercises', exercise.id) }
        end

        def workout_result(workout)
          { id: "workout:#{workout.id}", title: "Workout on #{workout.date.strftime('%Y-%m-%d')}",
            url: url('workouts', workout.id) }
        end

        # A program has no page of its own to link to yet, so the handle points at the
        # workouts the block writes, which is where a person would go to look at it.
        def program_result(program)
          { id: "program:#{program.id}", title: program.name, url: "#{Config.public_base_url}/workouts/" }
        end

        # The estimated max rides along with the movement rather than being a tool of its
        # own: it is derived from the account's completed sets, so a model reading about a
        # lift gets the number that percentage-based programming needs without a second
        # round trip. It is nil until something has been lifted that the chart can read.
        def exercise_document(context, exercise)
          return unless exercise

          estimated = exercise.estimated_max(account_id: context.account_id)
          exercise_result(exercise).merge(text: "Exercise: #{exercise.name}.",
                                          metadata: { library: exercise.library?, estimated_1rm: estimated })
        end

        # The prose line stays, because that is what a connector renders, but everything
        # the prose flattens away -- warmup against working set, planned against lifted,
        # completion, the session rating -- rides in the metadata, which is the only
        # place a model can read them back as data rather than parse them out of English.
        def workout_document(workout)
          return unless workout

          detail = Presenter.view_workout_detail(workout)
          lines = workout.sets.map { |s| "#{s.exercise.name} #{s.weight}x#{s.reps}" }.join(', ')
          workout_result(workout).merge(text: "Workout on #{workout.date.strftime('%Y-%m-%d')}: #{lines}.",
                                        metadata: detail)
        end

        def program_document(program)
          return unless program

          detail = ProgramView.full_program(program)
          program_result(program).merge(
            text: "#{program.name}: #{program.weeks} week(s) from #{program.start_date}.", metadata: detail
          )
        end

        def url(kind, id)
          "#{Config.public_base_url}/#{kind}/#{id}/"
        end
      end
    end
  end
end

