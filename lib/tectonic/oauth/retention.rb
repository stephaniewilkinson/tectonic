# frozen_string_literal: true

class Tectonic < Roda
  module OAuth
    # Deletes OAuth rows that can never be used again. Registration is unauthenticated, so
    # without this every table here grows without bound and anyone can choose how fast.
    #
    # What is deliberately kept matters as much as what goes. A rotated-out refresh token
    # is not garbage: reuse detection works by recognising a spent token and revoking its
    # family, so pruning spent links out of a live chain would answer a replayed stolen
    # token with "unknown token" and leave the grant running. Rows go only once the whole
    # grant is past its absolute deadline. api_tokens is never pruned at all, because the
    # audit log and every row's created_by_token_id point at it -- provenance is meant to
    # outlive the credential.
    module Retention
      module_function

      # Prunes everything older than `cutoff`, answering a table => rows-deleted hash.
      def prune(db, cutoff)
        {
          authorization_codes: codes(db, cutoff),
          refresh_tokens: refresh_tokens(db, cutoff),
          clients: clients(db, cutoff)
        }
      end

      # Codes are single-use and live five minutes; nothing references them.
      def codes(db, cutoff)
        db[:oauth_authorization_codes].where { expires_at < cutoff }.delete
      end

      # A whole chain goes at once, once its grant's absolute deadline has passed.
      # replaced_by_id is a plain integer rather than a foreign key, so no ordering is
      # needed within the table.
      def refresh_tokens(db, cutoff)
        db[:oauth_refresh_tokens].where { chain_expires_at < cutoff }.delete
      end

      # A client nothing was ever issued under, older than the window, is abandoned
      # registration spam -- the only one of these tables an unauthenticated caller can
      # grow. A client is in use if any refresh token, any code, or any still-usable access
      # token names it. That last check is the one that is easy to miss: codes are deleted
      # above, so a client whose code expired but whose hour-long access token is still
      # live would otherwise be deleted out from under a working credential.
      def clients(db, cutoff)
        db[:oauth_clients].exclude(client_id: db[:oauth_refresh_tokens].select(:client_id))
                          .exclude(client_id: db[:oauth_authorization_codes].select(:client_id))
                          .exclude(client_id: live_token_clients(db))
                          .where { created_at < cutoff }.delete
      end

      # Clients named by an access token that is neither revoked nor expired.
      def live_token_clients(db)
        db[:api_tokens].exclude(client_id: nil).where(revoked_at: nil)
                       .where { (expires_at > Sequel::CURRENT_TIMESTAMP) | { expires_at => nil } }
                       .select(:client_id)
      end
    end
  end
end

