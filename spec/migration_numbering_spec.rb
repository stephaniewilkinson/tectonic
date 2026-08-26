# frozen_string_literal: true

require_relative 'spec_helper'

# What the migrate directory has to be for the migrator to run at all.
#
# Two migrations arrived numbered 011 -- one adding a name to workouts, one widening the
# weight columns -- because each was written on a branch cut from a main that had neither,
# and Sequel's integer migrator numbers by filename. Nothing caught it. Both branches were
# green, both pull requests were green, and the collision only existed once they were both
# on main: `rake db:migrate` then raised `Duplicate migration version: 11` and refused to
# run a single migration.
#
# That is the pre-deploy command in render.yaml, so the next deploy would have failed, and
# any fresh checkout could not build a database at all. The suite did not notice because
# every run migrates a database that is already at the right version or builds one from a
# directory that was fine on its own branch.
#
# Read off the filenames rather than by running anything, because that is what the migrator
# reads, and this has to fail on the branch that adds the second 011 rather than after both
# have landed.
module MigrationNumbering
  DIRECTORY = File.expand_path('../migrate', __dir__)

  # Dir[] already sorts, and rubocop is right that saying so twice is noise. The order
  # matters: the gap check below compares this against 1..n.
  def self.files = Dir[File.join(DIRECTORY, '*.rb')]

  def self.versions = files.map { |path| File.basename(path).to_i }
end

describe 'the migrate directory' do
  it 'has migrations in it, so the rest of this is checking something' do
    refute_empty MigrationNumbering.files
  end

  # The one that actually happened.
  it 'numbers each migration differently' do
    duplicated = MigrationNumbering.versions.tally.select { |_, count| count > 1 }.keys

    assert_empty duplicated,
                 "two migrations share a version: #{duplicated.map do |version|
                   MigrationNumbering.files.select { |f| File.basename(f).to_i == version }.map { |f| File.basename(f) }
                 end.flatten.join(', ')}"
  end

  # A gap is the other way the same mistake shows up: renumbering the loser of a collision
  # to 013 rather than 012 leaves 012 missing, and Sequel refuses that too, with
  # "Missing migration version".
  it 'leaves no gap in the sequence' do
    versions = MigrationNumbering.versions

    assert_equal (1..versions.length).to_a, versions
  end

  # A file whose name does not start with a number is version 0 to `to_i`, which collides
  # with anything else that fails to parse and is silent about why.
  it 'starts every filename with its version' do
    MigrationNumbering.files.each do |path|
      assert_match(/\A\d{3}_/, File.basename(path), "#{File.basename(path)} does not open with a version")
    end
  end
end

