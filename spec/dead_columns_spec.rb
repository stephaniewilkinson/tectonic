# frozen_string_literal: true

require_relative 'spec_helper'

# #197. workouts.photo and accounts.profile_picture were in the schema from 001 and were
# written by nothing and read by nothing -- the only two columns in this database dead at
# both ends. Both were bytea, so the feature they were waiting for was image storage, which
# is a feature rather than a gap and not one wanted now.
#
# Asserted against the live schema rather than against the migration, because what matters
# is the shape of the database a checkout builds. A migration that stops being applied, or
# a column added back by hand, is exactly the case a file-reading test would miss.
#
# 053 dropped two more on the same test. oauth_grants.access_type is rodauth-oauth's, and live
# only behind use_oauth_access_type?, which this app has never turned on -- #602, and the
# migration says what turning it on would need. withings_workouts.effective_seconds was for a
# Withings field that does not exist -- #607.
GONE_COLUMNS = { workouts: :photo, accounts: :profile_picture,
                 oauth_grants: :access_type, withings_workouts: :effective_seconds }.freeze

describe 'the columns a feature was never built for' do
  it 'are no longer in the schema' do
    GONE_COLUMNS.each do |table, column|
      refute_includes DB.schema(table).map(&:first), column,
                      "#{table}.#{column} is back; it was dropped as dead at both ends"
    end
  end

  # The distinction the issue turned on, kept where it can be checked. exercises.icon_url
  # has no UI writer either -- #199 took the field off the form -- but the MCP tools write
  # it and Exercise#icon reads it on every workout record, so it is live at both ends and
  # is not the same shape at all.
  it 'leaves the column that only looks like them' do
    assert_includes DB.schema(:exercises).map(&:first), :icon_url
  end
end

