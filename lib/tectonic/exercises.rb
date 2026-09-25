# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'exercise_names'
require_relative 'measured'
require_relative 'oauth_application'
require_relative 'one_rep_max'
require_relative 'sets'
require_relative 'workouts'

class Tectonic < Roda
  class Exercise < Sequel::Model
    # The usual way this movement is counted, as a symbol.
    def default_measure
      Measured.cast(super)
    end

    one_to_many :sets, class: 'Tectonic::WorkoutSet'
    # The OAuth client (LLM) that created this row, or nil for a human-made one.
    # Provenance is displayed only when this resolves, so the web UI's rows stay
    # unadorned.
    many_to_one :created_by_oauth_application, class: 'Tectonic::OAuthApplication',
                                               key: :created_by_oauth_application_id

    # Rows an account may select or view: its own plus the shared library, whose
    # account_id is nil. account_id IN (nil, id) can't stand in for this -- SQL's
    # IN never matches NULL, so it would silently drop the entire library.
    def self.visible_to(account_id)
      where(account_id:).or(account_id: nil)
    end

    # Rows an account may write to: its own, and never a library row. Reads go through
    # visible_to, which folds the shared library in, and a write cannot -- a library row
    # is on every account's page, so a value written to one is a value one account wrote
    # and every other account reads. The IS NOT NULL is not redundant beside the
    # equality: a nil account_id arriving here, from a token that resolved no account,
    # would otherwise mean where(account_id: nil), which is the entire library, handed
    # back as writable. That is precisely the thing this method exists to refuse.
    def self.owned_by(account_id)
      where(account_id:).exclude(account_id: nil)
    end

    # A dataset method rather than a class method beside the two scopes above, because every
    # caller wants it *after* `visible_to`, and a class method cannot be chained onto the
    # dataset another class method returned. `Exercise.library_first_by_name` still works:
    # dataset_module defines the class method too.
    dataset_module do
      # The order a person reads a list of movements in: the library first, then the account's
      # own, each of them alphabetical. #551.
      #
      # What this replaces is `id`, which is insertion order wearing a number -- a fact about
      # the app rather than about the lifter. It mattered less while this list was a <select>
      # somebody scrolled past; since #549 the same list is what a typeahead filters, so the
      # order it is in is what a lifter reads at first glance and the whole of what a lifter
      # who types nothing ever sees. The job of a default order is to be predictable -- you
      # know roughly where `Bench Press` will be before you look -- and "whatever order the
      # rows were created in" is the one property an order can have that nobody can predict.
      #
      # **Most-recently-used would be a better guess and is deliberately not what this is.**
      # The data is here: `sets.completed_at` says what this account actually trains, and
      # mid-session the four lifts of the current block are what a thumb is reaching for. But a
      # recency order moves under the lifter between sessions, so where a movement sits can
      # never be learned, and mid-session it promotes the lift that was just finished over the
      # one coming next -- it is a guess about intent dressed as a fact about the list. This
      # app reports what an account has and leaves the judgements to a reader. Nothing here
      # forecloses it: recency is a layer over a baseline, and alphabetical is the baseline it
      # would have to argue against.
      #
      # Alphabetising the library too is the arguable half, so: `LIBRARY` is curated, grouped
      # by movement pattern in the source with the squats together and the presses together,
      # and that ordering is thrown away here. It is thrown away because nothing renders it --
      # the picker draws one flat group of fifty-four rows under the heading "Library", so
      # `Anderson Squat` sitting between `Tempo Squat` and `Safety Bar Squat` reads as noise to
      # everyone who has not read the constant -- and because it has already half decayed,
      # later additions having been appended to the end where an accessory lift now follows
      # `Z Press`. An order only the source can see is not an order the screen has.
      #
      # The library/own split is part of the sort rather than something the view does
      # afterwards, which is what keeps "the first movement" meaning one thing.
      # _exercise_options renders the library above the account's own and the picker reads its
      # groups off that markup, so an untouched new-set form posts the first library movement;
      # sorting the same way here means the dataset and the template cannot hold two different
      # ideas of which row that is. Postgres sorts false before true, so `account_id IS NOT
      # NULL` puts the library on top.
      #
      # Folded to lower case because a database built with the C collation sorts every capital
      # ahead of every lower-case letter, and the names in this table are typed by hand: a
      # lifter whose own `cable fly` is filed below `Zercher Squat` has been handed back the
      # same unreadable list this exists to fix.
      #
      # **And the collation is named rather than inherited, which CI had to teach me.** What
      # "alphabetical" means to Postgres is a property of the cluster the database was created
      # on: this laptop's is C, so it sorts by byte and puts `Z Press` above `Zercher Squat`,
      # while the Actions runner's is en_US.UTF-8, which weighs the space below the letters and
      # puts them the other way up. Same code, same rows, two different lists -- which is
      # precisely the unpredictable order this whole change is against, one level down. `COLLATE
      # "C"` over a folded name is the one rule every Postgres agrees on, so the list a lifter
      # reads is the list the specs assert and neither depends on how somebody ran initdb. The
      # price is that a name with an accent in it sorts after the plain ASCII ones; the movement
      # list is English barbell names, and a locale that reshuffles under a database restore is
      # the worse of the two.
      #
      # The id breaks a tie between two rows folding to one name, so the list cannot reshuffle
      # itself between two page views.
      def library_first_by_name
        order(Sequel.~(Sequel[:exercises][:account_id] => nil),
              Sequel.lit('lower(exercises.name) COLLATE "C"'),
              Sequel[:exercises][:id])
      end
    end

    # A nil account_id marks a shared library exercise, visible to everyone; any
    # other value is a single account's own.
    def library?
      account_id.nil?
    end

    # The one movement this account means by a name, or nothing. #474.
    #
    # Replaces an exact string match, which is how `Benchpress` came to sit beside
    # `Bench Press` with training on both: the two are the same movement written differently,
    # and an exact match cannot see it.
    #
    # **The account's own row wins over the library's**, and saying so is the point. Both are
    # visible, so a name can match two rows -- this account has a private `Deadlift` carrying
    # 64 sets, a training max and seven program lifts, and a library `Deadlift` with nothing on
    # it. The old ordering was by id, which picked the private row because it happened to be
    # older, and would have started filing training onto the empty one the moment that stopped
    # being true. The rule is now the reason rather than the accident: a lifter's own row is
    # where their training is.
    #
    # Folding in Ruby rather than in SQL keeps this agreeing with `near?` and with the browser
    # form, at the cost of reading the account's movements -- a few dozen rows, already loaded
    # on most of the pages that ask.
    def self.matching(account_id, name)
      wanted = ExerciseNames.fold(name)
      return nil if wanted.empty?

      visible_to(account_id).all
                            .select { |row| ExerciseNames.fold(row.name) == wanted }
                            .min_by { |row| [row.library? ? 1 : 0, row.id] }
    end

    # Movements already here that a new name might have meant. #478.
    #
    # Nothing is decided from this -- it is the list somebody is asked about. Anything folding
    # to the same name is left out, because that is `matching`'s answer and a settled one: a
    # caller offered `Bench Press` when they typed `Benchpress` has not been asked a question,
    # they have been told the movement already exists.
    def self.similar_to(account_id, name)
      wanted = ExerciseNames.fold(name)
      visible_to(account_id).order(:name).all
                            .reject { |row| ExerciseNames.fold(row.name) == wanted }
                            .select { |row| ExerciseNames.near?(name, row.name) }
    end

    # Sets already logged, brought into line when the movement's own answer changes. #392.
    #
    # A set carries its own is_per_side, copied from the movement when it was written, and
    # that copy is right: a set records how it was done, the way planned_weight records what
    # was asked for. Changing a movement must not reach back and rewrite training.
    #
    # Except that this particular flag is not a choice somebody made per set. It is a fact
    # about the movement -- a split squat is done one leg at a time and always was -- and the
    # only reason a logged set says otherwise is that the app did not know yet. Marking the
    # clamshell per side and finding yesterday's session still counting both legs as one is
    # #392, and the volume on that session is out by half until this runs.
    #
    # **Only the sets still carrying the old answer move.** A set an assistant set explicitly
    # against the default was a decision about that set, and this is not entitled to overrule
    # it. So the update is scoped to rows whose flag equals what the movement used to say,
    # which is exactly the set of rows that were following the movement rather than differing
    # from it.
    #
    # Scoped through the account's own workouts as well as by exercise. It cannot matter today
    # -- only a private movement is editable, so every set of it is the owner's -- but the
    # scope is what keeps that true if a library movement ever becomes editable, and an
    # unscoped UPDATE on a shared row would rewrite every account's training at once.
    def self.align_sets_per_side(exercise, account_id, was:)
      WorkoutSet.where(exercise_id: exercise.id, is_per_side: was)
                .where(workout_id: Workout.where(account_id:).select(:id))
                .update(is_per_side: !was)
    end

    # A note as it should be stored: nil when there is nothing in it. The textarea is
    # posted whether or not anyone typed in it, so "left blank" arrives as an empty
    # string, and the two spellings read differently afterwards -- '' is truthy, so a
    # blank note would draw its own empty paragraph above the chart forever. Stripping
    # first means a note of nothing but whitespace does not count as one either.
    def self.clean_note(raw)
      text = raw.to_s.strip
      text.empty? ? nil : text
    end

    # How many dumbbells, off a form. #439.
    #
    # Blank stays null, because "not said" is a real answer and the column exists to keep it
    # distinguishable from a deliberate two -- that difference is what makes it possible to
    # ask which movements still want one. Anything that is not 1 or 2 becomes null as well:
    # the check constraint would otherwise refuse the write and surface as a 500 on a Save
    # button, and there is no third answer a lifter could have meant.
    def self.clean_dumbbell_count(raw)
      count = raw.to_s.strip.to_i
      [1, 2].include?(count) ? count : nil
    end

    # `clean_rest_seconds` was here and is now `Rest.clean` (039). A rest stopped being a
    # column on this row when it turned out a library movement -- which is every barbell lift
    # the reporting account trains -- could not carry one, so the cleaner moved to where the
    # value lives. Left as a note rather than deleted silently, because a stray caller finding
    # nothing here should find out where it went.

    # The best estimated max an account's completed sets of this movement support as of a
    # date, or nil while nothing has been lifted that the chart can read. Answering as of
    # a date rather than only for today is the point: asked at the end of each week, it is
    # the curve a training block is actually judged by.
    def estimated_max(account_id:, on: Date.today)
      OneRepMax.best_of(lifted_sets(account_id, on))
    end

    # The same estimate with the day the set behind it was lifted, for the callers that
    # report it rather than only calculate with it. #293.
    #
    # A separate method rather than a wider return from estimated_max, because three callers
    # want the number alone and changing what they get would be churn for nothing. Both read
    # the same rows through the same scope, so the two cannot disagree.
    def estimated_reading(account_id:, on: Date.today, lifted: nil)
      OneRepMax.best_reading(through(lifted, on) || lifted_sets(account_id, on))
    end

    # The same, restricted to readings the chart is sure enough of to let stand on their own.
    #
    # This is what a training max derives from, and the pair is the point: `estimated_reading`
    # above is the best estimate there is and gets drawn, this is the best one allowed to
    # become a number the app then prescribes against. A movement trained in eights has the
    # first and not the second.
    def confident_reading(account_id:, on: Date.today, lifted: nil)
      OneRepMax.best_confident_reading(through(lifted, on) || lifted_sets(account_id, on))
    end

    # `lifted` is `lifted_sets` already read up to some later date, for a caller asking several
    # questions of one history -- the exercise page asks five, and until #596 each went and
    # read the whole of it again. The rows on or before `on` are the rows `lifted_sets` would
    # have returned for it: `workouts.date` is a timestamp without a zone, so `to_date` here
    # and `date < on + 1` there draw the same line. Nil where there is nothing in hand.
    def through(lifted, on)
      lifted&.select { |row| row[:date].to_date <= on }
    end

    # What recent training implies, as against what has ever been demonstrated. #307, and
    # the windowed companion #293 named and deliberately left unbuilt.
    #
    # `estimated_reading` above answers "the most that has been demonstrated", which is the
    # right meaning for a max and is also the one that goes quietly stale: there is no lower
    # bound on it, so a number earned on a single three years ago outranks everything since
    # and nothing about the number says so. #293 answered half of that by carrying the date.
    # This answers the other half, by saying what the last twelve, twenty-six and fifty-two
    # weeks each support on their own.
    #
    # **It does not replace the lifetime best and must not.** Nothing here decays, expires or
    # discounts anything -- a window is a second reading beside the first, and the gap between
    # them is information rather than a correction. A lifetime best of 315 from 2023 next to a
    # twelve-week best of 290 is a lifter who has not been near their best recently; the same
    # 315 next to a twelve-week 315 is a lifter who is there now. Collapsing the two would
    # throw away exactly the distinction the reader is reaching for. Which of them to open a
    # block at is a judgement, and this app does not make judgements -- it reports both and
    # leaves the arguing to somebody who can be argued with.
    #
    # **One query, not one per window.** The widest window is read once and the narrower ones
    # are taken from those rows in memory. Three queries for three answers about the same
    # movement would be three round trips on a read that already makes several, and they
    # could disagree at a date boundary if a set landed between them.
    #
    # `sets` rides along with each reading because a number off one set and a number off forty
    # are not the same claim, and the caller cannot tell them apart from the pounds alone.
    #
    # `lifted` is the whole history already in hand, as `through` takes it; the widest window
    # is cut from it rather than read again.
    def recent_readings(account_id:, windows:, on: Date.today, lifted: nil)
      since = on - (windows.max * 7)
      rows = through(lifted, on)&.select { |row| row[:date].to_date >= since } ||
             lifted_sets(account_id, on, since:)
      windows.map { |weeks| window_reading(rows, weeks, on) }
    end

    # The best reading in a window that is allowed to set a number by itself. #449.
    #
    # `recent_readings` above reads through `best_reading`, which is right for reporting what
    # a window supports: a reader wants the most recent training implies, and a set nine reps
    # from a single implies something even if it implies it loosely.
    #
    # This is the other question, and it is the one a proposal has to ask. A number that would
    # become the denominator of every percentage in the next block has to clear the bar
    # `TrainingMax.derived` already holds -- `CONFIDENT_REPS`, six restated reps -- or the
    # block is priced off a reading the app itself declines to trust. Those are different
    # thresholds for different jobs and collapsing them would quietly lower one of them.
    #
    # The window is the whole point of proposing from it rather than from the lifetime best:
    # a max is the most ever demonstrated, and what a block should open at is what training
    # has been supporting lately. #307 makes that argument at length and refuses to choose
    # between them; this does not choose either, it just answers the recent half.
    # Both answers come back from one read of the window, and they have to: a count taken from
    # a second query with its own idea of "the last eight weeks" could say a movement was
    # trained nine times and that nothing in it was readable, having looked at two different
    # nine. The window is defined once, here, by the rows.
    def window_of(account_id:, weeks:, on: Date.today)
      rows = lifted_sets(account_id, on, since: on - (weeks * 7))
      { sets: rows.count { |row| !row[:is_warmup] },
        reading: OneRepMax.best_confident_reading(rows) }
    end

    # One window's worth of those rows. Nil pounds rather than an absent entry where the
    # window holds nothing readable, so a caller gets the same three windows every time and
    # "nothing in the last twelve weeks" is itself an answer -- which on a movement somebody
    # has stopped training is the most useful thing this can say.
    def window_reading(rows, weeks, on)
      since = on - (weeks * 7)
      inside = rows.select { |row| row[:date].to_date >= since }
      { weeks:, sets: inside.length, pounds: nil, on: nil }
        .merge(OneRepMax.best_reading(inside) || {})
    end

    # An account's own completed sets of this movement, up to and including a date. Scoped
    # through the workouts rather than the sets alone, because a library movement is
    # shared and the work done on it is not: another account's lifting must never reach
    # this number.
    # planned_rpe joins the select with #294: it is what the chart reads a set at when the
    # lifter did not rate it, and it was sitting on the row unread since #265. The session's
    # date joins it with #293, which is what lets a reader say when a max was earned -- from
    # a join rather than a second query, so the number and its date cannot disagree.
    # `since` is the lower bound #307 needed and this never had: every caller before it
    # wanted everything up to a date, which is what a lifetime best means. Absent, it still
    # does, so the three existing callers are untouched.
    #
    # Ordered by day and then by id, which the progress chart needs and nothing else minds:
    # it groups these by day, `group_by` keeps first-seen order, and a SELECT with no ORDER BY
    # comes back in whatever order the table's physical layout suggests. That is what the
    # chart's own copy of this query found out in #593, before #596 folded it into this one.
    #
    # **Dated by when each set was lifted, not by when its session was planned.** #479 and #572
    # moved every other screen onto the day a session was trained; this read went on answering
    # with `workouts.date`, the day it was written for, so the progress chart on a movement's
    # page drew a Wednesday's squats on the Friday the block had pencilled them in for, and the
    # "as of" bound a max is read against cut on the planned day too. A spec about exactly that
    # passed for months only because its session was planned for a day still in the future,
    # which kept it off the chart altogether -- and failed the one day the future arrived.
    #
    # The set's own `completed_at`, which is when the Done was tapped, and the session's date
    # where a set has none: one logged by hand, or completed before #281 stamped anything.
    def lifted_sets(account_id, on, since: nil)
      rows = WorkoutSet.where(exercise_id: id, workout_id: Workout.where(account_id:).select(:id),
                              is_completed: true)
                       .join(:workouts, id: :workout_id).where(Sequel.expr(LIFTED_ON) < (on + 1))
      rows = rows.where(Sequel.expr(LIFTED_ON) >= since) if since
      rows.select(*READ_COLUMNS).order(*IN_ORDER).all
    end

    LIFTED_ON = Sequel.function(:coalesce, Sequel[:sets][:completed_at], Sequel[:workouts][:date])
    IN_ORDER = [LIFTED_ON, Sequel[:sets][:id]].freeze

    # Qualified because `date` is on workouts while the rest are on sets, and unqualified it
    # is ambiguous the moment the two tables meet.
    #
    # `is_warmup` joined the list for #449, which needs to count the working sets a window
    # holds -- "trained nine times and nothing readable in it" is a useful answer and "trained
    # nine times" counting ramp rungs is a misleading one.
    #
    # Selecting it changes nothing about what these rows mean. `lifted_sets` filters on
    # `is_completed` and has never filtered on this, so every caller gets the same rows it
    # always got with one more column on them; the readers take what they need by key. It is
    # also what let the progress chart read through here rather than keep a second copy of
    # this query that differed only by `is_warmup` (#596) -- the heaviest-set line and the
    # estimate both have to leave warmups out.
    #
    # `date` is LIFTED_ON under the name every reader already uses, so a reading's `on`, a
    # window's edge and a chart's x axis all mean the day the set was lifted.
    READ_COLUMNS = [
      Sequel[:sets][:weight], Sequel[:sets][:reps], Sequel[:sets][:rpe],
      Sequel[:sets][:planned_rpe], Sequel[:sets][:is_warmup], Sequel.as(LIFTED_ON, :date)
    ].freeze
  end
end

