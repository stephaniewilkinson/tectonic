# frozen_string_literal: true

require 'date'
require 'digest'
require_relative 'db'
require_relative 'oauth_application'
require_relative 'program_days'

class Tectonic < Roda
  class Workout < Sequel::Model
    # Ordered, because a one_to_many with no order emits SQL with no ORDER BY, and a
    # SELECT without one may come back in any order Postgres likes. It is free to change
    # that order after an UPDATE -- which on this table is every "Lifted something else"
    # save and every Done tap -- so the set list was stable right up until somebody
    # trained, and then quietly was not. That is #217: sets that will not stay put.
    #
    # id rather than anything cleverer. Insertion order is program order here: the
    # generator writes a lift's warmups and then its working sets, lift by lift, in the
    # order the program gives them, and a set added by hand later belongs at the end
    # because that is when it happened. It also matches what the session screen and the
    # MCP get_workout tool already sort by, so all three now agree.
    one_to_many :sets, class: 'Tectonic::WorkoutSet', order: :id
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

      # How many sets are on each row, answered the same way and for the same reason. The
      # workouts list printed workout.sets.count per row, which is a query per session on
      # the page -- fourteen for a page of twelve, and a year of training is a year of
      # queries. #234.
      #
      # A correlated subquery rather than a join with a group by: a join would multiply the
      # workout rows before collapsing them again, and this page also wants the EXISTS
      # above, which does not group. Both are index-backed since #233, so each is a lookup
      # rather than a scan.
      def with_set_count
        counted = db[:sets].where(workout_id: Sequel[:workouts][:id])
        select_append(counted.select { count.function.* }.as(:set_count))
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

    # How many sets are on this workout. Taken from the row when the list already asked
    # (with_set_count), and otherwise one count of its own -- the same shape as performed?
    # above, so a caller that has not opted into the wider select still gets an answer
    # rather than an error.
    def set_count
      values.fetch(:set_count) { sets_dataset.count }
    end

    # Whether the lifter said they were done, which is not a thing any amount of looking
    # at the sets can answer: three of ten completed is "I stopped early" and "I am between
    # sets" written identically. #218.
    #
    # Deliberately not a fourth value of `status`. That enum answers where a session stands
    # in the plan -- written, missed, or trained -- and is what the calendar colours a cell
    # by. A finished session and one still under way are both trained, and a diary cell has
    # no reason to tell them apart, so folding this in would have made every reader of
    # `status` grow a case for a distinction most of them do not care about. Two questions,
    # two fields.
    def finished? = !finished_at.nil?

    # Everything the session screen draws from this workout's sets, as one short string.
    # #249: the screen has no way to notice that an assistant changed the session under it.
    #
    # A digest rather than a timestamp, because there is no timestamp to read. `sets` has
    # created_at and no updated_at, so a weight corrected over MCP moves nothing a poller
    # could compare -- and adding an updated_at means a column, a trigger or a touch on
    # every write path, all to answer a question a digest of eleven columns answers exactly.
    # Exactly, and not approximately: it changes when and only when something the screen
    # renders changes, so a poll that finds it unchanged can be answered with a 204 and the
    # page left alone entirely.
    #
    # The column list is the screen's, which is why it is written out rather than being
    # `select_all`. created_at and created_by_oauth_application_id are on these rows and
    # are not drawn on this screen, and including them would make a set rewritten to the
    # same values look like news.
    # completed_at joins the list with #281 because the session header draws off it -- how
    # long the session has been going, and how long since the last set. It moves only when
    # is_completed moves, so it adds nothing the digest was not already noticing; it is here
    # to keep the list's stated rule true rather than true by accident, which is the state a
    # column drawn on the screen and missing from here would leave it in.
    SESSION_COLUMNS = %i[id exercise_id weight reps rpe is_warmup is_completed
                         measure duration_seconds is_per_side
                         planned_weight planned_reps completed_at].freeze

    def session_fingerprint
      rows = WorkoutSet.where(workout_id: id).order(:id).select(*SESSION_COLUMNS).all
      Digest::MD5.hexdigest(rows.map { |row| SESSION_COLUMNS.map { |column| row[column] }.join(',') }.join(';'))
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

