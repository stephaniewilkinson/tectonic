# frozen_string_literal: true

# When the heart rate behind a matched watch recording was read. #656.
#
# Heart rate arrives on its own now: saying "yes, that was this session" reads the watch's
# series over the session there and then, rather than leaving a button for the lifter to find.
# This column is what stops it being read twice, and what lets the record page tell the two
# cases that still need a hand -- a recording matched before this existed, and one whose read
# Withings did not answer -- from the ordinary case, where there is nothing to do.
#
# On the recording rather than the session, because the recording is what was matched and the
# match is the event that reads it. Null means not read; a time means read, whether or not the
# watch had any heart rate to give.
Sequel.migration do
  change do
    alter_table(:withings_workouts) { add_column :heart_rate_read_at, DateTime }
  end
end

