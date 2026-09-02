# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/timing'

# The arithmetic on its own, with no database and no HTTP, in the shape one_rep_max_spec
# uses for the same reason: what could be wrong here is a subtraction, and a subtraction
# does not need a web server to be wrong in.
#
# The thing under test is a decision as much as a calculation. What is measured between two
# Done taps is the rest *plus* the working time of the set that ended it, because one tap
# per set is one event per set -- so it is called a turnaround everywhere, and the specs
# below use that word deliberately. A number named "rest" would be a number the app cannot
# see.
module Timings
  BASE = Time.at(1_800_000_000).utc

  # A workout as Timing reads one: either a model or a plain row, and the plain row is what
  # this file uses because finished_at is the only field it touches.
  def workout(finished_at: nil)
    { finished_at: }
  end

  # Sets carrying nothing but the columns Timing looks at, at offsets in seconds from a
  # fixed base. nil means a set that was never completed and so carries no stamp.
  def sets_at(*offsets, **extra)
    offsets.map do |offset|
      { completed_at: offset && (BASE + offset), is_completed: !offset.nil? }.merge(extra)
    end
  end

  def session(sets, finished_at: nil)
    Tectonic::Timing.session(workout(finished_at:), sets)
  end
end

describe 'how long a session ran' do
  include Timings

  it 'is the first stamp to the last while it is still going' do
    measured = session(sets_at(0, 120, 300))

    assert_equal 300, measured[:overall]
    assert_equal :in_progress, measured[:overall_basis]
  end

  # A session whose last set was followed by ten minutes of putting plates away ended when
  # the lifter said it did, not when the bar last moved.
  it 'runs to finished_at where the lifter said they were done' do
    measured = session(sets_at(0, 120), finished_at: Timings::BASE + 900)

    assert_equal 900, measured[:overall]
    assert_equal :finished, measured[:overall_basis]
  end

  # A beginning with nothing after it is not a length, and answering zero would be
  # answering a question nobody asked.
  it 'is nothing at all for a single completed set with no end' do
    assert_nil session(sets_at(0))[:overall]
  end

  # Every set that existed before #281 shipped carries no stamp, and inventing one would be
  # inventing training history.
  it 'is nothing at all for a session with no stamps' do
    assert_nil session(sets_at(nil, nil))[:overall]
  end
end

describe 'the turnarounds between sets' do
  include Timings

  it 'are the intervals between consecutive stamps' do
    assert_equal [120, 180], session(sets_at(0, 120, 300))[:turnarounds]
  end

  # Unstamped sets are absent rather than zero: a session part-lifted through the screen and
  # part-logged afterwards must not produce a turnaround against a set that has no time.
  it 'skip the sets that carry no stamp' do
    assert_equal [240], session(sets_at(0, nil, 240))[:turnarounds]
  end

  it 'are empty for a session with one stamp' do
    assert_empty session(sets_at(0))[:turnarounds]
  end
end

# One four-hour "rest" ruins every average of the rest of them, and the ordinary way this
# data goes wrong is a lifter who took a phone call or left the page open until after
# dinner.
describe 'a gap too long to be training' do
  include Timings

  it 'is left out of the turnarounds' do
    measured = session(sets_at(0, 120, 120 + Tectonic::Timing::LONG_GAP_SECONDS + 1))

    assert_equal [120], measured[:turnarounds]
  end

  # Counted rather than dropped silently. "Typically 2m" over a session with a hole in it is
  # a different session from one without, and a reader who cannot see the count cannot tell.
  it 'is counted so a reader can see it happened' do
    measured = session(sets_at(0, 120, 120 + Tectonic::Timing::LONG_GAP_SECONDS + 1))

    assert_equal 1, measured[:discarded]
  end

  # It is a defended guess rather than a measurement, so the boundary is worth pinning: a
  # gap exactly at the ceiling is still training.
  it 'is kept at exactly the ceiling and dropped one second past it' do
    assert_equal 1, session(sets_at(0, Tectonic::Timing::LONG_GAP_SECONDS))[:turnarounds].length
    assert_empty session(sets_at(0, Tectonic::Timing::LONG_GAP_SECONDS + 1))[:turnarounds]
  end

  # The overall length is still not trimmed by it. Since #318 the trimmed figure is a second
  # number rather than a replacement, so both readings survive and neither destroys the other.
  it 'still counts towards how long the session ran' do
    measured = session(sets_at(0, 120, 120 + Tectonic::Timing::LONG_GAP_SECONDS + 1))

    assert_equal 120 + Tectonic::Timing::LONG_GAP_SECONDS + 1, measured[:overall]
  end
end

# The span with the hours nobody was training taken back out. #318. A session logged either
# side of midnight reported 24h and meant nine minutes.
describe 'the time a session was actually being trained' do
  include Timings

  it 'is the span with the long gaps subtracted' do
    walked_off = 120 + Tectonic::Timing::LONG_GAP_SECONDS + 1
    measured = session(sets_at(0, 120, walked_off, walked_off + 180))

    assert_equal 300, measured[:active]
    assert_equal walked_off + 180, measured[:overall]
  end

  # The midnight case the issue reported, to the minute: one set late on a Sunday, four the
  # next morning three minutes apart.
  it 'reads a session split across a night as the training it contained' do
    overnight = 24 * 60 * 60
    measured = session(sets_at(0, overnight, overnight + 180, overnight + 360))

    assert_equal 86_760, measured[:overall]
    assert_equal 360, measured[:active]
  end

  # Nothing to take out is the ordinary session, and it must not read differently from
  # before -- both numbers agree, which is what lets every surface show only one of them.
  it 'is the whole span when no gap was too long' do
    measured = session(sets_at(0, 120, 300))

    assert_equal measured[:overall], measured[:active]
  end

  # A long tail to finished_at stays in: finishing is something the lifter said, and the ten
  # minutes spent putting plates away is time the session cost.
  it 'keeps the time between the last set and being done' do
    measured = session(sets_at(0, 120), finished_at: Timings::BASE + 5400)

    assert_equal 5400, measured[:active]
  end

  it 'is nothing at all where there is no span to trim' do
    assert_nil session(sets_at(0))[:active]
  end
end

# The middle rather than the mean, because one long break between lifts pulls a mean past
# every gap that actually happened, and the question is "what is normal for me".
describe 'the typical turnaround' do
  include Timings

  it 'is the middle one of an odd number' do
    assert_equal 120, session(sets_at(0, 60, 180, 660))[:typical_turnaround]
  end

  it 'is the average of the middle two of an even number' do
    assert_equal 90, session(sets_at(0, 60, 180))[:typical_turnaround]
  end

  it 'is nothing at all when there are no turnarounds to take a middle of' do
    assert_nil session(sets_at(0))[:typical_turnaround]
  end
end

# The one part of "how long did the sets take" that is measured rather than inferred: a
# plank states its own length, so it needs no clock.
describe 'the seconds held on timed work' do
  include Timings

  it 'are summed off the sets that state their own length' do
    held = sets_at(0, 120, duration_seconds: 60)

    assert_equal 120, session(held)[:held]
  end

  # A written but unlifted 60 second hold is time nobody spent.
  it 'count only the completed ones' do
    written = [{ completed_at: nil, is_completed: false, duration_seconds: 60 }]

    assert_equal 0, session(written)[:held]
  end

  it 'are zero for a session counted entirely in reps' do
    assert_equal 0, session(sets_at(0, 120))[:held]
  end
end

# How a duration reads on a gym floor. Seconds under two minutes, where a turnaround is the
# thing being read and "2m" would round away the difference between 61 and 119; minutes
# above it, where a ticking second is a distraction.
describe 'spelling a duration' do
  it 'gives seconds under two minutes' do
    assert_equal '45s', Tectonic::Timing.phrase(45)
    assert_equal '119s', Tectonic::Timing.phrase(119)
  end

  it 'gives whole minutes up to an hour' do
    assert_equal '2m', Tectonic::Timing.phrase(120)
    assert_equal '59m', Tectonic::Timing.phrase(3599)
  end

  it 'gives hours and minutes past one' do
    assert_equal '1h 0m', Tectonic::Timing.phrase(3600)
    assert_equal '1h 12m', Tectonic::Timing.phrase(4320)
  end

  it 'says nothing about nothing' do
    assert_nil Tectonic::Timing.phrase(nil)
  end
end

