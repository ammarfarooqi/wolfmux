#!/usr/bin/env python3
"""flow-diagrams.py — draws the sequence diagrams in docs/diagrams/ from the specs below.

    tools/flow-diagrams.py        rewrites message-flow.svg, approval-flow.svg and
                                  notification-flow.svg

Hand-placed sequence diagrams drift apart; these share one renderer, so lifelines,
arrows, numbering and colours are identical everywhere. Same palette and type as the
hand-written diagrams (hero, architecture, billing-isolation). Standard library only.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from xml.sax.saxutils import escape

WIDTH = 1280
MARGIN = 48
LANE_TOP = 150
LANE_BOX = (208, 50)
FIRST_STEP = 262
STEP_GAP = 62
MONO_CHAR = 7.25  # px per character at 12px monospace
SANS_CHAR = 6.5  # px per character at 12.5px sans

COLORS = {"amber": "#f5b942", "ice": "#7cc4ff", "green": "#6ee7a8", "violet": "#b69cff", "coral": "#ff7a90", "muted": "#8fa3c2"}


@dataclass(frozen=True)
class Lane:
    name: str
    sub: str
    color: str


@dataclass(frozen=True)
class Step:
    source: int
    target: int  # equal to source: a note on that lifeline
    label: str
    detail: str = ""
    mono: bool = True


@dataclass(frozen=True)
class Flow:
    filename: str
    kicker: str
    title: str
    subtitle: str
    description: str
    lanes: tuple[Lane, ...]
    steps: tuple[Step, ...]
    footer: tuple[str, ...]


FLOWS = (
    Flow(
        filename="message-flow.svg",
        kicker="WOLFMUX · HOW WORK TRAVELS",
        title="A task goes out, a result comes back",
        subtitle="The text of a task never passes through tmux. Beads stores it; the pane only hears that something is waiting.",
        description="Sequence: the lead creates a Beads task for the backend worker. Beads fires its on_create hook, beads-nudge works out that the backend role needs to know and calls teamctl nudge, which types one fixed line into the backend pane. The worker reads and claims the task with bd, works in its own worktree, and closes the task. The same path tells the lead, who reviews the diff and merges.",
        lanes=(
            Lane("🐺 lead", "pane · your checkout", "amber"),
            Lane("Beads", "bd · <project>/.beads", "green"),
            Lane("beads-nudge", "event hook", "muted"),
            Lane("teamctl", "nudge", "ice"),
            Lane("🐶 backend", "pane · own worktree", "violet"),
        ),
        steps=(
            Step(0, 1, 'bd create "API: cart" -t task -a backend -d "…"'),
            Step(1, 2, "on_create · the bead as JSON on stdin"),
            Step(2, 3, "teamctl nudge backend --id shop-12"),
            Step(3, 4, "[wolfmux] Beads update for backend (shop-12)", "one fixed line · the id is validated · debounced"),
            Step(4, 1, "bd show shop-12 · bd update shop-12 --claim"),
            Step(4, 4, "works and commits on ai/backend-… in its own worktree", mono=False),
            Step(4, 1, 'bd close shop-12 -r "commit 3f9c1e2; tests pass"'),
            Step(1, 0, "on_close → beads-nudge → teamctl nudge lead", "the same path, in the other direction"),
            Step(0, 0, "teamctl diff backend · review · merge what it approves", mono=False),
        ),
        footer=(
            "Messages work the same way: bd create \"Subject\" -t message -a <role>. Worker to worker is allowed; every message is in Beads' history.",
        ),
    ),
    Flow(
        filename="approval-flow.svg",
        kicker="WOLFMUX · ONE MANAGER",
        title="The lead decides a worker's permission request",
        subtitle="Only with teamctl policy worker-permissions lead. The default is skip: agents run in their CLI's bypass mode and nothing is asked.",
        description="Sequence: a worker's Claude Code wants to run a command and fires its PermissionRequest hook, teamctl _permission-hook. The hook files request A7 atomically and tells the lead's pane. The lead runs teamctl approve A7 or teamctl deny A7 with a reason. The hook, which has been polling, returns the decision to the worker's CLI as JSON. If nobody answers before the timeout, the hook stays silent and the worker's normal prompt appears.",
        lanes=(
            Lane("🐶 qa", "teammate · Claude Code", "violet"),
            Lane("teamctl", "_permission-hook", "ice"),
            Lane("approvals", "~/.wolfmux/state/<project>", "muted"),
            Lane("🐺 lead", "the only manager", "amber"),
        ),
        steps=(
            Step(0, 1, "PermissionRequest · Bash · npm install left-pad"),
            Step(1, 2, "files request A7", "created atomically · ids never collide"),
            Step(1, 3, "[wolfmux] Permission request A7 from qa", "one line in the lead's pane"),
            Step(3, 2, 'teamctl approve A7      or      teamctl deny A7 "use npm ci"'),
            Step(2, 1, "decision found", "the hook polls · up to 600 s (WOLFMUX_APPROVAL_TIMEOUT)"),
            Step(1, 0, '{"decision": {"behavior": "allow"}}   or   deny + the reason'),
            Step(0, 0, "the CLI runs the command, or tells the model why it may not", mono=False),
        ),
        footer=(
            "No answer in time: the hook prints nothing, so the worker's own prompt appears. A worker cannot approve, deny, stop, restart, destroy or change policy (exit 77).",
        ),
    ),
    Flow(
        filename="notification-flow.svg",
        kicker="WOLFMUX · NOTIFICATIONS",
        title="A notification that leads back to the team",
        subtitle="Inside tmux the usual notifiers fall back to osascript, and macOS files those under Script Editor. teamctl sends its own.",
        description="Sequence: an agent finishes a turn and Claude Code fires its Stop hook, teamctl _notify. teamctl takes the first line of the agent's last message, removes control characters, asks tmux which terminals are attached to the team, and writes an OSC 9 notification to the tty of each capable terminal. The terminal posts the notification, so clicking it brings the tab with the team to the front. With no terminal attached, the fallback is osascript with a hint to run teamctl attach.",
        lanes=(
            Lane("🐺 or 🐶", "an agent · Claude Code", "violet"),
            Lane("teamctl", "_notify · Stop hook", "ice"),
            Lane("tmux", "list-clients", "muted"),
            Lane("iTerm2", "kitty · Ghostty · WezTerm", "green"),
            Lane("you", "macOS notification", "amber"),
        ),
        steps=(
            Step(0, 1, "Stop · last_assistant_message on stdin"),
            Step(1, 1, "first line · control characters removed · 100 characters at most", mono=False),
            Step(1, 2, "which terminals are attached to this team?"),
            Step(2, 1, "/dev/ttys009 · iTerm2 3.7.2"),
            Step(1, 3, "ESC ] 9 ; 🐺 lead: merged the cart API BEL", "written to that terminal's tty · one short write"),
            Step(3, 4, "notification owned by the terminal"),
            Step(4, 3, "click → the tab with the team comes to the front", mono=False),
        ),
        footer=(
            "Team on no screen: Wolfmux.app posts the notification instead (wolf icon). macOS opens the owner of a notification on click, and Wolfmux.app answers by opening a terminal attached to the team.",
            "The ECC plugin's own notifier is switched off inside team agents.   WOLFMUX_NOTIFY = all (default) · lead · off",
        ),
    ),
)


def lane_x(flow: Flow, index: int) -> float:
    span = WIDTH - 2 * MARGIN - LANE_BOX[0]
    return MARGIN + LANE_BOX[0] / 2 + span * index / (len(flow.lanes) - 1)


def text_width(text: str, mono: bool) -> float:
    return len(text) * (MONO_CHAR if mono else SANS_CHAR)


def render_step(flow: Flow, number: int, step: Step, y: float) -> list[str]:
    color = COLORS[flow.lanes[step.source].color]
    family = "mono" if step.mono else "sans"
    size = "12" if step.mono else "12.5"
    x1 = lane_x(flow, step.source)
    parts: list[str] = []
    if step.source == step.target:
        width = text_width(step.label, step.mono) + 56
        left = min(max(x1 - width / 2, MARGIN), WIDTH - MARGIN - width)
        parts.append(f'<rect x="{left:.0f}" y="{y - 17:.0f}" width="{width:.0f}" height="32" rx="16" fill="#16213a" stroke="{color}" stroke-width="1.5"/>')
        parts.append(f'<circle cx="{left + 18:.0f}" cy="{y - 1:.0f}" r="9" fill="{color}"/><text class="sans" x="{left + 18:.0f}" y="{y + 3:.0f}" text-anchor="middle" font-size="11" font-weight="700" fill="#0b1020">{number}</text>')
        parts.append(f'<text class="{family} text" x="{left + 36:.0f}" y="{y + 3:.0f}" font-size="{size}">{escape(step.label)}</text>')
        return parts
    x2 = lane_x(flow, step.target)
    direction = 1 if x2 > x1 else -1
    mid = (x1 + x2) / 2
    width = text_width(step.label, step.mono) + 20
    parts.append(f'<path d="M{x1 + 14 * direction:.0f} {y:.0f} H{x2 - 4 * direction:.0f}" fill="none" stroke="{color}" stroke-width="2" marker-end="url(#head-{flow.lanes[step.source].color})"/>')
    parts.append(f'<rect x="{mid - width / 2:.0f}" y="{y - 27:.0f}" width="{width:.0f}" height="19" rx="4" fill="#0b1020"/>')
    parts.append(f'<text class="{family} text" x="{mid:.0f}" y="{y - 13:.0f}" text-anchor="middle" font-size="{size}">{escape(step.label)}</text>')
    if step.detail:
        detail_width = text_width(step.detail, False) + 16
        parts.append(f'<rect x="{mid - detail_width / 2:.0f}" y="{y + 6:.0f}" width="{detail_width:.0f}" height="17" rx="4" fill="#0b1020"/>')
        parts.append(f'<text class="sans faint" x="{mid:.0f}" y="{y + 19:.0f}" text-anchor="middle" font-size="11.5">{escape(step.detail)}</text>')
    # last, so a label wider than its arrow never covers the step number
    parts.append(f'<circle cx="{x1:.0f}" cy="{y:.0f}" r="10" fill="{color}"/><text class="sans" x="{x1:.0f}" y="{y + 4:.0f}" text-anchor="middle" font-size="11" font-weight="700" fill="#0b1020">{number}</text>')
    return parts


def render(flow: Flow) -> str:
    bottom = FIRST_STEP + STEP_GAP * (len(flow.steps) - 1) + 40
    height = bottom + 34 + 22 * len(flow.footer) + 18
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {height}" width="{WIDTH}" height="{height}" role="img" aria-labelledby="title desc">',
        f'<title id="title">Wolfmux: {escape(flow.title)}</title>',
        f'<desc id="desc">{escape(flow.description)}</desc>',
        "<style>",
        '  .sans { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }',
        '  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; }',
        "  .text { fill: #e6edf7; } .muted { fill: #8fa3c2; } .faint { fill: #5d7196; }",
        "</style>",
        "<defs>",
        *[f'  <marker id="head-{name}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0 10 5 0 10z" fill="{value}"/></marker>' for name, value in COLORS.items()],
        "</defs>",
        f'<rect width="{WIDTH}" height="{height}" rx="24" fill="#0b1020"/>',
        f'<text class="sans" x="{MARGIN}" y="58" font-size="13" font-weight="700" letter-spacing="3" fill="{COLORS["amber"]}">{escape(flow.kicker)}</text>',
        f'<text class="sans text" x="{MARGIN}" y="94" font-size="28" font-weight="700">{escape(flow.title)}</text>',
        f'<text class="sans muted" x="{MARGIN}" y="122" font-size="15">{escape(flow.subtitle)}</text>',
    ]
    for index, lane in enumerate(flow.lanes):
        x, color = lane_x(flow, index), COLORS[lane.color]
        left = x - LANE_BOX[0] / 2
        out.append(f'<line x1="{x:.0f}" y1="{LANE_TOP + LANE_BOX[1]}" x2="{x:.0f}" y2="{bottom}" stroke="#26365a" stroke-width="1.5" stroke-dasharray="4 6"/>')
        out.append(f'<rect x="{left:.0f}" y="{LANE_TOP}" width="{LANE_BOX[0]}" height="{LANE_BOX[1]}" rx="12" fill="#111a2e" stroke="#26365a" stroke-width="1.5"/>')
        out.append(f'<rect x="{left:.0f}" y="{LANE_TOP}" width="{LANE_BOX[0]}" height="5" rx="2.5" fill="{color}"/>')
        out.append(f'<text class="sans" x="{x:.0f}" y="{LANE_TOP + 25}" text-anchor="middle" font-size="15" font-weight="700" fill="{color}">{escape(lane.name)}</text>')
        out.append(f'<text class="mono faint" x="{x:.0f}" y="{LANE_TOP + 42}" text-anchor="middle" font-size="11">{escape(lane.sub)}</text>')
    for number, step in enumerate(flow.steps, start=1):
        out.extend(render_step(flow, number, step, FIRST_STEP + STEP_GAP * (number - 1)))
    for index, line in enumerate(flow.footer):
        out.append(f'<text class="sans muted" x="{MARGIN}" y="{bottom + 34 + 22 * index}" font-size="13">{escape(line)}</text>')
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main() -> None:
    diagrams = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "diagrams")
    for flow in FLOWS:
        with open(os.path.join(diagrams, flow.filename), "w", encoding="utf-8") as handle:
            handle.write(render(flow))
        print(f"wrote docs/diagrams/{flow.filename}")  # noqa: T201 - a command-line tool reports what it did


if __name__ == "__main__":
    main()
