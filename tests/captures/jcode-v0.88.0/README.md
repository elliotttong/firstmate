# jcode v0.88.0 composer captures

Raw pane captures of a real jcode v0.88.0 TUI (`jcode --provider claude --no-update`) in a private tmux 3.6 server.
Each state has three files: `<state>.plain` (`tmux capture-pane -p -S 0 -E -`), `<state>.styled` (the same with `-e`), and `<state>.cursor` (`#{cursor_x} #{cursor_y} #{pane_width}x#{pane_height}`).
The tests read these files so the composer shapes are pinned to measured bytes rather than to a guess.

| state | what the pane held |
|---|---|
| `idle-empty` | fresh session, empty composer: `1>` with the context meter on the same row |
| `idle-typed` | `hello draft text` typed, not submitted: meter moves up a row and a hint row appears |
| `busy2` | mid-turn: prompt row reads `2…` (U+2026), not `N>` |
| `busy4` | idle after a turn: `2>` plus a private-use status glyph at the far right |
| `post-response-empty` | empty composer below an agent reply, with jcode's info box drawn at the top of the screen |
| `wrap` | a long draft wrapped onto a continuation row |
| `multiline-alt` | a draft with a real newline (Alt+Enter): `alpha` / `beta` |
| `blankfirst-alt-top` | a draft whose FIRST line is blank, cursor moved to that blank first line |
| `ws-spaces` | a draft of four spaces |
| `adv-agentglyph`, `adv-digit`, `adv-shellglyph` | drafts consisting of `❯`, `7`, and `>` alone |
