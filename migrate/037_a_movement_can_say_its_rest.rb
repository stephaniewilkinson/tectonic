# frozen_string_literal: true

# How long this movement is rested, when the block does not say. #456.
#
# The rest timer has been able to count down and ring since #281 and #395, and it has never
# done it for anybody. It rings on a *prescribed* rest -- `sets.planned_rest_seconds`, copied
# from `program_lifts.rest_seconds` at generation -- and **no lift has ever carried one**: 126
# program lifts on the reporting account, not one rest. So the bell exists and is unreachable.
#
# It is unreachable for a reason rather than by oversight. `add_program_lift` tells assistants
# to "leave it out rather than inventing a number", and #411 removed the web block editor, so
# the only way to set a rest at all is to ask an assistant to do it lift by lift. A lifter who
# wants a three-minute bell on squats has no way to say so.
#
# ## Why this is a column on the movement and not a default in the app
#
# The timer's own rule: "A prescribed rest is a length somebody named." That is what earns the
# bell -- a countdown that rings unasked is the app interrupting a session, and #263 settled
# that the app does not decide how long anybody rests. A constant of 180 picked here would ring
# at people on a schedule nothing in their programme contains.
#
# A rest on the movement is named by the lifter. "I take three minutes on squats" is a
# statement about their training, made by them, in a form they filled in -- so the bell is
# consented to and calling it prescribed is true.
#
# ## Read rather than copied
#
# Deliberately not generated onto sets. `rest_suggestion` consults this when the set carries no
# prescription of its own, which means it reaches every session already written -- the 126
# lifts, and every set generated from them -- without regenerating anything. Copying it onto
# rows would fix only sessions written after today, which is the wrong half.
#
# It also keeps the precedence readable in one place: the block's own rest wins, then the
# movement's, then the measured median, then nothing.
#
# 5 to 1800 matches Bounds::REST and `sets_planned_rest_seconds_off_warmups`, because the three
# describe the same quantity and a bound that differed between them would be a bound somebody
# eventually crosses. Nullable, and null is the ordinary case: most movements want no bell.
Sequel.migration do
  up do
    alter_table(:exercises) do
      add_column :default_rest_seconds, Integer
      add_constraint(:exercises_default_rest_seconds_in_range) do
        Sequel.lit('default_rest_seconds IS NULL OR (default_rest_seconds >= 5 AND default_rest_seconds <= 1800)')
      end
    end
  end

  down do
    alter_table(:exercises) do
      drop_constraint(:exercises_default_rest_seconds_in_range)
      drop_column :default_rest_seconds
    end
  end
end

