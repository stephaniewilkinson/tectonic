# frozen_string_literal: true

require_relative 'db'
require_relative 'timing'
require_relative 'withings'
require_relative 'withings_connection'

class Tectonic < Roda
  # The activity a watch recorded, and whether it was this session. #520.
  #
  # ## Propose and confirm, and nothing else
  #
  # #520 settled the flow in one line: *"close your workout in Withings, tap finish workout
  # in Tectonic, and Tectonic asks to match the records."* So this proposes and the lifter
  # answers. It never matches silently, which is the thing the issue is most explicit about
  # -- a lifter who walked the dog at 18:00 and lifted at 18:30 has two activities, and the
  # watch may well have called either one strength training. **An overlap in time is good
  # evidence and not proof**, and the difference between evidence and proof is a tap.
  #
  # And it never writes to Withings. The app reads; the watch is the instrument.
  #
  # ## What an interval is, here
  #
  # `workouts.date` is a timestamp that only ever holds midnight -- every writer puts a date
  # in it and every reader casts it back -- so it says nothing at all about when a session
  # ran and is useless for this. The real clock is on `sets.completed_at`, and Timing already
  # reduces it to the two ends: `started_at` is the first completion, `ended_at` is
  # `finished_at` where the lifter said they were done and the last completion otherwise.
  # This reuses `Timing.session` rather than asking the database the same question again, on
  # the grounds that two expressions of "when did this session run" would eventually
  # disagree, and the one that disagreed would be this one.
  #
  # ## The timezone assumption, written down rather than hidden
  #
  # `sets.completed_at` is `timestamp without time zone`, and so are the two ends stored
  # here. Neither carries a zone, so comparing them is only meaningful if both were written
  # in the same one -- and they are: this process writes both, `Time.now` for a completion
  # and `Time.at(epoch)` for a Withings activity, and Sequel is left at its default of
  # storing a Time's local reading. So the comparison holds on any machine, *provided the
  # machine's zone does not change between writing a set and fetching an activity.*
  #
  # On Render the zone is UTC and the question does not arise. On a laptop it does not arise
  # either, until somebody travels. What would break it is a deployment moved between zones
  # with sessions already stored, which would shift every old stamp against every new one --
  # and that is #349's problem rather than this one's. It is worth knowing that the app
  # already makes the stronger version of this assumption elsewhere: `_clock_time.erb`
  # prints `at.utc` and calls it UTC.
  #
  # ## Sessions that cannot match, which is not a bug
  #
  # A session logged at ten at night for training done at seven carries ten o'clock, because
  # `completed_at` is when the tap happened. Nothing overlaps it, no proposal appears, and
  # that is the correct answer rather than something to paper over: the app does not know
  # when that session was trained, and guessing would produce exactly the silent mismatch
  # #520 refuses.
  module WithingsWorkouts
    # What Withings' integer means. 16 is "Lift weights" and 17 is "Fitness", which are the
    # two a barbell session plausibly gets tagged as.
    #
    # **Scoring only.** Nothing filters on this. A lifter who tapped "Other", or whose watch
    # guessed, still lifted, and a category test that excluded them would turn a confident
    # guess into a missing feature.
    LIFTING = { 16 => 'Lift weights', 17 => 'Fitness' }.freeze
    # How much being tagged as lifting is worth, expressed in the same units as the overlap
    # ratio so the two can simply be added.
    #
    # A quarter, which is deliberately not enough to win on its own: an activity tagged "Lift
    # weights" overlapping a tenth of the session loses to an untagged one overlapping all of
    # it, and it should, because the overlap is measured and the tag is a label somebody
    # tapped. It is enough to break the realistic tie, which is a walk and a lift that both
    # touch the session window.
    CATEGORY_BONUS = 0.25
    # How far either side of the session to ask Withings for, in civil days.
    #
    # `getworkouts` takes dates rather than instants, so a session at 23:40 needs tomorrow
    # asked for as well -- and one at 00:20 needs yesterday. A day each way covers both and
    # costs one request either way.
    MARGIN_DAYS = 1
    # How long after a session ends the app is still willing to say an upload may be coming.
    #
    # **This was `LOOKS_BACK`, and it bounded something else entirely.** It was how long the
    # record page kept *asking Withings* about a session, and the argument for having a bound
    # at all was rate limiting: `proposal` fetched on every view inside the window, so without
    # one, browsing a year of training was a few hundred API calls -- which is how a read-only
    # integration gets itself throttled, and a throttled fetch is the one failure this page
    # cannot render honestly (see `Withings.workouts`).
    #
    # **That argument is gone, because #560 removed its cause rather than its symptom.** A
    # page view now reads stored rows and calls nobody; a lifter who wants Withings asked
    # presses a control that asks it. Browsing a year of training is a year of indexed queries
    # and no requests whatever, so there is nothing left for a 24-hour bound to protect -- and
    # proposing from stored activities now applies to a session of any age. That widening is
    # not hypothetical: on the reporting account an activity from yesterday, overlapping a
    # session for 43 of its 49 minutes, sat unproposed purely because the session had passed a
    # day old. It is offered now, on the next page view, with no fetch and no backfill.
    #
    # What the number still governs is a *sentence*. "Nothing from Withings yet" is a claim
    # about lateness, and lateness has a shelf life: closing a workout in the Withings app
    # starts an upload that lands on their servers seconds to minutes later, so for a session
    # that has just finished the claim is true and the advice is worth giving. For a session
    # from last March there is no upload on its way, absent really is absent, and the honest
    # rendering is silence rather than a hedge borrowed from a case that does not apply --
    # which is the distinction `standing` used to keep and this constant now keeps alone.
    #
    # A day rather than an hour, unchanged and for the unchanged reason: a lifter who taps
    # finish and reads the record the next morning is ordinary, and the prompt should be
    # there when they do.
    STILL_ARRIVING = 24 * 60 * 60

    module_function

    # What the record page should say about Withings, or nil where it should say nothing.
    #
    # **It calls nobody.** That is the whole of #560 and it replaces the reasoning that used
    # to sit here, which was #520's: *"the page looks again each time it is opened"*, because
    # the watch's upload is seconds to minutes behind a lifter tapping finish. The observation
    # was right and the implementation put somebody else's service, with a ten-second timeout,
    # in front of an ordinary page render -- so the slowest thing on a record page was
    # Withings, and the number of requests the app made was however many times a session got
    # looked at. Lateness is now handled by a control the lifter presses (see `check`), and
    # what this does is read rows already stored, with one indexed query and no network.
    #
    # Four answers, and they are four rather than two because the differences between them
    # are the substance of #520 and #560:
    #
    #   :matched   -- the lifter said yes; the watch's numbers are the session's numbers
    #   :proposed  -- a stored activity overlaps, with a sentence saying how much
    #   :waiting   -- nothing of Withings' is stored around this session, and it is recent
    #                 enough that an upload may still be on its way
    #   :elsewhere -- activities *are* stored around this session and none of them overlaps
    #                 it, so something was recorded and it was not this
    #
    # The last two were one state, `:waiting`, and folding them was the bug #560 reports: the
    # page told a lifter whose watch had recorded two activities that morning that nothing had
    # arrived, and advised them to check back in a minute for a thing that had already come
    # and was not theirs. Telling them apart costs one count, which `nearby` does.
    #
    # `:unreachable` used to be here too and is no longer a state of the page, because the
    # page no longer asks: a request that was never answered is an outcome of a press and is
    # reported as one. The trap it guarded is not gone and has moved to `check` -- Withings
    # signals a rate limit as body status 601 over HTTP 200, so `Withings.answered` folds a
    # throttle into the same nil as a revoked token, and a page that rendered that as "no
    # activity" would be lying about a thing that exists.
    def proposal(account_id:, workout:, timing:)
      found = matched(workout[:id])
      return { state: :matched, activity: found } if found
      return nil if workout[:withings_dismissed_at] || !WithingsConnection.connected?(account_id)

      window = interval(timing)
      window && propose(account_id, window, workout[:id])
    end

    # Is there already an unanswered proposal against this session, and what does it say.
    #
    # **This is the backfill's question now, and only the backfill's.** It used to be the
    # record page's other path: a session older than the window the page would fetch for got
    # whatever the backfill had written down, and a newer one got a live overlap computed by
    # `candidates`. Two paths to one answer, and they did not agree -- `standing` took the
    # first row it found while `candidates` and `best` scored them, so a session with a
    # written proposal and a second overlapping activity could be offered one activity on the
    # record and the other on /workouts/withings, depending only on its age.
    #
    # #560 collapsed that. A page view reads stored rows whatever the session's age, so
    # `candidates` covers every session `standing` used to cover -- every row this can return
    # overlaps the window, because the backfill only ever proposes rows `candidates` handed
    # it -- and `propose` prefers a written proposal outright, so the record page and the
    # review list name the same activity. What is left here is the idempotency check
    # `WithingsBackfill.offer` makes before it writes: one query and one spelling of "is there
    # an unanswered proposal on this session", because two spellings would eventually disagree
    # about whether a dismissed proposal counts, and the disagreement would show up as a
    # session offered a second activity while the first was still on screen.
    def standing(account_id, workout_id, window)
      row = DB[:withings_workouts].where(account_id:, proposed_workout_id: workout_id,
                                         workout_id: nil, dismissed_at: nil).first
      row && offered(row, window)
    end

    # The activity a session has already been matched to, or nil. Read on every record page,
    # including the ones this module otherwise has nothing to say about, because a match once
    # made is a fact about the session forever rather than a proposal with a shelf life.
    def matched(workout_id) = DB[:withings_workouts].where(workout_id:).first

    # The two ends of the session, from the reading Timing has already done. Nil where there
    # is nothing to compare: a session with no completed sets has no interval, and a session
    # whose two ends are the same instant has one of zero width, which overlaps nothing and
    # would divide by zero if it tried.
    def interval(timing)
      started_at = timing[:started_at]
      ended_at = timing[:ended_at]
      return nil unless started_at && ended_at && ended_at > started_at

      [started_at, ended_at]
    end

    def still_arriving?(ended_at) = Time.now - ended_at < STILL_ARRIVING

    # Asking Withings about one session, because the lifter asked. #560.
    #
    # **The only thing on a record page that makes a request.** #560 was opened because the
    # box said "check back in a minute" and offered no way to check -- the re-fetch existed,
    # on every page view, and was completely undiscoverable, so the likeliest answer to a
    # prompt meaning "try again shortly" was the button that silences it for good. Moving the
    # fetch behind a press makes it discoverable and, in the same move, takes it off the
    # thirty other page views that never wanted it.
    #
    # Three outcomes, because a lifter who has deliberately pressed a button is owed an
    # answer about what came back rather than a silently identical page:
    #
    #   :answered       -- Withings replied, and whatever it sent is now stored
    #   :unreachable    -- Withings did not reply, so nothing has been learned either way
    #   :nothing_to_ask -- no interval or no connection, so there was no question to put
    #
    # `:unreachable` is the trap #520 wrote `:unreachable` into the page for, in its proper
    # place: Withings delivers a rate limit as body status 601 over HTTP 200, exactly like a
    # revoked token and every other error they have, and `Withings.answered` folds the lot
    # into nil. A press that was throttled and a press that found nothing are the same shape
    # by the time they reach here, and they are told apart by that nil and never by counting
    # rows -- rendering a throttle as "nothing arrived" would assert something about the
    # lifter's afternoon on the strength of a request nobody answered.
    #
    # `:nothing_to_ask` is unreachable from the box, which only draws the form where there is
    # a window and a connection. It exists because a post is a post: a hand-made one, or one
    # from a page left open across a disconnect, must say nothing rather than report a
    # failure that never happened.
    def check(account_id:, workout:, timing:)
      window = interval(timing)
      return :nothing_to_ask unless window && WithingsConnection.connected?(account_id)
      return :nothing_to_ask if matched(workout[:id])

      fetched?(account_id, window) ? :answered : :unreachable
    end

    # Ask Withings what it has around this session and store it. True where it answered --
    # including where it answered with nothing -- and false where it did not.
    #
    # Reached only from `check`, which is to say only from a press. It used to be reached
    # from `proposal`, which is to say from every view of every record page inside a
    # 24-hour window; see `STILL_ARRIVING` for why that is no longer so.
    #
    # Deliberately does not touch `account_withings.synced_at`. That column is the resume
    # cursor for the measurement poll (#518, #472), and stamping it from a workout fetch
    # would tell that poll it had already read a window of bodyweights it has never seen.
    # Two different fetches wanting one watermark between them is how data goes quietly
    # missing.
    def fetched?(account_id, window)
      token = WithingsConnection.token(account_id)
      return false unless token

      found = Withings.workouts(token, from: window.first.to_date - MARGIN_DAYS,
                                       to: window.last.to_date + MARGIN_DAYS)
      return false unless found

      DB.transaction { found.each { |activity| store(account_id, activity) } }
      true
    end

    # One activity, written so that writing it twice is writing it once.
    #
    # The same idempotency pattern as `WithingsConnection.store` and the unique index in 041:
    # a unique target and `insert_conflict`, so a window re-read on the next page view is a
    # no-op rather than a second copy of a fortnight.
    #
    # **`workout_id` and `dismissed_at` are absent from the update on purpose.** They are the
    # lifter's answer, and a re-fetch is not new information about it. Withings will keep
    # sending an activity that has been confirmed or refused -- it is still in their account
    # -- and an upsert that wrote every column would un-answer the question every time the
    # page was opened, which is precisely the nagging #520 forbids.
    def store(account_id, activity)
      row = columns(activity)
      DB[:withings_workouts].insert_conflict(target: %i[account_id external_id], update: row)
                            .insert(account_id:, external_id: activity['id'].to_s, **row)
    end

    # Everything Withings sent about one activity, in this schema's names.
    def columns(activity)
      { started_at: Time.at(activity['startdate'].to_i),
        ended_at: Time.at(activity['enddate'].to_i), timezone: activity['timezone'],
        category: activity['category']&.to_i, attrib: activity['attrib']&.to_i,
        modified_at: stamp(activity['modified']), **fields(activity['data']) }
    end

    def stamp(epoch) = epoch.nil? ? nil : Time.at(epoch.to_i)

    # The measurements, which arrive under `data` and only because they were asked for by
    # name. Nil rather than zero where one is absent: a watch that recorded no heart rate and
    # a watch that recorded a resting one are different, and a zero would read as the second.
    def fields(data)
      data = {} unless data.is_a?(Hash)
      { calories: data['calories'], effective_seconds: data['effduration']&.to_i,
        hr_average: data['hr_average']&.to_i, hr_min: data['hr_min']&.to_i,
        hr_max: data['hr_max']&.to_i }
    end

    # The candidate to offer with the sentence that explains it, or the honest description of
    # having none. No age test in front of it: an overlap is an overlap whether the session
    # was trained this morning or in March, and since nothing here fetches there is no longer
    # a reason to decline to look. See `STILL_ARRIVING`.
    #
    # **A proposal somebody already wrote down wins outright**, ahead of scoring. The backfill
    # records its pick in `proposed_workout_id` and /workouts/withings lists that row, so
    # scoring afresh here could name a different activity for the same session on the two
    # screens -- a lifter answering "yes" in one place about a recording the other place was
    # not offering. There is at most one such row per session, because `WithingsBackfill.offer`
    # refuses to write a second while the first is unanswered, so "the one that was written
    # down" is never ambiguous.
    #
    # And nothing at all for an old session with nothing overlapping. That is not the same
    # silence as "there is nothing to say": it is the refusal to say *"nothing yet"* about a
    # session whose watch upload, if there were one, arrived and was filed months ago.
    def propose(account_id, window, workout_id = nil)
      rows = candidates(account_id, window, workout_id)
      pick = rows.find { |row| row[:proposed_workout_id] } || best(rows, window)
      return offered(pick, window) if pick
      return nil unless still_arriving?(window.last)

      around = nearby(account_id, window, workout_id)
      around.positive? ? { state: :elsewhere, nearby: around } : { state: :waiting }
    end

    # One activity offered for one session, in the shape the page and the review list both
    # read. One spelling of it, because the two paths into it -- scored here, written down by
    # the backfill -- are the pair #560 found disagreeing, and a second literal hash is how
    # they would come to disagree again.
    def offered(row, window)
      { state: :proposed, activity: row, overlap: overlap(row, window),
        span: window.last - window.first, because: because(row, window) }
    end

    # How many unanswered activities Withings has around this session without being it.
    #
    # This exists to tell one sentence from another, which is half of #560. `:waiting` said
    # *"nothing from Withings yet -- check back in a minute"* for two situations that are not
    # alike: Withings had nothing for these days, where the watch's upload may genuinely be
    # behind and "yet" is true; and Withings had activities and none of them overlapped this
    # session, where something was recorded, it was simply not this one, and checking back is
    # advice that will never pay off. The reporting account is in the second case and was
    # being told the first.
    #
    # The span is the one a fetch would have stored -- the session's days with `MARGIN_DAYS`
    # either side -- so the count answers "what did asking about this session bring back",
    # which is the question the sentence puts.
    #
    # Counted over the same unanswered scope as `candidates` rather than over every row, so
    # the sentence stays true in the case that would otherwise quietly falsify it: an activity
    # that *does* overlap but has been claimed by another session or refused already is not
    # something this session may be offered, and counting it would produce "3 activities, none
    # of them overlapping" about a set containing one that does.
    def nearby(account_id, window, workout_id = nil)
      from = (window.first.to_date - MARGIN_DAYS).to_time
      to = (window.last.to_date + MARGIN_DAYS + 1).to_time
      unanswered(account_id, workout_id).where { (started_at < to) & (ended_at > from) }.count
    end

    # Everything that could still be this session: unclaimed, un-refused, and overlapping.
    #
    # **Overlap is the gate.** `withings.start < session.end AND withings.end > session.start`
    # -- strict on both sides, so two activities that merely touch at an instant are not
    # candidates for each other. Everything else about the match is a score over these; a row
    # that does not overlap is not ranked low, it is not a candidate at all.
    #
    # The two local names are `opened`/`closed` rather than the column names, and that is not
    # decoration. Inside a virtual row block a bare `started_at` resolves to the *local
    # variable* where one is in scope and to the column where none is, so naming the locals
    # after the columns would compare each column to itself and match everything.
    #
    # **An activity already offered to a different session is not a candidate for this one.**
    # A backfill can leave a proposal against a session from March, and offering the same
    # activity here as well would be one recording asking two sessions to claim it -- with
    # only one of them able to, since `workout_id` is unique, so the loser's yes would
    # silently do nothing. The session it was offered to is still allowed to see it, which is
    # the ordinary case the moment a backfill and the forward flow overlap on one session.
    def candidates(account_id, window, workout_id = nil)
      opened, closed = window
      unanswered(account_id, workout_id).where { (started_at < closed) & (ended_at > opened) }
                                        .order(:started_at).all
    end

    # Everything this session is still allowed to be offered, before the overlap gate: not
    # claimed, not refused, and not already promised to somebody else's session.
    #
    # One spelling, shared by `candidates` and `nearby`, on the same argument
    # `WithingsProposals.outstanding` makes for its own: the count and the list have to mean
    # the same thing by "still a question", and two copies of a four-part filter drift on
    # exactly the clause nobody is watching. Here that drift would read as "2 activities, none
    # of them this session" printed over a box offering one of them.
    def unanswered(account_id, workout_id = nil)
      DB[:withings_workouts].where(account_id:, workout_id: nil, dismissed_at: nil)
                            .where { (proposed_workout_id =~ nil) | (proposed_workout_id =~ workout_id) }
    end

    # The one to propose. Highest score, and the nearest start where two score the same.
    #
    # Nearest-start as the tie-break rather than anything cleverer, because the tie this
    # actually breaks is two recordings of the same training -- a watch and a phone both
    # listening -- and the one that began closest to the first set is the one that was
    # started for it.
    def best(rows, window)
      rows.min_by { |row| [-score(row, window), (row[:started_at] - window.first).abs] }
    end

    # How much of the session the activity covers, plus a nudge for being tagged as lifting.
    #
    # A ratio of the *session's* length rather than of the activity's, or of their union.
    # The question being answered is "is this recording of this session", and a watch left
    # running for an hour after the bar went down should not be penalised for it -- it still
    # covered the session. The reverse case is caught: an activity touching a tenth of the
    # session scores a tenth, whatever else it has going for it.
    def score(row, window)
      (overlap(row, window) / (window.last - window.first).to_f) +
        (LIFTING.key?(row[:category]) ? CATEGORY_BONUS : 0)
    end

    def overlap(row, window)
      ([window.last, row[:ended_at]].min - [window.first, row[:started_at]].max).to_i
    end

    # The score in one sentence, which is what propose-and-confirm actually needs. A number
    # between nought and one and a quarter is not something a lifter can agree or disagree
    # with; "these overlap for 48 of 52 minutes" is, and it is the same fact.
    def because(row, window)
      said = LIFTING[row[:category]]
      phrase = "overlaps this session for #{Timing.phrase(overlap(row, window))} " \
               "of its #{Timing.phrase((window.last - window.first).to_i)}"
      said ? "#{phrase}, and Withings called it #{said.downcase}" : phrase
    end

    # The lifter saying yes. Scoped to the account, and refused where either side has already
    # been answered -- a second confirmation arriving from a stale page must not move a match
    # that is already made, and the unique index on `workout_id` would make it an exception
    # rather than a no-op if it tried.
    # How many rows it linked -- one, or none where there was nothing left to link. A count
    # rather than a flag because "nothing happened" and "it was refused" are the same answer
    # here and a boolean would invite a caller to treat them as different.
    def confirm(account_id:, workout_id:, external_id:)
      return 0 if matched(workout_id)

      DB[:withings_workouts].where(account_id:, external_id:, workout_id: nil, dismissed_at: nil)
                            .update(workout_id:)
    end

    # The lifter saying no, which #520 requires to stick per workout and permanently.
    #
    # Two writes, because "no" means two things at once and only one of them has an activity
    # to hang on. The session is marked asked-and-answered, which is what silences the prompt
    # even for a session Withings will never have anything for. And the activity that was on
    # screen, where there was one, is set aside too: it was offered *because* it overlaps this
    # session, so a lifter saying it is not this session is saying it is not a lift they
    # logged -- and offering it to the session half an hour either side would be the same nag
    # wearing a different session's clothes.
    #
    # The row survives both. Withings will send it again on the next fetch, and a delete
    # would simply let it come back and be proposed afresh.
    def dismiss(account_id:, workout_id:, external_id: nil)
      now = Time.now
      DB.transaction do
        DB[:workouts].where(id: workout_id, account_id:).update(withings_dismissed_at: now)
        next if external_id.to_s.empty?

        DB[:withings_workouts].where(account_id:, external_id:, workout_id: nil)
                              .update(dismissed_at: now)
      end
    end
  end
end

