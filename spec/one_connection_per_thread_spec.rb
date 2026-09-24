# frozen_string_literal: true

require_relative 'spec_helper'

# #591, and the reason this file is a tripwire rather than a fix.
#
# Sequel hands out connections by a "concurrency primitive", and the default is
# `Thread.current`. `TimedQueueConnectionPool#hold` -- the pool this app gets on Ruby 3.2
# and above -- is reentrant on that key, so a second checkout from the same thread returns
# the connection the first one is already holding. Under Puma that is exactly right: one
# request is one thread, and `config/puma.rb`'s arithmetic of five threads to five
# connections is a real ceiling.
#
# Under a fiber scheduler it is wrong, and wrong quietly. Every fiber on the reactor shares
# one thread, so `Sequel.current` returns the same object for all of them and each is handed
# whichever fiber's connection got there first. #591 measured five concurrent selects come
# back as four results and one nil row, three runs out of three, with no `Sequel::PoolTimeout`
# and no `Sequel::DatabaseError` -- rows landing on the wrong fiber, which in this app is one
# lifter's set list rendered from another's query.
#
# `Sequel.extension :fiber_concurrency` re-keys the pool on `Fiber.current` and fixes that,
# and it is deliberately **not** loaded -- see the argument in `lib/tectonic/db.rb`, which is
# where somebody reaching for a fiber scheduler would be standing. The short of it: the
# extension is not inert under threads. An ordinary Ruby `Enumerator` is a fiber, so with the
# extension loaded a query issued from inside one takes a *second* connection and runs outside
# whatever transaction the thread had open -- measured, with the uncommitted row invisible to
# it. That is the same class of silent wrongness the extension exists to prevent, pointed at
# the twenty-odd `DB.transaction` blocks this app has today rather than at the fibers it does
# not have.
#
# So this asserts the state the pool sizing assumes, and fails the day somebody changes it.
# It is not defending a behaviour; it is making a decision impossible to take by accident.
# If this test is what brought you here: read #591, then size the pool before loading it,
# because `max_connections: 5` is a ceiling that matches a fixed thread pool and a queue in
# front of an unbounded one.
describe 'the connection pool' do
  it 'still hands out a connection per thread rather than per fiber' do
    assert_same Thread.current, Sequel.current
  end

  # The same fact read off the pool rather than off the module, because the pool is what
  # actually hands connections out and an extension loaded after it exists would be a third
  # state worth failing on.
  #
  # An `Enumerator` is the cheapest fiber there is, and it is the one this codebase could
  # plausibly grow without anybody thinking of it as concurrency. Nested inside a checkout
  # the thread is already holding, it comes back with that same connection today -- which is
  # what makes a query inside one part of the surrounding `DB.transaction` rather than a
  # separate session that cannot see the rows it has written.
  it 'gives a fiber inside a checkout the connection the thread is already holding' do
    held = []
    from_a_fiber = Enumerator.new do |yielder|
      DB.synchronize { |inside| held << inside.object_id }
      yielder << :done
    end
    DB.synchronize do |connection|
      held << connection.object_id
      from_a_fiber.next
    end

    assert_equal 1, held.uniq.length
  end
end

