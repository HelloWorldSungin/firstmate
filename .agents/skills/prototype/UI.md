<!-- Adapted from Matt Pocock's prototype skill. MIT License. Copyright (c) 2026 Matt Pocock. -->

# UI Prototype

Generate several structurally different UI variants on one route and make them switchable with a URL parameter and floating bottom bar.

Prefer variants embedded in an existing page so they encounter real navigation, data, density, and constraints.
Create a new throwaway route only when no plausible host page exists.

Default to three variants and cap at five.
Make them disagree about layout, information hierarchy, and primary affordance, not only color or copy.
Keep existing data fetching above a variant switcher and vary only the rendered subtree.

The switcher cycles backward and forward, shows the active variant, updates a shareable URL parameter, supports arrow keys outside editable fields, and is visibly separate from the proposed design.
Gate it out of production builds as defense in depth.

Provide the route and variant keys in the scout report.
Record the chosen combination and why.
Keep every variant and the switcher on the throwaway scratch branch.
The main design branch receives only the verdict and primary-source pointer.

Do not share a layout that prevents genuine variation, connect real mutations, or promote prototype code directly to production.
