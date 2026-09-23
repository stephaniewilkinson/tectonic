# frozen_string_literal: true

require_relative '../../body_readings'
require_relative '../../error_reporting'
require_relative '../../withings_measures'

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
        # Called whatever `source` the caller named. A request for the caliper's readings does
        # not need the scale read, but the rule "the account's measurements are made current
        # when they are read" is one rule rather than one with an exception in it, and the
        # exception is the kind that is quietly wrong later -- a filter chooses what to report,
        # not whether what is reported is up to date.
        def checked(context, risk: nil)
          view = describe(read(context.account_id))
          view.merge(note: note(view, risk))
        end

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
        def read(account_id)
          WithingsMeasures.freshen(account_id)
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
          view = { outcome: fetch.outcome.to_s, last_read_at: BodyReadings.instant(fetch.synced_at),
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

        def note(view, risk)
          case view[:outcome]
          when 'revoked' then revoked(view)
          when 'incomplete' then incomplete(view, risk)
          when 'unreachable' then unreachable(view)
          when 'absent' then ABSENT
          when 'stored' then stored(view)
          else fresh(view)
          end
        end

        # The only failure that genuinely asks somebody to do something, and the only one
        # `freshen` can tell apart from the rest: a refresh that failed. Everything else
        # Withings does arrives as the same nil, so this sentence is kept for the case that
        # really does mean the connection is dead -- telling a lifter to reconnect a working
        # connection is how a caveat stops being read.
        def revoked(view)
          renew = 'The Withings connection needs renewing: the grant has been withdrawn, so nothing new ' \
                  'is arriving from the scale. Reconnecting it on the settings page is what starts it again.'
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
        ABSENT = 'No scale is connected to this account, so nothing here was read from one.'

        def stored(view)
          count = view[:new_readings].to_i
          arrived = count.positive? ? "#{count} new reading(s) arrived" : 'nothing new had arrived'
          "Read from the scale just now; #{arrived}."
        end

        def fresh(view)
          "Last read from the scale at #{view[:last_read_at]}; another read is made when that is more " \
            "than #{WithingsMeasures::STALE_AFTER / 60} minutes old."
        end
      end
    end
  end
end

