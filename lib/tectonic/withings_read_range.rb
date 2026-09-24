# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'withings_connection'

class Tectonic < Roda
  # Which years of a lifter's Withings history have been read, and what that leaves. #605.
  #
  # One record with two writers: the walk from the terminal and a press of the import button
  # both write the same two ends of the same range, through `record_read`, and both read
  # it back from here. Kept in one module of its own for that reason rather than despite it --
  # #554 and #566 were both a year claimed by one route that the other had not read, and the
  # rules that stop it are the ones below, in one place, whoever is asking.
  module WithingsReadRange
    module_function

    # What a press would do next, which the page has to be able to say *before* it is pressed.
    #
    # The same method answers both questions on purpose. A button offering to import 2023 and
    # a press that imports 2022 is the kind of disagreement that only shows up in front of a
    # lifter, and the way two answers to one question stay in agreement is for there to be
    # one answer.
    #
    # `years_left` counts every year still unread, on both sides of what has been read, so a
    # lifter can tell "press again" from "press four more times" -- and so the page can stop
    # asking at all once there is nothing behind the button. The rest of what `remaining`
    # returns is there because the page's offer has to be able to name a gap: see #566, and
    # the Wearables section of views/settings.erb, where those numbers become sentences.
    #
    # The range is read once here and handed down to both of them, rather than each fetching
    # the row again. Two readings of one row inside one answer is a way for the button and the
    # sentence beside it to disagree about a press made in between, and this method's whole
    # argument is that they cannot.
    def pending(account_id)
      floor = WithingsBackfill.first_session_year(account_id)
      return { state: :no_sessions } unless floor

      read = imported_range(account_id)
      year = next_year(read, floor)
      return { state: :nothing_left, earliest: floor } unless year

      { state: :ready, year:, earliest: floor, **remaining(read, floor) }
    end

    # The year the next press reads, or nil where every year from the earliest stamped set to
    # this one has been read.
    #
    # ## What this used to be, and why one number could not do it
    #
    # It used to be `imported_year&.pred || Date.today.year`: the year before the cursor, and
    # this year for an account that had never pressed. That reads the cursor as the answer to
    # two questions -- how far back the reading got, and whether everything above it is read --
    # and it is only ever the answer to the first. #566: a course of presses in 2023 that
    # reached 2019 leaves a cursor of 2019, and in 2026 this returned nil, because 2018 is
    # below the floor. 2024 and 2025 were never read and nothing would ever have read them.
    #
    # So the recorded claim is a *range* now, and the two ends of it are two columns, which is
    # argued at length in 049 and in `WithingsBackfill.settle`. Given a range, the years still to read are the
    # two gaps either side of it: the years since it, and the years below it down to the floor.
    #
    # ## Upward through the newer gap first, and why that is not the walk's order reversed
    #
    # The years above the range are newer than the years below it, so they go first -- which is
    # the same preference `WithingsBackfill.walk` states for reading a history newest year first, applied to the
    # two gaps rather than within one. Inside that gap the order has to be upward, because a
    # press of this year would leave two disjoint stretches of read history and a range is the
    # one thing two numbers can hold. That is a real cost and a small one: it is an ordering
    # over a gap that is usually a year or two, where `WithingsBackfill.walk`'s argument is about a decade cut
    # short by a throttle. It also loses least, since the very newest year is the one the
    # forward flow has been matching on its own all along.
    #
    # The floor is the year of the earliest stamped set, the same bound the task walks to and
    # one out of Tectonic's own data: a year before the first logged session holds nothing that
    # could ever be proposed to anything.
    #
    # The two ways of being wrong here are still not symmetrical, and that is what decides
    # every close call in this module: a claim behind the truth costs one request to a year
    # already stored, and `WithingsActivity.store` makes re-storing an activity a no-op, while
    # a claim ahead of the truth loses that year in silence.
    def next_year(read, floor)
      return Date.today.year unless read
      return read.last + 1 if read.last < Date.today.year

      candidate = read.first - 1
      candidate < floor ? nil : candidate
    end

    # The years this account's history has been read over, or nil where none have been.
    #
    # Both ends or neither, because they are one claim and half of one cannot be read: a row
    # carrying a bottom and no top says how far back some read got and nothing whatever about
    # what is above it, which is the state 049 emptied and the shape of #566. Nothing writes
    # that state now -- `record_read` always writes both -- and treating it as "nothing has
    # been read" is the reading that costs a re-read rather than a year.
    def imported_range(account_id)
      row = WithingsConnection.of(account_id)
      bottom = row&.fetch(:workouts_imported_year, nil)
      top = row&.fetch(:workouts_imported_through_year, nil)
      bottom && top ? bottom..top : nil
    end

    # Everything the page needs to say what is left, which since #566 is more than a count.
    #
    # A single number could describe the work left when the work was always one unbroken run
    # backwards. It is two runs now -- the years since the last read, and the years below it --
    # and a page given only a total cannot tell a lifter which. So the two gaps are reported as
    # the years they are, and the sentences are built from them in the view.
    def remaining(read, floor)
      since = unread_since(read)
      older = older_left(read, floor)
      { imported_from: read&.first, imported_to: read&.last,
        unread_from: since&.first, unread_to: since&.last,
        older_left: older, years_left: older + (since&.count || 0) }
    end

    # The years above the read range: the year after it up to this one. Nil where the range
    # already reaches this year, and nil where nothing has been read at all -- an account with
    # no range has no gap above it, only a whole history below.
    def unread_since(read)
      return nil unless read && read.last < Date.today.year

      (read.last + 1)..Date.today.year
    end

    # And the years at or below the bottom of the range that are still to be read. Zero rather
    # than negative where a read went below the floor, which SINCE can do.
    def older_left(read, floor)
      return Date.today.year - floor + 1 unless read

      [read.first - floor, 0].max
    end

    # The years this account's history has now been read over, by whichever route read them.
    #
    # 045 added the bottom of this for the presses alone and said in as many words that the
    # rake task would never write it, because at the time the task's own watermark could be
    # stamped for an account with five unread years behind it and the button could not afford
    # to believe anything the task wrote. #554 closed that, and with the task no longer able to
    # claim a history it did not read there is no reason left for two private opinions of one
    # number: a year read from a terminal is a year read, and a lifter should not be asked to
    # press Import for it. Still emphatically not the measurement poll's `synced_at`, which is
    # a different question about different data -- see 043.
    #
    # ## Why this took a second end, replacing the `LEAST` that used to be the whole of it
    #
    # This was one line -- `least(workouts_imported_year, year)` -- and the argument for it was
    # that the cursor must only ever move backwards, because a SINCE-narrowed task run writing
    # its floor in flat would drag it up over years somebody had already read. That argument
    # was right and it was half the shape. A bottom that only moves down cannot say anything at
    # all about the years above it, and the page was reading it as though it could: #566, where
    # a course of presses that finished in 2023 told a lifter in 2026 that 2024 and 2025 were
    # imported. So what is written down is the stretch of years actually read, at both ends.
    #
    # ## Three cases, because two ranges can fail to touch
    #
    # A read that **touches** what is recorded -- overlapping it, or adjacent to it with no year
    # in between -- widens the record to cover both, and that is every ordinary case: a press
    # reads the year next to the range by construction, and a task run walks from its floor up
    # to this year, which is at or above the top of anything recorded.
    #
    # A read that does **not** touch it can only come from an operator's SINCE, and there the
    # union of the two is not a range and there is nothing honest to write for the year between
    # them. One of the two has to be given up, and it is the shallower: the deeper claim is the
    # one that cost more requests to acquire, and the button walks up through the gap and on
    # over the shallow one anyway, where the other choice would hand a decade back to it. That
    # is also what keeps the promise the old `LEAST` made -- the bottom never moves forward.
    #
    # And a row with nothing recorded, or with half a claim on it, takes the read entire. 049
    # emptied the half-claims; the condition is here because a bottom without a top is not a
    # statement this module is willing to read, wherever it came from.
    #
    # All three in one statement rather than a read and then a write, for the reason the
    # `LEAST` gave: the arithmetic belongs in the database rather than in a round trip this
    # module would have to hold a lock across. Every reference below is to the row as it was
    # before the update, which is what Postgres gives an UPDATE's right-hand sides.
    def record_read(account_id, lowest, highest)
      read = lowest..highest
      DB[:account_withings].where(account_id:).update(
        workouts_imported_year: end_of_range(:workouts_imported_year, :least, lowest, read),
        workouts_imported_through_year: end_of_range(:workouts_imported_through_year, :greatest, highest, read)
      )
    end

    # One end of the recorded range under the three cases above, in the order they are argued.
    def end_of_range(column, merge, year, read)
      Sequel.case([[nothing_recorded, year],
                   [touching(read), Sequel.function(merge, column, year)],
                   [Sequel[:workouts_imported_year] > read.first, year]],
                  column)
    end

    # Half a claim is not a claim. Either column being null means this row has never had a
    # stretch of years written to it that could be widened.
    def nothing_recorded
      Sequel.|({ workouts_imported_year: nil }, { workouts_imported_through_year: nil })
    end

    # Two stretches of years touch unless one ends more than a year before the other begins.
    # Adjacent counts: 2019-2023 and 2024-2026 are one unbroken 2019-2026, and refusing to join
    # them would be refusing to record the ordinary result of pressing the button twice.
    def touching(read)
      Sequel.&(Sequel[:workouts_imported_through_year] >= read.first - 1,
               Sequel[:workouts_imported_year] <= read.last + 1)
    end
  end
end

