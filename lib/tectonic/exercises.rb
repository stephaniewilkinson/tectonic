# frozen_string_literal: true

require_relative 'db'
require_relative 'oauth_application'

class Tectonic < Roda
  class Exercise < Sequel::Model
    one_to_many :sets
    # The OAuth client (LLM) that created this row, or nil for a human-made one.
    # Provenance is displayed only when this resolves, so the web UI's rows stay
    # unadorned.
    many_to_one :created_by_oauth_application, class: 'Tectonic::OAuthApplication',
                                               key: :created_by_oauth_application_id

    # Rows an account may select or view: its own plus the shared library, whose
    # account_id is nil. account_id IN (nil, id) can't stand in for this -- SQL's
    # IN never matches NULL, so it would silently drop the entire library.
    def self.visible_to(account_id)
      where(account_id:).or(account_id: nil)
    end

    # A nil account_id marks a shared library exercise, visible to everyone; any
    # other value is a single account's own.
    def library?
      account_id.nil?
    end
  end
end

