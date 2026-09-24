# frozen_string_literal: true

require_relative '../db'

class Tectonic < Roda
  module MCP
    # Which client created a row, answered once per tool call rather than once per row. #594.
    #
    # `Presenter.provenance` puts `created_by` on every set, every workout and every movement
    # of every payload, and it read that name through a `many_to_one`. One primary-key lookup
    # per row: 200 of them on an `exercise_history` at `MAX_LIMIT`, 21 on a twenty-set
    # `get_workout`, 60 on a long `list_workouts`. None of it slow -- every one is a
    # primary-key hit Postgres answers instantly -- and all of it a round trip holding one of
    # five connections inside a 20-second budget.
    #
    # **The table has two rows in the whole production database.** That is what makes this a
    # "read it once" problem rather than an eager-load one. An eager load solves it too, and
    # #594 says so, but it solves it once per fetch site: three today, and a fourth the next
    # time somebody writes a tool that returns rows and does not think about provenance. This
    # is one place, and a tool cannot forget it.
    #
    # The whole table rather than the ids a payload happens to name, because it is two rows
    # and because the alternative is a query per distinct creator -- cheaper than per row and
    # still a number that depends on the payload. If this table ever grows past the handful of
    # assistants one person connects, `names` is the one method to narrow; nothing else here
    # would change. Nothing is emitted that was not emitted before: a name is only ever read
    # out by the id on a row the account already owns.
    #
    # Bound for the length of one tool invocation and unbound after, by Tool::Invocation --
    # the single place every tool body runs inside, and the object whose own comment says it
    # exists to keep per-request state off the shared tool class. A cache of a database table
    # that outlived the request would answer with a name somebody has since changed, and it
    # would do it for as long as the process lives; this cannot, because the slot is gone
    # before the response is.
    #
    # Unbound, `name_of` still answers, with the one query it would have cost anyway. That is
    # not a fallback nobody hits: the Presenter is also reachable from a console and from a
    # spec that calls a tool body directly, and a lookup that raised or returned nil there
    # would turn a missing binding into a payload that quietly disclaims a row's creator.
    module Applications
      # Thread-local rather than an argument, and this is the trade worth naming. The
      # alternative is threading a lookup through `view_set`, `view_workout` and
      # `view_exercise` and therefore through the twenty-one call sites that reach them --
      # twenty-one signatures carrying an object twenty of them do nothing with, to answer a
      # question about two rows. Puma serves one request per thread, and the binding below is
      # opened and closed in the same method, so the slot's life is exactly one tool call.
      SLOT = :tectonic_mcp_applications

      # One request's answer to "who created this", read on first use and not before: a tool
      # whose payload names no creator at all still costs nothing.
      class Lookup
        def name_of(id)
          id && names[id]
        end

        def names
          @names ||= DB[:oauth_applications].select_hash(:id, :name)
        end
      end

      module_function

      # Runs the block with a fresh lookup bound, and restores whatever was bound before --
      # nil in every real call, and an outer lookup only if a tool ever invokes another tool.
      # Restoring rather than clearing costs a local and makes that nesting harmless instead
      # of subtly wrong.
      def during
        outer = Thread.current[SLOT]
        Thread.current[SLOT] = Lookup.new
        yield
      ensure
        Thread.current[SLOT] = outer
      end

      def name_of(id)
        (Thread.current[SLOT] || Lookup.new).name_of(id)
      end
    end
  end
end

