# frozen_string_literal: true

require_relative '../../body_readings'
require_relative '../../error_reporting'
require_relative '../../withings_measures'
require_relative '../../withings_sleep'

class Tectonic < Roda
  module MCP
    module Tools
      # Reading the scale before reading the table, and saying what that came back with. #533.
      #
      # #518 built the fetch and #519 built the three tools over what it stores, each in its own
      # worktree and each staying out of the other's, so nothing ever joined them:
      # `WithingsMeasures.freshen` had no caller outside its own specs. A lifter could connect
      # Withings, watch the settings page report the connection live, and read three tools that
      # answered honestly and emptily forever -- nothing broken, nothing raised, and no data.
      # This is the join, and it is shared rather than written three times because what a tool
      # says about a failed fetch is the substance of it and three copies would be three
      # chances to say it differently.
      #
      # ## Why the reading tools do the asking
      #
      # #518 settled the trigger and this only obeys it: fetch when the connector asks, if
      # `synced_at` is stale, behind the fifteen-minute floor `freshen` already keeps. A
      # scheduled job wants a second paid service on Render, which is the infrastructure #458
      # declined; a Sync button is one more thing for a person to remember, and nobody is
      # looking at a page when an assistant asks what they weigh. The numbers only need to be
      # current at the moment somebody reads them, so reading is when they are made current --
      # and the floor is what keeps a conversation of a dozen tool calls to one HTTP call.
      #
      # ## A fetch may never make a read fail
      #
      # `Withings.post` folds every provider failure into nil precisely so that a bad afternoon
      # at Withings is not an exception, and this honours that rather than undoing it one layer
      # up. Everything is rescued, and the worst a failed fetch can do to a tool call is add a
      # sentence to it: the stored history is still the right answer, and a lifter asking what
      # they weigh gets it. A tool that errored because a third party was rate limiting us
      # would make the connector worse than no connector, since a tool call that fails is one
      # an assistant retries, apologises for, and stops using.
      #
      # ## And it may never be ignored
      #
      # The outcome is the whole reason `freshen` hands back a struct rather than a count, and
      # a caller that drops it puts back exactly the silent lie the rest of this design spent
      # its effort avoiding. Two of the six are lies of that shape and neither is visible in
      # the numbers:
      #
      # **:revoked** is a grant withdrawn from Withings' own app, where the only symptom is
      # that readings stop arriving. A window reported over three weeks that silently ends on
      # the first of them reads as a bodyweight that has been flat -- a conclusion drawn from
      # an absence of data, which is the worst kind to draw.
      #
      # **:incomplete** is the one worth the most care. Withings signals rate limiting as
      # status 601 delivered inside an ordinary HTTP 200, so a throttled fetch stops mid-window
      # and the rows that did arrive are all real. A rolling mean over a window with a hole in
      # it is a number that looks exactly like one over a whole window, and is a different
      # number. Nothing downstream can detect it, because there is nothing wrong with the rows.
      #
      # So the sentence for those leads the answer rather than trailing it: a reader who stops
      # at the first line has to have been told, and nobody needs telling in that position that
      # the scale was last read eleven minutes ago.
      #
      # The note goes in the prose as well as in the structured payload, on #262's lesson --
      # plenty of MCP clients render only the text, and a caveat a client never displays is a
      # caveat nobody reads.
      module Freshness
        module_function

        # What every one of the three tools calls first, before its own query, because the
        # rows a fetch writes are rows that query has to see.
        #
        # `risk` is the tool's own account of what a hole in the window would do to the answer
        # it is about to give, which differs enough between a count, a rolling mean and a
        # single weigh-in to be worth each of them saying in its own words.
        #
        # Not called where the caller has asked for readings the scale cannot have written.
        #
        # This started as one rule with no exception in it -- read the scale whenever anybody
        # reads the numbers, because a filter chooses what to report rather than whether what
        # is reported is current -- and that argument is still the right one for a filter that
        # *includes* Withings. It stops being right for one that excludes it. A request for the
        # caliper's readings cannot be answered differently by anything the scale says, so the
        # call is not a cheap habit, it is a call that could not have changed the answer.
        #
        # And it is not free in the way an exception-free rule assumes. Withings refuses a
        # caller that asks too often, and refuses it as a non-zero status inside an ordinary
        # 200 -- which `answered` folds into the same nil as a withdrawn grant. So a call spent
        # where it could not help is a call closer to the one refusal this module cannot tell
        # apart from a dead connection. The staleness floor bounds how often that happens; it
        # does not make a pointless call worth making.
        #
        # Silent rather than explained: `:not_asked` carries no note, because a sentence about
        # how fresh the scale is would be a caveat about an instrument the caller has just said
        # they are not reading from.
        #
        # ## `instrument`, which is the same exception one step further in
        #
        # #579 added a second read through the same grant: sleep, from a different service, on
        # a different window, with a watermark of its own. Nothing about it changes any of the
        # above -- a failed read still may not be rendered as a lifter who did not sleep, and
        # the six outcomes still mean what they mean -- so it arrives here as a choice of who
        # to ask rather than as a second copy of this module.
        #
        # One instrument per call, never both. The argument is the one `elsewhere?` already
        # makes: a question about bodyweight cannot be answered differently by anything the
        # watch says, and a question about last night cannot be answered differently by the
        # scale. Reading both on every call would double the requests this connector makes
        # against a provider that refuses a caller for asking too often, and it would spend the
        # second one where it could not have helped. Which instrument a question is about is
        # `HealthReadings`' to say, because the metric name is the only thing that says it.
        def checked(context, risk: nil, source: nil, instrument: :scale)
          return NOT_ASKED if elsewhere?(source)

          view = describe(read(context.account_id, instrument))
          view.merge(note: note(view, risk, instrument))
        end

        # Who a name refers to and what they are called in a sentence.
        #
        # The noun is here rather than inline because it appears in four sentences, and four
        # spellings of the same instrument is four chances for a lifter to be told about a
        # scale when they asked about a watch. `reader` is the module that owns the fetch and
        # the floor: both answer `freshen` and `STALE_AFTER`, and nothing here needs to know
        # anything else about either of them.
        INSTRUMENTS = { scale: { reader: WithingsMeasures, noun: 'scale' },
                        watch: { reader: WithingsSleep, noun: 'watch' } }.freeze

        def instrument(named) = INSTRUMENTS.fetch(named)

        def noun(named) = instrument(named)[:noun]

        # Whether the caller has filtered to something Withings did not write. Blank is not a
        # filter -- it is the ordinary case, everything, which includes Withings and therefore
        # wants the read.
        #
        # One source covers both instruments and that is right: `source` names the provider and
        # the grant, not the hardware, and a filter of `withings` means "what came through the
        # connection" rather than "what came off the scale". Which of the two instruments the
        # question is about is carried by the metric, which is what `instrument` is for.
        def elsewhere?(source)
          named = source.to_s.strip
          !named.empty? && named != WithingsMeasures::SOURCE
        end

        # `readings_may_be_missing` is false rather than absent, and it is true to say so: no
        # read was attempted, so nothing about these rows is missing *because a fetch failed*.
        # Whatever wrote them is as complete as it ever was.
        NOT_ASKED = { outcome: 'not_asked', last_read_at: nil,
                      readings_may_be_missing: false, note: nil }.freeze

        # The fetch, and nothing it can do escapes this method.
        #
        # `freshen` is careful and `Withings.post` is more careful still, so an exception here
        # is one neither of them foresaw -- which is exactly the case that must not reach a
        # lifter as "the tool failed unexpectedly and made no change". It is reported rather
        # than swallowed, on #384's reasoning: nobody watches this traffic, and an assistant
        # told to try again will apologise to the lifter and never mention it.
        #
        # Reported as :unreachable, which is the honest reading of an exception: something
        # went wrong on the way to the numbers, and this cannot say the grant is dead.
        def read(account_id, named)
          instrument(named)[:reader].freshen(account_id)
        rescue StandardError => e
          report(e)
          WithingsMeasures::Fetch.new(:unreachable, 0, nil)
        end

        def report(exception)
          return unless ErrorReporting.on?

          Sentry.capture_exception(exception, tags: { surface: 'mcp', tool: 'freshen' })
        rescue StandardError
          # A report that fails must not become the failure this whole method exists to prevent.
        end

        # The outcome as data. `readings_may_be_missing` is `Fetch#failed?` under the name a
        # reader needs it under: it is the one field that answers "can what is below be read as
        # the whole story", and a client reading only one field should read that one.
        #
        # `new_readings` only where a call was actually made, because zero means two different
        # things -- "nothing new had arrived" after a read, and "no read happened" before one --
        # and a field that says both says neither.
        def describe(fetch)
          view = { outcome: fetch.outcome.to_s, last_read_at: BodyReadings.instant(fetch.read_at),
                   readings_may_be_missing: fetch.failed? }
          return view unless %i[stored incomplete].include?(fetch.outcome)

          view.merge(new_readings: fetch.stored)
        end

        # The summary with the note put where it belongs: in front of the numbers where it
        # changes how they read, behind them where it is only housekeeping.
        def told(lines, view)
          ordered = view[:readings_may_be_missing] ? [view[:note], *lines] : [*lines, view[:note]]
          ordered.compact.join("\n")
        end

        def note(view, risk, named)
          case view[:outcome]
          when 'revoked' then revoked(view, named)
          when 'incomplete' then incomplete(view, risk)
          when 'unreachable' then unreachable(view)
          when 'absent' then absent(named)
          when 'stored' then stored(view, named)
          else fresh(view, named)
          end
        end

        # The only failure that genuinely asks somebody to do something, and the only one
        # `freshen` can tell apart from the rest: a refresh that failed. Everything else
        # Withings does arrives as the same nil, so this sentence is kept for the case that
        # really does mean the connection is dead -- telling a lifter to reconnect a working
        # connection is how a caveat stops being read.
        def revoked(view, named)
          renew = 'The Withings connection needs renewing: the grant has been withdrawn, so nothing new ' \
                  "is arriving from the #{noun(named)}. Reconnecting it on the settings page is what " \
                  'starts it again.'
          return "#{renew} Nothing was ever read through it." unless view[:last_read_at]

          "#{renew} Nothing below is newer than #{view[:last_read_at]}, whatever window was asked for."
        end

        # The gap nobody can see. Said in full every time, because the rows that did arrive are
        # real and correct, so there is nothing else anywhere in the answer that could hint at
        # it -- and said with what to do about it, since a few minutes is genuinely all it takes.
        def incomplete(view, risk)
          ['Withings stopped answering partway through this read -- it refuses a caller that asks too ' \
           'often, and says so inside an ordinary 200 -- so the window below may have a hole in it that ' \
           'none of these numbers show.',
           risk, whole(view), 'Asking again in a few minutes is what closes it.'].compact.join(' ')
        end

        def whole(view)
          return 'No read has ever finished, so nothing here is known to be a whole window.' unless view[:last_read_at]

          "The last read that finished was #{view[:last_read_at]}."
        end

        NEVER_REACHED = 'Withings could not be reached just now, and nothing has ever been read from it, ' \
                        'so this is only what was recorded some other way.'

        # Still an answer. The stored history is what a lifter asked about and it is all true;
        # the only thing this cannot do while handing it over is claim it is current.
        def unreachable(view)
          return NEVER_REACHED unless view[:last_read_at]

          'Withings could not be reached just now, so this is the stored history as of ' \
            "#{view[:last_read_at]} rather than anything more recent."
        end

        # Nothing is connected, which is not a failure and is worth one clause anyway: a model
        # that reads "no readings" cannot otherwise tell a scale that has not synced from an
        # account that never had one, and those want opposite next moves.
        #
        # One Withings connection covers both instruments, so this is about the grant rather
        # than about hardware -- but it is said in the words of whichever one was asked about,
        # because a lifter who asked how they slept is not helped by a sentence about a scale.
        def absent(named) = "No #{noun(named)} is connected to this account, so nothing here was read from one."

        def stored(view, named)
          count = view[:new_readings].to_i
          arrived = count.positive? ? "#{count} new reading(s) arrived" : 'nothing new had arrived'
          "Read from the #{noun(named)} just now; #{arrived}."
        end

        # The floor is read off the instrument's own module rather than named here, because the
        # two reads are independent rate limits on two different requests: they happen to be
        # fifteen minutes apart today, and a sentence that assumed they always would be is a
        # sentence that goes quietly wrong the first time one of them moves.
        def fresh(view, named)
          "Last read from the #{noun(named)} at #{view[:last_read_at]}; another read is made when that is " \
            "more than #{instrument(named)[:reader]::STALE_AFTER / 60} minutes old."
        end
      end
    end
  end
end

