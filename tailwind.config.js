// What to scan for class names, and it is not only the templates.
//
// Tailwind reads these files as plain text and keeps every candidate string it finds, so
// a Ruby file naming a class in a string literal counts. That matters more here than in
// most apps: app.rb builds `button_style`, `complete_style`, `rpe_style` and `row_style`
// out of class names, lib/tectonic/calendar.rb keeps a STYLES table of tints per status,
// and none of those appear in a template at all. Purging against views/ alone would
// compile a stylesheet that is missing exactly the classes the session screen and the
// calendar are drawn with, and the pages would render unstyled in the one place nobody
// looks -- production.
// The palette, named by role, reading its values from the custom properties in
// assets/css/app.css rather than holding them here.
//
// That indirection is the point. A hex in this file is a Tailwind fact and goes when
// Tailwind does; a custom property is plain CSS that any stylesheet can read, so the values
// outlive the tool that currently compiles them. What this file contributes is only the
// mapping from a role to a variable.
//
// rgb(... / <alpha-value>) rather than var(--x) on its own: Tailwind substitutes the alpha
// into that placeholder, so `bg-action/70` works the way `text-gray-900/70` already does in
// the nav. Written as a bare var it would compile, and every opacity modifier on a named
// colour would silently produce nothing.
//
// Nothing is removed. Tailwind's own scale is still there, every existing utility still
// resolves, and `bg-action` is the same colour as `bg-lime-500` -- spec/palette_spec.rb
// holds those together so the two cannot drift apart.
const role = (name) => `rgb(var(--color-${name}) / <alpha-value>)`

module.exports = {
  content: ['./views/**/*.erb', './app.rb', './lib/**/*.rb'],
  theme: {
    extend: {
      colors: {
        action: { DEFAULT: role('action'), strong: role('action-strong'), text: role('action-text') },
        session: { DEFAULT: role('session'), strong: role('session-strong') },
        done: { surface: role('done-surface'), edge: role('done-edge') },
        warning: { surface: role('warning-surface'), edge: role('warning-edge'), text: role('warning-text') },
      },
    },
  },
  plugins: [],
}
