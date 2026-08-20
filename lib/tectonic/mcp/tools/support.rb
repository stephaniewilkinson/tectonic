# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative '../../exercises'
require_relative '../../workouts'
require_relative '../../sets'

class Tectonic < Roda
  module MCP
    module Tools
      # Find-or-create by natural key, shared by every write tool so the three never
      # diverge in how they resolve an exercise or workout or stamp provenance. Each
      # method works only through the request's account-scoped datasets, so a resolved
      # row is always the caller's own (or the shared library) and never another
      # account's -- a cross-account write is unexpressible here, not merely avoided.
      module Resolver
        module_function

        # An exercise the account already has (its own or a library one) by name, or a
        # new private one stamped with the calling token.
        def exercise(context, name:, icon_url: nil)
          clean = name.to_s.strip
          raise Tool::Refusal, 'An exercise needs a non-empty name.' if clean.empty?

          context.exercises.where(name: clean).order(:id).first ||
            Exercise.create(name: clean, icon_url:, account_id: context.account_id,
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

        def view_workout(workout)
          { id: workout.id, date: workout.date.strftime('%Y-%m-%d'), sets: workout.sets.count }
            .merge(provenance(workout))
        end

        def view_set(set)
          { id: set.id, exercise: set.exercise.name, weight: set.weight, reps: set.reps,
            rpe: set.rpe, is_warmup: set.is_warmup, is_completed: set.is_completed }.merge(provenance(set))
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

        HANDLE = /\A(?<type>exercise|workout):(?<id>\d+)\z/

        # Up to 20 matches each across the account's exercises (by name) and workouts
        # (by date), as the id/title/url rows the connector expects.
        def search(context, query)
          like = "%#{query.to_s.strip}%"
          found_exercises(context, like).map { |e| exercise_result(e) } +
            found_workouts(context, like).map { |w| workout_result(w) }
        end

        def found_exercises(context, like)
          context.exercises.where(Sequel.ilike(:name, like)).limit(20).all
        end

        def found_workouts(context, like)
          context.workouts.where(Sequel.ilike(Sequel.cast(:date, :text), like)).limit(20).all
        end

        # The full document for a "type:id" handle, or nil when the handle is unknown or
        # the row is not the account's.
        def fetch(context, handle)
          match = HANDLE.match(handle)
          return unless match

          if match[:type] == 'exercise'
            exercise_document(context, context.exercises.where(id: match[:id]).first)
          else
            workout_document(context.workouts.where(id: match[:id]).first)
          end
        end

        def exercise_result(exercise)
          { id: "exercise:#{exercise.id}", title: exercise.name, url: url('exercises', exercise.id) }
        end

        def workout_result(workout)
          { id: "workout:#{workout.id}", title: "Workout on #{workout.date.strftime('%Y-%m-%d')}",
            url: url('workouts', workout.id) }
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

        def workout_document(workout)
          return unless workout

          lines = workout.sets.map { |s| "#{s.exercise.name} #{s.weight}x#{s.reps}" }.join(', ')
          workout_result(workout).merge(text: "Workout on #{workout.date.strftime('%Y-%m-%d')}: #{lines}.",
                                        metadata: { sets: workout.sets.count })
        end

        def url(kind, id)
          "#{Config.public_base_url}/#{kind}/#{id}/"
        end
      end
    end
  end
end

