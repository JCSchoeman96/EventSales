// Stub Tailwind config for Mishka Chelekom generators.
// EventSales does not run Tailwind in this slice; CSS is precompiled in priv/static.
module.exports = {
  content: ["../lib/event_sales_web/**/*.*ex", "../lib/event_sales_web.ex"],
  theme: { extend: {} },
  plugins: [],
};

