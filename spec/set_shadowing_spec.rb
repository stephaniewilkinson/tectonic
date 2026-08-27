# frozen_string_literal: true

require_relative 'spec_helper'

# Ruby 4.0 promoted Set from an autoloaded stdlib class to a core one, and this app had a
# Sequel model called Set. Every file in lib/ and app.rb reopens `class Tectonic`, so a
# bare Set there resolved lexically to the model: `Set.new` returned an empty row of the
# sets table and did not raise, which meant the mistake surfaced somewhere else entirely.
#
# The model is WorkoutSet now. This is the assertion that keeps it that way, because the
# failure it prevents is silent -- nothing about `Set.new` looks wrong at the call site.
describe 'the constant Set inside this app' do
  it 'is the core class, not a model' do
    resolved = Tectonic.instance_eval { Set }

    assert_same Set, resolved
  end

  # Written the way somebody reaching for a Set would write it, rather than through the
  # constant, so this fails if the shadowing ever comes back by another route.
  it 'behaves like a core Set where the app would use one' do
    seen = Tectonic.instance_eval { Set.new }
    seen << 1 << 1 << 2

    assert_equal 2, seen.size
    assert_includes seen, 1
  end

  it 'leaves the model reachable under its own name, on the same table' do
    assert_equal :sets, Tectonic::WorkoutSet.table_name
    refute_equal Set, Tectonic::WorkoutSet
  end
end

