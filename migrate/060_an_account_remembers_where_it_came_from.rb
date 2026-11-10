# frozen_string_literal: true

# Where an account arrived from, so the signup report can say which channel worked. #691.
#
# #684 made it possible to count signups each week; nothing could say whether they came
# from a Reddit thread, Hacker News, an assistant's answer, a search, or a link the owner
# posted. Fathom cannot answer it either: it is cookieless by design, so it can see
# which source a visit came from and never which visit became an account.
#
# Three facts about the first page a browser loaded here, carried in its session until it
# signs up and copied onto the account at that moment:
#
# - `signup_referrer_host`: the host of the referring page, never its path or query, which
#   can carry somebody's search terms or a thread title.
# - `signup_ref`: a `ref` or `utm_source` parameter on that first page. It is the reliable
#   one: assistants' apps often send no referrer at all, but a link that was posted with
#   `?ref=r-weightroom` says so whatever the browser does.
# - `signup_landing_path`: the page itself, path only.
#
# All nullable and all left null for every existing account, for #574's reason: there is
# nothing true to write into them. The landing path is always set for an account that had a
# first touch recorded, so a null there means "from before this was recorded", which the
# report says rather than counting them as having no source.
Sequel.migration do
  change do
    alter_table(:accounts) do
      add_column :signup_referrer_host, String
      add_column :signup_ref, String
      add_column :signup_landing_path, String
    end
  end
end

