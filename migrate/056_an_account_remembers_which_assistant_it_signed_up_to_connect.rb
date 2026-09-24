# frozen_string_literal: true

# Which assistant a new account was signing up to connect, so the first page it sees can say
# so. #628.
#
# Somebody pressing Connect in Claude with no account here is sent to sign in, signs up
# instead, and confirms their address from an emailed link. Where that link is opened in the
# browser the sign-up happened in, the session still holds the consent screen it was heading
# for and they land on it. Where it is opened anywhere else -- a phone, a mail app's own
# browser -- that session is gone, and they land on /start with no idea that the connection
# they came to make did not happen. This column is what lets /start tell them.
#
# Nullable, and null for every account that signed up any other way. Set null rather than
# refusing a delete if the assistant's registration goes: the note it drives is a courtesy and
# not worth holding on to a client row for.
# Concurrently and so outside a transaction, as 017, 044 and 054 are: this runs as Render's
# pre-deploy command, and a lock on accounts is every signed-in request waiting.
Sequel.migration do
  no_transaction

  up do
    alter_table(:accounts) do
      add_foreign_key :signed_up_connecting_id, :oauth_applications, on_delete: :set_null
    end
    # Indexed like every foreign key here, so deleting a client does not scan accounts.
    add_index :accounts, :signed_up_connecting_id, concurrently: true
  end

  down do
    drop_index :accounts, :signed_up_connecting_id, concurrently: true
    alter_table(:accounts) { drop_foreign_key :signed_up_connecting_id }
  end
end

