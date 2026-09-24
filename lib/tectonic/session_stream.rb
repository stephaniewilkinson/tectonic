# frozen_string_literal: true

class Tectonic < Roda
  # A doorbell for an open session screen: a held-open response that says "something changed"
  # the moment it does, so the screen asks for the change now rather than at its next
  # fifteen-second poll. #592, and the first of #590's async ideas carried over without Falcon.
  #
  # ## A doorbell, not a delivery
  #
  # The stream carries no markup. It sends one event, `changed`, and the page answers it by
  # firing the poll it already has. Everything the poll does right stays exactly where it is and
  # is not solved a second time: the fingerprint and its 204, the swap into #lift-panels that
  # keeps the scroller and its scrollLeft alive, and the poller replacing itself so its `since`
  # is never stale. The poll also goes on running every fifteen seconds whatever happens here,
  # so a stream that never connects -- no EventSource, a proxy that buffers, no signal at all --
  # leaves the screen exactly as current as it was before this existed.
  #
  # ## What it costs, and the three bounds on it
  #
  # A held-open response holds a Puma thread, and there are five. So:
  #
  # - **It closes itself after WINDOW seconds**, with a `done` event, and the page opens a new
  #   one. That also answers the question #592 left open about rack-timeout: a streaming body
  #   is written after `app.call` has returned, so rack-timeout cannot see it, and a body that
  #   bounds itself is the only timeout it has.
  # - **At most LIMIT are open at once per process.** Past that the route answers 204 and the
  #   page backs off and tries later; the fifteen-second poll covers the gap.
  # - **It holds no database connection while it waits.** Each check is one query, which takes
  #   a connection from the pool and gives it back; between checks it holds nothing but the
  #   socket. The pool is sized to the thread count and has no slack to lend a sleeping stream.
  #
  # The page closes its stream when the tab is hidden, so a phone locked on the session screen
  # holds nothing either.
  module SessionStream
    WINDOW = 25
    TICK = 2
    LIMIT = 2

    @open = 0
    @lock = Mutex.new

    # A slot for one more stream, or false where LIMIT are already open.
    def self.claim
      @lock.synchronize do
        next false if @open >= LIMIT

        @open += 1
        true
      end
    end

    def self.release = @lock.synchronize { @open -= 1 if @open.positive? }

    def self.open_now = @lock.synchronize { @open }

    # The response body: a Rack 3 streaming body, which Puma hands the socket to directly
    # rather than buffering. `since` is the fingerprint the page was rendered with -- the same
    # one its poller carries -- so a change that landed between the page loading and this
    # stream opening rings at once rather than being missed.
    class Body
      def initialize(workout, since, window: WINDOW, tick: TICK)
        @workout = workout
        @since = since
        @window = window
        @tick = tick
      end

      def call(stream)
        ring(stream)
      rescue IOError, SystemCallError
        # The lifter closed the tab or lost signal. Nothing to say to nobody.
      ensure
        close(stream)
        SessionStream.release
      end

      private

      # A comment line on each tick is a keepalive and a probe at once: it stops a proxy
      # deciding the connection is idle, and writing to a socket the browser has closed raises,
      # which is how a stream nobody is reading finds out and gives its thread back.
      def ring(stream)
        deadline = monotonic + @window
        while monotonic < deadline
          return stream.write("event: changed\ndata:\n\n") if @workout.session_fingerprint != @since

          stream.write(": waiting\n\n")
          sleep @tick
        end
        stream.write("event: done\ndata:\n\n")
      end

      def close(stream)
        stream.close
      rescue IOError, SystemCallError
        nil
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

