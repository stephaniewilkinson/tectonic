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
module.exports = {
  content: ['./views/**/*.erb', './app.rb', './lib/**/*.rb'],
  theme: { extend: {} },
  plugins: [],
}
