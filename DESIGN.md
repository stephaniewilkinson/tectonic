# Design

The rules the screens are drawn to. The identity stays what it was: the lime bar, the Blonde
display face, sky on the session screen, a grey page with white surfaces on it. What this
file adds is the part that was never written down, so the next screen comes out like the
last one. Every rule here has a helper in `app.rb`, and the helper is how the rule is kept:
a class list written out by hand is a decision nobody else can find.

## Width — `page_style(width)`

Three, by what the page is for.

| width | max | for |
|---|---|---|
| `:form` | 24rem | a form filled in once: sign in, sign up, password resets |
| `:reading` | 42rem | a page read down: home, one exercise, settings, assistants, docs |
| `:wide` | 64rem | data laid out side by side: the workout list, the library, volume, a workout record |

The layout's own container is `:wide`, so a page that names nothing is wide. The session
screen keeps its own phone-width column, since it is used one-handed at the rack.

## Headings — `heading_style(kind)`

| kind | element | face | for |
|---|---|---|---|
| `:page` | h1 | Blonde Sans | the screen's title, once |
| `:section` | h2 | Blonde Sans | a part of the screen |
| `:label` | h2 or h3 | system | the small capitalised line over a group of fields or figures |

Blonde is for h1 and h2 only. At label size it stops being letters: "BARBELL" over the
plate form read as a texture. `serif` (Blonde Serif) stays for surfaces that are read
rather than used — the front page, /about, a workout record's date.

## Buttons — `primary_button_style(kind)`, `secondary_button_style`

- **One filled button per view.** Two filled buttons side by side are two equally loud
  answers to "what now". The second one is `secondary_button_style`: white, grey ring.
- **Lime is the action** (`primary_button_style`), with gray-900 text — white on lime is
  1.98:1.
- **Sky is the session** (`primary_button_style(:session)`): Done, Run session. Lime means
  "finished" on that screen, so a lime control would wear the colour of the state it
  changes.
- Shape — radius, shadow, focus ring — is `button_style`, and every one of these builds
  on it.

## Surfaces — `card_style`

One white surface: `rounded-lg`, a small shadow, a hairline ring. Padding is at the call
site, because a card holding a table wants none and one holding prose wants room.

## Colour

Named by role in `assets/css/app.css` (`action`, `session`, `done`, `warning`). Amber is
warnings only. Links are lime-700 (the lime that clears AA on white).

## Fields — `field_style`. Nav — `nav_link_style`.

Already settled by #239 and #333; listed here so this file is the one place to look.
