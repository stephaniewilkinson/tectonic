# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # its mint and mcp_headers

# Every tool that writes or reads a set's weight says it is one dumbbell's. #674.
#
# Read off tools/list rather than off the constants, because the listing is what an assistant
# is actually shown, and a sentence that exists in Ruby but never reaches a description is the
# failure this is guarding against. On 3 November an assistant wrote a pair's total and then
# called the session screen's correct "two at 68 lb" a display bug, in a note to the lifter.
TOOLS_WITH_A_WEIGHT = %w[create_set complete_set update_set set_working_weight add_program_lift
                         update_program_lift create_program get_workout].freeze

describe 'what a dumbbell weight is the weight of' do
  include Rack::Test::Methods

  it 'is said on every tool that writes or reads one' do
    post 'http://localhost/mcp', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}', mcp_headers(mint.raw)
    tools = JSON.parse(last_response.body).dig('result', 'tools').to_h { |tool| [tool['name'], tool['description']] }

    TOOLS_WITH_A_WEIGHT.each do |name|
      assert_includes tools.fetch(name), 'one dumbbell, not the pair', name
    end
  end
end

