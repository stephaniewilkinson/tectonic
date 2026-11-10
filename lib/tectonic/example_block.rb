# frozen_string_literal: true

class Tectonic < Roda
  # One real training block, planned against lifted, for the public example page. #693.
  #
  # The owner's own Block 0 (24 Aug to 20 Sep 2026), chosen for #693 by the owner, as a frozen
  # snapshot rather than a query: the page must never read an account, never change when that
  # account is edited, and never show anything but what is written here. Every number was read
  # through the connector on 10 Nov 2026 (get_program 3, exercise_history for the three main
  # lifts) and copied by hand. No name, no dates, no account id.
  #
  # Shown as it happened, which is the point of it. Squat days in weeks 2 and 3 were skipped,
  # two deadlift sets were left undone twice, and the bench went over plan in week 2. A page
  # where every set matches the plan would be an advert; this one is a log.
  #
  # Weights are pounds, as the app keeps them. Plate breakdowns are left out on purpose: the
  # rack this was lifted on is not part of the snapshot, and the default rack cannot make
  # several of these loads (97, 117), so showing plates would be showing something false.
  module ExampleBlock
    Lift = Struct.new(:name, :plan, :sets, :not_done, :note, keyword_init: true)
    Week = Struct.new(:number, :title, :note, :lifts, :also, keyword_init: true)

    WEEKS = [
      Week.new(
        number: 1, title: 'Entry', note: 'Conservative entry. Rate every main top set.',
        lifts: [
          Lift.new(name: 'Back Squat', plan: '4 × 3, ramping 152 → 166', sets: [],
                   note: 'The planned day was missed. A session later that week, logged through Claude, ' \
                         'was 155 for two fives and two triples, the last rated RPE 10.'),
          Lift.new(name: 'Bench Press', plan: '4 × 3, ramping 95 → 105',
                   sets: [[95, 3, 8], [100, 3, 8], [100, 3, 8], [105, 3, 9]]),
          Lift.new(name: 'Deadlift', plan: '4 × 3, ramping 140 → 156',
                   sets: [[155, 4, nil], [135, 5, nil]], not_done: 2)
        ]
      ),
      Week.new(
        number: 2, title: 'Build', note: 'Step up if week 1 top sets landed RPE 8 or below.',
        lifts: [
          Lift.new(name: 'Back Squat', plan: '4 × 5 at 78% (150), RPE 7', sets: [], note: 'Skipped.'),
          Lift.new(name: 'Bench Press', plan: '4 × 3 at 78% (97), RPE 7',
                   sets: [[97, 3, 7], [97, 5, 7], [97, 4, 8], [97, 4, 8]],
                   note: 'More reps than written on three of four sets.'),
          Lift.new(name: 'Deadlift', plan: '4 × 5 at 78% (147), RPE 7',
                   sets: [[147, 5, 6], [147, 5, 7], [147, 5, 7], [147, 4, 7]])
        ]
      ),
      Week.new(
        number: 3, title: 'Heaviest week', note: 'Heaviest week of the block. Top sets should land RPE 8.',
        lifts: [
          Lift.new(name: 'Back Squat', plan: '4 × 5 at 80% (152), RPE 8', sets: [], note: 'Skipped.'),
          Lift.new(name: 'Bench Press', plan: '4 × 5 at 80% (100), RPE 8',
                   sets: [[100, 5, 7], [100, 5, 8], [100, 5, 8], [100, 5, 8]]),
          Lift.new(name: 'Deadlift', plan: '4 × 5 at 80% (150), RPE 8',
                   sets: [[150, 5, 7], [150, 5, 7]], not_done: 2)
        ],
        also: 'The accessory day gained Spanish squat holds (“should ease the knee, not provoke it”) ' \
              'and banded clamshells for knee tracking.'
      ),
      Week.new(
        number: 4, title: 'Deload', note: 'Deload. Bar speed should feel fast.',
        lifts: [
          Lift.new(name: 'Back Squat', plan: '3 × 5 at 70% (122), RPE 5',
                   sets: [[135, 5, nil], [135, 5, 6], [135, 5, nil]],
                   note: 'Back after two weeks off, and heavier than written.'),
          Lift.new(name: 'Bench Press', plan: '3 × 5 at 70% (77), RPE 5',
                   sets: [[77, 5, nil], [77, 5, nil], [77, 5, nil]]),
          Lift.new(name: 'Deadlift', plan: '3 × 5 at 70% (117), RPE 5',
                   sets: [[117, 5, nil], [117, 5, nil], [117, 5, nil]])
        ]
      )
    ].freeze

    module_function

    # "155 × 4" or "100 × 5 @ 8": RPE only where the lifter rated the set.
    def set_text((weight, reps, rpe)) = rpe ? "#{weight} × #{reps} @ #{rpe}" : "#{weight} × #{reps}"
  end
end

