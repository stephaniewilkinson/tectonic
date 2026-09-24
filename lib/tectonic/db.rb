# frozen_string_literal: true

require 'sequel'
require 'logger'
# Every model reopens class Tectonic < Roda, so loading one outside app.rb -- from
# a rake task, say -- needs the superclass to already exist.
require 'roda'

# max_connections is Sequel's own default of four without this, one short of the five
# threads Puma serves requests on, so the fifth thread waited for a connection and could
# raise Sequel::PoolTimeout on a request that had nothing wrong with it. config/puma.rb
# sizes the thread pool from the same variable, so the two cannot drift apart again.
#
# **That arithmetic is a ceiling only because this app runs threads, and the pool is keyed on
# them.** #591, which is a tripwire rather than a bug: Sequel hands out connections by
# `Sequel.current`, which is `Thread.current`, and `TimedQueueConnectionPool#hold` is
# reentrant on that key -- ask twice on one thread and you get the connection you already
# hold. One request is one thread here, so that is exactly right, and five threads can never
# want a sixth connection.
#
# Under a fiber scheduler it is exactly wrong, and wrong without raising. Every fiber on a
# reactor shares one thread, so all of them key to the same object and each is handed whatever
# connection the first one checked out. #591 measured five concurrent selects returning four
# results and a nil row, three runs of three, with no `Sequel::DatabaseError` and no pool
# timeout: rows simply landing on the wrong fiber, which in this app is one lifter's set list
# rendered from somebody else's query. `Sequel.extension :fiber_concurrency` re-keys the pool
# on `Fiber.current` and fixes it, and it has to be loaded before any connection is held --
# which is to say here, above this line.
#
# **It is deliberately not loaded**, and the reason is not caution about an unused feature.
# The extension is not inert under threads, which is the part #591 left open and this is the
# answer to. An ordinary Ruby `Enumerator` is a fiber. With the extension loaded, a query
# issued from inside one takes a *second* connection rather than the one the surrounding
# thread is holding -- measured here against sequel 5.107.0, deterministic: inside
# `DB.transaction`, a count run from inside an `Enumerator` could not see the row the
# transaction had just inserted, because it was a different session. This app has twenty-odd
# `DB.transaction` blocks, including the ones ProgramGenerator and WithingsBackfill.rehearse
# write through, and no fibers at all. Loading it would therefore buy nothing that runs today
# and arm the same class of silent wrongness -- work done outside the transaction that was
# supposed to contain it -- against code that does.
#
# So the hazard is written down where somebody introducing fibers would be standing, and
# spec/one_connection_per_thread_spec.rb fails the day the keying changes rather than the day
# a lifter sees somebody else's sets. Anyone taking that step needs the second half of #591
# too: a reactor's concurrency is unbounded, so `max_connections` stops being a ceiling that
# matches the workload and becomes a queue in front of it, with `pool_timeout` deciding
# requests. config/puma.rb's arithmetic would want rewriting rather than porting.
DB = Sequel.connect ENV.fetch('DATABASE_URL'), max_connections: Integer(ENV.fetch('RAILS_MAX_THREADS', 5))
DB.extension :date_arithmetic
# pg_json backs the mcp_audit_log.arguments jsonb column, so it comes back as a Ruby
# Hash and can be written with Sequel.pg_jsonb.
DB.extension :pg_json

# Sequel logs each statement with its bound values, so a logger attached here writes out
# the email address on an accounts row and every weight and rep somebody has recorded.
# That is fine on your own machine, where the data is yours and reading the SQL is the
# point, and wrong on a deployment, where the lines go to a log store nobody chose to keep
# a training log in, are retained and billed by the host, and cost a formatted line per
# query on the request path. This read `unless RACK_ENV == 'test'` for years, which
# quietened the suite and left development and production both logging everything.
#
# DB_LOG turns the log on wherever it is set, which is what makes tracing a real query
# against a deployment possible for as long as it takes and no longer. Empty counts as
# unset, as it does everywhere else here, because a name listed in a .env without a value
# arrives as "".
DB.loggers << Logger.new($stdout) if ENV['RACK_ENV'] == 'development' || !ENV.fetch('DB_LOG', nil).to_s.empty?

