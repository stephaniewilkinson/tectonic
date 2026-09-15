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

    # When the first set of a workout was ticked off, as a correlated subquery for the two
    # callers that need it in SQL: the calendar's fetch window and its select. Written once
    # because a subquery duplicated is a subquery that drifts.
    def self.first_completion
      DB[:sets].where(workout_id: Sequel[:workouts][:id], is_completed: true)
               .select { min(:completed_at) }
    end

    dataset_module do
      # Answers "has anything been lifted here" for every row of a list in the one
      # query that fetches it, as a correlated EXISTS rather than a join, so a page of
      # workouts stays one query and no row's set rows are loaded to find out.
      def with_performance
        lifted = db[:sets].where(workout_id: Sequel[:workouts][:id], is_completed: true)
        select_all(:workouts).select_append(lifted.exists.as(:is_performed))
      end

      # The day this session was actually trained, alongside whether it was. #479.
      #
      # `workouts.date` is when a session was *written for*. For a generated block that is a
      # plan made weeks ahead, and training does not keep to it: five sessions on the
      # reporting account were trained up to three days away from the date they carry, and
      # the calendar drew every one of them on the planned day. A session lifted on Monday
      # appeared on Thursday, and Monday looked like a rest day.
      #
      # The earliest completion rather than the latest, because a session spanning midnight
      # belongs to the day it started -- which is also the only reading `completed_at` can
      # give that a stored date cannot.
      # `select { min(...) }` rather than `.min(...)`, which is Sequel's aggregate *call* and
      # runs the query there and then -- producing a value where an expression was wanted, and
      # a correlated subquery that cannot see its outer table.
      def with_performed_on
        with_performance.select_append(Workout.first_completion.as(:performed_on))
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
      clean_text(raw)
    end

    # What the lifter said about how the session went, or nil where they said nothing. #310.
    # An RPE and a turnaround are both recorded now and neither says why; this is where "slept
    # badly" goes, which is the sentence that explains them three weeks later.
    def self.clean_note(raw)
      clean_text(raw)
    end

    # Blank as null, for both of the above. The comment on clean_name already said the two
    # spellings must not disagree and pointed at Exercise.clean_note for the same rule in a
    # third place -- so when the note arrived it went through the same helper rather than
    # becoming a fourth copy of four lines.
    def self.clean_text(raw)
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
    # planned_rpe joins the list with #265 because the session row draws it: a target the
    # block asks for is printed beside the prescribed load. The rule this list follows is
    # "what the screen renders", so a column the screen renders and the digest ignores is a
    # change an assistant could make -- retargeting a lift and regenerating the day -- that
    # the poll would answer 204 to, leaving the screen showing the old instruction.
    #
    # completed_at joins it with #281, because the session header draws off that: how long
    # the session has been going. It is the weaker of the two cases and worth saying so --
    # completed_at moves only when is_completed moves, which the digest already watches, so
    # it notices nothing new today. It is here to keep the list's stated rule true rather
    # than true by accident, which is what a column drawn on the screen and missing from
    # here would leave it.
    # planned_rest_seconds joins it with #281's second half. The session screen does not print
    # it, but the rest timer is armed from it, so an assistant that represcribes a lift's rest
    # and regenerates the day has changed what the screen will do -- and a poll answering 204
    # would leave the next Done tap offering the rest the block asked for yesterday.
    # is_commanded joins it with #311 for the plainest reason on the list: it is printed on
    # the row. A block represcribed under commands and regenerated changes what the session
    # screen says, and a poll answering 204 would leave the phrase on the page disagreeing
    # with the row behind it.
    # The setup columns join it with #412, on the plainest reason on the list again: they are
    # printed on the row. A block represcribed at a different bench angle and regenerated
    # changes what the session screen says, and a poll answering 204 would leave a lifter
    # setting the bench to a number the row behind the page no longer holds.
    SESSION_COLUMNS = %i[id exercise_id weight reps rpe is_warmup is_completed
                         measure duration_seconds is_per_side is_commanded
                         bench_angle_degrees rack_hole safety_hole
                         planned_weight planned_reps planned_rpe planned_rest_seconds
                         completed_at].freeze

    def session_fingerprint
      rows = WorkoutSet.where(workout_id: id).order(:id).select(*SESSION_COLUMNS).all
      Digest::MD5.hexdigest(rows.map { |row| SESSION_COLUMNS.map { |column| row[column] }.join(',') }.join(';'))
    end

    # Planned, performed or skipped, decided without inspecting the sets one at a time.
    # A session that has been lifted at all is performed; one still on or ahead of its date
    # is planned; one whose date has passed with nothing lifted was skipped.
    #
    # Today is not over, which is what the >= on the last line is for. The day is still
    # running, and a session with nothing lifted in it yet is one you are about to do
    # rather than a record of having done it. With > it fell through and the index filed
    # today's session under History, below every session still to come -- the row a lifter
    # opened the page to start.
    #
    # This used to end at a bare `:performed`, and #304 is what that cost. The rule it
    # encoded was:
    #
    # > A workout typed in by hand is never skipped: it exists because a person logged it,
    # > so once its day is over it reads as history whether or not anything in it was
    # > ticked off.
    #
    # That holds for a session somebody typed up *after* training, where the rows are the
    # record and the completion flags were never going to be ticked. It stopped holding
    # once `create_workout` and `create_set` became the way an assistant writes a session
    # **in advance**: those carry no program_day_id, so a plan written on Monday for
    # Thursday read as `performed` on Friday with nothing done in it. Workout 27 reported
    # `performed` over 0 of 26 sets while workout 24, differing only in having been
    # generated, correctly reported `skipped` over 0 of 4.
    #
    # So `performed` now means what it says rather than standing in for "neither planned
    # nor skipped". `performed?` is the first line, so anything reaching the bottom
    # demonstrably has nothing lifted in it, and that is the one reading certainly wrong.
    #
    # What it changes: a hand-logged past session with nothing ticked now reads `skipped`
    # and the calendar colours it accordingly. That is the intended correction rather than
    # a side effect -- a session nobody recorded any work in is not a session that
    # happened. The way to say otherwise is to tick something, which is also what makes it
    # true.
    # program_day_id no longer appears here, which is the tell that the rule got simpler
    # rather than gaining a case: whether a program wrote a session was only ever a proxy
    # for whether it was a plan, and the date answers that directly.
    # The day a calendar should draw this session on. #479.
    #
    # What happened, where it happened: a trained session belongs on the day it was trained,
    # and a plan belongs on the day it is written for. Those are the same date most of the
    # time and the calendar is only interesting when they are not.
    #
    # Falls back to the stored date whenever there is no stamp to read -- a session performed
    # before #281 gave sets a `completed_at`, or one whose completions predate it. Those rows
    # are not wrong, they simply cannot say, and the planned date is the best available answer
    # rather than a guess.
    def on_calendar
      performed_on&.to_date || date.to_date
    end

    # When the first set of this was ticked off, or nil. Taken from the row where the query
    # asked (with_performed_on) and otherwise fetched, the same shape as `performed?` above so
    # a caller that has not opted into the wider select gets an answer rather than an error.
    def performed_on
      values.fetch(:performed_on) { sets_dataset.where(is_completed: true).min(:completed_at) }
    end

    def status(today = Date.today)
      return :performed if performed?
      return :planned if date.to_date >= today

      :skipped
    end
  end
end

