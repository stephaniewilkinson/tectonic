# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # its login and workout helpers; idempotent require
require 'stringio'

# #592. An open session screen found out about a set an assistant logged at its next
# fifteen-second poll. The stream is a doorbell for that poll: it says `changed` the moment the
# sets differ, and the page fires the poll it already has. See lib/tectonic/session_stream.rb.
module Doorbell
  # A socket to write to, that can be told to hang up.
  class Socket < StringIO
    def initialize(hang_up_after: nil)
      super()
      @writes = 0
      @hang_up_after = hang_up_after
    end

    def write(chunk)
      @writes += 1
      raise Errno::EPIPE if @hang_up_after && @writes > @hang_up_after

      super
    end
  end

  # A session whose fingerprint reads as one thing and then, after `turns` checks, another.
  class Changing
    def initialize(turns) = @left = turns

    def session_fingerprint
      @left -= 1
      @left.negative? ? 'after' : 'before'
    end
  end

  # A stream that says it is done and gives its slot back, for a route spec that wants the
  # headers and not the wait.
  def finished_at_once
    lambda do |stream|
      stream.write("event: done\ndata:\n\n")
      Tectonic::SessionStream.release
    end
  end

  def ring(workout, since = 'before', **)
    socket = Socket.new(**)
    Tectonic::SessionStream.claim
    Tectonic::SessionStream::Body.new(workout, since, window: 1, tick: 0.01).call(socket)
    socket.string
  end
end

describe 'the doorbell on a session screen' do
  include Doorbell

  it 'rings when the sets change while it is open' do
    heard = ring(Doorbell::Changing.new(3))

    assert_includes heard, "event: changed\n"
    refute_includes heard, 'event: done'
  end

  # A change that landed between the page loading and the stream opening is not missed: the
  # stream compares against what the page was rendered with, not against what it first sees.
  it 'rings at once for a change it opened after' do
    assert ring(Doorbell::Changing.new(0)).start_with?("event: changed\n")
  end

  it 'says it is done when nothing changed, so the page can open another' do
    heard = ring(Doorbell::Changing.new(1_000_000))

    assert heard.end_with?("event: done\ndata:\n\n")
    refute_includes heard, 'event: changed'
  end

  # A held stream holds one of five Puma threads, so a stream nobody is reading has to notice
  # and give its slot back rather than waiting out its window.
  it 'gives its slot back when the browser hangs up' do
    before = Tectonic::SessionStream.open_now
    ring(Doorbell::Changing.new(1_000_000), hang_up_after: 2)

    assert_equal before, Tectonic::SessionStream.open_now
  end

  it 'stops taking streams past its limit' do
    Tectonic::SessionStream::LIMIT.times { Tectonic::SessionStream.claim }

    refute Tectonic::SessionStream.claim
  ensure
    Tectonic::SessionStream::LIMIT.times { Tectonic::SessionStream.release }
  end
end

describe 'the doorbell route' do
  include Rack::Test::Methods
  include RouteOwnership
  include Doorbell

  before { @account_id = login }

  it 'is closed to somebody else\'s session' do
    before = Tectonic::SessionStream.open_now
    get "/workouts/#{strangers_workout.first}/session/stream"

    assert_equal 302, last_response.status
    assert_equal before, Tectonic::SessionStream.open_now
  end

  it 'answers 204 rather than a stream once the limit is reached, so the page backs off' do
    Tectonic::SessionStream::LIMIT.times { Tectonic::SessionStream.claim }
    get "/workouts/#{own_workout(@account_id)}/session/stream"

    assert_equal 204, last_response.status
  ensure
    Tectonic::SessionStream::LIMIT.times { Tectonic::SessionStream.release }
  end

  it 'streams events, telling nothing between it and the browser to buffer them' do
    Tectonic::SessionStream::Body.stub(:new, ->(*) { finished_at_once }) do
      get "/workouts/#{own_workout(@account_id)}/session/stream?since=x"
    end

    assert_equal 'text/event-stream', last_response.headers['content-type']
    assert_equal 'no', last_response.headers['x-accel-buffering']
    assert_includes last_response.body, 'event: done'
  end
end

# The page's half: the poll listens for the doorbell as well as for its timer.
describe 'the poller on a session screen' do
  include Rack::Test::Methods
  include RouteOwnership

  it 'answers the doorbell as well as its timer' do
    account_id = login
    get "/workouts/#{own_workout(account_id)}/session"

    assert_includes last_response.body, 'session-changed from:body'
    assert_includes last_response.body, '/session/stream?'
  end
end

