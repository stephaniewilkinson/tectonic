# frozen_string_literal: true

# There was no Puma config at all, so it ran on stock defaults: five threads on MRI
# against a Sequel pool of four, which is a fifth request thread waiting for a connection
# and, past the pool timeout, a Sequel::PoolTimeout -- a 500 on a request that had nothing
# wrong with it. Both numbers now come out of RAILS_MAX_THREADS, read here and in
# lib/tectonic/db.rb, so the pool cannot end up smaller than the set of threads drawing on
# it. The name is what the host's docs and every Puma template use; it says nothing about
# Rails, which this app is not.
#
# Five is where Puma's own default already had it rather than a number chosen to look
# round. The web service is a Render starter instance -- half a CPU -- so more threads
# would queue rather than serve, and each one is another Postgres connection held open.
# What the database plan allows is not something this repo knows: render.yaml has no
# `databases:` block and DATABASE_URL is `sync: false`, pointed at a database managed from
# the dashboard. So the arithmetic is written down rather than a ceiling assumed -- one
# process times five threads is five connections, and raising either raises that.
max_threads = Integer(ENV.fetch('RAILS_MAX_THREADS', 5))
threads max_threads, max_threads

# Render passes the port to bind in the environment; 9292 keeps a local run on the address
# README documents for `rackup`. The host is spelled out because Puma would otherwise bind
# `::` and Render routes to the container over IPv4 -- rackup was binding 0.0.0.0 under
# RACK_ENV=production, and a change of start command is no time to find out whether the
# dual-stack socket happens to answer.
port ENV.fetch('PORT', 9292), '0.0.0.0'

# Zero workers is single mode, which is what `rackup` was already running, and on half a
# CPU a second worker buys queueing rather than throughput. WEB_CONCURRENCY is the knob for
# an instance big enough to want them.
workers Integer(ENV.fetch('WEB_CONCURRENCY', 0))

# Only reached once workers are above zero, whether that came from the variable or a -w on
# the command line. Both lines belong to that case: preloading is what makes forked workers
# share the parent's Postgres connections and use them at the same time, which returns one
# worker's rows to another and reads back from a log as a database fault rather than a
# fork. Declaring the hook unconditionally would instead have Puma warn on every
# single-mode boot that it will not run.
cluster do
  preload_app!
  # before_worker_boot rather than on_worker_boot, which Puma 8 renamed and warns about.
  # It runs in the worker after the preload, so DB is loaded: this drops the inherited
  # handles and Sequel opens the worker its own on first use.
  before_worker_boot { DB.disconnect }
end

