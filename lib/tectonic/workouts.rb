# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'oauth_application'
require_relative 'program_days'

class Tectonic < Roda
  class Workout < Sequel::Model
    one_to_many :sets, class: 'Tectonic::WorkoutSet'
    # The program day this workout was generated from, nil for one logged by hand or
    # over MCP. That null is the whole distinction between a plan and a record of
    # training, so every reading of "is this a planned session" starts here.
    many_to_one :program_day
    # The OAuth client (LLM) that created this row, or nil for a human-made one.
    many_to_one :created_by_oauth_application, class: 'Tectonic::OAuthApplication',
                                               key: :created_by_oauth_application_id

    dataset_module do
      # Answers "has anything been lifted here" for every row of a list in the one
      # query that fetches it, as a correlated EXISTS rather than a join, so a page of
      # workouts stays one query and no row's set rows are loaded to find out.
      def with_performance
        lifted = db[:sets].where(workout_id: Sequel[:workouts][:id], is_completed: true)
        select_all(:workouts).select_append(lifted.exists.as(:is_performed))
      end
    end

    # What a name is once a form has been through it. A text input posts an empty string
    # whether or not anybody typed in it, and '' is truthy in Ruby, so a blank name stored
    # as itself would draw its own empty element beside every date forever. Null is the
    # one a reader can test for, so it is the one that is stored. Stripping first means a
    # name of nothing but whitespace does not count as one either.
    #
    # The same shape as Exercise.clean_note, and deliberately so: two columns that both
    # mean "the lifter may say something here, or not" should not disagree about what
    # saying nothing looks like.
    def self.clean_name(raw)
      text = raw.to_s.strip
      text.empty? ? nil : text
    end

    # What to call this session in a list or a calendar cell. The name when there is one,
    # and otherwise the focus of the program day that wrote it -- which is free, already
    # written by the program editor, and already shown on /programs/:id, so the feature
    # arrives populated for anybody running a block rather than empty for everybody.
    #
    # Read through rather than copied onto the row at generation, so that renaming a
    # program day renames the sessions it has already written. A session that wants to
    # disagree with its day says so by carrying a name of its own, which wins here.
    def label
      name || program_day&.focus
    end

    # Whether any set has been lifted, which is what separates a session that happened
    # from one that was only written. Taken from the row when the list already asked
    # (with_performance), and otherwise one EXISTS of its own.
    def performed?
      values.fetch(:is_performed) { sets_dataset.where(is_completed: true).limit(1).any? }
    end

    # Planned, performed or skipped, decided without inspecting the sets one at a time.
    # A session that has been lifted at all is performed; a generated one still on or
    # ahead of its date is planned, and one whose date has passed with nothing lifted
    # was skipped. A workout typed in by hand is never skipped: it exists because a
    # person logged it, so once its day is over it reads as history whether or not
    # anything in it was ticked off.
    #
    # Today is not over, which is what the >= on the last line is for. The day is still
    # running, and a session with nothing lifted in it yet is one you are about to do
    # rather than a record of having done it. With > it fell through to performed and
    # the index filed today's session under History, below every session still to come
    # -- the row a lifter opened the page to start. A generated session dated today was
    # never affected either way: program_day_id makes it a plan before any date is
    # compared.
    def status(today = Date.today)
      return :performed if performed?
      return :skipped if program_day_id && date.to_date < today
      return :planned if program_day_id || date.to_date >= today

      :performed
    end
  end
end

