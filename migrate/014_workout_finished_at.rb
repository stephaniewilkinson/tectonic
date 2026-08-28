# frozen_string_literal: true

# When the lifter said they were done. #218.
#
# Nothing in this app could say a session was over. `Workout#status` derives everything,
# and `performed?` is *any one set completed* -- so ticking a single warmup moved a session
# into `:performed`, and a session abandoned after one lift was indistinguishable from one
# finished to the last rep. The MCP tools report that same status, which is how an
# assistant reading a training history came to treat a finished day as one still in
# progress: it saw `performed` over incomplete sets and drew the only conclusion available.
#
# No derivation fixes that, which is the point. Three sets done out of ten is genuinely
# ambiguous -- "I stopped early" and "I am between sets" are the same rows -- so the fact
# has to be asserted by the person who knows it rather than guessed from the data.
#
# A timestamp rather than a boolean, at the same cost: "when did I stop" is worth more
# later -- session length, time of day -- than "did I stop", and a null already means no.
#
# Nullable with no default, so every existing session stays exactly as it reads today and
# this arrives as something new to say rather than as a claim made retroactively about
# sessions nobody was asked about.
Sequel.migration do
  up do
    add_column :workouts, :finished_at, DateTime
  end

  down do
    drop_column :workouts, :finished_at
  end
end

