# Feature Ideas

This is a lightweight backlog for improving the usage view. The details below are intended to clarify the desired experience without prescribing a particular implementation.

## Usage graph improvements

### Smooth the graph

Make the usage trend easier to scan by drawing a smooth curve instead of sharp point-to-point segments.

- Preserve the underlying data values; smoothing should only affect presentation.
- Avoid overshooting below zero or above the actual range between points.
- Keep individual data points available for hover interactions, even if point markers are hidden by default.
- Consider reducing or disabling smoothing when there are very few data points, where a curve could be misleading.

### Add axis labels

Give the graph enough context to be understood without relying on surrounding text.

- Use the x-axis for dates, adapting the label format and number of ticks to the selected timeframe.
- Use the y-axis for usage values, with compact formatting for large numbers where appropriate.
- Include a unit in the y-axis title or nearby label so it is clear whether the graph represents tokens, requests, or another usage measure.
- Keep labels legible in the menu bar's constrained width and in both light and dark mode.

### Show values on hover

Add an interactive tooltip for precise values while preserving a clean graph at rest.

- Snap to the nearest data point as the pointer moves across the graph.
- Show the point's date/time and exact usage value.
- Highlight the active point and optionally add a subtle vertical guide line.
- Keep the tooltip within the graph or window bounds.
- Provide an equivalent click or focus interaction if keyboard accessibility is supported.

## Layout

### Move rate limits below usage

Reorder the view so the primary flow is usage summary, usage graph, then rate-limit status.

- Keep related rate-limit details grouped together below the usage section.
- Maintain clear spacing or a divider between usage and rate limits.
- Check that the new order still works when the window is narrow or content grows vertically.

## Model breakdown (exploration)

Explore showing how total usage is distributed across models, if the available usage data includes a reliable model identifier.

Possible presentation options:

- A compact list showing each model's usage and percentage of the total.
- A stacked graph that shows both the overall trend and each model's contribution over time.
- A model filter that lets the existing graph switch between all usage and a single model.

Questions to resolve before implementation:

- Does the Codex app-server expose model-level usage for every data point and timeframe?
- Should models with very small totals be grouped into an “Other” category?
- How should renamed, aliased, or unavailable model identifiers be displayed?
- Should percentages be based on tokens, requests, cost, or whichever metric the main usage view currently uses?
- How should the UI behave when model-level data is missing or only partially available?

## Suggested order

1. Move rate limits below usage.
2. Add axis labels and hover values to make the existing graph more informative.
3. Add graph smoothing after precise values remain available through the tooltip.
4. Investigate the available data before choosing a model-breakdown design.
